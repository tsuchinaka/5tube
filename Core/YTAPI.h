#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern NSString *const YTKey;
extern NSString *const YTTVKey;
extern NSString *const YTWebKey;
NSDictionary *YTContext(void);
NSDictionary *YTTVContext(void);
NSDictionary *YTWebContext(void);
id YTPostMode(NSString *method, NSDictionary *body, int mode);
id YTPost(NSString *method, NSDictionary *body);
id YTPostAuth(NSString *method, NSDictionary *body);
id YTPostWeb(NSString *method, NSDictionary *body);
NSData *YTGET(NSString *urlString);
BOOL YTAct(NSString *method, NSDictionary *body);
