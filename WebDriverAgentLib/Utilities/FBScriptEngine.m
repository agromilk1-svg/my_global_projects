//
//  FBScriptEngine.m
//  WebDriverAgentLib
//
//  JavaScript 脚本引擎实现
//

#import "FBScriptEngine.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <XCTest/XCTest.h>
#import "FBOCREngine.h"
#import "FBScreenshot.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"

// [v1738-fix] 不再需要 fb_activeApplication 前置声明
// 触摸操作改用 XCPointerEventPath 直接坐标注入，无需 App 引用

// WDA API 协议 - 暴露给 JavaScript
@protocol FBWDAJSExports <JSExport>

// 触摸操作
- (void)tapAtX:(double)x y:(double)y;
- (void)doubleTapAtX:(double)x y:(double)y;
- (void)longPressAtX:(double)x y:(double)y duration:(double)duration;
- (void)swipeFromX:(double)fromX
             fromY:(double)fromY
               toX:(double)toX
               toY:(double)toY;
- (void)swipeUp;
- (void)swipeDown;
- (void)swipeLeft;
- (void)swipeRight;

// 系统操作
- (void)home;
- (void)sleepSeconds:(double)seconds;
- (void)launchApp:(NSString *)bundleId;

// OCR
- (NSArray *)ocr;
- (NSDictionary *)findText:(NSString *)text;
- (void)tapText:(NSString *)text;

// 工具
- (double)randomMin:(double)min max:(double)max;
- (void)log:(NSString *)message;

// 屏幕信息
- (double)screenWidth;
- (double)screenHeight;
- (void)setScreenSizeWidth:(double)width height:(double)height;

@end

@class FBWDABridge;

// 内部扩展，重新声明属性为 readwrite
@interface FBScriptEngine ()
@property(nonatomic, strong) JSContext *jsContext;
@property(nonatomic, strong) FBWDABridge *wdaBridge;
@property(nonatomic, strong) dispatch_queue_t scriptQueue;
@property(nonatomic, readwrite) FBScriptStatus status;
@property(nonatomic, readwrite) NSString *currentScriptId;
@property(nonatomic, readwrite) NSInteger executedCommands;
@property(nonatomic, strong) NSTimer *pollTimer;
@property(nonatomic, copy) NSString *pollServerURL;
@property(nonatomic, strong) NSMutableDictionary *scheduledScripts;
@end

// WDA API 实现类
@interface FBWDABridge : NSObject <FBWDAJSExports>
@property(nonatomic, unsafe_unretained) FBScriptEngine *engine;
@property(nonatomic, assign) CGFloat cachedWidth;
@property(nonatomic, assign) CGFloat cachedHeight;
@end

@implementation FBWDABridge

- (instancetype)init {
  self = [super init];
  if (self) {
    // Default values for common iPhone screen sizes
    // These can be updated via setScreenSizeWidth:height:
    _cachedWidth = 375;
    _cachedHeight = 812;
  }
  return self;
}

- (void)setScreenSizeWidth:(double)width height:(double)height {
  self.cachedWidth = width;
  self.cachedHeight = height;
  // [self log:[NSString stringWithFormat:@"Screen size set to %dx%d",
  // (int)width, (int)height]];
}

#pragma mark - 触摸操作

- (void)tapAtX:(double)x y:(double)y {
  // 添加随机偏移模拟人手
  double offsetX = (arc4random_uniform(20) - 10);
  double offsetY = (arc4random_uniform(20) - 10);
  x += offsetX;
  y += offsetY;

  // [v1738-fix] 使用 XCPointerEventPath 直接坐标点击，
  // 彻底避免 fb_activeApplication 遍历 Accessibility 树（TikTok 场景下可能 10-30s）
  CGPoint targetPoint = CGPointMake(x, y);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:0.05];
  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"scriptTap"];
  [record addPointerEventPath:path];
  [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

  self.engine.executedCommands++;
}

