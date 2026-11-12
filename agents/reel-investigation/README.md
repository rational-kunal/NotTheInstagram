# Reel navigation restriction — Instagram 455.0.0

The new Reels-tab block, two-minute session bypass and three-second playback
delay are documented in [tab-session-notes.md](tab-session-notes.md). The
implementation narrative below records the earlier blanket restriction; its
successful device report must not be applied to the new feature without testing.

## Goal and current status

Keep the reel the user explicitly opened playable, while blocking both swipes
between reels and automatic advancement. Playback controls, comments, sharing
and exit navigation should retain their normal behavior.

On 2026-11-10 the user tested the initial injected framework and reported:

> it works

That is positive on-device evidence for the requested restriction. The user did
not separately report which entry points, playback controls, comments, rotation
or background/foreground cases were exercised. Do not mark those individual
checks as confirmed. The subsequent source cleanup preserves the same hook
behavior when enabled and adds a saved switch; this revision needs its own
device check, especially for the disabled setting.

## Files and responsibilities

- `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/ReelNavigation.h`:
  small internal API for future settings UI; no Instagram private types exposed.
- `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/ReelNavigation.m`:
  preference storage, private-method compatibility checks, hook installation,
  stored flag enforcement, feed paging restriction and timer suppression.
- This note: retained investigation findings, decisions, validation and follow-up
  guidance. Temporary probes, metadata dumps, logs and the reel fixture test
  directory were removed at the user's request. Earlier unrelated project files
  and the pre-existing FLEX tests were left alone.

The Xcode target uses a synchronized source group, so the new source/header are
included without explicit project-file entries. The header is internal to the
framework source, rather than added to its public umbrella API.

## Future toggle integration

The restriction defaults to **enabled**. Its saved preference lives in the host
Instagram process's standard `NSUserDefaults` under `NTIReelNavigationEnabled`.
An absent or nonnumeric value uses the enabled default. An explicit false value
allows Instagram's original reel behavior on the next launch.

A future settings controller inside this framework can import the header:

```objc
#import "ReelNavigation.h"

// Populate a settings switch.
switchControl.on = NTIReelNavigation.enabled;

// Save its new value from the switch's action handler.
NTIReelNavigation.enabled = switchControl.isOn;
```

Both the property and UI switch mean "restrict reel navigation": YES blocks
advancement, NO permits the original behavior. This is distinct from Instagram's
own `autoAdvanceToNextItem` and `isEnabled` properties, whose enabled states must
be suppressed while the restriction is active.

**Fully quit and relaunch Instagram after changing the setting.** `+load` reads
it once to decide whether to install any reel hooks. The property getter reports
the saved choice for the next launch; it does not report whether hooks are
currently installed or whether private-method compatibility checks passed.

No toggle UI is included yet. The internal class property is the integration
point. Saving the setting does not change Instagram's own saved auto-scroll
preference, the Explore restriction or other framework features. To return to
the default, remove `NTIReelNavigationEnabled` from the host defaults and relaunch.
Do not use the Mac host's defaults as though they were the injected iOS app's
settings; preferences belong to the process/container where the code executes.

### Why apply changes on launch

The working restriction writes backing state and disables an existing feed
collection. It also prevents timer work from being scheduled. Merely making
replacement getters conditional would leave a live viewer's stored flags,
scrolling and timer state inconsistent with the switch.

On a launch with the switch off, no reel methods are replaced, so Instagram
creates fresh viewers and timers using its normal implementation. This avoids
inventing a partial restoration mechanism during the cleanup.

If immediate toggling is required later, treat it as a separate feature:
preserve the original getter/timer implementations, retain native desired values
for every forced flag and scrolling state, track active controllers weakly, apply
changes on the main thread, and explicitly manage timer cancellation/restart.
Do not simply remove hooks while callbacks or visible viewers still depend on
their altered state. Add a device validation pass for both toggle directions.

## How the restriction works

### Installation and compatibility

`+load` checks the saved switch. Installation is scoped to
`com.burbn.instagram` and identifiers beginning `com.burbn.instagram.`; repeating
installation does not replace the saved originals with the hooks themselves.

