import Foundation
import CoreGraphics
import AVFoundation
import CoreMedia

/// 一次完整检查的 Sendable 结果；不暴露 parser cursor、reader 或 GPU 对象。
struct InspectionResult: Sendable {
    /// 对外不可变快照，携带可信文件身份与完整播放布局。
    let metadata: AssetMetadata
    /// 本次解析后的底图和动态槽布局。
    let vapc: VapcDocument
    /// 解码准备使用的纯值来源信息，不跨 actor 共享 AVAsset 或 AVAssetTrack。
    let frameSourceContext: FrameSourceContext?
}

/// 在并发执行器解析本地文件；所有可变 parser/AVFoundation 对象均限于单次检查。
struct AssetInspector: Sendable {
    /// 单文件检查上限，避免异常大文件进入 box 解析。
    private let maximumFileSize: Int64 = 2 * 1_024 * 1_024 * 1_024
    /// 编码帧单边上限，在启动 detector/decoder 前验证。
    private let maximumVideoDimension: Int32 = 8_192
    /// 编码帧总像素上限，约束颜色与透明区合计的解码内存。
    private let maximumVideoPixels: Int64 = 8_388_608

    /// 创建无共享可变状态的检查器；每次调用独立建立 parser 与媒体对象。
    init() {}

    /// 返回组件签发的完整快照；默认按 VAP，自动识别必须由调用者显式选择。
    @concurrent
    func inspect(url: URL, assetMode: PlaybackAssetMode = .vap) async throws -> AssetMetadata {
        try await inspectDetails(url: url, assetMode: assetMode).metadata
    }

