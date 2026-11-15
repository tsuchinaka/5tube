#import "5Tube.h"

NSString *const YTMark = @"YTInnerHandled";
NSString *const YTPrefsID = @"com.sokubit.5tube";
NSString *const YTLegacyPrefsID = @"com.bytebox.youtubeinnertube";
NSLock *YTLogLock;
void YTLog(NSString *line) {
    if (!YTLogLock) YTLogLock = [[NSLock alloc] init];
    [YTLogLock lock];
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
    [YTLogLock unlock];
}

void YTSyncPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsID);
}

void YTMigratePrefs(void) {
    CFStringRef oldID = (__bridge CFStringRef)YTLegacyPrefsID;
    CFStringRef newID = (__bridge CFStringRef)YTPrefsID;
    CFPreferencesAppSynchronize(oldID);
    CFArrayRef keys = CFPreferencesCopyKeyList(oldID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!keys) return;
    CFIndex count = CFArrayGetCount(keys);
    for (CFIndex i = 0; i < count; i++) {
        CFStringRef key = (CFStringRef)CFArrayGetValueAtIndex(keys, i);
        CFPropertyListRef present = CFPreferencesCopyAppValue(key, newID);
        if (present) {
            CFRelease(present);
            continue;
        }
        CFPropertyListRef value = CFPreferencesCopyAppValue(key, oldID);
        if (value) {
            CFPreferencesSetAppValue(key, value, newID);
            CFRelease(value);
        }
    }
    CFRelease(keys);
    CFPreferencesAppSynchronize(newID);
    YTLog(@"prefs migrated");
}

BOOL YTPrefBool(NSString *key, BOOL fallback) {
    YTSyncPrefs();
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)YTPrefsID);
    if (!value) return fallback;
    BOOL result = fallback;
    CFTypeID type = CFGetTypeID(value);
    if (type == CFBooleanGetTypeID()) result = CFBooleanGetValue(value);
    else if (type == CFNumberGetTypeID()) {
        int number = 0;
        CFNumberGetValue(value, kCFNumberIntType, &number);
        result = number != 0;
    }
    CFRelease(value);
    return result;
}

NSString *YTPrefString(NSString *key, NSString *fallback) {
    YTSyncPrefs();
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)YTPrefsID);
    if (!value) return fallback;
    NSString *result = fallback;
    if (CFGetTypeID(value) == CFStringGetTypeID()) result = [(__bridge NSString *)value copy];
    CFRelease(value);
    return result;
}

BOOL YTWant720(void) {
    return [YTPrefString(@"quality", @"720") isEqualToString:@"720"];
}

id YTGet(id obj, NSString *key) {
    if (![obj isKindOfClass:[NSDictionary class]] || !key) return nil;
    return [(NSDictionary *)obj objectForKey:key];
}

void YTSet(NSMutableDictionary *dict, NSString *key, id value) {
    if (!dict || !key || !value) return;
    [dict setObject:value forKey:key];
}

id YTAt(NSArray *array, NSUInteger index) {
    if (index >= array.count) return nil;
    return [array objectAtIndex:index];
}

NSString *YTEscape(NSString *text) {
    if (!text.length) return @"";
    NSMutableString *out = [text mutableCopy];
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, out.length)];
    return out;
}

NSString *YTText(id node) {
    if ([node isKindOfClass:[NSString class]]) return node;
    if (![node isKindOfClass:[NSDictionary class]]) return @"";
    id simple = YTGet(node, @"simpleText");
    if ([simple isKindOfClass:[NSString class]]) return simple;
    NSMutableString *joined = [NSMutableString string];
    id runs = YTGet(node, @"runs");
    if ([runs isKindOfClass:[NSArray class]]) {
        for (id run in runs) {
            id text = YTGet(run, @"text");
            if ([text isKindOfClass:[NSString class]]) [joined appendString:text];
        }
    }
    return joined;
}

NSInteger YTSeconds(NSString *text) {
    if (!text.length) return 0;
    NSArray *parts = [text componentsSeparatedByString:@":"];
    NSInteger value = 0;
    for (NSString *part in parts) value = value * 60 + [part integerValue];
    return value;
}

NSString *YTDigits(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    NSUInteger i;
    for (i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= '0' && c <= '9') [out appendFormat:@"%C", c];
    }
    return out.length ? out : @"0";
}

NSDictionary *YTQuery(NSURL *url) {
    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    NSArray *pairs = [url.query componentsSeparatedByString:@"&"];
    for (NSString *pair in pairs) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0) continue;
        NSString *key = [pair substringToIndex:eq.location];
        NSString *raw = [pair substringFromIndex:eq.location + 1];
        NSString *value = [raw stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
        [query setObject:(value.length ? value : raw) forKey:key];
    }
    return query;
}

NSString *YTQueryEscape(NSString *text) {
    if (!text.length) return @"";
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)text, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
}

