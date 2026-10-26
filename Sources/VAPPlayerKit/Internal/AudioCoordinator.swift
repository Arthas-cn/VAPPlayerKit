import Foundation

/// 管理内嵌音频的一次运行和退休任务；视频状态机仍由 PlaybackSession 拥有。
@MainActor
final class AudioCoordinator {
    /// 准备前设置也有效；更新只作用本实例，不修改全局音频会话。
    var isMuted = false {
        didSet { current?.driver.isMuted = isMuted }
    }
    /// ready 之后的音频故障；准备错误通过 prepare 抛出，不重复回调。
    var onFailure: (@MainActor (PlaybackError) -> Void)?
    /// 生产环境创建 AVFoundation 驱动，测试可注入受控驱动。
    private let makeDriver: AudioDriverFactory
    /// 准备截止时间；只约束等待 ready，不把超时误当底层已经退出。
    private let preparationTimeout: Duration
    /// 可取消的计时依赖；测试用手动闸门推进，不等待墙钟。
    private let sleep: AudioPreparationSleep
    /// 递增操作代次，防止等待旧清理的 prepare 迟到安装。
    private var generation: UInt64 = 0
    /// 当前可用或正在准备的运行；停止后立即转入退休集合。
    private var current: AudioPlaybackRun?
    /// 已请求停止但尚未真正退出的运行任务，必须由 stopAndWait 等待。
    private var retirements: [UUID: Task<Void, Never>] = [:]
    /// 当前请求是否本就没有音频；此类定位立即成功，不创建驱动。
    private var bypassesAudio = true

    /// 注入音频驱动和计时依赖；默认等待 ready 最多十五秒。
    init(
        preparationTimeout: Duration = .seconds(15),
        makeDriver: @escaping AudioDriverFactory = { url, events in
            AVFoundationAudioDriver(url: url, events: events)
        },
        sleep: @escaping AudioPreparationSleep = { duration in
            try await Task.sleep(for: duration)
        }
    ) {
        self.preparationTimeout = preparationTimeout
        self.makeDriver = makeDriver
        self.sleep = sleep
    }

    /// 调用方遗漏显式停止时也同步关门；严格排空仍必须由 owner 调用 stopAndWait。
    isolated deinit { current?.stop() }

    /// 等待 asset 可播放及 item.readyToPlay；取消抛 cancelled，其余准备失败抛 audioFailed。
    /// 退出前等待本次已发起操作收口，不能以移除观察者代替异步任务排空。
    func prepare(url: URL, mode: AudioMode, containsAudio: Bool) async throws {
        generation &+= 1
        let operationGeneration = generation
        retireCurrent()
        await waitForRetirements()
        // await 期间新的准备或停止已取代本调用，旧调用不能再次安装播放器。
        guard generation == operationGeneration, !Task.isCancelled else {
            throw PlaybackError.cancelled
        }
        bypassesAudio = mode != .embedded || !containsAudio
        // 三种无内嵌声音策略和无音轨素材不创建 AVPlayer，也不占准备等待。
        guard !bypassesAudio else { return }
        let run = AudioPlaybackRun(
            url: url,
            isMuted: isMuted,
            timeout: preparationTimeout,
            makeDriver: makeDriver,
            sleep: sleep,
            onFailure: { [weak self] error in
                self?.failCurrent(error, generation: operationGeneration)
            }
        )
        current = run
        let cancellation = run.events
        do {
            try await withTaskCancellationHandler {
                try await run.prepare()
            } onCancel: {
                // 取消处理器不跨隔离访问播放器，只向本次运行的有界邮箱投递。
                cancellation.yield(.cancelled)
            }
            // ready 和任务取消可以同拍到达，返回成功之前仍需检查调用代次。
            guard generation == operationGeneration, current === run, !Task.isCancelled else {
                throw PlaybackError.cancelled
            }
            try run.acknowledgePreparation()
        } catch {
            // 仅退休自己安装的运行，不能让旧准备的 catch 停掉后来的新播放器。
            if current === run { retireCurrent() }
            await run.stopAndWait()
            await waitForRetirements()
            throw (error as? PlaybackError) ?? PlaybackError.audioFailed(reason: "Embedded audio preparation failed.")
        }
    }

    /// 仅已通过 ready 屏障的音轨可启动；不存在音轨时保持无操作。
    func start() {
        // 准备中、停止后或失败的运行均不能抢先发声。
        guard let current, current.isReady else { return }
        current.driver.play()
    }

    /// 暂停当前音轨，保留定位与静音设置。
    func pause() { current?.driver.pause() }

    /// 从当前音轨位置继续，沿用 start 的 ready 校验。
    func resume() { start() }

    /// 将音轨定位到视频时间；系统返回 false 时回传 audioFailed，停止则回传 cancelled。
    func seek(to seconds: TimeInterval, completion: @MainActor @escaping (Result<Void, PlaybackError>) -> Void) {
        // 无音轨是合法成功路径，视频无需等待不存在的音频操作。
        guard !bypassesAudio else {
            completion(.success(()))
            return
        }
        // 已停止或尚未准备的内嵌音轨不能以空成功让视频误恢复。
        guard let current, current.isReady else {
            completion(.failure(.cancelled))
            return
        }
        // 非法时间不悄悄定位到零，避免把失败的恢复变成音画错位。
        guard seconds.isFinite, seconds >= 0 else {
            completion(.failure(.audioFailed(reason: "Audio seek time is invalid.")))
            return
        }
        current.seek(to: seconds, completion: completion)
    }

    /// 循环边界回到零；与 seek 共用成功、失败、取消及真实完成合同。
    func rewind(completion: @MainActor @escaping (Result<Void, PlaybackError>) -> Void) {
        seek(to: 0, completion: completion)
    }

    /// 同步停止出声并撤销业务回调，底层异步工作继续由退休任务持有。
    func stop() {
        generation &+= 1
        retireCurrent()
    }

    /// 停止并等待本次调用之前的所有 asset 加载、定位、事件和计时任务真实退出。
    /// 此等待不因调用方取消而提前返回；重入产生的新运行由自己的 owner 管理。
    func stopAndWait() async {
        stop()
        await waitForRetirements()
    }

    /// 移交当前运行到受管理收尾任务；先清 current，避免取消回调重入操作旧实例。
    private func retireCurrent() {
        // 无运行时不生成空的收尾 Task，重复 stop 保持幂等。
        guard let run = current else { return }
        current = nil
        // 先登记再触发同步取消回调，重入 stopAndWait 也必须看到这一退休任务。
        retirements[run.id] = Task { await run.stopAndWait() }
        run.stop()
    }

    /// 等待进入此方法时已有的退休任务；不误删 await 期间新登记的任务。
    private func waitForRetirements() async {
        let pending = retirements
        for (id, task) in pending {
            await task.value
            retirements.removeValue(forKey: id)
        }
    }

    /// 当前已就绪运行出现不可恢复错误时先静音停止，再通知上层一次。
    private func failCurrent(_ error: PlaybackError, generation failedGeneration: UInt64) {
        // 旧 item 的通知可能已经进入邮箱，不能将错误归到新请求。
        guard generation == failedGeneration, current != nil else { return }
        retireCurrent()
        onFailure?(error)
    }
}
