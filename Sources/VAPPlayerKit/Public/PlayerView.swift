import UIKit
import Metal
import QuartzCore

/// 宿主唯一需要持有的播放视图。负责 UIKit 生命周期和公开控制，不解析 MP4、不创建 VT session。
///
/// 运行时 ObjC 名为 `VPKPlayerView`。对照 `vap-master` 的 `UIView+VAP`，但不再做成 category。
/// 所有控制方法和 delegate 回调都在主线程。每一次 `play` 创建新的 `PlaybackSession`。
@objc(VPKPlayerView)
@MainActor
public final class PlayerView: UIView {
    /// Swift 播放回调。弱引用，避免和 UIView 循环持有。
    public weak var delegate: PlayerDelegate?
    /// Swift 动态内容提供者。网络和图片库仍由宿主实现。
    public weak var dynamicContentProvider: DynamicContentProvider?
    /// 可选埋点。为空则不记录。
    public weak var metricsSink: MetricsSink?

    /// Objective-C 回调，导出属性名为 `delegate`。
    @objc(delegate)
    public weak var objcDelegate: ObjCPlayerDelegate?
    /// Objective-C 动态内容提供者，导出属性名为 `dynamicContentProvider`。
    @objc(dynamicContentProvider)
    public weak var objcDynamicProvider: ObjCDynamicContentProvider?

    /// 当前播放 session。新资源到来时先 stop 旧 session。
    private var session: PlaybackSession?
    /// 最近一次成功 prepare 的本地文件，供 play 复用 metadata。
    private var preparedURL: URL?
    /// 与 `preparedURL` 对应的不可变 metadata。
    private var preparedMetadata: AssetMetadata?

    /// 使用 `CAMetalLayer` 作为 backing layer，后续由 `MetalRenderer` 写入 premultiplied alpha。
    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    /// 类型安全的 Metal layer 访问。只在主线程读取 bounds / drawableSize。
    public var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayer()
    }

    @objc public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayer()
    }

    /// 透明特效需要非不透明 layer，并按屏幕 scale 设置 drawable。
    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.framebufferOnly = true
    }

    /// 同步 drawableSize。render queue 不得自己读 UIView.bounds。
    public override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
        if drawableSize.width > 0, drawableSize.height > 0 {
            metalLayer.drawableSize = drawableSize
        }
    }

    /// Swift 异步准备：解析 metadata，不自动播放。
    /// - Parameters:
    ///   - url: 本地 file URL。
    ///   - options: 播放配置；Phase 1 起会参与 fallback 规则。
    /// - Returns: 不可变 `AssetMetadata`。
    public func prepare(
        url: URL,
        options: PlaybackOptions = .defaultOptions
    ) async throws -> AssetMetadata {
        let metadata = try await inspect(url: url)
        preparedURL = url
        preparedMetadata = metadata
        notifyMetadata(metadata)
        return metadata
    }

    /// Objective-C 入口。内部转到 async `prepare`，completion 只回调一次。
    @objc(prepareWithURL:options:completion:)
    public func prepare(
        url: URL,
        options: PlaybackOptions,
        completion: @escaping (AssetMetadata?, NSError?) -> Void
    ) {
        Task { @MainActor in
            do {
                let metadata = try await prepare(url: url, options: options)
                completion(metadata, nil)
            } catch {
                completion(nil, (error as NSError))
            }
        }
    }

    /// 直接播放。若尚未 prepare 会先走 inspect；资源已准备好则复用 metadata。
    ///
    /// 当前 Phase 0 在 inspect 阶段仍会因 parser stub 失败，这是预期行为。
    @objc(playWithURL:options:)
    public func play(url: URL, options: PlaybackOptions = .defaultOptions) {
        Task { @MainActor in
            do {
                _ = try await prepare(url: url, options: options)
                startSession(url: url, options: options)
            } catch {
                notifyFailure(error)
            }
        }
    }

    /// 暂停当前 session，冻结媒体时钟。未在 playing 时是空操作。
    @objc public func pause() {
        session?.pause()
    }

    /// 从 paused / suspended 恢复。不会重建 decoder。
    @objc public func resume() {
        session?.resume()
    }

    /// 取消当前 session 并发送 `stopped`。随后不会再出现旧 token 的 start / fail。
    @objc public func stop() {
        session?.stop()
        session = nil
        notifyFinish(.stopped)
    }

    /// 停止播放并释放当前画面。用于从窗口移除前的显式回收。
    @objc public func clear() {
        stop()
        preparedURL = nil
        preparedMetadata = nil
        metalLayer.contents = nil
    }

    /// 主线程校验 URL 后，把解析交给 `AssetInspector`（后台）。
    private func inspect(url: URL) async throws -> AssetMetadata {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound
        }
        return try await AssetInspector().inspect(url: url)
    }

    /// 停掉旧 session，拷贝 options 后创建新 session。
    private func startSession(url: URL, options: PlaybackOptions) {
        session?.stop()
        let newSession = PlaybackSession(url: url, options: options.copy() as! PlaybackOptions)
        session = newSession
        notifyStart()
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
