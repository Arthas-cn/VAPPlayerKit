import Synchronization
import UIKit
import VAPPlayerKit

/// 在真机上逐个验证所有 Bundle fixture：合法素材 prepare + 实际播放，非法素材必须明确失败。
final class BatchTestViewController: UIViewController, PlayerDelegate, DynamicContentProvider {
    /// 按目录顺序验证的固定样本快照。
    private let fixtures: [VAPFixture]
    /// 串行复用的实际渲染播放器。
    private let playerView = PlayerView()
    /// 整批运行状态及最终结果。
    private let stateLabel = UILabel()
    /// 已完成样本占总数的比例。
    private let progressView = UIProgressView(progressViewStyle: .bar)
    /// 当前样本序号和标识。
    private let progressLabel = UILabel()
    /// 每个样本的通过或失败证据。
    private let logView = UITextView()
    /// 从后台指标统计真实渲染帧数。
    private let renderProbe = RenderProbe()
    /// 页面持有的批量验证任务，退出时取消。
    private var runTask: Task<Void, Never>?
    /// 同一页面只执行一轮批量验证。
    private var started = false
    /// 当前样本是否收到开始播放回调。
    private var currentDidStart = false
    /// 当前样本的首个或最近失败；nil 表示尚未失败。
    private var currentFailure: Error?
    /// 当前样本停止后的终态理由。
    private var currentFinishReason: FinishReason?
    /// 按发生顺序保留的显示日志。
    private var lines: [String] = []

    /// 接收已扫描的目录快照，不重复扫描或调整排序。
    init(fixtures: [VAPFixture]) {
        self.fixtures = fixtures
        super.init(nibName: nil, bundle: nil)
    }

    /// 本测试页只接受代码初始化。
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 页面释放时取消尚未完成的验证任务。
    isolated deinit { runTask?.cancel() }

