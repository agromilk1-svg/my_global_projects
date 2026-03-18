//
//  ECScriptParser.m
//  ECMAIN
//
//  JavaScript script engine for ECMAIN (JavaScriptCore)
//

#import "ECScriptParser.h"
#import "../../System/ECSystemManager.h"
#import "ECBackgroundManager.h"
#import "ECLogManager.h"
#import "ECProxyURIParser.h"
#import "ECVPNConfigManager.h"
#import <NetworkExtension/NetworkExtension.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>

// RootHelper 工具函数声明
extern int spawnRoot(NSString *path, NSArray *args, NSString **stdOut,
                     NSString **stdErr);
extern NSString *rootHelperPath(void);
extern NSArray *trollStoreInstalledAppBundlePaths(void);

// WDA port (runs on same device)
static const int kWDAPort = 10088;

@implementation ECScriptParser {
  NSMutableArray *_executionLogs;
}

+ (instancetype)sharedParser {
  static ECScriptParser *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECScriptParser alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _executionLogs = [NSMutableArray array];
  }
  return self;
}

#pragma mark - Public Methods

- (void)executeScript:(NSString *)script
           completion:(void (^)(BOOL success, NSArray *results))completion {
  NSLog(@"[脚本动作] ====== 开始执行脚本 ======");
  NSLog(@"[脚本动作] 脚本长度: %lu 字符", (unsigned long)script.length);
  NSLog(@"[脚本动作] 脚本内容:\n%@", script);

  // 智能拦截：检测是否为代理 URI 而非 JS 脚本
  NSString *trimmed = [script
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];
  if ([trimmed hasPrefix:@"ecnode://"] || [trimmed hasPrefix:@"ss://"] ||
      [trimmed hasPrefix:@"ssr://"] || [trimmed hasPrefix:@"vmess://"] ||
      [trimmed hasPrefix:@"vless://"] || [trimmed hasPrefix:@"trojan://"] ||
      [trimmed hasPrefix:@"socks://"] || [trimmed hasPrefix:@"hysteria2://"]) {
    NSLog(@"[ECScriptEngine] 检测到代理 URI 格式，转入节点导入流程");
    [self log:@"检测到代理 URI 链接，自动转为节点导入..."];

    NSArray *nodes = [ECProxyURIParser parseSubscriptionContent:trimmed
                                                      withGroup:@"WebImport"];
    if (nodes.count > 0) {
      NSDictionary *firstNode = nodes.firstObject;
      for (NSDictionary *n in nodes) {
        NSMutableDictionary *mut = [n mutableCopy];
        if (!mut[@"id"])
          mut[@"id"] = [[NSUUID UUID] UUIDString];
        [[ECVPNConfigManager sharedManager] addNode:mut];
      }
      [self log:[NSString stringWithFormat:@"✅ 成功导入 %lu 个节点",
                                           (unsigned long)nodes.count]];

      // 自动连接第一个节点
      NSMutableDictionary *active = [firstNode mutableCopy];
      if (!active[@"id"])
        active[@"id"] = [[NSUUID UUID] UUIDString];
      [[ECVPNConfigManager sharedManager] setActiveNodeID:active[@"id"]];
      [[ECBackgroundManager sharedManager] connectVPNWithConfig:active];
      [self
          log:[NSString stringWithFormat:@"🔗 已自动连接节点: %@",
                                         active[@"name"] ?: active[@"server"]]];
    } else {
      [self log:@"⚠️ URI 解析失败，未能提取有效节点"];
    }

    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(nodes.count > 0, [self->_executionLogs copy]);
      });
    }
    return;
  }

  // Create execution context
  JSContext *context = [[JSContext alloc] init];

  // Exception Handler
  context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
    NSLog(@"[脚本动作] ❌ JS 异常: %@", exception);
    [self log:[NSString stringWithFormat:@"[脚本动作] JS Error: %@", exception]];
  };

  // Inject 'wda' object (self)
  context[@"wda"] = self;

  // Inject 'console.log'
  context[@"console"] = @{};
  context[@"console"][@"log"] = ^(NSString *message) {
    NSLog(@"[JS Log] %@", message);
    [self log:message];
  };

  // Clear logs
  [_executionLogs removeAllObjects];

  // Execute Script
  // We run this async to avoid blocking the caller, but the JS execution itself
  // will block this background thread for synchronous operations (sleep, tap,
  // etc.)
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   [context evaluateScript:script];

                   // Check for exceptions
                   if (context.exception) {
                     NSLog(@"[ECScriptEngine] Script failed with exception: %@",
                           context.exception);
                     if (completion) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                         completion(NO, [self->_executionLogs copy]);
                       });
                     }
                   } else {
                     NSLog(@"[ECScriptEngine] Script finished successfully");
                     if (completion) {
                       dispatch_async(dispatch_get_main_queue(), ^{
                         completion(YES, [self->_executionLogs copy]);
                       });
                     }
                   }
                 });
}

