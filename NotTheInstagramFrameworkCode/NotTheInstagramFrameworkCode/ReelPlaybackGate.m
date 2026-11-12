#import "ReelPlaybackGate.h"
#import "ReelRuntime.h"
#import "ReelTabSession.h"
#import <objc/message.h>
static Class NTIPlaybackFeedClass;
static NSHashTable *NTIPlaybackRequests;
static char NTIPlaybackRequestKey;
static __weak UIViewController *NTIPlaybackReleasingFeed;

typedef struct {
    const char *className;
    const char *startName;
    const char *pauseName;
    const char *stopName;
    IMP start, pause, stop, reuse;
} NTIPlaybackAPI;
static NTIPlaybackAPI NTIPlaybackAPIs[] = {
    {"_TtC11IGVideoView11IGVideoView", "startPlaybackWith:", "pausePlaybackWith:", "stopPlaybackWith:"},
    {"_TtC30IGSundialCommonUIVideoPlayback26IGSundialVideoPlaybackView", "playWithReason:", "pauseWithReason:", "stopWithReason:"},
    {"_TtC30IGSundialCommonUIVideoPlayback32IGSundialModernVideoPlaybackView", "playWithReason:", "pauseWithReason:", "stopWithReason:"},
};

static id NTIPlaybackObject(id object, const char *name) {
    SEL selector = sel_registerName(name);
    if (!NTIReelMethodMatches(class_getInstanceMethod([object class], selector), @encode(id), 0, NULL)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}
static UIViewController *NTIPlaybackFeed(UIView *view) {
    for (UIResponder *next = view; next; next = next.nextResponder) {
        if ([next isKindOfClass:NTIPlaybackFeedClass]) return (UIViewController *)next;
    }
    return nil;
}
static id NTIPlaybackIdentity(UIView *view) {
    id video = NTIPlaybackObject(view, "videoViewIfAvailable") ?: view;
    id identity = NTIPlaybackObject(video, "currentVideoRepresentationId");
    // Keep a stable value, never a mutable media object or a reused cell index.
    return [identity isKindOfClass:NSString.class] ? [identity copy] : nil;
}
static BOOL NTIPlaybackIsVisible(UIView *view, UIViewController *feed) {
    if (!view.window || !feed.viewIfLoaded.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    for (UIView *ancestor = view; ancestor; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.01) return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:feed.view];
    CGRect intersection = CGRectIntersection(frame, feed.view.bounds);
    return !CGRectIsNull(intersection) && CGRectGetHeight(intersection) > MIN(80, CGRectGetHeight(frame) / 2) &&
        CGRectGetWidth(intersection) > MIN(80, CGRectGetWidth(frame) / 2);
}

@interface NTIReelPlaybackRequest : NSObject
@property (weak) UIView *player;
@property (weak) UIViewController *feed;
@property NTIPlaybackAPI *api;
@property NSInteger reason;
@property BOOL wanted;
@property BOOL released;
@property (strong) id identity;
@property NSTimeInterval deadline;
@property (strong) NSTimer *timer;
@property (strong) UIVisualEffectView *cover;
- (void)reconcile;
- (void)cancelDelay;
@end

@implementation NTIReelPlaybackRequest
- (void)dealloc { [_timer invalidate]; }
- (void)cancelDelay {
    [self.timer invalidate];
    self.timer = nil;
    self.deadline = 0;
    [self.cover removeFromSuperview];
    self.cover = nil;
}
- (void)showCover {
    if (self.cover) return;
    UIView *player = self.player;
    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
    self.cover = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.cover.frame = player.bounds;
    self.cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.cover.userInteractionEnabled = NO;
    if (UIAccessibilityIsReduceTransparencyEnabled()) self.cover.backgroundColor = UIColor.systemBackgroundColor;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pause.circle"]];
    icon.tintColor = UIColor.labelColor;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.isAccessibilityElement = YES;
    icon.accessibilityLabel = @"Playback paused";
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cover.contentView addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerYAnchor constraintEqualToAnchor:self.cover.contentView.centerYAnchor],
        [icon.centerXAnchor constraintEqualToAnchor:self.cover.contentView.centerXAnchor],
        [icon.widthAnchor constraintEqualToConstant:52],
        [icon.heightAnchor constraintEqualToConstant:52],
    ]];
    [player addSubview:self.cover];
}
- (void)releasePlayback {
    UIView *player = self.player;
    if (!player || !self.wanted) return;
    [self cancelDelay];
    self.released = YES;
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:self.feed];
    id video = NTIPlaybackObject(player, "videoViewIfAvailable");
    UIView *canonicalPlayer = [video isKindOfClass:UIView.class] ? video : player;
    [session recordPlaybackWithIdentity:self.identity player:canonicalPlayer];
    UIViewController *previous = NTIPlaybackReleasingFeed;
    NTIPlaybackReleasingFeed = self.feed;
    // Nested legacy/modern/generic playback calls share this release so their
    // wrappers do not each impose another three seconds.
    ((void (*)(id, SEL, NSInteger))self.api->start)(player, sel_registerName(self.api->startName), self.reason);
    NTIPlaybackReleasingFeed = previous;
}
- (void)reconcile {
    UIView *player = self.player;
    if (!player) { [self cancelDelay]; return; }
    UIViewController *feed = NTIPlaybackFeed(player);
    if (self.feed && self.feed != feed) {
        [self cancelDelay];
        self.wanted = NO;
        self.released = NO;
    }
    self.feed = feed;
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:self.feed];
    id identity = NTIPlaybackIdentity(player);
    if ((identity || self.identity) && ![identity isEqual:self.identity]) {
        [self cancelDelay];
        // Reconfiguration is not a new play request. Wait for the host to ask
        // for this representation rather than transfer an older request to it.
        self.wanted = NO;
        self.released = NO;
        self.identity = identity;
    }
    if (!session) { [self cancelDelay]; return; }
    if (!session.playbackVisible || !session.bypassed || !NTIPlaybackIsVisible(player, self.feed)) {
        [self cancelDelay];
        if (self.released) {
            // Playback reasons are opaque host values. Reuse the observed start
            // reason rather than inventing a numeric enum case.
            ((void (*)(id, SEL, NSInteger))self.api->pause)(player, sel_registerName(self.api->pauseName), self.reason);
            self.released = NO;
        }
        return;
    }
    if (!self.wanted || self.released) return;
    if (!self.deadline) {
        self.deadline = NSProcessInfo.processInfo.systemUptime + session.playbackDelay;
        [self showCover];
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
            NTIReelPlaybackRequest *request = weakSelf;
            if (!request) { [timer invalidate]; return; }
            [request reconcile];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    if (NSProcessInfo.processInfo.systemUptime >= self.deadline) [self releasePlayback];
}
@end

