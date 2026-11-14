#import "YTAuth.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface YTCodeDelegate : NSObject <UIAlertViewDelegate>
@end

static NSString *const YTAuthPrefs = @"com.sokubit.5tube";
static NSString *const YTAuthClient = @"861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com";
static NSString *const YTAuthSecret = @"SboVhoG9s0rNafixCSGGKXAT";
static NSString *const YTAuthScope = @"https://www.googleapis.com/auth/youtube";

static NSLock *YTAuthLock;
static NSInteger YTLoginGen;
static BOOL YTLoginBusy;
static NSInteger YTLoginInterval;
static NSTimeInterval YTLoginDeadline;
static NSString *YTDeviceCode;
static NSString *YTTokenURL;
static NSString *YTGrantType;
static NSString *YTDeviceField;
static NSString *YTCachedAccess;
static NSTimeInterval YTCachedExp;
static BOOL YTSignedValid;
static BOOL YTSignedValue;
static UIAlertView *YTCodeAlert;
static YTCodeDelegate *YTCodeOwner;

static void YTAuthLog(NSString *line) {
    NSString *path = @"/var/tmp/ytinner.log";
    NSString *row = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line ?: @""];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static void YTAuthSync(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTAuthPrefs);
}

static void YTAuthSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, value ? (__bridge CFPropertyListRef)value : NULL, (__bridge CFStringRef)YTAuthPrefs);
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTAuthPrefs);
    YTSignedValid = NO;
}

static id YTAuthGet(NSString *key) {
    YTAuthSync();
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)YTAuthPrefs);
    if (!value) return nil;
    id obj = (__bridge_transfer id)value;
    return obj;
}

static NSString *YTAuthString(NSString *key) {
    id value = YTAuthGet(key);
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static BOOL YTAuthFlag(NSString *key) {
    id value = YTAuthGet(key);
    if ([value isKindOfClass:[NSNumber class]]) return [value boolValue];
    return NO;
}

BOOL YTAuthSignedIn(void) {
    if (!YTSignedValid) {
        YTSignedValue = [YTAuthString(@"refreshToken") length] > 0;
        YTSignedValid = YES;
    }
    return YTSignedValue;
}

static NSString *YTFormEscape(NSString *text) {
    if (!text.length) return @"";
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)text, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
}

static NSDictionary *YTForm(NSString *urlString, NSDictionary *fields) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in fields) {
        id raw = [fields objectForKey:key];
        if (![key isKindOfClass:[NSString class]] || ![raw isKindOfClass:[NSString class]]) continue;
        [parts addObject:[NSString stringWithFormat:@"%@=%@", YTFormEscape(key), YTFormEscape(raw)]];
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:25];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"https://www.youtube.com" forHTTPHeaderField:@"Origin"];
    [request setValue:@"https://www.youtube.com/tv" forHTTPHeaderField:@"Referer"];
    [request setHTTPBody:[[parts componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding]];
    NSURLResponse *response = nil;
    NSError *error = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (!data.length) {
        YTAuthLog([NSString stringWithFormat:@"auth http %ld %@", (long)code, [urlString lastPathComponent]]);
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:[NSDictionary class]]) {
        YTAuthLog([NSString stringWithFormat:@"auth bad %ld %@", (long)code, [urlString lastPathComponent]]);
        return nil;
    }
    id err = [json objectForKey:@"error"];
    if (err) YTAuthLog([NSString stringWithFormat:@"auth %@ %@", [urlString lastPathComponent], err]);
    return json;
}

static void YTTell(id obj, int depth, NSArray *names) {
    if (!obj || depth > 5) return;
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if (![obj respondsToSelector:sel]) continue;
        YTAuthLog([NSString stringWithFormat:@"tell %@ %@", NSStringFromClass([obj class]), name]);
        ((void (*)(id, SEL))objc_msgSend)(obj, sel);
    }
    if ([obj respondsToSelector:@selector(viewControllers)]) {
        id kids = ((id (*)(id, SEL))objc_msgSend)(obj, @selector(viewControllers));
        if ([kids isKindOfClass:[NSArray class]]) {
            for (id kid in kids) YTTell(kid, depth + 1, names);
        }
    }
    if ([obj respondsToSelector:@selector(topViewController)]) {
        YTTell(((id (*)(id, SEL))objc_msgSend)(obj, @selector(topViewController)), depth + 1, names);
    }
    if ([obj respondsToSelector:@selector(rootViewController)]) {
        YTTell(((id (*)(id, SEL))objc_msgSend)(obj, @selector(rootViewController)), depth + 1, names);
    }
}

