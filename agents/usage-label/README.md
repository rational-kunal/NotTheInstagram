# Instagram usage label

The label sits at the bottom of Instagram’s main window and leaves taps and
swipes available to the app. It shows active time for the local day and the
current Monday-start week. Counting begins on first launch with the updated
framework. The totals are stored inside the installed copy of Instagram and
survive normal relaunches. The tracker saves when Instagram loses focus and
periodically during use, so an abrupt process kill can lose the latest seconds.

## Instagram 455.0.0

The existing Hopper document `Instagram.hop` shows the following methods in
the extracted Mach-O arm64 executable. The Objective-C method table and
instruction bytes in that same file corroborate the addresses and signatures.

| Address | Method on `IGTimeSpentManager` | Encoding |
| --- | --- | --- |
| `0x106320100` | `fetchDeviceDailyTimeSpentForToday` | `d16@0:8` |
| `0x106319220` | `fetchDeviceDailyTimeSpentForWeek` | `@16@0:8` |
| `0x106320090` | `fetchDeviceDailyTimeSpentForTodayWithCompletionQueue:completionHandler:` | `v32@0:8@16@?24` |
| `0x10631481c` | `fetchDeviceDailyTimeSpentForWeekWithCompletionQueue:completionHandler:` | `v32@0:8@16@?24` |

Each synchronous device getter calls its completion-queue counterpart. The
weekly result’s object schema and the managers’ behavior under sideloading
remain unverified. The label uses public UIKit activity notifications and
its own local totals.
[UIApplication activity](https://developer.apple.com/documentation/uikit/uiapplication/didbecomeactivenotification)

The bundle plist has no scene manifest. The Mach-O declares
`-[IGAppDelegate window]`, `applicationDidBecomeActive:`, and
`applicationWillResignActive:`. The label attaches to the delegate’s window
and can also find a foreground scene’s normal key window.

## Integration and verification

The [source](../../NotTheInstagramFrameworkCode/NotTheInstagramFrameworkCode/Features/UsageLabel.m)
is part of the framework’s `Features/` folder. Xcode’s synchronized group
picks it up automatically.

The standard build script produced the arm64
[device framework](../../latest-framework/NotTheInstagramFrameworkCode.framework)
for Sideloadly. The resulting binary includes the usage label.

The arm64 iOS source passed a strict Clang check. Eleven Foundation assertions
passed, covering local midnight, Monday rollover, the 23-hour daylight-saving
day, the current-week sum, restoring totals from defaults, and duration text.
On-device verification is pending. Check the badge on Home, Reels, and an
Instagram modal on the device. After a minute with Instagram in the
background, bring it forward and verify that the totals only grew while it
was active. Relaunch and confirm the saved total.