    /// 检查容器、视频轨、布局与完整文件身份；取消保留 CancellationError，不生成半份 metadata。
    @concurrent
    func inspectDetails(url: URL, assetMode: PlaybackAssetMode = .vap) async throws -> InspectionResult {
        try Task.checkCancellation()
        let signature = try AssetMetadata.SourceSignature.read(from: url)
        // 大小在读任何 box 之前检查，禁止巨型文件消耗解析资源。
        guard signature.fileSize <= maximumFileSize else {
            throw PlaybackError.invalidMP4(reason: "File exceeds the 2 GiB inspection limit.")
        }
        let boxReader = MP4BoxReader()
        let boxes = try boxReader.topLevelBoxes(inFile: signature.url, fileSize: UInt64(signature.fileSize))
        // MP4 必须同时有文件类型与媒体描述，不能按扩展名假定容器完整。
        guard boxes.contains(where: { $0.type == "ftyp" }), boxes.contains(where: { $0.type == "moov" }) else {
            throw PlaybackError.invalidMP4(reason: "Missing ftyp or moov box.")
        }

        let asset = AVURLAsset(url: signature.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
        } catch {
            // 主动取消不能包装成损坏媒体，否则上层会错误重试或显示资源失败。
            try Task.checkCancellation()
            throw PlaybackError.invalidMP4(reason: "AVFoundation could not load media tracks.")
        }
        try Task.checkCancellation()
        // 缺视频轨的音频文件不能作为画面资源成功返回。
        guard let videoTrack = tracks.first(where: { $0.mediaType == .video }) else {
            throw PlaybackError.invalidMP4(reason: "Missing video track.")
        }
        let formatDescriptions: [CMFormatDescription]
        do {
            formatDescriptions = try await videoTrack.load(.formatDescriptions)
        } catch {
            // 检查轨道元数据的取消仍由调用者处理，不改为格式错误。
            try Task.checkCancellation()
            throw PlaybackError.invalidMP4(reason: "Video track description is unavailable.")
        }
        try Task.checkCancellation()
        // 无编码描述时不能安全创建纹理或计算透明区域。
        guard let format = formatDescriptions.first else {
            throw PlaybackError.invalidMP4(reason: "Missing video format description.")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        try validateDimensions(dimensions)
        let encodedSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        let codec = try codecName(CMFormatDescriptionGetMediaSubType(format))
        let durationSeconds = CMTimeGetSeconds(duration)
        // 无穷或零时长不能作为帧数推算与播放时间轴输入。
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            throw PlaybackError.invalidMP4(reason: "Media duration is invalid.")
        }

        let document: VapcDocument
        switch assetMode {
        // 外部布局是完整合同，必须优先于 vapc 和旧版检测，不能被隐藏 metadata 覆盖。
        case let .packedAlpha(layout):
            document = try await packedDocument(layout: layout, encodedVideoSize: encodedSize, duration: durationSeconds, track: videoTrack)
        // 普通模式始终显示完整画面，即使容器带有 vapc 也不改变路由。
        case .ordinaryVideo:
            document = try await ordinaryDocument(encodedVideoSize: encodedSize, duration: durationSeconds, track: videoTrack)
        // 两种 VAP 路径共用有 vapc 的解析；只有无 vapc 时才区分显式旧布局与启发式检测。
        case .vap, .automatic:
            if let box = boxes.first(where: { $0.type == "vapc" }) {
                // 先限制 JSON payload，再交给有上限的结构化解析器。
                guard box.payloadRange.count <= VapcReader.maximumJSONSize else {
                    throw PlaybackError.invalidVapc(reason: "JSON payload exceeds 8 MiB.")
                }
                let payload = try boxReader.readPayload(of: box, inFile: signature.url)
                let legacyFrameCount = try? await inferredLegacyFrameCount(duration: durationSeconds, track: videoTrack)
                try Task.checkCancellation()
                document = try VapcReader().read(from: payload, legacyFrameCount: legacyFrameCount)
                // 不能信任 JSON 声称的编码画布，纹理实际来自视频轨。
                guard approximatelyEqual(document.encodedVideoSize, encodedSize) else {
                    throw PlaybackError.invalidVapc(reason: "videoW/videoH do not match the video track.")
                }
            } else if assetMode == .vap {
                // 显式 VAP 保留旧版默认左 Alpha 的能力，不进行昂贵且可能误判的探测。
                document = try await legacyDocument(encodedVideoSize: encodedSize, duration: durationSeconds, track: videoTrack, alphaMode: .left)
            } else if let layout = await LegacyPackedVAPDetector.detect(asset: asset, track: videoTrack, encodedVideoSize: encodedSize, duration: durationSeconds) {
                // 只有 automatic 可用检测结果，方向与偏移必须整体保留。
                document = try await legacyDocument(encodedVideoSize: encodedSize, duration: durationSeconds, track: videoTrack, alphaMode: layout.alphaMode, alphaOffset: layout.alphaOffset)
            } else {
                // automatic 无可靠拼接证据时按普通视频，不伪造 Alpha。
                document = try await ordinaryDocument(encodedVideoSize: encodedSize, duration: durationSeconds, track: videoTrack)
            }
        }
        try Task.checkCancellation()
        // 整次检查跨过多个 await；返回前重读完整签名，拒绝过程中被替换的文件。
        guard try AssetMetadata.SourceSignature.read(from: signature.url) == signature else {
            throw PlaybackError.invalidMP4(reason: "File changed during inspection.")
        }
        let frameSourceMetadata = FrameSourceMetadata(encodedVideoSize: encodedSize, codec: codec)
        let frameSourceContext = FrameSourceContext(url: signature.url, metadata: frameSourceMetadata)
        let metadata = AssetMetadata(
            document: document,
            duration: durationSeconds,
            containsAudio: tracks.contains(where: { $0.mediaType == .audio }),
            codec: codec,
            sourceSignature: signature,
            sourceAssetMode: assetMode,
            frameSourceContext: frameSourceContext
        )
        return InspectionResult(metadata: metadata, vapc: document, frameSourceContext: frameSourceContext)
    }

    /// 验证真实编码帧的边长与像素预算；使用 Int64 乘法避免伪造尺寸产生整型溢出。
    private func validateDimensions(_ dimensions: CMVideoDimensions) throws {
        // 限制在 decoder/自动探测创建之前生效，不能等 GPU 分配失败才处理异常帧。
        guard dimensions.width > 0, dimensions.height > 0,
              dimensions.width <= maximumVideoDimension, dimensions.height <= maximumVideoDimension,
              Int64(dimensions.width) * Int64(dimensions.height) <= maximumVideoPixels else {
            throw PlaybackError.invalidMP4(reason: "Encoded size exceeds 8192 pixels per edge or 8388608 pixels in total.")
        }
    }

    /// FourCC 只接受当前渲染通路支持的 H.264/HEVC，其他编码明确报错。
    private func codecName(_ codec: FourCharCode) throws -> String {
        switch codec {
        // H.264 输出统一转换成 NV12 纹理。
        case kCMVideoCodecType_H264:
            return "h264"
        // HEVC 同样走 NV12；此名称不代表支持独立的原生 Alpha 轨道。
        case kCMVideoCodecType_HEVC:
            return "hevc"
        // 不跨编码尝试，也不把不支持的 FourCC 误报为透明配置问题。
        default:
            let bytes: [UInt8] = [24, 16, 8, 0].map { UInt8((codec >> $0) & 0xff) }
            throw PlaybackError.unsupportedCodec(String(bytes: bytes, encoding: .ascii) ?? String(codec))
        }
    }

