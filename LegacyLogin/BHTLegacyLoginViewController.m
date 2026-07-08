#import "BHTLegacyLoginViewController.h"
#import "../JGProgressHUD/JGProgressHUD.h"
#import <WebKit/WebKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Password login (no reset), matching 9.67's built-in sign-in:
//   1. Generate ui_metrics from x.com/i/js_inst (anti-bot token).
//   2. xauth_password -> OAuth token directly, or a 2FA challenge
//   3. If 2FA is required, present the app's own T1LoginChallengeWebViewController (via
//      T1LoginChallengeFactory), which loads the 2FA URL and polls xauth_challenge
//      until it returns an account.
//   4. Add the account and switch to it.

typedef void (^BHTCmdCompletion)(BOOL success, id response, id parseError);

typedef id (*BHTPwInitIMP)(id, SEL,
    id context, id accountID, id authContext, id identifier, id password, id simCountryCode,
    id httpConfig, BOOL supportOneFactor, id knownDeviceToken, id uiMetrics, id authTokenStorage,
    id source, id builder, id completion);


#pragma mark - Runtime helpers

static long long BHTUserId(id resp, SEL sel) {
    if (!resp || ![resp respondsToSelector:sel]) {
        return 0;
    }
    return ((long long (*)(id, SEL))objc_msgSend)(resp, sel);
}

