#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdlib.h>
#import <errno.h>
#import <signal.h>
#import <unistd.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>
#import <stdio.h>
#import "YTMux.h"
#import "YTAuth.h"
#import <dlfcn.h>

// iOS 5.1 YouTube.app reads Atom from gdata.youtube.com. That API is dead.
// This protocol answers those requests with Atom built from InnerTube, so the
// existing parser, lists and movie player keep working.

static NSString *const YTMark = @"YTInnerHandled";
static NSString *const YTKey = @"AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w";
static NSString *const YTTVKey = @"AIzaSyAd-YEOqZz9nXVzGtn3KWzYLbLaajhqIDA";
static NSString *const YTWebKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";

static NSLock *YTCacheLock;
static NSMutableDictionary *YTPlayCache;
static NSMutableDictionary *YTDurationCache;
static NSMutableSet *YTNo720;
static int YTProxyPort;
static BOOL YTAuthDidLoad;

static NSLock *YTLogLock;

static void YTLog(NSString *line) {
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

static NSString *const YTPrefsID = @"com.sokubit.5tube";
static NSString *const YTLegacyPrefsID = @"com.bytebox.youtubeinnertube";

static void YTSyncPrefs(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsID);
}

// The package id changed from com.bytebox.youtubeinnertube. Carry the old
// settings and sign-in over so the session does not have to be made again.
static void YTMigratePrefs(void) {
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

static BOOL YTPrefBool(NSString *key, BOOL fallback) {
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

static NSString *YTPrefString(NSString *key, NSString *fallback) {
    YTSyncPrefs();
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)YTPrefsID);
    if (!value) return fallback;
    NSString *result = fallback;
    if (CFGetTypeID(value) == CFStringGetTypeID()) result = [(__bridge NSString *)value copy];
    CFRelease(value);
    return result;
}

static BOOL YTWant720(void) {
    return [YTPrefString(@"quality", @"720") isEqualToString:@"720"];
}

static BOOL YTIsDeadLogin(NSURLRequest *request) {
    NSString *abs = [[[request URL] absoluteString] lowercaseString] ?: @"";
    if ([abs rangeOfString:@"applelogin"].location != NSNotFound) return YES;
    if ([abs rangeOfString:@"youtube/accounts"].location != NSNotFound) return YES;
    if ([abs rangeOfString:@"clientlogin"].location != NSNotFound) return YES;
    return NO;
}

static BOOL YTShouldHandle(NSURLRequest *request) {
    if ([NSURLProtocol propertyForKey:YTMark inRequest:request]) return NO;
    NSString *abs = [[[request URL] absoluteString] lowercaseString] ?: @"";
    if ([abs rangeOfString:@"gdata.youtube.com"].location != NSNotFound) return YES;
    if ([abs rangeOfString:@"/feeds/api/"].location != NSNotFound) return YES;
    if (YTPrefBool(@"suggestions", YES) && [abs rangeOfString:@"suggestqueries.google.com"].location != NSNotFound) return YES;
    return NO;
}

static id YTGet(id obj, NSString *key) {
    if (![obj isKindOfClass:[NSDictionary class]] || !key) return nil;
    return [(NSDictionary *)obj objectForKey:key];
}

static void YTSet(NSMutableDictionary *dict, NSString *key, id value) {
    if (!dict || !key || !value) return;
    [dict setObject:value forKey:key];
}

static id YTAt(NSArray *array, NSUInteger index) {
    if (index >= array.count) return nil;
    return [array objectAtIndex:index];
}

static NSString *YTEscape(NSString *text) {
    if (!text.length) return @"";
    NSMutableString *out = [text mutableCopy];
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, out.length)];
    return out;
}

static NSString *YTText(id node) {
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

static NSInteger YTSeconds(NSString *text) {
    if (!text.length) return 0;
    NSArray *parts = [text componentsSeparatedByString:@":"];
    NSInteger value = 0;
    for (NSString *part in parts) value = value * 60 + [part integerValue];
    return value;
}

static NSString *YTDigits(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    NSUInteger i;
    for (i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= '0' && c <= '9') [out appendFormat:@"%C", c];
    }
    return out.length ? out : @"0";
}

static NSDictionary *YTQuery(NSURL *url) {
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

static NSDictionary *YTContext(void) {
    return [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObjectsAndKeys:
             @"ANDROID", @"clientName",
             @"20.10.38", @"clientVersion",
             @"en", @"hl",
             @"US", @"gl",
             [NSNumber numberWithInt:30], @"androidSdkVersion",
             nil]
                                       forKey:@"client"];
}

static NSDictionary *YTTVContext(void) {
    return [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObjectsAndKeys:
             @"TVHTML5", @"clientName",
             @"7.20250319.10.00", @"clientVersion",
             @"en", @"hl",
             @"US", @"gl",
             nil]
                                       forKey:@"client"];
}

static NSDictionary *YTWebContext(void) {
    return [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObjectsAndKeys:
             @"WEB", @"clientName",
             @"2.20250319.01.00", @"clientVersion",
             @"en", @"hl",
             @"US", @"gl",
             nil]
                                       forKey:@"client"];
}

static id YTPostMode(NSString *method, NSDictionary *body, int mode) {
    BOOL authed = mode != 0;
    NSString *key = mode == 2 ? YTWebKey : (authed ? YTTVKey : YTKey);
    NSString *urlString = [NSString stringWithFormat:@"https://www.youtube.com/youtubei/v1/%@?key=%@", method, key];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:25.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSString *agent = @"com.google.android.youtube/20.10.38 (Linux; U; Android 13)";
    if (mode == 2) agent = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
    else if (authed) agent = @"Mozilla/5.0 (AppleTV; CPU OS 9_0 like Mac OS X) AppleWebKit/601.1.46 (KHTML, like Gecko) Mobile/13T534YI";
    [request setValue:agent forHTTPHeaderField:@"User-Agent"];
    NSString *token = authed ? YTAuthAccess() : nil;
    if (token.length) [request setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:YTMark inRequest:request];
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:body ?: [NSDictionary dictionary]];
    if (![payload objectForKey:@"context"]) {
        id context = YTContext();
        if (mode == 2) context = YTWebContext();
        else if (authed) context = YTTVContext();
        [payload setObject:context forKey:@"context"];
    }
    [request setHTTPBody:[NSJSONSerialization dataWithJSONObject:payload options:0 error:NULL]];
    NSError *error = nil;
    NSURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&response error:&error];
    NSInteger code = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (!data.length || code >= 400 || error) {
        YTLog([NSString stringWithFormat:@"post %@ code %ld bytes %u err %@", method, (long)code, (unsigned)[data length], error]);
    }
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

static id YTPost(NSString *method, NSDictionary *body) {
    return YTPostMode(method, body, NO);
}

static id YTPostAuth(NSString *method, NSDictionary *body) {
    return YTPostMode(method, body, YES);
}

static id YTPostWeb(NSString *method, NSDictionary *body) {
    return YTPostMode(method, body, 2);
}

