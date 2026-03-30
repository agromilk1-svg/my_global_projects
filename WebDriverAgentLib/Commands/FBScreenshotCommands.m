/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBScreenshotCommands.h"

#import "XCUIDevice+FBHelpers.h"

@implementation FBScreenshotCommands

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
  // [v1738-fix] 防卡死：将截图 + base64 编码移到后台线程，设置 10 秒超时。
  // 原代码直接在 WDA 主队列同步执行截图（XCTest IPC 最多 3s + PNG 降级 3s）
  // 加上 base64 编码（大图 1-3s），最坏情况阻塞主队列 9 秒，
  // 期间所有 WDA 请求（包括 /status 探活）全部排队，导致 ECMAIN 误判 WDA 卡死。
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

  if (waitResult != 0) {
    NSLog(@"[ECWDA] ⚠️ /screenshot 截图超时(10s)");
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

