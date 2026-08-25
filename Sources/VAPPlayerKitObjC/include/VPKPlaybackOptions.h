#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 音频策略。对应 Swift `AudioMode`。播放器不会自行决定是否出声。
typedef NS_ENUM(NSInteger, VPKAudioMode) {
    /// 不创建音频资源。
    VPKAudioModeMuted = 0,
    /// 播放内嵌音轨。
    VPKAudioModeEmbedded,
    /// 由宿主自己的播放器出声。
    VPKAudioModeExternal,
    /// 忽略音轨。
    VPKAudioModeDisabled
};

/// 后台 / 离屏策略。对应 Swift `BackgroundPolicy`。
typedef NS_ENUM(NSInteger, VPKBackgroundPolicy) {
    /// 挂起并保留进度。
    VPKBackgroundPolicySuspend = 0,
    /// 停止当前 session。
    VPKBackgroundPolicyStop
};

/// 动态槽位图片播放策略。对应 Swift `DynamicImagePlaybackMode`。
typedef NS_ENUM(NSInteger, VPKDynamicImagePlaybackMode) {
    /// 动图、静图都只显示静图；动图取第一帧。
    VPKDynamicImagePlaybackModeStill = 0,
    /// 可动画图片播放动图，静图仍显示静图。默认。
    VPKDynamicImagePlaybackModeAnimated = 1
};

/// 动态文字溢出策略。对应 Swift `DynamicTextOverflowMode`。
typedef NS_ENUM(NSInteger, VPKDynamicTextOverflowMode) {
    /// 单行尾部截断为省略号。默认。
    VPKDynamicTextOverflowModeTruncate = 0,
    /// 单行从右向左跑马灯；能放下时仍静态居中。
    VPKDynamicTextOverflowModeMarquee = 1
};

/// 一次播放配置。`loopCount` 是总次数：1 播一次，0 无限循环。不要按旧 `repeatCount` 直传。
@interface VPKPlaybackOptions : NSObject <NSCopying>

/// 总播放次数。1 播放一次，2 播放两次，0 无限循环。负值会被钳制为 1。
@property (nonatomic, assign) NSInteger loopCount;
/// 按 `canvasSize` 计算的内容缩放方式，不用编码分辨率。
@property (nonatomic, assign) UIViewContentMode contentMode;
/// 音频策略，默认静音。
@property (nonatomic, assign) VPKAudioMode audioMode;
/// 结束后是否清掉当前画面。
@property (nonatomic, assign) BOOL clearsAfterFinish;
/// 后台 / 离屏时是挂起还是停止。
@property (nonatomic, assign) VPKBackgroundPolicy backgroundPolicy;
/// 动态槽位图片播放策略。默认按内容播放动图。
@property (nonatomic, assign) VPKDynamicImagePlaybackMode dynamicImagePlaybackMode;
/// 动态文字溢出策略。默认尾部截断。
@property (nonatomic, assign) VPKDynamicTextOverflowMode dynamicTextOverflowMode;
/// 跑马灯速度，单位 pt/s。仅跑马灯模式生效。默认 80；非正值回退为 80。
@property (nonatomic, assign) CGFloat marqueeSpeed;
/// 跑马灯起步停顿，单位秒。每个滚动周期开头都会停顿。仅跑马灯模式生效。默认 0.6；负值钳制为 0。
@property (nonatomic, assign) NSTimeInterval marqueeStartDelay;

/// 宿主是否链接了 SDWebImage。组件不会把它编进自身。
@property (nonatomic, class, readonly) BOOL canPlayAnimatedDynamicImages;

/// 每次返回新实例。
@property (nonatomic, class, readonly, strong) VPKPlaybackOptions *defaultOptions;

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
