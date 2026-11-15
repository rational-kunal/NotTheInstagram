# Project

This experimental project aims to reduce addictive Instagram behaviors
through an injected framework.

There should be minimal impact on the user experience apart from the intended behavior changes, and the framework should be designed to be as robust as possible.

- Xcode project: `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode.xcodeproj`
- Decrypted app files: `original-decrypted-ipa/<version>/`
- Agent notes: `agents/`

Make source code changes in the project's source tree and put other project
deliverables in their usual locations. Keep agent-generated notes, plans,
intermediate results, lessons, and material for future reading in `agents/`
by default.

The intended workflow is to build the framework as an XCFramework, inject
it into Instagram with Sideloadly, and refine it using the user's on-device
test results. Do not assume an on-device test has passed without evidence.
Run `./scripts/build-framework.sh` to build the iOS device framework at
`latest-framework/NotTheInstagramFrameworkCode.framework` for Sideloadly.
Building the shared Xcode scheme also runs this script as a post-action.

For Hopper analysis, reuse the existing session if the target Instagram
executable is already open in Hopper. Otherwise, open the extracted
`Payload/Instagram.app/Instagram` executable from the app bundle.
Use the Mach-O loader and ARM64 architecture, and keep
automatic analysis and Objective-C, Swift, and exception parsing enabled.
Leave the two procedure/branch assumptions disabled.
For version 455.0.0, the executable is at
`original-decrypted-ipa/455.0.0/com.burbn.instagram-455.0.0-Decrypted/Payload/Instagram.app/Instagram`.

The Hopper demo may have less than 30 minutes remaining. If the timer expires
and Hopper is still needed, pause the work that requires Hopper, ask the user
to relaunch it, and resume once Hopper is available again.
