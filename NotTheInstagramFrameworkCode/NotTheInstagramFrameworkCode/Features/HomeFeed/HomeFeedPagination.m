#import <UIKit/UIKit.h>
#import "HomeFeedBatch.h"
#import "HomeFeedLoadingSection.h"
#import "../../Runtime/RuntimeHooks.h"

static const NSUInteger NTIHomeFeedBatchSize = 3;
static Class NTIHomeFeedModelClass, NTIHomeFeedTabClass, NTIHomeFeedSpinnerClass;
static Class NTIHomeFeedObjCClass, NTIHomeFeedSwiftClass;
static Class NTIHomeFeedMediaClass, NTIHomeFeedPostItemClass, NTIHomeFeedLoadingSectionClass;
static IMP NTIOriginalHomeFeedBind, NTIOriginalHomeFeedScroll, NTIOriginalHomeFeedWillDisplay;
static IMP NTIOriginalHomeFeedObjCLoadMore, NTIOriginalHomeFeedSwiftLoadMore;
static IMP NTIOriginalHomeFeedObjCAppear, NTIOriginalHomeFeedSwiftAppear, NTIOriginalHomeFeedDisappear;
static IMP NTIOriginalHomeFeedLegacyFinish, NTIOriginalHomeFeedSwiftFinish;
static IMP NTIOriginalHomeFeedObjCObjects, NTIOriginalHomeFeedSwiftObjects;
static IMP NTIOriginalHomeFeedObjCSection, NTIOriginalHomeFeedSwiftSection;
static Ivar NTIHomeFeedProviderIvar;
static char NTIHomeFeedModelStateKey, NTIHomeFeedProviderStateKey;

static BOOL NTIHomeFeedObjCLoadMore(id provider, SEL selector, NSInteger prefetchType, NSInteger reason, id params);
static BOOL NTIHomeFeedSwiftLoadMore(id provider, SEL selector, NSInteger prefetchType, NSInteger reason, id params);

typedef NS_ENUM(NSUInteger, NTIHomeFeedPageDecision) {
    NTIHomeFeedPageWait,
    NTIHomeFeedPageReady,
    NTIHomeFeedPageNative
};

@interface NTIHomeFeedPaginationState : NSObject
@property (nonatomic, weak) UIViewController *feed;
@property (nonatomic, weak) id model;
@property (nonatomic, weak) id provider;
@property (nonatomic, weak) id adapter;
@property (nonatomic, strong) id firstPostIdentifier;
@property (nonatomic, strong) NTIHomeFeedLoadingItem *loadingItem;
@property (nonatomic, strong) id visibleLoader;
@property (nonatomic) NSUInteger revealedPosts;
@property (nonatomic) NSUInteger presentedPosts;
@property (nonatomic) NSUInteger revealLimitBeforeRequest;
@property (nonatomic) NSUInteger completedWaits;
@property (nonatomic) NSTimeInterval visibleSince;
@property (nonatomic) BOOL requested;
@property (nonatomic, strong) NSTimer *timer;
@end

static NTIHomeFeedPageDecision NTIHomeFeedUpdateWait(NTIHomeFeedPaginationState *state, BOOL atDeadline);

@implementation NTIHomeFeedPaginationState
- (void)pause {
    [self.timer invalidate];
    self.timer = nil;
    self.visibleLoader = nil;
    self.visibleSince = 0;
}

- (void)resume {
    NTIHomeFeedUpdateWait(self, YES);
}

- (void)pauseForNotification:(NSNotification *)notification {
    (void)notification;
    [self pause];
}

- (void)resumeForNotification:(NSNotification *)notification {
    (void)notification;
    [self resume];
}

- (void)dealloc {
    [_timer invalidate];
}
@end

static BOOL NTIHomeFeedIsMainController(id controller) {
    return (NTIHomeFeedObjCClass && [controller isKindOfClass:NTIHomeFeedObjCClass]) ||
        (NTIHomeFeedSwiftClass && [controller isKindOfClass:NTIHomeFeedSwiftClass]);
}

static BOOL NTIHomeFeedIsPrimaryModel(id model) {
    return [model isKindOfClass:NTIHomeFeedModelClass] &&
        NTIBoolValueIs(model, sel_registerName("isSecondaryFeed"), NO) &&
        !NTIBoolValueIs(model, sel_registerName("isInFollowingTab"), YES);
}

