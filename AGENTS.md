# Project

This experimental project aims to reduce addictive Instagram behaviors
through an injected framework.

There should be minimal impact on the user experience apart from the intended behavior changes, and the framework should be designed to be as robust as possible.

- Xcode project: `NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode.xcodeproj`
- Decrypted app files: `original-decrypted-ipa/<version>/`
- Agent notes: `agents/`

The intended workflow is to build the framework as an XCFramework, inject
it into Instagram with Sideloadly, and refine it using the user's on-device
test results. Do not assume an on-device test has passed without evidence.
Run `./scripts/build-framework.sh` to build the iOS device framework at
`latest-framework/NotTheInstagramFrameworkCode.framework` for Sideloadly.
Building the shared Xcode scheme also runs this script as a post-action.
