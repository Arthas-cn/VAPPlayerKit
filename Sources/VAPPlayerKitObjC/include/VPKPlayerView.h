#import <UIKit/UIKit.h>
#import "VPKPlaybackOptions.h"
#import "VPKAssetMetadata.h"
#import "VPKPlayerDelegate.h"
#import "VPKDynamicContentProvider.h"

NS_ASSUME_NONNULL_BEGIN

/// 公开播放视图。运行时由 Swift `PlayerView` 实现，本 header 只做稳定的 ObjC 声明。
///
/// 对照 `vap-master` 的 `UIView+VAP`，但这里是独立 UIView 子类，不再提供 category。
@interface VPKPlayerView : UIView

/// 播放回调。全部在主线程。
@property (nonatomic, weak, nullable) id<VPKPlayerDelegate> delegate;
/// 动态内容提供者。组件不内置下载器。
@property (nonatomic, weak, nullable) id<VPKDynamicContentProvider> dynamicContentProvider;

/// 解析 metadata，不自动播放。completion 只回调一次。
/// 未传 metadata 时会查询全局 `VPKAssetMetadataCache`。
- (void)prepareWithURL:(NSURL *)URL
               options:(VPKPlaybackOptions *)options
            completion:(void (^)(VPKAssetMetadata * _Nullable metadata, NSError * _Nullable error))completion;

/// 使用本组件此前为同一 URL 返回的 metadata，跳过重复 MP4/vapc inspection。
/// 仅 `reusableForPlayback == YES` 的对象可用；成功后会写入全局缓存。
- (void)prepareWithURL:(NSURL *)URL
              metadata:(VPKAssetMetadata *)metadata
               options:(VPKPlaybackOptions *)options
            completion:(void (^)(VPKAssetMetadata * _Nullable metadata, NSError * _Nullable error))completion;

/// 准备并播放。可与 prepare 共用同一套 session 逻辑，并使用全局 metadata 缓存。
- (void)playWithURL:(NSURL *)URL options:(VPKPlaybackOptions *)options;
/// 使用本组件此前为同一 URL 返回的 metadata 播放，并写入全局 `VPKAssetMetadataCache`。
- (void)playWithURL:(NSURL *)URL
           metadata:(VPKAssetMetadata *)metadata
            options:(VPKPlaybackOptions *)options;
/// 暂停，冻结媒体时钟。
- (void)pause;
/// 恢复播放。
- (void)resume;
/// 取消当前 session。
- (void)stop;
/// 停止并清掉当前画面。
- (void)clear;

@end

NS_ASSUME_NONNULL_END
