#import "HomeFeedLoadingSection.h"
#import "../../Runtime/RuntimeHooks.h"

@implementation NTIHomeFeedLoadingItem
- (id)diffIdentifier { return self; }
- (BOOL)isEqualToDiffableObject:(id)object { return self == object; }
@end

@implementation NTIHomeFeedLoadingCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = UIColor.secondaryLabelColor;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:self.contentView.centerXAnchor],
        [spinner.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor]
    ]];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = NSLocalizedString(@"Loading more posts", nil);
    [spinner startAnimating];
    return self;
}
@end

static char NTIHomeFeedSectionAdapterKey;

@interface NTIHomeFeedSectionAdapter : NSObject
@property (nonatomic, weak) id object;
@end

@implementation NTIHomeFeedSectionAdapter
@end

id NTIHomeFeedMakeLoadingSection(Class sectionClass, id adapter) {
    id section = [sectionClass new];
    // The adapter owns the section, so the reference back must be weak.
    NTIHomeFeedSectionAdapter *reference = [NTIHomeFeedSectionAdapter new];
    reference.object = adapter;
    objc_setAssociatedObject(section, &NTIHomeFeedSectionAdapterKey, reference, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return section;
}

static NSInteger NTIHomeFeedLoadingItemCount(id section, SEL selector) {
    return 1;
}

static CGSize NTIHomeFeedLoadingItemSize(id section, SEL selector, NSInteger index) {
    NTIHomeFeedSectionAdapter *reference = objc_getAssociatedObject(section, &NTIHomeFeedSectionAdapterKey);
    UICollectionView *collection = NTIObjectValue(reference.object, @selector(collectionView));
    if (!collection) return CGSizeMake(1, 80);
    CGRect viewport = UIEdgeInsetsInsetRect(collection.bounds, collection.adjustedContentInset);
    return CGSizeMake(MAX(1, CGRectGetWidth(viewport)), 80);
}

static id NTIHomeFeedLoadingCellAtIndex(id section, SEL selector, NSInteger index) {
    NTIHomeFeedSectionAdapter *reference = objc_getAssociatedObject(section, &NTIHomeFeedSectionAdapterKey);
    return ((id (*)(id, SEL, Class, id, NSInteger))objc_msgSend)(reference.object,
        sel_registerName("dequeueReusableCellOfClass:forSectionController:atIndex:"), NTIHomeFeedLoadingCell.class, section, index);
}

Class NTIHomeFeedRegisterLoadingSection(void) {
    Class base = NSClassFromString(@"IGListSectionController");
    const NTIHook methods[] = {
        {"numberOfItems", (IMP)NTIHomeFeedLoadingItemCount, NULL, @encode(NSInteger), 0, {}},
        {"sizeForItemAtIndex:", (IMP)NTIHomeFeedLoadingItemSize, NULL, @encode(CGSize), 1, {@encode(NSInteger)}},
        {"cellForItemAtIndex:", (IMP)NTIHomeFeedLoadingCellAtIndex, NULL, @encode(id), 1, {@encode(NSInteger)}}
    };
    if (!NTIHooksMatch(base, methods, sizeof(methods) / sizeof(methods[0]))) return Nil;
    Class section = objc_allocateClassPair(base, "NTIHomeFeedLoadingSectionController", 0);
    if (!section) return Nil;
    NTIReplaceHooks(section, methods, sizeof(methods) / sizeof(methods[0]));
    objc_registerClassPair(section);
    return section;
}
