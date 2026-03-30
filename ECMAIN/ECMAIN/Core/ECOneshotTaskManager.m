//
//  ECOneshotTaskManager.m
//  ECMAIN
//
//  独立的一次性任务轮询管理器。
//  以 90 秒为周期查询专属于当前设备的一次性任务，
//  执行时抢占所有常规脚本和在线升级逻辑。
//

#import "ECOneshotTaskManager.h"
#import "ECBackgroundManager.h"
#import "ECLogManager.h"
#import "ECScriptParser.h"
#import "ECTaskPollManager.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#ifndef ECMAIN_EXTENSION

// 全局标志：一次性任务是否正在执行（供在线升级模块检查）
BOOL EC_ONESHOT_EXECUTING = NO;

@interface ECOneshotTaskManager ()
@property(nonatomic, strong) dispatch_source_t pollTimer;
@property(nonatomic, strong) dispatch_queue_t pollQueue;
@property(nonatomic, assign) BOOL isPolling;
@property(nonatomic, assign) BOOL isExecuting;
@end

@implementation ECOneshotTaskManager

+ (instancetype)sharedManager {
  static ECOneshotTaskManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECOneshotTaskManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _pollQueue = dispatch_queue_create("com.ecmain.oneshot", DISPATCH_QUEUE_SERIAL);
    _isPolling = NO;
    _isExecuting = NO;
  }
  return self;
}

#pragma mark - 获取设备 UDID

- (NSString *)deviceUDID {
  return [ECBackgroundManager deviceUDID];
}

#pragma mark - 轮询控制

- (void)startPolling {
  if (self.isPolling) return;
  self.isPolling = YES;

  if (!self.pollTimer) {
    self.pollTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.pollQueue);
    // 首次 10 秒后开始，之后每 90 秒一次
    dispatch_source_set_timer(
        self.pollTimer,
        dispatch_time(DISPATCH_TIME_NOW, 10.0 * NSEC_PER_SEC),
        90.0 * NSEC_PER_SEC, 1.0 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(self.pollTimer, ^{
      [self fetchOneshotTask];
    });
    dispatch_resume(self.pollTimer);
  }

  [[ECLogManager sharedManager]
      log:@"[ECOneshotTask] 一次性任务轮询引擎已启动 (90s)"];
}

- (void)suspendPolling {
  if (!self.isPolling) return;
  self.isPolling = NO;
  if (self.pollTimer) {
    dispatch_suspend(self.pollTimer);
  }
}

- (void)resumePolling {
  if (self.isPolling) return;
  self.isPolling = YES;
  if (self.pollTimer) {
    dispatch_resume(self.pollTimer);
  }
}

#pragma mark - 核心轮询逻辑

- (void)fetchOneshotTask {
  if (self.isExecuting) return; // 防重入

  NSString *udid = [self deviceUDID];
  if (!udid || udid.length == 0) return;

  // 获取服务器地址
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;

  NSString *urlString = [NSString
      stringWithFormat:@"%@/api/device/oneshot_task?udid=%@", baseUrl,
                       [udid stringByAddingPercentEncodingWithAllowedCharacters:
                                [NSCharacterSet URLQueryAllowedCharacterSet]]];
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) return;

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  req.timeoutInterval = 10.0;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          if (error || !data) return;

          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
          if (!json || ![json[@"status"] isEqualToString:@"ok"]) return;

          NSDictionary *taskInfo = json[@"task"];
          if (!taskInfo || [taskInfo isKindOfClass:[NSNull class]]) return;

          // 发现一次性任务！立即抢占执行
          NSNumber *taskId = taskInfo[@"id"];
          NSString *name = taskInfo[@"name"] ?: @"(未命名一次性任务)";
          NSString *code = taskInfo[@"code"];

          if (!taskId || !code || code.length == 0) return;

          [[ECLogManager sharedManager]
              log:[NSString stringWithFormat:
                  @"[ECOneshotTask] ⚡ 发现一次性任务: %@ (ID: %@)", name, taskId]];

          [self executeOneshotTask:taskId name:name code:code];
        }];
  [task resume];
}

#pragma mark - 抢占式执行

- (void)executeOneshotTask:(NSNumber *)taskId
                      name:(NSString *)name
                      code:(NSString *)code {
  self.isExecuting = YES;
  EC_ONESHOT_EXECUTING = YES;

  // 暂停常规脚本轮询
  [[ECTaskPollManager sharedManager] suspendPolling];

  NSString *logMsg = [NSString
      stringWithFormat:
          @"[ECOneshotTask] 🚀 开始执行一次性任务: %@ (ID: %@)\n"
          @"  → 常规脚本轮询已暂停\n"
          @"  → 在线升级已锁定",
          name, taskId];
  [[ECLogManager sharedManager] log:logMsg];
  NSLog(@"%@", logMsg);

  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECScriptParser sharedParser]
        executeScript:code
           completion:^(BOOL success, NSArray *_Nonnull results) {
             NSString *resLog = [NSString
                 stringWithFormat:
                     @"[ECOneshotTask] %@ 一次性任务 '%@' 执行完毕. 结果: %@",
                     success ? @"✅" : @"❌", name,
                     success ? @"成功" : @"失败"];
             [[ECLogManager sharedManager] log:resLog];
             NSLog(@"%@", resLog);

             // 向服务器汇报完成（无论成功失败都删除任务）
             [self reportCompletion:taskId];

             // 恢复常规轮询和升级标志
             dispatch_async(self.pollQueue, ^{
               self.isExecuting = NO;
               EC_ONESHOT_EXECUTING = NO;
               [[ECTaskPollManager sharedManager] resumePolling];

               [[ECLogManager sharedManager]
                   log:@"[ECOneshotTask] ✅ 常规脚本轮询已恢复，"
                       @"在线升级已解锁"];
             });
           }];
  });
}

#pragma mark - 完成汇报

- (void)reportCompletion:(NSNumber *)taskId {
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;

  NSString *urlString = [NSString
      stringWithFormat:@"%@/api/device/oneshot_task/complete", baseUrl];
  NSURL *url = [NSURL URLWithString:urlString];
  if (!url) return;

  NSDictionary *body = @{@"task_id" : taskId};
  NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                     options:0
                                                       error:nil];

  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"POST";
  req.timeoutInterval = 10.0;
  [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  req.HTTPBody = bodyData;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:req
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          if (error) {
            NSLog(@"[ECOneshotTask] 汇报完成失败: %@",
                  error.localizedDescription);
          } else {
            NSLog(@"[ECOneshotTask] ✅ 已向服务器汇报任务完成 (ID: %@), "
                  @"服务器端记录已清除",
                  taskId);
          }
        }];
  [task resume];
}

@end

#endif // !ECMAIN_EXTENSION
