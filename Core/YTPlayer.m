#import "5Tube.h"

@interface YTProxyFetch : NSObject
@property (nonatomic, assign) int fd;
@property (nonatomic, assign) BOOL head;
@property (nonatomic, assign) BOOL done;
@property (nonatomic, assign) BOOL sent;
- (void)run:(NSURLRequest *)request;
@end


NSLock *YTCacheLock;
NSMutableDictionary *YTPlayCache;
NSMutableDictionary *YTDurationCache;
NSMutableSet *YTNo720;
int YTProxyPort;
NSMutableDictionary *YTHLSCache;

static double YTHLSExpiry(NSString *url) {
    NSRange mark = [url rangeOfString:@"expire/"];
    if (mark.location == NSNotFound) return 0;
    NSString *rest = [url substringFromIndex:mark.location + mark.length];
    NSRange slash = [rest rangeOfString:@"/"];
    if (slash.location != NSNotFound) rest = [rest substringToIndex:slash.location];
    return [rest doubleValue];
}

void YTHLSSave(NSString *videoID, NSString *url) {
    if (!videoID.length || ![url isKindOfClass:[NSString class]] || !url.length) return;
    [YTCacheLock lock];
    if (!YTHLSCache) YTHLSCache = [NSMutableDictionary dictionary];
    NSDictionary *entry = [NSDictionary dictionaryWithObjectsAndKeys:
                           url, @"url",
                           [NSNumber numberWithDouble:YTHLSExpiry(url)], @"expiry", nil];
    [YTHLSCache setObject:entry forKey:videoID];
    [YTCacheLock unlock];
}

NSString *YTHLSURL(NSString *videoID) {
    if (!videoID.length) return nil;
    [YTCacheLock lock];
    NSDictionary *entry = [YTHLSCache objectForKey:videoID];
    [YTCacheLock unlock];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    double expiry = [[entry objectForKey:@"expiry"] doubleValue];
    if (expiry > 0 && expiry - [[NSDate date] timeIntervalSince1970] < 600) {
        [YTCacheLock lock];
        [YTHLSCache removeObjectForKey:videoID];
        [YTCacheLock unlock];
        return nil;
    }
    return [entry objectForKey:@"url"];
}

NSString *YTHLSFor(NSString *videoID) {
    if (!videoID.length) return nil;
    NSString *cached = YTHLSURL(videoID);
    if (cached.length) return cached;
    id json = YTPost(@"player", [NSDictionary dictionaryWithObjectsAndKeys:
                                 videoID, @"videoId",
                                 [NSNumber numberWithBool:YES], @"contentCheckOk",
                                 [NSNumber numberWithBool:YES], @"racyCheckOk",
                                 nil]);
    NSString *hls = YTGet(YTGet(json, @"streamingData"), @"hlsManifestUrl");
    if ([hls isKindOfClass:[NSString class]] && hls.length) YTHLSSave(videoID, hls);
    return ([hls isKindOfClass:[NSString class]] && hls.length) ? hls : nil;
}

NSString *YTLocalLiveURL(NSString *videoID) {
    if (!videoID.length) return nil;
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/live/%@.m3u8", YTProxyPort, videoID];
}

NSData *YTLiveMaster(NSData *master) {
    NSString *text = master.length ? [[NSString alloc] initWithData:master encoding:NSUTF8StringEncoding] : nil;
    if (!text.length) return master;
    NSMutableString *out = [NSMutableString string];
    BOOL skipNext = NO;
    BOOL kept = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"#EXT-X-STREAM-INF:"]) {
            int height = 0;
            int fps = 0;
            NSRange res = [line rangeOfString:@"RESOLUTION="];
            if (res.location != NSNotFound) {
                NSString *rest = [line substringFromIndex:res.location + res.length];
                NSRange x = [rest rangeOfString:@"x"];
                if (x.location != NSNotFound) height = [[rest substringFromIndex:x.location + 1] intValue];
            }
            NSRange fr = [line rangeOfString:@"FRAME-RATE="];
            if (fr.location != NSNotFound) fps = (int)[[line substringFromIndex:fr.location + fr.length] doubleValue];
            skipNext = height > 720 || fps > 30;
            if (!skipNext) {
                [out appendString:line];
                [out appendString:@"\n"];
                kept = YES;
            }
            continue;
        }
        if (skipNext && line.length && ![line hasPrefix:@"#"]) {
            skipNext = NO;
            continue;
        }
        [out appendString:line];
        [out appendString:@"\n"];
    }
    if (!kept) return master;
    return [out dataUsingEncoding:NSUTF8StringEncoding];
}

NSString *YTLocalPlayURL(NSString *videoID, BOOL high) {
    if (high) return [NSString stringWithFormat:@"http://127.0.0.1:%d/%@.mp4", YTProxyPort, videoID];
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/%@.360.mp4", YTProxyPort, videoID];
}