The controller is looked up by the exact runtime name
`IGSundialFeedViewController`. Each hook descriptor declares its selector,
replacement, optional original-implementation storage, result type and explicit
argument types. Before installation, Objective-C runtime metadata is checked for
argument count and every declared type.

All seven controller replacements and the `collectionView` accessor must be
compatible before any controller hook is installed. A missing or incompatible
core method leaves the controller untouched. Auto-scroll methods are optional
and checked individually; missing engine APIs do not undo controller protection.
There is no fallback to broadly hooking every scroll view or video view.

`class_replaceMethod` adds an override for inherited methods. It does not mutate
the original superclass method, so unrelated controllers do not inherit this
restriction through a UIKit-wide change.

### Controller state and lifecycle

The two host flags are forced through their original setters:

| Host property | Forced value | Purpose |
| --- | --- | --- |
| `advanceToNextItemDisabled` | YES | Keep advancement disabled in stored controller state. |
| `autoAdvanceToNextItem` | NO | Prevent the controller from opting into automatic advancement. |

Getter dispatch reports the same enforced values. The setter replacements
coerce subsequent Objective-C requests from Instagram to those values.

`viewDidLoad`, `viewWillAppear:` and `viewDidLayoutSubviews` apply these flags
before and after calling the original method exactly once. The appearance
argument is forwarded unchanged. The pre-call update makes the restriction
available during host setup; the post-call update preserves it after setup or
layout updates.

After each original lifecycle method, the hook retrieves `collectionView`,
checks that it is a `UICollectionView`, then sets `scrollEnabled = NO`. It
repeats the lookup so a replaced collection is handled, and tolerates nil.
It does not recursively disable nested views or all recognizers. This narrow
scope is intended to preserve separate comments, carousel and playback input.

No hard-coded runtime memory offsets, raw ivar writes or content-offset clamps
are used. The host can still position the reel explicitly selected on entry.

### Separate auto-scroll engine

Runtime class:
`_TtC19IGSundialAutoScroll19IGSundialAutoScroll`.

| Selector | Replacement behavior |
| --- | --- |
| `restartCurrentTimerIfNeededWithMediaAccess:mediaMap:block:` | Return without scheduling timer work or calling the supplied block. |
| `setReelDuration:onCountdownFinishedCallBack:` | Return without scheduling a countdown or calling its advancement callback. |
| `isEnabled` | Return NO. |

These blocks belong to the navigation countdown. They are intentionally not
completed by the hook because doing so could advance the reel immediately.
The hook does not stop the video player or persist a change to native auto-scroll
preferences. Engine method signatures are checked, including block and double
argument encodings, before replacement.

## Reverse-engineering findings

Target: the extracted Instagram 455.0.0 ARM64 Mach-O at
`original-decrypted-ipa/455.0.0/com.burbn.instagram-455.0.0-Decrypted/Payload/Instagram.app/Instagram`.

Original executable SHA-256:
`597efa50a6ed24a023f5a208a5b72dddad520e0311e29db6e27ddabb1e5bda40`.

1. The user's FLEX screenshots identify `IGVideoView.IGVideoView`, contained in
   a reel page whose nearest controller is `IGSundialFeedViewController`. This
   supports targeting the controller instead of interfering with the video view.
2. Static Objective-C method metadata identifies these methods and ABI:

   | Selector | Implementation address | Encoding |
   | --- | --- | --- |
   | `advanceToNextItemDisabled` | `0x107640a48` | `B16@0:8` |
   | `setAdvanceToNextItemDisabled:` | `0x108cb6574` | `v20@0:8B16` |
   | `autoAdvanceToNextItem` | `0x10764f59c` | `B16@0:8` |
   | `setAutoAdvanceToNextItem:` | `0x108cb6eb0` | `v20@0:8B16` |
   | `collectionView` | `0x1077103e0` | `@16@0:8` |
   | `viewDidLoad` | `0x10b1dd6d4` | `v16@0:8` |
   | `viewWillAppear:` | `0x10b1bf1c0` | `v20@0:8B16` |
   | `viewDidLayoutSubviews` | `0x10d4414d4` | `v16@0:8` |

