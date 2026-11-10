#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <string.h>

typedef void (*NTIPresentImplementation)(id, SEL, UIViewController *, BOOL, void (^)(void));
static NTIPresentImplementation NTIOriginalPresent;

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
    NTIOriginalPresent(presenter, selector, controller, animated, completion);
}

static void NTIInstallBetaUpdateBypass(NSString *identifier) {
    if (![identifier isEqualToString:@"com.burbn.instagram"] &&
        ![identifier hasPrefix:@"com.burbn.instagram."]) return;
    if (NTIOriginalPresent) return;

    SEL selector = @selector(presentViewController:animated:completion:);
    Method method = class_getInstanceMethod(UIViewController.class, selector);
    if (!method || method_getNumberOfArguments(method) != 5) return;
    // Leave a changed UIKit ABI alone instead of installing an incompatible IMP.
    char returnType[16], controllerType[16], animatedType[16], completionType[16];
    method_getReturnType(method, returnType, sizeof(returnType));
    method_getArgumentType(method, 2, controllerType, sizeof(controllerType));
    method_getArgumentType(method, 3, animatedType, sizeof(animatedType));
    method_getArgumentType(method, 4, completionType, sizeof(completionType));
    if (strcmp(returnType, @encode(void)) || strcmp(controllerType, @encode(id)) ||
        strcmp(animatedType, @encode(BOOL)) || strcmp(completionType, "@?")) return;

    NTIOriginalPresent = (NTIPresentImplementation)method_getImplementation(method);
    class_replaceMethod(UIViewController.class, selector, (IMP)NTIPresentSkippingBetaUpdate,
                        method_getTypeEncoding(method));
}

@interface NTIBetaUpdateBypass : NSObject
@end
@implementation NTIBetaUpdateBypass
+ (void)load {
    NTIInstallBetaUpdateBypass(NSBundle.mainBundle.bundleIdentifier);
}
@end