static BOOL YTIsShortNode(id node, int depth) {
    if (!node || depth > 8) return NO;
    if ([node isKindOfClass:[NSString class]]) {
        NSString *text = node;
        if ([text rangeOfString:@"/shorts/"].location != NSNotFound) return YES;
        if ([text isEqualToString:@"SHORTS"]) return YES;
        return NO;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) if (YTIsShortNode(child, depth + 1)) return YES;
        return NO;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return NO;
    for (id key in node) {
        if ([key isKindOfClass:[NSString class]]) {
            NSString *name = key;
            if ([name rangeOfString:@"reel" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            if ([name rangeOfString:@"shorts" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        }
        if (YTIsShortNode([node objectForKey:key], depth + 1)) return YES;
    }
    return NO;
}

static void YTCollect(id node, NSMutableArray *out, NSMutableSet *seen) {
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in (NSArray *)node) YTCollect(child, out, seen);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    NSString *videoID = YTGet(node, @"videoId");
    id title = YTGet(node, @"title");
    if (!title) title = YTGet(node, @"headline");
    if ([videoID isKindOfClass:[NSString class]] && [(NSString *)videoID length] == 11 && title) {
        if ([seen containsObject:videoID]) return;
        [seen addObject:videoID];
        if (YTPrefBool(@"hideShorts", YES) && YTIsShortNode(node, 0)) {
            YTLog([NSString stringWithFormat:@"skip short %@", videoID]);
            return;
        }
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        YTSet(item, @"id", videoID);
        YTSet(item, @"title", YTText(title));
        YTSet(item, @"author", YTText(YTGet(node, @"longBylineText") ?: YTGet(node, @"shortBylineText") ?: YTGet(node, @"ownerText")));
        YTSet(item, @"length", YTText(YTGet(node, @"lengthText")));
        YTSet(item, @"views", YTText(YTGet(node, @"viewCountText") ?: YTGet(node, @"shortViewCountText")));
        YTSet(item, @"published", YTText(YTGet(node, @"publishedTimeText")));
        [out addObject:item];
        return;
    }
    for (id child in [(NSDictionary *)node allValues]) YTCollect(child, out, seen);
}

static NSArray *YTVideosFromJSON(id json) {
    NSMutableArray *out = [NSMutableArray array];
    YTCollect(json, out, [NSMutableSet set]);
    return out;
}

static NSString *YTLocalPlayURL(NSString *videoID, BOOL high) {
    if (high) return [NSString stringWithFormat:@"http://127.0.0.1:%d/%@.mp4", YTProxyPort, videoID];
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/%@.360.mp4", YTProxyPort, videoID];
}

static int YTAvcLevel(NSString *mime) {
    NSRange mark = [mime rangeOfString:@"avc1." options:NSCaseInsensitiveSearch];
    if (mark.location == NSNotFound || mark.location + 11 > mime.length) return 0;
    NSString *hex = [mime substringWithRange:NSMakeRange(mark.location + mark.length + 4, 2)];
    unsigned int level = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    [scanner scanHexInt:&level];
    return (int)level;
}

static void YTPickStreams(NSMutableDictionary *streams, NSArray *formats) {
    NSDictionary *video = nil;
    NSDictionary *audio = nil;
    int videoScore = -1;
    int audioScore = -1;
    for (id format in formats) {
        if (![format isKindOfClass:[NSDictionary class]]) continue;
        NSString *url = YTGet(format, @"url");
        NSString *mime = YTGet(format, @"mimeType") ?: @"";
        if (![url isKindOfClass:[NSString class]] || !url.length) continue;
        int bitrate = [[YTGet(format, @"bitrate") description] intValue];
        if ([mime rangeOfString:@"audio/mp4"].location != NSNotFound || [mime rangeOfString:@"mp4a"].location != NSNotFound) {
            if ([mime rangeOfString:@"video"].location != NSNotFound) continue;
            if (bitrate > 192000) continue;
            if (bitrate > audioScore) { audioScore = bitrate; audio = format; }
            continue;
        }
        if ([mime rangeOfString:@"avc1"].location == NSNotFound) continue;
        int height = [[YTGet(format, @"height") description] intValue];
        int fps = [[YTGet(format, @"fps") description] intValue];
        if (fps > 30 || height < 144 || height > 720) continue;
        int level = YTAvcLevel(mime);
        if (level > 0x28) continue;
        int score = height * 1000000 + bitrate / 1000;
        if (level > 0x1f) score -= 200000;
        if (score > videoScore) { videoScore = score; video = format; }
    }
    if (video) {
        [streams setObject:[video objectForKey:@"url"] forKey:@"hi"];
        [streams setObject:[[YTGet(video, @"height") description] length] ? [YTGet(video, @"height") description] : @"0" forKey:@"hih"];
    }
    if (audio) [streams setObject:[audio objectForKey:@"url"] forKey:@"au"];
}

static NSString *YTStreamURL(NSString *videoID, NSString *itag) {
    [YTCacheLock lock];
    id info = [YTPlayCache objectForKey:videoID];
    [YTCacheLock unlock];
    if ([info isKindOfClass:[NSDictionary class]]) return [info objectForKey:itag];
    if ([itag isEqualToString:@"18"] && [info isKindOfClass:[NSString class]]) return info;
    return nil;
}

static void YTTakeStream(NSMutableDictionary *streams, id format) {
    NSString *url = YTGet(format, @"url");
    id tag = YTGet(format, @"itag");
    NSString *itag = [tag description];
    if ([url isKindOfClass:[NSString class]] && url.length && itag.length) [streams setObject:url forKey:itag];
}

static NSString *YTFetchUpstream(NSString *videoID) {
    if (!videoID.length) return nil;
    NSString *ready = YTStreamURL(videoID, @"18");
    if (!ready.length) ready = YTStreamURL(videoID, @"136");
    if (ready.length) return ready;
    id json = YTPost(@"player", [NSDictionary dictionaryWithObjectsAndKeys:
                                 videoID, @"videoId",
                                 [NSNumber numberWithBool:YES], @"contentCheckOk",
                                 [NSNumber numberWithBool:YES], @"racyCheckOk",
                                 nil]);
    NSMutableDictionary *streams = [NSMutableDictionary dictionary];
    NSMutableArray *formats = [NSMutableArray array];
    id lists = [NSArray arrayWithObjects:YTGet(YTGet(json, @"streamingData"), @"formats"), YTGet(YTGet(json, @"streamingData"), @"adaptiveFormats"), nil];
    for (id list in lists) {
        if (![list isKindOfClass:[NSArray class]]) continue;
        for (id format in list) {
            YTTakeStream(streams, format);
            if ([format isKindOfClass:[NSDictionary class]]) [formats addObject:format];
        }
    }
    id length = YTGet(YTGet(json, @"videoDetails"), @"lengthSeconds");
    NSInteger seconds = [[length description] integerValue];
    NSString *found = [streams objectForKey:@"18"] ?: [streams objectForKey:@"136"];
    id status = YTGet(YTGet(json, @"playabilityStatus"), @"status");
    if (YTPrefBool(@"ageBypass", YES) && found.length && status && ![status isEqualToString:@"OK"] && ![streams objectForKey:@"136"]) {
        NSMutableDictionary *retry = [NSMutableDictionary dictionaryWithObjectsAndKeys:videoID, @"videoId", [NSNumber numberWithBool:YES], @"contentCheckOk", [NSNumber numberWithBool:YES], @"racyCheckOk", nil];
        NSMutableDictionary *client = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"TVHTML5_SIMPLY_EMBEDDED_PLAYER", @"clientName", @"2.0", @"clientVersion", @"en", @"hl", @"US", @"gl", nil];
        [retry setObject:[NSDictionary dictionaryWithObject:client forKey:@"client"] forKey:@"context"];
        id again = YTPost(@"player", retry);
        id againLists = [NSArray arrayWithObjects:YTGet(YTGet(again, @"streamingData"), @"formats"), YTGet(YTGet(again, @"streamingData"), @"adaptiveFormats"), nil];
        for (id list in againLists) {
            if (![list isKindOfClass:[NSArray class]]) continue;
            for (id format in list) {
                YTTakeStream(streams, format);
                if ([format isKindOfClass:[NSDictionary class]]) [formats addObject:format];
            }
        }
        found = [streams objectForKey:@"18"] ?: [streams objectForKey:@"136"];
        YTLog([NSString stringWithFormat:@"age retry %@ %@", videoID, found.length ? @"ok" : @"no"]);
    }
    YTPickStreams(streams, formats);
    if (![streams objectForKey:@"au"]) {
        NSString *audio = [streams objectForKey:@"140"] ?: [streams objectForKey:@"139"];
        if (audio.length) [streams setObject:audio forKey:@"au"];
    }
    if (found.length || [streams objectForKey:@"hi"]) {
        [YTCacheLock lock];
        [YTPlayCache setObject:streams forKey:videoID];
        if (seconds > 0) [YTDurationCache setObject:[NSNumber numberWithInteger:seconds] forKey:videoID];
        [YTCacheLock unlock];
        YTLog([NSString stringWithFormat:@"upstream %@ %ld hi %@ %@", videoID, (long)seconds, [streams objectForKey:@"hih"] ?: @"-", [streams objectForKey:@"hi"] ? @"yes" : @"no"]);
    }
    return found;
}

void YTMuxNote(NSString *line) {
    YTLog(line);
}

static NSString *YTPlayURL(NSString *videoID) {
    NSString *progressive = YTFetchUpstream(videoID);
    BOOL high = [YTStreamURL(videoID, @"hi") length] > 0;
    if (YTProxyPort <= 0 || (!progressive.length && !high)) return nil;
    return YTLocalPlayURL(videoID, YTWant720() && high);
}

static NSDictionary *YTDetails(NSString *videoID) {
    id json = YTPost(@"player", [NSDictionary dictionaryWithObjectsAndKeys:
                                 videoID, @"videoId",
                                 [NSNumber numberWithBool:YES], @"contentCheckOk",
                                 [NSNumber numberWithBool:YES], @"racyCheckOk",
                                 nil]);
    NSDictionary *details = YTGet(json, @"videoDetails");
    if (![details isKindOfClass:[NSDictionary class]]) return nil;
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    YTSet(item, @"id", videoID);
    id title = YTGet(details, @"title");
    YTSet(item, @"title", [title isKindOfClass:[NSString class]] ? title : @"Video");
    id author = YTGet(details, @"author");
    YTSet(item, @"author", [author isKindOfClass:[NSString class]] ? author : @"");
    id views = YTGet(details, @"viewCount");
    YTSet(item, @"views", [views isKindOfClass:[NSString class]] ? views : @"0");
    id length = YTGet(details, @"lengthSeconds");
    YTSet(item, @"length", [length isKindOfClass:[NSString class]] ? length : @"0");
    YTSet(item, @"seconds", [NSNumber numberWithInteger:[[item objectForKey:@"length"] integerValue]]);
    id desc = YTGet(details, @"shortDescription");
    YTSet(item, @"description", [desc isKindOfClass:[NSString class]] ? desc : @"");
    NSString *play = YTPlayURL(videoID);
    if (play.length) YTSet(item, @"play", play);
    return item;
}

static NSString *YTEntry(NSDictionary *item) {
    NSString *videoID = [item objectForKey:@"id"] ?: @"";
    NSString *title = YTEscape([item objectForKey:@"title"] ?: @"Video");
    NSString *author = YTEscape([item objectForKey:@"author"] ?: @"");
    NSString *desc = YTEscape([item objectForKey:@"description"] ?: [item objectForKey:@"published"] ?: @"");
    NSInteger seconds = [[item objectForKey:@"seconds"] integerValue];
    if (seconds <= 0) seconds = YTSeconds([item objectForKey:@"length"]);
    NSString *views = YTDigits([item objectForKey:@"views"] ?: @"0");
    BOOL high = YTWant720();
    NSString *hi = high ? YTLocalPlayURL(videoID, YES) : YTLocalPlayURL(videoID, NO);
    NSString *lo = (high && YTPrefBool(@"cellular720", YES)) ? hi : YTLocalPlayURL(videoID, NO);
    if (!hi.length) hi = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", videoID];
    if (!lo.length) lo = hi;
    NSString *customThumb = [item objectForKey:@"thumb"];
    NSString *thumb = [customThumb isKindOfClass:[NSString class]] && customThumb.length ? customThumb : [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID];
    return [NSString stringWithFormat:
            @"<entry yt:x='1'>"
            "<id yt:x='1'>http://gdata.youtube.com/feeds/api/videos/%@</id>"
            "<published yt:x='1'>2026-11-13T00:00:00+0000</published>"
            "<updated yt:x='1'>2026-11-13T00:00:00+0000</updated>"
            "<title type='text'>%@</title>"
            "<author yt:x='1'><name yt:x='1'>%@</name></author>"
            "<yt:accessControl action='list' permission='allowed'/>"
            "<yt:statistics viewCount='%@'/>"
            "<media:group yt:x='1'>"
            "<media:title type='plain'>%@</media:title>"
            "<media:description type='plain'>%@</media:description>"
            "<media:keywords yt:x='1'>%@</media:keywords>"
            "<yt:videoid yt:x='1'>%@</yt:videoid>"
            "<yt:duration seconds='%ld'/>"
            "<media:credit role='uploader' scheme='urn:youtube'>%@</media:credit>"
            "<media:category label='Music' scheme='http://gdata.youtube.com/schemas/2007/categories.cat'>Music</media:category>"
            "<media:thumbnail url='%@' height='360' width='480' yt:name='hqdefault'/>"
            "<media:content url='%@' type='video/3gpp' yt:format='2' duration='%ld'/>"
            "<media:content url='%@' type='video/3gpp' yt:format='3' duration='%ld'/>"
            "<media:content url='%@' type='video/mp4' yt:format='8' duration='%ld'/>"
            "<media:content url='%@' type='video/mp4' yt:format='9' duration='%ld'/>"
            "<media:player url='https://www.youtube.com/watch?v=%@'/>"
            "</media:group>"
            "</entry>",
            videoID, title, author, views, title, desc, title, videoID, (long)seconds, author, thumb,
            YTEscape(lo), (long)seconds,
            YTEscape(lo), (long)seconds,
            YTEscape(hi), (long)seconds,
            YTEscape(hi), (long)seconds,
            videoID];
}

static NSData *YTFeed(NSArray *items, NSInteger start, NSString *nextURL) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?>"];
    [xml appendString:@"<feed xmlns='http://www.w3.org/2005/Atom' "
                       "xmlns:openSearch='http://a9.com/-/spec/opensearch/1.1/' "
                       "xmlns:media='http://search.yahoo.com/mrss/' "
                       "xmlns:yt='http://gdata.youtube.com/schemas/2007' "
                       "xmlns:gd='http://schemas.google.com/g/2005' "
                       "yt:x='1'>"];
    NSInteger total = start + (NSInteger)[items count] - 1;
    if (total < (NSInteger)[items count]) total = (NSInteger)[items count];
    if (nextURL.length) total += 500;
    [xml appendFormat:@"<openSearch:startIndex yt:x='1'>%ld</openSearch:startIndex>", (long)(start < 1 ? 1 : start)];
    [xml appendFormat:@"<openSearch:totalResults yt:x='1'>%ld</openSearch:totalResults>", (long)total];
    [xml appendFormat:@"<openSearch:itemsPerPage yt:x='1'>%u</openSearch:itemsPerPage>", (unsigned)[items count]];
    if (nextURL.length) [xml appendFormat:@"<link rel='next' href='%@'/>", YTEscape(nextURL)];
    for (NSDictionary *item in items) [xml appendString:YTEntry(item)];
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

static NSArray *YTPage(NSArray *items, NSInteger start, NSInteger limit) {
    if (start < 1) start = 1;
    if (limit < 1) limit = 25;
    if (limit > 50) limit = 50;
    NSInteger skip = start - 1;
    if (skip >= (NSInteger)[items count]) return [NSArray array];
    NSInteger end = (NSInteger)[items count];
    if (skip + limit < end) end = skip + limit;
    return [items subarrayWithRange:NSMakeRange((NSUInteger)skip, (NSUInteger)(end - skip))];
}

static NSMutableDictionary *YTPageCache;
static NSMutableDictionary *YTTokenCache;
static NSRecursiveLock *YTListLock;

static void YTListEnter(void) {
    if (!YTListLock) YTListLock = [[NSRecursiveLock alloc] init];
    [YTListLock lock];
}

static void YTListLeave(void) {
    [YTListLock unlock];
}

static NSString *YTFindToken(id node, int depth) {
    if (!node || depth > 20) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id command = YTGet(node, @"continuationCommand");
        id token = [command isKindOfClass:[NSDictionary class]] ? YTGet(command, @"token") : nil;
        if (![token isKindOfClass:[NSString class]] || ![token length]) {
            id next = YTGet(node, @"nextContinuationData");
            token = [next isKindOfClass:[NSDictionary class]] ? YTGet(next, @"continuation") : nil;
        }
        if (![token isKindOfClass:[NSString class]] || ![token length]) {
            id reload = YTGet(node, @"reloadContinuationData");
            token = [reload isKindOfClass:[NSDictionary class]] ? YTGet(reload, @"continuation") : nil;
        }
        if ([token isKindOfClass:[NSString class]] && [token length]) return token;
        for (id child in [node allValues]) {
            NSString *found = YTFindToken(child, depth + 1);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *found = YTFindToken(child, depth + 1);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *YTFindBrowseID(id node, int depth) {
    if (!node || depth > 10) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id browse = YTGet(node, @"browseId");
        if ([browse isKindOfClass:[NSString class]] && [(NSString *)browse length] > 2) return browse;
        for (id child in [node allValues]) {
            NSString *found = YTFindBrowseID(child, depth + 1);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *found = YTFindBrowseID(child, depth + 1);
            if (found.length) return found;
        }
    }
    return nil;
}

static void YTCollectComments(id node, NSMutableArray *out, int depth) {
    if (!node || depth > 14) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) YTCollectComments(child, out, depth + 1);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    id text = YTGet(node, @"contentText");
        if (text && YTGet(node, @"authorText")) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        YTSet(item, @"text", YTText(text));
        YTSet(item, @"author", YTText(YTGet(node, @"authorText")));
        if ([item objectForKey:@"text"]) [out addObject:item];
        return;
    }
    for (id child in [node allValues]) YTCollectComments(child, out, depth + 1);
}

static NSArray *YTFillKey(NSString *key, NSString *query, NSString *browseID, NSInteger need) {
    YTListEnter();
    if (!YTPageCache) YTPageCache = [NSMutableDictionary dictionary];
    if (!YTTokenCache) YTTokenCache = [NSMutableDictionary dictionary];
    NSMutableArray *all = [YTPageCache objectForKey:key];
    if (!all) {
        all = [NSMutableArray array];
        [YTPageCache setObject:all forKey:key];
    }
    BOOL paging = YTPrefBool(@"paging", YES);
    while ((NSInteger)[all count] < need) {
        NSString *token = [YTTokenCache objectForKey:key];
        id json = nil;
        if (!token.length && ![all count]) {
            if (browseID.length) json = YTPost(@"browse", [NSDictionary dictionaryWithObject:browseID forKey:@"browseId"]);
            else json = YTPost(@"search", [NSDictionary dictionaryWithObject:(query ?: @"trending") forKey:@"query"]);
        } else if (paging && token.length) {
            json = YTPost(@"search", [NSDictionary dictionaryWithObject:token forKey:@"continuation"]);
            if (!json) json = YTPost(@"browse", [NSDictionary dictionaryWithObject:token forKey:@"continuation"]);
        } else break;
        NSArray *page = YTVideosFromJSON(json);
        if (![page count]) break;
        NSMutableSet *seen = [NSMutableSet setWithArray:[all valueForKey:@"id"]];
        for (NSDictionary *item in page) {
            NSString *vid = [item objectForKey:@"id"];
            if (!vid.length || [seen containsObject:vid]) continue;
            [seen addObject:vid];
            [all addObject:item];
        }
        NSString *next = YTFindToken(json, 0);
        if (next.length) [YTTokenCache setObject:next forKey:key];
        else {
            [YTTokenCache removeObjectForKey:key];
            break;
        }
        if (!paging) break;
    }
    NSArray *snapshot = [NSArray arrayWithArray:all];
    YTListLeave();
    return snapshot;
}

static NSArray *YTFillSearch(NSString *key, NSString *query, NSString *params, NSString *region, NSInteger need) {
    YTListEnter();
    if (!YTPageCache) YTPageCache = [NSMutableDictionary dictionary];
    if (!YTTokenCache) YTTokenCache = [NSMutableDictionary dictionary];
    NSMutableArray *all = [YTPageCache objectForKey:key];
    if (!all) {
        all = [NSMutableArray array];
        [YTPageCache setObject:all forKey:key];
    }
    BOOL paging = YTPrefBool(@"paging", YES);
    while ((NSInteger)[all count] < need) {
        NSString *token = [YTTokenCache objectForKey:key];
        id json = nil;
        if (!token.length && ![all count]) {
            NSMutableDictionary *body = [NSMutableDictionary dictionary];
            [body setObject:(query.length ? query : @"a") forKey:@"query"];
            if (params.length) [body setObject:params forKey:@"params"];
            NSMutableDictionary *client = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                                           @"ANDROID", @"clientName",
                                           @"20.10.38", @"clientVersion",
                                           @"en", @"hl",
                                           (region.length == 2 ? region : @"US"), @"gl",
                                           [NSNumber numberWithInt:30], @"androidSdkVersion",
                                           nil];
            [body setObject:[NSDictionary dictionaryWithObject:client forKey:@"client"] forKey:@"context"];
            json = YTPost(@"search", body);
        } else if (paging && token.length) {
            json = YTPost(@"search", [NSDictionary dictionaryWithObject:token forKey:@"continuation"]);
        } else break;
        NSArray *page = YTVideosFromJSON(json);
        if (![page count]) break;
        NSMutableSet *seen = [NSMutableSet setWithArray:[all valueForKey:@"id"]];
        for (NSDictionary *item in page) {
            NSString *vid = [item objectForKey:@"id"];
            NSString *views = [item objectForKey:@"views"] ?: @"";
            if (!vid.length || [seen containsObject:vid]) continue;
            if ([views rangeOfString:@"watching" options:NSCaseInsensitiveSearch].location != NSNotFound) continue;
            [seen addObject:vid];
            [all addObject:item];
        }
        NSString *next = YTFindToken(json, 0);
        if (next.length) [YTTokenCache setObject:next forKey:key];
        else {
            [YTTokenCache removeObjectForKey:key];
            break;
        }
        if (!paging) break;
    }
    NSArray *snapshot = [NSArray arrayWithArray:all];
    YTListLeave();
    return snapshot;
}

