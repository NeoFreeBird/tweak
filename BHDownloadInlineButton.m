//
//  BHDownloadInlineButton.m
//  NeoFreeBird
//
//  Original author: BandarHelal at 09/04/2022
//  Modified by: actuallyaridan at 27/04/2025
//

#import "BHDownloadInlineButton.h"
#import <objc/runtime.h>
#import "BHTBundle/BHTBundle.h"

#pragma mark - Helpers
static inline UIViewController *BHTopMostController(void) {
    UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    return top;
}

#pragma mark - BHDownloadInlineButton
@interface BHDownloadInlineButton () <BHDownloadDelegate>
@property (nonatomic, strong) JGProgressHUD *hud;
@end

@implementation BHDownloadInlineButton

#pragma mark ••• Download handler
- (void)presentDownloadOptionsForMediaEntities:(NSArray *)mediaEntities {
    @try {
        NSAttributedString *titleString = [[NSAttributedString alloc] initWithString:[[BHTBundle sharedBundle] localizedStringForKey:@"DOWNLOAD_MENU_TITLE"]
                                                                         attributes:@{ NSFontAttributeName : [BHTManager menuTitleFont],
                                                                                       NSForegroundColorAttributeName : UIColor.labelColor }];
        TFNActiveTextItem *title = [[objc_getClass("TFNActiveTextItem") alloc] initWithTextModel:[[objc_getClass("TFNAttributedTextModel") alloc] initWithAttributedString:titleString] activeRanges:nil];

        NSMutableArray *actions      = [NSMutableArray arrayWithObject:title];
        NSMutableArray *innerActions = [NSMutableArray arrayWithObject:title];

        // HUD helpers
        void (^startHUD)(NSString *) = ^(NSString *key) {
            if ([BHTManager DirectSave]) return;
            self.hud = [JGProgressHUD progressHUDWithStyle:JGProgressHUDStyleDark];
            self.hud.textLabel.text = [[BHTBundle sharedBundle] localizedStringForKey:key];
            [self.hud showInView:BHTopMostController().view];
        };
        void (^dismissHUD)(void) = ^{ [self.hud dismiss]; };

        // Variant builders
        TFNActionItem* (^makeMP4Item)(NSURL *) = ^TFNActionItem*(NSURL *url) {
            return [objc_getClass("TFNActionItem") actionItemWithTitle:[BHTManager getVideoQuality:url.absoluteString]
                                                               imageName:@"arrow_down_circle_stroke" action:^{
                BHDownload *dwManager = [[BHDownload alloc] init];
                [dwManager setDelegate:self];
                [dwManager downloadFileWithURL:url];
                startHUD(@"PROGRESS_DOWNLOADING_STATUS_TITLE");
            }];
        };

        TFNActionItem* (^makeM3U8Item)(NSURL *) = ^TFNActionItem*(NSURL *url) {
            return [objc_getClass("TFNActionItem") actionItemWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"FFMPEG_DOWNLOAD_OPTION_TITLE"]
                                                               imageName:@"arrow_down_circle_stroke" action:^{
                startHUD(@"FETCHING_PROGRESS_TITLE");
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    MediaInformation *info = [BHTManager getM3U8Information:url];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        dismissHUD();
                        TFNMenuSheetViewController *sheet = [BHTManager newFFmpegDownloadSheet:info downloadingURL:url progressView:self.hud];
                        [sheet tfnPresentedCustomPresentFromViewController:BHTopMostController() animated:YES completion:nil];
                    });
                });
            }];
        };

        // Media enumeration
        if (mediaEntities.count > 1) {
            [mediaEntities enumerateObjectsUsingBlock:^(TFSTwitterEntityMedia *obj, NSUInteger idx, BOOL *stop) {
                if (obj.mediaType == 2 || obj.mediaType == 3) {
                    TFNActionItem *videoGroup = [objc_getClass("TFNActionItem") actionItemWithTitle:[NSString stringWithFormat:@"Video %lu", (unsigned long)idx + 1]
                                                                                       imageName:@"arrow_down_circle_stroke" action:^{
                        for (TFSTwitterEntityMediaVideoVariant *variant in obj.videoInfo.variants) {
                            if ([variant.contentType isEqualToString:@"video/mp4"])          [innerActions addObject:makeMP4Item([NSURL URLWithString:variant.url])];
                            if ([variant.contentType isEqualToString:@"application/x-mpegURL"]) [innerActions addObject:makeM3U8Item([NSURL URLWithString:variant.url])];
                        }
                        TFNMenuSheetViewController *inner = [[objc_getClass("TFNMenuSheetViewController") alloc] initWithActionItems:innerActions.copy];
                        [inner tfnPresentedCustomPresentFromViewController:BHTopMostController() animated:YES completion:nil];
                    }];
                    [actions addObject:videoGroup];
                }
            }];
        } else if (mediaEntities.firstObject) {
            TFSTwitterEntityMedia *first = mediaEntities.firstObject;
            for (TFSTwitterEntityMediaVideoVariant *variant in first.videoInfo.variants) {
                if ([variant.contentType isEqualToString:@"video/mp4"])          [actions addObject:makeMP4Item([NSURL URLWithString:variant.url])];
                if ([variant.contentType isEqualToString:@"application/x-mpegURL"]) [actions addObject:makeM3U8Item([NSURL URLWithString:variant.url])];
            }
        }

        TFNMenuSheetViewController *sheet = [[objc_getClass("TFNMenuSheetViewController") alloc] initWithActionItems:actions.copy];
        [sheet tfnPresentedCustomPresentFromViewController:BHTopMostController() animated:YES completion:nil];
    } @catch (__unused NSException *ex) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"ERROR_TITLE"]
                                                                       message:[[BHTBundle sharedBundle] localizedStringForKey:@"UNKNOWN_ERROR"]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"OK_BUTTON"] style:UIAlertActionStyleDefault handler:nil]];
        [BHTopMostController() presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark ••• BHDownloadDelegate
- (void)downloadProgress:(float)pct {
    self.hud.detailTextLabel.text = [BHTManager getDownloadingPersent:pct];
}

- (void)downloadDidFinish:(NSURL *)tmpURL Filename:(NSString *)name {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSURL *dst = [[NSURL fileURLWithPath:doc]
                  URLByAppendingPathComponent:[NSString stringWithFormat:@"%@.mp4", NSUUID.UUID.UUIDString]];

    [[NSFileManager defaultManager] moveItemAtURL:tmpURL toURL:dst error:nil];

    if (![BHTManager DirectSave]) {
        [self.hud dismiss];
        [BHTManager showSaveVC:dst];
    } else {
        if (@available(iOS 10.0, *)) {
            UINotificationFeedbackGenerator *g = [UINotificationFeedbackGenerator new];
            [g prepare];
            [g notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
        [BHTManager save:dst];
    }
}

- (void)downloadDidFailureWithError:(NSError *)error {
    [self.hud dismiss];
    if (!error) return;

    UIAlertController *a = [UIAlertController alertControllerWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"ERROR_TITLE"]
                                                               message:error.localizedDescription
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:[[BHTBundle sharedBundle] localizedStringForKey:@"OK_BUTTON"]
                                          style:UIAlertActionStyleDefault
                                        handler:nil]];
    [BHTopMostController() presentViewController:a animated:YES completion:nil];

    if (@available(iOS 10.0, *)) {
        UINotificationFeedbackGenerator *g = [UINotificationFeedbackGenerator new];
        [g prepare];
        [g notificationOccurred:UINotificationFeedbackTypeError];
    }
}

@end
