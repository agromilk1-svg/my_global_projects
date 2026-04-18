/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBAlertsMonitor.h"

#import "FBAlert.h"
#import "FBLogger.h"
#import "XCUIApplication+FBAlert.h"
#import "XCUIApplication+FBHelpers.h"

static const NSTimeInterval FB_MONTORING_INTERVAL = 2.0;

@interface FBAlertsMonitor()

@property (atomic) BOOL isMonitoring;
// [v2025优化] 使用独立的后台串行队列代替主队列
// 这样即使 XCTest IPC 死锁（查询 SpringBoard UI 树超时），
// 也仅阻塞 monitor 线程，不影响 WDA 的 HTTP 服务主线程
@property (nonatomic, strong) dispatch_queue_t monitorQueue;

@end

@implementation FBAlertsMonitor

- (instancetype)init
{
  if ((self = [super init])) {
    _isMonitoring = NO;
    _delegate = nil;
    _monitorQueue = dispatch_queue_create("com.ecwda.alerts.monitor", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (void)scheduleNextTick
{
  if (!self.isMonitoring) {
    return;
  }

  dispatch_time_t delta = (int64_t)(FB_MONTORING_INTERVAL * NSEC_PER_SEC);

  if (nil == self.delegate) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delta), self.monitorQueue, ^{
      [self scheduleNextTick];
    });
    return;
  }

  // [v2025优化] 在独立后台队列执行弹窗检测
  // 相比原实现（主队列 + 遍历所有活跃 App），改为：
  // 1. 后台串行队列执行，WDA HTTP 主线程不受影响
  // 2. 直接查询 SpringBoard（系统弹窗均属 SpringBoard 管辖），跳过耗时的 fb_activeApplications 枚举
  dispatch_async(self.monitorQueue, ^{
    XCUIElement *alertElement = nil;
    @try {
      XCUIApplication *systemApp = XCUIApplication.fb_systemApplication;
      alertElement = systemApp.fb_alertElement;
      if (nil != alertElement) {
        [self.delegate didDetectAlert:[FBAlert alertWithElement:alertElement]];
      }
    } @catch (NSException *e) {
      [FBLogger logFmt:@"[AlertMonitor] 检测弹窗时出现异常: %@", e.reason];
    }

    if (self.isMonitoring) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delta), self.monitorQueue, ^{
        [self scheduleNextTick];
      });
    }
  });
}

- (void)enable
{
  if (self.isMonitoring) {
    return;
  }

  self.isMonitoring = YES;
  [FBLogger log:@"[AlertMonitor] ✅ 智能弹窗监控已启用（后台队列模式）"];
  [self scheduleNextTick];
}

- (void)disable
{
  if (!self.isMonitoring) {
    return;
  }

  self.isMonitoring = NO;
  [FBLogger log:@"[AlertMonitor] ⛔ 智能弹窗监控已停用"];
}

@end
