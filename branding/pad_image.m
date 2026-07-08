// pad_image: resize <src> to exactly <W>x<H> preserving aspect ratio, centering
// the image on a transparent canvas (letterbox/pillarbox) rather than stretching.
// Used by build_merged_car.py's master resize so a square logo dropped in as a
// master (e.g. a launch image) is padded, not distorted, into non-square slots.
//
// usage: pad_image <src> <W> <H> <out.png>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 5) { fprintf(stderr, "usage: pad_image <src> <W> <H> <out.png>\n"); return 2; }
    int W = atoi(argv[2]), H = atoi(argv[3]);
    if (W <= 0 || H <= 0) { fprintf(stderr, "bad dimensions\n"); return 2; }

    CGImageSourceRef src = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], NULL);
    if (!src) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) { fprintf(stderr, "cannot decode %s\n", argv[1]); return 1; }

    size_t iw = CGImageGetWidth(img), ih = CGImageGetHeight(img);
    double scale = fmin((double)W / iw, (double)H / ih);  // fit inside, keep aspect
    double dw = iw * scale, dh = ih * scale;
    CGRect dst = CGRectMake((W - dw) / 2.0, (H - dh) / 2.0, dw, dh);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { CGImageRelease(img); fprintf(stderr, "context failed\n"); return 1; }
    CGContextClearRect(ctx, CGRectMake(0, 0, W, H));  // transparent background
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, dst, img);

    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dstImg = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[4])], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dstImg, out, NULL);
    bool ok = CGImageDestinationFinalize(dstImg);
    CFRelease(dstImg); CGImageRelease(out); CGContextRelease(ctx); CGImageRelease(img);
    return ok ? 0 : 1;
  }
}