- (void)doubleTapAtX:(double)x y:(double)y {
  // [v1738-fix] 使用 XCPointerEventPath 直接坐标双击
  CGPoint targetPoint = CGPointMake(x, y);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:0.05];
  [path pressDownAtOffset:0.1];
  [path liftUpAtOffset:0.15];
  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"scriptDoubleTap"];
  [record addPointerEventPath:path];
  [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

  self.engine.executedCommands++;
}

- (void)longPressAtX:(double)x y:(double)y duration:(double)duration {
  // [v1738-fix] 使用 XCPointerEventPath 直接坐标长按
  CGPoint targetPoint = CGPointMake(x, y);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:targetPoint offset:0];
  [path liftUpAtOffset:duration];
  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"scriptLongPress"];
  [record addPointerEventPath:path];
  [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

  self.engine.executedCommands++;
}

- (void)swipeFromX:(double)fromX
             fromY:(double)fromY
               toX:(double)toX
               toY:(double)toY {
  // 添加随机偏移
  fromX += (arc4random_uniform(30) - 15);
  fromY += (arc4random_uniform(30) - 15);
  toX += (arc4random_uniform(30) - 15);
  toY += (arc4random_uniform(30) - 15);

  // [v1738-fix] 使用 XCPointerEventPath 直接坐标滑动
  CGPoint startPoint = CGPointMake(fromX, fromY);
  CGPoint endPoint = CGPointMake(toX, toY);
  XCPointerEventPath *path =
      [[XCPointerEventPath alloc] initForTouchAtPoint:startPoint offset:0];
  [path moveToPoint:endPoint atOffset:0.5];
  [path liftUpAtOffset:0.55];
  XCSynthesizedEventRecord *record =
      [[XCSynthesizedEventRecord alloc] initWithName:@"scriptSwipe"];
  [record addPointerEventPath:path];
  [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:nil];

  self.engine.executedCommands++;
}

- (void)swipeUp {
  double cx = self.cachedWidth / 2;
  double startY = self.cachedHeight * (0.7 + (arc4random_uniform(15) / 100.0));
  double endY = self.cachedHeight * (0.2 + (arc4random_uniform(10) / 100.0));
  [self swipeFromX:cx fromY:startY toX:cx toY:endY];
}

- (void)swipeDown {
  double cx = self.cachedWidth / 2;
  double startY = self.cachedHeight * 0.3;
  double endY = self.cachedHeight * 0.8;
  [self swipeFromX:cx fromY:startY toX:cx toY:endY];
}

- (void)swipeLeft {
  double cy = self.cachedHeight / 2;
  double startX = self.cachedWidth * 0.8;
  double endX = self.cachedWidth * 0.2;
  [self swipeFromX:startX fromY:cy toX:endX toY:cy];
}

- (void)swipeRight {
  double cy = self.cachedHeight / 2;
  double startX = self.cachedWidth * 0.2;
  double endX = self.cachedWidth * 0.8;
  [self swipeFromX:startX fromY:cy toX:endX toY:cy];
}

#pragma mark - 系统操作

- (void)home {
  [self executeWDACommand:@"home" params:@{}];
  self.engine.executedCommands++;
  // [self log:@"home()"];
}

- (void)sleepSeconds:(double)seconds {
  [NSThread sleepForTimeInterval:seconds];
  // [self log:[NSString stringWithFormat:@"sleep(%.1f)", seconds]];
}

- (void)launchApp:(NSString *)bundleId {
  [self executeWDACommand:@"launchApp" params:@{@"bundleId" : bundleId}];
  self.engine.executedCommands++;
  // [self log:[NSString stringWithFormat:@"launchApp(%@)", bundleId]];
}

#pragma mark - OCR (直接内存调用，消除 HTTP 回环死锁风险)

// 内部辅助：带超时保护的截图
- (UIImage *)takeScreenshotWithTimeout:(NSTimeInterval)timeout {
  __block NSData *screenshotData = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [FBScreenshot takeInOriginalResolutionWithQuality:2 error:&error];
    dispatch_semaphore_signal(sema);
  });

  long result = dispatch_semaphore_wait(sema,
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
  if (result != 0 || !screenshotData) return nil;
  return [UIImage imageWithData:screenshotData];
}

