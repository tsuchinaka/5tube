#import "5Tube.h"

NSMutableDictionary *YTPageCache;
NSMutableDictionary *YTTokenCache;
NSRecursiveLock *YTListLock;
NSMutableDictionary *YTCommentParams;
NSMutableDictionary *YTAPICache;
BOOL YTIsShortNode(id node, int depth) {
    if (!node || depth > 8) return NO;
    if ([node isKindOfClass:[NSString class]]) {
        NSString *text = node;
        if ([text rangeOfString:@"/shorts/"].location != NSNotFound) return YES;
        if ([text isEqualToString:@"SHORTS"]) return YES;
        if ([text isEqualToString:@"TILE_CONTENT_TYPE_SHORT"]) return YES;
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

BOOL YTIsLiveNode(id node, int depth) {
    if (!node || depth > 8) return NO;
    if ([node isKindOfClass:[NSDictionary class]]) {
        id live = YTGet(node, @"isLiveNow");
        if ([live respondsToSelector:@selector(boolValue)] && [live boolValue]) return YES;
        id badges = YTGet(node, @"badges");
        if ([badges isKindOfClass:[NSArray class]]) {
            for (id badge in badges) {
                id renderer = YTGet(badge, @"metadataBadgeRenderer");
                NSString *label = YTText(YTGet(renderer, @"label"));
                NSString *style = YTGet(renderer, @"style");
                if ([label isEqualToString:@"LIVE"] || [style isEqualToString:@"BADGE_STYLE_TYPE_LIVE_NOW"]) return YES;
            }
        }
        for (id child in [node allValues]) if (YTIsLiveNode(child, depth + 1)) return YES;
        return NO;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) if (YTIsLiveNode(child, depth + 1)) return YES;
    }
    return NO;
}

NSString *YTMarkLive(NSString *title) {
    if (!title.length) return @"● LIVE";
    if ([title hasPrefix:@"● LIVE"]) return title;
    return [@"● LIVE " stringByAppendingString:title];
}

void YTCollect(id node, NSMutableArray *out, NSMutableSet *seen) {
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
        if (YTIsShortNode(node, 0)) {
            YTLog([NSString stringWithFormat:@"skip short %@", videoID]);
            return;
        }
        [seen addObject:videoID];
        BOOL live = YTIsLiveNode(node, 0);
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        YTSet(item, @"id", videoID);
        YTSet(item, @"title", live ? YTMarkLive(YTText(title)) : YTText(title));
        YTSet(item, @"author", YTText(YTGet(node, @"longBylineText") ?: YTGet(node, @"shortBylineText") ?: YTGet(node, @"ownerText")));
        YTSet(item, @"length", live ? @"0" : YTText(YTGet(node, @"lengthText")));
        YTSet(item, @"views", YTText(YTGet(node, @"viewCountText") ?: YTGet(node, @"shortViewCountText")));
        YTSet(item, @"published", live ? @"LIVE" : YTText(YTGet(node, @"publishedTimeText")));
        if (live) YTSet(item, @"live", [NSNumber numberWithBool:YES]);
        [out addObject:item];
        return;
    }
    for (id child in [(NSDictionary *)node allValues]) YTCollect(child, out, seen);
}

NSArray *YTVideosFromJSON(id json) {
    NSMutableArray *out = [NSMutableArray array];
    YTCollect(json, out, [NSMutableSet set]);
    return out;
}

