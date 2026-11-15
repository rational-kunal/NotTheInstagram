# Home feed pagination · Instagram 455.0.0

Home reveals three posts at a time. The waits increase from 8 to 11 to 14
seconds, then stay at 14 seconds. The sequence starts over when
the feed starts with a different first post. Stories and other feed modules
stay in the order Instagram supplied. At the real end of the available posts,
the native spinner or a UIKit fallback gates the next page request. Network
time is additional. Scrolling away or leaving Home during a wait restarts the
current timer.

The implementation lives in
[HomeFeedPagination.m](../../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/HomeFeed/HomeFeedPagination.m).
The first loader implementation only affected page requests. The on-device
report said posts continued appearing and the spinner showed up after many
posts. The list data source now withholds already available posts as well.

## Binary evidence

The executable analyzed was the extracted ARM64 Instagram 455.0.0 Mach-O
(SHA-256 `597efa50a6ed24a023f5a208a5b72dddad520e0311e29db6e27ddabb1e5bda40`).
The previously inspected Hopper Demo document returned the primary feed
controller labels and the tab predicate at `0x1063134a8`. For the pagination
pass Hopper was at its demo prompt. The evidence below comes from the local
Mach-O Objective-C metadata and focused disassembly.

- The Objective-C data source's `_objectsResolvingInsertionWithAdapter:`
  calls `_shouldAddTailLoadSpinner` at `0x1066bda44`. The append path calls
  the helper at `0x1066f60e8`, which passes the `spinner_model` string to
  the constructor path. That path loads the `IGSpinnerLabelViewModel` class
  reference at `0x1144ad1a8`. The controller also checks the class when
  determining whether the tail spinner is about to display.
- `IGMainFeedViewModel` uses `_feedDataProvider` for its load-more dispatch.
  `fetchMoreItemsWithPrefetchType:` sends
  `canLoadMoreWithPrefetchType:reason:extraParams:` with reason 9.
  `_fetchNextPage` supplies prefetch type 0 and requests a native list
  update when the load starts.
- Despite its name, the provider method can start a load. The Objective-C
  path at `0x106731a40` calls through to `_fetchMoreItemsWithReason:`
  and then `fetchDataWithConfig:` or applies a deferred response. The Swift
  bridge method at `0x1069c9460` updates request state and dispatches its
  load. Both expose `B40@0:8q16q24@32`.
- The bundled FBSharedFramework provides the shared `IGListAdapter`
  scroll and will-display callbacks at `0x5d63e8` and `0x5f4248`.
  The hook uses those callbacks to check the visibility of the spinner's
  actual collection cell.
- The Objective-C and Swift Home data sources expose `objectsForListAdapter:`
  at `0x1066be588` and `0x106719378`. The matching section factories are at
  `0x1066be978` and `0x10671c768`. The shared adapter supports
  `performUpdatesAnimated:completion:` at `0x5d3a78` and the collection-cell
  dequeue entry point at `0x5f3f78`. The replacement list preserves the native
  objects and adds one temporary section after the last exposed post.

The hook scopes the wait to the provider bound to the primary Home model.
It checks that the selected tab and spinner are visible again before
requesting a page. It invokes Instagram's native fetch path at the deadline,
which retains the app's request handling, including existing deferred
responses. These static observations cover the inspected pagination entry
points. Device testing is needed to confirm the active account variant
uses them.

## Verification

The arm64 iOS source passed compilation with warnings treated as errors. A
local fixture reproduced the original 20-post run and verified that the
updated list exposes the first three posts, then the next three in order,
with interleaved modules and the final native footer preserved.
The timing fixture verified the progression and the 14-second cap.
The framework was built with the repository's device build script in an
isolated project copy and the pinned FLEX revision from the local cache.
Use the rebuilt framework in `latest-framework/` for Sideloadly. The
binary contains the pagination hooks, loading cell, and FLEX.

On device, scroll past three Home posts and time the spinner once it comes
into view. Check for eight seconds at the first boundary, eleven at the
second, and fourteen at later boundaries. Scroll away and return during
another wait. Verify that pull to refresh and Following still load normally.
