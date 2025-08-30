// KnPatch.m —— 在不改动你原有去水印逻辑的前提下，增加“卡密验证”开关
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - ===== 可按需调整的配置 =====
static NSString * const kKNLicenseCheckURL = @"http://162.14.67.110:8080/check"; // 你的验证接口
static NSString * const kKNUserDefaultsKey = @"kn.lic.key";                      // 本地保存卡密的键
static NSString * const kKNCachedOKKey     = @"kn.lic.ok.cache";                 // 缓存是否通过
static NSString * const kKNCachedExpKey    = @"kn.lic.exp.cache";                // 缓存过期时间（服务端返回）
static NSString * const kKNCachedTSKey     = @"kn.lic.ts.cache";                 // 本地校验时间戳
static const NSTimeInterval kKNCacheTTL    = 4 * 3600;                           // 本地结果缓存 4 小时

#pragma mark - ===== 你原有的工具函数（未改动） =====
// 小工具：判断并隐藏“纯数字/冒号”的 UILabel
static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;
    // 1) 自身是纯数字的 UILabel
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *t = lbl.text ?: @"";
        // 只允许 0–9 和 “:” 组合（避免误伤普通文案）
        if (t.length <= 8 && t.length >= 8) {
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789:"];
            NSString *trim = [[t componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
            if ([trim isEqualToString:t]) {
                lbl.hidden = YES;
                lbl.alpha = 0.0;
                lbl.userInteractionEnabled = NO;
            }
        }
    }
    // 2) 递归检测子视图
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}

#pragma mark - ===== 你原有的 Hook（未改动） =====
static void (*kn_ori_didAddSubview)(UIView *, SEL, UIView *);
static void kn_swz_didAddSubview(UIView *self, SEL _cmd, UIView *sub) {
    kn_ori_didAddSubview(self, _cmd, sub);
    // 仅在目标 App 内处理，避免影响系统/其他 App
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid containsString:@"kuniu"]) {   // 你原逻辑中的“包含 kuni u”判断保留
        kn_hideDigitsInView(sub);
    }
}

static void (*kn_ori_viewDidAppear)(UIViewController *, SEL, BOOL);
static void kn_swz_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    kn_ori_viewDidAppear(self, _cmd, animated);
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid containsString:@"kuniu"]) {
        // 进入页面后异步补刀
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(self.view);
        });
    }
}

static void kn_swizzle(Class cls, SEL sel, SEL newSel) {
    Method m1 = class_getInstanceMethod(cls, sel);
    Method m2 = class_getInstanceMethod(cls, newSel);
    if (!m1 || !m2) return;
    BOOL added = class_addMethod(cls, sel, method_getImplementation(m2), method_getTypeEncoding(m2));
    if (added) {
        class_replaceMethod(cls, newSel, method_getImplementation(m1), method_getTypeEncoding(m1));
    } else {
        method_exchangeImplementations(m1, m2);
    }
}

#pragma mark - ====== 轻量卡密系统（新增） ======
static UIViewController *kn_topMostVC(void) {
    UIWindow *keyWin = nil;
    for (UIWindowScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (sc.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in sc.windows) {
                if (w.isKeyWindow) { keyWin = w; break; }
            }
        }
    }
    if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;
    UIViewController *root = keyWin.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    return root;
}

/// 读取 / 保存本地 Key
static NSString *kn_readLocalKey(void) {
    return [[NSUserDefaults standardUserDefaults] stringForKey:kKNUserDefaultsKey];
}
static void kn_saveLocalKey(NSString *key) {
    if (!key) return;
    [[NSUserDefaults standardUserDefaults] setObject:key forKey:kKNUserDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

/// 简单缓存（避免每次都打到服务器）
static void kn_cacheResult(BOOL ok, NSTimeInterval expTS) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:ok forKey:kKNCachedOKKey];
    [ud setDouble:expTS forKey:kKNCachedExpKey];
    [ud setDouble:[[NSDate date] timeIntervalSince1970] forKey:kKNCachedTSKey];
    [ud synchronize];
}
static BOOL kn_cacheStillValid(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL ok = [ud boolForKey:kKNCachedOKKey];
    NSTimeInterval ts = [ud doubleForKey:kKNCachedTSKey];
    NSTimeInterval exp = [ud doubleForKey:kKNCachedExpKey];
    if (!ok) return NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 服务端没过期 + 本地缓存没超过 TTL
    return (now < exp) && (now - ts < kKNCacheTTL);
}

