// KnPatch.m — 进入就隐藏骚扰数字水印 + 录屏/投屏放行 + 卡密验证（POST）

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - 可改配置
#define KN_SERVER_URL  @"http://162.14.67.110:8080/check"   // 你的校验服务
#define KN_BUNDLE_ID   @"net.kuniu"                        // 目标包名
#define KN_UDEF_OK_KEY @"kn.lic.ok"                        // 本地已通过
#define KN_UDEF_EXP    @"kn.lic.exp"                       // 过期时间戳
#define KN_UDEF_LAST   @"kn.lic.lastcheck"                 // 上次复查时间
#define KN_RECHECK_SEC (12*60*60)                          // 12 小时复查一次

static BOOL kn_isLicensed = NO;

#pragma mark - 简易 swizzle
static void kn_swizzle(Class c, SEL old, SEL new) {
    Method m1 = class_getInstanceMethod(c, old);
    Method m2 = class_getInstanceMethod(c, new);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - 工具：隐藏数字/号码样式的 UILabel
static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;

    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *txt = lbl.text ?: @"";
        // 典型手机号/UID长度 6~11 之间，以数字为主
        if (txt.length > 5 && txt.length < 12) {
            NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"];
            NSString *digits = [[txt componentsSeparatedByCharactersInSet:allowed.invertedSet] componentsJoinedByString:@""];
            if (digits.length == txt.length) {
                // 全是数字 → 水印概率高：隐藏
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

#pragma mark - 录屏/投屏放行（不过度干预）
/**
 * 有些 App 会依据 -[UIScreen isCaptured] 拦截录屏/投屏；
 * 我们仅在「授权通过」时返回 NO（表示未被捕获），以放行。
 */
@interface UIScreen (KN_Bypass)
@end
@implementation UIScreen (KN_Bypass)
- (BOOL)kn_isCaptured {
    if (kn_isLicensed) { return NO; }
    // 未授权时按系统原样
    return [self kn_isCaptured];
}
@end

/**
 * 部分播放器会把 allowsExternalPlayback 关掉；
 * 我们只做「不关」的策略：如果传 NO 就忽略，避免强制外接导致的黑屏。
 */
@interface AVPlayer (KN_External)
@end
@implementation AVPlayer (KN_External)
- (void)kn_setAllowsExternalPlayback:(BOOL)flag {
    if (kn_isLicensed) {
        if (!flag) { // 不允许时忽略，保持现状
            return;
        }
    }
    [self kn_setAllowsExternalPlayback:flag];
}
- (BOOL)kn_allowsExternalPlayback {
    BOOL ori = [self kn_allowsExternalPlayback];
    return kn_isLicensed ? YES : ori;
}
@end

#pragma mark - Hook：UIView 的 didAddSubview，边加边扫
@interface UIView (KN_Hook)
@end
@implementation UIView (KN_Hook)
- (void)kn_didAddSubview:(UIView *)v {
    [self kn_didAddSubview:v]; // 调原方法
    if (!kn_isLicensed) return;

    // 仅对指定 App 生效
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;

    kn_hideDigitsInView(v);
}
@end

#pragma mark - Hook：UIViewController 的 viewDidAppear，再扫一遍保险
@interface UIViewController (KN_Hook)
@end
@implementation UIViewController (KN_Hook)
- (void)kn_viewDidAppear:(BOOL)animated {
    [self kn_viewDidAppear:animated];
    if (!kn_isLicensed) return;

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;

    // 有些页面首帧晚到，延迟一丢丢再扫
    dispatch_async(dispatch_get_main_queue(), ^{
        kn_hideDigitsInView(self.view);
    });
}
@end

#pragma mark - 网络：POST /check
static void kn_postCheck(NSString *key, void (^cb)(BOOL ok, NSTimeInterval expTS)) {
    if (key.length == 0) { if (cb) cb(NO, 0); return; }

    NSDictionary *payload = @{@"bundle": KN_BUNDLE_ID, @"key": key};
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:KN_SERVER_URL]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        if (err || !data) { if (cb) cb(NO, 0); return; }
        NSDictionary *resp = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        BOOL ok = [resp[@"ok"] boolValue];
        NSTimeInterval exp = 0;
        if ([resp[@"expires_at"] respondsToSelector:@selector(doubleValue)]) {
            exp = [resp[@"expires_at"] doubleValue];
        }
        if (cb) cb(ok, exp);
    }] resume];
}

