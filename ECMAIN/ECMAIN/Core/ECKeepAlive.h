#import <Foundation/Foundation.h>

@interface ECKeepAlive : NSObject

+ (instancetype)sharedInstance;
- (void)start;

@end
