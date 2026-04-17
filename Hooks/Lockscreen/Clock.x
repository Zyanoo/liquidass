#import "Common.h"
#import "../../Shared/LGHookSupport.h"
#import "../../Shared/LGPrefAccessors.h"
#import <CoreText/CoreText.h>
#import <objc/runtime.h>

static void *kLGClockOverlayKey = &kLGClockOverlayKey;
static void *kLGClockOriginalAlphaKey = &kLGClockOriginalAlphaKey;
static void *kLGClockOriginalLayerOpacityKey = &kLGClockOriginalLayerOpacityKey;
static void *kLGClockScrollObserverKey = &kLGClockScrollObserverKey;
static void *kLGClockScrollKVOContext = &kLGClockScrollKVOContext;

LG_FLOAT_PREF_FUNC(LGClockBezelWidth, "Lockscreen.Clock.BezelWidth", 24.0)
LG_FLOAT_PREF_FUNC(LGClockGlassThickness, "Lockscreen.Clock.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGClockRefractionScale, "Lockscreen.Clock.RefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGClockRefractiveIndex, "Lockscreen.Clock.RefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGClockSpecularOpacity, "Lockscreen.Clock.SpecularOpacity", 0.8)
LG_FLOAT_PREF_FUNC(LGClockBlur, "Lockscreen.Clock.Blur", 3.0)
LG_FLOAT_PREF_FUNC(LGClockWallpaperScale, "Lockscreen.Clock.WallpaperScale", 1.0)
LG_FLOAT_PREF_FUNC(LGClockLegacyFontWeight, "Lockscreen.Clock.LegacyFontWeight", UIFontWeightHeavy)
LG_FLOAT_PREF_FUNC(LGClockLegacySizeBoost, "Lockscreen.Clock.LegacySizeBoost", 1.05)
LG_FLOAT_PREF_FUNC(LGClockLegacyEmbolden, "Lockscreen.Clock.LegacyEmbolden", 0.35)
LG_FLOAT_PREF_FUNC(LGClockLegacyGap, "Lockscreen.Clock.LegacyGap", 8.0)

static void LGSetLayerTreeOpacity(CALayer *layer, float opacity) {
    if (!layer) return;
    layer.opacity = opacity;
    for (CALayer *sub in layer.sublayers) {
        LGSetLayerTreeOpacity(sub, opacity);
    }
}

static BOOL LGClockEnabled(void) {
    return LGLockscreenEnabled()
        && LG_prefBool(@"Lockscreen.Clock.Enabled", NO);
}

static BOOL LGIsModernClockHost(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"CSProminentTimeView");
    return cls && [view isKindOfClass:cls];
}

static BOOL LGIsLegacyClockHost(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"SBFLockScreenDateView");
    return cls && [view isKindOfClass:cls];
}

static BOOL LGIsClockHost(UIView *view) {
    return LGIsModernClockHost(view) || LGIsLegacyClockHost(view);
}

static BOOL LGIsModernClockSourceLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    return [NSStringFromClass(view.class) isEqualToString:@"_UIAnimatingLabel"]
        && LGHasAncestorClassNamed(view, @"CSProminentTimeView");
}

static BOOL LGIsLegacyClockTextLabel(UIView *view) {
    if (![view isKindOfClass:[UILabel class]]) return NO;
    if (!LGHasAncestorClassNamed(view, @"SBUILegibilityLabel")) return NO;
    if (!LGHasAncestorClassNamed(view, @"SBFLockScreenDateView")) return NO;
    UILabel *label = (UILabel *)view;
    if (label.text.length == 0) return NO;
    if (label.font.pointSize < 20.0) return NO;
    return YES;
}

static NSArray<UILabel *> *LGClockSourceLabelsForHost(UIView *host) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    LGTraverseViews(host, ^(UIView *view) {
        if (LGIsModernClockSourceLabel(view) || LGIsLegacyClockTextLabel(view))
            [labels addObject:(UILabel *)view];
    });
    return labels;
}

