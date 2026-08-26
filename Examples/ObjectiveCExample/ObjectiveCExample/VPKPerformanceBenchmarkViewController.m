#import "VPKPerformanceBenchmarkViewController.h"

#import "VPKPlayerView.h"

// Keep this benchmark translation unit on the stable ObjC compatibility
// headers. Importing ObjectiveCExample-Swift.h here makes Clang see the same
// VPK* declarations from both VAPPlayerKitObjC and the generated Swift module,
// which newer Xcodes reject as cross-module definition mismatches.
@class VPKMetricsProbe;
@class VPKBenchmarkDynamicProvider;

@interface VPKMetricsProbe : NSObject
- (void)attachTo:(VPKPlayerView *)playerView;
- (void)reset;
- (void)beginOperation;
@property (nonatomic, readonly) double prepareMilliseconds;
@property (nonatomic, readonly) double operationToPrepareMilliseconds;
@property (nonatomic, readonly) double firstFrameMilliseconds;
@property (nonatomic, readonly) double operationToFirstFrameMilliseconds;
@property (nonatomic, readonly) NSInteger decodedFrameCount;
@property (nonatomic, readonly) NSInteger renderedFrameCount;
@property (nonatomic, readonly) NSInteger droppedFrameCount;
@property (nonatomic, readonly) NSInteger drawableFailureCount;
@property (nonatomic, readonly) NSInteger decoderRebuildCount;
@property (nonatomic, readonly) NSInteger dynamicTimeoutCount;
@property (nonatomic, readonly) NSInteger sessionFinishedCount;
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *prepareStageMilliseconds;
@end

@interface VPKBenchmarkDynamicProvider : NSObject <VPKDynamicContentProvider>
@end

@interface VPKPlayerView (VPKBenchmarkSwiftBridge)
@property (nonatomic, weak) id<VPKDynamicContentProvider> objcDynamicProvider;
@end

static NSTimeInterval const VPKBenchmarkWindow = 2.0;
static NSUInteger const VPKBenchmarkRunCount = 5;

@interface VPKPerformanceBenchmarkViewController () <VPKPlayerDelegate>
@property (nonatomic, strong) VPKPlayerView *playerView;
@property (nonatomic, strong) VPKMetricsProbe *probe;
@property (nonatomic, strong) VPKBenchmarkDynamicProvider *dynamicProvider;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) NSURL *assetURL;
@property (nonatomic, copy) NSArray<NSString *> *assetNames;
@property (nonatomic, assign) NSUInteger assetIndex;
@property (nonatomic, copy) NSArray<NSDictionary *> *samples;
@property (nonatomic, strong, nullable) NSError *currentError;
@property (nonatomic, assign) BOOL allAssetsPassed;
@property (nonatomic, assign) BOOL started;
@end

@implementation VPKPerformanceBenchmarkViewController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
        _probe = [[VPKMetricsProbe alloc] init];
        _dynamicProvider = [[VPKBenchmarkDynamicProvider alloc] init];
        _assetNames = @[];
        _samples = @[];
        _allAssetsPassed = YES;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"VAP 性能基准";
    self.view.backgroundColor = [UIColor colorWithRed:0.03 green:0.04 blue:0.065 alpha:1];
    self.playerView.delegate = self;
    self.playerView.objcDynamicProvider = self.dynamicProvider;
    [self.probe attachTo:self.playerView];
    [self configureUI];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.started) return;
    self.started = YES;
    [self startBenchmark];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isMovingFromParentViewController) [self.playerView stop];
}

- (void)configureUI {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [self.view addSubview:stack];

    self.stateLabel = [[UILabel alloc] init];
    self.stateLabel.text = @"WAITING";
    self.stateLabel.font = [UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightBold];
    self.stateLabel.textColor = [UIColor colorWithRed:0.48 green:0.84 blue:1 alpha:1];
    self.stateLabel.textAlignment = NSTextAlignmentCenter;
    self.stateLabel.numberOfLines = 0;
    self.stateLabel.accessibilityIdentifier = @"benchmark.result";

    self.playerView.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
    self.playerView.layer.cornerRadius = 18;
    self.playerView.clipsToBounds = YES;
    [self.playerView.heightAnchor constraintEqualToConstant:220].active = YES;

    self.logView = [[UITextView alloc] init];
    self.logView.backgroundColor = [UIColor colorWithRed:0.02 green:0.025 blue:0.04 alpha:1];
    self.logView.textColor = [UIColor colorWithWhite:0.78 alpha:1];
    self.logView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    self.logView.editable = NO;
    self.logView.layer.cornerRadius = 14;
    self.logView.accessibilityIdentifier = @"benchmark.log";

    [stack addArrangedSubview:self.stateLabel];
    [stack addArrangedSubview:self.playerView];
    [stack addArrangedSubview:self.logView];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16]
    ]];
}

