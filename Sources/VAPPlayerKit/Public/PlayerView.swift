import UIKit
import Metal
import QuartzCore

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

    public override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

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

    private func configureLayer() {
        isOpaque = false
        backgroundColor = .clear
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.framebufferOnly = true
    }

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

    @objc public func pause() {
        session?.pause()
    }

    @objc public func resume() {
        session?.resume()
    }

    @objc public func stop() {
        session?.stop()
        session = nil
        notifyFinish(.stopped)
    }

    @objc public func clear() {
        stop()
        preparedURL = nil
        preparedMetadata = nil
        metalLayer.contents = nil
    }

    private func inspect(url: URL) async throws -> AssetMetadata {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound
        }
        return try await AssetInspector().inspect(url: url)
    }

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
