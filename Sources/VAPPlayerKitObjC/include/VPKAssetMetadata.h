#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VPKAlphaMode) {
    VPKAlphaModeLeft = 0,
    VPKAlphaModeRight,
    VPKAlphaModeTop,
    VPKAlphaModeBottom
};

@interface VPKAssetMetadata : NSObject

@property (nonatomic, readonly, assign) CGSize encodedVideoSize;
@property (nonatomic, readonly, assign) CGSize canvasSize;
@property (nonatomic, readonly, assign) VPKAlphaMode alphaMode;
@property (nonatomic, readonly, assign) NSInteger frameCount;
@property (nonatomic, readonly, assign) NSTimeInterval duration;
@property (nonatomic, readonly, assign) BOOL containsAudio;
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
