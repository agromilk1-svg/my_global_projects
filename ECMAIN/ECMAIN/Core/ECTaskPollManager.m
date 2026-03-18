//
//  ECTaskPollManager.m
//  ECMAIN
//
//  用于自动轮询控制中心，拉取和管理全局动作脚本。
//

#import "ECTaskPollManager.h"
#import "ECBackgroundManager.h"
#import "ECLogManager.h"
#import "ECScriptParser.h"
#import "ECVPNConfigManager.h"
#import <UIKit/UIKit.h>

// 仅在主应用 ECMAIN 中编译，剔除 Tunnel 或其他 Extension
#ifndef ECMAIN_EXTENSION

@interface ECTaskPollManager ()
@property(nonatomic, strong) dispatch_source_t pollTimer;
@property(nonatomic, strong) dispatch_queue_t pollQueue;
@property(nonatomic, assign) BOOL isPolling;
@property(nonatomic, assign) BOOL isExecuting;
// 节流与退避相关
@property(nonatomic, assign) NSTimeInterval lastFetchTime;
@property(nonatomic, assign) NSTimeInterval backoffInterval;
// 本地存储已获取的任务 JSON 数组
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *localTasks;
// 记录已执行任务的日期字典，key=taskId字符串, value=执行日期(yyyy-MM-dd)
// 同一任务当天只执行一次，过了 0 点自动解锁
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSString *> *executedTaskDates;
// 每个任务的执行日志，key=taskId字符串, value=日志字典
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSDictionary *> *taskExecutionLogs;
@end

@implementation ECTaskPollManager

@synthesize isPolling = _isPolling;

+ (instancetype)sharedManager {
  static ECTaskPollManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECTaskPollManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _pollQueue =
        dispatch_queue_create("com.ecmain.taskpoller", DISPATCH_QUEUE_SERIAL);
    _isPolling = NO;
    _isExecuting = NO;
    [self loadPersistedData];
  }
  return self;
}

- (void)loadPersistedData {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSArray *tasks = [defaults arrayForKey:@"EC_SAVED_AUTO_SCRIPTS"];
  if (tasks) {
    _localTasks = [tasks mutableCopy];
  } else {
    _localTasks = [NSMutableArray array];
  }

  NSDictionary *dates = [defaults dictionaryForKey:@"EC_EXECUTED_TASK_DATES"];
  if (dates) {
    _executedTaskDates = [dates mutableCopy];
  } else {
    _executedTaskDates = [NSMutableDictionary dictionary];
  }

  NSDictionary *logs = [defaults dictionaryForKey:@"EC_TASK_EXECUTION_LOGS"];
  if (logs) {
    _taskExecutionLogs = [logs mutableCopy];
  } else {
    _taskExecutionLogs = [NSMutableDictionary dictionary];
  }
}

/// 获取今天的日期字符串 (yyyy-MM-dd)
- (NSString *)todayDateString {
  NSDateFormatter *df = [[NSDateFormatter alloc] init];
  [df setDateFormat:@"yyyy-MM-dd"];
  return [df stringFromDate:[NSDate date]];
}

/// 获取当前完整时间字符串 (yyyy-MM-dd HH:mm:ss)
- (NSString *)currentDateTimeString {
  NSDateFormatter *df = [[NSDateFormatter alloc] init];
  [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
  return [df stringFromDate:[NSDate date]];
}

/// 判断指定任务今天是否已经执行过
- (BOOL)isTaskExecutedToday:(NSNumber *)taskId {
  NSString *key = [taskId stringValue];
  NSString *execRecord = self.executedTaskDates[key];
  if (!execRecord)
    return NO;
  // 兼容旧格式 (yyyy-MM-dd) 和新格式 (yyyy-MM-dd HH:mm:ss)
  NSString *today = [self todayDateString];
  return [execRecord hasPrefix:today];
}

/// 获取指定任务的执行完成时间（如果今天执行过）
- (NSString *)taskCompletionTime:(NSNumber *)taskId {
  NSString *key = [taskId stringValue];
  NSString *execRecord = self.executedTaskDates[key];
  if (!execRecord)
    return nil;
  NSString *today = [self todayDateString];
  if ([execRecord hasPrefix:today] && execRecord.length > today.length) {
    // 提取时间部分 "HH:mm:ss"
    return [execRecord substringFromIndex:today.length + 1];
  }
  return nil;
}

- (void)savePersistedData {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults setObject:[_localTasks copy] forKey:@"EC_SAVED_AUTO_SCRIPTS"];
  [defaults setObject:[_executedTaskDates copy]
               forKey:@"EC_EXECUTED_TASK_DATES"];
  [defaults setObject:[_taskExecutionLogs copy]
               forKey:@"EC_TASK_EXECUTION_LOGS"];
  [defaults synchronize];
}

