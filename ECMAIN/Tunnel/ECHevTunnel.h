
#import <Foundation/Foundation.h>
#import <NetworkExtension/NetworkExtension.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECHevTunnel : NSObject

@property(nonatomic, copy) void (^writePacketHandler)
    (NSData *packet, NSNumber *protocol);

- (instancetype)initWithConfig:(NSDictionary *)config;
- (void)start;
- (void)stop;
- (void)inputPacket:(NSData *)packet;

@end

NS_ASSUME_NONNULL_END
