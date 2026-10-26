import Synchronization
import UIKit
import QuartzCore
import VAPPlayerKit

/// 创建 Demo 主窗口，根据启动参数选择目录或设备基准页。
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// 当前 scene 的根窗口；连接前为 nil。
    var window: UIWindow?

    /// 连接 UIKit 窗口场景，不接管非窗口 scene。
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        // 非窗口场景不能创建 UIWindow，直接交回系统。
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let root: UIViewController = ProcessInfo.processInfo.arguments.contains("--vap-metal-benchmark")
            ? MetalBenchmarkViewController()
            : ViewController()
        let navigationController = UINavigationController(rootViewController: root)
        navigationController.navigationBar.prefersLargeTitles = true
        window.rootViewController = navigationController
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// 设备端开发基准页，以相同十二个本地样本比较串行和并发 prepare。
/// 每种命令队列策略应在新进程运行，避免前轮状态影响测量。
final class MetalBenchmarkViewController: UIViewController {
    /// 呈现最终测量数据并保留既有 UI 测试定位。
    private let resultLabel = UILabel()
    /// 当前测量批次创建的播放器。
    private var players: [PlayerView] = []
    /// 与播放器一一对应的线程安全计数探针。
    private var probes: [MetalBenchmarkProbe] = []
    /// 强持有弱 delegate 的实际对象，直到播放器清理完成。
    private var delegates: [MetalBenchmarkDelegate] = []
    /// 防止页面重复出现时重新测量。
    private var hasStarted = false
    /// 控制整个基准流程的任务，页面退出时取消。
    private var runTask: Task<Void, Never>?

    /// 每个播放器至少需要达到的渲染帧数。
    private let minimumRenderedFramesPerPlayer = 5

