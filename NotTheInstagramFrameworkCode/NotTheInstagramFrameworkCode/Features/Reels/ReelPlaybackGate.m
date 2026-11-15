#import "ReelPlaybackGate.h"
#import "../../Runtime/RuntimeHooks.h"
#import "ReelTabSession.h"

@class NTIReelPlaybackRequest;
static Class NTIPlaybackFeedClass;
static NSHashTable<NTIReelPlaybackRequest *> *NTIPlaybackRequests;
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

static UIViewController *NTIPlaybackFeed(UIView *view) {
    for (UIResponder *next = view; next; next = next.nextResponder) {
        if ([next isKindOfClass:NTIPlaybackFeedClass]) return (UIViewController *)next;
    }
    return nil;
}
static NSString *NTIPlaybackIdentity(UIView *view) {
    id video = NTIObjectValue(view, sel_registerName("videoViewIfAvailable")) ?: view;
    id identity = NTIObjectValue(video, sel_registerName("currentVideoRepresentationId"));
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
@property (strong) NSString *identity;
@property NSTimeInterval deadline;
@property (strong) NSTimer *timer;
@property (strong) UIVisualEffectView *cover;
- (void)updateFeed:(UIViewController *)feed;
- (void)reconcileWithSession:(NTIReelTabSession *)session;
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
- (void)releasePlaybackInSession:(NTIReelTabSession *)session {
    UIView *player = self.player;
    if (!player || !self.wanted) return;
    [self cancelDelay];
    self.released = YES;
    id video = NTIObjectValue(player, sel_registerName("videoViewIfAvailable"));
    UIView *canonicalPlayer = [video isKindOfClass:UIView.class] ? video : player;
    [session recordPlaybackWithIdentity:self.identity player:canonicalPlayer];
    UIViewController *previous = NTIPlaybackReleasingFeed;
    NTIPlaybackReleasingFeed = self.feed;
    // Nested legacy/modern/generic playback calls share this release so their
    // wrappers do not each impose another three seconds.
    ((void (*)(id, SEL, NSInteger))self.api->start)(player, sel_registerName(self.api->startName), self.reason);
    NTIPlaybackReleasingFeed = previous;
}
- (void)updateFeed:(UIViewController *)feed {
    NSString *identity = NTIPlaybackIdentity(self.player);
    if ((self.feed && self.feed != feed) ||
        (self.identity != identity && ![self.identity isEqualToString:identity])) {
        [self cancelDelay];
        // Reconfiguration is not a new play request. Wait for the host to ask
        // for this representation rather than transfer an older request to it.
        self.wanted = NO;
        self.released = NO;
    }
    self.feed = feed;
    self.identity = identity;
}
- (void)reconcileWithSession:(NTIReelTabSession *)session {
    if (!session) { [self cancelDelay]; return; }
    if (!self.wanted && !self.released) return;
    UIView *player = self.player;
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
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!self.deadline) {
        self.deadline = now + session.playbackDelay;
        [self showCover];
    }
    NSTimeInterval remaining = self.deadline - now;
    if (remaining <= 0) {
        [self releasePlaybackInSession:session];
    } else if (!self.timer) {
        __weak typeof(self) weakSelf = self;
        self.timer = [NSTimer timerWithTimeInterval:remaining repeats:NO block:^(NSTimer *timer) {
            NTIReelPlaybackRequest *request = weakSelf;
            request.timer = nil;
            UIViewController *feed = NTIPlaybackFeed(request.player);
            [request updateFeed:feed];
            [request reconcileWithSession:[NTIReelTabSession sessionForController:feed]];
        }];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
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
    UIViewController *feed = NTIPlaybackFeed(player);
    // The generic player is shared by unrelated Instagram videos. Sundial
    // wrappers can be warmed up before they are attached to a feed.
    if (!feed && api == &NTIPlaybackAPIs[0]) {
        NTIReelPlaybackRequest *request = objc_getAssociatedObject(player, &NTIPlaybackRequestKey);
        if (request) {
            [request cancelDelay];
            objc_setAssociatedObject(player, &NTIPlaybackRequestKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        ((void (*)(id, SEL, NSInteger))api->start)(player, selector, reason);
        return;
    }
    NTIReelPlaybackRequest *request = NTIPlaybackRequest(player, api);
    [request updateFeed:feed];
    request.reason = reason;
    request.wanted = YES;
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:feed];
    if (!session || NTIPlaybackReleasingFeed == feed ||
        (session.playbackVisible && session.bypassed && request.released && NTIPlaybackIsVisible(player, feed))) {
        [request cancelDelay];
        request.released = YES;
        ((void (*)(id, SEL, NSInteger))api->start)(player, selector, reason);
        return;
    }
    [request reconcileWithSession:session];
}

static void NTIPlaybackCancel(UIView *player, BOOL reset) {
    NTIReelPlaybackRequest *request = objc_getAssociatedObject(player, &NTIPlaybackRequestKey);
    request.wanted = NO;
    if (reset) request.released = NO;
    [request cancelDelay];
}

static void NTIPlaybackCancelLater(UIView *player, BOOL reset) {
    __weak UIView *weakPlayer = player;
    dispatch_async(dispatch_get_main_queue(), ^{ NTIPlaybackCancel(weakPlayer, reset); });
}

static void NTIPlaybackPause(UIView *player, SEL selector, NSInteger reason, NTIPlaybackAPI *api, BOOL stop) {
    BOOL onMain = NSThread.isMainThread;
    if (onMain) NTIPlaybackCancel(player, stop);
    ((void (*)(id, SEL, NSInteger))(stop ? api->stop : api->pause))(player, selector, reason);
    if (!onMain) NTIPlaybackCancelLater(player, stop);
}
static void NTIPlaybackReuse(UIView *player, SEL selector, NTIPlaybackAPI *api) {
    BOOL onMain = NSThread.isMainThread;
    if (onMain) NTIPlaybackCancel(player, YES);
    ((void (*)(id, SEL))api->reuse)(player, selector);
    if (!onMain) NTIPlaybackCancelLater(player, YES);
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

#define NTI_PLAYBACK_HOOKS(N) { \
    {NTIPlaybackAPIs[N].startName, (IMP)NTIPlaybackStart##N, &NTIPlaybackAPIs[N].start, @encode(void), 1, {@encode(NSInteger)}}, \
    {NTIPlaybackAPIs[N].pauseName, (IMP)NTIPlaybackPause##N, &NTIPlaybackAPIs[N].pause, @encode(void), 1, {@encode(NSInteger)}}, \
    {NTIPlaybackAPIs[N].stopName, (IMP)NTIPlaybackStop##N, &NTIPlaybackAPIs[N].stop, @encode(void), 1, {@encode(NSInteger)}}, \
    {"prepareForReuse", (IMP)NTIPlaybackReuse##N, &NTIPlaybackAPIs[N].reuse, @encode(void), 0, {NULL}}, \
}

void NTIRefreshReelPlayback(UIViewController *controller) {
    if (!NSThread.isMainThread) return;
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:controller];
    for (NTIReelPlaybackRequest *request in NTIPlaybackRequests.allObjects) {
        UIViewController *feed = NTIPlaybackFeed(request.player);
        if (controller && feed != controller && request.feed != controller) continue;
        [request updateFeed:feed];
        [request reconcileWithSession:controller && feed == controller ? session : [NTIReelTabSession sessionForController:feed]];
    }
}
BOOL NTIInstallReelPlaybackGate(void) {
    if (NTIPlaybackRequests) return YES;
    const NTIHook hooks[][4] = {NTI_PLAYBACK_HOOKS(0), NTI_PLAYBACK_HOOKS(1), NTI_PLAYBACK_HOOKS(2)};
    Class classes[sizeof(hooks) / sizeof(hooks[0])];
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
        classes[i] = NSClassFromString(@(NTIPlaybackAPIs[i].className));
        if (![classes[i] isSubclassOfClass:UIView.class] || !NTIHooksMatch(classes[i], hooks[i], 4)) return NO;
    }
    // The tab blocker requires all known playback paths. Incompatible tab
    // hooks likewise leave shared video players on their original methods.
    if (![NTIReelTabSession installHooks]) return NO;
    NTIPlaybackFeedClass = NSClassFromString(@"IGSundialFeedViewController");
    NTIPlaybackRequests = NSHashTable.weakObjectsHashTable;
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) NTIReplaceHooks(classes[i], hooks[i], 4);
    [NSNotificationCenter.defaultCenter addObserverForName:NTIReelTabSessionDidChangeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { NTIRefreshReelPlayback(nil); }];
    return YES;
}
#undef NTI_PLAYBACK_HOOKS