static id YTSharedAuth(void) {
    Class cls = NSClassFromString(@"YTAccountAuthenticator");
    SEL sel = @selector(sharedAuthenticator);
    if (!cls || ![cls respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, sel);
}

static BOOL YTApplying;

static void YTAuthApplyUI(void) {
    if (YTApplying) return;
    YTApplying = YES;
    NSString *name = YTAuthString(@"accountName");
    if (!name.length) name = @"YouTube";
    id auth = YTSharedAuth();
    if (auth) {
        if ([auth respondsToSelector:@selector(setAccount:)])
            ((void (*)(id, SEL, id))objc_msgSend)(auth, @selector(setAccount:), name);
        if ([auth respondsToSelector:@selector(setAccountYouTubeName:)])
            ((void (*)(id, SEL, id))objc_msgSend)(auth, @selector(setAccountYouTubeName:), name);
        if ([auth respondsToSelector:@selector(setAccountToken:)])
            ((void (*)(id, SEL, id))objc_msgSend)(auth, @selector(setAccountToken:), @"ytinner");
        if ([auth respondsToSelector:@selector(setAccountTokenDate:)])
            ((void (*)(id, SEL, id))objc_msgSend)(auth, @selector(setAccountTokenDate:), [NSDate date]);
        Ivar password = class_getInstanceVariable([auth class], "_password");
        if (password && ivar_getTypeEncoding(password) && ivar_getTypeEncoding(password)[0] == '@' && !object_getIvar(auth, password)) {
            objc_setAssociatedObject(auth, password, @"", OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            object_setIvar(auth, password, @"");
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTAccountAuthenticatorDidAuthenticateNotification" object:auth];
    YTApplying = NO;
}

static void YTAuthApplySoon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ YTAuthApplyUI(); });
}

static NSString *YTFetchName(NSString *token) {
    if (!token.length) return @"";
    NSString *urlString = @"https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true&key=AIzaSyAd-YEOqZz9nXVzGtn3KWzYLbLaajhqIDA";
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:NULL error:NULL];
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    id items = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"items"] : nil;
    if (![items isKindOfClass:[NSArray class]] || ![items count]) return @"";
    id title = [[[items objectAtIndex:0] objectForKey:@"snippet"] objectForKey:@"title"];
    return [title isKindOfClass:[NSString class]] ? title : @"";
}

static void YTSaveToken(NSDictionary *json) {
    NSString *access = [json objectForKey:@"access_token"];
    NSString *refresh = [json objectForKey:@"refresh_token"];
    if (![access isKindOfClass:[NSString class]] || !access.length) return;
    if (![refresh isKindOfClass:[NSString class]] || !refresh.length) refresh = YTAuthString(@"refreshToken");
    NSInteger expires = [[json objectForKey:@"expires_in"] integerValue];
    if (expires < 60) expires = 3600;
    YTCachedAccess = access;
    YTCachedExp = [[NSDate date] timeIntervalSince1970] + expires - 60;
    YTAuthSet(@"accessToken", access);
    if (refresh.length) YTAuthSet(@"refreshToken", refresh);
    YTAuthSet(@"tokenExpiry", [NSString stringWithFormat:@"%.0f", YTCachedExp]);
    NSString *name = YTFetchName(access);
    if (!name.length) name = YTAuthString(@"accountName");
    if (!name.length) name = @"YouTube";
    YTAuthSet(@"accountName", name);
    YTAuthSet(@"loginState", [NSString stringWithFormat:@"Signed in %@", name]);
    YTAuthSet(@"userCode", @"");
    YTAuthSet(@"wantLogin", [NSNumber numberWithBool:NO]);
    YTSignedValue = YES;
    YTSignedValid = YES;
    YTAuthLog([NSString stringWithFormat:@"login ok %@", name]);
}

