
#import "ECHevTunnel.h"
#import "hev-main.h"
#import <sys/socket.h>

#define MAX_BUFFER_SIZE 4096

@interface ECHevTunnel () {
  int _tunnelFD; // The side we communicate with (End 0)
  int _hevFD;    // The side Hev uses (End 1)

  dispatch_queue_t _queue;
  dispatch_source_t _readSource;
  BOOL _running;

  NSString *_configYaml;
}
@end

@implementation ECHevTunnel

- (instancetype)initWithConfig:(NSDictionary *)config {
  self = [super init];
  if (self) {
    _queue =
        dispatch_queue_create("com.ecmain.hevtunnel", DISPATCH_QUEUE_SERIAL);

    // Generate YAML Config
    NSString *proxyIP = config[@"proxy_address"] ?: @"127.0.0.1";
    NSString *proxyPort = config[@"proxy_port"] ?: @"7890";

    _configYaml = [NSString stringWithFormat:@"tunnel:\n"
                                             @"  name: tun0\n"
                                             @"  mtu: 1500\n"
                                             @"  ipv4: 198.18.0.1\n"
                                             @"  ipv6: 'fd00::1'\n" // Fake IPv6
                                             @"  log-level: debug\n"
                                             @"socks5:\n"
                                             @"  port: %@\n"
                                             @"  address: %@\n"
                                             @"  udp: 'udp'\n",
                                             proxyPort, proxyIP];
  }
  return self;
}

- (void)start {
  if (_running)
    return;
  _running = YES;

  // Create Socket Pair (DGRAM to preserve packet boundaries)
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_DGRAM, 0, fds) < 0) {
    NSLog(@"[ECHevTunnel] Failed to create socketpair");
    return;
  }

  // Set buffer size to avoid drops (Optimized for Jetsam: 128KB)
  int bufSize = 128 * 1024; // 128KB (Was 4MB, causing Crash)
  setsockopt(fds[0], SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
  setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));
  setsockopt(fds[1], SOL_SOCKET, SO_RCVBUF, &bufSize, sizeof(bufSize));
  setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &bufSize, sizeof(bufSize));

  _tunnelFD = fds[0]; // We use this
  _hevFD = fds[1];    // Hev uses this

  // Start Read Source (Read from Hev -> Write to TUN)
  _readSource =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _tunnelFD, 0, _queue);
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_readSource, ^{
    [weakSelf handleRead];
  });
  dispatch_resume(_readSource);

  // Start Hev Task in Background
  const char *yamlStr = [_configYaml UTF8String];
  unsigned int yamlLen = (unsigned int)strlen(yamlStr);
  int hevFdCopy = _hevFD;

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    NSLog(@"[ECHevTunnel] Starting HevSocks5Tunnel Core...");
    // This blocks until quit
    int res = hev_socks5_tunnel_main_from_str((const unsigned char *)yamlStr,
                                              yamlLen, hevFdCopy);
    NSLog(@"[ECHevTunnel] HevSocks5Tunnel exited with code: %d", res);

    // Close FD if not closed
    close(hevFdCopy);
  });
}

- (void)stop {
  if (!_running)
    return;
  _running = NO;

  hev_socks5_tunnel_quit();

  if (_readSource) {
    dispatch_source_cancel(_readSource);
    _readSource = nil;
  }

  if (_tunnelFD > 0) {
    close(_tunnelFD);
    _tunnelFD = 0;
  }
}

- (void)inputPacket:(NSData *)packet {
  if (!_running || _tunnelFD <= 0)
    return;

  // Write packet to Hev via socketpair
  // Since it's SOCK_DGRAM, 1 write = 1 packet
  ssize_t written = write(_tunnelFD, packet.bytes, packet.length);
  if (written < 0) {
    NSLog(@"[ECHevTunnel] Write failed: %s", strerror(errno));
  } else {
    // Log sample
    static int writeCount = 0;
    writeCount++;
    if (writeCount < 10 || writeCount % 100 == 0) {
      NSLog(@"[ECHevTunnel] Wrote %zd bytes to HevCore", written);
    }
  }
}

- (void)handleRead {
  if (!_running || _tunnelFD <= 0)
    return;

  uint8_t buffer[MAX_BUFFER_SIZE];
  ssize_t len = read(_tunnelFD, buffer, MAX_BUFFER_SIZE);

  if (len < 0) {
    if (errno != EAGAIN && errno != EWOULDBLOCK) {
      NSLog(@"[ECHevTunnel] Read failed: %s", strerror(errno));
    }
  } else if (len > 0) {
    NSData *packet = [NSData dataWithBytes:buffer length:len];

    // Log sample read
    static int readCount = 0;
    readCount++;
    if (readCount < 10 || readCount % 100 == 0) {
      NSLog(@"[ECHevTunnel] Read %zd bytes from HevCore", len);
    }

    // Determine protocol family
    // IPv4: version (high 4 bits) of first byte is 4
    // IPv6: version is 6
    uint8_t version = (buffer[0] >> 4);
    NSNumber *proto = nil;
    if (version == 4) {
      proto = @(AF_INET);
    } else if (version == 6) {
      proto = @(AF_INET6);
    }

    if (proto && self.writePacketHandler) {
      self.writePacketHandler(packet, proto);
    }
  }
}

@end