3. Pseudocode obtained through the Python console in the user's already-open
   `Instagram.hop` window shows the advancement getter reading one byte from
   `self + *0x1144e7b48`, and the setter writing that same byte. This address is
   a binary-specific dynamic ivar-offset slot, not a runtime object offset to
   copy into source code.
4. Focused assembly at `0x10cd70798` onward reads this byte directly, and chooses
   false for a `setScrollEnabled:` call on the controller's `collectionView`.
   Selector-reference slots `0x114b7fb30` and `0x114b7ec68` decode to
   `setScrollEnabled:` and `collectionView`. This is why getter hooks alone are
   insufficient: stored state must also be set through the original setters.
5. The separate auto-scroll class exposes the three selectors listed above.
   Their presence and signatures are static observations; they do not prove
   that every Swift path dispatches through Objective-C.

Hopper background analysis was unfinished. Some requested procedures were
absent or yielded incomplete pseudocode; only the advancement getter/setter
pair gave useful complete pseudocode. Targeted methods were marked as
procedures in the existing analysis database. Executable bytes were not patched.

REA reported no bound native target. Its installed launcher opens an owned
copy rather than attaching to the user's existing window, so no `open_binary`
call or new Hopper instance was made. Existing Hopper was queried with computer
control, supplemented by read-only metadata and llvm-objdump inspection of the
same executable. No native REA session was opened or left to close. The temporary
reference scanner generated candidates with possible duplicates/false positives;
it was not a complete call graph, and it has been removed.

## Validation and maintenance

Before cleanup, the initial code passed 16 fixture checks covering app scope,
ABI mismatch rejection, repeat installation, flag values before host load,
backing-state coercion, original lifecycle calls and appearance arguments,
replacement/nil collections, subclass protection, superclass isolation and
suppression of timer callbacks. Those same checks passed after the hook-table
refactor, before their fixtures were removed. These tests modeled Objective-C
boundaries; they did not execute Instagram or real UIKit.

The initial iOS device build succeeded using `./scripts/build-framework.sh`.
The initial framework binary tested by the user had SHA-256:
`99890563211577d4ffe368bd214ddf4856f8c7b90cfc920a089b1d2afba5b91d`.
Do not confuse that initial build identity with later rebuilt artifacts.

The final cleanup build also succeeded on 2026-11-10. Symbol inspection verified
the restriction implementation and the `isEnabled` / `setEnabled:` settings
methods in the rebuilt ARM64 framework. Final binary SHA-256:
`17755031e6e6c504f55926ee161e29d55886f1ebb0e1a0bdea770474cae16b3e`.
`git diff --check` passed. The new preference's on/off behavior has not yet been
tested on device. No new fixture suite remains in the project.

For subsequent builds, run the same script; its device output is
`latest-framework/NotTheInstagramFrameworkCode.framework` for Sideloadly. The
script keeps the old artifact until compilation succeeds and uses a temporary
build directory. It fetches the project's pinned FLEX package when necessary.
The shared Xcode scheme also invokes this script as a post-action.

After a future Instagram update, recheck the exact class names, method signatures
and call paths before adapting any hook. Swift direct calls may bypass the
Objective-C replacements, and new automatic-advance paths may be introduced.
Full-screen viewers that do not inherit from the targeted feed controller are
outside this implementation. A positive result on 455.0.0 is not a guarantee for
another version or every entry point.

Useful device coverage for the cleaned build and future settings UI:

- Default/no preference: explicitly opened reel plays and stays selected after
  repeated swipes and playback endings.
- Save enabled = NO, fully quit/relaunch: native reel swiping/advancement returns.
- Save enabled = YES, fully quit/relaunch: both restrictions return.
- Reels opened from DMs, profiles, search and the Reels tab; leave and open a
  different reel to verify selected-item positioning.
- Comments, likes, sharing, pause/seek, horizontal carousels and back/dismiss.
- Tab switching, background/foreground, keyboard use and rotation.

If navigation escapes the restriction, record the Instagram version, entry
point, whether it follows a swipe or playback completion, the full FLEX
controller class and its `collectionView` details. A short recording can help
separate a remaining navigation path from a layout or playback issue.