NSString *YTAuthAccess(void) {
    if (!YTAuthSignedIn()) return nil;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (YTCachedAccess.length && YTCachedExp > now) return YTCachedAccess;
    if (!YTAuthLock) YTAuthLock = [[NSLock alloc] init];
    [YTAuthLock lock];
    if (YTCachedAccess.length && YTCachedExp > [[NSDate date] timeIntervalSince1970]) {
        NSString *hit = YTCachedAccess;
        [YTAuthLock unlock];
        return hit;
    }
    NSString *refresh = YTAuthString(@"refreshToken");
    NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:
                            YTAuthClient, @"client_id",
                            YTAuthSecret, @"client_secret",
                            refresh ?: @"", @"refresh_token",
                            @"refresh_token", @"grant_type", nil];
    NSDictionary *json = YTForm(@"https://www.youtube.com/o/oauth2/token", fields);
    if (![[json objectForKey:@"access_token"] isKindOfClass:[NSString class]])
        json = YTForm(@"https://oauth2.googleapis.com/token", fields);
    if ([[json objectForKey:@"access_token"] isKindOfClass:[NSString class]]) YTSaveToken(json);
    NSString *access = YTCachedAccess;
    [YTAuthLock unlock];
    return access;
}

static void YTShowFail(NSString *message) {
    YTAuthSet(@"loginState", message ?: @"Sign-in failed");
    YTAuthSet(@"userCode", @"");
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"YouTube" message:message delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [alert show];
}

static void YTPoll(NSInteger gen);

static void YTFinishLogin(NSDictionary *json) {
    YTSaveToken(json);
    YTDeviceCode = nil;
    YTLoginBusy = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (YTCodeAlert) {
            [YTCodeAlert dismissWithClickedButtonIndex:1 animated:YES];
            YTCodeAlert = nil;
        }
        NSString *name = YTAuthString(@"accountName");
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Signed in" message:(name.length ? name : @"YouTube") delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alert show];
        YTAuthApplyUI();
    });
}

static void YTPoll(NSInteger gen) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(YTLoginInterval * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (gen != YTLoginGen) return;
        if ([[NSDate date] timeIntervalSince1970] > YTLoginDeadline || !YTDeviceCode.length) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != YTLoginGen) return;
                YTLoginBusy = NO;
                YTShowFail(@"Code expired. Tap Sign In again.");
            });
            return;
        }
        NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:
                                YTAuthClient, @"client_id",
                                YTAuthSecret, @"client_secret",
                                YTDeviceCode, YTDeviceField ?: @"code",
                                YTGrantType ?: @"http://oauth.net/grant_type/device/1.0", @"grant_type", nil];
        NSDictionary *json = YTForm(YTTokenURL ?: @"https://www.youtube.com/o/oauth2/token", fields);
        NSString *access = [json objectForKey:@"access_token"];
        NSString *err = [json objectForKey:@"error"];
        if ([access isKindOfClass:[NSString class]] && access.length) {
            YTFinishLogin(json);
            return;
        }
        if ([err isEqualToString:@"slow_down"]) YTLoginInterval += 5;
        if ([err isEqualToString:@"access_denied"] || [err isEqualToString:@"expired_token"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != YTLoginGen) return;
                YTLoginBusy = NO;
                YTDeviceCode = nil;
                YTShowFail(@"Sign-in was denied or the code expired.");
            });
            return;
        }
        YTPoll(gen);
    });
}

@implementation YTCodeDelegate
- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == alertView.cancelButtonIndex) {
        YTLoginGen++;
        YTLoginBusy = NO;
        YTDeviceCode = nil;
        YTAuthSet(@"userCode", @"");
        YTAuthSet(@"loginState", YTAuthSignedIn() ? [NSString stringWithFormat:@"Signed in %@", YTAuthString(@"accountName")] : @"Signed out");
        YTAuthLog(@"login cancelled");
    }
}
@end

static void YTShowCode(NSString *code, NSString *page, NSInteger tries) {
    if (![[UIApplication sharedApplication] keyWindow] && tries < 8) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTShowCode(code, page, tries + 1);
        });
        return;
    }
    if (!YTCodeOwner) YTCodeOwner = [YTCodeDelegate new];
    NSString *message = [NSString stringWithFormat:@"Open youtube.com/activate\nor %@\n\nEnter this code, then come back.", page.length ? page : @"google.com/device"];
    YTCodeAlert = [[UIAlertView alloc] initWithTitle:code message:message delegate:YTCodeOwner cancelButtonTitle:@"Cancel" otherButtonTitles:@"OK", nil];
    [YTCodeAlert show];
    YTAuthLog([NSString stringWithFormat:@"login code %@", code]);
}

