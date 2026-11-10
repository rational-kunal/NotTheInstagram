#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
typedef NSInteger UIGestureRecognizerState;
enum { UIGestureRecognizerStateRecognized = 3 };
typedef NSInteger UISceneActivationState;
enum { UISceneActivationStateForegroundActive = 0, UISceneActivationStateBackground = 2 };
typedef NSInteger UIApplicationState;
enum { UIApplicationStateActive = 0, UIApplicationStateBackground = 2 };
static const double UIWindowLevelNormal = 0;
#define UIWindowDidBecomeVisibleNotification @"WindowVisible"
#define UIApplicationDidBecomeActiveNotification @"ApplicationActive"
#define UISceneDidActivateNotification @"SceneActive"
@class UIWindow, UIWindowScene, UIGestureRecognizer;
@protocol UIGestureRecognizerDelegate <NSObject>
@end
@interface UIView : NSObject
@property (nonatomic, weak) UIWindow *window;
@end
@interface UIScene : NSObject
@property UISceneActivationState activationState;
@end
@interface UIWindowScene : UIScene
@property (nonatomic, strong) NSArray<UIWindow *> *windows;
@end
@interface UIGestureRecognizer : NSObject
@property UIGestureRecognizerState state;
@property (nonatomic, weak) UIView *view;
@property BOOL cancelsTouchesInView;
@property BOOL delaysTouchesBegan;
@property BOOL delaysTouchesEnded;
@property (nonatomic, weak) id<UIGestureRecognizerDelegate> delegate;
@property (nonatomic, weak) id target;
@property SEL action;
- (instancetype)initWithTarget:(id)target action:(SEL)action;
- (void)fire;
@end
@interface UITapGestureRecognizer : UIGestureRecognizer
@property NSUInteger numberOfTouchesRequired;
@property NSUInteger numberOfTapsRequired;
@end
@interface UIWindow : UIView
@property BOOL hidden;
@property double windowLevel;
@property (nonatomic, strong) UIWindowScene *windowScene;
@property (nonatomic, strong) NSMutableArray<UIGestureRecognizer *> *gestureRecognizers;
- (void)addGestureRecognizer:(UIGestureRecognizer *)gesture;
@end
@interface UIApplication : NSObject
@property (class, nonatomic, readonly) UIApplication *sharedApplication;
@property (nonatomic, strong) NSSet<UIScene *> *connectedScenes;
@property (nonatomic, strong) NSArray<UIWindow *> *windows;
@property UIApplicationState applicationState;
@end