// 同步阻塞版脚本执行引擎：挂起当前线程，等待 JS
// 执行结束，并一次性打包所有产生日志与最后 return 值返回
- (NSDictionary *)executeScriptSync:(NSString *)script {
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

  JSContext *context = [[JSContext alloc] init];
  context.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
    [self log:[NSString stringWithFormat:@"[脚本动作] JS Error: %@", exception]];
  };
  context[@"wda"] = self;
  context[@"console"] = @{};
  context[@"console"][@"log"] = ^(NSString *message) {
    NSLog(@"[JS Log] %@", message);
    [self log:message];
  };

  // 清理本次容器的前置日志
  @synchronized(self) {
    [_executionLogs removeAllObjects];
  }

  __block BOOL isSuccess = YES;
  __block id finalRetVal = nil;

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   JSValue *ret = [context evaluateScript:script];

                   if (context.exception) {
                     NSLog(@"[ECScriptEngine] Script failed with exception: %@",
                           context.exception);
                     isSuccess = NO;
                   } else {
                     NSLog(@"[ECScriptEngine] Script finished successfully");
                     if (ret && ![ret isUndefined] && ![ret isNull]) {
                       // 尝试转成 NSObject
                       finalRetVal = [ret toObject];
                     }
                   }
                   dispatch_semaphore_signal(semaphore);
                 });

  // 超时阻断器（设定为最大 7200 秒/2小时，支持全自动无限挂机脚本运行，不再以 60
  // 秒作为惩罚熔断）
  dispatch_time_t timeoutTime =
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(7200.0 * NSEC_PER_SEC));
  long waitResult = dispatch_semaphore_wait(semaphore, timeoutTime);

  NSMutableDictionary *resultDict = [NSMutableDictionary dictionary];
  @synchronized(self) {
    resultDict[@"logs"] = [_executionLogs copy];
    [_executionLogs removeAllObjects];
  }

  if (waitResult != 0) {
    // Timeout
    isSuccess = NO;
    [self log:@"🚨 脚本执行超时 (60 秒上限) 被强制挂起熔断！"];
    resultDict[@"timeout"] = @(YES);
    // 把最后一句超时红字追加入打包内
    NSMutableArray *finalLogs = [resultDict[@"logs"] mutableCopy];
    [finalLogs addObject:@{
      @"type" : @"log",
      @"message" : @"🚨 脚本执行超时 (60 秒上限) 被强制挂起熔断！",
      @"timestamp" : @([[NSDate date] timeIntervalSince1970])
    }];
    resultDict[@"logs"] = finalLogs;
  }

  resultDict[@"status"] = isSuccess ? @"ok" : @"error";
  if (finalRetVal) {
    resultDict[@"return_value"] = finalRetVal;
  }

  return resultDict;
}

#pragma mark - Global Log// 内存中缓存提取记录
static NSMutableArray<NSDictionary *> *gPendingLogs = nil;
// WDA 接口活跃 Session 缓存（供需要 SessionId 前置的端点使用）
static NSString *gActiveWDASessionId = nil;

+ (void)addGlobalLog:(NSDictionary *)logDict {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    gPendingLogs = [NSMutableArray array];
  });
  @synchronized(gPendingLogs) {
    if (gPendingLogs.count > 500) {
      [gPendingLogs removeObjectAtIndex:0];
    }
    [gPendingLogs addObject:logDict];
  }
}

+ (NSArray *)popGlobalLogs {
  @synchronized(gPendingLogs) {
    if (!gPendingLogs || gPendingLogs.count == 0) {
      return @[];
    }
    NSArray *logs = [gPendingLogs copy];
    [gPendingLogs removeAllObjects];
    return logs;
  }
}

#pragma mark - WDAJSExport Implementation

- (void)log:(NSString *)message {
  if (message) {
    [_executionLogs addObject:@{
      @"type" : @"log",
      @"message" : message,
      @"timestamp" : @([[NSDate date] timeIntervalSince1970])
    }];
    [[ECLogManager sharedManager] log:@"[脚本动作] %@", message];

    // 将日志存入全局缓存池，等待前端主动定时抓取（备用通道）
    [ECScriptParser addGlobalLog:@{
      @"log" : message,
      @"timestamp" : @([[NSDate date] timeIntervalSince1970])
    }];
  }
}

// --- Basic Actions ---

- (NSNumber *)safeNumber:(NSNumber *)number {
  if (!number || [number isKindOfClass:[NSNull class]]) {
    return @0;
  }
  if (isnan([number doubleValue]) || isinf([number doubleValue])) {
    return @0;
  }
  return number;
}

- (BOOL)tap:(NSNumber *)x y:(NSNumber *)y {
  NSNumber *safeX = [self safeNumber:x];
  NSNumber *safeY = [self safeNumber:y];

  NSLog(@"[ECScriptEngine] Use WDA to Touch at %@, %@", safeX, safeY);
  return [self performWDAAction:@"tap"
                       endpoint:@"/wda/tapByCoord"
                           body:@{@"x" : safeX, @"y" : safeY}];
}

- (BOOL)doubleTap:(NSNumber *)x y:(NSNumber *)y {
  return [self performWDAAction:@"doubleTap"
                       endpoint:@"/wda/doubleTap"
                           body:@{
                             @"x" : [self safeNumber:x],
                             @"y" : [self safeNumber:y]
                           }];
}

- (BOOL)longPress:(NSNumber *)x y:(NSNumber *)y duration:(NSNumber *)duration {
  NSNumber *safeDuration = [self safeNumber:duration];
  if ([safeDuration doubleValue] <= 0)
    safeDuration = @1.0;

  return [self performWDAAction:@"longPress"
                       endpoint:@"/wda/longPress"
                           body:@{
                             @"x" : [self safeNumber:x],
                             @"y" : [self safeNumber:y],
                             @"duration" : safeDuration
                           }];
}

- (BOOL)swipe:(NSNumber *)fromX
        fromY:(NSNumber *)fromY
          toX:(NSNumber *)toX
          toY:(NSNumber *)toY
     duration:(NSNumber *)duration {
  double safeDuration = [duration doubleValue];
  if (safeDuration > 10.0) {
    safeDuration = safeDuration / 1000.0;
  }
  if (safeDuration < 0) {
    safeDuration = 0;
  }

  return [self performWDAAction:@"swipe"
                       endpoint:@"/wda/swipeByCoord"
                           body:@{
                             @"fromX" : [self safeNumber:fromX],
                             @"fromY" : [self safeNumber:fromY],
                             @"toX" : [self safeNumber:toX],
                             @"toY" : [self safeNumber:toY],
                             @"duration" : @(safeDuration)
                           }];
}

