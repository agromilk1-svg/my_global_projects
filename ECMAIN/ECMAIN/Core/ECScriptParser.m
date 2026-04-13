//
//  ECScriptParser.m
//  ECMAIN
//
//  JavaScript script engine for ECMAIN (JavaScriptCore)
//

#import "ECScriptParser.h"
#import "../../System/ECSystemManager.h"
#import "../../TrollStoreCore/TSApplicationsManager.h"
#import "ECAppInjector.h"
#import "ECBackgroundManager.h"
#import "ECLogManager.h"
#import "ECPersistentConfig.h"
#import "../Utils/ECAppLauncher.h"
#import "ECProxyURIParser.h"
#import "ECTaskPollManager.h"
#import "ECVPNConfigManager.h"
#import <Photos/Photos.h>
#import <NetworkExtension/NetworkExtension.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>
#import <net/if.h>

// [v1760] 声明系统级弹窗 API 以便动态调用，防止 Xcode 编译器的 unavailable 检查
typedef SInt32 (*CFUserNotificationDisplayAlert_t)(
    CFTimeInterval timeout, 
    CFOptionFlags flags, 
    CFURLRef iconURL, 
    CFURLRef soundURL, 
    CFURLRef localizationURL, 
    CFStringRef alertHeader, 
    CFStringRef alertMessage, 
    CFStringRef defaultButtonTitle, 
    CFStringRef alternateButtonTitle, 
    CFStringRef otherButtonTitle, 
    CFOptionFlags *responseFlags);

// RootHelper 工具函数声明
extern int spawnRoot(NSString *path, NSArray *args, NSString **stdOut,
                     NSString **stdErr);
extern NSString *rootHelperPath(void);
extern NSArray *trollStoreInstalledAppBundlePaths(void);

// 脚本执行日志文件路径（持久化，防止切换页面后丢失）
static NSString *ECScriptLogFilePath(void) {
  static NSString *path = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // [v1956修改] 将实质性日志文件存储从沙盒 Documents 迁移到全局可访问的 /var/mobile/Media 目录
    path = @"/var/mobile/Media/ec_script_log.txt";
  });
  return path;
}

// WDA port (runs on same device)
static const int kWDAPort = 10088;

// [v1956] 截图缓存提升为文件级静态变量，供 findImage 复用 + clearScreenshotCache 真正清理
static NSString *sCachedScreenshotB64 = nil;
static CFAbsoluteTime sCachedScreenshotTime = 0;
static const CFAbsoluteTime kScreenshotCacheTTL = 2.0; // 2 秒缓存窗口：连续 findImage 共享同一截图

// [v1956] 持久化日志文件句柄（文件级，executeScript 入口重建，log: 方法复用）
static NSFileHandle *sPersistLogHandle = nil;

@implementation ECScriptParser {
  NSMutableArray *_executionLogs;
  BOOL _shouldInterrupt; // 中断标志位
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

#pragma mark - 前置任务保活屏障

/**
 * 阻塞当前线程执行环境准备（最长阻塞 15 秒）
 * 1. 强行点亮屏幕
 * 2. 探测 WDA，若死亡则拉起
 * 3. 阻塞等待 WDA 恢复
 */
- (void)prepareTaskEnvironmentSync {
  [self log:@"[系统探活] 🛡️ 启动前置任务保活屏障..."];
  
  // 1. 点亮屏幕与应用前台化
  dispatch_async(dispatch_get_main_queue(), ^{
    [ECAppLauncher wakeScreenAndBringMainAppToFront];
  });
  
  // 给系统 1 秒时间响应锁屏解锁动画
  [NSThread sleepForTimeInterval:1.0];
  
  // 2 & 3. 探测 WDA 并阻塞等待
  int maxWaitSeconds = 15;
  NSURL *probeUrl = [NSURL URLWithString:@"http://127.0.0.1:10088/status"];
  
  for (int i = 0; i < maxWaitSeconds; i++) {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL isAlive = NO;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:probeUrl];
    req.timeoutInterval = 1.0; // 极短超时快速失败
    
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
      if (!error && httpResp.statusCode == 200) {
        isAlive = YES;
      }
      dispatch_semaphore_signal(sema);
    }] resume];
    
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 1.5 * NSEC_PER_SEC));
    
    if (isAlive) {
      [self log:@"[系统探活] ✅ WDA 环境已就绪，安全放行执行"];
      return;
    } else {
      if (i == 0) {
        [self log:@"[系统探活] ⚠️ WDA 当前无响应或未启动，正在强行拉起..."];
        dispatch_async(dispatch_get_main_queue(), ^{
          [[TSApplicationsManager sharedInstance] openApplicationWithBundleID:@"com.apple.accessibility.ecwda"];
        });
      } else {
        [self log:[NSString stringWithFormat:@"[系统探活] ⏳ 等待 WDA 恢复中 (%d/%ds)...", i, maxWaitSeconds]];
      }
    }
    
    [NSThread sleepForTimeInterval:1.0];
  }
  
  [self log:@"[系统探活] ❌ WDA 拉起等待超时 (15s)，放弃阻塞，继续强制执行。"];
}

#pragma mark - Public Methods

- (void)executeScript:(NSString *)script
           completion:(void (^)(BOOL success, NSArray *results))completion {
  NSLog(@"[脚本动作] ====== 开始执行脚本 ======");
  NSLog(@"[脚本动作] 脚本长度: %lu 字符", (unsigned long)script.length);
  NSLog(@"[脚本动作] 脚本内容:\n%@", script);

  // 清空日志文件（新脚本执行前清除上次记录）
  // [v1956修复] 不再使用 atomically:YES（会替换 inode 导致持久化 FileHandle 失效写入黑洞）
  NSString *logPath = ECScriptLogFilePath();
  if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
  } else {
    // 截断文件为0字节，保持 inode 不变
    NSFileHandle *truncHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    [truncHandle truncateFileAtOffset:0];
    [truncHandle closeFile];
  }
  // 重建持久化日志句柄（指向同一 inode 的全新 fd）
  sPersistLogHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];

  // 广播日志清空通知，通知任务列表页面清除旧日志
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ECScriptLogDidClear" object:nil];
  });

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
    NSString *errStr = [NSString stringWithFormat:@"%@", exception];
    NSLog(@"[脚本动作] ❌ JS 异常: %@", errStr);
    [self log:[NSString stringWithFormat:@"[脚本动作] JS Error: %@", errStr]];
    // 发送崩溃/异常报错通知给服务器端
    [[ECTaskPollManager sharedManager] reportActionErrorWithMessage:errStr forCommand:@"JS 运行异常中断"];
    self->_shouldInterrupt = YES;
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
  _shouldInterrupt = NO; // 重置中断标志

  // Execute Script
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   // [v1762] 执行环境前置拦截探测
                   [self prepareTaskEnvironmentSync];

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
    NSString *errStr = [NSString stringWithFormat:@"%@", exception];
    [self log:[NSString stringWithFormat:@"[脚本动作] JS Error: %@", errStr]];
    [[ECTaskPollManager sharedManager] reportActionErrorWithMessage:errStr forCommand:@"JS(Sync) 运行异常中断"];
    self->_shouldInterrupt = YES;
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
    _shouldInterrupt = NO; // 重置中断标志
  }

  // 广播日志清空通知
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ECScriptLogDidClear" object:nil];
  });

  __block BOOL isSuccess = YES;
  __block id finalRetVal = nil;

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   // 💡 Web 控制台（WebControlCenter）发起的是同步请求。
                   // 控制台发起的任务默认使用者正在看屏幕，不再“多此一举”去强制亮屏和阻塞探活，提升响应速度。
                   
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

