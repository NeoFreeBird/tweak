//
//  WebLoginViewController.h
//  NeoFreeBird Web Login Fix
//
//  Created for bypassing X/Twitter attestation checks
//

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

@interface WebLoginViewController : UIViewController <WKNavigationDelegate, WKScriptMessageHandler>

@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy) void (^completionHandler)(NSDictionary *authData, NSError *error);

- (instancetype)initWithCompletionHandler:(void (^)(NSDictionary *authData, NSError *error))completion;
- (void)startWebLogin;

@end
