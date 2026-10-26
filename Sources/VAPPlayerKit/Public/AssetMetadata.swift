import Foundation
import CoreGraphics

/// 本地素材的一次不可变解析快照；不持有解码器、音频播放器或 GPU 资源。
public struct AssetMetadata: Sendable, Equatable {
    /// 视频轨的完整编码宽高；拼接素材包含颜色和 Alpha 两区。
    public let encodedVideoSize: CGSize
    /// 最终逻辑画布；显式透明布局取 colorRect，普通视频取完整编码尺寸。
    public let canvasSize: CGSize
    /// 解析后 Alpha 相对颜色区域的方位；普通视频为 none。
    public let alphaMode: AlphaMode
    /// 当前内容是否使用拼接透明渲染，包含 VAP 和显式 packedAlpha。
    public var isVAP: Bool { alphaMode != .none }
    /// 有限正数帧数，仅用于 metadata 与动态槽索引，不代替真实媒体结束事件。
    public let frameCount: Int
    /// 视频媒体时长，单位秒，解析结果必须有限且大于 0。
    public let duration: TimeInterval
    /// 容器是否具有音轨，与当前 audioMode/isMuted 无关。
    public let containsAudio: Bool
    /// 已验证的编码名称，目前为 h264 或 hevc。
    public let codec: String
    /// vapc 的版本；旧版、普通视频和显式透明布局均为 0。
    public let vapVersion: Int
    /// vapc 声明的动态槽；普通视频和显式透明布局为空。
    public let dynamicSources: [SourceMetadata]

    /// 组件检查时赋予的身份；同一快照复用保持不变，手工摘要为 nil。
    internal let inspectionID: UUID?
    /// 解析得到的不可变渲染布局；手工摘要没有可播放凭证。
    internal let playbackDocument: VapcDocument?
    /// 文件的完整不可变身份；路径、大小、修改时间与 inode 标识共同参与校验。
    internal let sourceSignature: SourceSignature?
    /// 检查使用的完整模式，包含透明布局的轴和每个整数坐标。
    internal let sourceAssetMode: PlaybackAssetMode?
    /// 解码来源的纯值上下文，仅含本地 URL 与媒体摘要，不保存 AVFoundation 对象。
    internal let frameSourceContext: FrameSourceContext?

    /// 是否具有组件签发的布局、文件身份与模式；不能由公开摘要初始化器伪造。
    public var isReusableForPlayback: Bool {
        inspectionID != nil && playbackDocument != nil && sourceSignature != nil && sourceAssetMode != nil
    }

    /// 原始规范化本地 URL；手工摘要为 nil。
    internal var sourceURL: URL? { sourceSignature?.url }
    /// 检查时的文件字节数；手工摘要为 nil。
    internal var sourceFileSize: Int64? { sourceSignature?.fileSize }
    /// 检查时的内容修改时间；手工摘要为 nil。
    internal var sourceModificationDate: Date? { sourceSignature?.modificationDate }
    /// 检查时的稳定文件标识；能区分相同路径/大小/日期下的文件替换。
    internal var sourceFileIdentifier: Data? { sourceSignature?.fileIdentifier }

    /// 创建展示或测试用摘要；不读盘，不能提交为已检查的可播放 metadata。
    public init(
        encodedVideoSize: CGSize,
        canvasSize: CGSize,
        alphaMode: AlphaMode,
        frameCount: Int,
        duration: TimeInterval,
        containsAudio: Bool,
        codec: String,
        vapVersion: Int = 0,
        dynamicSources: [SourceMetadata] = []
    ) {
        self.encodedVideoSize = encodedVideoSize
        self.canvasSize = canvasSize
        self.alphaMode = alphaMode
        self.frameCount = frameCount
        self.duration = duration
        self.containsAudio = containsAudio
        self.codec = codec
        self.vapVersion = vapVersion
        self.dynamicSources = dynamicSources
        self.inspectionID = nil
        self.playbackDocument = nil
        self.sourceSignature = nil
        self.sourceAssetMode = nil
        self.frameSourceContext = nil
    }

    /// 由检查器一次性构造完整快照；所有 provenance 与布局同时固定，之后不可变更。
    internal init(
        document: VapcDocument,
        duration: TimeInterval,
        containsAudio: Bool,
        codec: String,
        sourceSignature: SourceSignature,
        sourceAssetMode: PlaybackAssetMode,
        frameSourceContext: FrameSourceContext?
    ) {
        self.encodedVideoSize = document.encodedVideoSize
        self.canvasSize = document.canvasSize
        self.alphaMode = document.alphaMode
        self.frameCount = document.frameCount
        self.duration = duration
        self.containsAudio = containsAudio
        self.codec = codec
        self.vapVersion = document.version
        self.dynamicSources = document.sources.map { source in
            SourceMetadata(tag: source.tag, slotSize: source.slotSize, kind: source.kind == .text ? .text : .image)
        }
        self.inspectionID = UUID()
        self.playbackDocument = document
        self.sourceSignature = sourceSignature
        self.sourceAssetMode = sourceAssetMode
        self.frameSourceContext = frameSourceContext
    }

    /// 比较公开值及完整 provenance；inspectionID 同时绑定内部不可变布局与纯值解码上下文。
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.encodedVideoSize == rhs.encodedVideoSize
            && lhs.canvasSize == rhs.canvasSize
            && lhs.alphaMode == rhs.alphaMode
            && lhs.frameCount == rhs.frameCount
            && lhs.duration == rhs.duration
            && lhs.containsAudio == rhs.containsAudio
            && lhs.codec == rhs.codec
            && lhs.vapVersion == rhs.vapVersion
            && lhs.dynamicSources == rhs.dynamicSources
            && lhs.inspectionID == rhs.inspectionID
            && lhs.sourceSignature == rhs.sourceSignature
            && lhs.sourceAssetMode == rhs.sourceAssetMode
    }

    /// 一次磁盘采样取得的完整文件身份，只保存 Sendable 值，不保存文件句柄。
    internal struct SourceSignature: Sendable, Equatable {
        /// 标准化后的本地 URL；不把不同路径的 metadata 互相复用。
        let url: URL
        /// 非空普通文件的实际字节数。
        let fileSize: Int64
        /// 内容最后修改时间，复用前必须精确匹配。
        let modificationDate: Date
        /// 文件系统稳定标识，防止同路径被另一文件替换。
        let fileIdentifier: Data

        /// 读取本地普通文件身份；非文件 URL、缺失或无法取得完整签名时抛 PlaybackError。
        static func read(from url: URL) throws -> Self {
            // 组件从不访问网络；先拒绝 scheme，避免 resourceValues 产生意外访问。
            guard url.isFileURL else { throw PlaybackError.invalidURL }
            let canonicalURL = url.standardizedFileURL
            // 缺文件与损坏文件分开报告，保留现有公开错误语义。
            guard FileManager.default.fileExists(atPath: canonicalURL.path) else {
                throw PlaybackError.fileNotFound
            }
            let values = try canonicalURL.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .contentModificationDateKey, .fileResourceIdentifierKey
            ])
            // 缺任一身份字段都不能安全复用，拒绝用路径/日期猜测文件身份。
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize, fileSize > 0,
                  let modificationDate = values.contentModificationDate,
                  let fileIdentifier = values.fileResourceIdentifier as? Data else {
                throw PlaybackError.invalidMP4(reason: "A nonempty regular file with a complete identity is required.")
            }
            return Self(
                url: canonicalURL,
                fileSize: Int64(fileSize),
                modificationDate: modificationDate,
                fileIdentifier: fileIdentifier
            )
        }
    }
}