int YTAvcLevel(NSString *mime) {
    NSRange mark = [mime rangeOfString:@"avc1." options:NSCaseInsensitiveSearch];
    if (mark.location == NSNotFound || mark.location + 11 > mime.length) return 0;
    NSString *hex = [mime substringWithRange:NSMakeRange(mark.location + mark.length + 4, 2)];
    unsigned int level = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hex];
    [scanner scanHexInt:&level];
    return (int)level;
}

void YTPickStreams(NSMutableDictionary *streams, NSArray *formats) {
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

NSString *YTStreamURL(NSString *videoID, NSString *itag) {
    [YTCacheLock lock];
    id info = [YTPlayCache objectForKey:videoID];
    [YTCacheLock unlock];
    if ([info isKindOfClass:[NSDictionary class]]) return [info objectForKey:itag];
    if ([itag isEqualToString:@"18"] && [info isKindOfClass:[NSString class]]) return info;
    return nil;
}

void YTTakeStream(NSMutableDictionary *streams, id format) {
    NSString *url = YTGet(format, @"url");
    id tag = YTGet(format, @"itag");
    NSString *itag = [tag description];
    if ([url isKindOfClass:[NSString class]] && url.length && itag.length) [streams setObject:url forKey:itag];
}

NSString *YTFetchUpstream(NSString *videoID) {
    if (!videoID.length) return nil;
    NSString *ready = YTStreamURL(videoID, @"18");
    if (!ready.length) ready = YTStreamURL(videoID, @"136");
    if (ready.length) return ready;
    id json = YTPost(@"player", [NSDictionary dictionaryWithObjectsAndKeys:
                                 videoID, @"videoId",
                                 [NSNumber numberWithBool:YES], @"contentCheckOk",
                                 [NSNumber numberWithBool:YES], @"racyCheckOk",
                                 nil]);
    id hls = YTGet(YTGet(json, @"streamingData"), @"hlsManifestUrl");
    if ([hls isKindOfClass:[NSString class]] && [hls length]) YTHLSSave(videoID, hls);
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

NSString *YTPlayURL(NSString *videoID) {
    NSString *progressive = YTFetchUpstream(videoID);
    BOOL high = [YTStreamURL(videoID, @"hi") length] > 0;
    if (YTProxyPort <= 0 || (!progressive.length && !high)) return nil;
    return YTLocalPlayURL(videoID, YTWant720() && high);
}

BOOL YTWriteAll(int fd, const void *bytes, size_t length) {
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

NSString *YTHeader(NSDictionary *headers, NSString *name) {
    for (NSString *key in headers) {
        if ([key caseInsensitiveCompare:name] == NSOrderedSame) return [headers objectForKey:key];
    }
    return nil;
}

NSString *YTVideoIDFromPath(NSString *path) {
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

void YTServeFile(int client, NSString *path, NSString *range, BOOL head) {
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

void YTServe(int client) {
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
    if ([rawPath rangeOfString:@"/live/"].location == 0) {
        NSString *name = [[rawPath lastPathComponent] stringByDeletingPathExtension];
        NSString *vid = YTIsVideoID(name) ? name : @"";
        NSString *hls = vid.length ? YTHLSFor(vid) : nil;
        NSData *master = hls.length ? YTGET(hls) : nil;
        NSData *body = master.length ? YTLiveMaster(master) : nil;
        if (!body.length) {
            NSString *miss = @"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            YTWriteAll(client, [miss UTF8String], [miss length]);
            return;
        }
        NSString *headText = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: application/vnd.apple.mpegurl\r\nContent-Length: %u\r\nConnection: close\r\n\r\n", (unsigned)[body length]];
        YTWriteAll(client, [headText UTF8String], [headText length]);
        if (![method isEqualToString:@"HEAD"]) YTWriteAll(client, [body bytes], [body length]);
        YTLog([NSString stringWithFormat:@"live master %@ %u", vid, (unsigned)[body length]]);
        return;
    }
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
        NSString *kind = [bits count] > 2 ? [bits objectAtIndex:2] : @"";
        NSString *track = YTIsVideoID(vid) ? YTCaptionURL(vid, lang, kind) : nil;
        NSData *xml = track.length ? YTGET(track) : nil;
        if (!xml.length && YTIsVideoID(vid)) {
            YTCaptionForget(vid);
            track = YTCaptionURL(vid, lang, kind);
            xml = track.length ? YTGET(track) : nil;
        }
        NSString *text = xml.length ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : @"";
        NSString *srt = YTSRTFromTrack(text);
        NSData *body = [srt dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
        NSString *head = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %u\r\nConnection: close\r\n\r\n", (unsigned)[body length]];
        YTWriteAll(client, [head UTF8String], [head length]);
        YTWriteAll(client, [body bytes], [body length]);
        YTLog([NSString stringWithFormat:@"captions srt %@ %@ %@ %u", vid, lang, kind.length ? kind : @"-", (unsigned)[body length]]);
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

void YTAcceptLoop(int server) {
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

void YTStartProxy(void) {
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
