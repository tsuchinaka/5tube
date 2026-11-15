#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString *const YTMark;
extern NSString *const YTPrefsID;
extern NSString *const YTLegacyPrefsID;
extern NSLock *YTLogLock;
void YTLog(NSString *line);
void YTSyncPrefs(void);
void YTMigratePrefs(void);
BOOL YTPrefBool(NSString *key, BOOL fallback);
NSString *YTPrefString(NSString *key, NSString *fallback);
BOOL YTWant720(void);
id YTGet(id obj, NSString *key);
void YTSet(NSMutableDictionary *dict, NSString *key, id value);
id YTAt(NSArray *array, NSUInteger index);
NSString *YTEscape(NSString *text);
NSString *YTText(id node);
NSInteger YTSeconds(NSString *text);
NSString *YTDigits(NSString *text);
NSDictionary *YTQuery(NSURL *url);
NSString *YTQueryEscape(NSString *text);
BOOL YTIsVideoID(NSString *text);
NSArray *YTIDsInBody(NSString *body);
NSString *YTBodyString(NSURLRequest *request);
NSString *YTFirstText(id node, int depth);
NSString *YTAuthorFrom(NSString *text);
id YTGlobalString(const char *name);
void YTWriteCrash(NSString *text);
void YTExceptionHandler(NSException *exception);
void YTSignalHandler(int sig, siginfo_t *info, void *ctx);
void YTInstallCrashHandler(void);
void YTHookMethod(Class cls, NSString *selName, IMP hook, IMP *orig);
void YTStoreIvar(id obj, NSString *name, id value);
