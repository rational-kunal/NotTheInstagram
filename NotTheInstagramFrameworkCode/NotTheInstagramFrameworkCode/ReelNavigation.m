#import "ReelNavigation.h"
#import "ReelRuntime.h"
#import "ReelTabSession.h"
#import "ReelPlaybackGate.h"
#import <objc/message.h>

static IMP NTIReelOriginalLoad, NTIReelOriginalAppear, NTIReelOriginalLayout;
static IMP NTIReelOriginalSetAdvanceDisabled, NTIReelOriginalSetAutoAdvance;
static IMP NTIReelOriginalAdvanceDisabled, NTIReelOriginalAutoAdvance;
static IMP NTIReelOriginalTimer, NTIReelOriginalCountdown, NTIReelOriginalEngineEnabled;
static Class NTIReelFeedClass;
static NSHashTable *NTIReelFeeds, *NTIReelEngines;
static NSString *const NTIReelNavigationEnabledKey = @"NTIReelNavigationEnabled";
static char NTIReelFeedStateKey;

@interface NTIReelFeedState : NSObject
@property BOOL nativeAdvanceDisabled;
@property BOOL nativeAutoAdvance;
@property BOOL restricted;
@property (weak) UICollectionView *collection;
@end
@implementation NTIReelFeedState
@end

static NTIReelFeedState *NTIReelState(id controller) {
    NTIReelFeedState *state = objc_getAssociatedObject(controller, &NTIReelFeedStateKey);
    if (!state) {
        state = [NTIReelFeedState new];
        state.nativeAdvanceDisabled = ((BOOL (*)(id, SEL))NTIReelOriginalAdvanceDisabled)(controller, sel_registerName("advanceToNextItemDisabled"));
        state.nativeAutoAdvance = ((BOOL (*)(id, SEL))NTIReelOriginalAutoAdvance)(controller, sel_registerName("autoAdvanceToNextItem"));
        objc_setAssociatedObject(controller, &NTIReelFeedStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NTIReelFeeds addObject:controller];
    }
    return state;
}

static BOOL NTIReelAllowsNavigation(UIViewController *controller) {
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:controller];
    return session.active && session.bypassed;
}

static BOOL NTIReelAdvanceDisabled(id controller, SEL selector) {
    return NTIReelAllowsNavigation(controller) ? NTIReelState(controller).nativeAdvanceDisabled : YES;
}
static BOOL NTIReelAutoAdvanceEnabled(id controller, SEL selector) {
    return NTIReelAllowsNavigation(controller) && NTIReelState(controller).nativeAutoAdvance;
}
static void NTIReelSetDisabled(id controller, SEL selector, BOOL disabled) {
    NTIReelState(controller).nativeAdvanceDisabled = disabled;
    ((void (*)(id, SEL, BOOL))NTIReelOriginalSetAdvanceDisabled)(controller, selector,
        NTIReelAllowsNavigation(controller) ? disabled : YES);
}
static void NTIReelSetAutoAdvance(id controller, SEL selector, BOOL enabled) {
    NTIReelState(controller).nativeAutoAdvance = enabled;
    ((void (*)(id, SEL, BOOL))NTIReelOriginalSetAutoAdvance)(controller, selector,
        NTIReelAllowsNavigation(controller) ? enabled : NO);
}

