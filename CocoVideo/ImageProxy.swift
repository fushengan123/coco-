import Foundation

/// 图片代理：H5 里 <img> 直接加载失败时（证书链不全 / 防盗链 / UA 判定），
/// 由原生取字节再转成 data URI 回传给页面。
/// 这些图片站经常只部署了叶证书，WebKit 校验不过就直接空白，原生这边可以放行。
final class ImageProxy {

    static let shared = ImageProxy()

    private let cache = NSCache<NSURL, NSString>()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg, delegate: PermissiveTLS(), delegateQueue: nil)
    }()

    private init() {
        cache.countLimit = 150
    }

    func load(_ url: URL, completion: @escaping (String?) -> Void) {
        if let hit = cache.object(forKey: url as NSURL) {
            completion(hit as String)
            return
        }

        var request = URLRequest(url: url)
        request.setValue(Config.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("\(url.scheme ?? "https")://\(url.host ?? "")/", forHTTPHeaderField: "Referer")
        request.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self,
                  error == nil,
                  let data = data,
                  !data.isEmpty,
                  data.count <= 4_000_000 else {
                completion(nil)
                return
            }
            let mime = Self.mimeType(response: response, data: data)
            let uri = "data:\(mime);base64,\(data.base64EncodedString())"
            self.cache.setObject(uri as NSString, forKey: url as NSURL)
            completion(uri)
        }.resume()
    }

    private static func mimeType(response: URLResponse?, data: Data) -> String {
        if let type = response?.mimeType, type.hasPrefix("image/") { return type }
        let bytes = [UInt8](data.prefix(8))
        if bytes.count > 2, bytes[0] == 0xFF, bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes.count > 4, bytes[0] == 0x89, bytes[1] == 0x50 { return "image/png" }
        if bytes.count > 4, bytes[0] == 0x52, bytes[1] == 0x49 { return "image/webp" }
        return "image/jpeg"
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
