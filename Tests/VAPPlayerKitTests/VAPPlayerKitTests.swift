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
        XCTAssertGreaterThanOrEqual(VAPFixture.allMP4URLs.count, 19)
        for name in VAPFixture.invalidXMLNames {
            XCTAssertTrue(FileManager.default.fileExists(atPath: VAPFixture.url(name).path))
        }
    }
}