- (NSArray *)ocr {
  UIImage *screenshot = [self takeScreenshotWithTimeout:10.0];
  if (!screenshot) return @[];

  NSArray<FBOCRTextResult *> *results =
      [[FBOCREngine sharedEngine] recognizeText:screenshot];
  CGFloat scale = [UIScreen mainScreen].scale;

  NSMutableArray *jsonResults = [NSMutableArray array];
  for (FBOCRTextResult *res in results) {
    CGRect f = res.frame;
    [jsonResults addObject:@{
      @"text"   : res.text ?: @"",
      @"x"      : @(f.origin.x / scale),
      @"y"      : @(f.origin.y / scale),
      @"width"  : @(f.size.width / scale),
      @"height" : @(f.size.height / scale)
    }];
  }
  return jsonResults;
}

- (NSDictionary *)findText:(NSString *)text {
  UIImage *screenshot = [self takeScreenshotWithTimeout:10.0];
  if (!screenshot) return @{};

  FBOCRTextResult *result =
      [[FBOCREngine sharedEngine] findText:text inImage:screenshot];
  if (!result) return @{};

  CGFloat scale = [UIScreen mainScreen].scale;
  CGRect f = result.frame;
  return @{
    @"found"  : @YES,
    @"x"      : @(f.origin.x / scale),
    @"y"      : @(f.origin.y / scale),
    @"width"  : @(f.size.width / scale),
    @"height" : @(f.size.height / scale),
    @"text"   : result.text ?: @""
  };
}

- (void)tapText:(NSString *)text {
  NSDictionary *result = [self findText:text];
  if ([result[@"found"] boolValue]) {
    double x = [result[@"x"] doubleValue] + [result[@"width"] doubleValue] / 2;
    double y = [result[@"y"] doubleValue] + [result[@"height"] doubleValue] / 2;
    [self tapAtX:x y:y];
  }
}

#pragma mark - 工具

- (double)randomMin:(double)min max:(double)max {
  double range = max - min;
  double r = (double)arc4random() / UINT32_MAX;
  return min + r * range;
}

- (void)log:(NSString *)message {
  // NSLog(@"[Script] %@", message);
}

- (double)screenWidth {
  return self.cachedWidth;
}

- (double)screenHeight {
  return self.cachedHeight;
}

#pragma mark - Internal

- (NSDictionary *)executeWDACommand:(NSString *)command
                             params:(NSDictionary *)params {
  // 内部执行 WDA 命令
  // 使用本地 HTTP 回环调用 WDA 命令
  // 这种方式兼容性最好，不需要 hack 内部路由
  // WDA 默认监听 10088
  // 注意：需要确保这些请求不会造成死锁（WDA 处理能力）
  // 且需要知道 Session ID。通常 /status 可以获取 sessionId。
  // 为了简化，我们假设这里使用简单的 JSON body，且 WDA 已经修改为支持无 Session
  // ID 的一部分命令（或自动获）。 但标准的 WDA 需要 Session。

  // 简单起见，我们先打印日志，因为实际对接需要根据 WDA 版本调整。
  // 如果是 ECWDA，可能有简化的接口。
  // NSLog(@"[Script] Execute: %@ %@", command, params);

  // 构造同步请求调用 localhost
  // 注意：这可能会阻塞脚本线程，但这正是我们要的（同步执行）
  // 假设端口 10088
  NSString *urlString =
      [NSString stringWithFormat:@"http://localhost:10088/wda/%@", command];
  // 对于 tap/swipe 等，WDA 可能期望 /session/:id/...
  // 这里我们假设 ECWDA 添加了 /wda/ 前缀的快捷指令，或者我们之后在
  // FBECWDACommands 中添加这些快捷指令。

  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
  request.HTTPMethod = @"POST";
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:params
                                                     options:0
                                                       error:nil];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  dispatch_semaphore_t sema = dispatch_semaphore_create(0);
  __block NSDictionary *jsonResponse = nil;

  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          if (data) {
            jsonResponse = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil];
          }
          dispatch_semaphore_signal(sema);
        }] resume];

  // 等待最多 5 秒
  dispatch_semaphore_wait(sema,
                          dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

  return jsonResponse ?: @{};
}

