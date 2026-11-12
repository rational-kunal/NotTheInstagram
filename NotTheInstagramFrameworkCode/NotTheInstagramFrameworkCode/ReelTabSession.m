#import "ReelTabSession.h"
#import "RuntimeHooks.h"

NSString *const NTIReelTabSessionDidChangeNotification = @"NTIReelTabSessionDidChange";
static const NSTimeInterval NTIReelBypassWait = 120.0;
static const NSTimeInterval NTIReelInitialPlaybackDelay = 3.0;
static const NSTimeInterval NTIReelPlaybackDelayIncrement = 0.5;
static Class NTIReelRootClass, NTIReelTabClass;
static char NTIReelTabSessionKey;
static char NTIReelRootVisibleKey;
static BOOL NTIReelTabHooksInstalled;
static NSHashTable<NTIReelTabSession *> *NTIReelTabSessions;
static IMP NTITabOriginalLoad, NTITabOriginalWillAppear, NTITabOriginalDidAppear;
static IMP NTITabOriginalWillDisappear, NTITabOriginalLayout, NTITabOriginalSelect;

@interface NTIReelTabSession ()
@property (nonatomic, weak, readwrite) UIViewController *controller;
@property (nonatomic, weak) UIViewController *tabController;
@property (nonatomic, strong) id surface;
@property (nonatomic, readwrite, getter=isBypassed) BOOL bypassed;
@property (nonatomic, readwrite, getter=isActive) BOOL active;
@property (nonatomic) BOOL visible;
@property (nonatomic) BOOL foreground;
@property (nonatomic) NSTimeInterval waitStarted;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) UIView *blocker;
@property (nonatomic) NSUInteger playedReelCount;
@property (nonatomic, copy) NSString *lastPlayedIdentity;
@property (nonatomic, weak) UIView *lastPlayedPlayer;
@property (nonatomic, strong) UIButton *continueButton;
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *accessibilityValues;
- (void)refresh;
- (void)endSession;
@end

static UIViewController *NTITabControllerForRoot(UIViewController *root) {
    for (UIViewController *parent = root.parentViewController; parent; parent = parent.parentViewController) {
        if ([parent isKindOfClass:NTIReelTabClass]) return parent;
    }
    return nil;
}

static BOOL NTITabIsPushedController(UIViewController *controller) {
    UIViewController *parent = controller.parentViewController;
    return [parent isKindOfClass:UINavigationController.class] &&
        ((UINavigationController *)parent).viewControllers.firstObject != controller;
}

static id NTITabSelectedReelsSurface(UIViewController *root, UIViewController *tabController) {
    if (!tabController || NTITabControllerForRoot(root) != tabController) return nil;
    // Instagram's predicate also recognizes the Homecoming Reels route, whose
    // surface does not have the legacy CLIPS label.
    SEL isReels = sel_registerName("isOnDiscoverVideo");
    if (!NTIMethodMatches(class_getInstanceMethod(object_getClass(tabController), isReels),
                              @encode(BOOL), 0, NULL) ||
        !((BOOL (*)(id, SEL))objc_msgSend)(tabController, isReels)) return nil;
    id selected = NTIObjectValue(tabController, @selector(selectedViewController));
    if (![selected isKindOfClass:UIViewController.class]) return nil;
    UIViewController *branch = selected;
    if ([branch isKindOfClass:UINavigationController.class]) {
        branch = ((UINavigationController *)branch).viewControllers.firstObject;
    }
    // A post can use the same root class, including on top of the Reels tab's
    // own stack. Only the root branch that the tab controller selected qualifies.
    for (UIViewController *current = root; current && current != tabController; current = current.parentViewController) {
        if (NTITabIsPushedController(current) || (current != root && [current isKindOfClass:NTIReelRootClass])) return nil;
        if (current == branch) return NTIObjectValue(tabController, sel_registerName("selectedTabBarSurface"));
    }
    return nil;
}

static BOOL NTITabSurfacesEqual(id first, id second) {
    return first == second || [first isEqual:second];
}

@implementation NTIReelTabSession

