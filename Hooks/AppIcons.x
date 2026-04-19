#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kAppIconTintTag = 0xA110;

static void *kAppIconRetryKey = &kAppIconRetryKey;
static void *kAppIconGlassKey = &kAppIconGlassKey;
static void *kAppIconTintKey = &kAppIconTintKey;
static void *kAppIconOriginalTransformKey = &kAppIconOriginalTransformKey;
static void *kAppIconLastGlassFrameKey = &kAppIconLastGlassFrameKey;
static void *kAppIconBackdropViewKey = &kAppIconBackdropViewKey;
static const CGFloat kAppIconImageScale = 0.99;
static void LGAppIconsRefreshAllHosts(void);

LG_ENABLED_BOOL_PREF_FUNC(LGAppIconsEnabled, "AppIcons.Enabled", NO)
LG_FLOAT_PREF_FUNC(LGAppIconCornerRadius, "AppIcons.CornerRadius", 13.5)
LG_FLOAT_PREF_FUNC(LGAppIconBezelWidth, "AppIcons.BezelWidth", 14.0)
LG_FLOAT_PREF_FUNC(LGAppIconGlassThickness, "AppIcons.GlassThickness", 80.0)
LG_FLOAT_PREF_FUNC(LGAppIconRefractionScale, "AppIcons.RefractionScale", 1.2)
LG_FLOAT_PREF_FUNC(LGAppIconRefractiveIndex, "AppIcons.RefractiveIndex", 1.0)
LG_FLOAT_PREF_FUNC(LGAppIconSpecularOpacity, "AppIcons.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGAppIconBlur, "AppIcons.Blur", 8.0)
LG_FLOAT_PREF_FUNC(LGAppIconWallpaperScale, "AppIcons.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGAppIconLightTintAlpha, "AppIcons.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGAppIconDarkTintAlpha, "AppIcons.DarkTintAlpha", 0.0)

static BOOL LGIsHomescreenIconImageView(UIView *view) {
    if (!view.window) return NO;
    if (![NSStringFromClass(view.class) isEqualToString:@"SBIconImageView"]) return NO;

    UIView *parent = view.superview;
    UIView *grandparent = parent.superview;
    if (!parent || !grandparent) return NO;
    if (![NSStringFromClass(parent.class) isEqualToString:@"SBFTouchPassThroughView"]) return NO;
    if (![NSStringFromClass(grandparent.class) isEqualToString:@"SBIconView"]) return NO;
    return YES;
}

static UIView *LGAppIconHostView(UIView *view) {
    UIView *host = view.superview;
    return host ?: view;
}

static CGRect LGAppIconGlassFrameInHost(UIView *iconView, UIView *host) {
    if (!iconView || !host) return CGRectZero;
    return [iconView convertRect:iconView.bounds toView:host];
}

static UIColor *appIconTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGAppIconLightTintAlpha(), LGAppIconDarkTintAlpha(), @"AppIcons.TintOverrideMode");
}

static void removeAppIconOverlays(UIView *view) {
    UIView *host = LGAppIconHostView(view);
    LGRemoveAssociatedSubview(host, kAppIconTintKey);

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(host, kAppIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);

    NSValue *originalTransform = objc_getAssociatedObject(view, kAppIconOriginalTransformKey);
    if (originalTransform) {
        view.transform = originalTransform.CGAffineTransformValue;
    } else {
        view.transform = CGAffineTransformIdentity;
    }
    LGRemoveLiveBackdropCaptureView(host, kAppIconBackdropViewKey);
}

