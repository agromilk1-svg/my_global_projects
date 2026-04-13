/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIDevice+FBHealthCheck.h"

#import "XCUIDevice+FBRotation.h"
#import "XCUIApplication+FBHelpers.h"
#import "FBUnattachedAppLauncher.h"
#import "FBConfiguration.h"

// ============ ECMAIN 保活探测计数器 ============
static NSInteger _ecmainFailureCount = 0;
static NSTimeInterval _lastEcmainLaunchTime = 0;

// ============ WDA 管道看门狗（自检） ============
// 连续自检失败次数（每次自检 = 向自身 10088 发 /health 请求）
static NSInteger _wdaPipelineFailureCount = 0;
// 自检超时阈值（秒），应远小于 ECMAIN 的 30s WDA 超时
static const NSTimeInterval kWDASelfCheckTimeout = 8.0;
// 连续失败多少次触发自杀重启
static const NSInteger kWDAPipelineMaxFailures = 2;
// 自检间隔（秒）
static const NSTimeInterval kWDASelfCheckInterval = 20.0;
// 自检首次启动延迟（秒），等待 WDA HTTP 服务器完全初始化
static const NSTimeInterval kWDASelfCheckInitialDelay = 45.0;

@implementation XCUIDevice (FBHealthCheck)

+ (void)load
{
  // ===== 1. ECMAIN 保活定时器（原有逻辑，30s 一次） =====
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [NSTimer scheduledTimerWithTimeInterval:30.0
                                    repeats:YES
                                      block:^(NSTimer * _Nonnull timer) {
      [self fb_checkEcmainHealth];
    }];
  });

  // ===== 2. WDA 管道看门狗（自检定时器） =====
  // 在后台队列启动，避免干扰主队列
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWDASelfCheckInitialDelay * NSEC_PER_SEC)),
                 dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
    [self fb_startWDAPipelineWatchdog];
  });
}

#pragma mark - ECMAIN 保活探测（ECWDA → ECMAIN via 8089）

+ (void)fb_checkEcmainHealth
{
  NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8089/ping"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"GET";
  request.timeoutInterval = 10.0;

  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    @synchronized (self) {
      if (error || httpResponse.statusCode != 200) {
        _ecmainFailureCount++;
        NSLog(@"[ECWDA] ECMAIN health check failed (%ld/3): %@", (long)_ecmainFailureCount, error.localizedDescription ?: @"Invalid Status Code");

        if (_ecmainFailureCount >= 3) {
          [self fb_relaunchEcmain];
        }
      } else {
        if (_ecmainFailureCount > 0) {
          NSLog(@"[ECWDA] ECMAIN health recovered.");
        }
        _ecmainFailureCount = 0;
      }
    }
  }] resume];
}

+ (void)fb_relaunchEcmain
{
  @synchronized (self) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastEcmainLaunchTime < 60.0) {
      NSLog(@"[ECWDA] ECMAIN relaunch skipped (cooldown active).");
      return;
    }

    _lastEcmainLaunchTime = now;
    _ecmainFailureCount = 0;
  }

  NSLog(@"[ECWDA] Attempting to relaunch ECMAIN (com.ecmain.app)...");
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL launched = [FBUnattachedAppLauncher launchAppInBackgroundWithBundleId:@"com.ecmain.app"];
    NSLog(@"[ECWDA] ECMAIN relaunch result: %@", launched ? @"SUCCESS" : @"FAILED");
  });
}

#pragma mark - WDA 管道看门狗（自检 + 自杀重启）

/**
 * 启动 WDA 看门狗定时循环。
 *
 * 原理：在后台队列定时向自身 HTTP 服务器（10088 /health）发送请求。
 * - HTTP 路由处理在 main_queue 上串行执行（见 FBWebServer.m setRouteQueue:dispatch_get_main_queue()）
 * - 如果 main_queue 被阻塞（截图 IPC 死锁等），/health 请求就无法返回
 * - 自检请求从后台队列发出、在后台队列等结果，因此不会被同样的死锁阻塞
 * - 连续 N 次超时 → 判定主线程管道死锁 → exit(1) 自杀，让 ECMAIN 重新拉起 ECWDA
 */
