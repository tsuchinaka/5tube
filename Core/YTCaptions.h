#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

void YTCaptionStart(void);
NSArray *YTCaptionTracks(NSString *videoID);
void YTCaptionForget(NSString *videoID);
NSString *YTCaptionURL(NSString *videoID, NSString *lang, NSString *kind);
NSString *YTSRTFromTrack(NSString *text);
void YTCaptionPrepare(NSString *videoID);
BOOL YTCaptionPrepared(NSString *videoID);
NSData *YTCaptionFeed(NSString *videoID);