- (BOOL)sleep:(NSNumber *)seconds {
  double sec = [seconds doubleValue];
  NSLog(@"[ECScriptEngine] Sleeping for %.2f seconds", sec);
  [self log:[NSString stringWithFormat:@"Sleep %.2fs", sec]];
  [NSThread sleepForTimeInterval:sec];
  return YES;
}

- (BOOL)input:(NSString *)text {
  return [self performWDAAction:@"input"
                       endpoint:@"/wda/inputText"
                           body:@{@"text" : text ?: @""}];
}

- (BOOL)home {
  return [self performWDAAction:@"home" endpoint:@"/wda/homescreen" body:@{}];
}

- (NSDictionary *)screenshot {
  // 使用有返回值版本获取 WDA 截图的 base64 数据
  NSDictionary *result = [self performWDAActionWithResult:@"screenshot"
                                                 endpoint:@"/screenshot"
                                                     body:nil];
  // WDA 返回格式: {"value": "<base64 PNG>", "sessionId": "..."}
  // performWDAActionWithResult 在 value 非 dict 时返回整个 json
  NSString *b64 = nil;
  if (result[@"value"] && [result[@"value"] isKindOfClass:[NSString class]]) {
    b64 = result[@"value"];
  }
  if (b64) {
    // 用专用类型写入日志，前端可通过 type=screenshot_result 识别
    [_executionLogs addObject:@{
      @"type" : @"screenshot_result",
      @"base64" : b64,
      @"timestamp" : @([[NSDate date] timeIntervalSince1970])
    }];
    NSLog(@"[ECScriptEngine] screenshot captured, base64 length: %lu",
          (unsigned long)b64.length);
    return @{@"base64" : b64};
  }
  [self log:@"screenshot 失败: 未获取到图像数据"];
  return @{@"error" : @"no image data"};
}

// --- App Management ---

- (BOOL)launch:(NSString *)bundleId {
  return [self performWDAAction:@"launch"
                       endpoint:@"/wda/apps/launchUnattached"
                           body:@{@"bundleId" : bundleId ?: @""}];
}

- (BOOL)terminate:(NSString *)bundleId {
  NSLog(@"[ECScriptEngine] Executing: terminate %@ (直接终止模式)", bundleId);
  [self log:[NSString stringWithFormat:@"Terminate: %@ (XCUIApplication API)",
                                       bundleId]];

  // 直接调用 WDA 的 terminateApp 端点，通过 XCUIApplication.terminate() 杀进程
  // 完全不需要打开 App Switcher
  NSDictionary *result =
      [self performWDAActionWithResult:@"terminateApp"
                              endpoint:@"/wda/terminateApp"
                                  body:@{@"bundleId" : bundleId}];

  BOOL terminated = [result[@"terminated"] boolValue];
  if (terminated) {
    [self log:[NSString stringWithFormat:@"✅ 已终止: %@", bundleId]];
    return YES;
  } else {
    NSString *reason = result[@"reason"] ?: @"Unknown";
    [self log:[NSString stringWithFormat:@"⚠️ 终止失败或应用未运行: %@ (%@)",
                                         bundleId, reason]];
    return NO;
  }
}

- (BOOL)wipeApp:(NSString *)bundleId {
  NSLog(@"[ECScriptEngine] Executing: wipeApp %@", bundleId);
  [self log:[NSString stringWithFormat:@"Wipe Data & Keychain: %@", bundleId]];

  NSString *stdOut;
  NSString *stdErr;
  int ret = spawnRoot(rootHelperPath(), @[ @"wipe-app", bundleId ?: @"" ],
                      &stdOut, &stdErr);

  if (ret == 0) {
    [self log:[NSString
                  stringWithFormat:@"✅ 已深度抹除: %@ 的沙盒与Keychain残留",
                                   [self appDisplayNameForBundleId:bundleId]]];
    return YES;
  } else {
    [self log:[NSString stringWithFormat:@"⚠️ 抹除执行发生异常: %@ (Code: %d)",
                                         bundleId, ret]];
    if (stdErr.length > 0) {
      NSLog(@"[RootHelper WipeApp Error] %@", stdErr);
    }
    return NO;
  }
}

// 从 bundleId 提取应用显示名称
- (NSString *)appDisplayNameForBundleId:(NSString *)bundleId {
  // 尝试用 LSApplicationProxy 获取真实应用名
  Class LSProxy = NSClassFromString(@"LSApplicationProxy");
  if (LSProxy) {
    id proxy =
        [LSProxy performSelector:@selector(applicationProxyForIdentifier:)
                      withObject:bundleId];
    if (proxy) {
      NSString *name = [proxy performSelector:@selector(localizedName)];
      if (name && name.length > 0) {
        return name;
      }
    }
  }
  // 兜底：取 bundleId 最后一段作为名称
  NSArray *components = [bundleId componentsSeparatedByString:@"."];
  return components.lastObject ?: bundleId;
}

