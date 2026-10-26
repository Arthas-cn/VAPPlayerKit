import UIKit

/// 资源解析策略；调用方明确选择后，播放期间不会再次猜测类型。
public enum PlaybackAssetMode: Sendable, Hashable {
    /// 优先解析 vapc；无 vapc 时检查旧拼接特征，无法确认则按普通视频处理。
    case automatic
    /// 明确播放 VAP；无 vapc 的旧素材沿用左侧 Alpha 布局。
    case vap
    /// 使用完整编码画面，不读取 vapc，也不生成 Alpha。
    case ordinaryVideo
    /// 使用调用方声明的整数矩形合成透明视频，不读取 vapc 或启发式布局。
    case packedAlpha(PackedAlphaLayout)
}

/// 动态图片槽位是否推进其自身动画时间轴。
public enum DynamicImagePlaybackMode: Sendable, Equatable {
    /// 动图取首帧，普通图片保持静态。
    case still
    /// 具备动态图能力时播放，否则保留静态图片。
    case animated
}

/// 动态文字宽于槽位时的布局策略。
public enum DynamicTextOverflowMode: Sendable, Equatable {
    /// 保持单行并在尾部截断。
    case truncate
    /// 仅超宽文字从右向左滚动，能放下时保持居中。
    case marquee
}

/// 一次准备使用的值配置；播放器保存快照，后续修改调用方副本不会改变现有会话。
public struct PlaybackOptions: Sendable, Equatable {
    /// 解析策略，默认明确按 VAP 处理；自动识别必须显式选择。
    public var assetMode: PlaybackAssetMode
    /// 总播放次数；0 为无限，正数为总次数，负数由 validate 拒绝。
    public var loopCount: Int
    /// 逻辑画布的布局方式，只接受 fit、fill 与 stretch。
    public var contentMode: UIView.ContentMode
    /// 是否建立内嵌音轨资源；运行时静音由 PlayerView.isMuted 控制。
    public var audioMode: AudioMode
    /// 自然结束后是否移除当前画面并回收可释放的 GPU 资源。
    public var clearsAfterFinish: Bool
    /// 离窗、后台或无有效尺寸时挂起还是停止。
    public var backgroundPolicy: BackgroundPolicy
    /// 安全挂起原因消失后是否允许 SDK 自动恢复；统一播放器应设 false。
    public var automaticallyResumesAfterSuspension: Bool
    /// 动态图片槽位的静态/动画策略。
    public var dynamicImagePlaybackMode: DynamicImagePlaybackMode
    /// 动态文字超宽时截断或滚动。
    public var dynamicTextOverflowMode: DynamicTextOverflowMode
    /// 跑马灯速度，单位 pt/s，必须有限且大于 0。
    public var marqueeSpeed: CGFloat
    /// 每次跑马灯滚动前的停顿秒数，必须有限且非负。
    public var marqueeStartDelay: TimeInterval

    /// 创建配置快照；不执行 I/O，非法值由准备入口调用 validate 后抛出。
    public init(
        assetMode: PlaybackAssetMode = .vap,
        loopCount: Int = 1,
        contentMode: UIView.ContentMode = .scaleAspectFit,
        audioMode: AudioMode = .embedded,
        clearsAfterFinish: Bool = true,
        backgroundPolicy: BackgroundPolicy = .suspend,
        automaticallyResumesAfterSuspension: Bool = true,
        dynamicImagePlaybackMode: DynamicImagePlaybackMode = .animated,
        dynamicTextOverflowMode: DynamicTextOverflowMode = .truncate,
        marqueeSpeed: CGFloat = 80,
        marqueeStartDelay: TimeInterval = 0.6
    ) {
        self.assetMode = assetMode
        self.loopCount = loopCount
        self.contentMode = contentMode
        self.audioMode = audioMode
        self.clearsAfterFinish = clearsAfterFinish
        self.backgroundPolicy = backgroundPolicy
        self.automaticallyResumesAfterSuspension = automaticallyResumesAfterSuspension
        self.dynamicImagePlaybackMode = dynamicImagePlaybackMode
        self.dynamicTextOverflowMode = dynamicTextOverflowMode
        self.marqueeSpeed = marqueeSpeed
        self.marqueeStartDelay = marqueeStartDelay
    }

    /// 校验配置值；非法通用参数抛 invalidArgument，透明几何错误抛 invalidAlphaLayout。
    /// 编码帧的实际边界必须在 inspection 获得尺寸后再次检查。
    public func validate() throws {
        // 负数不是“额外循环”或单次播放，拒绝输入以免掩盖上层配置错误。
        guard loopCount >= 0 else {
            throw PlaybackError.invalidArgument(reason: "loopCount must be nonnegative.")
        }
        // NaN/无穷无法用于时钟，不能让比较表达式悄悄放行。
        guard marqueeSpeed.isFinite, marqueeSpeed > 0,
              marqueeStartDelay.isFinite, marqueeStartDelay >= 0 else {
            throw PlaybackError.invalidArgument(reason: "Marquee speed and delay must be finite and in range.")
        }
        switch contentMode {
        // 三种显式方式对应 renderer 的完整布局能力。
        case .scaleAspectFit, .scaleAspectFill, .scaleToFill:
            break
        // 其他 UIView 对齐模式没有对应渲染语义，不能静默当作 aspectFit。
        default:
            throw PlaybackError.invalidArgument(reason: "contentMode must be aspectFit, aspectFill, or scaleToFill.")
        }
        // 仅显式透明模式携带外部区域，其形状错误不必等到打开文件才报告。
        if case let .packedAlpha(layout) = assetMode {
            try layout.validateGeometry()
        }
    }

    /// 宿主是否链接可选 SDWebImage 动态图能力；不会在组件内建立图片下载服务。
    @MainActor public static var canPlayAnimatedDynamicImages: Bool {
        SDWebImageRuntime.isAvailable
    }
}
