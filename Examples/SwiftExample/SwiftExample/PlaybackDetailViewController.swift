import UIKit
import VAPPlayerKit

final class PlaybackDetailViewController: UIViewController {
    private let fixture: VAPFixture
    private var animatedGiftIndex: Int
    private var stillGiftIndex: Int
    private let playerView = PlayerView()
    private let diagnostics = PlaybackDiagnostics()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let previewCard = UIView()
    private let stateLabel = InsetsLabel()
    private let metadataLabel = UILabel()
    private let metricsLabel = UILabel()
    private let consoleView = UITextView()
    private let contentModeControl = UISegmentedControl(items: ["Fit", "Fill", "Stretch"])
    private let loopControl = UISegmentedControl(items: ["1×", "2×", "∞"])
    private let audioControl = UISegmentedControl(items: ["静音", "内嵌", "外部", "禁用"])
    private let backgroundControl = UISegmentedControl(items: ["挂起", "停止"])
    private let dynamicImageControl = UISegmentedControl(items: ["静图", "动图"])
    private let textOverflowControl = UISegmentedControl(items: ["截断", "跑马灯"])
    private let marqueeSpeedControl = UISegmentedControl(items: ["20", "40", "80"])
    private let marqueeDelayControl = UISegmentedControl(items: ["0s", "0.6s", "1.2s"])
    private let previousGiftButton = UIButton(type: .system)
    private let nextGiftButton = UIButton(type: .system)
    private let giftNameLabel = UILabel()
    private let previousTextButton = UIButton(type: .system)
    private let nextTextButton = UIButton(type: .system)
    private let textSampleLabel = UILabel()
    private let clearsSwitch = UISwitch()
    private var operationTask: Task<Void, Never>?
    private var currentMetadata: AssetMetadata?
    private var isAutomatedRun = false
    private var currentDidStart = false
    private var currentFailure: Error?
    private var currentFinishReason: FinishReason?
    private var hasAutoPlayed = false
    private var replacementTextIndex = 0