- (BOOL)terminateAll {
  NSLog(@"[ECScriptEngine] Executing: terminateAll (RootHelper kill-all-apps "
        @"模式)");
  [self log:@"执行: 清除所有无关第三方后台应用 (RootHelper 强制结束)"];

  // 白名单：这些应用不会被结束
  NSArray *protectedNames = @[
    @"ECMAIN", @"ECWDA", @"WebDriverAgentRunner-Runner", @"trollstorehelper",
    @"Ecrunner-Runner"
  ];

  // 收集需要被杀掉的 App 名称
  NSMutableArray *appsToKill = [NSMutableArray array];

  // 遍历所有 TrollStore 安装的（和系统的）三方应用目录找出 Executable Name
  // 这里 ECMAIN 有提供 trollStoreInstalledAppBundlePaths
  NSArray *appBundlePaths = trollStoreInstalledAppBundlePaths();
  for (NSString *bundlePath in appBundlePaths) {
    NSString *infoPlistPath =
        [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist =
        [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *executableName = infoPlist[@"CFBundleExecutable"];

    if (executableName && ![protectedNames containsObject:executableName]) {
      // 为了防止查重
      if (![appsToKill containsObject:executableName]) {
        [appsToKill addObject:executableName];
      }
    }
  }

  // ECMAIN 有可能没有在 trollStoreInstalledAppBundlePaths 覆盖到其他通过
  // AppStore 安装的三方应用
  // 所以我们可以简单地通过已知的常用清理名单或是系统当前运行的进程名单来杀，或者退一步，通过
  // enumerateProcessesUsingBlock 获取所有进程 这里为了稳定直接通过 API
  // 获取活跃应用并结束（结合 RootHelper 直接结束）

  NSString *helperPath = rootHelperPath();
  if (!helperPath || appsToKill.count == 0) {
    [self log:@"⚠️ 未发现需要结束的三方应用或 RootHelper 不可用，回退普通清理"];
    [self terminateAllViaAPI];
    return YES;
  }

  [self log:[NSString
                stringWithFormat:@" 准备终止以下应用: %@",
                                 [appsToKill componentsJoinedByString:@", "]]];

  NSMutableArray *args = [NSMutableArray arrayWithObject:@"kill-all-apps"];
  [args addObjectsFromArray:appsToKill];

  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(helperPath, args, &stdOut, &stdErr);

  if (ret == 0) {
    [self log:@"✅ 后台进程已清理完毕，准备清理多任务卡片记录..."];
    return YES;
  } else {
    [self log:[NSString
                  stringWithFormat:@"❌ 进程清理部分失败, ret=%d. stderr: %@",
                                   ret, stdErr]];
    return NO;
  }

  // 移除了 App Switcher 清理逻辑，由 kill-all-apps 提供极速终结。
}

// 回退方案：通过 XCUIApplication.terminate() 逐个终止
- (void)terminateAllViaAPI {
  NSArray *protectedPrefixes = @[
    @"com.ecmain.app", @"com.facebook.WebDriverAgentRunner", @"com.apple"
  ];

  NSMutableArray *thirdPartyBundleIds = [NSMutableArray array];
  Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
  if (LSWorkspace) {
    id workspace = [LSWorkspace performSelector:@selector(defaultWorkspace)];
    NSArray *allApps =
        [workspace performSelector:@selector(allInstalledApplications)];
    for (id proxy in allApps) {
      NSString *bundleId =
          [proxy performSelector:@selector(applicationIdentifier)];
      if (!bundleId)
        continue;
      BOOL isProtected = NO;
      for (NSString *prefix in protectedPrefixes) {
        if ([bundleId hasPrefix:prefix]) {
          isProtected = YES;
          break;
        }
      }
      if (!isProtected) {
        [thirdPartyBundleIds addObject:bundleId];
      }
    }
  }

  int closedCount = 0;
  for (NSString *bundleId in thirdPartyBundleIds) {
    NSDictionary *result =
        [self performWDAActionWithResult:@"terminateApp"
                                endpoint:@"/wda/terminateApp"
                                    body:@{@"bundleId" : bundleId}];
    if ([result[@"terminated"] boolValue]) {
      closedCount++;
      [self log:[NSString stringWithFormat:@"✅ 已终止: %@", bundleId]];
    }
  }
  [self log:[NSString stringWithFormat:@"✅ 清理完成，共终止 %d 个应用",
                                       closedCount]];
}

// --- 飞行模式控制 ---

- (BOOL)airplaneOn {
  NSLog(@"[ECScriptEngine] Executing: airplaneOn");
  [self log:@"执行: 打开飞行模式"];
  return [self setAirplaneMode:YES];
}

- (BOOL)airplaneOff {
  NSLog(@"[ECScriptEngine] Executing: airplaneOff");
  [self log:@"执行: 关闭飞行模式"];
  return [self setAirplaneMode:NO];
}

- (BOOL)setAirplaneMode:(BOOL)enabled {
  NSString *helperPath = rootHelperPath();
  if (!helperPath) {
    [self log:@"❌ RootHelper 路径不可用，无法切换飞行模式"];
    return NO;
  }

  NSString *modeArg = enabled ? @"1" : @"0";
  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(helperPath, @[ @"set-airplane-mode", modeArg ], &stdOut,
                      &stdErr);

  if (ret == 0) {
    [self log:[NSString stringWithFormat:@"✅ 飞行模式已%@",
                                         enabled ? @"开启" : @"关闭"]];
    return YES;
  } else {
    [self log:[NSString stringWithFormat:@"❌ 飞行模式切换失败 (ret=%d): %@",
                                         ret, stdErr]];
    return NO;
  }
}

// --- 网络配置 ---

- (BOOL)setStaticIP:(NSString *)ip
             subnet:(NSString *)subnet
            gateway:(NSString *)gateway
                dns:(NSString *)dns {
  NSLog(@"[ECScriptEngine] Executing: setStaticIP %@ %@ %@ %@", ip, subnet,
        gateway, dns);
  [self log:[NSString stringWithFormat:@"设置静态IP: %@ / %@ / GW:%@ / DNS:%@",
                                       ip, subnet, gateway, dns]];

  NSString *helperPath = rootHelperPath();
  if (!helperPath) {
    [self log:@"❌ RootHelper 路径不可用"];
    return NO;
  }

  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(
      helperPath,
      @[
        @"set-static-ip", ip ?: @"", subnet ?: @"", gateway ?: @"", dns ?: @""
      ],
      &stdOut, &stdErr);
  if (ret == 0) {
    // 重启 Wi-Fi 使配置生效
    spawnRoot(helperPath, @[ @"toggle-wifi" ], nil, nil);
    [self log:@"✅ 静态IP已配置，Wi-Fi已自动重置"];
    return YES;
  } else {
    [self log:[NSString stringWithFormat:@"❌ 静态IP配置失败 (ret=%d): %@", ret,
                                         stdErr ?: @""]];
    return NO;
  }
}

- (BOOL)setWifi:(NSString *)ssid password:(NSString *)password {
  NSLog(@"[ECScriptEngine] Executing: setWifi %@", ssid);
  [self log:[NSString stringWithFormat:@"连接Wi-Fi: %@", ssid]];

  if (!ssid || ssid.length == 0) {
    [self log:@"❌ 请提供Wi-Fi名称"];
    return NO;
  }

  NEHotspotConfiguration *config = nil;
  if (password && password.length >= 8) {
    config = [[NEHotspotConfiguration alloc] initWithSSID:ssid
                                               passphrase:password
                                                    isWEP:NO];
  } else if (!password || password.length == 0) {
    config = [[NEHotspotConfiguration alloc] initWithSSID:ssid];
  } else {
    [self log:@"❌ Wi-Fi密码长度至少8位，或留空表示开放网络"];
    return NO;
  }
  config.joinOnce = NO;

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  __block BOOL isSuccess = NO;

  [[NEHotspotConfigurationManager sharedManager]
      applyConfiguration:config
       completionHandler:^(NSError *error) {
         if (error) {
           if (error.code == NEHotspotConfigurationErrorAlreadyAssociated) {
             [self log:[NSString stringWithFormat:@"✅ 已连接到 %@", ssid]];
             isSuccess = YES;
           } else {
             [self log:[NSString stringWithFormat:@"❌ Wi-Fi连接失败: %@",
                                                  error.localizedDescription]];
           }
         } else {
           [self log:[NSString
                         stringWithFormat:@"✅ 已成功连接 Wi-Fi: %@", ssid]];
           isSuccess = YES;
         }
         dispatch_semaphore_signal(sema);
       }];

  dispatch_semaphore_wait(sema,
                          dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
  return isSuccess;
}

- (BOOL)connectProxy:(NSString *)keyword {
  NSLog(@"[ECScriptEngine] Executing: connectProxy %@", keyword);
  [self log:[NSString stringWithFormat:@"尝试连接代理: %@",
                                       keyword ?: @"(重新连接上次节点)"]];

  if (!keyword || keyword.length == 0) {
    NSString *lastNodeID = [[ECVPNConfigManager sharedManager] activeNodeID];
    if (lastNodeID) {
      NSDictionary *lastNode =
          [[ECVPNConfigManager sharedManager] nodeWithID:lastNodeID];
      if (lastNode) {
        NSString *matchName = lastNode[@"name"] ?: lastNode[@"remark"] ?: @"Unknown";
        [self log:[NSString stringWithFormat:@"✅ 找到上次使用的节点: %@",
                                             matchName]];
        [[ECBackgroundManager sharedManager] connectVPNWithConfig:lastNode];
        return YES;
      }
    }

    [self log:@"❌ 未找到上次连接的节点记录"];
    return NO;
  }

  NSArray<NSDictionary *> *nodes =
      [[ECVPNConfigManager sharedManager] allNodes];
  NSDictionary *matchedNode = nil;

  // 1. 完全匹配 name 或 remark
  for (NSDictionary *node in nodes) {
    NSString *name = node[@"name"];
    NSString *remark = node[@"remark"];
    if (([name isKindOfClass:[NSString class]] &&
         [name isEqualToString:keyword]) ||
        ([remark isKindOfClass:[NSString class]] &&
         [remark isEqualToString:keyword])) {
      matchedNode = node;
      break;
    }
  }

  // 2. 如果没匹配到名字，尝试部分匹配 IP/Server/Host
  if (!matchedNode) {
    for (NSDictionary *node in nodes) {
      NSString *server = node[@"server"] ?: node[@"host"] ?: node[@"ip"];
      if ([server isKindOfClass:[NSString class]] &&
          [server rangeOfString:keyword options:NSCaseInsensitiveSearch]
                  .location != NSNotFound) {
        matchedNode = node;
        break;
      }
    }
  }

  // 3. 模糊匹配名称作为最后手段
  if (!matchedNode) {
    for (NSDictionary *node in nodes) {
      NSString *name = node[@"name"];
      NSString *remark = node[@"remark"];
      if (([name isKindOfClass:[NSString class]] &&
           [name rangeOfString:keyword options:NSCaseInsensitiveSearch]
                   .location != NSNotFound) ||
          ([remark isKindOfClass:[NSString class]] &&
           [remark rangeOfString:keyword options:NSCaseInsensitiveSearch]
                   .location != NSNotFound)) {
        matchedNode = node;
        break;
      }
    }
  }

  if (matchedNode) {
    NSString *matchName = matchedNode[@"name"] ?: matchedNode[@"remark"] ?: @"Unknown";
    [self log:[NSString stringWithFormat:@"✅ 找到匹配节点: %@", matchName]];
    [[ECVPNConfigManager sharedManager] setActiveNodeID:matchedNode[@"id"]];
    [[ECBackgroundManager sharedManager] connectVPNWithConfig:matchedNode];
    return YES;
  } else {
    [self log:[NSString stringWithFormat:@"❌ 未找到与 '%@' 匹配的代理节点",
                                         keyword]];
    return NO;
  }
}

// --- Text / OCR ---

- (NSDictionary *)findText:(NSString *)text {
  NSDictionary *result =
      [self performWDAActionWithResult:@"findText"
                              endpoint:@"/wda/findText"
                                  body:@{@"text" : text ?: @""}];
  return result ?: @{@"found" : @NO};
}

- (BOOL)tapText:(NSString *)text {
  return [self performWDAAction:@"tapText"
                       endpoint:@"/wda/clickText"
                           body:@{@"text" : text ?: @""}];
}

- (NSDictionary *)ocr {
  NSDictionary *result = [self performWDAActionWithResult:@"ocr"
                                                 endpoint:@"/wda/ocr"
                                                     body:@{}];
  return result ?: @{@"texts" : @[]};
}

// --- Utils ---

- (NSInteger)randomInt:(NSInteger)min max:(NSInteger)max {
  return min + arc4random_uniform((uint32_t)(max - min + 1));
}

- (double)random:(double)min max:(double)max {
  double r = (double)arc4random() / UINT32_MAX;
  return min + r * (max - min);
}

// --- VPN Actions ---

- (BOOL)connectVPN:(NSDictionary *)config {
  NSLog(@"[ECScriptEngine] connectVPN called with config: %@", config);
  [self log:[NSString stringWithFormat:@"配置VPN并连接: %@:%@",
                                       config[@"server"], config[@"port"]]];

  // Call ECBackgroundManager to apply config and connect
  // Use performSelector to avoid direct dependency header import if needed, but
  // we imported Manager in ECScriptParser.m usually? Let's import header if not
  // present, but ECScriptParser.m usually imports headers. Actually, better to
  // use the shared manager directly if header is available.

  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECBackgroundManager sharedManager] connectVPNWithConfig:config];
  });
  return YES;
}

