import UIKit
import VAPPlayerKit

/// UIKit 播放实验室；保留既有控制入口与测试标识，用 v2 值配置驱动内核。
@MainActor
final class PlaybackDetailViewController: UIViewController {
    /// 当前页面独占的本地样本，页面内切换配置不会改变源文件。
    let fixture: VAPFixture
    /// 动态图替换样本索引，仅在动态图模式使用。
    var animatedGiftIndex: Int
    /// 静态图替换样本索引，仅在静图模式使用。
    var stillGiftIndex: Int
    /// 页面唯一的 UIKit 播放内核，不与列表预览共用。
    let playerView = PlayerView()
    /// 线程安全指标收集器，负责摘要和报告。
    let diagnostics = PlaybackDiagnostics()
    /// 承载实验控制区，适应较小屏幕。
    let scrollView = UIScrollView()
    /// 按顺序排列预览、参数、控制和诊断卡片。
    let contentStack = UIStackView()
    /// 播放器与棋盘背景的共同容器。
    let previewCard = UIView()
    /// 当前播放状态徽标，同时保留 UI 测试定位。
    let stateLabel = InsetsLabel()
    /// 已解析的逻辑画布、编码帧与槽位摘要。
    let metadataLabel = UILabel()
    /// 累计解码、渲染与丢帧摘要。
    let metricsLabel = UILabel()
    /// 滚动显示最近诊断时间线。
    let consoleView = UITextView()
    /// 选择 fit、fill 或 stretch。
    let contentModeControl = UISegmentedControl(items: ["Fit", "Fill", "Stretch"])
    /// 选择总次数 1、2 或无限循环。
    let loopControl = UISegmentedControl(items: ["1×", "2×", "∞"])
    /// 选择内核音频资源策略。
    let audioControl = UISegmentedControl(items: ["静音", "内嵌", "外部", "禁用"])
    /// 选择后台挂起或停止行为。
    let backgroundControl = UISegmentedControl(items: ["挂起", "停止"])
    /// 选择动态槽使用静图首帧或动画。
    let dynamicImageControl = UISegmentedControl(items: ["静图", "动图"])
    /// 选择超宽动态文字的截断或跑马灯。
    let textOverflowControl = UISegmentedControl(items: ["截断", "跑马灯"])
    /// 选择跑马灯速度，单位 pt/s。
    let marqueeSpeedControl = UISegmentedControl(items: ["20", "40", "80"])
    /// 选择每次跑马灯起步等待秒数。
    let marqueeDelayControl = UISegmentedControl(items: ["0s", "0.6s", "1.2s"])
    /// 切换到前一个图片替换样本。
    let previousGiftButton = UIButton(type: .system)
    /// 切换到后一个图片替换样本。
    let nextGiftButton = UIButton(type: .system)
    /// 显示当前图片样本名称和类型。
    let giftNameLabel = UILabel()
    /// 切换到前一段文字样本。
    let previousTextButton = UIButton(type: .system)
    /// 切换到后一段文字样本。
    let nextTextButton = UIButton(type: .system)
    /// 显示当前文字样本摘要。
    let textSampleLabel = UILabel()
    /// 控制自然完成后是否清除最后画面。
    let clearsSwitch = UISwitch()
    /// 当前 prepare 或冒烟流程任务，离页时取消。
    var operationTask: Task<Void, Never>?
    /// 最近成功解析的元数据；nil 表示尚未成功准备。
    var currentMetadata: AssetMetadata?
    /// 是否正在执行页面内冒烟流程。
    var isAutomatedRun = false
    /// 本轮是否已收到内核运行回调。
    var currentDidStart = false
    /// 本轮不可恢复错误；nil 表示尚无错误。
    var currentFailure: Error?
    /// 本轮终态原因，供停止回调验证。
    var currentFinishReason: FinishReason?
    /// 确保首次进入页面只自动播放一次。
    var hasAutoPlayed = false
    /// 当前动态文字样本索引。
    var replacementTextIndex = 0

