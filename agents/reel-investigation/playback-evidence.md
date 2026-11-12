# Playback gate evidence — Instagram 455.0.0

Read-only inspection of the original Mach-O, 2026-11-10. No runtime playback was
observed. The metadata parser reused the existing search investigation's
`class_ro_t` / relative `method_list_t` reader in memory; it did not modify that
reader or executable. Exact relevant declarations are retained below so the
temporary broad metadata inventory can be removed after implementation.

## Narrow Sundial playback view methods

Both classes declare the following methods with Objective-C ABI
`v24@0:8q16` (void result, one signed 64-bit reason):

| Runtime class | Selector | Implementation |
| --- | --- | --- |
| `_TtC30IGSundialCommonUIVideoPlayback26IGSundialVideoPlaybackView` | `playWithReason:` | `0x10b1ccefc` |
| Same | `pauseWithReason:` | `0x10b1c43e0` |
| Same | `stopWithReason:` | `0x10b1c43b0` |
| `_TtC30IGSundialCommonUIVideoPlayback32IGSundialModernVideoPlaybackView` | `playWithReason:` | `0x10b1c4380` |
| Same | `pauseWithReason:` | `0x10217129c` |
| Same | `stopWithReason:` | `0x10217128c` |

The legacy view declares `prepareForReuse` (`v16@0:8`, `0x10b1ebb04`) and
`videoViewIfAvailable` (`@16@0:8`, `0x105e5621c`). The modern view has the same
selectors at `0x10b1ebab4` and `0x100123888`. Both declare `isPlaying`
(`B16@0:8`) and `currentPlaybackTime` (`d16@0:8`). Runtime UIKit subclass checks
are still required; this metadata reader does not resolve all imported
superclass binding records.

The generic screenshot class `_TtC11IGVideoView11IGVideoView` declares:

| Selector | Encoding | Implementation |
| --- | --- | --- |
| `startPlaybackWith:` | `v24@0:8q16` | `0x10b1c0210` |
| `pausePlaybackWith:` | `v24@0:8q16` | `0x10cbf47c4` |
| `stopPlaybackWith:` | `v24@0:8q16` | `0x10b1cd270` |
| `currentVideoRepresentationId` | `@16@0:8` | `0x108c5792c` |
| `prepareForReuse` | `v16@0:8` | `0x10b1fc198` |

The generic class is shared with other surfaces. Any hook here needs verified
feed ownership, not a global currently-selected-tab flag.

## Observed Objective-C coordinator dispatch

`IGSundialViewerPlaybackSession` declares
`applyCoordinatedEvent:withContext:` at `0x106b32dbc`, ABI `v32@0:8q16@24`.
Focused `llvm-objdump --disassemble --start-address=... --stop-address=...`
inspection of `0x106b32dbc` through `0x106b32e48` shows four event branches:

| Event value | Call site | Stub | Decoded selector reference | Dispatch |
| --- | --- | --- | --- | --- |
| 0 | `0x106b32e24` | `0x10dbebdcc` | `0x114b84a18` | `pauseWithReason:` |
| 1 | `0x106b32e3c` | `0x10dbf5f6c` | `0x114bc14e0` | `prepareForPlayback` |
| 2 | `0x106b32e04` | `0x10dc255e8` | `0x114b88908` | `playWithReason:` with reason 1 |
| 3 | `0x106b32df4` | `0x10dbe8b08` | `0x114b85c40` | `stopWithReason:` with reason 3 |

Selector names were decoded from each ARM64 `adrp` + `ldr` stub through its
original `__objc_selrefs` pointer and C string. This is static evidence that
the viewer playback session uses Objective-C dispatch for these operations,
supporting hooks on the two Sundial wrapper views. It does not prove every
playback path uses that session or that no Swift direct call bypasses the hook.

The generic `startPlaybackWith:` implementation is an Objective-C thunk calling
Swift body `0x106829670`. Legacy and modern `playWithReason:` thunks call
Swift bodies `0x1095d3830` and `0x106b3176c`, respectively. Do not patch these
addresses or assume they are stable between builds.

## Implementation consequences

- Suppress a pending `playWithReason:` dispatch while the gate is closed; a
  blur overlay alone does not suppress playback or its audio.
- Retain the supplied native reason for a delayed request; do not invent
  numeric reasons. The table documents observed values, not a complete enum.
- Cancel a saved request when the view is reused, paused/stopped by Instagram,
  removed, moved to another feed, or the tab session ends. A weak view and
  generation token protect against stale delayed playback.
- A wrapper can call the generic video directly inside its Swift body, so
  intercepting only the generic Objective-C thunk has incomplete coverage.
- Device checks must confirm silence for the full block and inter-reel delay,
  then correct playback after bypass, on ordinary and sponsored reels.
