#import <UIKit/UIKit.h>
#import "../Diagnostics/FLEXIntegration.h"
#import "../Runtime/RuntimeHooks.h"

static NSString *const UsageDefaultsKey = @"com.not-the-instagram.usage-label.daily-seconds.v1";

static NSString *NTIUsageDayKey(NSCalendar *calendar, NSDate *date) {
    NSDateComponents *day = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
                                         fromDate:date];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld", (long)day.year, (long)day.month, (long)day.day];
}

static void NTIUsageRecord(NSMutableDictionary<NSString *, NSNumber *> *days, NSCalendar *calendar,
                           NSDate *end, NSTimeInterval elapsed) {
    if (elapsed <= 0) return;
    NSDate *cursor = [end dateByAddingTimeInterval:-elapsed];
    while ([cursor compare:end] == NSOrderedAscending) {
        NSDate *dayStart;
        NSTimeInterval dayLength;
        if (![calendar rangeOfUnit:NSCalendarUnitDay startDate:&dayStart interval:&dayLength forDate:cursor]) break;
        NSDate *nextDay = [dayStart dateByAddingTimeInterval:dayLength];
        NSDate *segmentEnd = [nextDay earlierDate:end];
        NSString *key = NTIUsageDayKey(calendar, cursor);
        days[key] = @(days[key].doubleValue + [segmentEnd timeIntervalSinceDate:cursor]);
        cursor = segmentEnd;
    }
}

static NSTimeInterval NTIUsageWeekTotal(NSDictionary<NSString *, NSNumber *> *days, NSCalendar *calendar,
                                      NSDate *date) {
    NSDate *weekStart;
    if (![calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&weekStart interval:NULL forDate:date]) return 0;
    NSTimeInterval total = 0;
    NSDate *day = weekStart;
    while (day && [day compare:date] != NSOrderedDescending) {
        total += days[NTIUsageDayKey(calendar, day)].doubleValue;
        day = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:day options:0];
    }
    return total;
}

static NSString *NTIUsageDuration(NSTimeInterval seconds) {
    if (seconds < 60) return [NSString stringWithFormat:@"%lds", (long)seconds];
    NSInteger minutes = (NSInteger)(seconds / 60);
    if (minutes < 60) return [NSString stringWithFormat:@"%ldm", (long)minutes];
    return [NSString stringWithFormat:@"%ldh %ldm", (long)(minutes / 60), (long)(minutes % 60)];
}

@interface NTIUsageLabel : NSObject
@property (nonatomic, strong) NSCalendar *calendar;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *days;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) UILabel *badge;
@property (nonatomic) NSTimeInterval lastSample;
@property (nonatomic) NSTimeInterval lastSave;
@end

@implementation NTIUsageLabel

+ (void)load {
    if (!NTIIsInstagram(NSBundle.mainBundle.bundleIdentifier)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static NTIUsageLabel *usage;
        usage = [self new];
        [usage install];
    });
}

- (void)install {
    self.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierISO8601];
    self.calendar.timeZone = NSTimeZone.localTimeZone;
    self.days = [NSUserDefaults.standardUserDefaults dictionaryForKey:UsageDefaultsKey].mutableCopy
        ?: [NSMutableDictionary new];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(startTracking:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(stopTracking:) name:UIApplicationWillResignActiveNotification object:nil];
    [center addObserver:self selector:@selector(stopTracking:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(stopTracking:) name:UIApplicationWillTerminateNotification object:nil];
    [center addObserver:self selector:@selector(windowChanged:) name:UIWindowDidBecomeVisibleNotification object:nil];
    [center addObserver:self selector:@selector(windowChanged:) name:UIWindowDidBecomeKeyNotification object:nil];
    [center addObserver:self selector:@selector(windowChanged:) name:UISceneDidActivateNotification object:nil];

    if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) [self startTracking:nil];
}

