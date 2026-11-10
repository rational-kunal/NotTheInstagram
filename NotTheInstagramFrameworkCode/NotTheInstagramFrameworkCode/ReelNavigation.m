#import "ReelNavigation.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <string.h>

static IMP NTIReelOriginalLoad;
static IMP NTIReelOriginalAppear;
static IMP NTIReelOriginalLayout;
static IMP NTIReelOriginalSetAdvanceDisabled;
static IMP NTIReelOriginalSetAutoAdvance;
static SEL NTIReelSetAdvanceDisabled;
static SEL NTIReelSetAutoAdvanceSelector;
static SEL NTIReelCollectionView;
static NSString *const NTIReelNavigationEnabledKey = @"NTIReelNavigationEnabled";

typedef struct {
    const char *selector;
    IMP replacement;
    IMP *original;
    const char *returnType;
    unsigned int argumentCount;
    const char *argumentTypes[3];
} NTIReelHook;

// Check the ABI before calling private methods or replacing their implementations.
static BOOL NTIReelMethodMatches(Method method, const char *result,
                                 unsigned int count, const char *const *arguments) {
    if (!method || method_getNumberOfArguments(method) != count + 2) return NO;
    char type[32];
    method_getReturnType(method, type, sizeof(type));
    if (strcmp(type, result)) return NO;
    for (unsigned int i = 0; i < count; i++) {
        method_getArgumentType(method, i + 2, type, sizeof(type));
        if (strcmp(type, arguments[i])) return NO;
    }
    return YES;
}

static IMP NTIReelReplace(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    IMP original = method_getImplementation(method);
    // Add an override when inherited; never modify a superclass's method.
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
    return original;
}

// Validate a complete group before installing any of it. Optional auto-scroll
// hooks are installed individually so missing APIs do not disable swipe blocking.
static BOOL NTIReelInstallHooks(Class cls, const NTIReelHook *hooks, size_t count) {
    if (!cls) return NO;
    for (size_t i = 0; i < count; i++) {
        const NTIReelHook *hook = &hooks[i];
        Method method = class_getInstanceMethod(cls, sel_registerName(hook->selector));
        if (!NTIReelMethodMatches(method, hook->returnType, hook->argumentCount, hook->argumentTypes)) return NO;
    }
    for (size_t i = 0; i < count; i++) {
        const NTIReelHook *hook = &hooks[i];
        IMP original = NTIReelReplace(cls, sel_registerName(hook->selector), hook->replacement);
        if (hook->original) *hook->original = original;
    }
    return YES;
}

static BOOL NTIReelAdvanceDisabled(id object, SEL selector) { return YES; }
static BOOL NTIReelAutoAdvanceEnabled(id object, SEL selector) { return NO; }

static void NTIReelSetDisabled(id object, SEL selector, BOOL disabled) {
    ((void (*)(id, SEL, BOOL))NTIReelOriginalSetAdvanceDisabled)(object, selector, YES);
}

static void NTIReelSetAutoAdvance(id object, SEL selector, BOOL enabled) {
    ((void (*)(id, SEL, BOOL))NTIReelOriginalSetAutoAdvance)(object, selector, NO);
}

static void NTIReelApplyFlags(id controller) {
    // Swift also reads these fields directly. Use Instagram's setters to update
    // backing state, in addition to overriding Objective-C getter dispatch.
    NTIReelSetDisabled(controller, NTIReelSetAdvanceDisabled, YES);
    NTIReelSetAutoAdvance(controller, NTIReelSetAutoAdvanceSelector, NO);
}

static void NTIReelDisablePaging(id controller) {
    id collection = ((id (*)(id, SEL))objc_msgSend)(controller, NTIReelCollectionView);
    if ([collection isKindOfClass:UICollectionView.class]) {
        // Do not walk the view tree: nested comments, carousels and playback
        // controls should keep their own gestures.
        ((UICollectionView *)collection).scrollEnabled = NO;
    }
}

static void NTIReelDidLoad(id controller, SEL selector) {
    NTIReelApplyFlags(controller);
    ((void (*)(id, SEL))NTIReelOriginalLoad)(controller, selector);
    NTIReelApplyFlags(controller);
    NTIReelDisablePaging(controller);
}

