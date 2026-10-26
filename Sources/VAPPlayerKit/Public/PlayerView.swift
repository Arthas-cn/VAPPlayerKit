import AVFoundation
import Metal
import QuartzCore
import UIKit

/// UIKit 播放宿主；拥有一个当前 session，并保留已终态但尚未排空的资源。
/// 只接受本地文件，下载、缓存和加载并发由上层统一播放器管理。
@MainActor
public final class PlayerView: UIView {
    /// 当前宿主的事件接收者；session 的终态互斥且最多一次。
    public weak var delegate: (any PlayerDelegate)?
    /// 下一次准备时快照的动态内容提供者；session 会强持有至清理完成。
    public weak var dynamicContentProvider: (any DynamicContentProvider)?
    /// 可选的线程安全指标接收者，不承担播放控制。
    public weak var metricsSink: (any MetricsSink)?
    /// 当前静音期望值；准备之前设置也会应用到之后创建的内嵌音轨。
    public var isMuted = false {
        didSet { session?.setMuted(isMuted) }
    }
    /// 承载可见画面的独立透明层，不改变宿主 UIView 的可见性。
    public var metalLayer: CAMetalLayer { presentationLayer }

    /// 当前正在准备、就绪或播放的会话；终态后立即退出当前角色。
    private var session: PlaybackSession?
    /// 成功准备的输入身份，用于 prepare 后首次 play 复用。
    private var preparedURL: URL?
    /// 成功准备的不可变元数据，用于校验显式 metadata 是否同一份检查结果。
    private var preparedMetadata: AssetMetadata?
    /// 成功准备的完整值配置，包含显式透明矩形与恢复策略。
    private var preparedOptions: PlaybackOptions?
    /// 每次替换、停止或清空递增，迟到的异步操作不能启动新画面。
    private var operationGeneration: UInt64 = 0
    /// 由同步 play 入口拥有的准备任务，停止时请求取消并等待它退出。
    private var playTask: Task<Void, Never>?
    /// 已终态的会话排空任务；不能因当前 session=nil 就跳过它们。
    private var retirements: [SessionToken: Task<Void, Never>] = [:]
    /// 用户暂停覆盖 SDK 自带的场景恢复；系统暂停也等待显式恢复。
    private var requiresExplicitResume = false
    /// 音频中断尚未结束时禁止任何入口恢复音画；结束本身不代表恢复授权。
    private var isAudioInterrupted = false
    /// 已接纳首次 play 但被暂停门延迟的会话；prepare 本身不会设置它。
    private var pendingInitialStart = false
    /// 前后台与音频中断的通知订阅，销毁时解除。
    private var notificationTokens: [NSObjectProtocol] = []
    /// 独立于 UIView backing layer 的 Metal 呈现层。
    private let presentationLayer = CAMetalLayer()

