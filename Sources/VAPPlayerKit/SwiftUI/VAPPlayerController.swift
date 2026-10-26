import AVFAudio
import UIKit

/// 一次 SwiftUI 请求的内部状态；可变播放器和 provider 不进入业务值模型。
@MainActor
private final class VAPPlaybackRun {
    /// 原始不可变请求，供同 ID 更新检查。
    let request: VAPPlaybackRequest
    /// 关闭 SDK 自动恢复后的实际配置，不修改业务原始值。
    let effectiveRequest: VAPPlaybackRequest
    /// 接纳时固定的 provider，保持到该请求真实排空。
    var provider: (any DynamicContentProvider)?
    /// 接纳时固定的回调；旧事件不会错误调用新请求的闭包。
    let onEvent: @MainActor (VAPPlaybackEvent) -> Void
    /// 请求独占的内核桥；有效展示条件满足前为 nil。
    var transport: (any VAPPlayerTransport)?
    /// 当前准备任务，由控制器或退役 registry 持有到退出。
    var preparationTask: Task<Void, Never>?
    /// 已完整准备，可首次 play；解析 metadata 并不设置此值。
    var isPrepared = false
    /// 是否已发起首次 play，防止等待 started 时重复启动。
    var hasIssuedPlay = false
    /// 内核是否已确认首次 started。
    var hasStarted = false
    /// 当前是否已经发起运行或恢复；用于合并重复控制输入。
    var isRunning = false
    /// 终态已经结算，任何迟到事件均须丢弃。
    var isTerminal = false
    /// 是否已经开始退役，保证 clearAndWait 只由一个所有者执行。
    var isRetiring = false
    /// 是否报告过等待展示条件，避免布局重复发相同事件。
    var didReportWaiting = false
    /// 上次报告的暂停原因；nil 表示未暂停或已经恢复。
    var lastPauseReason: VAPPlaybackPauseReason?
    /// 系统暂停锁存；场景变 active 本身不能解除。
    var requiresExplicitResume = false

    /// 固定请求及 provider，并覆写仅由 SwiftUI 控制的生命周期选项。
    init(
        request: VAPPlaybackRequest,
        provider: (any DynamicContentProvider)?,
        onEvent: @escaping @MainActor (VAPPlaybackEvent) -> Void
    ) {
        self.request = request
        self.provider = provider
        self.onEvent = onEvent
        var options = request.options
        options.automaticallyResumesAfterSuspension = false
        options.backgroundPolicy = .suspend
        effectiveRequest = VAPPlaybackRequest(id: request.id, url: request.url, options: options)
    }
}

/// SwiftUI 与 UIKit 之间的单实例状态机；所有 UI 状态及回调都在 MainActor。
@MainActor
final class VAPPlayerController {
    /// 创建请求独占内核的工厂；测试可注入不使用 Metal 的实现。
    typealias TransportFactory = @MainActor (
        (any DynamicContentProvider)?,
        @escaping @MainActor (VAPTransportEvent) -> Void
    ) -> any VAPPlayerTransport

    /// 真正的内核创建边界，只有展示条件满足后才调用。
    private let makeTransport: TransportFactory
    /// 宿主由 SwiftUI 拥有；控制器不得形成 UIView 引用环。
    private weak var host: VAPSwiftUIHost?
    /// 当前请求，可能仍在等待上一次请求的清理。
    private var run: VAPPlaybackRun?
    /// 当前宿主生命周期内已经结束的 ID；再次提交不会复活或重复终态。
    private var terminalIDs: Set<UUID> = []
    /// 已开始但尚未实际结束的清理任务，阻止新请求提前准备。
    private var retirements: [UUID: Task<Void, Never>] = [:]
    /// 等待离开 SwiftUI 更新栈后交付的事件，保留原请求回调。
    private var pendingEvents: [(VAPPlaybackEvent, @MainActor (VAPPlaybackEvent) -> Void)] = []
    /// 事件交付任务，有明确 owner，不在 deinit 创建工作。
    private var deliveryTask: Task<Void, Never>?
    /// 当前宿主是否入窗且有正数尺寸。
    private var isPresentationAvailable = false
    /// 当前窗口是否 active；初始等待不会误判为一次系统中断。
    private var isSceneActive = false
    /// AVAudioSession 中断是否仍在进行，显式命令也不能绕过此门。
    private var isAudioInterrupted = false
    /// 当前业务意图，不随系统通知自动改写。
    private var intent: VAPPlaybackIntent = .playing
    /// 最近接收的显式控制版本，普通重绘保持原值。
    private var controlRevision: UInt64 = 0
    /// 当前静音值，新建内核之前也要保留。
    private var isMuted = false
    /// representable 已销毁后拒绝所有新输入与准备。
    private var isDismantled = false
    /// 主线程音频中断观察句柄，dismantle 时同步移除。
    private var interruptionObserver: (any NSObjectProtocol)?
    /// 实际 UIWindowScene 生命周期观察句柄，dismantle 时全部注销。
    private var sceneObservers: [any NSObjectProtocol] = []