static NSString *YTChartRegion(NSArray *parts) {
    NSString *maybe = YTAt(parts, 4);
    if ([YTAt(parts, 5) length] && maybe.length == 2) return [maybe uppercaseString];
    NSString *code = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return code.length == 2 ? [code uppercaseString] : @"US";
}

static NSArray *YTMostViewed(NSString *time, NSString *region, NSInteger need) {
    NSString *slot = @"all_time";
    NSString *params = @"CAMSAhAB";
    if ([time isEqualToString:@"today"]) {
        slot = @"today";
        params = @"CAMSAggC";
    } else if ([time isEqualToString:@"this_week"]) {
        slot = @"this_week";
        params = @"CAMSAggD";
    }
    NSString *key = [NSString stringWithFormat:@"chart:%@:%@", slot, region ?: @"US"];
    return YTFillSearch(key, @"a", params, region, need);
}

static NSArray *YTChannelUploads(NSString *user) {
    if (!user.length) return [NSArray array];
    NSMutableArray *urls = [NSMutableArray array];
    if ([user hasPrefix:@"UC"]) [urls addObject:[NSString stringWithFormat:@"https://www.youtube.com/channel/%@", user]];
    [urls addObject:[NSString stringWithFormat:@"https://www.youtube.com/@%@", user]];
    [urls addObject:[NSString stringWithFormat:@"https://www.youtube.com/user/%@", user]];
    [urls addObject:[NSString stringWithFormat:@"https://www.youtube.com/c/%@", user]];
    for (NSString *url in urls) {
        id json = YTPost(@"navigation/resolve_url", [NSDictionary dictionaryWithObject:url forKey:@"url"]);
        NSString *browseID = YTFindBrowseID(json, 0);
        if (!browseID.length) continue;
        NSArray *videos = YTFillKey([@"channel:" stringByAppendingString:browseID], nil, browseID, 40);
        if ([videos count]) {
            YTLog([NSString stringWithFormat:@"channel %@ %@", user, browseID]);
            return videos;
        }
    }
    return [NSArray array];
}

static NSMutableDictionary *YTCommentParams;

static NSString *YTFindCreateParams(id node, int depth) {
    if (!node || depth > 16) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id params = YTGet(node, @"createCommentParams");
        if ([params isKindOfClass:[NSString class]] && [(NSString *)params length] > 8) return params;
        for (id child in [node allValues]) {
            NSString *found = YTFindCreateParams(child, depth + 1);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *found = YTFindCreateParams(child, depth + 1);
            if (found.length) return found;
        }
    }
    return nil;
}

static void YTSaveCommentParams(NSString *videoID, id json) {
    NSString *params = YTFindCreateParams(json, 0);
    if (!videoID.length || !params.length) return;
    if (!YTCommentParams) YTCommentParams = [NSMutableDictionary dictionary];
    [YTCommentParams setObject:params forKey:videoID];
}

static NSData *YTCommentFeed(NSString *videoID) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?><feed xmlns='http://www.w3.org/2005/Atom' xmlns:yt='http://gdata.youtube.com/schemas/2007' yt:x='1'>"];
    if (YTPrefBool(@"comments", YES) && videoID.length) {
        id json = YTPost(@"next", [NSDictionary dictionaryWithObject:videoID forKey:@"videoId"]);
        YTSaveCommentParams(videoID, json);
        NSMutableArray *comments = [NSMutableArray array];
        YTCollectComments(json, comments, 0);
        for (NSDictionary *item in comments) {
            [xml appendFormat:@"<entry yt:x='1'><title yt:x='1'>%@</title><author yt:x='1'><name yt:x='1'>%@</name></author><content type='text'>%@</content></entry>",
             YTEscape([item objectForKey:@"author"] ?: @""), YTEscape([item objectForKey:@"author"] ?: @""), YTEscape([item objectForKey:@"text"] ?: @"")];
        }
        YTLog([NSString stringWithFormat:@"comments %@ %u", videoID, (unsigned)[comments count]]);
    }
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *YTGET(NSString *urlString) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:@"com.google.android.youtube/20.10.38" forHTTPHeaderField:@"User-Agent"];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:YTMark inRequest:request];
    return [NSURLConnection sendSynchronousRequest:request returningResponse:NULL error:NULL];
}

static NSData *YTCaptionFeed(NSString *videoID) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?><feed xmlns='http://www.w3.org/2005/Atom' xmlns:yt='http://gdata.youtube.com/schemas/2007' yt:x='1'>"];
    if (YTPrefBool(@"captions", YES) && videoID.length) {
        NSData *list = YTGET([NSString stringWithFormat:@"https://www.youtube.com/api/timedtext?type=list&v=%@", videoID]);
        NSString *text = list.length ? [[NSString alloc] initWithData:list encoding:NSUTF8StringEncoding] : @"";
        NSRange scan = NSMakeRange(0, text.length);
        while (scan.length) {
            NSRange found = [text rangeOfString:@"lang_code=\"" options:0 range:scan];
            if (found.location == NSNotFound) break;
            NSUInteger start = found.location + found.length;
            NSRange end = [text rangeOfString:@"\"" options:0 range:NSMakeRange(start, text.length - start)];
            if (end.location == NSNotFound) break;
            NSString *lang = [text substringWithRange:NSMakeRange(start, end.location - start)];
            NSString *src = [NSString stringWithFormat:@"http://127.0.0.1:%d/%@.%@.srt", YTProxyPort, videoID, lang];
            [xml appendFormat:@"<entry yt:x='1'><title yt:x='1'>%@</title><link rel='alternate' href='%@'/><yt:captionTrack url='%@' lang='%@' yt:x='1'/></entry>",
             YTEscape(lang), YTEscape(src), YTEscape(src), YTEscape(lang)];
            scan = NSMakeRange(end.location + 1, text.length - end.location - 1);
        }
    }
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