    /// 直接构造显式区域文档，不读取 vapc、不切半、不旋转编码帧。
    private func packedDocument(
        layout: PackedAlphaLayout,
        encodedVideoSize: CGSize,
        duration: TimeInterval,
        track: AVAssetTrack
    ) async throws -> VapcDocument {
        let alphaMode = try layout.validatedAlphaMode(in: encodedVideoSize)
        let timing = try await inferredLegacyFrameRateAndFrameCount(duration: duration, track: track)
        return VapcDocument(
            assetMode: .vap,
            version: 0,
            canvasSize: layout.colorRect.cgRect.size,
            alphaMode: alphaMode,
            frameCount: timing.frameCount,
            framesPerSecond: Int(timing.nominalFPS.rounded()),
            encodedVideoSize: encodedVideoSize,
            rgbRect: layout.colorRect.cgRect,
            alphaRect: layout.alphaRect.cgRect,
            sources: [],
            frames: [:]
        )
    }

    /// legacy VAP 的 fallback：Alpha/RGB 是等尺寸 packed 区域，方向由 detector
    /// 返回；显式 `.vap` 入口使用兼容历史素材的左 Alpha 默认值。
    private func legacyDocument(
        encodedVideoSize: CGSize,
        duration: TimeInterval,
        track: AVAssetTrack,
        alphaMode: AlphaMode,
        alphaOffset: Int = 0
    ) async throws -> VapcDocument {
        let canvas: CGSize
        let rgbRect: CGRect
        let alphaRect: CGRect
        // 检测发现错位时只保留共同区域；显式透明布局不会进入此兼容路径。
        if alphaOffset != 0 {
            (canvas, rgbRect, alphaRect) = try offsetRects(
                encodedVideoSize: encodedVideoSize,
                alphaMode: alphaMode,
                alphaOffset: alphaOffset
            )
        } else {
            // 无偏移的旧素材沿用等分布局，不改变历史 VAP 画布。
            (canvas, rgbRect, alphaRect) = try alignedRects(
                encodedVideoSize: encodedVideoSize,
                alphaMode: alphaMode
            )
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

    /// 等尺寸左右或上下分割，Alpha 与 RGB 在分割轴上没有额外位移。
    private func alignedRects(
        encodedVideoSize: CGSize,
        alphaMode: AlphaMode
    ) throws -> (CGSize, CGRect, CGRect) {
        let canvas: CGSize
        let rgbRect: CGRect
        let alphaRect: CGRect
        switch alphaMode {
        // 旧版左 Alpha 必须是等分宽度；配置驱动的新路径不使用此限制。
        case .left:
            guard Int(encodedVideoSize.width) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded width for the left/right split.")
            }
            canvas = CGSize(width: encodedVideoSize.width / 2, height: encodedVideoSize.height)
            rgbRect = CGRect(x: canvas.width, y: 0, width: canvas.width, height: canvas.height)
            alphaRect = CGRect(origin: .zero, size: canvas)
        // 旧版右 Alpha 使用镜像的左右区域，画布宽度仍取半幅。
        case .right:
            guard Int(encodedVideoSize.width) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded width for the left/right split.")
            }
            canvas = CGSize(width: encodedVideoSize.width / 2, height: encodedVideoSize.height)
            rgbRect = CGRect(origin: .zero, size: canvas)
            alphaRect = CGRect(x: canvas.width, y: 0, width: canvas.width, height: canvas.height)
        // 上下拼接沿高度等分，不能误用编码高度作为逻辑画布。
        case .top:
            guard Int(encodedVideoSize.height) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded height for the top/bottom split.")
            }
            canvas = CGSize(width: encodedVideoSize.width, height: encodedVideoSize.height / 2)
            rgbRect = CGRect(x: 0, y: canvas.height, width: canvas.width, height: canvas.height)
            alphaRect = CGRect(origin: .zero, size: canvas)
        // 下 Alpha 与上 Alpha 共用半幅大小，仅改变区域位置。
        case .bottom:
            guard Int(encodedVideoSize.height) % 2 == 0 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an even encoded height for the top/bottom split.")
            }
            canvas = CGSize(width: encodedVideoSize.width, height: encodedVideoSize.height / 2)
            rgbRect = CGRect(origin: .zero, size: canvas)
            alphaRect = CGRect(x: 0, y: canvas.height, width: canvas.width, height: canvas.height)
        // 普通视频应走独立分支，不能从 legacy VAP 中返回不透明布局。
        case .none:
            throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an Alpha layout.")
        }
        return (canvas, rgbRect, alphaRect)
    }

    /// 两半轮廓一致但沿分割轴错开时，只保留能同时取到 Alpha 和 RGB 的重叠区域。
    private func offsetRects(
        encodedVideoSize: CGSize,
        alphaMode: AlphaMode,
        alphaOffset: Int
    ) throws -> (CGSize, CGRect, CGRect) {
        let width = Int(encodedVideoSize.width)
        let height = Int(encodedVideoSize.height)
        let magnitude = abs(alphaOffset)
        switch alphaMode {
        // 左右旧素材仅允许沿 Y 轴错位，使用共同高度裁剪两块。
        case .left, .right:
            guard width % 2 == 0, width >= 2, magnitude > 0, magnitude < height, height - magnitude >= 2 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP alpha offset does not fit the encoded frame.")
            }
            let overlap = height - magnitude
            let half = width / 2
            let rgbY = alphaOffset < 0 ? magnitude : 0
            let alphaY = alphaOffset < 0 ? 0 : magnitude
            let rgbX = alphaMode == .left ? half : 0
            let alphaX = alphaMode == .left ? 0 : half
            return (
                CGSize(width: half, height: overlap),
                CGRect(x: rgbX, y: rgbY, width: half, height: overlap),
                CGRect(x: alphaX, y: alphaY, width: half, height: overlap)
            )
        // 上下旧素材仅允许沿 X 轴错位，使用共同宽度裁剪两块。
        case .top, .bottom:
            guard height % 2 == 0, height >= 2, magnitude > 0, magnitude < width, width - magnitude >= 2 else {
                throw PlaybackError.invalidVapc(reason: "Legacy VAP alpha offset does not fit the encoded frame.")
            }
            let overlap = width - magnitude
            let half = height / 2
            let rgbX = alphaOffset < 0 ? magnitude : 0
            let alphaX = alphaOffset < 0 ? 0 : magnitude
            let rgbY = alphaMode == .top ? half : 0
            let alphaY = alphaMode == .top ? 0 : half
            return (
                CGSize(width: overlap, height: half),
                CGRect(x: rgbX, y: rgbY, width: overlap, height: half),
                CGRect(x: alphaX, y: alphaY, width: overlap, height: half)
            )
        // 普通视频应走独立分支，不能从 legacy VAP 中返回不透明布局。
        case .none:
            throw PlaybackError.invalidVapc(reason: "Legacy VAP requires an Alpha layout.")
        }
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

    /// 用有限帧率和时长推导参考帧数；转换 Int 前先检查上限，取消不能被吞掉。
    private func inferredLegacyFrameRateAndFrameCount(
        duration: TimeInterval,
        track: AVAssetTrack
    ) async throws -> (nominalFPS: Float, frameCount: Int) {
        let nominalFPS: Float
        do {
            nominalFPS = try await track.load(.nominalFrameRate)
        } catch {
            // 主动取消继续向上传递，媒体属性读取失败才归类为容器错误。
            try Task.checkCancellation()
            throw PlaybackError.invalidMP4(reason: "Video frame rate is unavailable.")
        }
        try Task.checkCancellation()
        // 参考时间轴必须有限，避免后续 UInt/Int 转换崩溃。
        guard nominalFPS.isFinite, nominalFPS > 0, nominalFPS <= 240 else {
            throw PlaybackError.invalidMP4(reason: "Video has no usable frame rate.")
        }
        let rawFrameCount = duration * Double(nominalFPS)
        // 限额在 Int 转换之前检查，损坏时长不能触发转换 trap。
        guard rawFrameCount.isFinite, rawFrameCount > 0, rawFrameCount.rounded() <= 100_000 else {
            throw PlaybackError.invalidMP4(reason: "Video frame count is invalid or exceeds 100000.")
        }
        return (nominalFPS, max(1, Int(rawFrameCount.rounded())))
    }

    /// inspector 与 decoder 的编码尺寸允许 1 像素误差。
    private func approximatelyEqual(_ lhs: CGSize, _ rhs: CGSize) -> Bool {
        abs(lhs.width - rhs.width) < 1 && abs(lhs.height - rhs.height) < 1
    }
}