static NTIReelPlaybackRequest *NTIPlaybackRequest(UIView *player, NTIPlaybackAPI *api) {
    NTIReelPlaybackRequest *request = objc_getAssociatedObject(player, &NTIPlaybackRequestKey);
    if (!request) {
        request = [NTIReelPlaybackRequest new];
        request.player = player;
        request.api = api;
        objc_setAssociatedObject(player, &NTIPlaybackRequestKey, request, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NTIPlaybackRequests addObject:request];
    }
    return request;
}
static void NTIPlaybackStart(UIView *player, SEL selector, NSInteger reason, NTIPlaybackAPI *api) {
    // UIKit ownership and session state are main-thread confined. Preserve host
    // dispatch for an unexpected background call rather than touch its view tree.
    if (!NSThread.isMainThread) {
        ((void (*)(id, SEL, NSInteger))api->start)(player, selector, reason);
        return;
    }
    NTIReelPlaybackRequest *request = NTIPlaybackRequest(player, api);
    request.reason = reason;
    request.wanted = YES;
    UIViewController *feed = NTIPlaybackFeed(player);
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:feed];
    id identity = NTIPlaybackIdentity(player);
    if (request.feed && request.feed != feed) {
        [request cancelDelay];
        request.released = NO;
    }
    if ((identity || request.identity) && ![identity isEqual:request.identity]) {
        [request cancelDelay];
        request.released = NO;
    }
    request.identity = identity;
    request.feed = feed;
    if (!session || (NTIPlaybackReleasingFeed && NTIPlaybackReleasingFeed == feed) ||
        (session.playbackVisible && session.bypassed && request.released && NTIPlaybackIsVisible(player, feed))) {
        [request cancelDelay];
        request.released = YES;
        ((void (*)(id, SEL, NSInteger))api->start)(player, selector, reason);
        return;
    }
    [request reconcile];
}
static void NTIPlaybackPause(UIView *player, SEL selector, NSInteger reason, NTIPlaybackAPI *api, BOOL stop) {
    if (!NSThread.isMainThread) {
        ((void (*)(id, SEL, NSInteger))(stop ? api->stop : api->pause))(player, selector, reason);
        __weak UIView *weakPlayer = player;
        dispatch_async(dispatch_get_main_queue(), ^{
            NTIReelPlaybackRequest *request = objc_getAssociatedObject(weakPlayer, &NTIPlaybackRequestKey);
            request.wanted = NO;
            if (stop) request.released = NO;
            [request cancelDelay];
        });
        return;
    }
    NTIReelPlaybackRequest *request = objc_getAssociatedObject(player, &NTIPlaybackRequestKey);
    request.wanted = NO;
    [request cancelDelay];
    if (stop) request.released = NO;
    ((void (*)(id, SEL, NSInteger))(stop ? api->stop : api->pause))(player, selector, reason);
}
static void NTIPlaybackReuse(UIView *player, SEL selector, NTIPlaybackAPI *api) {
    if (!NSThread.isMainThread) {
        ((void (*)(id, SEL))api->reuse)(player, selector);
        __weak UIView *weakPlayer = player;
        dispatch_async(dispatch_get_main_queue(), ^{
            NTIReelPlaybackRequest *request = objc_getAssociatedObject(weakPlayer, &NTIPlaybackRequestKey);
            request.wanted = NO;
            request.released = NO;
            request.identity = nil;
            [request cancelDelay];
        });
        return;
    }
    NTIReelPlaybackRequest *request = objc_getAssociatedObject(player, &NTIPlaybackRequestKey);
    request.wanted = NO;
    request.released = NO;
    request.identity = nil;
    [request cancelDelay];
    ((void (*)(id, SEL))api->reuse)(player, selector);
}
#define NTI_PLAYBACK_CALLBACKS(N) \
static void NTIPlaybackStart##N(UIView *v, SEL s, NSInteger r) { NTIPlaybackStart(v, s, r, &NTIPlaybackAPIs[N]); } \
static void NTIPlaybackPause##N(UIView *v, SEL s, NSInteger r) { NTIPlaybackPause(v, s, r, &NTIPlaybackAPIs[N], NO); } \
static void NTIPlaybackStop##N(UIView *v, SEL s, NSInteger r) { NTIPlaybackPause(v, s, r, &NTIPlaybackAPIs[N], YES); } \
static void NTIPlaybackReuse##N(UIView *v, SEL s) { NTIPlaybackReuse(v, s, &NTIPlaybackAPIs[N]); }
NTI_PLAYBACK_CALLBACKS(0)
NTI_PLAYBACK_CALLBACKS(1)
NTI_PLAYBACK_CALLBACKS(2)
#undef NTI_PLAYBACK_CALLBACKS