+ (instancetype)sessionForController:(UIViewController *)controller {
    if (!NTIReelTabHooksInstalled || !NSThread.isMainThread) return nil;
    for (UIViewController *current = controller; current; current = current.parentViewController) {
        if (NTITabIsPushedController(current)) return nil;
        if (![current isKindOfClass:NTIReelRootClass]) continue;
        UIViewController *tabController = NTITabControllerForRoot(current);
        id surface = NTITabSelectedReelsSurface(current, tabController);
        if (!surface) return nil;
        NTIReelTabSession *session = objc_getAssociatedObject(current, &NTIReelTabSessionKey);
        if (!session) {
            session = [[self alloc] init];
            session.controller = current;
            session.tabController = tabController;
            session.visible = [objc_getAssociatedObject(current, &NTIReelRootVisibleKey) boolValue];
            if (session.visible) session.surface = surface;
            session.foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
            session.accessibilityValues = [NSMapTable weakToStrongObjectsMapTable];
            objc_setAssociatedObject(current, &NTIReelTabSessionKey, session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [NTIReelTabSessions addObject:session];
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            [center addObserver:session selector:@selector(applicationWillResign:)
                           name:UIApplicationWillResignActiveNotification object:nil];
            [center addObserver:session selector:@selector(applicationDidBecomeActive:)
                           name:UIApplicationDidBecomeActiveNotification object:nil];
        }
        return session;
    }
    return nil;
}

- (void)dealloc {
    [_timer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)notifyChange {
    [NSNotificationCenter.defaultCenter postNotificationName:NTIReelTabSessionDidChangeNotification object:self];
}

- (BOOL)isSelected {
    id surface = NTITabSelectedReelsSurface(self.controller, self.tabController);
    return surface && NTITabSurfacesEqual(self.surface, surface);
}

- (void)stopWaiting {
    [self.timer invalidate];
    self.timer = nil;
    self.waitStarted = 0;
    if (!self.continueButton.hidden) self.continueButton.hidden = YES;
}

- (void)restoreAccessibility {
    for (UIView *view in self.accessibilityValues) {
        view.accessibilityElementsHidden = [[self.accessibilityValues objectForKey:view] boolValue];
    }
    [self.accessibilityValues removeAllObjects];
}

- (void)endSession {
    BOOL changed = self.active || self.bypassed;
    self.active = NO;
    self.bypassed = NO;
    self.playedReelCount = 0;
    self.lastPlayedIdentity = nil;
    self.lastPlayedPlayer = nil;
    [self stopWaiting];
    [self refreshBlockerForSelection:NTITabSelectedReelsSurface(self.controller, self.tabController) != nil];
    if (changed) [self notifyChange];
}

- (void)applicationWillResign:(NSNotification *)notification {
    self.foreground = NO;
    [self endSession];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    self.foreground = YES;
    [self refresh];
}

- (void)buildBlockerIfNeeded {
    UIView *root = self.controller.viewIfLoaded;
    if (!root || self.blocker.superview == root) return;
    [self restoreAccessibility];
    [self.blocker removeFromSuperview];
    UIView *blocker = [[UIView alloc] initWithFrame:root.bounds];
    blocker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blocker.backgroundColor = UIColor.systemBackgroundColor;
    blocker.accessibilityIdentifier = @"NTIReelsBlocker";
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    [blocker addSubview:scroll];

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"pause.circle"]];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.secondaryLabelColor;
    icon.isAccessibilityElement = NO;
    [icon.heightAnchor constraintEqualToConstant:64].active = YES;

    UILabel *title = [[UILabel alloc] init];
    title.text = @"Reels are paused";
    title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    title.adjustsFontForContentSizeCategory = YES;
    title.textAlignment = NSTextAlignmentCenter;
    title.numberOfLines = 0;
    title.textColor = UIColor.labelColor;
    title.accessibilityTraits |= UIAccessibilityTraitHeader;

    UILabel *body = [[UILabel alloc] init];
    body.text = @"Take a moment before watching. Stay on this screen to unlock the option to continue for this session. You can leave this tab at any time.";
    body.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    body.adjustsFontForContentSizeCategory = YES;
    body.textAlignment = NSTextAlignmentCenter;
    body.numberOfLines = 0;
    body.textColor = UIColor.secondaryLabelColor;

    self.continueButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *buttonConfiguration = [UIButtonConfiguration filledButtonConfiguration];
    buttonConfiguration.title = @"Continue for this session";
    buttonConfiguration.baseBackgroundColor = UIColor.labelColor;
    buttonConfiguration.baseForegroundColor = UIColor.systemBackgroundColor;
    buttonConfiguration.contentInsets = NSDirectionalEdgeInsetsMake(14, 20, 14, 20);
    buttonConfiguration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    buttonConfiguration.titleAlignment = UIButtonConfigurationTitleAlignmentCenter;
    buttonConfiguration.titleLineBreakMode = NSLineBreakByWordWrapping;
    buttonConfiguration.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary *result = attributes.mutableCopy;
        result[NSFontAttributeName] = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        return result;
    };
    self.continueButton.configuration = buttonConfiguration;
    self.continueButton.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.continueButton.titleLabel.numberOfLines = 0;
    self.continueButton.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.continueButton.hidden = YES;
    self.continueButton.accessibilityHint = @"Allows Reels until you leave this tab or put Instagram in the background.";
    [self.continueButton.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    [self.continueButton addTarget:self action:@selector(continueForSession:) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, body, self.continueButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 20;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    NSLayoutConstraint *center = [stack.centerYAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.centerYAnchor];
    center.priority = UILayoutPriorityDefaultLow;
    NSLayoutConstraint *preferredHeight = [scroll.contentLayoutGuide.heightAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.heightAnchor];
    preferredHeight.priority = UILayoutPriorityDefaultLow;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:blocker.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:blocker.safeAreaLayoutGuide.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:blocker.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:blocker.safeAreaLayoutGuide.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:28],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-28],
        [stack.topAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:28],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-56],
        [scroll.contentLayoutGuide.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor],
        preferredHeight,
        center,
    ]];
    self.blocker = blocker;
    [root addSubview:blocker];
}

