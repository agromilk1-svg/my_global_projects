/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBMjpegServer.h"

#import <mach/mach_time.h>
@import UniformTypeIdentifiers;

#import "GCDAsyncSocket.h"
#import "FBConfiguration.h"
#import "FBLogger.h"
#import "FBScreenshot.h"
#import "FBImageProcessor.h"
#import "FBImageUtils.h"
#import "XCUIScreen.h"

static const NSUInteger MAX_FPS = 15;          // [fix] 帧率硬上限，防止配置意外放开
static const NSTimeInterval FRAME_TIMEOUT = 1.;
static const NSTimeInterval WRITE_TIMEOUT = 5.0; // [fix] 写入超时 5s：超时后 GCDAsyncSocket 自动断开僵尸客户端
static const NSTimeInterval ZOMBIE_CHECK_INTERVAL = 30.0; // [fix] 每 30s 主动扫描一次僵尸 socket

static NSString *const SERVER_NAME = @"WDA MJPEG Server";
static const char *QUEUE_NAME = "JPEG Screenshots Provider Queue";


@interface FBMjpegServer()

@property (nonatomic, readonly) dispatch_queue_t backgroundQueue;
@property (nonatomic, readonly) NSMutableArray<GCDAsyncSocket *> *listeningClients;
@property (nonatomic, readonly) FBImageProcessor *imageProcessor;
@property (nonatomic, readonly) long long mainScreenID;

@end


@implementation FBMjpegServer

- (instancetype)init
{
  if ((self = [super init])) {
    _listeningClients = [NSMutableArray array];
    dispatch_queue_attr_t queueAttributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
    _backgroundQueue = dispatch_queue_create(QUEUE_NAME, queueAttributes);
    // [fix] 不再在 init 时立即启动截图循环。
    // 截图循环只在第一个客户端连接时由 didClientSendData 触发，无客户端时完全静止。
    _imageProcessor = [[FBImageProcessor alloc] init];
    _mainScreenID = [XCUIScreen.mainScreen displayID];
  }
  return self;
}

- (void)scheduleNextScreenshotWithInterval:(uint64_t)timerInterval timeStarted:(uint64_t)timeStarted
{
  // [fix] 调度前先检查是否还有客户端，无客户端时停止调度（不再空转）
  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      return; // 无客户端：截图循环彻底停止，等待 didClientSendData 重新唤醒
    }
  }
  uint64_t timeElapsed = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - timeStarted;
  int64_t nextTickDelta = timerInterval - timeElapsed;
  if (nextTickDelta > 0) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, nextTickDelta), self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  } else {
    // 帧处理耗时超过帧间隔时，让出 50ms 给 XPC 避免 testmanagerd 饥饿
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  }
}

