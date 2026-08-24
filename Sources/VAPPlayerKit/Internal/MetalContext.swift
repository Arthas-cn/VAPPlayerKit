import Foundation
import Metal
import CoreVideo

/// The immutable Metal objects that are safe to share across renderers.
///
/// Pipeline compilation and texture-cache creation are intentionally owned by
/// this package-level context. Per-renderer state remains in `MetalRenderer`:
/// dynamic textures, snapshots, in-flight frame references and the drawable
/// layer are never shared.
struct MetalContextResources: @unchecked Sendable {
    let device: MTLDevice
    let library: MTLLibrary
    let pipeline: MTLRenderPipelineState
    let attachmentPipeline: MTLRenderPipelineState
    let attachmentPunchPipeline: MTLRenderPipelineState
    let textureCache: CVMetalTextureCache
    let sharedCommandQueue: MTLCommandQueue?
}

enum MetalCommandQueuePolicy: String, Sendable {
    case shared
    case perRenderer
}

/// Thread-safe package-level cache for device-scoped Metal resources.
///
/// `MTLCommandQueue` is configurable because queue sharing must be measured
/// on representative hardware. The production default is shared; tests and
/// the example benchmark can request `perRenderer` for an apples-to-apples
/// comparison without changing renderer code.
final class MetalContext: @unchecked Sendable {
    static let shared = MetalContext(policy: MetalContext.policyFromProcessArguments())

    let policy: MetalCommandQueuePolicy
    private let lock = NSLock()
    private var resources: MetalContextResources?
    private var resourceBuildCount = 0
    private var commandQueueBuildCount = 0
    private var activeTextureSubmissions = 0
    private var completedTextureSubmissions = 0
    private var lastTextureCacheFlushUptime = ProcessInfo.processInfo.systemUptime

    private let textureCacheFlushSubmissionInterval = 60
    private let textureCacheFlushTimeInterval: TimeInterval = 2

    init(policy: MetalCommandQueuePolicy = .shared) {
        self.policy = policy
    }

    func prepare(device: MTLDevice) throws -> MetalContextResources {
        lock.lock()
        defer { lock.unlock() }
        if let resources {
            guard resources.device === device else {
                throw PlaybackError.metalUnavailable
            }
            return resources
        }

        let library = try ShaderLibrary.make(device: device)
        guard
            let vertex = library.makeFunction(name: "vpk_vertex"),
            let fragment = library.makeFunction(name: "vpk_fragment"),
            let attachmentVertex = library.makeFunction(name: "vpk_attachment_vertex"),
            let attachmentFragment = library.makeFunction(name: "vpk_attachment_fragment"),
            let attachmentPunchFragment = library.makeFunction(name: "vpk_attachment_punch_fragment")
        else {
            throw PlaybackError.metalUnavailable
        }

        let pipeline = try Self.makePipeline(
            device: device,
            vertex: vertex,
            fragment: fragment,
            blending: .premultipliedOver
        )
        let attachmentPipeline = try Self.makePipeline(
            device: device,
            vertex: attachmentVertex,
            fragment: attachmentFragment,
            blending: .premultipliedOver
        )
        let attachmentPunchPipeline = try Self.makePipeline(
            device: device,
            vertex: attachmentVertex,
            fragment: attachmentPunchFragment,
            blending: .destinationTimesOneMinusSourceAlpha
        )
        var textureCache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache) == kCVReturnSuccess,
              let textureCache
        else {
            throw PlaybackError.metalUnavailable
        }

        let sharedCommandQueue: MTLCommandQueue?
        if policy == .shared {
            guard let queue = device.makeCommandQueue() else {
                throw PlaybackError.metalUnavailable
            }
            sharedCommandQueue = queue
            commandQueueBuildCount += 1
        } else {
            sharedCommandQueue = nil
        }

