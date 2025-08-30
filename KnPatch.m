// KnPatch.m —— 启动先做卡密校验(POST)，通过后再启用 “去水印 + 录屏绕过 + 允许投屏”
// 你的原有功能代码都保留；只是把启用时机放在了验证成功之后。

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - ====== 配置区 ======
#define KN_BUNDLE_MATCH      @"kuniu"                   // 只对包含该串的包名生效
#define KN_SERVER_CHECK_URL  @"http://162.14.67.110:8080/check"   // 你的校验服务(POST)
#define KN_KEY_USERDEFAULTS  @"kn.lic.key"
#define KN_VALID_UNTIL_UD    @"kn.lic.validUntil"       // 秒级时间戳
#define KN_GRACE_SECONDS     (12*60*60)                  // 12 小时离线宽限
#define KN_ALERT_DELAY       0.8                         // 激活后延迟弹框，绕过启动广告/闪屏

static inline NSString *kn_bundleID(void) {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"";
}
static inline NSTimeInterval kn_now(void) {
    return [[NSDate date] timeIntervalSince1970];
}

#pragma mark - ====== 去水印：你原来的逻辑，未改动 ======
static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *t = lbl.text ?: @"";
        // 只允许 5~8 位，由 0-9 和 : 组成（避免误伤）
        if (t.length >= 5 && t.length <= 8) {
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789:"];
            NSString *trim = [[t componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
            if ([trim isEqualToString:t]) {
                lbl.hidden = YES;
                lbl.alpha = 0.0;
                lbl.userInteractionEnabled = NO;
            }
        }
    }
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}

static void (*kn_orig_didAddSubview)(UIView *, SEL, UIView *);
static void kn_swz_didAddSubview(UIView *self, SEL _cmd, UIView *sub) {
    kn_orig_didAddSubview(self, _cmd, sub);
    NSString *bid = kn_bundleID();
    if ([bid containsString:KN_BUNDLE_MATCH]) {
        kn_hideDigitsInView(sub);
    }
}

static void (*kn_orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void kn_swz_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    kn_orig_viewDidAppear(self, _cmd, animated);
    NSString *bid = kn_bundleID();
    if ([bid containsString:KN_BUNDLE_MATCH]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(self.view);
        });
    }
}

static BOOL kn_isCaptured(id self, SEL _cmd) { return NO; }
static BOOL kn_allowsExternalPlayback(id self, SEL _cmd) { return YES; }

static void kn_swizzle(Class cls, SEL a, SEL b) {
    Method m1 = class_getInstanceMethod(cls, a);
    Method m2 = class_getInstanceMethod(cls, b);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - ====== License 管理（POST 校验 + 弹框输入 + 缓存/离线宽限） ======
@interface KNLic : NSObject
+ (void)ensureValidThen:(void (^)(BOOL ok))block;
@end

@implementation KNLic

+ (NSString *)savedKey {
    return [[NSUserDefaults standardUserDefaults] stringForKey:KN_KEY_USERDEFAULTS];
}
+ (void)saveKey:(NSString *)key {
    if (key.length) {
        [[NSUserDefaults standardUserDefaults] setObject:key forKey:KN_KEY_USERDEFAULTS];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}
+ (void)setValidUntil:(NSTimeInterval)ts {
    [[NSUserDefaults standardUserDefaults] setDouble:ts forKey:KN_VALID_UNTIL_UD];
    [[NSUserDefaults standardUserDefaults] synchronize];
}
+ (NSTimeInterval)validUntil {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:KN_VALID_UNTIL_UD];
}
+ (BOOL)cachedStillValid {
    NSTimeInterval until = [self validUntil];
    if (until <= 0) return NO;
    // 额外给一点宽限（离线容错）
    return kn_now() <= (until + KN_GRACE_SECONDS);
}

+ (UIViewController *)topVC {
    UIWindow *w = UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.windows.firstObject;
    UIViewController *root = w.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:UINavigationController.class]) root = [(UINavigationController*)root topViewController];
    if ([root isKindOfClass:UITabBarController.class]) root = [(UITabBarController*)root selectedViewController];
    return root ?: UIViewController.new;
}