/// 同步请求校验（带 5s 超时）
static BOOL kn_verifyWithServer(NSString *key, NSString *bundle, NSTimeInterval *outExp) {
    if (!key.length || !bundle.length) return NO;

    NSURL *url = [NSURL URLWithString:kKNLicenseCheckURL];
    if (!url) return NO;

    NSDictionary *body = @{@"key": key, @"bundle": bundle};
    NSData *postData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = postData;

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    cfg.timeoutIntervalForRequest = 5;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __block BOOL passed = NO;
    __block NSTimeInterval expAt = 0;

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]]) {
                NSNumber *ok = json[@"ok"];
                NSNumber *expires = json[@"expires_at"];
                if (ok.boolValue && expires) {
                    passed = YES;
                    expAt = expires.doubleValue;
                }
            }
        }
        dispatch_semaphore_signal(sema);
    }] resume];

    // 最多等 6 秒
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC));
    dispatch_semaphore_wait(sema, timeout);

    if (outExp) *outExp = expAt;
    return passed;
}

/// 弹窗输入 Key（第一次或失效时）
static void kn_promptForKey(NSString *bundle, void (^done)(BOOL ok)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = kn_topMostVC();
        if (!top) { if (done) done(NO); return; }

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"授权验证"
                                                                    message:@"请输入卡密（联系卖家获取）"
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
            tf.placeholder = @"输入卡密";
            tf.secureTextEntry = NO;
            tf.text = @"";
        }];
        [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction * _Nonnull a) {
            if (done) done(NO);
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"验证" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction * _Nonnull a) {
            NSString *key = ac.textFields.firstObject.text ?: @"";
            if (!key.length) { if (done) done(NO); return; }
            NSTimeInterval exp = 0;
            BOOL ok = kn_verifyWithServer(key, bundle, &exp);
            if (ok) {
                kn_saveLocalKey(key);
                kn_cacheResult(YES, exp);
            }
            if (done) done(ok);
        }]];

        [top presentViewController:ac animated:YES completion:nil];
    });
}

/// 对外：是否允许继续执行原逻辑
static BOOL kn_isLicenseOK(void) {
    NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (bundle.length == 0) return NO;

    // 先看缓存
    if (kn_cacheStillValid()) return YES;

    // 看本地是否有 key
    NSString *key = kn_readLocalKey();
    if (key.length > 0) {
        NSTimeInterval exp = 0;
        BOOL ok = kn_verifyWithServer(key, bundle, &exp);
        if (ok) {
            kn_cacheResult(YES, exp);
            return YES;
        }
    }

    // 没有 key 或校验失败 -> 弹窗输入（阻塞等待一次）
    __block BOOL finalOK = NO;
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    kn_promptForKey(bundle, ^(BOOL ok){
        finalOK = ok;
        dispatch_semaphore_signal(sema);
    });
    // 最多等 30 秒（用户操作）
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC));
    dispatch_semaphore_wait(sema, timeout);
    return finalOK;
}

#pragma mark - ===== 入口：只在鉴权成功后，才执行你原有 Hook =====
__attribute__((constructor))
static void kn_init(void) {
    // 鉴权失败 -> 不做任何 Hook（等于插件失效）
    if (!kn_isLicenseOK()) return;

    // 通过后，执行你原来的 Hook 逻辑（未改动）
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kn_swizzle(UIView.class, @selector(didAddSubview:), @selector(kn_swz_didAddSubview:));
        kn_swizzle(UIViewController.class, @selector(viewDidAppear:), @selector(kn_swz_viewDidAppear:));
    });
}