static UIView *LGClockLegacyVisibleSourceViewForLabel(UILabel *label) {
    UIView *cursor = label;
    while (cursor) {
        if ([NSStringFromClass(cursor.class) isEqualToString:@"SBUILegibilityLabel"]) {
            return cursor;
        }
        cursor = cursor.superview;
    }
    return label;
}

static NSArray<UIView *> *LGClockVisibleSourceViewsForHost(UIView *host, UILabel *sourceLabel) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    if (LGIsModernClockHost(host)) {
        [views addObjectsFromArray:LGClockSourceLabelsForHost(host)];
        return views;
    }

    if (LGIsLegacyClockHost(host) && sourceLabel) {
        UIView *visibleSourceView = LGClockLegacyVisibleSourceViewForLabel(sourceLabel);
        if (visibleSourceView) {
            [views addObject:visibleSourceView];
        }
    }
    return views;
}

static UIFont *LGClockPreferredRenderFont(UILabel *label, UIView *host) {
    UIFont *sourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    if (LGIsLegacyClockHost(host)) {
        CGFloat pointSize = MAX(sourceFont.pointSize * LGClockLegacySizeBoost(), 58.0);
        return [UIFont systemFontOfSize:pointSize weight:LGClockLegacyFontWeight()];
    }
    return sourceFont;
}

static UIImage *LGClockWallpaperSource(void) {
    UIImage *raw = LG_getRawLockscreenWallpaperImage();
    if (raw) return raw;
    return LGGetLockscreenSnapshotCached();
}

static UIScrollView *LGClockAncestorScrollView(UIView *view) {
    UIView *cursor = view.superview;
    while (cursor) {
        if ([cursor isKindOfClass:[UIScrollView class]])
            return (UIScrollView *)cursor;
        cursor = cursor.superview;
    }
    return nil;
}

@interface LGClockGlassView : UIView
@property (nonatomic, strong) LiquidGlassView *glassView;
@property (nonatomic, copy) NSString *displayText;
@property (nonatomic, copy) NSAttributedString *displayAttributedText;
@property (nonatomic, strong) UIFont *displayFont;
@property (nonatomic, assign) NSTextAlignment displayAlignment;
- (void)syncFromSourceLabel:(UILabel *)label;
@end

@interface LGClockScrollObserver : NSObject
@property (nonatomic, weak) UIView *host;
@property (nonatomic, weak) LGClockGlassView *overlay;
@property (nonatomic, weak) UIScrollView *scrollView;
@property (nonatomic, assign) BOOL observing;
- (instancetype)initWithScrollView:(UIScrollView *)scrollView
                              host:(UIView *)host
                           overlay:(LGClockGlassView *)overlay;
- (void)invalidate;
@end

@implementation LGClockGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;

    UIImage *wallpaper = LGClockWallpaperSource();
    CGPoint origin = LG_getLockscreenWallpaperOrigin();
    _glassView = [[LiquidGlassView alloc] initWithFrame:self.bounds wallpaper:wallpaper wallpaperOrigin:origin];
    _glassView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glassView.cornerRadius = 0.0;
    _glassView.bezelWidth = LGClockBezelWidth();
    _glassView.glassThickness = LGClockGlassThickness();
    _glassView.refractionScale = LGClockRefractionScale();
    _glassView.refractiveIndex = LGClockRefractiveIndex();
    _glassView.specularOpacity = LGClockSpecularOpacity();
    _glassView.blur = LGClockBlur();
    _glassView.wallpaperScale = LGClockWallpaperScale();
    _glassView.releasesWallpaperAfterUpload = YES;
    _glassView.updateGroup = LGUpdateGroupLockscreen;
    [self addSubview:_glassView];
    return self;
}

