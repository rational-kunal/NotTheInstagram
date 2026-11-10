#import <UIKit/UIKit.h>

// Loaded automatically by the dynamic linker when the injected framework is loaded.
@interface NTIHelloWorld : NSObject
@end

@implementation NTIHelloWorld

+ (void)load {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(appDidBecomeActive:)
                                                     name:UIApplicationDidBecomeActiveNotification
                                                   object:nil];
        if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
            [self showGreetingWhenReady:0];
        }
    });
}

+ (void)appDidBecomeActive:(NSNotification *)notification {
    [self showGreetingWhenReady:0];
}

+ (void)showGreetingWhenReady:(NSUInteger)attempt {
    static BOOL shown = NO;
    if (shown || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    if (!controller || !controller.viewIfLoaded.window || controller.isBeingDismissed) {
        if (attempt < 20) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self showGreetingWhenReady:attempt + 1];
            });
        }
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Hello, world!"
                                                                   message:@"NotTheInstagram framework loaded."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    shown = YES;
    [controller presentViewController:alert animated:YES completion:nil];
}
@end