- (void)reportErrorAndAbort:(NSString *)message {
  [self log:[NSString stringWithFormat:@"🚨 主动触发业务错误: %@", message]];
  [[ECTaskPollManager sharedManager] reportActionErrorWithMessage:message forCommand:@"JS主动抛错"];
  _shouldInterrupt = YES;
  if ([JSContext currentContext]) {
      [JSContext currentContext].exception = [JSValue valueWithNewErrorFromMessage:message inContext:[JSContext currentContext]];
  }
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

- (void)interruptExecution {
  _shouldInterrupt = YES;
  NSLog(@"[ECScriptEngine] 🛑 接收到中断信号，标记为中断执行状态");
  [self log:@"🚨 脚本执行被手动中断 (User Interrupt)"];
}

// 内部私有方法：检查中断状态
- (BOOL)_checkInterrupt {
  if (_shouldInterrupt) {
    NSLog(@"[ECScriptEngine] 🛑 检测到中断标志，拦截动作执行并强行抛出 JS 异常");
    JSContext *ctx = [JSContext currentContext];
    if (ctx) {
      // 通过抛出 JS 异常阻断所有的 JS 长循环和 while(true) 等逻辑
      ctx.exception = [JSValue valueWithNewErrorFromMessage:@"🛑 ECMAIN Scripts Execution Interrupted By User" inContext:ctx];
    }
    return YES;
  }
  return NO;
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

    // ★ 持久化写入日志文件（sPersistLogHandle 在 executeScript 入口重建，此处懒加载兼容首次调用）
    if (!sPersistLogHandle) {
      NSString *logPath = ECScriptLogFilePath();
      if (![[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
      }
      sPersistLogHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    }
    if (sPersistLogHandle) {
      static NSDateFormatter *sLogDateFmt = nil;
      static dispatch_once_t onceFmt;
      dispatch_once(&onceFmt, ^{
        sLogDateFmt = [[NSDateFormatter alloc] init];
        [sLogDateFmt setDateFormat:@"HH:mm:ss"];
      });
      NSString *timeStr = [sLogDateFmt stringFromDate:[NSDate date]];
      NSString *logLine = [NSString stringWithFormat:@"[%@] %@\n", timeStr, message];
      @try {
        [sPersistLogHandle seekToEndOfFile];
        [sPersistLogHandle writeData:[logLine dataUsingEncoding:NSUTF8StringEncoding]];
      } @catch (NSException *e) {
        // 文件句柄异常失效，重新打开
        sPersistLogHandle = [NSFileHandle fileHandleForWritingAtPath:ECScriptLogFilePath()];
      }
    }

    // 广播实时日志通知，供任务管理页面实时显示
    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
          postNotificationName:@"ECScriptLogDidAppend"
                        object:nil
                      userInfo:@{@"message": message}];
    });
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
  if ([self _checkInterrupt])
    return NO;
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
  if ([self _checkInterrupt])
    return NO;
  double sec = [seconds doubleValue];
  NSLog(@"[ECScriptEngine] Sleeping for %.2f seconds", sec);
  [self log:[NSString stringWithFormat:@"Sleep %.2fs", sec]];

  // 对于长 Sleep，采用分段检查，提高中断响应速度
  double remain = sec;
  while (remain > 0) {
    if ([self _checkInterrupt])
      return NO;
    double step = MIN(remain, 1.0);
    [NSThread sleepForTimeInterval:step];
    remain -= step;
  }
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

- (BOOL)lock {
  return [self performWDAAction:@"lock" endpoint:@"/wda/lock" body:@{}];
}

- (BOOL)volumeUp {
  return [self performWDAAction:@"volumeUp" endpoint:@"/wda/pressButton" body:@{@"name": @"volumeUp"}];
}

- (BOOL)volumeDown {
  return [self performWDAAction:@"volumeDown" endpoint:@"/wda/pressButton" body:@{@"name": @"volumeDown"}];
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
  NSLog(@"[ECScriptEngine] Executing: terminate %@", bundleId);
  [self log:[NSString stringWithFormat:@"Terminate: %@", bundleId]];

  // 1. 优先使用 TrollStore RootHelper 暴力结束应用进程
  NSString *helperPath = rootHelperPath();
  if (helperPath) {
    Class LSProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSProxy) {
      id proxy = [LSProxy performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleId];
      if (proxy && [proxy respondsToSelector:@selector(canonicalExecutablePath)]) {
        NSString *execPath = [proxy performSelector:@selector(canonicalExecutablePath)];
        NSString *executableName = execPath.lastPathComponent;
        
        if (executableName && executableName.length > 0) {
          [self log:[NSString stringWithFormat:@"利用 TrollStore 提权静默结束进程: %@", executableName]];
          NSString *stdOut = nil;
          NSString *stdErr = nil;
          int ret = spawnRoot(helperPath, @[@"kill-all-apps", executableName], &stdOut, &stdErr);
          
          if (ret == 0) {
            [self log:[NSString stringWithFormat:@"✅ 已成功终止: %@", bundleId]];
            return YES;
          } else {
            [self log:[NSString stringWithFormat:@"⚠️ 提权结束失败 (ret=%d)，回退标准模式: %@", ret, stdErr]];
          }
        }
      }
    }
  }

  // 2. 兜底后备方案：直接调用 WDA 的 terminateApp 端点，通过 XCUIApplication.terminate() 杀进程
  [self log:[NSString stringWithFormat:@"回退至 WDA XCUIApplication API 关闭应用..."]];
  NSDictionary *result =
      [self performWDAActionWithResult:@"terminateApp"
                              endpoint:@"/wda/apps/terminate"
                                  body:@{@"bundleId" : bundleId}];

  BOOL terminated = [result[@"value"] boolValue];
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
    @"ECMAIN", @"ECWDA", @"ECService-Runner", @"echelper",
    @"Ecrunner-Runner"
  ];

  // 收集需要被杀掉的 App 名称
  NSMutableArray *appsToKill = [NSMutableArray array];

  // 遍历所有安装的应用找出 Executable Name
  Class LSWorkspace = NSClassFromString(@"LSApplicationWorkspace");
  if (LSWorkspace) {
    id workspace = [LSWorkspace performSelector:@selector(defaultWorkspace)];
    NSArray *allApps =
        [workspace performSelector:@selector(allInstalledApplications)];

    NSArray *protectedPrefixes = @[
      @"com.ecmain.app", @"com.apple.accessibility.service", @"com.apple"
    ];

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
        NSString *executableName = nil;
        if ([proxy respondsToSelector:@selector(canonicalExecutablePath)]) {
          NSString *execPath =
              [proxy performSelector:@selector(canonicalExecutablePath)];
          executableName = execPath.lastPathComponent;
        }

        if (executableName && executableName.length > 0 &&
            ![protectedNames containsObject:executableName]) {
          // 为了防止查重
          if (![appsToKill containsObject:executableName]) {
            [appsToKill addObject:executableName];
          }
        }
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
    @"com.ecmain.app", @"com.apple.accessibility.service", @"com.apple"
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
                                endpoint:@"/wda/apps/terminate"
                                    body:@{@"bundleId" : bundleId}];
    if ([result[@"value"] boolValue]) {
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

- (void)reportFinished {
  NSLog(@"[ECScriptEngine] Executing: reportFinished");
  [self log:@"执行: 任务完成主动汇报"];
  // 提前通知服务器任务完成（在飞行模式开启前显式调用）
  [[ECTaskPollManager sharedManager] preReportTaskCompletion];
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
                                       (keyword && keyword.length > 0) ? keyword : @"(寻找默认节点)"]];

  if (!keyword || keyword.length == 0) {
    ECVPNConfigManager *mgr = [ECVPNConfigManager sharedManager];
    NSString *lastNodeID = [mgr activeNodeID];
    NSDictionary *targetNode = nil;
    
    // 1. 先尝试获取上一次记录的活跃节点
    if (lastNodeID) {
      targetNode = [mgr nodeWithID:lastNodeID];
    }
    
    // 2. 如果上一次节点丢失（如重启或清空导致找不到），降级取列表里第一个（默认选中的那个）
    if (!targetNode) {
      NSArray *all = [mgr allNodes];
      if (all && all.count > 0) {
        targetNode = all.firstObject;
        [self log:@"🔄 上次使用的节点已失效，自动降级选择节点列表第一项"];
      }
    }

    if (targetNode) {
      NSString *matchName = targetNode[@"name"] ?: targetNode[@"remark"] ?: @"Unknown";
      [self log:[NSString stringWithFormat:@"✅ 自动选择代理节点: %@", matchName]];
      
      // 顺便把状态存回去，以便下次直接命中
      NSString *nid = targetNode[@"id"];
      if (nid) {
        [mgr setActiveNodeID:nid];
      }
      
      [[ECBackgroundManager sharedManager] connectVPNWithConfig:targetNode];
      return YES;
    }

    [self log:@"❌ 无法连接代理: 未找到上次连接记录，且代理节点列表为空"];
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
  // 使用 findText+随机点击的模式重构，替代 WDA 硬编码的无偏移定点点击
  NSDictionary *res = [self findText:text];
  if ([res[@"found"] boolValue]) {
    NSDictionary *rectData = res[@"result"];
    if (!rectData) {
      // 兼容较老版本 WDA 如果直接平铺了 x/y 属性的情况
      if (res[@"x"]) {
        rectData = res;
      } else {
        return NO;
      }
    }
    
    double baseX = [rectData[@"x"] doubleValue];
    double baseY = [rectData[@"y"] doubleValue];
    double width = [rectData[@"width"] doubleValue];
    double height = [rectData[@"height"] doubleValue];
    
    // [防风控]: 留出 10% 的内缩安全边距，确保随机点击的落点始终真实且处在元素可交互区内
    double paddingX = width * 0.1;
    double paddingY = height * 0.1;
    
    double safeWidth = width - paddingX * 2;
    double safeHeight = height - paddingY * 2;
    if (safeWidth <= 0) safeWidth = 1;
    if (safeHeight <= 0) safeHeight = 1;
    
    double randomOffsetX = [self random:paddingX max:(paddingX + safeWidth)];
    double randomOffsetY = [self random:paddingY max:(paddingY + safeHeight)];
    
    double targetX = baseX + randomOffsetX;
    double targetY = baseY + randomOffsetY;
    
    [self log:[NSString stringWithFormat:@"✅ tapText 命中 '%@', 随机落点坐标: (%.1f, %.1f) [目标区域: %.1fx%.1f]", text, targetX, targetY, width, height]];
    
    NSDictionary *tapRes = [self performWDAActionWithResult:@"tap"
                                                   endpoint:@"/wda/tapByCoord"
                                                       body:@{@"x": @(targetX), @"y": @(targetY)}];
    return [tapRes[@"status"] integerValue] == 0;
  }
  
  [self log:[NSString stringWithFormat:@"❌ tapText 未命中文字: %@", text]];
  return NO;
}