- (BOOL)isVPNConnected {
  BOOL connected = [[ECBackgroundManager sharedManager] isVPNActive];
  [self log:[NSString stringWithFormat:@"查询VPN连接状态: %@",
                                       connected ? @"已连接" : @"未连接"]];
  return connected;
}

// --- Image / Color ---

- (NSDictionary *)findImage:(NSString *)template
                  threshold:(NSNumber *)threshold {
  NSDictionary *result =
      [self performWDAActionWithResult:@"findImage"
                              endpoint:@"/wda/findImage"
                                  body:@{
                                    @"template" : template ?: @"",
                                    @"threshold" : threshold ?: @0.8
                                  }];
  return result ?: @{@"found" : @NO};
}

- (NSString *)getColorAt:(NSNumber *)x y:(NSNumber *)y {
  NSDictionary *result =
      [self performWDAActionWithResult:@"getPixel"
                              endpoint:@"/wda/getPixel"
                                  body:@{
                                    @"x" : [self safeNumber:x],
                                    @"y" : [self safeNumber:y]
                                  }];
  return result[@"color"] ?: @"#000000";
}

- (NSDictionary *)findMultiColor:(NSString *)colors {
  if (!colors || colors.length == 0) {
    return @{@"found" : @NO};
  }

  NSArray *parts = [colors componentsSeparatedByString:@"|"];
  if (parts.count == 0)
    return @{@"found" : @NO};

  NSArray *firstParts = [parts[0] componentsSeparatedByString:@","];
  if (firstParts.count < 3)
    return @{@"found" : @NO};
  NSString *firstColor = firstParts[2];

  NSMutableArray *offsets = [NSMutableArray array];
  for (int i = 1; i < parts.count; i++) {
    NSArray *p = [parts[i] componentsSeparatedByString:@","];
    if (p.count >= 3) {
      [offsets addObject:@{
        @"offsetX" : @([p[0] integerValue]),
        @"offsetY" : @([p[1] integerValue]),
        @"color" : p[2]
      }];
    }
  }

  NSDictionary *result =
      [self performWDAActionWithResult:@"findMultiColor"
                              endpoint:@"/wda/findMultiColor"
                                  body:@{
                                    @"firstColor" : firstColor,
                                    @"offsets" : offsets ?: @[]
                                  }];
  return result ?: @{@"found" : @NO};
}

