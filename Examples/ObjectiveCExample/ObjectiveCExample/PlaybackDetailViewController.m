#import "PlaybackDetailViewController.h"

#import "FixtureCatalog.h"
#import "GiftCatalog.h"

@import VAPPlayerKitObjC;

static NSString *VPKAlphaModeName(VPKAlphaMode mode) {
    switch (mode) {
        case VPKAlphaModeLeft: return @"left";
        case VPKAlphaModeRight: return @"right";
        case VPKAlphaModeTop: return @"top";
        case VPKAlphaModeBottom: return @"bottom";
        case VPKAlphaModeNone: return @"none";
    }
    return @"unknown";
}

static NSString *VPKFinishReasonName(VPKFinishReason reason) {
    switch (reason) {
        case VPKFinishReasonCompleted: return @"completed";
        case VPKFinishReasonStopped: return @"stopped";
        case VPKFinishReasonCancelled: return @"cancelled";
    }
    return @"unknown";
}

@interface CheckerboardView : UIView
@end

@interface InsetsLabel : UILabel
@end

@interface PlaybackDetailViewController () <VPKPlayerDelegate, VPKDynamicContentProvider>
@property (nonatomic, strong) VAPFixture *fixture;
@property (nonatomic, strong) VPKPlayerView *playerView;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *contentStack;
@property (nonatomic, strong) UIView *previewCard;
@property (nonatomic, strong) InsetsLabel *stateLabel;
@property (nonatomic, strong) UILabel *metadataLabel;
@property (nonatomic, strong) UITextView *consoleView;
@property (nonatomic, strong) UISegmentedControl *contentModeControl;
@property (nonatomic, strong) UISegmentedControl *loopControl;
@property (nonatomic, strong) UISegmentedControl *audioControl;
@property (nonatomic, strong) UISegmentedControl *backgroundControl;
@property (nonatomic, strong) UISegmentedControl *textOverflowControl;
@property (nonatomic, strong) UISwitch *clearsSwitch;
@property (nonatomic, strong, nullable) VPKAssetMetadata *currentMetadata;
@property (nonatomic, assign) BOOL isAutomatedRun;
@property (nonatomic, assign) BOOL currentDidStart;
@property (nonatomic, strong, nullable) NSError *currentFailure;
@property (nonatomic, strong, nullable) NSNumber *currentFinishReason;
@property (nonatomic, assign) BOOL hasAutoPlayed;
@property (nonatomic, assign) NSUInteger operationGeneration;
@property (nonatomic, strong) NSMutableArray<NSString *> *logLines;
@property (nonatomic, assign) NSTimeInterval startedAt;
@end

@implementation PlaybackDetailViewController

- (instancetype)initWithFixture:(VAPFixture *)fixture {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _fixture = fixture;
        _playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
        _scrollView = [[UIScrollView alloc] init];
        _contentStack = [[UIStackView alloc] init];
        _previewCard = [[UIView alloc] init];
        _stateLabel = [[InsetsLabel alloc] init];
        _metadataLabel = [[UILabel alloc] init];
        _consoleView = [[UITextView alloc] init];
        _contentModeControl = [[UISegmentedControl alloc] initWithItems:@[@"Fit", @"Fill", @"Stretch"]];
        _loopControl = [[UISegmentedControl alloc] initWithItems:@[@"1×", @"2×", @"∞"]];
        _audioControl = [[UISegmentedControl alloc] initWithItems:@[@"静音", @"内嵌", @"外部", @"禁用"]];
        _backgroundControl = [[UISegmentedControl alloc] initWithItems:@[@"挂起", @"停止"]];
        _textOverflowControl = [[UISegmentedControl alloc] initWithItems:@[@"截断", @"跑马灯"]];
        _clearsSwitch = [[UISwitch alloc] init];
        _logLines = [NSMutableArray array];
        _startedAt = NSProcessInfo.processInfo.systemUptime;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self configureNavigation];
    [self configureHierarchy];
    [self configurePlayer];
    [self appendCategory:@"DEVICE" message:[NSString stringWithFormat:@"%@, iOS %@",
                                            UIDevice.currentDevice.model,
                                            UIDevice.currentDevice.systemVersion]];
    [self appendCategory:@"ASSET" message:[NSString stringWithFormat:@"%@, %@",
                                           self.fixture.shortIdentifier,
                                           self.fixture.formattedSize]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.hasAutoPlayed) {
        return;
    }
    self.hasAutoPlayed = YES;
    self.stateLabel.text = @"PREPARING";
    [self appendCategory:@"ACTION" message:@"auto play on detail entry"];
    [self.playerView playWithURL:self.fixture.url options:[self currentOptions]];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController || self.navigationController.isBeingDismissed) {
        [self cancelOperation];
        [self.playerView stop];
        [self persistReport];
    }
}

