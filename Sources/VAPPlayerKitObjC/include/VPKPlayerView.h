#import <UIKit/UIKit.h>
#import "VPKPlaybackOptions.h"
#import "VPKAssetMetadata.h"
#import "VPKPlayerDelegate.h"
#import "VPKDynamicContentProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface VPKPlayerView : UIView

@property (nonatomic, weak, nullable) id<VPKPlayerDelegate> delegate;
@property (nonatomic, weak, nullable) id<VPKDynamicContentProvider> dynamicContentProvider;

- (void)prepareWithURL:(NSURL *)URL
               options:(VPKPlaybackOptions *)options
            completion:(void (^)(VPKAssetMetadata * _Nullable metadata, NSError * _Nullable error))completion;

- (void)playWithURL:(NSURL *)URL options:(VPKPlaybackOptions *)options;
- (void)pause;
- (void)resume;
- (void)stop;
- (void)clear;

@end

NS_ASSUME_NONNULL_END
