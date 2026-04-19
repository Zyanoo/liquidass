#import "../LiquidGlass.h"
#import "../Shared/LGHookSupport.h"
#import "../Shared/LGBannerCaptureSupport.h"
#import "../Shared/LGPrefAccessors.h"
#import <objc/runtime.h>

static const NSInteger kFolderIconTintTag      = 0xF01D;
static NSUInteger sFolderSnapshotGeneration = 0;

static BOOL isInsideFolderIcon(UIView *view) {
    static Class folderIconCls, iconViewCls;
    if (!folderIconCls) folderIconCls = NSClassFromString(@"SBFolderIconImageView");
    if (!iconViewCls)   iconViewCls   = NSClassFromString(@"SBIconView");
    UIView *v = view.superview;
    while (v) {
        if ([v isKindOfClass:folderIconCls]) return YES;
        if ([v isKindOfClass:iconViewCls])   break;
        v = v.superview;
    }
    return NO;
}

static void *kFolderIconRetryKey = &kFolderIconRetryKey;
static void *kFolderIconGlassKey = &kFolderIconGlassKey;
static void *kFolderIconTintKey = &kFolderIconTintKey;
static void *kFolderIconLastPageKey = &kFolderIconLastPageKey;
static void *kFolderIconBackdropViewKey = &kFolderIconBackdropViewKey;

static void LGScheduleFolderSnapshotWarmup(NSTimeInterval delay) {
    if (LG_getFolderSnapshot()) return;
    NSUInteger generation = ++sFolderSnapshotGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderSnapshotGeneration) return;
        if (LG_getFolderSnapshot()) return;
        LG_cacheFolderSnapshot();
    });
}

static BOOL LGFolderScrollIsSettled(UIScrollView *scrollView) {
    if (!scrollView) return NO;
    if (scrollView.dragging || scrollView.decelerating || scrollView.tracking) return NO;
    CGFloat pageWidth = CGRectGetWidth(scrollView.bounds);
    if (pageWidth <= 1.0) return YES;
    CGFloat page = scrollView.contentOffset.x / pageWidth;
    return fabs(page - round(page)) < 0.02;
}

static void LGScheduleFolderSnapshotWarmupForScroll(UIScrollView *scrollView, NSTimeInterval delay) {
    if (!scrollView) return;
    if (LG_getFolderSnapshot()) return;
    NSUInteger generation = ++sFolderSnapshotGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != sFolderSnapshotGeneration) return;
        if (LG_getFolderSnapshot()) return;
        if (!LGFolderScrollIsSettled(scrollView)) {
            LGScheduleFolderSnapshotWarmupForScroll(scrollView, 0.12);
            return;
        }
        LG_cacheFolderSnapshot();
    });
}

