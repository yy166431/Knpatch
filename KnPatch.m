// KnPatch.m
// 进入就隐藏数字水印 + 允许投屏/录屏 + 会话级卡密验证（退出重进必输）
// 适配 iOS 12+，纯 ObjC + runtime，无 Logos

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - ===== 配置区 =====

// 你的 App 包名（已经确认是 net.kuniu）
#define KN_BUNDLE_ID        @"net.kuniu"

// 验证服务（POST）
// 你的服务器： http://162.14.67.110:8080
// 接口：POST /check   body: {"bundle":"net.kuniu","key":"xxxxxx"}
// 返回：{"ok":true,"expires_at": 1234567890}
#define KN_API_BASE         @"http://162.14.67.110:8080"
#define KN_API_PATH         @"/check"

// 是否“仅会话生效”（退出/后台->前台 都要重新输）: 1=是, 0=否
#define KN_SESSION_ONLY     1

// 弹窗文案
#define KN_ALRT_TITLE       @"请输入卡密"
#define KN_ALRT_FAIL        @"验证失败，请检查卡密/网络后重试"

// （仅当 KN_SESSION_ONLY=0 时才会用到的）本地缓存键
#define KN_UDEF_OK_KEY      @"kn.lic.ok"
#define KN_UDEF_EXP         @"kn.lic.exp"
#define KN_UDEF_LAST        @"kn.lic.last"

// 如果启动页有广告，这个延迟可以让 UI 稳定后再弹窗，避免“假死”感
#define KN_PROMPT_DELAY_SEC 0.35


#pragma mark - ===== 全局状态 =====

static BOOL kn_isLicensed = NO;   // 会话内授权态（本次打开 App 是否已通过）
static BOOL kn_prompting  = NO;   // 正在显示输入框，避免重复弹


#pragma mark - ===== 小工具：隐藏视图里“纯数字/编号”的 UILabel =====

static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;

    // 1) 自身是 UILabel 且文本看起来是“短数字/编号”
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *t = lbl.text ?: @"";
        // 只允许 0-9 和 . 号，长度 3~8（按你之前习惯，避免把普通文案误杀）
        if (t.length >= 3 && t.length <= 8) {
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789."];            
            NSString *trim = [[t componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
            if ([trim isEqualToString:t]) {
                lbl.hidden = YES;
                lbl.alpha  = 0.0;
                lbl.userInteractionEnabled = NO;
            }
        }
    }

    // 2) 递归子视图
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}


#pragma mark - ===== Hook: UIView didAddSubview（任何新视图加入都扫一次） =====

static void (*kn_orig_didAddSubview)(UIView *, SEL, UIView *);
static void kn_sw_didAddSubview(UIView *self, SEL _cmd, UIView *sub) {
    kn_orig_didAddSubview(self, _cmd, sub);
    // 仅在授权后才做隐藏
    if (kn_isLicensed) {
        // 延后一点点，等布局完成
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(sub);
        });
    }
}


#pragma mark - ===== Hook: UIViewController viewDidAppear（进入页后再扫一遍） =====

static void (*kn_orig_vc_viewDidAppear)(UIViewController *, SEL, BOOL);
static void kn_sw_vc_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    kn_orig_vc_viewDidAppear(self, _cmd, animated);

    // 仅在授权后才隐藏
    if (kn_isLicensed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(self.view);
        });
    }
}


#pragma mark - ===== 允许投屏：AVPlayer allowsExternalPlayback 永远 YES =====

static void (*kn_orig_setAllowExt)(AVPlayer *, SEL, BOOL);
static void kn_sw_setAllowExt(AVPlayer *self, SEL _cmd, BOOL flag) {
    // 强制打开
    kn_orig_setAllowExt(self, _cmd, YES);
}
static BOOL kn_sw_allowsExternalPlayback(AVPlayer *self, SEL _cmd) {
    return YES;
}


#pragma mark - ===== 允许录屏：UIScreen isCaptured -> NO =====