- (void)streamScreenshot
{
  NSUInteger framerate = FBConfiguration.mjpegServerFramerate;
  uint64_t timerInterval = (uint64_t)(1.0 / ((0 == framerate || framerate > MAX_FPS) ? MAX_FPS : framerate) * NSEC_PER_SEC);
  uint64_t timeStarted = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);

  // [fix] 每 30s 触发一次主动僵尸客户端扫描，防止 ECMAIN 异常断开后 socket 残留
  static uint64_t sLastZombieCheckTime = 0;
  uint64_t nowNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  if (sLastZombieCheckTime == 0 || (nowNs - sLastZombieCheckTime) > (uint64_t)(ZOMBIE_CHECK_INTERVAL * NSEC_PER_SEC)) {
    sLastZombieCheckTime = nowNs;
    [self _purgeZombieClients];
  }

  @synchronized (self.listeningClients) {
    if (0 == self.listeningClients.count) {
      [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
      return;
    }
  }

  NSError *error;
  CGFloat compressionQuality = MAX(FBMinCompressionQuality,
                                   MIN(FBMaxCompressionQuality, FBConfiguration.mjpegServerScreenshotQuality / 100.0));
  NSData *screenshotData = [FBScreenshot takeInOriginalResolutionWithScreenID:self.mainScreenID
                                                           compressionQuality:compressionQuality
                                                                          uti:UTTypeJPEG
                                                                      timeout:FRAME_TIMEOUT
                                                                        error:&error];
  if (nil == screenshotData) {
    [FBLogger logFmt:@"%@", error.description];
    [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
    return;
  }

  CGFloat scalingFactor = FBConfiguration.mjpegScalingFactor / 100.0;
  [self.imageProcessor submitImageData:screenshotData
                         scalingFactor:scalingFactor
                     completionHandler:^(NSData * _Nonnull scaled) {
    [self sendScreenshot:scaled];
  }];

  [self scheduleNextScreenshotWithInterval:timerInterval timeStarted:timeStarted];
}

- (void)sendScreenshot:(NSData *)screenshotData {
  NSString *chunkHeader = [NSString stringWithFormat:@"--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: %@\r\n\r\n", @(screenshotData.length)];
  NSMutableData *chunk = [[chunkHeader dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  [chunk appendData:screenshotData];
  [chunk appendData:(id)[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
  @synchronized (self.listeningClients) {
    for (GCDAsyncSocket *client in self.listeningClients) {
      if (!client.isConnected) {
        // 僵尸 socket：已断开但未收到回调，跳过写入（下一轮清理会移除）
        continue;
      }
      // [fix] withTimeout 从 -1 改为 WRITE_TIMEOUT(5s)：
      // 写入超时后 GCDAsyncSocket 会自动触发 disconnect + didClientDisconnect 回调，
      // 从而将僵尸客户端从 listeningClients 中移除，截图循环自然停止。
      [client writeData:chunk withTimeout:WRITE_TIMEOUT tag:0];
    }
  }
}

// [fix] 主动清理僵尸客户端：扫描 listeningClients 中所有 isConnected == NO 的 socket，
// 直接断开并触发 didClientDisconnect，防止 ECMAIN 异常退出后 10089 连接残留。
- (void)_purgeZombieClients {
  NSMutableArray<GCDAsyncSocket *> *deadClients = [NSMutableArray array];
  @synchronized (self.listeningClients) {
    for (GCDAsyncSocket *client in self.listeningClients) {
      if (!client.isConnected) {
        [deadClients addObject:client];
      }
    }
  }
  for (GCDAsyncSocket *dead in deadClients) {
    [FBLogger logFmt:@"[MjpegServer] 🧹 检测到僵尸客户端 %@:%d，主动断开",
     dead.connectedHost ?: @"unknown", dead.connectedPort];
    [dead disconnect]; // 触发 didClientDisconnect 回调，完成清理
  }
}

- (void)didClientConnect:(GCDAsyncSocket *)newClient
{
  [FBLogger logFmt:@"Got screenshots broadcast client connection at %@:%d", newClient.connectedHost, newClient.connectedPort];
  // Start broadcast only after there is any data from the client
  [newClient readDataWithTimeout:-1 tag:0];
}

- (void)didClientSendData:(GCDAsyncSocket *)client
{
  BOOL wasEmpty = NO;
  @synchronized (self.listeningClients) {
    if ([self.listeningClients containsObject:client]) {
      return;
    }
    wasEmpty = (self.listeningClients.count == 0);
    [self.listeningClients addObject:client];
  }

  [FBLogger logFmt:@"Starting screenshots broadcast for the client at %@:%d", client.connectedHost, client.connectedPort];
  NSString *streamHeader = [NSString stringWithFormat:@"HTTP/1.0 200 OK\r\nServer: %@\r\nConnection: close\r\nMax-Age: 0\r\nExpires: 0\r\nCache-Control: no-cache, private\r\nPragma: no-cache\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n", SERVER_NAME];
  [client writeData:(id)[streamHeader dataUsingEncoding:NSUTF8StringEncoding] withTimeout:-1 tag:0];

  // [fix] 首个客户端接入时唤醒截图循环（之前完全静止）
  if (wasEmpty) {
    [FBLogger log:@"[MjpegServer] 第一个客户端接入，唤醒截图循环"];
    dispatch_async(self.backgroundQueue, ^{
      [self streamScreenshot];
    });
  }
}

- (void)didClientDisconnect:(GCDAsyncSocket *)client
{
  @synchronized (self.listeningClients) {
    [self.listeningClients removeObject:client];
  }
  [FBLogger log:@"Disconnected a client from screenshots broadcast"];
}

@end