NSDictionary *YTDetails(NSString *videoID) {
    id json = YTPost(@"player", [NSDictionary dictionaryWithObjectsAndKeys:
                                 videoID, @"videoId",
                                 [NSNumber numberWithBool:YES], @"contentCheckOk",
                                 [NSNumber numberWithBool:YES], @"racyCheckOk",
                                 nil]);
    id status = YTGet(YTGet(json, @"playabilityStatus"), @"status");
    if (![status isEqualToString:@"OK"]) return nil;
    id streaming = YTGet(json, @"streamingData");
    id license = YTGet(streaming, @"licenseInfos");
    if ([license isKindOfClass:[NSArray class]] && [license count]) return nil;
    NSDictionary *details = YTGet(json, @"videoDetails");
    if (![details isKindOfClass:[NSDictionary class]]) return nil;
    BOOL live = [[YTGet(details, @"isLive") description] boolValue] ||
                [[YTGet(details, @"isLiveContent") description] boolValue];
    NSString *hls = YTGet(streaming, @"hlsManifestUrl");
    if (![hls isKindOfClass:[NSString class]]) hls = nil;
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    YTSet(item, @"id", videoID);
    id title = YTGet(details, @"title");
    NSString *titleText = [title isKindOfClass:[NSString class]] ? title : @"Video";
    YTSet(item, @"title", live ? YTMarkLive(titleText) : titleText);
    id author = YTGet(details, @"author");
    YTSet(item, @"author", [author isKindOfClass:[NSString class]] ? author : @"");
    id views = YTGet(details, @"viewCount");
    YTSet(item, @"views", [views isKindOfClass:[NSString class]] ? views : @"0");
    id length = YTGet(details, @"lengthSeconds");
    YTSet(item, @"length", live ? @"0" : ([length isKindOfClass:[NSString class]] ? length : @"0"));
    YTSet(item, @"seconds", [NSNumber numberWithInteger:[[item objectForKey:@"length"] integerValue]]);
    id desc = YTGet(details, @"shortDescription");
    YTSet(item, @"description", [desc isKindOfClass:[NSString class]] ? desc : @"");
    if (live) {
        YTSet(item, @"live", [NSNumber numberWithBool:YES]);
        YTSet(item, @"published", @"LIVE");
        if (hls.length) {
            YTHLSSave(videoID, hls);
            YTSet(item, @"hls", hls);
        }
        YTSet(item, @"play", YTLocalLiveURL(videoID));
        YTLog([NSString stringWithFormat:@"details live %@ hls %@", videoID, hls.length ? @"yes" : @"no"]);
    } else {
        NSString *play = YTPlayURL(videoID);
        if (play.length) YTSet(item, @"play", play);
    }
    return item;
}

NSString *YTEntry(NSDictionary *item) {
    NSString *videoID = [item objectForKey:@"id"] ?: @"";
    NSString *title = YTEscape([item objectForKey:@"title"] ?: @"Video");
    NSString *author = YTEscape([item objectForKey:@"author"] ?: @"");
    NSString *desc = YTEscape([item objectForKey:@"description"] ?: [item objectForKey:@"published"] ?: @"");
    NSInteger seconds = [[item objectForKey:@"seconds"] integerValue];
    if (seconds <= 0) seconds = YTSeconds([item objectForKey:@"length"]);
    NSString *views = YTDigits([item objectForKey:@"views"] ?: @"0");
    BOOL live = [[item objectForKey:@"live"] boolValue];
    NSString *liveURL = live ? YTLocalLiveURL(videoID) : nil;
    if (live) YTLog([NSString stringWithFormat:@"entry live %@", videoID]);
    NSInteger contentSeconds = live ? 3600 : seconds;
    BOOL high = YTWant720();
    NSString *hi = live ? liveURL : (high ? YTLocalPlayURL(videoID, YES) : YTLocalPlayURL(videoID, NO));
    NSString *lo = live ? liveURL : ((high && YTPrefBool(@"cellular720", YES)) ? hi : YTLocalPlayURL(videoID, NO));
    if (!hi.length) hi = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", videoID];
    if (!lo.length) lo = hi;
    NSString *playerURL = live ? liveURL : [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", videoID];
    if (!playerURL.length) playerURL = hi;
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
            "<yt:accessControl action='comment' permission='allowed'/>"
            "<yt:accessControl action='rate' permission='allowed'/>"
            "<gd:comments yt:x='1'><gd:feedLink rel='http://gdata.youtube.com/schemas/2007#comments' href='http://gdata.youtube.com/feeds/api/videos/%@/comments' countHint='10'/></gd:comments>"
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
            "<media:player url='%@'/>"
            "</media:group>"
            "</entry>",
            videoID, title, author, videoID, views, title, desc, title, videoID, (long)seconds, author, thumb,
            YTEscape(lo), (long)contentSeconds,
            YTEscape(lo), (long)contentSeconds,
            YTEscape(hi), (long)contentSeconds,
            YTEscape(hi), (long)contentSeconds,
            YTEscape(playerURL)];
}

