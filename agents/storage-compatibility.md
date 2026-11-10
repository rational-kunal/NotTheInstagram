# Storage compatibility repair — 2026-11-10

Status: implemented, iOS device framework built.
The user reported that the installed repair worked on 2026-11-10. Exact test
duration and relaunch counts were not separately stated. A subsequent cleanup
removes the hello-world popup and unused hook-helper code. The cleaned build
passed local checks and the iOS device build, but has not yet received
separate on-device confirmation.

The diagnosis and its evidence limits are in
[instagram-login-crash-2026-11-10.md](instagram-login-crash-2026-11-10.md).

## Plain-language explanation

Signing an app gives it an identity. Instagram still asked for Meta's shared
storage after Sideloadly gave the installed copy your signing identity. iOS
refused those requests. It could not save/read some login information, and a
missing shared-folder path reached a string operation that crashed.

The injected framework acts as a small adapter. When those particular requests
fail, it supplies a private folder and a permitted, separate keychain group.
Login secrets stay in the iOS keychain. The framework installs this adapter
early, before Instagram remembers the missing paths for the rest of the run.

## Repeat the build and install

In Terminal, run:

```sh
cd /Users/kunalkamble/Experimental/NotTheInstagram
./scripts/build-framework.sh
```

Then use Sideloadly with the same decrypted IPA and replace its injected
framework attachment with:

```
/Users/kunalkamble/Experimental/NotTheInstagram/latest-framework/NotTheInstagramFrameworkCode.framework
```

Keep the same Apple account and bundle-ID settings, and install over the
existing app. Those settings determine the storage identity, so changing them
can require another manual login. Open Instagram, log in if asked, leave it
open for five minutes, then fully close/reopen twice.

The source is automatically included by the Xcode project's synchronized source
folder. fishhook is vendored, so future builds need no download or package setup.

## How the problem was diagnosed

1. The device console reported keychain error `-34018` and denied shared-folder
   lookups. These pointed to storage permissions after signing.
2. The `.ips` crash reports both failed in `NSString hasPrefix:` during
   preferences synchronization. Their framework build UUID matched the copy
   extracted from your IPA.
3. Focused disassembly traced the offending prefix back to the denied
   shared-folder lookup, without a nil check. A small local probe reproduced
   the same Foundation exception with a nil prefix.
4. A narrow adapter was added for those storage requests. Initial local checks
   exercised the exception path and keychain operations; your phone test then
   supplied the evidence that the repair worked in Instagram.

If an Instagram update breaks this again, capture Console output from before
launch and the matching Instagram `.ips` report. Search Console for `[NTI]`,
`-34018`, and `client is not entitled`. Original denied requests can appear
before our retry, so check whether the following `[NTI]` retry succeeded.

## Implementation

`StorageCompatibility.m` installs synchronously from `+load`, restricted to the
Instagram bundle identifier (including Sideloadly's suffix). This matters
because Instagram caches its directory prefixes with `dispatch_once`.

- `NSFileManager` retains its real container result when available. If it
  returns nil for a recognized Instagram/Meta group, the replacement creates
  `Library/Application Support/NotTheInstagram/AppGroups/<group identifier>`
  in the app's own container. Each group gets a separate persistent directory.
  Unknown groups and filesystem errors preserve the original failure.
- The four `SecItem` imports are rebound only in images inside the app bundle,
  including images loaded later. Original implementations are resolved before
  registration. The vendored Facebook fishhook helper has been reduced to its
  image-scoped API; provenance, original file hashes, local changes and BSD
  license are in `Vendor/fishhook`.
- A keychain operation is retried only when the original returns
  `errSecMissingEntitlement` and explicitly targets `group.com.facebook.family`.
  It first discovers the signing prefix through a unique empty generic-password
  probe, then probes a dedicated group named
  `<prefix>.<installed bundle identifier>.NotTheInstagram.MetaFamily`.
  Probe items are deleted immediately. This is verification of existing access,
  not a grant of additional entitlements.
- The dedicated group must actually be accepted by Security. If it is denied,
  the original error remains. There is deliberately no fallback that omits the
  access-group filter or mixes family items with normal default-group items.
  The recorded development entitlements contain a team-prefixed wildcard;
  initial local checks simulated acceptance and rejection. The user reported success
  with the installed repair; future signing configurations still need testing.
- Successful original calls, unrelated groups, query contents, return values,
  CF ownership, and ordinary authentication failures are preserved. Diagnostics
  use `[NTI]` and never include credentials, accounts or query dictionaries.

This does not recover credentials from Meta's original inaccessible keychain
group. One manual login may be necessary after installing the new framework.
It also does not provide sharing with other Meta apps or separately running
extensions that have not loaded this framework.

## Verification history

Before removal, the local harness reproduced the nil-prefix exception and
validated the folder fallback, persistence across process launches, and
keychain retries using simulated Security results. It did not access the user's
real keychain or establish real Instagram login success. The user subsequently
reported that the installed repair worked on-device.

The local test harness and its runner were removed at the user's request.
Follow the on-device steps below when verifying future builds.

Build with `./scripts/build-framework.sh`. The device artifact is
`latest-framework/NotTheInstagramFrameworkCode.framework`.

## On-device test

1. Replace the framework attachment in Sideloadly with the newly built artifact.
   Install over the existing app using the same Apple account and bundle-ID
   settings, preserving its data.
2. Launch and manually log in if required. Leave it open for at least five
   minutes, including past any beta/update popup. The previous reports failed
   during background preferences synchronization, sometimes minutes after launch.
3. Fully close and reopen twice. Report whether automatic login succeeds and
   whether the crash returns.
4. If it fails, capture the log from before launch. Relevant `[NTI]` messages:
   `storage compatibility initialized`, `using persistent app-owned container`,
   `keychain compatibility using verified app-owned group`, or an
   `access-group probe failed` status. Original denied calls can still appear
   because the layer tries the original first. Group verification confirms
   access to the replacement storage; the login/reopen test verifies the full flow.

The hello-world alert was removed after the successful device report. The
`[NTI] storage compatibility initialized` log is the loading indicator.

## Cleanup scope

- The runtime consists of `StorageCompatibility.m` and the image-scoped
  fishhook helper. No hello-world UI remains.
- Removed fishhook's unused process-wide API, linked-list allocation, saved
  original-pointer output and inactive code. Kept the original symbol matching
  and pointer-write protection approach; protection failures now reach the log.
- Kept startup/fallback messages, one successful keychain-group verification
  message, and discovery/installation errors. Removed per-operation log tracking.
  Credentials are never logged.
- The repair's directory layout and keychain-group naming remain unchanged,
  preserving the storage used by the successfully tested build.