// iOS 11+ 有 isCaptured，旧系统也能安全处理
static BOOL (*kn_orig_isCaptured)(UIScreen *, SEL);
static BOOL kn_sw_isCaptured(UIScreen *self, SEL _cmd) {
    // 已授权后，强制“没有被捕获”，从而允许系统录屏/投屏
    if (kn_isLicensed) return NO;
    if (kn_orig_isCaptured) return kn_orig_isCaptured(self, _cmd);
    return NO;
}


#pragma mark - ===== 运行时交换工具 =====

static void kn_swizzle(Class c, SEL orig, SEL swiz) {
    Method m1 = class_getInstanceMethod(c, orig);
    Method m2 = class_getInstanceMethod(c, swiz);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}


#pragma mark - ===== 卡密验证：UI + POST =====

static void kn_doVerify(NSString *key, void (^onOK)(void)) {
    if (key.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *a = [UIAlertController alertControllerWithTitle:KN_ALRT_FAIL
                                                                       message:nil
                                                                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
            [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:a animated:YES completion:nil];
        });
        return;
    }

    NSURL *url = [NSURL URLWithString:[KN_API_BASE stringByAppendingString:KN_API_PATH]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *body = @{
        @"bundle": KN_BUNDLE_ID,
        @"key":    key ?: @""
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    req.HTTPBody = data;

    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:req
                                                               completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
        BOOL ok = NO;
        NSTimeInterval expTS = 0;

        if (!e && d.length > 0) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                ok = [json[@"ok"] boolValue];
                if (json[@"expires_at"]) expTS = [json[@"expires_at"] doubleValue];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                kn_isLicensed = YES;

#if !KN_SESSION_ONLY
                // 可持久化时才缓存
                NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
                [ud setBool:YES forKey:KN_UDEF_OK_KEY];
                if (expTS > 0) [ud setDouble:expTS forKey:KN_UDEF_EXP];
                [ud setDouble:[[NSDate date] timeIntervalSince1970] forKey:KN_UDEF_LAST];
                [ud synchronize];
#endif
                if (onOK) onOK();
            } else {
                UIAlertController *a = [UIAlertController alertControllerWithTitle:KN_ALRT_FAIL
                                                                           message:nil
                                                                    preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                [UIApplication.sharedApplication.keyWindow.rootViewController presentViewController:a animated:YES completion:nil];
            }
        });
    }];
    [task resume];
}

static void kn_promptLicenseIfNeeded(void (^onOK)(void)) {
    if (kn_isLicensed || kn_prompting) return;
    if (![UIApplication sharedApplication].keyWindow) {
        // 还没窗口：稍后再弹
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KN_PROMPT_DELAY_SEC * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            kn_promptLicenseIfNeeded(onOK);
        });
        return;
    }

    kn_prompting = YES;

    UIAlertController *ac = [UIAlertController alertControllerWithTitle:KN_ALRT_TITLE
                                                                message:nil
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
        tf.placeholder = @"粘贴/输入卡密";
        tf.keyboardType = UIKeyboardTypeASCIICapable;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak UIAlertController *weakAC = ac;
    [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull act) {
        __strong UIAlertController *sac = weakAC;
        NSString *key = sac.textFields.firstObject.text ?: @"";
        kn_prompting = NO;
        kn_doVerify(key, onOK);
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction * _Nonnull act) {
        kn_prompting = NO;
    }]];

    UIViewController *root = UIApplication.sharedApplication.keyWindow.rootViewController;
    [root presentViewController:ac animated:YES completion:nil];
}


#pragma mark - ===== 入口：安装 Hook + 会话授权策略 =====

