#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class VPKSourceMetadata;

@protocol VPKDynamicContentProvider <NSObject>
- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable image, NSError * _Nullable error))completion;
@end

@interface VPKSourceMetadata : NSObject

@property (nonatomic, readonly, copy) NSString *tag;
@property (nonatomic, readonly, assign) CGSize slotSize;

- (instancetype)initWithTag:(NSString *)tag slotSize:(CGSize)slotSize;

@end

NS_ASSUME_NONNULL_END
