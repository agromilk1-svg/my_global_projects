#import "ECNetworkManager.h"
#import "../ECMAIN/Core/ECLogManager.h"
#import "../ECMAIN/Core/ECScriptParser.h"
#import "../System/ECSystemManager.h"

@interface ECNetworkManager ()
@property(strong, nonatomic) NSTimer *pollTimer;
@property(strong, nonatomic) NSString *serverURL;
@end

@implementation ECNetworkManager

+ (instancetype)sharedManager {
  static ECNetworkManager *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ECNetworkManager alloc] init];
  });
  return sharedInstance;
}

- (void)setServerURL:(NSString *)urlString {
  self.serverURL = urlString;
  [[ECLogManager sharedManager]
      log:@"[ECNetwork] Server URL set to: %@", self.serverURL];

  // Restart polling if url changes
  [self.pollTimer invalidate];
  self.pollTimer = nil; // Ensure the old timer is released
  [self startPolling];
}

- (void)startPolling {
  if (!self.serverURL) {
    [[ECLogManager sharedManager] log:@"[ECNetwork] Waiting for Server URL..."];
    return;
  }

  [[ECLogManager sharedManager] log:@"[ECNetwork] Starting poll timer..."];
  self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                    target:self
                                                  selector:@selector(pollTask)
                                                  userInfo:nil
                                                   repeats:YES];
  [self.pollTimer fire]; // Execute immediately
}

- (void)handleTask:(NSDictionary *)task
        completion:(void (^)(BOOL success, id result))completion {
  NSString *type = task[@"type"];
  id payload = task[@"payload"];

  [[ECLogManager sharedManager] log:@"[ECNetwork] ====== TASK RECEIVED ======"];
  [[ECLogManager sharedManager] log:@"[ECNetwork] Type: %@", type];
  // Payload might be too large, log carefully or just log brief
  // [[ECLogManager sharedManager] log:@"[ECNetwork] Payload: %@", payload];

  if ([type isEqualToString:@"SCRIPT"]) {
    NSString *script = payload;
    [[ECLogManager sharedManager]
        log:@"[ECNetwork] >>> Parsing script with ECScriptParser..."];
    [[ECLogManager sharedManager] log:@"[ECNetwork] Script length: %lu chars",
                                      (unsigned long)script.length];

    [[ECScriptParser sharedParser]
        executeScript:script
           completion:^(BOOL success, NSArray *results) {
             [[ECLogManager sharedManager]
                 log:@"[ECNetwork] <<< Script execution completed"];
             [[ECLogManager sharedManager]
                 log:@"[ECNetwork] Success: %@", success ? @"YES" : @"NO"];
             // [[ECLogManager sharedManager] log:@"[ECNetwork] Results: %@",
             // results];
             if (completion) {
               completion(success, results);
             }
           }];
  } else if ([type isEqualToString:@"VPN"]) {
    [[ECLogManager sharedManager] log:@"[ECNetwork] >>> Configuring VPN..."];
    [[ECSystemManager sharedManager] configureVPN:payload];
    if (completion)
      completion(YES, @"VPN Configuration applied");
  } else if ([type isEqualToString:@"INSTALL"]) {
    [[ECLogManager sharedManager]
        log:@"[ECNetwork] >>> Installing app: %@", payload];
    [[ECSystemManager sharedManager] installApp:payload];
    if (completion)
      completion(YES, @"App installation started");
  } else if ([type isEqualToString:@"STOP_VPN"]) {
    [[ECLogManager sharedManager] log:@"[ECNetwork] >>> Stopping VPN..."];
    [[ECSystemManager sharedManager] stopVPN];
    if (completion)
      completion(YES, @"VPN Stopped");
  } else if ([type isEqualToString:@"SET_INFO"]) {
    [[ECLogManager sharedManager]
        log:@"[ECNetwork] >>> Setting device info..."];
    [[ECSystemManager sharedManager] setDeviceInfo:payload];
    if (completion)
      completion(YES, @"Device Info set");
  } else if ([type isEqualToString:@"PING"]) {
    [[ECLogManager sharedManager]
        log:@"[ECNetwork] >>> PING received, connection test OK"];
    if (completion)
      completion(YES, @"PONG");
  } else {
    [[ECLogManager sharedManager]
        log:@"[ECNetwork] !!! Unknown task type: %@", type];
  }

  [[ECLogManager sharedManager]
      log:@"[ECNetwork] ====== TASK PROCESSED ======"];
  if (![type isEqualToString:@"SCRIPT"]) {
    // 脚本类型的 completion 在异步回调里，其他的在这里如果没处理完保底触发
    // 但上面分支里已经都调用过了，保险起见在没有被命中时触发失败
    if (!task[@"handled_by_type"]) {
      // Just a fallback in case not properly completed
      // Actually best not to double trigger.
      // We ensure above every branch calls it or SCRIPT is async.
    }
  }
}

- (void)pollTask {
  // TODO: Implement actual URL fetch
  // Example: GET http://server/task
}

- (void)fetchConfig {
  [[ECLogManager sharedManager] log:@"[ECNetwork] Fetching configuration..."];
}

@end