void YTAuthBegin(void) {
    if (YTAuthSignedIn()) {
        YTAuthApplySoon();
        return;
    }
    if (YTLoginBusy) return;
    YTLoginBusy = YES;
    NSInteger gen = ++YTLoginGen;
    YTAuthSet(@"wantLogin", [NSNumber numberWithBool:NO]);
    YTAuthSet(@"loginState", @"Waiting for code");
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *fields = [NSDictionary dictionaryWithObjectsAndKeys:YTAuthClient, @"client_id", YTAuthScope, @"scope", nil];
        NSDictionary *json = YTForm(@"https://www.youtube.com/o/oauth2/device/code", fields);
        BOOL modern = NO;
        if (![[json objectForKey:@"user_code"] isKindOfClass:[NSString class]]) {
            json = YTForm(@"https://oauth2.googleapis.com/device/code", fields);
            modern = YES;
        }
        NSString *code = [json objectForKey:@"user_code"];
        NSString *device = [json objectForKey:@"device_code"];
        NSString *page = [json objectForKey:@"verification_url"];
        NSInteger interval = [[json objectForKey:@"interval"] integerValue];
        NSInteger expires = [[json objectForKey:@"expires_in"] integerValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (gen != YTLoginGen) return;
            if (![code isKindOfClass:[NSString class]] || !code.length || ![device isKindOfClass:[NSString class]]) {
                YTLoginBusy = NO;
                YTShowFail(@"Could not get a sign-in code.");
                return;
            }
            YTDeviceCode = device;
            YTTokenURL = modern ? @"https://oauth2.googleapis.com/token" : @"https://www.youtube.com/o/oauth2/token";
            YTGrantType = modern ? @"urn:ietf:params:oauth:grant-type:device_code" : @"http://oauth.net/grant_type/device/1.0";
            YTDeviceField = modern ? @"device_code" : @"code";
            YTLoginInterval = interval >= 5 ? interval : 5;
            YTLoginDeadline = [[NSDate date] timeIntervalSince1970] + (expires > 30 ? expires : 1800);
            YTAuthSet(@"userCode", code);
            YTShowCode(code, [page isKindOfClass:[NSString class]] ? page : @"https://www.google.com/device", 0);
            YTPoll(gen);
        });
    });
}

static void YTAuthForget(void) {
    YTLoginGen++;
    YTLoginBusy = NO;
    YTDeviceCode = nil;
    YTCachedAccess = nil;
    YTCachedExp = 0;
    YTAuthSet(@"refreshToken", @"");
    YTAuthSet(@"accessToken", @"");
    YTAuthSet(@"tokenExpiry", @"0");
    YTAuthSet(@"accountName", @"");
    YTAuthSet(@"userCode", @"");
    YTAuthSet(@"loginState", @"Signed out");
    YTAuthSet(@"wantLogin", [NSNumber numberWithBool:NO]);
    YTSignedValue = NO;
    YTSignedValid = YES;
    YTAuthLog(@"login cleared");
}

static BOOL YTOwns(Class cls, SEL sel) {
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return NO;
    Class sup = class_getSuperclass(cls);
    Method parent = sup ? class_getInstanceMethod(sup, sel) : NULL;
    return method != parent;
}

static void YTHookOwned(const char *selName, IMP hook, IMP *orig) {
    SEL sel = sel_registerName(selName);
    int count = objc_getClassList(NULL, 0);
    if (count < 1) return;
    Class *list = (Class *)malloc(sizeof(Class) * count);
    count = objc_getClassList(list, count);
    int i;
    for (i = 0; i < count; i++) {
        if (!YTOwns(list[i], sel)) continue;
        Method method = class_getInstanceMethod(list[i], sel);
        IMP imp = method_getImplementation(method);
        if (imp == hook) continue;
        if (orig && !*orig) *orig = imp;
        method_setImplementation(method, hook);
        YTAuthLog([NSString stringWithFormat:@"hooked %s %s", class_getName(list[i]), selName]);
    }
    free(list);
}

static void (*YTOrigSignInOut)(id, SEL);
static void YTHookSignInOut(id self, SEL cmd) {
    if (YTAuthSignedIn()) {
        if (YTOrigSignInOut) YTOrigSignInOut(self, cmd);
        return;
    }
    YTAuthLog(@"signIn button");
    YTAuthBegin();
}

static void YTHookLoginPopup(id self, SEL cmd) {
    YTAuthLog(@"loginPopup");
    YTAuthBegin();
}

static void YTHookNeeds(id self, SEL cmd, id auth) {
    YTAuthLog(@"needsAccount");
    YTAuthBegin();
}