static void NTIReelApplyPolicy(UIViewController *controller) {
    NTIReelFeedState *state = NTIReelState(controller);
    BOOL restricted = !NTIReelAllowsNavigation(controller);
    // Swift reads backing fields directly too. Write with the original setters,
    // without replacing the remembered host requests with our enforced values.
    BOOL disableAdvance = restricted || state.nativeAdvanceDisabled;
    if (((BOOL (*)(id, SEL))NTIReelOriginalAdvanceDisabled)(controller, sel_registerName("advanceToNextItemDisabled")) != disableAdvance) {
        ((void (*)(id, SEL, BOOL))NTIReelOriginalSetAdvanceDisabled)(controller, sel_registerName("setAdvanceToNextItemDisabled:"), disableAdvance);
    }
    BOOL autoAdvance = !restricted && state.nativeAutoAdvance;
    if (((BOOL (*)(id, SEL))NTIReelOriginalAutoAdvance)(controller, sel_registerName("autoAdvanceToNextItem")) != autoAdvance) {
        ((void (*)(id, SEL, BOOL))NTIReelOriginalSetAutoAdvance)(controller, sel_registerName("setAutoAdvanceToNextItem:"), autoAdvance);
    }

    UICollectionView *collection = ((id (*)(id, SEL))objc_msgSend)(controller, sel_registerName("collectionView"));
    if ([collection isKindOfClass:UICollectionView.class]) {
        // Only restore paging when transitioning to a bypassed session or when
        // Instagram replaces the collection. Other native layout rules stay intact.
        if (restricted || state.restricted || state.collection != collection) {
            BOOL scrollEnabled = !disableAdvance;
            if (collection.scrollEnabled != scrollEnabled) collection.scrollEnabled = scrollEnabled;
        }
        state.collection = collection;
    }
    state.restricted = restricted;
}
static void NTIReelDidLoad(UIViewController *controller, SEL selector) {
    NTIReelApplyPolicy(controller);
    ((void (*)(id, SEL))NTIReelOriginalLoad)(controller, selector);
    NTIReelApplyPolicy(controller);
    NTIRefreshReelPlayback(controller);
}
static void NTIReelWillAppear(UIViewController *controller, SEL selector, BOOL animated) {
    NTIReelApplyPolicy(controller);
    ((void (*)(id, SEL, BOOL))NTIReelOriginalAppear)(controller, selector, animated);
    NTIReelApplyPolicy(controller);
    NTIRefreshReelPlayback(controller);
}
static void NTIReelDidLayout(UIViewController *controller, SEL selector) {
    ((void (*)(id, SEL))NTIReelOriginalLayout)(controller, selector);
    NTIReelApplyPolicy(controller);
    NTIRefreshReelPlayback(controller);
}

