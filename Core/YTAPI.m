#import "5Tube.h"

NSString *const YTKey = @"AIzaSyA8eiZmM1FaDVjRy-df2KTyQ_vz_yYM39w";
NSString *const YTTVKey = @"AIzaSyAd-YEOqZz9nXVzGtn3KWzYLbLaajhqIDA";
NSString *const YTWebKey = @"AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8";
NSDictionary *YTContext(void) {
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

NSDictionary *YTTVContext(void) {
    return [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObjectsAndKeys:
             @"TVHTML5", @"clientName",
             @"7.20250319.10.00", @"clientVersion",
             @"en", @"hl",
             @"US", @"gl",
             nil]
                                       forKey:@"client"];
}

NSDictionary *YTWebContext(void) {
    return [NSDictionary dictionaryWithObject:
            [NSDictionary dictionaryWithObjectsAndKeys:
             @"WEB", @"clientName",
             @"2.20250319.01.00", @"clientVersion",
             @"en", @"hl",
             @"US", @"gl",
             nil]
                                       forKey:@"client"];
}

id YTPostMode(NSString *method, NSDictionary *body, int mode) {
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
    // WEB next rejects the TV bearer with 400. Only comment writes need it.
    BOOL sendToken = mode == 1 || (mode == 2 && [method hasPrefix:@"comment/"]);
    NSString *token = sendToken ? YTAuthAccess() : nil;
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
        NSString *snippet = @"";
        if (data.length) snippet = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, MIN((NSUInteger)140, data.length))] encoding:NSUTF8StringEncoding] ?: @"";
        YTLog([NSString stringWithFormat:@"post %@ code %ld bytes %u err %@ %@", method, (long)code, (unsigned)[data length], error, snippet]);
    }
    if (!data.length) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
}

id YTPost(NSString *method, NSDictionary *body) {
    return YTPostMode(method, body, NO);
}

id YTPostAuth(NSString *method, NSDictionary *body) {
    return YTPostMode(method, body, YES);
}

id YTPostWeb(NSString *method, NSDictionary *body) {
    return YTPostMode(method, body, 2);
}

NSData *YTGET(NSString *urlString) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
    [request setValue:@"com.google.android.youtube/20.10.38" forHTTPHeaderField:@"User-Agent"];
    [NSURLProtocol setProperty:[NSNumber numberWithBool:YES] forKey:YTMark inRequest:request];
    return [NSURLConnection sendSynchronousRequest:request returningResponse:NULL error:NULL];
}

BOOL YTAct(NSString *method, NSDictionary *body) {
    id json = YTPostAuth(method, body);
    BOOL ok = [json isKindOfClass:[NSDictionary class]] && ![json objectForKey:@"error"];
    YTLog([NSString stringWithFormat:@"act %@ %@", method, ok ? @"ok" : @"fail"]);
    return ok;
}
