#import <UIKit/UIKit.h>

@class VAPFixture;

NS_ASSUME_NONNULL_BEGIN

@interface BatchTestViewController : UIViewController

- (instancetype)initWithFixtures:(NSArray<VAPFixture *> *)fixtures;

@end

NS_ASSUME_NONNULL_END
