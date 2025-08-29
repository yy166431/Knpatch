// KnPatch.m
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Swizzle helper
static void kn_swizzle(Class c, SEL o, SEL n) {
    Method m1 = class_getInstanceMethod(c, o);
    Method m2 = class_getInstanceMethod(c, n);
    if (m1 && m2) method_exchangeImplementations(m1, m2);
}

#pragma mark - 水印隐藏（按需要微调）
static BOOL kn_isDigits(NSString *s) {
    if (!s) return NO;
    if (s.length < 3 || s.length > 12) return NO; // 依你的视频数字特征可再调
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c < '0' || c > '9') return NO;
    }
    return YES;
}

static void kn_hideDigitsInView(UIView *v) {
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *lab = (UILabel *)v;
        if (kn_isDigits(lab.text)) {
            lab.hidden = YES;
            lab.alpha = 0.0;
            v.layer.opacity = 0.0;
            v.userInteractionEnabled = NO;
        }
    }
    for (UIView *sub in v.subviews) kn_hideDigitsInView(sub);
}

// 只在较大的内容视图上扫描，避免性能抖动；如你知道具体容器类名，也可改成只对特定类扫描
@implementation UIView (KN_HideWatermark)
- (void)kn_didMoveToWindow {
    [self kn_didMoveToWindow];
    if (self.window && self.bounds.size.height > 200 && self.bounds.size.width > 200) {
        kn_hideDigitsInView(self);
    }
}
@end

#pragma mark - 录屏/投屏检测绕过
@implementation UIScreen (KN_CaptureBypass)
- (BOOL)kn_isCaptured {
    // 始终返回 NO：允许录屏与镜像（App 看到的是“没在录屏/投屏”）
    return NO;
}
@end

#pragma mark - 仅在“真的有外接设备”时，允许 AVPlayer 外接播放
static BOOL kn_hasExternalRoute(void) {
    AVAudioSessionRouteDescription *route = [AVAudioSession sharedInstance].currentRoute;
    for (AVAudioSessionPortDescription *o in route.outputs) {
        if ([o.portType isEqualToString:AVAudioSessionPortAirPlay] ||
            [o.portType isEqualToString:AVAudioSessionPortHDMI]  ||
            [o.portType isEqualToString:AVAudioSessionPortLineOut]) {
            return YES;
        }
    }
    return NO;
}

// 方便给当前 player 按需配置
static void kn_configurePlayerForExternal(AVPlayer *p) {
    if (!p) return;
    BOOL ext = kn_hasExternalRoute();
    // 外接存在→允许外接播放；否则遵循 App 自己逻辑（保持现状）
    if (ext) {
        @try {
            p.allowsExternalPlayback = YES;
            if ([p respondsToSelector:@selector(setUsesExternalPlaybackWhileExternalScreenIsActive:)]) {
                [p setUsesExternalPlaybackWhileExternalScreenIsActive:YES];
            }
        } @catch (__unused NSException *e) {}
    }
}

// swizzle init & setter，保证“有外接时”我们帮它开，没外接就不干预，避免黑屏
@implementation AVPlayer (KN_SafeExternal)

- (instancetype)kn_init {
    id obj = [self kn_init];
    kn_configurePlayerForExternal(obj);
    return obj;
}

- (instancetype)kn_initWithPlayerItem:(AVPlayerItem *)item {
    id obj = [self kn_initWithPlayerItem:item];
    kn_configurePlayerForExternal(obj);
    return obj;
}

// 只在有外接时把 flag 改成 YES，没外接就用原 flag，不破坏全屏
- (void)kn_setAllowsExternalPlayback:(BOOL)flag {
    BOOL ext = kn_hasExternalRoute();
    [self kn_setAllowsExternalPlayback:(ext ? YES : flag)];
}

@end

#pragma mark - 监听音频路由变化，外接出现/消失时给“未来的播放器”走正确分支
static void kn_onRouteChange(NSNotification *note) {
    // 这里只是为后续新建的 AVPlayer 提前确定策略；已有实例是否需要立即切换，交给 App 自己调用 setter。
    // 如果你想更激进地“遍历并更新所有 AVPlayer 实例”，需要额外维护弱引用表，不建议在通用补丁里做。
    (void)note;
}

__attribute__((constructor))
static void kn_init(void) {
    // 去水印 + 录屏绕过
    kn_swizzle([UIView class], @selector(didMoveToWindow), @selector(kn_didMoveToWindow));
    kn_swizzle([UIScreen class], @selector(isCaptured), @selector(kn_isCaptured));

    // AVPlayer：仅在有外接设备时，打开外接播放；否则不干预，避免黑屏
    kn_swizzle([AVPlayer class], @selector(init), @selector(kn_init));
    kn_swizzle([AVPlayer class], @selector(initWithPlayerItem:), @selector(kn_initWithPlayerItem:));
    kn_swizzle([AVPlayer class], @selector(setAllowsExternalPlayback:), @selector(kn_setAllowsExternalPlayback:));

    // 路由变化监听（给将来新建的 player 做正确配置）
    [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification * _Nonnull n) {
        kn_onRouteChange(n);
    }];
}
