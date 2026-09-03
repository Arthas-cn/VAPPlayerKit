import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia

/// 一次 inspection 的完整产物：对外暴露的不可变 metadata，以及内部 vapc 播放布局。
///
/// `AssetMetadataCache` 命中后会用 metadata 上挂着的 `playbackDocument` 还原本结构，
/// 从而跳过 MP4 box / vapc JSON 再解析。
struct InspectionResult {
    /// 宿主可见的资源摘要，同时携带内部布局和文件签名。
    let metadata: AssetMetadata
    /// 渲染所需的完整 vapc 文档，与 `metadata.playbackDocument` 是同一份布局。
    let vapc: VapcDocument
    /// inspection 已加载的 AVFoundation 媒体上下文，供解码器准备阶段复用。
    let frameSourceContext: FrameSourceContext?
}

/// 将本地文件转换为不可变 `AssetMetadata`。只在后台运行，结果不得夹带 parser cursor 或文件句柄。
///
/// 对照 `vap-master` 的 `QGMP4Parser` + `QGVAPConfigManager`，但媒体轨交给 AVFoundation 校验。
/// 解析成功后会把 vapc 布局和文件签名写进 metadata，供 `AssetMetadataCache` 复用。
final class AssetInspector {
    /// 单次 inspection 允许读取的最大文件大小，防止异常大文件拖垮解析线程。
    private let maximumFileSize: UInt64 = 2 * 1_024 * 1_024 * 1_024

    /// 只返回宿主可见的 metadata。内部播放仍应调用 `inspectDetails` 以拿到 vapc。
    func inspect(url: URL) async throws -> AssetMetadata {
        (try await inspectDetails(url: url, assetMode: .automatic)).metadata
    }

