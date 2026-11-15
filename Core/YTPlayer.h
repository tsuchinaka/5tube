#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSLock *YTCacheLock;
extern NSMutableDictionary *YTPlayCache;
extern NSMutableDictionary *YTDurationCache;
extern NSMutableSet *YTNo720;
extern int YTProxyPort;
NSString *YTLocalPlayURL(NSString *videoID, BOOL high);
int YTAvcLevel(NSString *mime);
void YTPickStreams(NSMutableDictionary *streams, NSArray *formats);
NSString *YTStreamURL(NSString *videoID, NSString *itag);
void YTTakeStream(NSMutableDictionary *streams, id format);
NSString *YTFetchUpstream(NSString *videoID);
void YTMuxNote(NSString *line);
NSString *YTPlayURL(NSString *videoID);
BOOL YTWriteAll(int fd, const void *bytes, size_t length);
NSString *YTHeader(NSDictionary *headers, NSString *name);
NSString *YTVideoIDFromPath(NSString *path);
void YTServeFile(int client, NSString *path, NSString *range, BOOL head);
void YTServe(int client);
void YTAcceptLoop(int server);
void YTStartProxy(void);
