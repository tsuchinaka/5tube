#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

void YTVideoPermissionsInstall(void);
extern void (*YTOrigAddHistory)(id, SEL, id);
void YTHookAddHistory(id self, SEL cmd, id video);
void YTHookAddHistoryNow(id self, SEL cmd, id video);
extern void (*YTOrigAddHistoryNow)(id, SEL, id);
extern void (*YTOrigHistoryReload)(id, SEL);
extern void (*YTOrigMyVideosReload)(id, SEL);
id YTPSDelegate(id request);
NSArray *YTPSItems(BOOL playlists);
void YTDeliverPS(id request, BOOL playlists);
NSString *YTVideoToken(id video);
NSString *YTResolveChannel(NSString *name);
NSString *YTTailID(id value);
void YTFinishPostError(id self, int type, id error);
void YTFinishPost(id self, int type);
void YTPostNote(NSString *name);
void YTHookPostComment(id self, SEL cmd, id text, id video);
NSDictionary *YTLikeBody(NSString *videoID);
void YTHookRate(id self, SEL cmd, int liked, id video);
void YTHookAddFav(id self, SEL cmd, id video);
void YTHookRemoveFav(id self, SEL cmd, id video);
void YTHookSubscribe(id self, SEL cmd, id user);
void YTHookUnsubscribe(id self, SEL cmd, id sub);
void YTHookCreateList(id self, SEL cmd, id name);
void YTHookAddToList(id self, SEL cmd, id video, id playlistURL);
void YTHookRequestSubs(id self, SEL cmd);
void YTHookRequestPlaylists(id self, SEL cmd);
void YTHookPSFail(id self, SEL cmd, id error);
BOOL YTCanTakeSearch(id source);
void YTLoadAccountFeed(id source, NSString *urlString, NSString *label);
void YTHookHistoryReload(id self, SEL cmd);
void YTHookMyVideosReload(id self, SEL cmd);