static NSData *YTSuggestData(NSURLRequest *request) {
    NSString *q = [YTQuery([request URL]) objectForKey:@"q"] ?: @"";
    NSData *raw = YTGET([[NSString stringWithFormat:@"https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=%@",
                          [q stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]] stringByReplacingOccurrencesOfString:@" " withString:@"%20"]);
    if (raw.length) return raw;
    return [[NSString stringWithFormat:@"[\"%@\",[]]", YTEscape(q)] dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *YTBodyString(NSURLRequest *request) {
    NSData *body = [request HTTPBody];
    if (![body length]) return @"";
    return [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] ?: @"";
}

static BOOL YTIsVideoID(NSString *text) {
    if ([text length] != 11) return NO;
    NSUInteger i;
    for (i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-')) return NO;
    }
    return YES;
}

static NSArray *YTIDsInBody(NSString *body) {
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

static NSMutableDictionary *YTAPICache;

static NSString *YTQueryEscape(NSString *text) {
    if (!text.length) return @"";
    return (__bridge_transfer NSString *)CFURLCreateStringByAddingPercentEscapes(NULL, (__bridge CFStringRef)text, NULL, CFSTR("!*'();:@&=+$,/?%#[]"), kCFStringEncodingUTF8);
}

static NSString *YTFirstText(id node, int depth) {
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

static NSString *YTAuthorFrom(NSString *text) {
    if (!text.length) return @"";
    NSRange bullet = [text rangeOfString:@"•"];
    if (bullet.location == NSNotFound) bullet = [text rangeOfString:@"·"];
    if (bullet.location != NSNotFound && bullet.location > 0) text = [text substringToIndex:bullet.location];
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *YTFindHandle(id node, int depth) {
    if (!node || depth > 16) return nil;
    if ([node isKindOfClass:[NSString class]]) {
        NSRange at = [(NSString *)node rangeOfString:@"@"];
        if (at.location != NSNotFound && at.location + 2 < [(NSString *)node length]) {
            NSString *rest = [(NSString *)node substringFromIndex:at.location + 1];
            NSMutableString *handle = [NSMutableString string];
            NSUInteger i;
            for (i = 0; i < rest.length && i < 30; i++) {
                unichar c = [rest characterAtIndex:i];
                if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-') [handle appendFormat:@"%C", c];
                else break;
            }
            if (handle.length > 1) return handle;
        }
        return nil;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *found = YTFindHandle(child, depth + 1);
            if (found.length) return found;
        }
        return nil;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    for (id child in [node allValues]) {
        NSString *found = YTFindHandle(child, depth + 1);
        if (found.length) return found;
    }
    return nil;
}

static NSString *YTFindParams(id node, int depth) {
    if (!node || depth > 8) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id params = YTGet(node, @"params");
        if ([params isKindOfClass:[NSString class]] && [(NSString *)params length] > 6) return params;
        for (id child in [node allValues]) {
            NSString *found = YTFindParams(child, depth + 1);
            if (found.length) return found;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) {
            NSString *found = YTFindParams(child, depth + 1);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSMutableDictionary *YTVideoItem(NSString *videoID, NSString *title, NSString *author, NSString *desc, NSInteger seconds, NSString *views) {
    if (!YTIsVideoID(videoID)) return nil;
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    YTSet(item, @"id", videoID);
    YTSet(item, @"title", title.length ? title : @"Video");
    YTSet(item, @"author", author ?: @"");
    YTSet(item, @"description", desc ?: @"");
    YTSet(item, @"views", views.length ? views : @"0");
    YTSet(item, @"length", [NSString stringWithFormat:@"%ld", (long)seconds]);
    YTSet(item, @"seconds", [NSNumber numberWithInteger:seconds]);
    return item;
}

static NSString *YTBestImage(id node);
static NSString *YTJoinedCount(id node, int depth);

static void YTCollectTiles(id node, NSMutableArray *videos, NSMutableArray *playlists, NSMutableSet *seen, int depth) {
    if (!node || depth > 24) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) YTCollectTiles(child, videos, playlists, seen, depth + 1);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    id tile = YTGet(node, @"tileRenderer");
    if ([tile isKindOfClass:[NSDictionary class]]) {
        NSString *cid = YTGet(tile, @"contentId");
        NSString *kind = YTGet(tile, @"contentType");
        NSString *title = YTText(YTGet(YTGet(YTGet(tile, @"metadata"), @"tileMetadataRenderer"), @"title"));
        if (!title.length) title = YTFirstText(YTGet(tile, @"metadata"), 0);
        NSString *subtitle = YTText(YTGet(YTGet(YTGet(tile, @"onLongPressCommand"), @"showMenuCommand"), @"subtitle"));
        NSString *author = YTAuthorFrom(subtitle);
        NSString *browse = YTGet(YTGet(YTGet(tile, @"onSelectCommand"), @"browseEndpoint"), @"browseId");
        BOOL playlist = [kind isEqualToString:@"TILE_CONTENT_TYPE_PLAYLIST"] || [browse hasPrefix:@"VL"] || [cid isEqualToString:@"LL"] || [cid isEqualToString:@"WL"];
        if ([cid isKindOfClass:[NSString class]] && cid.length && ![seen containsObject:cid]) {
            if (!playlist && YTIsVideoID(cid)) {
                [seen addObject:cid];
                NSMutableDictionary *item = YTVideoItem(cid, title, author, subtitle, 0, @"0");
                if (item && videos) [videos addObject:item];
            } else if (playlist && playlists) {
                [seen addObject:cid];
                NSMutableDictionary *item = [NSMutableDictionary dictionary];
                YTSet(item, @"playlistId", cid);
                YTSet(item, @"title", title.length ? title : cid);
                NSString *count = YTJoinedCount(YTGet(YTGet(tile, @"header"), @"tileHeaderRenderer"), 0);
                if (!count.length) count = YTJoinedCount(YTGet(tile, @"metadata"), 0);
                YTSet(item, @"count", count.length ? count : @"0");
                NSString *thumb = YTBestImage(YTGet(YTGet(tile, @"header"), @"tileHeaderRenderer"));
                if (!thumb.length) thumb = YTBestImage(YTGet(YTGet(YTGet(tile, @"header"), @"tileHeaderRenderer"), @"thumbnail"));
                if (thumb.length) YTSet(item, @"thumb", thumb);
                [playlists addObject:item];
            }
        }
    }
    for (id child in [node allValues]) YTCollectTiles(child, videos, playlists, seen, depth + 1);
}

static NSString *YTBestImage(id node) {
    id list = [node isKindOfClass:[NSDictionary class]] ? YTGet(node, @"thumbnails") : nil;
    if (![list isKindOfClass:[NSArray class]]) return nil;
    NSString *best = nil;
    int bestW = -1;
    for (id item in list) {
        NSString *url = YTGet(item, @"url");
        if (![url isKindOfClass:[NSString class]] || !url.length) continue;
        int width = [[YTGet(item, @"width") description] intValue];
        if (!best || width >= bestW) {
            best = url;
            bestW = width;
        }
    }
    if ([best hasPrefix:@"//"]) best = [@"https:" stringByAppendingString:best];
    return best;
}

static NSString *YTIconURL(NSString *remote) {
    if (!remote.length) return @"";
    if (YTProxyPort <= 0) return remote;
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/icon?u=%@", YTProxyPort, YTQueryEscape(remote)];
}

static NSString *YTJoinedCount(id node, int depth) {
    if (!node || depth > 6) return nil;
    if ([node isKindOfClass:[NSArray class]]) {
        NSMutableString *joined = [NSMutableString string];
        BOOL text = NO;
        for (id child in node) {
            if ([child isKindOfClass:[NSString class]]) {
                [joined appendString:child];
                text = YES;
            } else if ([child isKindOfClass:[NSDictionary class]]) {
                id bit = YTGet(child, @"text");
                if ([bit isKindOfClass:[NSString class]]) {
                    [joined appendString:bit];
                    text = YES;
                }
            }
        }
        if (text && [joined rangeOfString:@"video" options:NSCaseInsensitiveSearch].location != NSNotFound)
            return YTDigits(joined);
        for (id child in node) {
            NSString *found = YTJoinedCount(child, depth + 1);
            if (found.length) return found;
        }
        return nil;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return nil;
    for (id child in [node allValues]) {
        NSString *found = YTJoinedCount(child, depth + 1);
        if (found.length) return found;
    }
    return nil;
}

static void YTCollectTabs(id node, NSMutableArray *out, NSMutableSet *seen, int depth) {
    if (!node || depth > 24) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) YTCollectTabs(child, out, seen, depth + 1);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    id tab = YTGet(node, @"tabRenderer");
    if ([tab isKindOfClass:[NSDictionary class]]) {
        NSString *title = YTGet(tab, @"title");
        NSString *params = YTGet(YTGet(YTGet(tab, @"endpoint"), @"browseEndpoint"), @"params");
        if ([title isKindOfClass:[NSString class]] && title.length && [params isKindOfClass:[NSString class]] && params.length && ![title isEqualToString:@"All"] && ![title isEqualToString:@"A-Z"] && ![seen containsObject:title]) {
            [seen addObject:title];
            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            YTSet(item, @"title", title);
            YTSet(item, @"channelId", title);
            YTSet(item, @"params", params);
            NSString *avatar = YTBestImage(YTGet(tab, @"thumbnail"));
            if (avatar.length) YTSet(item, @"thumb", YTIconURL(avatar));
            [out addObject:item];
        }
    }
    for (id child in [node allValues]) YTCollectTabs(child, out, seen, depth + 1);
}

static id YTAuthPost(NSString *browseID, NSString *params, NSString *continuation) {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    if (continuation.length) [body setObject:continuation forKey:@"continuation"];
    else {
        if (browseID.length) [body setObject:browseID forKey:@"browseId"];
        if (params.length) [body setObject:params forKey:@"params"];
    }
    return YTPostAuth(@"browse", body);
}

static NSArray *YTAuthVideos(NSString *key, NSString *browseID, NSString *params, NSInteger need) {
    if (!YTAuthSignedIn() || !browseID.length) return [NSArray array];
    YTListEnter();
    if (!YTPageCache) YTPageCache = [NSMutableDictionary dictionary];
    if (!YTTokenCache) YTTokenCache = [NSMutableDictionary dictionary];
    NSString *cacheKey = [@"auth:" stringByAppendingString:key ?: browseID];
    NSMutableArray *all = [YTPageCache objectForKey:cacheKey];
    if (!all) {
        all = [NSMutableArray array];
        [YTPageCache setObject:all forKey:cacheKey];
    }
    int guard = 0;
    while ((NSInteger)[all count] < need && guard < 6) {
        guard++;
        NSString *token = [YTTokenCache objectForKey:cacheKey];
        id json = nil;
        if (!token.length && guard == 1) json = YTAuthPost(browseID, params, nil);
        else if (token.length) json = YTAuthPost(nil, nil, token);
        else break;
        NSUInteger before = [all count];
        NSMutableSet *seen = [NSMutableSet setWithArray:[all valueForKey:@"id"]];
        YTCollectTiles(json, all, nil, seen, 0);
        for (NSDictionary *item in YTVideosFromJSON(json)) {
            NSString *vid = [item objectForKey:@"id"];
            if (!vid.length || [seen containsObject:vid]) continue;
            [seen addObject:vid];
            [all addObject:item];
        }
        if ([all count] == before) break;
        NSString *next = YTFindToken(json, 0);
        if (next.length) [YTTokenCache setObject:next forKey:cacheKey];
        else {
            [YTTokenCache removeObjectForKey:cacheKey];
            break;
        }
    }
    YTLog([NSString stringWithFormat:@"browse %@ %u", browseID, (unsigned)[all count]]);
    NSArray *snapshot = [NSArray arrayWithArray:all];
    YTListLeave();
    return snapshot;
}

static NSArray *YTLiked(NSInteger need) {
    return YTAuthVideos(@"likes", @"VLLL", nil, need);
}

static NSArray *YTSubVideos(NSInteger need) {
    return YTAuthVideos(@"subs", @"FEsubscriptions", nil, need);
}

static NSArray *YTRelated(NSString *videoID, NSInteger need) {
    if (!videoID.length) return [NSArray array];
    YTListEnter();
    if (!YTPageCache) YTPageCache = [NSMutableDictionary dictionary];
    if (!YTTokenCache) YTTokenCache = [NSMutableDictionary dictionary];
    NSString *key = [@"related:" stringByAppendingString:videoID];
    NSMutableArray *all = [YTPageCache objectForKey:key];
    if (!all) {
        all = [NSMutableArray array];
        [YTPageCache setObject:all forKey:key];
    }
    int guard = 0;
    while ((NSInteger)[all count] < need && guard < 4) {
        guard++;
        NSString *token = [YTTokenCache objectForKey:key];
        id json = nil;
        if (!token.length && ![all count]) json = YTPost(@"next", [NSDictionary dictionaryWithObject:videoID forKey:@"videoId"]);
        else if (token.length) json = YTPost(@"next", [NSDictionary dictionaryWithObject:token forKey:@"continuation"]);
        else break;
        NSUInteger before = [all count];
        NSMutableSet *seen = [NSMutableSet setWithArray:[all valueForKey:@"id"]];
        for (NSDictionary *item in YTVideosFromJSON(json)) {
            NSString *vid = [item objectForKey:@"id"];
            if (!vid.length || [vid isEqualToString:videoID] || [seen containsObject:vid]) continue;
            [seen addObject:vid];
            [all addObject:item];
        }
        if ([all count] == before) break;
        NSString *next = YTFindToken(json, 0);
        if (next.length) [YTTokenCache setObject:next forKey:key];
        else {
            [YTTokenCache removeObjectForKey:key];
            break;
        }
    }
    NSArray *snapshot = [NSArray arrayWithArray:all];
    YTListLeave();
    return snapshot;
}

static NSArray *YTPlaylistVideos(NSString *playlistID, NSInteger need) {
    if (!playlistID.length) return [NSArray array];
    NSString *browse = [playlistID hasPrefix:@"VL"] ? playlistID : [@"VL" stringByAppendingString:playlistID];
    return YTAuthVideos([@"pl:" stringByAppendingString:playlistID], browse, nil, need);
}

static NSArray *YTMineUploads(NSInteger need) {
    id lists = YTAuthPost(@"FEplaylist_aggregation", nil, nil);
    NSString *handle = YTFindHandle(lists, 0);
    if (!handle.length) return [NSArray array];
    YTLog([NSString stringWithFormat:@"account @%@", handle]);
    id resolved = YTPostAuth(@"navigation/resolve_url", [NSDictionary dictionaryWithObject:[NSString stringWithFormat:@"https://www.youtube.com/@%@/videos", handle] forKey:@"url"]);
    NSString *browse = YTFindBrowseID(resolved, 0);
    NSString *params = YTFindParams(resolved, 0);
    if (!browse.length) return [NSArray array];
    return YTAuthVideos(@"mine", browse, params, need);
}

static NSArray *YTSubscriptionList(NSInteger need) {
    if (!YTAuthSignedIn()) return [NSArray array];
    if (!YTAPICache) YTAPICache = [NSMutableDictionary dictionary];
    NSMutableArray *cached = [YTAPICache objectForKey:@"sublist"];
    if ([cached count]) return cached;
    id json = YTAuthPost(@"FEsubscriptions", nil, nil);
    NSMutableArray *all = [NSMutableArray array];
    YTCollectTabs(json, all, [NSMutableSet set], 0);
    [YTAPICache setObject:all forKey:@"sublist"];
    YTLog([NSString stringWithFormat:@"subscriptions %u", (unsigned)[all count]]);
    return all;
}

static NSArray *YTPlaylistList(NSInteger need) {
    if (!YTAuthSignedIn()) return [NSArray array];
    if (!YTAPICache) YTAPICache = [NSMutableDictionary dictionary];
    NSMutableArray *cached = [YTAPICache objectForKey:@"pllist"];
    if ([cached count]) return cached;
    id json = YTAuthPost(@"FEplaylist_aggregation", nil, nil);
    NSMutableArray *all = [NSMutableArray array];
    YTCollectTiles(json, nil, all, [NSMutableSet set], 0);
    NSDictionary *specials[] = {
        [NSDictionary dictionaryWithObjectsAndKeys:@"WL", @"playlistId", @"Watch Later", @"title", nil],
        [NSDictionary dictionaryWithObjectsAndKeys:@"LL", @"playlistId", @"Liked", @"title", nil],
    };
    int s;
    for (s = 0; s < 2; s++) {
        NSString *pid = [specials[s] objectForKey:@"playlistId"];
        BOOL found = NO;
        for (NSDictionary *item in all) {
            if ([[item objectForKey:@"playlistId"] isEqualToString:pid]) { found = YES; break; }
        }
        if (!found) [all insertObject:[NSMutableDictionary dictionaryWithDictionary:specials[s]] atIndex:0];
    }
    [YTAPICache setObject:all forKey:@"pllist"];
    YTLog([NSString stringWithFormat:@"playlists %u", (unsigned)[all count]]);
    return all;
}

static NSString *YTSubEntry(NSDictionary *item) {
    NSString *channel = YTEscape([item objectForKey:@"channelId"] ?: @"");
    NSString *title = YTEscape([item objectForKey:@"title"] ?: channel);
    NSString *thumb = YTEscape([item objectForKey:@"thumb"] ?: @"");
    NSString *params = [item objectForKey:@"params"];
    NSString *uploads = params.length
        ? [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/users/default/newsubscriptionvideos?sub=%@", YTQueryEscape(params)]
        : [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/users/%@/uploads", channel];
    return [NSString stringWithFormat:
            @"<entry yt:x='1'>"
            "<id>http://gdata.youtube.com/feeds/api/users/default/subscriptions/%@</id>"
            "<title type='text'>%@</title>"
            "<author yt:x='1'><name yt:x='1'>%@</name><uri>http://gdata.youtube.com/feeds/api/users/%@</uri></author>"
            "<category scheme='http://gdata.youtube.com/schemas/2007/subscriptiontypes.cat' term='channel'/>"
            "<yt:username>%@</yt:username>"
            "<yt:countHint>0</yt:countHint>"
            "<link rel='related' type='application/atom+xml' href='%@'/>"
            "<link rel='edit' type='application/atom+xml' href='http://gdata.youtube.com/feeds/api/users/default/subscriptions/%@'/>"
            "<media:thumbnail url='%@'/>"
            "</entry>",
            channel, title, title, channel, channel, YTEscape(uploads), channel, thumb];
}

static NSString *YTPlaylistEntry(NSDictionary *item) {
    NSString *playlist = YTEscape([item objectForKey:@"playlistId"] ?: @"");
    NSString *title = YTEscape([item objectForKey:@"title"] ?: @"Playlist");
    NSString *desc = YTEscape([item objectForKey:@"description"] ?: @"");
    NSString *count = YTDigits([item objectForKey:@"count"] ?: @"0");
    NSString *thumb = YTEscape([item objectForKey:@"thumb"] ?: @"");
    NSString *href = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/playlists/%@", playlist];
    return [NSString stringWithFormat:
            @"<entry yt:x='1'>"
            "<id>http://gdata.youtube.com/feeds/api/users/default/playlists/%@</id>"
            "<title type='text'>%@</title>"
            "<summary>%@</summary>"
            "<author yt:x='1'><name yt:x='1'>%@</name></author>"
            "<yt:playlistId>%@</yt:playlistId>"
            "<yt:countHint>%@</yt:countHint>"
            "<link rel='http://gdata.youtube.com/schemas/2007#playlist' href='%@'/>"
            "<media:group yt:x='1'><media:title type='plain'>%@</media:title><media:thumbnail url='%@'/></media:group>"
            "</entry>",
            playlist, title, desc, title, playlist, count, YTEscape(href), title, thumb];
}

static NSData *YTRawFeed(NSString *body, NSInteger start, NSUInteger count, NSString *nextURL) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?>"];
    [xml appendString:@"<feed xmlns='http://www.w3.org/2005/Atom' "
                       "xmlns:openSearch='http://a9.com/-/spec/opensearch/1.1/' "
                       "xmlns:media='http://search.yahoo.com/mrss/' "
                       "xmlns:yt='http://gdata.youtube.com/schemas/2007' "
                       "xmlns:gd='http://schemas.google.com/g/2005' "
                       "yt:x='1'>"];
    [xml appendFormat:@"<openSearch:startIndex yt:x='1'>%ld</openSearch:startIndex>", (long)(start < 1 ? 1 : start)];
    [xml appendFormat:@"<openSearch:totalResults yt:x='1'>%u</openSearch:totalResults>", (unsigned)(count + (nextURL.length ? 500 : 0))];
    [xml appendFormat:@"<openSearch:itemsPerPage yt:x='1'>%u</openSearch:itemsPerPage>", (unsigned)count];
    if (nextURL.length) [xml appendFormat:@"<link rel='next' href='%@'/>", YTEscape(nextURL)];
    if (body.length) [xml appendString:body];
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

static NSString *YTNextPage(NSURLRequest *request, NSInteger start, NSInteger limit) {
    NSMutableString *next = [[[request URL] absoluteString] mutableCopy] ?: [NSMutableString string];
    NSString *from = [NSString stringWithFormat:@"start-index=%ld", (long)start];
    NSString *to = [NSString stringWithFormat:@"start-index=%ld", (long)(start + limit)];
    if ([next rangeOfString:from].location != NSNotFound) [next replaceOccurrencesOfString:from withString:to options:0 range:NSMakeRange(0, next.length)];
    else [next appendFormat:@"%@start-index=%ld", [next rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", (long)(start + limit)];
    return next;
}

static NSData *YTAtomForRequest(NSURLRequest *request) {
    NSURL *url = [request URL];
    NSString *path = [url path] ?: @"";
    NSDictionary *query = YTQuery(url);
    NSInteger start = [[query objectForKey:@"start-index"] integerValue];
    NSInteger limit = [[query objectForKey:@"max-results"] integerValue];
    if (start < 1) start = 1;
    if (limit < 1) limit = 10;
    NSArray *parts = [path componentsSeparatedByString:@"/"];
    NSMutableArray *items = [NSMutableArray array];
    NSString *q = [query objectForKey:@"q"];
    NSString *host = [[[request URL] host] lowercaseString] ?: @"";
    if ([host rangeOfString:@"suggestqueries"].location != NSNotFound) return YTSuggestData(request);
    if ([path rangeOfString:@"/comments"].location != NSNotFound) return YTCommentFeed(YTAt(parts, 4));
    if ([path rangeOfString:@"caption"].location != NSNotFound) return YTCaptionFeed(YTAt(parts, 4));
    if ([path rangeOfString:@"/videos/batch"].location != NSNotFound) {
        for (NSString *videoID in YTIDsInBody(YTBodyString(request))) {
            NSDictionary *details = YTDetails(videoID);
            if (details) [items addObject:[NSMutableDictionary dictionaryWithDictionary:details]];
        }
    } else if ([path rangeOfString:@"/related"].location != NSNotFound) {
        [items addObjectsFromArray:YTRelated(YTAt(parts, 4), start + limit)];
    } else if ([path rangeOfString:@"watch_history"].location != NSNotFound) {
        [items addObjectsFromArray:YTAuthVideos(@"history", @"FEhistory", nil, start + limit)];
    } else if ([path rangeOfString:@"/favorites"].location != NSNotFound) {
        [items addObjectsFromArray:YTLiked(start + limit)];
    } else if ([path rangeOfString:@"newsubscriptionvideos"].location != NSNotFound) {
        NSString *sub = [query objectForKey:@"sub"];
        if (sub.length) {
            NSArray *videos = YTAuthVideos([@"subtab:" stringByAppendingString:sub], @"FEsubscriptions", sub, start + limit);
            if (limit <= 1 && videos.count) {
                NSString *avatar = nil;
                for (NSDictionary *row in YTSubscriptionList(1)) {
                    if ([[row objectForKey:@"params"] isEqualToString:sub]) { avatar = [row objectForKey:@"thumb"]; break; }
                }
                if (avatar.length) {
                    NSMutableDictionary *preview = [NSMutableDictionary dictionaryWithDictionary:[videos objectAtIndex:0]];
                    [preview setObject:avatar forKey:@"thumb"];
                    videos = [NSArray arrayWithObject:preview];
                }
            }
            [items addObjectsFromArray:videos];
        } else [items addObjectsFromArray:YTSubVideos(start + limit)];
    } else if ([path rangeOfString:@"/subscriptions"].location != NSNotFound) {
        NSArray *all = YTSubscriptionList(start + limit);
        NSArray *page = YTPage(all, start, limit);
        NSMutableString *body = [NSMutableString string];
        for (NSDictionary *item in page) [body appendString:YTSubEntry(item)];
        YTLog([NSString stringWithFormat:@"atom subs %u", (unsigned)[page count]]);
        return YTRawFeed(body, start, [page count], [all count] >= start + limit - 1 ? YTNextPage(request, start, limit) : nil);
    } else if ([path rangeOfString:@"/users/default/playlists"].location != NSNotFound) {
        NSArray *all = YTPlaylistList(start + limit);
        NSArray *page = YTPage(all, start, limit);
        NSMutableString *body = [NSMutableString string];
        for (NSDictionary *item in page) [body appendString:YTPlaylistEntry(item)];
        YTLog([NSString stringWithFormat:@"atom playlists %u", (unsigned)[page count]]);
        return YTRawFeed(body, start, [page count], [all count] >= start + limit - 1 ? YTNextPage(request, start, limit) : nil);
    } else if ([path rangeOfString:@"/feeds/api/playlists/"].location != NSNotFound) {
        [items addObjectsFromArray:YTPlaylistVideos(YTAt(parts, 4), start + limit)];
    } else if ([path rangeOfString:@"/uploads"].location != NSNotFound) {
        NSString *user = YTAt(parts, 4);
        if (YTAuthSignedIn() && (!user.length || [user isEqualToString:@"default"])) {
            [items addObjectsFromArray:YTMineUploads(start + limit)];
        } else {
            if (!user.length || [user isEqualToString:@"default"]) user = @"music";
            NSArray *uploads = YTPrefBool(@"realChannels", YES) ? YTChannelUploads(user) : [NSArray array];
            [items addObjectsFromArray:uploads.count ? uploads : YTFillKey([@"search:" stringByAppendingString:user], user, nil, start + limit)];
        }
    } else if ([[YTAt(parts, 3) description] isEqualToString:@"videos"] && YTIsVideoID(YTAt(parts, 4)) && !q.length &&
               [path rangeOfString:@"/related"].location == NSNotFound) {
        NSDictionary *details = YTDetails(YTAt(parts, 4));
        if (details) [items addObject:[NSMutableDictionary dictionaryWithDictionary:details]];
    } else if (q.length) {
        [items addObjectsFromArray:YTFillKey([@"search:" stringByAppendingString:q], q, nil, start + limit)];
    } else if ([path rangeOfString:@"most_viewed"].location != NSNotFound) {
        [items addObjectsFromArray:YTMostViewed([query objectForKey:@"time"], YTChartRegion(parts), start + limit)];
    } else if ([path rangeOfString:@"top_rated"].location != NSNotFound) {
        [items addObjectsFromArray:YTMostViewed(@"this_week", YTChartRegion(parts), start + limit)];
    } else if ([path rangeOfString:@"recently_featured"].location != NSNotFound ||
               [[query objectForKey:@"orderby"] isEqualToString:@"updated"]) {
        if (YTAuthSignedIn() && YTPrefBool(@"accountHome", YES)) [items addObjectsFromArray:YTAuthVideos(@"home", @"FEwhat_to_watch", nil, start + limit)];
        else [items addObjectsFromArray:YTMostViewed(@"this_week", YTChartRegion(parts), start + limit)];
    } else if ([path rangeOfString:@"/feeds/api/videos"].location != NSNotFound) {
        if (YTAuthSignedIn() && YTPrefBool(@"accountHome", YES)) [items addObjectsFromArray:YTAuthVideos(@"home", @"FEwhat_to_watch", nil, start + limit)];
        else [items addObjectsFromArray:YTMostViewed(@"this_week", YTChartRegion(parts), start + limit)];
    }
    NSArray *page = YTPage(items, start, limit);
    YTLog([NSString stringWithFormat:@"atom %@ q=%@ items %u page %u", path, q ?: @"", (unsigned)[items count], (unsigned)[page count]]);
    NSMutableArray *mutable = [NSMutableArray array];
    for (NSDictionary *item in page) [mutable addObject:[NSMutableDictionary dictionaryWithDictionary:item]];
    NSString *nextURL = nil;
    if (YTPrefBool(@"paging", YES) && [items count] >= start + limit - 1) {
        NSMutableString *next = [[[request URL] absoluteString] mutableCopy] ?: [NSMutableString string];
        NSString *from = [NSString stringWithFormat:@"start-index=%ld", (long)start];
        NSString *to = [NSString stringWithFormat:@"start-index=%ld", (long)(start + limit)];
        if ([next rangeOfString:from].location != NSNotFound) [next replaceOccurrencesOfString:from withString:to options:0 range:NSMakeRange(0, next.length)];
        else [next appendFormat:@"%@start-index=%ld", [next rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", (long)(start + limit)];
        nextURL = next;
    }
    return YTFeed(mutable, start, nextURL);
}

@interface YTInnerProtocol : NSURLProtocol
@property (nonatomic, assign) BOOL cancelled;
@end

@implementation YTInnerProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:YTMark inRequest:request]) return NO;
    NSString *path = [[request URL] path] ?: @"";
    NSString *host = [[[request URL] host] lowercaseString] ?: @"";
    if ([host isEqualToString:@"gdata.youtube.com"]) return YES;
    if ([path rangeOfString:@"/feeds/api/"].location != NSNotFound) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)deliver:(NSData *)body {
    if (self.cancelled) return;
    id<NSURLProtocolClient> client = [self client];
    YTLog([NSString stringWithFormat:@"deliver %u bytes %@", (unsigned)[body length], [[[self request] URL] path]]);
    if (![body length]) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
        [client URLProtocol:self didFailWithError:error];
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[[self request] URL]
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:[NSDictionary dictionaryWithObject:@"text/xml; charset=utf-8" forKey:@"Content-Type"]];
    [client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [client URLProtocol:self didLoadData:body];
    [client URLProtocolDidFinishLoading:self];
}

- (void)startLoading {
    NSURLRequest *request = [self request];
    YTLog([NSString stringWithFormat:@"protocol %@", [[request URL] absoluteString]]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *body = nil;
        @try {
            body = YTAtomForRequest(request);
        } @catch (NSException *exception) {
            YTLog([NSString stringWithFormat:@"exception %@", exception]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self deliver:body];
        });
    });
}

- (void)stopLoading {
    self.cancelled = YES;
}

@end

static void YTDeliverLogin(id connection, id delegate, NSURLRequest *request);

@interface YTFakeConnection : NSURLConnection
@property (nonatomic, assign) id feedDelegate;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, retain) NSURLRequest *loginRequest;
- (void)begin:(NSURLRequest *)request;
@end

@implementation YTFakeConnection
- (void)cancel { self.cancelled = YES; }
- (void)start {
    if (!self.loginRequest) return;
    NSURLRequest *request = self.loginRequest;
    self.loginRequest = nil;
    YTDeliverLogin(self, self.feedDelegate, request);
}
- (void)begin:(NSURLRequest *)request {
    YTLog([NSString stringWithFormat:@"hook %@", [[request URL] absoluteString]]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *body = nil;
        @try {
            body = YTAtomForRequest(request);
        } @catch (NSException *exception) {
            YTLog([NSString stringWithFormat:@"hook exception %@", exception]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.cancelled || !self.feedDelegate) return;
            id delegate = self.feedDelegate;
            if (![body length]) {
                NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
                if ([delegate respondsToSelector:@selector(connection:didFailWithError:)]) {
                    [delegate connection:self didFailWithError:error];
                }
                return;
            }
            NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[request URL]
                                                                      statusCode:200
                                                                     HTTPVersion:@"HTTP/1.1"
                                                                    headerFields:[NSDictionary dictionaryWithObject:@"text/xml; charset=utf-8" forKey:@"Content-Type"]];
            if ([delegate respondsToSelector:@selector(connection:didReceiveResponse:)]) {
                [delegate connection:self didReceiveResponse:response];
            }
            if ([delegate respondsToSelector:@selector(connection:didReceiveData:)]) {
                [delegate connection:self didReceiveData:body];
            }
            if ([delegate respondsToSelector:@selector(connectionDidFinishLoading:)]) {
                [delegate connectionDidFinishLoading:self];
            }
            YTLog([NSString stringWithFormat:@"hook delivered %u", (unsigned)[body length]]);
        });
    });
}
@end

static void YTDeliverLogin(id connection, id delegate, NSURLRequest *request) {
    NSData *body = [@"SID=ytinner\r\nLSID=ytinner\r\nAuth=ytinner\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:[request URL]
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:[NSDictionary dictionaryWithObject:@"text/plain" forKey:@"Content-Type"]];
    if ([delegate respondsToSelector:@selector(connection:didReceiveResponse:)]) [delegate connection:connection didReceiveResponse:response];
    if ([delegate respondsToSelector:@selector(connection:didReceiveData:)]) [delegate connection:connection didReceiveData:body];
    if ([delegate respondsToSelector:@selector(connectionDidFinishLoading:)]) [delegate connectionDidFinishLoading:connection];
    YTLog(@"applelogin forged");
}

static id (*YTOrigInitConn)(id, SEL, NSURLRequest *, id, BOOL);
static id YTHookInitConn(id self, SEL cmd, NSURLRequest *request, id delegate, BOOL start) {
    if (YTIsDeadLogin(request)) {
        YTLog(@"skip applelogin");
        YTFakeConnection *connection = [[YTFakeConnection alloc] init];
        connection.feedDelegate = delegate;
        connection.loginRequest = request;
        if (start) dispatch_async(dispatch_get_main_queue(), ^{ [connection start]; });
        return connection;
    }
    if (YTShouldHandle(request)) {
        YTFakeConnection *connection = [[YTFakeConnection alloc] init];
        connection.feedDelegate = delegate;
        if (start) [connection begin:request];
        return connection;
    }
    return YTOrigInitConn(self, cmd, request, delegate, start);
}

static void YTWriteCrash(NSString *text) {
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

static void YTExceptionHandler(NSException *exception) {
    NSArray *stack = [exception callStackSymbols];
    NSString *report = [NSString stringWithFormat:@"exception %@\n%@\n%@", exception.name, exception.reason, [stack componentsJoinedByString:@"\n"]];
    YTWriteCrash(report);
}

static void YTSignalHandler(int sig, siginfo_t *info, void *ctx) {
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

static void YTInstallCrashHandler(void) {
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

static void YTFinishLoad(id self, NSURL *url, NSData *body) {
    YTLog([NSString stringWithFormat:@"load back %u %@", (unsigned)[body length], NSStringFromClass([self class])]);
    if (![body length] || !url) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
        @try { [self connection:nil didFailWithError:error]; } @catch (NSException *exception) { YTWriteCrash(exception.reason); }
        return;
    }
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url
                                                              statusCode:200
                                                             HTTPVersion:@"HTTP/1.1"
                                                            headerFields:[NSDictionary dictionaryWithObject:([[[url host] lowercaseString] rangeOfString:@"suggest"].location != NSNotFound ? @"application/json; charset=utf-8" : @"application/atom+xml; charset=utf-8") forKey:@"Content-Type"]];
    NSString *sample = [[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(0, MIN((NSUInteger)180, [body length]))] encoding:NSUTF8StringEncoding];
    YTLog([NSString stringWithFormat:@"xml %@", sample]);
    @try {
        [self connection:nil didReceiveResponse:response];
        [self connection:nil didReceiveData:body];
        [self connectionDidFinishLoading:nil];
        YTLog([NSString stringWithFormat:@"load delivered %u", (unsigned)[body length]]);
    } @catch (NSException *exception) {
        YTWriteCrash([NSString stringWithFormat:@"parse %@\n%@\n%@", exception.name, exception.reason, [[exception callStackSymbols] componentsJoinedByString:@"\n"]]);
        @try { [self connection:nil didFailWithError:[NSError errorWithDomain:@"com.sokubit.5tube" code:2 userInfo:nil]]; }
        @catch (NSException *ignored) {}
    }
}

static void YTStartLoad(id self, id request) {
    YTAuthDidLoad = YES;
    NSURL *url = [request respondsToSelector:@selector(URL)] ? [request URL] : nil;
    YTLog([NSString stringWithFormat:@"loadRequest %@ %@", NSStringFromClass([self class]), [url absoluteString]]);
    if ([self respondsToSelector:@selector(_startedLoading)]) [self performSelector:@selector(_startedLoading)];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *body = nil;
        @try {
            body = YTAtomForRequest(request);
        } @catch (NSException *exception) {
            YTLog([NSString stringWithFormat:@"load exception %@", exception]);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            YTFinishLoad(self, url, body);
        });
    });
}

static void (*YTOrigSAXLoad)(id, SEL, id);
static void YTHookSAXLoad(id self, SEL cmd, id request) {
    if ([request isKindOfClass:[NSURLRequest class]] && YTShouldHandle(request)) {
        YTStartLoad(self, request);
        return;
    }
    YTOrigSAXLoad(self, cmd, request);
}

static void (*YTOrigFeedLoad)(id, SEL, id);
static void YTHookFeedLoad(id self, SEL cmd, id request) {
    if ([request isKindOfClass:[NSURLRequest class]] && YTShouldHandle(request)) {
        YTAuthDidLoad = YES;
        YTStartLoad(self, request);
        return;
    }
    YTOrigFeedLoad(self, cmd, request);
}

static void (*YTOrigAuthLoad)(id, SEL, id, id, BOOL);
static void YTHookAuthLoad(id self, SEL cmd, id request, id delegate, BOOL auth) {
    NSURL *url = [request respondsToSelector:@selector(URL)] ? [request URL] : nil;
    YTLog([NSString stringWithFormat:@"loadAuth %d %@", auth, [url absoluteString]]);
    if ([request isKindOfClass:[NSURLRequest class]] && YTShouldHandle(request)) {
        YTAuthDidLoad = NO;
        if (YTOrigAuthLoad) YTOrigAuthLoad(self, cmd, request, delegate, auth);
        if (!YTAuthDidLoad) YTStartLoad(self, request);
        return;
    }
    if (YTOrigAuthLoad) YTOrigAuthLoad(self, cmd, request, delegate, auth);
}

static void (*YTOrigSearchFail)(id, SEL, id);
static void YTHookSearchFail(id self, SEL cmd, id error) {
    YTLog([NSString stringWithFormat:@"fail %@ %@", NSStringFromClass([self class]), error]);
    YTOrigSearchFail(self, cmd, error);
}

static void (*YTOrigFeedFail)(id, SEL, id);
static void YTHookFeedFail(id self, SEL cmd, id error) {
    YTLog([NSString stringWithFormat:@"fail %@ %@", NSStringFromClass([self class]), error]);
    YTOrigFeedFail(self, cmd, error);
}

static void (*YTOrigFeedParse)(id, SEL);
static void YTHookFeedParse(id self, SEL cmd) {
    YTLog([NSString stringWithFormat:@"parsed %@", NSStringFromClass([self class])]);
    YTOrigFeedParse(self, cmd);
}

static void YTHookMethod(Class cls, NSString *selName, IMP hook, IMP *orig) {
    if (!cls || !hook) return;
    Method method = class_getInstanceMethod(cls, NSSelectorFromString(selName));
    if (!method) return;
    if (method_getImplementation(method) == hook) return;
    if (orig && !*orig) *orig = method_getImplementation(method);
    method_setImplementation(method, hook);
    YTLog([NSString stringWithFormat:@"hooked %@ %@", NSStringFromClass(cls), selName]);
}

static id YTGlobalString(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (!sym) return nil;
    id value = *(__unsafe_unretained id *)sym;
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

static id YTPSDelegate(id request) {
    Class cls = [request class];
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, "_delegate");
        if (ivar) return object_getIvar(request, ivar);
        cls = class_getSuperclass(cls);
    }
    if ([request respondsToSelector:@selector(delegate)]) return [request performSelector:@selector(delegate)];
    return nil;
}