    /// 解析本地 VAP 文件，产出可缓存的 metadata 和完整 vapc 布局。
    ///
    /// 会同时采集文件 identity、大小和修改时间，作为后续缓存命中的签名。
    func inspectDetails(
        url: URL,
        assetMode: PlaybackAssetMode = .automatic
    ) async throws -> InspectionResult {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound
        }
        // 一次读齐签名字段：大小、是否常规文件、修改时间、稳定文件 identity。
        let resourceValues = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .contentModificationDateKey,
            .fileResourceIdentifierKey
        ])
        guard resourceValues.isRegularFile == true, let fileSize = resourceValues.fileSize, fileSize > 0 else {
            throw PlaybackError.invalidMP4(reason: "URL is not a non-empty regular file.")
        }
        guard UInt64(fileSize) <= maximumFileSize else {
            throw PlaybackError.invalidMP4(reason: "File exceeds the 2 GiB inspection limit.")
        }

        let boxReader = MP4BoxReader()
        let boxes = try boxReader.topLevelBoxes(inFile: url, fileSize: UInt64(fileSize))
        guard boxes.contains(where: { $0.type == "ftyp" }) else {
            throw PlaybackError.invalidMP4(reason: "Missing ftyp box.")
        }
        guard boxes.contains(where: { $0.type == "moov" }) else {
            throw PlaybackError.invalidMP4(reason: "Missing moov box.")
        }

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
        } catch {
            throw PlaybackError.invalidMP4(reason: "AVFoundation could not load media tracks.")
        }
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw PlaybackError.invalidMP4(reason: "Missing video track.")
        }
        let formatDescriptions: [CMFormatDescription]
        do {
            formatDescriptions = try await videoTrack.load(.formatDescriptions)
        } catch {
            throw PlaybackError.invalidMP4(reason: "Video track description is unavailable.")
        }
        guard let format = formatDescriptions.first else {
            throw PlaybackError.invalidMP4(reason: "Missing video format description.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let encodedSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        guard encodedSize.width > 0, encodedSize.height > 0 else {
            throw PlaybackError.invalidMP4(reason: "Video track has an invalid encoded size.")
        }
        let codec = try codecName(CMFormatDescriptionGetMediaSubType(format))
        let durationSeconds = CMTimeGetSeconds(duration)
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw PlaybackError.invalidMP4(reason: "Media duration is invalid.")
        }

        let vapc: VapcDocument
        if assetMode == .ordinaryVideo {
            vapc = try await ordinaryDocument(
                encodedVideoSize: encodedSize,
                duration: durationSeconds,
                track: videoTrack
            )
        } else if let box = boxes.first(where: { $0.type == "vapc" }) {
            guard box.payloadRange.count <= VapcReader.maximumJSONSize else {
                throw PlaybackError.invalidVapc(reason: "JSON payload is empty or exceeds 8 MiB.")
            }
            let payload = try boxReader.readPayload(of: box, inFile: url)
            // Some older VAP generators emit only the layout portion of VAPC and
            // omit both info.v and info.f. The frame count comes from the media
            // track in that format; never synthesize it from an arbitrary default.
            let legacyFrameCount = try? await inferredLegacyFrameCount(
                duration: durationSeconds,
                track: videoTrack
            )
            vapc = try VapcReader().read(from: payload, legacyFrameCount: legacyFrameCount)
            guard approximatelyEqual(vapc.encodedVideoSize, encodedSize) else {
                throw PlaybackError.invalidVapc(reason: "videoW/videoH do not match the video track.")
            }
        } else if assetMode == .vap {
            // The explicit legacy override preserves the historical API contract:
            // old packed VAP defaults to the traditional left-alpha layout.
            vapc = try await legacyDocument(
                encodedVideoSize: encodedSize,
                duration: durationSeconds,
                track: videoTrack,
                alphaMode: .left
            )
        } else if let alphaMode = LegacyPackedVAPDetector.detect(
            asset: asset,
            track: videoTrack,
            encodedVideoSize: encodedSize
        ) {
            vapc = try await legacyDocument(
                encodedVideoSize: encodedSize,
                duration: durationSeconds,
                track: videoTrack,
                alphaMode: alphaMode
            )
        } else {
            vapc = try await ordinaryDocument(
                encodedVideoSize: encodedSize,
                duration: durationSeconds,
                track: videoTrack
            )
        }

        // 把完整 vapc 布局和文件签名挂到 metadata 上，供全局缓存与复用播放校验。
        // 公开 initializer 不会设置这些字段，因此手工摘要对象无法跳过 inspection。
        let metadata = AssetMetadata(
            encodedVideoSize: encodedSize,
            canvasSize: vapc.canvasSize,
            alphaMode: vapc.alphaMode,
            frameCount: vapc.frameCount,
            duration: durationSeconds,
            containsAudio: tracks.contains(where: { $0.mediaType == .audio }),
            codec: codec,
            vapVersion: vapc.version,
            dynamicSources: vapc.sources.map {
                SourceMetadata(tag: $0.tag, slotSize: $0.slotSize, kind: $0.kind == .text ? .text : .image)
            }
        )
        metadata.playbackDocument = vapc
        metadata.sourceURL = url.standardizedFileURL
        metadata.sourceFileSize = Int64(fileSize)
        metadata.sourceModificationDate = resourceValues.contentModificationDate
        metadata.sourceFileIdentifier = resourceValues.fileResourceIdentifier as? Data
        let frameSourceMetadata = FrameSourceMetadata(encodedVideoSize: encodedSize, codec: codec)
        let frameSourceContext = FrameSourceContext(
            asset: asset,
            videoTrack: videoTrack,
            metadata: frameSourceMetadata
        )
        metadata.frameSourceContext = frameSourceContext
        return InspectionResult(
            metadata: metadata,
            vapc: vapc,
            frameSourceContext: frameSourceContext
        )
    }

    /// 把 FourCC 转成 `h264` / `hevc`。其他 codec 直接失败。
    private func codecName(_ codec: FourCharCode) throws -> String {
        switch codec {
        case kCMVideoCodecType_H264: return "h264"
        case kCMVideoCodecType_HEVC: return "hevc"
        default:
            let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xff) }
            let name = String(bytes: bytes, encoding: .ascii) ?? String(codec)
            throw PlaybackError.unsupportedCodec(name)
        }
    }

    /// legacy VAP 的 fallback：Alpha/RGB 是等尺寸 packed 区域，方向由 detector
    /// 返回；显式 `.vap` 入口使用兼容历史素材的左 Alpha 默认值。
    private func legacyDocument(
        encodedVideoSize: CGSize,
        duration: TimeInterval,
        track: AVAssetTrack,
        alphaMode: AlphaMode
    ) async throws -> VapcDocument {
        let canvas: CGSize
        let rgbRect: CGRect
        let alphaRect: CGRect
        switch alphaMode {
        case .left:
            guard Int(encodedVideoSize.width) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded width for the left/right split.")
            }
            canvas = CGSize(width: encodedVideoSize.width / 2, height: encodedVideoSize.height)
            rgbRect = CGRect(x: canvas.width, y: 0, width: canvas.width, height: canvas.height)
            alphaRect = CGRect(origin: .zero, size: canvas)
        case .right:
            guard Int(encodedVideoSize.width) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded width for the left/right split.")
            }
            canvas = CGSize(width: encodedVideoSize.width / 2, height: encodedVideoSize.height)
            rgbRect = CGRect(origin: .zero, size: canvas)
            alphaRect = CGRect(x: canvas.width, y: 0, width: canvas.width, height: canvas.height)
        case .top:
            guard Int(encodedVideoSize.height) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded height for the top/bottom split.")
            }
            canvas = CGSize(width: encodedVideoSize.width, height: encodedVideoSize.height / 2)
            rgbRect = CGRect(x: 0, y: canvas.height, width: canvas.width, height: canvas.height)
            alphaRect = CGRect(origin: .zero, size: canvas)
        case .bottom:
            guard Int(encodedVideoSize.height) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded height for the top/bottom split.")
            }
            canvas = CGSize(width: encodedVideoSize.width, height: encodedVideoSize.height / 2)
            rgbRect = CGRect(origin: .zero, size: canvas)
            alphaRect = CGRect(x: 0, y: canvas.height, width: canvas.width, height: canvas.height)
        case .none:
            throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an Alpha layout.")
        }
        let (nominalFPS, frameCount) = try await inferredLegacyFrameRateAndFrameCount(
            duration: duration,
            track: track
        )
        return VapcDocument(
            assetMode: .vap,
            version: 0,
            canvasSize: canvas,
            alphaMode: alphaMode,
            frameCount: frameCount,
            framesPerSecond: Int(nominalFPS.rounded()),
            encodedVideoSize: encodedVideoSize,
            rgbRect: rgbRect,
            alphaRect: alphaRect,
            sources: [],
            frames: [:]
        )
    }

    /// 普通视频使用完整编码画面，没有 packed Alpha 或动态 VAP 槽位。
    private func ordinaryDocument(
        encodedVideoSize: CGSize,
        duration: TimeInterval,
        track: AVAssetTrack
    ) async throws -> VapcDocument {
        let (nominalFPS, frameCount) = try await inferredLegacyFrameRateAndFrameCount(
            duration: duration,
            track: track
        )
        return VapcDocument(
            assetMode: .ordinaryVideo,
            version: 0,
            canvasSize: encodedVideoSize,
            alphaMode: .none,
            frameCount: frameCount,
            framesPerSecond: Int(nominalFPS.rounded()),
            encodedVideoSize: encodedVideoSize,
            rgbRect: CGRect(origin: .zero, size: encodedVideoSize),
            alphaRect: .zero,
            sources: [],
            frames: [:]
        )
    }

    /// 旧版 VAP 没有独立的帧数字段，使用媒体轨道的 nominal frame rate。
    /// 与无 VAPC 的 legacy 路径共用校验，保证两种旧格式的行为一致。
    private func inferredLegacyFrameCount(duration: TimeInterval, track: AVAssetTrack) async throws -> Int {
        try await inferredLegacyFrameRateAndFrameCount(duration: duration, track: track).frameCount
    }

    private func inferredLegacyFrameRateAndFrameCount(
        duration: TimeInterval,
        track: AVAssetTrack
    ) async throws -> (nominalFPS: Float, frameCount: Int) {
        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 0
        guard nominalFPS > 0, nominalFPS <= 240 else {
            throw PlaybackError.invalidMP4(reason: "Legacy VAP has no usable frame rate.")
        }
        let rawFrameCount = duration * Double(nominalFPS)
        guard rawFrameCount.isFinite, rawFrameCount > 0 else {
            throw PlaybackError.invalidMP4(reason: "Legacy VAP has an invalid frame count.")
        }
        let frameCount = max(1, Int(rawFrameCount.rounded()))
        guard frameCount <= 100_000 else {
            throw PlaybackError.invalidMP4(reason: "Legacy VAP has too many frames.")
        }
        return (nominalFPS, frameCount)
    }

    /// inspector 与 decoder 的编码尺寸允许 1 像素误差。
    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }
}