static id BHTPerform0(id target, SEL selector) {
    if (!target || ![target respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

// API error 243 ("client not privileged"/too many attempts) is likely rate limiting
// and can be bypassed by switching on a VPN.
static BOOL BHTIsRateLimit(id error) {
    if (![error isKindOfClass:[NSError class]]) {
        return NO;
    }

    NSError *e = error;
    if (e.code == 243) {
        return YES;
    }

    for (id value in [e.userInfo allValues]) {
        if ([value isKindOfClass:[NSNumber class]] && [value integerValue] == 243) {
            return YES;
        }
    }

    return [[e description] rangeOfString:@"243"].location != NSNotFound;
}


#pragma mark - Command / service accessors

static id BHTGuestAccountID(void) {
    void *sym = dlsym(RTLD_DEFAULT, "TFSTwitterAPIGuestAccountID");
    return sym ? (__bridge id)(*(void **)sym) : nil;
}

static id BHTLoader(void) {
    return BHTPerform0(objc_getClass("TFSTwitterServiceRunner"), @selector(APICommandLoader));
}

static id BHTContext(void) {
    return BHTPerform0(objc_getClass("TFSTwitterServiceRunner"), @selector(APICommandContext));
}

static id BHTBuilder(const char *className) {
    Class cls = objc_getClass(className);
    return cls ? [[cls alloc] init] : nil;
}

static id BHTStorage(void) {
    Class cls = objc_getClass("T1OnboardingAuthTokenStorage");
    return cls ? [[cls alloc] init] : nil;
}

static id BHTKnownDeviceToken(void) {
    return BHTPerform0(objc_getClass("TFNTwitterAccount"), @selector(knownDeviceToken));
}

static id BHTHTTPConfig(void) {
    Class cls = objc_getClass("TNUServiceHTTPConfiguration");
    if (!cls) {
        return nil;
    }

    SEL sel = @selector(configurationForForegroundRetriableRequestWithTotalPermittedRetryCount:);
    return ((id (*)(id, SEL, unsigned long long))objc_msgSend)(cls, sel, 10);
}


#pragma mark - Account finalization

static void BHTRegisterAccount(id account) {
    if (!account) {
        return;
    }

    Class twitterCls = objc_getClass("TFNTwitter");
    id shared = BHTPerform0(twitterCls, @selector(sharedTwitter));
    id service = BHTPerform0(shared, @selector(accountService));

    @try {
        if (service && [service respondsToSelector:@selector(addAccount:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(service, @selector(addAccount:), account);
        }

        if ([twitterCls respondsToSelector:@selector(saveSharedTwitter)]) {
            ((void (*)(id, SEL))objc_msgSend)(twitterCls, @selector(saveSharedTwitter));
        }

        if ([account respondsToSelector:@selector(refreshForced:source:)]) {
            ((void (*)(id, SEL, BOOL, unsigned long long))objc_msgSend)(account, @selector(refreshForced:source:), NO, 0);
        }

        Class notifCls = objc_getClass("TFSAccountNotification");
        id name = BHTPerform0(notifCls, @selector(TFSAccountsDidChange));
        if ([name isKindOfClass:[NSString class]]) {
            [[NSNotificationCenter defaultCenter] postNotificationName:name object:shared userInfo:nil];
        }
    } @catch (NSException *ex) {
    }
}

static void BHTSwitchToAccount(id account) {
    id host = BHTPerform0(objc_getClass("T1HostViewController"), @selector(sharedHostViewController));
    if (host && [host respondsToSelector:@selector(viewAccount:animated:)]) {
        ((void (*)(id, SEL, id, BOOL))objc_msgSend)(host, @selector(viewAccount:animated:), account, YES);
    }
}


#pragma mark - ui_metrics injection

// Hooks fetch/XHR/sendBeacon inside the js_inst page and forwards the requested URLs,
// so we can take the anti-bot `result=` token.
static NSString *const kJSInstJS =
    @"(function(){function rep(u){try{window.webkit.messageHandlers.bht.postMessage(String(u));}catch(e){}}"
    @"var of=window.fetch;if(of){window.fetch=function(){try{rep(arguments[0]&&arguments[0].url?arguments[0].url:arguments[0]);}catch(e){}return of.apply(this,arguments);};}"
    @"var oo=XMLHttpRequest.prototype.open;XMLHttpRequest.prototype.open=function(m,u){try{rep(u);}catch(e){}return oo.apply(this,arguments);};"
    @"if(navigator.sendBeacon){var sb=navigator.sendBeacon.bind(navigator);navigator.sendBeacon=function(u,d){try{rep(u);}catch(e){}return sb(u,d);};}})();";


@interface BHTLegacyLoginViewController () <WKNavigationDelegate, WKScriptMessageHandler>

@property (nonatomic, strong) UITextField *userField;
@property (nonatomic, strong) UITextField *passField;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) JGProgressHUD *hud;

@property (nonatomic, strong) WKWebView *instWebView;
@property (nonatomic, copy) NSString *uiMetrics;
@property (nonatomic, copy) void (^metricsCallback)(NSString *);
@property (nonatomic, assign) BOOL metricsDone;

@property (nonatomic, assign) BOOL asRootScreen; // YES when installed as the signed-out screen

@end


@implementation BHTLegacyLoginViewController

#pragma mark - Presentation

+ (BOOL)bht_isOurs:(UIViewController *)vc {
    if ([vc isKindOfClass:[BHTLegacyLoginViewController class]]) {
        return YES;
    }

    if ([vc isKindOfClass:[UINavigationController class]]) {
        id root = ((UINavigationController *)vc).viewControllers.firstObject;
        return [root isKindOfClass:[BHTLegacyLoginViewController class]];
    }

    return NO;
}

+ (void)presentLoginFrom:(UIViewController *)presenter {
    if (!presenter) {
        return;
    }

    // Return if the form is already anywhere in the presentation chain
    for (UIViewController *vc = presenter; vc; vc = vc.presentedViewController) {
        if ([self bht_isOurs:vc]) {
            return;
        }
    }

    while (presenter.presentedViewController) {
        presenter = presenter.presentedViewController;
    }

    BHTLegacyLoginViewController *login = [[BHTLegacyLoginViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:login];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;

    [presenter presentViewController:nav animated:YES completion:nil];
}

+ (UINavigationController *)loginRootNavigationController {
    BHTLegacyLoginViewController *login = [[BHTLegacyLoginViewController alloc] init];
    login.asRootScreen = YES;

    return [[UINavigationController alloc] initWithRootViewController:login];
}

#pragma mark - View setup

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = @"Log in";

    if (!self.asRootScreen) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                          target:self
                                                          action:@selector(cancelTapped)];
    }

    self.infoLabel = [self label:@"Log in with your username and password.\n\nGoogle and Apple sign-in aren't supported. If your account uses one of those, add a password to it first."];

    self.userField = [self field:@"Username, email or phone" secure:NO];
    self.userField.keyboardType = UIKeyboardTypeEmailAddress;
    // Tag the fields so iOS Password AutoFill recognises the form and offers
    // saved logins / the Passwords key in the QuickType bar (the native
    // equivalent of autocomplete=username / current-password on a web form).
    self.userField.textContentType = UITextContentTypeUsername;

    self.passField = [self field:@"Password" secure:YES];
    self.passField.textContentType = UITextContentTypePassword;

    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.actionButton setTitle:@"Log in" forState:UIControlStateNormal];
    self.actionButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.actionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];

    NSArray *fields = @[self.infoLabel, self.userField, self.passField, self.actionButton];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:fields];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-32],
        [self.userField.heightAnchor constraintEqualToConstant:44],
        [self.passField.heightAnchor constraintEqualToConstant:44],
    ]];
}

