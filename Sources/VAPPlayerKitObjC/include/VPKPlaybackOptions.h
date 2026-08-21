#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPKAudioMode) {
    VPKAudioModeMuted = 0,
    VPKAudioModeEmbedded,
    VPKAudioModeExternal,
    VPKAudioModeDisabled
};

typedef NS_ENUM(NSInteger, VPKBackgroundPolicy) {
    VPKBackgroundPolicySuspend = 0,
    VPKBackgroundPolicyStop
};

@interface VPKPlaybackOptions : NSObject <NSCopying>

@property (nonatomic, assign) NSInteger loopCount;
@property (nonatomic, assign) UIViewContentMode contentMode;
@property (nonatomic, assign) VPKAudioMode audioMode;
@property (nonatomic, assign) BOOL clearsAfterFinish;
@property (nonatomic, assign) VPKBackgroundPolicy backgroundPolicy;

@property (nonatomic, class, readonly, strong) VPKPlaybackOptions *defaultOptions;

- (instancetype)init;

@end

NS_ASSUME_NONNULL_END