- (NSDictionary *)ocr {
  if ([self _checkInterrupt])
    return @{@"texts" : @[]};
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

- (BOOL)showAlert:(NSString *)message {
  if (!message || message.length == 0) {
    [self log:@"⚠️ showAlert: 弹窗内容不能为空"];
    return NO;
  }
  
  // 当有执行 showAlert 动作指令时，将弹窗内容作为错误信息上报给服务器
  [[ECTaskPollManager sharedManager] reportActionErrorWithMessage:message forCommand:@"wda.showAlert"];

  [self log:[NSString stringWithFormat:@"📢 全局悬浮弹窗: %@", message]];

  CFOptionFlags responseFlags = 0;
  SInt32 result = -1;
  
  // 通过 dlopen 动态加载 CoreFoundation 获取私有 API，防止编译报错
  void *handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
  if (handle) {
      CFUserNotificationDisplayAlert_t displayAlert = (CFUserNotificationDisplayAlert_t)dlsym(handle, "CFUserNotificationDisplayAlert");
      if (displayAlert) {
          result = displayAlert(
              60.0,
              3, // Alert Level
              NULL,
              NULL,
              NULL,
              CFSTR("ECMAIN"),
              (__bridge CFStringRef)message,
              CFSTR("OK"),
              NULL,
              NULL,
              &responseFlags
          );
      } else {
          [self log:@"⚠️ showAlert 错误: 找不到 CFUserNotificationDisplayAlert 函数"];
      }
      dlclose(handle);
  } else {
      [self log:@"⚠️ showAlert 错误: 无法加载 CoreFoundation"];
  }

  if (result != 0 && result != -1) {
    [self log:@"⚠️ showAlert 超时(60s)，悬浮弹窗自动关闭"];
  }

  return YES;
}

// --- Image / Color ---

- (NSDictionary *)findImage:(NSString *)templateB64
                   threshold:(NSNumber *)threshold {
  // ── 截图缓存已提升为文件级静态变量 (sCachedScreenshotB64 / sCachedScreenshotTime / kScreenshotCacheTTL) ──
  // 2 秒内连续多次 findImage 共享同一截图，大幅减少 WDA 请求；超过 2 秒自动重新截图

  if ([self _checkInterrupt])
    return @{@"found" : @NO};

  @autoreleasepool { // 每次调用后立刻释放截图 Base64 等大对象，防止内存堆积

  // === 预处理：剥离 Base64 Data URI 前缀（例如 data:image/png;base64,）===
  NSString *template = templateB64;
  if ([template hasPrefix:@"data:"]) {
    NSRange range = [template rangeOfString:@"base64,"];
    if (range.location != NSNotFound) {
      template = [template substringFromIndex:range.location + range.length];
    }
  }
  template = [template stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

  // === 第 1 步：获取截图（优先复用缓存，500ms 内不重复请求 WDA）===
  NSString *screenshotBase64 = nil;
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();

  if (sCachedScreenshotB64.length > 0 && (now - sCachedScreenshotTime) < kScreenshotCacheTTL) {
    // 缓存命中：直接复用，省去一次 WDA /screenshot 往返
    screenshotBase64 = sCachedScreenshotB64;
  } else {
    // 缓存过期或为空，重新截图
    sCachedScreenshotB64 = nil; // 先主动释放旧截图内存

    int retry = 0;
    while (retry < 2) {
      NSDictionary *screenshotResult = [self performWDAActionWithResult:@"screenshot"
                                                                endpoint:@"/screenshot"
                                                                    body:nil];
      if (screenshotResult[@"value"] && [screenshotResult[@"value"] isKindOfClass:[NSString class]]) {
        screenshotBase64 = screenshotResult[@"value"];
        if (screenshotBase64.length > 0) break;
      }
      retry++;
      if (retry < 2) {
        [self log:@"⚠️ 截图为空(可能系统内存不足)，500ms 后重试..."];
        usleep(500000);
      }
    }

    // 更新缓存
    if (screenshotBase64.length > 0) {
      sCachedScreenshotB64 = screenshotBase64;
      sCachedScreenshotTime = CFAbsoluteTimeGetCurrent();
    }
  }

  if (!screenshotBase64 || screenshotBase64.length == 0) {
    [self log:@"❌ findImage 连续截图失败，跳过本次找图"];
    return @{@"found" : @NO};
  }

  // === 第 2 步：将截图 + 模板发给 /wda/matchImage 做纯 CPU 匹配（无 IPC 风险）===
  __block NSDictionary *result = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    result = [self performWDAActionWithResult:@"matchImage"
                                     endpoint:@"/wda/matchImage"
                                         body:@{
                                           @"screenshot" : screenshotBase64,
                                           @"template" : template ?: @"",
                                           @"threshold" : threshold ?: @0.8
                                         }];
    dispatch_semaphore_signal(sema);
  });

  // 匹配是纯 CPU 运算，5 秒超时足够
  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)));

  if (waitResult != 0) {
    NSLog(@"[ECScriptEngine] ⚠️ findImage 匹配超时(5s)，跳过本次找图");
    [self log:@"⚠️ findImage 匹配超时(5s)，已跳过"];
    return @{@"found" : @NO};
  }

  // === 第 3 步：打印匹配详情（用于辅助调试）===
  NSMutableDictionary *jsResult = [NSMutableDictionary dictionaryWithDictionary:(result ?: @{@"found" : @NO})];
  if (jsResult.count > 0) {
    // [v1738] 修复解析逻辑：处理 WDA 可能返回的嵌套 value 结构
    NSMutableDictionary *finalData = [NSMutableDictionary dictionaryWithDictionary:
        ([jsResult[@"value"] isKindOfClass:[NSDictionary class]] ? jsResult[@"value"] : jsResult)];
    
    BOOL found = [finalData[@"found"] boolValue];
    
    // [v1942] 强制校验坐标，如果 x 与 y 都为 0，视为匹配失败
    if (found) {
        // [v1945修复] WDA 返回的 matchImage 可能直接平铺 x,y，也可能包裹在 rect 中
        NSDictionary *coordDict = [finalData[@"rect"] isKindOfClass:[NSDictionary class]] ? finalData[@"rect"] : finalData;
        if (coordDict[@"x"] && coordDict[@"y"]) {
            float xVal = [coordDict[@"x"] floatValue];
            float yVal = [coordDict[@"y"] floatValue];
            if (xVal == 0 && yVal == 0) {
                found = NO;
                finalData[@"found"] = @NO;
                if ([jsResult[@"value"] isKindOfClass:[NSDictionary class]]) {
                    jsResult[@"value"] = finalData;
                } else {
                    jsResult[@"found"] = @NO;
                }
            }
        }
    }

    double confidence = [finalData[@"confidence"] doubleValue];

    // 透传并打印分辨率信息
    long sW = [finalData[@"screenshotWidth"] longValue];
    long sH = [finalData[@"screenshotHeight"] longValue];
    long tW = [finalData[@"templateWidth"] longValue];
    long tH = [finalData[@"templateHeight"] longValue];

    [self log:[NSString stringWithFormat:@"🔍 找图: %@ (置信度: %.2f, 阈值: %@) "
                                         @"[大图: %ldx%ld, 模板: %ldx%ld]",
                                         found ? @"✅ 成功" : @"❌ 失败",
                                         confidence, threshold ?: @0.8,
                                         sW, sH, tW, tH]];
  }

  // === 第 4 步：兼容老脚本对 res.value.found / res.value.x 的调用格式 ===
  if (!jsResult[@"value"]) {
      NSMutableDictionary *valDict = [NSMutableDictionary dictionary];
      if (jsResult[@"rect"]) {
          valDict[@"rect"] = jsResult[@"rect"];
          // 展开 rect 以便支持 res.value.x 取值
          if ([jsResult[@"rect"] isKindOfClass:[NSDictionary class]]) {
              [valDict addEntriesFromDictionary:jsResult[@"rect"]];
          }
      }
      valDict[@"found"] = jsResult[@"found"] ?: @NO;
      valDict[@"confidence"] = jsResult[@"confidence"] ?: @0;
      jsResult[@"value"] = valDict;
  }

  // [v1955优化] 主动释放过期截图缓存，防止大量 Base64 数据长期驻留内存
  CFAbsoluteTime nowEnd = CFAbsoluteTimeGetCurrent();
  if (sCachedScreenshotB64 && (nowEnd - sCachedScreenshotTime) >= kScreenshotCacheTTL) {
    sCachedScreenshotB64 = nil;
  }

  return jsResult;
  } // @autoreleasepool
}