    /// 创建指定样本的实验页面，并选择初始图片替换样本。
    init(fixture: VAPFixture) {
        self.fixture = fixture
        self.animatedGiftIndex = GiftCatalog.randomGiftIndex(policy: .animatedOnly)
        self.stillGiftIndex = GiftCatalog.randomGiftIndex(policy: .stillOnly)
        super.init(nibName: nil, bundle: nil)
    }

    /// 仅支持程序化页面，不接受 storyboard 构造。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 只取消已拥有的任务；底层资源由 PlayerView 的受管清理兜底。
    isolated deinit {
        operationTask?.cancel()
    }

    /// 组装页面、播放器与诊断，不在初始化器中做资源准备。
    override func viewDidLoad() {
        super.viewDidLoad()
        configureNavigation()
        configureHierarchy()
        configurePlayer()
        bindDiagnostics()
        diagnostics.append("DEVICE", "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)")
        diagnostics.append("ASSET", "\(fixture.shortIdentifier), \(fixture.formattedSize)")
        diagnostics.append(
            "GIFT",
            "animated \(GiftCatalog.animatedGiftDisplayName(at: animatedGiftIndex)), still \(GiftCatalog.stillGiftDisplayName(at: stillGiftIndex))"
        )
    }

    /// 首次页面真正出现后启动样本，避免普通重现重复播放。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 页面返回展示不能重新播放正在保留的请求。
        guard !hasAutoPlayed else { return }
        hasAutoPlayed = true
        stateLabel.text = "PREPARING"
        diagnostics.append("ACTION", "auto play on detail entry")
        playerView.play(url: fixture.url, options: currentOptions())
    }

    /// 返回或关闭页面时停止音画、取消操作并保存报告。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 仅真正退出才结束会话，弹出分享面板不误停播放。
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            operationTask?.cancel()
            playerView.stop()
            _ = diagnostics.persist(fixture: fixture)
        }
    }

    /// 绑定本页面 delegate、provider 与线程安全指标收集器。
    func configurePlayer() {
        playerView.delegate = self
        playerView.dynamicContentProvider = self
        playerView.metricsSink = diagnostics
    }

    /// 把纯值诊断快照应用到主线程 UI，闭包不强持有页面。
    func bindDiagnostics() {
        diagnostics.onUpdate = { [weak self] snapshot in
            self?.metricsLabel.text = snapshot.summary
            self?.consoleView.text = snapshot.log
            // 空日志没有可滚动的末尾范围，页面释放后也不触碰 UI。
            if let console = self?.consoleView, !snapshot.log.isEmpty {
                console.scrollRangeToVisible(NSRange(location: max(0, snapshot.log.utf16.count - 1), length: 1))
            }
        }
    }

    /// 从控件构造独立的 v2 配置值，历史样本显式采用 automatic。
    func currentOptions(contentMode: UIView.ContentMode? = nil, audioMode: AudioMode? = nil) -> PlaybackOptions {
        var options = PlaybackOptions()
        // 历史 fixture 同时包含普通视频与旧 packed VAP，显式保留自动识别测试路径。
        options.assetMode = .automatic
        options.contentMode = contentMode ?? [.scaleAspectFit, .scaleAspectFill, .scaleToFill][contentModeControl.selectedSegmentIndex]
        options.loopCount = [1, 2, 0][loopControl.selectedSegmentIndex]
        options.audioMode = audioMode ?? [.muted, .embedded, .external, .disabled][audioControl.selectedSegmentIndex]
        options.backgroundPolicy = backgroundControl.selectedSegmentIndex == 0 ? .suspend : .stop
        options.dynamicImagePlaybackMode = dynamicImageControl.selectedSegmentIndex == 0 ? .still : .animated
        options.dynamicTextOverflowMode = textOverflowControl.selectedSegmentIndex == 0 ? .truncate : .marquee
        options.marqueeSpeed = [20, 40, 80][marqueeSpeedControl.selectedSegmentIndex]
        options.marqueeStartDelay = [0, 0.6, 1.2][marqueeDelayControl.selectedSegmentIndex]
        options.clearsAfterFinish = clearsSwitch.isOn
        return options
    }

    /// 取消上一操作并登记新的异步准备任务。
    @objc func prepareTapped() {
        cancelOperation()
        operationTask = Task { @MainActor [weak self] in await self?.prepareCurrent() }
    }

    /// 使用当前配置创建新播放操作。
    @objc func playTapped() {
        cancelOperation()
        stateLabel.text = "PREPARING"
        diagnostics.append("ACTION", "play")
        playerView.play(url: fixture.url, options: currentOptions())
    }

    /// 切换到前一个图片替换样本并重播。
    @objc func previousGiftTapped() {
        cycleGift(by: -1)
    }

    /// 切换到后一个图片替换样本并重播。
    @objc func nextGiftTapped() {
        cycleGift(by: 1)
    }

    /// 切换到前一个文字样本并重播。
    @objc func previousTextTapped() {
        cycleReplacementText(by: -1)
    }

    /// 切换到后一个文字样本并重播。
    @objc func nextTextTapped() {
        cycleReplacementText(by: 1)
    }

    /// 切换静图或动图策略后刷新对应样本名称。
    @objc func dynamicImageModeChanged() {
        refreshGiftName()
    }

    /// 当前控件是否选择动态图替换。
    var usesAnimatedGift: Bool {
        dynamicImageControl.selectedSegmentIndex == 1
    }

    /// 当前图片模式对应的素材筛选策略。
    var currentImagePolicy: GiftCatalog.ImagePolicy {
        usesAnimatedGift ? .animatedOnly : .stillOnly
    }

    /// 当前模式对应的独立样本索引。
    var currentImageIndex: Int {
        usesAnimatedGift ? animatedGiftIndex : stillGiftIndex
    }

    /// 循环切换当前类别的图片索引，再以新内容重播。
    func cycleGift(by delta: Int) {
        // 两类样本分别维护索引，切换模式不串用边界。
        if usesAnimatedGift {
            let count = max(GiftCatalog.animatedGiftCount(), 1)
            animatedGiftIndex = (animatedGiftIndex + delta % count + count) % count
        } else {
            // 静图索引只在静图资源集合内循环。
            let count = max(GiftCatalog.stillGiftCount(), 1)
            stillGiftIndex = (stillGiftIndex + delta % count + count) % count
        }
        refreshGiftName()
        diagnostics.append(
            "ACTION",
            "switch \(usesAnimatedGift ? "animated" : "still") gift \(giftNameLabel.text ?? "")"
        )
        cancelOperation()
        stateLabel.text = "PREPARING"
        playerView.play(url: fixture.url, options: currentOptions())
    }

    /// 循环切换文字样本，再重新准备应用替换。
    func cycleReplacementText(by delta: Int) {
        let count = GiftCatalog.replacementSampleCount()
        replacementTextIndex = (replacementTextIndex + delta % count + count) % count
        refreshTextSampleName()
        diagnostics.append("ACTION", "switch text \(GiftCatalog.replacementSampleDisplayName(at: replacementTextIndex))")
        cancelOperation()
        stateLabel.text = "PREPARING"
        playerView.play(url: fixture.url, options: currentOptions())
    }

    /// 暂停当前时间轴并更新诊断。
    @objc func pauseTapped() {
        playerView.pause()
        stateLabel.text = "PAUSED"
        diagnostics.append("ACTION", "pause")
    }

    /// 显式恢复当前进度，不重新创建播放请求。
    @objc func resumeTapped() {
        playerView.resume()
        stateLabel.text = "PLAYING"
        diagnostics.append("ACTION", "resume")
    }

    /// 取消页面异步操作并停止当前会话。
    @objc func stopTapped() {
        cancelOperation()
        playerView.stop()
        stateLabel.text = "STOPPED"
        diagnostics.append("ACTION", "stop")
    }

    /// 取消操作并清空画面，保留诊断供排查。
    @objc func clearTapped() {
        cancelOperation()
        playerView.clear()
        stateLabel.text = "CLEARED"
        diagnostics.append("ACTION", "clear")
    }

    /// 登记一个页面内自动冒烟流程。
    @objc func autoTestTapped() {
        cancelOperation()
        isAutomatedRun = true
        operationTask = Task { @MainActor [weak self] in await self?.runAutomatedSmokeTest() }
    }

    /// 等待准备结果；失败显示原因，不假装已有首帧。
    func prepareCurrent() async {
        stateLabel.text = "PREPARING"
        diagnostics.append("ACTION", "prepare")
        do {
            let metadata = try await playerView.prepare(url: fixture.url, options: currentOptions())
            // 新操作取消旧准备时，迟到结果不能覆盖新操作的页面状态。
            try Task.checkCancellation()
            display(metadata)
            stateLabel.text = "READY"
            diagnostics.append("PASS", "prepare completed")
        } catch is CancellationError {
            // 用户已发起下一操作或离开页面，取消不展示成素材失败。
            return
        } catch {
            stateLabel.text = "FAILED"
            diagnostics.append("ERROR", error.localizedDescription)
        }
    }

    /// 取消本页面拥有的操作并清除自动测试标记。
    func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        isAutomatedRun = false
    }

    /// 显示元数据值快照，逻辑尺寸与编码尺寸分别标注。
    func display(_ metadata: AssetMetadata) {
        currentMetadata = metadata
        metadataLabel.text = String(
            format: "%@ · codec %@ · vapc v%ld · %ld frames · %.3fs\nencoded %.0f×%.0f · canvas %.0f×%.0f · alpha %@\naudio %@ · dynamic %ld",
            metadata.isVAP ? "VAP" : "普通视频",
            metadata.codec,
            metadata.vapVersion,
            metadata.frameCount,
            metadata.duration,
            metadata.encodedVideoSize.width,
            metadata.encodedVideoSize.height,
            metadata.canvasSize.width,
            metadata.canvasSize.height,
            String(describing: metadata.alphaMode),
            metadata.containsAudio ? "yes" : "no",
            metadata.dynamicSources.count
        )
    }

    /// 打开报告分享面板，不发送网络消息。
    @objc func shareReport() {
        let report = diagnostics.reportText(fixture: fixture)
        let controller = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

}


