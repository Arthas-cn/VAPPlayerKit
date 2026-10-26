import Foundation

/// 一次音频运行的任务所有者；就绪、取消、定位与错误均在 MainActor 串行裁决。
@MainActor
final class AudioPlaybackRun {
    /// 用于退休集合的唯一身份，不作为资源缓存标识。
    let id = UUID()
    /// 系统音频驱动，直到本运行所有异步调用真实结束才释放。
    let driver: any AudioPlaybackDriver
    /// 跨线程事件入口；停止后 finish，迟到 KVO 和通知无法再进入业务状态机。
    let events: AsyncStream<AudioDriverEvent>.Continuation
    /// 仅通过 asset 和 item 两个门后为 true，停止或失败立即复位。
    private(set) var isReady = false
    /// ready 之后向协调器报告一次失败；准备错误直接恢复准备 continuation。
    private let onFailure: @MainActor (PlaybackError) -> Void
    /// 有界系统事件流；低频状态事件不使用无限缓冲。
    private let stream: AsyncStream<AudioDriverEvent>
    /// 准备等待时长，停止仍须另外等待实际任务返回。
    private let timeout: Duration
    /// 注入的准备计时器。
    private let sleep: AudioPreparationSleep
    /// asset 可播放性检查已经通过。
    private var assetIsPlayable = false
    /// item 的 readyToPlay 已经被观察到。
    private var itemIsReady = false
    /// 准备结果已被协调器接受；此前失败只能归到 prepare，不能抢先发运行期回调。
    private var preparationWasDelivered = false
    /// 已停止运行的原因，覆盖 ready continuation 恢复后但调用者尚未返回的竞态。
    private var terminalError: PlaybackError?
    /// 一次 prepare 的结果等待者，完成或停止时恰好恢复一次。
    private var preparation: CheckedContinuation<Void, any Error>?
    /// 禁止重复启动此内部运行的准备流水线。
    private var hasStartedPreparation = false
    /// 同步停止门；清理后任何迟到事件只被丢弃。
    private var isStopped = false
    /// 当前消费事件的任务，关闭邮箱后仍由 stopAndWait 等待其退出。
    private var eventTask: Task<Void, Never>?
    /// 系统 asset 属性读取任务，取消并不等于其已经返回。
    private var loadTask: Task<Void, Never>?
    /// 可取消超时任务，成功 ready 时即撤销，收尾时确认已经退出。
    private var timeoutTask: Task<Void, Never>?
    /// 系统定位任务；业务回调取消后仍保留，直到系统 finished 返回。
    private var seeks: [UUID: Task<Void, Never>] = [:]
    /// 尚未结算的业务定位回调，与系统任务生命周期分开。
    private var seekCompletions: [UUID: @MainActor (Result<Void, PlaybackError>) -> Void] = [:]

    /// 创建暂停的驱动与邮箱；属性加载和事件消费由 prepare 正式启动。
    init(url: URL, isMuted: Bool, timeout: Duration,
         makeDriver: AudioDriverFactory, sleep: @escaping AudioPreparationSleep,
         onFailure: @escaping @MainActor (PlaybackError) -> Void) {
        let channel = AsyncStream.makeStream(of: AudioDriverEvent.self, bufferingPolicy: .bufferingNewest(8))
        stream = channel.stream
        events = channel.continuation
        driver = makeDriver(url) { channel.continuation.yield($0) }
        driver.isMuted = isMuted
        self.timeout = timeout
        self.sleep = sleep
        self.onFailure = onFailure
    }

    /// 注册一次结果等待并启动受管理任务；必须等两个 ready 门，不以 asset 可读冒充可播。
    func prepare() async throws {
        // 一次运行只允许一次准备，重复调用不是可重试的状态转换。
        guard !hasStartedPreparation, !isStopped else { throw PlaybackError.cancelled }
        hasStartedPreparation = true
        try await withCheckedThrowingContinuation { continuation in
            preparation = continuation
            eventTask = Task { [weak self, stream] in
                for await event in stream {
                    self?.receive(event)
                }
            }
            loadTask = Task { [driver, events] in
                do {
                    try await driver.loadPlayable()
                    events.yield(.assetPlayable)
                } catch {
                    // 驱动保留已分类错误；其他系统错误不把绝对路径透传到业务。
                    let failure = (error as? PlaybackError)
                        ?? .audioFailed(reason: "Embedded audio asset cannot be prepared.")
                    events.yield(.failed(failure))
                }
            }
            timeoutTask = Task { [sleep, timeout, events] in
                do {
                    try await sleep(timeout)
                    try Task.checkCancellation()
                    events.yield(.timedOut)
                } catch {
                    // 计时器取消是准备成功或停止的正常收尾，不生成第二个失败。
                }
            }
        }
    }