- (NSAttributedString *)lg_maskAttributedString {
    if (self.displayAttributedText.length > 0) {
        NSMutableAttributedString *copy = [self.displayAttributedText mutableCopy];
        [copy beginEditing];
        [copy enumerateAttribute:NSFontAttributeName
                         inRange:NSMakeRange(0, copy.length)
                         options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *font = [value isKindOfClass:[UIFont class]] ? (UIFont *)value : self.displayFont;
            if (!font) font = [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
            CTFontRef ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                              font.pointSize,
                                                              NULL);
            if (ctFont) {
                [copy removeAttribute:NSFontAttributeName range:range];
                [copy addAttribute:(__bridge NSString *)kCTFontAttributeName value:(__bridge id)ctFont range:range];
                CFRelease(ctFont);
            }
        }];
        [copy removeAttribute:NSForegroundColorAttributeName range:NSMakeRange(0, copy.length)];
        [copy removeAttribute:(__bridge NSString *)kCTForegroundColorAttributeName range:NSMakeRange(0, copy.length)];
        [copy addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName
                     value:(id)UIColor.whiteColor.CGColor
                     range:NSMakeRange(0, copy.length)];
        [copy endEditing];
        return copy;
    }

    UIFont *font = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CTFontRef ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                      font.pointSize,
                                                      NULL);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: (__bridge id)ctFont,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:self.displayText ?: @"" attributes:attrs];
    if (ctFont) CFRelease(ctFont);
    return string;
}

- (UIImage *)lg_maskImageForBounds:(CGRect)bounds {
    if (CGRectIsEmpty(bounds) || self.displayText.length == 0 || !self.displayFont) return nil;

    CGFloat scale = UIScreen.mainScreen.scale ?: 1.0;
    UIGraphicsBeginImageContextWithOptions(bounds.size, NO, scale);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) {
        UIGraphicsEndImageContext();
        return nil;
    }

    CGContextTranslateCTM(ctx, 0.0, bounds.size.height);
    CGContextScaleCTM(ctx, 1.0, -1.0);

    UIView *host = self.superview;
    while (host && !LGIsClockHost(host)) host = host.superview;
    BOOL legacyHost = LGIsLegacyClockHost(host);

    NSAttributedString *attributed = [self lg_maskAttributedString];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

    CGFloat x = 0.0;
    switch (self.displayAlignment) {
        case NSTextAlignmentCenter:
            x = floor((bounds.size.width - width) * 0.5);
            break;
        case NSTextAlignmentRight:
            x = floor(bounds.size.width - width);
            break;
        default:
            x = 0.0;
            break;
    }
    CGFloat lineHeight = ascent + descent + leading;
    CGFloat baseline = floor((bounds.size.height - lineHeight) * 0.5 + descent);
    if (legacyHost) {
        CGFloat embolden = MAX(0.0, LGClockLegacyEmbolden());
        static const CGPoint offsets[] = {
            {0.0, 0.0},
            {-1.0, 0.0},
            {1.0, 0.0},
            {0.0, 1.0},
            {0.0, -1.0},
        };
        for (NSUInteger i = 0; i < sizeof(offsets) / sizeof(offsets[0]); i++) {
            CGContextSetTextPosition(ctx, x + offsets[i].x * embolden, baseline + offsets[i].y * embolden);
            CTLineDraw(line, ctx);
        }
    } else {
        CGContextSetTextPosition(ctx, x, baseline);
        CTLineDraw(line, ctx);
    }

    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (line) CFRelease(line);
    return image;
}

- (void)lg_updateMask {
    UIImage *maskImage = [self lg_maskImageForBounds:self.bounds];
    if (!maskImage) {
        self.glassView.shapeMaskImage = nil;
        self.hidden = YES;
        return;
    }
    self.glassView.shapeMaskImage = maskImage;
    self.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glassView.frame = self.bounds;
    self.glassView.wallpaperImage = LGClockWallpaperSource();
    self.glassView.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
    [self.glassView updateOrigin];
    [self lg_updateMask];
}

