import XCTest
import CoreMedia
@testable import VAPPlayerKit

final class VAPPlayerKitParserTests: XCTestCase {
    func testInspectorRejectsMissingFile() async {
        let inspector = AssetInspector()
        let url = URL(fileURLWithPath: "/tmp/vapplayerkit-missing-\(UUID().uuidString).mp4")
        do {
            _ = try await inspector.inspect(url: url)
            XCTFail("Expected fileNotFound")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .fileNotFound)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testVapcReaderRejectsEmptyData() {
        XCTAssertThrowsError(try VapcReader().read(from: Data())) { error in
            guard let playbackError = error as? PlaybackError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(playbackError.code, .invalidVapc)
        }
    }

    func testVapcReaderParsesTypedMetadata() throws {
        let json: [String: Any] = [
            "info": [
                "v": 2, "f": 10, "w": 100, "h": 200, "fps": 25,
                "videoW": 150, "videoH": 200,
                "aFrame": [0, 0, 50, 200], "rgbFrame": [50, 0, 100, 200]
            ],
            "src": [[
                "srcId": "avatar", "srcType": "img", "srcTag": "user",
                "loadType": "net", "fitType": "fitXY", "w": 20, "h": 30
            ]],
            "frame": [[
                "i": 0,
                "obj": [["srcId": "avatar", "z": 1, "frame": [1, 2, 20, 30], "mFrame": [0, 0, 20, 30], "mt": 0]]
            ]]
        ]
        let document = try VapcReader().read(from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(document.version, 2)
        XCTAssertEqual(document.alphaMode, .left)
        XCTAssertEqual(document.canvasSize, CGSize(width: 100, height: 200))
        XCTAssertEqual(document.sources.first?.tag, "user")
        XCTAssertEqual(document.frames[0]?.count, 1)
    }

    func testVapcReaderRejectsUnknownVersionAndOutOfBoundsRect() throws {
        var root: [String: Any] = [
            "info": [
                "v": 3, "f": 1, "w": 100, "h": 100, "fps": 30,
                "videoW": 200, "videoH": 100,
                "aFrame": [0, 0, 100, 100], "rgbFrame": [100, 0, 100, 100]
            ]
        ]
        XCTAssertThrowsError(try VapcReader().read(from: JSONSerialization.data(withJSONObject: root)))

        root["info"] = [
            "v": 2, "f": 1, "w": 100, "h": 100, "fps": 30,
            "videoW": 200, "videoH": 100,
            "aFrame": [0, 0, 100, 100], "rgbFrame": [150, 0, 100, 100]
        ]
        XCTAssertThrowsError(try VapcReader().read(from: JSONSerialization.data(withJSONObject: root)))
    }

    func testMP4BoxReaderRejectsBoxPastFileBoundary() {
        var data = Data([0, 0, 0, 32])
        data.append(Data("ftyp".utf8))
        data.append(Data(repeating: 0, count: 4))
        XCTAssertThrowsError(try MP4BoxReader().topLevelBoxes(in: data))
    }

    func testVapcReaderRejectsDuplicateFrameIndices() throws {
        let root: [String: Any] = [
            "info": [
                "v": 2, "f": 1, "w": 100, "h": 100, "fps": 30,
                "videoW": 200, "videoH": 100,
                "aFrame": [0, 0, 100, 100], "rgbFrame": [100, 0, 100, 100]
            ],
            "frame": [["i": 0], ["i": 0]]
        ]
        XCTAssertThrowsError(try VapcReader().read(from: JSONSerialization.data(withJSONObject: root)))
    }

    func testInspectorParsesLegacyFixture() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url(VAPFixture.defaultPlayableName))
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 560, height: 280))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 280, height: 280))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertGreaterThan(metadata.frameCount, 0)
    }

    func testInspectorParsesVapcFixture() async throws {
        let url = VAPFixture.url("30f726180edb3f9678571999dd51dff00b3a6cf02cc1fd431beabef47f33bfb1.mp4")
        let metadata = try await AssetInspector().inspect(url: url)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1136, height: 1344))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 750, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .right)
        XCTAssertEqual(metadata.vapVersion, 2)
        XCTAssertEqual(metadata.frameCount, 96)
        XCTAssertEqual(metadata.dynamicSources.first?.tag, "avatar")
    }

    func testAllCommittedMediaFixturesInspectWithoutCrash() async throws {
        let invalid = Set(VAPFixture.invalidXMLNames)
        for url in VAPFixture.allMP4URLs where !invalid.contains(url.lastPathComponent) {
            let metadata = try await AssetInspector().inspect(url: url)
            XCTAssertGreaterThan(metadata.frameCount, 0, url.lastPathComponent)
            XCTAssertGreaterThan(metadata.duration, 0, url.lastPathComponent)
        }
    }

    func testInspectorRejectsInvalidXMLFixture() async {
        do {
            _ = try await AssetInspector().inspect(url: VAPFixture.url(VAPFixture.invalidXMLNames[0]))
            XCTFail("Expected invalidMP4")
        } catch let error as PlaybackError {
            XCTAssertEqual(error.code, .invalidMP4)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testAssetReaderProducesMonotonicFrames() async throws {
        let source = AVAssetReaderFrameSource(url: VAPFixture.url(VAPFixture.defaultPlayableName))
        _ = try await source.prepare()
        let buffer = FrameRingBuffer(capacity: 120)
        let finished = expectation(description: "decoder finished")
        var result: Result<Void, PlaybackError>?
        source.startProducing(to: buffer, token: .make(), didProduce: { _ in }) {
            result = $0
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        if case .failure(let error) = result { throw error }
        XCTAssertGreaterThan(buffer.count, 0)
        var previous = CMTime.negativeInfinity
        while let frame = buffer.dequeue() {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(frame.presentationTime, previous), 0)
            previous = frame.presentationTime
        }
        source.cancel()
    }

    func testInvalidXMLFixtureIsNotAValidMP4Header() throws {
        let url = VAPFixture.url(VAPFixture.invalidXMLNames[0])
        let data = try Data(contentsOf: url)
        XCTAssertFalse(data.starts(with: Data("ftyp".utf8)))
        let prefix = String(data: data.prefix(32), encoding: .utf8) ?? ""
        XCTAssertTrue(prefix.contains("xml") || prefix.contains("Error"))
    }
}
