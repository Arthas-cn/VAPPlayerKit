@import XCTest;
@import UIKit;
@import VAPPlayerKitObjC;

@interface VAPPlayerKitObjCTests : XCTestCase
@end

@implementation VAPPlayerKitObjCTests

- (void)testPlaybackOptionsDefaults {
    VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
    XCTAssertEqual(options.loopCount, 1);
    XCTAssertEqual(options.assetMode, VPKPlaybackAssetModeAutomatic);
    XCTAssertEqual(options.audioMode, VPKAudioModeEmbedded);
    XCTAssertTrue(options.clearsAfterFinish);
    XCTAssertEqual(options.dynamicImagePlaybackMode, VPKDynamicImagePlaybackModeAnimated);
    XCTAssertEqual(options.dynamicTextOverflowMode, VPKDynamicTextOverflowModeTruncate);
    XCTAssertEqualWithAccuracy(options.marqueeSpeed, 80, 0.001);
    XCTAssertEqualWithAccuracy(options.marqueeStartDelay, 0.6, 0.0001);
    XCTAssertFalse(VPKPlaybackOptions.canPlayAnimatedDynamicImages);
}

- (void)testSwiftRuntimeSymbolsExist {
    XCTAssertNotNil(NSClassFromString(@"VPKPlayerView"));
    XCTAssertNotNil(NSClassFromString(@"VPKPlaybackOptions"));
    XCTAssertNotNil(NSClassFromString(@"VPKAssetMetadata"));
    XCTAssertNotNil(NSClassFromString(@"VPKAssetMetadataCache"));
}

- (void)testAssetMetadataCacheFacade {
    VPKAssetMetadataCache *cache = VPKAssetMetadataCache.sharedCache;
    XCTAssertNotNil(cache);
    XCTAssertEqual(cache.countLimit, 20);
    cache.countLimit = 0;
    XCTAssertEqual(cache.countLimit, 0);
    [cache removeAll];
    cache.countLimit = 20;
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
    XCTAssertTrue(metadata.isVAP);
}

- (void)testErrorDomainConstant {
    XCTAssertEqualObjects(VPKPlaybackErrorDomain, @"com.vapplayerkit.playback");
}

@end
