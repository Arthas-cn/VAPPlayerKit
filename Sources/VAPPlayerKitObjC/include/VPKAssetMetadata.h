#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKSourceMetadata;

/// packed 视频中 Alpha 相对 RGB 的方向。对应 Swift `AlphaMode`。
typedef NS_ENUM(NSInteger, VPKAlphaMode) {
    /// Alpha 在左，RGB 在右。
    VPKAlphaModeLeft = 0,
    /// Alpha 在右，RGB 在左。
    VPKAlphaModeRight,
    /// Alpha 在上，RGB 在下。
    VPKAlphaModeTop,
    /// Alpha 在下，RGB 在上。
    VPKAlphaModeBottom
};

/// 不可变资源元数据。`canvasSize` 用于布局，`encodedVideoSize` 是 packed 编码尺寸。
@interface VPKAssetMetadata : NSObject

/// packed RGB+Alpha 视频编码宽高。
@property (nonatomic, readonly, assign) CGSize encodedVideoSize;
/// vapc 逻辑画布。
@property (nonatomic, readonly, assign) CGSize canvasSize;
/// Alpha 布局。
@property (nonatomic, readonly, assign) VPKAlphaMode alphaMode;
/// 帧数。
@property (nonatomic, readonly, assign) NSInteger frameCount;
/// 时长（秒）。
@property (nonatomic, readonly, assign) NSTimeInterval duration;
/// 容器是否含音轨。
@property (nonatomic, readonly, assign) BOOL containsAudio;
/// 例如 h264 / hevc。
@property (nonatomic, readonly, copy) NSString *codec;
/// vapc 版本；legacy 无 vapc 文件为 0。
@property (nonatomic, readonly, assign) NSInteger vapVersion;
/// vapc 动态 source 槽位。
@property (nonatomic, readonly, copy) NSArray<VPKSourceMetadata *> *dynamicSources;
/// 是否可直接用于 metadata 复用播放 API 和全局缓存。
///
/// 仅本组件解析出的、带内部 vapc 布局和文件签名的对象为 `YES`。
/// 手工构造的摘要对象为 `NO`，不能传给 `playWithURL:metadata:options:`。
@property (nonatomic, readonly, assign, getter=isReusableForPlayback) BOOL reusableForPlayback;

/// 手工构造的摘要对象。不包含内部 vapc 布局，因此 `reusableForPlayback` 为 `NO`。
- (instancetype)initWithEncodedVideoSize:(CGSize)encodedVideoSize
                              canvasSize:(CGSize)canvasSize
                               alphaMode:(VPKAlphaMode)alphaMode
                              frameCount:(NSInteger)frameCount
                                duration:(NSTimeInterval)duration
                           containsAudio:(BOOL)containsAudio
                                   codec:(NSString *)codec
                              vapVersion:(NSInteger)vapVersion
                          dynamicSources:(NSArray<VPKSourceMetadata *> *)dynamicSources;

@end

NS_ASSUME_NONNULL_END
