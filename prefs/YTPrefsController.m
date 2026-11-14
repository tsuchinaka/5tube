#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>

static NSString *const YTPrefsDomain = @"com.bytebox.youtubeinnertube";

@interface YTPrefsController : PSListController
@end

@implementation YTPrefsController

- (NSArray *)specifiers {
    if (!self.specifiers) {
        self.specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return self.specifiers;
}

- (void)signIn {
    CFPreferencesSetAppValue(CFSTR("wantLogin"), kCFBooleanTrue, (__bridge CFStringRef)YTPrefsDomain);
    CFPreferencesSetAppValue(CFSTR("loginState"), CFSTR("Waiting for code"), (__bridge CFStringRef)YTPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.bytebox.youtubeinnertube/login"), NULL, NULL, true);
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
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.bytebox.youtubeinnertube/signout"), NULL, NULL, true);
    [self reloadSpecifiers];
}

@end
