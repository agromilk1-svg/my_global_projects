
#pragma mark - Cloud Control (Heartbeat)

#import "../../ECBuildInfo.h"
#import "../../TrollStoreCore/TSApplicationsManager.h"
#import "ECBackgroundManager.h"
#import "ECLogManager.h"
#import "ECScriptParser.h"
#import "ECTaskPollManager.h"
#import "ECVPNConfigManager.h"
#import <UIKit/UIKit.h>

// 自动更新状态标志（防止心跳期间重复触发）
static BOOL _isEcwdaUpdating = NO;
// ECWDA 在线状态标志
static BOOL _isEcwdaOnline = YES;

// ECWDA 固定 Bundle ID
static NSString *const kECWDABundleID =
    @"com.facebook.WebDriverAgentRunner.ecwda";

#include <arpa/inet.h>
#import <dlfcn.h>
#include <ifaddrs.h>
@implementation ECBackgroundManager (Heartbeat)

- (void)sendHeartbeat:(NSString *)urlString {
  // 检查是否处于飞行模式，如果在执行时间之内，强行切出并唤醒
  BOOL isAirplaneModeOn = NO;
  Class RadiosPrefsClass = NSClassFromString(@"RadiosPreferences");
  if (RadiosPrefsClass) {
    id prefs = [[RadiosPrefsClass alloc] init];
    SEL airplaneSel = NSSelectorFromString(@"airplaneMode");
    if ([prefs respondsToSelector:airplaneSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      isAirplaneModeOn =
          ((BOOL(*)(id, SEL))[prefs methodForSelector:airplaneSel])(
              prefs, airplaneSel);
#pragma clang diagnostic pop
    }
  }

  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *execTimeStr = [defaults stringForKey:@"EC_DEVICE_EXEC_TIME"];
  if (execTimeStr && execTimeStr.length > 0) {
    NSDate *now = [NSDate date];
    NSDateFormatter *dfHH = [[NSDateFormatter alloc] init];
    [dfHH setDateFormat:@"HH"];
    NSString *currHourStr = [dfHH stringFromDate:now];

    // 若当前系统时间的小时数字符串正好命中或超过我们规定的限制点
    if (currHourStr.integerValue >= execTimeStr.integerValue) {
      if (isAirplaneModeOn) {

        // 增加当天防重放锁：限制每天只能由于配置触发时间而被动强制唤醒一次
        // 所以当执行完脚本后被主动关闭成离线态时，心跳也无法强行将其解绑
        NSDateFormatter *dfDay = [[NSDateFormatter alloc] init];
        [dfDay setDateFormat:@"yyyyMMdd"];
        NSString *todayStr = [dfDay stringFromDate:now];

        NSString *lastWakeDay = [defaults stringForKey:@"EC_LAST_WAKE_DAY"];
        if (![lastWakeDay isEqualToString:todayStr]) {
          [[ECLogManager sharedManager]
              log:[NSString
                      stringWithFormat:@"[ECBackground] ⏰ "
                                       @"检测到到达设定的工作时间 (%@ 点)，"
                                       @"主控强制断开飞行状态并执行今日联机唤醒"
                                       @" (仅此一次)。",
                                       execTimeStr]];
          [[ECScriptParser new] airplaneOff];
          isAirplaneModeOn = NO; // 立刻标记解除飞行屏蔽

          [defaults setObject:todayStr forKey:@"EC_LAST_WAKE_DAY"];
          [defaults synchronize];
        }
      }
    }
  }

  // >>> 如果仍深处飞行模式且非执行时段，拒绝接单和发送自身暴露的轨迹
  if (isAirplaneModeOn) {
    return; // 暂缓发包
  }

  // >>> 新增：交叉探测 ECWDA 存活状态 <<<
  if (!_isEcwdaUpdating) {
    NSURL *wdaUrl = [NSURL URLWithString:@"http://127.0.0.1:10088/status"];
    NSMutableURLRequest *wdaReq = [NSMutableURLRequest requestWithURL:wdaUrl];
    // 超时时间 60 秒，防止 WDA
    // 在执行阻塞/耗时任务（例如首次开屏或 input 遍历 AX 树）时被误认为挂掉
    wdaReq.timeoutInterval = 60.0;

    [[NSURLSession.sharedSession
        dataTaskWithRequest:wdaReq
          completionHandler:^(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (error || httpResp.statusCode != 200) {
              BOOL wasOnline = _isEcwdaOnline;
              _isEcwdaOnline = NO;
              [[ECLogManager sharedManager]
                  log:@"[ECBackground] ⚠️ 检测到 ECWDA "
                      @"进程丢失（连接被拒/无响应）"];
              // 如果之前在线，现在离线，则尝试拉起 ECWDA
              if (wasOnline) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  dispatch_after(
                      dispatch_time(DISPATCH_TIME_NOW,
                                    (int64_t)(5.0 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
                        [[ECLogManager sharedManager]
                            log:@"[ECBackground] 🔄 正在尝试拉起 ECWDA..."];
                        BOOL launched = [[TSApplicationsManager sharedInstance]
                            openApplicationWithBundleID:kECWDABundleID];
                        if (launched) {
                          [[ECLogManager sharedManager]
                              log:@"[ECBackground] ✅ ECWDA 已自动拉起"];
                        } else {
                          [[ECLogManager sharedManager]
                              log:@"[ECBackground] ❌ ECWDA 拉起失败"];
                        }
                      });
                });
              }
            } else {
              _isEcwdaOnline = YES;
            }
          }] resume];
  }
  // <<<

  // 1. Collect Info (使用 MGCopyAnswer 获取真实唯一的硬件出厂 UDID)
  NSString *udid = nil;
  void *lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
  if (lib) {
    CFTypeRef (*_MGCopyAnswer)(CFStringRef) = dlsym(lib, "MGCopyAnswer");
    if (_MGCopyAnswer) {
      CFStringRef uniqueId =
          (CFStringRef)_MGCopyAnswer(CFSTR("UniqueDeviceID"));
      if (uniqueId) {
        udid = [NSString stringWithString:(__bridge NSString *)uniqueId];
        CFRelease(uniqueId);
      }
    }
    dlclose(lib);
  }

  if (!udid) {
    // 降级保护兜底
    udid = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
  }
  NSString *status = @"online"; // 状态固定为在线，VPN 状态不影响设备状态显示

  // 启用电池监控以获取真实电量（iOS 默认关闭，不开启会返回 -1）
  [UIDevice currentDevice].batteryMonitoringEnabled = YES;

  // Local IP (Real Interface IP)
  NSString *localIP = [self getDeviceIPAddress];
  if ([localIP isEqualToString:@"error"] || localIP.length == 0) {
    localIP = @"未知IP";
  }

  NSUserDefaults *localDefaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedNo = [localDefaults stringForKey:@"EC_DEVICE_NO"];
  NSString *deviceNo = savedNo.length > 0 ? savedNo : @"";

  // 版本更新后，清空配置校验和，迫使下次心跳重新拉取服务器配置
  NSInteger lastSyncedVersion =
      [localDefaults integerForKey:@"EC_LAST_SYNCED_VERSION"];
  if (lastSyncedVersion != EC_BUILD_VERSION) {
    [localDefaults removeObjectForKey:@"EC_CONFIG_CHECKSUM"];
    [localDefaults setInteger:EC_BUILD_VERSION
                       forKey:@"EC_LAST_SYNCED_VERSION"];
    [localDefaults synchronize];
    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:@"[ECBackground] 🔄 检测到版本更新 (%ld "
                                       @"→ %d)，已重置配置校验和，"
                                       @"下次心跳将重新拉取服务器全量配置",
                                       (long)lastSyncedVersion,
                                       EC_BUILD_VERSION]];
  }

  NSString *configChecksum = [localDefaults stringForKey:@"EC_CONFIG_CHECKSUM"];
  if (!configChecksum)
    configChecksum = @"";

  // 获取任务状态 JSON（多任务的名称+完成时间）
  NSString *taskStatusJSON =
      [[ECTaskPollManager sharedManager] getTaskStatusJSON];

  NSString *adminUsername = [localDefaults stringForKey:@"EC_ADMIN_USERNAME"];

  NSDictionary *payload = @{
    @"udid" : udid,
    @"device_no" : deviceNo,
    @"status" : status,
    @"local_ip" : localIP,
    @"battery_level" : @((int)([[UIDevice currentDevice] batteryLevel] * 100)),
    @"app_version" : @(EC_BUILD_VERSION),
    @"ecwda_version" : @([self getLocalEcwdaVersion]),
    @"vpn_active" : @([self isVPNActive]),
    @"vpn_ip" : [self isVPNActive]
        ? ([[ECVPNConfigManager sharedManager] activeNode][@"name"]
               ?: [[ECVPNConfigManager sharedManager] activeNode][@"server"]
               ?: @"")
        : @"",
    @"ecwda_status" : _isEcwdaOnline ? @"online" : @"offline",
    @"config_checksum" : configChecksum,
    @"task_status" : taskStatusJSON ?: @"",
    @"admin_username" : adminUsername ?: @""
  };

  // 2. Request
  NSError *error;
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:&error];

  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
  [request setHTTPMethod:@"POST"];
  [request setHTTPBody:jsonData];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  // 3. Send
  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          if (error) {
            NSLog(@"[ECBackground] Heartbeat Failed: %@",
                  error.localizedDescription);
            return;
          }

          [self handleHeartbeatResponse:data];
        }] resume];
}