#pragma mark - 授权弹窗
static void kn_promptLicenseIfNeeded(void (^onOK)(void)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *root = [UIApplication sharedApplication].keyWindow.rootViewController;
        if (!root) {
            // 冷启动广告页时 root 可能还没就绪，循环等
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                kn_promptLicenseIfNeeded(onOK);
            });
            return;
        }

        UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"请输入卡密"
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"粘贴/输入卡密";
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
        }];

        [ac addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            NSString *raw = ac.textFields.firstObject.text ?: @"";
            // 清洗不可见字符/空格
            NSString *key = [[raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] stringByReplacingOccurrencesOfString:@" " withString:@""];
            for (NSString *z in @[@"\u200B", @"\u200C", @"\u200D", @"\uFEFF"]) {
                key = [key stringByReplacingOccurrencesOfString:z withString:@""];
            }
            key = key.lowercaseString;

            kn_postCheck(key, ^(BOOL ok, NSTimeInterval expTS) {
                if (ok) {
                    kn_isLicensed = YES;
                    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                    [ud setBool:YES forKey:KN_UDEF_OK_KEY];
                    if (expTS > 0) [ud setDouble:expTS forKey:KN_UDEF_EXP];
                    [ud setDouble:[[NSDate date] timeIntervalSince1970] forKey:KN_UDEF_LAST];
                    [ud synchronize];
                    if (onOK) onOK();
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"验证失败"
                                                                                     message:@"请检查卡密/网络后重试"
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                        [fail addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                            kn_promptLicenseIfNeeded(onOK);
                        }]];
                        [[UIApplication sharedApplication].keyWindow.rootViewController presentViewController:fail animated:YES completion:nil];
                    });
                }
            });
        }]];

        [ac addAction:[UIAlertAction actionWithTitle:@"退出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            exit(0);
        }]];

        [root presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - 启动入口：做授权 & 安装 hook
__attribute__((constructor))
static void kn_entry(void) {
    // 安装 swizzle
    kn_swizzle([UIView class], @selector(didAddSubview:), @selector(kn_didAddSubview:));
    kn_swizzle([UIViewController class], @selector(viewDidAppear:), @selector(kn_viewDidAppear:));
    kn_swizzle([UIScreen class], @selector(isCaptured), @selector(kn_isCaptured));
    kn_swizzle([AVPlayer class], @selector(setAllowsExternalPlayback:), @selector(kn_setAllowsExternalPlayback:));
    kn_swizzle([AVPlayer class], @selector(allowsExternalPlayback), @selector(kn_allowsExternalPlayback));

    // 仅目标包生效
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid isEqualToString:KN_BUNDLE_ID]) return;

    // 读本地授权状态
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL cachedOK = [ud boolForKey:KN_UDEF_OK_KEY];
    NSTimeInterval exp = [ud doubleForKey:KN_UDEF_EXP];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval last = [ud doubleForKey:KN_UDEF_LAST];

    if (cachedOK && (exp <= 0 || now < exp)) {
        kn_isLicensed = YES;

        // 距离上次复查超过阈值，静默复查一次（不弹窗）
        if (now - last > KN_RECHECK_SEC) {
            NSString *placeholderKey = @"cached_key"; // 如需做无感刷新，可把最近一次成功 key 存起来再带上
            // 这里不存 key，简单跳过；需要的话自行扩展：存 kn.lic.key，然后带着去 check
            [ud setDouble:now forKey:KN_UDEF_LAST];
            [ud synchronize];
            (void)placeholderKey;
        }
        return;
    }

    // 否则弹窗走验证
    kn_promptLicenseIfNeeded(^{
        // 通过后不需要做什么，所有 Hook 已经就位
    });
}