@end

// ========== 脚本引擎实现 ==========

@implementation FBScriptEngine

+ (instancetype)sharedEngine {
  static FBScriptEngine *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[FBScriptEngine alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _status = FBScriptStatusIdle;
    _executedCommands = 0;
    _scriptQueue =
        dispatch_queue_create("com.ecwda.scriptengine", DISPATCH_QUEUE_SERIAL);
    _scheduledScripts = [NSMutableDictionary dictionary];
    [self setupJSContext];
  }
  return self;
}

- (void)setupJSContext {
  self.jsContext = [[JSContext alloc] init];
  self.wdaBridge = [[FBWDABridge alloc] init];
  self.wdaBridge.engine = self;

  // 注入 wda 对象
  self.jsContext[@"wda"] = self.wdaBridge;

  // 注入 console.log
  self.jsContext[@"console"][@"log"] = ^(NSString *message) {
    // NSLog(@"[JS] %@", message);
  };

  // 异常处理
  self.jsContext.exceptionHandler = ^(JSContext *ctx, JSValue *exception) {
    // NSLog(@"[Script Error] %@", exception);
  };

  // 注入辅助函数和 JavaScript 友好的 API
  [self.jsContext
      evaluateScript:@"\
        // 简化 API 调用\n\
        "
                     @"wda.tap = function(x, y) { wda.tapAtX(x, "
                     @"y); };\n\
        wda.doubleTap = "
                     @"function(x, y) { wda.doubleTapAtX(x, y); "
                     @"};\n\
        wda.longPress = function(x, "
                     @"y, d) { wda.longPressAtX(x, y, d || 1); "
                     @"};\n\
        wda.swipe = function(fx, fy, "
                     @"tx, ty) { wda.swipeFromX(fx, fy, tx, ty); "
                     @"};\n\
        wda.sleep = function(s) { "
                     @"wda.sleepSeconds(s); };\n\
        "
                     @"wda.random = function(min, max) { return "
                     @"wda.randomMin(min, max); };\n\
        \n\
 "
                     @"       // 随机整数\n\
        wda.randomInt "
                     @"= function(min, max) {\n\
            "
                     @"return Math.floor(wda.random(min, max + "
                     @"1));\n\
        };\n\
    "];
}

- (NSString *)executeScript:(NSString *)script
                 completion:(FBScriptCompletionBlock)completion {
  NSString *scriptId = [[NSUUID UUID] UUIDString];

  dispatch_async(self.scriptQueue, ^{
    self.status = FBScriptStatusRunning;
    self.currentScriptId = scriptId;
    self.executedCommands = 0;

    @try {
      JSValue *result = [self.jsContext evaluateScript:script];

      self.status = FBScriptStatusCompleted;

      if (completion) {
        id resultObj = [result toObject];
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(YES, resultObj, nil);
        });
      }
    } @catch (NSException *exception) {
      self.status = FBScriptStatusFailed;

      if (completion) {
        NSError *error =
            [NSError errorWithDomain:@"FBScriptEngine"
                                code:-1
                            userInfo:@{
                              NSLocalizedDescriptionKey : exception.reason
                                  ?: @"Unknown error"
                            }];
        dispatch_async(dispatch_get_main_queue(), ^{
          completion(NO, nil, error);
        });
      }
    }

    self.currentScriptId = nil;
  });

  return scriptId;
}

- (void)stopScript {
  self.status = FBScriptStatusStopped;
  // TODO: 实现脚本中断机制
}

- (NSDictionary *)getStatus {
  return @{
    @"status" : @(self.status),
    @"statusName" : [self statusName],
    @"scriptId" : self.currentScriptId ?: [NSNull null],
    @"executedCommands" : @(self.executedCommands),
    @"polling" : @(self.pollTimer != nil),
    @"pollServer" : self.pollServerURL ?: [NSNull null]
  };
}

