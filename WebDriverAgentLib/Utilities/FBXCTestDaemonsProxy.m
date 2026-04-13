/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBXCTestDaemonsProxy.h"

#import <objc/runtime.h>

#import "FBConfiguration.h"
#import "FBErrorBuilder.h"
#import "FBExceptions.h"
#import "FBLogger.h"
#import "FBRunLoopSpinner.h"
#import "FBScreenRecordingPromise.h"
#import "FBScreenRecordingRequest.h"
#import "XCTestDriver.h"
#import "XCTRunnerDaemonSession.h"
#import "XCUIApplication.h"
#import "XCUIDevice.h"

#define LAUNCH_APP_TIMEOUT_SEC 300

static void (*originalLaunchAppMethod)(id, SEL, NSString*, NSString*, NSArray*, NSDictionary*, void (^)(_Bool, NSError *));

static void swizzledLaunchApp(id self, SEL _cmd, NSString *path, NSString *bundleID,
                              NSArray *arguments, NSDictionary *environment,
                              void (^reply)(_Bool, NSError *))
{
  __block BOOL isSuccessful;
  __block NSError *error;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  originalLaunchAppMethod(self, _cmd, path, bundleID, arguments, environment, ^(BOOL passed, NSError *innerError) {
    isSuccessful = passed;
    error = innerError;
    dispatch_semaphore_signal(sem);
  });
  int64_t timeoutNs = (int64_t)(LAUNCH_APP_TIMEOUT_SEC * NSEC_PER_SEC);
  if (0 != dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, timeoutNs))) {
    NSString *message = [NSString stringWithFormat:@"The application '%@' cannot be launched within %d seconds timeout",
                         bundleID ?: path, LAUNCH_APP_TIMEOUT_SEC];
    @throw [NSException exceptionWithName:FBTimeoutException reason:message userInfo:nil];
  }
  if (!isSuccessful || nil != error) {
    [FBLogger logFmt:@"%@", error.description];
    NSString *message = error.description ?: [NSString stringWithFormat:@"The application '%@' is not installed on the device under test",
                         bundleID ?: path];
    @throw [NSException exceptionWithName:FBApplicationMissingException reason:message userInfo:nil];
  }
  reply(isSuccessful, error);
}

@implementation FBXCTestDaemonsProxy

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-load-method"

+ (void)load
{
  [self.class swizzleLaunchApp];
}

#pragma clang diagnostic pop

+ (void)swizzleLaunchApp {
  Method original = class_getInstanceMethod([XCTRunnerDaemonSession class],
                                            @selector(launchApplicationWithPath:bundleID:arguments:environment:completion:));
  if (original == nil) {
    [FBLogger log:@"Could not find method -[XCTRunnerDaemonSession launchApplicationWithPath:]"];
    return;
  }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wcast-function-type-strict"
  // Workaround for https://github.com/appium/WebDriverAgent/issues/702
  originalLaunchAppMethod = (void(*)(id, SEL, NSString*, NSString*, NSArray*, NSDictionary*, void (^)(_Bool, NSError *))) method_getImplementation(original);
  method_setImplementation(original, (IMP)swizzledLaunchApp);
#pragma clang diagnostic pop
}

// [v1760] 文件级标志位：控制 testRunnerProxy 是否需要刷新 XPC 连接
static BOOL _proxyNeedsRefresh = YES;

+ (id<XCTestManager_ManagerInterface>)testRunnerProxy
{
  // [v1760] 移除 dispatch_once，以支持截图超时后强制刷新 XPC 连接
  static id<XCTestManager_ManagerInterface> proxy = nil;
  
  if ([FBConfiguration shouldUseSingletonTestManager]) {
    if (_proxyNeedsRefresh || proxy == nil) {
      [FBLogger logFmt:@"[v1760] 正在刷新 testRunnerProxy（singleton 模式）"];
      proxy = [self.class retrieveTestRunnerProxy];
      _proxyNeedsRefresh = NO;
    }
  } else {
    [FBLogger logFmt:@"Using general test manager"];
    proxy = [self.class retrieveTestRunnerProxy];
  }
  NSAssert(proxy != NULL, @"Could not determine testRunnerProxy", proxy);
  return proxy;
}