    /// 建立结果显示区域，播放画面在测量时动态加入。
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.065, alpha: 1)
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        resultLabel.numberOfLines = 0
        resultLabel.textAlignment = .center
        resultLabel.font = .monospacedSystemFont(ofSize: 14, weight: .medium)
        resultLabel.textColor = .white
        resultLabel.accessibilityIdentifier = "metal.benchmark"
        resultLabel.text = "METAL BENCHMARK RUNNING"
        view.addSubview(resultLabel)
        NSLayoutConstraint.activate([
            resultLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            resultLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            resultLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            resultLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }

    /// 随窗口尺寸重新排列当前播放器，保持每项可见。
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size: CGFloat = 64
        let gap: CGFloat = 8
        let startX = (view.bounds.width - (size * 3 + gap * 2)) / 2
        for (index, player) in players.enumerated() {
            let column = CGFloat(index % 3)
            let row = CGFloat(index / 3)
            player.frame = CGRect(
                x: startX + column * (size + gap),
                y: view.safeAreaInsets.top + 24 + row * (size + gap),
                width: size,
                height: size
            )
        }
    }

    /// 首次进入窗口后开始基准，避免离屏 drawable 失败污染结果。
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // 同一控制器的一次结果不可被重复出现事件覆盖。
        guard !hasStarted else { return }
        hasStarted = true
        runTask = Task { @MainActor [weak self] in await self?.runBenchmark() }
    }

    /// 运行准备时间与持续渲染测量；任意失败都会先清理，再报告。
    private func runBenchmark() async {
        let fixtures = FixtureCatalog.scan().filter(\.looksLikeMedia).prefix(12)
        // 样本数量不一致时基准不可比较，明确失败而不是少跑几项。
        guard fixtures.count == 12 else {
            resultLabel.text = "METAL BENCHMARK FAILED\nExpected 12 playable fixtures"
            return
        }

        let policy = ProcessInfo.processInfo.arguments
            .first(where: { $0.hasPrefix("-vap-metal-command-queue-policy=") })?
            .split(separator: "=", maxSplits: 1)
            .last.map(String.init) ?? "shared"
        do {
            let sequentialStart = CACurrentMediaTime()
            var options = PlaybackOptions()
            // 历史目录包含普通视频与无 vapc 拼接样本，显式采用自动识别。
            options.assetMode = .automatic
            options.loopCount = 0
            options.clearsAfterFinish = false
            for (index, fixture) in fixtures.enumerated() {
                // 清理不会替调用者抛取消，开始新一项前自行检查。
                try Task.checkCancellation()
                let player = makePlayer(index: index)
                _ = try await player.prepare(url: fixture.url, options: options)
            }
            let sequential = CACurrentMediaTime() - sequentialStart
            await removePlayers()
            try Task.checkCancellation()

            let concurrentPlayers = fixtures.map { _ in
                PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
            }
            players = concurrentPlayers
            probes = concurrentPlayers.map { player in
                let probe = MetalBenchmarkProbe()
                player.metricsSink = probe
                let delegate = MetalBenchmarkDelegate(probe: probe)
                player.delegate = delegate
                delegates.append(delegate)
                view.addSubview(player)
                return probe
            }
            view.setNeedsLayout()
            view.layoutIfNeeded()
            let concurrentStart = CACurrentMediaTime()
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (player, fixture) in zip(concurrentPlayers, fixtures) {
                    let url = fixture.url
                    let snapshot = options
                    group.addTask {
                        try await prepareBenchmarkPlayer(player, url: url, options: snapshot)
                    }
                }
                try await group.waitForAll()
            }
            let concurrent = CACurrentMediaTime() - concurrentStart
            for (index, player) in concurrentPlayers.enumerated() {
                player.play(url: fixtures[index].url, options: options)
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let midpointSnapshots = probes.map { $0.snapshot() }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let snapshots = probes.enumerated().map { index, probe in
                let end = probe.snapshot()
                let midpoint = midpointSnapshots[index]
                return end.with(secondHalfRendered: end.rendered - midpoint.rendered)
            }
            let rendered = snapshots.reduce(0) { $0 + $1.rendered }
            let dropped = snapshots.reduce(0) { $0 + $1.dropped }
            let failures = snapshots.reduce(0) { $0 + $1.failures }
            let drawableFailures = snapshots.reduce(0) { $0 + $1.drawableFailures }
            let floorSatisfied = snapshots.count == fixtures.count && snapshots.allSatisfy {
                $0.rendered >= minimumRenderedFramesPerPlayer &&
                $0.secondHalfRendered > 0 &&
                $0.failures == 0 &&
                $0.drawableFailures == 0
            }
            let perPlayer = snapshots.enumerated().map { index, snapshot in
                "\(index):rendered=\(snapshot.rendered),second_half=\(snapshot.secondHalfRendered),dropped=\(snapshot.dropped),failures=\(snapshot.failures),drawable_failures=\(snapshot.drawableFailures)"
            }.joined(separator: ";")
            await removePlayers()
            resultLabel.text = String(
                format: "METAL DEVICE BENCHMARK\npolicy=%@\ncount=%d\nsequential_ms=%.2f\nconcurrent_ms=%.2f\nrendered=%d\ndropped=%d\nfailures=%d\ndrawable_failures=%d\nper_player=%@\nstatus=%@",
                policy,
                fixtures.count,
                sequential * 1_000,
                concurrent * 1_000,
                rendered,
                dropped,
                failures,
                drawableFailures,
                perPlayer,
                floorSatisfied ? "PASS" : "FAILED"
            )
            resultLabel.accessibilityValue = resultLabel.text
        } catch {
            // 失败和取消都等待真实资源排空，禁止留下离屏播放。
            await removePlayers()
            resultLabel.text = "METAL BENCHMARK FAILED\n\(error.localizedDescription)"
        }
    }

    /// 为串行准备阶段创建播放器并持有它的计数和错误接收器。
    private func makePlayer(index: Int) -> PlayerView {
        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        let probe = MetalBenchmarkProbe()
        player.metricsSink = probe
        let delegate = MetalBenchmarkDelegate(probe: probe)
        player.delegate = delegate
        players.append(player)
        probes.append(probe)
        delegates.append(delegate)
        view.addSubview(player)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        return player
    }

    /// 同步暂停整批播放器，再逐一等待解码、音频和 GPU 清理完成。
    private func removePlayers() async {
        let retiring = players
        players.removeAll()
        // 先同时停音，随后逐个等待物理清理，下一组测试不得与旧 GPU 工作重叠。
        retiring.forEach { $0.pause() }
        for player in retiring {
            player.delegate = nil
            await player.clearAndWait()
            player.metricsSink = nil
            player.removeFromSuperview()
        }
        probes.removeAll()
        delegates.removeAll()
    }

    /// 离开基准页面时取消已有流程，流程自己的 catch 负责等待排空。
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        runTask?.cancel()
    }

}