// [v1956] 供 JS 层主动释放截图缓存内存（在不再需要找图时调用）
- (void)clearScreenshotCache {
  sCachedScreenshotB64 = nil;
  sCachedScreenshotTime = 0;
  [self log:@"🧹 已清理截图缓存，释放内存"];
}

- (BOOL)downloadToAlbum:(NSString *)urlStr {
  if ([self _checkInterrupt]) return NO;
  if (!urlStr || urlStr.length == 0) return NO;

  [self log:[NSString stringWithFormat:@"[Download] 开始下载媒体文件: %@", urlStr]];

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block BOOL success = NO;

  NSURL *url = [NSURL URLWithString:urlStr];
  NSString *fileName = [url lastPathComponent];
  if (!fileName || fileName.length == 0) {
      fileName = @"downloaded_media";
  }

  // 1. 同步下载文件
  NSURLSession *session = [NSURLSession sharedSession];
  NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
      if (error || !location) {
          [self log:[NSString stringWithFormat:@"[Download] 下载失败: %@", error]];
          dispatch_semaphore_signal(sem);
          return;
      }

      // 移动临时文件到缓存目录，因为 location 在 block 结束后会被系统删除
      NSString *tempDir = NSTemporaryDirectory();
      NSString *targetPath = [tempDir stringByAppendingPathComponent:fileName];

      [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
      NSError *moveErr = nil;
      [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:targetPath error:&moveErr];
      if (moveErr) {
          [self log:[NSString stringWithFormat:@"[Download] 移动临时文件失败: %@", moveErr]];
          dispatch_semaphore_signal(sem);
          return;
      }

      NSURL *targetURL = [NSURL fileURLWithPath:targetPath];

      // 2. 请求相册权限
      if (@available(iOS 14, *)) {
          [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
              if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                  [self log:@"[Download] ❌ 没有相册访问权限"];
                  dispatch_semaphore_signal(sem);
                  return;
              }
              [self _processMediaFile:targetURL fileName:fileName semaphore:sem successPtr:&success];
          }];
      } else {
          [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
              if (status != PHAuthorizationStatusAuthorized) {
                  [self log:@"[Download] ❌ 没有相册访问权限"];
                  dispatch_semaphore_signal(sem);
                  return;
              }
              [self _processMediaFile:targetURL fileName:fileName semaphore:sem successPtr:&success];
          }];
      }
  }];

  [task resume];
  // [v1955优化] 消灭 DISPATCH_TIME_FOREVER 死锁风险：下载+相册写入最长等待 120 秒
  long dlWait = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120.0 * NSEC_PER_SEC)));
  if (dlWait != 0) {
    [self log:@"[Download] ⏰ 下载到相册操作超时 (120s)，可能网络异常或相册权限卡住"];
  }

  return success;
}

- (void)_processMediaFile:(NSURL *)targetURL fileName:(NSString *)fileName semaphore:(dispatch_semaphore_t)sem successPtr:(BOOL *)successPtr {
    NSError *phErr = nil;
    
    // 3. 查找并删除同名文件
    PHFetchOptions *options = [[PHFetchOptions alloc] init];
    options.includeHiddenAssets = YES;
    PHFetchResult<PHAsset *> *assets = [PHAsset fetchAssetsWithOptions:options];
    NSMutableArray<PHAsset *> *assetsToDelete = [NSMutableArray array];

    [assets enumerateObjectsUsingBlock:^(PHAsset * _Nonnull asset, NSUInteger idx, BOOL * _Nonnull stop) {
        @try {
            NSString *assetName = [asset valueForKey:@"filename"];
            if ([assetName isEqualToString:fileName]) {
                [assetsToDelete addObject:asset];
            }
        } @catch (NSException *e) {
            // 忽略没有 filename 属性的资产
        }
    }];

    if (assetsToDelete.count > 0) {
        [self log:[NSString stringWithFormat:@"[Download] 👀 发现相册有 %lu 个同名文件(%@)，准备覆盖...", (unsigned long)assetsToDelete.count, fileName]];
        [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
            [PHAssetChangeRequest deleteAssets:assetsToDelete];
        } error:nil];
    }

    // 4. 将新下载的文件存入相册
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        NSString *ext = [[fileName pathExtension] lowercaseString];
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"] || [ext isEqualToString:@"m4v"]) {
            [PHAssetCreationRequest creationRequestForAssetFromVideoAtFileURL:targetURL];
        } else {
            [PHAssetCreationRequest creationRequestForAssetFromImageAtFileURL:targetURL];
        }
    } error:&phErr];

    [[NSFileManager defaultManager] removeItemAtURL:targetURL error:nil];

    if (phErr) {
        [self log:[NSString stringWithFormat:@"[Download] ❌ 保存到相册失败: %@", phErr]];
    } else {
        [self log:@"[Download] ✅ 成功保存最新文件到相册。"];
        *successPtr = YES;
    }

    dispatch_semaphore_signal(sem);
}

- (BOOL)downloadOneTimeMedia:(NSString *)type group:(NSString *)group {
  if ([self _checkInterrupt]) return NO;
  if (![type isEqualToString:@"video"] && ![type isEqualToString:@"image"]) {
      [self log:@"[DownloadOnetime] 错误：仅支持 video 或 image"];
      return NO;
  }

  NSString *cloudUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
  if (!cloudUrl || cloudUrl.length == 0) {
    [self log:@"[DownloadOnetime] 🛑 错误：未检测到云控服务器地址，请先在仪表盘【保存配置】！"];
    return NO;
  }

  NSString *apiPath;
  if (!group || [group isKindOfClass:[NSNull class]] || [group isEqualToString:@"undefined"] || group.length == 0) {
      apiPath = [NSString stringWithFormat:@"%@/api/files/download_onetime/%@", cloudUrl, type];
  } else {
      NSString *encodedGroup = [group stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
      apiPath = [NSString stringWithFormat:@"%@/api/files/download_onetime/%@?group=%@", cloudUrl, type, encodedGroup];
  }
  
  // 决定强覆盖存放的强制文件名
  NSString *fileName = [type isEqualToString:@"video"] ? @"mov1.mp4" : @"t1.jpg";

  [self log:[NSString stringWithFormat:@"[DownloadOnetime] 准备向控制台盲盒抽取一次性 %@ 文件，将物理固化为 %@...", type, fileName]];

  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block BOOL success = NO;

  NSURLSession *session = [NSURLSession sharedSession];
  NSURLSessionDownloadTask *task = [session downloadTaskWithURL:[NSURL URLWithString:apiPath] completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
      if (error || !location) {
          [self log:[NSString stringWithFormat:@"[DownloadOnetime] ❌ 网络抽盒失败: %@", error.localizedDescription]];
          dispatch_semaphore_signal(sem);
          return;
      }
      
      NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
      if (httpResp.statusCode == 404) {
          [self log:@"[DownloadOnetime] ❌ 一次性提取失败：服务器上已经没有库存储备了！"];
          dispatch_semaphore_signal(sem);
          return;
      } else if (httpResp.statusCode != 200) {
          [self log:[NSString stringWithFormat:@"[DownloadOnetime] ❌ API 响应异常: HTTP %ld", (long)httpResp.statusCode]];
          dispatch_semaphore_signal(sem);
          return;
      }

      NSString *tempDir = NSTemporaryDirectory();
      NSString *targetPath = [tempDir stringByAppendingPathComponent:fileName];

      [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
      NSError *moveErr = nil;
      [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:targetPath error:&moveErr];
      if (moveErr) {
          [self log:[NSString stringWithFormat:@"[DownloadOnetime] 移动临时文件受阻: %@", moveErr]];
          dispatch_semaphore_signal(sem);
          return;
      }

      NSURL *targetURL = [NSURL fileURLWithPath:targetPath];

      if (@available(iOS 14, *)) {
          [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelReadWrite handler:^(PHAuthorizationStatus status) {
              if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) {
                  [self log:@"[DownloadOnetime] ❌ 无相册写入权限"];
                  dispatch_semaphore_signal(sem);
                  return;
              }
              [self _processMediaFile:targetURL fileName:fileName semaphore:sem successPtr:&success];
          }];
      } else {
          [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
              if (status != PHAuthorizationStatusAuthorized) {
                  [self log:@"[DownloadOnetime] ❌ 无相册写入权限"];
                  dispatch_semaphore_signal(sem);
                  return;
              }
              [self _processMediaFile:targetURL fileName:fileName semaphore:sem successPtr:&success];
          }];
      }
  }];

  [task resume];
  // [v1955优化] 消灭 DISPATCH_TIME_FOREVER 死锁风险：一次性媒体下载最长等待 120 秒
  long otWait = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120.0 * NSEC_PER_SEC)));
  if (otWait != 0) {
    [self log:@"[DownloadOnetime] ⏰ 一次性媒体下载操作超时 (120s)"];
  }

  return success;
}

