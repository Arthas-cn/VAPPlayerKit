import XCTest
import UIKit
@testable import VAPPlayerKit

/// 保留资源打包、跑马灯布局与动态槽位的回归覆盖，使用 v2 的异步 Swift provider。
final class VAPPlayerKitTests: XCTestCase {
    /// 跑马灯每轮先停顿再滚动，归零后重新停顿；纹理采样区域应与偏移一致。
    @MainActor
    func testMarqueeLayoutOffsetHoldsThenWraps() {
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 0.3, startDelay: 0.6, speed: 40, cycleWidth: 100),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 0.6, startDelay: 0.6, speed: 40, cycleWidth: 100),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 1.6, startDelay: 0.6, speed: 40, cycleWidth: 100),
            40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 3.1, startDelay: 0.6, speed: 40, cycleWidth: 100),
            0,
            accuracy: 0.001
        )
        // 周期 = 0.6s 停顿 + 100/40s 滚动 = 3.1s。下一圈开头仍应停顿，而不是立刻接着滚。
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 3.4, startDelay: 0.6, speed: 40, cycleWidth: 100),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 4.7, startDelay: 0.6, speed: 40, cycleWidth: 100),
            40,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MarqueeLayout.offset(elapsed: 0.5, startDelay: 0, speed: 40, cycleWidth: 100),
            20,
            accuracy: 0.001
        )
        let uv = MarqueeLayout.sourceUV(offset: 40, slotWidth: 80, textureWidth: 200)
        XCTAssertEqual(uv.origin.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(uv.size.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(uv.origin.y, 0, accuracy: 0.0001)
        XCTAssertEqual(uv.size.y, 1, accuracy: 0.0001)
    }

    /// 超出纹理边界的长条必须被拒绝，合法长条与默认间距、速度保持可用。
    @MainActor
    func testMarqueeLayoutRejectsOversizedStrip() {
        let huge = CGSize(width: CGFloat(DynamicTextureLimits.maximumTextureDimension + 1), height: 40)
        XCTAssertFalse(MarqueeLayout.canAllocateStrip(size: huge))
        XCTAssertEqual(MarqueeLayout.gap(slotWidth: 40), 25, accuracy: 0.001)
        XCTAssertEqual(MarqueeLayout.gap(slotWidth: 200), 25, accuracy: 0.001)
        XCTAssertEqual(MarqueeLayout.defaultSpeed, 80, accuracy: 0.001)
        XCTAssertTrue(MarqueeLayout.canAllocateStrip(size: CGSize(width: 400, height: 40)))
    }

    /// 测试资源应由 SPM bundle 提供，避免依赖开发机器的绝对路径。
    @MainActor
    func testModuleBundleIsAvailable() {
        XCTAssertNotNil(Bundle.module.resourceURL)
    }

    /// Metal shader 应能从组件资源 bundle 定位。
    @MainActor
    func testShaderResourceIsInModuleBundle() {
        XCTAssertNotNil(ShaderLibrary.shaderResourceURL, "Metal shader should be locatable via Bundle.module")
    }

    /// 直接传入远程 URL 必须报 invalidURL，显式排空失败的准备任务。
    @MainActor
    func testPrepareRejectsNonFileURL() async {
        let player = PlayerView()
        // 播放器只接收本地文件，远程 URL 应在任何解码工作之前被拒绝。
        do {
            _ = try await player.prepare(url: URL(string: "https://example.com/demo.mp4")!)
            XCTFail("Expected invalidURL")
        } catch let error as PlaybackError {
            // 明确错误码使上层可以区分输入错误与媒体解码失败。
            XCTAssertEqual(error.code, .invalidURL)
        } catch {
            // 其它错误说明拒绝 URL 的边界已失效。
            XCTFail("Unexpected error: \(error)")
        }
        await player.clearAndWait()
    }

    /// 尚未建立 session 时 clear 仍应立即隐藏 drawable。
    @MainActor
    func testClearHidesDrawableWithoutActiveSession() {
        let player = PlayerView()
        XCTAssertFalse(player.metalLayer.isHidden)
        player.clear()
        XCTAssertTrue(player.metalLayer.isHidden)
    }

    /// 基础 VAP fixture 必须完整打包，可选素材按实际存在情况计数。
    @MainActor
    func testCommittedVAPFixturesExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: VAPFixture.defaultPlayableURL.path))
        let requiredNames = Set((1...21).map { "\($0).mp4" } + ["movie.mp4", "alpha_left_moive.mp4", "7878.mp4"])
        let actualNames = Set(VAPFixture.allMP4URLs.map(\.lastPathComponent))
        XCTAssertTrue(requiredNames.isSubset(of: actualNames))
        XCTAssertEqual(actualNames.count, requiredNames.count + VAPFixture.optionalFixtureNames.count)
        XCTAssertEqual(
            VAPFixture.playableURLs.count,
            22 + ["home.mp4", "nationalDayEffect.mp4", "nation.mp4", "movie01.mp4", "movie02.mp4"].filter { actualNames.contains($0) }.count
        )
        for name in VAPFixture.existingInvalidXMLNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: VAPFixture.url(name).path))
        }
    }

    /// 异步 provider 返回的文字和图片都应物化为对应槽位纹理。
    @MainActor
    func testDynamicTextAndImageSourcesResolveWithoutBlocking() async throws {
        let provider = DynamicProviderStub()
        let resolver = DynamicResolver()
        resolver.provider = provider
        let sources = [
            VapcSource(
                id: "avatar",
                kind: .image,
                tag: "avatar",
                slotSize: CGSize(width: 64, height: 64),
                loadType: "net",
                fitType: "fitXY",
                color: nil,
                style: nil
            ),
            VapcSource(
                id: "nickname",
                kind: .text,
                tag: "nickname",
                slotSize: CGSize(width: 197, height: 52),
                loadType: "local",
                fitType: "fitXY",
                color: "#ffffff",
                style: "b"
            )
        ]

        let snapshot = try await resolver.resolve(sources: sources, timeout: 1)
        XCTAssertEqual(snapshot.contents.count, 2)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let textImage) = snapshot.contents["nickname"] else {
            return XCTFail("Text source was not materialized as an image")
        }
        XCTAssertEqual(textImage.size, CGSize(width: 197, height: 52))
    }

    /// 透明图片缩放后边角仍透明，中央不透明区域保持有效 alpha。
    @MainActor
    func testDynamicImageResizePreservesTransparentBackground() async throws {
        let stamp = try XCTUnwrap(makeTransparentStampImage())
        let provider = FixedImageProviderStub(image: stamp)
        let resolver = DynamicResolver()
        resolver.provider = provider
        let source = VapcSource(
            id: "avatar",
            kind: .image,
            tag: "avatar",
            slotSize: CGSize(width: 8, height: 8),
            loadType: "local",
            fitType: "fitXY",
            color: nil,
            style: nil
        )
        let snapshot = try await resolver.resolve(sources: [source], timeout: 1)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let image) = snapshot.contents[source.id] else {
            return XCTFail("Image source was not materialized")
        }
        XCTAssertEqual(image.size, source.slotSize)
        let pixels = try premultipliedPixels(image)
        XCTAssertEqual(alpha(in: pixels, width: 8, x: 0, y: 0), 0)
        XCTAssertEqual(alpha(in: pixels, width: 8, x: 7, y: 0), 0)
        XCTAssertEqual(alpha(in: pixels, width: 8, x: 0, y: 7), 0)
        XCTAssertEqual(alpha(in: pixels, width: 8, x: 7, y: 7), 0)
        XCTAssertEqual(alpha(in: pixels, width: 8, x: 4, y: 4), 255)
    }

    /// SPM 独立宿主不具备动图能力；链接 SDWebImage 的 Demo 宿主应具备能力，普通 UIImage 始终静态。
    @MainActor
    func testSDWebImageRuntimeMatchesHostLinkage() {
        #if SWIFT_PACKAGE
        // 包的测试目标没有图片库依赖，必须验证缺库时的可选能力降级。
        XCTAssertFalse(SDWebImageRuntime.isAvailable)
        XCTAssertFalse(PlaybackOptions.canPlayAnimatedDynamicImages)
        #else
        // 应用宿主明确链接 SDWebImage，不能把真实集成环境误判成未链接的 SPM 宿主。
        XCTAssertTrue(SDWebImageRuntime.isAvailable)
        XCTAssertTrue(PlaybackOptions.canPlayAnimatedDynamicImages)
        #endif
        XCTAssertFalse(SDWebImageRuntime.isAnimatedImage(UIImage()))
        XCTAssertNil(SDWebImageRuntime.makePlayer(provider: UIImage(), onFrame: { _, _ in }))
    }

    /// 普通 UIImage 在 animated 和 still 两种策略下都生成静态槽位纹理。
    @MainActor
    func testRegularUIImageStaysStaticEvenWhenAnimatedPlaybackIsRequested() throws {
        let image = try XCTUnwrap(makeTransparentStampImage())
        let source = VapcSource(
            id: "avatar",
            kind: .image,
            tag: "avatar",
            slotSize: CGSize(width: 8, height: 8),
            loadType: "local",
            fitType: "fitXY",
            color: nil,
            style: nil
        )
        let animatedMode = DynamicResolver.resolveImage(image, source: source, imagePlayback: .animated)
        let stillMode = DynamicResolver.resolveImage(image, source: source, imagePlayback: .still)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let animatedResult) = animatedMode else {
            return XCTFail("Regular UIImage must stay a static slot without SDWebImage")
        }
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let stillResult) = stillMode else {
            return XCTFail("Still mode must rasterize a static slot")
        }
        XCTAssertEqual(animatedResult.size, source.slotSize)
        XCTAssertEqual(stillResult.size, source.slotSize)
    }

    /// 仅替换字符串时应继承素材颜色和粗体，并将文字限制在原槽位内。
    @MainActor
    func testTextReplacementUsesSourceStyleAndFitsOriginalSlot() async throws {
        let resolver = DynamicResolver()
        let provider = ReplacementTextProviderStub()
        resolver.provider = provider
        let replacement = "只提供字符串"
        let source = VapcSource(
            id: "nickname",
            kind: .text,
            tag: "nickname",
            slotSize: CGSize(width: 197, height: 52),
            loadType: "local",
            fitType: "fitXY",
            color: "#E7C454",
            style: "b"
        )
        let attributes = DynamicResolver.replacementTextAttributes(replacement, source: source)
        XCTAssertTrue(attributes.font.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertLessThanOrEqual(attributes.font.pointSize, source.slotSize.height)
        let replacementSize = (replacement as NSString).size(withAttributes: [.font: attributes.font])
        XCTAssertLessThanOrEqual(replacementSize.width, source.slotSize.width)
        XCTAssertLessThanOrEqual(replacementSize.height, source.slotSize.height)
        let components = attributes.color.cgColor.components ?? []
        XCTAssertGreaterThanOrEqual(components.count, 3)
        // 断言失败后仍避免数组越界，保留真正的颜色格式失败信息。
        if components.count >= 3 {
            XCTAssertEqual(components[0], 231.0 / 255.0, accuracy: 0.01)
            XCTAssertEqual(components[1], 196.0 / 255.0, accuracy: 0.01)
            XCTAssertEqual(components[2], 84.0 / 255.0, accuracy: 0.01)
        }
        let snapshot = try await resolver.resolve(sources: [source], timeout: 1)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let image) = snapshot.contents[source.id] else {
            return XCTFail("String-only replacement should become a text texture")
        }
        XCTAssertEqual(image.size, source.slotSize)
        XCTAssertNotNil(image.cgImage)
    }

    /// 极窄槽位中的长文本仍应得到有效正字号，避免生成非法字体。
    @MainActor
    func testTextReplacementFitsLongSingleLineInsideNarrowSlot() {
        let replacement = "VERY-LONG-REPLACEMENT"
        let source = VapcSource(
            id: "narrow",
            kind: .text,
            tag: "narrow",
            slotSize: CGSize(width: 40, height: 120),
            loadType: "local",
            fitType: "fitXY",
            color: "#FFFFFF",
            style: nil
        )
        let attributes = DynamicResolver.replacementTextAttributes(replacement, source: source)
        XCTAssertGreaterThan(attributes.font.pointSize, 0)
    }

    /// provider 指定字体时按相同 tag 取字体，并保留该字体交给截断路径。
    @MainActor
    func testTextReplacementUsesProviderFontAndUIKitTailTruncation() async throws {
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
        let providedFont = UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let provider = FontAwareReplacementTextProviderStub(font: providedFont)
        let resolver = DynamicResolver()
        resolver.provider = provider

        _ = try await resolver.resolve(sources: [source], timeout: 1)
        XCTAssertEqual(provider.requestedTag, source.tag)
        XCTAssertEqual(
            DynamicResolver.replacementTextAttributes("replacement", source: source, font: providedFont).font,
            providedFont
        )

        XCTAssertGreaterThan(providedFont.pointSize, 0)
    }

    /// 默认溢出策略应生成槽位大小的静态截断纹理。
    @MainActor
    func testOverflowingTextUsesTruncationByDefault() {
        let source = makeNarrowTextSource()
        let text = "THIS replacement is too long"
        let attributes = TextAttributes(font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular), color: .white)
        let resolved = DynamicResolver.resolveText(text, attributes: attributes, source: source, overflow: .truncate)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let image) = resolved else {
            return XCTFail("Default overflow must stay a slot-sized truncated texture")
        }
        XCTAssertEqual(image.size.width, source.slotSize.width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, source.slotSize.height, accuracy: 0.5)
    }

    /// 显式跑马灯策略应为超长文本创建大于槽位的可循环纹理条。
    @MainActor
    func testOverflowingTextUsesMarqueeStripWhenRequested() {
        let source = makeNarrowTextSource()
        let text = "THIS replacement is too long"
        let attributes = TextAttributes(font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular), color: .white)
        let resolved = DynamicResolver.resolveText(text, attributes: attributes, source: source, overflow: .marquee)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .marquee(let slot) = resolved else {
            return XCTFail("Overflowing text must become a marquee strip")
        }
        XCTAssertGreaterThan(slot.strip.size.width, source.slotSize.width)
        XCTAssertEqual(slot.strip.size.height, source.slotSize.height, accuracy: 0.5)
        XCTAssertEqual(slot.slotWidth, source.slotSize.width, accuracy: 0.5)
        XCTAssertGreaterThan(slot.cycleWidth, source.slotSize.width)
        XCTAssertEqual(slot.textureWidth, slot.strip.size.width, accuracy: 0.5)
    }

    /// 文本没有溢出时即使请求跑马灯，也应保留静态纹理。
    @MainActor
    func testFittingTextStaysStaticEvenWhenMarqueeIsRequested() {
        let source = VapcSource(
            id: "nickname",
            kind: .text,
            tag: "nickname",
            slotSize: CGSize(width: 240, height: 52),
            loadType: "local",
            fitType: "fitXY",
            color: "#FFFFFF",
            style: nil
        )
        let attributes = TextAttributes(font: UIFont.systemFont(ofSize: 16), color: .white)
        let resolved = DynamicResolver.resolveText("Hi", attributes: attributes, source: source, overflow: .marquee)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let image) = resolved else {
            return XCTFail("Text that fits must stay a static slot texture")
        }
        XCTAssertEqual(image.size, source.slotSize)
    }

    /// 超出纹理预算的跑马灯长条必须退回槽位内截断，避免超大分配。
    @MainActor
    func testOversizedMarqueeStripFallsBackToTruncation() {
        let source = makeNarrowTextSource()
        let text = String(repeating: "W", count: 2_000)
        let attributes = TextAttributes(font: UIFont.systemFont(ofSize: 40), color: .white)
        let resolved = DynamicResolver.resolveText(text, attributes: attributes, source: source, overflow: .marquee)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .image(let image) = resolved else {
            return XCTFail("Strip over the texture budget must fall back to truncation")
        }
        XCTAssertEqual(image.size.width, source.slotSize.width, accuracy: 0.5)
        XCTAssertEqual(image.size.height, source.slotSize.height, accuracy: 0.5)
    }

    /// session 级跑马灯选项应传递到字符串替换的物化路径。
    @MainActor
    func testResolverMarqueePathMaterializesReplacementText() async throws {
        let source = makeNarrowTextSource()
        let provider = FontAwareReplacementTextProviderStub(
            font: UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        )
        let resolver = DynamicResolver()
        resolver.provider = provider
        let snapshot = try await resolver.resolve(sources: [source], timeout: 1, textOverflow: .marquee)
        // 后续尺寸或像素断言只适用于预期的物化类型，错误类型应立即报告。
        guard case .marquee(let slot) = snapshot.contents[source.id] else {
            return XCTFail("Resolver must honor session-level marquee overflow")
        }
        XCTAssertGreaterThan(slot.strip.size.width, source.slotSize.width)
    }

    /// 没有 provider 或 provider 返回 nil 时都应产生隐藏槽位，不阻断准备。
    @MainActor
    func testMissingDynamicContentDefaultsToHiddenAndDoesNotFailPrepare() async throws {
        let source = VapcSource(
            id: "avatar",
            kind: .image,
            tag: "avatar",
            slotSize: CGSize(width: 64, height: 64),
            loadType: "net",
            fitType: "fitXY",
            color: nil,
            style: nil
        )

        let withoutProvider = try await DynamicResolver().resolve(sources: [source], timeout: 0.1)
        // 缺少 provider 应明确得到 hidden，不能意外保留一张占位纹理。
        guard case .hidden = withoutProvider.contents[source.id] else {
            return XCTFail("Missing provider must produce an empty dynamic slot")
        }

        let resolver = DynamicResolver()
        let provider = NilDynamicProviderStub()
        resolver.provider = provider
        let missingValue = try await resolver.resolve(sources: [source], timeout: 0.1)
        // 返回 nil 与没有 provider 的降级语义必须一致。
        guard case .hidden = missingValue.contents[source.id] else {
            return XCTFail("Provider returning nil must produce an empty dynamic slot")
        }
    }
}