- (NSString *)statusName {
  switch (self.status) {
  case FBScriptStatusIdle:
    return @"idle";
  case FBScriptStatusRunning:
    return @"running";
  case FBScriptStatusCompleted:
    return @"completed";
  case FBScriptStatusFailed:
    return @"failed";
  case FBScriptStatusStopped:
    return @"stopped";
  }
}

#pragma mark - 定时执行

- (NSString *)scheduleScript:(NSString *)script
                      atTime:(NSString *)scheduleTime
                 repeatDaily:(BOOL)repeatDaily {
  NSString *scriptId = [[NSUUID UUID] UUIDString];

  // 解析时间
  NSDate *targetDate = [self parseScheduleTime:scheduleTime];
  if (!targetDate) {
    return nil;
  }

  // 创建定时器
  NSTimeInterval delay = [targetDate timeIntervalSinceNow];
  if (delay < 0) {
    delay += 24 * 60 * 60; // 明天同一时间
  }

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      self.scriptQueue, ^{
        [self executeScript:script completion:nil];

        if (repeatDaily) {
          // 重新调度
          [self scheduleScript:script atTime:scheduleTime repeatDaily:YES];
        }
      });

  self.scheduledScripts[scriptId] =
      @{@"script" : script, @"time" : scheduleTime, @"repeat" : @(repeatDaily)};

  return scriptId;
}

- (NSDate *)parseScheduleTime:(NSString *)timeStr {
  // 支持 "16:30" 或 "16:00-18:00" 格式
  if ([timeStr containsString:@"-"]) {
    NSArray *parts = [timeStr componentsSeparatedByString:@"-"];
    NSDate *start = [self parseTimeString:parts[0]];
    NSDate *end = [self parseTimeString:parts[1]];

    if (start && end) {
      // 随机选择范围内的时间
      NSTimeInterval interval = [end timeIntervalSinceDate:start];
      NSTimeInterval randomOffset =
          (double)arc4random() / UINT32_MAX * interval;
      return [start dateByAddingTimeInterval:randomOffset];
    }
  }

  return [self parseTimeString:timeStr];
}

- (NSDate *)parseTimeString:(NSString *)timeStr {
  NSArray *parts = [timeStr componentsSeparatedByString:@":"];
  if (parts.count < 2)
    return nil;

  NSCalendar *calendar = [NSCalendar currentCalendar];
  NSDateComponents *components = [calendar
      components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay
        fromDate:[NSDate date]];
  components.hour = [parts[0] integerValue];
  components.minute = [parts[1] integerValue];
  components.second = 0;

  return [calendar dateFromComponents:components];
}

- (void)cancelScheduledScript:(NSString *)scriptId {
  [self.scheduledScripts removeObjectForKey:scriptId];
}

#pragma mark - 任务轮询

- (void)configureTaskPolling:(NSString *)serverURL
                    interval:(NSTimeInterval)interval {
  [self stopTaskPolling];

  self.pollServerURL = serverURL;
  self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                    target:self
                                                  selector:@selector(pollTasks)
                                                  userInfo:nil
                                                   repeats:YES];

  // 立即执行一次
  [self pollTasks];
}

- (void)pollTasks {
  if (!self.pollServerURL)
    return;
  if (self.status == FBScriptStatusRunning)
    return; // 正在执行，跳过

  NSURL *url = [NSURL URLWithString:self.pollServerURL];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"GET";
  request.timeoutInterval = 10;

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          if (error || !data)
            return;

          NSError *jsonError = nil;
          NSDictionary *json =
              [NSJSONSerialization JSONObjectWithData:data
                                              options:0
                                                error:&jsonError];
          if (jsonError || !json)
            return;

          NSString *script = json[@"script"];
          if (script && script.length > 0) {
            // NSLog(@"[TaskPoll] Received script, executing...");
            [self executeScript:script completion:nil];
          }
        }];
  [task resume];
}

- (void)stopTaskPolling {
  [self.pollTimer invalidate];
  self.pollTimer = nil;
  self.pollServerURL = nil;
}

@end