static void NTIReelWillAppear(id controller, SEL selector, BOOL animated) {
    NTIReelApplyFlags(controller);
    ((void (*)(id, SEL, BOOL))NTIReelOriginalAppear)(controller, selector, animated);
    NTIReelApplyFlags(controller);
    NTIReelDisablePaging(controller);
}

static void NTIReelDidLayout(id controller, SEL selector) {
    NTIReelApplyFlags(controller);
    ((void (*)(id, SEL))NTIReelOriginalLayout)(controller, selector);
    NTIReelApplyFlags(controller);
    NTIReelDisablePaging(controller);
}

static void NTIReelSkipAutoScrollTimer(id object, SEL selector, id access, id map, id block) {}
static void NTIReelSkipAutoScrollCountdown(id object, SEL selector, double duration, id block) {}

static void NTIInstallReelAutoScrollHooks(void) {
    // Suppress navigation timers without changing saved auto-scroll preferences.
    Class autoScroll = NSClassFromString(@"_TtC19IGSundialAutoScroll19IGSundialAutoScroll");
    const NTIReelHook hooks[] = {
        {"restartCurrentTimerIfNeededWithMediaAccess:mediaMap:block:", (IMP)NTIReelSkipAutoScrollTimer,
            NULL, @encode(void), 3, {@encode(id), @encode(id), "@?"}},
        {"setReelDuration:onCountdownFinishedCallBack:", (IMP)NTIReelSkipAutoScrollCountdown,
            NULL, @encode(void), 2, {@encode(double), "@?"}},
        {"isEnabled", (IMP)NTIReelAutoAdvanceEnabled, NULL, @encode(BOOL), 0, {NULL}},
    };
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) {
        NTIReelInstallHooks(autoScroll, &hooks[i], 1);
    }
}

static void NTIInstallReelNavigation(NSString *identifier) {
    if (![identifier isEqualToString:@"com.burbn.instagram"] &&
        ![identifier hasPrefix:@"com.burbn.instagram."]) return;
    if (NTIReelOriginalLoad) return;

    Class feed = NSClassFromString(@"IGSundialFeedViewController");
    if (!feed) return;
    NTIReelSetAdvanceDisabled = NSSelectorFromString(@"setAdvanceToNextItemDisabled:");
    NTIReelSetAutoAdvanceSelector = NSSelectorFromString(@"setAutoAdvanceToNextItem:");
    NTIReelCollectionView = NSSelectorFromString(@"collectionView");
    if (!NTIReelMethodMatches(class_getInstanceMethod(feed, NTIReelCollectionView), @encode(id), 0, NULL)) return;
    const NTIReelHook hooks[] = {
        {"setAdvanceToNextItemDisabled:", (IMP)NTIReelSetDisabled,
            &NTIReelOriginalSetAdvanceDisabled, @encode(void), 1, {@encode(BOOL)}},
        {"setAutoAdvanceToNextItem:", (IMP)NTIReelSetAutoAdvance,
            &NTIReelOriginalSetAutoAdvance, @encode(void), 1, {@encode(BOOL)}},
        {"advanceToNextItemDisabled", (IMP)NTIReelAdvanceDisabled, NULL, @encode(BOOL), 0, {NULL}},
        {"autoAdvanceToNextItem", (IMP)NTIReelAutoAdvanceEnabled, NULL, @encode(BOOL), 0, {NULL}},
        {"viewDidLoad", (IMP)NTIReelDidLoad, &NTIReelOriginalLoad, @encode(void), 0, {NULL}},
        {"viewWillAppear:", (IMP)NTIReelWillAppear, &NTIReelOriginalAppear, @encode(void), 1, {@encode(BOOL)}},
        {"viewDidLayoutSubviews", (IMP)NTIReelDidLayout, &NTIReelOriginalLayout, @encode(void), 0, {NULL}},
    };
    if (NTIReelInstallHooks(feed, hooks, sizeof(hooks) / sizeof(hooks[0]))) {
        NTIInstallReelAutoScrollHooks();
    }
}

@implementation NTIReelNavigation
+ (BOOL)isEnabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:NTIReelNavigationEnabledKey];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : YES;
}

+ (void)setEnabled:(BOOL)enabled {
    // Read only at installation; do not partially undo hooks on a live viewer.
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:NTIReelNavigationEnabledKey];
}

+ (void)load {
    if (self.isEnabled) NTIInstallReelNavigation(NSBundle.mainBundle.bundleIdentifier);
}
@end