+ (void)fb_startWDAPipelineWatchdog
{
  NSLog(@"[ECWDA] 🐕 WDA 管道看门狗已启动 (间隔=%.0fs, 超时=%.0fs, 最大容忍=%ld次)",
        kWDASelfCheckInterval, kWDASelfCheckTimeout, (long)kWDAPipelineMaxFailures);

  // 使用 GCD timer 而非 NSTimer，因为 NSTimer 依附在 RunLoop 上，
  // 而我们需要在独立的后台队列运行，不受主队列阻塞影响
  dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(timer,
                            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWDASelfCheckInterval * NSEC_PER_SEC)),
                            (uint64_t)(kWDASelfCheckInterval * NSEC_PER_SEC),
                            (uint64_t)(1.0 * NSEC_PER_SEC)); // 1s 容差

  dispatch_source_set_event_handler(timer, ^{
    [self fb_performWDAPipelineSelfCheck];
  });

  dispatch_resume(timer);

  // 保持 timer 引用，防止被释放
  // 使用关联对象绑定到 XCUIDevice 类上
  static dispatch_source_t _watchdogTimer;
  _watchdogTimer = timer;
}

/**
 * 执行一次 WDA 管道自检。
 * 向自身 10088 /health 发 GET，等待最多 kWDASelfCheckTimeout 秒。
 */
+ (void)fb_performWDAPipelineSelfCheck
{
  // 构造自检请求 URL（使用当前 WDA 的实际监听端口）
  NSUInteger wdaPort = FBConfiguration.bindingPortRange.location;
  NSString *urlStr = [NSString stringWithFormat:@"http://127.0.0.1:%lu/health", (unsigned long)wdaPort];
  NSURL *url = [NSURL URLWithString:urlStr];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"GET";
  request.timeoutInterval = kWDASelfCheckTimeout;

  // 使用独立的 ephemeral session，不与主 WDA session 共享连接池
  NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  config.timeoutIntervalForRequest = kWDASelfCheckTimeout;
  config.timeoutIntervalForResource = kWDASelfCheckTimeout;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

  // 同步等待（在后台队列，不会阻塞 UI）
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  __block BOOL selfCheckOK = NO;

  [[session dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (!error && httpResponse.statusCode == 200) {
      selfCheckOK = YES;
    }
    dispatch_semaphore_signal(sema);
  }] resume];

  long waitResult = dispatch_semaphore_wait(sema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kWDASelfCheckTimeout + 2.0) * NSEC_PER_SEC)));

  if (waitResult != 0) {
    // semaphore 本身超时（不应该发生，因为 NSURLSession 内部也有超时）
    selfCheckOK = NO;
  }

  // 清理 session
  [session invalidateAndCancel];

  // ========== 判定结果 ==========
  @synchronized (self) {
    if (selfCheckOK) {
      // 管道正常：重置计数器
      if (_wdaPipelineFailureCount > 0) {
        NSLog(@"[ECWDA] 🐕 WDA 管道自检恢复正常 (之前连续失败 %ld 次)", (long)_wdaPipelineFailureCount);
      }
      _wdaPipelineFailureCount = 0;
    } else {
      // 管道异常：计数器 +1
      _wdaPipelineFailureCount++;
      NSLog(@"[ECWDA] 🐕⚠️ WDA 管道自检失败 (%ld/%ld) — 主线程可能被 XCTest IPC 死锁阻塞",
            (long)_wdaPipelineFailureCount, (long)kWDAPipelineMaxFailures);

      if (_wdaPipelineFailureCount >= kWDAPipelineMaxFailures) {
        NSLog(@"[ECWDA] 🐕💀 WDA 管道连续 %ld 次自检失败，判定为死锁！执行 exit(1) 自杀重启...",
              (long)kWDAPipelineMaxFailures);
        // exit(1): ECMAIN 的 10088 探测会发现端口不通，
        // 触发 fb_relaunchEcwda 流程重新拉起 ECWDA
        exit(1);
      }
    }
  }
}

@end
