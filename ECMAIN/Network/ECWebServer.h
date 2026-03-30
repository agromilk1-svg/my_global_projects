#import <Foundation/Foundation.h>

@interface ECWebServer : NSObject

+ (instancetype)sharedServer;
- (void)startServerWithPort:(uint16_t)port;
- (void)stopServer;
- (BOOL)isPortActive;
- (void)restartOnPort:(uint16_t)port;

@end
