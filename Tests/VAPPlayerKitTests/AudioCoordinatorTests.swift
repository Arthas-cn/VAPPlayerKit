import Foundation
import Testing
@testable import VAPPlayerKit

/// 用手动系统驱动验证音频准备屏障、静音、错误和真实排空，不依赖设备音轨或墙钟。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AudioCoordinatorTests {
    /// item 已 ready 但 asset 属性尚未返回时不能开始，两个门均通过才允许出声。
    @Test func readinessRequiresPlayableAssetAndReadyItem() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let preparing = harness.prepare(coordinator)
        let driver = try await harness.createdDriver()
        await driver.loadStarted.wait()
        driver.emit(.ready)
        coordinator.start()
        #expect(driver.playCount == 0)
        driver.finishLoad.open()
        try await preparing.value
        coordinator.start()
        #expect(driver.playCount == 1)
        harness.finishTimer.open()
        await coordinator.stopAndWait()
    }

    /// asset 检查成功仍须等待 item.readyToPlay，不能只凭可读文件开始播放。
    @Test func playableAssetAloneCannotStartAudio() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let preparing = harness.prepare(coordinator)
        let driver = try await harness.createdDriver()
        driver.finishLoad.open()
        await driver.loadReturned.wait()
        coordinator.start()
        #expect(driver.playCount == 0)
        driver.emit(.ready)
        try await preparing.value
        coordinator.start()
        #expect(driver.playCount == 1)
        harness.finishTimer.open()
        await coordinator.stopAndWait()
    }

    /// 准备之前的静音值用于新驱动，准备后修改则立即更新同一实例。
    @Test func muteBeforePreparationAndDuringPlayback() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        coordinator.isMuted = true
        let driver = try await harness.prepareReady(coordinator)
        #expect(driver.isMuted)
        coordinator.start()
        coordinator.isMuted = false
        #expect(driver.isMuted == false)
        coordinator.pause()
        coordinator.resume()
        #expect(driver.playCount == 2)
        #expect(driver.pauseCount == 1)
        await coordinator.stopAndWait()
    }

    /// 调用方取消准备后，非合作 asset.load 仍须真正返回，stopAndWait 才可完成。
    @Test func cancellationWaitsForRealAssetLoadExit() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let preparing = harness.prepare(coordinator)
        let driver = try await harness.createdDriver()
        await driver.loadStarted.wait()
        preparing.cancel()
        await driver.stopped.wait()
        let waitEntered = AudioTestSignal()
        var drained = false
        let stopping = Task {
            waitEntered.open()
            await coordinator.stopAndWait()
            drained = true
        }
        await waitEntered.wait()
        #expect(drained == false)
        driver.emit(.ready)
        driver.finishLoad.open()
        harness.finishTimer.open()
        await stopping.value
        #expect(failureCode(await preparing.result) == .cancelled)
        #expect(drained)
        #expect(driver.playCount == 0)
    }

    /// 超时必须产生 audioFailed，同时继续持有未退出的系统属性加载。
    @Test func preparationTimeoutDrainsBeforeReturningFailure() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        var runtimeFailures = 0
        coordinator.onFailure = { _ in runtimeFailures += 1 }
        let preparing = harness.prepare(coordinator)
        let driver = try await harness.createdDriver()
        await driver.loadStarted.wait()
        await harness.timerStarted.wait()
        harness.finishTimer.open()
        await driver.stopped.wait()
        #expect(driver.stopCount == 1)
        #expect(runtimeFailures == 0)
        driver.finishLoad.open()
        #expect(failureCode(await preparing.result) == .audioFailed)
        await coordinator.stopAndWait()
    }

    /// 准备中的 item.failed 通过 prepare 抛错，不同时调用运行期 onFailure。
    @Test func itemFailureWhilePreparingThrowsOnlyOnce() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        var runtimeFailures = 0
        coordinator.onFailure = { _ in runtimeFailures += 1 }
        let preparing = harness.prepare(coordinator)
        let driver = try await harness.createdDriver()
        await driver.loadStarted.wait()
        driver.emit(.failed(.audioFailed(reason: "Controlled item failure.")))
        await driver.stopped.wait()
        driver.finishLoad.open()
        harness.finishTimer.open()
        #expect(failureCode(await preparing.result) == .audioFailed)
        #expect(runtimeFailures == 0)
        await coordinator.stopAndWait()
    }

    /// asset 异步读取失败同样结束准备，不能继续等待 item 的 ready 通知。
    @Test func assetLoadFailureClosesReadinessWait() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let preparing = harness.prepare(coordinator)
        let driver = try await harness.createdDriver()
        driver.loadError = .audioFailed(reason: "Controlled asset failure.")
        driver.finishLoad.open()
        await driver.stopped.wait()
        harness.finishTimer.open()
        #expect(failureCode(await preparing.result) == .audioFailed)
        await coordinator.stopAndWait()
    }

    /// 新 prepare 必须先排空旧运行；旧 item 的事件不能给新音轨报告失败或抢先开播。
    @Test func replacementWaitsForOldRunAndRejectsItsLateEvents() async throws {
        let firstCreated = AudioTestSignal()
        let secondCreated = AudioTestSignal()
        let firstTimer = AudioTestSignal()
        let secondTimer = AudioTestSignal()
        var drivers: [ControlledAudioDriver] = []
        let coordinator = AudioCoordinator(makeDriver: { _, events in
            let driver = ControlledAudioDriver(events: events)
            drivers.append(driver)
            // 两个工厂事件分开确认，不能让已打开的第一个闸门冒充新运行已创建。
            if drivers.count == 1 { firstCreated.open() } else { secondCreated.open() }
            return driver
        }, sleep: { _ in
            let timer = drivers.count == 1 ? firstTimer : secondTimer
            await timer.wait()
            try Task.checkCancellation()
        })
        let url = URL(fileURLWithPath: "/controlled-replacement.mp4")
        let firstPrepare = Task { try await coordinator.prepare(url: url, mode: .embedded, containsAudio: true) }
        await firstCreated.wait()
        let first = try #require(drivers.first)
        await first.loadStarted.wait()
        let secondPrepare = Task { try await coordinator.prepare(url: url, mode: .embedded, containsAudio: true) }
        await first.stopped.wait()
        #expect(drivers.count == 1)
        first.finishLoad.open()
        firstTimer.open()
        await secondCreated.wait()
        let second = try #require(drivers.last)
        second.emit(.ready)
        second.finishLoad.open()
        try await secondPrepare.value
        #expect(failureCode(await firstPrepare.result) == .cancelled)
        var failures = 0
        coordinator.onFailure = { _ in failures += 1 }
        first.emit(.failed(.audioFailed(reason: "Late retired item failure.")))
        first.emit(.ready)
        coordinator.start()
        #expect(first.playCount == 0)
        #expect(second.playCount == 1)
        #expect(failures == 0)
        secondTimer.open()
        await coordinator.stopAndWait()
    }

    /// ready 后的状态失败与播放到末尾失败合流为一次回调，停止后的旧事件不再外发。
    @Test func runtimeFailureIsDeliveredOnceAndLateEventsAreIgnored() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let driver = try await harness.prepareReady(coordinator)
        let failed = AudioTestSignal()
        var failures: [PlaybackErrorCode] = []
        coordinator.onFailure = { error in
            failures.append(error.code)
            failed.open()
        }
        coordinator.start()
        driver.emit(.failed(.audioFailed(reason: "Item status failed.")))
        await failed.wait()
        await coordinator.stopAndWait()
        driver.emit(.failed(.audioFailed(reason: "Failed to play to end.")))
        driver.emit(.ready)
        coordinator.resume()
        #expect(failures == [.audioFailed])
        #expect(driver.stopCount == 1)
        #expect(driver.playCount == 1)
    }

    /// seek/rewind 尚未完成时音轨失败，定位回调重入 stop 也必须保留原始故障，不能误报取消。
    @Test(arguments: [true, false])
    func runtimeFailurePreservesErrorWhilePositioning(rewinds: Bool) async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let driver = try await harness.prepareReady(coordinator)
        let completed = AudioTestSignal()
        let expected = PlaybackError.audioFailed(reason: "Controlled runtime failure during positioning.")
        var terminalErrors: [PlaybackError] = []
        coordinator.onFailure = { terminalErrors.append($0) }
        let completion: @MainActor (Result<Void, PlaybackError>) -> Void = { result in
            switch result {
            // 故障发生时系统定位仍被测试闸门阻塞，不应被伪装成成功。
            case .success:
                Issue.record("运行期故障不应将待完成定位结算为成功。")
            // 模拟 PlaybackSession 收到定位错误后立即 tearDown，复现真实的同步重入顺序。
            case .failure(let error):
                terminalErrors.append(error)
                coordinator.stop()
            }
            completed.open()
        }
        // 循环归零与挂起恢复共用定位收尾，两个公开控制入口都须保留故障原因。
        if rewinds {
            coordinator.rewind(completion: completion)
        } else {
            coordinator.seek(to: 2.5, completion: completion)
        }
        await driver.seekStarted.wait()
        driver.emit(.failed(expected))
        await completed.wait()
        #expect(terminalErrors == [expected])
        #expect(driver.stopCount == 1)

        // 业务终态已经交付，系统 seek 的迟到成功仍要真实排空且不能产生第二次结算。
        driver.completeSeek(finished: true)
        await coordinator.stopAndWait()
        #expect(terminalErrors == [expected])
    }

    /// 系统定位的 true/false 分别回传成功和 audioFailed，不忽略系统完成标志。
    @Test(arguments: [true, false])
    func seekPreservesSystemCompletion(finished: Bool) async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let driver = try await harness.prepareReady(coordinator)
        let completed = AudioTestSignal()
        var outcome: Result<Void, PlaybackError>?
        coordinator.seek(to: 2.5) { result in
            outcome = result
            completed.open()
        }
        await driver.seekStarted.wait()
        #expect(driver.seekTimes == [2.5])
        driver.completeSeek(finished: finished)
        await completed.wait()
        #expect(failureCode(try #require(outcome)) == (finished ? nil : .audioFailed))
        await coordinator.stopAndWait()
    }

    /// stop 立即结算定位取消，但在真实 seek 回调到达前，stopAndWait 必须保持等待。
    @Test func stopWaitsForSeekAndSuppressesLateSuccess() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let driver = try await harness.prepareReady(coordinator)
        var outcomes: [Result<Void, PlaybackError>] = []
        coordinator.rewind { outcomes.append($0) }
        await driver.seekStarted.wait()
        #expect(driver.seekTimes == [0])
        coordinator.stop()
        #expect(outcomes.count == 1)
        #expect(failureCode(try #require(outcomes.first)) == .cancelled)
        let waitEntered = AudioTestSignal()
        var drained = false
        let stopping = Task {
            waitEntered.open()
            await coordinator.stopAndWait()
            drained = true
        }
        await waitEntered.wait()
        #expect(drained == false)
        driver.completeSeek(finished: true)
        await stopping.value
        #expect(drained)
        #expect(outcomes.count == 1)
    }

    /// 非法恢复时间在发起系统 seek 之前失败，不悄悄退回零位置。
    @Test(arguments: [Double.nan, Double.infinity, -1])
    func invalidSeekTimeDoesNotReachSystem(seconds: Double) async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        let driver = try await harness.prepareReady(coordinator)
        var outcome: Result<Void, PlaybackError>?
        coordinator.seek(to: seconds) { outcome = $0 }
        #expect(failureCode(try #require(outcome)) == .audioFailed)
        #expect(driver.seekTimes.isEmpty)
        await coordinator.stopAndWait()
    }

    /// 无内嵌声音的模式不创建系统播放器，定位立即成功且不影响视频时间轴。
    @Test(arguments: [AudioMode.muted, .external, .disabled])
    func nonEmbeddedModesDoNotCreateDriver(mode: AudioMode) async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        try await coordinator.prepare(url: harness.url, mode: mode, containsAudio: true)
        var succeeded = false
        coordinator.rewind { succeeded = (try? $0.get()) != nil }
        #expect(succeeded)
        #expect(harness.driver == nil)
        await coordinator.stopAndWait()
    }

    /// embedded 但素材没有音轨时也是合法无声路径，不创建等待 ready 的空播放器。
    @Test func embeddedWithoutTrackDoesNotCreateDriver() async throws {
        let harness = AudioTestHarness()
        let coordinator = harness.makeCoordinator()
        try await coordinator.prepare(url: harness.url, mode: .embedded, containsAudio: false)
        #expect(harness.driver == nil)
        await coordinator.stopAndWait()
    }

    /// 只提取真实 PlaybackError 的代码，成功或意外错误返回 nil 让具体断言失败。
    private func failureCode<Failure: Error>(_ result: Result<Void, Failure>) -> PlaybackErrorCode? {
        switch result {
        // 成功不伪造错误，负向场景会据此失败。
        case .success:
            return nil
        // 未分类错误同样不能被测试辅助方法偷偷当成期望的 audioFailed。
        case .failure(let error):
            return (error as? PlaybackError)?.code
        }
    }
}

