#import "Common.h"
#import "../../Shared/LGHookSupport.h"
#import "../../Shared/LGPrefAccessors.h"
#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <math.h>
#import <objc/runtime.h>

static void *kLGClockOverlayKey = &kLGClockOverlayKey;
static void *kLGClockOriginalAlphaKey = &kLGClockOriginalAlphaKey;
static void *kLGClockOriginalLayerOpacityKey = &kLGClockOriginalLayerOpacityKey;
static void *kLGClockScrollObserverKey = &kLGClockScrollObserverKey;
static void *kLGClockScrollKVOContext = &kLGClockScrollKVOContext;
static void *kLGClockAttachedKey = &kLGClockAttachedKey;
static LGDisplayLinkState sClockDisplayLinkState = {0};
static NSHashTable<UIView *> *sClockHosts = nil;

LG_FLOAT_PREF_FUNC(LGClockBezelWidth, "Lockscreen.Clock.BezelWidth", 24.0)
LG_FLOAT_PREF_FUNC(LGClockGlassThickness, "Lockscreen.Clock.GlassThickness", 150.0)
LG_FLOAT_PREF_FUNC(LGClockRefractionScale, "Lockscreen.Clock.RefractionScale", 1.5)
LG_FLOAT_PREF_FUNC(LGClockRefractiveIndex, "Lockscreen.Clock.RefractiveIndex", 1.5)
LG_FLOAT_PREF_FUNC(LGClockSpecularOpacity, "Lockscreen.Clock.SpecularOpacity", 0.6)
LG_FLOAT_PREF_FUNC(LGClockBlur, "Lockscreen.Clock.Blur", 3.0)
LG_FLOAT_PREF_FUNC(LGClockWallpaperScale, "Lockscreen.Clock.WallpaperScale", 1.0)
LG_FLOAT_PREF_FUNC(LGClockLightTintAlpha, "Lockscreen.Clock.LightTintAlpha", 0.3)
LG_FLOAT_PREF_FUNC(LGClockDarkTintAlpha, "Lockscreen.Clock.DarkTintAlpha", 0.0)
LG_BOOL_PREF_FUNC(LGClockVariableFontEnabled, "Lockscreen.Clock.VariableFont.Enabled", YES)
LG_FLOAT_PREF_FUNC(LGClockVariableFontWeight, "Lockscreen.Clock.VariableFont.Weight", 640.0)
LG_FLOAT_PREF_FUNC(LGClockVariableFontWidth, "Lockscreen.Clock.VariableFont.Width", 92.0)
LG_FLOAT_PREF_FUNC(LGClockVariableFontHeight, "Lockscreen.Clock.VariableFont.Height", 112.0)
LG_FLOAT_PREF_FUNC(LGClockVariableFontSoftness, "Lockscreen.Clock.VariableFont.Softness", 56.0)
LG_FLOAT_PREF_FUNC(LGClockLegacyFontWeight, "Lockscreen.Clock.LegacyFontWeight", UIFontWeightHeavy)
LG_FLOAT_PREF_FUNC(LGClockLegacySizeBoost, "Lockscreen.Clock.LegacySizeBoost", 1.05)
LG_FLOAT_PREF_FUNC(LGClockLegacyEmbolden, "Lockscreen.Clock.LegacyEmbolden", 0.35)

static NSString * const LGClockLegacyFontStyleCurrent = @"current";
static NSString * const LGClockLegacyFontStyleRounded = @"rounded";

static void LGSetLayerTreeOpacity(CALayer *layer, float opacity) {
    if (!layer) return;
    layer.opacity = opacity;
    for (CALayer *sub in layer.sublayers) {
        LGSetLayerTreeOpacity(sub, opacity);
    }
}

static BOOL LGClockEnabled(void) {
    return LGLockscreenEnabled()
        && LG_prefBool(@"Lockscreen.Clock.Enabled", YES);
}

static NSString *LGClockVariableFontPath(void) {
    static NSString *path = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidates = @[
            @"/opt/simject/PreferenceBundles/LiquidAssPrefs.bundle/SFAdaptiveSoftNumeric-VF.otf",
            @"/var/jb/Library/PreferenceBundles/LiquidAssPrefs.bundle/SFAdaptiveSoftNumeric-VF.otf",
            @"/Library/PreferenceBundles/LiquidAssPrefs.bundle/SFAdaptiveSoftNumeric-VF.otf",
        ];
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *candidate in candidates) {
            if ([fm fileExistsAtPath:candidate]) {
                path = [candidate copy];
                break;
            }
        }
        if (!path.length) {
            LGLog(@"clock variable font path not found candidates=%@", candidates);
        }
    });
    return path;
}

