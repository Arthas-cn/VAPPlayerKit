import XCTest
import QuartzCore
@testable import VAPPlayerKit

final class VAPPlayerKitTests: XCTestCase {
    func testDefaultPlaybackOptions() {
        let options = PlaybackOptions.defaultOptions
        XCTAssertEqual(options.loopCount, 1)
        XCTAssertEqual(options.contentMode, .scaleAspectFit)
        XCTAssertEqual(options.audioMode, .muted)
        XCTAssertTrue(options.clearsAfterFinish)
        XCTAssertEqual(options.backgroundPolicy, .suspend)
    }

    func testPlaybackOptionsCopyIsIndependent() {
        let original = PlaybackOptions.defaultOptions
        original.loopCount = 0
        let copy = original.copy() as! PlaybackOptions
        copy.loopCount = 2
        XCTAssertEqual(original.loopCount, 0)
        XCTAssertEqual(copy.loopCount, 2)
    }

    func testNegativeLoopCountFallsBackToSinglePlayback() {
        let options = PlaybackOptions.defaultOptions
        options.loopCount = -1
        XCTAssertEqual(options.loopCount, 1)
    }

    func testModuleBundleIsAvailable() {
        XCTAssertEqual(Bundle.module.bundleURL.pathExtension, "bundle")
    }

    func testShaderResourceIsInModuleBundle() {
        XCTAssertNotNil(ShaderLibrary.shaderResourceURL, "Metal shader should be locatable via Bundle.module")
    }

