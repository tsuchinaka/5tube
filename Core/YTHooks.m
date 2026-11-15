#import "5Tube.h"

@interface YTFakeConnection : NSURLConnection
@property (nonatomic, assign) id feedDelegate;
@property (nonatomic, assign) BOOL cancelled;
@property (nonatomic, retain) NSURLRequest *loginRequest;
- (void)begin:(NSURLRequest *)request;
@end


BOOL YTAuthDidLoad;
id (*YTOrigInitConn)(id, SEL, NSURLRequest *, id, BOOL);
void (*YTOrigSAXLoad)(id, SEL, id);
void (*YTOrigFeedLoad)(id, SEL, id);
void (*YTOrigAuthLoad)(id, SEL, id, id, BOOL);
void (*YTOrigSearchFail)(id, SEL, id);
void (*YTOrigFeedFail)(id, SEL, id);
void (*YTOrigFeedParse)(id, SEL);
NSURLConnection *(*YTOrigConnect)(id, SEL, NSURLRequest *, id);
NSData *(*YTOrigSync)(id, SEL, NSURLRequest *, NSURLResponse **, NSError **);
double (*YTOrigDuration)(id, SEL);
double (*YTOrigPlayable)(id, SEL);
double (*YTOrigSeekEnd)(id, SEL);
double (*YTOrigPlayEnd)(id, SEL);
void (*YTOrigSetPath)(id, SEL, id);
void (*YTOrigPlayVideo)(id, SEL, id, id);
void (*YTOrigPlayVideoID)(id, SEL, id, id, id);
id (*YTOrigReq)(id, SEL, NSURL *, NSUInteger, NSTimeInterval);
BOOL YTIsDeadLogin(NSURLRequest *request) {
    NSString *abs = [[[request URL] absoluteString] lowercaseString] ?: @"";
    if ([abs rangeOfString:@"applelogin"].location != NSNotFound) return YES;
    if ([abs rangeOfString:@"youtube/accounts"].location != NSNotFound) return YES;
    if ([abs rangeOfString:@"clientlogin"].location != NSNotFound) return YES;
    return NO;
}

BOOL YTShouldHandle(NSURLRequest *request) {
    if ([NSURLProtocol propertyForKey:YTMark inRequest:request]) return NO;
    NSString *abs = [[[request URL] absoluteString] lowercaseString] ?: @"";
    if ([abs rangeOfString:@"gdata.youtube.com"].location != NSNotFound) return YES;
    if ([abs rangeOfString:@"/feeds/api/"].location != NSNotFound) return YES;
    if (YTPrefBool(@"suggestions", YES) && [abs rangeOfString:@"suggestqueries.google.com"].location != NSNotFound) return YES;
    return NO;
}