__attribute__((constructor))
static void kn_entry(void) {
    // 仅在指定包生效
    NSString *bid = [NSBundle.mainBundle bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;

    // Hook：隐藏数字水印（添加子视图 & 出现页面）
    kn_orig_didAddSubview = (void *)class_getInstanceMethod(UIView.class, @selector(didAddSubview:));
    if (kn_orig_didAddSubview) {
        class_addMethod(UIView.class, @selector(kn_sw_didAddSubview:), (IMP)kn_sw_didAddSubview, "v@:@");
        kn_swizzle(UIView.class, @selector(didAddSubview:), @selector(kn_sw_didAddSubview:));
    }

    kn_orig_vc_viewDidAppear = (void *)class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (kn_orig_vc_viewDidAppear) {
        class_addMethod(UIViewController.class, @selector(kn_sw_vc_viewDidAppear:), (IMP)kn_sw_vc_viewDidAppear, "v@:B");
        kn_swizzle(UIViewController.class, @selector(viewDidAppear:), @selector(kn_sw_vc_viewDidAppear:));
    }

    // Hook：投屏
    if (class_getInstanceMethod(AVPlayer.class, @selector(setAllowsExternalPlayback:))) {
        kn_orig_setAllowExt = (void *)class_getInstanceMethod(AVPlayer.class, @selector(setAllowsExternalPlayback:));
        class_addMethod(AVPlayer.class, @selector(kn_sw_setAllowExt:), (IMP)kn_sw_setAllowExt, "v@:B");
        kn_swizzle(AVPlayer.class, @selector(setAllowsExternalPlayback:), @selector(kn_sw_setAllowExt:));
    }
    if (class_getInstanceMethod(AVPlayer.class, @selector(allowsExternalPlayback))) {
        class_addMethod(AVPlayer.class, @selector(kn_sw_allowsExternalPlayback), (IMP)kn_sw_allowsExternalPlayback, "B@:");
        kn_swizzle(AVPlayer.class, @selector(allowsExternalPlayback), @selector(kn_sw_allowsExternalPlayback));
    }

    // Hook：录屏
    if ([UIScreen.mainScreen respondsToSelector:@selector(isCaptured)]) {
        Method m = class_getInstanceMethod(UIScreen.class, @selector(isCaptured));
        if (m) {
            kn_orig_isCaptured = (BOOL (*)(UIScreen*,SEL))method_getImplementation(m);
            class_addMethod(UIScreen.class, @selector(kn_sw_isCaptured), (IMP)kn_sw_isCaptured, "B@:");
            kn_swizzle(UIScreen.class, @selector(isCaptured), @selector(kn_sw_isCaptured));
        }
    }

#if KN_SESSION_ONLY
    // 会话模式：冷启动 / 回前台 均要求验证；退后台清状态
    kn_isLicensed = NO;

    // 冷启动：延后一点点，等 UI 稳定后弹
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KN_PROMPT_DELAY_SEC * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kn_promptLicenseIfNeeded(^{
            // 验证通过后，立刻对当前可见页面做一次清理
            UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
            if (vc) kn_hideDigitsInView(vc.view);
        });
    });

    // 回前台：如果未授权，再次弹
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification * _Nonnull note) {
        if (!kn_isLicensed) {
            kn_promptLicenseIfNeeded(^{
                UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
                if (vc) kn_hideDigitsInView(vc.view);
            });
        }
    }];

    // 退后台：清掉授权，确保回来必输
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification * _Nonnull note) {
        kn_isLicensed = NO;
    }];
#else
    // 可缓存：读取本地授权（如过期或未授权则弹窗）
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    BOOL cachedOK = [ud boolForKey:KN_UDEF_OK_KEY];
    NSTimeInterval exp  = [ud doubleForKey:KN_UDEF_EXP];
    NSTimeInterval now  = NSDate.date.timeIntervalSince1970;

    if (cachedOK && (exp <= 0 || now < exp)) {
        kn_isLicensed = YES;
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(KN_PROMPT_DELAY_SEC * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            kn_promptLicenseIfNeeded(^{
                UIViewController *vc = UIApplication.sharedApplication.keyWindow.rootViewController;
                if (vc) kn_hideDigitsInView(vc.view);
            });
        });
    }
#endif
}
