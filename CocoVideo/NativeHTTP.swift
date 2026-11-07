import Foundation
import WebKit

/// 原生 HTTP 通道：等价于安卓 MainActivity 里的 OkHttp 分支。
/// 作用：绕开 H5 的跨域 / 混合内容限制，并带上 WebView 里已登录的 Cookie。
final class NativeHTTP: NSObject {

    static let shared = NativeHTTP()

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    func send(url: URL, form: String?, userAgent: String,
              completion: @escaping (_ body: String?, _ error: String?) -> Void) {

        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self = self else { return }

            var request = URLRequest(url: url)
            request.httpMethod = form == nil ? "GET" : "POST"
            let port = url.port.map { ":\($0)" } ?? ""
            let origin = "\(url.scheme ?? "https")://\(url.host ?? "")\(port)/"
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue(origin, forHTTPHeaderField: "Referer")
            request.setValue("application/json,text/javascript,*/*", forHTTPHeaderField: "Accept")
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")

            let matched = cookies.filter { Self.matches($0, url: url) }
            if !matched.isEmpty {
                let field = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                request.setValue(field, forHTTPHeaderField: "Cookie")
            }

            if let form = form {
                request.httpBody = form.data(using: .utf8)
                request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            }

            self.session.dataTask(with: request) { data, response, error in
                if let error = error {
                    completion(nil, error.localizedDescription.isEmpty ? "network error" : error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse, let data = data else {
                    completion(nil, "network error")
                    return
                }
                self.storeCookies(from: http, url: url)
                if http.statusCode >= 400 && data.isEmpty {
                    completion(nil, "HTTP \(http.statusCode)")
                    return
                }
                completion(Self.decode(data, response: http), nil)
            }.resume()
        }
    }

    // MARK: - cookie 同步

    private func storeCookies(from response: HTTPURLResponse, url: URL) {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie"), !raw.isEmpty else { return }
        let store = WKWebsiteDataStore.default().httpCookieStore
        for part in Self.splitSetCookie(raw) {
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": part], for: url)
            for cookie in parsed {
                store.setCookie(cookie, completionHandler: nil)
            }
        }
    }

    /// Set-Cookie 里 Expires 带逗号，简单按逗号切会切坏，用「逗号 + 看起来像新 cookie」来切
    static func splitSetCookie(_ raw: String) -> [String] {
        let pattern = ",\\s*(?=[A-Za-z0-9_\\-\\.]+=)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [raw] }
        let ns = raw as NSString
        var pieces: [String] = []
        var cursor = 0
        for match in regex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            pieces.append(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            cursor = match.range.location + match.range.length
        }
        pieces.append(ns.substring(from: cursor))
        return pieces.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func matches(_ cookie: HTTPCookie, url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if domain.isEmpty { return false }
        return host == domain || host.hasSuffix("." + domain)
    }

    private static func decode(_ data: Data, response: HTTPURLResponse) -> String {
        let charset = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if charset.contains("gbk") || charset.contains("gb2312") || charset.contains("gb18030") {
            let gbk = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            if let text = String(data: data, encoding: String.Encoding(rawValue: gbk)) { return text }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func origin(of url: URL) -> String {
        "\(url.scheme ?? "https")://\(url.host ?? "")"
    }
}

extension NativeHTTP: URLSessionDelegate {

    /// 宽松 HTTPS：站点证书链不全时也能取到数据（与安卓 TrustManager 等价）
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
