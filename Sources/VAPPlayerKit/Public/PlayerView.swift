import UIKit
import Metal
import QuartzCore

/// 宿主唯一需要持有的播放视图。负责 UIKit 生命周期和公开控制；每一次新播放都拥有独立 session。
///
/// 视图本身不解析 MP4、不持有解码器。真正的准备 / 出帧 / 终态都在 `PlaybackSession` 内完成，
/// 本类只做入口转发、前后台策略和 Swift / ObjC 回调桥接。
@objc(VPKPlayerView)
@MainActor
public final class PlayerView: UIView {
    /// Swift 侧播放回调。所有事件在主线程派发，每个 session 终态最多一次。
    public weak var delegate: PlayerDelegate?
    /// Swift 动态内容提供者。prepare 时注入到新 session，播放中途更换不会影响当前 session。
    public weak var dynamicContentProvider: DynamicContentProvider?
    /// 可选埋点接收器。组件不依赖具体 APM。
    public weak var metricsSink: MetricsSink?

    /// Objective-C 侧播放回调。与 `delegate` 并行派发，互不影响。
    @objc(delegate)
    public weak var objcDelegate: ObjCPlayerDelegate?
    /// Objective-C 动态内容提供者。与 Swift provider 二选一即可。
    @objc(dynamicContentProvider)
    public weak var objcDynamicProvider: ObjCDynamicContentProvider?

    /// 当前正在准备或播放的 session。终态后会被置空。
    private var session: PlaybackSession?
    /// 最近一次成功 prepare 的本地 URL，用于判断后续 `play` 能否复用 ready session。
    private var preparedURL: URL?
    /// 最近一次成功 prepare 得到的 metadata 实例，用于判断显式 metadata 入口是否仍匹配。
    private var preparedMetadata: AssetMetadata?
    /// 最近一次成功 prepare 的 options 快照。任一字段变化都视为需要新建 session。
    private var preparedOptions: OptionsSignature?
    /// 递增代数。新的 prepare / play / stop 会作废进行中的异步任务。
    private var operationGeneration: UInt64 = 0
    /// 当前 `play` 的异步准备任务。新操作会先取消它。
    private var playTask: Task<Void, Never>?
    /// 前后台通知观察者，deinit 时必须移除。
    private var notificationTokens: [NSObjectProtocol] = []
    /// 独立于 UIView backing layer 的 Metal 呈现层，避免内部隐藏 drawable 覆盖宿主可见性。
    private let presentationLayer = CAMetalLayer()

