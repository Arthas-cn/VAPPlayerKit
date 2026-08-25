import UIKit
import QuartzCore
import VAPPlayerKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
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

/// Development-only screen used by the real-device queue policy benchmark.
/// It exercises the public prepare path with the same 12 media fixtures under
/// a fresh process for each command-queue policy.
final class MetalBenchmarkViewController: UIViewController {
    private let resultLabel = UILabel()
    private var players: [PlayerView] = []
    private var probes: [MetalBenchmarkProbe] = []
    private var delegates: [MetalBenchmarkDelegate] = []
    private var hasStarted = false

    private let minimumRenderedFramesPerPlayer = 5

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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasStarted else { return }
        hasStarted = true
        Task { @MainActor [weak self] in await self?.runBenchmark() }
    }

    private func runBenchmark() async {
        let fixtures = FixtureCatalog.scan().filter(\.looksLikeMedia).prefix(12)
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
            let options = PlaybackOptions.defaultOptions
            options.loopCount = 0
            options.clearsAfterFinish = false
            for (index, fixture) in fixtures.enumerated() {
                let player = makePlayer(index: index)
                _ = try await player.prepare(url: fixture.url, options: options)
            }
            let sequential = CACurrentMediaTime() - sequentialStart
            removePlayers()

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
                    group.addTask { @MainActor in
                        _ = try await player.prepare(url: fixture.url, options: options)
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
            removePlayers()
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
            removePlayers()
            resultLabel.text = "METAL BENCHMARK FAILED\n\(error.localizedDescription)"
        }
    }

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

    private func removePlayers() {
        players.forEach {
            $0.stop()
            $0.delegate = nil
            $0.metricsSink = nil
            $0.removeFromSuperview()
        }
        players.removeAll()
        probes.removeAll()
        delegates.removeAll()
    }

}

private final class MetalBenchmarkProbe: MetricsSink {
    private let lock = NSLock()
    private var rendered = 0
    private var dropped = 0
    private var failures = 0
    private var drawableFailures = 0

    struct Snapshot {
        let rendered: Int
        let dropped: Int
        let failures: Int
        let drawableFailures: Int
        let secondHalfRendered: Int

        func with(secondHalfRendered: Int) -> Snapshot {
            Snapshot(
                rendered: rendered,
                dropped: dropped,
                failures: failures,
                drawableFailures: drawableFailures,
                secondHalfRendered: secondHalfRendered
            )
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            rendered: rendered,
            dropped: dropped,
            failures: failures,
            drawableFailures: drawableFailures,
            secondHalfRendered: 0
        )
    }

    func recordFailure() {
        lock.lock()
        failures += 1
        lock.unlock()
    }

    func record(_ event: MetricsEvent) {
        lock.lock()
        defer { lock.unlock() }
        switch event {
        case .renderedFrame: rendered += 1
        case .droppedFrame: dropped += 1
        case .metalDrawableFailure: drawableFailures += 1
        default: break
        }
    }
}

@MainActor
private final class MetalBenchmarkDelegate: PlayerDelegate {
    private let probe: MetalBenchmarkProbe

    init(probe: MetalBenchmarkProbe) {
        self.probe = probe
    }

    func playerDidStart(_ player: PlayerView) {}
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {}
    func player(_ player: PlayerView, didFail error: Error) {
        probe.recordFailure()
    }
}
