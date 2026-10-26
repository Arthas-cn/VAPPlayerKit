import XCTest
@testable import VAPPlayerKit
import Metal
import MetalKit
import UIKit
import QuartzCore
import CoreVideo
import CoreMedia
import Synchronization

/// 验证帧缓冲、动态纹理上传及共享 Metal 资源的并发初始化和缓存访问。
final class VAPPlayerKitRendererTests: XCTestCase {
    /// 帧缓冲达到容量后必须拒绝新帧，空缓冲出队返回 nil。
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

    /// 按媒体时间出队应选择最新到期帧，并统计被覆盖的旧帧。
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

    /// 没有 Metal 设备时明确报错，有设备时可以准备并等待资源排空。
    @MainActor
    func testMetalRendererPrepareRequiresDevice() async throws {
        let renderer = MetalRenderer()
        let layer = CAMetalLayer()
        // 无设备是可预期能力错误；有设备分支则必须真实完成准备。
        if MTLCreateSystemDefaultDevice() == nil {
            do {
                try await renderer.prepare(layer: layer)
                XCTFail("Expected metalUnavailable")
            } catch {
                // 只能接受缺少设备的专门错误，不能吞掉其它准备错误。
                XCTAssertEqual((error as? PlaybackError)?.code, .metalUnavailable)
            }
        } else {
            // 成功路径必须在离开测试前完成真实资源释放。
            try await renderer.prepare(layer: layer)
        }
        await renderer.disposeAndWait()
    }

    /// 文字栅格图应能上传为动态 Metal 纹理，测试结束前等待 GPU 资源释放。
    @MainActor
    func testMetalRendererUploadsTextTexture() async throws {
        // 这组断言需要真实 Metal 设备，没有设备时明确标记跳过。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
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
        await renderer.disposeAndWait()
    }