static BOOL LGAxisNameMatches(NSString *axisName, NSString *needle, NSString *shortNeedle) {
    if (![axisName isKindOfClass:[NSString class]]) return NO;
    NSString *lower = axisName.lowercaseString;
    return [lower containsString:needle] || [lower containsString:shortNeedle];
}

static NSDictionary<NSString *, NSNumber *> *sClockVariableAxisIdentifiers = nil;
static NSDictionary<NSString *, NSArray<NSNumber *> *> *sClockVariableAxisRanges = nil;
static NSString *sClockVariablePostScriptName = nil;
static CGFontRef sClockVariableCGFont = NULL;
static CTFontRef LGClockVariableCTFont(CGFloat pointSize);
static CTFontRef LGClockVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue);
static CGRect LGClockExpandedModernFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject,
                                                NSTextAlignment alignment);
static void LGApplyClockReplacement(UIView *host);

static NSHashTable<UIView *> *LGClockHostRegistry(void) {
    if (!sClockHosts) {
        sClockHosts = [NSHashTable weakObjectsHashTable];
    }
    return sClockHosts;
}

static NSUInteger LGClockLiveHostCount(void) {
    return [LGClockHostRegistry().allObjects count];
}

static void LGEnsureClockVariableFontMetadata(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *fontPath = LGClockVariableFontPath();
        if (!fontPath.length) return;

        NSURL *fontURL = [NSURL fileURLWithPath:fontPath];
        NSData *fontData = [NSData dataWithContentsOfURL:fontURL];
        if (![fontData isKindOfClass:[NSData class]] || fontData.length == 0) {
            LGLog(@"clock variable font read failed path=%@", fontPath);
            return;
        }

        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)fontData);
        if (!provider) {
            LGLog(@"clock variable font provider create failed path=%@", fontPath);
            return;
        }
        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cgFont) {
            LGLog(@"clock variable font CGFont create failed path=%@", fontPath);
            return;
        }
        sClockVariableCGFont = cgFont;

        sClockVariablePostScriptName = CFBridgingRelease(CGFontCopyPostScriptName(cgFont));
        CFErrorRef registerError = NULL;
        BOOL registered = CTFontManagerRegisterGraphicsFont(cgFont, &registerError);
        if (!registered && registerError) {
            NSError *error = CFBridgingRelease(registerError);
            LGLog(@"clock variable font register failed postscript=%@ error=%@",
                  sClockVariablePostScriptName ?: @"(null)",
                  error);
        }

        CTFontRef baseFont = CTFontCreateWithGraphicsFont(cgFont, 60.0, NULL, NULL);
        NSArray *axes = baseFont ? CFBridgingRelease(CTFontCopyVariationAxes(baseFont)) : nil;
        if (!axes.count) {
            LGLog(@"clock variable font has no variation axes postscript=%@", sClockVariablePostScriptName ?: @"(null)");
        }
        NSMutableDictionary<NSString *, NSNumber *> *ids = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *ranges = [NSMutableDictionary dictionary];
        for (NSDictionary *axis in axes) {
            NSString *name = axis[(id)kCTFontVariationAxisNameKey];
            NSNumber *identifier = axis[(id)kCTFontVariationAxisIdentifierKey];
            NSNumber *minimum = axis[(id)kCTFontVariationAxisMinimumValueKey];
            NSNumber *maximum = axis[(id)kCTFontVariationAxisMaximumValueKey];
            if (![identifier isKindOfClass:[NSNumber class]]) continue;

            NSString *key = nil;
            if (LGAxisNameMatches(name, @"weight", @"wght")) key = @"weight";
            else if (LGAxisNameMatches(name, @"width", @"wdth")) key = @"width";
            else if (LGAxisNameMatches(name, @"height", @"hght")) key = @"height";
            else if (LGAxisNameMatches(name, @"soft", @"soft")) key = @"softness";
            if (!key.length) continue;

            ids[key] = identifier;
            ranges[key] = @[
                @([minimum isKindOfClass:[NSNumber class]] ? minimum.doubleValue : -CGFLOAT_MAX),
                @([maximum isKindOfClass:[NSNumber class]] ? maximum.doubleValue : CGFLOAT_MAX),
            ];
        }
        sClockVariableAxisIdentifiers = [ids copy];
        sClockVariableAxisRanges = [ranges copy];

        if (baseFont) CFRelease(baseFont);
    });
}

static CGFloat LGClockClampedAxisValue(NSString *axisKey, CGFloat value) {
    NSArray<NSNumber *> *range = sClockVariableAxisRanges[axisKey];
    if (range.count != 2) return value;
    CGFloat minimum = range[0].doubleValue;
    CGFloat maximum = range[1].doubleValue;
    return MIN(MAX(value, minimum), maximum);
}