- (void)handleHeartbeatResponse:(NSData *)data {
  NSError *error;
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:&error];
  if (error || !json)
    return;

  // 打印心跳响应内容供调试
  NSLog(@"[ECBackground] 心跳响应: %@", json);

  // --- 自动更新检测 ---
  NSDictionary *updateInfo = json[@"update"];
  if (updateInfo && [updateInfo isKindOfClass:[NSDictionary class]]) {
    NSInteger serverVersion = [updateInfo[@"version"] integerValue];
    if (serverVersion > EC_BUILD_VERSION && !_isUpdating) {
      [[ECLogManager sharedManager]
          log:[NSString stringWithFormat:
                            @"[ECBackground] 🔄 发现新版本: %ld (当前: %d)",
                            (long)serverVersion, EC_BUILD_VERSION]];
      [self performSelfUpdate:updateInfo];
    }
  }

  // --- ECWDA 自动更新检测 ---
  NSDictionary *ecwdaUpdate = json[@"ecwda_update"];
  if (ecwdaUpdate && [ecwdaUpdate isKindOfClass:[NSDictionary class]]) {
    NSInteger serverWdaVer = [ecwdaUpdate[@"version"] integerValue];
    NSInteger localWdaVer = [self getLocalEcwdaVersion];
    if (serverWdaVer > localWdaVer && !_isEcwdaUpdating) {
      [[ECLogManager sharedManager]
          log:[NSString
                  stringWithFormat:
                      @"[ECBackground] 🔄 发现 ECWDA 新版本: %ld (本地: %ld)",
                      (long)serverWdaVer, (long)localWdaVer]];
      [self performEcwdaUpdate:ecwdaUpdate];
    }
  }

  // --- 配置下发更新 ---
  NSDictionary *pushConfig = json[@"push_config"];
  if (pushConfig && [pushConfig isKindOfClass:[NSDictionary class]]) {
    NSString *newIpJson = pushConfig[@"config_ip"];
    NSString *newVpnStr = pushConfig[@"config_vpn"];
    NSString *newChecksum = pushConfig[@"config_checksum"];

    // 取出最新的三个多维限制规则属性并沉淀到本地
    NSString *newCountry = pushConfig[@"country"];
    NSString *newGroupName = pushConfig[@"group_name"];
    NSString *newExecTime = pushConfig[@"exec_time"];

    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:
                          @"[ECBackground] ⬇️ "
                          @"收到最新的环境配置下发，准备切换... (Checksum: %@)",
                          newChecksum]];

    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    [defaults setObject:newChecksum forKey:@"EC_CONFIG_CHECKSUM"];

    // 如果无该属性，置空防止业务出错
    [defaults setObject:(newCountry ?: @"") forKey:@"EC_DEVICE_COUNTRY"];
    [defaults setObject:(newGroupName ?: @"") forKey:@"EC_DEVICE_GROUP"];
    [defaults setObject:(newExecTime ?: @"") forKey:@"EC_DEVICE_EXEC_TIME"];

    // 账号信息存储
    NSString *newAppleAccount = pushConfig[@"apple_account"];
    NSString *newApplePassword = pushConfig[@"apple_password"];
    NSString *newTiktokAccounts = pushConfig[@"tiktok_accounts"];
    [defaults setObject:(newAppleAccount ?: @"") forKey:@"EC_APPLE_ACCOUNT"];
    [defaults setObject:(newApplePassword ?: @"") forKey:@"EC_APPLE_PASSWORD"];
    [defaults setObject:(newTiktokAccounts ?: @"[]")
                 forKey:@"EC_TIKTOK_ACCOUNTS"];

    [defaults synchronize];

    // 1. IP 配置
    if (newIpJson.length > 0) {
      NSError *err;
      NSDictionary *ipDict = [NSJSONSerialization
          JSONObjectWithData:[newIpJson dataUsingEncoding:NSUTF8StringEncoding]
                     options:0
                       error:&err];
      if (!err && ipDict) {
        NSString *ip = ipDict[@"ip"] ?: @"";
        NSString *subnet = ipDict[@"subnet"] ?: @"";
        NSString *gateway = ipDict[@"gateway"] ?: @"";
        NSString *dns = ipDict[@"dns"] ?: @"";

        if (ip.length > 0 && subnet.length > 0 && gateway.length > 0) {
          extern int spawnRoot(NSString * path, NSArray * args,
                               NSString * *stdOut, NSString * *stdErr);
          extern NSString *rootHelperPath(void);

          NSMutableArray *args = [NSMutableArray
              arrayWithObjects:@"set-static-ip", ip, subnet, gateway, nil];
          if (dns.length > 0) {
            [args addObject:dns];
          }

          // 这里交由 RootHelper 注入 SystemConfiguration 重组网络
          spawnRoot(rootHelperPath(), args, nil, nil);
          [[ECLogManager sharedManager]
              log:[NSString stringWithFormat:@"[ECBackground] ✅ 静态 IP "
                                             @"下发底层完毕: IP=%@ GW=%@",
                                             ip, gateway]];
        }
      }
    }

    // 2. VPN 节点配置
    if (newVpnStr.length > 0 && [newVpnStr hasPrefix:@"ecnode://"]) {
      NSString *b64 = [newVpnStr substringFromIndex:9]; // 去除 ecnode://
      NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:b64
                                                                options:0];
      if (decodedData) {
        NSString *decodedStr =
            [[NSString alloc] initWithData:decodedData
                                  encoding:NSUTF8StringEncoding];
        if (decodedStr) {
          // Vue URL decode component
          NSString *jsonStr = [decodedStr stringByRemovingPercentEncoding];
          if (jsonStr) {
            NSError *err;
            NSArray *nodes = [NSJSONSerialization
                JSONObjectWithData:[jsonStr
                                       dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             error:&err];
            if (!err && [nodes isKindOfClass:[NSArray class]] &&
                nodes.count > 0) {
              // 记住当前用户选中的节点（用 name + server 组合匹配，不用 UUID）
              NSDictionary *prevActiveNode =
                  [[ECVPNConfigManager sharedManager] activeNode];
              NSString *prevName = prevActiveNode[@"name"] ?: @"";
              NSString *prevServer = prevActiveNode[@"server"] ?: @"";

              // 先清空旧节点列表，与服务器配置完全同步
              [[ECVPNConfigManager sharedManager] saveNodes:@[]];

              // 逐个添加所有下发节点到 ECVPNConfigManager
              for (NSDictionary *node in nodes) {
                [[ECVPNConfigManager sharedManager] addNode:node];
              }

              // 恢复上次选中的节点：优先根据 name+server 匹配
              NSArray *newNodes = [[ECVPNConfigManager sharedManager] allNodes];
              NSDictionary *matchedNode = nil;
              if (prevName.length > 0 || prevServer.length > 0) {
                for (NSDictionary *n in newNodes) {
                  NSString *nName = n[@"name"] ?: @"";
                  NSString *nServer = n[@"server"] ?: @"";
                  if ([nName isEqualToString:prevName] &&
                      [nServer isEqualToString:prevServer]) {
                    matchedNode = n;
                    break;
                  }
                }
              }

              // 如果匹配不到旧节点，回退到首节点
              NSDictionary *activeNode = matchedNode ?: newNodes.firstObject;
              if (activeNode) {
                [[ECVPNConfigManager sharedManager]
                    setActiveNodeID:activeNode[@"id"]];

                [[ECLogManager sharedManager]
                    log:[NSString stringWithFormat:
                                      @"[ECBackground] ✅ "
                                      @"已导入 %lu 个代理节点，激活节点: "
                                      @"%@%@，正在挂载...",
                                      (unsigned long)nodes.count,
                                      activeNode[@"name"] ?: @"Unnamed",
                                      matchedNode ? @" (已恢复上次选择)"
                                                  : @" (首节点)"]];
                dispatch_async(dispatch_get_main_queue(), ^{
                  [self connectVPNWithConfig:activeNode];
                });
              }
            }
          }
        }
      }
    } else if (newVpnStr.length == 0) {
      // 下发为空时，如果原本在线，就强制关闭它
      if ([self isVPNActive]) {
        [self stopVPN];
      }
    }
  }

  // --- 任务处理（保持原有逻辑不变） ---
  NSDictionary *task = json[@"task"];
  if (task && [task isKindOfClass:[NSDictionary class]]) {
    NSString *type = task[@"type"];
    NSNumber *taskId = task[@"id"];

    [[ECLogManager sharedManager]
        log:[NSString
                stringWithFormat:@"[脚本动作] 📩 收到心跳任务: %@ (ID: %@)",
                                 type, taskId]];

    if ([type isEqualToString:@"script"]) {
      NSString *script = task[@"script"];
      if (script) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [[ECScriptParser sharedParser]
              executeScript:script
                 completion:^(BOOL success, NSArray *_Nonnull results) {
                   [self reportTaskResult:taskId
                                   status:success ? @"success" : @"failed"
                                   result:results.description];
                 }];
        });
      }
    } else if ([type isEqualToString:@"vpn"]) {
      NSDictionary *config = task[@"payload"];
      if (config) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self connectVPNWithConfig:config];
          [self reportTaskResult:taskId
                          status:@"success"
                          result:@"VPN Config Applied"];
        });
      }
    }
  }
}