NSData *YTFeed(NSArray *items, NSInteger start, NSString *nextURL) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?>"];
    [xml appendString:@"<feed xmlns='http://www.w3.org/2005/Atom' "
                       "xmlns:openSearch='http://a9.com/-/spec/opensearch/1.1/' "
                       "xmlns:media='http://search.yahoo.com/mrss/' "
                       "xmlns:yt='http://gdata.youtube.com/schemas/2007' "
                       "xmlns:gd='http://schemas.google.com/g/2005' "
                       "xmlns:app='http://www.w3.org/2007/app' "
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

NSArray *YTPage(NSArray *items, NSInteger start, NSInteger limit) {
    if (start < 1) start = 1;
    if (limit < 1) limit = 25;
    if (limit > 50) limit = 50;
    NSInteger skip = start - 1;
    if (skip >= (NSInteger)[items count]) return [NSArray array];
    NSInteger end = (NSInteger)[items count];
    if (skip + limit < end) end = skip + limit;
    return [items subarrayWithRange:NSMakeRange((NSUInteger)skip, (NSUInteger)(end - skip))];
}

void YTListEnter(void) {
    if (!YTListLock) YTListLock = [[NSRecursiveLock alloc] init];
    [YTListLock lock];
}

void YTListLeave(void) {
    [YTListLock unlock];
}

NSString *YTFindToken(id node, int depth) {
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

NSString *YTFindBrowseID(id node, int depth) {
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

static void YTCollectContinuations(id node, NSMutableArray *out, int depth) {
    if (!node || depth > 12) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) YTCollectContinuations(child, out, depth + 1);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    id command = YTGet(node, @"continuationCommand");
    id token = YTGet(command, @"token");
    if ([token isKindOfClass:[NSString class]] && [token length] && ![out containsObject:token]) [out addObject:token];
    for (id child in [node allValues]) YTCollectContinuations(child, out, depth + 1);
}

static BOOL YTHasKey(id node, NSString *key, int depth) {
    if (!node || depth > 12) return NO;
    if ([node isKindOfClass:[NSDictionary class]]) {
        if (YTGet(node, key)) return YES;
        for (id child in [node allValues]) if (YTHasKey(child, key, depth + 1)) return YES;
        return NO;
    }
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) if (YTHasKey(child, key, depth + 1)) return YES;
    }
    return NO;
}

