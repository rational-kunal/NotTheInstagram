# NotTheInstagram features

This framework is injected into a sideloaded copy of Instagram. The private
classes and methods were investigated against Instagram 455.0.0. Each hook
checks the Instagram bundle ID, including Sideloadly suffixes. Runtime hooks
check their method signatures before installation.

The framework source is grouped into `Features/` for Home, Reels, Explore,
and the usage label, `Compatibility/` for launch and storage hooks,
`Diagnostics/` for FLEX, and `Runtime/` for shared hook validation. Xcode
discovers these folders through the synchronized source group.

## Show time spent today and this week

A label at the bottom of Instagram shows how long the app has been active
today and during the current Monday-start week. It lets taps and swipes pass
through. Totals are saved locally from the first launch with the feature.
[Usage label](usage-label/README.md)

## Reveal Home posts three at a time

Home reveals three posts at each boundary. The waits are 8, 11, and then
14 seconds for subsequent boundaries. The spinner must remain visible
while the wait runs. The native request handles fetching the next page.
[Home Feed pagination](home-feed-investigation/README.md)

## Open a Reel without entering an endless feed

A Reel opened from a post, message, or other viewer plays immediately. Swiping
and automatic advancement to the next Reel are disabled in that viewer.

The framework sets Instagram's advancement flags through the original setters
and disables scrolling on the Reel collection. It also blocks the native
auto-scroll engine unless it can tie that engine to an unlocked Reels tab.
The framework keeps track of Instagram's requested settings so it can restore
them when the tab is unlocked.
[Reel navigation](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelNavigation.m)

## Pause before entering the Reels tab

The Reels tab starts behind a pause screen. After two continuous minutes on
that screen with Instagram active, **Continue for this session** appears.
Tapping it restores Instagram's normal Reels navigation for that visit.
Leaving the tab or losing foreground activity resets the bypass.

The framework uses Instagram's own Reels-tab predicate and checks that the
viewer belongs to the selected tab's root. A post opened on top of that tab
still gets the single-Reel behavior. A one-shot timer uses device uptime to
measure the wait, and the button checks the full wait again before unlocking.
The pause screen hides covered content from VoiceOver and restores its previous
accessibility state on unlock. The Reel features share a saved switch that
defaults to on and takes effect after relaunch.
[Tab session](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelTabSession.m)

## Add a pause between Reels

After unlocking the Reels tab, the first Reel waits 3 seconds before playback.
The wait increases by half a second after each new Reel starts. Resuming the
same Reel keeps the current delay. A blur with a pause icon covers the player
during the wait, and the delay resets with the tab session.

The framework holds Instagram's play request before video or audio starts.
It checks the viewer, media identity, and visibility at the deadline before
forwarding the saved play request. Layout and session changes can recheck a
pending request, and Instagram's pause, stop, and reuse calls cancel it.
Ordinary videos outside a Reel feed use the original player without allocating
delay state.
[Playback gate](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/Reels/ReelPlaybackGate.m)

## Keep search while hiding the Explore grid

The Explore recommendations grid is replaced by a magnifying glass. The
separate search bar can still open Instagram's search flow.

The framework hides the grid's direct collection view only under Explore.
One lightweight placeholder fills the same area. If Instagram replaces the
collection or lays out the controller in a different context, the previous
collection's hidden state is restored. Instagram can still fetch grid data.
[Explore grid](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/ExploreGrid.m)

## Skip the TestFlight update prompt

The TestFlight update prompt is suppressed so it does not interrupt launch.
Instagram's presentation callback still runs when it supplied one. Other
dialogs use UIKit's normal presentation path.

The framework identifies the specific TestFlight update controller when
Instagram asks UIKit to present it.
[Beta update bypass](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Compatibility/BetaUpdateBypass.m)

## Keep login storage working after sideloading

When re-signing removes access to Meta's storage, Instagram can still save
preferences and sign-in data in storage available to the installed copy.

The framework first tries the original shared-folder and keychain APIs. For
known Meta folders that iOS denies, it creates a persistent folder inside the
app's container. For keychain calls that fail because the app lacks access to
Meta's family group, it retries against a separate app-owned group after
Security verifies access. Credentials stay in the iOS keychain.
[Storage compatibility](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Compatibility/StorageCompatibility.m)

## Open FLEX for inspection

Double-tap with three fingers to open FLEX. The inspector starts hidden.

The framework attaches one gesture to each eligible app window, including
legacy windows and windows managed by scenes. The gesture allows simultaneous
recognition and keeps ordinary touches flowing to Instagram. It opens FLEX in
the active scene or active legacy app.
[FLEX integration](../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Diagnostics/FLEXIntegration.m)

## Build and verification

Run `./scripts/build-framework.sh` and attach the resulting
`latest-framework/NotTheInstagramFrameworkCode.framework` in Sideloadly.
The refactored framework builds for arm64 iOS devices. A UIKit simulator
fixture passed 26 checks across Home pagination, Reels, Explore, the beta
prompt, and shared folders. Ten FLEX checks and six simulated keychain
checks also passed.
On-device verification inside Instagram is pending.
