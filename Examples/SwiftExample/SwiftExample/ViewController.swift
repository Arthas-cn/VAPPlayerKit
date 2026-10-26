import SwiftUI
import UIKit
import VAPPlayerKit

/// 自动扫描 Bundle/VAP 的资源浏览器。每个文件对应一行，点击进入完整播放器实验室。
final class ViewController: UIViewController {
    /// 展示筛选后的样本列表，行定位规则沿用现有 UI 测试。
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    /// 只按本地文件名筛选，不改变底层目录顺序。
    private let searchController = UISearchController(searchResultsController: nil)
    /// Bundle 扫描得到的全部样本。
    private var fixtures: [VAPFixture] = []
    /// 当前搜索条件下实际呈现的样本。
    private var filteredFixtures: [VAPFixture] = []

    /// 配置列表、搜索入口并扫描本地样本。
    override func viewDidLoad() {
        super.viewDidLoad()
        configureAppearance()
        configureTableView()
        configureSearch()
        reloadFixtures()
    }

    /// 返回列表时恢复当前可见行的轻量预览。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        tableView.visibleCells.compactMap { $0 as? FixtureCell }.forEach { $0.startPreview() }
    }

    /// 离开列表立即停止可见预览，避免与详情播放争抢资源。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        tableView.visibleCells.compactMap { $0 as? FixtureCell }.forEach { $0.stopPreview() }
    }

    /// 保留重扫和批量测试入口，增加独立 SwiftUI 演示入口。
    private func configureAppearance() {
        title = "VAP Gallery"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = UIColor(red: 0.47, green: 0.84, blue: 1, alpha: 1)
        view.backgroundColor = UIColor(red: 0.035, green: 0.045, blue: 0.075, alpha: 1)
        let reload = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            style: .plain,
            target: self,
            action: #selector(reloadFixtures)
        )
        reload.accessibilityIdentifier = "catalog.reload"
        let batch = UIBarButtonItem(
            image: UIImage(systemName: "checkmark.seal"),
            style: .plain,
            target: self,
            action: #selector(runBatchTest)
        )
        batch.accessibilityIdentifier = "catalog.batchTest"
        navigationItem.rightBarButtonItems = [reload, batch]
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "SwiftUI", style: .plain, target: self, action: #selector(showSwiftUIPlayer)
        )
    }

    /// 安装列表与约束，保留既有测试标识。
    private func configureTableView() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.rowHeight = 118
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(FixtureCell.self, forCellReuseIdentifier: FixtureCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "catalog.list"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    /// 将搜索输入连接到本地文件名过滤。
    private func configureSearch() {
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "搜索文件 Hash"
        searchController.searchResultsUpdater = self
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    /// 重新读取 Bundle，保持当前查询条件。
    @objc private func reloadFixtures() {
        fixtures = FixtureCatalog.scan()
        tableView.accessibilityValue = fixtures.map(\.identifier).joined(separator: ",")
        applyFilter(searchController.searchBar.text)
    }

    /// 用完整目录开启既有逐项设备验证页。
    @objc private func runBatchTest() {
        navigationController?.pushViewController(BatchTestViewController(fixtures: fixtures), animated: true)
    }

    /// 打开独立 SwiftUI 展示页；只从当前真实样本目录查找已知透明布局素材。
    @objc private func showSwiftUIPlayer() {
        let fixture = fixtures.first { $0.identifier == "alpha_left_moive" }
        let controller = UIHostingController(rootView: SwiftUIPlaybackShowcase(fixture: fixture))
        navigationController?.pushViewController(controller, animated: true)
    }

    /// 空查询显示全部样本，否则按文件名进行大小写无关匹配。
    private func applyFilter(_ query: String?) {
        let query = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filteredFixtures = query.isEmpty
            ? fixtures
            : fixtures.filter { $0.fileName.localizedCaseInsensitiveContains(query) }
        tableView.reloadData()
        updateBackground()
    }

    /// 没有结果时区分资源缺失与搜索无匹配。
    private func updateBackground() {
        // 有样本时移除占位，避免遮住可交互列表。
        guard filteredFixtures.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        let label = UILabel()
        label.text = fixtures.isEmpty
            ? "未在 App Bundle/VAP 中发现 MP4\n请检查 Copy Bundle Resources"
            : "没有匹配的资源"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.accessibilityIdentifier = "catalog.empty"
        tableView.backgroundView = label
    }
}

/// 列表数据与可见行生命周期；进入详情时仍传递原始样本。
extension ViewController: UITableViewDataSource, UITableViewDelegate {
    /// 返回当前筛选结果数量。
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        filteredFixtures.count
    }

    /// 同时展示总样本数和筛选后的数量。
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "已扫描 \(fixtures.count) 个资源 · 当前显示 \(filteredFixtures.count) 个"
    }

    /// 为行绑定样本，保留它在完整目录中的稳定序号。
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FixtureCell.reuseIdentifier, for: indexPath)
        // 注册类型异常时返回 UIKit 的原始单元格，避免强制转换崩溃。
        guard let cell = cell as? FixtureCell else { return cell }
        let fixture = filteredFixtures[indexPath.row]
        cell.configure(with: fixture, index: fixtures.firstIndex(of: fixture) ?? indexPath.row)
        return cell
    }

    /// 打开选中素材的完整播放实验室。
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(
            PlaybackDetailViewController(fixture: filteredFixtures[indexPath.row]),
            animated: true
        )
    }

    /// 仅在行即将可见时启动预览。
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? FixtureCell)?.startPreview()
    }

    /// 行移出屏幕后停止其播放。
    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? FixtureCell)?.stopPreview()
    }
}

