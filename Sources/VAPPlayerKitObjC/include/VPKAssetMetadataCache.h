#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局共享的 `VPKAssetMetadata` 进程内内存缓存。
///
/// 所有 `VPKPlayerView` 共用同一实例，复用本组件解析出的、带完整播放布局和文件签名的
/// metadata，避免相同本地 URL 被重复 inspection。不持久化到磁盘，也不缓存解码器或视频帧。
///
/// `countLimit` 默认为 20；设置为 0 会立即禁用并清空缓存。命中后仍会校验文件 identity、
/// 大小和修改时间，签名变化时自动丢弃旧值并重新解析。
@interface VPKAssetMetadataCache : NSObject

/// 所有播放视图共享的缓存实例。不要自行 alloc/init。
+ (instancetype)sharedCache;

/// 最多保留的 metadata 数量。默认 20；0 表示禁用并清空；负值会被钳制为 0。
@property (nonatomic, assign) NSInteger countLimit;

/// 清空全部缓存项，并使进行中的 inspection 结果不再写入。
- (void)removeAll;

/// 移除指定本地文件 URL 对应的缓存项。非文件 URL 会被忽略。
- (void)removeMetadataForURL:(NSURL *)URL;

@end

NS_ASSUME_NONNULL_END
