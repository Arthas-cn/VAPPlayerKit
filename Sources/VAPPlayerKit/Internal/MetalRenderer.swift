import Foundation
import UIKit
import Metal
import CoreVideo
import QuartzCore
import simd

/// 当前 drawable 尺寸和内容缩放方式。由主线程写入，renderer 在 render queue 读取。
struct RenderSnapshot: Sendable {
    /// 像素尺寸，已乘 screen scale。
    let drawableSize: CGSize
    /// 按 vapc `canvasSize` 计算 viewport，不用编码分辨率。
    let contentMode: UIView.ContentMode
}

/// 视频底图 fragment 的 RGB/Alpha 采样区域、模式和 YCbCr 矩阵。
private struct FrameUniforms {
    var rgbRect: SIMD4<Float>
    var alphaRect: SIMD4<Float>
    var colorMatrix: UInt32
    var alphaEnabled: UInt32
    var padding = SIMD2<UInt32>(repeating: 0)
}

/// 动态槽位 overlay 的画布矩形、mask 区域、旋转和 source UV 窗口。
private struct AttachmentUniforms {
    var renderRect: SIMD4<Float>
    var maskRect: SIMD4<Float>
    var rgbRect: SIMD4<Float>
    var sourceUVOrigin: SIMD2<Float>
    var sourceUVSize: SIMD2<Float>
    var rotation: UInt32
    var colorMatrix: UInt32
    var padding = SIMD2<UInt32>(repeating: 0)
}

/// 动态纹理上的可见采样窗口。静图 / 动图为整张；跑马灯为滑动矩形。
private struct SourceUV {
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    static let identity = SourceUV(origin: SIMD2(0, 0), size: SIMD2(1, 1))
}

/// GPU 尚未完成时必须继续持有的帧资源。共享 texture cache 由 `MetalContext` 持有；
/// 这些引用必须在 context 允许 idle flush 之前释放。
private final class InFlightFrameResources: @unchecked Sendable {
    private var frame: DecodedFrame?
    private var yReference: CVMetalTexture?
    private var uvReference: CVMetalTexture?

    init(frame: DecodedFrame, yReference: CVMetalTexture, uvReference: CVMetalTexture) {
        self.frame = frame
        self.yReference = yReference
        self.uvReference = uvReference
    }

    /// command buffer 完成后丢掉 CVPixelBuffer / CVMetalTexture，才能安全 flush cache。
    func releaseReferences() {
        frame = nil
        yReference = nil
        uvReference = nil
    }
}

/// 将 NV12 pixel buffer 中的 packed RGB/Alpha 区域合成到 `CAMetalLayer`。
/// 可变状态限制在 `renderQueue`；MainActor 只传入不可变 snapshot。
final class MetalRenderer: @unchecked Sendable {
    private let context: MetalContext
    /// 所有 GPU 提交和动态纹理更新都在这条队列串行执行。
    private let renderQueue = DispatchQueue(label: "com.vapplayerkit.renderer", qos: .userInteractive)
    /// 跟踪尚未完成的 command buffer，dispose 时必须等它归零。
    private let inFlight = DispatchGroup()
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    /// packed 视频底图 pipeline。
    private var pipeline: MTLRenderPipelineState?
    /// 动态 overlay 正向混合 pipeline。
    private var attachmentPipeline: MTLRenderPipelineState?
    /// 图片槽位先打孔（抠掉近黑 locator）再用的 pipeline。
    private var attachmentPunchPipeline: MTLRenderPipelineState?
    /// 按 vapc source id 缓存的动态纹理。
    private var dynamicTextures: [String: MTLTexture] = [:]
    /// 按 vapc source id 缓存的动态纹理 UV 窗口。缺省视为整张纹理。
    private var sourceUVs: [String: SourceUV] = [:]
    private weak var layer: CAMetalLayer?
    private var snapshot = RenderSnapshot(drawableSize: .zero, contentMode: .scaleAspectFit)
    /// dispose 后拒绝新的 render / 动态纹理更新。
    private var disposed = false

    init(context: MetalContext = .shared) {
        self.context = context
    }

