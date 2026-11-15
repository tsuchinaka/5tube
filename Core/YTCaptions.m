#import "5Tube.h"

@interface YTSubtitleTicker : NSObject
- (void)tick:(NSTimer *)timer;
- (void)toggle;
@end


NSMutableDictionary *YTCaptionCache;
NSLock *YTCaptionLock;
UILabel *YTCaptionLabel;
UIButton *YTCaptionButton;
NSArray *YTCaptionCues;
NSString *YTCaptionVideoID;
BOOL YTCaptionOn = YES;
YTSubtitleTicker *YTCaptionTicker;
void YTCaptionSetup(void) {
    if (YTCaptionLock) return;
    YTCaptionLock = [[NSLock alloc] init];
    YTCaptionCache = [NSMutableDictionary dictionary];
}

NSArray *YTCaptionTracks(NSString *videoID) {
    if (!videoID.length) return [NSArray array];
    YTCaptionSetup();
    [YTCaptionLock lock];
    id cached = [YTCaptionCache objectForKey:videoID];
    [YTCaptionLock unlock];
    if ([cached isKindOfClass:[NSArray class]]) return cached;
    id json = YTPost(@"player", [NSDictionary dictionaryWithObjectsAndKeys:
                                 videoID, @"videoId",
                                 [NSNumber numberWithBool:YES], @"contentCheckOk",
                                 [NSNumber numberWithBool:YES], @"racyCheckOk",
                                 nil]);
    id tracks = YTGet(YTGet(YTGet(json, @"captions"), @"playerCaptionsTracklistRenderer"), @"captionTracks");
    NSMutableArray *out = [NSMutableArray array];
    if ([tracks isKindOfClass:[NSArray class]]) {
        for (id track in tracks) {
            if (![track isKindOfClass:[NSDictionary class]]) continue;
            NSString *url = YTGet(track, @"baseUrl");
            NSString *lang = YTGet(track, @"languageCode");
            if (![url isKindOfClass:[NSString class]] || !url.length || ![lang isKindOfClass:[NSString class]] || !lang.length) continue;
            NSString *kind = YTGet(track, @"kind");
            if (![kind isKindOfClass:[NSString class]]) kind = @"";
            NSString *name = YTText(YTGet(track, @"name"));
            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            [item setObject:url forKey:@"url"];
            [item setObject:lang forKey:@"lang"];
            [item setObject:kind forKey:@"kind"];
            [item setObject:(name.length ? name : lang) forKey:@"name"];
            [out addObject:item];
        }
    }
    [YTCaptionLock lock];
    [YTCaptionCache setObject:out forKey:videoID];
    [YTCaptionLock unlock];
    YTLog([NSString stringWithFormat:@"captions %@ %u", videoID, (unsigned)[out count]]);
    return out;
}

NSDictionary *YTCaptionTrack(NSString *videoID, NSString *lang, NSString *kind) {
    NSArray *tracks = YTCaptionTracks(videoID);
    NSDictionary *fallback = nil;
    for (NSDictionary *track in tracks) {
        if (![[track objectForKey:@"lang"] isEqualToString:lang]) continue;
        NSString *trackKind = [track objectForKey:@"kind"] ?: @"";
        if (trackKind.length == kind.length && (kind.length == 0 || [trackKind isEqualToString:kind])) return track;
        if (!fallback) fallback = track;
    }
    return fallback;
}

void YTCaptionForget(NSString *videoID) {
    if (!videoID.length) return;
    YTCaptionSetup();
    [YTCaptionLock lock];
    [YTCaptionCache removeObjectForKey:videoID];
    [YTCaptionLock unlock];
}

NSString *YTCaptionURL(NSString *videoID, NSString *lang, NSString *kind) {
    NSDictionary *track = YTCaptionTrack(videoID, lang, kind);
    return [track objectForKey:@"url"];
}

int YTCaptionAttr(NSString *attrs, NSString *name) {
    NSString *needle = [name stringByAppendingString:@"=\""];
    NSRange mark = [attrs rangeOfString:needle];
    if (mark.location == NSNotFound) return 0;
    NSUInteger start = mark.location + mark.length;
    NSRange end = [attrs rangeOfString:@"\"" options:0 range:NSMakeRange(start, attrs.length - start)];
    if (end.location == NSNotFound) return 0;
    return [[attrs substringWithRange:NSMakeRange(start, end.location - start)] intValue];
}