// [v1760] 截图超时后调用此方法，强制下次重新获取 daemon proxy
// 解决 testmanagerd XPC 连接 stale 后永久超时的问题
+ (void)invalidateTestRunnerProxy
{
  [FBLogger logFmt:@"[v1760] ⚠️ invalidateTestRunnerProxy: 标记 proxy 需要刷新"];
  _proxyNeedsRefresh = YES;
}

+ (id<XCTestManager_ManagerInterface>)retrieveTestRunnerProxy
{
  return ((XCTRunnerDaemonSession *)[XCTRunnerDaemonSession sharedSession]).daemonProxy;
}

// [v1762] IPC 超时保护：防止 synthesizeEvent 卡死时永久阻塞主线程
// 超时后返回错误，ECScriptParser 的 performWDAAction 会自动重试
static const NSTimeInterval SYNTHESIZE_EVENT_TIMEOUT = 15.0;

+ (BOOL)synthesizeEventWithRecord:(XCSynthesizedEventRecord *)record error:(NSError *__autoreleasing*)error
{
  __block NSError *innerError = nil;
  BOOL completed = [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    void (^errorHandler)(NSError *) = ^(NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      }
      completion();
    };

    XCEventGeneratorHandler handlerBlock = ^(XCSynthesizedEventRecord *innerRecord, NSError *invokeError) {
      errorHandler(invokeError);
    };
    [[XCUIDevice.sharedDevice eventSynthesizer] synthesizeEvent:record completion:(id)^(BOOL result, NSError *invokeError) {
      handlerBlock(record, invokeError);
    }];
  } timeout:SYNTHESIZE_EVENT_TIMEOUT];

  // [v1762] IPC 超时：释放主线程，让 HTTP 服务恢复响应能力
  if (!completed) {
    [FBLogger logFmt:@"[v1762] ⚠️ synthesizeEvent IPC 超时 (%.0fs)，释放主线程", SYNTHESIZE_EVENT_TIMEOUT];
    if (error) {
      *error = [[FBErrorBuilder.builder
          withDescriptionFormat:@"XCTest IPC timeout after %.0fs for event synthesis", SYNTHESIZE_EVENT_TIMEOUT]
          build];
    }
    return NO;
  }

  if (nil != innerError) {
    if (error) {
      *error = innerError;
    }
    return NO;
  }
  return YES;
}

+ (BOOL)openURL:(NSURL *)url usingApplication:(NSString *)bundleId error:(NSError *__autoreleasing*)error
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(openURL:usingApplication:completion:)]) {
    return [[[FBErrorBuilder builder]
      withDescriptionFormat:@"The current Xcode SDK does not support opening of URLs with given application"]
     buildError:error];
  }

  __block NSError *innerError = nil;
  __block BOOL didSucceed = NO;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session openURL:url usingApplication:bundleId completion:^(bool result, NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      } else {
        didSucceed = result;
      }
      completion();
    }];
  }];
  if (nil != innerError && error) {
    *error = innerError;
  }
  return didSucceed;
}

+ (BOOL)openDefaultApplicationForURL:(NSURL *)url error:(NSError *__autoreleasing*)error
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(openDefaultApplicationForURL:completion:)]) {
    return [[[FBErrorBuilder builder]
      withDescriptionFormat:@"The current Xcode SDK does not support opening of URLs. Consider upgrading to Xcode 14.3+/iOS 16.4+"]
     buildError:error];
  }

  __block NSError *innerError = nil;
  __block BOOL didSucceed = NO;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session openDefaultApplicationForURL:url completion:^(bool result, NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      } else {
        didSucceed = result;
      }
      completion();
    }];
  }];
  if (nil != innerError && error) {
    *error = innerError;
  }
  return didSucceed;
}

#if !TARGET_OS_TV
+ (BOOL)setSimulatedLocation:(CLLocation *)location error:(NSError *__autoreleasing*)error
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(setSimulatedLocation:completion:)]) {
    return [[[FBErrorBuilder builder]
      withDescriptionFormat:@"The current Xcode SDK does not support location simulation. Consider upgrading to Xcode 14.3+/iOS 16.4+"]
     buildError:error];
  }
  if (![session supportsLocationSimulation]) {
    return [[[FBErrorBuilder builder]
      withDescriptionFormat:@"Your device does not support location simulation"]
     buildError:error];
  }

  __block NSError *innerError = nil;
  __block BOOL didSucceed = NO;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session setSimulatedLocation:location completion:^(bool result, NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      } else {
        didSucceed = result;
      }
      completion();
    }];
  }];
  if (nil != innerError && error) {
    *error = innerError;
  }
  return didSucceed;
}

