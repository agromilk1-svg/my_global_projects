
#pragma mark - Cloud Control (Heartbeat)

// 自动更新状态标志（防止心跳期间重复触发）
static BOOL _isEcwdaUpdating = NO;
// ECWDA 在线状态标志
static BOOL _isEcwdaOnline = YES;
// [v1742] ECWDA 10088 端口连续探测失败计数器
static NSInteger _ecwda10088FailCount = 0;
// [v1742] 防止重复触发强杀+重启操作
static BOOL _isEcwdaRestarting = NO;
// [v1934] 心跳成功计数器（每次 HTTP 请求成功发出时递增，供看门狗监控）
static NSInteger _heartbeatSendCount = 0;
// [v1934] 心跳连续异常计数器（@try/@catch 捕获异常时递增）
static NSInteger _heartbeatExceptionCount = 0;

// ECWDA 固定 Bundle ID
static NSString *const kECWDABundleID =
    @"com.apple.accessibility.ecwda";

// 💓 心跳时间戳改用 ECBackgroundManager 成员变量 _lastHeartbeatTime

- (void)handleHeartbeatFailure {
    // 构建候选地址列表：用户偏好的原始地址 + 固定候选列表（去重）
    NSString *userPreferredUrl = [ECPersistentConfig stringForKey:@"EC_USER_PREFERRED_URL"];
    NSString *currentActiveUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
    NSMutableArray *candidates = [NSMutableArray array];
    
    // 1. 用户偏好的地址优先
    if (userPreferredUrl.length > 0) [candidates addObject:userPreferredUrl];
    
    // 2. 追加固定候选地址（跳过已存在的）
    for (NSString *fallback in ECServerFallbackList()) {
        if (![candidates containsObject:fallback]) {
            [candidates addObject:fallback];
        }
    }
    
    if (candidates.count <= 1) {
        [[ECLogManager sharedManager] log:@"[ECBackground] ⚠️ 心跳超时且无其他候选地址可切换"];
        return;
    }
    
    // 3. 找到当前正在工作且发生超时的地址在候选列表中的位置，切换到下一个
    NSUInteger currentIdx = [candidates indexOfObject:currentActiveUrl];
    NSUInteger nextIdx = (currentIdx != NSNotFound) ? (currentIdx + 1) % candidates.count : 0;
    NSString *nextUrl = candidates[nextIdx];
    
    if (![nextUrl isEqualToString:currentActiveUrl]) {
        [[ECLogManager sharedManager] log:[NSString stringWithFormat:@"[ECBackground] ⚠️ 心跳连接服务器10秒超时，循环切换服务器至: %@", nextUrl]];
        [ECPersistentConfig setObject:nextUrl forKey:@"CloudServerURL"];
        [ECPersistentConfig synchronize];
    }
    // 通知仪表盘心跳探测失败
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ECHeartbeatDidComplete"
                          object:nil
                        userInfo:@{@"success": @NO, @"error": @"连接超时，已自动切换服务器"}];
    });
}

