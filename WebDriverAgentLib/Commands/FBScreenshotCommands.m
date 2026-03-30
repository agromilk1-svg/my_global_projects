/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBScreenshotCommands.h"
#import <libkern/OSAtomic.h>

#import "XCUIDevice+FBHelpers.h"
#import "FBXCTestDaemonsProxy.h"

@implementation FBScreenshotCommands

// [v1760] 截图并发保护：防止 MJPEG 轮询导致多个 _XCT_requestScreenshot 同时排队堵死 XPC
static volatile int32_t _screenshotInProgress = 0;

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes
{
  return
  @[
    [[FBRoute GET:@"/screenshot"].withoutSession respondWithTarget:self action:@selector(handleGetScreenshot:)],
    [[FBRoute GET:@"/screenshot"] respondWithTarget:self action:@selector(handleGetScreenshot:)],
  ];
}


#pragma mark - Commands

+ (id<FBResponsePayload>)handleGetScreenshot:(FBRouteRequest *)request
{
  // [v1760] 并发保护：如果上一次截图还在进行中，直接返回繁忙错误
  // 避免多个 _XCT_requestScreenshot IPC 调用同时排队导致 testmanagerd 死锁
  if (!OSAtomicCompareAndSwap32(0, 1, &_screenshotInProgress)) {
    return FBResponseWithStatus([FBCommandStatus
        unableToCaptureScreenErrorWithMessage:@"Screenshot already in progress (debounced)"
                                   traceback:nil]);
  }

  // [v1738-fix] 防卡死：将截图 + base64 编码移到后台线程，设置 10 秒超时。
  __block NSData *screenshotData = nil;
  __block NSError *screenshotError = nil;
  dispatch_semaphore_t sema = dispatch_semaphore_create(0);

  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError *error = nil;
    screenshotData = [[XCUIDevice sharedDevice] fb_screenshotWithError:&error];
    screenshotError = error;
    dispatch_semaphore_signal(sema);
  });

  long waitResult = dispatch_semaphore_wait(
      sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)));

  // 截图完成或超时，释放并发锁
  OSAtomicCompareAndSwap32(1, 0, &_screenshotInProgress);

  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ /screenshot 截图超时(10s)，将刷新 XPC 连接");
    // [v1760] 超时说明 testmanagerd XPC 可能已断开，标记 proxy 需要刷新
    [FBXCTestDaemonsProxy invalidateTestRunnerProxy];
    return FBResponseWithStatus([FBCommandStatus
        unableToCaptureScreenErrorWithMessage:@"Screenshot timed out (10s)"
                                   traceback:nil]);
  }

  if (nil == screenshotData) {
    return FBResponseWithStatus([FBCommandStatus
        unableToCaptureScreenErrorWithMessage:screenshotError.description
                                   traceback:nil]);
  }

  NSString *screenshot = [screenshotData base64EncodedStringWithOptions:0];
  return FBResponseWithObject(screenshot);
}

@end