// Timed auto-scroll is never enabled by us. Preserve native behavior only when
// this engine can be tied to a bypassed tab feed; unknown ownership stays blocked.
static UIViewController *NTIReelEngineFeed(id engine) {
    SEL getter = NSSelectorFromString(@"feedDelegate");
    if (!NTIReelMethodMatches(class_getInstanceMethod([engine class], getter), @encode(id), 0, NULL)) return nil;
    id delegate = ((id (*)(id, SEL))objc_msgSend)(engine, getter);
    if ([delegate isKindOfClass:NTIReelFeedClass]) return delegate;
    if ([delegate isKindOfClass:UIResponder.class]) {
        for (UIResponder *next = delegate; next; next = next.nextResponder) {
            if ([next isKindOfClass:NTIReelFeedClass]) return (UIViewController *)next;
        }
    }
    return nil;
}
static BOOL NTIReelEngineAllowed(id engine) {
    if (!NSThread.isMainThread) return NO;
    [NTIReelEngines addObject:engine];
    return NTIReelAllowsNavigation(NTIReelEngineFeed(engine));
}
static BOOL NTIReelEngineEnabled(id engine, SEL selector) {
    return NTIReelEngineAllowed(engine) && ((BOOL (*)(id, SEL))NTIReelOriginalEngineEnabled)(engine, selector);
}
static void NTIReelAutoScrollTimer(id engine, SEL selector, id access, id map, id block) {
    if (NTIReelEngineAllowed(engine)) ((void (*)(id, SEL, id, id, id))NTIReelOriginalTimer)(engine, selector, access, map, block);
}
static void NTIReelAutoScrollCountdown(id engine, SEL selector, double duration, id block) {
    if (NTIReelEngineAllowed(engine)) ((void (*)(id, SEL, double, id))NTIReelOriginalCountdown)(engine, selector, duration, block);
}
static void NTIReelRefreshSessions(void) {
    for (UIViewController *controller in NTIReelFeeds.allObjects) NTIReelApplyPolicy(controller);
    for (id engine in NTIReelEngines.allObjects) {
        if (NTIReelAllowsNavigation(NTIReelEngineFeed(engine))) continue;
        SEL cancel = NSSelectorFromString(@"invalidateTimer");
        if (NTIReelMethodMatches(class_getInstanceMethod([engine class], cancel), @encode(void), 0, NULL)) {
            ((void (*)(id, SEL))objc_msgSend)(engine, cancel);
        }
    }
}
static void NTIInstallReelAutoScrollHooks(void) {
    Class engine = NSClassFromString(@"_TtC19IGSundialAutoScroll19IGSundialAutoScroll");
    const NTIReelHook hooks[] = {
        {"restartCurrentTimerIfNeededWithMediaAccess:mediaMap:block:", (IMP)NTIReelAutoScrollTimer,
            &NTIReelOriginalTimer, @encode(void), 3, {@encode(id), @encode(id), "@?"}},
        {"setReelDuration:onCountdownFinishedCallBack:", (IMP)NTIReelAutoScrollCountdown,
            &NTIReelOriginalCountdown, @encode(void), 2, {@encode(double), "@?"}},
        {"isEnabled", (IMP)NTIReelEngineEnabled, &NTIReelOriginalEngineEnabled, @encode(BOOL), 0, {NULL}},
    };
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); i++) NTIReelInstallHooks(engine, &hooks[i], 1);
}
static void NTIInstallReelNavigation(NSString *identifier) {
    if (![identifier isEqualToString:@"com.burbn.instagram"] && ![identifier hasPrefix:@"com.burbn.instagram."]) return;
    if (NTIReelOriginalLoad) return;
    Class feed = NSClassFromString(@"IGSundialFeedViewController");
    if (!feed || !NTIReelMethodMatches(class_getInstanceMethod(feed, NSSelectorFromString(@"collectionView")), @encode(id), 0, NULL)) return;
    NTIReelFeedClass = feed;
    NTIReelFeeds = NSHashTable.weakObjectsHashTable;
    NTIReelEngines = NSHashTable.weakObjectsHashTable;
    const NTIReelHook hooks[] = {
        {"setAdvanceToNextItemDisabled:", (IMP)NTIReelSetDisabled, &NTIReelOriginalSetAdvanceDisabled, @encode(void), 1, {@encode(BOOL)}},
        {"setAutoAdvanceToNextItem:", (IMP)NTIReelSetAutoAdvance, &NTIReelOriginalSetAutoAdvance, @encode(void), 1, {@encode(BOOL)}},
        {"advanceToNextItemDisabled", (IMP)NTIReelAdvanceDisabled, &NTIReelOriginalAdvanceDisabled, @encode(BOOL), 0, {NULL}},
        {"autoAdvanceToNextItem", (IMP)NTIReelAutoAdvanceEnabled, &NTIReelOriginalAutoAdvance, @encode(BOOL), 0, {NULL}},
        {"viewDidLoad", (IMP)NTIReelDidLoad, &NTIReelOriginalLoad, @encode(void), 0, {NULL}},
        {"viewWillAppear:", (IMP)NTIReelWillAppear, &NTIReelOriginalAppear, @encode(void), 1, {@encode(BOOL)}},
        {"viewDidLayoutSubviews", (IMP)NTIReelDidLayout, &NTIReelOriginalLayout, @encode(void), 0, {NULL}},
    };
    if (!NTIReelInstallHooks(feed, hooks, sizeof(hooks) / sizeof(hooks[0]))) return;
    NTIInstallReelAutoScrollHooks();
    // Keep the previously working restriction if the new tab/playback APIs differ.
    if (NTIInstallReelPlaybackGate()) [NTIReelTabSession installHooks];
    [NSNotificationCenter.defaultCenter addObserverForName:NTIReelTabSessionDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { NTIReelRefreshSessions(); }];
}

@implementation NTIReelNavigation
+ (BOOL)isEnabled {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:NTIReelNavigationEnabledKey];
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : YES;
}
+ (void)setEnabled:(BOOL)enabled {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:NTIReelNavigationEnabledKey];
}
+ (void)load {
    if (self.isEnabled) NTIInstallReelNavigation(NSBundle.mainBundle.bundleIdentifier);
}
@end
