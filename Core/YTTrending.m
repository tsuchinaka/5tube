#import "5Tube.h"

void (*YTOrigHiddenControllers)(id, SEL);

void YTTrendingReload(id self, SEL cmd) {
    NSString *code = [[NSLocale currentLocale] objectForKey:NSLocaleCountryCode] ?: @"US";
    NSString *time = YTPrefString(@"trendingTime", @"today");
    NSString *url = [NSString stringWithFormat:@"http://gdata.youtube.com/feeds/api/standardfeeds/%@/most_viewed?time=%@&start-index=1&max-results=25", code, time];
    id request = [[NSClassFromString(@"YTSearchRequest") alloc] init];
    objc_setAssociatedObject(request, "YTSearchDelegate", self, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if ([request respondsToSelector:@selector(setDelegate:)])
        ((void (*)(id, SEL, id))objc_msgSend)(request, @selector(setDelegate:), self);
    if ([self respondsToSelector:@selector(_startedLoading)]) [self performSelector:@selector(_startedLoading)];
    if ([request respondsToSelector:@selector(loadRequest:)])
        ((void (*)(id, SEL, id))objc_msgSend)(request, @selector(loadRequest:), [NSURLRequest requestWithURL:[NSURL URLWithString:url]]);
    YTLog([NSString stringWithFormat:@"trending reload %@", time]);
}

NSString *YTTrendingName(id self, SEL cmd) { return @"Trending"; }

NSString *YTTrendingIcon(id self, SEL cmd) { return @"MostViewed"; }

Class YTTrendingDataClass(id self, SEL cmd) { return YTTrendingSourceClass(); }

Class YTTrendingSourceClass(void) {
    static Class cls;
    if (cls) return cls;
    Class base = NSClassFromString(@"YTVideoDataSource");
    if (!base) return Nil;
    cls = objc_allocateClassPair(base, "YTTrendingVideoDataSource", 0);
    if (!cls) return Nil;
    class_addMethod(cls, @selector(reloadData), (IMP)YTTrendingReload, "v@:");
    objc_registerClassPair(cls);
    return cls;
}

Class YTTrendingControllerClass(void) {
    static Class cls;
    if (cls) return cls;
    Class base = NSClassFromString(@"YTVideoCategoryController");
    if (!base) return Nil;
    cls = objc_allocateClassPair(base, "YTTrendingCategoryController", 0);
    if (!cls) return Nil;
    class_addMethod(object_getClass((id)cls), @selector(dataSourceClass), (IMP)YTTrendingDataClass, "#@:");
    class_addMethod(cls, @selector(name), (IMP)YTTrendingName, "@@:");
    class_addMethod(cls, @selector(navBarTitle), (IMP)YTTrendingName, "@@:");
    class_addMethod(cls, @selector(iconName), (IMP)YTTrendingIcon, "@@:");
    class_addMethod(cls, @selector(moreIconName), (IMP)YTTrendingIcon, "@@:");
    objc_registerClassPair(cls);
    return cls;
}

void YTTrendingClasses(void) {
    YTTrendingSourceClass();
    YTTrendingControllerClass();
}

void YTHookHiddenControllers(id self, SEL cmd) {
    if (YTOrigHiddenControllers) YTOrigHiddenControllers(self, cmd);
    if (!YTPrefBool(@"trendingSection", NO)) return;
    Ivar ivar = class_getInstanceVariable([self class], "_hiddenControllers");
    NSMutableArray *hidden = ivar ? object_getIvar(self, ivar) : nil;
    if (![hidden isKindOfClass:[NSMutableArray class]]) return;
    Class cls = NSClassFromString(@"YTTrendingCategoryController");
    if (!cls) return;
    for (id controller in hidden) if ([controller isKindOfClass:cls]) return;
    [hidden insertObject:[[cls alloc] init] atIndex:0];
}
