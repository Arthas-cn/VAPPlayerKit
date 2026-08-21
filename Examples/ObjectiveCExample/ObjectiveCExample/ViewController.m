#import "ViewController.h"

@interface ViewController ()
@property (nonatomic, strong) VPKPlayerView *playerView;
@property (nonatomic, strong) UILabel *statusLabel;
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
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.statusLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.playerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.playerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.playerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.playerView.bottomAnchor constraintEqualToAnchor:self.statusLabel.topAnchor constant:-16],
        [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.statusLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [self.statusLabel.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16]
    ]];
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
