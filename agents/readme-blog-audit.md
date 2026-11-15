# README and blog audit — 2026-11-15

Review of `README.md` and `docs/blog.md` before publishing. Claims were
checked against the source at commit `049c8e9` and the 455.0.0 IPA.

## Fact check

| Claim | Status | Evidence |
| --- | --- | --- |
| Home waits 8, 11, 14 s, then stays at 14 | Correct | `Features/HomeFeed/HomeFeedBatch.h:4` (`8 + 3 * MIN(n, 2)`) |
| Reels tab unlock after 2 min | Correct | `Features/Reels/ReelTabSession.m:5` (`120.0`) |
| Reel delay 3 s + 0.5 s each; 20th reel = 12.5 s | Correct | `ReelTabSession.m:6-7, 280` |
| FLEX: three-finger double tap, or hold label 1 s | Correct | `Diagnostics/FLEXIntegration.m:47-51` |
| Explore snippet in blog | Matches | `Features/ExploreGrid.m:63-70` |
| "~400 MB executable" | Correct | Binary is 384 MB |
| First afternoon timeline | Matches git | Commits Nov 10, 13:05 hello world to 18:01 "no next reel" |
| **README: "iPhone (iOS 15+)"** | **Wrong** | Instagram 455.0.0 `MinimumOSVersion` is **16.3**. 15.0 is only the framework's deployment target |
| **README: blog link is `TODO`** | **Placeholder** | `README.md:7` |
| Blog: "Every hook in the project goes through this check" | Overstated | Keychain calls are C functions rebound with fishhook (`StorageCompatibility.m:210`), with no signature check |
| "Checks the method's exact signature / exactly the argument and return types" | Overstated | ObjC type encodings show every object as `@`, so `NSString *` → `NSArray *` still passes. A method that keeps its signature but changes behavior is not detected either |
| "Reels from DMs play alone" | Undersells | `agents/FEATURES.md`: any reel opened outside the Reels tab (post, message, other viewer) plays alone |
| "Each feature lives in its own file under `Features/`" | Slightly off | `HomeFeed/` and `Reels/` are folders of 3-4 files |
| Quoted AGENTS.md: "build the framework as an XCFramework" | Inconsistent | Script builds a plain `.framework`. iOS developers will notice because the blog quotes this line |
| Blog's project tree | Incomplete | Leaves out `Vendor/fishhook` |
| "That one feature turns off and the app keeps working" | True but invisible | `ExploreGrid.m:70` ignores the return value and nothing logs it, so a user cannot tell which feature switched off |

Repo-level gaps:

- No `LICENSE`, even though both docs invite pull requests. FLEX and fishhook
  licenses are vendored, but the project has no license of its own.
- `README.md` and `docs/` are untracked. `docs/` is about 31 MB.
  `docs/prompt.png` (770 KB) is unused. `image.png` and `image-1.png` have
  generic names.
- The README's hero row loads about 8.8 MB (`home-feed.gif` 5.5 MB,
  `reels-pause.gif` 2.9 MB). That is slow on mobile.

## Reader by reader

### 1. Non-technical Instagram user (came from a share or tweet)

Works: the tagline, the first paragraph, the hero GIFs, the "What it changes"
table and the plain-English issue invite.

Breaks:
- They find out they can't install it only when they reach "decrypted IPA" and
  "Xcode". Say near the top that this is not an App Store app and who can
  install it.
- Open questions: Does it replace my real Instagram? Is my password safe? Will
  I get banned? How do I undo it? Does it stop working after a week?
- "FLEX for poking around" is jargon. Holding the usage label for a second
  opens a debugger, which they could do by accident.

### 2. Tech-curious hobbyist who has never sideloaded

Works: the blog's "If those words are new" paragraph (IPA, framework,
Sideloadly) is the best onboarding in either doc. The README doesn't have it.

Breaks:
- Getting a decrypted IPA is the main blocker, and both docs only say "I can't
  share it". Say plainly that they must get one themselves and why there's no
  link, so they don't think they missed a step.
- Free Apple accounts: the app must be re-signed every 7 days, and free
  accounts have a limit on sideloaded apps. Neither doc mentions this.
- The blog's "Try it yourself" lists Hopper and REA as step 1. Those are only
  needed to change features, not to use them. The README separates the two
  paths better.
- No troubleshooting section. Sideloadly certificate errors, such as the 7460
  error in `agents/sideloadly-signing.md`, are common.

### 3. iOS developer or reverse engineer

Works: the keychain story (-34018, `group.com.facebook.family`, the nil
container causing a `hasPrefix:` crash) is real and specific. The `NTIHook`
snippet is clean.

Breaks:
- The signature-check overclaim above. "Exact signature" invites a correction
  in the comments. Something like "checks the class and method exist with the
  expected argument count and type encodings" is accurate.
- "Every hook goes through this check" isn't true for the keychain rebinding.
  One sentence fixes it: keychain calls are C functions, so they're rebound
  with fishhook instead of swizzled.