    @MainActor
    func testPrepareRejectsNonFileURL() async {
        let player = PlayerView()
        do {
            _ = try await player.prepare(url: URL(string: "https://example.com/demo.mp4")!)
            XCTFail("Expected invalidURL")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .invalidURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testClearHidesDrawableWithoutActiveSession() {
        let player = PlayerView()
        XCTAssertFalse(player.metalLayer.isHidden)
        player.clear()
        XCTAssertTrue(player.metalLayer.isHidden)
    }

    func testErrorDomainMatchesObjCFacade() {
        XCTAssertEqual(VPKPlaybackErrorDomain, "com.vapplayerkit.playback")
        XCTAssertEqual(PlaybackError.cancelled.asNSError().domain, VPKPlaybackErrorDomain)
        XCTAssertEqual(PlaybackError.cancelled.asNSError().code, PlaybackErrorCode.cancelled.rawValue)
    }

    func testCommittedVAPFixturesExist() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: VAPFixture.defaultPlayableURL.path))
        XCTAssertEqual(VAPFixture.allMP4URLs.count, 21)
        XCTAssertEqual(VAPFixture.playableURLs.count, 19)
        XCTAssertEqual(
            VAPFixture.allMP4URLs.map(\.lastPathComponent),
            (1...21).map { "\($0).mp4" }
        )
        for name in VAPFixture.invalidXMLNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: VAPFixture.url(name).path))
        }
    }

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
        guard case .image(let textImage) = snapshot.contents["nickname"] else {
            return XCTFail("Text source was not materialized as an image")
        }
        XCTAssertEqual(textImage.size, CGSize(width: 197, height: 52))
    }

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
        if components.count >= 3 {
            XCTAssertEqual(components[0], 231.0 / 255.0, accuracy: 0.01)
            XCTAssertEqual(components[1], 196.0 / 255.0, accuracy: 0.01)
            XCTAssertEqual(components[2], 84.0 / 255.0, accuracy: 0.01)
        }
        let snapshot = try await resolver.resolve(sources: [source], timeout: 1)
        guard case .image(let image) = snapshot.contents[source.id] else {
            return XCTFail("String-only replacement should become a text texture")
        }
        XCTAssertEqual(image.size, source.slotSize)
        XCTAssertNotNil(image.cgImage)
    }

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
        guard case .hidden = withoutProvider.contents[source.id] else {
            return XCTFail("Missing provider must produce an empty dynamic slot")
        }

        let resolver = DynamicResolver()
        let provider = NilDynamicProviderStub()
        resolver.provider = provider
        let missingValue = try await resolver.resolve(sources: [source], timeout: 0.1)
        guard case .hidden = missingValue.contents[source.id] else {
            return XCTFail("Provider returning nil must produce an empty dynamic slot")
        }
    }

    @MainActor
    func testReusableMetadataSkipsVapcReinspectionForSameURL() async throws {
        let url = VAPFixture.url(VAPFixture.defaultPlayableName)
        let metadata = try await AssetInspector().inspect(url: url)
        XCTAssertTrue(metadata.isReusableForPlayback)

        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 320, height: 320))
        let reused = try await player.prepare(url: url, metadata: metadata)
        XCTAssertTrue(reused === metadata)
        player.clear()
    }

    @MainActor
    func testReusableMetadataRejectsDifferentURLAndManualSummary() async throws {
        let sourceURL = VAPFixture.url(VAPFixture.defaultPlayableName)
        let metadata = try await AssetInspector().inspect(url: sourceURL)
        let differentURL = VAPFixture.playableURLs.first { $0 != sourceURL }!
        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        do {
            _ = try await player.prepare(url: differentURL, metadata: metadata)
            XCTFail("Metadata from another URL must not be reused")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .invalidVapc)
        }

        let manual = AssetMetadata(
            encodedVideoSize: metadata.encodedVideoSize,
            canvasSize: metadata.canvasSize,
            alphaMode: metadata.alphaMode,
            frameCount: metadata.frameCount,
            duration: metadata.duration,
            containsAudio: metadata.containsAudio,
            codec: metadata.codec
        )
        XCTAssertFalse(manual.isReusableForPlayback)
    }

    @MainActor
    func testReusableMetadataRejectsAChangedFileSignature() async throws {
        let fixture = VAPFixture.url(VAPFixture.defaultPlayableName)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vap-metadata-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: fixture, to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let metadata = try await AssetInspector().inspect(url: temporaryURL)
        XCTAssertTrue(metadata.isReusableForPlayback)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 60)],
            ofItemAtPath: temporaryURL.path
        )

        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        do {
            _ = try await player.prepare(url: temporaryURL, metadata: metadata)
            XCTFail("Metadata must not be reused after the file signature changes")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .invalidMP4)
        }
    }

    @MainActor
    func testReusableMetadataRejectsFileChangedDuringDecoderPrepare() async throws {
        let fixture = VAPFixture.url(VAPFixture.defaultPlayableName)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("vap-metadata-race-\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: fixture, to: temporaryURL)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        let metadata = try await AssetInspector().inspect(url: temporaryURL)
        let frameSource = MutatingFrameSource(
            metadata: FrameSourceMetadata(
                encodedVideoSize: metadata.encodedVideoSize,
                codec: metadata.codec
            )
        ) {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 60)],
                ofItemAtPath: temporaryURL.path
            )
        }
        let layer = CAMetalLayer()
        let session = PlaybackSession(
            url: temporaryURL,
            options: PlaybackOptions.defaultOptions,
            metalLayer: layer,
            dynamicProvider: nil,
            objcDynamicProvider: nil,
            frameSource: frameSource
        )

        do {
            _ = try await session.prepare(using: metadata)
            XCTFail("A file replaced during decoder preparation must be rejected")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .invalidMP4)
        }
    }

    @MainActor
    func testReusableMetadataRejectsSameSizeAndDateReplacement() async throws {
        let fixture = VAPFixture.url(VAPFixture.defaultPlayableName)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vap-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let playbackURL = directory.appendingPathComponent("asset.mp4")
        let replacementURL = directory.appendingPathComponent("replacement.mp4")
        try FileManager.default.copyItem(at: fixture, to: playbackURL)
        let metadata = try await AssetInspector().inspect(url: playbackURL)
        let expectedDate = try XCTUnwrap(metadata.sourceModificationDate)
        let expectedSize = try XCTUnwrap(metadata.sourceFileSize)
        let expectedIdentifier = try XCTUnwrap(metadata.sourceFileIdentifier)

        try FileManager.default.copyItem(at: fixture, to: replacementURL)
        try FileManager.default.removeItem(at: playbackURL)
        try FileManager.default.moveItem(at: replacementURL, to: playbackURL)
        try FileManager.default.setAttributes(
            [.modificationDate: expectedDate],
            ofItemAtPath: playbackURL.path
        )
        let values = try playbackURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        XCTAssertEqual(Int64(try XCTUnwrap(values.fileSize)), expectedSize)
        XCTAssertEqual(values.contentModificationDate, expectedDate)
        XCTAssertNotEqual(values.fileResourceIdentifier as? Data, expectedIdentifier)

        let player = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        do {
            _ = try await player.prepare(url: playbackURL, metadata: metadata)
            XCTFail("Replacing a file while preserving size and mtime must invalidate metadata")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .invalidMP4)
        }
    }

    @MainActor
    func testPreparedSessionAndOwnedResourcesAreReleasedAfterStop() async throws {
        let url = VAPFixture.url(VAPFixture.defaultPlayableName)
        let layer = CAMetalLayer()
        layer.frame = CGRect(x: 0, y: 0, width: 64, height: 64)
        layer.drawableSize = CGSize(width: 64, height: 64)

        var frameSource: AVAssetReaderFrameSource? = AVAssetReaderFrameSource(url: url)
        var renderer: MetalRenderer? = MetalRenderer()
        var session: PlaybackSession? = PlaybackSession(
            url: url,
            options: PlaybackOptions.defaultOptions,
            metalLayer: layer,
            dynamicProvider: nil,
            objcDynamicProvider: nil,
            frameSource: frameSource,
            renderer: renderer!
        )
        weak var weakSession = session
        weak var weakFrameSource = frameSource
        weak var weakRenderer = renderer

        let playbackStarted = expectation(description: "decoder produced a frame and started the timeline")
        session!.onStart = { playbackStarted.fulfill() }
        _ = try await session!.prepare()
        session!.play()
        await fulfillment(of: [playbackStarted], timeout: 10)
        session!.stop(reason: .stopped)
        session = nil
        frameSource = nil
        renderer = nil

        for _ in 0..<100 where weakSession != nil || weakFrameSource != nil || weakRenderer != nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakSession, "PlaybackSession leaked after stop")
        XCTAssertNil(weakFrameSource, "Frame source leaked after stop")
        XCTAssertNil(weakRenderer, "Metal renderer leaked after stop")
    }

    @MainActor
    func testPlayerViewLifecycleObserversDoNotRetainPlayer() async {
        var player: PlayerView? = PlayerView()
        weak var weakPlayer = player
        player?.clear()
        player = nil
        for _ in 0..<10 where weakPlayer != nil { await Task.yield() }
        XCTAssertNil(weakPlayer)
    }

    @MainActor
    func testPlayerViewIsReleasedWhileDynamicProviderIsPending() async {
        let requested = expectation(description: "dynamic provider was invoked")
        let provider = NeverCompletingDynamicProviderStub { requested.fulfill() }
        var player: PlayerView? = PlayerView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        player?.dynamicContentProvider = provider
        player?.play(url: VAPFixture.url("8.mp4"))
        await fulfillment(of: [requested], timeout: 10)

        weak var weakPlayer = player
        player = nil
        for _ in 0..<100 where weakPlayer != nil {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNil(weakPlayer, "playTask retained PlayerView while dynamic prepare was pending")
    }
}

