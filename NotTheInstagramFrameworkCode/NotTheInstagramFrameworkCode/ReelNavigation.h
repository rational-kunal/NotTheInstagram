#import <Foundation/Foundation.h>

/// Controls Reels tab blocking, its session bypass and delayed playback.
/// Viewers opened elsewhere keep navigation restricted to the selected reel.
@interface NTIReelNavigation : NSObject

/// Saved in Instagram's standard user defaults; defaults to YES.
/// Changes take effect after Instagram is fully quit and relaunched.
/// A future settings screen can read and assign this property directly.
/// The two-minute bypass is temporary and never changes this saved preference.
@property (class, nonatomic, getter=isEnabled) BOOL enabled;

@end
