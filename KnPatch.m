// KnPatch.m
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - 简单交换工具
static void kn_swizzle(Class c, SEL o, SEL n) {
    Method m1 = class_getInstanceMethod(c, o);
    Method m2 = class_getInstanceMethod(c, n);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - 去水印（按需调参/换类名）
static BOOL kn_isDigitsString(NSString *s) {
    if (!s) return NO;
    if (s.length < 4 || s.length > 14) return NO; // 你的视频一般是“93xxx”一类的数字，可按需要微调
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static void kn_hideDigitsInView(UIView *v) {
    // 方案A：文本水印（UILabel）
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lab = (UILabel *)v;
        if (kn_isDigitsString(lab.text)) {
            lab.hidden = YES;
            lab.alpha = 0.0;
            v.layer.opacity = 0.0;
            v.userInteractionEnabled = NO;
        }
    }
    // 方案B：如果你已经确认了水印具体类名，可以直接判断类名更精准，比如：
    // if ([NSStringFromClass(v.class) isEqualToString:@"SBSWatermarkView"]) { v.hidden = YES; v.alpha = 0; }

    for (UIView *sub in v.subviews) kn_hideDigitsInView(sub);
}

@implementation UIView (KN_HideWatermark)
- (void)kn_didMoveToWindow {
    [self kn_didMoveToWindow];
    // 只在比较“像视频区域”的大视图出现时扫描，避免性能问题
    if (self.window && self.bounds.size.height > 200) {
        kn_hideDigitsInView(self);
    }
}
@end

#pragma mark - 解除录屏/镜像检测（投屏需要）
@implementation UIScreen (KN_CaptureBypass)
- (BOOL)kn_isCaptured {
    // 始终返回 NO，让 App 认为未被录屏/镜像，从而放行投屏/录屏
    return NO;
}
@end

#pragma mark - 投屏（外接播放）安全开启
// 只有检测到真的有外接/AirPlay 路由时，才允许外接播放；否则保持 App 原逻辑避免全屏黑屏
static BOOL kn_hasExternalRoute(void) {
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *o in route.outputs) {
        if ([o.portType isEqualToString:AVAudioSessionPortAirPlay] ||
            [o.portType isEqualToString:AVAudioSessionPortHDMI]   ||
            [o.portType isEqualToString:AVAudioSessionPortLineOut]) {
            return YES;
        }
    }
    return NO;
}

@implementation AVPlayer (KN_SafeExternal)
- (void)kn_setAllowsExternalPlayback:(BOOL)flag {
    // 如果有外接设备/路由，就放开；否则沿用 App 原 flag，避免误走外接播放导致黑屏
    BOOL finalFlag = kn_hasExternalRoute() ? YES : flag;
    [self kn_setAllowsExternalPlayback:finalFlag];
}
@end

// （可选）一些 App 通过 AVPlayerViewController 的配置控制全屏/外接播放
// 如果你遇到进全屏时依然会被误导，放开这段：仅当有外接路由时才“偏向”外接
/*
#import <AVKit/AVKit.h>
@implementation AVPlayerViewController (KN_SafeExternal)
- (void)kn_viewDidAppear:(BOOL)animated {
    [self kn_viewDidAppear:animated];
    if (kn_hasExternalRoute()) {
        // 有外接路由时，允许外接屏时继续在外屏播放
        self.requiresLinearPlayback = NO;
        self.canStartPictureInPictureAutomaticallyFromInline = YES;
    }
}
@end
*/

__attribute__((constructor))
static void kn_init(void) {
    // 去水印
    kn_swizzle([UIView class], @selector(didMoveToWindow), @selector(kn_didMoveToWindow));

    // 录屏/镜像绕过（为“无限投屏/可录屏”服务）
    kn_swizzle([UIScreen class], @selector(isCaptured), @selector(kn_isCaptured));

    // 投屏安全开启（只有检测到外接才放开，否则不干预 App 原逻辑，防止黑屏）
    kn_swizzle([AVPlayer class], @selector(setAllowsExternalPlayback:), @selector(kn_setAllowsExternalPlayback:));

    // （可选）如果你启用上面的 AVPlayerViewController 类别，也要 swizzle：
    // kn_swizzle([AVPlayerViewController class], @selector(viewDidAppear:), @selector(kn_viewDidAppear:));
}