- (NSString *)getRandomTag {
  if ([self _checkInterrupt]) return @"";
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *country = [defaults stringForKey:@"EC_DEVICE_COUNTRY"];
  if (!country || country.length == 0) country = @"";
  NSString *cloudUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
  if (!cloudUrl || cloudUrl.length == 0) {
    [self log:@"[getRandomTag] 🛑 错误：未检测到云控服务器地址！"];
    return @"";
  }
  
  NSString *group = [defaults stringForKey:@"EC_DEVICE_GROUP"];
  if (!group || [group isKindOfClass:[NSNull class]]) group = @"";
  
  NSString *encodedCountry = [country stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSString *encodedGroup = [group stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSString *apiPath = [NSString stringWithFormat:@"%@/api/assets/tags/random?country=%@&group_name=%@", cloudUrl, encodedCountry, encodedGroup];
  
  NSURL *url = [NSURL URLWithString:apiPath];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
  
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSString *result = @"";
  [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (data && !error) {
          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          if (json && [json[@"ok"] boolValue]) {
              result = json[@"value"] ?: @"";
          }
      }
      dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
  return result;
}

- (NSString *)getRandomBio {
  if ([self _checkInterrupt]) return @"";
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *country = [defaults stringForKey:@"EC_DEVICE_COUNTRY"];
  if (!country || country.length == 0) country = @"";
  NSString *cloudUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
  if (!cloudUrl || cloudUrl.length == 0) {
    [self log:@"[getRandomBio] 🛑 错误：未检测到云控服务器地址！"];
    return @"";
  }
  
  NSString *group = [defaults stringForKey:@"EC_DEVICE_GROUP"];
  if (!group || [group isKindOfClass:[NSNull class]]) group = @"";
  
  NSString *encodedCountry = [country stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSString *encodedGroup = [group stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSString *apiPath = [NSString stringWithFormat:@"%@/api/assets/bios/random?country=%@&group_name=%@", cloudUrl, encodedCountry, encodedGroup];
  
  NSURL *url = [NSURL URLWithString:apiPath];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:6.0];
  
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSString *result = @"";
  [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
      if (data && !error) {
          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
          if (json && [json[@"ok"] boolValue]) {
              result = json[@"value"] ?: @"";
          }
      }
      dispatch_semaphore_signal(sem);
  }] resume];
  dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
  return result;
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

- (NSDictionary *)findMultiColor:(NSString *)colors sim:(NSNumber *)sim {
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
                                    @"offsetColors" : offsets ?: @[], // [v1769] WDA 期望的键名是 offsetColors
                                    @"similarity" : sim ?: @(0.9)
                                  }];
  
  // [v1770] 强制统一数据结构：使其返回值格式与 findImage 完全一致 (包含 value 嵌套封装)
  NSMutableDictionary *jsResult = [NSMutableDictionary dictionary];
  jsResult[@"found"] = result[@"found"] ?: @NO;
  
  NSMutableDictionary *valDict = [NSMutableDictionary dictionaryWithDictionary:(result ?: @{})];
  valDict[@"found"] = result[@"found"] ?: @NO;
  valDict[@"width"] = result[@"width"] ?: @0;
  valDict[@"height"] = result[@"height"] ?: @0;
  jsResult[@"value"] = valDict;
  
  return jsResult;
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
  // 中断检查：在发起 HTTP 请求前拦截，防止中断信号发出后仍继续执行
  if ([self _checkInterrupt]) {
    [self log:[NSString stringWithFormat:@"🛑 已中断，跳过: %@", name]];
    return @{@"status" : @(-1), @"error" : @"Interrupted by user"};
  }
  NSLog(@"[ECScriptEngine] Executing with result: %@", name);
  [self log:[NSString stringWithFormat:@"Execute: %@", name]];

  NSString *actualEndpoint = endpoint;
  // 路由策略：
  // - /wda/ 前缀的端点默认不加 session（绝大多数都是 withoutSession）
  // - /wda/apps/ 前缀的端点需要 session（launch/activate/terminate/state 均需要 session）
  // - /alert/ 前缀的端点需要 session（有 session 和 withoutSession 双版本）
  // - /wda/alert/ 前缀的端点需要 session（仅有带 session 版本）
  // - /screenshot 等其他端点不需要 session
  if ([endpoint hasPrefix:@"/alert/"] || [endpoint hasPrefix:@"/wda/alert/"] ||
      [endpoint hasPrefix:@"/wda/apps/"]) {
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
  // [v1955优化] HTTP 超时从 120s 收敛到 30s，避免 WDA 半死不活时无限等待
  request.timeoutInterval = 30.0;

  if (body) {
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:nil];
  }

  int retryCount = 0;
  const int maxRetries = 2; // [v1955优化] 从 3 次减为 2 次，减少 WDA 半死状态下的无效阻塞
  __block NSDictionary *resultDict = nil;

  while (retryCount < maxRetries) {
    // 每次重试前检查中断标志
    if ([self _checkInterrupt]) {
      [self log:[NSString stringWithFormat:@"🛑 重试中断，放弃: %@", name]];
      return @{@"status" : @(-1), @"error" : @"Interrupted by user"};
    }
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
              // [v1738] 响应用户需求：不打印 screenshot 的结果（因其 Base64 数据量巨大），
              // 但保留 matchImage 等其他关键动作的结果回显。
              if (![name isEqualToString:@"screenshot"]) {
                [self log:[NSString stringWithFormat:@"%@ 结果: %@", name, resultDict]];
              }
            } else {
              NSString *errorMsg =
                  [NSString stringWithFormat:@"❌ WDA 网络请求失败(%@): %@",
                                             name, error.localizedDescription];
              NSLog(@"[ECScriptEngine] Attempt %d failed (%@): %@",
                    retryCount + 1, name, error.localizedDescription);
              [self log:errorMsg];
            }
            dispatch_semaphore_signal(sema);
          }] resume];

    // [v1955优化] 信号量超时与 HTTP timeoutInterval 对齐（30s + 5s 缓冲 = 35s），避免过长阻塞
    long waitResult = dispatch_semaphore_wait(
        sema,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35.0 * NSEC_PER_SEC)));
    if (waitResult != 0) {
      NSLog(@"[ECScriptEngine] ⏰ WDA 请求信号量超时(60s)，操作: %@", name);
      [self log:[NSString stringWithFormat:@"⏰ WDA 请求超时(60s): %@", name]];
    }

    // 超时后检查中断标志
    if ([self _checkInterrupt]) {
      [self log:[NSString stringWithFormat:@"🛑 信号量恢复后检测到中断: %@", name]];
      return nil;
    }

    if (resultDict)
      break;

    retryCount++;
    if (retryCount < maxRetries) {
      // 优化：重试前先快速探活 WDA（120秒超时），避免对已死进程反复发请求
      __block BOOL wdaAlive = NO;
      dispatch_semaphore_t probeSema = dispatch_semaphore_create(0);
      NSURL *statusURL = [NSURL
          URLWithString:[NSString
                            stringWithFormat:@"http://127.0.0.1:%d/status",
                                             kWDAPort]];
      NSMutableURLRequest *probeReq =
          [NSMutableURLRequest requestWithURL:statusURL];
      probeReq.timeoutInterval = 5.0; // [v1955优化] 探活请求不需要 120s，5 秒足够
      probeReq.HTTPMethod = @"GET";
      [[NSURLSession.sharedSession
          dataTaskWithRequest:probeReq
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
              NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
              wdaAlive = (!error && resp.statusCode == 200);
              dispatch_semaphore_signal(probeSema);
            }] resume];
      // [v1955优化] 探活信号量从 15s 收敛到 8s，快速失败
      long probeWait = dispatch_semaphore_wait(
          probeSema,
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)));
      if (probeWait != 0) {
        NSLog(@"[ECScriptEngine] ⏰ WDA 探活信号量超时(15s)");
        wdaAlive = NO; // 超时视为 WDA 已死
      }

      if (!wdaAlive) {
        NSLog(@"[ECScriptEngine] ⚠️ WDA 探活失败，放弃重试 %@", name);
        [self
            log:[NSString stringWithFormat:@"⚠️ WDA 已崩溃，中断当前脚本: %@", name]];
        // [v1945] WDA 已死 → 立即中断脚本执行，避免后续 WDA 调用继续浪费时间
        [self interruptExecution];
        // 触发 WDA 拉起 (通过 TSApplicationsManager 在主线程执行)
        dispatch_async(dispatch_get_main_queue(), ^{
          id mgr = [NSClassFromString(@"TSApplicationsManager")
              performSelector:@selector(sharedInstance)];
          if (mgr && [mgr respondsToSelector:@selector
                          (openApplicationWithBundleID:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [mgr performSelector:@selector(openApplicationWithBundleID:)
                      withObject:@"com.apple.test.ECService-Runner"];
#pragma clang diagnostic pop
          }
        });
        break;
      }

      // 递增退避间隔：第1次重试等1秒，第2次等2秒
      NSTimeInterval delay = (NSTimeInterval)retryCount;
      [NSThread sleepForTimeInterval:delay];
      NSLog(@"[ECScriptEngine] 正在进行第 %d 次 WDA 重试（等待 %.0fs）...",
            retryCount, delay);
    }
  }

  if (!resultDict) {
    [self log:[NSString
                  stringWithFormat:@"❌ WDA 动作 [%@] 在 %d 次重试后均未响应",
                                   name, maxRetries]];
  }

  return resultDict
             ?: @{@"status" : @(-1), @"error" : @"No response after retries"};
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
  // 中断检查：在发起 HTTP 请求前拦截
  if ([self _checkInterrupt]) {
    [self log:[NSString stringWithFormat:@"🛑 已中断，跳过: %@", name]];
    return NO;
  }
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
  request.timeoutInterval = 15; // [v1955优化] 简单动作 (tap/swipe 等) 从 30s 降到 15s

  if (body) {
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:nil];
  }

  int retryCount = 0;
  const int maxRetries = 2; // [v1955优化] 从 3 次减为 2 次，减少无效阻塞
  __block BOOL isSuccess = NO;

  while (retryCount < maxRetries) {
    // 每次重试前检查中断标志
    if ([self _checkInterrupt]) {
      [self log:[NSString stringWithFormat:@"🛑 重试中断，放弃: %@", name]];
      return NO;
    }
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block BOOL currentAttemptSuccess = NO;

    [[NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response,
                              NSError *error) {
            if (error) {
              NSLog(@"[EC_CMD_LOG] [ECScriptEngine] WDA Attempt %d Error (%@): "
                    @"%@",
                    retryCount + 1, name, error.localizedDescription);
            } else {
              NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
              if (httpResp.statusCode >= 200 && httpResp.statusCode < 300) {
                currentAttemptSuccess = YES;
                NSLog(@"[EC_CMD_LOG] [ECScriptEngine] ========= WDA "
                      @"指令执行结果 =========");
                NSLog(@"[EC_CMD_LOG] [ECScriptEngine] Success (%@): Status %ld",
                      name, (long)httpResp.statusCode);
                NSLog(@"[EC_CMD_LOG] [ECScriptEngine] "
                      @"==================================");
              } else {
                [self
                    log:[NSString
                            stringWithFormat:@"⚠️ WDA 响应异常(%@): HTTP %ld",
                                             name, (long)httpResp.statusCode]];
              }
            }
            dispatch_semaphore_signal(sema);
          }] resume];

    // [v1955优化] 信号量超时与 timeoutInterval 对齐（15s + 5s 缓冲 = 20s）
    long waitResult = dispatch_semaphore_wait(
        sema,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)));
    if (waitResult != 0) {
      NSLog(@"[EC_CMD_LOG] [ECScriptEngine] ⏰ WDA 动作信号量超时(60s): %@", name);
      [self log:[NSString stringWithFormat:@"⏰ WDA 动作超时(60s): %@", name]];
    }

    // 超时后检查中断标志
    if ([self _checkInterrupt]) {
      [self log:[NSString stringWithFormat:@"🛑 动作超时后检测到中断: %@", name]];
      return NO;
    }

    if (currentAttemptSuccess) {
      isSuccess = YES;
      break;
    }

    retryCount++;
    if (retryCount < maxRetries) {
      // [v1945] 重试前快速探活 WDA，确认是否还活着
      __block BOOL wdaAlive = NO;
      dispatch_semaphore_t probeSema = dispatch_semaphore_create(0);
      NSURL *statusURL = [NSURL
          URLWithString:[NSString
                            stringWithFormat:@"http://127.0.0.1:%d/status",
                                             kWDAPort]];
      NSMutableURLRequest *probeReq =
          [NSMutableURLRequest requestWithURL:statusURL];
      probeReq.timeoutInterval = 10.0;
      probeReq.HTTPMethod = @"GET";
      [[NSURLSession.sharedSession
          dataTaskWithRequest:probeReq
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
              NSHTTPURLResponse *resp = (NSHTTPURLResponse *)response;
              wdaAlive = (!error && resp.statusCode == 200);
              dispatch_semaphore_signal(probeSema);
            }] resume];
      long probeWait = dispatch_semaphore_wait(
          probeSema,
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)));
      if (probeWait != 0) wdaAlive = NO;

      if (!wdaAlive) {
        NSLog(@"[ECScriptEngine] ⚠️ WDA 探活失败(简单动作)，中断脚本: %@", name);
        [self log:[NSString stringWithFormat:@"⚠️ WDA 已崩溃，中断当前脚本: %@", name]];
        [self interruptExecution];
        break;
      }
      [NSThread sleepForTimeInterval:1.0];
      NSLog(@"[ECScriptEngine] 正在进行第 %d 次 WDA 重试...", retryCount);
    }
  }

  if (!isSuccess) {
    [self
        log:[NSString
                stringWithFormat:@"❌ WDA 动作 [%@] 最终执行失败 (重试 %d 次)",
                                 name, maxRetries]];
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

  // [v1955优化] 消灭 DISPATCH_TIME_FOREVER 死锁风险：评论同步最长等待 60 秒
  long syncWait = dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)));
  if (syncWait != 0) {
    [self log:@"⏰ 评论数据同步超时 (60s)"];
  }
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

    NSString *cloudUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
    if (!cloudUrl || cloudUrl.length == 0) {
      [self log:@"[getRandomComment] 🛑 错误：未检测到云控服务器地址！"];
      return @"";
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

#pragma mark - TikTok 主账号数据读取

// 从 NSUserDefaults (App Group) 中读取主账号数据（JSON 数组首元素）
// 后端按 is_primary DESC, id ASC 排序，主账号排首位；若无主账号则默认取第一个
- (NSDictionary *)_getMasterTkAccountDict {
  NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *json = [defaults stringForKey:@"EC_TIKTOK_ACCOUNTS"] ?: @"[]";
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  NSArray *accounts = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![accounts isKindOfClass:[NSArray class]] || accounts.count == 0) {
    return nil;
  }
  // 首元素即为主账号（有 is_primary 标记的排最前），若无主账号则自动降级为第一个
  return accounts.firstObject;
}

