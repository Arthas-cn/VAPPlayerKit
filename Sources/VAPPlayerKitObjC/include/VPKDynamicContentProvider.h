#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKSourceMetadata;

/// 动态内容提供者。组件不内置下载器和图片库；completion 必须且只能调用一次。
///
/// 文字槽位应通过 `replacementText` 返回替换字符串，组件会使用 vapc 颜色、粗体标记
/// 和槽位尺寸自动估算字号（与 Swift `.textReplacement` 相同）。溢出默认截断，
/// 可通过 `VPKPlaybackOptions.dynamicTextOverflowMode` 切换为跑马灯。图片槽位返回 `image`。
@protocol VPKDynamicContentProvider <NSObject>
/// 解析 tag。文字槽位返回 `replacementText`，图片槽位返回 `image`；失败传 `error`。
/// completion 必须且只能调用一次。
- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable replacementText, NSError * _Nullable error))completion;

/// 可选的文字字体覆盖；未实现或返回 nil 时由组件自动估算字号。
@optional
- (nullable UIFont *)fontForTag:(NSString *)tag;
@end

typedef NS_ENUM(NSInteger, VPKDynamicSourceKind) {
    /// 图片槽位。
    VPKDynamicSourceKindImage = 0,
    /// 文字槽位。
    VPKDynamicSourceKindText = 1
};

/// vapc 动态槽位描述。`slotSize` 是预缩放目标像素尺寸。
@interface VPKSourceMetadata : NSObject

/// vapc 中的 tag，例如 `avatar`。
@property (nonatomic, readonly, copy) NSString *tag;
/// 该槽位的像素尺寸。
@property (nonatomic, readonly, assign) CGSize slotSize;
/// vapc 声明的槽位类型：`img` 或 `txt`。
@property (nonatomic, readonly, assign) VPKDynamicSourceKind kind;

/// 兼容旧调用：未声明 kind 时按图片槽位处理。
- (instancetype)initWithTag:(NSString *)tag slotSize:(CGSize)slotSize;
/// 完整构造。`kind` 必须与 vapc `srcType` 一致。
- (instancetype)initWithTag:(NSString *)tag slotSize:(CGSize)slotSize kind:(VPKDynamicSourceKind)kind;

@end

NS_ASSUME_NONNULL_END