/// 将 UIKit 搜索框的变化转换成本地筛选。
extension ViewController: UISearchResultsUpdating {
    /// 搜索文本变化时刷新列表与空态。
    func updateSearchResults(for searchController: UISearchController) {
        applyFilter(searchController.searchBar.text)
    }
}

/// 本地素材预览行，负责可见期间播放及动态素材供应。
private final class FixtureCell: UITableViewCell, PlayerDelegate, DynamicContentProvider {
    /// 注册与复用使用同一个标识。
    static let reuseIdentifier = "FixtureCell"

    /// 统一承载预览和样本描述的卡片容器。
    private let card = UIView()
    /// 当前样本的静音循环播放器。
    private let previewView = PlayerView()
    /// 样本在完整目录中的序号。
    private let indexLabel = UILabel()
    /// 样本类型或调用者传入的名称。
    private let titleLabel = UILabel()
    /// 文件摘要或调用者提供的副标题。
    private let subtitleLabel = UILabel()
    /// 带内边距的文件体积标签。
    private let sizeLabel = PaddingLabel()
    /// 表示可进入详情页的箭头。
    private let stateImage = UIImageView()
    /// 当前绑定样本；复用期间为 nil。
    private var fixture: VAPFixture?
    /// 防止重复可见回调重复发起播放。
    private var isPreviewActive = false
    /// 动态替换内容使用的图片类型范围。
    private var imagePolicy: GiftCatalog.ImagePolicy = .mixed

