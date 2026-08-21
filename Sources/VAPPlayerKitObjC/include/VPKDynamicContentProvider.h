#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKSourceMetadata;

/// 动态内容提供者。组件不内置下载器和图片库；completion 必须且只能调用一次。
@protocol VPKDynamicContentProvider <NSObject>
- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable image, NSError * _Nullable error))completion;
@end

/// vapc 动态槽位描述。`slotSize` 是预缩放目标像素尺寸。
@interface VPKSourceMetadata : NSObject

@property (nonatomic, readonly, copy) NSString *tag;
@property (nonatomic, readonly, assign) CGSize slotSize;

- (instancetype)initWithTag:(NSString *)tag slotSize:(CGSize)slotSize;

@end

NS_ASSUME_NONNULL_END
