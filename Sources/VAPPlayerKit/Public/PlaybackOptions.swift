import UIKit

/// 一次播放的可变配置。必须在 `play` / `prepare` 前设置；播放中修改副本不会影响当前 session。
///
/// `loopCount` 是总播放次数：`1` 播一次，`2` 播两次，`0` 无限循环。
/// 这与 `vap-master` 里 `repeatCount`「额外重复次数」语义不同，不要按旧值直传。
@objc(VPKPlaybackOptions)
public final class PlaybackOptions: NSObject, NSCopying {
    /// 总播放次数。`1` 播放一次，`2` 播放两次，`0` 无限循环。
    @objc public var loopCount: Int = 1
    /// 按 `canvasSize` 计算的内容缩放方式，不用编码分辨率。
    @objc public var contentMode: UIView.ContentMode = .scaleAspectFit
    /// 音频策略，默认静音透明特效。
    @objc public var audioMode: AudioMode = .muted
    /// 结束后是否清掉当前画面和可回收 GPU 资源。
    @objc public var clearsAfterFinish: Bool = true
    /// 后台 / 离屏时是挂起还是停止。
    @objc public var backgroundPolicy: BackgroundPolicy = .suspend

    /// 每次调用都返回新实例，避免共享可变单例。
    @objc(defaultOptions)
    public static var defaultOptions: PlaybackOptions {
        PlaybackOptions()
    }

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
        return copy
    }
}