LG_ENABLED_BOOL_PREF_FUNC(LGFolderIconEnabled, "FolderIcon.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGFolderIconBezelWidth, "FolderIcon.BezelWidth", 12.0)
LG_FLOAT_PREF_FUNC(LGFolderIconGlassThickness, "FolderIcon.GlassThickness", 90.0)
LG_FLOAT_PREF_FUNC(LGFolderIconRefractionScale, "FolderIcon.RefractionScale", 2.0)
LG_FLOAT_PREF_FUNC(LGFolderIconRefractiveIndex, "FolderIcon.RefractiveIndex", 2.0)
LG_FLOAT_PREF_FUNC(LGFolderIconSpecularOpacity, "FolderIcon.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGFolderIconBlur, "FolderIcon.Blur", 3.0)
LG_FLOAT_PREF_FUNC(LGFolderIconWallpaperScale, "FolderIcon.WallpaperScale", 0.5)
LG_FLOAT_PREF_FUNC(LGFolderIconLightTintAlpha, "FolderIcon.LightTintAlpha", 0.1)
LG_FLOAT_PREF_FUNC(LGFolderIconDarkTintAlpha, "FolderIcon.DarkTintAlpha", 0.0)
static CGFloat LGFolderIconCornerRadius(CGFloat fallback) { return LG_prefFloat(@"FolderIcon.CornerRadius", fallback); }

static UIColor *folderIconTintColorForView(UIView *view) {
    return LGDefaultTintColorForViewWithOverrideKey(view, LGFolderIconLightTintAlpha(), LGFolderIconDarkTintAlpha(), @"FolderIcon.TintOverrideMode");
}

static void removeFolderIconOverlays(UIView *self_) {
    LGRemoveAssociatedSubview(self_, kFolderIconTintKey);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderIconGlassKey);
    if (glass) [glass removeFromSuperview];
    objc_setAssociatedObject(self_, kFolderIconGlassKey, nil, OBJC_ASSOCIATION_ASSIGN);
    LGRemoveLiveBackdropCaptureView(self_, kFolderIconBackdropViewKey);
}

static void ensureFolderIconTintOverlay(UIView *self_) {
    UIView *tint = LGEnsureTintOverlayView(self_,
                                           kFolderIconTintKey,
                                           kFolderIconTintTag,
                                           self_.bounds,
                                           UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight);
    LGConfigureTintOverlayView(tint,
                               folderIconTintColorForView(self_),
                               LGFolderIconCornerRadius(self_.layer.cornerRadius),
                               self_.layer,
                               NO);
    [self_ bringSubviewToFront:tint];
}

static void injectIntoFolderIcon(UIView *self_) {
    if (!LGFolderIconEnabled()) {
        removeFolderIconOverlays(self_);
        return;
    }
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderIconGlassKey);

    CGPoint wallpaperOrigin = CGPointZero;
    UIImage *wallpaper = LG_getHomescreenSnapshot(&wallpaperOrigin);
    if (!wallpaper && !LG_prefersLiveCapture(@"FolderIcon.RenderingMode")) {
        if ([objc_getAssociatedObject(self_, kFolderIconRetryKey) boolValue]) return;
        objc_setAssociatedObject(self_, kFolderIconRetryKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(self_, kFolderIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
            injectIntoFolderIcon(self_);
        });
        return;
    }

    if (!glass) {
        glass = [[LiquidGlassView alloc]
            initWithFrame:self_.bounds wallpaper:wallpaper wallpaperOrigin:wallpaperOrigin];
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                 UIViewAutoresizingFlexibleHeight;
        glass.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
        glass.bezelWidth = LGFolderIconBezelWidth();
        glass.glassThickness = LGFolderIconGlassThickness();
        glass.refractionScale = LGFolderIconRefractionScale();
        glass.refractiveIndex = LGFolderIconRefractiveIndex();
        glass.specularOpacity = LGFolderIconSpecularOpacity();
        glass.blur = LGFolderIconBlur();
        glass.wallpaperScale = LGFolderIconWallpaperScale();
        glass.updateGroup = LGUpdateGroupFolderIcon;
        [self_ addSubview:glass];
        objc_setAssociatedObject(self_, kFolderIconGlassKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    glass.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
    glass.bezelWidth = LGFolderIconBezelWidth();
    glass.glassThickness = LGFolderIconGlassThickness();
    glass.refractionScale = LGFolderIconRefractionScale();
    glass.refractiveIndex = LGFolderIconRefractiveIndex();
    glass.specularOpacity = LGFolderIconSpecularOpacity();
    glass.blur = LGFolderIconBlur();
    glass.wallpaperScale = LGFolderIconWallpaperScale();
    if (!LGApplyRenderingModeToGlassHost(self_,
                                         glass,
                                         @"FolderIcon.RenderingMode",
                                         kFolderIconBackdropViewKey,
                                         wallpaper,
                                         wallpaperOrigin)) {
        objc_setAssociatedObject(self_, kFolderIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }
    ensureFolderIconTintOverlay(self_);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self_.window) ensureFolderIconTintOverlay(self_);
    });
    objc_setAssociatedObject(self_, kFolderIconRetryKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGFolderIconRefreshAllHosts(void) {
    UIWindow *window = LG_getHomescreenWindow();
    if (!window) return;
    LGTraverseViews(window, ^(UIView *view) {
        if (![view isKindOfClass:NSClassFromString(@"MTMaterialView")]) return;
        if (!isInsideFolderIcon(view)) return;
        injectIntoFolderIcon(view);
    });
}

static NSInteger LGFolderScrollPageForOffset(UIScrollView *scrollView, CGPoint offset) {
    CGFloat pageWidth = CGRectGetWidth(scrollView.bounds);
    if (pageWidth <= 1.0) return 0;
    return (NSInteger)llround(offset.x / pageWidth);
}

static void LGHandleFolderSnapshotForScroll(UIScrollView *scrollView, CGPoint offset) {
    NSInteger page = LGFolderScrollPageForOffset(scrollView, offset);
    NSNumber *lastPageNumber = objc_getAssociatedObject(scrollView, kFolderIconLastPageKey);
    NSInteger lastPage = lastPageNumber ? lastPageNumber.integerValue : page;
    if (!lastPageNumber) {
        objc_setAssociatedObject(scrollView, kFolderIconLastPageKey, @(page), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if (lastPage != page) {
        objc_setAssociatedObject(scrollView, kFolderIconLastPageKey, @(page), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        LG_invalidateFolderSnapshot();
        LGScheduleFolderSnapshotWarmupForScroll(scrollView, 0.18);
    }
    if (LG_prefersLiveCapture(@"FolderIcon.RenderingMode")) LGFolderIconRefreshAllHosts();
    else LG_updateRegisteredGlassViews(LGUpdateGroupFolderIcon);
}

static void LGFolderIconPrefsChanged(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        LGFolderIconRefreshAllHosts();
    });
}

%group LGFolderIconSpringBoard

%hook MTMaterialView

- (void)didMoveToWindow {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!self_.window) return;
    if (!isInsideFolderIcon(self_)) return;
    LGScheduleFolderSnapshotWarmup(0.18);
    injectIntoFolderIcon(self_);
}

- (void)layoutSubviews {
    %orig;
    UIView *self_ = (UIView *)self;
    if (!isInsideFolderIcon(self_)) return;
    if (!LGFolderIconEnabled()) {
        removeFolderIconOverlays(self_);
        return;
    }
    ensureFolderIconTintOverlay(self_);
    LiquidGlassView *glass = objc_getAssociatedObject(self_, kFolderIconGlassKey);
    glass.cornerRadius = LGFolderIconCornerRadius(self_.layer.cornerRadius);
    glass.bezelWidth = LGFolderIconBezelWidth();
    glass.glassThickness = LGFolderIconGlassThickness();
    glass.refractionScale = LGFolderIconRefractionScale();
    glass.refractiveIndex = LGFolderIconRefractiveIndex();
    glass.specularOpacity = LGFolderIconSpecularOpacity();
    glass.blur = LGFolderIconBlur();
    glass.wallpaperScale = LGFolderIconWallpaperScale();
    [glass updateOrigin];
}

%end

%hook SBIconScrollView

- (void)setContentOffset:(CGPoint)offset {
    %orig;
    LGHandleFolderSnapshotForScroll((UIScrollView *)self, offset);
}

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
    %orig;
    LGHandleFolderSnapshotForScroll((UIScrollView *)self, offset);
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        LGFolderIconPrefsChanged(NULL, NULL, NULL, NULL, NULL);
    });
    %init(LGFolderIconSpringBoard);
}
