#import "FLEXIntegration.h"
#import "../Runtime/RuntimeHooks.h"
@import FLEX;

static __weak UIView *NTIFLEXUsageLabel;

void NTISetFLEXUsageLabel(UIView *label) {
    NTIFLEXUsageLabel = label;
}

// Keep the explorer out of ordinary use and leave Instagram's touches intact.
@interface NTIFLEXIntegration : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, strong) NSHashTable<UIWindow *> *installedWindows;
@end

@implementation NTIFLEXIntegration

+ (void)load {
    if (!NTIIsInstagram(NSBundle.mainBundle.bundleIdentifier)) return;

    // UIKit work must wait until after image loading and run on the main queue.
    dispatch_async(dispatch_get_main_queue(), ^{
        static NTIFLEXIntegration *integration;
        integration = [self new];
        integration.installedWindows = NSHashTable.weakObjectsHashTable;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:integration selector:@selector(windowBecameVisible:)
                       name:UIWindowDidBecomeVisibleNotification object:nil];
        [center addObserver:integration selector:@selector(refreshWindows:)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:integration selector:@selector(refreshWindows:)
                       name:UISceneDidActivateNotification object:nil];
        [integration refreshWindows:nil];
        NSLog(@"[NTI] FLEX activation v3 ready: double-tap with three fingers or hold the usage label (attached windows=%lu)",
              (unsigned long)integration.installedWindows.count);
    });
}

- (void)installOnWindow:(UIWindow *)window {
    // Ignore keyboard, system overlays, and FLEX's own explorer window.
    if (window.hidden || window.windowLevel != UIWindowLevelNormal ||
        [self.installedWindows containsObject:window] ||
        [window isKindOfClass:NSClassFromString(@"FLEXWindow")]) return;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(openFromTap:)];
    tap.numberOfTouchesRequired = 3;
    tap.numberOfTapsRequired = 2;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(openFromHold:)];
    hold.minimumPressDuration = 1;
    for (UIGestureRecognizer *gesture in @[tap, hold]) {
        gesture.cancelsTouchesInView = NO;
        gesture.delaysTouchesBegan = NO;
        gesture.delaysTouchesEnded = NO;
        gesture.delegate = self;
        [window addGestureRecognizer:gesture];
    }
    [self.installedWindows addObject:window];
    NSLog(@"[NTI] FLEX opener attached (scene=%d)", window.windowScene != nil);
}

- (void)refreshWindows:(NSNotification *)notification {
    if ([notification.object isKindOfClass:UIWindowScene.class]) {
        for (UIWindow *window in ((UIWindowScene *)notification.object).windows) [self installOnWindow:window];
        return;
    }
    // Instagram still uses the pre-scene application lifecycle. Its windows
    // are absent from connectedScenes and legitimately have no windowScene.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        [self installOnWindow:window];
    }
#pragma clang diagnostic pop
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            [self installOnWindow:window];
        }
    }
}

- (void)windowBecameVisible:(NSNotification *)notification {
    if ([notification.object isKindOfClass:UIWindow.class]) {
        [self installOnWindow:notification.object];
    }
}

- (void)openFromTap:(UITapGestureRecognizer *)tap {
    if (tap.state == UIGestureRecognizerStateRecognized) {
        [self openExplorerInWindow:(UIWindow *)tap.view trigger:@"three-finger tap"];
    }
}

- (void)openFromHold:(UILongPressGestureRecognizer *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) {
        [self openExplorerInWindow:(UIWindow *)hold.view trigger:@"usage label"];
    }
}

- (void)openExplorerInWindow:(UIWindow *)window trigger:(NSString *)trigger {
    if (!window || window.hidden) return;
    UIWindowScene *scene = window.windowScene;
    NSLog(@"[NTI] FLEX gesture recognized (%@, scene=%d)", trigger, scene != nil);
    if (scene) {
        if (scene.activationState != UISceneActivationStateForegroundActive) return;
        [FLEXManager.sharedManager showExplorerFromScene:scene];
    } else {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        [FLEXManager.sharedManager showExplorer];
    }
    NSLog(@"[NTI] FLEX open requested (scene=%d)", scene != nil);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (![gesture isKindOfClass:UILongPressGestureRecognizer.class]) return YES;
    UIView *label = NTIFLEXUsageLabel;
    return label.window && label.window == gesture.view && !label.hidden &&
        CGRectContainsPoint(label.bounds, [touch locationInView:label]);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end