static NSArray *YTPSItems(BOOL playlists) {
    NSArray *raw = playlists ? YTPlaylistList(40) : YTSubscriptionList(80);
    Class cls = NSClassFromString(@"YTSubscriptionsRequest");
    SEL urlSel = @selector(URLForSubscription:);
    SEL nameSel = @selector(displayStringForSubscription:);
    id (*urlProbe)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
    NSString *hrefKey = nil;
    NSString *labelKey = nil;
    NSArray *hrefGuess = [NSArray arrayWithObjects:@"href", @"Href", @"url", @"URL", @"edit", @"link", @"playlistId", nil];
    NSArray *labelGuess = [NSArray arrayWithObjects:@"Label", @"label", @"name", @"title", @"Username", @"username", nil];
    if (cls && [cls respondsToSelector:urlSel]) {
        for (NSString *key in hrefGuess) {
            NSDictionary *test = [NSDictionary dictionaryWithObject:@"probe-value" forKey:key];
            id result = urlProbe(cls, urlSel, test);
            if ([result isKindOfClass:[NSString class]] && [(NSString *)result length]) { hrefKey = key; break; }
        }
    }
    if (cls && [cls respondsToSelector:nameSel]) {
        for (NSString *key in labelGuess) {
            NSDictionary *test = [NSDictionary dictionaryWithObject:@"probe-value" forKey:key];
            id result = urlProbe(cls, nameSel, test);
            if ([result isKindOfClass:[NSString class]] && [(NSString *)result length]) { labelKey = key; break; }
        }
    }
    id hrefGlobal = YTGlobalString("YTSubscriptionsCategoryHrefKey");
    id labelGlobal = YTGlobalString("YTSubscriptionsCategoryLabelKey");
    id editGlobal = YTGlobalString("YTSubscriptionsEditURLKey");
    id countGlobal = YTGlobalString("YTSubscriptionsCountKey");
    id schemeGlobal = YTGlobalString("YTSubscriptionsCategorySchemeKey");
    id needGlobal = YTGlobalString("YTSubscriptionsCategoryNeedsAccountAuthenticationKey");
    YTLog([NSString stringWithFormat:@"ps keys href=%@ label=%@ ghref=%@", hrefKey, labelKey, hrefGlobal]);
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *item in raw) {
        NSString *title = [item objectForKey:@"title"] ?: @"Item";
        NSString *cid = [item objectForKey:@"playlistId"] ?: [item objectForKey:@"channelId"] ?: title;
        NSString *params = [item objectForKey:@"params"];
        NSString *href = nil;
        if (playlists) href = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/playlists/%@", cid];
        else if (params.length) href = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/users/default/newsubscriptionvideos?sub=%@", YTQueryEscape(params)];
        else href = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/users/%@/uploads", cid];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (NSString *key in [NSArray arrayWithObjects:@"href", @"Href", @"url", @"URL", @"edit", @"link", @"Label", @"label", @"name", @"title", @"Username", @"username", @"scheme", @"SubscriptionScheme", @"count", nil]) {
            BOOL text = [key isEqualToString:@"Label"] || [key isEqualToString:@"label"] || [key isEqualToString:@"name"] || [key isEqualToString:@"title"] || [key isEqualToString:@"Username"] || [key isEqualToString:@"username"];
            BOOL scheme = [key isEqualToString:@"scheme"] || [key isEqualToString:@"SubscriptionScheme"];
            if (text) [dict setObject:title forKey:key];
            else if (scheme) [dict setObject:(playlists ? @"playlist" : @"channel") forKey:key];
            else if ([key isEqualToString:@"count"]) [dict setObject:[NSNumber numberWithInt:playlists ? (int)[[item objectForKey:@"count"] integerValue] : 1] forKey:key];
            else [dict setObject:href forKey:key];
        }
        [dict setObject:cid forKey:@"playlistId"];
        [dict setObject:href forKey:@"href"];
        if (hrefKey) [dict setObject:href forKey:hrefKey];
        if (labelKey) [dict setObject:title forKey:labelKey];
        if (hrefGlobal) [dict setObject:href forKey:hrefGlobal];
        if (labelGlobal) [dict setObject:title forKey:labelGlobal];
        if (editGlobal) [dict setObject:href forKey:editGlobal];
        if (countGlobal) [dict setObject:[NSNumber numberWithInt:playlists ? (int)[[item objectForKey:@"count"] integerValue] : 1] forKey:countGlobal];
        if (schemeGlobal) [dict setObject:(playlists ? @"playlist" : @"channel") forKey:schemeGlobal];
        if (needGlobal) [dict setObject:[NSNumber numberWithBool:NO] forKey:needGlobal];
        [out addObject:dict];
    }
    return out;
}

