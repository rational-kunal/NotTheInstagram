# Reels tab block and session bypass — 2026-11-10

## Requested behavior and decisions

This revision replaces the blanket reel navigation block with a scoped policy:

- Opening the actual Reels tab shows a pause symbol and an opaque screen headed
  “Reels are paused”. The main tab bar remains available so the user can leave.
- Keeping that screen visible and Instagram active for 120 continuous seconds
  reveals “Continue for this session”. Waiting alone never grants access.
- Tapping that button permits native paging in that Reels tab visit. The bypass
  is held only in memory. Leaving the tab or resigning active ends it and resets
  the wait. The user explicitly selected this reset behavior.
- In-tab comments, profiles and presentations interrupt an unfinished wait but
  preserve an already granted bypass while the same tab remains selected.
- Each new reel's playback is held behind a system blur with a pause icon. The
  delay starts at three seconds and grows by half a second after each reel starts
  playing in the same session. No remaining-time text is shown. Playback start itself is deferred, rather
  than merely covering moving video and allowing its audio to play.
- A reel opened from a post, message or another non-tab viewer retains the old
  restriction: play the selected reel, prevent paging and automatic chaining.
  It does not acquire the two-minute tab block or playback delay.

The user clarified the auto-scroll wording with:

> dont scroll automatically if its being alredy done then fine

Interpretation communicated to the user: do not create forced auto-scroll. Allow
swiping after bypass; preserve an already enabled native timer only when its
owner can be resolved to that bypassed tab feed. Unknown engine ownership remains
restricted. This implementation never calls `setUserEnabled:` or changes
Instagram's saved auto-scroll preference.

## Code responsibilities

All paths below are relative to the project root.

| File | Responsibility |
| --- | --- |
| `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelNavigation.h` | Existing saved master switch. |
| `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelNavigation.m` | Per-feed native flag requests, backing-state enforcement, scoped collection paging, engine ownership and cancellation. |
| `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Runtime/RuntimeHooks.h` | Internal ABI checks and safe class-local method replacements. |
| `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelTabSession.h` / `.m` | Root-tab identity, continuous foreground wait, consent button, in-memory bypass, blocker and accessibility restoration. |
| `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelPlaybackGate.h` / `.m` | Deferred play requests, per-media identity, weak ownership, blur and cancellation on native pause/stop/reuse or session changes. |

`NTIReelNavigation.enabled` remains the persistent master switch, default YES.
It is read at launch; fully quit and relaunch Instagram after changing it.
NO skips all reel hooks on a fresh launch. The bypass button never writes this
preference. Future settings UI should call this property, not write Instagram's
private flags. The current timing policy is centralized in `ReelTabSession.m`: 
`NTIReelBypassWait` (120 seconds), `NTIReelInitialPlaybackDelay` (3 seconds) and
`NTIReelPlaybackDelayIncrement` (0.5 seconds).

## State and lifecycle

Only a root in the selected branch can own an `NTIReelTabSession`, and
Instagram's `isOnDiscoverVideo` must identify that branch as Reels. A shared viewer used by a post or message is not enough to
qualify. The session starts inactive, becomes active after the confirmed root
appears and the selected surface is captured, then either waits or holds a
bypass. See the entry-point regression notes below. Matching the selected surface uses its actual object identity /
`isEqual:` value, never a hard-coded tab index, icon position or localized title.
Preloading the root while Home is selected cannot capture Home as a Reels visit:
the selected surface is captured in `viewDidAppear:`, not `viewDidLoad`.

The canonical tab-selection setter ends matching sessions **before** the host
switches to a different surface. It marks them invisible first, preventing
layout callbacks during transition from reactivating the old session. Root
`viewWillDisappear:` stops the wait and playback delay; it does not by itself
revoke an existing bypass, since native comments/profile presentation can use
the same lifecycle event. Foreground notifications have a separate latch, so a
`willResignActive` notification cannot immediately restart the wait merely
because `UIApplication.applicationState` has not updated yet.

The wait uses monotonic `systemUptime`, rather than wall-clock dates or counting
timer firings. A delayed run loop cannot reveal the button before the full
120 seconds. The action rechecks eligibility, selected tab, visibility and
elapsed time; hiding the button is not the only enforcement. Timers use common
run-loop modes and weak captures. The root blocker is brought above native
children after layout and adapts to a replaced root view.

Session state changes post `NTIReelTabSessionDidChangeNotification` with the
session as sender. Navigation re-applies policy to weakly tracked feeds;
playback rechecks weakly tracked requests. A session lookup returns nil until
both root and selection hooks have installed successfully. If new compatibility
checks fail, retain the older navigation restriction without silently creating
an unusable invisible playback block.