#pragma mark - Helper Methods

#pragma mark - UIAlert Handling

- (NSString *)getAlertText {
  NSDictionary *res = [self performWDAActionWithResult:@"getAlertText"
                                              endpoint:@"/alert/text"
                                                  body:nil
                                                method:@"GET"];
  if ([res[@"status"] integerValue] == 0 && res[@"value"]) {
    return [NSString stringWithFormat:@"%@", res[@"value"]];
  }
  return nil;
}

- (BOOL)acceptAlert {
  NSDictionary *res = [self performWDAActionWithResult:@"acceptAlert"
                                              endpoint:@"/alert/accept"
                                                  body:nil
                                                method:@"POST"];
  return [res[@"status"] integerValue] == 0;
}

- (BOOL)dismissAlert {
  NSDictionary *res = [self performWDAActionWithResult:@"dismissAlert"
                                              endpoint:@"/alert/dismiss"
                                                  body:nil
                                                method:@"POST"];
  return [res[@"status"] integerValue] == 0;
}

- (void)ensureWDASessionId {
  if (!gActiveWDASessionId) {
    NSDictionary *caps = @{@"capabilities" : @{@"alwaysMatch" : @{}}};
    // 这里使用无拦截的原生 GET/POST 或者直接让底层的 perform 进去时还未判定挂载
    [self performWDAActionWithResult:@"createSession"
                            endpoint:@"/session"
                                body:caps
                              method:@"POST"];
    NSLog(@"[ECScriptEngine] 自动预创 WDA Session, 获取到 ID: %@",
          gActiveWDASessionId ?: @"(nil)");
  }
}