NSString *YTCaptionStrip(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    BOOL tag = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '<') tag = YES;
        else if (c == '>') tag = NO;
        else if (!tag) [out appendFormat:@"%C", c];
    }
    return out;
}

NSString *YTCaptionDecode(NSString *text) {
    if (!text.length) return @"";
    NSMutableString *out = [text mutableCopy];
    NSArray *names = [NSArray arrayWithObjects:@"amp", @"lt", @"gt", @"quot", @"apos", @"nbsp", nil];
    NSArray *chars = [NSArray arrayWithObjects:@"&", @"<", @">", @"\"", @"'", @" ", nil];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSString *needle = [NSString stringWithFormat:@"&%@;", [names objectAtIndex:i]];
        [out replaceOccurrencesOfString:needle withString:[chars objectAtIndex:i] options:0 range:NSMakeRange(0, out.length)];
    }
    while (1) {
        NSRange amp = [out rangeOfString:@"&#"];
        if (amp.location == NSNotFound) break;
        NSRange semi = [out rangeOfString:@";" options:0 range:NSMakeRange(amp.location, out.length - amp.location)];
        if (semi.location == NSNotFound) break;
        NSString *number = [out substringWithRange:NSMakeRange(amp.location + 2, semi.location - amp.location - 2)];
        unsigned int code = 0;
        if ([number hasPrefix:@"x"] || [number hasPrefix:@"X"]) {
            NSScanner *scanner = [NSScanner scannerWithString:[number substringFromIndex:1]];
            [scanner scanHexInt:&code];
        } else {
            code = (unsigned int)[number intValue];
        }
        if (code == 0 || code > 0xffff) break;
        [out replaceCharactersInRange:NSMakeRange(amp.location, semi.location - amp.location + 1)
                           withString:[NSString stringWithFormat:@"%C", (unichar)code]];
    }
    return out;
}

NSString *YTCaptionTime(int ms) {
    int hours = ms / 3600000;
    ms %= 3600000;
    int minutes = ms / 60000;
    ms %= 60000;
    int seconds = ms / 1000;
    return [NSString stringWithFormat:@"%02d:%02d:%02d,%03d", hours, minutes, seconds, ms % 1000];
}

NSString *YTSRTFromTrack(NSString *text) {
    NSMutableString *srt = [NSMutableString string];
    if (!text.length) return srt;
    NSUInteger index = 1;
    NSRange scan = NSMakeRange(0, text.length);
    while (scan.length) {
        NSRange open = [text rangeOfString:@"<p " options:0 range:scan];
        if (open.location == NSNotFound) break;
        NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(open.location, text.length - open.location)];
        if (gt.location == NSNotFound) break;
        NSRange close = [text rangeOfString:@"</p>" options:0 range:NSMakeRange(gt.location, text.length - gt.location)];
        if (close.location == NSNotFound) break;
        NSString *attrs = [text substringWithRange:NSMakeRange(open.location + 3, gt.location - open.location - 3)];
        int start = YTCaptionAttr(attrs, @"t");
        int duration = YTCaptionAttr(attrs, @"d");
        if (duration <= 0) duration = 2000;
        NSString *body = [text substringWithRange:NSMakeRange(gt.location + 1, close.location - gt.location - 1)];
        body = [YTCaptionDecode(YTCaptionStrip(body)) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (body.length) {
            [srt appendFormat:@"%u\n%@ --> %@\n%@\n\n", (unsigned)index++, YTCaptionTime(start), YTCaptionTime(start + duration), body];
        }
        NSUInteger next = close.location + 4;
        if (next >= text.length) break;
        scan = NSMakeRange(next, text.length - next);
    }
    if (srt.length) return srt;
    scan = NSMakeRange(0, text.length);
    while (scan.length) {
        NSRange mark = [text rangeOfString:@"start=\"" options:0 range:scan];
        if (mark.location == NSNotFound) break;
        NSUInteger a = mark.location + mark.length;
        NSRange endq = [text rangeOfString:@"\"" options:0 range:NSMakeRange(a, text.length - a)];
        if (endq.location == NSNotFound) break;
        double start = [[text substringWithRange:NSMakeRange(a, endq.location - a)] doubleValue];
        NSRange durMark = [text rangeOfString:@"dur=\"" options:0 range:NSMakeRange(endq.location, text.length - endq.location)];
        double duration = 2;
        NSUInteger bodyAt = endq.location;
        if (durMark.location != NSNotFound) {
            NSUInteger b = durMark.location + durMark.length;
            NSRange endd = [text rangeOfString:@"\"" options:0 range:NSMakeRange(b, text.length - b)];
            if (endd.location != NSNotFound) duration = [[text substringWithRange:NSMakeRange(b, endd.location - b)] doubleValue];
            bodyAt = endd.location;
        }
        NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(bodyAt, text.length - bodyAt)];
        NSRange lt = gt.location == NSNotFound ? gt : [text rangeOfString:@"</text>" options:0 range:NSMakeRange(gt.location, text.length - gt.location)];
        if (gt.location != NSNotFound && lt.location != NSNotFound) {
            NSString *body = [text substringWithRange:NSMakeRange(gt.location + 1, lt.location - gt.location - 1)];
            body = [YTCaptionDecode(YTCaptionStrip(body)) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (body.length) {
                int startMs = (int)(start * 1000);
                int endMs = (int)((start + duration) * 1000);
                [srt appendFormat:@"%u\n%@ --> %@\n%@\n\n", (unsigned)index++, YTCaptionTime(startMs), YTCaptionTime(endMs), body];
            }
        }
        NSUInteger next = lt.location == NSNotFound ? text.length : lt.location + 7;
        if (next >= text.length) break;
        scan = NSMakeRange(next, text.length - next);
    }
    return srt;
}