- XCFramework vs `.framework`.
- They'll want to know how you inject (`+load` via Sideloadly's load command),
  why a decrypted IPA is needed (FairPlay), and how Swift classes in the home
  feed were handled (`HomeFeedPagination.m` has both ObjC and Swift
  providers). The Swift part is interesting and not mentioned.
- Name the error: -34018 is `errSecMissingEntitlement`.

### 4. AI-agent practitioner (probably the largest audience for the title)

Works: "give the agent a map" (FLEX class names leading into Hopper) is the
best takeaway in the post and is broadly useful. The `AGENTS.md` excerpt and
the "Do not assume an on-device test has passed" line are good.

Breaks:
- The title promises an AI-agent story, but "Working with the agent" is two
  short paragraphs. Readers want concrete detail: one moment the agent was
  wrong, how many sessions it took, what you'd tell someone else, what you
  still did by hand.
- "It kept going off in different directions" needs one specific example.
- Link to one real note in `agents/` (for example `agents/reel-investigation/`).
  It shows what the notes habit produces.
- REA gets one line. Say what kind of tool it is (MCP server? CLI?) and what
  the agent did with it.
- The timeline is good material: day 1 from 13:05 to 18:01 for hello world,
  crash fix, Explore and single reels; then two more sessions over five days.
  Say that directly.

### 5. Digital-wellbeing or behavior-design reader

Works: "friction, not blocking" is the strongest idea in the post. The
two-minute pause screen paragraph ("long enough to ask myself why") is the
best writing in it.

Breaks:
- **There is no result.** The post opens with "60 minutes are gone" and never
  says whether that changed. Even "my week went from ~X h to ~Y h" or "I stopped
  opening Reels at night" would close the loop.
- The usage screenshot reads "Today 1h 8m / This week 1h 8m". Without context
  a skeptic reads it as "still an hour a day". Explain it (first day of
  tracking?) or replace it.
- "It worked for a while, but it was a blunt fix." What happened? Did you
  remove it or work around it? That answer is the whole argument for v2.
- Why these numbers: 3 posts, 8 s, 2 min, +0.5 s. One sentence on the reasoning
  (or "I tuned these by feel") helps.
- Loopholes: name them honestly (stories, profile grids, search results). Also
  note that reels from posts and profiles already play alone, which answers the
  obvious "just go around it" reply.

### 6. Security- or privacy-minded skeptic

Breaks:
- You're asking people to log into a modified Instagram. Say what it doesn't do:
  no network calls (verified: no `NSURLSession` or URL code in the framework),
  usage totals stay on the device, login data stays in the iOS keychain, the
  source is all there.
- "Instagram doesn't allow modified clients" is vague. Say the realistic risk
  directly: the account could be flagged or suspended.
- A shipped debugger (FLEX) with full in-app inspection is a reasonable thing
  to question. Say it's local only and how to remove it if they don't want it.

### 7. Potential collaborator or employer

Works: the repo is tidy, the `agents/` notes show method, and the writing is clear.

Breaks:
- "I would love to chat" has no contact link. Add one.
- No license means they can't use or contribute.

## Writing and formatting

- `<u>` underlines read as links on the web. Use bold or italics.
- Blog ends with "Thank you." on its own line, which falls flat. End on the
  result, or on the friction-not-blocking idea.
- Blog `<details>` toggles: good for scanning, but images inside may still
  download. Add `loading="lazy"`, and check how `<details>` and `<video>`
  render on the target platform. If the blog is also read on GitHub, it may
  not render `<video>` from a repo path.
- Blog images use paths relative to `docs/`. They need copying or rewriting
  for the site the blog is published on.
- The README's "Each feature lives in its own file" and the blog's version say
  slightly different things. Make them match ("its own file or folder").
- Tone is good: short sentences, first person, no hype. Keep it.

## Suggested README additions

1. "Who this is for" line under the tagline.
2. Requirements: iOS 16.3+ (Instagram 455), free vs paid Apple account (7-day
   re-sign), Xcode version, internet for the first build (FLEX via SwiftPM).
3. "Privacy" line: no network, local usage data, keychain stays local.
4. "Change the numbers": `HomeFeedBatch.h:4`, `HomeFeedPagination.m:6`,
   `ReelTabSession.m:5-7`.
5. "Undo it": delete the sideloaded app, then reinstall from the App Store. Say
   whether it replaces the App Store copy (depends on the bundle ID Sideloadly
   uses).
6. "Troubleshooting": certificate errors, a feature not showing up (version
   mismatch), login prompt on first launch.
7. LICENSE.

## Before committing `docs/`

- Delete `docs/prompt.png` (unused).
- Rename `image.png` to something like `login-error.png`, and `image-1.png` to
  `flex-explore.png`.
- Compress the GIFs (gifsicle, or MP4 uploaded through GitHub's editor).
  31 MB stays in git history for good.

## Possible code follow-up

Log once (`[NTI] Explore grid disabled: signature mismatch`) when a hook
doesn't install, so "that one feature turns off" can be seen in Console and
troubleshot.