void YTCollectComments(id node, NSMutableArray *out, int depth) {
    if (!node || depth > 16) return;
    if ([node isKindOfClass:[NSArray class]]) {
        for (id child in node) YTCollectComments(child, out, depth + 1);
        return;
    }
    if (![node isKindOfClass:[NSDictionary class]]) return;
    id payload = YTGet(node, @"commentEntityPayload");
    if ([payload isKindOfClass:[NSDictionary class]]) {
        id props = YTGet(payload, @"properties");
        id content = YTGet(props, @"content");
        NSString *text = [content isKindOfClass:[NSString class]] ? content : YTText(YTGet(content, @"content"));
        if (!text.length) text = YTText(content);
        NSString *author = YTText(YTGet(YTGet(payload, @"author"), @"displayName"));
        NSString *date = YTText(YTGet(props, @"publishedTime"));
        id cid = YTGet(props, @"commentId");
        if (text.length) {
            NSMutableDictionary *item = [NSMutableDictionary dictionary];
            YTSet(item, @"text", text);
            YTSet(item, @"author", author);
            YTSet(item, @"date", date);
            if (cid) YTSet(item, @"id", cid);
            [out addObject:item];
        }
        return;
    }
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

NSArray *YTFillKey(NSString *key, NSString *query, NSString *browseID, NSInteger need) {
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

NSArray *YTFillSearch(NSString *key, NSString *query, NSString *params, NSString *region, NSInteger need) {
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

NSString *YTChartRegion(NSArray *parts) {
    NSString *maybe = YTAt(parts, 4);
    if ([YTAt(parts, 5) length] && maybe.length == 2) return [maybe uppercaseString];
    NSString *code = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode];
    return code.length == 2 ? [code uppercaseString] : @"US";
}

NSArray *YTMostViewed(NSString *time, NSString *region, NSInteger need) {
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

NSArray *YTChannelUploads(NSString *user) {
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

NSString *YTFindCreateParams(id node, int depth) {
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

void YTSaveCommentParams(NSString *videoID, id json) {
    NSString *params = YTFindCreateParams(json, 0);
    if (!videoID.length || !params.length) return;
    if (!YTCommentParams) YTCommentParams = [NSMutableDictionary dictionary];
    [YTCommentParams setObject:params forKey:videoID];
}

NSData *YTCommentFeed(NSString *videoID) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?><feed xmlns='http://www.w3.org/2005/Atom' xmlns:openSearch='http://a9.com/-/spec/opensearch/1.1/' xmlns:yt='http://gdata.youtube.com/schemas/2007' yt:x='1'>"];
    if (YTPrefBool(@"comments", YES) && videoID.length) {
        YTLog([NSString stringWithFormat:@"comments feed %@", videoID]);
        id first = YTPostWeb(@"next", [NSDictionary dictionaryWithObject:videoID forKey:@"videoId"]);
        YTSaveCommentParams(videoID, first);
        NSMutableArray *tokens = [NSMutableArray array];
        YTCollectContinuations(first, tokens, 0);
        YTLog([NSString stringWithFormat:@"comments next %u", (unsigned)[tokens count]]);
        NSMutableArray *comments = [NSMutableArray array];
        for (NSString *token in tokens) {
            id page = YTPostWeb(@"next", [NSDictionary dictionaryWithObject:token forKey:@"continuation"]);
            if (!YTHasKey(page, @"commentThreadRenderer", 0) && !YTHasKey(page, @"commentEntityPayload", 0)) continue;
            YTCollectComments(page, comments, 0);
            YTLog([NSString stringWithFormat:@"comments page %u", (unsigned)[comments count]]);
            if (comments.count) break;
        }
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableArray *unique = [NSMutableArray array];
        for (NSDictionary *item in comments) {
            id cid = [item objectForKey:@"id"];
            if (cid && [seen containsObject:cid]) continue;
            if (cid) [seen addObject:cid];
            [unique addObject:item];
        }
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
        NSString *now = [formatter stringFromDate:[NSDate date]];
        [xml appendFormat:@"<openSearch:totalResults>%u</openSearch:totalResults><openSearch:startIndex>1</openSearch:startIndex><openSearch:itemsPerPage>%u</openSearch:itemsPerPage>",
         (unsigned)[unique count], (unsigned)[unique count]];
        for (NSDictionary *item in unique) {
            NSString *cid = [item objectForKey:@"id"] ?: now;
            NSString *date = [item objectForKey:@"date"];
            if (!date.length) date = now;
            [xml appendFormat:@"<entry yt:x='1'><id>tag:youtube.com,2008:video:%@:comment:%@</id><published>%@</published><updated>%@</updated><author yt:x='1'><name yt:x='1'>%@</name></author><content type='text'>%@</content></entry>",
             YTEscape(videoID), YTEscape([cid description]), YTEscape(date), YTEscape(date),
             YTEscape([item objectForKey:@"author"] ?: @""), YTEscape([item objectForKey:@"text"] ?: @"")];
        }
        YTLog([NSString stringWithFormat:@"comments %@ %u", videoID, (unsigned)[unique count]]);
    }
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

NSString *YTFindHandle(id node, int depth) {
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

NSString *YTFindParams(id node, int depth) {
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

NSMutableDictionary *YTVideoItem(NSString *videoID, NSString *title, NSString *author, NSString *desc, NSInteger seconds, NSString *views) {
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

void YTCollectTiles(id node, NSMutableArray *videos, NSMutableArray *playlists, NSMutableSet *seen, int depth) {
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
                if (YTIsShortNode(tile, 0)) {
                    YTLog([NSString stringWithFormat:@"skip short %@", cid]);
                    return;
                }
                [seen addObject:cid];
                NSMutableDictionary *item = YTVideoItem(cid, title, author, subtitle, 0, @"0");
                if (item && YTIsLiveNode(tile, 0)) {
                    [item setObject:[NSNumber numberWithBool:YES] forKey:@"live"];
                    [item setObject:YTMarkLive([item objectForKey:@"title"]) forKey:@"title"];
                    [item setObject:@"0" forKey:@"length"];
                }
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

NSString *YTBestImage(id node) {
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

NSString *YTIconURL(NSString *remote) {
    if (!remote.length) return @"";
    if (YTProxyPort <= 0) return remote;
    return [NSString stringWithFormat:@"http://127.0.0.1:%d/icon?u=%@", YTProxyPort, YTQueryEscape(remote)];
}

NSString *YTJoinedCount(id node, int depth) {
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

void YTCollectTabs(id node, NSMutableArray *out, NSMutableSet *seen, int depth) {
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

id YTAuthPost(NSString *browseID, NSString *params, NSString *continuation) {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    if (continuation.length) [body setObject:continuation forKey:@"continuation"];
    else {
        if (browseID.length) [body setObject:browseID forKey:@"browseId"];
        if (params.length) [body setObject:params forKey:@"params"];
    }
    return YTPostAuth(@"browse", body);
}

NSArray *YTAuthVideos(NSString *key, NSString *browseID, NSString *params, NSInteger need) {
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

NSArray *YTLiked(NSInteger need) {
    return YTAuthVideos(@"likes", @"VLLL", nil, need);
}

NSArray *YTSubVideos(NSInteger need) {
    return YTAuthVideos(@"subs", @"FEsubscriptions", nil, need);
}

NSArray *YTRelated(NSString *videoID, NSInteger need) {
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

NSArray *YTPlaylistVideos(NSString *playlistID, NSInteger need) {
    if (!playlistID.length) return [NSArray array];
    NSString *browse = [playlistID hasPrefix:@"VL"] ? playlistID : [@"VL" stringByAppendingString:playlistID];
    return YTAuthVideos([@"pl:" stringByAppendingString:playlistID], browse, nil, need);
}

NSArray *YTMineUploads(NSInteger need) {
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

NSArray *YTSubscriptionList(NSInteger need) {
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

NSArray *YTPlaylistList(NSInteger need) {
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

NSString *YTSubEntry(NSDictionary *item) {
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

NSString *YTPlaylistEntry(NSDictionary *item) {
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

NSData *YTRawFeed(NSString *body, NSInteger start, NSUInteger count, NSString *nextURL) {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version='1.0' encoding='UTF-8'?>"];
    [xml appendString:@"<feed xmlns='http://www.w3.org/2005/Atom' "
                       "xmlns:openSearch='http://a9.com/-/spec/opensearch/1.1/' "
                       "xmlns:media='http://search.yahoo.com/mrss/' "
                       "xmlns:yt='http://gdata.youtube.com/schemas/2007' "
                       "xmlns:gd='http://schemas.google.com/g/2005' "
                       "xmlns:app='http://www.w3.org/2007/app' "
                       "yt:x='1'>"];
    [xml appendFormat:@"<openSearch:startIndex yt:x='1'>%ld</openSearch:startIndex>", (long)(start < 1 ? 1 : start)];
    [xml appendFormat:@"<openSearch:totalResults yt:x='1'>%u</openSearch:totalResults>", (unsigned)(count + (nextURL.length ? 500 : 0))];
    [xml appendFormat:@"<openSearch:itemsPerPage yt:x='1'>%u</openSearch:itemsPerPage>", (unsigned)count];
    if (nextURL.length) [xml appendFormat:@"<link rel='next' href='%@'/>", YTEscape(nextURL)];
    if (body.length) [xml appendString:body];
    [xml appendString:@"</feed>"];
    return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

NSString *YTNextPage(NSURLRequest *request, NSInteger start, NSInteger limit) {
    NSMutableString *next = [[[request URL] absoluteString] mutableCopy] ?: [NSMutableString string];
    NSString *from = [NSString stringWithFormat:@"start-index=%ld", (long)start];
    NSString *to = [NSString stringWithFormat:@"start-index=%ld", (long)(start + limit)];
    if ([next rangeOfString:from].location != NSNotFound) [next replaceOccurrencesOfString:from withString:to options:0 range:NSMakeRange(0, next.length)];
    else [next appendFormat:@"%@start-index=%ld", [next rangeOfString:@"?"].location == NSNotFound ? @"?" : @"&", (long)(start + limit)];
    return next;
}