- (void)syncFromSourceLabel:(UILabel *)label {
    if (!label) return;
    self.displayText = label.text ?: @"";
    UIView *host = self.superview;
    while (host && !LGIsClockHost(host)) host = host.superview;
    if (LGIsLegacyClockHost(host)) {
        self.frame = CGRectOffset(host.bounds, 0.0, -LGClockLegacyGap());
        self.displayAlignment = NSTextAlignmentCenter;
        self.displayAttributedText = nil;
    } else {
        self.frame = label.frame;
        self.displayAlignment = label.textAlignment;
        self.displayAttributedText = label.attributedText;
    }
    self.displayFont = LGClockPreferredRenderFont(label, host);
    self.glassView.bezelWidth = LGClockBezelWidth();
    self.glassView.glassThickness = LGClockGlassThickness();
    self.glassView.refractionScale = LGClockRefractionScale();
    self.glassView.refractiveIndex = LGClockRefractiveIndex();
    self.glassView.specularOpacity = LGClockSpecularOpacity();
    self.glassView.blur = LGClockBlur();
    self.glassView.wallpaperScale = LGClockWallpaperScale();
    self.hidden = !self.displayText.length;
    [self setNeedsLayout];
}

@end

@implementation LGClockScrollObserver

- (instancetype)initWithScrollView:(UIScrollView *)scrollView
                              host:(UIView *)host
                           overlay:(LGClockGlassView *)overlay {
    self = [super init];
    if (!self) return nil;
    _scrollView = scrollView;
    _host = host;
    _overlay = overlay;
    if (scrollView) {
        [scrollView addObserver:self
                     forKeyPath:@"contentOffset"
                        options:NSKeyValueObservingOptionNew
                        context:kLGClockScrollKVOContext];
        [scrollView addObserver:self
                     forKeyPath:@"bounds"
                        options:NSKeyValueObservingOptionNew
                        context:kLGClockScrollKVOContext];
        _observing = YES;
    }
    return self;
}

- (void)dealloc {
    [self invalidate];
}

