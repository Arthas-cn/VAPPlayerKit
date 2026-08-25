#import "BatchTestViewController.h"

#import "FixtureCatalog.h"
#import "GiftCatalog.h"

@import VAPPlayerKitObjC;

@interface BatchTestViewController () <VPKPlayerDelegate, VPKDynamicContentProvider>
@property (nonatomic, copy) NSArray<VAPFixture *> *fixtures;
@property (nonatomic, strong) VPKPlayerView *playerView;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *progressLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, assign) BOOL started;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, assign) BOOL currentDidStart;
@property (nonatomic, strong, nullable) NSError *currentFailure;
@property (nonatomic, strong, nullable) NSNumber *currentFinishReason;
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@property (nonatomic, assign) NSUInteger runGeneration;
@end

@implementation BatchTestViewController

- (instancetype)initWithFixtures:(NSArray<VAPFixture *> *)fixtures {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _fixtures = [fixtures copy];
        _playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
        _stateLabel = [[UILabel alloc] init];
        _progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleBar];
        _progressLabel = [[UILabel alloc] init];
        _logView = [[UITextView alloc] init];
        _lines = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    _cancelled = YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Device Batch Test";
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.04 blue:0.065 alpha:1];
    self.playerView.delegate = self;
    self.playerView.dynamicContentProvider = self;
    [self configureUI];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started) {
        return;
    }
    self.started = YES;
    [self runAllFixtures];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController) {
        self.cancelled = YES;
        self.runGeneration += 1;
        [self.playerView stop];
    }
}

- (void)configureUI {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [self.view addSubview:stack];

    self.stateLabel.text = @"WAITING";
    self.stateLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightBold];
    self.stateLabel.textColor = [UIColor colorWithRed:0.48 green:0.84 blue:1 alpha:1];
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.accessibilityIdentifier = @"batch.state";
    self.progressView.progressTintColor = [UIColor colorWithRed:0.28 green:0.75 blue:0.57 alpha:1];
    self.progressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.progressLabel.textColor = UIColor.secondaryLabelColor;
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.accessibilityIdentifier = @"batch.progress";
    self.playerView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.playerView.layer.cornerRadius = 18;
    self.playerView.clipsToBounds = YES;
    [self.playerView.heightAnchor constraintEqualToConstant:220].active = YES;
    self.logView.backgroundColor = [UIColor colorWithRed:0.02 green:0.025 blue:0.04 alpha:1];
    self.logView.textColor = [UIColor colorWithWhite:0.75 alpha:1];
    self.logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.logView.editable = NO;
    self.logView.layer.cornerRadius = 14;
    self.logView.accessibilityIdentifier = @"batch.log";

    for (UIView *view in @[self.stateLabel, self.progressView, self.progressLabel, self.playerView, self.logView]) {
        [stack addArrangedSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16]
    ]];
}

- (void)runAllFixtures {
    if (self.fixtures.count == 0) {
        self.stateLabel.text = @"BATCH FAILED";
        [self appendLine:@"No fixtures found"];
        return;
    }
    self.stateLabel.text = @"BATCH RUNNING";
    [self appendLine:[NSString stringWithFormat:@"Device: %@, iOS %@", UIDevice.currentDevice.name, UIDevice.currentDevice.systemVersion]];
    [self appendLine:[NSString stringWithFormat:@"Fixtures: %lu", (unsigned long)self.fixtures.count]];
    [self runFixtureAtIndex:0 failures:[NSMutableArray array] generation:self.runGeneration];
}

