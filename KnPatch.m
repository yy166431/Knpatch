// KnPatch.m —— 先做卡密校验(POST)，通过后再启用 “去水印 + 录屏绕过 + 允许投屏”
// 移除了任何 exit(0)，并加了只弹一次 + try/catch 保护

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - ====== 配置 ======
#define KN_BUNDLE_MATCH      @"kuniu"                         // 只对包含该串的包名生效
#define KN_SERVER_CHECK_URL  @"http://162.14.67.110:8080/check" // 强烈建议改为 https://你的域名/check
#define KN_KEY_USERDEFAULTS  @"kn.lic.key"
#define KN_VALID_UNTIL_UD    @"kn.lic.validUntil"
#define KN_GRACE_SECONDS     (12*60*60)                        // 12h 离线宽限
#define KN_ALERT_DELAY       0.8                               // 激活后延迟弹框

static inline NSString *kn_bundleID(void){ return [[NSBundle mainBundle] bundleIdentifier] ?: @""; }
static inline NSTimeInterval kn_now(void){ return [[NSDate date] timeIntervalSince1970]; }

#pragma mark - ====== 去水印/录屏绕过/投屏（原逻辑不动） ======
static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *t = lbl.text ?: @"";
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
    for (UIView *sub in v.subviews) kn_hideDigitsInView(sub);
}

static void (*kn_orig_didAddSubview)(UIView*,SEL,UIView*);
static void kn_swz_didAddSubview(UIView*self,SEL _cmd,UIView*sub){
    kn_orig_didAddSubview(self,_cmd,sub);
    if ([[kn_bundleID() lowercaseString] containsString:[KN_BUNDLE_MATCH lowercaseString]]) {
        kn_hideDigitsInView(sub);
    }
}

static void (*kn_orig_viewDidAppear)(UIViewController*,SEL,BOOL);
static void kn_swz_viewDidAppear(UIViewController*self,SEL _cmd,BOOL animated){
    kn_orig_viewDidAppear(self,_cmd,animated);
    if ([[kn_bundleID() lowercaseString] containsString:[KN_BUNDLE_MATCH lowercaseString]]) {
        dispatch_async(dispatch_get_main_queue(), ^{ kn_hideDigitsInView(self.view); });
    }
}

static BOOL kn_isCaptured(id self, SEL _cmd){ return NO; }
static BOOL kn_allowsExternalPlayback(id self, SEL _cmd){ return YES; }

static void kn_enableHooks(void){
    // UIView didAddSubview:
    Method m1 = class_getInstanceMethod(UIView.class, @selector(didAddSubview:));
    kn_orig_didAddSubview = (void*)method_getImplementation(m1);
    class_replaceMethod(UIView.class, @selector(didAddSubview:), (IMP)kn_swz_didAddSubview, method_getTypeEncoding(m1));
    // UIViewController viewDidAppear:
    Method m2 = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    kn_orig_viewDidAppear = (void*)method_getImplementation(m2);
    class_replaceMethod(UIViewController.class, @selector(viewDidAppear:), (IMP)kn_swz_viewDidAppear, method_getTypeEncoding(m2));
    // 录屏绕过 & 允许外接
    Method m3 = class_getInstanceMethod(UIScreen.class, @selector(isCaptured));
    if (m3) class_replaceMethod(UIScreen.class, @selector(isCaptured), (IMP)kn_isCaptured, method_getTypeEncoding(m3));
    Method m4 = class_getInstanceMethod(AVPlayer.class, @selector(allowsExternalPlayback));
    if (m4) class_replaceMethod(AVPlayer.class, @selector(allowsExternalPlayback), (IMP)kn_allowsExternalPlayback, method_getTypeEncoding(m4));
}

#pragma mark - ====== License 管理 ======
@interface KNLic : NSObject
+ (void)ensureValidThen:(void(^)(BOOL ok))block;
@end

