#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

#pragma mark - swizzle helper
static void kn_swizzle(Class c, SEL old, SEL new) {
    Method m1 = class_getInstanceMethod(c, old);
    Method m2 = class_getInstanceMethod(c, new);
    if (!m1 || !m2) return;
    method_exchangeImplementations(m1, m2);
}

#pragma mark - 工具：判断“疑似水印”的 UILabel
static BOOL kn_isWatermarkLabel(UILabel *lab) {
    if (!lab) return NO;
    NSString *t = lab.text;
    if (![t isKindOfClass:NSString.class]) return NO;
    if (t.length == 0) return NO;

    // 规则 1：包含这些关键词（可按需增删）
    static NSArray<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[@"watermark", @"Watermark", @"WM", @"标识", @"水印", @"UID", @"ID",
                 @"kuniu", @"kuniu", @"kuniu",
                 @"douyin", @"抖音", @"快手", @"ks", @"wechat", @"weixin"];
    });
    for (NSString *k in keys) {
        if ([t rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }

    // 规则 2：一串 6~18 位纯数字（常见 UID/手机号样式）
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    NSCharacterSet *notDigits = [digits invertedSet];
    if ([t rangeOfCharacterFromSet:notDigits].location == NSNotFound) {
        if (t.length >= 6 && t.length <= 18) return YES;
    }

    // 规则 3：非常浅的颜色 + 高 alpha 也可能是水印（保守处理）
    CGFloat a = 1.0;
    if (lab.textColor) {
        [lab.textColor getRed:NULL green:NULL blue:NULL alpha:&a];
        if (a < 0.35) return YES;
    }

    return NO;
}

static BOOL kn_viewLooksLikeWatermark(UIView *v) {
    if (!v) return NO;
    NSString *cls = NSStringFromClass(v.class);
    // 类名中出现 watermark/wm 等
    NSArray *marks = @[@"Watermark", @"watermark", @"WM", @"wm", @"Mark", @"mark"];
    for (NSString *m in marks) {
        if ([cls rangeOfString:m options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    // 小尺寸角落元素也可能是水印（可选，保守）
    CGSize sz = v.bounds.size;
    if (sz.width <= 160 && sz.height <= 80) {
        CGPoint org = [v.superview convertPoint:v.frame.origin toView:v.window];
        if (org.x <= 30 || org.y <= 30) return YES; // 左上角
    }
    return NO;
}

static void kn_hideWatermarkInView(UIView *root) {
    if (!root) return;

    if ([root isKindOfClass:UILabel.class]) {
        UILabel *lab = (UILabel *)root;
        if (kn_isWatermarkLabel(lab)) {
            lab.hidden = YES;           // 隐藏
            lab.alpha  = 0.0;
            lab.layer.opacity = 0.0;
            lab.userInteractionEnabled = NO;
            return;
        }
    } else {
        if (kn_viewLooksLikeWatermark(root)) {
            root.hidden = YES;
            root.alpha  = 0.0;
            root.layer.opacity = 0.0;
            root.userInteractionEnabled = NO;
            return;
        }
    }

    for (UIView *sub in root.subviews) {
        kn_hideWatermarkInView(sub);
    }
}

#pragma mark - 钩 UIView 的 didMoveToWindow，在每次入窗时清一次
@interface UIView (KnPatch)
@end

@implementation UIView (KnPatch)
- (void)kn_didMoveToWindow {
    [self kn_didMoveToWindow]; // 调用原实现
    // 安全地延时处理，以确保层级稳定
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        kn_hideWatermarkInView(self);
    });
}
@end

#pragma mark - 允许外接播放（某些 App 禁止投屏）
@interface AVPlayer (KnPatch)
@end
@implementation AVPlayer (KnPatch)
- (BOOL)kn_allowsExternalPlayback { return YES; }
- (void)kn_setAllowsExternalPlayback:(BOOL)flag { [self kn_setAllowsExternalPlayback:YES]; }
@end

#pragma mark - 屏幕录制检测绕过（isCaptured→NO）
@interface UIScreen (KnPatch)
@end
@implementation UIScreen (KnPatch)
- (BOOL)kn_isCaptured { return NO; }
@end

#pragma mark - 注入入口
__attribute__((constructor))
static void kn_init(void) {
    // UIView didMoveToWindow
    kn_swizzle(UIView.class, @selector(didMoveToWindow), @selector(kn_didMoveToWindow));

    // UIScreen -isCaptured
    kn_swizzle(UIScreen.class, @selector(isCaptured), @selector(kn_isCaptured));

    // AVPlayer 允许外接播放
    kn_swizzle(AVPlayer.class, @selector(allowsExternalPlayback), @selector(kn_allowsExternalPlayback));
    kn_swizzle(AVPlayer.class, @selector(setAllowsExternalPlayback:), @selector(kn_setAllowsExternalPlayback:));
}
