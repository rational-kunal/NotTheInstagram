# Project

This experimental project aims to reduce addictive Instagram behaviors
through an injected framework.

There should be minimal impact on the user experience apart from the intended behavior changes, and the framework should be designed to be as robust as possible.

- Xcode project: `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode.xcodeproj`
- Decrypted app files: `original-decrypted-ipa/<version>/`
- Agent notes: `agents/`

Do not create, modify, move, or delete files outside `agents/` without explicit
user permission. Keep agent-generated notes, plans, lessons, and reference
material inside `agents/` by default.

The intended workflow is to build the framework as an XCFramework, inject
it into Instagram with Sideloadly, and refine it using the user's on-device
test results. Do not assume an on-device test has passed without evidence.
Run `./scripts/build-framework.sh` to build the iOS device framework at
`latest-framework/NotTheInstagramFrameworkCode.framework` for Sideloadly.
Building the shared Xcode scheme also runs this script as a post-action.

For Hopper analysis, open the extracted `Payload/Instagram.app/Instagram`
executable, not the IPA. Use the Mach-O loader and ARM64 architecture; keep
automatic analysis and Objective-C, Swift, and exception parsing enabled.
Leave the two procedure/branch assumptions disabled.
For version 455.0.0, the executable is at
`original-decrypted-ipa/455.0.0/com.burbn.instagram-455.0.0-Decrypted/Payload/Instagram.app/Instagram`.
