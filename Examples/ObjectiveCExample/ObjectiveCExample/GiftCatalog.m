#import "GiftCatalog.h"

#import <ImageIO/ImageIO.h>

@implementation GiftCatalog

+ (NSSet<NSString *> *)imageExtensions {
    return [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"gif", @"webp", nil];
}

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
    NSMutableArray<NSURL *> *urls = [[self imageURLsInBundle:bundle] mutableCopy];
    while (urls.count > 0) {
        NSUInteger index = arc4random_uniform((uint32_t)urls.count);
        NSURL *url = urls[index];
        [urls removeObjectAtIndex:index];
        UIImage *image = [self imageAtURL:url];
        if (image != nil) {
            return image;
        }
    }
    return nil;
}

+ (NSArray<NSURL *> *)imageURLsInBundle:(NSBundle *)bundle {
    NSMutableArray<NSURL *> *candidates = [NSMutableArray array];
    NSURL *giftsURL = [bundle URLForResource:@"Gifts" withExtension:nil];
    if (giftsURL != nil) {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:giftsURL
                                                               includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                             errorHandler:nil];
        for (NSURL *url in enumerator) {
            if ([self.imageExtensions containsObject:url.pathExtension.lowercaseString]) {
                [candidates addObject:url];
            }
        }
    }

    if (candidates.count == 0) {
        for (NSString *fileExtension in self.imageExtensions) {
            NSArray<NSURL *> *matches = [bundle URLsForResourcesWithExtension:fileExtension subdirectory:@"Gifts"];
            if (matches.count > 0) {
                [candidates addObjectsFromArray:matches];
            }
        }
    }

    if (candidates.count == 0 && bundle.resourceURL != nil) {
        NSDirectoryEnumerator *enumerator = [NSFileManager.defaultManager enumeratorAtURL:bundle.resourceURL
                                                               includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                                                                                  options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                             errorHandler:nil];
        for (NSURL *url in enumerator) {
            if ([self.imageExtensions containsObject:url.pathExtension.lowercaseString]) {
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

+ (UIImage *)imageAtURL:(NSURL *)url {
    // Demo 不引入 SDWebImage，GIF / WebP 只取首帧静图，与 Swift Demo 对照。
    UIImage *image = [UIImage imageWithContentsOfFile:url.path];
    if (image.size.width > 0 && image.size.height > 0) {
        return image;
    }
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (source == NULL) {
        return nil;
    }
    CGImageRef cgImage = NULL;
    if (CGImageSourceGetCount(source) > 0) {
        cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    }
    CFRelease(source);
    if (cgImage == NULL) {
        return nil;
    }
    UIImage *decoded = [UIImage imageWithCGImage:cgImage];
    CGImageRelease(cgImage);
    return decoded;
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
