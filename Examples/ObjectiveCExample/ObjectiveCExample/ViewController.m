#import "ViewController.h"

@interface ViewController ()
@property (nonatomic, strong) VPKPlayerView *playerView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *playButton;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;

    self.playerView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
    self.playerView.delegate = self;
    self.playerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.playerView];

    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.text = @"VAPPlayerKit Objective-C Example";
    self.statusLabel.textColor = UIColor.whiteColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playButton setTitle:@"Play Fixture" forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playFixture) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.playButton];

    [NSLayoutConstraint activateConstraints:@[
        [self.playerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.playerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.playerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.playerView.bottomAnchor constraintEqualToAnchor:self.playButton.topAnchor constant:-16],
        [self.playButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.playButton.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-12],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16]
    ]];
}

- (void)playFixture {
    // 与 Tests/Fixtures/README.md 中的默认 Demo 文件一致。
    NSString *name = @"18";
    NSURL *url = [[NSBundle mainBundle] URLForResource:name withExtension:@"mp4" subdirectory:@"VAP"];
    if (url == nil) {
        self.statusLabel.text = @"Missing Tests/Fixtures/VAP in app bundle";
        return;
    }
    self.statusLabel.text = url.lastPathComponent;
    [self.playerView playWithURL:url options:VPKPlaybackOptions.defaultOptions];
}

- (void)playerViewDidStart:(VPKPlayerView *)playerView {
    self.statusLabel.text = @"Started";
}

- (void)playerView:(VPKPlayerView *)playerView didResolveMetadata:(VPKAssetMetadata *)metadata {
    self.statusLabel.text = [NSString stringWithFormat:@"Metadata %@", metadata.codec];
}

- (void)playerView:(VPKPlayerView *)playerView didFinishWithReason:(VPKFinishReason)reason {
    self.statusLabel.text = @"Finished";
}

- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error {
    self.statusLabel.text = error.localizedDescription;
}

@end
