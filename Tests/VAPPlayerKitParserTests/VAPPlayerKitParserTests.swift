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

    func testMP4BoxReaderScansFileHeadersAndReadsOnlySelectedPayload() throws {
        let prefix = Data([0, 0, 0, 8]) + Data("ftyp".utf8)
        let payload = Data("{\"vapc\":true}".utf8)
        let boxSize = UInt32(8 + payload.count)
        var vapcHeader = Data([
            UInt8((boxSize >> 24) & 0xff),
            UInt8((boxSize >> 16) & 0xff),
            UInt8((boxSize >> 8) & 0xff),
            UInt8(boxSize & 0xff)
        ])
        vapcHeader.append(Data("vapc".utf8))

        var fileData = prefix
        fileData.append(vapcHeader)
        fileData.append(payload)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vapplayerkit-box-reader-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try fileData.write(to: url)

        let reader = MP4BoxReader()
        let boxes = try reader.topLevelBoxes(inFile: url, fileSize: UInt64(fileData.count))
        XCTAssertEqual(boxes.map(\.type), ["ftyp", "vapc"])
        XCTAssertEqual(try reader.readPayload(of: boxes[1], inFile: url), payload)
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

    func testVapcReaderRejectsDynamicTextureBudgetsBeforeRasterization() throws {
        let commonInfo: [String: Any] = [
            "v": 2, "f": 1, "w": 100, "h": 100, "fps": 30,
            "videoW": 200, "videoH": 100,
            "aFrame": [0, 0, 100, 100], "rgbFrame": [100, 0, 100, 100]
        ]
        let oversized: [String: Any] = [
            "info": commonInfo,
            "src": [[
                "srcId": "huge", "srcType": "img", "srcTag": "huge",
                "w": 5_000, "h": 5_000
            ]]
        ]
        XCTAssertThrowsError(try VapcReader().read(from: JSONSerialization.data(withJSONObject: oversized)))

        let aggregateSources: [[String: Any]] = (0..<9).map { index in
            [
                "srcId": "\(index)", "srcType": "img", "srcTag": "image\(index)",
                "w": 2_048, "h": 2_048
            ]
        }
        let aggregate: [String: Any] = ["info": commonInfo, "src": aggregateSources]
        XCTAssertThrowsError(try VapcReader().read(from: JSONSerialization.data(withJSONObject: aggregate)))
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
        let url = VAPFixture.url("8.mp4")
        let metadata = try await AssetInspector().inspect(url: url)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1136, height: 1344))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 750, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .right)
        XCTAssertEqual(metadata.vapVersion, 2)
        XCTAssertEqual(metadata.frameCount, 96)
        XCTAssertEqual(metadata.dynamicSources.first?.tag, "avatar")
        XCTAssertEqual(metadata.dynamicSources.first?.kind, .image)
    }

    func testInspectorExposesTextSourceKindForContentTag() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("13.mp4"))
        XCTAssertEqual(metadata.dynamicSources.map(\.tag), ["avatar1", "avatar2", "content"])
        XCTAssertEqual(metadata.dynamicSources.map(\.kind), [.image, .image, .text])
    }

    func testAllCommittedMediaFixturesInspectWithoutCrash() async throws {
        XCTAssertEqual(VAPFixture.playableURLs.count, 19)
        for url in VAPFixture.playableURLs {
            let metadata = try await AssetInspector().inspect(url: url)
            XCTAssertGreaterThan(metadata.frameCount, 0, url.lastPathComponent)
            XCTAssertGreaterThan(metadata.duration, 0, url.lastPathComponent)
        }
    }


    func testEveryCommittedMediaFixtureDecodesFrames() async throws {
        for url in VAPFixture.playableURLs {
            let source = AVAssetReaderFrameSource(url: url)
            _ = try await source.prepare()
            let buffer = FrameRingBuffer(capacity: 8)
            let decodedFrames = FrameCountRecorder()
            let finished = expectation(description: "decoder finished: \(url.lastPathComponent)")
            var result: Result<Void, PlaybackError>?
            source.startProducing(
                to: buffer,
                token: .make(),
                startTime: .zero,
                frameIndexOffset: 0,
                didProduce: { _ in
                    _ = buffer.dequeue()
                    decodedFrames.increment()
                }
            ) {
                result = $0
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 10)
            if case .failure(let error) = result {
                XCTFail("\(url.lastPathComponent) failed to decode: \(error)")
            }
            XCTAssertGreaterThan(decodedFrames.value, 0, url.lastPathComponent)
            source.cancel()
        }
    }

    func testInspectorRejectsInvalidXMLFixture() async {
        for name in VAPFixture.invalidXMLNames {
            do {
                _ = try await AssetInspector().inspect(url: VAPFixture.url(name))
                XCTFail("Expected invalidMP4 for \(name)")
            } catch let error as PlaybackError {
                XCTAssertEqual(error.code, .invalidMP4, name)
            } catch {
                XCTFail("Unexpected error for \(name): \(error)")
            }
        }
    }

    func testAssetReaderProducesMonotonicFrames() async throws {
        let source = AVAssetReaderFrameSource(url: VAPFixture.url(VAPFixture.defaultPlayableName))
        _ = try await source.prepare()
        let buffer = FrameRingBuffer(capacity: 120)
        let finished = expectation(description: "decoder finished")
        var result: Result<Void, PlaybackError>?
        source.startProducing(
            to: buffer,
            token: .make(),
            startTime: .zero,
            frameIndexOffset: 0,
            didProduce: { _ in }
        ) {
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
        for name in VAPFixture.invalidXMLNames {
            let data = try Data(contentsOf: VAPFixture.url(name))
            XCTAssertFalse(data.starts(with: Data("ftyp".utf8)), name)
            let prefix = String(data: data.prefix(32), encoding: .utf8) ?? ""
            XCTAssertTrue(prefix.contains("xml") || prefix.contains("Error"), name)
        }
    }
}

private final class FrameCountRecorder {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
