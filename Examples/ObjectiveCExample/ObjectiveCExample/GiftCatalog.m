#import "GiftCatalog.h"

@implementation GiftCatalog

+ (NSString *)replacementText {
    return @"ObjC VAP Test";
}

+ (void)resolveSource:(VPKSourceMetadata *)source
           completion:(void (^)(UIImage * _Nullable, NSString * _Nullable, NSError * _Nullable))completion {
    if (source.kind == VPKDynamicSourceKindText) {
        completion(nil, self.replacementText, nil);
        return;
    }
    completion([self imageForSource:source], nil, nil);
}

+ (UIImage *)imageForSource:(VPKSourceMetadata *)source {
    UIImage *gift = [self randomImage];
    if (gift != nil) {
        return gift;
    }
    return [self placeholderWithSize:source.slotSize tag:source.tag];
}

+ (UIImage *)randomImage {
    return [self randomImageInBundle:NSBundle.mainBundle];
}

+ (UIImage *)randomImageInBundle:(NSBundle *)bundle {
    NSArray<NSURL *> *urls = [self imageURLsInBundle:bundle];
    if (urls.count == 0) {
        return nil;
    }
    NSURL *url = urls[arc4random_uniform((uint32_t)urls.count)];
    return [UIImage imageWithContentsOfFile:url.path];
}

+ (NSArray<NSURL *> *)imageURLsInBundle:(NSBundle *)bundle {
    NSMutableArray<NSURL *> *candidates = [[bundle URLsForResourcesWithExtension:@"png" subdirectory:@"Gifts"] mutableCopy];
    if (candidates == nil) {
        candidates = [NSMutableArray array];
    }
    if (candidates.count == 0 && bundle.resourceURL != nil) {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:bundle.resourceURL
                                                               includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                             errorHandler:nil];
        for (NSURL *url in enumerator) {
            if ([url.pathExtension.lowercaseString isEqualToString:@"png"]) {
                [candidates addObject:url];
            }
        }
    }

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NSMutableArray<NSURL *> *unique = [NSMutableArray array];
    for (NSURL *url in candidates) {
        NSString *key = url.URLByStandardizingPath.path;
        if (key.length == 0 || [seen containsObject:key]) {
            continue;
        }
        [seen addObject:key];
        [unique addObject:url];
    }
    return [unique copy];
}

+ (UIImage *)placeholderWithSize:(CGSize)size tag:(NSString *)tag {
    CGSize safeSize = CGSizeMake(MAX(1, size.width), MAX(1, size.height));
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:safeSize];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGColorRef colors[] = {
            [UIColor colorWithRed:0.15 green:0.55 blue:0.95 alpha:1].CGColor,
            [UIColor colorWithRed:0.52 green:0.22 blue:0.92 alpha:1].CGColor
        };
        CFArrayRef colorArray = CFArrayCreate(NULL, (const void **)colors, 2, &kCFTypeArrayCallBacks);
        CGFloat locations[] = { 0, 1 };
        CGGradientRef gradient = CGGradientCreateWithColors(colorSpace, colorArray, locations);
        if (gradient != NULL) {
            CGContextDrawLinearGradient(context.CGContext,
                                        gradient,
                                        CGPointZero,
                                        CGPointMake(safeSize.width, safeSize.height),
                                        0);
            CGGradientRelease(gradient);
        }
        CFRelease(colorArray);
        CGColorSpaceRelease(colorSpace);

        NSString *symbol = tag.length > 0 ? [[tag substringToIndex:1] uppercaseString] : @"?";
        UIFont *font = [UIFont boldSystemFontOfSize:MIN(safeSize.width, safeSize.height) * 0.42];
        NSDictionary *attributes = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: UIColor.whiteColor
        };
        CGSize measured = [symbol sizeWithAttributes:attributes];
        CGPoint origin = CGPointMake((safeSize.width - measured.width) / 2.0,
                                     (safeSize.height - measured.height) / 2.0);
        [symbol drawAtPoint:origin withAttributes:attributes];
    }];
}

@end
