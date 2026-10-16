// The native player's hookup for scrubbing with broader runtime detection.
// (Patch: broaden hooked classes and add safe fallbacks.)

#import "Core/SGCore.h"
#import <objc/runtime.h>

// The player's vertical list (the string is in 9.1.78's binary), so a sideways list inside it is not the one held.
static NSString *const kListIdentifier = @"scrolling_npv_collection_view_accessibility_identifier";

// The list whose pan a scrub turned off, so only that one is turned back on: a pan off for some other
// reason stays off. One finger scrubs at a time, so one is enough.
static __weak UIScrollView *sg_scrubbedList;

static void scrubBegan(UIView *slider) {
    UIScrollView *list = nil;
    for (UIView *v = slider.superview; v && !list; v = v.superview) {
        if ([v isKindOfClass:UIScrollView.class] && [v.accessibilityIdentifier isEqualToString:kListIdentifier]) list = (UIScrollView *)v;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"native player: a scrub %@", list ? @"holds the list's pan" : @"found no list above the slider"); });
    if (!list || !list.panGestureRecognizer.enabled) return;
    list.panGestureRecognizer.enabled = NO;
    sg_scrubbedList = list;
}

static void scrubEnded(void) {
    if (!sg_scrubbedList) return;
    sg_scrubbedList.panGestureRecognizer.enabled = YES;
    sg_scrubbedList = nil;
}

// Candidate class names Spotify may use for the now-playing progress control.
// This keeps the hook resilient across builds that ship alternate control classes.
static NSArray<NSString *> *SGProgressBarCandidates(void) {
    return @[
        @"_TtCO17NowPlaying_ECMKit11ProgressBar6Slider",
        @"_TtCO17NowPlaying_ECMKit11ProgressBar6SeekBar",
        @"_TtCO17NowPlaying_ECMKit11SliderNowPlaying",
        @"_TtCO17NowPlaying_ECMKit11SeekBarView",
        @"_TtC17NowPlaying_ECMKit11ProgressBar6Slider"
    ];
}

static void SGHookProgressBarClass(Class cls) {
    if (!cls) return;

    Method mBegin = class_getInstanceMethod(cls, @selector(beginTrackingWithTouch:withEvent:));
    Method mEnd = class_getInstanceMethod(cls, @selector(endTrackingWithTouch:withEvent:));
    Method mCancel = class_getInstanceMethod(cls, @selector(cancelTrackingWithEvent:));
    Method mDidMove = class_getInstanceMethod(cls, @selector(didMoveToWindow));

    if (mBegin) {
        IMP origImp = method_getImplementation(mBegin);
        IMP newImp = imp_implementationWithBlock(^BOOL(id self, UITouch *touch, UIEvent *event) {
            BOOL tracking = ((BOOL(*)(id, SEL, UITouch *, UIEvent *))origImp)(self, @selector(beginTrackingWithTouch:withEvent:), touch, event);
            if (tracking) scrubBegan((UIView *)self);
            return tracking;
        });
        method_setImplementation(mBegin, newImp);
    }
    if (mEnd) {
        IMP origImp = method_getImplementation(mEnd);
        IMP newImp = imp_implementationWithBlock(^void(id self, UITouch *touch, UIEvent *event) {
            ((void(*)(id, SEL, UITouch *, UIEvent *))origImp)(self, @selector(endTrackingWithTouch:withEvent:), touch, event);
            scrubEnded();
        });
        method_setImplementation(mEnd, newImp);
    }
    if (mCancel) {
        IMP origImp = method_getImplementation(mCancel);
        IMP newImp = imp_implementationWithBlock(^void(id self, UIEvent *event) {
            ((void(*)(id, SEL, UIEvent *))origImp)(self, @selector(cancelTrackingWithEvent:), event);
            scrubEnded();
        });
        method_setImplementation(mCancel, newImp);
    }
    if (mDidMove) {
        IMP origImp = method_getImplementation(mDidMove);
        IMP newImp = imp_implementationWithBlock(^void(id self) {
            ((void(*)(id, SEL))origImp)(self, @selector(didMoveToWindow));
            if (!((UIView *)self).window) scrubEnded();
        });
        method_setImplementation(mDidMove, newImp);
    }
}

static void SGHookProgressBars(void) {
    for (NSString *name in SGProgressBarCandidates()) {
        Class cls = NSClassFromString(name);
        if (cls) SGHookProgressBarClass(cls);
    }
}

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGHookProgressBars();
}
