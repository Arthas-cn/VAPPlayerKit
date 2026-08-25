#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 全局共享的 AssetMetadata 内存缓存。
/// countLimit 默认为 20；设置为 0 会禁用并清空缓存。
@interface VPKAssetMetadataCache : NSObject

+ (instancetype)sharedCache;

@property (nonatomic, assign) NSInteger countLimit;

- (void)removeAll;
- (void)removeMetadataForURL:(NSURL *)URL;

@end

NS_ASSUME_NONNULL_END