    /// layer 的 UIKit 属性由调用方在主线程准备；shader 与 pipeline 在 render queue 编译。
    @MainActor
    func prepare(layer: CAMetalLayer) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw PlaybackError.metalUnavailable
        }
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = false
        self.layer = layer

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            renderQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: PlaybackError.cancelled)
                    return
                }
                do {
                    let resources = try self.context.prepare(device: device)
                    self.device = resources.device
                    self.commandQueue = try self.context.makeCommandQueue(for: resources)
                    self.library = resources.library
                    self.pipeline = resources.pipeline
                    self.attachmentPipeline = nil
                    self.attachmentPunchPipeline = nil
                    self.disposed = false
                    continuation.resume(returning: ())
                } catch let error as PlaybackError {
                    continuation.resume(throwing: error)
                } catch {
                    continuation.resume(throwing: PlaybackError.metalUnavailable)
                }
            }
        }
    }

    /// 把动态槽位 UIImage 上传为 Metal 纹理。超出单张 / 整场字节上限时失败。
    func prepareDynamic(_ snapshot: DynamicSnapshot) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            renderQueue.async { [weak self] in
                guard let self, let device = self.device, !self.disposed else {
                    continuation.resume(throwing: PlaybackError.cancelled)
                    return
                }
                do {
                    let needsAttachments = snapshot.contents.contains { content in
                        if case .hidden = content.value { return false }
                        return true
                    }
                    if needsAttachments {
                        let pipelines = try self.context.prepareAttachmentPipelines(device: device)
                        self.attachmentPipeline = pipelines.overlay
                        self.attachmentPunchPipeline = pipelines.punch
                    } else {
                        self.attachmentPipeline = nil
                        self.attachmentPunchPipeline = nil
                    }
                    var textures: [String: MTLTexture] = [:]
                    var uvs: [String: SourceUV] = [:]
                    var totalBytes = 0
                    for (id, content) in snapshot.contents {
                        let image: UIImage?
                        var uv = SourceUV.identity
                        switch content {
                        case .image(let value):
                            image = value
                        case .animated(let slot):
                            image = slot.firstFrame
                        case .marquee(let slot):
                            image = slot.strip
                            let window = MarqueeLayout.sourceUV(
                                offset: 0,
                                slotWidth: slot.slotWidth,
                                textureWidth: slot.textureWidth
                            )
                            uv = SourceUV(origin: window.origin, size: window.size)
                        case .hidden:
                            continue
                        }
                        guard let image, let cgImage = image.cgImage else { continue }
                        guard
                            let bytes = DynamicTextureLimits.byteCount(width: cgImage.width, height: cgImage.height),
                            bytes <= DynamicTextureLimits.maximumBytesPerTexture,
                            totalBytes <= DynamicTextureLimits.maximumBytesPerSession - bytes
                        else {
                            throw PlaybackError.metalUnavailable
                        }
                        totalBytes += bytes
                        textures[id] = try Self.makeDynamicTexture(cgImage: cgImage, device: device)
                        uvs[id] = uv
                    }
                    self.dynamicTextures = textures
                    self.sourceUVs = uvs
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: PlaybackError.metalUnavailable)
                }
            }
        }
    }

    /// 把 UIKit / TextKit 输出规范成左上角原点的 RGBA8 表面再上传。
    /// `MTKTextureLoader` 会拒绝部分设备扩展色域 CGImage，因此走手工 bitmap。
    static func makeDynamicTexture(cgImage: CGImage, device: MTLDevice) throws -> MTLTexture {
        let width = cgImage.width
        let height = cgImage.height
        guard
            let byteCount = DynamicTextureLimits.byteCount(width: width, height: height),
            byteCount <= DynamicTextureLimits.maximumBytesPerTexture
        else {
            throw PlaybackError.metalUnavailable
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let bytes = context.data else {
            throw PlaybackError.metalUnavailable
        }
        // DynamicResolver 已经把图片和替换文字栅格化成左上角原点的 RGBA。
        // Metal 纹理坐标同源，这里不要再做常见的 CGImage 垂直翻转，否则动态素材会上下颠倒。
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            let count = width * height
            for index in 0..<count {
                let offset = index * 4
                if pixels[offset + 3] == 0 {
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                }
            }
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PlaybackError.metalUnavailable
        }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: width * 4
        )
        return texture
    }

    /// 主线程更新 viewport 计算所需的 drawable 尺寸和 contentMode。
    func update(snapshot: RenderSnapshot) {
        renderQueue.async { [weak self] in self?.snapshot = snapshot }
    }

    /// 动图槽位换帧时替换对应 source id 的纹理。已 dispose 则忽略。
    func updateDynamicTexture(id: String, image: UIImage) {
        renderQueue.async { [weak self] in
            guard let self, let device = self.device, !self.disposed, let cgImage = image.cgImage else { return }
            guard let texture = try? Self.makeDynamicTexture(cgImage: cgImage, device: device) else { return }
            self.dynamicTextures[id] = texture
        }
    }

    /// 跑马灯换窗时更新对应 source id 的采样矩形。已 dispose 则忽略。
    func updateSourceUV(id: String, origin: SIMD2<Float>, size: SIMD2<Float>) {
        renderQueue.async { [weak self] in
            guard let self, !self.disposed else { return }
            self.sourceUVs[id] = SourceUV(origin: origin, size: size)
        }
    }

    /// 提交一帧。返回 false 表示 drawable 暂不可用；这不是播放终态。
    func render(
        _ frame: DecodedFrame,
        vapc: VapcDocument,
        didSubmit: @escaping (CFTimeInterval) -> Void,
        completion: @escaping (Result<Bool, PlaybackError>) -> Void
    ) {
        renderQueue.async { [weak self] in
            guard let self, !self.disposed else {
                completion(.failure(.cancelled))
                return
            }
            do {
                let submitted = try self.encode(frame, vapc: vapc, didSubmit: didSubmit) { result in
                    completion(result)
                }
                if !submitted { completion(.success(false)) }
            } catch let error as PlaybackError {
                completion(.failure(error))
            } catch {
                completion(.failure(.metalUnavailable))
            }
        }
    }

    /// 编码一帧：清屏、画 packed 视频、再按 zIndex 叠加动态槽位。
    /// 返回 `false` 表示 drawable 暂不可用，调用方应保留该帧下次再试。
    private func encode(
        _ frame: DecodedFrame,
        vapc: VapcDocument,
        didSubmit: @escaping (CFTimeInterval) -> Void,
        completion: @escaping (Result<Bool, PlaybackError>) -> Void
    ) throws -> Bool {
        guard
            let layer,
            snapshot.drawableSize.width > 0,
            snapshot.drawableSize.height > 0
        else { return false }
        guard
            let commandQueue,
            let pipeline,
            let drawable = layer.nextDrawable()
        else { return false }
        let pixelBuffer = frame.pixelBuffer
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            throw PlaybackError.decoderFailed(osStatus: -1)
        }

        let planeTextures = try context.makePlaneTexturesAndBeginSubmission(for: pixelBuffer)
        let yReference = planeTextures.y
        let uvReference = planeTextures.uv
        guard
            let yTexture = CVMetalTextureGetTexture(yReference),
            let uvTexture = CVMetalTextureGetTexture(uvReference)
        else {
            context.cancelTextureSubmission()
            throw PlaybackError.decoderFailed(osStatus: -1)
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            context.cancelTextureSubmission()
            throw PlaybackError.metalUnavailable
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            context.cancelTextureSubmission()
            throw PlaybackError.metalUnavailable
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setViewport(Self.viewport(
            drawableSize: snapshot.drawableSize,
            canvasSize: vapc.canvasSize,
            contentMode: snapshot.contentMode
        ))
        encoder.setFragmentTexture(yTexture, index: 0)
        encoder.setFragmentTexture(uvTexture, index: 1)
        var uniforms = FrameUniforms(
            rgbRect: normalized(vapc.rgbRect, within: vapc.encodedVideoSize),
            alphaRect: normalized(vapc.alphaRect, within: vapc.encodedVideoSize),
            colorMatrix: colorMatrix(for: pixelBuffer),
            alphaEnabled: vapc.alphaMode == .none ? 0 : 1
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        for attachment in vapc.frames[frame.index] ?? [] {
            guard let texture = dynamicTextures[attachment.sourceID] else { continue }
            guard let attachmentPipeline else { throw PlaybackError.metalUnavailable }
            let uv = sourceUVs[attachment.sourceID] ?? .identity
            var attachmentUniforms = AttachmentUniforms(
                renderRect: normalized(attachment.renderRect, within: vapc.canvasSize),
                maskRect: normalized(attachment.maskRect, within: vapc.encodedVideoSize),
                rgbRect: uniforms.rgbRect,
                sourceUVOrigin: uv.origin,
                sourceUVSize: uv.size,
                rotation: UInt32(max(0, attachment.maskRotation)),
                colorMatrix: uniforms.colorMatrix
            )
            encoder.setVertexBytes(
                &attachmentUniforms,
                length: MemoryLayout<AttachmentUniforms>.stride,
                index: 0
            )
            encoder.setFragmentBytes(
                &attachmentUniforms,
                length: MemoryLayout<AttachmentUniforms>.stride,
                index: 0
            )
            encoder.setFragmentTexture(yTexture, index: 0)
            encoder.setFragmentTexture(uvTexture, index: 1)
            encoder.setFragmentTexture(texture, index: 2)
            // 图片槽位把彩色动画 (A) 压在近黑 locator (B) 上。
            // 先打孔只抠掉 B，再叠加 C，让礼物透明像素透出 A；文字槽位不打孔。
            if attachment.kind == .image {
                guard let attachmentPunchPipeline else { throw PlaybackError.metalUnavailable }
                encoder.setRenderPipelineState(attachmentPunchPipeline)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }
            encoder.setRenderPipelineState(attachmentPipeline)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        let resources = InFlightFrameResources(
            frame: frame,
            yReference: yReference,
            uvReference: uvReference
        )
        inFlight.enter()
        commandBuffer.addCompletedHandler { [context, inFlight, resources] commandBuffer in
            if commandBuffer.status == .completed {
                completion(.success(true))
            } else {
                completion(.failure(.metalUnavailable))
            }
            // `DispatchGroup.notify` 可能在 leave() 后立刻跑。
            // 先丢掉 CVMetalTexture 引用再减少 context 计数，避免 idle flush 与析构竞态。
            resources.releaseReferences()
            context.endTextureSubmission()
            inFlight.leave()
        }
        commandBuffer.commit()
        // Count a rendered frame at the same boundary as the legacy renderer:
        // after the command buffer is submitted, before GPU completion.
        didSubmit(CACurrentMediaTime())
        return true
    }

    /// 等待所有已提交 command buffer 完成后再释放本 session 的 GPU 对象。
    /// 共享 texture cache 仍由 context 持有，这里只拆除 renderer 私有状态。
    func dispose() {
        renderQueue.async { [self] in
            self.disposed = true
            self.inFlight.notify(queue: self.renderQueue) { [self] in
                self.releaseResources()
            }
        }
    }

    /// 释放 pipeline / 动态纹理 / command queue。texture cache 可能仍被其他 renderer 使用。
    private func releaseResources() {
        pipeline = nil
        attachmentPipeline = nil
        attachmentPunchPipeline = nil
        dynamicTextures.removeAll()
        sourceUVs.removeAll()
        library = nil
        commandQueue = nil
        device = nil
        layer = nil
        context.flushTextureCacheIfIdle()
    }

    /// 按 `canvasSize` + `contentMode` 计算 Metal viewport。AspectFit / Fill 居中，Fill 铺满。
    static func viewport(drawableSize: CGSize, canvasSize: CGSize, contentMode: UIView.ContentMode) -> MTLViewport {
        guard drawableSize.width > 0, drawableSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else {
            return MTLViewport(originX: 0, originY: 0, width: 0, height: 0, znear: 0, zfar: 1)
        }
        if contentMode == .scaleToFill {
            return MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)
        }
        let widthScale = drawableSize.width / canvasSize.width
        let heightScale = drawableSize.height / canvasSize.height
        let scale = contentMode == .scaleAspectFill ? max(widthScale, heightScale) : min(widthScale, heightScale)
        let width = canvasSize.width * scale
        let height = canvasSize.height * scale
        return MTLViewport(
            originX: (drawableSize.width - width) / 2,
            originY: (drawableSize.height - height) / 2,
            width: width,
            height: height,
            znear: 0,
            zfar: 1
        )
    }

    /// 把像素矩形归一化到 0...1，供 shader 采样。
    private func normalized(_ rect: CGRect, within size: CGSize) -> SIMD4<Float> {
        SIMD4(
            Float(rect.minX / size.width),
            Float(rect.minY / size.height),
            Float(rect.width / size.width),
            Float(rect.height / size.height)
        )
    }

    /// AVFoundation 会把轨道矩阵写到 pixel buffer。未知 / BT.2020 按 BT.709 处理。
    private func colorMatrix(for pixelBuffer: CVPixelBuffer) -> UInt32 {
        let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        return attachment == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ? 0 : 1
    }
}