- (void)configureNavigation {
    self.title = @"Playback Lab";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.04 blue:0.065 alpha:1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                                                               style:UIBarButtonItemStylePlain
                                                                              target:self
                                                                              action:@selector(shareReport)];
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier = @"detail.shareReport";
}

- (void)configureHierarchy {
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    self.contentStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentStack.axis = UILayoutConstraintAxisVertical;
    self.contentStack.spacing = 16;
    [self.view addSubview:self.scrollView];
    [self.scrollView addSubview:self.contentStack];
    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.contentStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:14],
        [self.contentStack.leadingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.leadingAnchor constant:16],
        [self.contentStack.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-16],
        [self.contentStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-28]
    ]];

    [self configurePreviewCard];
    [self.contentStack addArrangedSubview:[self makeAssetHeader]];
    [self.contentStack addArrangedSubview:self.previewCard];
    [self.contentStack addArrangedSubview:[self makeOptionsCard]];
    [self.contentStack addArrangedSubview:[self makeControlsCard]];
    [self.contentStack addArrangedSubview:[self makeDiagnosticsCard]];
}

- (void)configurePreviewCard {
    self.previewCard.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.12 alpha:1];
    self.previewCard.layer.cornerRadius = 22;
    self.previewCard.layer.cornerCurve = kCACornerCurveContinuous;
    self.previewCard.clipsToBounds = YES;
    [self.previewCard.heightAnchor constraintEqualToConstant:360].active = YES;

    CheckerboardView *checker = [[CheckerboardView alloc] init];
    checker.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.playerView.accessibilityIdentifier = @"detail.player";
    self.stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.stateLabel.text = @"IDLE";
    self.stateLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightBold];
    self.stateLabel.textColor = UIColor.whiteColor;
    self.stateLabel.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.62];
    self.stateLabel.layer.cornerRadius = 9;
    self.stateLabel.clipsToBounds = YES;
    self.stateLabel.accessibilityIdentifier = @"detail.state";
    [self.previewCard addSubview:checker];
    [self.previewCard addSubview:self.playerView];
    [self.previewCard addSubview:self.stateLabel];
    [NSLayoutConstraint activateConstraints:@[
        [checker.topAnchor constraintEqualToAnchor:self.previewCard.topAnchor],
        [checker.leadingAnchor constraintEqualToAnchor:self.previewCard.leadingAnchor],
        [checker.trailingAnchor constraintEqualToAnchor:self.previewCard.trailingAnchor],
        [checker.bottomAnchor constraintEqualToAnchor:self.previewCard.bottomAnchor],
        [self.playerView.topAnchor constraintEqualToAnchor:self.previewCard.topAnchor],
        [self.playerView.leadingAnchor constraintEqualToAnchor:self.previewCard.leadingAnchor],
        [self.playerView.trailingAnchor constraintEqualToAnchor:self.previewCard.trailingAnchor],
        [self.playerView.bottomAnchor constraintEqualToAnchor:self.previewCard.bottomAnchor],
        [self.stateLabel.topAnchor constraintEqualToAnchor:self.previewCard.topAnchor constant:12],
        [self.stateLabel.leadingAnchor constraintEqualToAnchor:self.previewCard.leadingAnchor constant:12]
    ]];
}

