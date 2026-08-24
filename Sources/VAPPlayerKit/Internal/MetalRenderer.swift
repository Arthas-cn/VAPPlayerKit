import Foundation
import UIKit
import Metal
import CoreVideo
import QuartzCore
import simd

struct RenderSnapshot: Sendable {
    let drawableSize: CGSize
    let contentMode: UIView.ContentMode
}

private struct FrameUniforms {
    var rgbRect: SIMD4<Float>
    var alphaRect: SIMD4<Float>
    var colorMatrix: UInt32
    var padding = SIMD3<UInt32>(repeating: 0)
}

private struct AttachmentUniforms {
    var renderRect: SIMD4<Float>
    var maskRect: SIMD4<Float>
    var rotation: UInt32
    var padding = SIMD3<UInt32>(repeating: 0)
}

/// Resources whose lifetime must extend through GPU completion. The shared
/// texture cache is owned by `MetalContext`; these references are released
/// before the context is allowed to perform an idle flush.
private final class InFlightFrameResources: @unchecked Sendable {
    private var frame: DecodedFrame?
    private var yReference: CVMetalTexture?
    private var uvReference: CVMetalTexture?

    init(frame: DecodedFrame, yReference: CVMetalTexture, uvReference: CVMetalTexture) {
        self.frame = frame
        self.yReference = yReference
        self.uvReference = uvReference
    }

    func releaseReferences() {
        frame = nil
        yReference = nil
        uvReference = nil
    }
}

/// 将 NV12 pixel buffer 中的 packed RGB/Alpha 区域合成到 `CAMetalLayer`。
/// Mutable state is confined to `renderQueue`; MainActor only hands in immutable snapshots.
final class MetalRenderer: @unchecked Sendable {
    private let context: MetalContext
    private let renderQueue = DispatchQueue(label: "com.vapplayerkit.renderer", qos: .userInteractive)
    private let inFlight = DispatchGroup()
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    private var pipeline: MTLRenderPipelineState?
    private var attachmentPipeline: MTLRenderPipelineState?
    private var dynamicTextures: [String: MTLTexture] = [:]
    private weak var layer: CAMetalLayer?
    private var snapshot = RenderSnapshot(drawableSize: .zero, contentMode: .scaleAspectFit)
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
                    self.attachmentPipeline = resources.attachmentPipeline
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

    func prepareDynamic(_ snapshot: DynamicSnapshot) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            renderQueue.async { [weak self] in
                guard let self, let device = self.device, !self.disposed else {
                    continuation.resume(throwing: PlaybackError.cancelled)
                    return
                }
                do {
                    var textures: [String: MTLTexture] = [:]
                    var totalBytes = 0
                    for (id, content) in snapshot.contents {
                        guard case .image(let image) = content, let cgImage = image.cgImage else { continue }
                        guard
                            let bytes = DynamicTextureLimits.byteCount(width: cgImage.width, height: cgImage.height),
                            bytes <= DynamicTextureLimits.maximumBytesPerTexture,
                            totalBytes <= DynamicTextureLimits.maximumBytesPerSession - bytes
                        else {
                            throw PlaybackError.metalUnavailable
                        }
                        totalBytes += bytes
                        textures[id] = try Self.makeDynamicTexture(cgImage: cgImage, device: device)
                    }
                    self.dynamicTextures = textures
                    continuation.resume(returning: ())
                } catch {
                    continuation.resume(throwing: PlaybackError.metalUnavailable)
                }
            }
        }
    }

    /// Normalize UIKit / TextKit output to a predictable top-left RGBA8 surface before upload.
    /// MTKTextureLoader rejects some device-only extended-color CGImage formats.
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
        // DynamicResolver has already rasterized both provider images and
        // replacement text through UIGraphicsImageRenderer, whose CGImage
        // pixels are top-left oriented. Metal samples texture coordinates
        // from the same origin, so do not apply the usual raw-CGImage
        // CoreGraphics flip here; doing so mirrors every replacement asset.
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

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

    func update(snapshot: RenderSnapshot) {
        renderQueue.async { [weak self] in self?.snapshot = snapshot }
    }

    /// 提交一帧。返回 false 表示 drawable 暂不可用；这不是播放终态。
    func render(
        _ frame: DecodedFrame,
        vapc: VapcDocument,
        completion: @escaping (Result<Bool, PlaybackError>) -> Void
    ) {
        renderQueue.async { [weak self] in
            guard let self, !self.disposed else {
                completion(.failure(.cancelled))
                return
            }
            do {
                let submitted = try self.encode(frame, vapc: vapc) { result in
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

    private func encode(
        _ frame: DecodedFrame,
        vapc: VapcDocument,
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
            let attachmentPipeline,
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
            colorMatrix: colorMatrix(for: pixelBuffer)
        )
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        for attachment in vapc.frames[frame.index] ?? [] {
            guard let texture = dynamicTextures[attachment.sourceID] else { continue }
            encoder.setRenderPipelineState(attachmentPipeline)
            var attachmentUniforms = AttachmentUniforms(
                renderRect: normalized(attachment.renderRect, within: vapc.canvasSize),
                maskRect: normalized(attachment.maskRect, within: vapc.encodedVideoSize),
                rotation: UInt32(max(0, attachment.maskRotation))
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
            encoder.setFragmentTexture(texture, index: 2)
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
            // `DispatchGroup.notify` may run as soon as leave() is called.
            // Drop CVMetalTexture references before decrementing the context's
            // active count so an idle cache flush cannot race finalizers.
            resources.releaseReferences()
            context.endTextureSubmission()
            inFlight.leave()
        }
        commandBuffer.commit()
        return true
    }

    func dispose() {
        // Keep the renderer alive until every submitted command buffer has
        // completed and its CVMetalTexture references have been released.
        // The context owns the shared cache; this only tears down session state.
        renderQueue.async { [self] in
            self.disposed = true
            self.inFlight.notify(queue: self.renderQueue) { [self] in
                self.releaseResources()
            }
        }
    }

    private func releaseResources() {
        // The texture cache is package-scoped and may be in use by another
        // renderer. It is flushed/released only with the shared context.
        pipeline = nil
        attachmentPipeline = nil
        dynamicTextures.removeAll()
        library = nil
        commandQueue = nil
        device = nil
        layer = nil
        context.flushTextureCacheIfIdle()
    }

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

    private func normalized(_ rect: CGRect, within size: CGSize) -> SIMD4<Float> {
        SIMD4(
            Float(rect.minX / size.width),
            Float(rect.minY / size.height),
            Float(rect.width / size.width),
            Float(rect.height / size.height)
        )
    }

    /// AVFoundation propagates the track matrix to the decoded image buffer. Treat unknown/2020 as 709.
    private func colorMatrix(for pixelBuffer: CVPixelBuffer) -> UInt32 {
        let attachment = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
        return attachment == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ? 0 : 1
    }
}
