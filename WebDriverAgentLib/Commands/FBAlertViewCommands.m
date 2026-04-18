/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBAlertViewCommands.h"

#import "FBAlert.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "XCUIApplication+FBAlert.h"
#import "XCUIApplication+FBHelpers.h"

@implementation FBAlertViewCommands

#pragma mark - <FBCommandHandler>

+ (NSArray *)routes {
  return @[
    [[FBRoute GET:@"/alert/text"]
        respondWithTarget:self
                   action:@selector(handleAlertGetTextCommand:)],
    [[FBRoute GET:@"/alert/text"].withoutSession
        respondWithTarget:self
                   action:@selector(handleAlertGetTextCommand:)],
    [[FBRoute POST:@"/alert/text"]
        respondWithTarget:self
                   action:@selector(handleAlertSetTextCommand:)],
    [[FBRoute POST:@"/alert/accept"]
        respondWithTarget:self
                   action:@selector(handleAlertAcceptCommand:)],
    [[FBRoute POST:@"/alert/accept"].withoutSession
        respondWithTarget:self
                   action:@selector(handleAlertAcceptCommand:)],
    [[FBRoute POST:@"/alert/dismiss"]
        respondWithTarget:self
                   action:@selector(handleAlertDismissCommand:)],
    [[FBRoute POST:@"/alert/dismiss"].withoutSession
        respondWithTarget:self
                   action:@selector(handleAlertDismissCommand:)],
    [[FBRoute GET:@"/wda/alert/buttons"]
        respondWithTarget:self
                   action:@selector(handleGetAlertButtonsCommand:)],
    [[FBRoute GET:@"/wda/alert/buttons"].withoutSession
        respondWithTarget:self
                   action:@selector(handleGetAlertButtonsCommand:)],
    [[FBRoute GET:@"/wda/alert/info"]
        respondWithTarget:self
                   action:@selector(handleAlertInfoCommand:)],
    [[FBRoute GET:@"/wda/alert/info"].withoutSession
        respondWithTarget:self
                   action:@selector(handleAlertInfoCommand:)],
  ];
}

#pragma mark - Commands

+ (id<FBResponsePayload>)handleAlertGetTextCommand:(FBRouteRequest *)request {
  // 直接查询 SpringBoard，跳过耗时的 fb_activeApplication 枚举（在 TikTok
  // 等复杂 App 前台可能卡 10-30 秒）
  XCUIApplication *application = XCUIApplication.fb_systemApplication;
  NSString *alertText = [FBAlert alertWithApplication:application].text;
  if (!alertText) {
    return FBResponseWithStatus(
        [FBCommandStatus noAlertOpenErrorWithMessage:nil traceback:nil]);
  }
  return FBResponseWithObject(alertText);
}

