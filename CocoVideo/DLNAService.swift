import Foundation
import UIKit

/// 一台可投的电视（DLNA MediaRenderer）
struct DLNADevice {
    let key: String          // UDN，用于去重
    let name: String         // friendlyName
    let controlURL: URL      // AVTransport 控制地址
}

/// 极简 DLNA 实现：SSDP 发现 + AVTransport 控制。
/// 安卓那边用乐播 SDK（私有协议、只有安卓），iOS 这里走标准 UPnP，小米/奇异果/当贝这类电视都认。
final class DLNAService {

    static let shared = DLNAService()

    private var sock: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "coco.dlna", qos: .userInitiated)
    private var handler: ((DLNADevice) -> Void)?
    private var seen = Set<String>()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = 8
        return URLSession(configuration: cfg)
    }()

    private init() {}

    // MARK: - 发现

    func start(onDevice: @escaping (DLNADevice) -> Void) {
        stop()
        handler = onDevice
        seen.removeAll()

        sock = socket(AF_INET, SOCK_DGRAM, 0)
        guard sock >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(sock)
            sock = -1
            return
        }

        let src = DispatchSource.makeReadSource(fileDescriptor: sock, queue: queue)
        src.setEventHandler { [weak self] in self?.receive() }
        src.resume()
        source = src

        msearch()
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.msearch() }
        queue.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.msearch() }
    }

    func stop() {
        source?.cancel()
        source = nil
        if sock >= 0 {
            close(sock)
            sock = -1
        }
        handler = nil
    }

    private func msearch() {
        guard sock >= 0 else { return }
        let msg = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: 239.255.255.250:1900\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"

        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(1900).bigEndian
        dst.sin_addr.s_addr = inet_addr("239.255.255.250")

        _ = msg.withCString { cs in
            withUnsafePointer(to: &dst) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(sock, cs, strlen(cs), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutablePointer(to: &from) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(sock, &buf, buf.count, 0, sa, &len)
            }
        }
        guard n > 0 else { return }

        let text = String(decoding: buf[0..<Int(n)], as: UTF8.self)
        guard let location = Self.header(text, "LOCATION"),
              let url = URL(string: location),
              !seen.contains(location) else { return }
        seen.insert(location)
        describe(url)
    }

    private static func header(_ raw: String, _ name: String) -> String? {
        for line in raw.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespaces).uppercased() == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func describe(_ url: URL) {
        session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data else { return }
            let parser = DeviceDescParser()
            let xml = XMLParser(data: data)
            xml.delegate = parser
            xml.parse()

            guard let ctrl = parser.controlURL,
                  let base = URL(string: ctrl, relativeTo: url)?.absoluteURL else { return }

            let name = (parser.friendly ?? "电视").trimmingCharacters(in: .whitespacesAndNewlines)
            let key = parser.udn ?? base.absoluteString
            let device = DLNADevice(key: key, name: name.isEmpty ? "电视" : name, controlURL: base)

            DispatchQueue.main.async {
                self.handler?(device)
            }
        }.resume()
    }

    // MARK: - 控制

    func play(_ device: DLNADevice, media: URL, title: String,
              completion: @escaping (Bool, String) -> Void) {

        let didl = Self.didl(media: media, title: title)
        let setURI = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><CurrentURI>\(Self.escape(media.absoluteString))</CurrentURI><CurrentURIMetaData>\(Self.escape(didl))</CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>
        """

        soap(device.controlURL, action: "SetAVTransportURI", body: setURI) { [weak self] ok, message in
            guard ok, let self = self else {
                completion(false, message)
                return
            }
            let playBody = """
            <?xml version="1.0" encoding="utf-8"?>
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID><Speed>1</Speed></u:Play></s:Body></s:Envelope>
            """
            self.soap(device.controlURL, action: "Play", body: playBody) { ok2, msg2 in
                completion(ok2, ok2 ? "已投到 \(device.name)" : msg2)
            }
        }
    }

    func pause(_ device: DLNADevice, completion: ((Bool) -> Void)? = nil) {
        let body = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:Pause xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"><InstanceID>0</InstanceID></u:Pause></s:Body></s:Envelope>
        """
        soap(device.controlURL, action: "Pause", body: body) { ok, _ in completion?(ok) }
    }

    private func soap(_ url: URL, action: String, body: String,
                      completion: @escaping (Bool, String) -> Void) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"urn:schemas-upnp-org:service:AVTransport:1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = body.data(using: .utf8)

        session.dataTask(with: request) { _, response, error in
            if let error = error {
                completion(false, error.localizedDescription)
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = code >= 200 && code < 300
            completion(ok, ok ? "ok" : "电视拒绝了这条指令（HTTP \(code)）")
        }.resume()
    }

    // MARK: - 元数据

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func didl(media: URL, title: String) -> String {
        let mime: String
        switch media.pathExtension.lowercased() {
        case "m3u8": mime = "application/vnd.apple.mpegurl"
        case "mp4", "m4v": mime = "video/mp4"
        case "flv": mime = "video/x-flv"
        case "ts": mime = "video/mp2t"
        default: mime = "video/mp4"
        }
        return "<DIDL-Lite xmlns=\"urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/\""
            + " xmlns:dc=\"http://purl.org/dc/elements/1.1/\""
            + " xmlns:upnp=\"urn:schemas-upnp-org:metadata-1-0/upnp/\">"
            + "<item id=\"1\" parentID=\"0\" restricted=\"1\">"
            + "<dc:title>\(escape(title.isEmpty ? "COCO影视" : title))</dc:title>"
            + "<upnp:class>object.item.videoItem</upnp:class>"
            + "<res protocolInfo=\"http-get:*:\(mime):*\">\(escape(media.absoluteString))</res>"
            + "</item></DIDL-Lite>"
    }
}

/// 解析 device description，拿 friendlyName / UDN / AVTransport 的 controlURL
private final class DeviceDescParser: NSObject, XMLParserDelegate {

    var friendly: String?
    var udn: String?
    var controlURL: String?

    private var buffer = ""
    private var serviceType = ""
    private var inTransport = false

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        buffer = ""
        if elementName == "service" {
            serviceType = ""
            inTransport = false
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "friendlyName":
            if friendly == nil { friendly = value }
        case "UDN":
            if udn == nil { udn = value }
        case "serviceType":
            serviceType = value
            inTransport = value.contains("AVTransport")
        case "controlURL":
            if inTransport, controlURL == nil { controlURL = value }
        default:
            break
        }
        buffer = ""
    }
}
