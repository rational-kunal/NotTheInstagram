#import <UIKit/UIKit.h>

/// Installs only validated playback hooks; no timers or scroll gestures are added.
BOOL NTIInstallReelPlaybackGate(void);
/// Reconciles already playing/prepared views after containment or session changes.
void NTIRefreshReelPlayback(UIViewController *controller);
