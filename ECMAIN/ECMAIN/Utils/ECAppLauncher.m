#import "ECAppLauncher.h"
#import "../Core/ECLogManager.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <sys/sysctl.h>

// 辅助宏用于输出日志到仪表盘
#define LAUNCHER_LOG(fmt, ...)                                                 \
  [[ECLogManager sharedManager] log:@"[Launcher] " fmt, ##__VA_ARGS__]

// FrontBoard/BackBoard 私有 API 声明
@interface FBSSystemService : NSObject
+ (instancetype)sharedService;
- (void)openApplication:(NSString *)bundleIdentifier
                options:(NSDictionary *)options
             completion:(void (^)(NSError *))completion;
@end

// LSApplicationWorkspace 声明在 TSCoreServices.h 中
#import "../../TrollStoreCore/TSCoreServices.h"

@implementation ECAppLauncher

+ (LaunchdResponse_t)launchAppWithBundleIdentifier:(NSString *)bundleIdentifier
                                    executablePath:(NSString *)executablePath {
  LAUNCHER_LOG(@"启动应用: %@", bundleIdentifier);

  // 从可执行文件路径提取可执行文件名
  NSString *executableName = [executablePath lastPathComponent];
  LAUNCHER_LOG(@"可执行文件名: %@", executableName);

  // 方案 1: 尝试使用 FBSSystemService (iOS 13+)
  LAUNCHER_LOG(@"尝试方案 1: FBSSystemService");
  Class FBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
  if (FBSSystemServiceClass) {
    id systemService = [FBSSystemServiceClass sharedService];
    if (systemService && [systemService respondsToSelector:@selector
                                        (openApplication:
                                                 options:completion:)]) {

      __block BOOL launched = NO;
      __block NSError *launchError = nil;
      dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

      NSDictionary *options =
          @{@"__ActivateSuspended" : @YES, @"__UnlockDevice" : @YES};

      [systemService openApplication:bundleIdentifier
                             options:options
                          completion:^(NSError *error) {
                            launchError = error;
                            launched = (error == nil);
                            dispatch_semaphore_signal(semaphore);
                          }];

      dispatch_time_t timeout =
          dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
      if (dispatch_semaphore_wait(semaphore, timeout) == 0) {
        if (launched) {
          LAUNCHER_LOG(@"✅ FBSSystemService 启动成功");
          [NSThread sleepForTimeInterval:1.0];
          pid_t pid = [self getPIDForBundleIdentifier:bundleIdentifier
                                       executableName:executableName];
          if (pid > 0) {
            LAUNCHER_LOG(@"获取到 PID: %d", pid);
            LaunchdResponse_t response = {
                .job_handle = nil, .job_state = 0, .pid = pid, .removing = NO};
            return response;
          } else {
            LAUNCHER_LOG(@"警告: 应用已启动但无法获取 PID");
          }
        } else {
          LAUNCHER_LOG(@"❌ FBSSystemService 启动失败: %@", launchError);
        }
      } else {
        LAUNCHER_LOG(@"❌ FBSSystemService 超时");
      }
    }
  }

  // 方案 2: 尝试使用 LSApplicationWorkspace
  LAUNCHER_LOG(@"尝试方案 2: LSApplicationWorkspace");
  Class LSApplicationWorkspaceClass =
      NSClassFromString(@"LSApplicationWorkspace");
  if (LSApplicationWorkspaceClass) {
    id workspace = [LSApplicationWorkspaceClass defaultWorkspace];
    if (workspace && [workspace respondsToSelector:@selector
                                (openApplicationWithBundleID:)]) {
      BOOL success = [workspace openApplicationWithBundleID:bundleIdentifier];
      if (success) {
        LAUNCHER_LOG(@"✅ LSApplicationWorkspace 启动成功");
        [NSThread sleepForTimeInterval:1.5];
        pid_t pid = [self getPIDForBundleIdentifier:bundleIdentifier
                                     executableName:executableName];
        if (pid > 0) {
          LAUNCHER_LOG(@"获取到 PID: %d", pid);
          LaunchdResponse_t response = {
              .job_handle = nil, .job_state = 0, .pid = pid, .removing = NO};
          return response;
        } else {
          LAUNCHER_LOG(@"警告: 应用已启动但无法获取 PID");
        }
      } else {
        LAUNCHER_LOG(@"❌ LSApplicationWorkspace 启动失败");
      }
    }
  }

  // 方案 3: 使用 UIApplication openURL
  LAUNCHER_LOG(@"尝试方案 3: UIApplication openURL");
  if ([NSThread isMainThread]) {
    NSURL *url = [NSURL
        URLWithString:[NSString stringWithFormat:@"%@://", bundleIdentifier]];
    if (!url) {
      url = [NSURL URLWithString:[NSString stringWithFormat:@"app://%@",
                                                            bundleIdentifier]];
    }
    if (url) {
      Class UIApplicationClass = NSClassFromString(@"UIApplication");
      if (UIApplicationClass) {
        id sharedApp =
            [UIApplicationClass performSelector:@selector(sharedApplication)];
        if (sharedApp) {
          SEL openURLSelector =
              NSSelectorFromString(@"openURL:options:completionHandler:");
          if ([sharedApp respondsToSelector:openURLSelector]) {
            __block BOOL opened = NO;
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            void (^completionHandler)(BOOL) = ^(BOOL success) {
              opened = success;
              dispatch_semaphore_signal(semaphore);
            };
            NSMethodSignature *signature =
                [sharedApp methodSignatureForSelector:openURLSelector];
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            [invocation setTarget:sharedApp];
            [invocation setSelector:openURLSelector];
            [invocation setArgument:&url atIndex:2];
            NSDictionary *options = @{};
            [invocation setArgument:&options atIndex:3];
            [invocation setArgument:&completionHandler atIndex:4];
            [invocation invoke];
            dispatch_time_t timeout =
                dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC);
            if (dispatch_semaphore_wait(semaphore, timeout) == 0 && opened) {
              LAUNCHER_LOG(@"✅ UIApplication openURL 成功");
              [NSThread sleepForTimeInterval:1.5];
              pid_t pid = [self getPIDForBundleIdentifier:bundleIdentifier
                                           executableName:executableName];
              if (pid > 0) {
                LAUNCHER_LOG(@"获取到 PID: %d", pid);
                LaunchdResponse_t response = {.job_handle = nil,
                                              .job_state = 0,
                                              .pid = pid,
                                              .removing = NO};
                return response;
              }
            }
          }
        }
      }
    }
  }

  LAUNCHER_LOG(@"❌ 所有启动方案都失败");
  LAUNCHER_LOG(@"建议: 检查应用是否正确安装，Bundle ID 是否正确");
  return NIL_LAUNCHD_RESPONSE;
}