- (void)startPolling {
  if (self.isPolling)
    return;

  self.isPolling = YES;
  if (!self.pollTimer) {
    self.pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            self.pollQueue);
    // 首次延时 5 秒，之后每 60 秒一次
    dispatch_source_set_timer(
        self.pollTimer, dispatch_time(DISPATCH_TIME_NOW, 5.0 * NSEC_PER_SEC),
        60.0 * NSEC_PER_SEC, 1.0 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.pollTimer, ^{
      [self fetchGlobalTasks];
    });
    dispatch_resume(self.pollTimer);
  }

  [[ECLogManager sharedManager]
      log:@"[ECTaskPollManager] 动作脚本轮询引擎已启动 (60s)"];
}

- (void)suspendPolling {
  if (!self.isPolling)
    return;
  self.isPolling = NO;
  if (self.pollTimer) {
    dispatch_suspend(self.pollTimer);
  }
  [[ECLogManager sharedManager] log:@"[ECTaskPollManager] 暂停获取全局任务"];
}

- (void)resumePolling {
  if (self.isPolling)
    return;
  self.isPolling = YES;
  if (self.pollTimer) {
    dispatch_resume(self.pollTimer);
  }
  [[ECLogManager sharedManager] log:@"[ECTaskPollManager] 恢复获取全局任务"];
}

- (void)fetchGlobalTasks {
  // 检查是否受限于飞行模式，若是则停止获取轮询以节省开销
  Class RadiosPrefsClass = NSClassFromString(@"RadiosPreferences");
  if (RadiosPrefsClass) {
    id prefs = [[RadiosPrefsClass alloc] init];
    SEL airplaneSel = NSSelectorFromString(@"airplaneMode");
    if ([prefs respondsToSelector:airplaneSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      BOOL isAirplaneModeOn =
          ((BOOL(*)(id, SEL))[prefs methodForSelector:airplaneSel])(
              prefs, airplaneSel);
#pragma clang diagnostic pop
      if (isAirplaneModeOn) {
        return; // 已处于伪装与沉寂状态，不接发任务
      }
    }
  }

  if (self.isExecuting) {
    return; // 防重入
  }

  // --- 节流与退避逻辑 ---
  NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
  if (now - self.lastFetchTime < (10.0 + self.backoffInterval)) {
    // NSLog(@"[ECTaskPollManager] 轮询请求太频繁，跳过 (退避中: %.1fs)", self.backoffInterval);
    return;
  }
  self.lastFetchTime = now;

  NSLog(@"[ECTaskPollManager] Fetching global scripts...");

  // 获取设备填写的中心配置 URL
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;

  // 从本地缓存读取当前设备的属性，拼接到查询参数中用于服务器端的精确筛选
  NSString *country = [defaults stringForKey:@"EC_DEVICE_COUNTRY"] ?: @"";
  NSString *group = [defaults stringForKey:@"EC_DEVICE_GROUP"] ?: @"";

  // 组装最终获取设备自动脚本列表的接口（仅通过国家和分组匹配）
  NSString *queryString = [NSString
      stringWithFormat:@"?country=%@&group_name=%@",
                       [country
                           stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLQueryAllowedCharacterSet]],
                       [group
                           stringByAddingPercentEncodingWithAllowedCharacters:
                               [NSCharacterSet URLQueryAllowedCharacterSet]]];
  NSString *urlString =
      [[baseUrl stringByAppendingString:@"/api/device/scripts"]
          stringByAppendingString:queryString];
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url)
    return;

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  req.timeoutInterval = 10.0;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
          if (error || !data || (httpResp && httpResp.statusCode != 200)) {
            NSLog(@"[ECTaskPollManager] 获取任务异常 (Status: %ld): %@", 
                  (long)(httpResp ? httpResp.statusCode : 0),
                  error.localizedDescription ?: @"HTTP Error");
            
            // 遭遇 502 或其他服务端错误，实施指数退避 (10s -> 20s -> 40s -> max 300s)
            if (self.backoffInterval < 10) {
                self.backoffInterval = 10.0;
            } else {
                self.backoffInterval = MIN(self.backoffInterval * 2.0, 300.0);
            }
            return;
          }

          // 请求成功，重置退避
          self.backoffInterval = 0;

          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
          if (json && [json[@"status"] isEqualToString:@"ok"]) {
            NSArray *tasks = json[@"tasks"];
            if ([tasks isKindOfClass:[NSArray class]]) {
              [self processFetchedTasks:tasks];
            }
          }
        }];
  [task resume];
}

