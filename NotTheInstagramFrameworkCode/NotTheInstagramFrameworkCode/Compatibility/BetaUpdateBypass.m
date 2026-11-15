#import <UIKit/UIKit.h>
#import "../Runtime/RuntimeHooks.h"

typedef void (*NTIPresentImplementation)(id, SEL, UIViewController *, BOOL, void (^)(void));
static IMP NTIOriginalPresent;

static void NTIPresentSkippingBetaUpdate(id presenter, SEL selector,
                                        UIViewController *controller, BOOL animated,
                                        void (^completion)(void)) {
    // UIKit presentations run on the main thread. Cache successful lookup,
    // but retry a missing class to tolerate Swift registration order.
    static Class nudge;
    if (!nudge) {
        nudge = objc_lookUpClass("_TtC29IGCoreRootTestFlightNagPlugin35TestFlightUpdateNudgeViewController");
    }
    if (nudge && [controller isKindOfClass:nudge]) {
        if (completion) dispatch_async(dispatch_get_main_queue(), completion);
        return;
    }
    ((NTIPresentImplementation)NTIOriginalPresent)(presenter, selector, controller, animated, completion);
}

@interface NTIBetaUpdateBypass : NSObject
@end
@implementation NTIBetaUpdateBypass
+ (void)load {
    if (!NTIIsInstagram(NSBundle.mainBundle.bundleIdentifier)) return;
    const NTIHook hook = {"presentViewController:animated:completion:", (IMP)NTIPresentSkippingBetaUpdate,
        &NTIOriginalPresent, @encode(void), 3, {@encode(id), @encode(BOOL), "@?"}};
    NTIInstallHooks(UIViewController.class, &hook, 1);
}
@end