NSArray *YTCaptionParse(NSString *text) {
    NSMutableArray *out = [NSMutableArray array];
    if (!text.length) return out;
    NSRange scan = NSMakeRange(0, text.length);
    while (scan.length) {
        NSRange open = [text rangeOfString:@"<p " options:0 range:scan];
        if (open.location == NSNotFound) break;
        NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(open.location, text.length - open.location)];
        if (gt.location == NSNotFound) break;
        NSRange close = [text rangeOfString:@"</p>" options:0 range:NSMakeRange(gt.location, text.length - gt.location)];
        if (close.location == NSNotFound) break;
        NSString *attrs = [text substringWithRange:NSMakeRange(open.location + 3, gt.location - open.location - 3)];
        int start = YTCaptionAttr(attrs, @"t");
        int duration = YTCaptionAttr(attrs, @"d");
        if (duration <= 0) duration = 2000;
        NSString *body = [text substringWithRange:NSMakeRange(gt.location + 1, close.location - gt.location - 1)];
        body = [YTCaptionDecode(YTCaptionStrip(body)) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (body.length) {
            [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                            [NSNumber numberWithInt:start], @"start",
                            [NSNumber numberWithInt:start + duration], @"end",
                            body, @"text", nil]];
        }
        NSUInteger next = close.location + 4;
        if (next >= text.length) break;
        scan = NSMakeRange(next, text.length - next);
    }
    if (out.count) return out;
    scan = NSMakeRange(0, text.length);
    while (scan.length) {
        NSRange mark = [text rangeOfString:@"start=\"" options:0 range:scan];
        if (mark.location == NSNotFound) break;
        NSUInteger a = mark.location + mark.length;
        NSRange endq = [text rangeOfString:@"\"" options:0 range:NSMakeRange(a, text.length - a)];
        if (endq.location == NSNotFound) break;
        double start = [[text substringWithRange:NSMakeRange(a, endq.location - a)] doubleValue];
        NSRange durMark = [text rangeOfString:@"dur=\"" options:0 range:NSMakeRange(endq.location, text.length - endq.location)];
        double duration = 2;
        NSUInteger bodyAt = endq.location;
        if (durMark.location != NSNotFound) {
            NSUInteger b = durMark.location + durMark.length;
            NSRange endd = [text rangeOfString:@"\"" options:0 range:NSMakeRange(b, text.length - b)];
            if (endd.location != NSNotFound) duration = [[text substringWithRange:NSMakeRange(b, endd.location - b)] doubleValue];
            bodyAt = endd.location;
        }
        NSRange gt = [text rangeOfString:@">" options:0 range:NSMakeRange(bodyAt, text.length - bodyAt)];
        NSRange lt = gt.location == NSNotFound ? gt : [text rangeOfString:@"</text>" options:0 range:NSMakeRange(gt.location, text.length - gt.location)];
        if (gt.location != NSNotFound && lt.location != NSNotFound) {
            NSString *body = [text substringWithRange:NSMakeRange(gt.location + 1, lt.location - gt.location - 1)];
            body = [YTCaptionDecode(YTCaptionStrip(body)) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (body.length) {
                int startMs = (int)(start * 1000);
                int endMs = (int)((start + duration) * 1000);
                [out addObject:[NSDictionary dictionaryWithObjectsAndKeys:
                                [NSNumber numberWithInt:startMs], @"start",
                                [NSNumber numberWithInt:endMs], @"end",
                                body, @"text", nil]];
            }
        }
        NSUInteger next = lt.location == NSNotFound ? text.length : lt.location + 7;
        if (next >= text.length) break;
        scan = NSMakeRange(next, text.length - next);
    }
    return out;
}

