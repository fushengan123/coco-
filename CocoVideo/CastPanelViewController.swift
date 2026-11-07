import UIKit

/// 投屏面板：列出局域网里能接 DLNA 的电视，选中即推流。
/// 底部保留 AirPlay / 本机播放入口（苹果电视、HomePod 走这条路）。
final class CastPanelViewController: UIViewController {

    private let mediaURL: URL
    private let castTitle: String

    /// 结果回调：成功/失败回传给 H5，H5 据此收起或保留"正在投屏"遮罩
    var onResult: ((Bool, String) -> Void)?

    private let ink = UIColor(red: 0.059, green: 0.063, blue: 0.078, alpha: 1)
    private let card = UIColor(red: 0.106, green: 0.114, blue: 0.141, alpha: 1)
    private let gold = UIColor(red: 0.961, green: 0.773, blue: 0.094, alpha: 1)

    private var devices: [DLNADevice] = []
    private let table = UITableView(frame: .zero, style: .plain)
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(mediaURL: URL, title: String) {
        self.mediaURL = mediaURL
        self.castTitle = title
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ink
        buildUI()
        startScan()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DLNAService.shared.stop()
    }

    // MARK: - UI

    private func buildUI() {
        let title = UILabel()
        title.text = "电视投屏"
        title.textColor = .white
        title.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let close = UIButton(type: .system)
        close.setTitle("关闭", for: .normal)
        close.setTitleColor(gold, for: .normal)
        close.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        close.addTarget(self, action: #selector(onClose), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false

        let sub = UILabel()
        sub.text = castTitle
        sub.textColor = UIColor(white: 0.55, alpha: 1)
        sub.font = UIFont.systemFont(ofSize: 12)
        sub.lineBreakMode = .byTruncatingMiddle
        sub.translatesAutoresizingMaskIntoConstraints = false

        status.text = "正在搜索附近的电视…"
        status.textColor = UIColor(white: 0.62, alpha: 1)
        status.font = UIFont.systemFont(ofSize: 12)
        status.translatesAutoresizingMaskIntoConstraints = false

        spinner.color = gold
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        table.backgroundColor = .clear
        table.separatorColor = UIColor(white: 1, alpha: 0.06)
        table.dataSource = self
        table.delegate = self
        table.register(CastDeviceCell.self, forCellReuseIdentifier: "cell")
        table.translatesAutoresizingMaskIntoConstraints = false
        table.tableFooterView = UIView()

        let airplay = UIButton(type: .system)
        airplay.setTitle("用 AirPlay / 本机播放", for: .normal)
        airplay.setTitleColor(ink, for: .normal)
        airplay.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .bold)
        airplay.backgroundColor = gold
        airplay.layer.cornerRadius = 10
        airplay.addTarget(self, action: #selector(onAirPlay), for: .touchUpInside)
        airplay.translatesAutoresizingMaskIntoConstraints = false

        [title, sub, close, spinner, status, table, airplay].forEach { view.addSubview($0) }

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            close.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            spinner.topAnchor.constraint(equalTo: sub.bottomAnchor, constant: 14),
            spinner.leadingAnchor.constraint(equalTo: title.leadingAnchor),

            status.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            table.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 10),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: airplay.topAnchor, constant: -12),

            airplay.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            airplay.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            airplay.heightAnchor.constraint(equalToConstant: 46),
            airplay.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -14)
        ])
    }

    // MARK: - 扫描 / 投屏

    private func startScan() {
        devices.removeAll()
        table.reloadData()
        status.text = "正在搜索附近的电视…"
        spinner.startAnimating()

        DLNAService.shared.start { [weak self] device in
            guard let self = self else { return }
            if self.devices.contains(where: { $0.key == device.key }) { return }
            self.devices.append(device)
            self.table.reloadData()
            self.status.text = "找到 \(self.devices.count) 台设备，点一下就能投"
            self.spinner.stopAnimating()
        }
    }

    private func cast(to device: DLNADevice) {
        status.text = "正在连接 \(device.name)…"
        spinner.startAnimating()
        DLNAService.shared.play(device, media: mediaURL, title: castTitle) { [weak self] ok, message in
            guard let self = self else { return }
            self.spinner.stopAnimating()
            self.status.text = message
            self.status.textColor = ok ? self.gold : UIColor(red: 0.95, green: 0.42, blue: 0.36, alpha: 1)
            self.onResult?(ok, message)
            if ok {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.dismiss(animated: true) }
            } else {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    @objc private func onAirPlay() {
        let vc = CastViewController(mediaURL: mediaURL, title: castTitle, poster: nil)
        vc.modalPresentationStyle = .fullScreen
        onResult?(true, "已切到 AirPlay 播放页")
        dismiss(animated: true) {
            self.presentingViewController?.present(vc, animated: true, completion: nil)
        }
    }

    @objc private func onClose() {
        // 没投成功就关掉面板：告诉 H5 收回遮罩，别一直卡在"正在搜索电视"
        onResult?(false, "已取消投屏")
        dismiss(animated: true, completion: nil)
    }
}

extension CastPanelViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        devices.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath) as! CastDeviceCell
        cell.configure(name: devices[indexPath.row].name, tint: gold)
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        cast(to: devices[indexPath.row])
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat { 58 }
}

private final class CastDeviceCell: UITableViewCell {

    private let label = UILabel()
    private let icon = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .default
        let bg = UIView()
        bg.backgroundColor = UIColor(red: 0.106, green: 0.114, blue: 0.141, alpha: 1)
        selectedBackgroundView = bg

        icon.text = "📺"
        icon.font = UIFont.systemFont(ofSize: 18)
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.textColor = UIColor(white: 0.92, alpha: 1)
        label.font = UIFont.systemFont(ofSize: 15, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(icon)
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(name: String, tint: UIColor) {
        label.text = name
        icon.tintColor = tint
    }
}