- (void)sendHeartbeat:(NSString *)urlString {
  // [v1934] 全方位异常防护罩：包裹整个心跳方法体
  // 即使内部任何步骤抛出 ObjC 异常（nil 字典插入、私有 API 崩溃等），
  // 也只是跳过本轮心跳，绝不会让 GCD Timer 连锁崩溃。下轮 60 秒后照常重试。
  @try {
  // 兜底：如果外部传了 nil，安全降级为读取系统默认配置，防止
  // NSMutableURLRequest 崩溃
  if (!urlString || urlString.length == 0) {
    NSString *savedUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
    if (!savedUrl || savedUrl.length == 0) {
      [[ECLogManager sharedManager] log:@"[ECBackground] 🛑 服务器地址未配置，无法发送心跳"];
      return;
    }
    urlString = [savedUrl stringByAppendingString:@"/devices/heartbeat"];
  }

  // 1. 发送初步尝试日志 (前置以确保透明度)
  [[ECLogManager sharedManager] log:@"[ECBackground] 💓 尝试发送心跳包..."];

  // --- 节流防护：5 秒内禁止重复发送核心心跳，防止 502 导致的请求瞬间堆叠 ---
  NSTimeInterval nowTime = [[NSDate date] timeIntervalSince1970];
  if (nowTime - _lastHeartbeatTime < 5.0) {
    NSLog(@"[ECBackground] 💓 心跳发送触发过快，已节流拦截 (%.1fs)",
          nowTime - _lastHeartbeatTime);
    return;
  }
  _lastHeartbeatTime = nowTime;
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
    [[ECLogManager sharedManager]
        log:@"[ECBackground] 💓 设备处于飞行模式且非执行时段，拒绝发包"];
    return; // 暂缓发包
  }

  // >>> [fix] 增强型 ECWDA 存活探测：提升误杀防护 <<<
  // 修改点：
  //   1. 探测超时 15s→5s：更快失败，避免每轮心跳被 URLSession 长时间占用
  //   2. 失败阈值 2次→5次：给 MJPEG 高负载/网络抖动留出足够容错窗口
  //   3. 新增 _lastEcwdaRestartTime：两次重启之间强制间隔 120 秒
  //      防止 ECWDA 在高负载下连续被误杀，形成重启雪崩
  if (self.watchdogWdaEnabled && !_isEcwdaUpdating && !_isEcwdaRestarting) {
    NSURL *wdaUrl = [NSURL URLWithString:@"http://127.0.0.1:10088/status"];
    NSMutableURLRequest *wdaReq = [NSMutableURLRequest requestWithURL:wdaUrl];
    // [fix] 超时从 15s 缩短到 5s：快速失败，减少对心跳线程的占用
    wdaReq.timeoutInterval = 5.0;

    [[NSURLSession.sharedSession
        dataTaskWithRequest:wdaReq
          completionHandler:^(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            if (error || httpResp.statusCode != 200) {
              _ecwda10088FailCount++;
              NSString *errInfo = error ? error.localizedDescription
                  : [NSString stringWithFormat:@"HTTP %ld", (long)httpResp.statusCode];
              [[ECLogManager sharedManager]
                  log:[NSString stringWithFormat:
                      @"[ECBackground] ⚠️ ECWDA 10088 端口探测失败 (%ld/5): %@",
                      (long)_ecwda10088FailCount, errInfo]];

              if (_ecwda10088FailCount == 1) {
                // ====== 第 1 级：首次失败，可能是进程根本没有运行 ======
                // 直接尝试拉起 ECWDA，不强杀（进程可能本就不存在）
                _isEcwdaOnline = NO;
                [[ECLogManager sharedManager]
                    log:@"[ECBackground] 🔄 ECWDA 10088 首次探测失败，"
                        @"尝试直接拉起进程（应对进程不存在的情况）..."];
                dispatch_async(dispatch_get_main_queue(), ^{
                  BOOL launched = [[TSApplicationsManager sharedInstance]
                      openApplicationWithBundleID:kECWDABundleID];
                  if (launched) {
                    [[ECLogManager sharedManager]
                        log:@"[ECBackground] ✅ ECWDA 已尝试拉起，"
                            @"等待下一轮探测验证..."];
                  } else {
                    [[ECLogManager sharedManager]
                        log:@"[ECBackground] ❌ ECWDA 拉起失败"];
                  }
                });
              // [fix] 阈值从 2 提升到 5：面对 MJPEG 高负载/网络抖动引起的超时，
              // 需要更多次数才能确认 ECWDA 真正僵死，避免误杀触发重启雪崩
              } else if (_ecwda10088FailCount >= 5) {
                // ====== 第 2 级：连续 5 次失败，真正判定为僵死，执行强杀重启 ======

                // [fix] 重启冷却期：两次 killall 之间强制间隔 120 秒
                // 防止高负载下"重启→系统更卡→再超时→再重启"的正反馈雪崩
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                static NSTimeInterval sLastEcwdaRestartTime = 0;
                static const NSTimeInterval kRestartCooldown = 120.0;
                if (sLastEcwdaRestartTime > 0 &&
                    (now - sLastEcwdaRestartTime) < kRestartCooldown) {
                  [[ECLogManager sharedManager]
                      log:[NSString stringWithFormat:
                          @"[ECBackground] 🛡️ 重启冷却保护中 (已过 %.0fs / 需 %.0fs)，"
                          @"跳过本次强杀，防止雪崩",
                          now - sLastEcwdaRestartTime, kRestartCooldown]];
                  _ecwda10088FailCount = 3; // 回落，继续观察而非立即再次触发
                  return;
                }

                _isEcwdaOnline = NO;
                _isEcwdaRestarting = YES; // 锁定，防止重复触发
                _ecwda10088FailCount = 0; // 重置计数器
                sLastEcwdaRestartTime = now; // 记录本次重启时刻

                [[ECLogManager sharedManager]
                    log:@"[ECBackground] 🚨 ECWDA 10088 端口连续 5 次无响应，"
                        @"判定子线程已僵死。即将强杀进程并重新拉起..."];

                dispatch_async(dispatch_get_main_queue(), ^{
                  // 第 1 步：使用 killall 发送 SIGKILL(9) 强制终止 ECWDA
                  // 进程及所有子线程
                  extern void killall(NSString *processName, BOOL softly);
                  [[ECLogManager sharedManager]
                      log:@"[ECBackground] 🔪 正在强杀 "
                          @"ECService-Runner 进程..."];
                  killall(@"ECService-Runner",
                          NO); // NO = SIGKILL(9) 硬杀

                  // 第 2 步：等待 3 秒让系统彻底回收进程资源
                  dispatch_after(
                      dispatch_time(DISPATCH_TIME_NOW,
                                    (int64_t)(3.0 * NSEC_PER_SEC)),
                      dispatch_get_main_queue(), ^{
                        [[ECLogManager sharedManager]
                            log:@"[ECBackground] 🔄 进程已强杀，"
                                @"正在重新拉起 ECWDA..."];

                        BOOL launched = [[TSApplicationsManager sharedInstance]
                            openApplicationWithBundleID:kECWDABundleID];
                        if (launched) {
                          [[ECLogManager sharedManager]
                              log:@"[ECBackground] ✅ ECWDA "
                                  @"已强杀后重新拉起"];
                        } else {
                          [[ECLogManager sharedManager]
                              log:@"[ECBackground] ❌ ECWDA "
                                  @"强杀后拉起失败"];
                        }

                        // [fix] 重启保护期从 30s 延长至 60s，
                        // 给 ECWDA 留出充足的 XCTRunnerDaemonSession 初始化时间
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(60.0 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              _isEcwdaRestarting = NO;
                              [[ECLogManager sharedManager]
                                  log:@"[ECBackground] 🔓 ECWDA "
                                      @"重启保护期已结束，恢复正常探测"];
                            });
                      });
                });
              }
            } else {
              // 探测成功，重置计数器和在线状态
              if (_ecwda10088FailCount > 0) {
                [[ECLogManager sharedManager]
                    log:@"[ECBackground] ✅ ECWDA 10088 端口已恢复正常响应"];
              }
              _ecwda10088FailCount = 0;
              _isEcwdaOnline = YES;
            }
          }] resume];
  }
  // <<<


  // [v1726] 8089 探测已迁移至心跳 GCD Timer 的 event handler 中，与
  // sendHeartbeat 平级执行

  // 1. Collect Info (使用 MGCopyAnswer 获取真实唯一的硬件出厂 UDID)
  NSString *udid = nil;
  void *lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
  if (lib) {
    CFTypeRef (*_MGCopyAnswer)(CFStringRef) = dlsym(lib, "MGCopyAnswer");
    if (_MGCopyAnswer) {
      CFStringRef uniqueId = (CFStringRef)_MGCopyAnswer(CFSTR("SerialNumber"));
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

  NSString *configChecksum = [ECPersistentConfig stringForKey:@"EC_CONFIG_CHECKSUM"];
  if (!configChecksum)
    configChecksum = @"";

  // 获取任务状态 JSON（多任务的名称+完成时间）
  NSString *taskStatusJSON =
      [[ECTaskPollManager sharedManager] getTaskStatusJSON];

  NSString *adminUsername = [ECPersistentConfig stringForKey:@"EC_ADMIN_USERNAME"];

  // [v1735] 获取 TikTok 版本号 (按顺序检测所有可能的包名)
  NSString *tiktokVersion = @"";
  {
    Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
    if (LSAppProxyClass) {
      NSString *targetAppsStr = [ECPersistentConfig stringForKey:@"EC_TARGET_APPS"];
      if (!targetAppsStr || targetAppsStr.length == 0) {
        targetAppsStr = @"com.zhiliaoapp.musically,com.ss.iphone.ugc.Ame,com.ss.iphone.ugc.Aweme";
      }
      NSString *cleanedStr = [targetAppsStr stringByReplacingOccurrencesOfString:@" " withString:@""];
      NSArray *targetPkgs = [cleanedStr componentsSeparatedByString:@","];

      for (NSString *pkg in targetPkgs) {
        if (pkg.length == 0) continue;
        id proxy = [LSAppProxyClass
            performSelector:@selector(applicationProxyForIdentifier:)
                 withObject:pkg];
        if (proxy) {
          NSNumber *isInstalled = [proxy valueForKey:@"isInstalled"];
          if (isInstalled && [isInstalled boolValue]) {
            NSString *shortVer = [proxy valueForKey:@"shortVersionString"];
            if (shortVer.length > 0) {
              tiktokVersion = shortVer;
              break; // 找到第一个已安装的即跳出
            }
          }
        }
      }
    }
  }

  // [v1736] 获取 VPN 节点显示名称（具备 name -> remark -> server 回退逻辑）
  NSString *vpnNodeName = @"";
  if ([self isVPNActive]) {
    NSDictionary *active = [[ECVPNConfigManager sharedManager] activeNode];
    vpnNodeName = active[@"name"] ?: active[@"remark"] ?: active[@"server"] ?: @"";
  }

  // [修复] vpnNodeName 可能为 nil（activeNode 中 name/remark/server 全缺失时），
  // ObjC 字典字面量 @{} 不允许 nil value，否则整个 sendHeartbeat 会静默崩溃，
  // 导致心跳永远发不出去，服务端判定设备离线。
  NSString *safeVpnNodeName = vpnNodeName ?: @"";
  NSString *safeTiktokVersion = tiktokVersion ?: @"";

  NSDictionary *payload = @{
    @"udid" : udid,
    @"device_no" : deviceNo,
    @"status" : status,
    @"local_ip" : localIP,
    @"battery_level" : @((int)([[UIDevice currentDevice] batteryLevel] * 100)),
    @"app_version" : @(EC_BUILD_VERSION),
    @"ecwda_version" : @([self getLocalEcwdaVersion]),
    @"vpn_active" : @([self isVPNActive]),
    @"vpn_ip" : @"",  // [修复] 补齐服务端 HeartbeatRequest 模型要求的 vpn_ip 字段
    @"vpn_node" : safeVpnNodeName,
    @"ecwda_status" : _isEcwdaOnline ? @"online" : @"offline",
    @"config_checksum" : configChecksum,
    @"task_status" : taskStatusJSON ?: @"",
    @"admin_username" : adminUsername ?: @"",
    @"tiktok_version" : safeTiktokVersion
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
  
  // [v1930] 防止 iOS 锁屏/后台休眠期间静默掐断心跳请求，使用强化版 Session
  static NSURLSession *heartbeatSession = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
      NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
      config.waitsForConnectivity = YES;
      config.discretionary = NO; // 禁止系统推迟该请求
      if (@available(iOS 13.0, *)) {
          config.allowsExpensiveNetworkAccess = YES;
          config.allowsConstrainedNetworkAccess = YES;
      }
      config.timeoutIntervalForRequest = 10.0; // [v1930] 发送超时由60s缩短至10秒，以便快速切换节点
      heartbeatSession = [NSURLSession sessionWithConfiguration:config];
  });

  // 3. Send (增加 Payload 打印)
  NSLog(@"[ECBackground] ⬆️ 发送心跳包 Payload: %@", payload);

  _heartbeatSendCount++; // [v1934] 心跳发送计数
  [[heartbeatSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable hs_error) {
          if (hs_error) {
            NSLog(@"[ECBackground] Heartbeat Failed: %@",
                  hs_error.localizedDescription);
            [self handleHeartbeatFailure];
            return;
          }

          [self handleHeartbeatResponse:data];
        }] resume];

  } @catch (NSException *exception) {
    // [v1934] 捕获所有 ObjC 异常，防止心跳静默死亡
    _heartbeatExceptionCount++;
    NSLog(@"[ECBackground] ❌ 心跳发送过程中捕获异常 (第%ld次): %@ - %@",
          (long)_heartbeatExceptionCount, exception.name, exception.reason);
    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:
            @"[ECBackground] ❌ 心跳异常已捕获并跳过 (第%ld次): %@，"
            @"下轮 60s 后将自动重试",
            (long)_heartbeatExceptionCount, exception.reason]];
  }
}