static BOOL NTIHomeFeedIsVisible(UIViewController *feed) {
    if (!feed.viewIfLoaded.window || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIViewController *child = feed;
    for (UIViewController *parent = child.parentViewController; parent; parent = child.parentViewController) {
        if (child.presentedViewController || parent.presentedViewController) return NO;
        if ([parent isKindOfClass:UINavigationController.class] &&
            ((UINavigationController *)parent).topViewController != child) return NO;
        if ([parent isKindOfClass:NTIHomeFeedTabClass]) {
            return NTIBoolValueIs(parent, sel_registerName("isOnMainFeed"), YES) &&
                NTIObjectValue(parent, @selector(selectedViewController)) == child;
        }
        child = parent;
    }
    return NO;
}

static BOOL NTIHomeFeedIsLoadingItem(id object) {
    return [object isKindOfClass:NTIHomeFeedLoadingItem.class] ||
        [object isKindOfClass:NTIHomeFeedSpinnerClass];
}

static BOOL NTIHomeFeedHasLoader(NSArray *objects) {
    for (id object in objects.reverseObjectEnumerator) {
        if (NTIHomeFeedIsLoadingItem(object)) return YES;
    }
    return NO;
}

static id NTIHomeFeedVisibleLoader(NSArray *objects, UICollectionView *collection) {
    CGRect viewport = UIEdgeInsetsInsetRect(collection.bounds, collection.adjustedContentInset);
    for (NSIndexPath *path in collection.indexPathsForVisibleItems) {
        if (path.length != 2 || (NSUInteger)path.section >= objects.count) continue;
        id object = objects[(NSUInteger)path.section];
        if (!NTIHomeFeedIsLoadingItem(object)) continue;
        UICollectionViewCell *cell = [collection cellForItemAtIndexPath:path];
        if (cell.window && !cell.hidden && CGRectContainsPoint(viewport, cell.center)) return object;
    }
    return nil;
}

static NTIHomeFeedPaginationState *NTIHomeFeedStateForController(UIViewController *feed) {
    id model = NTIObjectValue(feed, sel_registerName("viewModel"));
    NTIHomeFeedPaginationState *state = objc_getAssociatedObject(model, &NTIHomeFeedModelStateKey);
    return state.feed == feed ? state : nil;
}

static void NTIHomeFeedObjCAppear(UIViewController *feed, SEL selector, BOOL animated) {
    ((void (*)(id, SEL, BOOL))NTIOriginalHomeFeedObjCAppear)(feed, selector, animated);
    [NTIHomeFeedStateForController(feed) resume];
}

static void NTIHomeFeedSwiftAppear(UIViewController *feed, SEL selector, BOOL animated) {
    ((void (*)(id, SEL, BOOL))NTIOriginalHomeFeedSwiftAppear)(feed, selector, animated);
    [NTIHomeFeedStateForController(feed) resume];
}

static void NTIHomeFeedRequestNextPage(NTIHomeFeedPaginationState *state) {
    UIViewController *feed = state.feed;
    // The ObjC controller also schedules the native loading-state update.
    SEL nextPage = sel_registerName("_fetchNextPage");
    if (NTIMethodMatches(class_getInstanceMethod(object_getClass(feed), nextPage), @encode(void), 0, NULL)) {
        ((void (*)(id, SEL))objc_msgSend)(feed, nextPage);
        return;
    }
    SEL fetch = sel_registerName("fetchMoreItemsWithPrefetchType:");
    if (((BOOL (*)(id, SEL, NSInteger))objc_msgSend)(state.model, fetch, 0)) {
        SEL render = sel_registerName("mainFeedViewModelNeedsRenderFeed:");
        const char *arguments[] = {@encode(id)};
        if (NTIMethodMatches(class_getInstanceMethod(object_getClass(feed), render),
                             @encode(void), 1, arguments)) {
            ((void (*)(id, SEL, id))objc_msgSend)(feed, render, state.model);
        }
    }
}

static void NTIHomeFeedSchedule(NTIHomeFeedPaginationState *state, NSTimeInterval delay) {
    if (state.timer) return;
    __weak NTIHomeFeedPaginationState *weakState = state;
    state.timer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        NTIHomeFeedPaginationState *current = weakState;
        if (!current || current.timer != timer) return;
        current.timer = nil;
        NTIHomeFeedUpdateWait(current, YES);
    }];
    [NSRunLoop.mainRunLoop addTimer:state.timer forMode:NSRunLoopCommonModes];
}