void NTIRefreshReelPlayback(UIViewController *controller) {
    if (!NSThread.isMainThread) return;
    for (NTIReelPlaybackRequest *request in NTIPlaybackRequests.allObjects) {
        if (!controller || NTIPlaybackFeed(request.player) == controller) [request reconcile];
    }
}
BOOL NTIInstallReelPlaybackGate(void) {
    if (NTIPlaybackRequests) return YES;
    NTIPlaybackFeedClass = NSClassFromString(@"IGSundialFeedViewController");
    IMP starts[] = {(IMP)NTIPlaybackStart0, (IMP)NTIPlaybackStart1, (IMP)NTIPlaybackStart2};
    IMP pauses[] = {(IMP)NTIPlaybackPause0, (IMP)NTIPlaybackPause1, (IMP)NTIPlaybackPause2};
    IMP stops[] = {(IMP)NTIPlaybackStop0, (IMP)NTIPlaybackStop1, (IMP)NTIPlaybackStop2};
    IMP reuses[] = {(IMP)NTIPlaybackReuse0, (IMP)NTIPlaybackReuse1, (IMP)NTIPlaybackReuse2};
    // All three known playback paths are required for a visible blocker. If a
    // future Instagram ABI differs, retain the old navigation restriction only.
    for (size_t i = 0; i < 3; i++) {
        NTIPlaybackAPI *api = &NTIPlaybackAPIs[i];
        Class cls = NSClassFromString(@(api->className));
        const char *argument[] = {@encode(NSInteger)};
        if (!cls || ![cls isSubclassOfClass:UIView.class]) return NO;
        const char *names[] = {api->startName, api->pauseName, api->stopName};
        for (size_t n = 0; n < 3; n++) {
            if (!NTIReelMethodMatches(class_getInstanceMethod(cls, sel_registerName(names[n])), @encode(void), 1, argument)) return NO;
        }
        if (!NTIReelMethodMatches(class_getInstanceMethod(cls, @selector(prepareForReuse)), @encode(void), 0, NULL)) return NO;
    }
    NTIPlaybackRequests = NSHashTable.weakObjectsHashTable;
    for (size_t i = 0; i < 3; i++) {
        NTIPlaybackAPI *api = &NTIPlaybackAPIs[i];
        const NTIReelHook hooks[] = {
            {api->startName, starts[i], &api->start, @encode(void), 1, {@encode(NSInteger)}},
            {api->pauseName, pauses[i], &api->pause, @encode(void), 1, {@encode(NSInteger)}},
            {api->stopName, stops[i], &api->stop, @encode(void), 1, {@encode(NSInteger)}},
            {"prepareForReuse", reuses[i], &api->reuse, @encode(void), 0, {NULL}},
        };
        NTIReelInstallHooks(NSClassFromString(@(api->className)), hooks, 4);
    }
    [NSNotificationCenter.defaultCenter addObserverForName:NTIReelTabSessionDidChangeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { NTIRefreshReelPlayback(nil); }];
    return YES;
}
