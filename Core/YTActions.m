#import "5Tube.h"

static BOOL YTHookAllowComments(id self, SEL cmd) { return YES; }
static BOOL YTHookAllowRating(id self, SEL cmd) { return YES; }
static id (*YTOrigVideoInit)(id, SEL, BOOL, BOOL, BOOL);
static id YTHookVideoInit(id self, SEL cmd, BOOL comments, BOOL rating, BOOL own) {
    return YTOrigVideoInit ? YTOrigVideoInit(self, cmd, YES, YES, own) : self;
}

static id (*YTOrigCommentsURL)(id, SEL);
static id YTHookCommentsURL(id self, SEL cmd) {
    NSString *vid = YTVideoToken(self);
    if (vid.length) {
        YTLog([NSString stringWithFormat:@"comments getter %@", vid]);
        return [NSURL URLWithString:[NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/videos/%@/comments", vid]];
    }
    return YTOrigCommentsURL ? YTOrigCommentsURL(self, cmd) : nil;
}

static id (*YTOrigCommentsRequestInit)(id, SEL, id, id);
static id YTHookCommentsRequestInit(id self, SEL cmd, id video, id delegate) {
    YTLog([NSString stringWithFormat:@"comments request init %@", YTVideoToken(video) ?: @"-"]);
    if (video) {
        NSString *vid = YTVideoToken(video);
        Ivar ivar = class_getInstanceVariable([video class], "_commentsURL");
        if (vid.length && ivar && !object_getIvar(video, ivar)) {
            NSString *text = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/videos/%@/comments", vid];
            const char *type = ivar_getTypeEncoding(ivar);
            id value = (type && strstr(type, "NSURL")) ? [NSURL URLWithString:text] : text;
            objc_setAssociatedObject(video, ivar, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            object_setIvar(video, ivar, value);
            YTLog([NSString stringWithFormat:@"comments url %@", vid]);
        }
    }
    return YTOrigCommentsRequestInit ? YTOrigCommentsRequestInit(self, cmd, video, delegate) : nil;
}

// YTCommentsRequest overrides loadRequest: and hands the URL to
// YTAuthenticator. Device auth never completes, so the request stays
// deferred and the comments view spins forever. Deliver it ourselves.
static void YTHookCommentsLoad(id self, SEL cmd, id request) {
    NSURL *url = [request respondsToSelector:@selector(URL)] ? [request URL] : nil;
    YTLog([NSString stringWithFormat:@"comments load %@", [url absoluteString]]);
    YTStartLoad(self, request);
}

static Ivar YTFindIvar(id object, NSString *name) {
    Class cls = [object class];
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, [name UTF8String]);
        if (ivar) return ivar;
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static void YTSetFlagIvar(id object, Ivar ivar) {
    if (!ivar) return;
    const char *type = ivar_getTypeEncoding(ivar);
    if (!type) return;
    if (type[0] == '@') {
        objc_setAssociatedObject(object, ivar, [NSNumber numberWithBool:YES], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        object_setIvar(object, ivar, [NSNumber numberWithBool:YES]);
    } else {
        *(BOOL *)((char *)(__bridge void *)object + ivar_getOffset(ivar)) = YES;
    }
}

void YTFixVideoObject(id video) {
    if (!video) return;
    NSString *vid = YTVideoToken(video);
    if (!vid.length) return;
    Ivar comments = YTFindIvar(video, @"_commentsURL");
    if (comments && !object_getIvar(video, comments)) {
        NSString *text = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/videos/%@/comments", vid];
        const char *type = ivar_getTypeEncoding(comments);
        id value = (type && strstr(type, "NSURL")) ? [NSURL URLWithString:text] : text;
        objc_setAssociatedObject(video, comments, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        object_setIvar(video, comments, value);
        YTLog([NSString stringWithFormat:@"fixed comments %@", vid]);
    }
    YTSetFlagIvar(video, YTFindIvar(video, @"_allowComments"));
    YTSetFlagIvar(video, YTFindIvar(video, @"_allowRating"));
}

void YTFixVideosInSource(id source) {
    if (!source) return;
    Ivar ivar = YTFindIvar(source, @"_videos");
    if (!ivar) return;
    id videos = object_getIvar(source, ivar);
    if (![videos isKindOfClass:[NSArray class]]) return;
    for (id video in videos) YTFixVideoObject(video);
}

static void (*YTOrigCommentsViewSetVideo)(id, SEL, id);
static void YTHookCommentsViewSetVideo(id self, SEL cmd, id video) {
    YTFixVideoObject(video);
    if (YTOrigCommentsViewSetVideo) YTOrigCommentsViewSetVideo(self, cmd, video);
}

static void (*YTOrigDetailsViewSetVideo)(id, SEL, id);
static void YTHookDetailsViewSetVideo(id self, SEL cmd, id video) {
    YTFixVideoObject(video);
    if (YTOrigDetailsViewSetVideo) YTOrigDetailsViewSetVideo(self, cmd, video);
}

void YTVideoPermissionsInstall(void) {
    Class video = NSClassFromString(@"YTVideo");
    YTHookMethod(video, @"allowComments", (IMP)YTHookAllowComments, NULL);
    YTHookMethod(video, @"allowRating", (IMP)YTHookAllowRating, NULL);
    YTHookMethod(video, @"initAllowingComments:allowingRating:ownVideo:", (IMP)YTHookVideoInit, (IMP *)&YTOrigVideoInit);
    YTHookMethod(video, @"commentsURL", (IMP)YTHookCommentsURL, (IMP *)&YTOrigCommentsURL);
    YTHookMethod(NSClassFromString(@"YTCommentsRequest"), @"initRequestingCommentsForVideo:withDelegate:", (IMP)YTHookCommentsRequestInit, (IMP *)&YTOrigCommentsRequestInit);
    YTHookMethod(NSClassFromString(@"YTCommentsRequest"), @"loadRequest:", (IMP)YTHookCommentsLoad, NULL);
    YTHookMethod(NSClassFromString(@"YTCommentsView"), @"setVideo:", (IMP)YTHookCommentsViewSetVideo, (IMP *)&YTOrigCommentsViewSetVideo);
    YTHookMethod(NSClassFromString(@"YTVideoDetailsView"), @"setVideo:", (IMP)YTHookDetailsViewSetVideo, (IMP *)&YTOrigDetailsViewSetVideo);
}

void (*YTOrigAddHistory)(id, SEL, id);
void (*YTOrigAddHistoryNow)(id, SEL, id);
void (*YTOrigHistoryReload)(id, SEL);
void (*YTOrigMyVideosReload)(id, SEL);

static double YTVideoDuration(id video) {
    if (!video) return 0;
    SEL sel = @selector(duration);
    Method method = class_getInstanceMethod([video class], sel);
    if (!method) return 0;
    char type = method_getTypeEncoding(method)[0];
    if (type == 'd') return ((double (*)(id, SEL))objc_msgSend)(video, sel);
    if (type == 'f') return ((float (*)(id, SEL))objc_msgSend)(video, sel);
    return ((int (*)(id, SEL))objc_msgSend)(video, sel);
}

static BOOL YTSkipLongHistory(id self, NSString *label, id video) {
    double seconds = YTVideoDuration(video);
    if (seconds < 3600) return NO;
    YTLog([NSString stringWithFormat:@"%@ long %@ %.0f", label, YTVideoToken(video), seconds]);
    return YES;
}

void YTHookAddHistory(id self, SEL cmd, id video) {
    if (YTSkipLongHistory(self, @"skip history", video)) return;
    if (YTOrigAddHistory) YTOrigAddHistory(self, cmd, video);
}

void YTHookAddHistoryNow(id self, SEL cmd, id video) {
    if (YTSkipLongHistory(self, @"skip history now", video)) return;
    if (YTOrigAddHistoryNow) YTOrigAddHistoryNow(self, cmd, video);
}

id YTPSDelegate(id request) {
    Class cls = [request class];
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, "_delegate");
        if (ivar) return object_getIvar(request, ivar);
        cls = class_getSuperclass(cls);
    }
    if ([request respondsToSelector:@selector(delegate)]) return [request performSelector:@selector(delegate)];
    return nil;
}

NSArray *YTPSItems(BOOL playlists) {
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

void YTDeliverPS(id request, BOOL playlists) {
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

NSString *YTVideoToken(id video) {
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

NSString *YTResolveChannel(NSString *name) {
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

NSString *YTTailID(id value) {
    NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
    if (!text.length) return nil;
    NSString *name = [text lastPathComponent];
    NSRange q = [name rangeOfString:@"?"];
    if (q.location != NSNotFound) name = [name substringToIndex:q.location];
    return name.length ? name : nil;
}

void YTFinishPostError(id self, int type, id error) {
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(YTAuthenticatedAccountPost:didFinishWithType:error:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, int, id))objc_msgSend)(delegate, sel, self, type, error);
}

void YTFinishPost(id self, int type) {
    YTFinishPostError(self, type, nil);
}

void YTPostNote(NSString *name) {
    if (!name.length) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:nil];
    });
}

void YTHookPostComment(id self, SEL cmd, id text, id video) {
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

NSDictionary *YTLikeBody(NSString *videoID) {
    return [NSDictionary dictionaryWithObject:[NSDictionary dictionaryWithObject:(videoID ?: @"") forKey:@"videoId"] forKey:@"target"];
}

void YTHookRate(id self, SEL cmd, int liked, id video) {
    NSString *vid = YTVideoToken(video);
    BOOL ok = YTAct(liked ? @"like/like" : @"like/dislike", YTLikeBody(vid));
    if (ok) {
        YTFinishPost(self, 10);
        YTPostNote(@"YTVideoDidChangeNotification");
    }
    YTLog([NSString stringWithFormat:@"rate %d %@", liked, vid ?: @"-"]);
}

void YTHookAddFav(id self, SEL cmd, id video) {
    NSString *vid = YTVideoToken(video);
    if (YTAct(@"like/like", YTLikeBody(vid))) {
        YTFinishPost(self, 1);
        YTPostNote(@"YTVideoBookmarksDidChangeNotification");
    }
    YTLog([NSString stringWithFormat:@"favorite %@", vid ?: @"-"]);
}

void YTHookRemoveFav(id self, SEL cmd, id video) {
    NSString *vid = YTVideoToken(video);
    if (YTAct(@"like/removelike", YTLikeBody(vid))) {
        YTFinishPost(self, 2);
        YTPostNote(@"YTVideoBookmarksDidChangeNotification");
    }
    YTLog([NSString stringWithFormat:@"unfavorite %@", vid ?: @"-"]);
}

void YTHookSubscribe(id self, SEL cmd, id user) {
    NSString *name = [user isKindOfClass:[NSString class]] ? user : YTTailID(user);
    NSString *channel = YTResolveChannel(name);
    BOOL ok = channel.length && YTAct(@"subscription/subscribe", [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:channel] forKey:@"channelIds"]);
    YTLog([NSString stringWithFormat:@"subscribe %@ %@", name, ok ? @"ok" : @"fail"]);
    if (!ok) return;
    YTPostNote(@"YTVideoBookmarksDidChangeNotification");
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

void YTHookUnsubscribe(id self, SEL cmd, id sub) {
    NSString *name = [sub isKindOfClass:[NSDictionary class]] ? ([sub objectForKey:@"Label"] ?: [sub objectForKey:@"label"] ?: [sub objectForKey:@"username"]) : YTTailID(sub);
    NSString *channel = YTResolveChannel(name);
    BOOL ok = channel.length && YTAct(@"subscription/unsubscribe", [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:channel] forKey:@"channelIds"]);
    if (ok) {
        YTFinishPost(self, 4);
        YTPostNote(@"YTVideoBookmarksDidChangeNotification");
    }
    YTLog([NSString stringWithFormat:@"unsubscribe %@ %@", name, ok ? @"ok" : @"fail"]);
}

void YTHookCreateList(id self, SEL cmd, id name) {
    NSString *title = [name isKindOfClass:[NSString class]] ? name : [name description];
    BOOL ok = YTAct(@"playlist/create", [NSDictionary dictionaryWithObjectsAndKeys:title ?: @"", @"title", @"PRIVATE", @"privacyStatus", nil]);
    YTLog([NSString stringWithFormat:@"create playlist %@ %@", title, ok ? @"ok" : @"fail"]);
    if (!ok) return;
    YTPostNote(@"YTPlaylistsDidChangeNotification");
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    [item setObject:title forKey:@"Label"];
    [item setObject:title forKey:@"label"];
    [item setObject:[NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/playlists/%@", YTQueryEscape(title)] forKey:@"href"];
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(subscriptionsRequest:receivedSubscriptions:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, self, [NSArray arrayWithObject:item]);
}

void YTHookAddToList(id self, SEL cmd, id video, id playlistURL) {
    NSString *vid = YTVideoToken(video);
    NSString *playlist = YTTailID(playlistURL);
    NSDictionary *action = [NSDictionary dictionaryWithObjectsAndKeys:@"ACTION_ADD_VIDEO", @"action", vid ?: @"", @"addedVideoId", nil];
    BOOL ok = vid.length && playlist.length && YTAct(@"browse/edit_playlist", [NSDictionary dictionaryWithObjectsAndKeys:playlist, @"playlistId", [NSArray arrayWithObject:action], @"actions", nil]);
    YTLog([NSString stringWithFormat:@"add %@ to %@ %@", vid, playlist, ok ? @"ok" : @"fail"]);
    if (!ok || !video) return;
    YTPostNote(@"YTPlaylistsDidChangeNotification");
    id delegate = YTPSDelegate(self);
    SEL sel = @selector(accountFeedRequest:receivedVideos:);
    if ([delegate respondsToSelector:sel])
        ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, self, [NSArray arrayWithObject:video]);
}

void YTHookRequestSubs(id self, SEL cmd) {
    YTLog(@"requestSubscriptions");
    dispatch_async(dispatch_get_main_queue(), ^{ YTDeliverPS(self, NO); });
}

void YTHookRequestPlaylists(id self, SEL cmd) {
    YTLog(@"requestPlaylists");
    dispatch_async(dispatch_get_main_queue(), ^{ YTDeliverPS(self, YES); });
}

void YTHookPSFail(id self, SEL cmd, id error) {
    YTLog([NSString stringWithFormat:@"ps fail %@", error]);
}

BOOL YTCanTakeSearch(id source) {
    return [source respondsToSelector:@selector(searchRequest:receivedVideos:startIndex:videosRemaining:)];
}

void YTLoadAccountFeed(id source, NSString *urlString, NSString *label) {
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

void YTHookHistoryReload(id self, SEL cmd) {
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

void YTHookMyVideosReload(id self, SEL cmd) {
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
