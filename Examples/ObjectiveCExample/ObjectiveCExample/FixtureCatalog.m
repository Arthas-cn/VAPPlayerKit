#import "FixtureCatalog.h"

@implementation VAPFixture

- (instancetype)initWithURL:(NSURL *)url byteCount:(int64_t)byteCount {
    self = [super init];
    if (self) {
        _url = url;
        _byteCount = byteCount;
    }
    return self;
}

- (NSString *)fileName {
    return self.url.lastPathComponent;
}

- (NSString *)identifier {
    return self.url.URLByDeletingPathExtension.lastPathComponent;
}

- (NSString *)shortIdentifier {
    NSString *value = self.identifier;
    if (value.length <= 18) {
        return value;
    }
    return [NSString stringWithFormat:@"%@…%@",
            [value substringToIndex:10],
            [value substringFromIndex:value.length - 6]];
}

- (NSString *)formattedSize {
    NSByteCountFormatter *formatter = [[NSByteCountFormatter alloc] init];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    return [formatter stringFromByteCount:self.byteCount];
}

- (BOOL)looksLikeMedia {
    static NSSet<NSString *> *expectedNegativeNames;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expectedNegativeNames = [NSSet setWithObjects:@"2.mp4", @"9.mp4", @"u1.mp4", @"u2.mp4", @"u3.mp4", nil];
    });
    return ![expectedNegativeNames containsObject:self.fileName];
}

- (NSInteger)numericID {
    NSScanner *scanner = [NSScanner scannerWithString:self.identifier];
    NSInteger value = 0;
    if ([scanner scanInteger:&value] && scanner.isAtEnd) {
        return value;
    }
    return NSIntegerMax;
}

- (BOOL)isEqual:(id)object {
    if (self == object) {
        return YES;
    }
    if (![object isKindOfClass:[VAPFixture class]]) {
        return NO;
    }
    VAPFixture *other = object;
    return [self.url.URLByStandardizingPath.path isEqualToString:other.url.URLByStandardizingPath.path];
}

- (NSUInteger)hash {
    return self.url.URLByStandardizingPath.path.hash;
}

@end

@implementation FixtureCatalog

+ (NSArray<VAPFixture *> *)scan {
    return [self scanInBundle:NSBundle.mainBundle];
}

+ (NSArray<VAPFixture *> *)scanInBundle:(NSBundle *)bundle {
    NSMutableArray<NSURL *> *candidates = [[bundle URLsForResourcesWithExtension:@"mp4" subdirectory:@"VAP"] mutableCopy];
    if (candidates == nil) {
        candidates = [NSMutableArray array];
    }

    // Folder references normally preserve VAP/, while some Xcode configurations flatten resources.
    if (candidates.count == 0 && bundle.resourceURL != nil) {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:bundle.resourceURL
                                                               includingPropertiesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey]
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                             errorHandler:nil];
        for (NSURL *url in enumerator) {
            if ([url.pathExtension.lowercaseString isEqualToString:@"mp4"]) {
                [candidates addObject:url];
            }
        }
    }

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<VAPFixture *> *fixtures = [NSMutableArray array];
    for (NSURL *url in candidates) {
        NSString *key = url.URLByStandardizingPath.path;
        if (key.length == 0 || [seen containsObject:key]) {
            continue;
        }
        [seen addObject:key];
        NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:@[NSURLIsRegularFileKey, NSURLFileSizeKey] error:nil];
        NSNumber *isRegular = values[NSURLIsRegularFileKey];
        if (isRegular != nil && !isRegular.boolValue) {
            continue;
        }
        int64_t byteCount = [values[NSURLFileSizeKey] longLongValue];
        [fixtures addObject:[[VAPFixture alloc] initWithURL:url byteCount:byteCount]];
    }

    [fixtures sortUsingComparator:^NSComparisonResult(VAPFixture *lhs, VAPFixture *rhs) {
        if (lhs.numericID != rhs.numericID) {
            return lhs.numericID < rhs.numericID ? NSOrderedAscending : NSOrderedDescending;
        }
        return [lhs.fileName localizedStandardCompare:rhs.fileName];
    }];
    return [fixtures copy];
}

@end
