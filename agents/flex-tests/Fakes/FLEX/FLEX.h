#import <UIKit/UIKit.h>
@interface FLEXManager : NSObject
@property (class, nonatomic, readonly) FLEXManager *sharedManager;
@property NSUInteger presentations;
@property (nonatomic, strong) UIWindowScene *lastScene;
- (void)showExplorer;
- (void)showExplorerFromScene:(UIWindowScene *)scene;
@end
