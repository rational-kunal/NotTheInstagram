# Instagram 455.0.0 login persistence and crash investigation

Date: 2026-11-10 (Asia/Kolkata)

Follow-up: a compatibility repair was subsequently implemented. See
[storage-compatibility.md](storage-compatibility.md) for its scope, local
verification and user-reported on-device success. This report records the earlier
investigation and its original evidence limits.

## Findings

Two signing compatibility failures are supported by the supplied evidence:

1. **Observed:** iOS rejects keychain operations explicitly targeting
   `group.com.facebook.family` with OSStatus `-34018`. The re-signed app's
   recorded allowed groups are `KTZBQ22Z6S.*` and
   `KTZBQ22Z6S.com.burbn.instagram.KTZBQ22Z6S`. Both reads and writes fail.
   **Inference:** this is a strong explanation for automatic login failing
   after a successful manual login. The private keychain item names/contents
   are not exposed, so the exact session item has not been identified.
2. **Observed:** both crash reports terminate through the same `hasPrefix:`
   call in `FBSharedFramework`, on
   `com.instagram.igdatauserdefaults.sync.queue.serial`, with an uncaught
   Objective-C exception and `SIGABRT`.
   **High-confidence inference:** a failed app-group container lookup leaves a
   nil shared-container path that is passed as the prefix. The binary trace
   explains this exact call site, and the later console capture independently
   records app-group lookup entitlement failures. The report does not retain
   the original exception reason or the prefix argument, so its runtime nil
   value is inferred rather than directly observed.

The beta-update popup is not established as the cause. The injected greeting
framework is loaded in both crashed processes, but its code is absent from
their exception backtraces. This does not exclude indirect effects.

## Target and evidence identity

- Source IPA: `original-decrypted-ipa/455.0.0/com.burbn.instagram-455.0.0-Decrypted.ipa`
- IPA SHA-256: `490546d17c0dde85a0058e30ed72a70c8abfd3f243304b46a3ffaa1b674c9010`
- Selected ZIP member:
  `Payload/Instagram.app/Frameworks/FBSharedFramework.framework/FBSharedFramework`
- Extracted member SHA-256:
  `dd8d39d0cff3791fd8b96ea05e99c2288b2d35eab3fd86539045a199b83076af`
- Mach-O UUID: `4C4C44CF-5555-3144-A1F2-A935290318DA`, arm64.
  `xcrun dwarfdump --uuid` matches the framework UUID in both crash reports.
  This establishes matching build identity, not byte identity with the
  re-signed installed framework.
- First crash REA Evidence:
  `ev_0927043305421df610f4932d2cf2ab4e67abadef093e11983baca1cc35225a32`.
  Captured 13:06:59.6280 +0530, PID 55329.
- Second crash REA Evidence:
  `ev_2429e50995e5b2634e9e07025d2d17df39de21b3d44a992cf46cbe93b30da393`.
  Captured 13:11:42.1333 +0530, PID 55350.
- The supplied console capture is from a later launch, PID 55356, beginning
  around 13:11:56. It corroborates failures in the same installation, but
  does not record either crash's pre-exception events.
- Console source:
  `/Users/kunalkamble/.codex/attachments/ef1a9a6d-b3f7-4e8c-9df5-9a51bb563e1e/Pasted text.txt`.
  Relevant lines: 9 (signed entitlements), 787/801/919/7395 (app-group
  container lookup rejected), 1468 (keychain read rejected), 2178 (update
  rejected), 2208 (add rejected).

The second crash's complete REA record is retained in
`instagram-login-crash-2026-11-10-evidence.json` beside this report.

## Static trace in the matching framework

These observations come from Apple toolchain disassembly, not a successful
REA decompilation. The framework's preferred `__TEXT` VM address is zero, so
these unslid addresses also match the crash report's image-relative offsets.

- At `0x417af0`, the preferences synchronization caller calls `0x3da2e4`.
  Its return address `0x417af4` is present in both crash backtraces.
- The function at `0x3da2e4` obtains `[object filePath]`, checks that the result
  is nonnil, and initializes cached directory prefixes with `dispatch_once`.