- (void)handleHeartbeatResponse:(NSData *)data {
  NSError *error;
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                       options:0
                                                         error:&error];
  if (error || !json)
    return;

  // [v1934] 通知仪表盘心跳探测成功
  dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
          postNotificationName:@"ECHeartbeatDidComplete"
                        object:nil
                      userInfo:@{@"success": @YES}];
  });

  // 打印心跳响应内容供调试
  NSLog(@"[ECBackground] 心跳响应: %@", json);
  [[ECLogManager sharedManager]
      log:[NSString
              stringWithFormat:@"[ECBackground] ⬇️ 收到心跳响应: %@", json]];

  // --- 自动更新检测 ---
  NSDictionary *updateInfo = json[@"update"];
  if (updateInfo && [updateInfo isKindOfClass:[NSDictionary class]]) {
    NSInteger serverVersion = [updateInfo[@"version"] integerValue];
    if (serverVersion > EC_BUILD_VERSION && !_isUpdating) {
      [[ECLogManager sharedManager]
          log:[NSString stringWithFormat:
                            @"[ECBackground] 🔄 发现新版本: %ld (当前: %d)，准备停止现有任务并静默更新",
                            (long)serverVersion, EC_BUILD_VERSION]];
      [[ECTaskPollManager sharedManager] stopCurrentActionScript];
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
                      @"[ECBackground] 🔄 发现 ECWDA 新版本: %ld (本地: %ld)，准备停止现有任务并静默更新",
                      (long)serverWdaVer, (long)localWdaVer]];
      [[ECTaskPollManager sharedManager] stopCurrentActionScript];
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
    NSString *newTargetApps = pushConfig[@"target_apps"]; // 获取下发的拦截目标包名

    // [诊断日志] 打印 push_config 全量内容，便于排查 VPN 配置下发问题
    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:
                          @"[ECBackground] 📋 push_config 全量内容:\n"
                          @"  config_vpn: [%@] (长度: %lu)\n"
                          @"  config_ip: [%@]\n"
                          @"  country: [%@]\n"
                          @"  group_name: [%@]\n"
                          @"  exec_time: [%@]\n"
                          @"  target_apps: [%@]\n"
                          @"  apple_account: [%@]\n"
                          @"  apple_password: [%@]\n"
                          @"  watchdog_wda: [%@]\n"
                          @"  config_checksum: [%@]",
                          newVpnStr ?: @"(nil)", (unsigned long)(newVpnStr ?: @"").length,
                          newIpJson ?: @"(nil)",
                          newCountry ?: @"(nil)",
                          newGroupName ?: @"(nil)",
                          newExecTime ?: @"(nil)",
                          newTargetApps ?: @"(nil)",
                          pushConfig[@"apple_account"] ?: @"(nil)",
                          pushConfig[@"apple_password"] ?: @"(nil)",
                          pushConfig[@"watchdog_wda"] ?: @"(nil)",
                          newChecksum ?: @"(nil)"]];

    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:
                          @"[ECBackground] ⬇️ "
                          @"收到最新的环境配置下发，准备切换... (Checksum: %@)",
                          newChecksum]];

    // 所有配置通过 ECPersistentConfig 双写（App Group + plist 文件），
    // 确保 OTA 更新后即使 App Group 容器被重建，配置依然可恢复
    [ECPersistentConfig setObject:newChecksum forKey:@"EC_CONFIG_CHECKSUM"];

    // 如果无该属性，置空防止业务出错
    [ECPersistentConfig setObject:(newCountry ?: @"") forKey:@"EC_DEVICE_COUNTRY"];
    [ECPersistentConfig setObject:(newGroupName ?: @"") forKey:@"EC_DEVICE_GROUP"];
    [ECPersistentConfig setObject:(newExecTime ?: @"") forKey:@"EC_DEVICE_EXEC_TIME"];
    [ECPersistentConfig setObject:(newTargetApps ?: @"") forKey:@"EC_TARGET_APPS"];

    // 账号信息存储
    NSString *newAppleAccount = pushConfig[@"apple_account"];
    NSString *newApplePassword = pushConfig[@"apple_password"];
    [ECPersistentConfig setObject:(newAppleAccount ?: @"") forKey:@"EC_APPLE_ACCOUNT"];
    [ECPersistentConfig setObject:(newApplePassword ?: @"") forKey:@"EC_APPLE_PASSWORD"];

    // watchdog_wda 支持
    NSNumber *watchdogVal = pushConfig[@"watchdog_wda"];
    if (watchdogVal) {
      [ECPersistentConfig setBool:[watchdogVal boolValue] forKey:@"EC_WATCHDOG_WDA_ENABLED"];
    }

    // --- 缓存检验对比（IP/VPN 缓存仍使用 App Group 直接读取） ---
    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    NSString *cachedIpJson = [defaults stringForKey:@"EC_CONFIG_IP_CACHED"];
    NSString *cachedVpnStr = [defaults stringForKey:@"EC_CONFIG_VPN_CACHED"];

    // 1. IP 配置
    if (newIpJson.length > 0) {
      if ([newIpJson isEqualToString:(cachedIpJson ?: @"")]) {
        [[ECLogManager sharedManager]
            log:@"[ECBackground] ⏭️ 静态 IP 配置无实质变化，已跳过本地重置"];
      } else {
        NSError *err;
        NSDictionary *ipDict = [NSJSONSerialization
            JSONObjectWithData:[newIpJson
                                   dataUsingEncoding:NSUTF8StringEncoding]
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

            [defaults setObject:newIpJson forKey:@"EC_CONFIG_IP_CACHED"];
            [defaults synchronize];
          }
        }
      }
    }

    // 2. VPN 节点配置
    if ([newVpnStr isEqualToString:(cachedVpnStr ?: @"")]) {
      if (newVpnStr.length > 0) {
        [[ECLogManager sharedManager]
            log:@"[ECBackground] ⏭️ VPN 代理配置无实质变化，已跳过挂载重连"];
      }
    } else {
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
                // 记住当前用户选中的节点（用 name + server 组合匹配，不用
                // UUID）
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
                NSArray *newNodes =
                    [[ECVPNConfigManager sharedManager] allNodes];
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
                                        activeNode[@"name"] ?: activeNode[@"server"] ?: @"Unnamed",
                                        matchedNode ? @" (已恢复上次选择)"
                                                    : @" (首节点)"]];
                  dispatch_async(dispatch_get_main_queue(), ^{
                    [self connectVPNWithConfig:activeNode];
                  });

                  // 同步防抖缓存
                  [defaults setObject:newVpnStr forKey:@"EC_CONFIG_VPN_CACHED"];
                  [defaults synchronize];
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
        [defaults setObject:newVpnStr forKey:@"EC_CONFIG_VPN_CACHED"];
        [defaults synchronize];
      }
    }
  } else {
    // push_config 不存在 → 说明本地 checksum 与服务器一致，无需下发配置
    NSString *localChecksum = [ECPersistentConfig stringForKey:@"EC_CONFIG_CHECKSUM"];
    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:
                          @"[ECBackground] ℹ️ 心跳响应中无 push_config（本地 checksum: [%@]，与服务器一致，配置未更新）",
                          localChecksum ?: @"(空)"]];
  }

  // --- 任务处理（保持原有逻辑不变） ---
  NSArray *tasks = json[@"tasks"]; // 支持数组形式
  if (!tasks && json[@"task"]) {
    tasks = @[ json[@"task"] ]; // 兜底单任务
  }

  if (tasks && [tasks isKindOfClass:[NSArray class]]) {
    [self processHeartbeatTasks:tasks];
  }
}