- (UIView *)makeAssetHeader {
    UILabel *eyebrow = [[UILabel alloc] init];
    eyebrow.text = self.fixture.looksLikeMedia ? @"LOCAL MEDIA FIXTURE" : @"NEGATIVE FIXTURE";
    eyebrow.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    eyebrow.textColor = [UIColor colorWithRed:0.42 green:0.82 blue:1 alpha:1];
    UILabel *name = [[UILabel alloc] init];
    name.text = self.fixture.shortIdentifier;
    name.font = [UIFont monospacedSystemFontOfSize:19 weight:UIFontWeightSemibold];
    name.textColor = UIColor.whiteColor;
    name.adjustsFontSizeToFitWidth = YES;
    UILabel *detail = [[UILabel alloc] init];
    detail.text = [NSString stringWithFormat:@"%@ · 本地文件 · 已自动播放，可用下方控制测试", self.fixture.formattedSize];
    detail.font = [UIFont systemFontOfSize:13];
    detail.textColor = [UIColor colorWithWhite:0.62 alpha:1];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[eyebrow, name, detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 5;
    return stack;
}

- (UIView *)makeOptionsCard {
    self.contentModeControl.selectedSegmentIndex = 0;
    self.loopControl.selectedSegmentIndex = 0;
    self.audioControl.selectedSegmentIndex = 0;
    self.backgroundControl.selectedSegmentIndex = 0;
    self.textOverflowControl.selectedSegmentIndex = 0;
    self.clearsSwitch.on = YES;
    UIColor *tint = [UIColor colorWithRed:0.15 green:0.43 blue:0.62 alpha:1];
    self.contentModeControl.selectedSegmentTintColor = tint;
    self.loopControl.selectedSegmentTintColor = tint;
    self.audioControl.selectedSegmentTintColor = tint;
    self.backgroundControl.selectedSegmentTintColor = tint;
    self.textOverflowControl.selectedSegmentTintColor = tint;
    self.contentModeControl.accessibilityIdentifier = @"detail.contentMode";
    self.loopControl.accessibilityIdentifier = @"detail.loopCount";
    self.audioControl.accessibilityIdentifier = @"detail.audioMode";
    self.backgroundControl.accessibilityIdentifier = @"detail.backgroundPolicy";
    self.textOverflowControl.accessibilityIdentifier = @"detail.textOverflow";
    self.clearsSwitch.accessibilityIdentifier = @"detail.clearsAfterFinish";
    return [self makeCardWithTitle:@"播放参数" rows:@[
        [self makeOptionRowWithTitle:@"画布模式" control:self.contentModeControl],
        [self makeOptionRowWithTitle:@"循环次数" control:self.loopControl],
        [self makeOptionRowWithTitle:@"音频策略" control:self.audioControl],
        [self makeOptionRowWithTitle:@"离屏策略" control:self.backgroundControl],
        [self makeOptionRowWithTitle:@"文字溢出" control:self.textOverflowControl],
        [self makeOptionRowWithTitle:@"结束清屏" control:self.clearsSwitch]
    ]];
}

- (UIView *)makeControlsCard {
    UIButton *prepare = [self makeButtonWithTitle:@"Prepare" icon:@"doc.text.magnifyingglass" action:@selector(prepareTapped) identifier:@"detail.prepare" prominent:NO];
    UIButton *play = [self makeButtonWithTitle:@"Play" icon:@"play.fill" action:@selector(playTapped) identifier:@"detail.play" prominent:YES];
    UIButton *pause = [self makeButtonWithTitle:@"Pause" icon:@"pause.fill" action:@selector(pauseTapped) identifier:@"detail.pause" prominent:NO];
    UIButton *resume = [self makeButtonWithTitle:@"Resume" icon:@"forward.fill" action:@selector(resumeTapped) identifier:@"detail.resume" prominent:NO];
    UIButton *stop = [self makeButtonWithTitle:@"Stop" icon:@"stop.fill" action:@selector(stopTapped) identifier:@"detail.stop" prominent:NO];
    UIButton *clear = [self makeButtonWithTitle:@"Clear" icon:@"trash" action:@selector(clearTapped) identifier:@"detail.clear" prominent:NO];
    UIButton *autoTest = [self makeButtonWithTitle:@"运行自动真机冒烟测试"
                                              icon:@"checkmark.seal.fill"
                                            action:@selector(autoTestTapped)
                                        identifier:@"detail.autoTest"
                                         prominent:YES];
    return [self makeCardWithTitle:@"控制矩阵" rows:@[
        [self makeButtonRow:@[prepare, play]],
        [self makeButtonRow:@[pause, resume]],
        [self makeButtonRow:@[stop, clear]],
        autoTest
    ]];
}

- (UIView *)makeDiagnosticsCard {
    self.metadataLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.metadataLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1];
    self.metadataLabel.numberOfLines = 0;
    self.metadataLabel.text = @"Metadata 尚未解析";
    self.metadataLabel.accessibilityIdentifier = @"detail.metadata";
    self.consoleView.backgroundColor = [UIColor colorWithRed:0.025 green:0.03 blue:0.045 alpha:1];
    self.consoleView.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    self.consoleView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.consoleView.editable = NO;
    self.consoleView.layer.cornerRadius = 12;
    [self.consoleView.heightAnchor constraintEqualToConstant:220].active = YES;
    self.consoleView.accessibilityIdentifier = @"detail.console";
    return [self makeCardWithTitle:@"实时诊断" rows:@[self.metadataLabel, self.consoleView]];
}