- (void)runFixtureAtIndex:(NSUInteger)index
                 failures:(NSMutableArray<NSString *> *)failures
               generation:(NSUInteger)generation {
    if (self.cancelled || self.runGeneration != generation) {
        return;
    }
    if (index >= self.fixtures.count) {
        [self.progressView setProgress:1 animated:YES];
        self.progressLabel.text = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)self.fixtures.count, (unsigned long)self.fixtures.count];
        [self.playerView clear];
        if (failures.count == 0) {
            self.stateLabel.text = @"BATCH PASSED";
            [self appendLine:@"All fixture checks passed"];
        } else {
            self.stateLabel.text = @"BATCH FAILED";
            [self appendLine:[NSString stringWithFormat:@"Failures: %lu", (unsigned long)failures.count]];
            for (NSString *line in failures) {
                [self appendLine:line];
            }
        }
        return;
    }

    VAPFixture *fixture = self.fixtures[index];
    self.progressLabel.text = [NSString stringWithFormat:@"%lu / %lu · %@", (unsigned long)(index + 1), (unsigned long)self.fixtures.count, fixture.shortIdentifier];
    [self.progressView setProgress:(float)index / (float)self.fixtures.count animated:YES];
    self.currentDidStart = NO;
    self.currentFailure = nil;
    self.currentFinishReason = nil;
    [self.playerView clear];

    VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
    options.loopCount = 0;
    options.clearsAfterFinish = NO;

    __weak typeof(self) weakSelf = self;
    [self.playerView prepareWithURL:fixture.url options:options completion:^(VPKAssetMetadata *metadata, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self.cancelled || self.runGeneration != generation) {
            return;
        }
        if (metadata == nil) {
            [self.playerView stop];
            if (fixture.looksLikeMedia) {
                [failures addObject:[NSString stringWithFormat:@"%@: %@", fixture.shortIdentifier, error.localizedDescription]];
                [self appendLine:[NSString stringWithFormat:@"FAIL %lu: %@", (unsigned long)(index + 1), error.localizedDescription]];
            } else {
                [self appendLine:[NSString stringWithFormat:@"PASS %lu: negative fixture rejected", (unsigned long)(index + 1)]];
            }
            [self runFixtureAtIndex:index + 1 failures:failures generation:generation];
            return;
        }
        if (!fixture.looksLikeMedia) {
            [failures addObject:[NSString stringWithFormat:@"%@: invalid fixture unexpectedly prepared", fixture.shortIdentifier]];
            [self appendLine:@"FAIL negative fixture accepted"];
            [self.playerView stop];
            [self runFixtureAtIndex:index + 1 failures:failures generation:generation];
            return;
        }
        if (metadata.frameCount <= 0 || metadata.duration <= 0 || metadata.canvasSize.width <= 0 || metadata.canvasSize.height <= 0) {
            [self.playerView stop];
            [failures addObject:[NSString stringWithFormat:@"%@: Metadata invariants failed.", fixture.shortIdentifier]];
            [self appendLine:[NSString stringWithFormat:@"FAIL %lu: Metadata invariants failed.", (unsigned long)(index + 1)]];
            [self runFixtureAtIndex:index + 1 failures:failures generation:generation];
            return;
        }

        [self.playerView playWithURL:fixture.url options:options];
        [self waitUntil:^BOOL {
            return self.currentDidStart;
        } timeout:3 generation:generation completion:^(NSError *waitError) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil || self.cancelled || self.runGeneration != generation) {
                return;
            }
            if (waitError != nil) {
                [self.playerView stop];
                [failures addObject:[NSString stringWithFormat:@"%@: %@", fixture.shortIdentifier, waitError.localizedDescription]];
                [self appendLine:[NSString stringWithFormat:@"FAIL %lu: %@", (unsigned long)(index + 1), waitError.localizedDescription]];
                [self runFixtureAtIndex:index + 1 failures:failures generation:generation];
                return;
            }
            NSTimeInterval keep = MIN(1, metadata.duration);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(keep * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (self == nil || self.cancelled || self.runGeneration != generation) {
                    return;
                }
                if (self.currentFailure != nil) {
                    [self.playerView stop];
                    [failures addObject:[NSString stringWithFormat:@"%@: %@", fixture.shortIdentifier, self.currentFailure.localizedDescription]];
                    [self appendLine:[NSString stringWithFormat:@"FAIL %lu: %@", (unsigned long)(index + 1), self.currentFailure.localizedDescription]];
                    [self runFixtureAtIndex:index + 1 failures:failures generation:generation];
                    return;
                }
                [self.playerView stop];
                [self waitUntil:^BOOL {
                    return self.currentFinishReason != nil && self.currentFinishReason.integerValue == VPKFinishReasonStopped;
                } timeout:3 generation:generation completion:^(NSError *stopError) {
                    __strong typeof(weakSelf) self = weakSelf;
                    if (self == nil || self.cancelled || self.runGeneration != generation) {
                        return;
                    }
                    if (stopError != nil || self.currentFinishReason.integerValue != VPKFinishReasonStopped) {
                        [failures addObject:[NSString stringWithFormat:@"%@: Stop did not emit the stopped terminal callback.", fixture.shortIdentifier]];
                        [self appendLine:[NSString stringWithFormat:@"FAIL %lu: Stop did not emit the stopped terminal callback.", (unsigned long)(index + 1)]];
                    } else {
                        [self appendLine:[NSString stringWithFormat:@"PASS %lu: %@, %ldf", (unsigned long)(index + 1), metadata.codec, (long)metadata.frameCount]];
                    }
                    [self runFixtureAtIndex:index + 1 failures:failures generation:generation];
                }];
            });
        }];
    }];
}

- (void)waitUntil:(BOOL (^)(void))predicate
          timeout:(NSTimeInterval)timeout
       generation:(NSUInteger)generation
       completion:(void (^)(NSError * _Nullable error))completion {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    [self pollUntil:predicate deadline:deadline generation:generation completion:completion];
}

- (void)pollUntil:(BOOL (^)(void))predicate
         deadline:(NSTimeInterval)deadline
       generation:(NSUInteger)generation
       completion:(void (^)(NSError * _Nullable error))completion {
    if (self.cancelled || self.runGeneration != generation) {
        return;
    }
    if (self.currentFailure != nil) {
        completion(self.currentFailure);
        return;
    }
    if (predicate()) {
        completion(nil);
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        completion([NSError errorWithDomain:@"ObjectiveCExample" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Playback did not start before timeout."
        }]);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pollUntil:predicate deadline:deadline generation:generation completion:completion];
    });
}

- (void)appendLine:(NSString *)line {
    [self.lines addObject:line];
    self.logView.text = [self.lines componentsJoinedByString:@"\n"];
    if (self.logView.text.length > 0) {
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
    }
}

- (void)playerViewDidStart:(VPKPlayerView *)playerView {
    self.currentDidStart = YES;
}

- (void)playerView:(VPKPlayerView *)playerView didResolveMetadata:(VPKAssetMetadata *)metadata {
}

- (void)playerView:(VPKPlayerView *)playerView didFinishWithReason:(VPKFinishReason)reason {
    self.currentFinishReason = @(reason);
}

- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error {
    self.currentFailure = error;
}

- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable, NSString * _Nullable, NSError * _Nullable))completion {
    [GiftCatalog resolveSource:source completion:completion];
}

@end