- (void)processHeartbeatTasks:(NSArray *)tasks {
  for (NSDictionary *task in tasks) {
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

  // [v1762] OTA 前激活：将 ECMAIN 拉到前台并唤醒屏幕
  // 如果设备在后台或锁屏状态安装，可能不会自动激活，导致安装失败或永远无法重启 ECWDA
  [[ECLogManager sharedManager] log:@"[ECBackground] 🔄 ECWDA 更新前先激活屏幕..."];
  dispatch_async(dispatch_get_main_queue(), ^{
    [[TSApplicationsManager sharedInstance]
        openApplicationWithBundleID:@"com.ecmain.app"];
  });
  // 给系统 1 秒时间完成前台切换
  [NSThread sleepForTimeInterval:1.0];

  // 构建完整下载 URL
  NSString *savedUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
  if (!savedUrl || savedUrl.length == 0) {
    [[ECLogManager sharedManager] log:@"[ECBackground] 🛑 服务器地址未配置，无法下载 ECWDA 更新"];
    _isEcwdaUpdating = NO;
    return;
  }
  NSString *baseUrl = savedUrl;

  NSString *downloadPath = updateInfo[@"download_url"];
  NSString *fullURL =
      [NSString stringWithFormat:@"%@%@", baseUrl, downloadPath];
  NSURL *url = [NSURL URLWithString:fullURL];

  NSString *tmpDir = NSTemporaryDirectory();
  NSString *ipaPath =
      [tmpDir stringByAppendingPathComponent:@"ecwda_update.ipa"];

  [[ECLogManager sharedManager]
      log:[NSString
              stringWithFormat:@"[ECBackground] 开始下载 ECWDA 更新包: %@",
                               fullURL]];

  // BUILD #403: 使用增强型下载器，支持 502 自动重试与后台能力
  [self
      downloadAndUpdateWithURL:url
                        toPath:ipaPath
                    retryCount:0
                    completion:^(BOOL success, NSString *_Nullable filePath) {
                      if (!success) {
                        _isEcwdaUpdating = NO;
                        return;
                      }

                      [[ECLogManager sharedManager]
                          log:@"[ECBackground] ✅ ECWDA "
                              @"下载完成，开始静默安装..."];

                      // 使用 TSApplicationsManager 原包安装（静默，不弹提示）
                      NSString *logOut = nil;
                      int ret = [[TSApplicationsManager sharedInstance]
                                  installIpa:filePath
                                       force:YES
                            registrationType:@"System"
                              customBundleId:nil
                           customDisplayName:nil
                                 skipSigning:NO
                          installationMethod:0 // method 0 = Installd
                                               // Direct（原包安装）
                                         log:&logOut];

                      if (ret == 0) {
                        [[ECLogManager sharedManager]
                            log:@"[ECBackground] ✅ ECWDA "
                                @"静默安装成功！正在自动启动..."];

                        // 安装成功后自动启动 ECWDA
                        dispatch_after(
                            dispatch_time(DISPATCH_TIME_NOW,
                                          (int64_t)(2.0 * NSEC_PER_SEC)),
                            dispatch_get_main_queue(), ^{
                              BOOL launched = [[TSApplicationsManager
                                  sharedInstance]
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
                      } else {
                        NSLog(@"[ECBackground] ❌ ECWDA 安装失败 (code: %d) "
                              @"log: %@",
                              ret, logOut);
                        _isEcwdaUpdating = NO;
                      }

                      // 清理临时文件
                      [[NSFileManager defaultManager] removeItemAtPath:filePath
                                                                 error:nil];
                    }];
}