+ (nullable CLLocation *)getSimulatedLocation:(NSError *__autoreleasing*)error;
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(getSimulatedLocationWithReply:)]) {
    [[[FBErrorBuilder builder]
      withDescriptionFormat:@"The current Xcode SDK does not support location simulation. Consider upgrading to Xcode 14.3+/iOS 16.4+"]
     buildError:error];
    return nil;
  }
  if (![session supportsLocationSimulation]) {
    [[[FBErrorBuilder builder]
      withDescriptionFormat:@"Your device does not support location simulation"]
     buildError:error];
    return nil;
  }

  __block NSError *innerError = nil;
  __block CLLocation *location = nil;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session getSimulatedLocationWithReply:^(CLLocation *reply, NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      } else {
        location = reply;
      }
      completion();
    }];
  }];
  if (nil != innerError && error) {
    *error = innerError;
  }
  return location;
}

+ (BOOL)clearSimulatedLocation:(NSError *__autoreleasing*)error
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(clearSimulatedLocationWithReply:)]) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"The current Xcode SDK does not support location simulation. Consider upgrading to Xcode 14.3+/iOS 16.4+"]
       buildError:error];
  }
  if (![session supportsLocationSimulation]) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"Your device does not support location simulation"]
       buildError:error];
  }

  __block NSError *innerError = nil;
  __block BOOL didSucceed = NO;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session clearSimulatedLocationWithReply:^(bool result, NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      } else {
        didSucceed = result;
      }
      completion();
    }];
  }];
  if (nil != innerError && error) {
    *error = innerError;
  }
  return didSucceed;
}
#endif

+ (FBScreenRecordingPromise *)startScreenRecordingWithRequest:(FBScreenRecordingRequest *)request
                                                        error:(NSError *__autoreleasing*)error
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(startScreenRecordingWithRequest:withReply:)]) {
    [[[FBErrorBuilder builder]
      withDescriptionFormat:@"The current Xcode SDK does not support screen recording. Consider upgrading to Xcode 15+/iOS 17+"]
     buildError:error];
    return nil;
  }
  if (![session supportsScreenRecording]) {
    [[[FBErrorBuilder builder]
      withDescriptionFormat:@"Your device does not support screen recording"]
     buildError:error];
    return nil;
  }

  id nativeRequest = [request toNativeRequestWithError:error];
  if (nil == nativeRequest) {
    return nil;
  }

  __block id futureMetadata = nil;
  __block NSError *innerError = nil;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session startScreenRecordingWithRequest:nativeRequest withReply:^(id reply, NSError *invokeError) {
      if (nil == invokeError) {
        futureMetadata = reply;
      } else {
        innerError = invokeError;
      }
      completion();
    }];
  }];
  if (nil != innerError) {
    if (error) {
      *error = innerError;
    }
    return nil;
  }
  return [[FBScreenRecordingPromise alloc] initWithNativePromise:futureMetadata];
}

+ (BOOL)stopScreenRecordingWithUUID:(NSUUID *)uuid error:(NSError *__autoreleasing*)error
{
  XCTRunnerDaemonSession *session = [XCTRunnerDaemonSession sharedSession];
  if (![session respondsToSelector:@selector(stopScreenRecordingWithUUID:withReply:)]) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"The current Xcode SDK does not support screen recording. Consider upgrading to Xcode 15+/iOS 17+"]
       buildError:error];

  }
  if (![session supportsScreenRecording]) {
    return [[[FBErrorBuilder builder]
        withDescriptionFormat:@"Your device does not support screen recording"]
       buildError:error];
  }

  __block NSError *innerError = nil;
  [FBRunLoopSpinner spinUntilCompletion:^(void(^completion)(void)){
    [session stopScreenRecordingWithUUID:uuid withReply:^(NSError *invokeError) {
      if (nil != invokeError) {
        innerError = invokeError;
      }
      completion();
    }];
  }];
  if (nil != innerError && error) {
    *error = innerError;
  }
  return nil == innerError;
}

@end