- (UITextField *)field:(NSString *)placeholder secure:(BOOL)secure {
    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder;
    field.secureTextEntry = secure;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.translatesAutoresizingMaskIntoConstraints = NO;

    return field;
}

- (UILabel *)label:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.numberOfLines = 0;
    label.font = [UIFont systemFontOfSize:14];
    label.textColor = [UIColor secondaryLabelColor];
    label.text = text;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    return label;
}

#pragma mark - Actions

- (void)cancelTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionTapped {
    [self.view endEditing:YES];
    [self startLogin];
}

- (void)showHUD:(NSString *)text {
    self.hud = [JGProgressHUD progressHUDWithStyle:JGProgressHUDStyleDark];
    self.hud.textLabel.text = text;
    [self.hud showInView:self.view];
}

#pragma mark - ui_metrics

- (void)generateUIMetrics:(void (^)(NSString *))then {
    self.uiMetrics = nil;
    self.metricsDone = NO;
    self.metricsCallback = then;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
    [cfg.userContentController addScriptMessageHandler:self name:@"bht"];

    WKUserScript *script = [[WKUserScript alloc] initWithSource:kJSInstJS
                                                 injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                              forMainFrameOnly:NO];
    [cfg.userContentController addUserScript:script];

    self.instWebView = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:cfg];
    self.instWebView.navigationDelegate = self;
    self.instWebView.alpha = 0.02;
    [self.view addSubview:self.instWebView];

    NSURL *url = [NSURL URLWithString:@"https://x.com/i/js_inst?native=true"];
    [self.instWebView loadRequest:[NSURLRequest requestWithURL:url]];

    // Give up after a while so a failed js_inst load can't wedge the login.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self finishMetrics];
    });
}

- (void)finishMetrics {
    if (self.metricsDone) {
        return;
    }
    self.metricsDone = YES;

    [self.instWebView removeFromSuperview];
    self.instWebView = nil;

    void (^cb)(NSString *) = self.metricsCallback;
    self.metricsCallback = nil;

    if (cb) {
        cb(self.uiMetrics);
    }
}

- (void)consumeURL:(NSString *)urlString {
    if (self.uiMetrics || ![urlString containsString:@"result="]) {
        return;
    }

    NSURLComponents *components = [NSURLComponents componentsWithURL:[NSURL URLWithString:urlString]
                                            resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"result"] && item.value.length) {
            self.uiMetrics = item.value;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishMetrics];
            });
            return;
        }
    }
}

- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.body isKindOfClass:[NSString class]]) {
        [self consumeURL:message.body];
    }
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    [self consumeURL:action.request.URL.absoluteString];
    handler(WKNavigationActionPolicyAllow);
}

#pragma mark - Step 1: password