static void YTDeliverPS(id request, BOOL playlists) {
    NSArray *items = YTPSItems(playlists);
    id delegate = YTPSDelegate(request);
    YTLog([NSString stringWithFormat:@"deliver %@ %u %@", playlists ? @"playlists" : @"subscriptions", (unsigned)[items count], NSStringFromClass([delegate class])]);
    SEL sel = @selector(subscriptionsRequest:receivedSubscriptions:);
    if ([delegate respondsToSelector:sel]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, request, items);
    }
    if ([delegate respondsToSelector:@selector(setLoading:)]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(delegate, @selector(setLoading:), NO);
    }
}

static BOOL YTAct(NSString *method, NSDictionary *body) {
    id json = YTPostAuth(method, body);
    BOOL ok = [json isKindOfClass:[NSDictionary class]] && ![json objectForKey:@"error"];
    YTLog([NSString stringWithFormat:@"act %@ %@", method, ok ? @"ok" : @"fail"]);
    return ok;
}

static NSString *YTVideoToken(id video) {
    if ([video isKindOfClass:[NSString class]]) {
        if (YTIsVideoID((NSString *)video)) return video;
        NSString *text = video;
        NSUInteger i;
        for (i = 0; i + 11 <= text.length; i++) {
            NSString *bit = [text substringWithRange:NSMakeRange(i, 11)];
            if (YTIsVideoID(bit)) return bit;
        }
        return nil;
    }
    SEL names[3];
    names[0] = @selector(shortID);
    names[1] = @selector(ID);
    names[2] = @selector(videoID);
    int i;
    for (i = 0; i < 3; i++) {
        if ([video respondsToSelector:names[i]]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(video, names[i]);
            NSString *found = YTVideoToken(value);
            if (found.length) return found;
        }
    }
    return nil;
}

static NSString *YTResolveChannel(NSString *name) {
    if (!name.length) return nil;
    if ([name hasPrefix:@"UC"] && name.length > 20) return name;
    NSArray *urls = [NSArray arrayWithObjects:
                     [NSString stringWithFormat:@"https://www.youtube.com/@%@", name],
                     [NSString stringWithFormat:@"https://www.youtube.com/user/%@", name],
                     [NSString stringWithFormat:@"https://www.youtube.com/c/%@", name], nil];
    for (NSString *url in urls) {
        id json = YTPostAuth(@"navigation/resolve_url", [NSDictionary dictionaryWithObject:url forKey:@"url"]);
        NSString *browse = YTFindBrowseID(json, 0);
        if ([browse hasPrefix:@"UC"]) return browse;
    }
    return nil;
}

static NSString *YTTailID(id value) {
    NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
    if (!text.length) return nil;
    NSString *name = [text lastPathComponent];
    NSRange q = [name rangeOfString:@"?"];
    if (q.location != NSNotFound) name = [name substringToIndex:q.location];
    return name.length ? name : nil;
}

static void YTFinishPostError(id self, int type, id error) {
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(YTAuthenticatedAccountPost:didFinishWithType:error:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, int, id))objc_msgSend)(delegate, sel, self, type, error);
}

static void YTFinishPost(id self, int type) {
    YTFinishPostError(self, type, nil);
}

static void YTHookPostComment(id self, SEL cmd, id text, id video) {
    NSString *vid = YTVideoToken(video);
    NSString *body = [text isKindOfClass:[NSString class]] ? text : [text description];
    body = [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!YTCommentParams) YTCommentParams = [NSMutableDictionary dictionary];
    NSString *params = vid.length ? [YTCommentParams objectForKey:vid] : nil;
    if (!params.length && vid.length) {
        id json = YTPost(@"next", [NSDictionary dictionaryWithObject:vid forKey:@"videoId"]);
        YTSaveCommentParams(vid, json);
        params = [YTCommentParams objectForKey:vid];
    }
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    [payload setObject:(body ?: @"") forKey:@"commentText"];
    if (params.length) [payload setObject:params forKey:@"createCommentParams"];
    BOOL ok = body.length && params.length && YTAct(@"comment/create_comment", payload);
    if (!ok && body.length && params.length) {
        id json = YTPostWeb(@"comment/create_comment", payload);
        ok = [json isKindOfClass:[NSDictionary class]] && ![json objectForKey:@"error"];
        YTLog([NSString stringWithFormat:@"comment web %@", ok ? @"ok" : @"fail"]);
    }
    YTFinishPostError(self, 5, ok ? nil : [NSError errorWithDomain:@"com.sokubit.5tube" code:1 userInfo:nil]);
    YTLog([NSString stringWithFormat:@"comment %@ %@", vid ?: @"-", ok ? @"ok" : @"fail"]);
}

static NSDictionary *YTLikeBody(NSString *videoID) {
    return [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:(videoID ?: @"") forKey:@"videoId"] forKey:@"target"];
}

static void YTHookRate(id self, SEL cmd, int liked, id video) {
    NSString *vid = YTVideoToken(video);
    BOOL ok = YTAct(liked ? @"like/like" : @"like/dislike", YTLikeBody(vid));
    if (ok) YTFinishPost(self, 10);
    YTLog([NSString stringWithFormat:@"rate %d %@", liked, vid ?: @"-"]);
}

static void YTHookAddFav(id self, SEL cmd, id video) {
    NSString *vid = YTVideoToken(video);
    if (YTAct(@"like/like", YTLikeBody(vid))) YTFinishPost(self, 1);
    YTLog([NSString stringWithFormat:@"favorite %@", vid ?: @"-"]);
}

static void YTHookRemoveFav(id self, SEL cmd, id video) {
    NSString *vid = YTVideoToken(video);
    if (YTAct(@"like/removelike", YTLikeBody(vid))) YTFinishPost(self, 2);
    YTLog([NSString stringWithFormat:@"unfavorite %@", vid ?: @"-"]);
}

static void YTHookSubscribe(id self, SEL cmd, id user) {
    NSString *name = [user isKindOfClass:[NSString class]] ? user : YTTailID(user);
    NSString *channel = YTResolveChannel(name);
    BOOL ok = channel.length && YTAct(@"subscription/subscribe", [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:channel] forKey:@"channelIds"]);
    YTLog([NSString stringWithFormat:@"subscribe %@ %@", name, ok ? @"ok" : @"fail"]);
    if (!ok) return;
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    NSString *href = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/users/%@/uploads", channel];
    [item setObject:(name ?: channel) forKey:@"Label"];
    [item setObject:(name ?: channel) forKey:@"label"];
    [item setObject:href forKey:@"href"];
    [item setObject:@"channel" forKey:@"scheme"];
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(subscriptionsRequest:receivedSubscriptions:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, self, [NSArray arrayWithObject:item]);
}