- (NSArray *)getAlertButtons {
  [self ensureWDASessionId];

  NSDictionary *res = [self performWDAActionWithResult:@"getAlertButtons"
                                              endpoint:@"/wda/alert/buttons"
                                                  body:nil
                                                method:@"GET"];
  if ([res[@"status"] integerValue] == 0 &&
      [res[@"value"] isKindOfClass:[NSArray class]]) {
    return res[@"value"];
  }
  return nil; // 无弹窗或获取失败
}

- (BOOL)clickAlertButton:(NSString *)label {
  if (!label || label.length == 0)
    return NO;

  // WDA 的 handleAlertAcceptCommand: 支持带 name 参数定点点击指定的 Alert Box
  // Item
  NSDictionary *payload = @{@"name" : label};
  NSDictionary *res = [self performWDAActionWithResult:@"clickAlertButton"
                                              endpoint:@"/alert/accept"
                                                  body:payload
                                                method:@"POST"];
  return [res[@"status"] integerValue] == 0;
}

// 同步 WDA 调用（带返回值并且可指定 Method）
- (NSDictionary *)performWDAActionWithResult:(NSString *)name
                                    endpoint:(NSString *)endpoint
                                        body:(NSDictionary *)body
                                      method:(NSString *)method {
  NSLog(@"[ECScriptEngine] Executing with result: %@", name);
  [self log:[NSString stringWithFormat:@"Execute: %@", name]];

  NSString *actualEndpoint = endpoint;
  // 路由策略：
  // - /wda/ 前缀的端点默认不加 session（绝大多数都是 withoutSession）
  // - /alert/ 前缀的端点需要 session（有 session 和 withoutSession 双版本）
  // - /wda/alert/ 前缀的端点需要 session（仅有带 session 版本）
  // - /screenshot 等其他端点不需要 session
  if ([endpoint hasPrefix:@"/alert/"] || [endpoint hasPrefix:@"/wda/alert/"]) {
    [self ensureWDASessionId];
    if (gActiveWDASessionId) {
      actualEndpoint = [NSString
          stringWithFormat:@"/session/%@%@", gActiveWDASessionId, endpoint];
    }
  }

  NSString *urlString = [NSString
      stringWithFormat:@"http://127.0.0.1:%d%@", kWDAPort, actualEndpoint];
  NSURL *url = [NSURL URLWithString:urlString];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = method;
  request.timeoutInterval = 30;

  if (body) {
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:nil];
  }

  int retryCount = 0;
  const int maxRetries = 3;
  __block NSDictionary *resultDict = nil;

  while (retryCount < maxRetries) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    [[NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (!error && data) {
              NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
              id json = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:nil];
              NSLog(@"[ECScriptEngine] %@ 响应 (HTTP %ld): %@", name,
                    (long)httpResp.statusCode, json);

              if ([json isKindOfClass:[NSDictionary class]]) {
                if (json[@"sessionId"] &&
                    [json[@"sessionId"] isKindOfClass:[NSString class]]) {
                  gActiveWDASessionId = json[@"sessionId"];
                }

                NSMutableDictionary *dictToReturn =
                    [NSMutableDictionary dictionary];
                if (json[@"status"]) {
                  dictToReturn[@"status"] = json[@"status"];
                }

                id valueObj = json[@"value"];
                if ([valueObj isKindOfClass:[NSDictionary class]]) {
                  [dictToReturn addEntriesFromDictionary:valueObj];
                } else if (valueObj) {
                  dictToReturn[@"value"] = valueObj;
                }
                resultDict = [dictToReturn copy];
              }
              [self log:[NSString
                            stringWithFormat:@"%@ 结果: %@", name, resultDict]];
            } else {
                NSLog(@"[ECScriptEngine] Attempt %d failed (%@): %@", retryCount + 1, name,
                    error.localizedDescription);
            }
            dispatch_semaphore_signal(sema);
          }] resume];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    if (resultDict) break;
    
    retryCount++;
    if (retryCount < maxRetries) {
        [NSThread sleepForTimeInterval:1.0];
        NSLog(@"[ECScriptEngine] 正在进行第 %d 次 WDA 重试...", retryCount);
    }
  }

  return resultDict ?: @{@"status" : @(-1), @"error" : @"No response after retries"};
}

// 同步 WDA 调用（向下兼容旧实现）
- (NSDictionary *)performWDAActionWithResult:(NSString *)name
                                    endpoint:(NSString *)endpoint
                                        body:(NSDictionary *)body {
  // 兼容老请求：如果有 body 就是 POST，否则视作 GET
  return [self performWDAActionWithResult:name
                                 endpoint:endpoint
                                     body:body
                                   method:body ? @"POST" : @"GET"];
}