- (void)startBenchmark {
    NSArray<NSString *> *allAssets = @[@"demo.mp4", @"1.mp4"];
    NSString *requestedAsset = nil;
    NSString *argumentPrefix = @"--vap-performance-asset=";
    for (NSString *argument in NSProcessInfo.processInfo.arguments) {
        if ([argument hasPrefix:argumentPrefix]) {
            requestedAsset = [argument substringFromIndex:argumentPrefix.length];
            break;
        }
    }
    self.assetNames = requestedAsset.length ? @[requestedAsset] : allAssets;
    self.assetIndex = 0;
    self.allAssetsPassed = YES;
    self.stateLabel.text = @"RUNNING";
    [self appendLine:[NSString stringWithFormat:@"player=VAPPlayerKit device=%@ iOS=%@",
                      UIDevice.currentDevice.model, UIDevice.currentDevice.systemVersion]];
    [self appendLine:[NSString stringWithFormat:@"assets=%@ window=%.1fs runs=%lu",
                      [self.assetNames componentsJoinedByString:@","], VPKBenchmarkWindow,
                      (unsigned long)VPKBenchmarkRunCount]];
    // Let the first layout pass publish a non-zero CAMetalLayer drawable size.
    // Starting from viewDidAppear synchronously can otherwise produce a
    // false cold sample on a freshly launched process.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self startAssetAtIndex:0];
    });
}

- (void)startAssetAtIndex:(NSUInteger)assetIndex {
    if (assetIndex >= self.assetNames.count) {
        self.stateLabel.text = [NSString stringWithFormat:@"%@\nassets=%lu/%lu",
                                self.allAssetsPassed ? @"BENCHMARK PASS" : @"BENCHMARK FAILED",
                                (unsigned long)self.assetNames.count,
                                (unsigned long)self.assetNames.count];
        [self appendLine:[NSString stringWithFormat:@"status=%@ assets=%lu/%lu",
                          self.allAssetsPassed ? @"PASS" : @"FAIL",
                          (unsigned long)self.assetNames.count,
                          (unsigned long)self.assetNames.count]];
        return;
    }
    self.assetIndex = assetIndex;
    NSString *assetName = self.assetNames[assetIndex];
    NSString *baseName = [assetName stringByDeletingPathExtension];
    self.assetURL = [[NSBundle mainBundle] URLForResource:baseName withExtension:@"mp4"];
    if (!self.assetURL) {
        self.allAssetsPassed = NO;
        [self appendLine:[NSString stringWithFormat:@"asset=%@ error=asset_not_found", assetName]];
        [self startAssetAtIndex:assetIndex + 1];
        return;
    }
    self.samples = @[];
    [self appendLine:[NSString stringWithFormat:@"asset=%@ bytes=%lld window=%.1fs runs=%lu",
                      assetName, [self fileSize], VPKBenchmarkWindow,
                      (unsigned long)VPKBenchmarkRunCount]];
    [self runSampleAtIndex:0];
}

- (void)runSampleAtIndex:(NSUInteger)index {
    if (index >= VPKBenchmarkRunCount) {
        [self finishCurrentAsset];
        return;
    }
    [self.playerView stop];
    [self.probe reset];
    [self.probe beginOperation];
    self.currentError = nil;

    VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
    options.loopCount = 0;
    options.audioMode = VPKAudioModeMuted;
    options.clearsAfterFinish = NO;
    options.backgroundPolicy = VPKBackgroundPolicyStop;
    [self.playerView playWithURL:self.assetURL options:options];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(VPKBenchmarkWindow * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self finishSampleAtIndex:index];
    });
}