static void YTHookUnsubscribe(id self, SEL cmd, id sub) {
    NSString *name = [sub isKindOfClass:[NSDictionary class]] ? ([sub objectForKey:@"Label"] ?: [sub objectForKey:@"label"] ?: [sub objectForKey:@"username"]) : YTTailID(sub);
    NSString *channel = YTResolveChannel(name);
    BOOL ok = channel.length && YTAct(@"subscription/unsubscribe", [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:channel] forKey:@"channelIds"]);
    if (ok) YTFinishPost(self, 4);
    YTLog([NSString stringWithFormat:@"unsubscribe %@ %@", name, ok ? @"ok" : @"fail"]);
}

static void YTHookCreateList(id self, SEL cmd, id name) {
    NSString *title = [name isKindOfClass:[NSString class]] ? name : [name description];
    BOOL ok = YTAct(@"playlist/create", [NSDictionary dictionaryWithObjectsAndKeys:title ?: @"", @"title", @"PRIVATE", @"privacyStatus", nil]);
    YTLog([NSString stringWithFormat:@"create playlist %@ %@", title, ok ? @"ok" : @"fail"]);
    if (!ok) return;
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    [item setObject:title forKey:@"Label"];
    [item setObject:title forKey:@"label"];
    [item setObject:[NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/playlists/%@", YTQueryEscape(title)] forKey:@"href"];
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(subscriptionsRequest:receivedSubscriptions:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, self, [NSArray arrayWithObject:item]);
}

static void YTHookAddToList(id self, SEL cmd, id video, id playlistURL) {
    NSString *vid = YTVideoToken(video);
    NSString *playlist = YTTailID(playlistURL);
    NSDictionary *action = [NSDictionary dictionaryWithObjectsAndKeys:@"ACTION_ADD_VIDEO", @"action", vid ?: @"", @"addedVideoId", nil];
    BOOL ok = vid.length && playlist.length && YTAct(@"browse/edit_playlist", [NSDictionary dictionaryWithObjectsAndKeys:playlist, @"playlistId", [NSArray arrayWithObject:action], @"actions", nil]);
    YTLog([NSString stringWithFormat:@"add %@ to %@ %@", vid, playlist, ok ? @"ok" : @"fail"]);
    if (!ok || !video) return;
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(accountFeedRequest:receivedVideos:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, self, [NSArray arrayWithObject:video]);
}

static void YTHookRequestSubs(id self, SEL cmd) {
    YTLog(@"requestSubscriptions");
    dispatch_async(dispatch_get_main_queue(), ^{ YTDeliverPS(self, NO); });
}

static void YTHookRequestPlaylists(id self, SEL cmd) {
    YTLog(@"requestPlaylists");
    dispatch_async(dispatch_get_main_queue(), ^{ YTDeliverPS(self, YES); });
}

static void YTHookPSFail(id self, SEL cmd, id error) {
    YTLog([NSString stringWithFormat:@"ps fail %@", error]);
}

static void YTStoreIvar(id obj, NSString *name, id value) {
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

static BOOL YTCanTakeSearch(id source) {
    return [source respondsToSelector:@selector(searchRequest:receivedVideos:startIndex:videosRemaining:)];
}

static void YTLoadAccountFeed(id source, NSString *urlString, NSString *label) {
    if (!YTCanTakeSearch(source)) return;
    Class cls = NSClassFromString(@"YTSearchRequest");
    if (!cls) return;
    id request = [[cls alloc] init];
    // The feed request keeps its delegate unretained. Hold the data source for
    // as long as the request lives, so a closed screen is not messaged after
    // its memory has been reused as an NSData or an NSString.
    objc_setAssociatedObject(request, "YTSearchDelegate", source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([request respondsToSelector:@selector(setDelegate:)])
        ((void (*)(id, SEL, id))objc_msgSend)(request, @selector(setDelegate:), source);
    if ([request respondsToSelector:@selector(loadRequest:)])
        ((void (*)(id, SEL, id))objc_msgSend)(request, @selector(loadRequest:), [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]]);
    YTLog(label);
}

static void (*YTOrigHistoryReload)(id, SEL);
static void YTHookHistoryReload(id self, SEL cmd) {
    if (!YTAuthSignedIn() || !YTPrefBool(@"accountHistory", YES) || !YTCanTakeSearch(self)) {
        if (YTOrigHistoryReload) YTOrigHistoryReload(self, cmd);
        return;
    }
    @try {
        if ([self respondsToSelector:@selector(_clearVideos)]) [self performSelector:@selector(_clearVideos)];
        else YTStoreIvar(self, @"_videos", [NSMutableArray array]);
        YTStoreIvar(self, @"_history", [NSMutableArray array]);
    } @catch (NSException *exception) {
        YTLog([NSString stringWithFormat:@"history clear %@", exception]);
    }
    YTLoadAccountFeed(self, @"http://gdata.youtube.com/feeds/api/users/default/watch_history?start-index=1&max-results=40", @"history reload");
}

static void (*YTOrigMyVideosReload)(id, SEL);
static void YTHookMyVideosReload(id self, SEL cmd) {
    if (!YTAuthSignedIn() || !YTCanTakeSearch(self)) {
        if (YTOrigMyVideosReload) YTOrigMyVideosReload(self, cmd);
        return;
    }
    @try {
        if ([self respondsToSelector:@selector(_clearVideos)]) [self performSelector:@selector(_clearVideos)];
    } @catch (NSException *exception) {
        YTLog([NSString stringWithFormat:@"my videos clear %@", exception]);
    }
    YTLoadAccountFeed(self, @"http://gdata.youtube.com/feeds/api/users/default/uploads?start-index=1&max-results=25", @"my videos reload");
}

static void YTHookSAX(void) {
    YTHookMethod(NSClassFromString(@"XMLSAXHTTPRequest"), @"loadRequest:", (IMP)YTHookSAXLoad, (IMP *)&YTOrigSAXLoad);
    YTHookMethod(NSClassFromString(@"YTFeedRequest"), @"loadRequest:", (IMP)YTHookFeedLoad, (IMP *)&YTOrigFeedLoad);
    YTHookMethod(NSClassFromString(@"YTFeedRequest"), @"loadRequest:withDelegate:accountAuthRequired:", (IMP)YTHookAuthLoad, (IMP *)&YTOrigAuthLoad);
    YTHookMethod(NSClassFromString(@"YTSearchRequest"), @"failWithError:", (IMP)YTHookSearchFail, (IMP *)&YTOrigSearchFail);
    YTHookMethod(NSClassFromString(@"YTFeedRequest"), @"failWithError:", (IMP)YTHookFeedFail, (IMP *)&YTOrigFeedFail);
    YTHookMethod(NSClassFromString(@"YTFeedRequest"), @"didParseData", (IMP)YTHookFeedParse, (IMP *)&YTOrigFeedParse);
    Class subs = NSClassFromString(@"YTSubscriptionsRequest");
    YTHookMethod(subs, @"requestSubscriptions", (IMP)YTHookRequestSubs, NULL);
    YTHookMethod(subs, @"requestPlaylists", (IMP)YTHookRequestPlaylists, NULL);
    YTHookMethod(subs, @"failWithError:", (IMP)YTHookPSFail, NULL);
    YTHookMethod(subs, @"subscribeToUser:", (IMP)YTHookSubscribe, NULL);
    YTHookMethod(subs, @"createPlaylistNamed:", (IMP)YTHookCreateList, NULL);
    Class post = NSClassFromString(@"YTAuthenticatedAccountPost");
    YTHookMethod(post, @"setRating:forVideo:", (IMP)YTHookRate, NULL);
    YTHookMethod(post, @"addVideoToFavorites:", (IMP)YTHookAddFav, NULL);
    YTHookMethod(post, @"removeVideoFromFavorites:", (IMP)YTHookRemoveFav, NULL);
    YTHookMethod(post, @"unsubscribeToSubscription:", (IMP)YTHookUnsubscribe, NULL);
    YTHookMethod(post, @"postComment:forVideo:", (IMP)YTHookPostComment, NULL);
    YTHookMethod(NSClassFromString(@"YTAccountFeedRequest"), @"addVideo:toPlaylist:", (IMP)YTHookAddToList, NULL);
    YTHookMethod(NSClassFromString(@"YTHistoryVideoDataSource"), @"reloadData", (IMP)YTHookHistoryReload, (IMP *)&YTOrigHistoryReload);
    YTHookMethod(NSClassFromString(@"YTMyVideosVideoDataSource"), @"reloadData", (IMP)YTHookMyVideosReload, (IMP *)&YTOrigMyVideosReload);
}

static NSURLConnection *(*YTOrigConnect)(id, SEL, NSURLRequest *, id);

static NSData *(*YTOrigSync)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **);
static NSData *YTHookSync(id self, SEL cmd, NSURLRequest *request, NSURLResponse **response, NSError **error) {
    if (YTIsDeadLogin(request)) {
        YTLog(@"skip applelogin sync");
        if (response) {
            *response = [[NSHTTPURLResponse alloc] initWithURL:[request URL] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:[NSDictionary dictionaryWithObject:@"text/plain" forKey:@"Content-Type"]];
        }
        if (error) *error = nil;
        return [@"SID=ytinner\r\nLSID=ytinner\r\nAuth=ytinner\r\n" dataUsingEncoding:NSUTF8StringEncoding];
    }
    return YTOrigSync(self, cmd, request, response, error);
}

static NSURLConnection *YTHookConnect(id self, SEL cmd, NSURLRequest *request, id delegate) {
    if (YTIsDeadLogin(request)) {
        YTLog(@"skip applelogin");
        YTFakeConnection *connection = [[YTFakeConnection alloc] init];
        connection.feedDelegate = delegate;
        connection.loginRequest = request;
        dispatch_async(dispatch_get_main_queue(), ^{ [connection start]; });
        return connection;
    }
    if (YTShouldHandle(request)) {
        YTFakeConnection *connection = [[YTFakeConnection alloc] init];
        connection.feedDelegate = delegate;
        [connection begin:request];
        return connection;
    }
    return YTOrigConnect(self, cmd, request, delegate);
}

static BOOL YTWriteAll(int fd, const void *bytes, size_t length) {
    const char *cursor = bytes;
    while (length) {
        ssize_t wrote = write(fd, cursor, length);
        if (wrote < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        cursor += wrote;
        length -= wrote;
    }
    return YES;
}

static NSString *YTHeader(NSDictionary *headers, NSString *name) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return [headers objectForKey:key];
    }
    return nil;
}

static NSString *YTVideoIDFromPath(NSString *path) {
    if (![path isKindOfClass:[NSString class]]) return nil;
    NSRange query = [path rangeOfString:@"?"];
    if (query.location != NSNotFound) path = [path substringToIndex:query.location];
    NSRange slash = [path rangeOfString:@"/" options:NSBackwardsSearch];
    NSString *name = slash.location == NSNotFound ? path : [path substringFromIndex:slash.location + 1];
    NSRange dot = [name rangeOfString:@".mp4" options:NSCaseInsensitiveSearch];
    if (dot.location != NSNotFound) name = [name substringToIndex:dot.location];
    if ([name hasSuffix:@".360"]) name = [name substringToIndex:name.length - 4];
    return YTIsVideoID(name) ? name : nil;
}

@interface YTProxyFetch : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, assign) BOOL head;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) BOOL sent;
@end

@implementation YTProxyFetch
- (void)fail:(int)code {
    if (!self.sent) {
        NSString *body = [NSString stringWithFormat:@"HTTP/1.1 %d Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", code];
        YTWriteAll(self.fd, [body UTF8String], [body length]);
        self.sent = YES;
    }
    self.done = YES;
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    if (![response isKindOfClass:[NSHTTPURLResponse class]]) {
        [self fail:502];
        [connection cancel];
        return;
    }
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSInteger code = [http statusCode];
    if (code >= 400) {
        YTLog([NSString stringWithFormat:@"proxy upstream %ld", (long)code]);
        [self fail:(int)code];
        [connection cancel];
        return;
    }
    NSDictionary *headers = [http allHeaderFields];
    NSString *type = YTHeader(headers, @"Content-Type") ?: @"video/mp4";
    NSString *length = YTHeader(headers, @"Content-Length");
    NSString *range = YTHeader(headers, @"Content-Range");
    NSMutableString *head = [NSMutableString string];
    [head appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)code, code == 206 ? @"Partial Content" : @"OK"];
    [head appendFormat:@"Content-Type: %@\r\n", type];
    if (length.length) [head appendFormat:@"Content-Length: %@\r\n", length];
    if (range.length) [head appendFormat:@"Content-Range: %@\r\n", range];
    [head appendString:@"Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"];
    if (!YTWriteAll(self.fd, [head UTF8String], [head length])) {
        [connection cancel];
        self.done = YES;
        return;
    }
    self.sent = YES;
    if (self.head) {
        [connection cancel];
        self.done = YES;
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData *)data {
    if (self.head || !self.sent) return;
    if (!YTWriteAll(self.fd, [data bytes], [data length])) {
        [connection cancel];
        self.done = YES;
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection *)connection {
    self.done = YES;
}

- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    YTLog([NSString stringWithFormat:@"proxy fail %@", error]);
    [self fail:502];
}

- (void)run:(NSURLRequest *)request {
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:NO];
    [connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    [connection start];
    while (!self.done) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
}
@end

