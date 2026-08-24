import UIKit
import VAPPlayerKit

/// 在真机上逐个验证所有 Bundle fixture：合法素材 prepare + 实际播放，非法素材必须明确失败。
final class BatchTestViewController: UIViewController, PlayerDelegate, DynamicContentProvider {
    private let fixtures: [VAPFixture]
    private let playerView = PlayerView()
    private let stateLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let progressLabel = UILabel()
    private let logView = UITextView()
    private let renderProbe = RenderProbe()
    private var runTask: Task<Void, Never>?
    private var started = false
    private var currentDidStart = false
    private var currentFailure: Error?
    private var currentFinishReason: FinishReason?
    private var lines: [String] = []

    init(fixtures: [VAPFixture]) {
        self.fixtures = fixtures
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { runTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Device Batch Test"
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.065, alpha: 1)
        playerView.delegate = self
        playerView.dynamicContentProvider = self
        playerView.metricsSink = renderProbe
        configureUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        runTask = Task { @MainActor [weak self] in await self?.runAllFixtures() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            runTask?.cancel()
            playerView.stop()
        }
    }

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

    private func runAllFixtures() async {
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
            guard !Task.isCancelled else { return }
            progressLabel.text = "\(index + 1) / \(fixtures.count) · \(fixture.shortIdentifier)"
            progressView.setProgress(Float(index) / Float(fixtures.count), animated: true)
            currentDidStart = false
            currentFailure = nil
            currentFinishReason = nil
            playerView.clear()
            let options = PlaybackOptions.defaultOptions
            options.loopCount = 0
            options.clearsAfterFinish = false

            do {
                let metadata = try await playerView.prepare(url: fixture.url, options: options)
                if !fixture.looksLikeMedia {
                    failures.append("\(fixture.shortIdentifier): invalid fixture unexpectedly prepared")
                    append("FAIL negative fixture accepted")
                    playerView.stop()
                    continue
                }
                guard metadata.frameCount > 0, metadata.duration > 0,
                      metadata.canvasSize.width > 0, metadata.canvasSize.height > 0 else {
                    throw BatchTestError.invalidMetadata
                }
                let initialRenderedCount = renderProbe.renderedFrameCount
                playerView.play(url: fixture.url, options: options)
                try await waitForPlaybackEvidence(after: initialRenderedCount, timeout: 3)
                try await keepPlaying(for: min(1, metadata.duration))
                playerView.stop()
                guard currentFinishReason == .stopped else { throw BatchTestError.missingStoppedCallback }
                append("PASS \(index + 1): \(metadata.codec), \(metadata.frameCount)f")
            } catch is CancellationError {
                return
            } catch {
                playerView.stop()
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
        playerView.clear()
        if failures.isEmpty {
            stateLabel.text = "BATCH PASSED"
            append("All fixture checks passed")
        } else {
            stateLabel.text = "BATCH FAILED"
            append("Failures: \(failures.count)")
            failures.forEach { append($0) }
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        logView.text = lines.joined(separator: "\n")
        if !logView.text.isEmpty {
            logView.scrollRangeToVisible(NSRange(location: logView.text.utf16.count - 1, length: 1))
        }
    }

    private func waitForPlaybackEvidence(after renderedCount: Int, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let currentFailure { throw currentFailure }
            if currentDidStart, renderProbe.renderedFrameCount > renderedCount { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw BatchTestError.noRenderedFrame
    }

    private func keepPlaying(for duration: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, duration)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let currentFailure { throw currentFailure }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func playerDidStart(_ player: PlayerView) { currentDidStart = true }
    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {}
    func playerDidFinish(_ player: PlayerView, reason: FinishReason) { currentFinishReason = reason }
    func player(_ player: PlayerView, didFail error: Error) { currentFailure = error }

    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        if tag.localizedCaseInsensitiveContains("text") || tag.localizedCaseInsensitiveContains("name") {
            completion(.textReplacement("VAP Swift"), nil)
            return
        }
        let image = UIGraphicsImageRenderer(size: source.slotSize).image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: source.slotSize))
        }
        completion(.image(image), nil)
    }
}

private enum BatchTestError: LocalizedError {
    case invalidMetadata
    case noRenderedFrame
    case missingStoppedCallback

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "Metadata invariants failed."
        case .noRenderedFrame: return "Playback did not start and render a frame before timeout."
        case .missingStoppedCallback: return "Stop did not emit the stopped terminal callback."
        }
    }
}

private final class RenderProbe: MetricsSink {
    private let lock = NSLock()
    private var renderedFrames = 0

    var renderedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return renderedFrames
    }

    func record(_ event: MetricsEvent) {
        guard case .renderedFrame = event else { return }
        lock.lock()
        renderedFrames += 1
        lock.unlock()
    }
}
