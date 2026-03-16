//
//  ECTun2Proxy.m
//  ECMAIN Tunnel
//
//  tun2proxy wrapper for iOS Network Extension
//  Uses socketpair to bridge NEPacketTunnelFlow with tun2proxy
//

#import "ECTun2Proxy.h"
#import "tun2proxy.h"
#import <dispatch/dispatch.h>
#import <sys/socket.h>
#import <unistd.h>

@interface ECTun2Proxy ()
@property(nonatomic, strong) NSString *proxyURL;
@property(nonatomic, assign) BOOL isRunning;
@property(nonatomic, strong)
    dispatch_queue_t runQueue; // For tun2proxy main loop
@property(nonatomic, strong)
    dispatch_queue_t readQueue;             // For reading responses
@property(nonatomic, assign) int tunSideFD; // FD given to tun2proxy
@property(nonatomic, assign) int appSideFD; // FD for our app to write/read
@property(nonatomic, copy) ECTun2ProxyWriteBlock writeHandler;
@end

@implementation ECTun2Proxy

// Log callback for tun2proxy
static void tun2proxy_log_cb(enum Tun2proxyVerbosity level, const char *message,
                             void *ctx) {
  NSString *levelStr;
  switch (level) {
  case Tun2proxyVerbosity_Error:
    levelStr = @"ERROR";
    break;
  case Tun2proxyVerbosity_Warn:
    levelStr = @"WARN";
    break;
  case Tun2proxyVerbosity_Info:
    levelStr = @"INFO";
    break;
  case Tun2proxyVerbosity_Debug:
    levelStr = @"DEBUG";
    break;
  case Tun2proxyVerbosity_Trace:
    levelStr = @"TRACE";
    break;
  default:
    levelStr = @"???";
    break;
  }
  NSLog(@"[tun2proxy][%@] %s", levelStr, message);
}

- (instancetype)initWithProxyURL:(NSString *)proxyURL {
  self = [super init];
  if (self) {
    _proxyURL = proxyURL;
    _isRunning = NO;
    _tunSideFD = -1;
    _appSideFD = -1;
    _runQueue = dispatch_queue_create("com.ecmain.tun2proxy.run",
                                      DISPATCH_QUEUE_SERIAL);
    _readQueue = dispatch_queue_create("com.ecmain.tun2proxy.read",
                                       DISPATCH_QUEUE_SERIAL);

    // Set up logging
    tun2proxy_set_log_callback(tun2proxy_log_cb, NULL);
  }
  return self;
}

- (BOOL)startWithTunFD:(int)tunFD mtu:(uint16_t)mtu {
  if (self.isRunning) {
    NSLog(@"[ECTun2Proxy] Already running");
    return YES;
  }

  if (tunFD <= 0) {
    NSLog(@"[ECTun2Proxy] Invalid TUN FD: %d", tunFD);
    return NO;
  }

  NSLog(@"[ECTun2Proxy] Starting with native FD=%d MTU=%d Proxy=%@", tunFD, mtu,
        self.proxyURL);

  // Start tun2proxy in background thread (it blocks)
  dispatch_async(self.runQueue, ^{
    self.isRunning = YES;

    int result = tun2proxy_with_fd_run(
        [self.proxyURL UTF8String], tunFD,
        true,  // close_fd_on_drop
        false, // packet_information: iOS TUN doesn't have PI header
        mtu,
        Tun2proxyDns_OverTcp, // Force DNS over TCP (UDP doesn't work with
                              // socketpair)
        Tun2proxyVerbosity_Info);

    NSLog(@"[ECTun2Proxy] Native mode exited with result: %d", result);
    self.isRunning = NO;
  });

  usleep(100000); // 100ms for startup
  return YES;
}