- (void)processFetchedTasks:(NSArray<NSDictionary *> *)serverTasks {
  dispatch_async(self.pollQueue, ^{
    BOOL hasChanges = NO;
    NSDictionary *newTargetTask = nil;

    for (NSDictionary *t in serverTasks) {
      NSNumber *taskId = t[@"id"];
      NSString *taskCode = t[@"code"];
      if (!taskId || !taskCode)
        continue;

      // 是否在本地列表里存在？（用作显示）
      BOOL existsLocal = NO;
      for (NSDictionary *lt in self.localTasks) {
        if ([lt[@"id"] isEqual:taskId] &&
            [lt[@"updated_at"] isEqual:t[@"updated_at"]]) {
          existsLocal = YES;
          break;
        }
      }
      if (!existsLocal) {
        // 如果 id 一样只是 updated_at 变了，我们需要替换掉旧的
        NSUInteger replaceIdx = NSNotFound;
        for (NSUInteger i = 0; i < self.localTasks.count; i++) {
          if ([self.localTasks[i][@"id"] isEqual:taskId]) {
            replaceIdx = i;
            break;
          }
        }
        if (replaceIdx != NSNotFound) {
          [self.localTasks replaceObjectAtIndex:replaceIdx withObject:t];
          // 内容变了，就应当从已执行日期记录里踢除，让它重跑一遍
          [self.executedTaskDates removeObjectForKey:[taskId stringValue]];
        } else {
          [self.localTasks addObject:t];
        }
        hasChanges = YES;
      }

      // 筛选亟待执行的任务 (今天还没执行过的任务)
      if (![self isTaskExecutedToday:taskId] && !newTargetTask) {
        newTargetTask = t;
      }
    }

    // 服务器上删掉的任务，本地也应当清掉
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSDictionary *lt in self.localTasks) {
      BOOL stillOnServer = NO;
      for (NSDictionary *st in serverTasks) {
        if ([st[@"id"] isEqual:lt[@"id"]]) {
          stillOnServer = YES;
          break;
        }
      }
      if (!stillOnServer) {
        [toRemove addObject:lt];
      }
    }
    if (toRemove.count > 0) {
      [self.localTasks removeObjectsInArray:toRemove];
      hasChanges = YES;
    }

    if (hasChanges) {
      [self savePersistedData];
      // 发一个通知告诉界面刷新列表（如果在看详情）
      dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:@"ECTasksDidUpdateAlert"
                          object:nil];
      });
    }

    if (newTargetTask && !self.isExecuting) {
      // 在决定自动执行之前，增加时间屏障检查，防止未到时钟点自动跑
      NSUserDefaults *defaults =
          [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
      NSString *execTimeStr = [defaults stringForKey:@"EC_DEVICE_EXEC_TIME"];
      BOOL shouldExecute = YES;

      if (execTimeStr && execTimeStr.length > 0 &&
          ![execTimeStr isEqualToString:@"无"] &&
          ![execTimeStr isEqualToString:@"全时段"]) {
        NSScanner *scanner = [NSScanner scannerWithString:execTimeStr];
        int timeVal;
        BOOL isNumeric = [scanner scanInt:&timeVal] && [scanner isAtEnd];
        if (isNumeric) {
          NSDateFormatter *df = [[NSDateFormatter alloc] init];
          [df setDateFormat:@"HH"];
          NSString *currHourStr = [df stringFromDate:[NSDate date]];
          if (currHourStr.integerValue < timeVal) {
            shouldExecute = NO;
          }
        }
      }

      if (shouldExecute) {
        [self executeTask:newTargetTask];
      } else {
        NSLog(@"[ECTaskPollManager] 发现新任务，但当前未到规定的设备执行时段 "
              @"(%@点)，自动执行延后...",
              execTimeStr);
      }
    }
  });
}

