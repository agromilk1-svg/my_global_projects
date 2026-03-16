#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECConnectionTester : NSObject

/// TCP Ping an IP and port and return the response time in milliseconds.
/// If port is 0, it falls back to a simple reachability check (ICMP proxy via
/// external library or just fails if strict).
+ (void)pingHost:(NSString *)host
            port:(int)port
      completion:
          (void (^)(NSInteger timingMs, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
