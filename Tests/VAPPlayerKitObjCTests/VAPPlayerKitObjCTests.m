@import XCTest;
@import UIKit;
@import VAPPlayerKitObjC;

@interface VAPPlayerKitObjCTests : XCTestCase
@end

@implementation VAPPlayerKitObjCTests

- (void)testPlaybackOptionsDefaults {
    VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
    XCTAssertEqual(options.loopCount, 1);
    XCTAssertEqual(options.audioMode, VPKAudioModeMuted);
    XCTAssertTrue(options.clearsAfterFinish);
}

- (void)testSwiftRuntimeSymbolsExist {
    XCTAssertNotNil(NSClassFromString(@"VPKPlayerView"));
    XCTAssertNotNil(NSClassFromString(@"VPKPlaybackOptions"));
    XCTAssertNotNil(NSClassFromString(@"VPKAssetMetadata"));
}

- (void)testPlayerViewCanBeCreatedFromObjectiveC {
    VPKPlayerView *playerView = [[VPKPlayerView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    XCTAssertNotNil(playerView);
    [playerView pause];
    [playerView resume];
    [playerView stop];
    [playerView clear];
}

- (void)testErrorDomainConstant {
    XCTAssertEqualObjects(VPKPlaybackErrorDomain, @"com.vapplayerkit.playback");
}

@end
