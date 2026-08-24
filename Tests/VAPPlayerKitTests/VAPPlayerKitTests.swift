import XCTest
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