static void ensureAppIconTintOverlay(UIView *view) {
    UIView *host = LGAppIconHostView(view);
    CGRect frame = LGAppIconGlassFrameInHost(view, host);
    UIView *tint = LGEnsureTintOverlayView(host,
                                           kAppIconTintKey,
                                           kAppIconTintTag,
                                           frame,
                                           UIViewAutoresizingNone);
    LGConfigureTintOverlayView(tint,
                               appIconTintColorForView(view),
                               LGAppIconCornerRadius(),
                               nil,
                               NO);
    if (@available(iOS 13.0, *)) {
        tint.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [host insertSubview:tint aboveSubview:objc_getAssociatedObject(host, kAppIconGlassKey)];
}

static void injectIntoAppIcon(UIView *view) {
    if (!LGAppIconsEnabled()) {
        removeAppIconOverlays(view);
        return;
    }

    UIView *host = LGAppIconHostView(view);
    CGRect frame = LGAppIconGlassFrameInHost(view, host);
    if (CGRectIsEmpty(frame)) return;

    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper && !LG_prefersLiveCapture(@"AppIcons.RenderingMode")) {
        if ([objc_getAssociatedObject(host, kAppIconRetryKey) boolValue]) return;
        objc_setAssociatedObject(host, kAppIconRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoAppIcon(view);
        });
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc] initWithFrame:frame
                                             wallpaper:wallpaper
                                       wallpaperOrigin:wallpaperOrigin];
        glass.cornerRadius = LGAppIconCornerRadius();
        glass.bezelWidth = LGAppIconBezelWidth();
        glass.glassThickness = LGAppIconGlassThickness();
        glass.refractionScale = LGAppIconRefractionScale();
        glass.refractiveIndex = LGAppIconRefractiveIndex();
        glass.specularOpacity = LGAppIconSpecularOpacity();
        glass.blur = LGAppIconBlur();
        glass.wallpaperScale = LGAppIconWallpaperScale();
        glass.updateGroup = LGUpdateGroupAppIcons;
        [host insertSubview:glass atIndex:0];
        objc_setAssociatedObject(host, kAppIconGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (!objc_getAssociatedObject(view, kAppIconOriginalTransformKey)) {
        objc_setAssociatedObject(view, kAppIconOriginalTransformKey,
                                 [NSValue valueWithCGAffineTransform:view.transform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    view.transform = CGAffineTransformMakeScale(kAppIconImageScale, kAppIconImageScale);

    glass.frame = frame;
    glass.cornerRadius = LGAppIconCornerRadius();
    glass.bezelWidth = LGAppIconBezelWidth();
    glass.glassThickness = LGAppIconGlassThickness();
    glass.refractionScale = LGAppIconRefractionScale();
    glass.refractiveIndex = LGAppIconRefractiveIndex();
    glass.specularOpacity = LGAppIconSpecularOpacity();
    glass.blur = LGAppIconBlur();
    glass.wallpaperScale = LGAppIconWallpaperScale();
    if (!LGApplyRenderingModeToGlassHost(host,
                                         glass,
                                         @"AppIcons.RenderingMode",
                                         kAppIconBackdropViewKey,
                                         wallpaper,
                                         wallpaperOrigin)) {
        objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    objc_setAssociatedObject(host, kAppIconLastGlassFrameKey,
                             [NSValue valueWithCGRect:frame],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ensureAppIconTintOverlay(view);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.window) ensureAppIconTintOverlay(view);
    });
    objc_setAssociatedObject(host, kAppIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGAppIconsRefreshAllHosts(void) {
    UIWindow *window = LG_getHomescreenWindow();
    if (!window) return;
    LGTraverseViews(window, ^(UIView *view) {
        if (!LGIsHomescreenIconImageView(view)) return;
        injectIntoAppIcon(view);
    });
}

%hook SBIconImageView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) {
        removeAppIconOverlays(self_);
        return;
    }
    if (!LGIsHomescreenIconImageView(self_)) return;
    injectIntoAppIcon(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!LGIsHomescreenIconImageView(self_)) return;
    if (!LGAppIconsEnabled()) {
        removeAppIconOverlays(self_);
        return;
    }
    ensureAppIconTintOverlay(self_);
    if (!objc_getAssociatedObject(self_, kAppIconOriginalTransformKey)) {
        objc_setAssociatedObject(self_, kAppIconOriginalTransformKey,
                                 [NSValue valueWithCGAffineTransform:self_.transform],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    self_.transform = CGAffineTransformMakeScale(kAppIconImageScale, kAppIconImageScale);
    UIView *host = LGAppIconHostView(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(host, kAppIconGlassKey);
    if (!glass) {
        injectIntoAppIcon(self_);
        return;
    }
    CGRect frame = LGAppIconGlassFrameInHost(self_, host);
    if (CGRectIsEmpty(frame)) return;
    glass.frame = frame;
    glass.cornerRadius = LGAppIconCornerRadius();
    glass.bezelWidth = LGAppIconBezelWidth();
    glass.glassThickness = LGAppIconGlassThickness();
    glass.refractionScale = LGAppIconRefractionScale();
    glass.refractiveIndex = LGAppIconRefractiveIndex();
    glass.specularOpacity = LGAppIconSpecularOpacity();
    glass.blur = LGAppIconBlur();
    glass.wallpaperScale = LGAppIconWallpaperScale();
    CGRect lastFrame = [objc_getAssociatedObject(host, kAppIconLastGlassFrameKey) CGRectValue];
    if (!CGRectEqualToRect(lastFrame, frame)) {
        [glass updateOrigin];
        objc_setAssociatedObject(host, kAppIconLastGlassFrameKey,
                                 [NSValue valueWithCGRect:frame],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

%end

%hook SBIconScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    if (LG_prefersLiveCapture(@"AppIcons.RenderingMode")) LGAppIconsRefreshAllHosts();
    else LG_updateRegisteredGlassViews(LGUpdateGroupAppIcons);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    if (LG_prefersLiveCapture(@"AppIcons.RenderingMode")) LGAppIconsRefreshAllHosts();
    else LG_updateRegisteredGlassViews(LGUpdateGroupAppIcons);
}

%end