- (void)finishSampleAtIndex:(NSUInteger)index {
    NSDictionary *sample = @{
        @"index": @(index + 1),
        @"phase": index == 0 ? @"cold" : @"warm",
        @"prepare_ms": @([self.probe prepareMilliseconds]),
        @"prepare_api_to_ready_ms": @([self.probe operationToPrepareMilliseconds]),
        @"first_frame_ms": @([self.probe firstFrameMilliseconds]),
        @"play_to_first_frame_ms": @([self.probe operationToFirstFrameMilliseconds]),
        @"decoded": @([self.probe decodedFrameCount]),
        @"rendered": @([self.probe renderedFrameCount]),
        @"dropped": @([self.probe droppedFrameCount]),
        @"drawable_failures": @([self.probe drawableFailureCount]),
        @"decoder_rebuilds": @([self.probe decoderRebuildCount]),
        @"dynamic_timeouts": @([self.probe dynamicTimeoutCount]),
        @"session_finished": @([self.probe sessionFinishedCount]),
        @"prepare_stages_ms": self.probe.prepareStageMilliseconds ?: @{},
        @"error": self.currentError.localizedDescription ?: [NSNull null],
        @"valid": @([self.probe renderedFrameCount] > 0 && self.currentError == nil)
    };
    [self.playerView stop];
    self.samples = [self.samples arrayByAddingObject:sample];
    [self appendLine:[NSString stringWithFormat:@"run=%lu phase=%@ prepare=%.2fms first=%.2fms call_to_first=%.2fms decoded=%ld rendered=%ld dropped=%ld drawable_failures=%ld error=%@",
                      (unsigned long)(index + 1), sample[@"phase"],
                      [sample[@"prepare_ms"] doubleValue], [sample[@"first_frame_ms"] doubleValue],
                      [sample[@"play_to_first_frame_ms"] doubleValue],
                      (long)[sample[@"decoded"] integerValue], (long)[sample[@"rendered"] integerValue],
                      (long)[sample[@"dropped"] integerValue],
                      (long)[sample[@"drawable_failures"] integerValue], sample[@"error"]]];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self runSampleAtIndex:index + 1];
    });
}

- (void)finishCurrentAsset {
    BOOL pass = self.samples.count == VPKBenchmarkRunCount;
    for (NSDictionary *sample in self.samples) {
        pass = pass && [sample[@"rendered"] integerValue] > 0;
        pass = pass && [sample[@"drawable_failures"] integerValue] == 0;
        pass = pass && [sample[@"error"] isEqual:[NSNull null]];
    }
    NSDictionary *report = @{
        @"schema": @1,
        @"player": @"VAPPlayerKit",
        @"asset": self.assetURL.lastPathComponent ?: @"",
        @"asset_bytes": @([self fileSize]),
        @"device": UIDevice.currentDevice.model ?: @"",
        @"system": UIDevice.currentDevice.systemVersion ?: @"",
        @"window_seconds": @(VPKBenchmarkWindow),
        @"runs": self.samples ?: @[]
    };
    NSString *prefix = [NSString stringWithFormat:@"VAPPlayerKit-%@",
                        self.assetURL.lastPathComponent.stringByDeletingPathExtension];
    NSString *path = [self writeReport:report prefix:prefix];
    [self appendLine:[NSString stringWithFormat:@"status=%@ report=%@",
                      pass ? @"PASS" : @"FAIL", path]];
    self.allAssetsPassed = self.allAssetsPassed && pass;
    NSUInteger nextAssetIndex = self.assetIndex + 1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self startAssetAtIndex:nextAssetIndex];
    });
}

- (NSArray<NSNumber *> *)sortedValuesForKey:(NSString *)key {
    NSMutableArray<NSNumber *> *values = [NSMutableArray arrayWithCapacity:self.samples.count];
    for (NSDictionary *sample in self.samples) [values addObject:sample[key] ?: @0];
    [values sortUsingSelector:@selector(compare:)];
    return values;
}

- (NSString *)writeReport:(NSDictionary *)report prefix:(NSString *)prefix {
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *url = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.json", prefix, NSProcessInfo.processInfo.globallyUniqueString]];
    [data writeToURL:url atomically:YES];
    return url.path ?: @"";
}

- (long long)fileSize {
    NSDictionary *values = [self.assetURL resourceValuesForKeys:@[NSURLFileSizeKey] error:nil];
    return [values[NSURLFileSizeKey] longLongValue];
}

- (void)appendLine:(NSString *)line {
    NSString *old = self.logView.text ?: @"";
    self.logView.text = old.length ? [old stringByAppendingFormat:@"\n%@", line] : line;
    if (self.logView.text.length) [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length - 1, 1)];
}

- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error {
    if (playerView == self.playerView) self.currentError = error;
}

@end
