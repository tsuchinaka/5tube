#import "5Tube.h"

__attribute__((constructor))
void YTLoad(void) {
    YTCacheLock = [[NSLock alloc] init];
    YTPlayCache = [NSMutableDictionary dictionary];
    YTDurationCache = [NSMutableDictionary dictionary];
    YTNo720 = [NSMutableSet set];

    YTInstallCrashHandler();
    YTMigratePrefs();
    YTTrendingClasses();
    YTAuthInstall();

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    YTPrefsChanged, CFSTR("com.sokubit.5tube/reload"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    YTStartProxy();
    YTHooksInstall();
    YTCaptionStart();
    YTLog(@"loaded");
}
