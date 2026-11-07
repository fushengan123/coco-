import UIKit
import WebKit

/// 内嵌网页容器：会员中心 / 找回密码 / 官网等，对应安卓 WebActivity
final class WebPageViewController: UIViewController {

    private let url: URL
    private let pageTitle: String
    private let ink = UIColor(red: 0.07, green: 0.07, blue: 0.07, alpha: 1)
    private let gold = UIColor(red: 0.961, green: 0.773, blue: 0.094, alpha: 1)

    private var webView: WKWebView!
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var observations: [NSKeyValueObservation] = []

    init(url: URL, pageTitle: String) {
        self.url = url
        self.pageTitle = pageTitle
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink
        title = pageTitle
        buildBars()
        buildWebView()
        webView.load(URLRequest(url: url))
    }

    deinit { observations.forEach { $0.invalidate() } }

    private func buildBars() {
        navigationController?.navigationBar.barTintColor = UIColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        navigationController?.navigationBar.isTranslucent = false
        navigationController?.navigationBar.tintColor = gold
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: UIColor(white: 0.93, alpha: 1)]

        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "‹ 返回", style: .plain,
                                                           target: self, action: #selector(onBack))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain,
                                                            target: self, action: #selector(onClose))

        progress.trackTintColor = .clear
        progress.progressTintColor = gold
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)
    }

    private func buildWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Config.mobileUserAgent
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            progress.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: progress.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        observations.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = Float(view.estimatedProgress)
            DispatchQueue.main.async {
                self?.progress.setProgress(value, animated: true)
                self?.progress.isHidden = value >= 1.0
            }
        })
    }

    @objc private func onBack() {
        if webView.canGoBack { webView.goBack() } else { onClose() }
    }

    @objc private func onClose() {
        dismiss(animated: true, completion: nil)
    }
}

extension WebPageViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { }

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

extension WebPageViewController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { webView.load(URLRequest(url: url)) }
        return nil
    }
}
