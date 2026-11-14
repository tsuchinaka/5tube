#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

static NSString *const YTPrefsDomain = @"com.sokubit.5tube";

@interface YTPrefsController : PSListController
@end

@implementation YTPrefsController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)signIn {
    CFPreferencesSetAppValue(CFSTR("wantLogin"), kCFBooleanTrue, (__bridge CFStringRef)YTPrefsDomain);
    CFPreferencesSetAppValue(CFSTR("loginState"), CFSTR("Waiting for code"), (__bridge CFStringRef)YTPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.sokubit.5tube/login"), NULL, NULL, true);
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"youtube://"]];
}

- (void)signOut {
    NSArray *keys = [NSArray arrayWithObjects:@"refreshToken", @"accessToken", @"tokenExpiry", @"accountName", @"userCode", nil];
    for (NSString *key in keys) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, CFSTR(""), (__bridge CFStringRef)YTPrefsDomain);
    }
    CFPreferencesSetAppValue(CFSTR("wantLogin"), kCFBooleanFalse, (__bridge CFStringRef)YTPrefsDomain);
    CFPreferencesSetAppValue(CFSTR("loginState"), CFSTR("Signed out"), (__bridge CFStringRef)YTPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.sokubit.5tube/signout"), NULL, NULL, true);
    [self reloadSpecifiers];
}

@end
