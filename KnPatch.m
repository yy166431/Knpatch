// KnPatch.m  — 进入就隐藏数字水印 + 持续拦截新加入的水印视图
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - 小工具：判断并隐藏“纯数字/冒号”的Label
static void kn_hideDigitsInView(UIView *v) {
    if (!v) return;
    // 1) 自身是数字样式的 UILabel
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)v;
        NSString *t = lbl.text ?: @"";
        // 只允许 5~8 个字符，且仅由 0-9 和 : 组成（避免误伤普通文案）
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
    // 2) 继续递归子视图
    for (UIView *sub in v.subviews) {
        kn_hideDigitsInView(sub);
    }
}

#pragma mark - Hook: UIView didAddSubview: 任何新子视图加入都检查一次
static void (*kn_orig_didAddSubview)(UIView *, SEL, UIView *);
static void kn_swz_didAddSubview(UIView *self, SEL _cmd, UIView *sub) {
    kn_orig_didAddSubview(self, _cmd, sub);
    // 只在目标 App 内处理，避免影响系统/其他 App
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid containsString:@"kuniu"]) { // 你的 App 包名里含 “kuniu”，可按需改更严格
        kn_hideDigitsInView(sub);
    }
}

#pragma mark - Hook: UIViewController viewDidAppear: 进入页面立即全量扫描
static void (*kn_orig_viewDidAppear)(UIViewController *, SEL, BOOL);
static void kn_swz_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    kn_orig_viewDidAppear(self, _cmd, animated);
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if ([bid containsString:@"kuniu"]) {
        // 马上在主线程扫一次（尽早把首帧的数字干掉）
        dispatch_async(dispatch_get_main_queue(), ^{
            kn_hideDigitsInView(self.view);
        });
    }
}

#pragma mark - 录屏绕过 & 允许外接播放（保留你已有逻辑，也给一份简单可用的）
static BOOL kn_isCaptured(id self, SEL _cmd) { return NO; }
static BOOL kn_allowsExternalPlayback(id self, SEL _cmd) { return YES; }

static void kn_swizzle(Class cls, SEL a, SEL b) {
    Method m1 = class_getInstanceMethod(cls, a);
    Method m2 = class_getInstanceMethod(cls, b);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

__attribute__((constructor))
static void kn_init(void) {
    // 仅在目标 App 里启用
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    if (![bid containsString:@"kuniu"]) return;

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

    // 4) 允许外接播放（投屏）
    {
        Method m = class_getInstanceMethod([AVPlayer class], @selector(allowsExternalPlayback));
        if (m) class_replaceMethod([AVPlayer class], @selector(allowsExternalPlayback),
                                   (IMP)kn_allowsExternalPlayback, method_getTypeEncoding(m));
    }
}
