#import <Foundation/Foundation.h>

/// Controls whether the opened reel is kept from advancing to another reel.
@interface NTIReelNavigation : NSObject

/// Saved in Instagram's standard user defaults; defaults to YES.
/// Changes take effect after Instagram is fully quit and relaunched.
/// A future settings screen can read and assign this property directly.
@property (class, nonatomic, getter=isEnabled) BOOL enabled;

@end
