#import "ViewController.h"

#import "BatchTestViewController.h"
#import "FixtureCatalog.h"
#import "GiftCatalog.h"
#import "PlaybackDetailViewController.h"

@import VAPPlayerKitObjC;

@interface PaddingLabel : UILabel
@end

@interface FixtureCell : UITableViewCell <VPKPlayerDelegate, VPKDynamicContentProvider>
@property (nonatomic, class, readonly) NSString *reuseIdentifier;
- (void)configureWithFixture:(VAPFixture *)fixture index:(NSInteger)index;
- (void)startPreview;
- (void)stopPreview;
@end

@interface ViewController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, copy) NSArray<VAPFixture *> *fixtures;
@property (nonatomic, copy) NSArray<VAPFixture *> *filteredFixtures;
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.fixtures = @[];
    self.filteredFixtures = @[];
    [self configureAppearance];
    [self configureTableView];
    [self configureSearch];
    [self reloadFixtures];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:[FixtureCell class]]) {
            [(FixtureCell *)cell startPreview];
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell isKindOfClass:[FixtureCell class]]) {
            [(FixtureCell *)cell stopPreview];
        }
    }
}

- (void)configureAppearance {
    self.title = @"VAP Gallery";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:0.47 green:0.84 blue:1 alpha:1];
    self.view.backgroundColor = [UIColor colorWithRed:0.035 green:0.045 blue:0.075 alpha:1];

    UIBarButtonItem *reload = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
                                                               style:UIBarButtonItemStylePlain
                                                              target:self
                                                              action:@selector(reloadFixtures)];
    reload.accessibilityIdentifier = @"catalog.reload";
    UIBarButtonItem *batch = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.seal"]
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(runBatchTest)];
    batch.accessibilityIdentifier = @"catalog.batchTest";
    self.navigationItem.rightBarButtonItems = @[reload, batch];
}

- (void)configureTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.backgroundColor = UIColor.clearColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 118;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.tableView registerClass:[FixtureCell class] forCellReuseIdentifier:FixtureCell.reuseIdentifier];
    self.tableView.accessibilityIdentifier = @"catalog.list";
    [self.view addSubview:self.tableView];
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)configureSearch {
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"搜索文件 Hash";
    self.searchController.searchResultsUpdater = self;
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)reloadFixtures {
    self.fixtures = [FixtureCatalog scan];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray arrayWithCapacity:self.fixtures.count];
    for (VAPFixture *fixture in self.fixtures) {
        [identifiers addObject:fixture.identifier];
    }
    self.tableView.accessibilityValue = [identifiers componentsJoinedByString:@","];
    [self applyFilter:self.searchController.searchBar.text];
}

- (void)runBatchTest {
    BatchTestViewController *controller = [[BatchTestViewController alloc] initWithFixtures:self.fixtures];
    [self.navigationController pushViewController:controller animated:YES];
}

- (void)applyFilter:(NSString *)query {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) {
        self.filteredFixtures = self.fixtures;
    } else {
        NSMutableArray<VAPFixture *> *filtered = [NSMutableArray array];
        for (VAPFixture *fixture in self.fixtures) {
            if ([fixture.fileName localizedCaseInsensitiveContainsString:trimmed]) {
                [filtered addObject:fixture];
            }
        }
        self.filteredFixtures = filtered;
    }
    [self.tableView reloadData];
    [self updateBackground];
}

- (void)updateBackground {
    if (self.filteredFixtures.count > 0) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [[UILabel alloc] init];
    label.text = self.fixtures.count == 0
        ? @"未在 App Bundle/VAP 中发现 MP4\n请检查 Copy Bundle Resources"
        : @"没有匹配的资源";
    label.textColor = UIColor.secondaryLabelColor;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    label.accessibilityIdentifier = @"catalog.empty";
    self.tableView.backgroundView = label;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredFixtures.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return [NSString stringWithFormat:@"已扫描 %lu 个资源 · 当前显示 %lu 个",
            (unsigned long)self.fixtures.count,
            (unsigned long)self.filteredFixtures.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    FixtureCell *cell = [tableView dequeueReusableCellWithIdentifier:FixtureCell.reuseIdentifier forIndexPath:indexPath];
    VAPFixture *fixture = self.filteredFixtures[indexPath.row];
    NSUInteger index = [self.fixtures indexOfObject:fixture];
    if (index == NSNotFound) {
        index = (NSUInteger)indexPath.row;
    }
    [cell configureWithFixture:fixture index:(NSInteger)index];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    PlaybackDetailViewController *detail = [[PlaybackDetailViewController alloc] initWithFixture:self.filteredFixtures[indexPath.row]];
    [self.navigationController pushViewController:detail animated:YES];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:[FixtureCell class]]) {
        [(FixtureCell *)cell startPreview];
    }
}

- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([cell isKindOfClass:[FixtureCell class]]) {
        [(FixtureCell *)cell stopPreview];
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter:searchController.searchBar.text];
}

@end

@implementation PaddingLabel

- (CGSize)intrinsicContentSize {
    CGSize size = [super intrinsicContentSize];
    return CGSizeMake(size.width + 12, size.height + 4);
}

@end

@interface FixtureCell ()
@property (nonatomic, strong) UIView *card;
@property (nonatomic, strong) VPKPlayerView *previewView;
@property (nonatomic, strong) UILabel *indexLabel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) PaddingLabel *sizeLabel;
@property (nonatomic, strong) UIImageView *stateImage;
@property (nonatomic, strong, nullable) VAPFixture *fixture;
@property (nonatomic, assign) BOOL isPreviewActive;
@end

@implementation FixtureCell

+ (NSString *)reuseIdentifier {
    return @"FixtureCell";
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _card = [[UIView alloc] init];
        _card.translatesAutoresizingMaskIntoConstraints = NO;
        _card.backgroundColor = [UIColor colorWithRed:0.075 green:0.09 blue:0.14 alpha:1];
        _card.layer.cornerRadius = 18;
        _card.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:_card];

        _previewView = [[VPKPlayerView alloc] initWithFrame:CGRectZero];
        _previewView.translatesAutoresizingMaskIntoConstraints = NO;
        _previewView.backgroundColor = [UIColor colorWithWhite:0.025 alpha:0.8];
        _previewView.layer.cornerRadius = 14;
        _previewView.clipsToBounds = YES;
        _previewView.userInteractionEnabled = NO;
        _previewView.isAccessibilityElement = YES;
        _previewView.delegate = self;
        _previewView.dynamicContentProvider = self;
        [_card addSubview:_previewView];

        _indexLabel = [[UILabel alloc] init];
        _indexLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
        _indexLabel.textColor = [UIColor colorWithRed:0.42 green:0.82 blue:1 alpha:1];
        _indexLabel.textAlignment = NSTextAlignmentCenter;
        _indexLabel.backgroundColor = [UIColor colorWithRed:0.11 green:0.22 blue:0.31 alpha:1];
        _indexLabel.layer.cornerRadius = 7;
        _indexLabel.clipsToBounds = YES;

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        _subtitleLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1];
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

        _sizeLabel = [[PaddingLabel alloc] init];
        _sizeLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold];
        _sizeLabel.textColor = [UIColor colorWithRed:0.54 green:0.9 blue:0.75 alpha:1];
        _sizeLabel.backgroundColor = [UIColor colorWithRed:0.08 green:0.22 blue:0.17 alpha:1];
        _sizeLabel.layer.cornerRadius = 8;
        _sizeLabel.clipsToBounds = YES;

        _stateImage = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        _stateImage.tintColor = [UIColor colorWithWhite:0.45 alpha:1];

        for (UIView *view in @[_indexLabel, _titleLabel, _subtitleLabel, _sizeLabel, _stateImage]) {
            view.translatesAutoresizingMaskIntoConstraints = NO;
            [_card addSubview:view];
        }

        [NSLayoutConstraint activateConstraints:@[
            [_card.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:5],
            [_card.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-5],
            [_card.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
            [_card.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [_previewView.leadingAnchor constraintEqualToAnchor:_card.leadingAnchor constant:8],
            [_previewView.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor],
            [_previewView.widthAnchor constraintEqualToConstant:92],
            [_previewView.heightAnchor constraintEqualToConstant:92],
            [_indexLabel.leadingAnchor constraintEqualToAnchor:_previewView.leadingAnchor constant:5],
            [_indexLabel.topAnchor constraintEqualToAnchor:_previewView.topAnchor constant:5],
            [_indexLabel.widthAnchor constraintEqualToConstant:28],
            [_indexLabel.heightAnchor constraintEqualToConstant:20],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:_previewView.trailingAnchor constant:14],
            [_titleLabel.topAnchor constraintEqualToAnchor:_card.topAnchor constant:17],
            [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_stateImage.leadingAnchor constant:-10],
            [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:5],
            [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_stateImage.leadingAnchor constant:-10],
            [_sizeLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_sizeLabel.topAnchor constraintEqualToAnchor:_subtitleLabel.bottomAnchor constant:7],
            [_sizeLabel.heightAnchor constraintEqualToConstant:20],
            [_stateImage.trailingAnchor constraintEqualToAnchor:_card.trailingAnchor constant:-16],
            [_stateImage.centerYAnchor constraintEqualToAnchor:_card.centerYAnchor]
        ]];
    }
    return self;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.fixture = nil;
    self.isPreviewActive = NO;
    [self.previewView clear];
    self.previewView.accessibilityValue = @"idle";
}