- (void)refreshBlockerForSelection:(BOOL)selected {
    if (!selected) {
        [self restoreAccessibility];
        [self.blocker removeFromSuperview];
        self.blocker = nil;
        self.continueButton = nil;
        return;
    }
    [self buildBlockerIfNeeded];
    UIView *root = self.controller.viewIfLoaded;
    BOOL blocked = !self.bypassed;
    if (self.blocker.hidden == blocked) self.blocker.hidden = !blocked;
    if (!blocked) {
        [self restoreAccessibility];
        return;
    }
    if (!CGRectEqualToRect(self.blocker.frame, root.bounds)) self.blocker.frame = root.bounds;
    NSArray<UIView *> *children = root.subviews;
    if (children.lastObject != self.blocker) [root bringSubviewToFront:self.blocker];
    for (UIView *child in children) {
        if (child == self.blocker) continue;
        if (![self.accessibilityValues objectForKey:child]) {
            [self.accessibilityValues setObject:@(child.accessibilityElementsHidden) forKey:child];
        }
        if (!child.accessibilityElementsHidden) child.accessibilityElementsHidden = YES;
    }
}

- (BOOL)canWait {
    return self.active && self.visible && !self.bypassed && self.controller.viewIfLoaded.window &&
           self.foreground && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

- (BOOL)isPlaybackVisible {
    return self.active && self.visible && self.foreground && self.controller.viewIfLoaded.window != nil;
}

- (NSTimeInterval)playbackDelay {
    return NTIReelInitialPlaybackDelay + NTIReelPlaybackDelayIncrement * self.playedReelCount;
}

- (void)recordPlaybackWithIdentity:(NSString *)identity player:(UIView *)player {
    if (!self.active || !self.bypassed) return;
    // Legacy/modern/generic wrappers can report the same reel. Resuming it or
    // releasing another wrapper must not increase the delay a second time.
    BOOL sameReel = identity && self.lastPlayedIdentity
        ? [identity isEqualToString:self.lastPlayedIdentity]
        : self.lastPlayedPlayer == player;
    if (sameReel) return;
    self.lastPlayedIdentity = identity;
    self.lastPlayedPlayer = player;
    if (self.playedReelCount < NSUIntegerMax) self.playedReelCount++;
}

- (void)completeWaitOrSchedule {
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - self.waitStarted;
    NSTimeInterval remaining = NTIReelBypassWait - elapsed;
    if (remaining <= 0) {
        self.continueButton.hidden = NO;
        UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, self.continueButton);
        return;
    }

    __weak NTIReelTabSession *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:remaining repeats:NO block:^(NSTimer *timer) {
        NTIReelTabSession *session = weakSelf;
        session.timer = nil;
        if ([session canWait] && [session isSelected]) [session completeWaitOrSchedule];
        else [session stopWaiting];
    }];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)refresh {
    id surface = NTITabSelectedReelsSurface(self.controller, self.tabController);
    BOOL selected = surface && NTITabSurfacesEqual(self.surface, surface);
    BOOL foreground = self.foreground && UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
    if ((!selected || !foreground) && (self.active || self.bypassed)) {
        [self endSession];
        return;
    }
    BOOL changed = !self.active && selected && foreground && self.visible;
    if (changed) self.active = YES;
    [self refreshBlockerForSelection:surface != nil];
    if (selected && [self canWait]) {
        if (!self.waitStarted) self.waitStarted = NSProcessInfo.processInfo.systemUptime;
        if (!self.timer && self.continueButton.hidden) [self completeWaitOrSchedule];
    } else {
        [self stopWaiting];
    }
    if (changed) [self notifyChange];
}