+ (void)askForKeyWithMessage:(NSString *)msg completion:(void(^)(NSString *key))done {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KN_ALERT_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *top = [self topVC];
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"请输入卡密"
                                                                    message:(msg ?: @"")
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
            tf.placeholder = @"粘贴/输入卡密";
            tf.text = [self savedKey] ?: @"";
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *k = ac.textFields.firstObject.text ?: @"";
            done(k);
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            exit(0);
        }]];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

+ (void)postCheckKey:(NSString *)key completion:(void(^)(BOOL ok, NSTimeInterval exp, NSString *err))done {
    if (key.length == 0) { if (done) done(NO, 0, @"卡密为空"); return; }

    NSURL *url = [NSURL URLWithString:KN_SERVER_CHECK_URL];
    if (!url) { if (done) done(NO, 0, @"校验地址错误"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{@"bundle": kn_bundleID(), @"key": key};
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    req.HTTPBody = body;

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForRequest = 8.0;
    NSURLSession *ss = [NSURLSession sessionWithConfiguration:cfg];

    [[ss dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable resp, NSError * _Nullable error) {
        if (error) { if (done) done(NO, 0, error.localizedDescription); return; }
        NSDictionary *json = nil;
        if (data) json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        BOOL ok = [json[@"ok"] boolValue];
        NSTimeInterval exp = [json[@"expires_at"] doubleValue];
        if (done) done(ok, exp, ok?nil:(json[@"msg"] ?: @"验证失败"));
    }] resume];
}

+ (void)ensureValidThen:(void (^)(BOOL ok))block {
    // 1) 缓存有效 → 直接过
    if ([self cachedStillValid]) { if (block) block(YES); return; }

    // 2) 开始交互：弹一次输入框；成功则落盘并回调开启
    void (^loopAsk)(NSString *) = ^(NSString *hint){
        [self askForKeyWithMessage:(hint ?: @"") completion:^(NSString * _Nonnull key) {
            [self postCheckKey:key completion:^(BOOL ok, NSTimeInterval exp, NSString *err) {
                if (ok && exp > 0) {
                    [self saveKey:key];
                    [self setValidUntil:exp];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (block) block(YES);
                    });
                } else {
                    // 再来一次
                    NSString *m = err ?: @"验证失败，请检查卡密/网络后重试";
                    loopAsk(m);
                }
            }];
        }];
    };
    loopAsk(nil);
}

@end

#pragma mark - ====== 把原来的 hook 封装成 “启用函数” ======
static void kn_enableHooks(void) {
    // 1) UIView didAddSubview:
    {
        Method m = class_getInstanceMethod([UIView class], @selector(didAddSubview:));
        kn_orig_didAddSubview = (void *)method_getImplementation(m);
        class_replaceMethod([UIView class], @selector(didAddSubview:),
                            (IMP)kn_swz_didAddSubview, method_getTypeEncoding(m));
    }
    // 2) UIViewController viewDidAppear:
    {
        Method m = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
        kn_orig_viewDidAppear = (void *)method_getImplementation(m);
        class_replaceMethod([UIViewController class], @selector(viewDidAppear:),
                            (IMP)kn_swz_viewDidAppear, method_getTypeEncoding(m));
    }
    // 3) 录屏绕过
    {
        Method m = class_getInstanceMethod([UIScreen class], @selector(isCaptured));
        if (m) class_replaceMethod([UIScreen class], @selector(isCaptured),
                                   (IMP)kn_isCaptured, method_getTypeEncoding(m));
    }
    // 4) 允许外接播放
    {
        Method m = class_getInstanceMethod([AVPlayer class], @selector(allowsExternalPlayback));
        if (m) class_replaceMethod([AVPlayer class], @selector(allowsExternalPlayback),
                                   (IMP)kn_allowsExternalPlayback, method_getTypeEncoding(m));
    }
}

#pragma mark - ====== 入口：先验证 → 再启用功能 ======
__attribute__((constructor))
static void kn_init(void) {
    NSString *bid = kn_bundleID();
    if (![bid containsString:KN_BUNDLE_MATCH]) return;

    // 等 App 激活后再开始（避免启动广告页面还没准备好就弹框）
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification * _Nonnull note) {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [KNLic ensureValidThen:^(BOOL ok) {
                if (ok) kn_enableHooks();
            }];
        });
    }];
}