// 将文本写入系统剪切板
- (void)_copyToPasteboard:(NSString *)text {
  dispatch_async(dispatch_get_main_queue(), ^{
    [UIPasteboard generalPasteboard].string = text;
  });
  // 主线程异步执行，给一点时间让剪切板生效
  [NSThread sleepForTimeInterval:0.1];
}

- (NSString *)getMasterTkAccount {
  NSDictionary *master = [self _getMasterTkAccountDict];
  if (!master) {
    [self log:@"⚠️ 未找到 TikTok 主账号数据，请先在配置中心绑定账号"];
    return @"";
  }
  NSString *account = master[@"account"] ?: @"";
  if (account.length == 0) {
    [self log:@"⚠️ TikTok 主账号用户名为空"];
    return @"";
  }
  [self _copyToPasteboard:account];
  [self log:[NSString stringWithFormat:@"📋 TikTok 主账号已写入剪切板: %@", account]];
  return account;
}

- (NSString *)getMasterTkPassword {
  NSDictionary *master = [self _getMasterTkAccountDict];
  if (!master) {
    [self log:@"⚠️ 未找到 TikTok 主账号数据，请先在配置中心绑定账号"];
    return @"";
  }
  NSString *password = master[@"password"] ?: @"";
  if (password.length == 0) {
    [self log:@"⚠️ TikTok 主账号密码为空"];
    return @"";
  }
  [self _copyToPasteboard:password];
  [self log:@"📋 TikTok 主账号密码已写入剪切板 (已隐藏明文)"];
  return password;
}