static id YTHookDialog(id self, SEL cmd, id target, SEL action) {
    YTAuthLog(@"authDialog");
    YTAuthBegin();
    return nil;
}

static void YTHookSetPassword(id self, SEL cmd, id account, id password) {
    YTAuthLog([NSString stringWithFormat:@"setAccount %@", account ?: @""]);
    if (YTAuthSignedIn()) YTAuthApplySoon();
    else YTAuthBegin();
}

static void YTHookValidate(id self, SEL cmd, id account, id password) {
    YTAuthLog([NSString stringWithFormat:@"validate %@", account ?: @""]);
    if (YTAuthSignedIn()) YTAuthApplySoon();
    else YTAuthBegin();
}

static void (*YTOrigClear)(id, SEL);
static void YTHookClear(id self, SEL cmd) {
    YTAuthForget();
    if (YTOrigClear && YTOrigClear != (void *)YTHookClear) YTOrigClear(self, cmd);
}

static void (*YTOrigSignedOut)(id, SEL);
static void YTHookSignedOut(id self, SEL cmd) {
    YTAuthForget();
    if (YTOrigSignedOut && YTOrigSignedOut != (void *)YTHookSignedOut) YTOrigSignedOut(self, cmd);
}

static void (*YTOrigStyle)(id, SEL, NSInteger);
static void YTHookStyle(id self, SEL cmd, NSInteger style) {
    if (style == 3) {
        YTAuthLog(@"blocked password alert");
        if (YTOrigStyle) YTOrigStyle(self, cmd, 0);
        YTAuthBegin();
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self respondsToSelector:@selector(dismissWithClickedButtonIndex:animated:)])
                ((void (*)(id, SEL, NSInteger, BOOL))objc_msgSend)(self, @selector(dismissWithClickedButtonIndex:animated:), 0, NO);
        });
        return;
    }
    if (YTOrigStyle) YTOrigStyle(self, cmd, style);
}

static BOOL YTHookIsAuthed(id self, SEL cmd) {
    return YTAuthSignedIn();
}

static id YTHookDevToken(id self, SEL cmd) {
    return @"ytinner";
}

static void YTHookDeviceAuth(id self, SEL cmd) {
    if (![NSStringFromClass([self class]) isEqualToString:@"YTDeviceAuthenticator"]) return;
    YTAuthLog(@"device auth skipped");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTDeviceAuthenticatorDidAuthenticateNotification" object:self];
}

static void YTHookDeviceFail(id self, SEL cmd, int code) {
    if (![NSStringFromClass([self class]) isEqualToString:@"YTDeviceAuthenticator"]) return;
    YTAuthLog([NSString stringWithFormat:@"device fail %d skipped", code]);
    [[NSNotificationCenter defaultCenter] postNotificationName:@"YTDeviceAuthenticatorDidAuthenticateNotification" object:self];
}

static NSTimeInterval YTLastConnectAlert;
static void (*YTOrigPresent)(id, SEL, id);
static void YTHookPresent(id self, SEL cmd, id error) {
    NSString *domain = [error respondsToSelector:@selector(domain)] ? ((id (*)(id, SEL))objc_msgSend)(error, @selector(domain)) : nil;
    if ([domain isEqualToString:@"YTDeviceAuthenticatorErrorDomain"] || [domain isEqualToString:@"YTAccountAuthenticatorErrorDomain"]) {
        YTAuthLog([NSString stringWithFormat:@"drop alert %@", domain]);
        return;
    }
    id failing = nil;
    if ([error respondsToSelector:@selector(userInfo)]) {
        id info = ((id (*)(id, SEL))objc_msgSend)(error, @selector(userInfo));
        if ([info isKindOfClass:[NSDictionary class]]) {
            failing = [info objectForKey:@"NSErrorFailingURLStringKey"];
            if (!failing) failing = [info objectForKey:@"NSErrorFailingURLKey"];
            if (failing && ![failing isKindOfClass:[NSString class]] && [failing respondsToSelector:@selector(absoluteString)])
                failing = [failing absoluteString];
        }
    }
    NSString *low = [failing lowercaseString] ?: @"";
    if ([low rangeOfString:@"applelogin"].location != NSNotFound || [low rangeOfString:@"youtube/accounts"].location != NSNotFound || [low rangeOfString:@"gdata.youtube.com"].location != NSNotFound) {
        YTAuthLog(@"drop alert dead host");
        return;
    }
    if ([domain isEqualToString:@"NSURLErrorDomain"] || [domain isEqualToString:@"XMLHTTPRequestErrorDomain"]) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (now - YTLastConnectAlert < 20) return;
        YTLastConnectAlert = now;
        YTAuthLog([NSString stringWithFormat:@"connect alert %@", domain]);
    }
    if (YTOrigPresent) YTOrigPresent(self, cmd, error);
}

