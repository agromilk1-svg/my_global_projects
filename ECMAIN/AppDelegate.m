#import "AppDelegate.h"
#import "ECMAIN/Core/ECKeepAlive.h"
#import "ECMAIN/UI/MainTabBarController.h"
#import "Network/ECNetworkManager.h"
#import "Network/ECWebServer.h"
#import "ViewController.h"

#import "ECMAIN/Core/ECBackgroundManager.h"
#import "ECMAIN/Core/ECLogManager.h"
#import "ECMAIN/Core/ECOneshotTaskManager.h"
#import "ECMAIN/Core/ECTaskPollManager.h"
#import "Shared/TSUtil.h" // for spawnRoot & rootHelperPath

@interface AppDelegate ()
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
  self.window.rootViewController = [[MainTabBarController alloc] init];
  [self.window makeKeyAndVisible];

  // 启动网络任务轮询 (Active Mode)
  [[ECNetworkManager sharedManager] startPolling];

  // 启动被动监听服务 (Passive Mode)
  // 监听端口 8089 (避免与 WDA 8100 冲突)
  [[ECWebServer sharedServer] startServerWithPort:8089];

  // 启动保活
  [[ECKeepAlive sharedInstance] start];

  // 初始化 Background Manager (触发 VPN Setup)
  [[ECBackgroundManager sharedManager] startCloudHeartbeat];

  // 启动自动动作脚本获取轮询引擎
  [[ECTaskPollManager sharedManager] startPolling];

  // 启动一次性任务轮询 (最高优先级，90 秒周期)
  [[ECOneshotTaskManager sharedManager] startPolling];

  // 确保日志文件夹可见
  [[ECLogManager sharedManager] syncToDocuments];

  // 自动刷新应用注册 (恢复 System 权限) - 后台执行避免阻塞启动
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *helperPath = rootHelperPath();
        if (helperPath &&
            [[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
          int result = spawnRoot(helperPath, @[ @"refresh" ], nil, nil);
          NSLog(@"[ECMAIN] Refreshed app registrations on launch (result: %d)",
                result);
        } else {
          NSLog(@"[ECMAIN] RootHelper not found, skipping app registration "
                @"refresh");
        }
      });

  // --- 随版本更新自动拉取最新全集评论数据 ---
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
    NSString *currentVersion =
        [[NSBundle mainBundle] infoDictionary][@"CFBundleShortVersionString"];
    NSString *currentBuild =
        [[NSBundle mainBundle] infoDictionary][(NSString *)kCFBundleVersionKey];
    NSString *fullVersionStr =
        [NSString stringWithFormat:@"%@.%@", currentVersion, currentBuild];

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *lastSyncedVersion =
        [defaults stringForKey:@"EC_LAST_COMMENTS_SYNC_VERSION"];

    if (![lastSyncedVersion isEqualToString:fullVersionStr]) {
      NSLog(@"[ECMAIN] 检测到 App 安装/更新 (%@ -> "
            @"%@)，开始静默桥接并缓存最新全部评论...",
            lastSyncedVersion ?: @"(首次)", fullVersionStr);

      NSUserDefaults *groupDefaults =
          [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
      NSString *cloudUrl = [groupDefaults stringForKey:@"EC_CLOUD_SERVER_URL"];
      if (!cloudUrl || cloudUrl.length == 0) {
        cloudUrl = @"http://s.ecmain.site:8088";
        NSLog(@"[ECMAIN_ERR] 未能在组字典读取到有效的 EC_CLOUD_SERVER_URL "
              @"(用户可能尚未按【保存配置】或【连接云控】)"
              @"。本次同步将使用默认域名: %@，可能导致后续网络超时失败！",
              cloudUrl);
        [[ECLogManager sharedManager]
            log:@"⚠️ "
                @"云控地址为空，本地评论字典同步使用了公网兜底连线，如请求失败"
                @"请手动运行一次 [同步全量评论] 或连接一次内网！"];
      } else {
        NSLog(@"[ECMAIN] 获取到本地主控端组网络地址: %@", cloudUrl);
      }
      // 由于云端拉取评论的接口固定在 /api/comments
      NSString *commentsUrl =
          [cloudUrl stringByAppendingString:@"/api/comments"];
      NSLog(@"[ECMAIN] 执行 commentsUrl: %@", commentsUrl);

      BOOL ok = [[[NSClassFromString(@"ECScriptParser") alloc] init]
          performSelector:@selector(syncCommentsFromServer:)
               withObject:commentsUrl];

      if (ok) {
        [defaults setObject:fullVersionStr
                     forKey:@"EC_LAST_COMMENTS_SYNC_VERSION"];
        [defaults synchronize];
        [[ECLogManager sharedManager]
            log:[NSString
                    stringWithFormat:
                        @"[ECMAIN 数据中心] 自驱更新完毕，全量语料已入库。"]];
      } else {
        NSLog(@"[ECMAIN_ERR] syncCommentsFromServer "
              @"远端网络请求响应了失败或内部 JSON 错误。");
      }
    }
  });

  return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
  NSLog(@"[ECMAIN] Entered Background");

  // 立即确保保活体系被激活（麦克风录音 + 静音播放）
  [[ECBackgroundManager sharedManager] ensureBackgroundNetworkAlive];

  // BUILD #402: 无限递归 BackgroundTask 续命链
  // 每次到期前立即申请新 Task，确保进程永远有有效的后台执行权
  [self registerInfiniteBackgroundTask];
}

// BUILD #402: 递归式后台任务续命（参考 ECKeepAlive 的经典模式）
- (void)registerInfiniteBackgroundTask {
  UIApplication *app = [UIApplication sharedApplication];
  __block UIBackgroundTaskIdentifier oldTask = self.bgTaskId;

  self.bgTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
    NSLog(@"[ECMAIN] Background Task Expiring, re-registering (infinite "
          @"chain)...");
    // 递归续命：到期前再申请新 Task
    [self registerInfiniteBackgroundTask];
  }];

  // 结束旧 Task（如果存在）
  if (oldTask != UIBackgroundTaskInvalid) {
    [app endBackgroundTask:oldTask];
  }

  if (self.bgTaskId == UIBackgroundTaskInvalid) {
    NSLog(@"[ECMAIN] ❌ Failed to start background task!");
  } else {
    NSLog(@"[ECMAIN] ✅ Background Task Registered (Remaining: %.1f sec)",
          app.backgroundTimeRemaining);
  }
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
  NSLog(@"[ECMAIN] Will Enter Foreground - 触发全链路保活自检");
  
  // 延迟 1s 待 SpringBoard 稳定后操作
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      // 【保活加固】检查网络和后台保活
      [[ECBackgroundManager sharedManager] ensureBackgroundNetworkAlive];
      
      // [修复端口假死] 通过内存状态判断，避免 connect 导致的沙盒闪退风险
      if (![[ECWebServer sharedServer] isPortActive]) {
          NSLog(@"[ECMAIN] ⚠️ 检测到 8089 端口监听已失效，正在为您重启服务...");
          [[ECWebServer sharedServer] restartOnPort:8089];
      }
  });
}

@end