## Preserving host state

The old implementation forced every controller to disabled advancement, disabled
auto-advance and disabled collection scrolling. Conditional getter changes alone
would leave its stored fields and collection inconsistent after bypass.

The revised code records native setter requests separately from enforced values.
Policy refresh uses original setters to update backing fields; it does not feed
its own forced values back into the remembered native requests. On bypass,
native desired values are restored. Collection scrolling is restored at the
restriction-to-allowed transition and when the host replaces the collection,
then native allowed-mode layout rules remain in control. Other viewers stay
restricted even while the root Reels tab holds a bypass.

The native timer engine's `feedDelegate` accessor is ABI-checked. It must resolve
to a real `IGSundialFeedViewController`, directly or through a responder chain,
whose own session permits navigation. Merely having *some* allowed tab is not
enough. Already observed engines are tracked weakly; session closure calls the
validated `invalidateTimer` method for restricted engines. Native preference
and countdown methods are forwarded only for a permitted owner. Block callback
signatures are not guessed or wrapped.

## Playback gate

The generic video view and both legacy/modern Sundial playback wrappers are
hooked. Each play/pause/stop/reuse group is ABI-checked before installation; all
three known paths must be compatible for the new tab feature to install. Every
playback hook still forwards non-tab playback to its original implementation.

Requests hold players and owner feeds weakly. They retain the original native
play reason, media representation identity where available, and monotonic
deadline. A repeated request for the same released media resumes normally.
Reusing a view, changing representation identity, moving it to another known
feed, host pause/stop, invisibility, presentation, backgrounding or session
closure cancels an outstanding delay. No delayed block captures a recycled cell
strongly. Returning to the tab can only schedule a fresh eligible request.

At release, the saved original start implementation runs once. A scoped
synchronous release context prevents legacy/modern/generic nested wrappers from
each adding three more seconds to the same playback operation. Timer callbacks
reconcile current state before releasing; they do not blindly start a saved
player after a fixed dispatch delay. Invisible/prefetched views cannot start a
delay solely because the app selected the Reels tab.

When an already forwarded player becomes blocked, the validated host pause
method is called. Its reason value is reused from the recorded start request;
the full private reason enum and pause-specific semantic mapping remain unknown.
This needs a device check. The implementation never invents a numeric enum case
or changes global audio-session behavior. Unexpected background-thread start
calls are forwarded untouched to avoid traversing UIKit off-main; this is an
explicit coverage limitation, not evidence that those calls cannot occur.

## UI and accessibility

The blocker uses semantic system background/label colors, an SF Symbol,
Dynamic Type and a scrollable stack within safe areas. The explicit continue
button is at least 48 points tall. It appears only when eligible and announces
its availability once. The block screen retains its title, explanation and pause
symbol, but exposes no countdown or wait duration. Main tab
navigation is outside the blocked root view. Existing accessibility-hidden
values of native root siblings are recorded weakly, hidden while blocked, then
restored after bypass; the framework does not globally trap VoiceOver in the
root and prevent exit through the main tabs.

The inter-reel cover uses the system material blur and a pause-circle SF Symbol,
with the nonnumeric accessibility label “Playback paused”. Reduce
Transparency uses an opaque system background. There is no decorative countdown
animation, so Reduce Motion does not need a separate animation path.

## Static evidence, scope and unknowns

Target: Instagram 455.0.0's original extracted ARM64 executable. Its previously
recorded SHA-256 remains
`597efa50a6ed24a023f5a208a5b72dddad520e0311e29db6e27ddabb1e5bda40`.
See `playback-evidence.md` for exact playback declarations and coordinator call
sites, and `README.md` for the earlier successful restriction and flag evidence.

The following exact declarations came from original `class_ro_t` and relative
`method_list_t` metadata; they are static observations, not runtime tracing:

| Runtime class / selector | ABI | Implementation |
| --- | --- | --- |
| `_TtC13IGSundialTabs30IGSundialRootTabViewController` `viewDidLoad` | `v16@0:8` | `0x10d375c28` |
| Same `viewWillAppear:` | `v20@0:8B16` | `0x10d367cec` |
| Same `viewDidAppear:` | `v20@0:8B16` | `0x109d70bfc` |
| Same `viewWillDisappear:` | `v20@0:8B16` | `0x10cccc04c` |
| Same `viewDidLayoutSubviews` | `v16@0:8` | `0x10d459680` |
| `IGTabBarController` `selectedTabBarSurface` | `@16@0:8` | `0x1062ca0a4` |
| Same `_setSelectedTabBarSurface:isTabBarAction:animated:navigationAction:skipMainFeedFetch:animateIndicator:` | `v48@0:8@16B24B28Q32B40B44` | `0x1062eeb74` |
| Auto-scroll engine `feedDelegate` | `@16@0:8` | `0x109469100` |
| Auto-scroll engine `invalidateTimer` | `v16@0:8` | `0x10b2cb888` |