static NSMutableDictionary *LGClockRequestedVariations(void) {
    NSMutableDictionary *variations = [NSMutableDictionary dictionary];
    NSNumber *weightAxis = sClockVariableAxisIdentifiers[@"weight"];
    NSNumber *widthAxis = sClockVariableAxisIdentifiers[@"width"];
    NSNumber *heightAxis = sClockVariableAxisIdentifiers[@"height"];
    NSNumber *softAxis = sClockVariableAxisIdentifiers[@"softness"];
    if (weightAxis) variations[weightAxis] = @(LGClockClampedAxisValue(@"weight", LGClockVariableFontWeight()));
    if (widthAxis) variations[widthAxis] = @(LGClockClampedAxisValue(@"width", LGClockVariableFontWidth()));
    if (heightAxis) variations[heightAxis] = @(LGClockClampedAxisValue(@"height", LGClockVariableFontHeight()));
    if (softAxis) variations[softAxis] = @(LGClockClampedAxisValue(@"softness", LGClockVariableFontSoftness()));
    return variations;
}

static NSMutableDictionary *LGClockRequestedVariationsForHeight(CGFloat heightValue) {
    NSMutableDictionary *variations = LGClockRequestedVariations();
    NSNumber *heightAxis = sClockVariableAxisIdentifiers[@"height"];
    if (heightAxis) {
        variations[heightAxis] = @(LGClockClampedAxisValue(@"height", heightValue));
    }
    return variations;
}

static UIFont *LGClockVariableFont(CGFloat pointSize) {
    if (!LGIsAtLeastiOS16()) return nil;
    if (!LGClockVariableFontEnabled()) return nil;
    CTFontRef renderFont = LGClockVariableCTFont(pointSize);
    if (!renderFont) return nil;
    return (__bridge_transfer UIFont *)renderFont;
}

static CTFontRef LGClockVariableCTFont(CGFloat pointSize) {
    return LGClockVariableCTFontForHeight(pointSize, LGClockVariableFontHeight());
}

static CTFontRef LGClockVariableCTFontForHeight(CGFloat pointSize, CGFloat heightValue) {
    if (!LGIsAtLeastiOS16()) return NULL;
    if (!LGClockVariableFontEnabled()) return NULL;
    LGEnsureClockVariableFontMetadata();
    if (!sClockVariablePostScriptName.length) return NULL;

    NSMutableDictionary *variations = LGClockRequestedVariationsForHeight(heightValue);

    CTFontDescriptorRef descriptor = NULL;
    if (sClockVariablePostScriptName.length) {
        NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
        attributes[(id)kCTFontNameAttribute] = sClockVariablePostScriptName;
        if (variations.count > 0) {
            attributes[(id)kCTFontVariationAttribute] = variations;
        }
        descriptor = CTFontDescriptorCreateWithAttributes((__bridge CFDictionaryRef)attributes);
    }

    CTFontRef renderFont = descriptor ? CTFontCreateWithFontDescriptor(descriptor, pointSize, NULL) : NULL;
    if (descriptor) CFRelease(descriptor);
    if (!renderFont) {
        LGLog(@"clock variable CTFont descriptor create failed postscript=%@ size=%.2f variations=%@",
              sClockVariablePostScriptName,
              pointSize,
              variations);
        return NULL;
    }
    return renderFont;
}

static BOOL LGIsModernClockHost(UIView *view) {
    static Class cls;
    if (!cls) cls = NSClassFromString(@"CSProminentTimeView");
    return cls && [view isKindOfClass:cls];
}

