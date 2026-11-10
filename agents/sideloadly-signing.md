# Sideloadly signing — 2026-11-10

Sideloadly 0.72 failed certificate creation with Apple error 7460, then
failed its attempt to revoke the Xcode Apple Development certificate with
error 7252. The account also had an iOS Development certificate from iloader.

With explicit user approval, revoked only iloader's iOS Development certificate
using iloader's Certificates screen. Kept the Xcode Apple Development
certificate. Retrying Sideloadly on the same Apple Account then succeeded:
its UI reported `Done. 100%` when installing Instagram 455.0.0 with
`latest-framework/NotTheInstagramFrameworkCode.framework` attached.

Apps previously signed with the revoked iloader certificate may need to be
signed again. The hello-world alert and Instagram's on-device behavior still
require the user's verification; installation success alone does not prove
framework loading or app launch success.