#pragma mark - ECWDA 自动升级

// 获取本地 ECWDA 的版本号（通过 LSApplicationProxy 查询）
- (NSInteger)getLocalEcwdaVersion {
  Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
  if (!LSAppProxyClass)
    return 0;

  id proxy =
      [LSAppProxyClass performSelector:@selector(applicationProxyForIdentifier:)
                            withObject:kECWDABundleID];
  if (!proxy)
    return 0;

  // 检查应用是否实际安装
  NSNumber *isInstalled = [proxy valueForKey:@"isInstalled"];
  if (!isInstalled || ![isInstalled boolValue])
    return 0;

  // 读取 CFBundleVersion
  NSString *bundleVersion = [proxy valueForKey:@"bundleVersion"];
  if (bundleVersion && bundleVersion.length > 0) {
    return [bundleVersion integerValue];
  }

  return 0;
}

// 执行 ECWDA 下载 → 静默安装 → 自动启动
- (void)performEcwdaUpdate:(NSDictionary *)updateInfo {
  if (_isEcwdaUpdating) {
    NSLog(@"[ECBackground] ECWDA 更新已在进行中，跳过...");
    return;
  }
  _isEcwdaUpdating = YES;

  // 构建完整下载 URL
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;

  NSString *downloadPath = updateInfo[@"download_url"];
  NSString *fullURL =
      [NSString stringWithFormat:@"%@%@", baseUrl, downloadPath];

  [[ECLogManager sharedManager]
      log:[NSString
              stringWithFormat:@"[ECBackground] 开始下载 ECWDA 更新包: %@",
                               fullURL]];

  NSURL *url = [NSURL URLWithString:fullURL];
  NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession]
      downloadTaskWithURL:url
        completionHandler:^(NSURL *_Nullable location,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          if (error || !location) {
            NSLog(@"[ECBackground] ❌ ECWDA 下载失败: %@",
                  error.localizedDescription);
            _isEcwdaUpdating = NO;
            return;
          }

          // 保存到临时目录
          NSString *tmpDir = NSTemporaryDirectory();
          NSString *ipaPath =
              [tmpDir stringByAppendingPathComponent:@"ecwda_update.ipa"];

          [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];

          NSError *moveError;
          [[NSFileManager defaultManager]
              moveItemAtURL:location
                      toURL:[NSURL fileURLWithPath:ipaPath]
                      error:&moveError];
          if (moveError) {
            NSLog(@"[ECBackground] ❌ ECWDA 移动下载文件失败: %@", moveError);
            _isEcwdaUpdating = NO;
            return;
          }

          // 验证文件大小
          NSDictionary *attrs =
              [[NSFileManager defaultManager] attributesOfItemAtPath:ipaPath
                                                               error:nil];
          unsigned long long fileSize =
              [attrs[NSFileSize] unsignedLongLongValue];
          if (fileSize < 1024) {
            NSLog(@"[ECBackground] ❌ ECWDA 下载文件太小 (%llu bytes)",
                  fileSize);
            _isEcwdaUpdating = NO;
            return;
          }

          [[ECLogManager sharedManager]
              log:[NSString
                      stringWithFormat:@"[ECBackground] ✅ ECWDA 下载完成 "
                                       @"(%.1f MB)，开始静默安装...",
                                       fileSize / 1024.0 / 1024.0]];

          // 使用 TSApplicationsManager 原包安装（静默，不弹提示）
          NSString *logOut = nil;
          int ret = [[TSApplicationsManager sharedInstance]
                      installIpa:ipaPath
                           force:YES
                registrationType:@"System"
                  customBundleId:nil
               customDisplayName:nil
                     skipSigning:NO
              installationMethod:0 // method 0 = Installd Direct（原包安装）
                             log:&logOut];

          if (ret == 0) {
            [[ECLogManager sharedManager]
                log:@"[ECBackground] ✅ ECWDA 静默安装成功！正在自动启动..."];

            // 安装成功后自动启动 ECWDA
            dispatch_async(dispatch_get_main_queue(), ^{
              dispatch_after(
                  dispatch_time(DISPATCH_TIME_NOW,
                                (int64_t)(2.0 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
                    BOOL launched = [[TSApplicationsManager sharedInstance]
                        openApplicationWithBundleID:kECWDABundleID];
                    if (launched) {
                      [[ECLogManager sharedManager]
                          log:@"[ECBackground] ✅ ECWDA 已自动启动"];
                    } else {
                      [[ECLogManager sharedManager]
                          log:@"[ECBackground] ⚠️ ECWDA "
                              @"启动失败，可能需要手动启动"];
                    }
                    _isEcwdaUpdating = NO;
                  });
            });
          } else {
            NSLog(@"[ECBackground] ❌ ECWDA 安装失败 (code: %d) log: %@", ret,
                  logOut);
            _isEcwdaUpdating = NO;
          }

          // 清理临时文件
          [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
        }];
  [downloadTask resume];
}

@end
