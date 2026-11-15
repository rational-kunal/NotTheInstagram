# FLEX integration — 2026-11-10

FLEX is linked into the injected framework through Swift Package Manager,
pinned to upstream revision `dac6130e0c7aca0bbf7ff8c0b57ba284776bfdff`:
https://github.com/FLEXTool/FLEX

Both Debug and Release intentionally include FLEX: the Sideloadly build script
uses Release, and this framework is for local exploration of the sideloaded
app. FLEX's license prohibits including it in an App Store submission.
`FLEX-LICENSES.txt` carries upstream and bundled third-party license notices.

## Use

1. Run `./scripts/build-framework.sh` (package resolution requires access to GitHub).
2. Replace Sideloadly's framework attachment with
   `latest-framework/NotTheInstagramFrameworkCode.framework` and install using
   the existing signing and bundle identifier settings.
3. In Instagram, double-tap with three fingers or hold the usage label at the
   bottom for one second to open FLEX. Either gesture can reopen the toolbar.

FLEX starts hidden. The integration does not explicitly enable network capture;
FLEX's own settings control it. Capturing NSURLSession traffic does not imply
coverage of all Instagram networking stacks.

## Implementation

`FLEXIntegration.m` limits installation to Instagram's bundle identifier and
Sideloadly suffixes. After loading, it registers on the main queue for visible
windows and application/scene activation, covering existing and replacement
legacy and scene windows without swizzling Instagram. Each eligible window gets one
gesture recognizer tracked in a weak hash table. System overlays and FLEX's own
window are excluded. The gesture permits simultaneous recognition, does not
cancel or delay app touches. It opens FLEX in the originating active scene when
available, or uses `showExplorer` for an active application with legacy windows.

`-ObjC` retains FLEX's Objective-C categories in the linked framework. The
finished binary must contain FLEX and must not require a separate FLEX dynamic
framework attachment.

## Verification

`./scripts/build-framework.sh` passed for Release / iphoneos26.2 / arm64.
The final binary exports `FLEXManager`, `FLEXExplorerViewController`,
`NTIFLEXIntegration`, and `NTIStorageCompatibility`. `otool -L` lists only system
dependencies and this framework's own install name, with no separate FLEX dylib.
The framework contains `FLEX-LICENSES.txt`. Project plist validation and
`git diff --check` passed. No integration-source compiler warnings were emitted;
upstream FLEX emits SDK deprecation warnings.

Corrected artifact UUID: `C705722E-34A8-3958-AC26-62A3A7E9400D` (arm64).
The corrected device build passed and the binary contains the v2 log marker;
it still has no separate FLEX dynamic dependency.

The user reported that the initial three-finger double tap did not open FLEX.
The corrected build still needs on-device confirmation of launch, gesture
recognition, toolbar reopening, ordinary navigation, and login persistence.

## Activation failure and repair

The extracted Instagram 455.0.0 `Info.plist` has no
`UIApplicationSceneManifest`. The first integration only enumerated
`connectedScenes`, rejected every window without `windowScene`, and also
rejected activation without a scene. That leaves the pre-scene application
lifecycle with no working opener.

`bash agents/flex-tests/run.sh` compiles the production integration source on
macOS with small UIKit/FLEX fakes. Before the repair it failed five checks:
existing legacy-window attachment, opening, replacement-window attachment,
reopening, and one-recognizer attachment. The three scene/background checks
passed. After the repair all eight checks pass. This exercises the actual
integration methods and gesture action, but does not emulate iOS touch delivery
or prove the installed phone's UI behavior.

The repair enumerates `UIApplication.windows` as well as scene windows,
allows legacy windows, and selects the appropriate FLEX presentation method.
It retains deduplication, scene/background checks, and simultaneous gesture
recognition. Logs distinguish attachment from a recognized action:

- `[NTI] FLEX activation v2 ready` identifies the corrected integration.
- `[NTI] FLEX opener attached (scene=0)` confirms a legacy-window opener.
- `[NTI] FLEX open requested (scene=0)` confirms that the gesture reached FLEX.

The phone was discoverable through CoreDevice during diagnosis, but no live
debugger or actual touch replay was used. The exact installed-window state and
possible system-level gesture interception remain unverified.

## Follow-up — 2026-11-15

Live iPhone Console logs showed the v2 opener attaching to a scene window,
without an open request in the capture. The v3 integration keeps the original
gesture and accepts a one-finger hold starting inside the usage label. It now
logs gesture recognition before checking whether the app or scene is active.
The activation fixture covers the new gesture and rejects touches outside the
label. The device build succeeded. The new gesture still needs an iPhone test.
