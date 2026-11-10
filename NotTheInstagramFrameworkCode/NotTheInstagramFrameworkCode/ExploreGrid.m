#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP NTIOriginalGridWillLayout;
static Class NTIExploreClass;
static Class NTIListClass;
static char NTIPlaceholderKey;

static BOOL NTIIsExploreTab(UIViewController *controller) {
    for (UIViewController *parent = controller.parentViewController; parent; parent = parent.parentViewController) {
        if ([parent isKindOfClass:NTIExploreClass]) return YES;
    }
    return NO;
}

static void NTIGridWillLayout(UIViewController *controller, SEL selector) {
    ((void (*)(id, SEL))NTIOriginalGridWillLayout)(controller, selector);
    // The same grid controller may be used elsewhere in Instagram.
    if (!NTIIsExploreTab(controller)) return;

    // The search bar is outside this grid. Hide only its direct collection view.
    UIView *root = controller.view;
    UIView *list = nil;
    for (UIView *child in root.subviews) {
        if ([child isKindOfClass:NTIListClass]) { list = child; break; }
    }
    if (!list) return;

    UIView *placeholder = objc_getAssociatedObject(controller, &NTIPlaceholderKey);
    if (!placeholder || placeholder.superview != root) {
        [placeholder removeFromSuperview];
        placeholder = [[UIView alloc] initWithFrame:list.frame];
        placeholder.backgroundColor = UIColor.systemBackgroundColor;
        placeholder.userInteractionEnabled = NO;
        placeholder.accessibilityElementsHidden = YES;
        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"magnifyingglass"]];
        icon.tintColor = UIColor.secondaryLabelColor;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.frame = CGRectMake(0, 0, 52, 52);
        icon.center = CGPointMake(CGRectGetMidX(placeholder.bounds), CGRectGetMidY(placeholder.bounds));
        icon.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [placeholder addSubview:icon];
        [root insertSubview:placeholder aboveSubview:list];
        objc_setAssociatedObject(controller, &NTIPlaceholderKey, placeholder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    placeholder.frame = list.frame;
    list.hidden = YES;
}

@interface NTIExploreGrid : NSObject
@end
@implementation NTIExploreGrid
+ (void)load {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (![identifier isEqualToString:@"com.burbn.instagram"] &&
        ![identifier hasPrefix:@"com.burbn.instagram."]) return;
    Class grid = NSClassFromString(@"IGExploreGridViewController");
    NTIExploreClass = NSClassFromString(@"IGExploreViewController");
    NTIListClass = NSClassFromString(@"IGListCollectionView");
    Method method = grid ? class_getInstanceMethod(grid, @selector(viewWillLayoutSubviews)) : NULL;
    if (!method || !NTIExploreClass || !NTIListClass) return;
    // Preserve Instagram's layout before updating the placeholder.
    NTIOriginalGridWillLayout = method_getImplementation(method);
    class_replaceMethod(grid, @selector(viewWillLayoutSubviews), (IMP)NTIGridWillLayout, method_getTypeEncoding(method));
}
@end
