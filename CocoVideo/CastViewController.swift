import UIKit
import AVKit
import AVFoundation

/// 电视投屏（iOS 等价实现）：AVPlayer + AirPlay 路由选择
/// 安卓端走乐播 SDK（含私有协议，仅安卓），iOS 走系统 AirPlay / 屏幕镜像。
final class CastViewController: UIViewController {

    private let mediaURL: URL
    private let castTitle: String
    private let ink = UIColor(red: 0.059, green: 0.063, blue: 0.078, alpha: 1)
    private let gold = UIColor(red: 0.961, green: 0.773, blue: 0.094, alpha: 1)

    private let playerVC = AVPlayerViewController()
    private var player: AVPlayer?
    private let routePicker = AVRoutePickerView()
    private let statusLabel = UILabel()

    init(mediaURL: URL, title: String, poster: URL?) {
        self.mediaURL = mediaURL
        self.castTitle = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink
        buildTopBar()
        buildPlayer()
        buildFooter()
        startPlayback()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        player?.pause()
    }

    private func buildTopBar() {
        let title = UILabel()
        title.text = castTitle.isEmpty ? "电视投屏" : castTitle
        title.textColor = UIColor(white: 0.95, alpha: 1)
        title.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.setTitleColor(gold, for: .normal)
        close.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        close.addTarget(self, action: #selector(onClose), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false

        routePicker.tintColor = gold
        routePicker.activeTintColor = gold
        routePicker.prioritizesVideoDevices = true
        routePicker.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(title)
        view.addSubview(close)
        view.addSubview(routePicker)

        NSLayoutConstraint.activate([
            routePicker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            routePicker.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            routePicker.widthAnchor.constraint(equalToConstant: 32),
            routePicker.heightAnchor.constraint(equalToConstant: 32),

            close.centerYAnchor.constraint(equalTo: routePicker.centerYAnchor),
            close.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14),

            title.centerYAnchor.constraint(equalTo: routePicker.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: routePicker.leadingAnchor, constant: -12)
        ])
    }

    private func buildPlayer() {
        addChild(playerVC)
        playerVC.view.backgroundColor = .black
        playerVC.view.translatesAutoresizingMaskIntoConstraints = false
        playerVC.showsPlaybackControls = true
        playerVC.allowsPictureInPicturePlayback = true
        playerVC.updatesNowPlayingInfoCenter = true
        view.addSubview(playerVC.view)
        playerVC.didMove(toParent: self)

        NSLayoutConstraint.activate([
            playerVC.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
            playerVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            playerVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            playerVC.view.heightAnchor.constraint(equalTo: playerVC.view.widthAnchor, multiplier: 9.0 / 16.0)
        ])
    }

    private func buildFooter() {
        statusLabel.text = "点右上角投屏图标选择 Apple TV / 支持 AirPlay 的电视；\n没有设备时，用控制中心的「屏幕镜像」把整块屏幕投到电视。"
        statusLabel.textColor = UIColor(white: 0.62, alpha: 1)
        statusLabel.font = UIFont.systemFont(ofSize: 13)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: playerVC.view.bottomAnchor, constant: 18),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        ])
    }

    private func startPlayback() {
        let headers: [String: String] = [
            "User-Agent": Config.mobileUserAgent,
            "Referer": "\(mediaURL.scheme ?? "https")://\(mediaURL.host ?? "")/"
        ]
        let asset = AVURLAsset(url: mediaURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { }

        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        playerVC.player = player
        self.player = player
        player.play()

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(onFailed(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime,
                                               object: item)
    }

    @objc private func onFailed(_ note: Notification) {
        statusLabel.textColor = UIColor(red: 0.95, green: 0.42, blue: 0.36, alpha: 1)
        statusLabel.text = "这个源在 iOS 上无法直接播放（多为私有加密或非标准 m3u8）。\n换一条线路再试，或用「屏幕镜像」直接投屏。"
    }

    @objc private func onClose() {
        dismiss(animated: true) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