- At `0x3da348`, it calls `hasPrefix:` with the cached home directory.
- If that test is false, at `0x3da35c` it calls `hasPrefix:` again, using the
  pointer stored at `0x2d41810` as the prefix. There is no nil check for this
  prefix. The return address `0x3da360` exactly matches both crashes.
- The initializer at `0x3da490` obtains `NSHomeDirectory()` and stores it at
  `0x2d41800`.
- At `0x3da4cc`, that initializer calls `_IGAppGroupContainerURL`, then sends
  `path` to the result at `0x3da4d8`, and stores the returned path at
  `0x2d41810` at `0x3da4ec`.
- `_IGAppGroupContainerURL` at `0x106520` calls
  `_IGAppGroupContainerURLWithAppType` at `0xfd3a8`, which uses
  `_IGAppGroupIdentifier` and `containerURLForSecurityApplicationGroupIdentifier:`.

Simplified reconstructed logic (not original source):

```objc
NSString *filePath = [object filePath];
if (!filePath) return nil;
dispatch_once(&once, ^{
    homePath = NSHomeDirectory();
    sharedPath = [IGAppGroupContainerURL(/* ... */) path];
});
if ([filePath hasPrefix:homePath]) {
    // Encode an ordinary app-container path.
} else if ([filePath hasPrefix:sharedPath]) { // Crash return address 0x3da360
    // Encode an app-group path.
} else {
    // Encode an absolute path.
}
```

The names `IGProductSaveStatusStore prepareIfNeeded` and
`IGMediaBandwidthEstimator videoSharedInstance` in the reports are nearby
exported symbols with large offsets. Disassembly shows additional function
boundaries after those symbols. Do not attribute the failing function's
semantics to those class names.

## Bounded validation

- REA parsed the second crash completely: 78 threads, 577 frames, 32 images,
  no reported type mismatches.
- Both reports have identical exception backtrace image offsets, including
  `0x3da360` and `0x417af4` in the matching framework.
- `xcrun llvm-objdump` resolved the focused instruction ranges; selector
  references were decoded from their Mach-O mappings (`filePath`, `hasPrefix:`,
  and `path`). The indirect symbol table identifies `NSHomeDirectory`.
- A temporary Objective-C Foundation probe ran `[filePath hasPrefix:nil]`
  under `@try/@catch` on this Mac. It reported:
  `NSInvalidArgumentException: -[__NSCFConstantString hasPrefix:]: nil argument`.
  This validates the API failure mechanism, not the complete iPhone repro.
- REA's Hopper provider timed out after 120 seconds waiting for its bridge.
  UI inspection showed background analysis still running. No pseudocode
  Evidence was returned. The temporary analysis document was closed manually
  after the provider could not acknowledge cleanup. REA continued to report
  `cleanup_incomplete` after manual closure and retained `/tmp/rea-usY3Kh`;
  reconnect REA before another native-provider investigation. That retained
  resource was not deleted without confirmed provider ownership release.

## Repair direction and remaining work

The framework needs signing compatibility handling before behavioral features:

- Map the relevant unavailable Instagram app-group container to a stable,
  app-owned writable location, so saved paths remain valid across launches.
- Map the exact unsupported keychain access group to an authorized app-owned
  group consistently across add, read, update, and delete operations. Preserve
  item separation and existing status/error behavior.
- Do not try to grant the development-signed app Meta's original access groups.
- Avoid globally suppressing Foundation exceptions or globally changing
  `NSString hasPrefix:`; those would hide the storage failure.

Implementation is not part of this investigation pass. No framework source or
build output was changed. An on-device manual-login, close/reopen, and
preferences-sync test is still required after a compatibility fix. Existing
credentials cannot be assumed recoverable from inaccessible keychain groups.

Checklist:

- [x] Compare crash signatures and verify matching framework build.
- [x] Locate the exact failing call and trace its prefix initialization.
- [x] Correlate app-group and keychain entitlement failures from the supplied log.
- [ ] Directly observe the exception reason and argument on the iPhone.
- [ ] Implement and validate the repair on device.
- [ ] Establish the beta-update popup's exact text and relationship to the crash.
