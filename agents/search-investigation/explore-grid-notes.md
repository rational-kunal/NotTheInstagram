# Explore grid investigation — Instagram 455.0.0

The user's FLEX screenshots show `IGExploreViewController` containing an
`IGExploreGridViewController`, whose view contains an `IGListCollectionView`
with media thumbnails. A later screenshot shows `IGExploreSearchTitleView`
and `IGSearchBar` under a separate `IGExploreUIComponents.IGExploreNa…`
navigation view, outside that grid controller's view. The navigation class
name is truncated in the screenshot. This supports targeting the grid rather
than the search bar; it does not prove runtime behavior after a hook.

Static Objective-C metadata in `explore-metadata.json` identifies
`-[IGExploreGridViewController viewWillLayoutSubviews]` at `0x106d6feec` and
the separate `IGExploreViewController`. The metadata is from the local 455.0.0
Mach-O, not an execution trace. Hopper was already open on that executable and
was still performing background analysis when inspected.

`ExploreGrid.m` hides the grid's direct `IGListCollectionView` and puts
a non-interactive magnifying glass placeholder above it, only when the grid
controller is a child of `IGExploreViewController`. It hides all grid content,
not just video thumbnails. The user reported that the integrated build works
on device; the individual checks below have not all been separately confirmed.

Further device checks: confirm the grid is absent from first load,
the search bar opens and returns results, navigating back restores the empty
state, tab switching and rotation remain correct, and accessibility does not
expose hidden thumbnails. Confirm the icon and background look appropriate in
both appearances. Data fetching may continue because the draft hides the view
rather than changing Instagram's data source.
