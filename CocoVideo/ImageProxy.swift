import Foundation
import UIKit
import WebKit

/// 图片代理：图片站普遍只部署叶证书、开了防盗链，WebKit 校验不过就直接裂图。
/// 原生这边拿字节（放行证书链 + 正确 UA/Referer），顺手压到 480px 再交回去。
///
/// 两种出口：
///  - `loadData`  → 给 cocoimg:// 协议处理器用，直接把字节喂给 <img>（主路径）
///  - `load`      → 老桥接接口，base64 data URI（保留兜底）
final class ImageProxy {

    static let shared = ImageProxy()

    private let dataCache = NSCache<NSURL, NSData>()
    private let uriCache = NSCache<NSURL, NSString>()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.urlCache = nil
        return URLSession(configuration: cfg, delegate: PermissiveTLS(), delegateQueue: nil)
    }()

    private init() {
        dataCache.countLimit = 200
        uriCache.countLimit = 150
    }

    // MARK: - 主路径：返回字节

    func loadData(_ url: URL, completion: @escaping (Data?) -> Void) {
        if let hit = dataCache.object(forKey: url as NSURL) {
            completion(hit as Data)
            return
        }
        fetch(url) { [weak self] data in
            guard let self = self, let data = data else {
                completion(nil)
                return
            }
            let out = Self.downscale(data) ?? data
            self.dataCache.setObject(out as NSData, forKey: url as NSURL)
            completion(out)
        }
    }

    // MARK: - 兼容路径：返回 base64 data URI

    func load(_ url: URL, completion: @escaping (String?) -> Void) {
        if let hit = uriCache.object(forKey: url as NSURL) {
            completion(hit as String)
            return
        }
        loadData(url) { [weak self] data in
            guard let self = self, let data = data else {
                completion(nil)
                return
            }
            let uri = "data:image/jpeg;base64," + data.base64EncodedString()
            self.uriCache.setObject(uri as NSString, forKey: url as NSURL)
            completion(uri)
        }
    }

    // MARK: - 取字节

    private func fetch(_ url: URL, completion: @escaping (Data?) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(Config.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(url.scheme ?? "https")://\(url.host ?? "")/", forHTTPHeaderField: "Referer")
        request.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data = data,
                  !data.isEmpty,
                  data.count <= 8_000_000 else {
                completion(nil)
                return
            }
            completion(data)
        }.resume()
    }

    /// 压到 480px 宽的 JPEG；解不了（webp/异常）就返回 nil，由调用方用原字节
    static func downscale(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxWidth: CGFloat = 480
        let scale = min(1, maxWidth / max(image.size.width, 1))
        let size = CGSize(width: round(image.size.width * scale),
                          height: round(image.size.height * scale))
        guard size.width > 0, size.height > 0 else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        let out = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return out.jpegData(compressionQuality: 0.78)
    }
}

/// cocoimg://img/?u=<percent-encoded https url>
/// 让 <img src> 直接走原生取图，避免把 base64 大字符串塞回 JS。
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "cocoimg"
    static let host = "img"

    static func makeURL(_ raw: String) -> String? {
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        guard let encoded = encoded else { return nil }
        return "\(scheme)://\(host)/?u=\(encoded)"
    }

    static func target(from url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              let target = URL(string: value),
              let s = target.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        return target
    }

    // 已取消 / 已结束的任务必须记账：
    // 对结束过的 WKURLSchemeTask 再调 didReceive，WebKit 会直接抛
    // "This task has already been stopped" 的 ObjC 异常（闪退）。
    private var closed = Set<Int>()
    private let lock = NSLock()

    private func key(of task: WKURLSchemeTask) -> Int {
        ObjectIdentifier(task as AnyObject).hashValue
    }

    private func take(_ task: WKURLSchemeTask) -> Bool {
        let k = key(of: task)
        lock.lock(); defer { lock.unlock() }
        if closed.contains(k) { return false }
        closed.insert(k)
        return true
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let target = Self.target(from: url) else {
            if take(urlSchemeTask) {
                urlSchemeTask.didFailWithError(NSError(domain: "cocoimg", code: 400))
            }
            return
        }

        ImageProxy.shared.loadData(target) { data in
            DispatchQueue.main.async {
                guard self.take(urlSchemeTask) else { return }
                guard let data = data else {
                    urlSchemeTask.didFailWithError(NSError(domain: "cocoimg", code: 404))
                    return
                }
                let headers: [String: String] = [
                    "Content-Type": "image/jpeg",
                    "Content-Length": String(data.count),
                    "Cache-Control": "max-age=86400",
                    "Access-Control-Allow-Origin": "*"
                ]
                guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                     httpVersion: "HTTP/1.1", headerFields: headers) else {
                    urlSchemeTask.didFailWithError(NSError(domain: "cocoimg", code: 500))
                    return
                }
                urlSchemeTask.didReceive(response)
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        _ = take(urlSchemeTask)   // 标记已结束，后续回调一律跳过
    }
}

/// 只对图片通道放行证书链（站点普遍只部署叶证书）
private final class PermissiveTLS: NSObject, URLSessionDelegate {

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