static void YTLoginNote(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    YTSignedValid = NO;
    if (YTAuthFlag(@"wantLogin")) {
        dispatch_async(dispatch_get_main_queue(), ^{ YTAuthBegin(); });
    }
}

static void YTSignOutNote(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    YTAuthForget();
    dispatch_async(dispatch_get_main_queue(), ^{
        id auth = YTSharedAuth();
        if (auth && YTOrigClear) YTOrigClear(auth, @selector(clearAccountInfo));
        id app = [UIApplication sharedApplication];
        YTTell([app delegate], 0, [NSArray arrayWithObjects:@"didSignOut", @"userSignedOutOfAccount", @"_updateAfterSingInOrSignOut", nil]);
        id window = [app keyWindow];
        if ([window respondsToSelector:@selector(rootViewController)])
            YTTell([window rootViewController], 0, [NSArray arrayWithObjects:@"didSignOut", @"userSignedOutOfAccount", nil]);
    });
}

void YTAuthInstall(void) {
    static BOOL done = NO;
    YTHookOwned("isAccountAuthenticated", (IMP)YTHookIsAuthed, NULL);
    YTHookOwned("_signInOutPressed", (IMP)YTHookSignInOut, (IMP *)&YTOrigSignInOut);
    YTHookOwned("_loginPopup", (IMP)YTHookLoginPopup, NULL);
    YTHookOwned("presentAlertForError:", (IMP)YTHookPresent, (IMP *)&YTOrigPresent);
    YTHookOwned("authenticatorNeedsAccountAndPassword:", (IMP)YTHookNeeds, NULL);
    YTHookOwned("authenticationDialogWithTarget:action:", (IMP)YTHookDialog, NULL);
    YTHookOwned("setAccount:password:", (IMP)YTHookSetPassword, NULL);
    YTHookOwned("validateAccount:password:", (IMP)YTHookValidate, NULL);
    YTHookOwned("_authRequestForAccount:password:", (IMP)YTHookSetPassword, NULL);
    YTHookOwned("_getNewTokenForAccount:password:", (IMP)YTHookValidate, NULL);
    YTHookOwned("clearAccountInfo", (IMP)YTHookClear, (IMP *)&YTOrigClear);
    YTHookOwned("didSignOut", (IMP)YTHookSignedOut, (IMP *)&YTOrigSignedOut);
    YTHookOwned("userSignedOutOfAccount", (IMP)YTHookSignedOut, (IMP *)&YTOrigSignedOut);
    Class deviceAuth = NSClassFromString(@"YTDeviceAuthenticator");
    Method auth = class_getInstanceMethod(deviceAuth, @selector(authenticate));
    if (auth && method_getImplementation(auth) != (IMP)YTHookDeviceAuth)
        method_setImplementation(auth, (IMP)YTHookDeviceAuth);
    Method fail = class_getInstanceMethod(deviceAuth, @selector(_failWithErrorCode:));
    if (fail && method_getImplementation(fail) != (IMP)YTHookDeviceFail)
        method_setImplementation(fail, (IMP)YTHookDeviceFail);
    Method token = class_getInstanceMethod(deviceAuth, @selector(token));
    if (token && method_getImplementation(token) != (IMP)YTHookDevToken)
        method_setImplementation(token, (IMP)YTHookDevToken);
    Class alert = [UIAlertView class];
    Method style = class_getInstanceMethod(alert, @selector(setAlertViewStyle:));
    if (style && method_getImplementation(style) != (IMP)YTHookStyle) {
        if (!YTOrigStyle) YTOrigStyle = (void (*)(id, SEL, NSInteger))method_getImplementation(style);
        method_setImplementation(style, (IMP)YTHookStyle);
    }
    if (done) return;
    done = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, YTLoginNote, CFSTR("com.sokubit.5tube/login"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, YTSignOutNote, CFSTR("com.sokubit.5tube/signout"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    if (YTAuthFlag(@"wantLogin")) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTAuthBegin();
        });
    } else if (YTAuthSignedIn()) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            YTAuthApplyUI();
        });
    }
}