- (void)startLogin {
    NSString *user = self.userField.text ?: @"";
    NSString *pass = self.passField.text ?: @"";
    if (user.length == 0 || pass.length == 0) {
        [self alert:@"Missing input" msg:@"Enter username and password."];
        return;
    }

    [self showHUD:@"Verifying…"];

    [self generateUIMetrics:^(NSString *metrics) {
        self.hud.textLabel.text = @"Signing in…";

        Class cmdCls = objc_getClass("TFSTwitterAPIXAuthPasswordCommand");
        if (!cmdCls || !BHTLoader() || !BHTContext()) {
            [self.hud dismiss];
            [self alert:@"Unavailable" msg:@"Login classes missing."];
            return;
        }

        __weak typeof(self) ws = self;
        BHTCmdCompletion completion = ^(BOOL ok, id resp, id err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [ws handlePassword:ok response:resp error:err];
            });
        };

        @try {
            SEL sel = @selector(initWithContext:accountID:authContext:identifier:password:simCountryCode:httpRequestConfiguration:supportOneFactorAuthorization:knownDeviceToken:uiMetrics:authTokenStorage:source:responseModelBuilder:completionBlock:);
            BHTPwInitIMP imp = (BHTPwInitIMP)objc_msgSend;

            id cmd = imp([cmdCls alloc], sel,
                         BHTContext(), BHTGuestAccountID(), nil, user, pass, nil,
                         BHTHTTPConfig(), NO, BHTKnownDeviceToken(), metrics, BHTStorage(), nil,
                         BHTBuilder("TFSTwitterXAuthPasswordResponseBuilder"), [completion copy]);
            if (!cmd) {
                [self.hud dismiss];
                [self alert:@"Unavailable" msg:@"Could not build command."];
                return;
            }

            ((void (*)(id, SEL, id))objc_msgSend)(BHTLoader(), @selector(startCommand:), cmd);
        } @catch (NSException *ex) {
            [self.hud dismiss];
            [self alert:@"Crash avoided" msg:ex.reason ?: ex.description];
        }
    }];
}

- (void)handlePassword:(BOOL)ok response:(id)resp error:(id)err {
    [self.hud dismiss];

    if (!ok) {
        [self alertError:err title:@"Login failed"];
        return;
    }

    id token = BHTPerform0(resp, @selector(token));
    id secret = BHTPerform0(resp, @selector(tokenSecret));
    if (token && secret) {
        id screenName = BHTPerform0(resp, @selector(screenName)) ?: BHTPerform0(resp, @selector(username));
        [self buildAndAddAccountWithToken:token
                                   secret:secret
                               screenName:screenName
                                   userId:BHTUserId(resp, @selector(userId))];
        return;
    }

    if (!BHTPerform0(resp, @selector(loginVerificationRequestId))) {
        [self alert:@"Unexpected response" msg:@"No token and no challenge."];
        return;
    }

    [self presentChallengeForResponse:resp];
}

#pragma mark - Step 2: 2FA / login-verification (web challenge)

