import XCTest
import CoreMedia
import Synchronization
@testable import VAPPlayerKit

/// 覆盖 VAPC/MP4 边界校验、真实素材检查与解码时间戳，使用 bundle 中的正式 fixture。
final class VAPPlayerKitParserTests: XCTestCase {
    /// 缺失的本地文件应返回 fileNotFound，不能进入容器或媒体解析。
    func testInspectorRejectsMissingFile() async {
        let inspector = AssetInspector()
        let url = URL(fileURLWithPath: "/tmp/vapplayerkit-missing-\(UUID().uuidString).mp4")
        do {
            _ = try await inspector.inspect(url: url, assetMode: .automatic)
            XCTFail("Expected fileNotFound")
        } catch let error as PlaybackError {
            // 缺文件必须保留专门错误码，便于宿主触发重新下载。
            XCTAssertEqual(error.code, .fileNotFound)
        } catch {
            // 非 PlaybackError 表示文件输入的错误归一化失效。
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// 空 VAPC 数据应报 invalidVapc，而非生成默认布局。
    func testVapcReaderRejectsEmptyData() {
        XCTAssertThrowsError(try VapcReader().read(from: Data())) { error in
            // 类型不符时先报告实际错误，避免后续断言掩盖错误边界。
            guard let playbackError = error as? PlaybackError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(playbackError.code, .invalidVapc)
        }
    }

    /// 完整 VAPC 应解析出版本、画布、Alpha 方向及动态槽帧引用。
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

    /// 四种相对方位都应依据矩形计算，不能固定假定 Alpha 在左侧。
    func testVapcReaderRecognizesAllAlphaDirections() throws {
        let layouts: [(AlphaMode, [Int], [Int], [Int])] = [
            (.left, [100, 200], [0, 0, 100, 200], [100, 0, 100, 200]),
            (.right, [100, 200], [100, 0, 100, 200], [0, 0, 100, 200]),
            (.top, [200, 100], [0, 0, 200, 100], [0, 100, 200, 100]),
            (.bottom, [200, 100], [0, 100, 200, 100], [0, 0, 200, 100])
        ]

        for (expectedMode, canvasSize, alphaFrame, rgbFrame) in layouts {
            let json: [String: Any] = [
                "info": [
                    "v": 2, "f": 1, "w": canvasSize[0], "h": canvasSize[1], "fps": 30,
                    "videoW": 200, "videoH": 200,
                    "aFrame": alphaFrame, "rgbFrame": rgbFrame
                ]
            ]
            let document = try VapcReader().read(
                from: JSONSerialization.data(withJSONObject: json)
            )
            XCTAssertEqual(document.alphaMode, expectedMode)
        }
    }

    /// 旧 VAPC 同时缺失版本和帧数时，可用轨道帧数补齐并保持布局。
    func testVapcReaderParsesLegacyLayoutWithTrackFrameCount() throws {
        let json: [String: Any] = [
            "info": [
                "w": 750, "h": 1334, "fps": 30,
                "videoW": 1500, "videoH": 1334,
                "aFrame": [0, 0, 750, 1334], "rgbFrame": [750, 0, 750, 1334]
            ]
        ]
        let document = try VapcReader().read(
            from: JSONSerialization.data(withJSONObject: json),
            legacyFrameCount: 121
        )
        XCTAssertEqual(document.version, 0)
        XCTAssertEqual(document.frameCount, 121)
        XCTAssertEqual(document.framesPerSecond, 30)
        XCTAssertEqual(document.alphaMode, .left)
        XCTAssertTrue(document.sources.isEmpty)
        XCTAssertTrue(document.frames.isEmpty)
    }

    /// 结构化头只缺帧数时应拒绝，不能误走旧格式的兼容路径。
    func testVapcReaderRejectsPartiallyMissingStructuredHeader() throws {
        let json: [String: Any] = [
            "info": [
                "v": 2, "w": 100, "h": 100, "fps": 30,
                "videoW": 200, "videoH": 100,
                "aFrame": [0, 0, 100, 100], "rgbFrame": [100, 0, 100, 100]
            ]
        ]
        XCTAssertThrowsError(try VapcReader().read(
            from: JSONSerialization.data(withJSONObject: json),
            legacyFrameCount: 1
        ))
    }

    /// 未知 VAPC 版本和超出视频边界的矩形都必须拒绝。
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

    /// 声明长度超过文件剩余字节的 MP4 box 必须被拒绝。
    func testMP4BoxReaderRejectsBoxPastFileBoundary() {
        var data = Data([0, 0, 0, 32])
        data.append(Data("ftyp".utf8))
        data.append(Data(repeating: 0, count: 4))
        XCTAssertThrowsError(try MP4BoxReader().topLevelBoxes(in: data))
    }

    /// 文件扫描应只按 box 头定位，再读取指定 VAPC payload。
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

    /// 同一帧索引重复出现时必须拒绝，避免覆盖已有动态槽数据。
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

    /// 单张或全场动态纹理超预算时应在解析阶段拒绝，避免进入栅格化。
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

    /// automatic 应识别基础旧素材的左 Alpha、画布和 H.264 编码。
    func testInspectorParsesLegacyFixture() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url(VAPFixture.defaultPlayableName), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 560, height: 280))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 280, height: 280))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertGreaterThan(metadata.frameCount, 0)
    }

    /// automatic 应读取标准 VAPC 的右 Alpha、动态图片槽和真实帧数。
    func testInspectorParsesVapcFixture() async throws {
        let url = VAPFixture.url("8.mp4")
        let metadata = try await AssetInspector().inspect(url: url, assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1136, height: 1344))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 750, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .right)
        XCTAssertEqual(metadata.vapVersion, 2)
        XCTAssertEqual(metadata.frameCount, 96)
        XCTAssertEqual(metadata.dynamicSources.first?.tag, "avatar")
        XCTAssertEqual(metadata.dynamicSources.first?.kind, .image)
    }

    /// 缺少版本字段的真实旧 VAPC 应结合轨道得到正确帧数及画布。
    func testInspectorParsesLegacyVapcMovieFixture() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("movie.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1500, height: 1334))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 750, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertEqual(metadata.frameCount, 121)
        XCTAssertEqual(metadata.dynamicSources.count, 0)
    }

    /// 无 VAPC 的左 Alpha 素材应自动识别拼接布局及媒体时长。
    func testInspectorDetectsAlphaLeftMovieWithoutVapc() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("alpha_left_moive.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1504, height: 448))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 752, height: 448))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertEqual(metadata.frameCount, 72)
        XCTAssertEqual(metadata.duration, 3, accuracy: 0.01)
        XCTAssertTrue(metadata.isVAP)
        XCTAssertTrue(metadata.dynamicSources.isEmpty)
    }

    /// ordinary MP4 自动检查应使用完整画面，不能被误当作拼接透明视频。
    func testInspectorAutomaticallyUsesFullFrameForOrdinaryMP4() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("home.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 720, height: 1280))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 720, height: 1280))
        XCTAssertEqual(metadata.alphaMode, .none)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertEqual(metadata.dynamicSources.count, 0)
        XCTAssertFalse(metadata.isVAP)
    }

    /// 无 VAPC 的国庆素材应自动识别左 Alpha 布局且没有动态槽。
    func testInspectorDetectsNationalDayLegacyPackedVAPWithoutVapc() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("nationalDayEffect.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1504, height: 320))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 752, height: 320))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertTrue(metadata.isVAP)
        XCTAssertTrue(metadata.dynamicSources.isEmpty)
    }

    /// 初始空白帧不能阻止后续抽帧识别真实旧拼接布局。
    func testInspectorDetectsNationLegacyPackedVAPAfterInitialBlankFrame() async throws {
        let url = VAPFixture.url("nation.mp4")
        let metadata = try await AssetInspector().inspect(url: url, assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1504, height: 1334))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 752, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertTrue(metadata.isVAP)
        XCTAssertEqual(metadata.frameCount, 120)
        XCTAssertTrue(metadata.dynamicSources.isEmpty)
    }

    /// 探测应按时长的 20%、50%、70% 顺序进行，首个命中后停止。
    func testLegacyProbeScheduleUsesAssetDurationInOrder() {
        let probeTimes = LegacyPackedVAPDetector.probeTimes(for: 10.0)
        XCTAssertEqual(probeTimes.count, 3)
        XCTAssertEqual(probeTimes[0], 2.0, accuracy: 0.001)
        XCTAssertEqual(probeTimes[1], 5.0, accuracy: 0.001)
        XCTAssertEqual(probeTimes[2], 7.0, accuracy: 0.001)
        XCTAssertTrue(LegacyPackedVAPDetector.probeTimes(for: 0).isEmpty)
        XCTAssertTrue(LegacyPackedVAPDetector.probeTimes(for: .infinity).isEmpty)

        let trackRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 10.0, preferredTimescale: 600)
        )
        let readDuration = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        var sampledStarts: [Double] = []
        let firstResult = LegacyPackedVAPDetector.firstMatchingMode(
            duration: 10.0,
            trackRange: trackRange,
            readDuration: readDuration
        ) { range in
            sampledStarts.append(CMTimeGetSeconds(range.start))
            return LegacyPackedLayout(alphaMode: .left, alphaOffset: 0)
        }
        XCTAssertEqual(firstResult?.alphaMode, .left)
        XCTAssertEqual(sampledStarts.count, 1)
        XCTAssertEqual(sampledStarts[0], 2.0, accuracy: 0.001)

        sampledStarts.removeAll()
        let secondResult = LegacyPackedVAPDetector.firstMatchingMode(
            duration: 10.0,
            trackRange: trackRange,
            readDuration: readDuration
        ) { range in
            sampledStarts.append(CMTimeGetSeconds(range.start))
            return sampledStarts.count == 2 ? LegacyPackedLayout(alphaMode: .right, alphaOffset: 0) : nil
        }
        XCTAssertEqual(secondResult?.alphaMode, .right)
        XCTAssertEqual(sampledStarts.count, 2)
        XCTAssertEqual(sampledStarts[1], 5.0, accuracy: 0.001)

        sampledStarts.removeAll()
        let noResult = LegacyPackedVAPDetector.firstMatchingMode(
            duration: 10.0,
            trackRange: trackRange,
            readDuration: readDuration
        ) { range in
            sampledStarts.append(CMTimeGetSeconds(range.start))
            return nil
        }
        XCTAssertNil(noResult)
        XCTAssertEqual(sampledStarts.count, 3)
        XCTAssertEqual(sampledStarts[2], 7.0, accuracy: 0.001)
    }

    /// 带纵向偏移的旧拼接素材应保留不同颜色与 Alpha 起点。
    func testInspectorDetectsOffsetLegacyPackedVAPWithoutVapc() async throws {
        let inspection = try await AssetInspector().inspectDetails(
            url: VAPFixture.url("7878.mp4"), assetMode: .automatic
        )
        let metadata = inspection.metadata
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1136, height: 1632))
        XCTAssertEqual(metadata.alphaMode, .right)
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 568, height: 1270))
        XCTAssertEqual(metadata.vapVersion, 0)
        XCTAssertEqual(metadata.codec, "h264")
        XCTAssertEqual(metadata.frameCount, 150)
        XCTAssertEqual(metadata.duration, 6, accuracy: 0.01)
        XCTAssertTrue(metadata.isVAP)
        XCTAssertTrue(metadata.dynamicSources.isEmpty)
        XCTAssertEqual(inspection.vapc.rgbRect, CGRect(x: 0, y: 362, width: 568, height: 1270))
        XCTAssertEqual(inspection.vapc.alphaRect, CGRect(x: 568, y: 0, width: 568, height: 1270))
    }

    /// movie01 的自动检查应保留左 Alpha 画布及 300 帧轨道信息。
    func testInspectorDetectsMovie01LegacyPackedVAP() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("movie01.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1504, height: 1334))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 752, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.frameCount, 300)
        XCTAssertTrue(metadata.isVAP)
        XCTAssertTrue(metadata.dynamicSources.isEmpty)
    }

    /// movie02 的自动检查应保留左 Alpha 画布及 229 帧轨道信息。
    func testInspectorDetectsMovie02LegacyPackedVAP() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("movie02.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.encodedVideoSize, CGSize(width: 1500, height: 1334))
        XCTAssertEqual(metadata.canvasSize, CGSize(width: 750, height: 1334))
        XCTAssertEqual(metadata.alphaMode, .left)
        XCTAssertEqual(metadata.frameCount, 229)
        XCTAssertTrue(metadata.isVAP)
        XCTAssertTrue(metadata.dynamicSources.isEmpty)
    }

    /// 显式 ordinaryVideo 使用完整画面，显式 vap 仍支持旧左 Alpha 兼容布局。
    func testAssetModeCanOverrideAutomaticLegacyDetection() async throws {
        let inspector = AssetInspector()
        let ordinary = try await inspector.inspectDetails(
            url: VAPFixture.url(VAPFixture.defaultPlayableName),
            assetMode: .ordinaryVideo
        ).metadata
        XCTAssertEqual(ordinary.canvasSize, ordinary.encodedVideoSize)
        XCTAssertEqual(ordinary.alphaMode, .none)

        let legacyVAP = try await inspector.inspectDetails(
            url: VAPFixture.url("home.mp4"),
            assetMode: .vap
        ).metadata
        XCTAssertEqual(legacyVAP.alphaMode, .left)
        XCTAssertEqual(legacyVAP.canvasSize.width, legacyVAP.encodedVideoSize.width / 2)
    }

    /// VAPC 的图片和文本槽种类应按素材声明公开，保持 tag 顺序。
    func testInspectorExposesTextSourceKindForContentTag() async throws {
        let metadata = try await AssetInspector().inspect(url: VAPFixture.url("13.mp4"), assetMode: .automatic)
        XCTAssertEqual(metadata.dynamicSources.map(\.tag), ["avatar1", "avatar2", "content"])
        XCTAssertEqual(metadata.dynamicSources.map(\.kind), [.image, .image, .text])
    }

    /// 全部合法正式 fixture 应完成 automatic 检查并得到有限正帧数与时长。
    func testAllCommittedMediaFixturesInspectWithoutCrash() async throws {
        XCTAssertEqual(
            VAPFixture.playableURLs.count,
            22 + VAPFixture.optionalFixtureNames.filter {
                ["home.mp4", "nationalDayEffect.mp4", "nation.mp4", "movie01.mp4", "movie02.mp4"].contains($0)
            }.count
        )
        for url in VAPFixture.playableURLs {
            let metadata = try await AssetInspector().inspect(url: url, assetMode: .automatic)
            XCTAssertGreaterThan(metadata.frameCount, 0, url.lastPathComponent)
            XCTAssertGreaterThan(metadata.duration, 0, url.lastPathComponent)
        }
    }


    /// 每份正式素材都应实际产出视频帧，并在换下一份素材前等待解码器排空。
    func testEveryCommittedMediaFixtureDecodesFrames() async throws {
        for url in VAPFixture.playableURLs {
            let source = AVAssetReaderFrameSource(url: url)
            _ = try await source.prepare()
            let buffer = FrameRingBuffer(capacity: 8)
            let decodedFrames = FrameCountRecorder()
            let finished = expectation(description: "decoder finished: \(url.lastPathComponent)")
            let result = Mutex<Result<Void, PlaybackError>?>(nil)
            source.startProducing(
                to: buffer,
                token: .make(),
                startTime: .zero,
                frameIndexOffset: 0,
                didProduce: { _ in
                    // 即时消费防止容量为 8 的缓冲阻塞长素材生产，计数单独受锁保护。
                    _ = buffer.dequeue()
                    decodedFrames.increment()
                }
            ) { completion in
                // 结果写入受 Mutex 隔离，通知只在完整结果已经可见后发出。
                result.withLock { $0 = completion }
                finished.fulfill()
            }
            await fulfillment(of: [finished], timeout: 10)
            // 超时或失败也必须等待底层队列退出，避免下一素材与旧 decoder 重叠。
            await source.cancelAndWait()
            let completion = try XCTUnwrap(result.withLock { $0 })
            // 保留逐文件错误信息，同时继续验证其它 fixture 的实际解码能力。
            if case .failure(let error) = completion {
                XCTFail("\(url.lastPathComponent) failed to decode: \(error)")
            }
            XCTAssertGreaterThan(decodedFrames.value, 0, url.lastPathComponent)
        }
    }

    /// 伪装成 mp4 的 XML 文件应返回 invalidMP4，不能交给解码器。
    func testInspectorRejectsInvalidXMLFixture() async {
        for name in VAPFixture.existingInvalidXMLNames {
            do {
                _ = try await AssetInspector().inspect(url: VAPFixture.url(name), assetMode: .automatic)
                XCTFail("Expected invalidMP4 for \(name)")
            } catch let error as PlaybackError {
                // XML 媒体应在容器边界被拒绝，不能变成解码失败。
                XCTAssertEqual(error.code, .invalidMP4, name)
            } catch {
                // 记录 fixture 名称，保留其它负向素材继续执行的机会。
                XCTFail("Unexpected error for \(name): \(error)")
            }
        }
    }

    /// 真实解码帧应按非递减 PTS 排列，验证结束后显式排空解码来源。
    func testAssetReaderProducesMonotonicFrames() async throws {
        let source = AVAssetReaderFrameSource(url: VAPFixture.url(VAPFixture.defaultPlayableName))
        _ = try await source.prepare()
        let buffer = FrameRingBuffer(capacity: 120)
        let finished = expectation(description: "decoder finished")
        let result = Mutex<Result<Void, PlaybackError>?>(nil)
        source.startProducing(
            to: buffer,
            token: .make(),
            startTime: .zero,
            frameIndexOffset: 0,
            // 120 帧容量覆盖本素材全部帧，保留队列供结束后验证 PTS。
            didProduce: { _ in }
        ) { completion in
            // decoder 回调与测试等待者不共享未受保护的可变局部变量。
            result.withLock { $0 = completion }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        // 先确认生产已结束，再读取不可变结果及缓冲区，不让失败路径遗留后台工作。
        await source.cancelAndWait()
        let completion = try XCTUnwrap(result.withLock { $0 })
        try completion.get()
        XCTAssertGreaterThan(buffer.count, 0)
        var previous = CMTime.negativeInfinity
        while let frame = buffer.dequeue() {
            XCTAssertGreaterThanOrEqual(CMTimeCompare(frame.presentationTime, previous), 0)
            previous = frame.presentationTime
        }
    }

    /// 负向 fixture 应确实保留 XML 内容，防止素材被误替换成正常 MP4。
    func testInvalidXMLFixtureIsNotAValidMP4Header() throws {
        for name in VAPFixture.existingInvalidXMLNames {
            let data = try Data(contentsOf: VAPFixture.url(name))
            XCTAssertFalse(data.starts(with: Data("ftyp".utf8)), name)
            let prefix = String(data: data.prefix(32), encoding: .utf8) ?? ""
            XCTAssertTrue(prefix.contains("xml") || prefix.contains("Error"), name)
        }
    }
}

/// 跨 decoder 回调与测试任务统计帧数；只返回整数快照，不泄漏可变状态。
private final class FrameCountRecorder: Sendable {
    /// 计数的唯一存储；所有读写都必须经过同一个 Mutex。
    private let count = Mutex(0)

    /// 返回锁保护下的计数快照，不能从外部修改内部计数。
    var value: Int { count.withLock { $0 } }

    /// 记录一次实际产帧回调，不包含帧缓存是否随后丢帧的判断。
    func increment() { count.withLock { $0 += 1 } }
}
