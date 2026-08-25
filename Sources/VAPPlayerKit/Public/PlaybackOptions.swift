import UIKit

/// 动态槽位图片的播放策略。对本次播放的全部图片槽位生效。
@objc(VPKDynamicImagePlaybackMode)
public enum DynamicImagePlaybackMode: Int, Sendable {
    /// 动图、静图都只显示静图；若对象为动图则取第一帧。
    case still = 0
    /// 可动画图片播放动图，静图仍显示静图。默认。
    case animated = 1
}

/// 动态文字放不下槽位时的溢出策略。对本次播放的全部文字槽位生效。
@objc(VPKDynamicTextOverflowMode)
public enum DynamicTextOverflowMode: Int, Sendable {
    /// 单行尾部截断为 `…`。默认，兼容现有行为。
    case truncate = 0
    /// 单行从右向左跑马灯；能放下时仍静态居中。
    case marquee = 1
}

/// 一次播放的可变配置。必须在 `play` / `prepare` 前设置；播放中修改副本不会影响当前 session。
///
/// `loopCount` 是总播放次数：`1` 播一次，`2` 播两次，`0` 无限循环。
/// 这与 `vap-master` 里 `repeatCount`「额外重复次数」语义不同，不要按旧值直传。
@objc(VPKPlaybackOptions)
public final class PlaybackOptions: NSObject, NSCopying {
    /// 总播放次数。`1` 播放一次，`2` 播放两次，`0` 无限循环。
    @objc public var loopCount: Int = 1 {
        didSet {
            if loopCount < 0 { loopCount = 1 }
        }
    }
    /// 按 `canvasSize` 计算的内容缩放方式，不用编码分辨率。
    @objc public var contentMode: UIView.ContentMode = .scaleAspectFit
    /// 音频策略，默认静音透明特效。
    @objc public var audioMode: AudioMode = .muted
    /// 结束后是否清掉当前画面和可回收 GPU 资源。
    @objc public var clearsAfterFinish: Bool = true
    /// 后台 / 离屏时是挂起还是停止。
    @objc public var backgroundPolicy: BackgroundPolicy = .suspend
    /// 动态槽位图片播放策略。默认按内容播放：可动画则播动图。
    ///
    /// 动图能力依赖宿主链接的 SDWebImage（WebP 还需 SDWebImageWebPCoder）。
    /// 组件本身不链接这些库；运行时探测不到时始终按静图处理。
    @objc public var dynamicImagePlaybackMode: DynamicImagePlaybackMode = .animated
    /// 动态文字溢出策略。默认尾部截断；仅当文字宽于槽位时才会跑马灯。
    ///
    /// 同时作用于 `.textReplacement`、`.text(attributes:)` 和 ObjC `replacementText`。
    @objc public var dynamicTextOverflowMode: DynamicTextOverflowMode = .truncate
    /// 跑马灯速度，单位 pt/s。仅 `dynamicTextOverflowMode == .marquee` 时生效。默认 80。
    /// 非正值回退为 80。
    @objc public var marqueeSpeed: CGFloat = 80 {
        didSet {
            if marqueeSpeed <= 0 { marqueeSpeed = 80 }
        }
    }
    /// 跑马灯起步停顿，单位秒。每个滚动周期开头都会停顿，从文字真正上屏开始算。
    /// 仅跑马灯模式生效。默认 0.6。负值钳制为 0。
    @objc public var marqueeStartDelay: TimeInterval = 0.6 {
        didSet {
            if marqueeStartDelay < 0 { marqueeStartDelay = 0 }
        }
    }

    /// 宿主进程是否链接了 SDWebImage。组件不会把它编进自身。
    @objc public static var canPlayAnimatedDynamicImages: Bool {
        SDWebImageRuntime.isAvailable
    }

    /// 每次调用都返回新实例，避免共享可变单例。
    @objc(defaultOptions)
    public static var defaultOptions: PlaybackOptions {
        PlaybackOptions()
    }

    /// 使用全部默认值：播一次、静音、AspectFit、结束后清画面、后台挂起、动态图按内容播放、文字尾部截断。
    @objc public override init() {
        super.init()
    }

    /// 深拷贝到新对象，供 session 持有，避免宿主事后改 options 污染正在播放的 session。
    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = PlaybackOptions()
        copy.loopCount = loopCount
        copy.contentMode = contentMode
        copy.audioMode = audioMode
        copy.clearsAfterFinish = clearsAfterFinish
        copy.backgroundPolicy = backgroundPolicy
        copy.dynamicImagePlaybackMode = dynamicImagePlaybackMode
        copy.dynamicTextOverflowMode = dynamicTextOverflowMode
        copy.marqueeSpeed = marqueeSpeed
        copy.marqueeStartDelay = marqueeStartDelay
        return copy
    }
}
