#import <UIKit/UIKit.h>
#import "RuntimeHooks.h"

static IMP NTIOriginalGridWillLayout;
static Class NTIExploreClass;
static Class NTIListClass;
static char NTIPlaceholderKey;

@interface NTIExplorePlaceholder : UIImageView
@property (nonatomic, weak) UIView *list;
@property (nonatomic) BOOL originallyHidden;
@end
@implementation NTIExplorePlaceholder
@end

static BOOL NTIIsExploreTab(UIViewController *controller) {
    for (UIViewController *parent = controller.parentViewController; parent; parent = parent.parentViewController) {
        if ([parent isKindOfClass:NTIExploreClass]) return YES;
    }
    return NO;
}

static void NTIGridWillLayout(UIViewController *controller, SEL selector) {
    ((void (*)(id, SEL))NTIOriginalGridWillLayout)(controller, selector);

    // The search bar is outside this grid. Find only its direct collection view.
    UIView *root = controller.viewIfLoaded;
    UIView *list = nil;
    if (NTIIsExploreTab(controller)) {
        for (UIView *child in root.subviews) {
            if ([child isKindOfClass:NTIListClass]) { list = child; break; }
        }
    }
    NTIExplorePlaceholder *placeholder = objc_getAssociatedObject(controller, &NTIPlaceholderKey);
    if (placeholder && (!list || placeholder.list != list || placeholder.superview != root)) {
        placeholder.list.hidden = placeholder.originallyHidden;
        [placeholder removeFromSuperview];
        objc_setAssociatedObject(controller, &NTIPlaceholderKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        placeholder = nil;
    }
    if (!list) return;

    if (!placeholder) {
        UIImageSymbolConfiguration *size = [UIImageSymbolConfiguration configurationWithPointSize:44];
        placeholder = [[NTIExplorePlaceholder alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass" withConfiguration:size]];
        placeholder.list = list;
        placeholder.originallyHidden = list.hidden;
        placeholder.backgroundColor = UIColor.systemBackgroundColor;
        placeholder.tintColor = UIColor.secondaryLabelColor;
        placeholder.contentMode = UIViewContentModeCenter;
        placeholder.userInteractionEnabled = NO;
        placeholder.accessibilityElementsHidden = YES;
        [root insertSubview:placeholder aboveSubview:list];
        objc_setAssociatedObject(controller, &NTIPlaceholderKey, placeholder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (!CGRectEqualToRect(placeholder.frame, list.frame)) placeholder.frame = list.frame;
    if (!list.hidden) list.hidden = YES;
}

@interface NTIExploreGrid : NSObject
@end
@implementation NTIExploreGrid
+ (void)load {
    if (!NTIIsInstagram(NSBundle.mainBundle.bundleIdentifier)) return;
    Class grid = NSClassFromString(@"IGExploreGridViewController");
    NTIExploreClass = NSClassFromString(@"IGExploreViewController");
    NTIListClass = NSClassFromString(@"IGListCollectionView");
    if (!NTIExploreClass || !NTIListClass) return;
    const NTIHook hook = {"viewWillLayoutSubviews", (IMP)NTIGridWillLayout, &NTIOriginalGridWillLayout, @encode(void), 0, {NULL}};
    NTIInstallHooks(grid, &hook, 1);
}
@end