// 辅助方法：通过 Bundle ID 或可执行文件名获取 PID
+ (pid_t)getPIDForBundleIdentifier:(NSString *)bundleIdentifier
                    executableName:(NSString *)executableName {

  // 方案 1: 使用 RunningBoard 私有 API 获取 PID
  Class RBSProcessHandleClass = NSClassFromString(@"RBSProcessHandle");
  if (RBSProcessHandleClass) {
    SEL predicateSelector =
        NSSelectorFromString(@"predicateMatchingBundleIdentifier:");
    if ([RBSProcessHandleClass respondsToSelector:predicateSelector]) {
      id predicate = [RBSProcessHandleClass performSelector:predicateSelector
                                                 withObject:bundleIdentifier];
      SEL handlesSelector = NSSelectorFromString(
          @"currentProcessHandlesMatchingPredicate:error:");
      if ([RBSProcessHandleClass respondsToSelector:handlesSelector]) {
        NSError *error = nil;
        NSMethodSignature *signature =
            [RBSProcessHandleClass methodSignatureForSelector:handlesSelector];
        NSInvocation *invocation =
            [NSInvocation invocationWithMethodSignature:signature];
        [invocation setTarget:RBSProcessHandleClass];
        [invocation setSelector:handlesSelector];
        [invocation setArgument:&predicate atIndex:2];
        [invocation setArgument:&error atIndex:3];
        [invocation invoke];
        NSSet *__unsafe_unretained handles = nil;
        [invocation getReturnValue:&handles];
        if (handles && handles.count > 0) {
          id handle = [handles anyObject];
          SEL pidSelector = NSSelectorFromString(@"pid");
          if ([handle respondsToSelector:pidSelector]) {
            NSNumber *pidNumber = [handle performSelector:pidSelector];
            pid_t pid = [pidNumber intValue];
            LAUNCHER_LOG(@"通过 RBSProcessHandle 找到 PID: %d", pid);
            return pid;
          }
        }
      }
    }
  }

  // 方案 2: 使用 sysctl 遍历所有进程，用可执行文件名匹配
  LAUNCHER_LOG(@"RBSProcessHandle 不可用，使用 sysctl 回退方案");
  LAUNCHER_LOG(@"查找进程名: %@", executableName);

  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size;

  if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
    LAUNCHER_LOG(@"sysctl 获取进程列表大小失败");
    return -1;
  }

  struct kinfo_proc *procs = malloc(size);
  if (!procs) {
    LAUNCHER_LOG(@"malloc 失败");
    return -1;
  }

  if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
    LAUNCHER_LOG(@"sysctl 获取进程列表失败");
    free(procs);
    return -1;
  }

  int procCount = (int)(size / sizeof(struct kinfo_proc));
  LAUNCHER_LOG(@"正在遍历 %d 个进程...", procCount);

  pid_t foundPid = -1;

  for (int i = 0; i < procCount; i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 0 || pid == getpid()) {
      continue;
    }

    char *procName = procs[i].kp_proc.p_comm;
    NSString *procNameStr = [NSString stringWithUTF8String:procName];

    // 精确匹配可执行文件名
    if ([procNameStr isEqualToString:executableName]) {
      LAUNCHER_LOG(@"✅ 精确匹配进程: PID=%d, 进程名=%@", pid, procNameStr);
      foundPid = pid;
      break;
    }

    // 部分匹配（进程名可能被截断为 16 字符）
    if (executableName.length > 15) {
      NSString *truncatedName = [executableName substringToIndex:15];
      if ([procNameStr isEqualToString:truncatedName]) {
        LAUNCHER_LOG(@"✅ 截断匹配进程: PID=%d, 进程名=%@", pid, procNameStr);
        foundPid = pid;
        break;
      }
    }
  }

  free(procs);

  if (foundPid == -1) {
    LAUNCHER_LOG(@"未找到匹配的进程");
  }

  return foundPid;
}