The existing `Instagram.hop` Hopper Demo window was used. No second Hopper,
import or executable patch was created. Through its Python console, the tab
root's `viewDidLoad` was analyzed and decompiled. It calls super, sets up its
lanes, adds/raises a native subview, sets a selected inner tab and applies a
background override. This supports overlaying that root after its native setup,
but does not itself prove live parent containment on every Instagram account.
One recursive procedure-creation call exceeded the client deadline; it later
completed in the same document. It was not restarted as a fresh import. Broad
background analysis was still running; unavailable playback procedures were not
claimed to have complete Hopper decompilation.

REA `binary_session` reported no bound target. Its Hopper route opens an owned
session rather than attaching this document, so `open_binary` was deliberately
not used. These are Hopper-console, original-metadata and focused assembly
observations; no fabricated REA Evidence IDs are assigned. No owned native
session required closure.

Remaining device questions include actual root/child containment, whether
`feedDelegate` directly resolves on this build, Swift direct-call paths, sound
suppression, native reason semantics, native collection gesture behavior and
sponsored/photo/carousel reels. The older user “it works” report applies to the
previous blanket restriction, not this new behavior.

## Validation and device handoff

Validation results for this revision are recorded below after the final build.
No fixture or test directory is intended to remain in the repository.

Device acceptance steps:

1. Open Reels: symbol/text appear; playback and audio stay stopped; other main
   tabs remain usable. At 1:59 there is no enabled bypass; at 2:00 it becomes an
   explicit choice. Wait longer without tapping: the block remains.
2. Leave at 1:50 or background the app, then return: the full wait restarts.
   Change the device clock during a wait: it must not change elapsed eligibility.
3. Tap Continue: blur and icon remain for three seconds, then the selected reel
   plays. The next played reel waits 3.5 seconds, then 4 seconds, and so on. No
   numbers or countdown text appear. Leave the tab and start a new visit: the
   delay starts at three seconds again.
4. Swipe repeatedly during a delay, pause, open comments/profile, change tab or
   background: an older reel must never start from a stale countdown.
5. Open comments/profile during an allowed visit and return to the same tab:
   bypass is retained. Switch to Home and back, or background: bypass is revoked.
6. While a tab visit is allowed, open a reel from a message/post: its selected
   reel plays but paging and auto-chaining remain blocked. Return to its sender.
7. Check the native auto-scroll setting both off and already on; framework does
   not turn it on. Any existing behavior is allowed only for a resolved tab owner.
8. Exercise ordinary/sponsored/photo/carousel reels, rotation, large Dynamic
   Type, VoiceOver, Reduce Transparency, interruptions and rapid tab switches.
9. Save master switch OFF, fully relaunch: native Reels behavior returns. Save
   ON and relaunch: blocker and non-tab navigation policy return.

If a case fails, record Instagram version, entry point, whether audio/video
started, elapsed time, tab/session transition and FLEX's nearest controller and
player class. Do not report the whole matrix as passed from one successful swipe.

### Results before progressive-delay follow-up

- `./scripts/build-framework.sh` completed with `BUILD SUCCEEDED`; the final
  build log contained no compiler warning/error diagnostics. All new source
  files are included by the synchronized Xcode source group.
- Final iOS framework:
  `latest-framework/NotTheInstagramFrameworkCode.framework`.
- Final framework executable SHA-256:
  `54f5d4605d3371300b70dd01951c0659e3614bde6f59fe33dfa61aa443911444`.
- Direct arm64 iOS 15 ARC syntax checks passed for navigation, session and
  playback sources. `git diff --check` passed.
- A temporary UIKit app on the iPhone 17 Pro / iOS 26.3 simulator included the
  production source unchanged, with stand-in runtime classes for the private
  Instagram classes. The final run passed **32 assertions, zero failures**.
  It checked initial blocker and disabled paging, refusal of an early action,
  readiness without automatic unlocking, explicit bypass, paging restoration,
  actual three-second play deferral with one original invocation, media changes,
  cancellation of reconfigured requests without a new host play request, tab
  exit cancellation, fresh visits, in-tab presentation visibility, foreground
  reset, and immediate selected-reel playback with paging restricted outside
  the tab.