    /// 超长文字的跑马灯条应能上传，保持完整纹理而不误截断为槽位。
    @MainActor
    func testMetalRendererUploadsMarqueeStrip() async throws {
        // 这组断言需要真实 Metal 设备，没有设备时明确标记跳过。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
        let renderer = MetalRenderer()
        let layer = CAMetalLayer()
        try await renderer.prepare(layer: layer)
        let source = VapcSource(
            id: "nickname",
            kind: .text,
            tag: "nickname",
            slotSize: CGSize(width: 40, height: 60),
            loadType: "local",
            fitType: "fitXY",
            color: "#FFFFFF",
            style: nil
        )
        let resolved = DynamicResolver.resolveText(
            "THIS replacement is too long",
            attributes: TextAttributes(font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular), color: .white),
            source: source,
            overflow: .marquee
        )
        // 形态错误时也先排空 renderer，避免错误用例留下后台释放。
        guard case .marquee(let slot) = resolved else {
            await renderer.disposeAndWait()
            return XCTFail("Overflowing text should produce a marquee strip")
        }
        try await renderer.prepareDynamic(DynamicSnapshot(contents: ["nickname": .marquee(slot)]))
        await renderer.disposeAndWait()
    }

    /// 自定义纹理上传的四角像素应与 MetalKit 左上原点策略完全一致。
    @MainActor
    func testDynamicTextureUploadMatchesMetalKitTopLeftOrigin() throws {
        // 无 Metal 设备无法比较实际上传后的像素，不将静默返回记作验证成功。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    /// 纹理上传应保留透明角落的零预乘颜色，以及中央不透明红色像素。
    @MainActor
    func testDynamicTextureUploadPreservesTransparentPixels() throws {
        // 无 Metal 设备无法比较实际上传后的像素，不将静默返回记作验证成功。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
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

    /// 串行与并行准备应共用一次 pipeline 构建，并按策略分配 command queue。
    @MainActor
    func testMetalRendererPrepareBenchmark() async throws {
        // 这组断言需要真实 Metal 设备，没有设备时明确标记跳过。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
        let count = 12
        for policy in [MetalCommandQueuePolicy.shared, .perRenderer] {
            let context = MetalContext(policy: policy)
            let result = try await Self.benchmark(context: context, count: count)
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

    /// 多个 renderer 同时准备时，共享 context 只能构建一次公共资源和队列。
    @MainActor
    func testMetalContextInitializesOnceUnderConcurrentPrepare() async throws {
        // 这组断言需要真实 Metal 设备，没有设备时明确标记跳过。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
        let count = 12
        let context = MetalContext(policy: .shared)
        let renderers = (0..<count).map { _ in MetalRenderer(context: context) }
        try await Self.prepareConcurrently(renderers)
        XCTAssertEqual(context.metrics().resourceBuilds, 1)
        XCTAssertEqual(context.metrics().commandQueueBuilds, 1)
        for renderer in renderers { await renderer.disposeAndWait() }
    }

    /// 并行创建平面纹理并穿插 flush 时不得失败，测试不得用外部大锁串行缓存调用。
    @MainActor
    func testMetalContextSerializesSharedTextureCacheAccess() async throws {
        // 这组断言需要真实 Metal 设备，没有设备时明确标记跳过。
        try XCTSkipIf(MTLCreateSystemDefaultDevice() == nil, "需要 Metal 设备")
        let context = MetalContext(policy: .shared)
        let renderer = MetalRenderer(context: context)
        try await renderer.prepare(layer: Self.makeBenchmarkLayer())

        let frames = try (0..<32).map { index in
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
            // 分配失败立即报告真实 CoreVideo 状态，不能向并发任务传入空缓冲。
            guard status == kCVReturnSuccess, let pixelBuffer else {
                throw PlaybackError.decoderFailed(osStatus: Int32(status))
            }
            return DecodedFrame(
                token: .make(),
                pixelBuffer: pixelBuffer,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 25),
                index: index
            )
        }

        for _ in 0..<8 {
            let errors = Mutex<[String]>([])
            // 仅错误集合需要测试侧锁；实际纹理创建必须保持 32 路并发以覆盖共享缓存竞争。
            DispatchQueue.concurrentPerform(iterations: frames.count) { index in
                do {
                    _ = try context.makePlaneTexturesAndBeginSubmission(for: frames[index].pixelBuffer)
                    // 穿插 flush 与在途 submission，验证 context 自己保护共享 texture cache。
                    if index.isMultiple(of: 4) {
                        context.flushTextureCacheIfIdle()
                    }
                    context.endTextureSubmission()
                } catch {
                    // 只保存不可变错误说明，锁外不会持有可变错误容器或系统媒体对象。
                    errors.withLock { $0.append(String(describing: error)) }
                }
            }
            let failures = errors.withLock { $0 }
            XCTAssertTrue(failures.isEmpty, "Concurrent texture creation failed: \(failures)")
        }

        context.flushTextureCacheIfIdle()
        await renderer.disposeAndWait()
    }

    /// 测量同一 context 下串行及并行准备耗时；每组完成后先排空再开始下一组。
    @MainActor
    private static func benchmark(context: MetalContext, count: Int) async throws -> (
        sequential: TimeInterval,
        concurrent: TimeInterval,
        metrics: (resourceBuilds: Int, commandQueueBuilds: Int)
    ) {
        let sequentialRenderers = (0..<count).map { _ in MetalRenderer(context: context) }
        let sequentialStart = CACurrentMediaTime()
        for renderer in sequentialRenderers {
            try await renderer.prepare(layer: Self.makeBenchmarkLayer())
        }
        let sequentialDuration = CACurrentMediaTime() - sequentialStart
        for renderer in sequentialRenderers { await renderer.disposeAndWait() }

        let concurrentRenderers = (0..<count).map { _ in MetalRenderer(context: context) }
        let concurrentStart = CACurrentMediaTime()
        try await Self.prepareConcurrently(concurrentRenderers)
        let concurrentDuration = CACurrentMediaTime() - concurrentStart
        for renderer in concurrentRenderers { await renderer.disposeAndWait() }
        return (sequentialDuration, concurrentDuration, context.metrics())
    }

    /// 并行准备各 renderer；任务只捕获 Sendable renderer，避免跨任务持有 XCTestCase。
    @MainActor
    private static func prepareConcurrently(_ renderers: [MetalRenderer]) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for renderer in renderers {
                group.addTask {
                    try await prepareBenchmarkRenderer(renderer)
                }
            }
            try await group.waitForAll()
        }
    }

    /// 创建固定的 64×64 Metal 宿主层，排除布局变化对准备测试的干扰。
    @MainActor
    private static func makeBenchmarkLayer() -> CAMetalLayer {
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        layer.drawableSize = CGSize(width: 64, height: 64)
        return layer
    }

    /// aspectFit 应按逻辑画布居中缩放，不能用编码视频尺寸代替画布。
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


    /// 生成固定 2×2 像素的测试帧，只通过参数控制时间戳、帧序号和 session token。
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

/// 读取 RGBA 纹理的不可变字节副本，供上传方向及预乘 alpha 的断言使用。
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

/// 生成 scale=1 的透明底红色印章，保证像素位置不受屏幕 scale 影响。
@MainActor
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

/// 在 MainActor 创建一个独立呈现层，Sendable 任务闭包只传 renderer，不捕获 XCTest 类型元数据。
@MainActor
private func prepareBenchmarkRenderer(_ renderer: MetalRenderer) async throws {
    let layer = CAMetalLayer()
    layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
    layer.drawableSize = CGSize(width: 64, height: 64)
    try await renderer.prepare(layer: layer)
}