static NTIHomeFeedPageDecision NTIHomeFeedUpdateWait(NTIHomeFeedPaginationState *state, BOOL atDeadline) {
    UIViewController *feed = state.feed;
    id model = state.model;
    if (!feed || !NTIHomeFeedIsPrimaryModel(model) || NTIObjectValue(feed, sel_registerName("viewModel")) != model ||
        !NTIHomeFeedIsVisible(feed)) {
        [state pause];
        return NTIHomeFeedPageWait;
    }
    id adapter = state.adapter ?: NTIObjectValue(feed, sel_registerName("listAdapter"));
    id collection = NTIObjectValue(adapter, @selector(collectionView));
    if (![collection isKindOfClass:UICollectionView.class] || ![collection window]) {
        [state pause];
        return NTIHomeFeedPageWait;
    }
    if ([collection hasUncommittedUpdates] || !NTIBoolValueIs(adapter, sel_registerName("isInObjectUpdateTransaction"), NO)) {
        if (state.visibleSince || state.loadingItem) NTIHomeFeedSchedule(state, 0.15);
        return NTIHomeFeedPageWait;
    }
    id objects = NTIObjectValue(adapter, sel_registerName("objects"));
    if (![objects isKindOfClass:NSArray.class] || ![objects count]) {
        [state pause];
        return NTIHomeFeedPageWait;
    }
    id loader = NTIHomeFeedVisibleLoader(objects, collection);
    if (!loader) {
        [state pause];
        BOOL canLoadNatively = !state.loadingItem && NTIBoolValueIs(model, sel_registerName("moreAvailable"), YES) &&
            !NTIHomeFeedHasLoader(objects);
        return canLoadNatively ? NTIHomeFeedPageNative : NTIHomeFeedPageWait;
    }
    BOOL syntheticLoader = [loader isKindOfClass:NTIHomeFeedLoadingItem.class];
    if (syntheticLoader && loader != state.loadingItem) return NTIHomeFeedPageWait;
    BOOL localBatch = syntheticLoader && !state.loadingItem.requestsPage;
    if (!localBatch && (!NTIBoolValueIs(model, sel_registerName("moreAvailable"), YES) ||
                       (state.loadingItem && !state.loadingItem.requestsPage) || state.requested)) return NTIHomeFeedPageWait;
    id loaderIdentifier = localBatch ? loader : NTIHomeFeedSpinnerClass;
    if (state.visibleLoader != loaderIdentifier) {
        [state pause];
        state.visibleLoader = loaderIdentifier;
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (!state.visibleSince) state.visibleSince = now;
    NSTimeInterval remaining = NTIHomeFeedLoaderDuration(state.completedWaits) - (now - state.visibleSince);
    if (remaining > 0) {
        NTIHomeFeedSchedule(state, remaining);
        return NTIHomeFeedPageWait;
    }
    if (localBatch) {
        if (!atDeadline) {
            NTIHomeFeedSchedule(state, 0);
            return NTIHomeFeedPageWait;
        }
        [state pause];
        state.completedWaits++;
        state.revealedPosts += NTIHomeFeedBatchSize;
        state.loadingItem = nil;
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(adapter, sel_registerName("performUpdatesAnimated:completion:"), NO, nil);
        return NTIHomeFeedPageWait;
    }
    if (!NTIBoolValueIs(model, sel_registerName("isLoading"), NO)) return NTIHomeFeedPageWait;
    if (atDeadline) NTIHomeFeedRequestNextPage(state);
    return NTIHomeFeedPageReady;
}

static NTIHomeFeedPaginationState *NTIHomeFeedAttach(id model, UIViewController *feed) {
    if (!NSThread.isMainThread || !NTIHomeFeedIsMainController(feed)) return nil;
    NTIHomeFeedPaginationState *state = objc_getAssociatedObject(model, &NTIHomeFeedModelStateKey);
    if (!NTIHomeFeedIsPrimaryModel(model)) {
        if (state.feed == feed) [state pause];
        return nil;
    }
    id provider = object_getIvar(model, NTIHomeFeedProviderIvar);
    if (!provider) return nil;
    if (state.feed == feed && state.provider == provider) return state;
    IMP fetch = class_getMethodImplementation(object_getClass(provider),
                    sel_registerName("canLoadMoreWithPrefetchType:reason:extraParams:"));
    [state pause];
    id previousProvider = state.provider;
    if (previousProvider && objc_getAssociatedObject(previousProvider, &NTIHomeFeedProviderStateKey) == state) {
        objc_setAssociatedObject(previousProvider, &NTIHomeFeedProviderStateKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    state = [NTIHomeFeedPaginationState new];
    state.feed = feed;
    state.model = model;
    state.provider = provider;
    state.revealedPosts = NTIHomeFeedBatchSize;
    objc_setAssociatedObject(model, &NTIHomeFeedModelStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (fetch == (IMP)NTIHomeFeedObjCLoadMore || fetch == (IMP)NTIHomeFeedSwiftLoadMore) {
        objc_setAssociatedObject(provider, &NTIHomeFeedProviderStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:state selector:@selector(pauseForNotification:)
                   name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:state selector:@selector(resumeForNotification:)
                   name:UIApplicationDidBecomeActiveNotification object:nil];
    return state;
}

static void NTIHomeFeedBind(id model, SEL selector, UIViewController *feed) {
    NTIHomeFeedAttach(model, feed);
    ((void (*)(id, SEL, id))NTIOriginalHomeFeedBind)(model, selector, feed);
    NTIHomeFeedAttach(model, feed);
}

static BOOL NTIHomeFeedIsPost(id object, NSHashTable *viewablePosts) {
    if ([object isKindOfClass:NTIHomeFeedMediaClass] || [object isKindOfClass:NTIHomeFeedPostItemClass] ||
        [viewablePosts containsObject:object]) return YES;
    SEL mediaType = sel_registerName("mediaTypeEnum");
    Method method = class_getInstanceMethod(object_getClass(object), mediaType);
    return (NTIMethodMatches(method, @encode(NSInteger), 0, NULL) ||
            NTIMethodMatches(method, @encode(int), 0, NULL)) &&
        NTIObjectValue(object, sel_registerName("mediaId")) != nil;
}

static NSArray *NTIHomeFeedProjectObjects(id adapter, NSArray *objects) {
    if (![objects isKindOfClass:NSArray.class] || !objects.count || !NSThread.isMainThread) return objects;
    UIViewController *feed = NTIObjectValue(adapter, @selector(viewController));
    id mainAdapter = NTIObjectValue(feed, sel_registerName("listAdapter"));
    if (mainAdapter && mainAdapter != adapter) return objects;
    id model = NTIObjectValue(feed, sel_registerName("viewModel"));
    NTIHomeFeedPaginationState *state = NTIHomeFeedAttach(model, feed);
    if (!state) return objects;
    state.adapter = adapter;

    id posts = NTIObjectValue(model, sel_registerName("viewablePosts"));
    NSHashTable *viewablePosts = nil;
    if ([posts isKindOfClass:NSArray.class] && [posts count]) {
        viewablePosts = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        for (id post in posts) [viewablePosts addObject:post];
    }
    id firstPost = nil;
    for (id object in objects) {
        if (NTIHomeFeedIsPost(object, viewablePosts)) {
            firstPost = NTIObjectValue(object, sel_registerName("mediaId")) ?:
                NTIObjectValue(object, sel_registerName("diffIdentifier")) ?: object;
            break;
        }
    }
    if (firstPost && ![state.firstPostIdentifier isEqual:firstPost]) {
        [state pause];
        state.firstPostIdentifier = firstPost;
        state.revealedPosts = NTIHomeFeedBatchSize;
        state.completedWaits = 0;
        state.loadingItem = nil;
    }
    NSUInteger presentedPosts = 0;
    NSUInteger cutoff = NTIHomeFeedBatchCutoff(objects, state.revealedPosts, &presentedPosts, ^BOOL(id object) {
        return NTIHomeFeedIsPost(object, viewablePosts);
    });
    state.presentedPosts = presentedPosts;
    BOOL bufferedPosts = cutoff < objects.count;
    BOOL needsPageLoader = !bufferedPosts && presentedPosts > 0 &&
        objc_getAssociatedObject(state.provider, &NTIHomeFeedProviderStateKey) == state &&
        NTIBoolValueIs(model, sel_registerName("moreAvailable"), YES) && !NTIHomeFeedHasLoader(objects);
    if (!bufferedPosts && !needsPageLoader) {
        state.loadingItem = nil;
        return objects;
    }
    if (!state.loadingItem || state.loadingItem.requestsPage != needsPageLoader) {
        state.loadingItem = [NTIHomeFeedLoadingItem new];
        state.loadingItem.requestsPage = needsPageLoader;
    }
    NSMutableArray *batch = [NSMutableArray arrayWithCapacity:cutoff + 1];
    for (NSUInteger index = 0; index < cutoff; index++) [batch addObject:objects[index]];
    [batch addObject:state.loadingItem];
    return batch;
}

static id NTIHomeFeedObjCObjects(id source, SEL selector, id adapter) {
    return NTIHomeFeedProjectObjects(adapter, ((id (*)(id, SEL, id))NTIOriginalHomeFeedObjCObjects)(source, selector, adapter));
}

static id NTIHomeFeedSwiftObjects(id source, SEL selector, id adapter) {
    return NTIHomeFeedProjectObjects(adapter, ((id (*)(id, SEL, id))NTIOriginalHomeFeedSwiftObjects)(source, selector, adapter));
}

static id NTIHomeFeedSection(IMP original, id source, SEL selector, id adapter, id object) {
    if (![object isKindOfClass:NTIHomeFeedLoadingItem.class]) {
        return ((id (*)(id, SEL, id, id))original)(source, selector, adapter, object);
    }
    return NTIHomeFeedMakeLoadingSection(NTIHomeFeedLoadingSectionClass, adapter);
}

static id NTIHomeFeedObjCSection(id source, SEL selector, id adapter, id object) {
    return NTIHomeFeedSection(NTIOriginalHomeFeedObjCSection, source, selector, adapter, object);
}

static id NTIHomeFeedSwiftSection(id source, SEL selector, id adapter, id object) {
    return NTIHomeFeedSection(NTIOriginalHomeFeedSwiftSection, source, selector, adapter, object);
}

static NTIHomeFeedPaginationState *NTIHomeFeedStateForAdapter(id adapter, UIScrollView *scrollView) {
    if (!NSThread.isMainThread || NTIObjectValue(adapter, @selector(collectionView)) != scrollView) return nil;
    id feed = NTIObjectValue(adapter, @selector(viewController));
    if (!NTIHomeFeedIsMainController(feed)) return nil;
    NTIHomeFeedPaginationState *state = NTIHomeFeedStateForController(feed);
    id mainAdapter = state.adapter ?: NTIObjectValue(feed, sel_registerName("listAdapter"));
    return mainAdapter == adapter ? state : nil;
}

static void NTIHomeFeedDidScroll(id adapter, SEL selector, UIScrollView *scrollView) {
    NTIHomeFeedPaginationState *state = NTIHomeFeedStateForAdapter(adapter, scrollView);
    if (state) NTIHomeFeedUpdateWait(state, NO);
    ((void (*)(id, SEL, id))NTIOriginalHomeFeedScroll)(adapter, selector, scrollView);
}

static void NTIHomeFeedWillDisplay(id adapter, SEL selector, UICollectionView *collection,
                                  UICollectionViewCell *cell, NSIndexPath *path) {
    ((void (*)(id, SEL, id, id, id))NTIOriginalHomeFeedWillDisplay)(adapter, selector, collection, cell, path);
    NTIHomeFeedPaginationState *state = NTIHomeFeedStateForAdapter(adapter, collection);
    if (state && path.length == 2) {
        id objects = NTIObjectValue(adapter, sel_registerName("objects"));
        BOOL loaderCell = [cell isKindOfClass:NTIHomeFeedLoadingCell.class] ||
            ([objects isKindOfClass:NSArray.class] && (NSUInteger)path.section < [objects count] &&
             NTIHomeFeedIsLoadingItem(objects[(NSUInteger)path.section]));
        if (!loaderCell) return;
        __weak NTIHomeFeedPaginationState *weakState = state;
        dispatch_async(dispatch_get_main_queue(), ^{
            NTIHomeFeedPaginationState *current = weakState;
            if (current) NTIHomeFeedUpdateWait(current, NO);
        });
    }
}

static BOOL NTIHomeFeedLoadMore(IMP original, id provider, SEL selector,
                                NSInteger prefetchType, NSInteger reason, id params) {
    NTIHomeFeedPaginationState *state = objc_getAssociatedObject(provider, &NTIHomeFeedProviderStateKey);
    BOOL (*loadMore)(id, SEL, NSInteger, NSInteger, id) = (BOOL (*)(id, SEL, NSInteger, NSInteger, id))original;
    if (!state || !state.feed || !state.model ||
        (NSThread.isMainThread && !NTIHomeFeedIsPrimaryModel(state.model))) {
        return loadMore(provider, selector, prefetchType, reason, params);
    }
    // The provider method starts a next-page load and reports whether it started.
    // Keep native callers on their existing retry path until the spinner is visible.
    if (!NSThread.isMainThread || state.requested || (state.loadingItem && !state.loadingItem.requestsPage)) return NO;
    NTIHomeFeedPageDecision decision = NTIHomeFeedUpdateWait(state, NO);
    if (decision == NTIHomeFeedPageWait) return NO;
    if (decision == NTIHomeFeedPageNative) {
        return loadMore(provider, selector, prefetchType, reason, params);
    }
    state.requested = YES;
    state.revealLimitBeforeRequest = state.revealedPosts;
    if (state.presentedPosts) state.revealedPosts = state.presentedPosts + NTIHomeFeedBatchSize;
    BOOL started = loadMore(provider, selector, prefetchType, reason, params);
    if (!started) {
        state.revealedPosts = state.revealLimitBeforeRequest;
        state.requested = NO;
    } else {
        [state.timer invalidate];
        state.timer = nil;
    }
    return started;
}

static BOOL NTIHomeFeedObjCLoadMore(id provider, SEL selector, NSInteger prefetchType, NSInteger reason, id params) {
    return NTIHomeFeedLoadMore(NTIOriginalHomeFeedObjCLoadMore, provider, selector, prefetchType, reason, params);
}

static BOOL NTIHomeFeedSwiftLoadMore(id provider, SEL selector, NSInteger prefetchType, NSInteger reason, id params) {
    return NTIHomeFeedLoadMore(NTIOriginalHomeFeedSwiftLoadMore, provider, selector, prefetchType, reason, params);
}

static void NTIHomeFeedWillDisappear(id model, SEL selector, UIViewController *feed) {
    NTIHomeFeedPaginationState *state = objc_getAssociatedObject(model, &NTIHomeFeedModelStateKey);
    if (NSThread.isMainThread && state.feed == feed) [state pause];
    ((void (*)(id, SEL, id))NTIOriginalHomeFeedDisappear)(model, selector, feed);
}

static void NTIHomeFeedLoadDidFinish(id model, BOOL success) {
    NTIHomeFeedPaginationState *state = objc_getAssociatedObject(model, &NTIHomeFeedModelStateKey);
    if (!state) return;
    // The adapter can still be applying the response when the model finishes.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (objc_getAssociatedObject(model, &NTIHomeFeedModelStateKey) != state) return;
        if (!state.requested) {
            if (success) [state resume];
            return;
        }
        [state pause];
        state.requested = NO;
        if (success) {
            state.completedWaits++;
            [state resume];
        } else {
            state.revealedPosts = state.revealLimitBeforeRequest;
        }
    });
}

static void NTIHomeFeedLegacyFinish(id model, SEL selector, id session, id context, id config, BOOL success) {
    ((void (*)(id, SEL, id, id, id, BOOL))NTIOriginalHomeFeedLegacyFinish)(model, selector, session, context, config, success);
    NTIHomeFeedLoadDidFinish(model, success);
}

static void NTIHomeFeedSwiftFinish(id model, SEL selector, id bridge, id config, id context, BOOL success) {
    ((void (*)(id, SEL, id, id, id, BOOL))NTIOriginalHomeFeedSwiftFinish)(model, selector, bridge, config, context, success);
    NTIHomeFeedLoadDidFinish(model, success);
}

static BOOL NTIInstallHomeFeedPagination(void) {
    if (NTIOriginalHomeFeedBind) return YES;
    NTIHomeFeedModelClass = NSClassFromString(@"IGMainFeedViewModel");
    NTIHomeFeedTabClass = NSClassFromString(@"IGTabBarController");
    NTIHomeFeedSpinnerClass = NSClassFromString(@"IGSpinnerLabelViewModel");
    NTIHomeFeedObjCClass = NSClassFromString(@"IGMainFeedViewController_objc");
    NTIHomeFeedSwiftClass = NSClassFromString(@"_TtC15IGMainFeedSwift30IGMainFeedViewController_swift");
    if (!NTIHomeFeedModelClass || !NTIHomeFeedTabClass || !NTIHomeFeedSpinnerClass ||
        (!NTIHomeFeedObjCClass && !NTIHomeFeedSwiftClass)) return NO;

    NTIHomeFeedProviderIvar = class_getInstanceVariable(NTIHomeFeedModelClass, "_feedDataProvider");
    const char *providerType = NTIHomeFeedProviderIvar ? ivar_getTypeEncoding(NTIHomeFeedProviderIvar) : NULL;
    const char *fetchArguments[] = {@encode(NSInteger)};
    if (!providerType || providerType[0] != '@' ||
        !NTIMethodMatches(class_getInstanceMethod(NTIHomeFeedModelClass, sel_registerName("fetchMoreItemsWithPrefetchType:")),
                          @encode(BOOL), 1, fetchArguments)) return NO;

    const NTIHook modelHooks[] = {
        {"bindToViewController:", (IMP)NTIHomeFeedBind, &NTIOriginalHomeFeedBind,
         @encode(void), 1, {@encode(id)}},
        {"viewControllerWillDisappear:", (IMP)NTIHomeFeedWillDisappear, &NTIOriginalHomeFeedDisappear,
         @encode(void), 1, {@encode(id)}},
        {"feedSession:didFinishLoadingWithResponseContext:forRequestConfig:success:",
         (IMP)NTIHomeFeedLegacyFinish, &NTIOriginalHomeFeedLegacyFinish, @encode(void), 4,
         {@encode(id), @encode(id), @encode(id), @encode(BOOL)}},
        {"dataBridge:didFinishLoadingWith:responseContext:success:",
         (IMP)NTIHomeFeedSwiftFinish, &NTIOriginalHomeFeedSwiftFinish, @encode(void), 4,
         {@encode(id), @encode(id), @encode(id), @encode(BOOL)}}
    };
    const NTIHook adapterHooks[] = {
        {"scrollViewDidScroll:", (IMP)NTIHomeFeedDidScroll, &NTIOriginalHomeFeedScroll,
         @encode(void), 1, {@encode(id)}},
        {"collectionView:willDisplayCell:forItemAtIndexPath:", (IMP)NTIHomeFeedWillDisplay, &NTIOriginalHomeFeedWillDisplay,
         @encode(void), 3, {@encode(id), @encode(id), @encode(id)}}
    };
    const NTIHook objcLoad = {"canLoadMoreWithPrefetchType:reason:extraParams:", (IMP)NTIHomeFeedObjCLoadMore,
                             &NTIOriginalHomeFeedObjCLoadMore, @encode(BOOL), 3,
                             {@encode(NSInteger), @encode(NSInteger), @encode(id)}};
    NTIHook swiftLoad = objcLoad;
    swiftLoad.replacement = (IMP)NTIHomeFeedSwiftLoadMore;
    swiftLoad.original = &NTIOriginalHomeFeedSwiftLoadMore;
    const NTIHook objcAppear = {"viewDidAppear:", (IMP)NTIHomeFeedObjCAppear, &NTIOriginalHomeFeedObjCAppear,
                               @encode(void), 1, {@encode(BOOL)}};
    const NTIHook swiftAppear = {"viewDidAppear:", (IMP)NTIHomeFeedSwiftAppear, &NTIOriginalHomeFeedSwiftAppear,
                                @encode(void), 1, {@encode(BOOL)}};
    const NTIHook objcDataSourceHooks[] = {
        {"objectsForListAdapter:", (IMP)NTIHomeFeedObjCObjects, &NTIOriginalHomeFeedObjCObjects, @encode(id), 1, {@encode(id)}},
        {"listAdapter:sectionControllerForObject:", (IMP)NTIHomeFeedObjCSection, &NTIOriginalHomeFeedObjCSection,
         @encode(id), 2, {@encode(id), @encode(id)}}
    };
    const NTIHook swiftDataSourceHooks[] = {
        {"objectsForListAdapter:", (IMP)NTIHomeFeedSwiftObjects, &NTIOriginalHomeFeedSwiftObjects, @encode(id), 1, {@encode(id)}},
        {"listAdapter:sectionControllerForObject:", (IMP)NTIHomeFeedSwiftSection, &NTIOriginalHomeFeedSwiftSection,
         @encode(id), 2, {@encode(id), @encode(id)}}
    };
    Class adapter = NSClassFromString(@"IGListAdapter");
    Class objcProvider = NSClassFromString(@"IGMainFeedDataController");
    Class swiftProvider = NSClassFromString(@"_TtC20IGMainFeedDataBridge20IGMainFeedDataBridge");
    BOOL objcSupported = NTIHooksMatch(objcProvider, &objcLoad, 1);
    BOOL swiftSupported = NTIHooksMatch(swiftProvider, &swiftLoad, 1);
    if ((!objcSupported && !swiftSupported) ||
        !NTIHooksMatch(NTIHomeFeedModelClass, modelHooks, sizeof(modelHooks) / sizeof(modelHooks[0])) ||
        !NTIHooksMatch(adapter, adapterHooks, sizeof(adapterHooks) / sizeof(adapterHooks[0]))) return NO;

    Class objcDataSource = NSClassFromString(@"IGMainFeedListAdapterDataSource");
    Class swiftDataSource = NSClassFromString(@"_TtC22IGMainFeedSwiftHelpers37IGMainFeedListAdapterDataSource_swift");
    BOOL objcDataSourceSupported = NTIHooksMatch(objcDataSource, objcDataSourceHooks, 2);
    BOOL swiftDataSourceSupported = NTIHooksMatch(swiftDataSource, swiftDataSourceHooks, 2);
    const char *updateArguments[] = {@encode(BOOL), @encode(void (^)(BOOL))};
    const char *dequeueArguments[] = {@encode(Class), @encode(id), @encode(NSInteger)};
    if ((objcDataSourceSupported || swiftDataSourceSupported) &&
        NTIMethodMatches(class_getInstanceMethod(adapter, sel_registerName("performUpdatesAnimated:completion:")),
                         @encode(void), 2, updateArguments) &&
        NTIMethodMatches(class_getInstanceMethod(adapter, sel_registerName("dequeueReusableCellOfClass:forSectionController:atIndex:")),
                         @encode(id), 3, dequeueArguments)) {
        NTIHomeFeedLoadingSectionClass = NTIHomeFeedRegisterLoadingSection();
    }
    if (NTIHomeFeedLoadingSectionClass) {
        NTIHomeFeedMediaClass = NSClassFromString(@"IGMedia");
        NTIHomeFeedPostItemClass = NSClassFromString(@"IGPostItem");
        Protocol *diffable = NSProtocolFromString(@"IGListDiffable");
        if (diffable) class_addProtocol(NTIHomeFeedLoadingItem.class, diffable);
        if (objcDataSourceSupported) NTIReplaceHooks(objcDataSource, objcDataSourceHooks, 2);
        if (swiftDataSourceSupported) NTIReplaceHooks(swiftDataSource, swiftDataSourceHooks, 2);
    }
    if (objcSupported) NTIReplaceHooks(objcProvider, &objcLoad, 1);
    if (swiftSupported) NTIReplaceHooks(swiftProvider, &swiftLoad, 1);
    NTIReplaceHooks(adapter, adapterHooks, 2);
    NTIReplaceHooks(NTIHomeFeedModelClass, modelHooks, 4);
    NTIInstallHooks(NTIHomeFeedObjCClass, &objcAppear, 1);
    NTIInstallHooks(NTIHomeFeedSwiftClass, &swiftAppear, 1);
    return YES;
}

@interface NTIHomeFeedPagination : NSObject
@end

@implementation NTIHomeFeedPagination
+ (void)load {
    if (!NTIIsInstagram(NSBundle.mainBundle.bundleIdentifier)) return;
    if (!NTIInstallHomeFeedPagination()) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NTIInstallHomeFeedPagination();
        });
    }
}
@end
