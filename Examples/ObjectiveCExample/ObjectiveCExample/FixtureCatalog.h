#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VAPFixture : NSObject

@property (nonatomic, readonly, strong) NSURL *url;
@property (nonatomic, readonly, assign) int64_t byteCount;
@property (nonatomic, readonly, copy) NSString *fileName;
@property (nonatomic, readonly, copy) NSString *identifier;
@property (nonatomic, readonly, copy) NSString *shortIdentifier;
@property (nonatomic, readonly, copy) NSString *formattedSize;
@property (nonatomic, readonly, assign) BOOL looksLikeMedia;
@property (nonatomic, readonly, assign) NSInteger numericID;

- (instancetype)initWithURL:(NSURL *)url byteCount:(int64_t)byteCount;

@end

@interface FixtureCatalog : NSObject

+ (NSArray<VAPFixture *> *)scan;
+ (NSArray<VAPFixture *> *)scanInBundle:(NSBundle *)bundle;

@end

NS_ASSUME_NONNULL_END