// Synchronous WDA Call
- (BOOL)performWDAAction:(NSString *)name
                endpoint:(NSString *)endpoint
                    body:(NSDictionary *)body {
  NSLog(@"[ECScriptEngine] Executing: %@", name);
  [self log:[NSString stringWithFormat:@"Execute: %@", name]];

  NSString *actualEndpoint = endpoint;
  // 路由策略：同 performWDAActionWithResult
  if ([endpoint hasPrefix:@"/alert/"] || [endpoint hasPrefix:@"/wda/alert/"]) {
    [self ensureWDASessionId];
    if (gActiveWDASessionId) {
      actualEndpoint = [NSString
          stringWithFormat:@"/session/%@%@", gActiveWDASessionId, endpoint];
    }
  }

  NSString *urlString = [NSString
      stringWithFormat:@"http://127.0.0.1:%d%@", kWDAPort, actualEndpoint];
  NSURL *url = [NSURL URLWithString:urlString];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = body ? @"POST" : @"GET";
  request.timeoutInterval = 30;

  if (body) {
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:nil];
  }

  int retryCount = 0;
  const int maxRetries = 3;
  __block BOOL isSuccess = NO;

  while (retryCount < maxRetries) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL currentAttemptSuccess = NO;

    [[NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (error) {
              NSLog(@"[EC_CMD_LOG] [ECScriptEngine] WDA Attempt %d Error (%@): %@", 
                    retryCount + 1, name, error.localizedDescription);
            } else {
              NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
              if (httpResp.statusCode >= 200 && httpResp.statusCode < 300) {
                currentAttemptSuccess = YES;
                NSLog(@"[EC_CMD_LOG] [ECScriptEngine] ========= WDA 指令执行结果 =========");
                NSLog(@"[EC_CMD_LOG] [ECScriptEngine] Success (%@): Status %ld",
                      name, (long)httpResp.statusCode);
                NSLog(@"[EC_CMD_LOG] [ECScriptEngine] ==================================");
              }
            }
            dispatch_semaphore_signal(sema);
          }] resume];

    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
    
    if (currentAttemptSuccess) {
        isSuccess = YES;
        break;
    }
    
    retryCount++;
    if (retryCount < maxRetries) {
        [NSThread sleepForTimeInterval:1.0];
        NSLog(@"[ECScriptEngine] 正在进行第 %d 次 WDA 重试...", retryCount);
    }
  }

  return isSuccess;
}

#pragma mark - 评论引擎 (本地全量缓存)

- (BOOL)syncCommentsFromServer:(NSString *)serverUrl {
  [self log:[NSString stringWithFormat:
                          @"[ECScriptEngine] 🔁 开始从服务器拉取评论数据: %@",
                          serverUrl]];

  NSURL *url = [NSURL URLWithString:serverUrl];
  if (!url) {
    [self log:@"❌ 无效的服务器 URL"];
    return NO;
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"GET";
  request.timeoutInterval = 60.0; // 较大数据可能需要更长超时

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  __block BOOL success = NO;

  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          if (error) {
            [self log:[NSString stringWithFormat:@"❌ 下载评论数据失败: %@",
                                                 error.localizedDescription]];
          } else if (data) {
            NSError *jsonError = nil;
            NSDictionary *json =
                [NSJSONSerialization JSONObjectWithData:data
                                                options:0
                                                  error:&jsonError];

            if (!jsonError && [json isKindOfClass:[NSDictionary class]] &&
                [json[@"status"] isEqualToString:@"ok"]) {
              NSArray *commentsArray = json[@"data"];
              if ([commentsArray isKindOfClass:[NSArray class]]) {
                // 将下载的数组扁平化存储，以 language 为 key
                // 再次分类提高读取效率
                NSMutableDictionary *groupedComments =
                    [NSMutableDictionary dictionary];
                for (NSDictionary *c in commentsArray) {
                  NSString *lang = c[@"language"];
                  NSString *content = c[@"content"];
                  if (lang && content) {
                    NSMutableArray *arr = groupedComments[lang];
                    if (!arr) {
                      arr = [NSMutableArray array];
                      groupedComments[lang] = arr;
                    }
                    [arr addObject:content];
                  }
                }

                // 使用 UserDefaults 持久化
                NSUserDefaults *defaults =
                    [NSUserDefaults standardUserDefaults];
                [defaults setObject:groupedComments
                             forKey:@"EC_LOCAL_COMMENTS_CACHE"];
                [defaults synchronize];

                [self log:[NSString stringWithFormat:
                                        @"✅ 评论库本地全量更新完成！共计引入 "
                                        @"%lu 条语料，涵盖 %lu 种语言。",
                                        (unsigned long)commentsArray.count,
                                        (unsigned long)groupedComments.count]];
                success = YES;
              } else {
                [self log:@"❌ 抓取到的数据格式有误：无 data 数组"];
              }
            } else {
              [self log:@"❌ 抓取到的数据存在服务层报错或 JSON 解析问题"];
            }
          }
          dispatch_semaphore_signal(sema);
        }] resume];

  dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
  return success;
}

- (NSString *)getRandomComment:(NSString *)language {
  if (!language || language.length == 0) {
    [self log:@"⚠️ getRandomComment 缺失语言参数"];
    return @"";
  }

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDictionary *allComments =
      [defaults dictionaryForKey:@"EC_LOCAL_COMMENTS_CACHE"];

  if (!allComments || allComments.count == 0 || !allComments[language] ||
      [allComments[language] count] == 0) {
    [self log:@"⚠️ "
              @"本地评论缓存为空或缺失对应语言，尝试直接连接服务器自动补充拉取."
              @".."];

    NSUserDefaults *groupDefaults =
        [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    NSString *cloudUrl = [groupDefaults stringForKey:@"EC_CLOUD_SERVER_URL"];
    if (!cloudUrl || cloudUrl.length == 0) {
      cloudUrl = @"https://s.ecmain.site";
    }
    NSString *commentsUrl = [cloudUrl stringByAppendingString:@"/api/comments"];

    BOOL syncOk = [self syncCommentsFromServer:commentsUrl];
    if (syncOk) {
      // 重新读取
      allComments = [defaults dictionaryForKey:@"EC_LOCAL_COMMENTS_CACHE"];
    } else {
      [self log:@"❌ 自动补充拉取评论失败！"];
      return @"";
    }
  }

  NSArray *candidates = allComments[language];
  if (!candidates || candidates.count == 0) {
    [self log:[NSString stringWithFormat:
                            @"⚠️ 本地评论库内依然不存在为语言 [%@] 的任何储存",
                            language]];
    return @"";
  }

  uint32_t randomIndex = arc4random_uniform((uint32_t)candidates.count);
  NSString *picked = candidates[randomIndex];

  [self log:[NSString stringWithFormat:@"💬 已成功为 [%@] 抽取随机本地词条: %@",
                                       language, picked]];
  return picked;
}

@end