- (void)invalidate {
    if (!_observing) return;
    UIScrollView *scrollView = _scrollView;
    _observing = NO;
    if (!scrollView) return;
    @try {
        [scrollView removeObserver:self forKeyPath:@"contentOffset" context:kLGClockScrollKVOContext];
        [scrollView removeObserver:self forKeyPath:@"bounds" context:kLGClockScrollKVOContext];
    } @catch (__unused NSException *exception) {
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                       context:(void *)context {
    if (context != kLGClockScrollKVOContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    UIView *host = self.host;
    LGClockGlassView *overlay = self.overlay;
    if (!host.window || !overlay || !overlay.superview) return;

    overlay.glassView.wallpaperImage = LGClockWallpaperSource();
    overlay.glassView.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
    [overlay.glassView updateOrigin];
    [overlay setNeedsLayout];
}

@end

static void LGRestoreClockSourceView(UIView *view) {
    if (!view) return;
    NSNumber *originalAlpha = objc_getAssociatedObject(view, kLGClockOriginalAlphaKey);
    NSNumber *originalLayerOpacity = objc_getAssociatedObject(view, kLGClockOriginalLayerOpacityKey);
    view.alpha = originalAlpha ? originalAlpha.doubleValue : 1.0;
    view.layer.opacity = originalLayerOpacity ? originalLayerOpacity.floatValue : 1.0f;
    LGSetLayerTreeOpacity(view.layer, view.layer.opacity);
    objc_setAssociatedObject(view, kLGClockOriginalAlphaKey, nil, OBJC_ASSOCIATION_ASSIGN);
    objc_setAssociatedObject(view, kLGClockOriginalLayerOpacityKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGDetachClockScrollObserver(UIView *host) {
    LGClockScrollObserver *observer = objc_getAssociatedObject(host, kLGClockScrollObserverKey);
    [observer invalidate];
    objc_setAssociatedObject(host, kLGClockScrollObserverKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void LGEnsureClockScrollObserver(UIView *host, LGClockGlassView *overlay) {
    UIScrollView *scrollView = LGClockAncestorScrollView(host);
    LGClockScrollObserver *observer = objc_getAssociatedObject(host, kLGClockScrollObserverKey);
    if (observer && observer.scrollView == scrollView) {
        observer.overlay = overlay;
        return;
    }

    [observer invalidate];
    if (!scrollView) {
        objc_setAssociatedObject(host, kLGClockScrollObserverKey, nil, OBJC_ASSOCIATION_ASSIGN);
        return;
    }

    observer = [[LGClockScrollObserver alloc] initWithScrollView:scrollView host:host overlay:overlay];
    objc_setAssociatedObject(host, kLGClockScrollObserverKey, observer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void LGApplyClockReplacement(UIView *host) {
    if (!LGIsClockHost(host)) return;

    NSArray<UILabel *> *sourceLabels = LGClockSourceLabelsForHost(host);
    UILabel *sourceLabel = sourceLabels.firstObject;
    NSArray<UIView *> *visibleSourceViews = LGClockVisibleSourceViewsForHost(host, sourceLabel);
    LGClockGlassView *overlay = objc_getAssociatedObject(host, kLGClockOverlayKey);

    if (!LGClockEnabled() || !host.window || !sourceLabel) {
        [overlay removeFromSuperview];
        objc_setAssociatedObject(host, kLGClockOverlayKey, nil, OBJC_ASSOCIATION_ASSIGN);
        LGDetachClockScrollObserver(host);
        LGDetachLockHostIfNeeded(host);
        for (UIView *view in visibleSourceViews) LGRestoreClockSourceView(view);
        return;
    }

    for (UIView *view in visibleSourceViews) {
        if (!objc_getAssociatedObject(view, kLGClockOriginalAlphaKey)) {
            objc_setAssociatedObject(view, kLGClockOriginalAlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kLGClockOriginalLayerOpacityKey, @(view.layer.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.alpha = 0.0;
        LGSetLayerTreeOpacity(view.layer, 0.0f);
    }

    if (!overlay) {
        overlay = [[LGClockGlassView alloc] initWithFrame:sourceLabel.frame];
        objc_setAssociatedObject(host, kLGClockOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [host addSubview:overlay];
    }

    LGAttachLockHostIfNeeded(host);
    LGEnsureClockScrollObserver(host, overlay);
    [overlay syncFromSourceLabel:sourceLabel];
    [host bringSubviewToFront:overlay];
}

static void LGRefreshClockHosts(void) {
    UIApplication *app = UIApplication.sharedApplication;
    void (^refreshWindow)(UIWindow *) = ^(UIWindow *window) {
        LGTraverseViews(window, ^(UIView *view) {
            if (LGIsClockHost(view)) LGApplyClockReplacement(view);
        });
    };
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) refreshWindow(window);
        }
    } else {
        for (UIWindow *window in LGApplicationWindows(app)) refreshWindow(window);
    }
}

%group LGClockSpringBoard

%hook CSProminentTimeView

- (void)didMoveToWindow {
    %orig;
    LGApplyClockReplacement((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyClockReplacement((UIView *)self);
}

%end

%hook SBFLockScreenDateView

- (void)didMoveToWindow {
    %orig;
    LGApplyClockReplacement((UIView *)self);
}

- (void)layoutSubviews {
    %orig;
    LGApplyClockReplacement((UIView *)self);
}

%end

%hook UILabel

- (void)setText:(NSString *)text {
    %orig;
    if (LGIsModernClockSourceLabel((UIView *)self) || LGIsLegacyClockTextLabel((UIView *)self)) {
        UIView *host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
        if (host) LGApplyClockReplacement(host);
    }
}

- (void)setFont:(UIFont *)font {
    %orig;
    if (LGIsModernClockSourceLabel((UIView *)self) || LGIsLegacyClockTextLabel((UIView *)self)) {
        UIView *host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
        if (host) LGApplyClockReplacement(host);
    }
}

%end

%end

%ctor {
    if (!LGIsSpringBoardProcess()) return;
    LGObservePreferenceChanges(^{
        dispatch_async(dispatch_get_main_queue(), ^{
            LGRefreshClockHosts();
        });
    });
    %init(LGClockSpringBoard);
}
