import UIKit
import WebKit

/// H5 <-> 原生 的桥，方法名与安卓 WebBridge 完全一致：
/// request / post / cast / share / copy / openWeb
final class NativeBridge: NSObject, WKScriptMessageHandler {

    static let handlerName = "coco"

    weak var webView: WKWebView?
    weak var host: UIViewController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let method = body["m"] as? String else { return }

        switch method {
        case "request": handleRequest(body, form: nil)
        case "post":    handleRequest(body, form: (body["data"] as? String) ?? "")
        case "cast":    handleCast(body)
        case "img":     handleImage(body)
        case "share":   handleShare(body)
        case "copy":    handleCopy(body)
        case "openWeb": handleOpenWeb(body)
        default:        break
        }
    }

    // MARK: - 网络

    private func handleRequest(_ body: [String: Any], form: String?) {
        guard let raw = body["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let cb = (body["cb"] as? String) ?? ""
        NativeHTTP.shared.send(url: url, form: form, userAgent: Config.mobileUserAgent) { [weak self] text, err in
            let js = JSUtil.resp(cb: cb, body: text, err: err)
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - 图片代理

    private func handleImage(_ body: [String: Any]) {
        guard let raw = body["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        let cb = (body["cb"] as? String) ?? ""
        ImageProxy.shared.load(url) { [weak self] uri in
            let payload = uri.map(JSUtil.quote) ?? "null"
            let js = "window.Coco&&Coco._nativeImg(\(JSUtil.quote(cb)),\(payload));"
            DispatchQueue.main.async {
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
    }

    // MARK: - 投屏

    private func handleCast(_ body: [String: Any]) {
        let raw = (body["url"] as? String) ?? ""
        let title = (body["title"] as? String) ?? ""
        guard !raw.isEmpty, let url = URL(string: raw) else {
            toast("未获取到播放地址")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.host else { return }
            let vc = CastPanelViewController(mediaURL: url, title: title)
            // 结果回传 H5：成功保留遮罩，失败让页面恢复本地播放
            vc.onResult = { [weak self] ok, message in
                let js = "window.__cocoCastResult&&window.__cocoCastResult(\(ok ? "true" : "false"),\(JSUtil.quote(message)));"
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
            host.present(vc, animated: true, completion: nil)
        }
    }

    // MARK: - 分享

    private func handleShare(_ body: [String: Any]) {
        let title = (body["title"] as? String) ?? Config.brandName
        let raw = (body["url"] as? String) ?? Config.site
        let text = title + "\n" + "快来一起看：" + raw

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.host else { return }
            let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
            sheet.popoverPresentationController?.sourceView = host.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: host.view.bounds.midX,
                                                                     y: host.view.bounds.maxY - 60,
                                                                     width: 1, height: 1)
            host.present(sheet, animated: true, completion: nil)
        }
    }

    // MARK: - 复制

    private func handleCopy(_ body: [String: Any]) {
        let text = (body["text"] as? String) ?? ""
        UIPasteboard.general.string = text
        toast("已复制")
    }

    // MARK: - 内嵌网页（会员中心 / 找回密码）

    private func handleOpenWeb(_ body: [String: Any]) {
        guard let raw = body["url"] as? String,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, let host = self.host else { return }
            let page = WebPageViewController(url: url, pageTitle: "会员中心")
            let nav = UINavigationController(rootViewController: page)
            nav.modalPresentationStyle = .fullScreen
            host.present(nav, animated: true, completion: nil)
        }
    }

    // MARK: - 小工具

    private func toast(_ text: String) {
        let js = "if(window.Coco&&Coco.toast){Coco.toast(\(JSUtil.quote(text)));}"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