- (void)configurePlayer {
    self.playerView.delegate = self;
    self.playerView.dynamicContentProvider = self;
}

- (VPKPlaybackOptions *)currentOptions {
    return [self currentOptionsWithContentMode:NSNotFound audioMode:NSNotFound];
}

- (VPKPlaybackOptions *)currentOptionsWithContentMode:(NSInteger)contentMode audioMode:(NSInteger)audioMode {
    VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
    UIViewContentMode modes[] = {
        UIViewContentModeScaleAspectFit,
        UIViewContentModeScaleAspectFill,
        UIViewContentModeScaleToFill
    };
    VPKAudioMode audios[] = {
        VPKAudioModeMuted,
        VPKAudioModeEmbedded,
        VPKAudioModeExternal,
        VPKAudioModeDisabled
    };
    NSInteger loops[] = { 1, 2, 0 };
    NSInteger contentIndex = self.contentModeControl.selectedSegmentIndex;
    NSInteger loopIndex = self.loopControl.selectedSegmentIndex;
    NSInteger audioIndex = self.audioControl.selectedSegmentIndex;
    if (contentIndex < 0 || contentIndex > 2) {
        contentIndex = 0;
    }
    if (loopIndex < 0 || loopIndex > 2) {
        loopIndex = 0;
    }
    if (audioIndex < 0 || audioIndex > 3) {
        audioIndex = 0;
    }
    options.contentMode = contentMode == NSNotFound ? modes[contentIndex] : (UIViewContentMode)contentMode;
    options.loopCount = loops[loopIndex];
    options.audioMode = audioMode == NSNotFound ? audios[audioIndex] : (VPKAudioMode)audioMode;
    options.backgroundPolicy = self.backgroundControl.selectedSegmentIndex == 0 ? VPKBackgroundPolicySuspend : VPKBackgroundPolicyStop;
    options.dynamicTextOverflowMode = self.textOverflowControl.selectedSegmentIndex == 0 ? VPKDynamicTextOverflowModeTruncate : VPKDynamicTextOverflowModeMarquee;
    options.clearsAfterFinish = self.clearsSwitch.isOn;
    return options;
}

- (void)prepareTapped {
    [self cancelOperation];
    NSUInteger generation = self.operationGeneration;
    self.stateLabel.text = @"PREPARING";
    [self appendCategory:@"ACTION" message:@"prepare"];
    __weak typeof(self) weakSelf = self;
    [self.playerView prepareWithURL:self.fixture.url options:[self currentOptions] completion:^(VPKAssetMetadata *metadata, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self.operationGeneration != generation) {
            return;
        }
        if (metadata != nil) {
            [self displayMetadata:metadata];
            self.stateLabel.text = @"READY";
            [self appendCategory:@"PASS" message:@"prepare completed"];
        } else {
            self.stateLabel.text = @"FAILED";
            [self appendCategory:@"ERROR" message:error.localizedDescription ?: @"prepare failed"];
        }
    }];
}