- The two-minute readiness test advanced only the test instance's monotonic
  start value via KVC. It did **not** wait 120 real seconds or change production
  timing constants. The three-second playback delay was exercised in real time.
- The blocked, eligible and blurred states were rendered and visually inspected
  at the simulator's default portrait size. This is not a full dark-mode,
  landscape, VoiceOver or largest-Dynamic-Type pass.
- The stand-in app proves framework-side state/hook behavior with UIKit, not
  actual Instagram containment, audio suppression or every Swift playback path.
  **This new feature has not yet been confirmed on the user's device.**
- Temporary broad metadata JSON, parser copy and raw Hopper pseudocode dump were
  removed after their relevant findings were recorded. No fixtures or tests were
  added to the repository. The test app was uninstalled and the previously
  stopped simulator was shut down after verification. Existing unrelated notes
  and tests were preserved.


## Follow-up: progressive delays and no countdowns

On 2026-11-10 the user requested a small increase after each reel within a
session and an icon instead of remaining-time text. The chosen increment is
0.5 seconds, communicated before implementation. Delay policy is per root-tab
session: 3.0, 3.5, 4.0, 4.5 seconds, etc. There is no added maximum or persisted
counter. Leaving the tab or resigning active resets the count. Comments/profile
presentations in the same tab preserve it with the existing bypass.

The count advances when a new reel's gated host play method is released. This
uses the observed playback boundary; it does not claim a full-video completion
event has been observed. Skipped or cancelled requests do not increase the
count. Duplicate wrapper reports and resumes of the same representation are
deduplicated using the media identity, or the canonical underlying player when
no identity is available. Revisiting a reel after a different one counts as
another playback. Existing deadlines remain fixed for their request, so a
separate wrapper cannot lengthen a countdown already in progress.

Only the outer release records playback; nested wrapper/generic starts share
that release context and cancel any redundant pending cover/timer. The blur now
contains a single meaningful pause icon. The tab blocker retains its explanatory
copy and pause symbol, removes its numeric countdown and explicit duration, and
reveals the same consent button after the unchanged internal wait. No numeric
time is exposed through the icon's accessibility label.

### Follow-up validation

The updated arm64 iOS syntax check and device framework build passed, with no
compiler warnings/errors in the build log. The temporary UIKit simulator harness
passed **40 assertions with zero failures**, including base delay, per-reel
increase, duplicate-reel deduplication, cancellation without increment, the next
request's increased deadline, session/foreground reset and icon presence. The
prior blocking and playback-cancellation checks remain covered. Rendered default
portrait captures confirmed that neither the block screen nor the playback blur
shows a remaining-time value; the blur contains only its pause icon.

This still uses stand-in private classes, and advances the test instance's
initial two-minute wait via KVC; it is not an on-device Instagram pass or proof
of full-video completion tracking. No tests or fixtures are retained in the
repository. Final framework executable SHA-256:
`3c94d96ca0b6261ffc1da6e71a873d83ddb91ec2c30a3f4235ad1e1112e6d224`.


## Follow-up: posts and messages using the shared viewer

The user reported that opening a reel from a post showed the full “Reels are
paused” screen. The earlier test only modeled a standalone feed controller,
which bypasses the blocker by construction. A targeted UIKit fixture instead
opened a feed inside the shared `IGSundialRootTabViewController` while Home was
selected. Before the fix it failed three checks: no tab session, immediate
playback, and absence of the blocker. Swipe prevention still passed. This
reproduces the reported symptom in the model; the actual phone hierarchy was
not captured.

Root cause in the framework: matching the shared class was sufficient to
create the session and install the overlay; it did not verify the main tab's
identity before covering content. Even a root with no tab host could be covered,
with no way to become eligible. A later `viewDidAppear:` could also capture the
Home surface as if it were a Reels session.

Static evidence from the original Instagram 455.0.0 executable:

- The Objective-C `IGMainAppSurfaceIntent (SurfaceCheck)` category provides
  `tabStringFromSurfaceIntent` (`@16@0:8`, `0x10673e1fc`). At
  `0x10673e248`/`0x10673e24c` it selects the constant at `0x1140377d0`
  for tag 2. The CFString data is `CLIPS`. Other observed tab strings include
  `FEED`, `SEARCH`, `PROFILE`, and `DIRECT`. Code uses the internal string,
  with no compiled-in numeric index or localized title.
