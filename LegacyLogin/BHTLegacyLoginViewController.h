#import <UIKit/UIKit.h>

// Reimplementation of 9.67's built-in xAuth login form for 11.99.
@interface BHTLegacyLoginViewController : UIViewController
+ (void)presentLoginFrom:(UIViewController *)presenter;

+ (UINavigationController *)loginRootNavigationController;
@end
