#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern void (*YTOrigHiddenControllers)(id, SEL);
void YTTrendingReload(id self, SEL cmd);
NSString *YTTrendingName(id self, SEL cmd);
NSString *YTTrendingIcon(id self, SEL cmd);
Class YTTrendingDataClass(id self, SEL cmd);
Class YTTrendingSourceClass(void);
Class YTTrendingControllerClass(void);
void YTTrendingClasses(void);
void YTHookHiddenControllers(id self, SEL cmd);