- (NSString *)getMasterTkEmail {
  NSDictionary *master = [self _getMasterTkAccountDict];
  if (!master) {
    [self log:@"⚠️ 未找到 TikTok 主账号数据，请先在配置中心绑定账号"];
    return @"";
  }
  NSString *email = master[@"email"] ?: @"";
  if (email.length == 0) {
    [self log:@"⚠️ TikTok 主账号邮箱为空"];
    return @"";
  }
  [self _copyToPasteboard:email];
  [self log:[NSString stringWithFormat:@"📋 TikTok 主账号邮箱已写入剪切板: %@", email]];
  return email;
}

#pragma mark - 立即同步配置

- (BOOL)syncConfig {
  [self log:@"🔄 正在向服务器拉取最新配置..."];

  // 直接调用 ECBackgroundManager 的心跳发送方法
  // 心跳响应中会自动解析 push_config 并更新 NSUserDefaults
  [[ECBackgroundManager sharedManager] sendHeartbeat:nil];

  // 等待心跳请求完成（心跳是异步的，给 3 秒等待响应）
  [NSThread sleepForTimeInterval:3.0];

  [self log:@"✅ 配置同步请求已完成，本地配置已刷新"];
  return YES;
}

#pragma mark - 下载 IPA 文件

- (BOOL)downloadIPA:(NSString *)url {
  if (!url || url.length == 0) {
    [self log:@"⚠️ downloadIPA 缺少 URL 参数"];
    return NO;
  }

  [self log:[NSString stringWithFormat:@"📥 开始下载 IPA: %@", url]];

  NSURL *downloadURL = [NSURL URLWithString:url];
  if (!downloadURL) {
    [self log:@"❌ 无效的 URL 格式"];
    return NO;
  }

  // 目标目录：Documents/ImportedIPAs/（与应用管理已下载列表一致）
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *importDir = [docsDir stringByAppendingPathComponent:@"ImportedIPAs"];

  // 确保目录存在
  if (![[NSFileManager defaultManager] fileExistsAtPath:importDir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:importDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  // 同步下载（信号量阻塞，最长等待 120 秒）
  __block BOOL success = NO;
  __block NSString *savedPath = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
  config.timeoutIntervalForRequest = 120;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

  NSURLSessionDownloadTask *task = [session downloadTaskWithURL:downloadURL
      completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
          [self log:[NSString stringWithFormat:@"❌ 下载失败: %@", error.localizedDescription]];
          dispatch_semaphore_signal(sema);
          return;
        }

        if (!location) {
          [self log:@"❌ 下载完成但文件不存在"];
          dispatch_semaphore_signal(sema);
          return;
        }

        // 从 URL 路径或响应头取文件名
        NSString *filename = response.suggestedFilename;
        if (!filename || filename.length == 0) {
          filename = downloadURL.lastPathComponent;
        }
        if (!filename || filename.length == 0) {
          filename = @"downloaded.ipa";
        }
        // 确保 .ipa 后缀
        if (![[filename pathExtension] isEqualToString:@"ipa"]) {
          filename = [filename stringByAppendingString:@".ipa"];
        }

        NSString *destPath = [importDir stringByAppendingPathComponent:filename];

        // 自动去重
        int idx = 1;
        while ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
          destPath = [importDir stringByAppendingPathComponent:
              [NSString stringWithFormat:@"%@_%d.ipa",
                  [filename stringByDeletingPathExtension], idx++]];
        }

        NSError *moveError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:destPath]
                                                error:&moveError];
        if (moveError) {
          [self log:[NSString stringWithFormat:@"❌ 文件保存失败: %@", moveError.localizedDescription]];
        } else {
          savedPath = destPath;
          success = YES;
          [self log:[NSString stringWithFormat:@"✅ IPA 已下载至: %@", destPath.lastPathComponent]];
        }

        dispatch_semaphore_signal(sema);
      }];

  [task resume];

  // 最长等待 120 秒
  long waitResult = dispatch_semaphore_wait(sema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(120.0 * NSEC_PER_SEC)));

  if (waitResult != 0) {
    [task cancel];
    [self log:@"⚠️ downloadIPA 超时(120s)，已取消下载"];
    return NO;
  }

  return success;
}

#pragma mark - 自动化注入安装 IPA（远程脚本调用，无 UI）

/// 在 ImportedIPAs 目录中按文件名搜索 IPA（精确匹配 → 模糊匹配）
- (NSString *)findIPAByName:(NSString *)filename {
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *importDir =
      [docsDir stringByAppendingPathComponent:@"ImportedIPAs"];
  NSFileManager *fm = [NSFileManager defaultManager];

  if (![fm fileExistsAtPath:importDir]) {
    [self log:@"⚠️ ImportedIPAs 目录不存在"];
    return nil;
  }

  NSArray *files = [fm contentsOfDirectoryAtPath:importDir error:nil];
  if (!files || files.count == 0) {
    [self log:@"⚠️ ImportedIPAs 目录为空"];
    return nil;
  }

  // 精确匹配（完整文件名）
  for (NSString *file in files) {
    if ([file isEqualToString:filename]) {
      return [importDir stringByAppendingPathComponent:file];
    }
  }

  // 模糊匹配（文件名包含搜索关键字，忽略大小写）
  NSString *lowerFilename = [filename lowercaseString];
  for (NSString *file in files) {
    if ([[file lowercaseString] containsString:lowerFilename] &&
        [[file pathExtension] isEqualToString:@"ipa"]) {
      [self log:[NSString stringWithFormat:@"📎 模糊匹配到: %@", file]];
      return [importDir stringByAppendingPathComponent:file];
    }
  }

  return nil;
}