+ (void)wakeScreenAndBringMainAppToFront {
  LAUNCHER_LOG(@"🌟 准备强行点亮屏幕并激活主程序到前台...");
  Class FBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
  if (FBSSystemServiceClass) {
    id systemService = [FBSSystemServiceClass sharedService];
    if (systemService && [systemService respondsToSelector:@selector(openApplication:options:completion:)]) {
      // ✅ 仅保留 __UnlockDevice 不使用 __ActivateSuspended，这样应用会被真正推到前台同时点亮屏幕
      NSDictionary *options = @{@"__UnlockDevice" : @YES};
      [systemService openApplication:@"com.ecmain.app"
                             options:options
                          completion:^(NSError *error) {
                            if (error) {
                              LAUNCHER_LOG(@"⚠️ FBSSystemService 尝试点亮屏幕失败: %@", error);
                            } else {
                              LAUNCHER_LOG(@"✅ 屏幕已被点亮并确立前台状态");
                            }
                          }];
      return;
    }
  }
  
  // 兜底降级方案：使用 LSApplicationWorkspace (但不一定能黑屏亮屏)
  LAUNCHER_LOG(@"⚠️ 找不到 FBSSystemService，使用 LSApplicationWorkspace 兜底唤醒");
  Class LSApplicationWorkspaceClass = NSClassFromString(@"LSApplicationWorkspace");
  if (LSApplicationWorkspaceClass) {
    id workspace = [LSApplicationWorkspaceClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
    if (workspace && [workspace respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:")]) {
      [workspace performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:@"com.ecmain.app"];
    }
  }
}

+ (NSString *)executablePathForAppAtPath:(NSString *)bundlePath {
  NSString *infoPlistPath =
      [bundlePath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *infoPlist =
      [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
  NSString *executableName = infoPlist[@"CFBundleExecutable"];
  if (!executableName) {
    executableName =
        [[bundlePath lastPathComponent] stringByDeletingPathExtension];
  }
  return [bundlePath stringByAppendingPathComponent:executableName];
}

@end