    /// 创建状态机，不立即创建 UIKit 播放器；工厂只供包内部替换与测试。
    init(makeTransport: @escaping TransportFactory = { provider, onEvent in
        VAPViewTransport(provider: provider, onEvent: onEvent)
    }) {
        self.makeTransport = makeTransport
    }

    /// 关联稳定宿主并安装系统通知，不执行文件准备。
    func attach(to host: VAPSwiftUIHost) {
        self.host = host
        host.controller = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            // 通知显式派发到主队列，隔离断言比 unchecked Sendable 更准确。
            MainActor.assumeIsolated {
                guard let rawType,
                      let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                self?.setAudioInterrupted(type == .began)
            }
        }
        // SwiftUI 外壳也可由 UIKit 承载，不能假设存在向下传播 scenePhase 的 SwiftUI Scene。
        let sceneChanges: [(Notification.Name, Bool)] = [
            (UIScene.didActivateNotification, true),
            (UIScene.willDeactivateNotification, false),
            (UIScene.didEnterBackgroundNotification, false),
            (UIScene.didDisconnectNotification, false)
        ]
        for (name, isActive) in sceneChanges {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak host] notification in
                // 先提取 MainActor 隔离的场景引用，不把包含任意 userInfo 的 Notification 送入 actor。
                guard let scene = notification.object as? UIWindowScene else { return }
                // Foundation 明确派发到主队列，同步关闭播放门，避免再调度造成短暂续播。
                MainActor.assumeIsolated {
                    host?.receiveSceneActivation(isActive, from: scene)
                }
            }
            sceneObservers.append(observer)
        }
        host.refreshAvailability()
    }

    /// 接收外部输入；只允许新 ID 改请求内容，控制状态与静音可原位更新。
    func update(
        resource: VAPPlaybackRequest?,
        intent: VAPPlaybackIntent,
        controlRevision: UInt64,
        isVisible: Bool,
        isMuted: Bool,
        isSceneActive: Bool,
        dynamicContentProvider: (any DynamicContentProvider)?,
        onEvent: @escaping @MainActor (VAPPlaybackEvent) -> Void
    ) {
        // 销毁后的迟到 SwiftUI 更新不允许重新登记播放。
        guard !isDismantled else { return }
        let hadActiveScene = self.isSceneActive
        let isExplicitCommand = self.controlRevision != controlRevision
        self.intent = intent
        self.controlRevision = controlRevision
        self.isMuted = isMuted
        self.isSceneActive = isSceneActive

        // 新身份先终结旧请求；新请求只能等待旧清理真正结束。
        if resource?.id != run?.request.id {
            if let run { finish(run, with: .finished(.cancelled)) }
            run = resource.map {
                VAPPlaybackRun(request: $0, provider: dynamicContentProvider, onEvent: onEvent)
            }
            if let run, terminalIDs.contains(run.request.id) {
                // 已终结身份不重新发事件；调用方必须明确创建新 ID。
                run.isTerminal = true
                run.provider = nil
            }
        } else if let resource, let run, resource != run.request {
            // 同 ID 改内容属于调用违约；终态身份也不能再发第二次 failed。
            finish(run, with: .failed(.requestChanged))
        } else if hadActiveScene && !isSceneActive {
            // 只有已存在请求经历 active → inactive 才锁存系统暂停。
            run?.requiresExplicitResume = true
        }

        guard let run else { return }
        run.transport?.isMuted = isMuted
        // 隐藏与显式停止优先于一切暂停，包含尚未开始准备的请求。
        guard isVisible, intent != .stopped else {
            finish(run, with: .finished(.stopped))
            return
        }
        // 恢复只能由新控制版本发起，系统中断尚未结束时不能预先解锁。
        if isExplicitCommand, intent == .playing, isSceneActive, !isAudioInterrupted {
            run.requiresExplicitResume = false
        }
        reconcile()
    }

    /// 接收宿主的真实展示条件；失去尺寸暂停，恢复尺寸不解除系统或用户暂停。
    func setPresentationAvailable(_ isAvailable: Bool) {
        // 相同 layout 通知不应重复驱动内核或事件。
        guard isPresentationAvailable != isAvailable else { return }
        isPresentationAvailable = isAvailable
        reconcile()
    }

    /// 实际场景失活时锁存系统暂停；再次 active 只解除物理门，不代替显式恢复。
    func setSceneActive(_ isActive: Bool) {
        // 重复 layout 或相同场景通知不应反复驱动内核。
        guard isSceneActive != isActive else { return }
        let wasActive = isSceneActive
        isSceneActive = isActive
        // 初次入窗前的未知状态不锁存；真实 active → inactive 必须等新控制版本恢复。
        if wasActive && !isActive { run?.requiresExplicitResume = true }
        reconcile()
    }

    /// 音频中断结束只解除物理门，仍等待业务显式恢复。
    func setAudioInterrupted(_ isInterrupted: Bool) {
        isAudioInterrupted = isInterrupted
        // 中断开始必须锁存，即使 preparation 尚未完成也不能抢先开播。
        if isInterrupted { run?.requiresExplicitResume = true }
        reconcile()
    }

    /// 同步终结当前请求；registry 会在控制器被释放后继续持有真实清理。
    func dismantle() {
        // 重复 dismantle 不重复终态或移除其他实例的通知。
        guard !isDismantled else { return }
        isDismantled = true
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
        sceneObservers.removeAll()
        if let run { finish(run, with: .finished(.cancelled)) }
        host?.controller = nil
        host = nil
    }

    /// 等待当前已登记的准备、清理及事件工作，不等待整个动画自然播放完毕。
    /// 供包内集成与测试明确等待物理工作；不可在自身事件回调里同步阻塞调用。
    func waitForPendingWork() async {
        while true {
            let tasks = Array(retirements.values) + [run?.preparationTask, deliveryTask].compactMap { $0 }
            // 空集合表示实际工作已经结束，不通过 sleep 推测队列是否清空。
            guard !tasks.isEmpty else { return }
            for task in tasks { await task.value }
        }
    }

    /// 根据全部门条件决定准备、首次播放或恢复；不会抢占仍在退役的旧内核。
    private func reconcile() {
        // 终态代次始终封闭，迟到尺寸/场景通知不能使它复活。
        guard !isDismantled, let run, !run.isTerminal else { return }
        if run.transport == nil {
            // 未入窗、零尺寸、后台或旧清理中均不能先创建解码器。
            guard isPresentationAvailable, isSceneActive, retirements.isEmpty else {
                if !run.didReportWaiting {
                    run.didReportWaiting = true
                    emit(.waitingForPresentation, for: run)
                }
                return
            }
            beginPreparation(run)
        }
        // 准备期间只记录控制意图，不能调用 resume 冒充初次启动。
        guard run.isPrepared, let transport = run.transport else { return }
        if let reason = pauseReason(for: run) {
            // 即使 play 的 started 尚未返回，也先暂停，迟到 started 会再次复查门。
            if run.hasIssuedPlay, run.isRunning || run.lastPauseReason != reason { transport.pause() }
            run.isRunning = false
            if run.lastPauseReason != reason {
                run.lastPauseReason = reason
                emit(.paused(reason), for: run)
            }
            return
        }
        if !run.hasIssuedPlay {
            // prepare 不等于 play；第一轮必须走显式首次启动入口。
            run.hasIssuedPlay = true
            run.isRunning = true
            run.lastPauseReason = nil
            transport.play(run.effectiveRequest)
        } else if !run.isRunning {
            // 首次 play 已发起便可恢复，包括尚未收到首帧 started 的暂停；不能重发 play。
            run.isRunning = true
            run.lastPauseReason = nil
            transport.resume()
            if run.hasStarted {
                // 首帧前恢复仍等待首次 started，不能反向先报告 resumed。
                emit(.resumed, for: run)
            }
        }
    }

    /// 汇总暂停门；用户暂停优先展示，但其他原因不会因此被删除。
    private func pauseReason(for run: VAPPlaybackRun) -> VAPPlaybackPauseReason? {
        // 用户意图不能被系统前台/窗口恢复覆盖。
        if intent == .paused { return .user }
        // 活动场景和中断结束只是必要条件，锁存仍须显式命令解除。
        if !isSceneActive || isAudioInterrupted || run.requiresExplicitResume { return .system }
        // 仅尺寸门恢复可自动继续，不能越过前两项。
        if !isPresentationAvailable { return .surfaceUnavailable }
        return nil
    }

    /// 建立独立内核并发起受管准备任务，返回后必须再次核对请求对象身份。
    private func beginPreparation(_ run: VAPPlaybackRun) {
        let transport = makeTransport(run.provider) { [weak self, weak run] event in
            guard let self, let run else { return }
            self.receive(event, from: run)
        }
        run.transport = transport
        transport.isMuted = isMuted
        host?.install(transport.view)
        emit(.preparing, for: run)
        run.preparationTask = Task { @MainActor [weak self, run] in
            defer { run.preparationTask = nil }
            do {
                try await transport.prepare(run.effectiveRequest)
                // await 期间可能已经换请求或销毁；旧结果只参与清理。
                guard let self, self.run === run, !run.isTerminal, !Task.isCancelled else { return }
                run.isPrepared = true
                self.emit(.ready, for: run)
                self.reconcile()
            } catch {
                // prepare 和 delegate 可能同时报告失败，finish 会先结算终态再发事件。
                guard let self, self.run === run, !run.isTerminal else { return }
                self.finish(run, with: self.failureEvent(error))
            }
        }
    }

    /// 接收特定请求内核的事件；对象身份同时隔离同 URL 的不同播放代次。
    private func receive(_ event: VAPTransportEvent, from run: VAPPlaybackRun) {
        // 独立内核也可能有迟到 delegate，不能仅依赖 SDK 自身 token。
        guard self.run === run, !run.isTerminal, !isDismantled else { return }
        switch event {
        // 内核 resume 也可能报告 started；业务首次事件只能一次。
        case .started:
            run.isRunning = true
            if !run.hasStarted {
                run.hasStarted = true
                emit(.started, for: run)
            }
            reconcile()
        // 自然结束遵守末帧保留配置；其他结束始终清理。
        case .finished(let reason):
            finish(run, with: .finished(reason), retainLastFrame: reason == .completed && !run.request.options.clearsAfterFinish)
        // 失败不跨请求尝试恢复或降级成成功。
        case .failed(let error):
            finish(run, with: failureEvent(error))
        }
    }

    /// 将内核取消与普通失败区分，业务 provider 的未知错误转成纯值说明。
    private func failureEvent(_ error: any Error) -> VAPPlaybackEvent.Kind {
        // 取消不是资源损坏，也不再跟随 failed 事件。
        if error is CancellationError || (error as? PlaybackError) == .cancelled {
            return .finished(.cancelled)
        }
        if let error = error as? PlaybackError { return .failed(.playback(error)) }
        return .failed(.underlying(message: error.localizedDescription))
    }

    /// 先封闭终态再交付事件；重复停止仍可清理此前刻意保留的末帧。
    private func finish(
        _ run: VAPPlaybackRun,
        with event: VAPPlaybackEvent.Kind,
        retainLastFrame: Bool = false
    ) {
        if !run.isTerminal {
            // 标记必须早于回调和清理，避免重入或双错误产生第二个终态。
            run.isTerminal = true
            terminalIDs.insert(run.request.id)
            emit(event, for: run)
        }
        // 只有自然完成且显式要求末帧时保留；隐藏/替换/销毁会再次进入并清掉它。
        guard !retainLastFrame else { return }
        retire(run)
    }

    /// 立即停音并隐藏旧画面；异步排空完成前新请求只能等待。
    private func retire(_ run: VAPPlaybackRun) {
        // 已经退役的请求只等待原所有者，不重复创建清理任务。
        guard !run.isRetiring else { return }
        guard let transport = run.transport else {
            // 尚未创建内核的终态请求也要立即释放接纳时固定的 provider。
            run.provider = nil
            return
        }
        run.isRetiring = true
        transport.pause()
        transport.view.isHidden = true
        transport.view.removeFromSuperview()
        let preparationTask = run.preparationTask
        preparationTask?.cancel()
        let id = UUID()
        retirements[id] = VAPSwiftUIRetirementRegistry.retain { [weak self, run] in
            await transport.clearAndWait()
            await preparationTask?.value
            run.transport = nil
            run.provider = nil
            // 即使控制器已消失，registry 仍持有 transport 至两个等待都结束。
            guard let self else { return }
            self.retirements[id] = nil
            self.reconcile()
        }
    }

    /// 延后到当前 SwiftUI/UIKit 更新栈退出后交付事件，保持同请求事件顺序。
    private func emit(_ kind: VAPPlaybackEvent.Kind, for run: VAPPlaybackRun) {
        pendingEvents.append((VAPPlaybackEvent(requestID: run.request.id, kind: kind), run.onEvent))
        // 一个交付任务持续消费重入追加的事件，不为每条事件创建无界 Task。
        guard deliveryTask == nil else { return }
        deliveryTask = Task { @MainActor [self] in
            while !pendingEvents.isEmpty {
                let (event, callback) = pendingEvents.removeFirst()
                callback(event)
            }
            deliveryTask = nil
        }
    }
}