/// 将伪装参数写入 App Bundle 的 Frameworks/com.apple.preferences.display.plist
- (void)writeSpoofConfig:(NSDictionary *)spoofConfig
      toWorkingDirectory:(NSString *)workingDir {
  // 定位 Payload/*.app 路径
  NSString *payloadPath =
      [workingDir stringByAppendingPathComponent:@"Payload"];
  NSArray *contents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadPath
                                                          error:nil];
  NSString *appBundleName = nil;
  for (NSString *item in contents) {
    if ([item.pathExtension isEqualToString:@"app"]) {
      appBundleName = item;
      break;
    }
  }
  if (!appBundleName) {
    [self log:@"⚠️ 未找到 .app 目录，跳过伪装配置写入"];
    return;
  }

  NSString *appPath =
      [payloadPath stringByAppendingPathComponent:appBundleName];
  NSString *frameworksDir =
      [appPath stringByAppendingPathComponent:@"Frameworks"];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:frameworksDir]) {
    [fm createDirectoryAtPath:frameworksDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  NSString *configPath = [appPath
      stringByAppendingPathComponent:
          @"Frameworks/com.apple.preferences.display.plist"];
  [spoofConfig writeToFile:configPath atomically:YES];
  [self log:[NSString stringWithFormat:@"📝 伪装配置已写入: %@",
                                       configPath.lastPathComponent]];
}

- (NSDictionary *)installIPA:(NSDictionary *)config {
  if (!config || ![config isKindOfClass:[NSDictionary class]]) {
    [self log:@"❌ installIPA: 参数无效"];
    return @{@"success" : @NO, @"error" : @"参数无效"};
  }

  NSString *filename = config[@"filename"];
  // 克隆模式 1: 分身编号（自动生成 BundleID 和显示名称）
  NSString *cloneNumber = config[@"clone_number"] ?: @"0";
  // 克隆模式 2: 高级手动指定（优先级高于 clone_number）
  NSString *manualBundleId = config[@"custom_bundle_id"];
  NSString *manualDisplayName = config[@"custom_display_name"];
  // 伪装参数字典（键值与 ECDeviceInfoManager 一致）
  NSDictionary *spoofConfig = config[@"spoof_config"];

  if (!filename || filename.length == 0) {
    [self log:@"❌ installIPA: 缺少 filename 参数"];
    return @{@"success" : @NO, @"error" : @"缺少 filename 参数"};
  }

  [self log:[NSString stringWithFormat:@"📦 开始自动化注入安装: %@", filename]];

  // 1. 搜索 IPA 文件
  NSString *ipaPath = [self findIPAByName:filename];
  if (!ipaPath) {
    [self
        log:[NSString stringWithFormat:@"❌ 未找到匹配的 IPA: %@", filename]];
    return @{@"success" : @NO, @"error" : @"未找到匹配的 IPA 文件"};
  }
  [self log:[NSString stringWithFormat:@"✅ 找到 IPA: %@",
                                       ipaPath.lastPathComponent]];

  // 2. 预解压 IPA 到临时目录
  ECAppInjector *injector = [ECAppInjector sharedInstance];
  NSError *error = nil;
  NSString *tempDir = [injector extractIPAToTemp:ipaPath error:&error];
  if (!tempDir) {
    NSString *errMsg =
        error.localizedDescription ?: @"IPA 解压失败";
    [self log:[NSString stringWithFormat:@"❌ 解压失败: %@", errMsg]];
    return @{@"success" : @NO, @"error" : errMsg};
  }
  [self log:@"✅ IPA 解压完成"];

  // 3. 读取原始应用信息
  NSDictionary *info = [injector getAppInfoFromBundlePath:tempDir];
  NSString *originalBundleId = info[@"CFBundleIdentifier"] ?: @"com.unknown";
  NSString *originalName =
      info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"App";
  [self log:[NSString stringWithFormat:@"📋 原始 BundleID=%@, 名称=%@",
                                       originalBundleId, originalName]];

  // 4. 生成克隆参数
  //    优先使用手动指定的 custom_bundle_id，否则按 clone_number 自动生成
  NSString *customBundleId = nil;
  NSString *customDisplayName = nil;

  if (manualBundleId.length > 0) {
    // 高级模式：手动指定完整的 BundleID 和显示名称
    customBundleId = manualBundleId;
    customDisplayName = manualDisplayName.length > 0 ? manualDisplayName : originalName;
    [self log:[NSString stringWithFormat:@"🔧 高级克隆: BundleID=%@, 名称=%@",
                                         customBundleId, customDisplayName]];
  } else if ([cloneNumber integerValue] > 0) {
    // 分身编号模式：自动追加编号
    // com.zhiliaoapp.musically → com.zhiliaoapp.musically8
    customBundleId =
        [originalBundleId stringByAppendingString:cloneNumber];
    // TikTok → TikTok 8
    customDisplayName =
        [originalName stringByAppendingFormat:@" %@", cloneNumber];
    [self log:[NSString stringWithFormat:@"🔄 分身配置 #%@: BundleID=%@, 名称=%@",
                                         cloneNumber, customBundleId, customDisplayName]];
  } else {
    [self log:@"ℹ️ 保持原 App 信息（不分身）"];
  }


  // 5. 执行注入（Dylib 注入 + 签名处理 + 默认配置生成）
  //    注意：prepareIPAForInjection 内部会自动生成包含所有 Hook 开关的完整配置
  //    伪装参数必须在注入完成之后再覆盖写入，否则会被 injector 内部逻辑覆盖
  [self log:@"⚙️ 正在注入 Dylib..."];
  NSString *preparedPath = [injector prepareIPAForInjection:ipaPath
                                               manualTeamID:nil
                                             customBundleId:customBundleId
                                          customDisplayName:customDisplayName
                                           workingDirectory:tempDir
                                                      error:&error];
  if (!preparedPath) {
    NSString *errMsg = error.localizedDescription ?: @"注入准备失败";
    [self log:[NSString stringWithFormat:@"❌ 注入失败: %@", errMsg]];
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
    return @{@"success" : @NO, @"error" : errMsg};
  }
  [self log:@"✅ Dylib 注入完成"];

  // 6. 合并或覆盖伪装配置（在注入之后、安装之前）
  //    prepareIPAForInjection 会生成默认包含所有 Hook 开启的配置。
  //    如果用户传入了 spoofConfig，我们就合并并开启伪装；

  // 6. 合并或覆盖伪装配置（在注入之后、安装之前）
  //    prepareIPAForInjection 会生成默认包含所有 Hook 开启的配置。
  //    如果用户传入了 spoofConfig，我们就合并并开启伪装；
  //    如果未传入（ spoofConfig为空 ），我们认为是"仅克隆不伪装"模式，必须显式覆盖写入全为@NO的配置以关闭所有Hook。
  
  NSString *configPath = [preparedPath
      stringByAppendingPathComponent:
          @"Frameworks/com.apple.preferences.display.plist"];
  NSMutableDictionary *existingConfig =
      [NSMutableDictionary dictionaryWithContentsOfFile:configPath];
  if (!existingConfig) {
    existingConfig = [NSMutableDictionary dictionary];
  }

  if (spoofConfig && [spoofConfig isKindOfClass:[NSDictionary class]] &&
      spoofConfig.count > 0) {
    // 6.1 伪装模式：使用用户指定的参数覆盖，并开启必须的 Hook 开关
    for (NSString *key in spoofConfig) {
      id value = spoofConfig[key];
      if ([value isKindOfClass:[NSNumber class]]) {
        existingConfig[key] = value;
      } else {
        existingConfig[key] = [value description];
      }
    }
    // 强制开启所有伪装 Hook
    NSDictionary *defaultFlags = @{
      @"enableMethodSwizzling" : @YES,
      @"enableSysctlHooks" : @YES,
      @"enableNSCFLocaleHooks" : @YES,
      @"enableCFLocaleHooks" : @YES,
      @"enableTikTokHooks" : @YES,
      @"enableMobileGestaltHooks" : @YES,
      @"enableNetworkHooks" : @YES,
      @"enableCFBundleFishhook" : @YES,
      @"enableISASwizzling" : @YES,
      @"enableAntiDetectionHooks" : @YES,
      @"enableKeychainIsolation" : @YES,
      @"enableForkHooks" : @YES,
      @"enableBundleIDHook" : @YES,
      @"enableCanOpenURLHook" : @YES,
    };
    [existingConfig addEntriesFromDictionary:defaultFlags];
    [self log:[NSString stringWithFormat:
        @"📝 启用设备伪装 (%lu 项覆盖, 总 %lu 项)",
        (unsigned long)spoofConfig.count,
        (unsigned long)existingConfig.count]];
  } else {
    // 6.2 仅克隆不伪装模式：关闭所有 Hook 开关
    NSArray *allHookKeys = @[
      @"enableMethodSwizzling", @"enableSysctlHooks", @"enableNSCFLocaleHooks",
      @"enableCFLocaleHooks", @"enableTikTokHooks", @"enableMobileGestaltHooks",
      @"enableNetworkHooks", @"enableCFBundleFishhook", @"enableISASwizzling",
      @"enableAntiDetectionHooks", @"enableKeychainIsolation", @"enableForkHooks",
      @"enableBundleIDHook", @"enableCanOpenURLHook"
    ];
    for (NSString *key in allHookKeys) {
      existingConfig[key] = @NO;
    }
    [self log:@"📝 仅克隆安装（已自动关闭所有设备伪装 Hook）"];
  }

  // 写入配置（安全写入支持 Root）
  if (![existingConfig writeToFile:configPath atomically:YES]) {
    NSData *plistData = [NSPropertyListSerialization
        dataWithPropertyList:existingConfig
                      format:NSPropertyListXMLFormat_v1_0
                     options:0
                       error:nil];
    if (plistData) {
      NSString *tempPlist = [NSTemporaryDirectory()
          stringByAppendingPathComponent:@"spoof_temp.plist"];
      [plistData writeToFile:tempPlist atomically:YES];
      spawnRoot(rootHelperPath(), @[ @"copy-file", tempPlist, configPath ],
                nil, nil);
      spawnRoot(rootHelperPath(), @[ @"chmod-file", @"644", configPath ], nil,
                nil);
      [[NSFileManager defaultManager] removeItemAtPath:tempPlist error:nil];
    }
  }

  // 7. 系统安装（与 ECAppListViewController 调用方式完全一致）
  [self log:@"📲 正在安装到系统..."];
  int ret = [[TSApplicationsManager sharedInstance]
             installIpa:preparedPath
                  force:YES
       registrationType:@"System"
         customBundleId:nil
      customDisplayName:nil
            skipSigning:NO
                    log:nil];

  // 8. 清理临时目录
  [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];

  if (ret == 0) {
    [self log:@"✅ 注入并安装成功！"];
    return @{@"success" : @YES, @"error" : @""};
  } else {
    NSString *errMsg =
        [NSString stringWithFormat:@"安装失败 (错误码: %d)", ret];
    [self log:[NSString stringWithFormat:@"❌ %@", errMsg]];
    return @{@"success" : @NO, @"error" : errMsg};
  }
}

@end
