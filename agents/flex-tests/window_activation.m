#import <UIKit/UIKit.h>
@import FLEX;
#import "../../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/FLEXIntegration.m"
@implementation UIView
@end
@implementation UIScene
@end
@implementation UIWindowScene
@end
@implementation UIGestureRecognizer
- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super init])) { _target = target; _action = action; }
    return self;
}
- (void)fire {
    self.state = UIGestureRecognizerStateRecognized;
    ((void (*)(id, SEL, id))[self.target methodForSelector:self.action])(self.target, self.action, self);
}
@end
@implementation UITapGestureRecognizer
@end
@implementation UIWindow
- (instancetype)init {
    if ((self = [super init])) {
        self.window = self;
        _gestureRecognizers = NSMutableArray.new;
    }
    return self;
}
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture {
    gesture.view = self;
    [self.gestureRecognizers addObject:gesture];
}
@end
@implementation UIApplication
+ (instancetype)sharedApplication {
    static UIApplication *app;
    if (!app) { app = self.new; app.connectedScenes = NSSet.set; app.windows = @[]; }
    return app;
}
@end
@implementation FLEXManager
+ (instancetype)sharedManager { static FLEXManager *manager; if (!manager) manager = self.new; return manager; }
- (void)showExplorer { self.presentations++; self.lastScene = nil; }
- (void)showExplorerFromScene:(UIWindowScene *)scene { self.presentations++; self.lastScene = scene; }
@end
static int failures;
static void check(BOOL condition, NSString *message) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", message.UTF8String);
    if (!condition) failures++;
}
int main(void) { @autoreleasepool {
    UIApplication *app = UIApplication.sharedApplication;
    FLEXManager *manager = FLEXManager.sharedManager;
    NTIFLEXIntegration *integration = NTIFLEXIntegration.new;
    integration.installedWindows = NSHashTable.weakObjectsHashTable;
    // The extracted Instagram Info.plist has no UIApplicationSceneManifest.
    // Replay its legacy lifecycle at the UIKit boundary; use production methods.
    UIWindow *legacy = UIWindow.new;
    app.windows = @[legacy];
    [integration refreshWindows:nil];
    check(legacy.gestureRecognizers.count == 1, @"existing legacy window receives opener");
    [legacy.gestureRecognizers.firstObject fire];
    check(manager.presentations == 1, @"recognized gesture opens FLEX without a scene");
    UIWindow *replacement = UIWindow.new;
    [integration windowBecameVisible:[NSNotification notificationWithName:UIWindowDidBecomeVisibleNotification object:replacement]];
    check(replacement.gestureRecognizers.count == 1, @"replacement legacy window receives opener");
    [replacement.gestureRecognizers.firstObject fire];
    check(manager.presentations == 2, @"replacement window can reopen FLEX");
    [integration refreshWindows:nil];
    check(legacy.gestureRecognizers.count == 1, @"activation does not duplicate recognizers");
    UIWindowScene *scene = UIWindowScene.new;
    UIWindow *modern = UIWindow.new;
    modern.windowScene = scene;
    scene.windows = @[modern];
    app.connectedScenes = [NSSet setWithObject:scene];
    [integration refreshWindows:nil];
    NSUInteger before = manager.presentations;
    [modern.gestureRecognizers.firstObject fire];
    check(manager.presentations == before + 1 && manager.lastScene == scene, @"scene window opens FLEX in its own scene");
    scene.activationState = UISceneActivationStateBackground;
    before = manager.presentations;
    [modern.gestureRecognizers.firstObject fire];
    check(manager.presentations == before, @"background scene cannot open FLEX");
    app.applicationState = UIApplicationStateBackground;
    before = manager.presentations;
    [legacy.gestureRecognizers.firstObject fire];
    check(manager.presentations == before, @"background legacy app cannot open FLEX");
    return failures ? 1 : 0;
} }