- (void)playTapped {
    [self cancelOperation];
    self.stateLabel.text = @"PREPARING";
    [self appendCategory:@"ACTION" message:@"play"];
    [self.playerView playWithURL:self.fixture.url options:[self currentOptions]];
}

- (void)pauseTapped {
    [self.playerView pause];
    self.stateLabel.text = @"PAUSED";
    [self appendCategory:@"ACTION" message:@"pause"];
}

- (void)resumeTapped {
    [self.playerView resume];
    self.stateLabel.text = @"PLAYING";
    [self appendCategory:@"ACTION" message:@"resume"];
}

- (void)stopTapped {
    [self cancelOperation];
    [self.playerView stop];
    self.stateLabel.text = @"STOPPED";
    [self appendCategory:@"ACTION" message:@"stop"];
}

- (void)clearTapped {
    [self cancelOperation];
    [self.playerView clear];
    self.stateLabel.text = @"CLEARED";
    [self appendCategory:@"ACTION" message:@"clear"];
}

- (void)autoTestTapped {
    [self cancelOperation];
    self.isAutomatedRun = YES;
    [self runAutomatedSmokeTestWithGeneration:self.operationGeneration];
}

- (void)runAutomatedSmokeTestWithGeneration:(NSUInteger)generation {
    [self appendCategory:@"TEST" message:@"automated smoke test started"];
    [self.playerView clear];
    __weak typeof(self) weakSelf = self;
    [self.playerView prepareWithURL:self.fixture.url options:[self currentOptions] completion:^(VPKAssetMetadata *metadata, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self.operationGeneration != generation) {
            return;
        }
        if (metadata == nil) {
            if (!self.fixture.looksLikeMedia) {
                self.stateLabel.text = @"EXPECTED FAIL";
                [self appendCategory:@"PASS" message:[NSString stringWithFormat:@"negative fixture rejected: %@", error.localizedDescription]];
            } else {
                self.stateLabel.text = @"TEST FAILED";
                [self appendCategory:@"ERROR" message:[NSString stringWithFormat:@"prepare: %@", error.localizedDescription]];
            }
            [self finishAutomatedRun];
            return;
        }
        [self displayMetadata:metadata];
        if (metadata.frameCount <= 0 || metadata.duration <= 0 || metadata.canvasSize.width <= 0 || metadata.canvasSize.height <= 0) {
            self.stateLabel.text = @"TEST FAILED";
            [self appendCategory:@"ERROR" message:@"Metadata invariants failed."];
            [self finishAutomatedRun];
            return;
        }
        [self appendCategory:@"PASS" message:@"metadata invariants"];
        [self runSmokeCaseAtIndex:0 generation:generation];
    }];
}

