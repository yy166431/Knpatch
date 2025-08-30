//
//  KnPatch.m
//  进入就清除数字水印 + 持续拦截新加入的水印视图
//  + 会话级卡密验证（每次退出/回到前台都需重新输入）
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - 可按需修改的配置

/// 目标 App 包名（只在该 App 内生效）
#define KN_BUNDLE_ID        @"net.kuniu"

/// 服务器地址（POST /check）
#define KN_SERVER_BASE      @"http://162.14.67.110:8080"
#define KN_CHECK_PATH       @"/check"

/// 会话级授权：1=每次进入都要重新输入；0=允许本地缓存
#define KN_SESSION_ONLY     1

/// 本地缓存键（只有在 KN_SESSION_ONLY=0 时才会使用）
#define KN_UDEF_OK_KEY      @"kn_ok"
#define KN_UDEF_EXP         @"kn_exp"
#define KN_UDEF_LAST        @"kn_last"

#pragma mark - 内部状态

static BOOL kn_isLicensed = NO;

#pragma mark - 通用小工具

/// 简易方法交换
static void kn_swizzle(Class c, SEL a, SEL b) {
    Method m1 = class_getInstanceMethod(c, a);
    Method m2 = class_getInstanceMethod(c, b);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

/// 获取最顶层可展示控制器
static UIViewController *kn_topVC(void) {
    UIWindow *win = UIApplication.sharedApplication.keyWindow;
    if (!win) win = UIApplication.sharedApplication.windows.firstObject;
    UIViewController *vc = win.rootViewController;
    while (1) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:UINavigationController.class]) {
            vc = ((UINavigationController *)vc).visibleViewController;
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            vc = ((UITabBarController *)vc).selectedViewController;
        } else {
            break;
        }
    }
    return vc;
}

#pragma mark - 去数字水印核心