static void YTServeFile(int client, NSString *path, NSString *range, BOOL head) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return;
    unsigned long long size = [file seekToEndOfFile];
    unsigned long long start = 0;
    unsigned long long end = size ? size - 1 : 0;
    BOOL partial = NO;
    if (range.length) {
        NSRange marker = [range rangeOfString:@"bytes="];
        NSString *spec = marker.location == NSNotFound ? range : [range substringFromIndex:marker.location + 6];
        NSArray *bits = [spec componentsSeparatedByString:@"-"];
        if (bits.count >= 2 && size) {
            start = [[[bits objectAtIndex:0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] longLongValue];
            NSString *tail = [[bits objectAtIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            end = tail.length ? [tail longLongValue] : size - 1;
            if (end >= size) end = size - 1;
            partial = YES;
        }
    }
    if (start > end || start >= size) {
        NSString *miss = @"HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        YTWriteAll(client, [miss UTF8String], [miss length]);
        return;
    }
    unsigned long long length = end - start + 1;
    NSMutableString *headText = [NSMutableString string];
    [headText appendFormat:@"HTTP/1.1 %d %@\r\n", partial ? 206 : 200, partial ? @"Partial Content" : @"OK"];
    [headText appendFormat:@"Content-Type: video/mp4\r\nContent-Length: %llu\r\n", length];
    if (partial) [headText appendFormat:@"Content-Range: bytes %llu-%llu/%llu\r\n", start, end, size];
    [headText appendString:@"Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"];
    if (!YTWriteAll(client, [headText UTF8String], [headText length]) || head) return;
    [file seekToFileOffset:start];
    unsigned long long left = length;
    while (left) {
        NSUInteger chunk = left > 32 * 1024 ? 32 * 1024 : (NSUInteger)left;
        NSData *data = [file readDataOfLength:chunk];
        if (![data length] || !YTWriteAll(client, [data bytes], [data length])) break;
        left -= [data length];
    }
}

static void YTServe(int client) {
    char buffer[4096];
    size_t used = 0;
    while (used + 1 < sizeof(buffer)) {
        ssize_t got = read(client, buffer + used, sizeof(buffer) - 1 - used);
        if (got < 0) {
            if (errno == EINTR) continue;
            return;
        }
        if (got == 0) return;
        used += got;
        buffer[used] = 0;
        if (strstr(buffer, "\r\n\r\n")) break;
    }
    NSString *header = [[NSString alloc] initWithBytes:buffer length:used encoding:NSUTF8StringEncoding] ?: @"";
    NSString *first = [[header componentsSeparatedByString:@"\r\n"] objectAtIndex:0];
    NSArray *parts = [first componentsSeparatedByString:@" "];
    if (parts.count < 2) return;
    NSString *method = [parts objectAtIndex:0];
    NSString *rawPath = [parts objectAtIndex:1];
    if ([rawPath rangeOfString:@"/icon?"].location == 0) {
        NSString *remote = nil;
        NSRange query = [rawPath rangeOfString:@"u="];
        if (query.location != NSNotFound) {
            NSString *value = [rawPath substringFromIndex:query.location + 2];
            NSRange amp = [value rangeOfString:@"&"];
            if (amp.location != NSNotFound) value = [value substringToIndex:amp.location];
            remote = [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: value;
        }
        NSURL *iconURL = remote.length ? [NSURL URLWithString:remote] : nil;
        NSString *host = [[iconURL host] lowercaseString] ?: @"";
        BOOL allowed = [host hasSuffix:@"ggpht.com"] || [host hasSuffix:@"googleusercontent.com"] || [host hasSuffix:@"ytimg.com"];
        NSData *icon = (allowed && [iconURL scheme]) ? YTGET(remote) : nil;
        if (!icon.length) {
            NSString *miss = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            YTWriteAll(client, [miss UTF8String], [miss length]);
            return;
        }
        NSString *headText = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: %u\r\nConnection: close\r\n\r\n", (unsigned)[icon length]];
        YTWriteAll(client, [headText UTF8String], [headText length]);
        if (![method isEqualToString:@"HEAD"]) YTWriteAll(client, [icon bytes], [icon length]);
        return;
    }
    if (YTPrefBool(@"captions", YES) && [rawPath rangeOfString:@".srt"].location != NSNotFound) {
        NSString *name = [[rawPath lastPathComponent] stringByDeletingPathExtension];
        NSArray *bits = [name componentsSeparatedByString:@"."];
        NSString *vid = [bits count] ? [bits objectAtIndex:0] : @"";
        NSString *lang = [bits count] > 1 ? [bits objectAtIndex:1] : @"en";
        NSData *xml = YTIsVideoID(vid) ? YTGET([NSString stringWithFormat:@"https://www.youtube.com/api/timedtext?v=%@&lang=%@", vid, lang]) : nil;
        NSString *text = xml.length ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : @"";
        NSMutableString *srt = [NSMutableString string];
        NSUInteger index = 1;
        NSRange scan = NSMakeRange(0, text.length);
        while (scan.length) {
            NSRange startMark = [text rangeOfString:@"start=\"" options:0 range:scan];
            if (startMark.location == NSNotFound) break;
            NSUInteger a = startMark.location + startMark.length;
            NSRange endq = [text rangeOfString:@"\"" options:0 range:NSMakeRange(a, text.length - a)];
            if (endq.location == NSNotFound) break;
            double start = [[text substringWithRange:NSMakeRange(a, endq.location - a)] doubleValue];
            NSRange durMark = [text rangeOfString:@"dur=\"" options:0 range:NSMakeRange(endq.location, text.length - endq.location)];
            double dur = 2;
            NSUInteger bodyAt = endq.location;
            if (durMark.location != NSNotFound) {
                NSUInteger b = durMark.location + durMark.length;
                NSRange endd = [text rangeOfString:@"\"" options:0 range:NSMakeRange(b, text.length - b)];
                if (endd.location != NSNotFound) dur = [[text substringWithRange:NSMakeRange(b, endd.location - b)] doubleValue];
                bodyAt = endd.location;
            }
            NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(bodyAt, text.length - bodyAt)];
            NSRange lt = gt.location == NSNotFound ? gt : [text rangeOfString:@"</text>" options:0 range:NSMakeRange(gt.location, text.length - gt.location)];
            NSString *line = (gt.location != NSNotFound && lt.location != NSNotFound) ? [text substringWithRange:NSMakeRange(gt.location + 1, lt.location - gt.location - 1)] : @"";
            int ss = (int)start;
            int ee = (int)(start + dur);
            [srt appendFormat:@"%u\n%02d:%02d:%02d,000 --> %02d:%02d:%02d,000\n%@\n\n", (unsigned)index, ss / 3600, (ss / 60) % 60, ss % 60, ee / 3600, (ee / 60) % 60, ee % 60, line];
            index++;
            NSUInteger next = lt.location == NSNotFound ? text.length : lt.location + 7;
            if (next >= text.length) break;
            scan = NSMakeRange(next, text.length - next);
        }
        NSData *body = [srt dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: %u\r\nConnection: close\r\n\r\n", (unsigned)[body length]];
        YTWriteAll(client, [head UTF8String], [head length]);
        YTWriteAll(client, [body bytes], [body length]);
        return;
    }
    NSString *videoID = YTVideoIDFromPath([parts objectAtIndex:1]);
    if (!videoID) {
        NSString *miss = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        YTWriteAll(client, [miss UTF8String], [miss length]);
        return;
    }
    NSString *range = nil;
    for (NSString *line in [header componentsSeparatedByString:@"\r\n"]) {
        if ([line rangeOfString:@"Range:" options:NSCaseInsensitiveSearch].location == 0) {
            range = [[line substringFromIndex:6] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }
    BOOL low = [[parts objectAtIndex:1] rangeOfString:@".360.mp4"].location != NSNotFound;
    NSString *upstream = YTFetchUpstream(videoID);
    if (low || !YTWant720()) {
        YTLog([NSString stringWithFormat:@"serve 360 %@ %@", videoID, range ?: @"-"]);
        if (!upstream.length) {
            NSString *miss = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            YTWriteAll(client, [miss UTF8String], [miss length]);
            return;
        }
    } else {
    [YTCacheLock lock];
    BOOL skip720 = [YTNo720 containsObject:videoID];
    [YTCacheLock unlock];
    NSString *muxed = nil;
    if (!skip720) {
        muxed = YTEnsure720(videoID, YTStreamURL(videoID, @"hi"), YTStreamURL(videoID, @"au"));
        if (!muxed.length) {
            [YTCacheLock lock];
            [YTNo720 addObject:videoID];
            [YTCacheLock unlock];
        }
    }
    if (muxed.length) {
        YTLog([NSString stringWithFormat:@"serve hi%@ %@ %@", YTStreamURL(videoID, @"hih") ?: @"", videoID, range ?: @"-"]);
        YTServeFile(client, muxed, range, [method isEqualToString:@"HEAD"]);
        return;
    }
    if (!YTPrefBool(@"fallback360", YES)) {
        NSString *miss = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        YTWriteAll(client, [miss UTF8String], [miss length]);
        return;
    }
    }
    if (!upstream.length) {
        NSString *miss = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        YTWriteAll(client, [miss UTF8String], [miss length]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:upstream]
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:30];
    [request setHTTPMethod:[method isEqualToString:@"HEAD"] ? @"HEAD" : @"GET"];
    [request setValue:@"com.google.android.youtube/20.10.38 (Linux; U; Android 13)" forHTTPHeaderField:@"User-Agent"];
    if (range.length) [request setValue:range forHTTPHeaderField:@"Range"];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:YTMark inRequest:request];
    YTLog([NSString stringWithFormat:@"proxy %@ %@ %@", method, videoID, range ?: @"-"]);
    YTProxyFetch *fetch = [[YTProxyFetch alloc] init];
    fetch.fd = client;
    fetch.head = [method isEqualToString:@"HEAD"];
    [fetch run:request];
}

static void YTAcceptLoop(int server) {
    while (1) {
        @autoreleasepool {
            int client = accept(server, NULL, NULL);
            if (client < 0) continue;
            int nosig = 1;
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, sizeof(nosig));
            struct timeval wait;
            wait.tv_sec = 15;
            wait.tv_usec = 0;
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &wait, sizeof(wait));
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @autoreleasepool {
                    YTServe(client);
                }
                close(client);
            });
        }
    }
}

static void YTStartProxy(void) {
    signal(SIGPIPE, SIG_IGN);
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) return;
    int yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int port;
    for (port = 8765; port < 8780; port++) {
        addr.sin_port = htons(port);
        if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) == 0) break;
    }
    if (port >= 8780 || listen(server, 8) != 0) {
        close(server);
        YTLog(@"proxy bind failed");
        return;
    }
    YTProxyPort = port;
    YTLog([NSString stringWithFormat:@"proxy %d", port]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        YTAcceptLoop(server);
    });
}

static double (*YTOrigDuration)(id, SEL);
static double (*YTOrigPlayable)(id, SEL);
static double (*YTOrigSeekEnd)(id, SEL);
static double (*YTOrigPlayEnd)(id, SEL);

static double YTKnownDuration(id player) {
    if (![player respondsToSelector:@selector(moviePath)]) return 0;
    NSString *path = [player performSelector:@selector(moviePath)];
    NSString *videoID = YTVideoIDFromPath(path);
    if (!videoID) return 0;
    [YTCacheLock lock];
    NSNumber *seconds = [YTDurationCache objectForKey:videoID];
    [YTCacheLock unlock];
    return seconds ? [seconds doubleValue] : 0;
}

static double YTFixTime(id self, double (*orig)(id, SEL), SEL cmd) {
    double value = orig ? orig(self, cmd) : 0;
    if (value > 0.5 && value < 86400.0 * 12.0) return value;
    double known = YTKnownDuration(self);
    return known > 0.5 ? known : value;
}

static double YTHookDuration(id self, SEL cmd) { return YTFixTime(self, YTOrigDuration, cmd); }
static double YTHookPlayable(id self, SEL cmd) { return YTFixTime(self, YTOrigPlayable, cmd); }
static double YTHookSeekEnd(id self, SEL cmd) { return YTFixTime(self, YTOrigSeekEnd, cmd); }
static double YTHookPlayEnd(id self, SEL cmd) { return YTFixTime(self, YTOrigPlayEnd, cmd); }

static void (*YTOrigSetPath)(id, SEL, id);
static void YTHookSetPath(id self, SEL cmd, id path) {
    YTLog([NSString stringWithFormat:@"movie %@", path]);
    if (YTOrigSetPath) YTOrigSetPath(self, cmd, path);
}

static void YTHookPlayer(void) {
    Class player = NSClassFromString(@"UIMoviePlayerController");
    YTHookMethod(player, @"duration", (IMP)YTHookDuration, (IMP *)&YTOrigDuration);
    YTHookMethod(player, @"playableDuration", (IMP)YTHookPlayable, (IMP *)&YTOrigPlayable);
    YTHookMethod(player, @"seekableEndTime", (IMP)YTHookSeekEnd, (IMP *)&YTOrigSeekEnd);
    YTHookMethod(player, @"playableEndTime", (IMP)YTHookPlayEnd, (IMP *)&YTOrigPlayEnd);
    YTHookMethod(player, @"setMoviePath:", (IMP)YTHookSetPath, (IMP *)&YTOrigSetPath);
}

static id (*YTOrigReq)(id, SEL, NSURL *, NSUInteger, NSTimeInterval);
static id YTHookReq(id self, SEL cmd, NSURL *url, NSUInteger policy, NSTimeInterval timeout) {
    YTLog([NSString stringWithFormat:@"request %@", [url absoluteString]]);
    return YTOrigReq(self, cmd, url, policy, timeout);
}

static void YTPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsID);
    YTLog(@"prefs reloaded");
}

__attribute__((constructor))
static void YTLoad(void) {
    YTCacheLock = [[NSLock alloc] init];
    YTPlayCache = [NSMutableDictionary dictionary];
    YTDurationCache = [NSMutableDictionary dictionary];
    YTNo720 = [NSMutableSet set];
    YTInstallCrashHandler();
    YTMigratePrefs();
    YTAuthInstall();
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, YTPrefsChanged, CFSTR("com.sokubit.5tube/reload"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    YTStartProxy();
    [NSURLProtocol registerClass:[YTInnerProtocol class]];
    Class connection = [NSURLConnection class];
    Method initConn = class_getInstanceMethod(connection, @selector(initWithRequest:delegate:startImmediately:));
    if (initConn) {
        YTOrigInitConn = (id (*)(id, SEL, NSURLRequest *, id, BOOL))method_getImplementation(initConn);
        method_setImplementation(initConn, (IMP)YTHookInitConn);
    }
    Method method = class_getClassMethod(connection, @selector(connectionWithRequest:delegate:));
    YTOrigConnect = (NSURLConnection *(*)(id, SEL, NSURLRequest *, id))method_getImplementation(method);
    method_setImplementation(method, (IMP)YTHookConnect);
    Method sync = class_getClassMethod(connection, @selector(sendSynchronousRequest:returningResponse:error:));
    if (sync) {
        YTOrigSync = (NSData *(*)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **))method_getImplementation(sync);
        method_setImplementation(sync, (IMP)YTHookSync);
    }
    YTHookSAX();
    YTHookPlayer();
    YTLog(@"loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class req = NSClassFromString(@"YTMutableURLRequest");
        Method reqInit = class_getInstanceMethod(req, @selector(initWithURL:cachePolicy:timeoutInterval:));
        if (reqInit) {
            YTOrigReq = (id (*)(id, SEL, NSURL *, NSUInteger, NSTimeInterval))method_getImplementation(reqInit);
            method_setImplementation(reqInit, (IMP)YTHookReq);
            YTLog(@"hooked YTMutableURLRequest");
        }
        YTHookSAX();
        YTHookPlayer();
        YTAuthInstall();
    });
}