- (void)runSmokeCaseAtIndex:(NSInteger)index generation:(NSUInteger)generation {
    if (self.operationGeneration != generation) {
        return;
    }
    NSArray<NSDictionary *> *modes = @[
        @{ @"title": @"AspectFit", @"mode": @(UIViewContentModeScaleAspectFit) },
        @{ @"title": @"AspectFill", @"mode": @(UIViewContentModeScaleAspectFill) },
        @{ @"title": @"ScaleToFill", @"mode": @(UIViewContentModeScaleToFill) }
    ];
    if (index >= (NSInteger)modes.count) {
        [self.playerView clear];
        self.stateLabel.text = @"TEST PASSED";
        [self appendCategory:@"PASS" message:@"all smoke cases completed"];
        [self finishAutomatedRun];
        return;
    }

    NSDictionary *mode = modes[index];
    [self appendCategory:@"TEST" message:[NSString stringWithFormat:@"case %ld: %@", (long)(index + 1), mode[@"title"]]];
    self.currentDidStart = NO;
    self.currentFailure = nil;
    self.currentFinishReason = nil;
    VPKAudioMode audio = (index == (NSInteger)modes.count - 1 && self.currentMetadata.containsAudio) ? VPKAudioModeEmbedded : VPKAudioModeMuted;
    VPKPlaybackOptions *options = [self currentOptionsWithContentMode:[mode[@"mode"] integerValue] audioMode:audio];
    options.loopCount = 0;
    options.clearsAfterFinish = NO;

    __weak typeof(self) weakSelf = self;
    [self.playerView prepareWithURL:self.fixture.url options:options completion:^(VPKAssetMetadata *metadata, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (self == nil || self.operationGeneration != generation) {
            return;
        }
        if (metadata == nil) {
            [self appendCategory:@"ERROR" message:[NSString stringWithFormat:@"%@: %@", mode[@"title"], error.localizedDescription]];
            self.stateLabel.text = @"TEST FAILED";
            [self finishAutomatedRun];
            return;
        }
        [self.playerView playWithURL:self.fixture.url options:options];
        [self waitUntil:^BOOL {
            return self.currentDidStart;
        } failure:^NSError * {
            return self.currentFailure;
        } timeout:3 generation:generation completion:^(NSError *waitError) {
            __strong typeof(weakSelf) self = weakSelf;
            if (self == nil || self.operationGeneration != generation) {
                return;
            }
            if (waitError != nil) {
                [self appendCategory:@"ERROR" message:[NSString stringWithFormat:@"%@: %@", mode[@"title"], waitError.localizedDescription]];
                self.stateLabel.text = @"TEST FAILED";
                [self finishAutomatedRun];
                return;
            }
            [self.playerView pause];
            self.stateLabel.text = @"PAUSED";
            [self appendCategory:@"TEST" message:@"pause"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (self == nil || self.operationGeneration != generation) {
                    return;
                }
                [self.playerView resume];
                self.stateLabel.text = @"PLAYING";
                [self appendCategory:@"TEST" message:@"resume"];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) self = weakSelf;
                    if (self == nil || self.operationGeneration != generation) {
                        return;
                    }
                    if (self.currentFailure != nil) {
                        [self appendCategory:@"ERROR" message:[NSString stringWithFormat:@"%@: %@", mode[@"title"], self.currentFailure.localizedDescription]];
                        self.stateLabel.text = @"TEST FAILED";
                        [self finishAutomatedRun];
                        return;
                    }
                    [self.playerView stop];
                    [self waitUntil:^BOOL {
                        return self.currentFinishReason != nil && self.currentFinishReason.integerValue == VPKFinishReasonStopped;
                    } failure:^NSError * {
                        return self.currentFailure;
                    } timeout:3 generation:generation completion:^(NSError *stopError) {
                        __strong typeof(weakSelf) self = weakSelf;
                        if (self == nil || self.operationGeneration != generation) {
                            return;
                        }
                        if (stopError != nil || self.currentFinishReason.integerValue != VPKFinishReasonStopped) {
                            [self appendCategory:@"ERROR" message:[NSString stringWithFormat:@"%@: Stop did not emit the stopped terminal callback.", mode[@"title"]]];
                            self.stateLabel.text = @"TEST FAILED";
                            [self finishAutomatedRun];
                            return;
                        }
                        [self appendCategory:@"PASS" message:[NSString stringWithFormat:@"%@ lifecycle", mode[@"title"]]];
                        [self runSmokeCaseAtIndex:index + 1 generation:generation];
                    }];
                });
            });
        }];
    }];
}

- (void)waitUntil:(BOOL (^)(void))predicate
          failure:(NSError * (^)(void))failure
          timeout:(NSTimeInterval)timeout
       generation:(NSUInteger)generation
       completion:(void (^)(NSError * _Nullable error))completion {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    [self pollUntil:predicate failure:failure deadline:deadline generation:generation completion:completion];
}

