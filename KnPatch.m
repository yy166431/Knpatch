#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// 简单工具：方法交换
static void kn_swizzle(Class c, SEL o, SEL n) {
    Method m1 = class_getInstanceMethod(c, o);
    Method m2 = class_getInstanceMethod(c, n);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - 去水印（请按你的实际类名/层级微调）
static BOOL isDigits(NSString *s) {
    if (s.length < 6 || s.length > 12) return NO; // 依你的视频上“93xxx”来判定，必要时调整
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static void hideDigitsInView(UIView *v) {
    // 根据你 App 的实际水印视图调整。这里是一个“文本即是数字”的例子：
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lab = (UILabel *)v;
        if (isDigits(lab.text)) {
            lab.hidden = YES;
            lab.alpha = 0.0;
            v.layer.opacity = 0.0;
            v.userInteractionEnabled = NO;
        }
    }
    for (UIView *sub in v.subviews) hideDigitsInView(sub);
}

@implementation UIView (KN_HideWatermark)
- (void)kn_didMoveToWindow {
    [self kn_didMoveToWindow];
    // 将“水印所在的大容器视图”换成你实际的播放器容器（或使用更精确的类名判断）
    // 这里用一个保守做法：只在视频区域较大的时候扫描，避免全局扫描影响性能。
    if (self.window && self.bounds.size.height > 200) {
        hideDigitsInView(self);
    }
}
@end

#pragma mark - 录屏/投屏绕过：isCaptured恒为NO
@implementation UIScreen (KN_CaptureBypass)
- (BOOL)kn_isCaptured {
    return NO; // 解除录屏/投屏检测
}
@end

__attribute__((constructor))
static void kn_init(void) {
    // 视图出现时尝试隐藏数字水印
    kn_swizzle([UIView class], @selector(didMoveToWindow), @selector(kn_didMoveToWindow));
    // 录屏检测绕过
    kn_swizzle([UIScreen class], @selector(isCaptured), @selector(kn_isCaptured));

    // ⚠️ 不再 swizzle AVPlayer 的 allowsExternalPlayback / setAllowsExternalPlayback
    // 这能避免全屏时误走“外接播放”而黑屏。
}
