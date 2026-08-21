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

/// 一次播放配置。`loopCount` 是总次数：1 播一次，0 无限循环。不要按旧 `repeatCount` 直传。
@interface VPKPlaybackOptions : NSObject <NSCopying>

@property (nonatomic, assign) NSInteger loopCount;
@property (nonatomic, assign) UIViewContentMode contentMode;
@property (nonatomic, assign) VPKAudioMode audioMode;
@property (nonatomic, assign) BOOL clearsAfterFinish;
@property (nonatomic, assign) VPKBackgroundPolicy backgroundPolicy;

/// 每次返回新实例。
@property (nonatomic, class, readonly, strong) VPKPlaybackOptions *defaultOptions;

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