@implementation KNLic
+ (NSString*)savedKey {
    return [[NSUserDefaults standardUserDefaults] stringForKey:KN_KEY_USERDEFAULTS];
}
+ (void)saveKey:(NSString*)key {
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
+ (BOOL)cachedValid {
    NSTimeInterval until = [self validUntil];
    return (until > 0) && (kn_now() <= (until + KN_GRACE_SECONDS));
}
+ (UIViewController*)topVC {
    UIWindow *w = UIApplication.sharedApplication.keyWindow ?: UIApplication.sharedApplication.windows.firstObject;
    UIViewController *root = w.rootViewController ?: UIViewController.new;
    while (root.presentedViewController) root = root.presentedViewController;
    if ([root isKindOfClass:UINavigationController.class]) root = [(UINavigationController*)root topViewController];
    if ([root isKindOfClass:UITabBarController.class])   root = [(UITabBarController*)root selectedViewController];
    return root ?: UIViewController.new;
}

+ (void)showInputWith:(NSString*)msg completion:(void(^)(NSString*key))done {
    static BOOL showing = NO;
    if (showing) return;
    showing = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(KN_ALERT_DELAY*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try{
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"请输入卡密"
                                                                        message:(msg?:@"")
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
                tf.placeholder = @"粘贴/输入卡密";
                tf.text = [self savedKey] ?: @"";
            }];
            [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                showing = NO;
                NSString *k = ac.textFields.firstObject.text ?: @"";
                if (done) done(k);
            }]];
            // 不再提供“退出”按钮——避免误触导致退出
            [[self topVC] presentViewController:ac animated:YES completion:nil];
        }@catch(NSException *e){
            // 如果广告页导致 present 异常，稍后再试
            showing = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self showInputWith:msg completion:done];
            });
        }
    });
}

+ (void)postCheck:(NSString*)key completion:(void(^)(BOOL ok, NSTimeInterval exp, NSString*err))done {
    if (key.length==0){ if(done)done(NO,0,@"卡密为空"); return; }
    NSURL *u = [NSURL URLWithString:KN_SERVER_CHECK_URL];
    if (!u){ if(done)done(NO,0,@"校验地址错误"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *payload = @{@"bundle":kn_bundleID(), @"key":key};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.defaultSessionConfiguration;
    cfg.timeoutIntervalForRequest = 8.0;
    [[[NSURLSession sessionWithConfiguration:cfg]
      dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err){ if(done)done(NO,0,err.localizedDescription); return; }
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ok = [json[@"ok"] boolValue];
        NSTimeInterval exp = [json[@"expires_at"] doubleValue];
        if (done) done(ok,exp, ok?nil:(json[@"msg"]?:@"验证失败"));
    }] resume];
}

+ (void)ensureValidThen:(void(^)(BOOL ok))block {
    if ([self cachedValid]){ if(block)block(YES); return; }

    __block void (^loop)(NSString*);
    loop = ^(NSString *hint){
        [self showInputWith:hint completion:^(NSString *key) {
            [self postCheck:key completion:^(BOOL ok, NSTimeInterval exp, NSString *err) {
                if (ok && exp>0){
                    [self saveKey:key];
                    [self setValidUntil:exp];
                    dispatch_async(dispatch_get_main_queue(), ^{ if(block)block(YES); });
                }else{
                    NSString *m = err ?: @"验证失败，请检查卡密/网络后重试";
                    loop(m); // 不退出，继续弹
                }
            }];
        }];
    };
    loop(nil);
}
@end

#pragma mark - ====== 入口：先验证 → 再启用功能 ======
__attribute__((constructor))
static void kn_init(void){
    NSString *bid = kn_bundleID();
    if (![[bid lowercaseString] containsString:[KN_BUNDLE_MATCH lowercaseString]]) return;

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:NSOperationQueue.mainQueue
                                                  usingBlock:^(__unused NSNotification *n){
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            [KNLic ensureValidThen:^(BOOL ok){
                if (ok) kn_enableHooks();
            }];
        });
    }];
}
