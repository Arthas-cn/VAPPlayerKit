#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKPlayerView;
@class VPKAssetMetadata;

typedef NS_ENUM(NSInteger, VPKFinishReason) {
    VPKFinishReasonCompleted = 0,
    VPKFinishReasonStopped,
    VPKFinishReasonCancelled
};

@protocol VPKPlayerDelegate <NSObject>
@optional
- (void)playerViewDidStart:(VPKPlayerView *)playerView;
- (void)playerView:(VPKPlayerView *)playerView didResolveMetadata:(VPKAssetMetadata *)metadata;
- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error;
- (void)playerView:(VPKPlayerView *)playerView didFinishWithReason:(VPKFinishReason)reason;
@end

NS_ASSUME_NONNULL_END
