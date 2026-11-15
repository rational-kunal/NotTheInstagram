#import <UIKit/UIKit.h>
#import "../Runtime/RuntimeHooks.h"
@import FLEX;

// Keep the explorer out of ordinary use. A three-finger double tap opens it
// without replacing Instagram's window methods or cancelling its touches.
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
        NSLog(@"[NTI] FLEX activation v2 ready: double-tap with three fingers (attached windows=%lu)",
              (unsigned long)integration.installedWindows.count);
    });
}

- (void)installOnWindow:(UIWindow *)window {
    // Ignore keyboard, system overlays, and FLEX's own explorer window.
    if (window.hidden || window.windowLevel != UIWindowLevelNormal ||
        [self.installedWindows containsObject:window] ||
        [window isKindOfClass:NSClassFromString(@"FLEXWindow")]) return;

    UITapGestureRecognizer *gesture = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(openExplorer:)];
    gesture.numberOfTouchesRequired = 3;
    gesture.numberOfTapsRequired = 2;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    gesture.delegate = self;
    [window addGestureRecognizer:gesture];
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

- (void)openExplorer:(UITapGestureRecognizer *)gesture {
    UIWindow *window = gesture.view.window;
    if (gesture.state != UIGestureRecognizerStateRecognized || !window || window.hidden) return;
    UIWindowScene *scene = window.windowScene;
    if (scene) {
        if (scene.activationState != UISceneActivationStateForegroundActive) return;
        [FLEXManager.sharedManager showExplorerFromScene:scene];
    } else {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        [FLEXManager.sharedManager showExplorer];
    }
    NSLog(@"[NTI] FLEX open requested (scene=%d)", scene != nil);
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

@end