- (void)executeTask:(NSDictionary *)task {
  self.isExecuting = YES;
  [self suspendPolling]; // 挂起 60 秒的轮询

  NSNumber *taskId = task[@"id"];
  NSString *code = task[@"code"];
  NSString *name = task[@"name"] ?: @"(无名动作)";

  NSString *logMsg = [NSString
      stringWithFormat:
          @"[脚本动作] 🎬 发现新任务，开始自动执行: %@ (ID: %@)", name,
          taskId];
  [[ECLogManager sharedManager] log:logMsg];
  NSLog(@"%@", logMsg);
  NSLog(@"[脚本动作] 脚本内容:\n%@", code);

  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECScriptParser sharedParser]
        executeScript:code
           completion:^(BOOL success, NSArray *_Nonnull results) {
             NSString *resLog = [NSString
                 stringWithFormat:
                     @"[脚本动作] %@ 自动任务 '%@' 执行完毕. 结果: %@",
                     success ? @"✅" : @"❌",
                     name, success ? @"成功" : @"失败"];
             [[ECLogManager sharedManager] log:resLog];
             NSLog(@"%@", resLog);

             // === 持久化保存执行日志 ===
             NSMutableArray *logMessages = [NSMutableArray array];
             NSString *lastCommand = @"（无）";
             NSString *errorInfo = @"";
             for (NSDictionary *logEntry in results) {
               NSString *msg = logEntry[@"message"] ?: @"";
               [logMessages addObject:msg];
               // 提取最后一条非错误的消息作为"最后执行的指令"
               if (![msg containsString:@"Error"] && ![msg containsString:@"❌"] && msg.length > 0) {
                 lastCommand = msg;
               }
               // 提取错误信息
               if ([msg containsString:@"Error"] || [msg containsString:@"❌"]) {
                 if (errorInfo.length > 0) {
                   errorInfo = [errorInfo stringByAppendingString:@"\n"];
                 }
                 errorInfo = [errorInfo stringByAppendingString:msg];
               }
             }

             NSDictionary *logRecord = @{
               @"success" : @(success),
               @"error" : errorInfo ?: @"",
               @"last_command" : lastCommand ?: @"",
               @"log_count" : @(logMessages.count),
               @"logs" : logMessages,
               @"timestamp" : [self currentDateTimeString]
             };

             dispatch_async(self.pollQueue, ^{
               self.taskExecutionLogs[[taskId stringValue]] = logRecord;
               [self savePersistedData];
             });

             // 如果脚本执行出错，弹窗显示错误信息
             if (!success) {
               NSString *alertMsg = [NSString
                   stringWithFormat:@"错误信息:\n%@\n\n最后执行的指令:\n%@",
                   errorInfo.length > 0 ? errorInfo : @"未知错误",
                   lastCommand];

               dispatch_async(dispatch_get_main_queue(), ^{
                 UIAlertController *errorAlert = [UIAlertController
                     alertControllerWithTitle:[NSString
                                                 stringWithFormat:
                                                     @"⚠️ 脚本执行出错\n%@",
                                                     name]
                                     message:alertMsg
                              preferredStyle:UIAlertControllerStyleAlert];
                 [errorAlert
                     addAction:[UIAlertAction
                                   actionWithTitle:@"确定"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];

                 // 获取当前最顶层的 ViewController 来弹窗
                 UIWindow *keyWindow = nil;
                 for (UIScene *scene in [UIApplication sharedApplication]
                          .connectedScenes) {
                   if (scene.activationState ==
                       UISceneActivationStateForegroundActive) {
                     UIWindowScene *windowScene = (UIWindowScene *)scene;
                     for (UIWindow *window in windowScene.windows) {
                       if (window.isKeyWindow) {
                         keyWindow = window;
                         break;
                       }
                     }
                   }
                 }
                 UIViewController *topVC = keyWindow.rootViewController;
                 while (topVC.presentedViewController) {
                   topVC = topVC.presentedViewController;
                 }
                 [topVC presentViewController:errorAlert
                                     animated:YES
                                   completion:nil];
               });
             }

             dispatch_async(self.pollQueue, ^{
               // 执行完成后，标记完整的日期时间，今天内不再重复执行
               // 任务保留在本地列表中供查看，0 点后自动解锁
               self.executedTaskDates[[taskId stringValue]] =
                   [self currentDateTimeString];
               [self savePersistedData];

               // 通知 UI 刷新
               dispatch_async(dispatch_get_main_queue(), ^{
                 [[NSNotificationCenter defaultCenter]
                     postNotificationName:@"ECTasksDidUpdateAlert"
                                   object:nil];
               });

               self.isExecuting = NO;
               [self resumePolling]; // 重启轮询
             });
           }];
  });
}

