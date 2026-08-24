import XCTest
@testable import VAPPlayerKit
import Metal
import MetalKit
import UIKit
import QuartzCore
import CoreVideo
import CoreMedia

final class VAPPlayerKitRendererTests: XCTestCase {
    func testFrameRingBufferEnforcesCapacity() {
        let buffer = FrameRingBuffer(capacity: 2)
        XCTAssertFalse(buffer.isFull)
        XCTAssertNil(buffer.dequeue())
        let token = SessionToken.make()
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0, index: 0, token: token)))
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 1, index: 1, token: token)))
        XCTAssertTrue(buffer.isFull)
        XCTAssertFalse(buffer.enqueue(makeFrame(pts: 2, index: 2, token: token)))
    }

    func testFrameRingBufferSelectsLatestDueFrameAndCountsDrops() {
        let buffer = FrameRingBuffer(capacity: 4)
        let token = SessionToken.make()
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0, index: 0, token: token)))
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0.04, index: 1, token: token)))
        XCTAssertTrue(buffer.enqueue(makeFrame(pts: 0.08, index: 2, token: token)))

        let due = buffer.dequeueDue(at: CMTime(seconds: 0.05, preferredTimescale: 600))
        XCTAssertEqual(due.frame?.index, 1)
        XCTAssertEqual(due.dropped, 1)
        XCTAssertEqual(buffer.count, 1)
    }

    @MainActor
    func testMetalRendererPrepareRequiresDevice() async throws {
        let renderer = MetalRenderer()
        let layer = CAMetalLayer()
        if MTLCreateSystemDefaultDevice() == nil {
            do {
                try await renderer.prepare(layer: layer)
                XCTFail("Expected metalUnavailable")
            } catch {
                XCTAssertEqual((error as? PlaybackError)?.code, .metalUnavailable)
            }
        } else {
            try await renderer.prepare(layer: layer)
            renderer.dispose()
        }
    }

    @MainActor
    func testMetalRendererUploadsTextTexture() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = MetalRenderer()
        let layer = CAMetalLayer()
        try await renderer.prepare(layer: layer)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 197, height: 52)).image { _ in
            NSAttributedString(
                string: "VAP Swift",
                attributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.white]
            ).draw(at: .zero)
        }
        try await renderer.prepareDynamic(DynamicSnapshot(contents: ["nickname": .image(image)]))
        renderer.dispose()
    }

    func testDynamicTextureUploadMatchesMetalKitTopLeftOrigin() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
            UIColor.green.setFill()
            context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 1, width: 1, height: 1))
            UIColor.yellow.setFill()
            context.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        let loader = MTKTextureLoader(device: device)
        let reference = try loader.newTexture(
            cgImage: cgImage,
            options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ]
        )
        let custom = try MetalRenderer.makeDynamicTexture(cgImage: cgImage, device: device)
        XCTAssertEqual(readTextureBytes(reference), readTextureBytes(custom))
    }

    func testDynamicTextureUploadPreservesTransparentPixels() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let stamp = try XCTUnwrap(makeTransparentStampCGImage())
        let texture = try MetalRenderer.makeDynamicTexture(cgImage: stamp, device: device)
        let bytes = readTextureBytes(texture)
        XCTAssertEqual(bytes[3], 0)
        XCTAssertEqual(bytes[0], 0)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[2], 0)
        let center = ((2 * 4) + 2) * 4
        XCTAssertEqual(bytes[center + 3], 255)
        XCTAssertEqual(bytes[center], 255)
        XCTAssertEqual(bytes[center + 1], 0)
        XCTAssertEqual(bytes[center + 2], 0)
    }

    @MainActor
    func testMetalRendererPrepareBenchmark() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let count = 12
        for policy in [MetalCommandQueuePolicy.shared, .perRenderer] {
            let context = MetalContext(policy: policy)
            let result = try await benchmark(context: context, count: count)
            XCTAssertEqual(result.metrics.resourceBuilds, 1)
            XCTAssertEqual(
                result.metrics.commandQueueBuilds,
                policy == .shared ? 1 : count * 2
            )
            print(
                "METAL_PREPARE_BENCHMARK policy=\(policy.rawValue) count=\(count) " +
                "sequential_ms=\(result.sequential * 1_000) " +
                "concurrent_ms=\(result.concurrent * 1_000) " +
                "resource_builds=\(result.metrics.resourceBuilds) " +
                "command_queue_builds=\(result.metrics.commandQueueBuilds)"
            )
        }
    }

    @MainActor
    func testMetalContextInitializesOnceUnderConcurrentPrepare() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let count = 12
        let context = MetalContext(policy: .shared)
        let renderers = (0..<count).map { _ in MetalRenderer(context: context) }
        try await prepareConcurrently(renderers)
        XCTAssertEqual(context.metrics().resourceBuilds, 1)
        XCTAssertEqual(context.metrics().commandQueueBuilds, 1)
        renderers.forEach { $0.dispose() }
    }

    @MainActor
    func testMetalContextSerializesSharedTextureCacheAccess() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let context = MetalContext(policy: .shared)
        let renderer = MetalRenderer(context: context)
        try await renderer.prepare(layer: makeBenchmarkLayer())

        let pixelBuffers = try (0..<32).map { _ in
            var pixelBuffer: CVPixelBuffer?
            let attributes: [String: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
            let status = CVPixelBufferCreate(
                nil,
                64,
                64,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                attributes as CFDictionary,
                &pixelBuffer
            )
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw PlaybackError.decoderFailed(osStatus: Int32(status))
            }
            return pixelBuffer
        }
        let sharedPixelBuffers = SendablePixelBuffers(pixelBuffers)

        for _ in 0..<8 {
            let errorLock = NSLock()
            var errors: [Error] = []
            DispatchQueue.concurrentPerform(iterations: sharedPixelBuffers.values.count) { index in
                do {
                    _ = try context.makePlaneTexturesAndBeginSubmission(for: sharedPixelBuffers.values[index])
                    if index.isMultiple(of: 4) {
                        context.flushTextureCacheIfIdle()
                    }
                    context.endTextureSubmission()
                } catch {
                    errorLock.lock()
                    errors.append(error)
                    errorLock.unlock()
                }
            }
            XCTAssertTrue(errors.isEmpty, "Concurrent texture creation failed: \(errors)")
        }

        context.flushTextureCacheIfIdle()
        renderer.dispose()
    }

    @MainActor
    private func benchmark(context: MetalContext, count: Int) async throws -> (
        sequential: TimeInterval,
        concurrent: TimeInterval,
        metrics: (resourceBuilds: Int, commandQueueBuilds: Int)
    ) {
        let sequentialRenderers = (0..<count).map { _ in MetalRenderer(context: context) }
        let sequentialStart = CACurrentMediaTime()
        for renderer in sequentialRenderers {
            try await renderer.prepare(layer: makeBenchmarkLayer())
        }
        let sequentialDuration = CACurrentMediaTime() - sequentialStart
        sequentialRenderers.forEach { $0.dispose() }

        let concurrentRenderers = (0..<count).map { _ in MetalRenderer(context: context) }
        let concurrentStart = CACurrentMediaTime()
        try await prepareConcurrently(concurrentRenderers)
        let concurrentDuration = CACurrentMediaTime() - concurrentStart
        concurrentRenderers.forEach { $0.dispose() }
        return (sequentialDuration, concurrentDuration, context.metrics())
    }

    @MainActor
    private func prepareConcurrently(_ renderers: [MetalRenderer]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for renderer in renderers {
                group.addTask { @MainActor in
                    try await renderer.prepare(layer: self.makeBenchmarkLayer())
                }
            }
            try await group.waitForAll()
        }
    }

    @MainActor
    private func makeBenchmarkLayer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        layer.drawableSize = CGSize(width: 64, height: 64)
        return layer
    }

    func testAspectFitViewportUsesCanvasSize() {
        let viewport = MetalRenderer.viewport(
            drawableSize: CGSize(width: 300, height: 200),
            canvasSize: CGSize(width: 100, height: 100),
            contentMode: .scaleAspectFit
        )
        XCTAssertEqual(viewport.originX, 50, accuracy: 0.001)
        XCTAssertEqual(viewport.originY, 0, accuracy: 0.001)
        XCTAssertEqual(viewport.width, 200, accuracy: 0.001)
        XCTAssertEqual(viewport.height, 200, accuracy: 0.001)
    }


    private func makeFrame(pts: Double, index: Int, token: SessionToken) -> DecodedFrame {
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        return DecodedFrame(
            token: token,
            pixelBuffer: pixelBuffer!,
            presentationTime: CMTime(seconds: pts, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 25),
            index: index
        )
    }
}

private func readTextureBytes(_ texture: MTLTexture) -> [UInt8] {
    var bytes = Array(repeating: UInt8(0), count: texture.width * texture.height * 4)
    texture.getBytes(
        &bytes,
        bytesPerRow: texture.width * 4,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    return bytes
}

private func makeTransparentStampCGImage() -> CGImage? {
    UIGraphicsBeginImageContextWithOptions(CGSize(width: 4, height: 4), false, 1)
    UIColor.clear.setFill()
    UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
    UIColor.red.setFill()
    UIRectFill(CGRect(x: 1, y: 1, width: 2, height: 2))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image?.cgImage
}

private final class SendablePixelBuffers: @unchecked Sendable {
    let values: [CVPixelBuffer]

    init(_ values: [CVPixelBuffer]) {
        self.values = values
    }
}