    /// 连接播放器回调和指标，并建立验证界面。
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Device Batch Test"
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.065, alpha: 1)
        playerView.delegate = self
        playerView.dynamicContentProvider = self
        playerView.metricsSink = renderProbe
        configureUI()
    }

    /// 首次实际出现后启动验证，确保播放器已有窗口和布局。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 返回本页不重复跑一轮，以免污染前一轮结果。
        guard !started else { return }
        started = true
        runTask = Task { @MainActor [weak self] in await self?.runAllFixtures() }
    }

    /// 返回上级时取消任务并立即停止当前播放器。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 临时遮挡不是退出；仅导航移除时结束本轮。
        if isMovingFromParent {
            runTask?.cancel()
            playerView.stop()
        }
    }

    /// 呈现状态、进度、真实播放画面和逐项日志。
    private func configureUI() {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        view.addSubview(stack)

        stateLabel.text = "WAITING"
        stateLabel.font = .monospacedSystemFont(ofSize: 18, weight: .bold)
        stateLabel.textColor = UIColor(red: 0.48, green: 0.84, blue: 1, alpha: 1)
        stateLabel.textAlignment = .center
        stateLabel.accessibilityIdentifier = "batch.state"
        progressView.progressTintColor = UIColor(red: 0.28, green: 0.75, blue: 0.57, alpha: 1)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        progressLabel.textColor = .secondaryLabel
        progressLabel.textAlignment = .center
        progressLabel.accessibilityIdentifier = "batch.progress"
        playerView.backgroundColor = UIColor(white: 0.12, alpha: 1)
        playerView.layer.cornerRadius = 18
        playerView.clipsToBounds = true
        playerView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        logView.backgroundColor = UIColor(red: 0.02, green: 0.025, blue: 0.04, alpha: 1)
        logView.textColor = UIColor(white: 0.75, alpha: 1)
        logView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        logView.isEditable = false
        logView.layer.cornerRadius = 14
        logView.accessibilityIdentifier = "batch.log"

        [stateLabel, progressView, progressLabel, playerView, logView].forEach(stack.addArrangedSubview)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
    }

    /// 逐个验证准备、渲染和停止回调，损坏资源必须被拒绝。
    private func runAllFixtures() async {
        // 没有样本不能被报告为一轮成功验证。
        guard !fixtures.isEmpty else {
            stateLabel.text = "BATCH FAILED"
            append("No fixtures found")
            return
        }
        stateLabel.text = "BATCH RUNNING"
        append("Device: \(UIDevice.current.name), iOS \(UIDevice.current.systemVersion)")
        append("Fixtures: \(fixtures.count)")
        var failures: [String] = []

        for (index, fixture) in fixtures.enumerated() {
            // 用户退出后不再消费下一个资源。
            guard !Task.isCancelled else { return }
            progressLabel.text = "\(index + 1) / \(fixtures.count) · \(fixture.shortIdentifier)"
            progressView.setProgress(Float(index) / Float(fixtures.count), animated: true)
            currentDidStart = false
            currentFailure = nil
            currentFinishReason = nil
            await playerView.clearAndWait()
            var options = PlaybackOptions()
            // 历史目录包含普通视频与无 vapc 拼接样本，显式采用自动识别。
            options.assetMode = .automatic
            options.loopCount = 0
            options.clearsAfterFinish = false

            do {
                let metadata = try await playerView.prepare(url: fixture.url, options: options)
                // 负向素材意外准备成功必须记录失败，不能进入正常播放路径。
                if !fixture.looksLikeMedia {
                    failures.append("\(fixture.shortIdentifier): invalid fixture unexpectedly prepared")
                    append("FAIL negative fixture accepted")
                    playerView.stop()
                    continue
                }
                // 可播放素材至少应有有效尺寸、时长和帧数。
                guard metadata.frameCount > 0, metadata.duration > 0,
                      metadata.canvasSize.width > 0, metadata.canvasSize.height > 0 else {
                    throw BatchTestError.invalidMetadata
                }
                // 既有左 Alpha 样本用于锁定自动检测结果，防止退化成普通视频。
                if fixture.identifier == "alpha_left_moive" {
                    // 编码尺寸包括 Alpha 半幅，展示尺寸只包含颜色半幅。
                    guard metadata.isVAP, metadata.alphaMode == .left,
                          metadata.encodedVideoSize == CGSize(width: 1504, height: 448),
                          metadata.canvasSize == CGSize(width: 752, height: 448) else {
                        throw BatchTestError.invalidMetadata
                    }
                }
                // 普通视频不得被自动检测误判为透明拼接素材。
                if fixture.identifier == "home" {
                    // 普通视频的展示尺寸应等于编码尺寸。
                    guard !metadata.isVAP, metadata.alphaMode == .none,
                          metadata.canvasSize == metadata.encodedVideoSize else {
                        throw BatchTestError.invalidMetadata
                    }
                }
                let initialRenderedCount = renderProbe.renderedFrameCount
                playerView.play(url: fixture.url, options: options)
                try await waitForPlaybackEvidence(after: initialRenderedCount, timeout: 3)
                try await keepPlaying(for: min(1, metadata.duration))
                playerView.stop()
                // stop 的终态回调是同步契约，不等待额外主队列轮转。
                guard currentFinishReason == .stopped else { throw BatchTestError.missingStoppedCallback }
                append("PASS \(index + 1) \(fixture.shortIdentifier): \(metadata.codec), \(metadata.frameCount)f")
            } catch is CancellationError {
                // 取消属于页面生命周期，不计为素材失败。
                return
            } catch {
                playerView.stop()
                // 合法素材报错需要记录；损坏素材报错才是负向用例的预期。
                if fixture.looksLikeMedia {
                    failures.append("\(fixture.shortIdentifier): \(error.localizedDescription)")
                    append("FAIL \(index + 1): \(error.localizedDescription)")
                } else {
                    append("PASS \(index + 1): negative fixture rejected")
                }
            }
        }

        progressView.setProgress(1, animated: true)
        progressLabel.text = "\(fixtures.count) / \(fixtures.count)"
        await playerView.clearAndWait()
        // 只有全部样本通过并完成物理清理后，才发布整批成功。
        if failures.isEmpty {
            stateLabel.text = "BATCH PASSED"
            append("All fixture checks passed")
        } else {
            stateLabel.text = "BATCH FAILED"
            append("Failures: \(failures.count)")
            failures.forEach { append($0) }
        }
    }

    /// 追加一条日志并滚动到最新结果。
    private func append(_ line: String) {
        lines.append(line)
        logView.text = lines.joined(separator: "\n")
        // 空内容没有合法的最后一个 UTF-16 范围。
        if !logView.text.isEmpty {
            logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1))
        }
    }

    /// 在超时前同时等待开始回调和新渲染帧；失败或取消直接抛出。
    private func waitForPlaybackEvidence(after renderedCount: Int, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            // 实际播放失败优先于超时，保留原始错误证据。
            if let currentFailure { throw currentFailure }
            // prepare 成功和单独 start 回调都不能证明画面已经提交。
            if currentDidStart, renderProbe.renderedFrameCount > renderedCount { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BatchTestError.noRenderedFrame
    }

    /// 继续观察指定时长内的延迟失败，取消会通过 sleep 抛出。
    private func keepPlaying(for duration: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
        while ProcessInfo.processInfo.systemUptime < deadline {
            // 捕获开始之后才发生的解码或渲染错误。
            if let currentFailure { throw currentFailure }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// 记录当前样本开始信号，供渲染证据等待共同判定。
    func playerDidStart(_ player: PlayerView) { currentDidStart = true }
    /// 元信息直接使用 prepare 返回值，不在回调里重复校验。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}
    /// 保存终态用于核对 stop 的同步契约。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) { currentFinishReason = reason }
    /// 将异步播放错误交给当前验证循环处理。
    func player(_ player: PlayerView, didFail error: Error) { currentFailure = error }

    /// 批量测试不替换动态素材，nil 让素材保持默认表现。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? { nil }
}

/// 批量验证自身发现的契约错误，与 SDK 的素材错误区分。
private enum BatchTestError: LocalizedError {
    /// 素材尺寸、帧数、时长或已知 Alpha 布局不符合预期。
    case invalidMetadata
    /// 截止时间内没有同时观察到开始和渲染证据。
    case noRenderedFrame
    /// 显式 stop 没有立刻发出 stopped 终态。
    case missingStoppedCallback

    /// 为逐项日志提供可读失败原因。
    var errorDescription: String? {
        switch self {
        // 准备结果无效，需要检查解析或识别分支。
        case .invalidMetadata: return "Metadata invariants failed."
        // 准备完成但没有渲染，不能当作播放成功。
        case .noRenderedFrame: return "Playback did not start and render a frame before timeout."
        // 同步停止契约丢失，应单独定位生命周期回调。
        case .missingStoppedCallback: return "Stop did not emit the stopped terminal callback."
        }
    }
}

/// 批量测试的跨线程帧计数探针，全部可变状态受 Mutex 保护。
nonisolated private final class RenderProbe: MetricsSink {
    /// 唯一渲染计数，后台指标与主线程读取使用同一把锁。
    private let renderedFrames = Mutex(0)

    /// 返回已提交渲染的帧数，供条件等待使用。
    var renderedFrameCount: Int { renderedFrames.withLock { $0 } }

    /// 只累计实际渲染事件，其余指标不属于此探针职责。
    func record(_ event: MetricsEvent) {
        // 解析或解码成功不能替代实际渲染证据。
        guard case .renderedFrame = event else { return }
        renderedFrames.withLock { $0 += 1 }
    }
}
