# fishhook

Adapted from upstream `fishhook.c` and `fishhook.h`, retrieved 2026-11-10 from
https://github.com/facebook/fishhook (`main`). BSD license is retained in both files.

Original upstream SHA-256 (before local cleanup):

- fishhook.c: `48f51e1a36d9013501381fdf31a3e9c838938ebf8bb39e0e3a7ac119aa59b61b`
- fishhook.h: `5432b81bd302956adcbfc8836af74e47dd38748d5078495cbe1b5bea62180120`

Storage compatibility uses `rebind_symbols_image` only for images inside the
Instagram application bundle. It does not rebind imports in system frameworks.

Local cleanup removes the unused process-wide API, linked-list allocation,
original-pointer output, inactive protection helper, and unused includes.
Symbol matching and section-protection handling follow upstream. The image
function now returns -1 when a matching pointer cannot be made writable, so
the caller can log that failure. No instruction patching is performed.