- (void)startTracking:(NSNotification *)notification {
    if (self.timer) return;
    self.lastSample = self.lastSave = NSProcessInfo.processInfo.systemUptime;
    self.timer = [NSTimer timerWithTimeInterval:5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    self.timer.tolerance = 1;
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self windowChanged:nil];
}

- (void)stopTracking:(NSNotification *)notification {
    if (!self.timer) return;
    [self.timer invalidate];
    self.timer = nil;
    [self updateUsageAndSave:YES];
}

- (void)tick:(NSTimer *)timer {
    if (!self.badge.window || self.badge.window.hidden) [self windowChanged:nil];
    [self updateUsageAndSave:NO];
}

- (void)updateUsageAndSave:(BOOL)forceSave {
    NSDate *now = NSDate.date;
    NSTimeInterval uptime = NSProcessInfo.processInfo.systemUptime;
    NTIUsageRecord(self.days, self.calendar, now, uptime - self.lastSample);
    self.lastSample = uptime;
    if (forceSave || uptime - self.lastSave >= 15) {
        NSDate *cutoff = [self.calendar dateByAddingUnit:NSCalendarUnitDay value:-14 toDate:now options:0];
        NSString *oldestDay = NTIUsageDayKey(self.calendar, cutoff);
        for (NSString *day in self.days.allKeys) {
            if ([day compare:oldestDay] == NSOrderedAscending) [self.days removeObjectForKey:day];
        }
        [NSUserDefaults.standardUserDefaults setObject:self.days forKey:UsageDefaultsKey];
        self.lastSave = uptime;
    }
    [self updateBadgeAtDate:now];
}

- (void)windowChanged:(NSNotification *)notification {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *window = [app.delegate respondsToSelector:@selector(window)] ? app.delegate.window : nil;
    if (!window || window.hidden) {
        window = nil;
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
                if (candidate.isKeyWindow && !candidate.hidden && candidate.windowLevel == UIWindowLevelNormal) {
                    window = candidate;
                    break;
                }
            }
            if (window) break;
        }
    }
    if (!window || window == self.badge.superview) return;
    [self.badge removeFromSuperview];

    // Use the host window so the badge stays above tab changes and modal presentations.
    UILabel *badge = [UILabel new];
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    badge.userInteractionEnabled = NO;
    badge.isAccessibilityElement = YES;
    badge.font = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleCaption2]
        scaledFontForFont:[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold] maximumPointSize:15];
    badge.adjustsFontForContentSizeCategory = YES;
    badge.adjustsFontSizeToFitWidth = YES;
    badge.textAlignment = NSTextAlignmentCenter;
    badge.textColor = UIColor.whiteColor;
    badge.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.84];
    badge.layer.cornerRadius = 8;
    badge.clipsToBounds = YES;
    badge.layer.zPosition = 1000;
    [window addSubview:badge];
    self.badge = badge;
    NTISetFLEXUsageLabel(badge);
    UILayoutGuide *safeArea = window.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [badge.centerXAnchor constraintEqualToAnchor:safeArea.centerXAnchor],
        [badge.bottomAnchor constraintEqualToAnchor:window.bottomAnchor constant:-12],
        [badge.leadingAnchor constraintGreaterThanOrEqualToAnchor:safeArea.leadingAnchor constant:8],
        [badge.trailingAnchor constraintLessThanOrEqualToAnchor:safeArea.trailingAnchor constant:-8],
        [badge.heightAnchor constraintGreaterThanOrEqualToConstant:18],
    ]];
    [self updateBadgeAtDate:NSDate.date];
}

- (void)updateBadgeAtDate:(NSDate *)date {
    UILabel *badge = self.badge;
    if (!badge) return;
    NSTimeInterval today = self.days[NTIUsageDayKey(self.calendar, date)].doubleValue;
    NSTimeInterval week = NTIUsageWeekTotal(self.days, self.calendar, date);
    NSString *text = [NSString stringWithFormat:@"  Today %@  ·  This week %@  ",
                      NTIUsageDuration(today), NTIUsageDuration(week)];
    if (![badge.text isEqualToString:text]) badge.text = text;
}

@end