/// 为两个固定 tag 提供文字或图片，验证一次 resolve 中不同素材类型的组合。
@MainActor
private final class DynamicProviderStub: DynamicContentProvider {
    /// 返回文字或按槽位大小生成的蓝色静图；本 stub 不执行异步 I/O。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        // nickname 走文字物化路径，其余 tag 走图片缩放路径。
        if tag == "nickname" {
            return .text("VAP Swift", attributes: TextAttributes())
        }
        let image = UIGraphicsImageRenderer(size: source.slotSize).image { context in
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(origin: .zero, size: source.slotSize))
        }
        return .image(image)
    }
}

/// 始终返回同一张图片，用于隔离图片缩放与 alpha 处理行为。
@MainActor
private final class FixedImageProviderStub: DynamicContentProvider {
    /// 测试指定的原始图片，不随请求修改。
    let image: UIImage

    /// 保存要提供的图片；尺寸和透明度由测试场景决定。
    init(image: UIImage) { self.image = image }

    /// 返回固定图片，槽位适配由被测 resolver 完成。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        .image(image)
    }
}

/// 生成 4×4 的透明底红色印章，固定 scale 为 1 便于逐像素验证。
@MainActor
private func makeTransparentStampImage() -> UIImage? {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
        UIColor.red.setFill()
        context.cgContext.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
    }
}