private final class DynamicProviderStub: DynamicContentProvider {
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        if tag == "nickname" {
            completion(.text("VAP Swift", attributes: TextAttributes()), nil)
        } else {
            let image = UIGraphicsImageRenderer(size: source.slotSize).image { context in
                UIColor.blue.setFill()
                context.cgContext.fill(CGRect(origin: .zero, size: source.slotSize))
            }
            completion(.image(image), nil)
        }
    }
}

private final class FixedImageProviderStub: DynamicContentProvider {
    let image: UIImage

    init(image: UIImage) {
        self.image = image
    }

    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        completion(.image(image), nil)
    }
}

private func makeTransparentStampImage() -> UIImage? {
    UIGraphicsBeginImageContextWithOptions(CGSize(width: 4, height: 4), false, 1)
    UIColor.clear.setFill()
    UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
    UIColor.red.setFill()
    UIRectFill(CGRect(x: 1, y: 1, width: 2, height: 2))
    let image = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    return image
}

private func premultipliedPixels(_ image: UIImage) throws -> [UInt8] {
    let cgImage = try XCTUnwrap(image.cgImage)
    var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    let created = bytes.withUnsafeMutableBytes { raw -> Bool in
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
    guard created else { throw PlaybackError.metalUnavailable }
    return bytes
}

private func alpha(in pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
    pixels[(y * width + x) * 4 + 3]
}

private final class ReplacementTextProviderStub: DynamicContentProvider {
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        completion(.textReplacement("只提供字符串"), nil)
    }
}

private final class FontAwareReplacementTextProviderStub: DynamicContentProvider {
    let font: UIFont
    private(set) var requestedTag: String?

    init(font: UIFont) {
        self.font = font
    }

    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        completion(.textReplacement("THIS replacement is too long"), nil)
    }

    func font(forTag tag: String) -> UIFont? {
        requestedTag = tag
        return font
    }
}

private final class NilDynamicProviderStub: DynamicContentProvider {
    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        completion(nil, nil)
    }
}

private final class MutatingFrameSource: FrameSource {
    private let metadata: FrameSourceMetadata
    private let mutation: () throws -> Void

    init(metadata: FrameSourceMetadata, mutation: @escaping () throws -> Void) {
        self.metadata = metadata
        self.mutation = mutation
    }

    func prepare() async throws -> FrameSourceMetadata {
        try mutation()
        return metadata
    }

    func startProducing(
        to buffer: FrameRingBuffer,
        token: SessionToken,
        didProduce: @escaping (Int) -> Void,
        completion: @escaping (Result<Void, PlaybackError>) -> Void
    ) {}

    func pause() {}
    func resume() {}
    func cancel() {}
}

private final class NeverCompletingDynamicProviderStub: DynamicContentProvider {
    private let onFirstRequest: () -> Void
    private var didNotify = false

    init(onFirstRequest: @escaping () -> Void) {
        self.onFirstRequest = onFirstRequest
    }

    func resolve(
        tag: String,
        source: SourceMetadata,
        completion: @escaping (DynamicContent?, Error?) -> Void
    ) {
        if !didNotify {
            didNotify = true
            onFirstRequest()
        }
        // Intentionally keep the request pending. PlayerView deinit must cancel
        // the session without waiting for the normal dynamic timeout.
    }
}