static BOOL LGIsLegacyClockHost(UIView *view) {
    if (LGIsAtLeastiOS16()) return NO;
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

static UILabel *LGClockPrimarySourceLabelForHost(UIView *host) {
    NSArray<UILabel *> *labels = LGClockSourceLabelsForHost(host);
    if (labels.count == 0) return nil;
    if (!LGIsLegacyClockHost(host)) return labels.firstObject;

    UILabel *best = nil;
    for (UILabel *label in labels) {
        if (!best || label.font.pointSize > best.font.pointSize) {
            best = label;
        }
    }
    return best ?: labels.firstObject;
}

static void LGStartClockDisplayLink(void) {
    LGAssertMainThread();
    if (sClockDisplayLinkState.link || !LGClockEnabled()) return;
    LGStartDisplayLinkState(&sClockDisplayLinkState,
                            LGPreferredFramesPerSecondForKey(@"Lockscreen.FPS", 30),
                            ^{
        for (UIView *host in LGClockHostRegistry().allObjects) {
            if (!host.window || host.hidden || host.alpha <= 0.01f || host.layer.opacity <= 0.01f) continue;
            if (!LGIsClockHost(host)) continue;
            LGApplyClockReplacement(host);
        }
    });
}

static void LGStopClockDisplayLink(void) {
    LGAssertMainThread();
    LGStopDisplayLinkState(&sClockDisplayLinkState);
}

static void LGAttachClockHostIfNeeded(UIView *host) {
    LGAssertMainThread();
    if (!host || !LGIsClockHost(host)) return;
    if ([objc_getAssociatedObject(host, kLGClockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(host, kLGClockAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [LGClockHostRegistry() addObject:host];
    LGStartClockDisplayLink();
}

static void LGDetachClockHostIfNeeded(UIView *host) {
    LGAssertMainThread();
    if (!host) return;
    if (![objc_getAssociatedObject(host, kLGClockAttachedKey) boolValue]) return;
    objc_setAssociatedObject(host, kLGClockAttachedKey, nil, OBJC_ASSOCIATION_ASSIGN);
    [LGClockHostRegistry() removeObject:host];
    if (LGClockLiveHostCount() == 0) {
        LGStopClockDisplayLink();
    }
}

static UIFont *LGClockPreferredRenderFont(UILabel *label, UIView *host) {
    UIFont *sourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CGFloat pointSize = sourceFont.pointSize;
    if (LGIsLegacyClockHost(host)) {
        pointSize = MAX(sourceFont.pointSize * LGClockLegacySizeBoost(), 58.0);
    }

    UIFont *variableFont = LGClockVariableFont(pointSize);
    if (variableFont) return variableFont;
    if (LGIsLegacyClockHost(host)) {
        UIFont *baseFont = [UIFont systemFontOfSize:pointSize weight:LGClockLegacyFontWeight()];
        NSString *style = LG_prefString(@"Lockscreen.Clock.LegacyFontStyle", LGClockLegacyFontStyleCurrent);
        if ([style isEqualToString:LGClockLegacyFontStyleRounded]) {
            UIFontDescriptor *descriptor = [baseFont.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
            if (descriptor) {
                UIFont *roundedFont = [UIFont fontWithDescriptor:descriptor size:pointSize];
                if (roundedFont) return roundedFont;
            }
        }
        return baseFont;
    }
    return sourceFont;
}

static UIImage *LGClockWallpaperSource(void) {
    UIImage *raw = LG_getRawLockscreenWallpaperImage();
    if (raw) return raw;
    return LGGetLockscreenSnapshotCached();
}

static UIColor *LGClockTintColorForView(UIView *view) {
    NSString *override = LG_prefString(@"Lockscreen.Clock.TintOverrideMode", LGTintOverrideLight);
    if ([override isEqualToString:LGTintOverrideDark]) {
        return [UIColor colorWithWhite:0.0 alpha:LGClockDarkTintAlpha()];
    }
    if ([override isEqualToString:LGTintOverrideLight]) {
        return [UIColor colorWithWhite:1.0 alpha:LGClockLightTintAlpha()];
    }
    return LGDefaultTintColorForView(view, LGClockLightTintAlpha(), LGClockDarkTintAlpha());
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

static CGFloat LGClockResolvedLineHeight(UIFont *font, id ctFontObject) {
    if (ctFontObject) {
        CTFontRef ctFont = (__bridge CTFontRef)ctFontObject;
        return ceil(CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont) + CTFontGetLeading(ctFont));
    }
    return ceil(font.lineHeight);
}

static BOOL LGClockContainerClips(UIView *view) {
    if (!view) return NO;
    return view.clipsToBounds || view.layer.masksToBounds;
}

static BOOL LGClockViewIsVisiblyPresent(UIView *view) {
    if (!view || !view.window || view.hidden) return NO;
    if (view.alpha <= 0.01 || view.layer.opacity <= 0.01f) return NO;
    if (CGRectIsEmpty(view.bounds)) return NO;
    return YES;
}

static BOOL LGClockIsNotificationObstacleView(UIView *view) {
    if (!LGClockViewIsVisiblyPresent(view)) return NO;
    if (LGHasAncestorClassNamed(view, @"NCNotificationShortLookView")) return NO;
    if (LGHasAncestorClassNamed(view, @"NCNotificationLongLookView")) return NO;
    NSString *className = NSStringFromClass(view.class);
    return [className isEqualToString:@"PLPlatterView"]
        || [className isEqualToString:@"NCNotificationShortLookView"]
        || [className isEqualToString:@"NCNotificationLongLookView"];
}

static CGFloat LGClockNearestNotificationTop(UIView *host, UIView *container, CGRect sourceFrame) {
    if (!host || !container) return CGFLOAT_MAX;

    UIView *scanRoot = container.window ?: container;
    CGRect clockBand = CGRectInset(sourceFrame, -32.0, 0.0);
    __block CGFloat nearestTop = CGFLOAT_MAX;

    LGTraverseViews(scanRoot, ^(UIView *view) {
        if (view == host || [view isDescendantOfView:host]) return;
        if (!LGClockIsNotificationObstacleView(view)) return;

        CGRect obstacleFrame = [view convertRect:view.bounds toView:container];
        if (CGRectIsEmpty(obstacleFrame)) return;
        if (CGRectGetMaxX(obstacleFrame) < CGRectGetMinX(clockBand) ||
            CGRectGetMinX(obstacleFrame) > CGRectGetMaxX(clockBand)) {
            return;
        }
        if (CGRectGetMaxY(obstacleFrame) <= CGRectGetMinY(sourceFrame) + 1.0) return;

        nearestTop = MIN(nearestTop, CGRectGetMinY(obstacleFrame));
    });

    return nearestTop;
}

static CGFloat LGClockModernGlyphBottomForSourceFrame(CGRect sourceFrame,
                                                      NSString *text,
                                                      UIFont *font,
                                                      id ctFontObject,
                                                      CGFloat topInset) {
    if (CGRectIsEmpty(sourceFrame) || text.length == 0 || !font) return CGRectGetMaxY(sourceFrame);

    CGRect expanded = LGClockExpandedModernFrameForRect(sourceFrame,
                                                        nil,
                                                        text,
                                                        font,
                                                        ctFontObject,
                                                        NSTextAlignmentCenter);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);

    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGRect glyphBounds = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    if (CGRectIsNull(glyphBounds) || CGRectIsEmpty(glyphBounds)) {
        glyphBounds = CGRectMake(0.0, -descent, 0.0, ascent + descent);
    }
    CGFloat baseline = floor(CGRectGetHeight(expanded) - MAX(0.0, topInset) - ascent);
    CGFloat localBottom = CGRectGetHeight(expanded) - (baseline + CGRectGetMinY(glyphBounds));
    CFRelease(line);
    return CGRectGetMinY(expanded) + localBottom;
}

static CGFloat LGClockLineWidthForText(NSString *text, UIFont *font, id ctFontObject) {
    if (text.length == 0 || !font) return 0.0;
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
        (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
    };
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)attributed);
    CGFloat ascent = 0.0;
    CGFloat descent = 0.0;
    CGFloat leading = 0.0;
    CGFloat width = (CGFloat)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CFRelease(line);
    return ceil(width);
}

static CGFloat LGClockDynamicHeightAxisForContext(UILabel *label,
                                                  UIView *host,
                                                  UIView *container,
                                                  CGRect sourceFrame) {
    CGFloat requestedHeight = LGClockVariableFontHeight();
    if (!LGClockVariableFontEnabled() || !LGIsModernClockHost(host) || !label.text.length) return requestedHeight;

    CGFloat minimumHeight = 100.0;
    NSArray<NSNumber *> *heightRange = sClockVariableAxisRanges[@"height"];
    if (heightRange.count == 2) {
        minimumHeight = MAX(minimumHeight, heightRange[0].doubleValue);
    }
    if (requestedHeight <= minimumHeight + 0.5) return requestedHeight;

    CGFloat nearestTop = LGClockNearestNotificationTop(host, container, sourceFrame);
    if (nearestTop == CGFLOAT_MAX) return requestedHeight;

    UIFont *sourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    CGFloat pointSize = sourceFont.pointSize;
    static const CGFloat kClockBottomClearance = 10.0;

    CTFontRef requestedCTFont = LGClockVariableCTFontForHeight(pointSize, requestedHeight);
    id requestedFontObject = requestedCTFont ? (__bridge_transfer id)requestedCTFont : nil;
    UIFont *requestedFont = requestedFontObject ? (UIFont *)requestedFontObject : sourceFont;
    CGFloat requestedBottom = LGClockModernGlyphBottomForSourceFrame(sourceFrame,
                                                                     label.text,
                                                                     requestedFont,
                                                                     requestedFontObject,
                                                                     CGRectGetMinY(label.bounds));
    if (requestedBottom + kClockBottomClearance <= nearestTop) return requestedHeight;

    CGFloat low = minimumHeight;
    CGFloat high = requestedHeight;
    for (NSUInteger i = 0; i < 8; i++) {
        CGFloat mid = floor((low + high) * 0.5);
        CTFontRef midCTFont = LGClockVariableCTFontForHeight(pointSize, mid);
        id midFontObject = midCTFont ? (__bridge_transfer id)midCTFont : nil;
        UIFont *midFont = midFontObject ? (UIFont *)midFontObject : sourceFont;
        CGFloat midBottom = LGClockModernGlyphBottomForSourceFrame(sourceFrame,
                                                                   label.text,
                                                                   midFont,
                                                                   midFontObject,
                                                                   CGRectGetMinY(label.bounds));
        if (midBottom + kClockBottomClearance <= nearestTop) {
            low = mid;
        } else {
            high = mid;
        }
    }

    return floor(low);
}

static CGRect LGClockExpandedModernFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject,
                                                NSTextAlignment alignment) {
    if (CGRectIsEmpty(frame)) return frame;

    CGFloat resolvedLineHeight = MAX(CGRectGetHeight(frame), LGClockResolvedLineHeight(font, ctFontObject));
    CGFloat extraBottom = MAX(18.0, ceil(resolvedLineHeight - CGRectGetHeight(frame)) + ceil(resolvedLineHeight * 0.18) + 18.0);
    CGRect expanded = frame;
    expanded.size.height += extraBottom;

    CGFloat textWidth = LGClockLineWidthForText(text, font, ctFontObject);
    CGFloat desiredWidth = MAX(CGRectGetWidth(expanded), textWidth + 18.0);
    if (desiredWidth > CGRectGetWidth(expanded)) {
        CGFloat delta = desiredWidth - CGRectGetWidth(expanded);
        switch (alignment) {
            case NSTextAlignmentRight:
                expanded.origin.x -= delta;
                break;
            case NSTextAlignmentLeft:
            case NSTextAlignmentNatural:
            case NSTextAlignmentJustified:
                break;
            case NSTextAlignmentCenter:
            default:
                expanded.origin.x -= floor(delta * 0.5);
                break;
        }
        expanded.size.width = desiredWidth;
    }

    if (host) {
        CGFloat minX = CGRectGetMinX(host.bounds);
        CGFloat maxX = CGRectGetMaxX(host.bounds);
        if (CGRectGetMinX(expanded) < minX) {
            expanded.origin.x = minX;
        }
        if (CGRectGetMaxX(expanded) > maxX) {
            CGFloat overflow = CGRectGetMaxX(expanded) - maxX;
            expanded.size.width = MAX(0.0, expanded.size.width - overflow);
        }
        CGFloat minY = CGRectGetMinY(host.bounds);
        CGFloat maxY = CGRectGetMaxY(host.bounds);
        if (CGRectGetMinY(expanded) < minY) {
            expanded.origin.y = minY;
        }
        if (CGRectGetMaxY(expanded) > maxY) {
            CGFloat overflow = CGRectGetMaxY(expanded) - maxY;
            expanded.size.height = MAX(0.0, expanded.size.height - overflow);
        }
    }
    return expanded;
}

static CGRect LGClockExpandedLegacyFrameForRect(CGRect frame,
                                                UIView *host,
                                                NSString *text,
                                                UIFont *font,
                                                id ctFontObject) {
    if (CGRectIsEmpty(frame)) return frame;

    CGRect expanded = LGClockExpandedModernFrameForRect(frame,
                                                        nil,
                                                        text,
                                                        font,
                                                        ctFontObject,
                                                        NSTextAlignmentCenter);
    CGFloat textWidth = LGClockLineWidthForText(text, font, ctFontObject);
    CGFloat desiredWidth = MAX(CGRectGetWidth(expanded), textWidth + 18.0);
    if (desiredWidth > CGRectGetWidth(expanded)) {
        CGFloat delta = desiredWidth - CGRectGetWidth(expanded);
        expanded.origin.x -= floor(delta * 0.5);
        expanded.size.width = desiredWidth;
    }

    if (host) {
        CGFloat minX = CGRectGetMinX(host.bounds);
        CGFloat maxX = CGRectGetMaxX(host.bounds);
        if (CGRectGetMinX(expanded) < minX) {
            expanded.origin.x = minX;
        }
        if (CGRectGetMaxX(expanded) > maxX) {
            CGFloat overflow = CGRectGetMaxX(expanded) - maxX;
            expanded.size.width = MAX(0.0, expanded.size.width - overflow);
        }
        if (CGRectGetMaxY(expanded) > CGRectGetMaxY(host.bounds)) {
            CGFloat overflow = CGRectGetMaxY(expanded) - CGRectGetMaxY(host.bounds);
            expanded.size.height = MAX(0.0, expanded.size.height - overflow);
        }
    }
    return expanded;
}

static UIView *LGClockBestModernOverlayContainer(UIView *host, UILabel *label, UIFont *font, id ctFontObject) {
    if (!host || !label) return host;

    for (UIView *candidate = host.superview; candidate; candidate = candidate.superview) {
        CGRect sourceFrame = [label convertRect:label.bounds toView:candidate];
        CGRect expanded = LGClockExpandedModernFrameForRect(sourceFrame,
                                                            nil,
                                                            label.text,
                                                            font,
                                                            ctFontObject,
                                                            label.textAlignment);
        BOOL fitsVertically = CGRectGetMinY(expanded) >= 0.0 && CGRectGetMaxY(expanded) <= CGRectGetHeight(candidate.bounds);
        BOOL fitsHorizontally = CGRectGetMinX(expanded) >= -1.0 && CGRectGetMaxX(expanded) <= CGRectGetWidth(candidate.bounds) + 1.0;
        if (!LGClockContainerClips(candidate) && fitsVertically && fitsHorizontally) {
            return candidate;
        }
        if (candidate == host.window) break;
    }

    return host.window ?: host.superview ?: host;
}

@interface LGClockGlassView : UIView
@property (nonatomic, strong) LiquidGlassView *glassView;
@property (nonatomic, strong) UIView *tintView;
@property (nonatomic, copy) NSString *displayText;
@property (nonatomic, copy) NSAttributedString *displayAttributedText;
@property (nonatomic, strong) UIFont *displayFont;
@property (nonatomic, strong) id displayCTFont;
@property (nonatomic, assign) NSTextAlignment displayAlignment;
@property (nonatomic, assign) CGFloat displayTopInset;
@property (nonatomic, weak) UIView *clockHost;
@property (nonatomic, weak) UILabel *sourceLabel;
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

    _tintView = [[UIView alloc] initWithFrame:self.bounds];
    _tintView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tintView.userInteractionEnabled = NO;
    _tintView.backgroundColor = LGClockTintColorForView(self);
    [self addSubview:_tintView];
    return self;
}

- (NSAttributedString *)lg_maskAttributedString {
    if (LGClockVariableFontEnabled() && self.displayText.length > 0 && (self.displayCTFont || self.displayFont)) {
        UIFont *font = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
        id ctFontObject = self.displayCTFont;
        CTFontRef ctFont = NULL;
        if (!ctFontObject) {
            ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                    font.pointSize,
                                                    NULL);
            ctFontObject = (__bridge id)ctFont;
        }
        NSDictionary *attrs = @{
            (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
            (__bridge id)kCTForegroundColorAttributeName: (__bridge id)UIColor.whiteColor.CGColor,
        };
        NSAttributedString *string = [[NSAttributedString alloc] initWithString:self.displayText ?: @"" attributes:attrs];
        if (ctFont) CFRelease(ctFont);
        return string;
    }

    if (self.displayAttributedText.length > 0) {
        NSMutableAttributedString *copy = [self.displayAttributedText mutableCopy];
        [copy beginEditing];
        NSRange fullRange = NSMakeRange(0, copy.length);
        [copy enumerateAttribute:NSFontAttributeName
                         inRange:fullRange
                         options:0
                      usingBlock:^(id value, NSRange range, BOOL *stop) {
            UIFont *font = [value isKindOfClass:[UIFont class]] ? (UIFont *)value : self.displayFont;
            if (!font) font = [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
            [copy removeAttribute:NSFontAttributeName range:range];
            CTFontRef ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                              font.pointSize,
                                                              NULL);
            if (ctFont) {
                [copy addAttribute:(__bridge NSString *)kCTFontAttributeName value:(__bridge id)ctFont range:range];
                CFRelease(ctFont);
            }
        }];
        [copy removeAttribute:NSForegroundColorAttributeName range:fullRange];
        [copy removeAttribute:(__bridge NSString *)kCTForegroundColorAttributeName range:fullRange];
        [copy addAttribute:(__bridge NSString *)kCTForegroundColorAttributeName
                     value:(id)UIColor.whiteColor.CGColor
                     range:fullRange];
        [copy endEditing];
        return copy;
    }

    UIFont *font = self.displayFont ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
    id ctFontObject = self.displayCTFont;
    CTFontRef ctFont = NULL;
    if (!ctFontObject) {
        ctFont = CTFontCreateWithFontDescriptor((__bridge CTFontDescriptorRef)font.fontDescriptor,
                                                font.pointSize,
                                                NULL);
        ctFontObject = (__bridge id)ctFont;
    }
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName: ctFontObject ?: font,
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

    UIView *host = self.clockHost;
    if (!host) {
        host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
    }
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
    CGFloat baseline = 0.0;
    if (legacyHost) {
        baseline = floor(bounds.size.height - ascent);
    } else {
        CGFloat topInset = MAX(0.0, self.displayTopInset);
        baseline = floor(bounds.size.height - topInset - ascent);
    }
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
        self.tintView.maskView = nil;
        self.hidden = YES;
        return;
    }
    self.glassView.shapeMaskImage = maskImage;
    UIImageView *maskView = [[UIImageView alloc] initWithFrame:self.tintView.bounds];
    maskView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    maskView.image = maskImage;
    self.tintView.maskView = maskView;
    self.hidden = NO;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.glassView.frame = self.bounds;
    self.tintView.frame = self.bounds;
    self.glassView.wallpaperImage = LGClockWallpaperSource();
    self.glassView.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
    [self.glassView updateOrigin];
    [self lg_updateMask];
}