    /// 实际提交 GPU 画面的 Metal layer。宿主一般不需要直接操作。
    public var metalLayer: CAMetalLayer { presentationLayer }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
        observeApplicationLifecycle()
    }

    @objc public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
        observeApplicationLifecycle()
    }

    deinit {
        playTask?.cancel()
        let activeSession = session
        Task { @MainActor in
            activeSession?.stop(reason: .cancelled)
        }
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    /// 配置透明 Metal 呈现层。必须独立于 UIView backing layer，才能在结束后隐藏画面而不改宿主 alpha。
    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(metalLayer)
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.framebufferOnly = true
    }

    /// 同步 Metal 层几何与 drawable 尺寸。零尺寸时挂起，避免空 drawable 被当成播放错误；
    /// 从零尺寸恢复且仍在前台 window 中时自动 resume。
    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0 {
            metalLayer.drawableSize = size
            if
                let session,
                session.state == .suspended,
                window != nil,
                UIApplication.shared.applicationState == .active
            {
                session.resume()
            }
        } else {
            session?.suspend()
        }
        session?.updateRenderSnapshot(RenderSnapshot(
            drawableSize: size,
            contentMode: session?.options.contentMode ?? .scaleAspectFit
        ))
    }

    /// 离开 window 时按 `backgroundPolicy` 挂起或停止；重新入窗且仍 suspended 时恢复。
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let session else { return }
        if window == nil {
            switch session.options.backgroundPolicy {
            case .suspend: session.suspend()
            case .stop:
                if session.options.clearsAfterFinish { metalLayer.isHidden = true }
                session.stop(reason: .stopped)
            }
        } else if
            session.state == .suspended,
            !bounds.isEmpty,
            UIApplication.shared.applicationState == .active
        {
            session.resume()
        }
    }

    /// 解析 metadata、准备动态内容和 GPU pipeline，但不自动播放。
    ///
    /// 会查询全局 `AssetMetadataCache`：相同本地 URL 命中时可跳过 MP4/vapc 再解析。
    public func prepare(url: URL, options: PlaybackOptions = .defaultOptions) async throws -> AssetMetadata {
        try await prepareInternal(url: url, metadata: nil, options: options)
    }

    /// 使用本组件此前为同一 URL 解析出的 metadata 准备，跳过重复 MP4/vapc inspection。
    ///
    /// 仅 `isReusableForPlayback == true` 的对象可用；成功后会写入全局 `AssetMetadataCache`，
    /// 供后续未显式传 metadata 的 `prepare` / `play` 复用。
    public func prepare(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions = .defaultOptions
    ) async throws -> AssetMetadata {
        try await prepareInternal(url: url, metadata: metadata, options: options)
    }

    /// 取消当前操作并创建新 session 执行 prepare。代数或 token 变化时丢弃过期结果。
    private func prepareInternal(
        url: URL,
        metadata: AssetMetadata?,
        options: PlaybackOptions
    ) async throws -> AssetMetadata {
        let generation = beginNewOperation()
        replaceCurrentSession(reason: .cancelled)
        let newSession = makeSession(url: url, options: options)
        session = newSession
        do {
            let resolvedMetadata = try await newSession.prepare(using: metadata)
            guard operationGeneration == generation, session?.token == newSession.token else {
                throw PlaybackError.cancelled
            }
            preparedURL = url
            preparedMetadata = resolvedMetadata
            preparedOptions = OptionsSignature(options)
            updateSnapshot(for: newSession)
            return resolvedMetadata
        } catch {
            if session?.token == newSession.token, newSession.state == .failed { session = nil }
            throw error
        }
    }

    /// Objective-C 回调式 prepare。completion 在主线程调用且只回调一次。
    @objc(prepareWithURL:options:completion:)
    public func prepare(
        url: URL,
        options: PlaybackOptions,
        completion: @escaping (AssetMetadata?, NSError?) -> Void
    ) {
        Task { @MainActor in
            do {
                completion(try await prepare(url: url, options: options), nil)
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    /// Objective-C 回调式 metadata 复用 prepare。
    @objc(prepareWithURL:metadata:options:completion:)
    public func prepare(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions,
        completion: @escaping (AssetMetadata?, NSError?) -> Void
    ) {
        Task { @MainActor in
            do {
                completion(try await prepare(url: url, metadata: metadata, options: options), nil)
            } catch {
                completion(nil, error as NSError)
            }
        }
    }

    /// 准备并播放。已由相同 URL 与 options 准备好的 ready session 会被复用。
    /// 未显式传 metadata 时走全局 `AssetMetadataCache`。
    @objc(playWithURL:options:)
    public func play(url: URL, options: PlaybackOptions = .defaultOptions) {
        playInternal(url: url, metadata: nil, options: options)
    }

    /// 使用本组件此前返回的 metadata 播放，避免重复 MP4/vapc inspection。
    /// 仅可复用对象有效；成功后会写入全局缓存，供后续未传 metadata 的播放复用。
    @objc(playWithURL:metadata:options:)
    public func play(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions = .defaultOptions
    ) {
        playInternal(url: url, metadata: metadata, options: options)
    }

    /// 启动播放 Task。已 ready 且 URL/options 未变时可跳过 prepare；离屏或零尺寸时按策略挂起/停止。
    private func playInternal(url: URL, metadata suppliedMetadata: AssetMetadata?, options: PlaybackOptions) {
        let generation = beginNewOperation()
        playTask = Task { @MainActor [weak self] in
            let signature = OptionsSignature(options)
            guard let context = self?.makePlayPreparation(
                url: url,
                metadata: suppliedMetadata,
                options: options,
                signature: signature
            ) else { return }
            var resolvedMetadata: AssetMetadata?
            if context.requiresPrepare {
                do {
                    resolvedMetadata = try await context.target.prepare(using: suppliedMetadata)
                } catch {
                    return
                }
            }
            guard let self else {
                context.target.stop(reason: .cancelled)
                return
            }
            if let resolvedMetadata {
                self.preparedURL = url
                self.preparedMetadata = resolvedMetadata
                self.preparedOptions = signature
            }
            guard
                !Task.isCancelled,
                self.operationGeneration == generation,
                self.session?.token == context.target.token
            else {
                context.target.stop(reason: .cancelled)
                return
            }
            self.updateSnapshot(for: context.target)
            context.target.play()
            if self.bounds.isEmpty {
                context.target.suspend()
            } else if self.window == nil || UIApplication.shared.applicationState != .active {
                switch context.target.options.backgroundPolicy {
                case .suspend: context.target.suspend()
                case .stop:
                    if context.target.options.clearsAfterFinish { self.metalLayer.isHidden = true }
                    context.target.stop(reason: .stopped)
                }
            }
        }
    }

    /// 判断当前 ready session 能否直接 play；不能则取消旧 session 并创建新的。
    private func makePlayPreparation(
        url: URL,
        metadata suppliedMetadata: AssetMetadata?,
        options: PlaybackOptions,
        signature: OptionsSignature
    ) -> PlayPreparation {
        if
            let current = session,
            current.state == .ready,
            preparedURL == url,
            preparedOptions == signature,
            suppliedMetadata == nil || preparedMetadata === suppliedMetadata
        {
            return PlayPreparation(target: current, requiresPrepare: false)
        }
        replaceCurrentSession(reason: .cancelled)
        let target = makeSession(url: url, options: options)
        session = target
        return PlayPreparation(target: target, requiresPrepare: true)
    }

    /// 暂停当前 session，冻结媒体时钟。无 session 时为空操作。
    @objc public func pause() { session?.pause() }

    /// 从 pause / suspend 恢复。无 session 时为空操作。
    @objc public func resume() { session?.resume() }

    /// 停止当前 session。若 `clearsAfterFinish` 为 true，会隐藏 Metal 层。
    @objc public func stop() {
        _ = beginNewOperation()
        guard let session else { return }
        if session.options.clearsAfterFinish { metalLayer.isHidden = true }
        session.stop(reason: .stopped)
        if self.session?.token == session.token { self.session = nil }
        preparedURL = nil
        preparedMetadata = nil
        preparedOptions = nil
    }

    /// 停止并强制隐藏当前画面，不论 `clearsAfterFinish` 如何设置。
    @objc public func clear() {
        _ = beginNewOperation()
        metalLayer.isHidden = true
        if let session {
            session.stop(reason: .stopped)
            if self.session?.token == session.token { self.session = nil }
        }
        preparedURL = nil
        preparedMetadata = nil
        preparedOptions = nil
    }

    /// 深拷贝 options 后创建 session，并把 session 事件转发到 Swift / ObjC delegate。
    private func makeSession(url: URL, options: PlaybackOptions) -> PlaybackSession {
        let copiedOptions = options.copy() as! PlaybackOptions
        let session = PlaybackSession(
            url: url,
            options: copiedOptions,
            metalLayer: metalLayer,
            dynamicProvider: dynamicContentProvider,
            objcDynamicProvider: objcDynamicProvider
        )
        session.metricsSink = metricsSink
        session.onStart = { [weak self, weak session] in
            guard let self, let session, self.session?.token == session.token else { return }
            self.notifyStart()
        }
        session.onMetadata = { [weak self, weak session] metadata in
            guard let self, let session, self.session?.token == session.token else { return }
            self.notifyMetadata(metadata)
        }
        session.onFirstFrame = { [weak self, weak session] in
            guard let self, let session, self.session?.token == session.token else { return }
            self.metalLayer.isHidden = false
        }
        session.onFinish = { [weak self, weak session] reason in
            guard let self, let session, self.session?.token == session.token else { return }
            if session.options.clearsAfterFinish { self.metalLayer.isHidden = true }
            self.session = nil
            self.preparedURL = nil
            self.preparedMetadata = nil
            self.preparedOptions = nil
            self.notifyFinish(reason)
        }
        session.onFailure = { [weak self, weak session] error in
            guard let self, let session, self.session?.token == session.token else { return }
            self.session = nil
            self.preparedURL = nil
            self.preparedMetadata = nil
            self.preparedOptions = nil
            self.notifyFailure(error)
        }
        return session
    }

    /// 把当前视图尺寸和 contentMode 同步给 renderer，供 viewport 计算。
    private func updateSnapshot(for session: PlaybackSession) {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        session.updateRenderSnapshot(RenderSnapshot(
            drawableSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            contentMode: session.options.contentMode
        ))
    }

    /// 递增操作代数并取消进行中的 play Task，使过期异步结果失效。
    @discardableResult
    private func beginNewOperation() -> UInt64 {
        operationGeneration &+= 1
        playTask?.cancel()
        playTask = nil
        return operationGeneration
    }

    /// 停止并丢弃当前 session，同时清掉 prepared 快照。
    private func replaceCurrentSession(reason: FinishReason) {
        guard let session else { return }
        if session.options.clearsAfterFinish { metalLayer.isHidden = true }
        session.stop(reason: reason)
        if self.session?.token == session.token { self.session = nil }
        preparedURL = nil
        preparedMetadata = nil
        preparedOptions = nil
    }

    /// 监听进后台 / 回前台，把生命周期映射到 session 的 suspend / resume / stop。
    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
        // willResignActive arrives before iOS may suspend AVFoundation / Metal work.
        // Suspending early prevents an in-flight AVAssetReader from being reported as
        // a real decoder failure while the process is moving to the background.
        notificationTokens.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleBackground() }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleBackground() }
        })
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        })
    }

    /// 进入后台：按 `backgroundPolicy` 挂起或停止，不把后台当成播放完成。
    private func handleBackground() {
        guard let session else { return }
        switch session.options.backgroundPolicy {
        case .suspend: session.suspend()
        case .stop:
            if session.options.clearsAfterFinish { metalLayer.isHidden = true }
            session.stop(reason: .stopped)
        }
    }

    /// 回到前台且仍在 window、尺寸有效、状态为 suspended 时恢复播放。
    private func handleForeground() {
        guard window != nil, !bounds.isEmpty, let session, session.state == .suspended else { return }
        session.resume()
    }

    /// 同时通知 Swift 与 ObjC delegate。token 校验已在调用方完成。
    private func notifyStart() {
        delegate?.playerDidStart(self)
        objcDelegate?.playerViewDidStart?(self)
    }

    /// 把解析完成的 metadata 转发给两侧 delegate，供宿主按 `canvasSize` 布局。
    private func notifyMetadata(_ metadata: AssetMetadata) {
        delegate?.player(self, didUpdate: metadata)
        objcDelegate?.playerView?(self, didResolveMetadata: metadata)
    }

    /// 终态完成回调。每个 session 最多一次，不会再跟 fail。
    private func notifyFinish(_ reason: FinishReason) {
        delegate?.playerDidFinish(self, reason: reason)
        objcDelegate?.playerView?(self, didFinishWithReason: reason)
    }

    /// 不可恢复错误回调。每个 session 最多一次，不会再跟 finish。
    private func notifyFailure(_ error: Error) {
        delegate?.player(self, didFail: error)
        objcDelegate?.playerView?(self, didFailWithError: error as NSError)
    }
}