- (void)pollUntil:(BOOL (^)(void))predicate
          failure:(NSError * (^)(void))failure
         deadline:(NSTimeInterval)deadline
       generation:(NSUInteger)generation
       completion:(void (^)(NSError * _Nullable error))completion {
    if (self.operationGeneration != generation) {
        return;
    }
    NSError *currentFailure = failure();
    if (currentFailure != nil) {
        completion(currentFailure);
        return;
    }
    if (predicate()) {
        completion(nil);
        return;
    }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        NSError *timeout = [NSError errorWithDomain:@"ObjectiveCExample" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"Playback did not start before timeout."
        }];
        completion(timeout);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pollUntil:predicate failure:failure deadline:deadline generation:generation completion:completion];
    });
}

- (void)cancelOperation {
    self.operationGeneration += 1;
    self.isAutomatedRun = NO;
}

- (void)finishAutomatedRun {
    self.isAutomatedRun = NO;
    [self persistReport];
}

- (void)displayMetadata:(VPKAssetMetadata *)metadata {
    self.currentMetadata = metadata;
    self.metadataLabel.text = [NSString stringWithFormat:
                               @"%@ · codec %@ · vapc v%ld · %ld frames · %.3fs\nencoded %.0f×%.0f · canvas %.0f×%.0f · alpha %@\naudio %@ · dynamic %lu",
                               metadata.isVAP ? @"VAP" : @"普通视频",
                               metadata.codec,
                               (long)metadata.vapVersion,
                               (long)metadata.frameCount,
                               metadata.duration,
                               metadata.encodedVideoSize.width,
                               metadata.encodedVideoSize.height,
                               metadata.canvasSize.width,
                               metadata.canvasSize.height,
                               VPKAlphaModeName(metadata.alphaMode),
                               metadata.containsAudio ? @"yes" : @"no",
                               (unsigned long)metadata.dynamicSources.count];
}

- (void)shareReport {
    UIActivityViewController *controller = [[UIActivityViewController alloc] initWithActivityItems:@[[self reportText]] applicationActivities:nil];
    controller.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    [self presentViewController:controller animated:YES completion:nil];
}

- (NSString *)reportText {
    return [NSString stringWithFormat:
            @"VAPPlayerKit Device Test Report\n"
            @"===============================\n"
            @"Date: %@\n"
            @"Device: %@ / %@\n"
            @"System: %@ %@\n"
            @"Fixture: %@\n"
            @"Size: %@\n\n"
            @"%@\n\n"
            @"Timeline\n"
            @"--------\n"
            @"%@",
            [[[NSISO8601DateFormatter alloc] init] stringFromDate:[NSDate date]],
            UIDevice.currentDevice.name,
            UIDevice.currentDevice.model,
            UIDevice.currentDevice.systemName,
            UIDevice.currentDevice.systemVersion,
            self.fixture.fileName,
            self.fixture.formattedSize,
            self.metadataLabel.text ?: @"Metadata 尚未解析",
            [self.logLines componentsJoinedByString:@"\n"]];
}

- (NSURL *)persistReport {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSString *prefix = self.fixture.identifier.length > 10 ? [self.fixture.identifier substringToIndex:10] : self.fixture.identifier;
    NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"VAPPlayerKit-%@-report.txt", prefix]];
    NSError *error = nil;
    [[self reportText] writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (error != nil) {
        [self appendCategory:@"REPORT" message:[NSString stringWithFormat:@"write failed: %@", error.localizedDescription]];
        return nil;
    }
    return url;
}

- (void)appendCategory:(NSString *)category message:(NSString *)message {
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.startedAt;
    [self.logLines addObject:[NSString stringWithFormat:@"[%7.3f] %-7@ %@", elapsed, category, message]];
    if (self.logLines.count > 300) {
        [self.logLines removeObjectsInRange:NSMakeRange(0, self.logLines.count - 300)];
    }
    self.consoleView.text = [[self.logLines subarrayWithRange:NSMakeRange(MAX(0, (NSInteger)self.logLines.count - 120), MIN(120, self.logLines.count))] componentsJoinedByString:@"\n"];
    if (self.consoleView.text.length > 0) {
        NSRange range = NSMakeRange(self.consoleView.text.length - 1, 1);
        [self.consoleView scrollRangeToVisible:range];
    }
}

