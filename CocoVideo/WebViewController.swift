import UIKit
import WebKit

/// 主界面：本地 H5 + 原生通道，对应安卓 MainActivity
final class WebViewController: UIViewController {

    private let gold = UIColor(red: 0.961, green: 0.773, blue: 0.094, alpha: 1)
    private let ink = UIColor(red: 0.059, green: 0.063, blue: 0.078, alpha: 1)

    private let bridge = NativeBridge()
    private var observations: [NSKeyValueObservation] = []
    private var splashDeadline: DispatchWorkItem?

    private lazy var webView: WKWebView = makeWebView()
    private let progress = UIProgressView(progressViewStyle: .bar)
    private let splash = UIView()
    private let failure = UIView()
    private let refresh = UIRefreshControl()

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink
        buildWebView()
        buildProgress()
        buildSplash()
        buildFailure()
        observe()
        loadHome()
    }

    deinit {
        observations.forEach { $0.invalidate() }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: NativeBridge.handlerName)
        splashDeadline?.cancel()
    }

    // MARK: - 构建

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.allowsPictureInPictureMediaPlayback = true
        config.dataDetectorTypes = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        config.setURLSchemeHandler(LocalSchemeHandler(root: Config.webRoot), forURLScheme: Config.scheme)
        // 图片走原生取图协议：<img src="cocoimg://img/?u=...">
        config.setURLSchemeHandler(ImageSchemeHandler(), forURLScheme: ImageSchemeHandler.scheme)

        let controller = config.userContentController
        bridge.host = self
        controller.add(bridge, name: NativeBridge.handlerName)
        controller.addUserScript(WKUserScript(source: Config.bridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: Config.shimScript,
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))

        let view = WKWebView(frame: .zero, configuration: config)
        view.customUserAgent = Config.mobileUserAgent
        view.allowsBackForwardNavigationGestures = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.keyboardDismissMode = .onDrag
        view.scrollView.showsVerticalScrollIndicator = false
        view.isOpaque = true
        view.backgroundColor = ink
        view.scrollView.backgroundColor = ink
        view.navigationDelegate = self
        view.uiDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        bridge.webView = view
        return view
    }

    private func buildWebView() {
        refresh.tintColor = gold
        refresh.addTarget(self, action: #selector(onRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func buildProgress() {
        progress.trackTintColor = .clear
        progress.progressTintColor = gold
        progress.progress = 0
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    private func buildSplash() {
        splash.backgroundColor = ink
        splash.translatesAutoresizingMaskIntoConstraints = false

        let mark = UILabel()
        mark.text = "▶"
        mark.textColor = ink
        mark.textAlignment = .center
        mark.font = UIFont.systemFont(ofSize: 26, weight: .black)
        mark.backgroundColor = gold
        mark.layer.cornerRadius = 14
        mark.layer.masksToBounds = true
        mark.translatesAutoresizingMaskIntoConstraints = false

        let name = UILabel()
        name.text = Config.brandName
        name.textColor = .white
        name.font = UIFont.systemFont(ofSize: 19, weight: .heavy)
        name.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.color = gold
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        splash.addSubview(mark)
        splash.addSubview(name)
        splash.addSubview(spinner)
        view.addSubview(splash)

        NSLayoutConstraint.activate([
            splash.topAnchor.constraint(equalTo: view.topAnchor),
            splash.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splash.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splash.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            mark.centerXAnchor.constraint(equalTo: splash.centerXAnchor, constant: -46),
            mark.centerYAnchor.constraint(equalTo: splash.centerYAnchor, constant: -40),
            mark.widthAnchor.constraint(equalToConstant: 40),
            mark.heightAnchor.constraint(equalToConstant: 40),

            name.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 10),
            name.centerYAnchor.constraint(equalTo: mark.centerYAnchor),

            spinner.topAnchor.constraint(equalTo: mark.bottomAnchor, constant: 26),
            spinner.centerXAnchor.constraint(equalTo: splash.centerXAnchor)
        ])
    }

    private func buildFailure() {
        failure.backgroundColor = ink
        failure.isHidden = true
        failure.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = "网络连接失败"
        label.textColor = UIColor(white: 0.75, alpha: 1)
        label.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        let retry = UIButton(type: .system)
        retry.setTitle("重新加载", for: .normal)
        retry.setTitleColor(ink, for: .normal)
        retry.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        retry.backgroundColor = gold
        retry.layer.cornerRadius = 8
        retry.contentEdgeInsets = UIEdgeInsets(top: 9, left: 22, bottom: 9, right: 22)
        retry.addTarget(self, action: #selector(onRetry), for: .touchUpInside)
        retry.translatesAutoresizingMaskIntoConstraints = false

        failure.addSubview(label)
        failure.addSubview(retry)
        view.addSubview(failure)

        NSLayoutConstraint.activate([
            failure.topAnchor.constraint(equalTo: view.topAnchor),
            failure.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            failure.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            failure.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            label.centerXAnchor.constraint(equalTo: failure.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: failure.centerYAnchor, constant: -22),

            retry.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 16),
            retry.centerXAnchor.constraint(equalTo: failure.centerXAnchor)
        ])
    }

    // MARK: - 加载

    private func loadHome() {
        webView.load(URLRequest(url: Config.homeURL))
        splashDeadline?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hideSplash() }
        splashDeadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: item)
    }

    @objc private func onRefresh() {
        failure.isHidden = true
        webView.reload()
    }

    @objc private func onRetry() {
        failure.isHidden = true
        webView.reload()
    }

    private func hideSplash() {
        guard !splash.isHidden else { return }
        splashDeadline?.cancel()
        UIView.animate(withDuration: 0.22, animations: { self.splash.alpha = 0 }) { _ in
            self.splash.isHidden = true
            self.splash.alpha = 1
        }
    }

    private func observe() {
        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = Float(view.estimatedProgress)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.progress.setProgress(value, animated: true)
                self.progress.isHidden = value >= 1.0
            }
        })
    }
}

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        progress.isHidden = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh.endRefreshing()
        failure.isHidden = true
        progress.isHidden = true
        hideSplash()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    private func handle(_ error: Error) {
        refresh.endRefreshing()
        progress.isHidden = true
        hideSplash()

        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }
        // 本地首页不会失败；子资源失败不弹错误页，避免误判（与安卓一致）
        if let url = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           url.hasPrefix(Config.scheme + "://") {
            return
        }
        if webView.url?.scheme == Config.scheme && (webView.url?.path ?? "").contains(Config.startPage) {
            return
        }
        failure.isHidden = false
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = (url.scheme ?? "").lowercased()
        switch scheme {
        case Config.scheme, "about", "data", "blob":
            decisionHandler(.allow)
        case "http", "https":
            // 安卓端 shouldOverrideUrlLoading 也是在同一个 WebView 里 loadUrl
            decisionHandler(.allow)
        case "tel", "mailto", "sms", "itms-apps", "itms-services":
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        default:
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView,
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

extension WebViewController: WKUIDelegate {

    /// window.open / target=_blank：同 WebView 里打开，不弹新窗口
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: Config.brandName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true, completion: nil)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: Config.brandName, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true, completion: nil)
    }
}