- `IGTabBarController.selectedViewController` (`@16@0:8`, `0x1062d55dc`)
  reads the selected intent and dispatches `navigationViewControllerForAppSurfaceIntent:`
  through the stub at `0x10dcebdc8`. That stub resolves through selector reference
  `0x114c5b4c8`. This is the native selected branch, rather than the topmost
  presented viewer. `warmUpDeferredReelsViewControllerIfNeeded` also calls
  `discoverVideoNavigationController`, `viewControllers` and `firstObject` in
  its Reels warm-up path. These were read from metadata and focused ARM64
  assembly, without a new Hopper instance or a target launch.

Session lookup now requires an actual `IGTabBarController` parent, selected
`CLIPS` intent, and the shared root belonging to the root of the selected
navigation stack (or the selected controller itself). A viewer pushed above
that root, or nested in a second shared root, cannot inherit its bypass. The
ABI checks cover all new getters; if the origin cannot be verified, the blocker
and delay are skipped while the independent swipe and automatic-advance
restrictions remain. A root that loses ownership has any old blocker removed
and its accessibility state restored. Appearance is remembered separately
from scope so a late tab assignment cannot leave a valid tab waiting forever.

After the fix, all nine assertions in the targeted fixture passed: Home/post,
Direct/message, and a post pushed onto the already selected `CLIPS` stack all
started playback immediately and kept paging disabled. The 40 existing
assertions also passed, now using a real UIKit navigation stack and stand-in
`IGMainAppSurfaceIntent` metadata for the genuine Reels-tab root. The fixture
apps and temporary binary output are not part of the repository. On-device
confirmation is still pending.

The iOS device framework rebuilt successfully with no compiler diagnostics.
`git diff --check` passed. The fixture apps were uninstalled and the simulator
was shut down. Final framework executable SHA-256:
`cfaf77749dad49c6a86e327cc784e61a7c7b130c92e3cb4c7c930ac0b2e05c86`.


## Follow-up: native Reels tab routing

The user reported immediate playback and disabled swiping when entering the
Reels tab. Both are the behavior for an external viewer, which meant the tab
was not receiving a session. The previous scope check required the legacy
`CLIPS` label. In the 455.0.0 executable, `IGTabBarController.isOnDiscoverVideo`
(`B16@0:8`, entry `0x1062c0528`) dispatches to a predicate at `0x1062efc54`
that accepts tag 2 and accepts tag 5 when `isHomecomingEnabled` is true.
The latter selector resolves through `0x114c0e468`. The legacy label mapper
returns nil for tag 5. This identifies a concrete route the old code excluded.
The user's exact runtime tab variant was not captured.

The framework now validates and calls Instagram's predicate and retains the
selected root branch check. A pushed post viewer remains outside the session
even when the Reels tab is selected. The selected surface object continues to
track tab exit and reset the session.

## Runtime cleanup — 2026-11-12

The Home feed delay source was already absent. The previous generated
framework still contained its hook, so the device build was regenerated from
the current source and checked for the absence of its class and overlay names.

The Reels bypass wait schedules a one-shot timer for its monotonic deadline.
Leaving the tab, resigning active, or losing root visibility cancels it. The
callback rechecks eligibility and elapsed time, and tapping the button checks
both again. There is no timer left running after the button appears. The
configured wait is still 120 seconds.

Layout enforcement compares the original getter results with the desired flags
before calling the original setters. In Instagram 455.0.0, both setters branch
to `0x1066aa1d0`, which stores the byte at the supplied ivar offset. Layout
still repairs changes to those flags and collection scrolling. The blocker also
avoids repeating frame, stacking, and accessibility writes when UIKit is
already in the desired state.

A temporary UIKit simulator app used a shortened wait and stand-in Instagram
controllers to exercise timer cancellation and restart, explicit bypass, tab
exit, restoration of native flags, and layout repair without repeated setter
calls. The device build succeeded. This cleanup has not been tested inside
Instagram on a device.

A temporary UIKit fixture reproduced the failure with a native Reels selection
and no legacy label. It reported immediate playback and no waiting session
before the change. Afterward, all 12 checks passed. They covered the entry
block, enabling swiping after Continue, the first reel and next reel delays,
the pause cover, immediate playback with paging disabled for post viewers,
and reset on tab exit. The test advanced the private wait deadlines to check
the state transitions without waiting in real time. On-device confirmation
remains pending.

The device framework rebuilt successfully. Binary SHA-256:
`622ff6315c7d3f93455fc88b5e0492c5a9d7d8156d80e8965d8af6a64f862938`.