/// play 前对当前 session 的判定结果：复用 ready session，或必须重新 prepare。
private struct PlayPreparation {
    /// 即将用于 play 的 session。
    let target: PlaybackSession
    /// `true` 表示还要走 prepare；`false` 表示当前 session 已 ready，可直接 play。
    let requiresPrepare: Bool
}

/// `PlaybackOptions` 的不可变快照，用于判断 prepared session 是否仍匹配宿主配置。
private struct OptionsSignature: Equatable {
    let loopCount: Int
    let contentMode: UIView.ContentMode
    let audioMode: AudioMode
    let clearsAfterFinish: Bool
    let backgroundPolicy: BackgroundPolicy
    let dynamicImagePlaybackMode: DynamicImagePlaybackMode
    let dynamicTextOverflowMode: DynamicTextOverflowMode
    let marqueeSpeed: CGFloat
    let marqueeStartDelay: TimeInterval

    init(_ options: PlaybackOptions) {
        loopCount = options.loopCount
        contentMode = options.contentMode
        audioMode = options.audioMode
        clearsAfterFinish = options.clearsAfterFinish
        backgroundPolicy = options.backgroundPolicy
        dynamicImagePlaybackMode = options.dynamicImagePlaybackMode
        dynamicTextOverflowMode = options.dynamicTextOverflowMode
        marqueeSpeed = options.marqueeSpeed
        marqueeStartDelay = options.marqueeStartDelay
    }
}
