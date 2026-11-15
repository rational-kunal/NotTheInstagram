#import <UIKit/UIKit.h>

@interface NTIHomeFeedLoadingItem : NSObject
@property (nonatomic) BOOL requestsPage;
@end

@interface NTIHomeFeedLoadingCell : UICollectionViewCell
@end

Class NTIHomeFeedRegisterLoadingSection(void);
id NTIHomeFeedMakeLoadingSection(Class sectionClass, id adapter);
