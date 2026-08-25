#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKPlayerView;
@class VPKAssetMetadata;

/// 终态原因。每个 session 最多回调一次 finish 或 fail。
typedef NS_ENUM(NSInteger, VPKFinishReason) {
    /// 按 loopCount 播完。
    VPKFinishReasonCompleted = 0,
    /// 宿主 stop 或后台策略要求停止。
    VPKFinishReasonStopped,
    /// 被新的播放操作取消。
    VPKFinishReasonCancelled
};

/// Objective-C 播放回调。全部在主线程。实现侧是 Swift `ObjCPlayerDelegate`。
@protocol VPKPlayerDelegate <NSObject>
@optional
/// session 开始出帧。
- (void)playerViewDidStart:(VPKPlayerView *)playerView;
/// metadata 解析完成，可按 canvasSize 布局。
- (void)playerView:(VPKPlayerView *)playerView didResolveMetadata:(VPKAssetMetadata *)metadata;
/// 不可恢复错误。不会再跟 finish。
- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error;
/// 播完、stop 或 cancel。
- (void)playerView:(VPKPlayerView *)playerView didFinishWithReason:(VPKFinishReason)reason;
@end

NS_ASSUME_NONNULL_END
