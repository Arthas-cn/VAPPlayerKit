#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// packed 视频中 Alpha 相对 RGB 的方向。对应 Swift `AlphaMode`。
typedef NS_ENUM(NSInteger, VPKAlphaMode) {
    VPKAlphaModeLeft = 0,
    VPKAlphaModeRight,
    VPKAlphaModeTop,
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

- (instancetype)initWithEncodedVideoSize:(CGSize)encodedVideoSize
                              canvasSize:(CGSize)canvasSize
                               alphaMode:(VPKAlphaMode)alphaMode
                              frameCount:(NSInteger)frameCount
                                duration:(NSTimeInterval)duration
                           containsAudio:(BOOL)containsAudio
                                   codec:(NSString *)codec;

@end

NS_ASSUME_NONNULL_END