    /// 创建透明播放宿主，不执行文件读取或播放器准备。
    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
        observeApplicationLifecycle()
    }

    /// 从 UIKit 归档创建宿主；与代码构造使用相同生命周期。
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
        observeApplicationLifecycle()
    }

    /// 销毁时解除通知并移交尚未排空的 session；正常资源归还应显式等待 clearAndWait。
    isolated deinit {
        playTask?.cancel()
        // 显式 clearAndWait 是正常收尾路径；未显式清理的 UIKit 宿主仍交给受管 owner 排空。
        if let session { PlaybackRetirementOwner.retire(session) }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    /// 配置透明层，显示 scale 取当前 trait，不使用全局屏幕猜测窗口。
    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(presentationLayer)
        presentationLayer.isOpaque = false
        presentationLayer.pixelFormat = .bgra8Unorm
        presentationLayer.contentsScale = traitCollection.displayScale
        presentationLayer.framebufferOnly = true
    }

    /// 更新实际 drawable 尺寸；零尺寸只挂起，不作为解码错误或自然结束。
    public override func layoutSubviews() {
        super.layoutSubviews()
        presentationLayer.frame = bounds
        let scale = traitCollection.displayScale
        presentationLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // 无效展示尺寸必须先冻结音画；恢复只在宿主允许自动恢复时生效。
        if size.width > 0, size.height > 0 {
            presentationLayer.drawableSize = size
            resumeAutomaticallyIfAllowed()
        } else {
            session?.suspend()
        }
        updateSnapshot()
    }

    /// 离窗时遵守安全挂起/停止策略，重新入窗不覆盖统一层的恢复控制。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        // 离窗不能继续提交 GPU 工作；入窗是否恢复由配置与显式暂停门共同决定。
        if window == nil { handleBackground() }
        else { resumeAutomaticallyIfAllowed() }
    }

    /// 只解析本地资源和槽位，不创建解码器、renderer、动态 provider 或音频。
    /// 结果按文件签名与完整布局缓存；取消会等本次 inspection 真实收口。
    public static func inspect(url: URL, options: PlaybackOptions = .init()) async throws -> AssetMetadata {
        try options.validate()
        let resolution = try await AssetMetadataCache.shared.resolve(
            url: url, inspector: AssetInspector(), assetMode: options.assetMode
        )
        try Task.checkCancellation()
        return resolution.inspection.metadata
    }

    /// 准备全部播放子系统而不启动时间轴；取消/非法资源会抛错，事件仍只结算一次。
    @discardableResult
    public func prepare(url: URL, options: PlaybackOptions = .init()) async throws -> AssetMetadata {
        try await prepare(url: url, suppliedMetadata: nil, options: options)
    }

    /// 使用同一文件、相同布局的检查结果准备，文件签名不匹配时拒绝复用。
    @discardableResult
    public func prepare(url: URL, metadata: AssetMetadata, options: PlaybackOptions = .init()) async throws -> AssetMetadata {
        try await prepare(url: url, suppliedMetadata: metadata, options: options)
    }

    /// 为调用方准备操作创建代次，确保旧会话排空后才分配下一份管线。
    private func prepare(url: URL, suppliedMetadata: AssetMetadata?, options: PlaybackOptions) async throws -> AssetMetadata {
        let generation = beginNewOperation()
        requiresExplicitResume = false
        return try await prepareForOperation(url: url, metadata: suppliedMetadata, options: options, generation: generation)
    }

    /// 在当前代次中准备；同步 play 与 async prepare 共用这条路径，避免互相取消自身。
    private func prepareForOperation(url: URL, metadata: AssetMetadata?, options: PlaybackOptions, generation: UInt64) async throws -> AssetMetadata {
        // 已取消的启动任务可能晚于新请求才获调度，不能先停掉新请求再检查代次。
        guard generation == operationGeneration, !Task.isCancelled else { throw CancellationError() }
        retireCurrent(reason: .cancelled)
        await waitForRetirements()
        // 等待旧 GPU/提供者期间可能已经换资源，失效请求不再分配下一份资源。
        guard generation == operationGeneration, !Task.isCancelled else { throw CancellationError() }
        do { try options.validate() }
        catch {
            delegate?.player(self, didFail: error)
            throw error
        }
        let target = makeSession(url: url, options: options)
        session = target
        do {
            let resolved = try await target.prepare(using: metadata)
            // 准备完成只能提交给创建它的操作；新静音值另外从属性同步。
            guard generation == operationGeneration, session?.token == target.token, !Task.isCancelled else {
                throw CancellationError()
            }
            preparedURL = url
            preparedMetadata = resolved
            preparedOptions = options
            target.setMuted(isMuted)
            updateSnapshot()
            return resolved
        } catch {
            // 失败的 session 自己发一次终态；无论是否仍是当前会话都保留到实际排空。
            registerRetirement(target)
            if session?.token == target.token { session = nil }
            throw error
        }
    }

    /// 播放本地文件；若相同输入已 ready 则直接启动，否则受管地异步准备。
    public func play(url: URL, options: PlaybackOptions = .init()) {
        play(url: url, suppliedMetadata: nil, options: options)
    }

    /// 播放经过本库检查的文件，复用前仍校验完整文件和布局身份。
    public func play(url: URL, metadata: AssetMetadata, options: PlaybackOptions = .init()) {
        play(url: url, suppliedMetadata: metadata, options: options)
    }

    /// 拥有异步启动任务；所有暂停点之后检查代次，取消不能产生迟到画面。
    private func play(url: URL, suppliedMetadata: AssetMetadata?, options: PlaybackOptions) {
        let generation = beginNewOperation()
        requiresExplicitResume = false
        playTask = Task { @MainActor [weak self] in
            // 首次调度也可能已过期；任何 session 状态读取和替换都在代次门之后。
            guard let self, self.operationGeneration == generation, !Task.isCancelled else { return }
            let target: PlaybackSession
            // prepare 后第一次 play 不重复创建 session；不同配置必须走完整替换路径。
            if let current = self.session, current.state == .ready,
               self.preparedURL == url, self.preparedOptions == options,
               suppliedMetadata == nil || self.preparedMetadata == suppliedMetadata {
                target = current
            } else {
                do {
                    _ = try await self.prepareForOperation(url: url, metadata: suppliedMetadata, options: options, generation: generation)
                    guard let current = self.session else { return }
                    target = current
                } catch { return }
            }
            // 仅最新操作可以启动；展示条件不满足时进入安全挂起，绝不继续声音。
            guard self.operationGeneration == generation, !Task.isCancelled, self.session?.token == target.token else { return }
            self.updateSnapshot()
            self.pendingInitialStart = true
            // 首次 play 的准备期间收到用户暂停时，不能短暂启动声音再补暂停。
            guard !self.requiresExplicitResume, !self.isAudioInterrupted else { return }
            self.pendingInitialStart = false
            target.play()
            if self.bounds.isEmpty || self.window == nil || UIApplication.shared.applicationState != .active {
                self.handleBackground()
            }
        }
    }

    /// 暂停并要求显式恢复；已经系统挂起的 session 也会记住用户意图。
    public func pause() {
        requiresExplicitResume = true
        session?.pause()
    }

    /// 显式恢复，只有当前窗口、有效尺寸和前台状态都允许时才继续音画。
    public func resume() {
        // 业务可以提前表达恢复，但不能绕过系统安全门在后台播放。
        guard !isAudioInterrupted, window != nil, !bounds.isEmpty, UIApplication.shared.applicationState == .active else { return }
        requiresExplicitResume = false
        // 只有已接受 play 的 ready 会话可以首次启动；单纯 prepare 后 resume 仍为空操作。
        if pendingInitialStart, let session, session.state == .ready {
            pendingInitialStart = false
            session.play()
        } else {
            session?.resume()
        }
    }

    /// 立即停止并使旧操作失效；物理资源仍受管收尾，等待完成请用 clearAndWait。
    public func stop() {
        _ = beginNewOperation()
        retireCurrent(reason: .stopped)
    }

    /// 立即停止并隐藏画面；不会删除宿主的文件或共享 metadata 缓存。
    public func clear() {
        presentationLayer.isHidden = true
        stop()
    }

    /// 停止并等待当前及已终态 session 的准备、provider、解码、音频和 GPU 排空。
    /// 幂等；调用方取消等待也不会提前归还尚在使用的底层资源。
    public func clearAndWait() async {
        let launching = playTask
        clear()
        if let launching { await launching.value }
        await waitForRetirements()
    }

    /// 创建一个配置值独立、事件按 token 过滤的 session。
    private func makeSession(url: URL, options: PlaybackOptions) -> PlaybackSession {
        let target = PlaybackSession(url: url, options: options, metalLayer: presentationLayer,
                                     dynamicProvider: dynamicContentProvider)
        target.setMuted(isMuted)
        target.metricsSink = metricsSink
        target.onStart = { [weak self, weak target] in
            guard let self, let target, self.session?.token == target.token else { return }
            self.delegate?.playerDidStart(self)
        }
        target.onMetadata = { [weak self, weak target] metadata in
            guard let self, let target, self.session?.token == target.token else { return }
            self.delegate?.player(self, didUpdate: metadata)
        }
        target.onFirstFrame = { [weak self, weak target] in
            guard let self, let target, self.session?.token == target.token else { return }
            self.presentationLayer.isHidden = false
        }
        target.onFinish = { [weak self, weak target] reason in
            guard let self, let target, self.session?.token == target.token else { return }
            // 终态先退出当前角色；回调重入 play 不会被旧 session 的尾部覆盖。
            self.session = nil
            self.resetPreparedIdentity()
            if target.options.clearsAfterFinish { self.presentationLayer.isHidden = true }
            self.registerRetirement(target)
            self.delegate?.playerDidFinish(self, reason: reason)
        }
        target.onFailure = { [weak self, weak target] error in
            guard let self, let target, self.session?.token == target.token else { return }
            self.session = nil
            self.presentationLayer.isHidden = true
            self.resetPreparedIdentity()
            self.registerRetirement(target)
            self.delegate?.player(self, didFail: error)
        }
        return target
    }

    /// 将当前会话转为退役状态，保留清理所有权直到它真正完成。
    private func retireCurrent(reason: FinishReason) {
        guard let target = session else { return }
        target.stop(reason: reason)
        // idle 或已经终态的会话不一定再触发 delegate，仍需登记清理。
        if session?.token == target.token { session = nil }
        resetPreparedIdentity()
        if target.options.clearsAfterFinish { presentationLayer.isHidden = true }
        registerRetirement(target)
    }

    /// 每个 session 只登记一个排空任务，保留自然结束但还在 GPU 收尾的会话。
    private func registerRetirement(_ target: PlaybackSession) {
        guard retirements[target.token] == nil else { return }
        retirements[target.token] = Task { @MainActor [weak self] in
            await target.clearAndWait()
            self?.retirements[target.token] = nil
        }
    }

    /// 等待本调用开始时已登记的退役会话，不取消之后由新操作建立的会话。
    private func waitForRetirements() async {
        let pending = Array(retirements.values)
        for task in pending { await task.value }
    }

    /// 清理仅用于 ready 复用的输入快照，不干扰已取得元数据的业务代码。
    private func resetPreparedIdentity() {
        pendingInitialStart = false
        preparedURL = nil
        preparedMetadata = nil
        preparedOptions = nil
    }

    /// 作废旧操作并请求旧 play 任务取消，已分配资源由 session 排空路径保留。
    @discardableResult
    private func beginNewOperation() -> UInt64 {
        operationGeneration &+= 1
        playTask?.cancel()
        playTask = nil
        return operationGeneration
    }

    /// 将 UIKit 的实际像素尺寸传给串行 renderer，不在后台访问 UIView。
    private func updateSnapshot() {
        guard let session else { return }
        let scale = traitCollection.displayScale
        session.updateRenderSnapshot(RenderSnapshot(
            drawableSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            contentMode: session.options.contentMode
        ))
    }

    /// 仅在配置允许、未被用户/系统显式暂停且安全门打开时由 SDK 自动恢复。
    private func resumeAutomaticallyIfAllowed() {
        guard let session, session.options.automaticallyResumesAfterSuspension,
              !requiresExplicitResume, !isAudioInterrupted, session.state == .suspended,
              window != nil, !bounds.isEmpty, UIApplication.shared.applicationState == .active else { return }
        session.resume()
    }

    /// 观察 App 生命周期与音频中断；不修改 App 全局 AVAudioSession 策略。
    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // 订阅明确在主队列交付，必须同步关门，不能让下一条播放命令抢在失活之前。
                MainActor.assumeIsolated { self?.handleBackground() }
            })
        }
        notificationTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAutomaticallyIfAllowed() }
        })
        notificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            // 主队列交付保证 actor 前置条件；同步 latch 避免通知返回后 resume 抢先执行。
            MainActor.assumeIsolated {
                guard let self else { return }
                // 中断开始后显式 resume 和新 play 也不能绕过系统暂停门。
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.isAudioInterrupted = true
                    self.pause()
                // 中断结束仅移除阻塞，仍由宿主显式授权恢复。
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.isAudioInterrupted = false
                }
            }
        })
    }

    /// 离窗或失活时立即冻结画面和声音，stop 策略产生明确终态。
    private func handleBackground() {
        guard let target = session else { return }
        switch target.options.backgroundPolicy {
        // 挂起保留媒体位置，不把系统切换当成自然完成。
        case .suspend:
            target.suspend()
        // 停止策略完整结算并进入同一受管排空路径。
        case .stop:
            retireCurrent(reason: .stopped)
        }
    }
}

/// UIKit 宿主忘记显式清理时的资源兜底 owner，不将异步任务丢给 deinit 后无人管理。
@MainActor
private enum PlaybackRetirementOwner {
    /// 尚未排空的会话任务；完成后移除，不无限保留已结束会话。
    static var tasks: [SessionToken: Task<Void, Never>] = [:]

    /// 接管一次会话并等待其真实清理完成；不触碰其他播放器的文件或缓存。
    static func retire(_ session: PlaybackSession) {
        session.stop(reason: .cancelled)
        tasks[session.token] = Task { @MainActor in
            await session.clearAndWait()
            tasks[session.token] = nil
        }
    }
}
