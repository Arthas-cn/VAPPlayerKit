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