    /// 创建卡片、预览播放器与样本标签。
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.translatesAutoresizingMaskIntoConstraints = false
        card.backgroundColor = UIColor(red: 0.075, green: 0.09, blue: 0.14, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        contentView.addSubview(card)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.backgroundColor = UIColor(white: 0.025, alpha: 0.8)
        previewView.layer.cornerRadius = 14
        previewView.clipsToBounds = true
        previewView.isUserInteractionEnabled = false
        previewView.isAccessibilityElement = true
        previewView.delegate = self
        previewView.dynamicContentProvider = self
        card.addSubview(previewView)

        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        indexLabel.textColor = UIColor(red: 0.42, green: 0.82, blue: 1, alpha: 1)
        indexLabel.textAlignment = .center
        indexLabel.backgroundColor = UIColor(red: 0.11, green: 0.22, blue: 0.31, alpha: 1)
        indexLabel.layer.cornerRadius = 7
        indexLabel.clipsToBounds = true

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = UIColor(white: 0.62, alpha: 1)
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        sizeLabel.textColor = UIColor(red: 0.54, green: 0.9, blue: 0.75, alpha: 1)
        sizeLabel.backgroundColor = UIColor(red: 0.08, green: 0.22, blue: 0.17, alpha: 1)
        sizeLabel.layer.cornerRadius = 8
        sizeLabel.clipsToBounds = true

        stateImage.image = UIImage(systemName: "chevron.right")
        stateImage.tintColor = UIColor(white: 0.45, alpha: 1)

        [indexLabel, titleLabel, subtitleLabel, sizeLabel, stateImage].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            previewView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            previewView.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            previewView.widthAnchor.constraint(equalToConstant: 92),
            previewView.heightAnchor.constraint(equalToConstant: 92),
            indexLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor, constant: 5),
            indexLabel.topAnchor.constraint(equalTo: previewView.topAnchor, constant: 5),
            indexLabel.widthAnchor.constraint(equalToConstant: 28),
            indexLabel.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: previewView.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 17),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateImage.leadingAnchor, constant: -10),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: stateImage.leadingAnchor, constant: -10),
            sizeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            sizeLabel.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 7),
            sizeLabel.heightAnchor.constraint(equalToConstant: 20),
            stateImage.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stateImage.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
    }

    /// 此单元格只由代码注册，不接受 Storyboard 解码。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 清空上一行资源，避免复用时显示旧画面。
    override func prepareForReuse() {
        super.prepareForReuse()
        fixture = nil
        isPreviewActive = false
        imagePolicy = .mixed
        previewView.clear()
        previewView.accessibilityValue = "idle"
    }

    /// 绑定样本和可选显示覆盖值，不在离屏配置阶段开始播放。
    func configure(
        with fixture: VAPFixture,
        index: Int,
        title: String? = nil,
        subtitle: String? = nil,
        accessibilityID: String? = nil,
        previewID: String? = nil,
        imagePolicy: GiftCatalog.ImagePolicy = .mixed
    ) {
        stopPreview()
        self.fixture = fixture
        self.imagePolicy = imagePolicy
        indexLabel.text = String(format: "%02d", index + 1)
        titleLabel.text = title ?? (fixture.looksLikeMedia ? "VAP 动画资源" : "损坏资源（负向样例）")
        subtitleLabel.text = subtitle ?? fixture.shortIdentifier
        sizeLabel.text = "  \(fixture.formattedSize)  "
        accessibilityIdentifier = accessibilityID ?? "catalog.item.\(index)"
        accessibilityLabel = "资源 \(index + 1)，\(fixture.formattedSize)，\(subtitleLabel.text ?? fixture.shortIdentifier)"
        previewView.accessibilityIdentifier = previewID ?? "catalog.preview.\(index)"
        previewView.accessibilityValue = fixture.looksLikeMedia ? "idle" : "invalid"
    }

    /// 对合法且未启动的样本开启静音预览；损坏样本保持负向标记。
    func startPreview() {
        // 负向样本不应在滚动目录时触发失败流程，重复可见回调也必须幂等。
        guard !isPreviewActive, let fixture, fixture.looksLikeMedia else { return }
        isPreviewActive = true
        var options = PlaybackOptions()
        // 历史目录包含普通视频与无 vapc 拼接样本，显式采用自动识别。
        options.assetMode = .automatic
        options.loopCount = 0
        options.audioMode = .muted
        options.clearsAfterFinish = false
        options.contentMode = .scaleAspectFit
        // 只有动图专用预览需要启用逐帧替换，默认保持既有静态策略。
        if imagePolicy == .animatedOnly {
            options.dynamicImagePlaybackMode = .animated
        }
        previewView.accessibilityValue = "preparing"
        previewView.play(url: fixture.url, options: options)
    }

    /// 停止播放，并为可播放样本恢复待机标记。
    func stopPreview() {
        isPreviewActive = false
        previewView.stop()
        // 损坏样本仍保留 invalid 标记，供原有 UI 测试识别。
        if fixture?.looksLikeMedia == true { previewView.accessibilityValue = "idle" }
    }

    /// 收到真实开始回调后更新预览状态。
    func playerDidStart(_ player: PlayerView) {
        previewView.accessibilityValue = "playing"
    }

    /// 列表不展示详细元信息，详情页负责该能力。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}

    /// 为自然结束或显式停止记录终态。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {
        previewView.accessibilityValue = "finished"
    }

    /// 将播放失败呈现为已有的测试状态值。
    func player(_ player: PlayerView, didFail error: Error) {
        previewView.accessibilityValue = "failed"
    }

    /// 在主线程为动态槽位提供本地图片或文字；不访问网络。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        GiftCatalog.content(for: source, imagePolicy: imagePolicy)
    }
}

/// 为文件大小文字增加固定内边距，不改变标签文本内容。
private final class PaddingLabel: UILabel {
    /// 扩展固有尺寸以容纳卡片内边距。
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + 12, height: size.height + 4)
    }
}