- (NSArray<NSDictionary *> *)getAllLocalTasks {
  __block NSArray *tasks = nil;
  dispatch_sync(self.pollQueue, ^{
    tasks = [self.localTasks copy];
  });
  return tasks;
}

/// 生成任务状态 JSON 字符串，包含所有今天已执行任务的名称和完成时间
- (NSString *)getTaskStatusJSON {
  __block NSString *jsonStr = @"";
  dispatch_sync(self.pollQueue, ^{
    NSMutableArray *statusArray = [NSMutableArray array];
    NSString *today = [self todayDateString];

    for (NSDictionary *task in self.localTasks) {
      NSNumber *taskId = task[@"id"];
      NSString *name = task[@"name"] ?: @"未命名";
      NSString *key = [taskId stringValue];
      NSString *execRecord = self.executedTaskDates[key];

      if (execRecord && [execRecord hasPrefix:today]) {
        // 提取时间部分
        NSString *timeStr = @"已完成";
        if (execRecord.length > today.length) {
          timeStr = [execRecord substringFromIndex:today.length + 1];
        }
        [statusArray addObject:@{@"name" : name, @"time" : timeStr}];
      } else {
        [statusArray addObject:@{@"name" : name, @"time" : @"等待执行"}];
      }
    }

    if (statusArray.count > 0) {
      NSData *data = [NSJSONSerialization dataWithJSONObject:statusArray
                                                    options:0
                                                      error:nil];
      if (data) {
        jsonStr = [[NSString alloc] initWithData:data
                                        encoding:NSUTF8StringEncoding];
      }
    }
  });
  return jsonStr;
}

- (void)stopCurrentActionScript {
  // ECScriptParser
  // 自身其实是一个阻塞或持续执行的过程，若未来实现中断抛出在此处接应
  [[ECLogManager sharedManager]
      log:@"[ECTaskPollManager] "
          @"试图强制终止正在执行的脚本（此操作可能需要引擎层支持）"];
}

- (void)deleteTaskWithId:(NSNumber *)taskId {
  dispatch_async(self.pollQueue, ^{
    NSMutableArray *toRemove = [NSMutableArray array];
    for (NSDictionary *lt in self.localTasks) {
      if ([lt[@"id"] isEqual:taskId]) {
        [toRemove addObject:lt];
      }
    }
    [self.localTasks removeObjectsInArray:toRemove];
    // 手动删除时清除日期标记，允许从服务器重新拉回后再次执行
    [self.executedTaskDates removeObjectForKey:[taskId stringValue]];
    [self savePersistedData];

    dispatch_async(dispatch_get_main_queue(), ^{
      [[NSNotificationCenter defaultCenter]
          postNotificationName:@"ECTasksDidUpdateAlert"
                        object:nil];
    });
  });
}

- (NSDictionary *)getTaskExecutionLog:(NSNumber *)taskId {
  __block NSDictionary *log = nil;
  dispatch_sync(self.pollQueue, ^{
    log = self.taskExecutionLogs[[taskId stringValue]];
  });
  return log;
}

@end

#endif // !ECMAIN_EXTENSION
