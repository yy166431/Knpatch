// KnPatch.m  — 进入就隐藏数字水印 + 持续拦截新加入的水印视图 + 服务器卡密校验（异步、非阻塞）

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - ===== 可按需修改的配置 =====
static NSString *const kKn_ServerBase = @"http://162.14.67.110:8080";   // 你的校验服务
static NSString *const kKn_BundleHint = @"kuniu";                       // 目标包名包含的关键字
static NSString *const kKn_KeyStore   = @"kn_key";                       // 本地存储的 key 名

#pragma mark - ===== 授权开关 & 原始 IMP 保存 =====
static BOOL g_knLicensed = NO;                     // 授权通过后置 YES
static BOOL g_knPrompted = NO;                     // 只弹一次输入框

static BOOL (*orig_isCaptured)(UIScreen *, SEL);   // 保存系统原始实现
static BOOL (*orig_allowsExternalPlayback)(AVPlayer *, SEL);

#pragma mark - ===== 数字水印处理（保持你的原逻辑） =====
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
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}

#pragma mark - ===== didAddSubview: / viewDidAppear: Hook（保留 + 加授权判断） =====
static void (*kn_orig_didAddSubview)(UIView *, SEL, UIView *);
static void kn_swz_didAddSubview(UIView *self, SEL _cmd, UIView *sub) {
    kn_orig_didAddSubview(self, _cmd, sub);
    if (!g_knLicensed) return; // 未授权不动
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid containsString:kKn_BundleHint]) {
        kn_hideDigitsInView(sub);
    }
}

static void (*kn_orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void kn_swz_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    kn_orig_viewDidAppear(self, _cmd, animated);

    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid containsString:kKn_BundleHint]) return;

    // 授权通过才做一次全量清理
    if (g_knLicensed) {
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(self.view);
        });
        return;
    }

    // 首次进入页面时，给用户一次输入卡密的机会（不阻塞）
    if (!g_knPrompted) {
        g_knPrompted = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIViewController *vc = self;
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"输入卡密"
                                                                        message:@"请粘贴你的授权码后“验证”"
                                                                 preferredStyle:UIAlertControllerStyleAlert];
            [ac addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
                tf.placeholder = @"粘贴卡密...";
                tf.clearButtonMode = UITextFieldViewModeWhileEditing;
                tf.text = [[NSUserDefaults standardUserDefaults] stringForKey:kKn_KeyStore] ?: @"";
            }];

            [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [ac addAction:[UIAlertAction actionWithTitle:@"验证" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull a) {
                NSString *key = ac.textFields.firstObject.text ?: @"";
                key = [key stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (key.length == 0) return;
                [[NSUserDefaults standardUserDefaults] setObject:key forKey:kKn_KeyStore];

                // 走异步校验
                NSString *bundle = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
                NSString *qs = [NSString stringWithFormat:@"/check?bundle=%@&key=%@", bundle, key];
                NSString *urlStr = [kKn_ServerBase stringByAppendingString:[qs stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

                NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
                cfg.timeoutIntervalForRequest = 3.0; // 3 秒超时
                NSURLSession *ssn = [NSURLSession sessionWithConfiguration:cfg];

                NSURLSessionDataTask *task = [ssn dataTaskWithURL:[NSURL URLWithString:urlStr]
                                                completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    BOOL ok = NO;
                    if (!err && data.length) {
                        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                        if ([json isKindOfClass:[NSDictionary class]]) {
                            ok = [json[@"ok"] boolValue];
                        }
                    }
                    if (ok) {
                        g_knLicensed = YES;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            // 立刻清一次画面
                            kn_hideDigitsInView(vc.view);
                            UIAlertController *done = [UIAlertController alertControllerWithTitle:@"验证成功" message:nil preferredStyle:UIAlertControllerStyleAlert];
                            [vc presentViewController:done animated:YES completion:^{
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                    [done dismissViewControllerAnimated:YES completion:nil];
                                });
                            }];
                        });
                    } else {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"验证失败"
                                                                                         message:@"请核对卡密/网络后重试"
                                                                                  preferredStyle:UIAlertControllerStyleAlert];
                            [fail addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleCancel handler:nil]];
                            [vc presentViewController:fail animated:YES completion:nil];
                        });
                    }
                }];
                [task resume];
            }]];
            [vc presentViewController:ac animated:YES completion:nil];
        });
    }
}

#pragma mark - ===== 录屏 & 外接播放：按授权决定，未授权走系统原始实现 =====
static BOOL kn_isCaptured(id selfObj, SEL _cmd) {
    if (g_knLicensed) return NO;                  // 授权后：报告“未被捕获”，从而允许系统录屏
    if (orig_isCaptured) return orig_isCaptured(selfObj, _cmd);  // 未授权：保持系统原样
    return ((UIScreen *)selfObj).captured;        // 兜底
}

static BOOL kn_allowsExternalPlayback_swz(id selfObj, SEL _cmd) {
    if (g_knLicensed) return YES;                 // 授权后：允许外接播放(投屏)
    if (orig_allowsExternalPlayback) return orig_allowsExternalPlayback(selfObj, _cmd);
    return YES;                                   // 兜底（通常为 YES）
}

#pragma mark - ===== 安全交换工具 =====
static void kn_replaceInstanceMethod(Class cls, SEL sel, IMP newImp, IMP *oldOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    IMP old = method_getImplementation(m);
    if (oldOut) *oldOut = (IMP)old;
    class_replaceMethod(cls, sel, newImp, method_getTypeEncoding(m));
}

__attribute__((constructor))
static void kn_init(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid containsString:kKn_BundleHint]) return;

    // 读取本地 key（如果之前输入过）
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:kKn_KeyStore];
    if (saved.length) {
        // 异步自检，不阻塞首帧
        NSString *qs = [NSString stringWithFormat:@"/check?bundle=%@&key=%@", bid, saved];
        NSString *urlStr = [kKn_ServerBase stringByAppendingString:[qs stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 2.5;
        NSURLSession *ssn = [NSURLSession sessionWithConfiguration:cfg];
        [[ssn dataTaskWithURL:[NSURL URLWithString:urlStr]
            completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                if (!err && data.length) {
                    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([json isKindOfClass:[NSDictionary class]] && [json[@"ok"] boolValue]) {
                        g_knLicensed = YES;
                    }
                }
        }] resume];
    }

    // 1) UIView didAddSubview:
    kn_replaceInstanceMethod([UIView class], @selector(didAddSubview:), (IMP)kn_swz_didAddSubview, (IMP *)&kn_orig_didAddSubview);

    // 2) UIViewController viewDidAppear:
    kn_replaceInstanceMethod([UIViewController class], @selector(viewDidAppear:), (IMP)kn_swz_viewDidAppear, (IMP *)&kn_orig_viewDidAppear);

    // 3) 录屏：保存原始实现，按授权切换
    kn_replaceInstanceMethod([UIScreen class], @selector(isCaptured), (IMP)kn_isCaptured, (IMP *)&orig_isCaptured);

    // 4) 外接播放：保存原始实现，按授权切换
    kn_replaceInstanceMethod([AVPlayer class], @selector(allowsExternalPlayback), (IMP)kn_allowsExternalPlayback_swz, (IMP *)&orig_allowsExternalPlayback);
}
