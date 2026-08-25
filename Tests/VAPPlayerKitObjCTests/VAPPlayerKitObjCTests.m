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
    XCTAssertEqual(options.dynamicImagePlaybackMode, VPKDynamicImagePlaybackModeAnimated);
    XCTAssertFalse(VPKPlaybackOptions.canPlayAnimatedDynamicImages);
}

- (void)testSwiftRuntimeSymbolsExist {
    XCTAssertNotNil(NSClassFromString(@"VPKPlayerView"));
    XCTAssertNotNil(NSClassFromString(@"VPKPlaybackOptions"));
    XCTAssertNotNil(NSClassFromString(@"VPKAssetMetadata"));
}

- (void)testPlayerViewCanBeCreatedFromObjectiveC {
    VPKPlayerView *playerView = [[VPKPlayerView alloc] initWithFrame:CGRectMake(0, 0, 100, 100)];
    XCTAssertNotNil(playerView);
    XCTAssertTrue([playerView respondsToSelector:@selector(prepareWithURL:metadata:options:completion:)]);
    XCTAssertTrue([playerView respondsToSelector:@selector(playWithURL:metadata:options:)]);
    [playerView pause];
    [playerView resume];
    [playerView stop];
    [playerView clear];
}

- (void)testManuallyConstructedMetadataIsNotReusableForPlayback {
    VPKAssetMetadata *metadata = [[VPKAssetMetadata alloc]
        initWithEncodedVideoSize:CGSizeMake(200, 100)
        canvasSize:CGSizeMake(100, 100)
        alphaMode:VPKAlphaModeLeft
        frameCount:30
        duration:1
        containsAudio:NO
        codec:@"h264"
        vapVersion:0
        dynamicSources:@[]];
    XCTAssertFalse(metadata.reusableForPlayback);
}

- (void)testErrorDomainConstant {
    XCTAssertEqualObjects(VPKPlaybackErrorDomain, @"com.vapplayerkit.playback");
}

@end