    init(fixture: VAPFixture) {
        self.fixture = fixture
        self.animatedGiftIndex = GiftCatalog.randomGiftIndex(policy: .animatedOnly)
        self.stillGiftIndex = GiftCatalog.randomGiftIndex(policy: .stillOnly)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        operationTask?.cancel()
    }

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

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasAutoPlayed else { return }
        hasAutoPlayed = true
        stateLabel.text = "PREPARING"
        diagnostics.append("ACTION", "auto play on detail entry")
        playerView.play(url: fixture.url, options: currentOptions())
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            operationTask?.cancel()
            playerView.stop()
            _ = diagnostics.persist(fixture: fixture)
        }
    }

    private func configureNavigation() {
        title = "Playback Lab"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = UIColor(red: 0.03, green: 0.04, blue: 0.065, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"),
            style: .plain,
            target: self,
            action: #selector(shareReport)
        )
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "detail.shareReport"
    }

    private func configureHierarchy() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 16
        view.addSubview(scrollView)
        scrollView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -28)
        ])

        configurePreviewCard()
        contentStack.addArrangedSubview(makeAssetHeader())
        contentStack.addArrangedSubview(previewCard)
        contentStack.addArrangedSubview(makeOptionsCard())
        contentStack.addArrangedSubview(makeGiftSwitcherCard())
        contentStack.addArrangedSubview(makeTextSampleCard())
        contentStack.addArrangedSubview(makeControlsCard())
        contentStack.addArrangedSubview(makeDiagnosticsCard())
    }

    private func configurePreviewCard() {
        previewCard.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        previewCard.layer.cornerRadius = 22
        previewCard.layer.cornerCurve = .continuous
        previewCard.clipsToBounds = true
        previewCard.heightAnchor.constraint(equalToConstant: 360).isActive = true

        let checker = CheckerboardView()
        checker.translatesAutoresizingMaskIntoConstraints = false
        playerView.translatesAutoresizingMaskIntoConstraints = false
        playerView.accessibilityIdentifier = "detail.player"
        stateLabel.translatesAutoresizingMaskIntoConstraints = false
        stateLabel.text = "IDLE"
        stateLabel.font = .monospacedSystemFont(ofSize: 11, weight: .bold)
        stateLabel.textColor = .white
        stateLabel.backgroundColor = UIColor.black.withAlphaComponent(0.62)
        stateLabel.layer.cornerRadius = 9
        stateLabel.clipsToBounds = true
        stateLabel.accessibilityIdentifier = "detail.state"
        previewCard.addSubview(checker)
        previewCard.addSubview(playerView)
        previewCard.addSubview(stateLabel)
        NSLayoutConstraint.activate([
            checker.topAnchor.constraint(equalTo: previewCard.topAnchor),
            checker.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            checker.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            checker.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
            playerView.topAnchor.constraint(equalTo: previewCard.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: previewCard.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: previewCard.bottomAnchor),
            stateLabel.topAnchor.constraint(equalTo: previewCard.topAnchor, constant: 12),
            stateLabel.leadingAnchor.constraint(equalTo: previewCard.leadingAnchor, constant: 12)
        ])
    }

    private func makeAssetHeader() -> UIView {
        let eyebrow = UILabel()
        eyebrow.text = fixture.looksLikeMedia ? "LOCAL MEDIA FIXTURE" : "NEGATIVE FIXTURE"
        eyebrow.font = .systemFont(ofSize: 11, weight: .bold)
        eyebrow.textColor = UIColor(red: 0.42, green: 0.82, blue: 1, alpha: 1)
        let name = UILabel()
        name.text = fixture.shortIdentifier
        name.font = .monospacedSystemFont(ofSize: 19, weight: .semibold)
        name.textColor = .white
        name.adjustsFontSizeToFitWidth = true
        let detail = UILabel()
        detail.text = "\(fixture.formattedSize) · 本地文件 · 已自动播放，可用下方控制测试"
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = UIColor(white: 0.62, alpha: 1)
        let stack = UIStackView(arrangedSubviews: [eyebrow, name, detail])
        stack.axis = .vertical
        stack.spacing = 5
        return stack
    }

    private func makeOptionsCard() -> UIView {
        contentModeControl.selectedSegmentIndex = 0
        loopControl.selectedSegmentIndex = 2
        audioControl.selectedSegmentIndex = 1
        backgroundControl.selectedSegmentIndex = 0
        dynamicImageControl.selectedSegmentIndex = 1
        textOverflowControl.selectedSegmentIndex = 1
        marqueeSpeedControl.selectedSegmentIndex = 2
        marqueeDelayControl.selectedSegmentIndex = 1
        clearsSwitch.isOn = true
        [
            contentModeControl,
            loopControl,
            audioControl,
            backgroundControl,
            dynamicImageControl,
            textOverflowControl,
            marqueeSpeedControl,
            marqueeDelayControl
        ].forEach {
            $0.selectedSegmentTintColor = UIColor(red: 0.15, green: 0.43, blue: 0.62, alpha: 1)
        }
        contentModeControl.accessibilityIdentifier = "detail.contentMode"
        loopControl.accessibilityIdentifier = "detail.loopCount"
        audioControl.accessibilityIdentifier = "detail.audioMode"
        backgroundControl.accessibilityIdentifier = "detail.backgroundPolicy"
        dynamicImageControl.accessibilityIdentifier = "detail.dynamicImagePlayback"
        textOverflowControl.accessibilityIdentifier = "detail.textOverflow"
        marqueeSpeedControl.accessibilityIdentifier = "detail.marqueeSpeed"
        marqueeDelayControl.accessibilityIdentifier = "detail.marqueeDelay"
        clearsSwitch.accessibilityIdentifier = "detail.clearsAfterFinish"
        dynamicImageControl.addTarget(self, action: #selector(dynamicImageModeChanged), for: .valueChanged)
        return makeCard(title: "播放参数", accessory: "切换参数需要点击播放才生效", rows: [
            makeOptionRow(title: "画布模式", control: contentModeControl),
            makeOptionRow(title: "循环次数", control: loopControl),
            makeOptionRow(title: "音频策略", control: audioControl),
            makeOptionRow(title: "离屏策略", control: backgroundControl),
            makeOptionRow(title: "槽位图片", control: dynamicImageControl),
            makeOptionRow(title: "文字溢出", control: textOverflowControl),
            makeOptionRow(title: "跑马灯速度", control: marqueeSpeedControl),
            makeOptionRow(title: "起步停顿", control: marqueeDelayControl),
            makeOptionRow(title: "结束清屏", control: clearsSwitch)
        ])
    }

    private func makeGiftSwitcherCard() -> UIView {
        previousGiftButton.configuration = giftSwitcherConfiguration("上一张", icon: "chevron.left")
        nextGiftButton.configuration = giftSwitcherConfiguration("下一张", icon: "chevron.right")
        previousGiftButton.accessibilityIdentifier = "detail.animated.previous"
        nextGiftButton.accessibilityIdentifier = "detail.animated.next"
        previousGiftButton.addTarget(self, action: #selector(previousGiftTapped), for: .touchUpInside)
        nextGiftButton.addTarget(self, action: #selector(nextGiftTapped), for: .touchUpInside)
        giftNameLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        giftNameLabel.textColor = UIColor(red: 0.54, green: 0.9, blue: 0.75, alpha: 1)
        giftNameLabel.textAlignment = .center
        giftNameLabel.lineBreakMode = .byTruncatingMiddle
        giftNameLabel.accessibilityIdentifier = "detail.animated.name"
        refreshGiftName()
        let row = UIStackView(arrangedSubviews: [previousGiftButton, giftNameLabel, nextGiftButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        giftNameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previousGiftButton.setContentHuggingPriority(.required, for: .horizontal)
        nextGiftButton.setContentHuggingPriority(.required, for: .horizontal)
        return makeCard(title: "切换图片", rows: [row])
    }

    private func makeTextSampleCard() -> UIView {
        previousTextButton.configuration = giftSwitcherConfiguration("上一组", icon: "chevron.left")
        nextTextButton.configuration = giftSwitcherConfiguration("下一组", icon: "chevron.right")
        previousTextButton.accessibilityIdentifier = "detail.text.previous"
        nextTextButton.accessibilityIdentifier = "detail.text.next"
        previousTextButton.addTarget(self, action: #selector(previousTextTapped), for: .touchUpInside)
        nextTextButton.addTarget(self, action: #selector(nextTextTapped), for: .touchUpInside)
        textSampleLabel.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        textSampleLabel.textColor = UIColor(red: 0.54, green: 0.9, blue: 0.75, alpha: 1)
        textSampleLabel.textAlignment = .center
        textSampleLabel.lineBreakMode = .byTruncatingMiddle
        textSampleLabel.accessibilityIdentifier = "detail.text.name"
        refreshTextSampleName()
        let row = UIStackView(arrangedSubviews: [previousTextButton, textSampleLabel, nextTextButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        textSampleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previousTextButton.setContentHuggingPriority(.required, for: .horizontal)
        nextTextButton.setContentHuggingPriority(.required, for: .horizontal)
        return makeCard(title: "切换替换文字", rows: [row])
    }

    private func giftSwitcherConfiguration(_ title: String, icon: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 4
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.72, alpha: 1)
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        return configuration
    }

    private func refreshGiftName() {
        giftNameLabel.text = usesAnimatedGift
            ? GiftCatalog.animatedGiftDisplayName(at: animatedGiftIndex)
            : GiftCatalog.stillGiftDisplayName(at: stillGiftIndex)
    }

    private func refreshTextSampleName() {
        textSampleLabel.text = GiftCatalog.replacementSampleDisplayName(at: replacementTextIndex)
    }

    private func makeControlsCard() -> UIView {
        let prepare = makeButton("Prepare", icon: "doc.text.magnifyingglass", action: #selector(prepareTapped), id: "detail.prepare")
        let play = makeButton("Play", icon: "play.fill", action: #selector(playTapped), id: "detail.play", prominent: true)
        let pause = makeButton("Pause", icon: "pause.fill", action: #selector(pauseTapped), id: "detail.pause")
        let resume = makeButton("Resume", icon: "forward.fill", action: #selector(resumeTapped), id: "detail.resume")
        let stop = makeButton("Stop", icon: "stop.fill", action: #selector(stopTapped), id: "detail.stop")
        let clear = makeButton("Clear", icon: "trash", action: #selector(clearTapped), id: "detail.clear")
        let rows = [
            makeButtonRow([prepare, play]),
            makeButtonRow([pause, resume]),
            makeButtonRow([stop, clear])
        ]
        let auto = makeButton("运行自动真机冒烟测试", icon: "checkmark.seal.fill", action: #selector(autoTestTapped), id: "detail.autoTest", prominent: true)
        return makeCard(title: "控制矩阵", rows: rows + [auto])
    }

    private func makeDiagnosticsCard() -> UIView {
        metadataLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        metadataLabel.textColor = UIColor(white: 0.78, alpha: 1)
        metadataLabel.numberOfLines = 0
        metadataLabel.text = "Metadata 尚未解析"
        metadataLabel.accessibilityIdentifier = "detail.metadata"
        metricsLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        metricsLabel.textColor = UIColor(red: 0.52, green: 0.91, blue: 0.73, alpha: 1)
        metricsLabel.numberOfLines = 0
        metricsLabel.text = "Decoded 0  Rendered 0  Dropped 0"
        metricsLabel.accessibilityIdentifier = "detail.metrics"
        consoleView.backgroundColor = UIColor(red: 0.025, green: 0.03, blue: 0.045, alpha: 1)
        consoleView.textColor = UIColor(white: 0.72, alpha: 1)
        consoleView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        consoleView.isEditable = false
        consoleView.layer.cornerRadius = 12
        consoleView.heightAnchor.constraint(equalToConstant: 220).isActive = true
        consoleView.accessibilityIdentifier = "detail.console"
        return makeCard(title: "实时诊断", rows: [metadataLabel, metricsLabel, consoleView])
    }

    private func configurePlayer() {
        playerView.delegate = self
        playerView.dynamicContentProvider = self
        playerView.metricsSink = diagnostics
    }

    private func bindDiagnostics() {
        diagnostics.onUpdate = { [weak self] snapshot in
            self?.metricsLabel.text = snapshot.summary
            self?.consoleView.text = snapshot.log
            if let console = self?.consoleView, !snapshot.log.isEmpty {
                console.scrollRangeToVisible(NSRange(location: max(0, snapshot.log.utf16.count - 1), length: 1))
            }
        }
    }

    private func currentOptions(contentMode: UIView.ContentMode? = nil, audioMode: AudioMode? = nil) -> PlaybackOptions {
        let options = PlaybackOptions.defaultOptions
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

    @objc private func prepareTapped() {
        cancelOperation()
        operationTask = Task { @MainActor [weak self] in await self?.prepareCurrent() }
    }

    @objc private func playTapped() {
        cancelOperation()
        stateLabel.text = "PREPARING"
        diagnostics.append("ACTION", "play")
        playerView.play(url: fixture.url, options: currentOptions())
    }

    @objc private func previousGiftTapped() {
        cycleGift(by: -1)
    }

    @objc private func nextGiftTapped() {
        cycleGift(by: 1)
    }

    @objc private func previousTextTapped() {
        cycleReplacementText(by: -1)
    }

    @objc private func nextTextTapped() {
        cycleReplacementText(by: 1)
    }

    @objc private func dynamicImageModeChanged() {
        refreshGiftName()
    }

    private var usesAnimatedGift: Bool {
        dynamicImageControl.selectedSegmentIndex == 1
    }

    private var currentImagePolicy: GiftCatalog.ImagePolicy {
        usesAnimatedGift ? .animatedOnly : .stillOnly
    }

    private var currentImageIndex: Int {
        usesAnimatedGift ? animatedGiftIndex : stillGiftIndex
    }

    private func cycleGift(by delta: Int) {
        if usesAnimatedGift {
            let count = max(GiftCatalog.animatedGiftCount(), 1)
            animatedGiftIndex = (animatedGiftIndex + delta % count + count) % count
        } else {
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

    private func cycleReplacementText(by delta: Int) {
        let count = GiftCatalog.replacementSampleCount()
        replacementTextIndex = (replacementTextIndex + delta % count + count) % count
        refreshTextSampleName()
        diagnostics.append("ACTION", "switch text \(GiftCatalog.replacementSampleDisplayName(at: replacementTextIndex))")
        cancelOperation()
        stateLabel.text = "PREPARING"
        playerView.play(url: fixture.url, options: currentOptions())
    }

    @objc private func pauseTapped() {
        playerView.pause()
        stateLabel.text = "PAUSED"
        diagnostics.append("ACTION", "pause")
    }

    @objc private func resumeTapped() {
        playerView.resume()
        stateLabel.text = "PLAYING"
        diagnostics.append("ACTION", "resume")
    }

    @objc private func stopTapped() {
        cancelOperation()
        playerView.stop()
        stateLabel.text = "STOPPED"
        diagnostics.append("ACTION", "stop")
    }

    @objc private func clearTapped() {
        cancelOperation()
        playerView.clear()
        stateLabel.text = "CLEARED"
        diagnostics.append("ACTION", "clear")
    }

    @objc private func autoTestTapped() {
        cancelOperation()
        isAutomatedRun = true
        operationTask = Task { @MainActor [weak self] in await self?.runAutomatedSmokeTest() }
    }

    private func prepareCurrent() async {
        stateLabel.text = "PREPARING"
        diagnostics.append("ACTION", "prepare")
        do {
            let metadata = try await playerView.prepare(url: fixture.url, options: currentOptions())
            display(metadata)
            stateLabel.text = "READY"
            diagnostics.append("PASS", "prepare completed")
        } catch {
            stateLabel.text = "FAILED"
            diagnostics.append("ERROR", error.localizedDescription)
        }
    }

    private func runAutomatedSmokeTest() async {
        defer {
            isAutomatedRun = false
            _ = diagnostics.persist(fixture: fixture)
        }
        diagnostics.append("TEST", "automated smoke test started")
        playerView.clear()
        do {
            let initialMetadata = try await playerView.prepare(url: fixture.url, options: currentOptions())
            display(initialMetadata)
            guard initialMetadata.frameCount > 0, initialMetadata.duration > 0,
                  initialMetadata.canvasSize.width > 0, initialMetadata.canvasSize.height > 0 else {
                throw SmokeTestError.invalidMetadata
            }
            diagnostics.append("PASS", "metadata invariants")
        } catch {
            if !fixture.looksLikeMedia {
                stateLabel.text = "EXPECTED FAIL"
                diagnostics.append("PASS", "negative fixture rejected: \(error.localizedDescription)")
            } else {
                stateLabel.text = "TEST FAILED"
                diagnostics.append("ERROR", "prepare: \(error.localizedDescription)")
            }
            return
        }

        let modes: [(String, UIView.ContentMode)] = [
            ("AspectFit", .scaleAspectFit),
            ("AspectFill", .scaleAspectFill),
            ("ScaleToFill", .scaleToFill)
        ]
        for (index, mode) in modes.enumerated() {
            guard !Task.isCancelled else { return }
            diagnostics.append("TEST", "case \(index + 1): \(mode.0)")
            currentDidStart = false
            currentFailure = nil
            currentFinishReason = nil
            let audio: AudioMode = index == modes.count - 1 && currentMetadata?.containsAudio == true ? .embedded : .muted
            let options = currentOptions(contentMode: mode.1, audioMode: audio)
            options.loopCount = 0
            options.clearsAfterFinish = false
            do {
                _ = try await playerView.prepare(url: fixture.url, options: options)
                let initialRenderedCount = diagnostics.renderedFrameCount
                playerView.play(url: fixture.url, options: options)
                try await waitForPlaybackEvidence(after: initialRenderedCount, timeout: 3)
                playerView.pause()
                stateLabel.text = "PAUSED"
                diagnostics.append("TEST", "pause")
                try await Task.sleep(nanoseconds: 250_000_000)
                let pausedRenderedCount = diagnostics.renderedFrameCount
                playerView.resume()
                stateLabel.text = "PLAYING"
                diagnostics.append("TEST", "resume")
                try await waitForRenderedFrame(after: pausedRenderedCount, timeout: 3)
                playerView.stop()
                guard currentFinishReason == .stopped else { throw SmokeTestError.missingStoppedCallback }
                diagnostics.append("PASS", "\(mode.0) lifecycle")
            } catch is CancellationError {
                return
            } catch {
                diagnostics.append("ERROR", "\(mode.0): \(error.localizedDescription)")
                stateLabel.text = "TEST FAILED"
                return
            }
        }
        playerView.clear()
        stateLabel.text = "TEST PASSED"
        diagnostics.append("PASS", "all smoke cases completed")
    }

    private func waitForPlaybackEvidence(after renderedCount: Int, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let currentFailure { throw currentFailure }
            if currentDidStart, diagnostics.renderedFrameCount > renderedCount { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SmokeTestError.playbackEvidenceTimeout
    }

    private func waitForRenderedFrame(after renderedCount: Int, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let currentFailure { throw currentFailure }
            if diagnostics.renderedFrameCount > renderedCount { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw SmokeTestError.renderTimeout
    }

    private func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        isAutomatedRun = false
    }

    private func display(_ metadata: AssetMetadata) {
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

    @objc private func shareReport() {
        let report = diagnostics.reportText(fixture: fixture)
        let controller = UIActivityViewController(activityItems: [report], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(controller, animated: true)
    }

    private func makeCard(title: String, accessory: String? = nil, rows: [UIView]) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 15, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header: UIView
        if let accessory {
            let hintLabel = UILabel()
            hintLabel.text = accessory
            hintLabel.font = .systemFont(ofSize: 11, weight: .regular)
            hintLabel.textColor = UIColor(white: 0.52, alpha: 1)
            hintLabel.textAlignment = .right
            hintLabel.numberOfLines = 2
            hintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [titleLabel, hintLabel])
            row.axis = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            header = row
        } else {
            header = titleLabel
        }
        let stack = UIStackView(arrangedSubviews: [header] + rows)
        stack.axis = .vertical
        stack.spacing = 12
        let card = UIView()
        card.backgroundColor = UIColor(red: 0.07, green: 0.08, blue: 0.12, alpha: 1)
        card.layer.cornerRadius = 18
        card.layer.cornerCurve = .continuous
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16)
        ])
        return card
    }

    private func makeOptionRow(title: String, control: UIView) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = UIColor(white: 0.72, alpha: 1)
        label.setContentHuggingPriority(.required, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return stack
    }

    private func makeButtonRow(_ buttons: [UIButton]) -> UIView {
        let row = UIStackView(arrangedSubviews: buttons)
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 10
        return row
    }

    private func makeButton(
        _ title: String,
        icon: String,
        action: Selector,
        id: String,
        prominent: Bool = false
    ) -> UIButton {
        var configuration: UIButton.Configuration = prominent ? .filled() : .tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 7
        configuration.cornerStyle = .medium
        configuration.baseBackgroundColor = UIColor(red: 0.12, green: 0.48, blue: 0.72, alpha: 1)
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)
        button.accessibilityIdentifier = id
        return button
    }
}

extension PlaybackDetailViewController: PlayerDelegate {
    func playerDidStart(_ player: PlayerView) {
        currentDidStart = true
        stateLabel.text = "PLAYING"
        diagnostics.append("CALLBACK", "didStart")
    }

    func player(_ player: PlayerView, didUpdate metadata: AssetMetadata) {
        display(metadata)
        diagnostics.append("CALLBACK", "metadata resolved")
    }

    func playerDidFinish(_ player: PlayerView, reason: FinishReason) {
        currentFinishReason = reason
        stateLabel.text = "FINISHED"
        diagnostics.append("CALLBACK", "finish: \(String(describing: reason))")
    }

    func player(_ player: PlayerView, didFail error: Error) {
        currentFailure = error
        stateLabel.text = fixture.looksLikeMedia ? "FAILED" : "EXPECTED FAIL"
        diagnostics.append(fixture.looksLikeMedia ? "ERROR" : "PASS", error.localizedDescription)
    }
}

extension PlaybackDetailViewController: DynamicContentProvider {
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        diagnostics.append(
            "DYNAMIC",
            "resolve \(tag) (\(source.kind == .text ? "txt" : "img")), \(Int(source.slotSize.width))×\(Int(source.slotSize.height))"
                + (source.kind == .text
                    ? ", \(GiftCatalog.replacementSampleDisplayName(at: replacementTextIndex))"
                    : ", \(giftNameLabel.text ?? "")")
        )
        completion(GiftCatalog.content(
            for: source,
            imagePolicy: currentImagePolicy,
            imageIndex: currentImageIndex,
            replacementIndex: replacementTextIndex
        ), nil)
    }
}

private enum SmokeTestError: LocalizedError {
    case invalidMetadata
    case playbackEvidenceTimeout
    case renderTimeout
    case missingStoppedCallback

    var errorDescription: String? {
        switch self {
        case .invalidMetadata: return "Metadata invariants failed."
        case .playbackEvidenceTimeout: return "Playback did not start and render a frame before timeout."
        case .renderTimeout: return "Playback did not render a frame after resume before timeout."
        case .missingStoppedCallback: return "Stop did not emit the stopped terminal callback."
        }
    }
}

private final class CheckerboardView: UIView {
    override func draw(_ rect: CGRect) {
        let side: CGFloat = 18
        let rows = Int(ceil(rect.height / side))
        let columns = Int(ceil(rect.width / side))
        for row in 0..<rows {
            for column in 0..<columns {
                let light = (row + column).isMultiple(of: 2)
                (light ? UIColor(white: 0.16, alpha: 1) : UIColor(white: 0.11, alpha: 1)).setFill()
                UIRectFill(CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side))
            }
        }
    }
}

private final class InsetsLabel: UILabel {
    private let insets = UIEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: insets)) }
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}
