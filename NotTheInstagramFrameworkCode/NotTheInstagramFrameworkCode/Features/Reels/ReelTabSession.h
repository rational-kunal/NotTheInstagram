#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const NTIReelTabSessionDidChangeNotification;

/// Main-thread state for one visit to the actual Reels tab.
/// A session survives presentations inside that tab; leaving the tab or the
/// foreground ends its bypass. It never grants access automatically.
@interface NTIReelTabSession : NSObject
+ (nullable instancetype)sessionForController:(nullable UIViewController *)controller;
+ (BOOL)installHooks;
@property (nonatomic, readonly, getter=isBypassed) BOOL bypassed;
@property (nonatomic, readonly, getter=isActive) BOOL active;
/// Foreground root visibility, separate from bypass lifetime within a tab.
@property (nonatomic, readonly, getter=isPlaybackVisible) BOOL playbackVisible;
/// Grows slightly after each newly started reel; resets when the session ends.
@property (nonatomic, readonly) NSTimeInterval playbackDelay;
- (void)recordPlaybackWithIdentity:(nullable NSString *)identity player:(UIView *)player;
@end

NS_ASSUME_NONNULL_END
