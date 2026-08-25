import Foundation
import Metal
import CoreVideo

/// 可在多个 renderer 之间安全共享的不可变 Metal 对象。
///
/// Pipeline 编译和 texture cache 创建由包级 context 持有。
/// 每个 `MetalRenderer` 仍独占动态纹理、snapshot、in-flight 帧引用和 drawable layer。
struct MetalContextResources: @unchecked Sendable {
    /// 创建这些资源时使用的 MTLDevice。后续 prepare 必须是同一 device。
    let device: MTLDevice
    /// 已编译的 VPK shader library。
    let library: MTLLibrary
    /// packed 视频底图。
    let pipeline: MTLRenderPipelineState
    /// 动态 overlay 正向混合。
    let attachmentPipeline: MTLRenderPipelineState
    /// 图片槽位打孔（抠近黑 locator）。
    let attachmentPunchPipeline: MTLRenderPipelineState
    /// NV12 plane 转 Metal 纹理的共享 cache。
    let textureCache: CVMetalTextureCache
    /// `shared` 策略下所有 renderer 共用的 command queue；`perRenderer` 时为 nil。
    let sharedCommandQueue: MTLCommandQueue?
}

/// command queue 共享策略。生产默认 shared；测试可用进程参数切到 perRenderer 做对比。
enum MetalCommandQueuePolicy: String, Sendable {
    /// 整个进程共用一条 command queue。
    case shared
    /// 每个 renderer 各自创建 queue，便于基准测试隔离。
    case perRenderer
}

/// 线程安全的包级 Metal 资源缓存。按 MTLDevice 复用 pipeline 和 texture cache。
final class MetalContext: @unchecked Sendable {
    /// 进程内默认实例。策略可由 `-vap-metal-command-queue-policy=` 覆盖。
    static let shared = MetalContext(policy: MetalContext.policyFromProcessArguments())

    let policy: MetalCommandQueuePolicy
    private let lock = NSLock()
    /// 首次 prepare 后缓存的共享资源。
    private var resources: MetalContextResources?
    private var resourceBuildCount = 0
    private var commandQueueBuildCount = 0
    /// 仍持有 CVMetalTexture 的提交数。非 0 时禁止 flush cache。
    private var activeTextureSubmissions = 0
    private var completedTextureSubmissions = 0
    private var lastTextureCacheFlushUptime = ProcessInfo.processInfo.systemUptime

    /// 完成这么多次提交后，若 cache 空闲则 flush。
    private let textureCacheFlushSubmissionInterval = 60
    /// 距上次 flush 超过该秒数且 cache 空闲则 flush。
    private let textureCacheFlushTimeInterval: TimeInterval = 2

    /// 默认 shared 策略。测试可传入 `perRenderer` 做对比。
    /// 默认 shared。测试可传入 `perRenderer` 做 queue 隔离对比。
    /// 默认 shared queue。测试可传入 `.perRenderer` 做对照。
    init(policy: MetalCommandQueuePolicy = .shared) {
        self.policy = policy
    }

    /// 编译 shader / pipeline，并创建共享 texture cache。同一 device 只构建一次。
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

    /// shared 策略返回缓存 queue；perRenderer 策略为调用方新建一条。
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

    /// 测试用：资源构建次数和 command queue 创建次数。
    func metrics() -> (resourceBuilds: Int, commandQueueBuilds: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (resourceBuildCount, commandQueueBuildCount)
    }

    /// 在同一把 cache 锁下创建 NV12 的 Y/UV 纹理并登记一次提交。
    /// 先计数再返回，避免 renderer 已持有引用时 idle flush 误判「零活跃提交」。
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

    /// GPU 完成后减少活跃计数，并在空闲时按间隔 flush cache。
    func endTextureSubmission() {
        lock.lock()
        activeTextureSubmissions = max(0, activeTextureSubmissions - 1)
        completedTextureSubmissions += 1
        flushTextureCacheIfNeededLocked(force: false)
        lock.unlock()
    }

    /// 取消尚未 commit 的提交。调用方仍持有临时 CVMetalTexture 时不要走 completion/flush。
    func cancelTextureSubmission() {
        lock.lock()
        activeTextureSubmissions = max(0, activeTextureSubmissions - 1)
        lock.unlock()
    }

    /// 仅在没有任何 in-flight CVMetalTexture 时 flush。renderer dispose 后以及长播放期间周期性调用。
    func flushTextureCacheIfIdle() {
        lock.lock()
        flushTextureCacheIfNeededLocked(force: true)
        lock.unlock()
    }

    /// 空闲且达到提交次数或时间间隔时 flush texture cache。`force` 用于 dispose 路径。
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

    /// 视频输出预乘 RGB/A；打孔路径用 `(1 - src.a)` 乘目标色，抠掉近黑 locator。
    private enum ColorBlending {
        /// 视频和 overlay 输出预乘 RGB/A。
        case premultipliedOver
        /// 目标色乘 `(1 - src.a)`，用于打孔。
        case destinationTimesOneMinusSourceAlpha
    }

    /// 按混合模式编译 render pipeline。视频和 overlay 用预乘 over；打孔用 dst * (1-src.a)。
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

    /// 从进程启动参数读取 queue 策略，便于 example / 测试切换而不改代码。
    private static func policyFromProcessArguments() -> MetalCommandQueuePolicy {
        let prefix = "-vap-metal-command-queue-policy="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return .shared
        }
        return MetalCommandQueuePolicy(rawValue: String(argument.dropFirst(prefix.count))) ?? .shared
    }
}