BOOL YTIsVideoID(NSString *text) {
    if ([text length] != 11) return NO;
    NSUInteger i;
    for (i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return NO;
    }
    return YES;
}

NSArray *YTIDsInBody(NSString *body) {
    NSMutableArray *ids = [NSMutableArray array];
    NSString *marker = @"/feeds/api/videos/";
    NSRange scan = NSMakeRange(0, [body length]);
    while (scan.length > 0) {
        NSRange found = [body rangeOfString:marker options:0 range:scan];
        if (found.location == NSNotFound) break;
        NSUInteger start = found.location + found.length;
        if (start + 11 <= [body length]) {
            NSString *videoID = [body substringWithRange:NSMakeRange(start, 11)];
            if (YTIsVideoID(videoID)) [ids addObject:videoID];
        }
        if (start >= [body length]) break;
        scan = NSMakeRange(start, [body length] - start);
    }
    return ids;
}

NSString *YTBodyString(NSURLRequest *request) {
    NSData *body = [request HTTPBody];
    if (![body length]) return @"";
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
}

NSString *YTFirstText(id node, int depth) {
    if (!node || depth > 6) return @"";
    if ([node isKindOfClass:[NSString class]]) return node;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *found = YTFirstText(child, depth + 1);
            if (found.length) return found;
        }
        return @"";
    }
    if (![node isKindOfClass:[NSDictionary class]]) return @"";
    NSString *simple = YTText(node);
    if (simple.length && ![simple isEqualToString:@""]) {
        id runs = YTGet(node, @"runs");
        id plain = YTGet(node, @"simpleText");
        if (plain || runs) return simple;
    }
    for (id child in [node allValues]) {
        NSString *found = YTFirstText(child, depth + 1);
        if (found.length) return found;
    }
    return @"";
}

NSString *YTAuthorFrom(NSString *text) {
    if (!text.length) return @"";
    NSRange bullet = [text rangeOfString:@"•"];
    if (bullet.location == NSNotFound) bullet = [text rangeOfString:@"·"];
    if (bullet.location != NSNotFound && bullet.location > 0) text = [text substringToIndex:bullet.location];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

id YTGlobalString(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) return nil;
    id value = *(__unsafe_unretained id *)sym;
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

void YTWriteCrash(NSString *text) {
    NSString *path = @"/var/tmp/ytinner-crash.txt";
    NSString *row = [NSString stringWithFormat:@"%@\n%@\n", [NSDate date], text ?: @""];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        handle = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [handle seekToEndOfFile];
    [handle writeData:[row dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
    YTLog([NSString stringWithFormat:@"crash %@", [text length] > 180 ? [text substringToIndex:180] : text]);
}

void YTExceptionHandler(NSException *exception) {
    NSArray *stack = [exception callStackSymbols];
    NSString *report = [NSString stringWithFormat:@"exception %@\n%@\n%@", exception.name, exception.reason, [stack componentsJoinedByString:@"\n"]];
    YTWriteCrash(report);
}

void YTSignalHandler(int sig, siginfo_t *info, void *ctx) {
    int fd = open("/var/tmp/ytinner-crash.txt", O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        char line[96];
        unsigned long fault = info ? (unsigned long)info->si_addr : 0;
        int n = snprintf(line, sizeof(line), "signal %d fault 0x%lx\n", sig, fault);
        if (n > 0) write(fd, line, (size_t)n);
        close(fd);
    }
    signal(sig, SIG_DFL);
    raise(sig);
}

void YTInstallCrashHandler(void) {
    NSSetUncaughtExceptionHandler(&YTExceptionHandler);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_sigaction = YTSignalHandler;
    action.sa_flags = SA_SIGINFO;
    sigaction(SIGABRT, &action, NULL);
    sigaction(SIGSEGV, &action, NULL);
    sigaction(SIGBUS, &action, NULL);
    sigaction(SIGILL, &action, NULL);
}

void YTHookMethod(Class cls, NSString *selName, IMP hook, IMP *orig) {
    if (!cls || !hook) return;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!method) return;
    if (method_getImplementation(method) == hook) return;
    if (orig && !*orig) *orig = method_getImplementation(method);
    method_setImplementation(method, hook);
    YTLog([NSString stringWithFormat:@"hooked %@ %@", NSStringFromClass(cls), selName]);
}

void YTStoreIvar(id obj, NSString *name, id value) {
    if (!obj || !name.length) return;
    Ivar ivar = nil;
    Class cls = [obj class];
    while (cls && !ivar) {
        ivar = class_getInstanceVariable(cls, [name UTF8String]);
        cls = class_getSuperclass(cls);
    }
    if (!ivar) return;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type || type[0] != '@') return;
    objc_setAssociatedObject(obj, ivar, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    object_setIvar(obj, ivar, value);
}
