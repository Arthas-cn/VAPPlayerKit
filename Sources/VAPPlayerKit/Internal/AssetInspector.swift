import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia

struct InspectionResult {
    let metadata: AssetMetadata
    let vapc: VapcDocument
}

/// 将本地文件转换为不可变 `AssetMetadata`。只在后台运行，结果不得夹带 parser cursor 或文件句柄。
///
/// 对照 `vap-master` 的 `QGMP4Parser` + `QGVAPConfigManager`，但媒体轨交给 AVFoundation 校验。
final class AssetInspector {
    private let maximumFileSize: UInt64 = 2 * 1_024 * 1_024 * 1_024

    func inspect(url: URL) async throws -> AssetMetadata {
        (try await inspectDetails(url: url)).metadata
    }

    func inspectDetails(url: URL) async throws -> InspectionResult {
        guard url.isFileURL else {
            throw PlaybackError.invalidURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw PlaybackError.fileNotFound
        }
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

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw PlaybackError.invalidMP4(reason: "File cannot be read.")
        }
        let boxes = try MP4BoxReader().topLevelBoxes(in: data)
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
        if let box = boxes.first(where: { $0.type == "vapc" }) {
            vapc = try VapcReader().read(from: data.subdata(in: box.payloadRange))
            guard approximatelyEqual(vapc.encodedVideoSize, encodedSize) else {
                throw PlaybackError.invalidVapc(reason: "videoW/videoH do not match the video track.")
            }
        } else {
            vapc = try await legacyDocument(encodedVideoSize: encodedSize, duration: durationSeconds, track: videoTrack)
        }

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
        return InspectionResult(metadata: metadata, vapc: vapc)
    }

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

    /// legacy VAP 的唯一 fallback：packed 帧左右等分，左半为 Alpha、右半为 RGB。
    private func legacyDocument(encodedVideoSize: CGSize, duration: TimeInterval, track: AVAssetTrack) async throws -> VapcDocument {
        guard Int(encodedVideoSize.width) % 2 == 0 else {
            throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded width for the left/right split.")
        }
        let canvas = CGSize(width: encodedVideoSize.width / 2, height: encodedVideoSize.height)
        let nominalFPS = (try? await track.load(.nominalFrameRate)) ?? 0
        guard nominalFPS > 0, nominalFPS <= 240 else {
            throw PlaybackError.invalidMP4(reason: "Legacy VAP has no usable frame rate.")
        }
        let frameCount = max(1, Int((duration * Double(nominalFPS)).rounded()))
        return VapcDocument(
            version: 0,
            canvasSize: canvas,
            alphaMode: .left,
            frameCount: frameCount,
            framesPerSecond: Int(nominalFPS.rounded()),
            encodedVideoSize: encodedVideoSize,
            rgbRect: CGRect(x: canvas.width, y: 0, width: canvas.width, height: canvas.height),
            alphaRect: CGRect(origin: .zero, size: canvas),
            sources: [],
            frames: [:]
        )
    }

    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }
}
