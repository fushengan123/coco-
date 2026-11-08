import Foundation
import WebKit
import UniformTypeIdentifiers

/// cocoapp://local/... -> Bundle/web/...
/// 等价于安卓的 file:///android_asset/web/，但带真实 Origin，Ajax / 存储都正常。
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {

    private let root: URL
    private let queue = DispatchQueue(label: "coco.scheme", qos: .userInitiated, attributes: .concurrent)
    private var cancelled: Set<Int> = []
    private let lock = NSLock()

    init(root: URL) {
        self.root = root.standardizedFileURL
        super.init()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject).hashValue
        guard let url = urlSchemeTask.request.url else {
            fail(urlSchemeTask, key, code: 400)
            return
        }

        var relative = url.path
        if relative.isEmpty || relative == "/" { relative = "/" + Config.startPage }
        while relative.hasPrefix("/") { relative.removeFirst() }

        // 图片代理入口：cocoapp://local/__img/?u=<编码后的图片地址>
        // 走已经验证可用的 cocoapp scheme，避免自定义 scheme 在图片上的不确定性
        if relative.hasPrefix("__img") {
            guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let value = comps.queryItems?.first(where: { $0.name == "u" })?.value,
                  let pic = URL(string: value),
                  let ps = pic.scheme?.lowercased(), ps == "http" || ps == "https" else {
                fail(urlSchemeTask, key, code: 400)
                return
            }
            ImageResponder.serve(url: url, target: pic, task: urlSchemeTask)
            return
        }

        let target = root.appendingPathComponent(relative).standardizedFileURL
        guard target.path.hasPrefix(root.path) else {
            fail(urlSchemeTask, key, code: 403)
            return
        }

        queue.async { [weak self] in
            guard let self = self else { return }
            let data = try? Data(contentsOf: target)
            if self.isCancelled(key) { return }

            if let data = data {
                let mime = Self.mimeType(for: target.pathExtension)
                let headers: [String: String] = [
                    "Content-Type": mime,
                    "Content-Length": String(data.count),
                    "Cache-Control": "no-cache",
                    "Access-Control-Allow-Origin": "*"
                ]
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)
                DispatchQueue.main.async {
                    guard let response = response else { return }
                    // 派发到主线程的这段时间任务可能已被 stop，再回调会抛异常
                    if self.isCancelled(key) { return }
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                    self.release(key)
                }
            } else {
                self.fail(urlSchemeTask, key, code: 404)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask as AnyObject).hashValue
        lock.lock(); cancelled.insert(key); lock.unlock()
        // 图片代理走的是同一条 scheme，也要同步标记，否则会对着已停止的任务回调
        ImageResponder.markStopped(urlSchemeTask)
    }

    private func isCancelled(_ key: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled.contains(key)
    }

    private func release(_ key: Int) {
        lock.lock(); cancelled.remove(key); lock.unlock()
    }

    private func fail(_ task: WKURLSchemeTask, _ key: Int, code: Int) {
        DispatchQueue.main.async {
            if self.isCancelled(key) { return }
            if let url = task.request.url {
                let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1",
                                               headerFields: ["Content-Type": "text/plain; charset=utf-8"])
                if let response = response {
                    task.didReceive(response)
                    task.didReceive(Data("not found".utf8))
                    task.didFinish()
                }
            } else {
                task.didFailWithError(NSError(domain: "coco.scheme", code: code))
            }
            self.release(key)
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4": return "video/mp4"
        case "txt", "md": return "text/plain; charset=utf-8"
        default:
            return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