- (void)syncFromSourceLabel:(UILabel *)label {
    if (!label) return;
    self.displayText = label.text ?: @"";
    self.sourceLabel = label;
    UIView *host = self.clockHost;
    if (!host) {
        host = self.superview;
        while (host && !LGIsClockHost(host)) host = host.superview;
    }
    if (LGIsLegacyClockHost(host)) {
        UIView *container = self.superview ?: LGClockBestModernOverlayContainer(host,
                                                                                label,
                                                                                LGClockPreferredRenderFont(label, host),
                                                                                nil);
        CGRect sourceFrame = [label convertRect:label.bounds toView:container];
        self.displayCTFont = nil;
        self.displayFont = LGClockPreferredRenderFont(label, host);
        self.frame = LGClockExpandedLegacyFrameForRect(sourceFrame,
                                                       container,
                                                       self.displayText,
                                                       self.displayFont,
                                                       nil);
        self.displayAlignment = NSTextAlignmentCenter;
        self.displayAttributedText = nil;
        self.displayTopInset = 0.0;
    } else {
        UIView *container = self.superview ?: host.window ?: host;
        CGRect sourceFrame = [label convertRect:label.bounds toView:container];
        UIFont *sourceFont = label.font ?: [UIFont systemFontOfSize:84.0 weight:UIFontWeightBold];
        CGFloat pointSize = sourceFont.pointSize;
        CGFloat dynamicHeight = LGClockDynamicHeightAxisForContext(label, host, container, sourceFrame);
        CTFontRef renderCTFont = LGClockVariableCTFontForHeight(pointSize, dynamicHeight);
        id renderFontObject = renderCTFont ? (__bridge_transfer id)renderCTFont : nil;
        self.displayCTFont = renderFontObject;
        self.displayFont = renderFontObject ? (UIFont *)renderFontObject : LGClockPreferredRenderFont(label, host);
        self.frame = LGClockExpandedModernFrameForRect(sourceFrame,
                                                       container,
                                                       self.displayText,
                                                       self.displayFont,
                                                       self.displayCTFont,
                                                       label.textAlignment);
        self.displayAlignment = label.textAlignment;
        self.displayAttributedText = label.attributedText;
        self.displayTopInset = MAX(0.0, CGRectGetMinY(label.bounds));
    }
    self.glassView.bezelWidth = LGClockBezelWidth();
    self.glassView.glassThickness = LGClockGlassThickness();
    self.glassView.refractionScale = LGClockRefractionScale();
    self.glassView.refractiveIndex = LGClockRefractiveIndex();
    self.glassView.specularOpacity = LGClockSpecularOpacity();
    self.glassView.blur = LGClockBlur();
    self.glassView.wallpaperScale = LGClockWallpaperScale();
    self.tintView.backgroundColor = LGClockTintColorForView(host ?: self);
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

    UILabel *sourceLabel = overlay.sourceLabel;
    if (sourceLabel) {
        [overlay syncFromSourceLabel:sourceLabel];
    } else {
        overlay.glassView.wallpaperImage = LGClockWallpaperSource();
        overlay.glassView.wallpaperOrigin = LG_getLockscreenWallpaperOrigin();
        [overlay.glassView updateOrigin];
        [overlay setNeedsLayout];
    }
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
    LGDetachClockHostIfNeeded(host);
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

    UILabel *sourceLabel = LGClockPrimarySourceLabelForHost(host);
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

    UIView *overlayContainer = LGClockBestModernOverlayContainer(host,
                                                                 sourceLabel,
                                                                 LGClockPreferredRenderFont(sourceLabel, host),
                                                                 nil);

    if (!overlay) {
        overlay = [[LGClockGlassView alloc] initWithFrame:sourceLabel.frame];
        objc_setAssociatedObject(host, kLGClockOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [overlayContainer addSubview:overlay];
    } else if (overlay.superview != overlayContainer) {
        [overlay removeFromSuperview];
        [overlayContainer addSubview:overlay];
    }

    overlay.clockHost = host;
    LGAttachLockHostIfNeeded(host);
    LGAttachClockHostIfNeeded(host);
    LGEnsureClockScrollObserver(host, overlay);
    [overlay syncFromSourceLabel:sourceLabel];
    [overlay.superview bringSubviewToFront:overlay];
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

static void LGRefreshRegisteredClockHosts(void) {
    LGAssertMainThread();
    for (UIView *host in LGClockHostRegistry().allObjects) {
        if (!host.window) continue;
        LGApplyClockReplacement(host);
    }
    if (LGClockLiveHostCount() == 0) {
        LGStopClockDisplayLink();
    } else if (LGClockEnabled()) {
        LGStartClockDisplayLink();
    } else {
        LGStopClockDisplayLink();
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
            LGRefreshRegisteredClockHosts();
        });
    });
    %init(LGClockSpringBoard);
}
