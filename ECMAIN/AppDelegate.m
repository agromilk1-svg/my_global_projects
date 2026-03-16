#import "AppDelegate.h"
#import "ECMAIN/Core/ECKeepAlive.h"
#import "ECMAIN/UI/MainTabBarController.h"
#import "Network/ECNetworkManager.h"
#import "Network/ECWebServer.h"
#import "ViewController.h"

#import "ECMAIN/Core/ECBackgroundManager.h"
#import "ECMAIN/Core/ECLogManager.h"
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
        cloudUrl = @"http://s.ecmain.site";
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

  __block UIBackgroundTaskIdentifier bgTask =
      [application beginBackgroundTaskWithExpirationHandler:^{
        NSLog(@"[ECMAIN] Background Task Expiring");
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
      }];

  if (bgTask == UIBackgroundTaskInvalid) {
    NSLog(@"[ECMAIN] Failed to start background task!");
  } else {
    NSLog(@"[ECMAIN] Background Task Started (Time Remaining: %f)",
          application.backgroundTimeRemaining);
  }
}

@end
