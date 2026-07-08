// car_extract: dump bitmap renditions of a compiled .car to PNGs + JSON manifest.
// Uses private CoreUI. Manifest lets build_merged_car.py match pixels to
// assetutil's rendition list by (renditionName, scale, width, height).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

@interface CUIRenditionKey : NSObject
- (void *)keyList;
- (long long)themeScale;
- (long long)themeIdiom;
- (long long)themeDisplayGamut;
- (long long)themeAppearance;
@end

@interface CUIThemeRendition : NSObject
- (CGImageRef)unslicedImage;
@end

@interface CUIStructuredThemeStore : NSObject
- (CUIThemeRendition *)renditionWithKey:(void *)key;
- (NSString *)renditionNameForKeyList:(void *)keyList;
@end

@interface CUICommonAssetStorage : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (NSArray *)allAssetKeys;
- (NSString *)renditionNameForKeyList:(void *)keyList;
@end

@interface CUICatalog : NSObject
- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error;
- (id)_themeStore;
@end

static BOOL writePNG(CGImageRef img, NSString *path) {
  CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:path];
  CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
  if (!dst) return NO;
  CGImageDestinationAddImage(dst, img, NULL);
  BOOL ok = CGImageDestinationFinalize(dst);
  CFRelease(dst);
  return ok;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 3) { fprintf(stderr, "usage: car_extract <Assets.car> <outdir>\n"); return 2; }
    NSString *carPath = @(argv[1]);
    NSString *outDir  = @(argv[2]);
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSError *err = nil;
    CUICatalog *cat = [[CUICatalog alloc] initWithURL:[NSURL fileURLWithPath:carPath] error:&err];
    if (!cat) { fprintf(stderr, "open failed: %s\n", err.description.UTF8String); return 1; }
    CUIStructuredThemeStore *store = [cat _themeStore];
    CUICommonAssetStorage *storage = [[CUICommonAssetStorage alloc] initWithPath:carPath];

    NSMutableArray *manifest = [NSMutableArray array];
    int idx = 0;
    for (CUIRenditionKey *key in [storage allAssetKeys]) {
      CUIThemeRendition *rend = [store renditionWithKey:[key keyList]];
      if (!rend) continue;
      CGImageRef img = [rend unslicedImage];
      if (!img) continue;                 // non-bitmap (color/vector/data) -> skip
      NSString *rname = [storage renditionNameForKeyList:[key keyList]];
      NSString *file = [NSString stringWithFormat:@"r%04d.png", idx++];
      if (!writePNG(img, [outDir stringByAppendingPathComponent:file])) continue;
      [manifest addObject:@{
        @"file": file,
        @"renditionName": rname ?: @"",
        @"scale": @([key themeScale]),
        @"idiom": @([key themeIdiom]),
        @"gamut": @([key themeDisplayGamut]),
        @"appearance": @([key themeAppearance]),
        @"width": @(CGImageGetWidth(img)),
        @"height": @(CGImageGetHeight(img)),
      }];
    }
    NSData *j = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:nil];
    [j writeToFile:[outDir stringByAppendingPathComponent:@"manifest.json"] atomically:YES];
    fprintf(stderr, "extracted %lu bitmap renditions\n", (unsigned long)manifest.count);
  }
  return 0;
}
