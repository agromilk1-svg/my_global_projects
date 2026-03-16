#import <Foundation/Foundation.h>

@interface ECWebServer : NSObject

+ (instancetype)sharedServer;
- (void)startServerWithPort:(uint16_t)port;
- (void)stopServer;

@end
