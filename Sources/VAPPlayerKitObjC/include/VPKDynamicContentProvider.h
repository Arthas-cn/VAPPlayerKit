#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKSourceMetadata;

/// 动态内容提供者。组件不内置下载器和图片库；completion 必须且只能调用一次。
///
/// 文字槽位应通过 `replacementText` 返回替换字符串，组件会使用 vapc 颜色、粗体标记
/// 和槽位尺寸自动估算字号（与 Swift `.textReplacement` 相同）。图片槽位返回 `image`。
@protocol VPKDynamicContentProvider <NSObject>
- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable replacementText, NSError * _Nullable error))completion;

/// 可选的文字字体覆盖；未实现或返回 nil 时由组件自动估算字号。
@optional
- (nullable UIFont *)fontForTag:(NSString *)tag;
@end

typedef NS_ENUM(NSInteger, VPKDynamicSourceKind) {
    VPKDynamicSourceKindImage = 0,
    VPKDynamicSourceKindText = 1
};

/// vapc 动态槽位描述。`slotSize` 是预缩放目标像素尺寸。
@interface VPKSourceMetadata : NSObject

@property (nonatomic, readonly, copy) NSString *tag;
@property (nonatomic, readonly, assign) CGSize slotSize;
@property (nonatomic, readonly, assign) VPKDynamicSourceKind kind;

- (instancetype)initWithTag:(NSString *)tag slotSize:(CGSize)slotSize;
- (instancetype)initWithTag:(NSString *)tag slotSize:(CGSize)slotSize kind:(VPKDynamicSourceKind)kind;

@end

NS_ASSUME_NONNULL_END