    /// 协调器返回 prepare 成功前同步确认本运行仍有效，再启用运行期错误通道。
    func acknowledgePreparation() throws {
        // ready continuation 恢复与调用者重新获得 MainActor 之间，item 仍可能失败。
        guard isReady, !isStopped else { throw terminalError ?? PlaybackError.cancelled }
        preparationWasDelivered = true
    }

    /// 启动一次定位并独立登记业务回调；系统返回 false 不再伪装成功。
    func seek(to seconds: TimeInterval, completion: @MainActor @escaping (Result<Void, PlaybackError>) -> Void) {
        // 停止之后的请求不能重新进入系统播放器。
        guard !isStopped, isReady else {
            completion(.failure(.cancelled))
            return
        }
        let seekID = UUID()
        seekCompletions[seekID] = completion
        seeks[seekID] = Task { [self] in
            // stop 可能先于调度到这个 Task，此时只完成内部收尾。
            guard !isStopped else {
                finishSeek(seekID, finished: false)
                return
            }
            let finished = await driver.seek(to: seconds)
            finishSeek(seekID, finished: finished)
        }
    }

    /// 立即停声并结算取消；保留系统任务，直到 stopAndWait 真正等到其返回。
    func stop() { stop(preparationError: .cancelled) }

    /// 幂等等待本运行所有已发起异步操作；调用者自身取消不会跳过这些 await。
    func stopAndWait() async {
        stop()
        let pendingSeeks = Array(seeks.values)
        await loadTask?.value
        await timeoutTask?.value
        await eventTask?.value
        for task in pendingSeeks { await task.value }
        loadTask = nil
        timeoutTask = nil
        eventTask = nil
        seeks.removeAll()
    }

    /// 将系统事件折叠为准备结果或运行期失败；所有终态在发回调前先关门。
    private func receive(_ event: AudioDriverEvent) {
        // KVO/通知已排队的事件也可能迟到，停止门优先于所有状态转换。
        guard !isStopped else { return }
        switch event {
        // item ready 不能跳过异步 asset 检查。
        case .ready:
            itemIsReady = true
            finishPreparationIfReady()
        // asset 可播放也不能跳过 item 的实际 readiness。
        case .assetPlayable:
            assetIsPlayable = true
            finishPreparationIfReady()
        // 同一个错误通过准备 throw 或运行期回调二选一，禁止双重结算。
        case .failed(let error):
            let reportsRuntimeFailure = preparationWasDelivered
            stop(preparationError: error)
            if reportsRuntimeFailure { onFailure(error) }
        // 调用方取消只影响自己的准备，不能发运行期错误通知。
        case .cancelled:
            stop(preparationError: .cancelled)
        // 已 ready 后迟到的超时无效；prepare 的超时只触发安全收尾。
        case .timedOut:
            guard !isReady else { return }
            stop(preparationError: .audioFailed(reason: "Embedded audio readiness timed out."))
        }
    }

    /// 两个准备门都满足后恢复一次等待者，同时撤销超时计时。
    private func finishPreparationIfReady() {
        // 重复 ready 通知、尚未完成任一门或已经结算时均不产生新结果。
        guard assetIsPlayable, itemIsReady, let preparation else { return }
        self.preparation = nil
        isReady = true
        timeoutTask?.cancel()
        preparation.resume()
    }

    /// 系统定位完成时结算仍存活的业务等待者；停止已结算者只做任务回收。
    private func finishSeek(_ seekID: UUID, finished: Bool) {
        seeks.removeValue(forKey: seekID)
        // stop 已同步取消该回调，系统迟到 finished 不得再唤醒视频。
        guard let completion = seekCompletions.removeValue(forKey: seekID) else { return }
        // 系统 false 包括被其他 seek 打断，不能当成音视频已对齐。
        if finished, !isStopped {
            completion(.success(()))
        } else {
            completion(.failure(.audioFailed(reason: "Embedded audio seek did not finish.")))
        }
    }

    /// 停止实际驱动，并用同一原因结算当前准备与定位，避免真实故障被重入回调改成取消。
    private func stop(preparationError: PlaybackError) {
        // 先置终态，避免同步取消回调重入时再次恢复 continuation。
        guard !isStopped else { return }
        isStopped = true
        terminalError = preparationError
        isReady = false
        events.finish()
        driver.stop()
        loadTask?.cancel()
        timeoutTask?.cancel()
        eventTask?.cancel()
        let pendingPreparation = preparation
        preparation = nil
        pendingPreparation?.resume(throwing: preparationError)
        let callbacks = Array(seekCompletions.values)
        seekCompletions.removeAll()
        // 定位回调可能立即终结上层 session；它必须先看到真实错误，不能抢先用 cancelled 覆盖音轨故障。
        for completion in callbacks { completion(.failure(preparationError)) }
    }
}
