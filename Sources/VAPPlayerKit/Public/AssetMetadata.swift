import Foundation
import CoreGraphics

/// 一份 VAP 资源解析后的不可变元数据。
///
/// `encodedVideoSize` 是 packed 视频的物理编码尺寸；`canvasSize` 是 vapc 定义的逻辑画布。
/// 布局必须用 `canvasSize`，对照 `vap-master` 的 `QGVAPConfigModel`，但不暴露可变 JSON。
@objc(VPKAssetMetadata)
public final class AssetMetadata: NSObject {
    /// packed RGB+Alpha 视频的编码宽高。
    @objc public let encodedVideoSize: CGSize
    /// 逻辑画布尺寸，用于 AspectFit / Fill 和宿主布局。
    @objc public let canvasSize: CGSize
    /// Alpha 区域相对 RGB 的方向。
    @objc public let alphaMode: AlphaMode
    /// 可展示的帧数量。
    @objc public let frameCount: Int
    /// 媒体时长，单位秒。
    @objc public let duration: TimeInterval
    /// 容器是否包含音轨。与当前是否播放音频无关。
    @objc public let containsAudio: Bool
    /// 例如 `h264` 或 `hevc`。
    @objc public let codec: String
    /// vapc 版本。legacy 无 vapc 文件为 0。
    @objc public let vapVersion: Int
    /// vapc 声明的动态 source；legacy 文件为空。
    @objc public let dynamicSources: [SourceMetadata]

    /// 是否携带本组件解析得到的内部布局，可直接用于 metadata 复用播放 API 和全局缓存。
    ///
    /// 需要同时具备 vapc 完整帧布局，以及 inspection 时采集的本地文件签名。
    /// 手工调用公开 initializer 构造的摘要对象缺少这些内部字段，因此返回 `false`，
    /// 既不能传给 `prepare(url:metadata:)`，也不会进入 `AssetMetadataCache`。
    @objc public var isReusableForPlayback: Bool {
        playbackDocument != nil
            && sourceURL != nil
            && sourceFileSize != nil
            && sourceModificationDate != nil
            && sourceFileIdentifier != nil
    }

    /// 组件解析出的完整 vapc 布局。公开摘要对象为 `nil`，因此不能跳过 inspection。
    internal var playbackDocument: VapcDocument?
    /// inspection 时的规范化本地路径。复用时必须与当前播放 URL 一致。
    internal var sourceURL: URL?
    /// inspection 时的文件大小（字节）。签名校验的一部分。
    internal var sourceFileSize: Int64?
    /// inspection 时的内容修改时间。签名校验的一部分。
    internal var sourceModificationDate: Date?
    /// `NSURLFileResourceIdentifierKey` 对应的稳定文件 identity。
    /// 路径被替换成另一个 inode 时即使大小和修改时间被刻意对齐，也能识别为过期。
    internal var sourceFileIdentifier: Data?

    /// 由 `AssetInspector` 在后台解析完成后构造。宿主也可以在测试里直接创建。
    @objc public init(
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
        super.init()
    }
}