+ (id<FBResponsePayload>)handleAlertSetTextCommand:(FBRouteRequest *)request {
  FBSession *session = request.session;
  id value = request.arguments[@"value"];
  if (!value) {
    return FBResponseWithStatus([FBCommandStatus
        invalidArgumentErrorWithMessage:@"Missing 'value' parameter"
                              traceback:nil]);
  }
  // [v1738-fix] 改用 fb_systemApplication，避免 session.activeApplication 遍历 Accessibility 树
  FBAlert *alert = [FBAlert alertWithApplication:XCUIApplication.fb_systemApplication];
  if (!alert.isPresent) {
    return FBResponseWithStatus(
        [FBCommandStatus noAlertOpenErrorWithMessage:nil traceback:nil]);
  }
  NSString *textToType = value;
  if ([value isKindOfClass:[NSArray class]]) {
    textToType = [value componentsJoinedByString:@""];
  }
  NSError *error;
  if (![alert typeText:textToType error:&error]) {
    return FBResponseWithStatus([FBCommandStatus
        unsupportedOperationErrorWithMessage:error.description
                                   traceback:[NSString
                                                 stringWithFormat:
                                                     @"%@",
                                                     NSThread
                                                         .callStackSymbols]]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleAlertAcceptCommand:(FBRouteRequest *)request {
  XCUIApplication *application = XCUIApplication.fb_systemApplication;
  NSString *name = request.arguments[@"name"];
  FBAlert *alert = [FBAlert alertWithApplication:application];
  NSError *error;

  if (!alert.isPresent) {
    return FBResponseWithStatus(
        [FBCommandStatus noAlertOpenErrorWithMessage:nil traceback:nil]);
  }
  if (name) {
    if (![alert clickAlertButton:name error:&error]) {
      return FBResponseWithStatus([FBCommandStatus
          invalidElementStateErrorWithMessage:error.description
                                    traceback:[NSString
                                                  stringWithFormat:
                                                      @"%@",
                                                      NSThread
                                                          .callStackSymbols]]);
    }
  } else if (![alert acceptWithError:&error]) {
    return FBResponseWithStatus([FBCommandStatus
        invalidElementStateErrorWithMessage:error.description
                                  traceback:[NSString
                                                stringWithFormat:
                                                    @"%@",
                                                    NSThread
                                                        .callStackSymbols]]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleAlertDismissCommand:(FBRouteRequest *)request {
  XCUIApplication *application = XCUIApplication.fb_systemApplication;
  NSString *name = request.arguments[@"name"];
  FBAlert *alert = [FBAlert alertWithApplication:application];
  NSError *error;

  if (!alert.isPresent) {
    return FBResponseWithStatus(
        [FBCommandStatus noAlertOpenErrorWithMessage:nil traceback:nil]);
  }
  if (name) {
    if (![alert clickAlertButton:name error:&error]) {
      return FBResponseWithStatus([FBCommandStatus
          invalidElementStateErrorWithMessage:error.description
                                    traceback:[NSString
                                                  stringWithFormat:
                                                      @"%@",
                                                      NSThread
                                                          .callStackSymbols]]);
    }
  } else if (![alert dismissWithError:&error]) {
    return FBResponseWithStatus([FBCommandStatus
        invalidElementStateErrorWithMessage:error.description
                                  traceback:[NSString
                                                stringWithFormat:
                                                    @"%@",
                                                    NSThread
                                                        .callStackSymbols]]);
  }
  return FBResponseWithOK();
}

+ (id<FBResponsePayload>)handleGetAlertButtonsCommand:
    (FBRouteRequest *)request {
  // [v1738-fix] 改用 fb_systemApplication（SpringBoard）直接查询弹窗，
  // 避免 session.activeApplication 在 TikTok 等复杂 App 中遍历 Accessibility 树（可能耗时 10-30s）
  XCUIApplication *application = XCUIApplication.fb_systemApplication;
  FBAlert *alert = [FBAlert alertWithApplication:application];

  if (!alert.isPresent) {
    return FBResponseWithStatus(
        [FBCommandStatus noAlertOpenErrorWithMessage:nil traceback:nil]);
  }
  NSArray *labels = alert.buttonLabels;
  return FBResponseWithObject(labels);
}

+ (id<FBResponsePayload>)handleAlertInfoCommand:
    (FBRouteRequest *)request {
  // [v2025] 极速弹窗探测：一次调用同时获取 Text 和 Buttons，避免多次 XCTest IPC 调用引发死锁。
  // 直接查询 SpringBoard 避免耗时的活跃 App 枚举
  XCUIApplication *application = XCUIApplication.fb_systemApplication;
  XCUIElement *alertElement = application.fb_alertElement;
  
  // 若无弹窗直接返回 null，不抛错，极大降低脚本层的出错率和耗时
  if (nil == alertElement) {
    return FBResponseWithObject([NSNull null]);
  }
  
  FBAlert *alert = [FBAlert alertWithElement:alertElement];
  if (!alert.isPresent) {
    return FBResponseWithObject([NSNull null]);
  }
  
  NSString *text = alert.text;
  NSArray *buttons = alert.buttonLabels;
  
  // [v2025优化] 增加一次轻量级重试：如果抓到了 text 但 buttons 为空，
  // 可能是系统弹窗还在动画中，UI 树尚未完全挂载。
  if (text && (!buttons || buttons.count == 0)) {
    [NSThread sleepForTimeInterval:0.5];
    buttons = alert.buttonLabels;
  }
  
  return FBResponseWithObject(@{
    @"text": text ?: @"",
    @"buttons": buttons ?: @[]
  });
}

@end