- (BOOL)startBridgeModeWithMTU:(uint16_t)mtu
                  writeHandler:(ECTun2ProxyWriteBlock)writeBlock {
  if (self.isRunning) {
    NSLog(@"[ECTun2Proxy] Already running");
    return YES;
  }

  self.writeHandler = writeBlock;

  // Create socketpair for bidirectional communication
  int fds[2];
  if (socketpair(AF_UNIX, SOCK_DGRAM, 0, fds) < 0) {
    NSLog(@"[ECTun2Proxy] Failed to create socketpair: %s", strerror(errno));
    return NO;
  }

  self.appSideFD = fds[0]; // Our side - we write packets here, read responses
  self.tunSideFD =
      fds[1]; // tun2proxy's side - it reads packets, writes responses

  // Set socket buffer sizes for packet handling
  int bufsize = 65536;
  setsockopt(self.appSideFD, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof(bufsize));
  setsockopt(self.appSideFD, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));
  setsockopt(self.tunSideFD, SOL_SOCKET, SO_SNDBUF, &bufsize, sizeof(bufsize));
  setsockopt(self.tunSideFD, SOL_SOCKET, SO_RCVBUF, &bufsize, sizeof(bufsize));

  NSLog(@"[ECTun2Proxy] Created socketpair: app=%d, tun2proxy=%d",
        self.appSideFD, self.tunSideFD);
  NSLog(@"[ECTun2Proxy] Starting bridge mode with MTU=%d Proxy=%@", mtu,
        self.proxyURL);

  // Start tun2proxy in background thread
  dispatch_async(self.runQueue, ^{
    self.isRunning = YES;

    int result = tun2proxy_with_fd_run(
        [self.proxyURL UTF8String], self.tunSideFD,
        true,  // close_fd_on_drop - tun2proxy will close this FD
        false, // packet_information: no PI header for raw IP packets
        mtu,
        Tun2proxyDns_OverTcp, // Force DNS over TCP (UDP doesn't work with
                              // socketpair)
        Tun2proxyVerbosity_Off);

    NSLog(@"[ECTun2Proxy] Bridge mode exited with result: %d", result);
    self.tunSideFD = -1; // Marked as closed by tun2proxy
    self.isRunning = NO;
  });

  // Start reading responses from tun2proxy
  [self startReadingResponses];

  usleep(200000); // 200ms for startup
  NSLog(@"[ECTun2Proxy] Bridge mode started successfully");
  return YES;
}

- (void)startReadingResponses {
  dispatch_async(self.readQueue, ^{
    uint8_t buffer[65536];

    while (self.isRunning && self.appSideFD >= 0) {
      ssize_t len = recv(self.appSideFD, buffer, sizeof(buffer), 0);

      if (len < 0) {
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
          usleep(1000); // 1ms
          continue;
        }
        NSLog(@"[ECTun2Proxy] Read error: %s", strerror(errno));
        break;
      }

      if (len == 0) {
        NSLog(@"[ECTun2Proxy] Socket closed by tun2proxy");
        break;
      }

      // Parse IP version from first byte to determine family
      int family = 2; // AF_INET (IPv4) default
      if (len > 0) {
        uint8_t version = (buffer[0] >> 4);
        if (version == 6) {
          family = 30; // AF_INET6
        }
      }

      NSData *packet = [NSData dataWithBytes:buffer length:len];

      // Call write handler on main queue
      if (self.writeHandler) {
        dispatch_async(dispatch_get_main_queue(), ^{
          self.writeHandler(packet, family);
        });
      }
    }

    NSLog(@"[ECTun2Proxy] Read loop ended");
  });
}

- (void)inputPacket:(NSData *)packet {
  if (!self.isRunning || self.appSideFD < 0) {
    return;
  }

  ssize_t sent = send(self.appSideFD, packet.bytes, packet.length, 0);
  if (sent < 0) {
    if (errno != EAGAIN && errno != EWOULDBLOCK) {
      NSLog(@"[ECTun2Proxy] Failed to send packet: %s", strerror(errno));
    }
  }
}

- (void)stop {
  if (!self.isRunning) {
    NSLog(@"[ECTun2Proxy] Not running");
    return;
  }

  NSLog(@"[ECTun2Proxy] Stopping...");

  // Signal tun2proxy to stop
  int result = tun2proxy_stop();
  NSLog(@"[ECTun2Proxy] Stop result: %d", result);

  // Close our side of the socket (tun2proxy closes its side)
  if (self.appSideFD >= 0) {
    close(self.appSideFD);
    self.appSideFD = -1;
  }

  self.isRunning = NO;
  self.writeHandler = nil;
}

- (void)dealloc {
  [self stop];
}

@end
