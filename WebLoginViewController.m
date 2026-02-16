//
//  WebLoginViewController.m
//  NeoFreeBird Web Login Fix
//
//  This controller uses WKWebView to load the x.com login page
//  and extract authentication tokens to bypass attestation checks
//

#import "WebLoginViewController.h"
#import <objc/runtime.h>

@implementation WebLoginViewController

- (instancetype)initWithCompletionHandler:(void (^)(NSDictionary *authData, NSError *error))completion {
    self = [super init];
    if (self) {
        _completionHandler = completion;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Web Login";
    
    // Add cancel button
    UIBarButtonItem *cancelButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel 
                                                                                   target:self 
                                                                                   action:@selector(cancelLogin)];
    self.navigationItem.leftBarButtonItem = cancelButton;
    
    // Setup WebView
    [self setupWebView];
    
    // Start login
    [self startWebLogin];
}

- (void)setupWebView {
    // Configure WebView with custom User-Agent to appear as Safari
    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    
    // Add script message handler to detect login success
    WKUserContentController *contentController = [[WKUserContentController alloc] init];
    [contentController addScriptMessageHandler:self name:@"loginHandler"];
    
    // Inject JavaScript to detect successful login
    NSString *jsCode = @"window.addEventListener('load', function() {"
                       @"  setTimeout(function() {"
                       @"    if (window.location.href.indexOf('/home') !== -1 || "
                       @"        document.querySelector('[data-testid=\"SideNav_AccountSwitcher_Button\"]') !== null) {"
                       @"      window.webkit.messageHandlers.loginHandler.postMessage('success');"
                       @"    }"
                       @"  }, 2000);"
                       @"});";
    
    WKUserScript *script = [[WKUserScript alloc] initWithSource:jsCode 
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentEnd 
                                               forMainFrameOnly:NO];
    [contentController addUserScript:script];
    
    configuration.userContentController = contentController;
    
    // Allow JavaScript
    configuration.preferences.javaScriptEnabled = YES;
    
    // Create WebView
    self.webView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    // Set custom User-Agent to appear as Safari/Web browser
    self.webView.customUserAgent = @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
    
    [self.view addSubview:self.webView];
}

- (void)startWebLogin {
    // Load X.com login page
    NSURL *loginURL = [NSURL URLWithString:@"https://x.com/i/flow/login"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:loginURL];
    
    // Set headers to appear as web browser
    [request setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"https://x.com" forHTTPHeaderField:@"Referer"];
    
    [self.webView loadRequest:request];
}

#pragma mark - WKScriptMessageHandler

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"loginHandler"] && [message.body isEqualToString:@"success"]) {
        NSLog(@"[WebLogin] Login detected as successful!");
        [self extractAuthenticationData];
    }
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"[WebLogin] Page loaded: %@", webView.URL.absoluteString);
    
    // Check if we're on home page (successful login)
    if ([webView.URL.absoluteString containsString:@"/home"] || 
        [webView.URL.absoluteString containsString:@"/compose"]) {
        [self extractAuthenticationData];
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSLog(@"[WebLogin] Navigation to: %@", url.absoluteString);
    
    // Allow all navigation
    decisionHandler(WKNavigationActionPolicyAllow);
}

#pragma mark - Authentication Extraction

- (void)extractAuthenticationData {
    NSLog(@"[WebLogin] Extracting authentication data...");
    
    WKHTTPCookieStore *cookieStore = self.webView.configuration.websiteDataStore.httpCookieStore;
    
    [cookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        NSMutableDictionary *authData = [NSMutableDictionary dictionary];
        NSMutableArray *cookieArray = [NSMutableArray array];
        
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.domain containsString:@"twitter.com"] || [cookie.domain containsString:@"x.com"]) {
                [cookieArray addObject:cookie];
                
                // Store important auth tokens
                if ([cookie.name isEqualToString:@"auth_token"]) {
                    authData[@"auth_token"] = cookie.value;
                }
                if ([cookie.name isEqualToString:@"ct0"]) {
                    authData[@"csrf_token"] = cookie.value;
                }
                if ([cookie.name isEqualToString:@"twid"]) {
                    authData[@"user_id"] = cookie.value;
                }
            }
        }
        
        authData[@"cookies"] = cookieArray;
        authData[@"user_agent"] = self.webView.customUserAgent;
        
        NSLog(@"[WebLogin] Extracted %lu cookies", (unsigned long)cookieArray.count);
        NSLog(@"[WebLogin] Auth token: %@", authData[@"auth_token"] ? @"✓" : @"✗");
        NSLog(@"[WebLogin] CSRF token: %@", authData[@"csrf_token"] ? @"✓" : @"✗");
        
        // Call completion handler
        dispatch_async(dispatch_get_main_queue(), ^{
            if (authData[@"auth_token"] && authData[@"csrf_token"]) {
                if (self.completionHandler) {
                    self.completionHandler(authData, nil);
                }
                [self dismissViewControllerAnimated:YES completion:nil];
            } else {
                NSLog(@"[WebLogin] Warning: Missing required tokens");
                // Continue monitoring for tokens
            }
        });
    }];
}

- (void)cancelLogin {
    if (self.completionHandler) {
        NSError *error = [NSError errorWithDomain:@"WebLoginError" 
                                             code:-1 
                                         userInfo:@{NSLocalizedDescriptionKey: @"User cancelled login"}];
        self.completionHandler(nil, error);
    }
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
