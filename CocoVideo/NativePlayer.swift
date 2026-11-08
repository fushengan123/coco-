import UIKit
import AVKit
import AVFoundation
import WebKit

/// 原生播放器：把 AVPlayerViewController 嵌在 H5 的播放器区域上方。
/// 控制条、拖动、AirPlay、画中画、全屏全部用系统原生的那套，
/// H5 只负责选集、进度记忆、片头片尾跳过逻辑。
final class NativePlayer: NSObject {

    private weak var parent: UIViewController?
    private weak var webView: WKWebView?

    private let playerVC = AVPlayerViewController()
    private var player: AVPlayer?
    private var container: UIView?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failedObserver: NSObjectProtocol?

    /// 左上角返回键（44pt，压在播放器之上）
    private let backButton = UIButton(type: .system)

    /// H5 传来的原始布局（CSS 像素），转屏后按新的视口重新换算
    private var cssRect: CGRect = .zero
    private var cssWidth: CGFloat = 375

    init(parent: UIViewController, webView: WKWebView) {
        self.parent = parent
        self.webView = webView
        playerVC.showsPlaybackControls = true
        playerVC.videoGravity = .resizeAspect
        playerVC.updatesNowPlayingInfoCenter = false
        super.init()
    }

    // MARK: - 开关

    func open(url: URL, cssRect: CGRect, cssWidth: CGFloat, title: String) {
        guard let parent = parent, let host = parent.view else { return }
        self.cssRect = cssRect
        self.cssWidth = max(cssWidth, 1)

        if container == nil {
            let box = UIView(frame: layoutFrame(in: host))
            box.backgroundColor = .black
            box.clipsToBounds = true
            host.addSubview(box)
            container = box

            parent.addChild(playerVC)
            playerVC.view.frame = box.bounds
            playerVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            box.addSubview(playerVC.view)
            playerVC.didMove(toParent: parent)

            backButton.frame = CGRect(x: 8, y: 8, width: 44, height: 44)
            backButton.setTitle("‹", for: .normal)
            backButton.setTitleColor(.white, for: .normal)
            backButton.titleLabel?.font = UIFont.systemFont(ofSize: 30, weight: .medium)
            backButton.backgroundColor = UIColor(white: 0, alpha: 0.4)
            backButton.layer.cornerRadius = 22
            backButton.addTarget(self, action: #selector(onBack), for: .touchUpInside)
            box.addSubview(backButton)
        } else {
            container?.frame = layoutFrame(in: host)
            playerVC.view.frame = container?.bounds ?? .zero
        }

        attach(url: url)
    }

    func close() {
        detachObservers()
        player?.pause()
        playerVC.player = nil
        player = nil

        if playerVC.parent != nil {
            playerVC.willMove(toParent: nil)
            playerVC.view.removeFromSuperview()
            playerVC.removeFromParent()
        }
        backButton.removeFromSuperview()
        container?.removeFromSuperview()
        container = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - 控制

    func play() { player?.play() }
    func pause() { player?.pause() }

    func seek(to seconds: Double) {
        guard let player = player else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 转屏 / 页面滚动后重新对齐
    func relayout(cssRect: CGRect, cssWidth: CGFloat) {
        self.cssRect = cssRect
        self.cssWidth = max(cssWidth, 1)
        guard let host = parent?.view, let box = container else { return }
        UIView.animate(withDuration: 0.15) {
            box.frame = self.layoutFrame(in: host)
            self.playerVC.view.frame = box.bounds
        }
    }

    // MARK: - 内部

    private func attach(url: URL) {
        detachObservers()

        let asset = AVURLAsset(url: url, options: [
            "AVURLAssetHTTPHeaderFieldsKey": [
                "User-Agent": Config.mobileUserAgent,
                "Referer": "\(url.scheme ?? "https")://\(url.host ?? "")/"
            ]
        ])
        let item = AVPlayerItem(asset: asset)

        let player: AVPlayer
        if let existing = self.player {
            existing.replaceCurrentItem(with: item)
            player = existing
        } else {
            player = AVPlayer(playerItem: item)
            player.allowsExternalPlayback = true
            player.usesExternalPlaybackWhileExternalScreenIsActive = true
            self.player = player
            playerVC.player = player
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        observe(player: player, item: item)
        player.play()
        send("window.__cocoPlayerState&&window.__cocoPlayerState('playing');")
    }

    private func detachObservers() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        if let token = endObserver { NotificationCenter.default.removeObserver(token) }
        if let token = failedObserver { NotificationCenter.default.removeObserver(token) }
        endObserver = nil
        failedObserver = nil
    }

    private func layoutFrame(in host: UIView) -> CGRect {
        let scale = host.bounds.width / cssWidth
        return CGRect(x: cssRect.origin.x * scale,
                      y: cssRect.origin.y * scale,
                      width: cssRect.width * scale,
                      height: cssRect.height * scale)
    }

    private func observe(player: AVPlayer, item: AVPlayerItem) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let t = CMTimeGetSeconds(time)
            let d = CMTimeGetSeconds(item.duration)
            let dur = d.isFinite ? d : 0
            self?.send("window.__cocoPlayerTime&&window.__cocoPlayerTime(\(t.isFinite ? t : 0),\(dur));")
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.send("window.__cocoPlayerEnded&&window.__cocoPlayerEnded();")
        }

        failedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            self?.send("window.__cocoPlayerError&&window.__cocoPlayerError(\(JSUtil.quote(err ?? "无法播放该片源")));")
        }
    }

    @objc private func onBack() {
        send("window.__cocoPlayerBack&&window.__cocoPlayerBack();")
    }

    private func send(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}
