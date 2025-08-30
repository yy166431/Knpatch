// KnPatch.m — 去掉水印 + 允许录屏/投屏（仅验证成功后生效）+ 每次冷启动都要求验证
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// ====== 配置 ======
static NSString * const kBundleLimit = @"net.kuniu";
static NSString * const kCheckURL    = @"http://162.14.67.110:8080/check";
static const NSTimeInterval kPromptDelay = 0.6; // 避开开屏广告/首屏构建

// ====== 运行时状态 ======
static BOOL gVerifiedThisLaunch = NO;   // 不持久化，冷启动后默认 NO
static BOOL gFeatureEnabled     = NO;   // 验证通过后，开启所有功能

#pragma mark - 小工具：找到顶层VC并弹窗

static UIViewController *kn_topMostVC(void) {
    UIWindow *keyWin = UIApplication.sharedApplication.keyWindow;
    if (!keyWin) {
        for (UIWindow *win in UIApplication.sharedApplication.windows) {
            if (win.isKeyWindow) { keyWin = win; break; }
        }
    }
    UIViewController *root = keyWin.rootViewController;
    if (!root) return nil;
    UIViewController *top = root;
    while (top.presentedViewController) {
        top = top.presentedViewController;
    }
    if ([top isKindOfClass:UINavigationController.class]) {
        top = [(UINavigationController *)top visibleViewController] ?: top;
    } else if ([top isKindOfClass:UITabBarController.class]) {
        UIViewController *sel = [(UITabBarController *)top selectedViewController];
        if ([sel isKindOfClass:UINavigationController.class]) {
            top = [(UINavigationController *)sel visibleViewController] ?: top;
        } else if (sel) {
            top = sel;
        }
    }
    return top;
}

#pragma mark - 验证：POST /check

static void kn_doVerifyWithKey(NSString *key, void (^done)(BOOL ok, NSString *message)) {
    if (key.length == 0) { if (done) done(NO, @"卡密为空"); return; }

    NSURL *url = [NSURL URLWithString:kCheckURL];
    if (!url) { if (done) done(NO, @"服务器地址无效"); return; }

    NSDictionary *body = @{@"bundle": kBundleLimit, @"key": key};
    NSData *json = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = json;
    req.timeoutInterval = 8.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        if (error) { if (done) done(NO, @"网络异常"); return; }
        if (!data)   { if (done) done(NO, @"无响应");   return; }

        NSDictionary *ret = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        BOOL ok = [[ret objectForKey:@"ok"] boolValue];
        NSString *msg = ret[@"msg"] ?: (ok ? @"验证成功" : @"验证失败");
        if (done) done(ok, msg);
    }] resume];
}

static void kn_presentVerifyAlertIfNeeded(void) {
    if (gVerifiedThisLaunch) return;
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:kBundleLimit]) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPromptDelay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gVerifiedThisLaunch) return; // 期间已验证

        UIViewController *top = kn_topMostVC();
        if (!top) return;

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"请输入卡密"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"粘贴/输入卡密";
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];

        __weak UIAlertController *weakAC = ac;
        UIAlertAction *ok = [UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            __strong UIAlertController *strongAC = weakAC;
            NSString *key = strongAC.textFields.firstObject.text ?: @"";
            kn_doVerifyWithKey(key, ^(BOOL ok, NSString *message) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ok) {
                        gVerifiedThisLaunch = YES;
                        gFeatureEnabled     = YES; // ← 验证成功，本次会话开启功能
                    } else {
                        // 失败提示后，继续停留在弹窗（再次输入）
                        UIAlertController *tip = [UIAlertController alertControllerWithTitle:@"验证失败"
                                                                                     message:@"请检查卡密/网络后重试"
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                        [tip addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
                            kn_presentVerifyAlertIfNeeded();
                        }]];
                        [top presentViewController:tip animated:YES completion:nil];
                    }
                });
            });
        }];

        UIAlertAction *quit = [UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            // 用户选择退出，直接杀进程
            exit(0);
        }];

        [ac addAction:ok];
        [ac addAction:quit];
        [top presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - 去水印（保持你的原始逻辑不变）

static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;

    // 1) 自身是数字纯文本 UILabel
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *txt = lbl.text ?: @"";
        // 只允许 0-9，且长度 5~8
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
    // 2) 递归遍历子视图
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}

#pragma mark - Hook：addSubview / viewDidAppear（触发去水印）

static void (*orig_addSubview)(UIView *, SEL, UIView *);
static void kn_swz_addSubview(UIView *self, SEL _cmd, UIView *sub) {
    orig_addSubview(self, _cmd, sub);
    if (!gFeatureEnabled) return;
    // 只在指定 App 包名里工作，避免影响其它 App
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:kBundleLimit]) {
        kn_hideDigitsInView(sub);
    }
}

static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void kn_swz_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    if (!gFeatureEnabled) { return; }
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if ([bid isEqualToString:kBundleLimit]) {
        // 弹窗在首次活跃时机做，这里兜底再尝试一次（一般不会重复弹）
        kn_presentVerifyAlertIfNeeded();
        // 进入页面再清一次数字水印
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(self.view);
        });
    }
}

#pragma mark - 允许录屏/投屏（仅验证成功后启用）

// swizzle -[UIScreen isCaptured] -> 返回 NO
static BOOL (*orig_isCaptured)(UIScreen *, SEL);
static BOOL kn_swz_isCaptured(UIScreen *self, SEL _cmd) {
    if (gFeatureEnabled) {
        return NO; // 验证通过后，永远告知“没被录屏/投屏”
    }
    return orig_isCaptured(self, _cmd);
}

// 某些 App 会观察 UIScreenCapturedDidChangeNotification，这里在验证通过后发一次“未捕获”的刷新
static void kn_postUncapturedIfNeeded(void) {
    if (!gFeatureEnabled) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:UIScreenCapturedDidChangeNotification object:[UIScreen mainScreen]];
    });
}

#pragma mark - swizzle 辅助

static void kn_swizzle(Class cls, SEL sel, IMP newImp, IMP *storeOrig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (storeOrig) *storeOrig = old;
    method_setImplementation(m, newImp);
}

#pragma mark - 入口

__attribute__((constructor))
static void knpatch_entry(void) {
    // 限定包名
    NSString *bid = [NSBundle mainBundle].bundleIdentifier ?: @"";
    if (![bid isEqualToString:kBundleLimit]) return;

    // 冷启动未验证：安排弹窗（避开开屏）
    kn_presentVerifyAlertIfNeeded();

    // Hook：addSubview & viewDidAppear（保留你的去水印触发逻辑）
    kn_swizzle(UIView.class, @selector(addSubview:), (IMP)kn_swz_addSubview, (IMP *)&orig_addSubview);
    kn_swizzle(UIViewController.class, @selector(viewDidAppear:), (IMP)kn_swz_viewDidAppear, (IMP *)&orig_viewDidAppear);

    // Hook：UIScreen isCaptured（录屏/投屏检测）
    kn_swizzle(UIScreen.class, @selector(isCaptured), (IMP)kn_swz_isCaptured, (IMP *)&orig_isCaptured);

    // App 激活时机再做一次验证提示（兜底）
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(__unused NSNotification * _Nonnull note) {
        kn_presentVerifyAlertIfNeeded();
        kn_postUncapturedIfNeeded();
    }];
}