/// 基准测量的跨线程指标；所有计数只在 Mutex 内修改。
nonisolated private final class MetalBenchmarkProbe: MetricsSink {
    /// 一次测量的纯值快照，供主线程计算汇总与后半程帧数。
    struct Snapshot: Sendable {
        /// 累计渲染帧数。
        var rendered = 0
        /// 累计丢帧数。
        var dropped = 0
        /// 会话失败次数。
        var failures = 0
        /// drawable 获取失败次数。
        var drawableFailures = 0
        /// 后半程新增帧数，汇总时计算。
        var secondHalfRendered = 0

        /// 返回补上后半程帧数的新值，不改写探针计数。
        func with(secondHalfRendered: Int) -> Snapshot {
            var copy = self
            copy.secondHalfRendered = secondHalfRendered
            return copy
        }
    }

    /// 唯一状态容器，保证 MetricsSink 的 Sendable 没有隐藏可变字段。
    private let state = Mutex(Snapshot())

    /// 取得当前一致快照，不向调用方暴露锁内引用。
    func snapshot() -> Snapshot { state.withLock { $0 } }

    /// delegate 报错与后台指标使用同一把锁累加。
    func recordFailure() { state.withLock { $0.failures += 1 } }

    /// 只记录基准需要的渲染、丢帧和表面失败。
    func record(_ event: MetricsEvent) {
        state.withLock { value in
            switch event {
            // 成功帧是持续播放的直接证据。
            case .renderedFrame: value.rendered += 1
            // 丢帧单独计数，不与解码失败混淆。
            case .droppedFrame: value.dropped += 1
            // drawable 不可用会导致画面缺失，独立报告。
            case .metalDrawableFailure: value.drawableFailures += 1
            // 其他指标不进入本基准，避免扩展无关统计口径。
            default: break
            }
        }
    }
}

/// 将主线程的播放失败交给可跨线程读取的基准探针。
@MainActor
private final class MetalBenchmarkDelegate: PlayerDelegate {
    /// 与该 delegate 绑定的计数探针。
    private let probe: MetalBenchmarkProbe

    /// 接收当前播放器对应的探针。
    init(probe: MetalBenchmarkProbe) {
        self.probe = probe
    }

    /// 基准以实际帧数为证据，不额外计数开始信号。
    func playerDidStart(_ player: PlayerView) {}
    /// 元信息由 prepare 返回值验证，此处不重复处理。
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}
    /// 基准主动清理结束测量，不统计正常终态。
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {}
    /// 任意播放失败都使该播放器的基准结果失败。
    func player(_ player: PlayerView, didFail error: Error) {
        probe.recordFailure()
    }
}

/// 将并发基准的 Sendable 任务转入 MainActor，不在任务闭包捕获控制器或 fixture。
@MainActor
private func prepareBenchmarkPlayer(_ player: PlayerView, url: URL, options: PlaybackOptions) async throws {
    _ = try await player.prepare(url: url, options: options)
}
