import Foundation
import UIKit
import WebKit
import ObjectiveC

/// 图片代理：图片站普遍只部署叶证书、开了防盗链，WebKit 校验不过就直接裂图。
/// 原生这边放行证书链取字节，顺手压到 480px，再按原格式（或 jpeg）交回去。
///
/// 出口：
///  - `loadData`  → 给 cocoapp://local/__img/ 用（主路径，走已验证的 scheme）
///  - `load`      → 桥接兜底，base64 data URI
final class ImageProxy {

    static let shared = ImageProxy()

    /// 带 mime 的载荷
    final class Payload: NSObject {
        let data: Data
        let mime: String
        init(data: Data, mime: String) {
            self.data = data
            self.mime = mime
        }
    }

    private let cache = NSCache<NSURL, Payload>()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.urlCache = nil
        return URLSession(configuration: cfg, delegate: PermissiveTLS(), delegateQueue: nil)
    }()

    private init() {
        cache.countLimit = 200
    }

    // MARK: - 取字节（主路径）

    func loadData(_ url: URL, completion: @escaping (Data?, String) -> Void) {
        if let hit = cache.object(forKey: url as NSURL) {
            completion(hit.data, hit.mime)
            return
        }
        fetch(url) { [weak self] data, mime in
            guard let self = self, let data = data else {
                completion(nil, "image/jpeg")
                return
            }
            // 能解码就压到 480px 转 jpeg；解不了（webp/异常）就原样交回，mime 用原始的
            if let small = Self.downscale(data) {
                self.cache.setObject(Payload(data: small, mime: "image/jpeg"), forKey: url as NSURL)
                completion(small, "image/jpeg")
            } else {
                self.cache.setObject(Payload(data: data, mime: mime), forKey: url as NSURL)
                completion(data, mime)
            }
        }
    }

    // MARK: - 兼容路径：base64 data URI

    func load(_ url: URL, completion: @escaping (String?) -> Void) {
        loadData(url) { data, mime in
            guard let data = data else {
                completion(nil)
                return
            }
            completion("data:\(mime);base64," + data.base64EncodedString())
        }
    }

    // MARK: - 网络

    private func fetch(_ url: URL, completion: @escaping (Data?, String) -> Void) {
        var request = URLRequest(url: url)
        request.setValue(Config.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Config.site + "/", forHTTPHeaderField: "Referer")
        request.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { data, response, error in
            // 状态码必须 2xx：很多站会拿 200 的 HTML 错误页糊弄，那是解不成图的
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let data = data,
                  !data.isEmpty,
                  data.count <= 8_000_000,
                  Self.looksLikeImage(data) else {
                completion(nil, "image/jpeg")
                return
            }
            completion(data, Self.mimeType(response: response, data: data))
        }.resume()
    }

    /// 只接受真图片，避免把 HTML/JSON 错误页当图片喂给 WebKit（会显示成破图/问号）
    static func looksLikeImage(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(12))
        if b.count < 4 { return false }
        if b[0] == 0xFF, b[1] == 0xD8 { return true }                       // jpeg
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return true } // png
        if b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 { return true }        // gif
        if b.count >= 12, b[0] == 0x52, b[1] == 0x49, b[8] == 0x57 { return true } // webp
        if b[0] == 0x42, b[1] == 0x4D { return true }                      // bmp
        if b.count >= 12, b[4] == 0x66, b[5] == 0x74, b[6] == 0x79, b[7] == 0x70 { return true } // heic
        return false
    }

    static func mimeType(response: URLResponse?, data: Data) -> String {
        if let type = response?.mimeType, type.hasPrefix("image/") { return type }
        let bytes = [UInt8](data.prefix(12))
        if bytes.count > 2, bytes[0] == 0xFF, bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes.count > 4, bytes[0] == 0x89, bytes[1] == 0x50 { return "image/png" }
        if bytes.count > 4, bytes[0] == 0x47, bytes[1] == 0x49 { return "image/gif" }
        if bytes.count > 12, bytes[0] == 0x52, bytes[1] == 0x49, bytes[8] == 0x57 { return "image/webp" }
        return "image/jpeg"
    }

    /// 压到 480px 宽的 JPEG；解不了就返回 nil
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

/// 统一的图片响应：给某个 WKURLSchemeTask 回字节
enum ImageResponder {

    /// 结束标记直接挂在任务对象上（而不是按指针哈希存全局表）：
    /// 对象释放后标记自然消失，不会出现哈希被复用、新任务被误判成已结束的情况
    private static var closedKey: UInt8 = 0
    private static let lock = NSLock()

    static func take(_ task: WKURLSchemeTask) -> Bool {
        let object = task as AnyObject
        lock.lock(); defer { lock.unlock() }
        if objc_getAssociatedObject(object, &closedKey) != nil { return false }
        objc_setAssociatedObject(object, &closedKey, NSNumber(value: true), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return true
    }

    static func markStopped(_ task: WKURLSchemeTask) {
        _ = take(task)
    }

    static func serve(url: URL, target: URL, task: WKURLSchemeTask) {
        ImageProxy.shared.loadData(target) { data, mime in
            DispatchQueue.main.async {
                guard take(task) else { return }
                guard let data = data else {
                    task.didFailWithError(NSError(domain: "cocoimg", code: 404))
                    return
                }
                let headers: [String: String] = [
                    "Content-Type": mime,
                    "Content-Length": String(data.count),
                    "Cache-Control": "max-age=86400",
                    "Access-Control-Allow-Origin": "*"
                ]
                guard let response = HTTPURLResponse(url: url, statusCode: 200,
                                                     httpVersion: "HTTP/1.1", headerFields: headers) else {
                    task.didFailWithError(NSError(domain: "cocoimg", code: 500))
                    return
                }
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            }
        }
    }
}

/// cocoimg://img/?u=<percent-encoded https url>（备用入口）
final class ImageSchemeHandler: NSObject, WKURLSchemeHandler {

    static let scheme = "cocoimg"
    static let host = "img"

    private static func target(from url: URL) -> URL? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "u" })?.value,
              let target = URL(string: value),
              let s = target.scheme?.lowercased(), s == "http" || s == "https" else { return nil }
        return target
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let target = Self.target(from: url) else {
            if ImageResponder.take(urlSchemeTask) {
                urlSchemeTask.didFailWithError(NSError(domain: "cocoimg", code: 400))
            }
            return
        }
        ImageResponder.serve(url: url, target: target, task: urlSchemeTask)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        ImageResponder.markStopped(urlSchemeTask)
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