NSData *YTAtomForRequest(NSURLRequest *request) {
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

NSData *YTSuggestData(NSURLRequest *request) {
    NSString *q = [YTQuery([request URL]) objectForKey:@"q"] ?: @"";
    NSData *raw = YTGET([[NSString stringWithFormat:@"https://suggestqueries.google.com/complete/search?client=firefox&ds=yt&q=%@",
                          [q stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]] stringByReplacingOccurrencesOfString:@" " withString:@"%20"]);
    if (raw.length) return raw;
    return [[NSString stringWithFormat:@"[\"%@\",[]]", YTEscape(q)] dataUsingEncoding:NSUTF8StringEncoding];
}

void YTDeliverLogin(id connection, id delegate, NSURLRequest *request) {
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

id YTHookInitConn(id self, SEL cmd, NSURLRequest *request, id delegate, BOOL start) {
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

void YTReleaseFeedDelegate(id self) {
    objc_setAssociatedObject(self, "YTFeedDelegate", nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

void YTFinishLoad(id self, NSURL *url, NSData *body) {
    YTLog([NSString stringWithFormat:@"load back %u %@", (unsigned)[body length], NSStringFromClass([self class])]);
    if (![body length] || !url) {
        NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotConnectToHost userInfo:nil];
        @try { [self connection:nil didFailWithError:error]; } @catch (NSException *exception) { YTWriteCrash(exception.reason); }
        YTReleaseFeedDelegate(self);
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
    YTReleaseFeedDelegate(self);
}

void YTStartLoad(id self, id request) {
    YTAuthDidLoad = YES;
    NSURL *url = [request respondsToSelector:@selector(URL)] ? [request URL] : nil;
    YTLog([NSString stringWithFormat:@"loadRequest %@ %@", NSStringFromClass([self class]), [url absoluteString]]);
    // The feed request keeps its delegate unretained. A screen can close while
    // the answer is coming back; without this the parser messages freed memory.
    id delegate = YTPSDelegate(self);
    if (delegate) objc_setAssociatedObject(self, "YTFeedDelegate", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

void YTHookSAXLoad(id self, SEL cmd, id request) {
    if ([request isKindOfClass:[NSURLRequest class]] && YTShouldHandle(request)) {
        YTStartLoad(self, request);
        return;
    }
    YTOrigSAXLoad(self, cmd, request);
}

void YTHookFeedLoad(id self, SEL cmd, id request) {
    if ([request isKindOfClass:[NSURLRequest class]] && YTShouldHandle(request)) {
        YTAuthDidLoad = YES;
        YTStartLoad(self, request);
        return;
    }
    YTOrigFeedLoad(self, cmd, request);
}

void YTHookAuthLoad(id self, SEL cmd, id request, id delegate, BOOL auth) {
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

void YTHookSearchFail(id self, SEL cmd, id error) {
    YTLog([NSString stringWithFormat:@"fail %@ %@", NSStringFromClass([self class]), error]);
    YTOrigSearchFail(self, cmd, error);
}

void YTHookFeedFail(id self, SEL cmd, id error) {
    YTLog([NSString stringWithFormat:@"fail %@ %@", NSStringFromClass([self class]), error]);
    YTOrigFeedFail(self, cmd, error);
}

void YTHookFeedParse(id self, SEL cmd) {
    YTLog([NSString stringWithFormat:@"parsed %@", NSStringFromClass([self class])]);
    YTOrigFeedParse(self, cmd);
}

void YTHookSAX(void) {
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
    YTHookMethod(NSClassFromString(@"YTContentView"), @"addVideoToHistory:", (IMP)YTHookAddHistory, (IMP *)&YTOrigAddHistory);
    YTHookMethod(NSClassFromString(@"YTContentView"), @"_addVideoToHistoryNow:", (IMP)YTHookAddHistoryNow, (IMP *)&YTOrigAddHistoryNow);
    YTVideoPermissionsInstall();
    YTHookMethod(NSClassFromString(@"YTContentView"), @"_updateHiddenControllers", (IMP)YTHookHiddenControllers, (IMP *)&YTOrigHiddenControllers);
}

NSData *YTHookSync(id self, SEL cmd, NSURLRequest *request, NSURLResponse **response, NSError **error) {
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

NSURLConnection *YTHookConnect(id self, SEL cmd, NSURLRequest *request, id delegate) {
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

double YTKnownDuration(id player) {
    if (![player respondsToSelector:@selector(moviePath)]) return 0;
    NSString *path = [player performSelector:@selector(moviePath)];
    NSString *videoID = YTVideoIDFromPath(path);
    if (!videoID) return 0;
    [YTCacheLock lock];
    NSNumber *seconds = [YTDurationCache objectForKey:videoID];
    [YTCacheLock unlock];
    return seconds ? [seconds doubleValue] : 0;
}

double YTFixTime(id self, double (*orig)(id, SEL), SEL cmd) {
    double value = orig ? orig(self, cmd) : 0;
    if (isnan(value) || isinf(value)) return 0;
    if (value > 0.5 && value < 86400.0 * 12.0) return value;
    double known = YTKnownDuration(self);
    return known > 0.5 ? known : value;
}

double YTHookDuration(id self, SEL cmd) { return YTFixTime(self, YTOrigDuration, cmd); }

double YTHookPlayable(id self, SEL cmd) { return YTFixTime(self, YTOrigPlayable, cmd); }

double YTHookSeekEnd(id self, SEL cmd) { return YTFixTime(self, YTOrigSeekEnd, cmd); }

double YTHookPlayEnd(id self, SEL cmd) { return YTFixTime(self, YTOrigPlayEnd, cmd); }

void YTHookSetPath(id self, SEL cmd, id path) {
    YTLog([NSString stringWithFormat:@"movie %@", path]);
    if (YTOrigSetPath) YTOrigSetPath(self, cmd, path);
}

void YTHookPlayVideo(id self, SEL cmd, id video, id list) {
    NSString *vid = YTVideoToken(video);
    if (vid.length && !YTCaptionPrepared(vid)) YTCaptionPrepare(vid);
    if (YTOrigPlayVideo) YTOrigPlayVideo(self, cmd, video, list);
}

void YTHookPlayVideoID(id self, SEL cmd, id video, id list, id videoID) {
    NSString *vid = YTVideoToken(video);
    if (!vid.length && [videoID isKindOfClass:[NSString class]]) vid = videoID;
    if (vid.length && !YTCaptionPrepared(vid)) YTCaptionPrepare(vid);
    if (YTOrigPlayVideoID) YTOrigPlayVideoID(self, cmd, video, list, videoID);
}

void YTHookPlayer(void) {
    Class player = NSClassFromString(@"UIMoviePlayerController");
    YTHookMethod(player, @"duration", (IMP)YTHookDuration, (IMP *)&YTOrigDuration);
    YTHookMethod(player, @"playableDuration", (IMP)YTHookPlayable, (IMP *)&YTOrigPlayable);
    YTHookMethod(player, @"seekableEndTime", (IMP)YTHookSeekEnd, (IMP *)&YTOrigSeekEnd);
    YTHookMethod(player, @"playableEndTime", (IMP)YTHookPlayEnd, (IMP *)&YTOrigPlayEnd);
    YTHookMethod(player, @"setMoviePath:", (IMP)YTHookSetPath, (IMP *)&YTOrigSetPath);
    YTHookMethod(NSClassFromString(@"YTController"), @"playVideo:inList:", (IMP)YTHookPlayVideo, (IMP *)&YTOrigPlayVideo);
    YTHookMethod(NSClassFromString(@"YTController"), @"_playVideo:inList:orLoadVideoWithID:", (IMP)YTHookPlayVideoID, (IMP *)&YTOrigPlayVideoID);
}

id YTHookReq(id self, SEL cmd, NSURL *url, NSUInteger policy, NSTimeInterval timeout) {
    YTLog([NSString stringWithFormat:@"request %@", [url absoluteString]]);
    return YTOrigReq(self, cmd, url, policy, timeout);
}

void YTPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)YTPrefsID);
    YTLog(@"prefs reloaded");
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

void YTHooksInstall(void) {
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
