//
//  ECTun2Proxy.h
//  ECMAIN Tunnel
//
//  tun2proxy wrapper for iOS Network Extension
//  Uses socketpair to bridge NEPacketTunnelFlow with tun2proxy
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Write callback for sending packets back to NEPacketTunnelFlow
typedef void (^ECTun2ProxyWriteBlock)(NSData *packet, int family);

/// ECTun2Proxy wraps the Rust tun2proxy library for use with iOS
/// NEPacketTunnelProvider It creates a socketpair bridge when no native TUN FD
/// is available.
@interface ECTun2Proxy : NSObject

/// Initialize with SOCKS5 proxy URL (e.g., "socks5://127.0.0.1:7890")
- (instancetype)initWithProxyURL:(NSString *)proxyURL;

/// Start tun2proxy with a TUN file descriptor (Native mode)
/// @param tunFD The TUN file descriptor from iOS
/// @param mtu The MTU for the TUN interface
/// @return YES if started successfully
- (BOOL)startWithTunFD:(int)tunFD mtu:(uint16_t)mtu;

/// Start tun2proxy in bridge mode using socketpair
/// This creates an internal pipe that bridges NEPacketTunnelFlow to tun2proxy
/// @param mtu The MTU for packet processing
/// @param writeBlock Callback to write packets back to NEPacketTunnelFlow
/// @return YES if started successfully
- (BOOL)startBridgeModeWithMTU:(uint16_t)mtu
                  writeHandler:(ECTun2ProxyWriteBlock)writeBlock;

/// Input packet from NEPacketTunnelFlow (for bridge mode)
/// @param packet Raw IP packet data
- (void)inputPacket:(NSData *)packet;

/// Stop tun2proxy
- (void)stop;

/// Check if tun2proxy is running
@property(nonatomic, readonly) BOOL isRunning;

@end

NS_ASSUME_NONNULL_END
