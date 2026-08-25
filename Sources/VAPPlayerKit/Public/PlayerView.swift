import UIKit
import Metal
import QuartzCore

/// 宿主唯一需要持有的播放视图。负责 UIKit 生命周期和公开控制；每一次新播放都拥有独立 session。
@objc(VPKPlayerView)
@MainActor
public final class PlayerView: UIView {
    public weak var delegate: PlayerDelegate?
    public weak var dynamicContentProvider: DynamicContentProvider?
    public weak var metricsSink: MetricsSink?

    @objc(delegate)
    public weak var objcDelegate: ObjCPlayerDelegate?
    @objc(dynamicContentProvider)
    public weak var objcDynamicProvider: ObjCDynamicContentProvider?

    private var session: PlaybackSession?
    private var preparedURL: URL?
    private var preparedMetadata: AssetMetadata?
    private var preparedOptions: OptionsSignature?
    private var operationGeneration: UInt64 = 0
    private var playTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []
    private let presentationLayer = CAMetalLayer()

    /// Metal presentation layer. It is kept separate from the UIView backing
    /// layer so internal drawable suppression never overrides host visibility.
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

    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        layer.addSublayer(metalLayer)
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.framebufferOnly = true
    }

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
    public func prepare(url: URL, options: PlaybackOptions = .defaultOptions) async throws -> AssetMetadata {
        try await prepareInternal(url: url, metadata: nil, options: options)
    }

    /// 使用本组件此前为同一 URL 解析出的 metadata 准备，跳过重复 MP4/vapc inspection。
    public func prepare(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions = .defaultOptions
    ) async throws -> AssetMetadata {
        try await prepareInternal(url: url, metadata: metadata, options: options)
    }

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
    @objc(playWithURL:options:)
    public func play(url: URL, options: PlaybackOptions = .defaultOptions) {
        playInternal(url: url, metadata: nil, options: options)
    }

    /// 使用本组件此前返回的 metadata 播放，避免重复 MP4/vapc inspection。
    @objc(playWithURL:metadata:options:)
    public func play(
        url: URL,
        metadata: AssetMetadata,
        options: PlaybackOptions = .defaultOptions
    ) {
        playInternal(url: url, metadata: metadata, options: options)
    }

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
            } else if self.window == nil {
                switch context.target.options.backgroundPolicy {
                case .suspend: context.target.suspend()
                case .stop:
                    if context.target.options.clearsAfterFinish { self.metalLayer.isHidden = true }
                    context.target.stop(reason: .stopped)
                }
            }
        }
    }

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

    @objc public func pause() { session?.pause() }

    @objc public func resume() { session?.resume() }

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

    private func updateSnapshot(for session: PlaybackSession) {
        let scale = window?.screen.scale ?? UIScreen.main.scale
        session.updateRenderSnapshot(RenderSnapshot(
            drawableSize: CGSize(width: bounds.width * scale, height: bounds.height * scale),
            contentMode: session.options.contentMode
        ))
    }

    @discardableResult
    private func beginNewOperation() -> UInt64 {
        operationGeneration &+= 1
        playTask?.cancel()
        playTask = nil
        return operationGeneration
    }

    private func replaceCurrentSession(reason: FinishReason) {
        guard let session else { return }
        if session.options.clearsAfterFinish { metalLayer.isHidden = true }
        session.stop(reason: reason)
        if self.session?.token == session.token { self.session = nil }
        preparedURL = nil
        preparedMetadata = nil
        preparedOptions = nil
    }

    private func observeApplicationLifecycle() {
        let center = NotificationCenter.default
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

    private func handleBackground() {
        guard let session else { return }
        switch session.options.backgroundPolicy {
        case .suspend: session.suspend()
        case .stop:
            if session.options.clearsAfterFinish { metalLayer.isHidden = true }
            session.stop(reason: .stopped)
        }
    }

    private func handleForeground() {
        guard window != nil, !bounds.isEmpty, let session, session.state == .suspended else { return }
        session.resume()
    }

    private func notifyStart() {
        delegate?.playerDidStart(self)
        objcDelegate?.playerViewDidStart?(self)
    }

    private func notifyMetadata(_ metadata: AssetMetadata) {
        delegate?.player(self, didUpdate: metadata)
        objcDelegate?.playerView?(self, didResolveMetadata: metadata)
    }

    private func notifyFinish(_ reason: FinishReason) {
        delegate?.playerDidFinish(self, reason: reason)
        objcDelegate?.playerView?(self, didFinishWithReason: reason)
    }

    private func notifyFailure(_ error: Error) {
        delegate?.player(self, didFail: error)
        objcDelegate?.playerView?(self, didFailWithError: error as NSError)
    }
}

private struct PlayPreparation {
    let target: PlaybackSession
    let requiresPrepare: Bool
}

private struct OptionsSignature: Equatable {
    let loopCount: Int
    let contentMode: UIView.ContentMode
    let audioMode: AudioMode
    let clearsAfterFinish: Bool
    let backgroundPolicy: BackgroundPolicy
    let dynamicImagePlaybackMode: DynamicImagePlaybackMode

    init(_ options: PlaybackOptions) {
        loopCount = options.loopCount
        contentMode = options.contentMode
        audioMode = options.audioMode
        clearsAfterFinish = options.clearsAfterFinish
        backgroundPolicy = options.backgroundPolicy
        dynamicImagePlaybackMode = options.dynamicImagePlaybackMode
    }
}
