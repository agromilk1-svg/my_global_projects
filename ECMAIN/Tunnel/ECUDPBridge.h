
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ECUDPBridgeWriteHandler)(NSData *packet);

@interface ECUDPBridge : NSObject

@property(nonatomic, copy) ECUDPBridgeWriteHandler writeHandler;

- (instancetype)initWithProxyHost:(NSString *)host port:(uint16_t)port;
- (void)start;
- (void)stop;
- (void)inputPacket:(NSData *)packet;

@end

NS_ASSUME_NONNULL_END