UIView *YTCaptionFindPlayer(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:NSClassFromString(@"UIMoviePlayerController")]) return view;
    if ([view isKindOfClass:NSClassFromString(@"YTMovieView")]) return view;
    for (UIView *child in view.subviews) {
        UIView *found = YTCaptionFindPlayer(child);
        if (found) return found;
    }
    return nil;
}

double YTCaptionPlayerTime(UIView *player) {
    if (player && [player respondsToSelector:@selector(currentPlaybackTime)])
        return ((double (*)(id, SEL))objc_msgSend)(player, @selector(currentPlaybackTime));
    return -1;
}

void YTCaptionStyle(void) {
    if (YTCaptionLabel) return;
    if (!YTCaptionTicker) YTCaptionTicker = [[YTSubtitleTicker alloc] init];
    YTCaptionLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 0, 0)];
    YTCaptionLabel.backgroundColor = [UIColor colorWithWhite:0 alpha:0.65f];
    YTCaptionLabel.textColor = [UIColor whiteColor];
    YTCaptionLabel.font = [UIFont boldSystemFontOfSize:16];
    YTCaptionLabel.textAlignment = UITextAlignmentCenter;
    YTCaptionLabel.numberOfLines = 3;
    YTCaptionLabel.userInteractionEnabled = NO;
    YTCaptionLabel.hidden = YES;
    YTCaptionButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [YTCaptionButton setTitle:@"CC" forState:UIControlStateNormal];
    [YTCaptionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [YTCaptionButton setTitleColor:[UIColor yellowColor] forState:UIControlStateHighlighted];
    YTCaptionButton.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    YTCaptionButton.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55f];
    YTCaptionButton.hidden = YES;
    [YTCaptionButton addTarget:YTCaptionTicker action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
}

void YTCaptionToggle(void) {
    YTCaptionOn = !YTCaptionOn;
    YTLog([NSString stringWithFormat:@"caption toggle %d", YTCaptionOn]);
}

void YTCaptionTick(void) {
    if (!YTPrefBool(@"captionOverlay", NO)) {
        YTCaptionLabel.hidden = YES;
        YTCaptionButton.hidden = YES;
        return;
    }
    UIWindow *window = [[UIApplication sharedApplication] keyWindow];
    UIView *player = YTCaptionFindPlayer(window);
    if (!window || !player) {
        YTCaptionLabel.hidden = YES;
        YTCaptionButton.hidden = YES;
        return;
    }
    YTCaptionStyle();
    if (YTCaptionLabel.superview != window) {
        [YTCaptionButton removeFromSuperview];
        [YTCaptionLabel removeFromSuperview];
        [window addSubview:YTCaptionButton];
        [window addSubview:YTCaptionLabel];
    }
    CGRect frame = window.bounds;
    CGFloat width = frame.size.width - 24;
    YTCaptionLabel.frame = CGRectMake(12, frame.size.height - 96, width, 64);
    YTCaptionButton.frame = CGRectMake(frame.size.width - 54, 44, 42, 30);
    YTCaptionButton.hidden = NO;
    if (!YTCaptionOn || !YTCaptionCues.count) {
        YTCaptionLabel.hidden = YES;
        return;
    }
    double now = YTCaptionPlayerTime(player);
    if (now < 0) {
        YTCaptionLabel.hidden = YES;
        return;
    }
    NSString *line = nil;
    for (NSDictionary *cue in YTCaptionCues) {
        double start = [[cue objectForKey:@"start"] doubleValue] / 1000.0;
        double end = [[cue objectForKey:@"end"] doubleValue] / 1000.0;
        if (now >= start && now <= end) {
            line = [cue objectForKey:@"text"];
            break;
        }
    }
    YTCaptionLabel.text = line;
    YTCaptionLabel.hidden = line.length ? NO : YES;
    [window bringSubviewToFront:YTCaptionButton];
    [window bringSubviewToFront:YTCaptionLabel];
}