- (void)presentChallengeForResponse:(id)resp {
    id requestID = BHTPerform0(resp, @selector(loginVerificationRequestId));
    id urlString = BHTPerform0(resp, @selector(challengeURLString));

    long long userID = BHTUserId(resp, @selector(loginVerificationUserId));
    if (!userID) {
        userID = BHTUserId(resp, @selector(userId));
    }

    long long loginType = 0;
    long long cause = 0;
    if ([resp respondsToSelector:@selector(loginVerificationRequestType)]) {
        loginType = ((int (*)(id, SEL))objc_msgSend)(resp, @selector(loginVerificationRequestType));
    }
    if ([resp respondsToSelector:@selector(loginVerificationRequestCause)]) {
        cause = ((int (*)(id, SEL))objc_msgSend)(resp, @selector(loginVerificationRequestCause));
    }

    if (!requestID || !urlString) {
        [self alert:@"Unexpected response" msg:@"Challenge is missing its request id or URL."];
        return;
    }

    BOOL securityKey = NO;
    Class tps = objc_getClass("TPSDeviceFeatureSwitches");
    if (tps && [tps respondsToSelector:@selector(isSecurityKeyAuthEnabled)]) {
        securityKey = ((BOOL (*)(id, SEL))objc_msgSend)(tps, @selector(isSecurityKeyAuthEnabled));
    }

    Class factoryCls = objc_getClass("T1LoginChallengeFactory");
    id host = BHTPerform0(objc_getClass("T1HostViewController"), @selector(sharedHostViewController));
    if (!factoryCls || !host) {
        [self alert:@"Unavailable" msg:@"Challenge/host classes missing."];
        return;
    }

    @try {
        SEL sel = @selector(loginChallengeWithMode:loginType:requestID:user:userID:URLString:loginCause:);
        id (*imp)(id, SEL, long long, long long, id, id, long long, id, long long) =
            (id (*)(id, SEL, long long, long long, id, id, long long, id, long long))objc_msgSend;

        id challenge = imp(factoryCls, sel,
                           securityKey ? 1 : 0, loginType, requestID,
                           self.userField.text ?: @"", userID, urlString, cause);
        if (!challenge) {
            [self alert:@"Unavailable" msg:@"Could not build challenge."];
            return;
        }

        void (^added)(id, id) = ^(id challengeVC, id account) {
            BHTRegisterAccount(account);

            void (^switchBlock)(void) = ^{
                BHTSwitchToAccount(account);
            };

            UIViewController *h = BHTPerform0(objc_getClass("T1HostViewController"), @selector(sharedHostViewController));
            if (h.presentedViewController) {
                [h dismissViewControllerAnimated:YES completion:switchBlock];
            } else {
                switchBlock();
            }
        };

        if ([challenge respondsToSelector:@selector(setDidAddAccountBlock:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(challenge, @selector(setDidAddAccountBlock:), [added copy]);
        }

        if ([host respondsToSelector:@selector(setLoginChallengeProvider:)]) {
            ((void (*)(id, SEL, id))objc_msgSend)(host, @selector(setLoginChallengeProvider:), challenge);
        }

        void (^present)(void) = ^{
            SEL presentSel = @selector(presentLoginChallengeFromViewController:animated:completion:);
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(challenge, presentSel, host, YES, (id)nil);
        };

        id flow = nil;
        if ([host respondsToSelector:@selector(signedOutOnboardingFlow)]) {
            flow = BHTPerform0(host, @selector(signedOutOnboardingFlow));
        }

        if (flow && [flow respondsToSelector:@selector(completeFlowAnimated:completion:)]) {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(flow, @selector(completeFlowAnimated:completion:), NO, present);
        } else {
            present();
        }
    } @catch (NSException *ex) {
        [self alert:@"Crash avoided" msg:ex.reason ?: ex.description];
    }
}

#pragma mark - Account

- (void)buildAndAddAccountWithToken:(id)token secret:(id)secret screenName:(id)screenName userId:(long long)userId {
    if (!token || !secret) {
        [self alert:@"Unexpected response" msg:@"No token in response."];
        return;
    }

    Class accountCls = objc_getClass("TFNTwitterAccount");
    id account = ((id (*)(id, SEL, id, long long))objc_msgSend)([accountCls alloc], @selector(initWithUsername:userID:), screenName, userId);

    if ([account respondsToSelector:@selector(updateUserInfoAndCredentialsWithToken:secret:username:)]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(account, @selector(updateUserInfoAndCredentialsWithToken:secret:username:), token, secret, screenName);
    }

    [self addAndSwitchToAccount:account];
}

- (void)addAndSwitchToAccount:(id)account {
    if (!account) {
        [self alert:@"Login failed" msg:@"No account was returned."];
        return;
    }

    BHTRegisterAccount(account);

    void (^switchBlock)(void) = ^{
        BHTSwitchToAccount(account);
    };

    UIViewController *popup = self.presentingViewController;
    if (!popup) {
        switchBlock();
        return;
    }

    UIViewController *dismisser = popup.presentingViewController ?: popup;
    [dismisser dismissViewControllerAnimated:YES completion:switchBlock];
}

#pragma mark - Alerts

- (NSString *)errorText:(id)error {
    if ([error isKindOfClass:[NSError class]]) {
        NSError *e = error;
        return [NSString stringWithFormat:@"%@ (%ld)\n%@", e.domain, (long)e.code, [e.userInfo description] ?: @""];
    }

    return error ? [error description] : @"Unknown error";
}

- (void)alertError:(id)err title:(NSString *)title {
    NSString *details = [self errorText:err];

    if (BHTIsRateLimit(err)) {
        NSString *msg = [NSString stringWithFormat:@"Too many attempts. Wait a while or switch network/VPN, then try again.\n\nDetails:\n%@", details];
        [self alert:@"Likely rate limited (243)" msg:msg];
        return;
    }

    [self alert:title msg:details];
}

- (void)alert:(NSString *)title msg:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