- (void)configureWithFixture:(VAPFixture *)fixture index:(NSInteger)index {
    [self stopPreview];
    self.fixture = fixture;
    self.indexLabel.text = [NSString stringWithFormat:@"%02ld", (long)(index + 1)];
    self.titleLabel.text = fixture.looksLikeMedia ? @"VAP 动画资源" : @"损坏资源（负向样例）";
    self.subtitleLabel.text = fixture.shortIdentifier;
    self.sizeLabel.text = [NSString stringWithFormat:@"  %@  ", fixture.formattedSize];
    self.accessibilityIdentifier = [NSString stringWithFormat:@"catalog.item.%ld", (long)index];
    self.accessibilityLabel = [NSString stringWithFormat:@"资源 %ld，%@，%@",
                               (long)(index + 1),
                               fixture.formattedSize,
                               fixture.shortIdentifier];
    self.previewView.accessibilityIdentifier = [NSString stringWithFormat:@"catalog.preview.%ld", (long)index];
    self.previewView.accessibilityValue = fixture.looksLikeMedia ? @"idle" : @"invalid";
}

- (void)startPreview {
    if (self.isPreviewActive || self.fixture == nil || !self.fixture.looksLikeMedia) {
        return;
    }
    self.isPreviewActive = YES;
    VPKPlaybackOptions *options = VPKPlaybackOptions.defaultOptions;
    options.loopCount = 0;
    options.clearsAfterFinish = NO;
    options.contentMode = UIViewContentModeScaleAspectFit;
    self.previewView.accessibilityValue = @"preparing";
    [self.previewView playWithURL:self.fixture.url options:options];
}

- (void)stopPreview {
    self.isPreviewActive = NO;
    [self.previewView stop];
    if (self.fixture.looksLikeMedia) {
        self.previewView.accessibilityValue = @"idle";
    }
}

- (void)playerViewDidStart:(VPKPlayerView *)playerView {
    self.previewView.accessibilityValue = @"playing";
}

- (void)playerView:(VPKPlayerView *)playerView didResolveMetadata:(VPKAssetMetadata *)metadata {
}

- (void)playerView:(VPKPlayerView *)playerView didFinishWithReason:(VPKFinishReason)reason {
    self.previewView.accessibilityValue = @"finished";
}

- (void)playerView:(VPKPlayerView *)playerView didFailWithError:(NSError *)error {
    self.previewView.accessibilityValue = @"failed";
}

- (void)resolveTag:(NSString *)tag
            source:(VPKSourceMetadata *)source
        completion:(void (^)(UIImage * _Nullable, NSString * _Nullable, NSError * _Nullable))completion {
    [GiftCatalog resolveSource:source completion:completion];
}

@end