/// 小工具：剔除并隐藏“纯数字/号码”的 UILabel
static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;

    // 1) 自身是否是嫌疑的 UILabel
    if ([v isKindOfClass:UILabel.class]) {
        UILabel *lbl = (UILabel *)v;
        NSString *txt = lbl.text ?: @"";
        // 只允许 5~8 位，且仅包含 0~9 的 “号码”（避免误伤普通文案）
        if (txt.length >= 5 && txt.length <= 8) {
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
            NSString *trim = [[txt componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
            if ([trim isEqualToString:txt]) {
                lbl.hidden = YES;
                lbl.alpha  = 0.0;
                lbl.userInteractionEnabled = NO;
            }
        }
    }

    // 2) 递归清理子视图
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}

#pragma mark - Hook：UIView didAddSubview（新视图加入就清理一次）

@implementation UIView (KN_NoDigits)

- (void)kn_orig_didAddSubview:(UIView *)sub { [self kn_orig_didAddSubview:sub]; }

- (void)kn_didAddSubview:(UIView *)sub {
    [self kn_didAddSubview:sub];   // 调用原实现
    // 只在目标 App 内生效，避免影响其它 App
    NSString *bid = [NSBundle.mainBundle bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;
    if (!kn_isLicensed) return;    // 未授权不处理
    kn_hideDigitsInView(sub);
}
@end

#pragma mark - Hook：UIViewController viewDidAppear（进入页面后再补一次）

@implementation UIViewController (KN_NoDigits)

- (void)kn_orig_viewDidAppear:(BOOL)animated { [self kn_orig_viewDidAppear:animated]; }

- (void)kn_viewDidAppear:(BOOL)animated {
    [self kn_viewDidAppear:animated];

    NSString *bid = [NSBundle.mainBundle bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;
    if (!kn_isLicensed) return;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        kn_hideDigitsInView(self2.view);
    });
}
@end

#pragma mark - 授权：会话级卡密验证（POST /check）

/// 组装校验请求
static NSURLRequest *kn_makeCheckRequest(NSString *key) {
    NSString *bundle = [NSBundle.mainBundle bundleIdentifier] ?: @"";
    NSString *device = UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"";
    NSDictionary *payload = @{
        @"bundle": bundle,
        @"key": key ?: @"",
        @"device": device
    };

    NSURL *url = [NSURL URLWithString:[KN_SERVER_BASE stringByAppendingString:KN_CHECK_PATH]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;

    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    req.HTTPBody = data;
    return req;
}

/// 弹框输入 & 远端验证；成功则 kn_isLicensed=YES（会话内有效）
static void kn_promptLicenseIfNeeded(void (^onOK)(void)) {
    if (kn_isLicensed) { if (onOK) onOK(); return; }

#if !KN_SESSION_ONLY
    // 可缓存模式：读缓存（你若永远会话模式可删除此段）
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL ok = [ud boolForKey:KN_UDEF_OK_KEY];
    NSTimeInterval exp = [ud doubleForKey:KN_UDEF_EXP];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (ok && (exp <= 0 || now < exp)) { kn_isLicensed = YES; if (onOK) onOK(); return; }
#endif

    UIViewController *presenter = kn_topVC();
    if (!presenter) return;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"请输入卡密"
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"粘贴/输入卡密";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];

    __weak UIAlertController *weakAC = ac;

    UIAlertAction *okAct = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull act) {
        NSString *key = weakAC.textFields.firstObject.text ?: @"";
        if (key.length == 0) {
            [presenter.view endEditing:YES];
            return;
        }

        NSURLRequest *req = kn_makeCheckRequest(key);
        [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            BOOL pass = NO;
            NSTimeInterval expTS = 0;

            if (!error && data.length > 0) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                // 兼容 {ok:true,expires_at:...} 或 {ok:1}
                id okVal = json[@"ok"];
                if ([okVal respondsToSelector:@selector(boolValue)] && [okVal boolValue]) {
                    pass = YES;
                    id expVal = json[@"expires_at"];
                    if ([expVal respondsToSelector:@selector(doubleValue)]) expTS = [expVal doubleValue];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (pass) {
                    kn_isLicensed = YES;

#if !KN_SESSION_ONLY
                    // 只有允许缓存时才落盘
                    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
                    [ud setBool:YES forKey:KN_UDEF_OK_KEY];
                    if (expTS > 0) [ud setDouble:expTS forKey:KN_UDEF_EXP];
                    [ud setDouble:NSDate.date.timeIntervalSince1970 forKey:KN_UDEF_LAST];
                    [ud synchronize];
#endif
                    if (onOK) onOK();
                } else {
                    UIAlertController *tip = [UIAlertController alertControllerWithTitle:@"验证失败"
                                                                                message:@"请检查卡密/网络后重试"
                                                                         preferredStyle:UIAlertControllerStyleAlert];
                    [tip addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:nil]];
                    [presenter presentViewController:tip animated:YES completion:nil];
                }
            });
        }] resume];
    }];

    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction * _Nonnull act) {
        // 用户拒绝：不授权
    }];

    [ac addAction:okAct];
    [ac addAction:cancel];
    [presenter presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 入口：安装 Hook & 会话授权流程

__attribute__((constructor))
static void kn_entry(void) {
    // 仅目标 App 生效
    NSString *bid = [NSBundle.mainBundle bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;

    // Hook
    kn_swizzle(UIView.class, @selector(didAddSubview:), @selector(kn_didAddSubview:));
    kn_swizzle(UIViewController.class, @selector(viewDidAppear:), @selector(kn_viewDidAppear:));

#if KN_SESSION_ONLY
    // 会话模式：冷启动弹一次；回到前台若未授权则再弹；退到后台清空授权
    kn_isLicensed = NO;

    dispatch_async(dispatch_get_main_queue(), ^{
        kn_promptLicenseIfNeeded(NULL);
    });

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification * _Nonnull n) {
        if (!kn_isLicensed) {
            kn_promptLicenseIfNeeded(NULL);
        }
    }];

    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification * _Nonnull n) {
        kn_isLicensed = NO;
    }];
#else
    // 允许缓存模式：仅首次不合法时弹窗
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL ok = [ud boolForKey:KN_UDEF_OK_KEY];
    NSTimeInterval exp = [ud doubleForKey:KN_UDEF_EXP];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (ok && (exp <= 0 || now < exp)) {
        kn_isLicensed = YES;
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_promptLicenseIfNeeded(NULL);
        });
    }
#endif
}

