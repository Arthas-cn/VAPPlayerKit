#import <UIKit/UIKit.h>
@import VAPPlayerKitObjC;

NS_ASSUME_NONNULL_BEGIN

@interface GiftCatalog : NSObject

@property (nonatomic, class, readonly, copy) NSString *replacementText;

+ (void)resolveSource:(VPKSourceMetadata *)source
           completion:(void (^)(UIImage * _Nullable image, NSString * _Nullable replacementText, NSError * _Nullable error))completion;
+ (nullable UIImage *)imageForSource:(VPKSourceMetadata *)source;
+ (nullable UIImage *)randomImage;
+ (NSArray<NSURL *> *)imageURLsInBundle:(NSBundle *)bundle;

@end

NS_ASSUME_NONNULL_END