- (void)continueForSession:(UIButton *)button {
    if (!self.waitStarted || ![self canWait] || ![self isSelected] ||
        NSProcessInfo.processInfo.systemUptime - self.waitStarted < NTIReelBypassWait) return;
    self.bypassed = YES;
    [self stopWaiting];
    [self refreshBlockerForSelection:YES];
    [self notifyChange];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, self.controller.viewIfLoaded);
}

static NTIReelTabSession *NTITabSessionForLifecycle(UIViewController *controller) {
    NTIReelTabSession *session = [NTIReelTabSession sessionForController:controller];
    if (session) {
        session.visible = [objc_getAssociatedObject(controller, &NTIReelRootVisibleKey) boolValue];
        if (session.visible && !session.active) {
            session.surface = NTITabSelectedReelsSurface(controller, session.tabController);
        }
    } else {
        // If Instagram repurposes a previously confirmed root, remove its old
        // blocker and bypass before it can be used as a standalone viewer.
        NTIReelTabSession *stale = objc_getAssociatedObject(controller, &NTIReelTabSessionKey);
        [stale endSession];
    }
    return session;
}

static void NTITabDidLoad(UIViewController *controller, SEL selector) {
    ((void (*)(id, SEL))NTITabOriginalLoad)(controller, selector);
    [NTITabSessionForLifecycle(controller) refresh];
}

static void NTITabWillAppear(UIViewController *controller, SEL selector, BOOL animated) {
    [NTITabSessionForLifecycle(controller) refreshBlockerForSelection:YES];
    ((void (*)(id, SEL, BOOL))NTITabOriginalWillAppear)(controller, selector, animated);
    [NTITabSessionForLifecycle(controller) refreshBlockerForSelection:YES];
}

