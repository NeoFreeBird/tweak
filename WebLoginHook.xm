//
//  WebLoginHook.xm
//  NeoFreeBird Web Login Integration
//
//  Add this code to your Tweak.x file to enable web login
//

#import "WebLoginViewController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// ============================================
// MARK: - Helper Functions
// ============================================

static void injectWebCookies(NSArray<NSHTTPCookie *> *cookies) {
    NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
    
    for (NSHTTPCookie *cookie in cookies) {
        [cookieStorage setCookie:cookie];
        NSLog(@"[WebLogin] Injected cookie: %@ = %@", cookie.name, cookie.value);
    }
    
    [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"WebLoginCompleted"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSLog(@"[WebLogin] All cookies injected successfully!");
}

static void spoofUserAgentForRequests() {
    // Swizzle NSURLRequest to add web User-Agent
    NSString *webUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
    
    NSDictionary *dictionary = @{@"UserAgent": webUserAgent};
    [[NSUserDefaults standardUserDefaults] registerDefaults:dictionary];
    
    NSLog(@"[WebLogin] User-Agent spoofed to web browser");
}

// ============================================
// MARK: - Login Flow Hooks
// ============================================

// Hook the login view controller to redirect to web login
%hook UIViewController

%new
- (void)presentWebLogin {
    NSLog(@"[WebLogin] Presenting web login interface...");
    
    WebLoginViewController *webLoginVC = [[WebLoginViewController alloc] initWithCompletionHandler:^(NSDictionary *authData, NSError *error) {
        if (error) {
            NSLog(@"[WebLogin] Error: %@", error.localizedDescription);
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Login Cancelled" 
                                                                           message:@"Web login was cancelled" 
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            
            UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            [topVC presentViewController:alert animated:YES completion:nil];
            
        } else if (authData) {
            NSLog(@"[WebLogin] Login successful! Processing auth data...");
            
            // Inject cookies
            NSArray *cookies = authData[@"cookies"];
            if (cookies) {
                injectWebCookies(cookies);
            }
            
            // Spoof User-Agent for future requests
            spoofUserAgentForRequests();
            
            // Show success message
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Login Successful" 
                                                                           message:@"You are now logged in via web authentication. Please restart the app." 
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"Restart Now" 
                                                      style:UIAlertActionStyleDefault 
                                                    handler:^(UIAlertAction *action) {
                exit(0); // Restart app to apply changes
            }]];
            
            UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            [topVC presentViewController:alert animated:YES completion:nil];
        }
    }];
    
    UINavigationController *navController = [[UINavigationController alloc] initWithRootViewController:webLoginVC];
    navController.modalPresentationStyle = UIModalPresentationFullScreen;
    
    [self presentViewController:navController animated:YES completion:nil];
}

%end

// ============================================
// MARK: - Network Request Hooks
// ============================================

// Hook NSURLSession to modify User-Agent for all Twitter API requests
%hook NSURLSessionConfiguration

+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *config = %orig;
    
    // Check if web login was used
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WebLoginCompleted"]) {
        NSMutableDictionary *headers = [config.HTTPAdditionalHeaders mutableCopy] ?: [NSMutableDictionary dictionary];
        
        // Add web User-Agent
        headers[@"User-Agent"] = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
        
        config.HTTPAdditionalHeaders = headers;
        
        NSLog(@"[WebLogin] Modified session config with web User-Agent");
    }
    
    return config;
}

%end

// ============================================
// MARK: - Login Button Hook
// ============================================

// Try to hook common Twitter login button classes
// You may need to adjust these class names based on the actual Twitter app structure

%hook UIButton

- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    // Detect login button tap
    NSString *currentTitle = self.currentTitle;
    NSString *actionString = NSStringFromSelector(action);
    
    // Check if this is likely a login button
    if ([currentTitle containsString:@"Log in"] || 
        [currentTitle containsString:@"Sign in"] ||
        [actionString containsString:@"login"] ||
        [actionString containsString:@"signIn"]) {
        
        NSLog(@"[WebLogin] Login button detected: %@ - %@", currentTitle, actionString);
        
        // Show alert to choose login method
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Choose Login Method" 
                                                                       message:@"Select how you want to log in" 
                                                                preferredStyle:UIAlertControllerStyleAlert];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Web Login (Recommended)" 
                                                  style:UIAlertActionStyleDefault 
                                                handler:^(UIAlertAction *action) {
            // Use web login
            UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
            while (topVC.presentedViewController) {
                topVC = topVC.presentedViewController;
            }
            [topVC presentWebLogin];
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Native Login (May Fail)" 
                                                  style:UIAlertActionStyleDestructive 
                                                handler:^(UIAlertAction *action) {
            // Continue with original action
            %orig;
        }]];
        
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" 
                                                  style:UIAlertActionStyleCancel 
                                                handler:nil]];
        
        UIViewController *topVC = [UIApplication sharedApplication].keyWindow.rootViewController;
        while (topVC.presentedViewController) {
            topVC = topVC.presentedViewController;
        }
        [topVC presentViewController:alert animated:YES completion:nil];
        
        return; // Don't call original
    }
    
    // For non-login buttons, proceed normally
    %orig;
}

%end

// ============================================
// MARK: - Attestation Bypass Hooks
// ============================================

// Hook potential attestation check methods
// These are speculative and may need adjustment based on actual Twitter app

%hook NSObject

// Bypass any method containing "attestation" in its name
- (id)performSelector:(SEL)aSelector {
    NSString *selectorName = NSStringFromSelector(aSelector);
    
    if ([selectorName containsString:@"attestation"] || 
        [selectorName containsString:@"Attestation"]) {
        
        NSLog(@"[WebLogin] Bypassing attestation check: %@", selectorName);
        
        // Return success/bypass value
        // Adjust return value based on what the method expects
        return nil; // or @YES, @NO, depending on context
    }
    
    return %orig;
}

%end

// ============================================
// MARK: - Settings Integration (Optional)
// ============================================

%hook UITableView

- (void)reloadData {
    %orig;
    
    // You can add a "Use Web Login" button in settings here
    // This is optional and depends on your UI preferences
}

%end

// ============================================
// MARK: - Constructor
// ============================================

%ctor {
    NSLog(@"[WebLogin] NeoFreeBird Web Login Hook initialized");
    
    // Spoof User-Agent on startup if web login was previously used
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"WebLoginCompleted"]) {
        spoofUserAgentForRequests();
        NSLog(@"[WebLogin] Web login session detected, User-Agent spoofed");
    }
}