/// 将内核回调或动态内容解析收敛到当前实验页面。
extension PlaybackDetailViewController: PlayerDelegate {
    /// 记录本轮已运行，更新页面状态。
    func playerDidStart(_ player: PlayerView) {
        currentDidStart = true
        stateLabel.text = "PLAYING"
        diagnostics.append("CALLBACK", "didStart")
    }

    /// 显示 prepare 解析得到的元数据快照。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {
        display(metadata)
        diagnostics.append("CALLBACK", "metadata resolved")
    }

    /// 记录唯一终态原因，供冒烟流程核对。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {
        currentFinishReason = reason
        stateLabel.text = "FINISHED"
        diagnostics.append("CALLBACK", "finish: \(String(describing: reason))")
    }

    /// 更新元数据或记录不可恢复错误，保持负向样本的预期失败语义。
    func player(_ player: PlayerView, didFail error: Error) {
        currentFailure = error
        stateLabel.text = fixture.looksLikeMedia ? "FAILED" : "EXPECTED FAIL"
        diagnostics.append(fixture.looksLikeMedia ? "ERROR" : "PASS", error.localizedDescription)
    }
}

/// 为本地槽位提供主线程图片或文本，保持已有素材选择控件行为。
extension PlaybackDetailViewController: DynamicContentProvider {
    /// 异步 provider 返回已准备的本地样本内容，不下载资源。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        diagnostics.append(
            "DYNAMIC",
            "resolve \(tag) (\(source.kind == .text ? "txt" : "img")), \(Int(source.slotSize.width))×\(Int(source.slotSize.height))"
                + (source.kind == .text
                    ? ", \(GiftCatalog.replacementSampleDisplayName(at: replacementTextIndex))"
                    : ", \(giftNameLabel.text ?? "")")
        )
        return GiftCatalog.content(
            for: source,
            imagePolicy: currentImagePolicy,
            imageIndex: currentImageIndex,
            replacementIndex: replacementTextIndex
        )
    }
}