- (UIView *)makeCardWithTitle:(NSString *)title rows:(NSArray<UIView *> *)rows {
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = title;
    titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    titleLabel.textColor = UIColor.whiteColor;
    NSMutableArray<UIView *> *arranged = [NSMutableArray arrayWithObject:titleLabel];
    [arranged addObjectsFromArray:rows];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:arranged];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.12 alpha:1];
    card.layer.cornerRadius = 18;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16]
    ]];
    return card;
}

- (UIView *)makeOptionRowWithTitle:(NSString *)title control:(UIView *)control {
    UILabel *label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentCenter;
    [control setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    return stack;
}

- (UIView *)makeButtonRow:(NSArray<UIButton *> *)buttons {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:buttons];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 10;
    return row;
}

- (UIButton *)makeButtonWithTitle:(NSString *)title
                             icon:(NSString *)icon
                           action:(SEL)action
                       identifier:(NSString *)identifier
                        prominent:(BOOL)prominent {
    UIButtonConfiguration *configuration = prominent ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:icon];
    configuration.imagePadding = 7;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseBackgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:0.72 alpha:1];
    configuration.baseForegroundColor = UIColor.whiteColor;
    UIButton *button = [UIButton buttonWithConfiguration:configuration primaryAction:nil];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    button.accessibilityIdentifier = identifier;
    return button;
}

- (void)playerViewDidStart:(VPKPlayerView *)playerView {
    self.currentDidStart = YES;
    self.stateLabel.text = @"PLAYING";
    [self appendCategory:@"CALLBACK" message:@"didStart"];
}

- (void)playerView:(VPKPlayerView *)playerView didResolveMetadata:(VPKAssetMetadata *)metadata {
    [self displayMetadata:metadata];
    [self appendCategory:@"CALLBACK" message:@"metadata resolved"];
}

- (void)playerView:(VPKPlayerView *)playerView didFinishWithReason:(VPKFinishReason)reason {
    self.currentFinishReason = @(reason);
    self.stateLabel.text = @"FINISHED";
    [self appendCategory:@"CALLBACK" message:[NSString stringWithFormat:@"finish: %@", VPKFinishReasonName(reason)]];
}

- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error {
    self.currentFailure = error;
    self.stateLabel.text = self.fixture.looksLikeMedia ? @"FAILED" : @"EXPECTED FAIL";
    [self appendCategory:self.fixture.looksLikeMedia ? @"ERROR" : @"PASS" message:error.localizedDescription];
}

- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable, NSString * _Nullable, NSError * _Nullable))completion {
    [self appendCategory:@"DYNAMIC" message:[NSString stringWithFormat:@"resolve %@ (%@), %ldx%ld",
                                             tag,
                                             source.kind == VPKDynamicSourceKindText ? @"txt" : @"img",
                                             (long)source.slotSize.width,
                                             (long)source.slotSize.height]];
    [GiftCatalog resolveSource:source completion:completion];
}

@end

@implementation CheckerboardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.opaque = YES;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGFloat side = 18;
    NSInteger rows = (NSInteger)ceil(rect.size.height / side);
    NSInteger columns = (NSInteger)ceil(rect.size.width / side);
    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger column = 0; column < columns; column++) {
            BOOL light = ((row + column) % 2) == 0;
            [(light ? [UIColor colorWithWhite:0.16 alpha:1] : [UIColor colorWithWhite:0.11 alpha:1]) setFill];
            UIRectFill(CGRectMake(column * side, row * side, side, side));
        }
    }
}

@end

@implementation InsetsLabel

- (void)drawTextInRect:(CGRect)rect {
    UIEdgeInsets insets = UIEdgeInsetsMake(5, 9, 5, 9);
    [super drawTextInRect:UIEdgeInsetsInsetRect(rect, insets)];
}

- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 18, size.height + 10);
}

@end