/// 将静图读取成 RGBA 预乘像素；缺失 CGImage 或无法创建上下文时让测试失败。
@MainActor
private func premultipliedPixels(_ image: UIImage) throws -> [UInt8] {
    let cgImage = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let created = bytes.withUnsafeMutableBytes { raw -> Bool in
        // 创建失败不能返回全零像素，否则透明边角断言会伪通过。
        guard let context = CGContext(
            data: raw.baseAddress,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        context.clear(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return true
    }
    // 只有实际完成读取才能解释 alpha 字节。
    guard created else { throw PlaybackError.metalUnavailable }
    return bytes
}

/// 读取已知合法坐标的 alpha 字节；输入必须是 width 宽度的 RGBA 数据。
private func alpha(in pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
    pixels[(y * width + x) * 4 + 3]
}

/// 创建固定窄文字槽位，让截断和跑马灯用例共享同一几何前提。
private func makeNarrowTextSource() -> VapcSource {
    VapcSource(
        id: "nickname",
        kind: .text,
        tag: "nickname",
        slotSize: CGSize(width: 40, height: 60),
        loadType: "local",
        fitType: "fitXY",
        color: "#FFFFFF",
        style: nil
    )
}

/// 只提供字符串，让 resolver 决定素材样式和字体尺寸。
@MainActor
private final class ReplacementTextProviderStub: DynamicContentProvider {
    /// 返回没有自定义样式的中文替换文字。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        .textReplacement("只提供字符串")
    }
}

/// 提供固定字体并记录字体请求的 tag，用于验证字体桥接和溢出策略。
@MainActor
private final class FontAwareReplacementTextProviderStub: DynamicContentProvider {
    /// 被测 resolver 应原样使用的字体。
    let font: UIFont
    /// 最近一次字体请求的 tag；nil 表示尚未请求。
    private(set) var requestedTag: String?

    /// 指定测试字体，字号和字形由调用方控制。
    init(font: UIFont) { self.font = font }

    /// 返回足以溢出窄槽位的字符串，样式通过 font(forTag:) 单独提供。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? {
        .textReplacement("THIS replacement is too long")
    }

    /// 记录 tag 并返回固定字体，用于核对字体请求对应正确槽位。
    func font(forTag tag: String) -> UIFont? {
        requestedTag = tag
        return font
    }
}

/// 模拟业务没有为某个动态槽位提供内容。
@MainActor
private final class NilDynamicProviderStub: DynamicContentProvider {
    /// 返回 nil，请求应降级为空槽位而非准备失败。
    func resolve(tag: String, source: SourceMetadata) async throws -> DynamicContent? { nil }
}