static void NTITabDidAppear(UIViewController *controller, SEL selector, BOOL animated) {
    ((void (*)(id, SEL, BOOL))NTITabOriginalDidAppear)(controller, selector, animated);
    objc_setAssociatedObject(controller, &NTIReelRootVisibleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NTIReelTabSession *session = NTITabSessionForLifecycle(controller);
    BOOL wasActive = session.active;
    [session refresh];
    if (wasActive == session.active) [session notifyChange];
}

static void NTITabWillDisappear(UIViewController *controller, SEL selector, BOOL animated) {
    objc_setAssociatedObject(controller, &NTIReelRootVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NTIReelTabSession *session = objc_getAssociatedObject(controller, &NTIReelTabSessionKey);
    session.visible = NO;
    [session stopWaiting];
    [session notifyChange];
    ((void (*)(id, SEL, BOOL))NTITabOriginalWillDisappear)(controller, selector, animated);
    // The tab-selection hook ends the session on tab exit. Presenting comments
    // or a profile inside this tab only interrupts the wait, not an existing bypass.
}

static void NTITabDidLayout(UIViewController *controller, SEL selector) {
    ((void (*)(id, SEL))NTITabOriginalLayout)(controller, selector);
    [NTITabSessionForLifecycle(controller) refresh];
}

static void NTITabSelect(id controller, SEL selector, id surface, BOOL action, BOOL animated,
                         NSUInteger navigationAction, BOOL skipFetch, BOOL animateIndicator) {
    for (NTIReelTabSession *session in NTIReelTabSessions.allObjects) {
        if (session.tabController == controller && !NTITabSurfacesEqual(surface, session.surface)) {
            session.visible = NO;
            objc_setAssociatedObject(session.controller, &NTIReelRootVisibleKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [session endSession];
        }
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, NSUInteger, BOOL, BOOL))NTITabOriginalSelect)
        (controller, selector, surface, action, animated, navigationAction, skipFetch, animateIndicator);
}

+ (BOOL)installHooks {
    if (NTITabOriginalLoad) return NTIReelTabHooksInstalled;
    Class root = NSClassFromString(@"_TtC13IGSundialTabs30IGSundialRootTabViewController");
    Class tab = NSClassFromString(@"IGTabBarController");
    const NTIHook lifecycle[] = {
        {"viewDidLoad", (IMP)NTITabDidLoad, &NTITabOriginalLoad, @encode(void), 0, {NULL}},
        {"viewWillAppear:", (IMP)NTITabWillAppear, &NTITabOriginalWillAppear, @encode(void), 1, {@encode(BOOL)}},
        {"viewDidAppear:", (IMP)NTITabDidAppear, &NTITabOriginalDidAppear, @encode(void), 1, {@encode(BOOL)}},
        {"viewWillDisappear:", (IMP)NTITabWillDisappear, &NTITabOriginalWillDisappear, @encode(void), 1, {@encode(BOOL)}},
        {"viewDidLayoutSubviews", (IMP)NTITabDidLayout, &NTITabOriginalLayout, @encode(void), 0, {NULL}},
    };
    const NTIHook selection = {
        "_setSelectedTabBarSurface:isTabBarAction:animated:navigationAction:skipMainFeedFetch:animateIndicator:",
        (IMP)NTITabSelect, &NTITabOriginalSelect, @encode(void), 6,
        {@encode(id), @encode(BOOL), @encode(BOOL), @encode(NSUInteger), @encode(BOOL), @encode(BOOL)}
    };
    if (![root isSubclassOfClass:UIViewController.class] || ![tab isSubclassOfClass:UIViewController.class] ||
        !NTIMethodMatches(class_getInstanceMethod(tab, sel_registerName("isOnDiscoverVideo")), @encode(BOOL), 0, NULL) ||
        !NTIMethodMatches(class_getInstanceMethod(tab, sel_registerName("selectedTabBarSurface")), @encode(id), 0, NULL) ||
        !NTIMethodMatches(class_getInstanceMethod(tab, @selector(selectedViewController)), @encode(id), 0, NULL)) return NO;
    size_t lifecycleCount = sizeof(lifecycle) / sizeof(lifecycle[0]);
    if (!NTIHooksMatch(root, lifecycle, lifecycleCount) || !NTIHooksMatch(tab, &selection, 1)) return NO;
    NTIReelRootClass = root;
    NTIReelTabClass = tab;
    NTIReelTabSessions = NSHashTable.weakObjectsHashTable;
    NTIReplaceHooks(root, lifecycle, lifecycleCount);
    NTIReplaceHooks(tab, &selection, 1);
    NTIReelTabHooksInstalled = YES;
    return YES;
}
@end