/// MainActor 手动闸门，允许测试等待明确事件，不轮询或使用固定 sleep。
@MainActor
private final class AudioTestSignal {
    /// 一次打开后所有后来的等待也立即通过。
    private var isOpen = false
    /// 当前阻塞的测试或假系统操作，打开时恢复一次。
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// 等待测试明确打开闸门；故意不响应取消，用于模拟非合作系统调用。
    func wait() async {
        // 已发生的事件不要求测试注册早于系统操作，避免确认时序偶发失败。
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// 幂等打开闸门并恢复所有已登记等待者。
    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// 为每个测试隔离驱动、准备计时器和假本地 URL，不访问真实媒体系统。
@MainActor
private final class AudioTestHarness {
    /// 仅传给假驱动，文件无需存在且不进行 I/O。
    let url = URL(fileURLWithPath: "/controlled-audio.mp4")
    /// 最近一次构造的假驱动，nil 表示无需音频资源。
    private(set) var driver: ControlledAudioDriver?
    /// 驱动工厂已被调用。
    private let driverCreated = AudioTestSignal()
    /// 准备计时任务已经开始等待。
    let timerStarted = AudioTestSignal()
    /// 测试打开后计时器返回，取消状态由真实 Task.checkCancellation 判断。
    let finishTimer = AudioTestSignal()

    /// 创建注入同一测试闸门的协调器，不替换生产状态机。
    func makeCoordinator() -> AudioCoordinator {
        AudioCoordinator(makeDriver: { [self] _, events in
            let driver = ControlledAudioDriver(events: events)
            self.driver = driver
            driverCreated.open()
            return driver
        }, sleep: { [self] _ in
            timerStarted.open()
            await finishTimer.wait()
            try Task.checkCancellation()
        })
    }

    /// 返回可由测试取消并 await 的完整准备任务。
    func prepare(_ coordinator: AudioCoordinator) -> Task<Void, any Error> {
        Task { try await coordinator.prepare(url: url, mode: .embedded, containsAudio: true) }
    }

    /// 等待工厂创建驱动后读取它，避免对 Task 调度顺序作假设。
    func createdDriver() async throws -> ControlledAudioDriver {
        await driverCreated.wait()
        return try #require(driver)
    }

    /// 共同前置条件：放行两个真实准备门，撤销计时等待后返回已 ready 的假驱动。
    func prepareReady(_ coordinator: AudioCoordinator) async throws -> ControlledAudioDriver {
        let preparing = prepare(coordinator)
        let driver = try await createdDriver()
        driver.emit(.ready)
        driver.finishLoad.open()
        try await preparing.value
        finishTimer.open()
        return driver
    }
}

/// 模拟 AVFoundation 可延迟完成的 load/seek；stop 不自动放行，验证真实排空。
@MainActor
private final class ControlledAudioDriver: AudioPlaybackDriver {
    /// 注入的邮箱入口，测试可模拟 readiness、状态失败和通知失败。
    private let events: @Sendable (AudioDriverEvent) -> Void
    /// 记录协调器写入的实例静音值。
    var isMuted = false
    /// 系统开始播放的调用次数。
    private(set) var playCount = 0
    /// 保留当前位置暂停的调用次数，不包含 stop。
    private(set) var pauseCount = 0
    /// 实际系统关门的次数，期望幂等为一次。
    private(set) var stopCount = 0
    /// 每个真实发起的定位时间，便于核实 rewind 为零。
    private(set) var seekTimes: [TimeInterval] = []
    /// 放行属性读取后要抛出的受控错误；nil 表示该读取成功。
    var loadError: PlaybackError?
    /// asset 属性读取已进入异步系统边界。
    let loadStarted = AudioTestSignal()
    /// 控制 asset 读取实际返回，故意允许忽略 Task 取消。
    let finishLoad = AudioTestSignal()
    /// asset 读取已走到返回前，测试可确定其已经放行。
    let loadReturned = AudioTestSignal()
    /// 驱动已接受停止，底层读取与定位仍可继续挂起。
    let stopped = AudioTestSignal()
    /// 系统已经接受定位请求。
    let seekStarted = AudioTestSignal()
    /// 已发起但尚未真实完成的定位结果等待者。
    private var seekWaiters: [CheckedContinuation<Bool, Never>] = []

    /// 保存生产运行传入的事件邮箱，不引用协调器本身。
    init(events: @escaping @Sendable (AudioDriverEvent) -> Void) { self.events = events }

    /// 模拟不能立刻取消的 asset 属性加载，只有测试放行才实际返回。
    func loadPlayable() async throws {
        loadStarted.open()
        await finishLoad.wait()
        loadReturned.open()
        // 测试在放行前决定系统读取结果，不以取消自动替代真实完成。
        if let loadError { throw loadError }
    }

    /// 记录播放调用，测试用它检查 ready 与迟到回调保护。
    func play() { playCount += 1 }

    /// 记录普通暂停，与停止清理计数区分。
    func pause() { pauseCount += 1 }

    /// 等待测试提供系统 finished 标志，不因 Task.cancel 提前完成。
    func seek(to seconds: TimeInterval) async -> Bool {
        seekTimes.append(seconds)
        return await withCheckedContinuation { continuation in
            seekWaiters.append(continuation)
            seekStarted.open()
        }
    }

    /// 模拟同步停声但异步操作仍在收尾，测试之后单独放行它们。
    func stop() {
        stopCount += 1
        stopped.open()
    }

    /// 发送真实驱动可产生的纯值事件，停止后的发送应被运行邮箱丢弃。
    func emit(_ event: AudioDriverEvent) { events(event) }

    /// 完成最早一次系统定位，保留成功或失败标志。
    func completeSeek(finished: Bool) {
        // 缺少请求属于测试编排错误，不能用强制解包制造无关崩溃。
        guard !seekWaiters.isEmpty else {
            Issue.record("没有待完成的音频定位。")
            return
        }
        seekWaiters.removeFirst().resume(returning: finished)
    }
}

/// 使用 bundle 内真实音轨验证 AVFoundation 的准备、定位和排空，不替宿主配置音频会话。
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AudioCoordinatorIntegrationTests {
    /// 曾卡在 preparing 的 1/10/17 必须通过真实 item readiness、完成系统 seek，并排空无故障。
    @Test(arguments: ["1.mp4", "10.mp4", "17.mp4"])
    func embeddedFixturePreparesSeeksAndDrains(fileName: String) async throws {
        let url = VAPFixture.url(fileName)
        let metadata = try await PlayerView.inspect(
            url: url,
            options: PlaybackOptions(assetMode: .ordinaryVideo)
        )
        // 必须检查实际容器，避免素材没有音轨时走无声旁路却误报真实驱动通过。
        try #require(metadata.containsAudio, "\(fileName) 必须包含内嵌音轨。")
        try #require(metadata.duration.isFinite && metadata.duration > 0)

        let coordinator = AudioCoordinator()
        var runtimeFailures: [PlaybackError] = []
        coordinator.onFailure = { runtimeFailures.append($0) }
        do {
            try await coordinator.prepare(url: url, mode: .embedded, containsAudio: metadata.containsAudio)
            let result: Result<Void, PlaybackError> = await withCheckedContinuation { continuation in
                coordinator.seek(to: min(0.25, metadata.duration / 2)) { result in
                    continuation.resume(returning: result)
                }
            }
            try result.get()
        } catch {
            // 失败也等待真实系统任务退出，再把原始错误交给测试框架，不能用取消或静音掩盖故障。
            await coordinator.stopAndWait()
            throw error
        }
        await coordinator.stopAndWait()
        #expect(runtimeFailures.isEmpty)
    }
}