        let resources = MetalContextResources(
            device: device,
            library: library,
            pipeline: pipeline,
            attachmentPipeline: attachmentPipeline,
            attachmentPunchPipeline: attachmentPunchPipeline,
            textureCache: textureCache,
            sharedCommandQueue: sharedCommandQueue
        )
        self.resources = resources
        resourceBuildCount += 1
        return resources
    }

    func makeCommandQueue(for resources: MetalContextResources) throws -> MTLCommandQueue {
        if let sharedCommandQueue = resources.sharedCommandQueue {
            return sharedCommandQueue
        }
        lock.lock()
        defer { lock.unlock() }
        guard let queue = resources.device.makeCommandQueue() else {
            throw PlaybackError.metalUnavailable
        }
        commandQueueBuildCount += 1
        return queue
    }

    func metrics() -> (resourceBuilds: Int, commandQueueBuilds: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (resourceBuildCount, commandQueueBuildCount)
    }

    /// Create the two NV12 plane textures and register their submission under
    /// one cache lock. Counting before returning closes the gap in which a
    /// renderer owns cache references but an idle flush could otherwise see
    /// zero active submissions.
    func makePlaneTexturesAndBeginSubmission(
        for pixelBuffer: CVPixelBuffer
    ) throws -> (y: CVMetalTexture, uv: CVMetalTexture) {
        lock.lock()
        defer { lock.unlock() }
        guard let textureCache = resources?.textureCache else {
            throw PlaybackError.metalUnavailable
        }
        var yReference: CVMetalTexture?
        var uvReference: CVMetalTexture?
        let yStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .r8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0, &yReference
        )
        let uvStatus = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixelBuffer, nil, .rg8Unorm,
            CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
            CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &uvReference
        )
        guard
            yStatus == kCVReturnSuccess,
            uvStatus == kCVReturnSuccess,
            let yReference,
            let uvReference
        else {
            throw PlaybackError.decoderFailed(osStatus: Int32(yStatus != kCVReturnSuccess ? yStatus : uvStatus))
        }
        activeTextureSubmissions += 1
        return (yReference, uvReference)
    }

    func endTextureSubmission() {
        lock.lock()
        activeTextureSubmissions = max(0, activeTextureSubmissions - 1)
        completedTextureSubmissions += 1
        flushTextureCacheIfNeededLocked(force: false)
        lock.unlock()
    }

    /// Cancel a submission that failed before a command buffer was committed.
    /// Do not run the completion/flush path while the caller still owns the
    /// temporary CVMetalTexture references; they leave scope immediately
    /// after this method returns.
    func cancelTextureSubmission() {
        lock.lock()
        activeTextureSubmissions = max(0, activeTextureSubmissions - 1)
        lock.unlock()
    }

    /// Flush only when no submitted frame still owns a CVMetalTexture. This is
    /// called after renderer disposal and periodically during long playback;
    /// a renderer never flushes another renderer's in-flight cache entries.
    func flushTextureCacheIfIdle() {
        lock.lock()
        flushTextureCacheIfNeededLocked(force: true)
        lock.unlock()
    }

    private func flushTextureCacheIfNeededLocked(force: Bool) {
        guard activeTextureSubmissions == 0 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = force ||
            completedTextureSubmissions >= textureCacheFlushSubmissionInterval ||
            now - lastTextureCacheFlushUptime >= textureCacheFlushTimeInterval
        guard due, let textureCache = resources?.textureCache else { return }
        CVMetalTextureCacheFlush(textureCache, 0)
        completedTextureSubmissions = 0
        lastTextureCacheFlushUptime = now
    }

    private enum ColorBlending {
        /// Video and overlay paths output premultiplied RGB/A.
        case premultipliedOver
        /// Multiply the destination by `(1 - src.a)` to knock out the near-black locator.
        case destinationTimesOneMinusSourceAlpha
    }

    private static func makePipeline(
        device: MTLDevice,
        vertex: MTLFunction,
        fragment: MTLFunction,
        blending: ColorBlending
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        switch blending {
        case .premultipliedOver:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .destinationTimesOneMinusSourceAlpha:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .zero
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .zero
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func policyFromProcessArguments() -> MetalCommandQueuePolicy {
        let prefix = "-vap-metal-command-queue-policy="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return .shared
        }
        return MetalCommandQueuePolicy(rawValue: String(argument.dropFirst(prefix.count))) ?? .shared
    }
}
