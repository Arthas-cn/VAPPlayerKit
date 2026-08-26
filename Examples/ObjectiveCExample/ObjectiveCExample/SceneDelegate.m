#import "SceneDelegate.h"
#import "ViewController.h"
#import "VPKPerformanceBenchmarkViewController.h"

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *rootViewController;
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--vap-performance-benchmark"]) {
        rootViewController = [[VPKPerformanceBenchmarkViewController alloc] init];
    } else {
        rootViewController = [[ViewController alloc] init];
    }
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:rootViewController];
    navigationController.navigationBar.prefersLargeTitles = YES;
    window.rootViewController = navigationController;
    [window makeKeyAndVisible];
    self.window = window;
}

@end
