/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBUnattachedAppLauncher.h"

#import <MobileCoreServices/MobileCoreServices.h>
#import <XCTest/XCTest.h>

#import "LSApplicationWorkspace.h"

@implementation FBUnattachedAppLauncher

+ (BOOL)launchAppWithBundleId:(NSString *)bundleId {
  return [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:bundleId];
}

+ (BOOL)launchAppInBackgroundWithBundleId:(NSString *)bundleId {
  // 方案 1（推荐）：利用 XCTest 框架的 XCUIApplication 启动 App
  // XCTest Runner 进程天然拥有 com.apple.springboard.debugapplications 等特权
  // 可以在锁屏状态下直接启动 App，无需 SBS 信任等级
  @try {
    XCUIApplication *app = [[XCUIApplication alloc] initWithBundleIdentifier:bundleId];
    [app activate];
    // activate 成功不会抛异常，检查状态
    BOOL success = (app.state == XCUIApplicationStateRunningForeground ||
                    app.state == XCUIApplicationStateRunningBackground ||
                    app.state == XCUIApplicationStateRunningBackgroundSuspended);
    NSLog(@"[FBUnattachedAppLauncher] XCUIApplication activate %@, 状态: %ld, 结果: %@",
          bundleId, (long)app.state, success ? @"✅" : @"⚠️");
    if (success) {
      return YES;
    }
  } @catch (NSException *exception) {
    NSLog(@"[FBUnattachedAppLauncher] XCUIApplication 启动异常: %@", exception.reason);
  }

  // 方案 2：XCTest 方式失败时，fallback 到 LSApplicationWorkspace（仅解锁时生效）
  NSLog(@"[FBUnattachedAppLauncher] XCUIApplication 未成功，回退到 LSApplicationWorkspace");
  return [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:bundleId];
}

@end