void YTCaptionPrepare(NSString *videoID) {
    YTCaptionVideoID = videoID;
    YTCaptionCues = nil;
    if (!YTPrefBool(@"captionOverlay", NO) || !YTPrefBool(@"captions", YES) || !videoID.length) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSArray *tracks = YTCaptionTracks(videoID);
        NSArray *preferred = [NSLocale preferredLanguages];
        NSString *device = (preferred.count ? [[preferred objectAtIndex:0] lowercaseString] : nil) ?: @"en";
        NSDictionary *pick = nil;
        NSDictionary *english = nil;
        for (NSDictionary *track in tracks) {
            NSString *lang = [[track objectForKey:@"lang"] lowercaseString] ?: @"";
            NSString *kind = [track objectForKey:@"kind"] ?: @"";
            BOOL autoMade = [kind isEqualToString:@"asr"];
            if (!pick && !autoMade && (device.length >= 2 ? [lang hasPrefix:[device substringToIndex:2]] : [lang hasPrefix:@"en"])) pick = track;
            if (!english && !autoMade && [lang hasPrefix:@"en"]) english = track;
            if (!pick && !autoMade) pick = track;
        }
        if (!pick) pick = english ?: (tracks.count ? [tracks objectAtIndex:0] : nil);
        NSString *url = [pick objectForKey:@"url"];
        NSData *xml = url.length ? YTGET(url) : nil;
        if (!xml.length && url.length) {
            YTCaptionForget(videoID);
            NSString *fresh = YTCaptionURL(videoID, [pick objectForKey:@"lang"], [pick objectForKey:@"kind"]);
            xml = fresh.length ? YTGET(fresh) : nil;
        }
        NSString *text = xml.length ? [[NSString alloc] initWithData:xml encoding:NSUTF8StringEncoding] : @"";
        NSArray *cues = YTCaptionParse(text);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![YTCaptionVideoID isEqualToString:videoID]) return;
            YTCaptionCues = cues;
            YTLog([NSString stringWithFormat:@"caption cues %@ %u", videoID, (unsigned)[cues count]]);
        });
    });
}

BOOL YTCaptionPrepared(NSString *videoID) {
    return videoID.length && [YTCaptionVideoID isEqualToString:videoID];
}

NSData *YTCaptionFeed(NSString *videoID) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?><feed xmlns='http://www.w3.org/2005/Atom' xmlns:yt='http://gdata.youtube.com/schemas/2007' yt:x='1'>"];
    if (YTPrefBool(@"captionOverlay", NO) && YTPrefBool(@"captions", YES) && videoID.length) {
        for (NSDictionary *track in YTCaptionTracks(videoID)) {
            NSString *lang = [track objectForKey:@"lang"];
            NSString *kind = [track objectForKey:@"kind"] ?: @"";
            NSString *name = [track objectForKey:@"name"] ?: lang;
            NSString *suffix = kind.length ? [NSString stringWithFormat:@".%@", kind] : @"";
            NSString *src = [NSString stringWithFormat:@"http://127.0.0.1:%d/%@.%@%@.srt", YTProxyPort, videoID, lang, suffix];
            NSString *derived = [kind isEqualToString:@"asr"] ? @"<yt:derived yt:x='1'>speechRecognition</yt:derived>" : @"";
            [xml appendFormat:@"<entry yt:x='1'><title yt:x='1'>%@</title><link rel='alternate' href='%@'/>%@<yt:captionTrack url='%@' lang='%@' kind='%@' yt:x='1'/></entry>",
             YTEscape(name), YTEscape(src), derived, YTEscape(src), YTEscape(lang), YTEscape(kind)];
        }
    }
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}


@implementation YTSubtitleTicker
- (void)tick:(NSTimer *)timer { YTCaptionTick(); }
- (void)toggle { YTCaptionToggle(); }
@end

void YTCaptionStart(void) {
    YTCaptionTicker = [[YTSubtitleTicker alloc] init];
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:YTCaptionTicker selector:@selector(tick:) userInfo:nil repeats:YES];
}
