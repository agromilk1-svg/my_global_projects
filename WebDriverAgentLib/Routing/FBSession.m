/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "FBSession.h"
#import "FBSession-Private.h"

#import <objc/runtime.h>

#import "FBXCAccessibilityElement.h"
#import "FBAlert.h"
#import "FBAlertsMonitor.h"
#import "FBConfiguration.h"
#import "FBElementCache.h"
#import "FBExceptions.h"
#import "FBLogger.h"
#import "FBMacros.h"
#import "FBScreenRecordingContainer.h"
#import "XCUIElement+FBClassChain.h"
#import "FBScreenRecordingPromise.h"
#import "FBScreenRecordingRequest.h"
#import "FBXCodeCompatibility.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIApplication+FBQuiescence.h"
#import "XCUIElement.h"
#import "XCUIElement+FBClassChain.h"

/*!
 The intial value for the default application property.
 Setting this value to `defaultActiveApplication` property forces WDA to use the internal
 automated algorithm to determine the active on-screen application
 */
NSString *const FBDefaultApplicationAuto = @"auto";

NSString *const FB_SAFARI_BUNDLE_ID = @"com.apple.mobilesafari";

@interface FBSession ()
@property (nullable, nonatomic) XCUIApplication *testedApplication;
@property (nonatomic) BOOL isTestedApplicationExpectedToRun;
@property (nonatomic) BOOL shouldAppsWaitForQuiescence;
@property (nonatomic, nullable) FBAlertsMonitor *alertsMonitor;
@property (nonatomic, readwrite) NSMutableDictionary<NSNumber *, NSMutableDictionary<NSString *, NSNumber *> *> *elementsVisibilityCache;
@end

@interface FBSession (FBAlertsMonitorDelegate)

- (void)didDetectAlert:(FBAlert *)alert;

@end

@implementation FBSession (FBAlertsMonitorDelegate)

- (void)didDetectAlert:(FBAlert *)alert
{
  // 优先级1：autoClickAlertSelector（class chain 选择器）
  NSString *autoClickAlertSelector = FBConfiguration.autoClickAlertSelector;
  if ([autoClickAlertSelector length] > 0) {
    @try {
      NSArray<XCUIElement*> *matches = [alert.alertElement fb_descendantsMatchingClassChain:autoClickAlertSelector
                                                                shouldReturnAfterFirstMatch:YES];
      if (matches.count > 0) {
          [[matches objectAtIndex:0] tap];
      }
    } @catch (NSException *e) {
      [FBLogger logFmt:@"Could not click at the alert element '%@'. Original error: %@",
       autoClickAlertSelector, e.description];
    }
    return;
  }

  if (nil == self.defaultAlertAction || 0 == self.defaultAlertAction.length) {
    return;
  }

  // 优先级2：smart 模式 — 根据弹窗内容智能选择按钮
  if ([self.defaultAlertAction isEqualToString:@"smart"]) {
    [self handleAlertSmart:alert];
    return;
  }

  // 优先级3：简单的 accept / dismiss
  NSError *error;
  if ([self.defaultAlertAction isEqualToString:@"accept"]) {
    if (![alert acceptWithError:&error]) {
      [FBLogger logFmt:@"Cannot accept the alert. Original error: %@", error.description];
    }
  } else if ([self.defaultAlertAction isEqualToString:@"dismiss"]) {
    if (![alert dismissWithError:&error]) {
      [FBLogger logFmt:@"Cannot dismiss the alert. Original error: %@", error.description];
    }
  } else {
    [FBLogger logFmt:@"'%@' default alert action is unsupported", self.defaultAlertAction];
  }
}

#pragma mark - 智能弹窗处理（smart 模式）

/// 根据弹窗内容和按钮文字，自动决定点击"允许"还是"拒绝"
/// 移植自 JavaScript 端 autoHandleAlert() 的完整逻辑
- (void)handleAlertSmart:(FBAlert *)alert
{
  @try {
    NSString *text = alert.text;
    NSArray<NSString *> *buttons = alert.buttonLabels;

    if (!buttons || buttons.count == 0) {
      NSError *error;
      [alert acceptWithError:&error];
      return;
    }

    NSString *msg = text ? [text lowercaseString] : @"";

    // 辅助块：检查弹窗内容是否包含任一关键词
    BOOL (^has)(NSArray<NSString *> *) = ^BOOL(NSArray<NSString *> *keywords) {
      for (NSString *kw in keywords) {
        if ([msg containsString:[kw lowercaseString]]) return YES;
      }
      return NO;
    };

    // 拒绝关键词列表（用于排除按钮名称中包含否定语义的项）
    NSArray *denyWords = @[@"不允许", @"不", @"don't", @"nicht", @"しない",
                           @"ne ", @"non ", @"no ", @"não", @"refuser"];

    // 辅助块：在按钮列表中查找并点击匹配关键词的按钮
    BOOL (^clickBtn)(NSArray<NSString *> *, NSArray<NSString *> *) =
      ^BOOL(NSArray<NSString *> *keywords, NSArray<NSString *> *excludeWords) {
        for (NSString *btn in buttons) {
          NSString *b = [btn lowercaseString];
          // 检查排除词
          BOOL skip = NO;
          if (excludeWords) {
            for (NSString *ex in excludeWords) {
              if ([b containsString:[ex lowercaseString]]) { skip = YES; break; }
            }
          }
          if (skip) continue;
          // 匹配关键词
          for (NSString *kw in keywords) {
            if ([b containsString:[kw lowercaseString]]) {
              NSError *error;
              if (![alert clickAlertButton:btn error:&error]) {
                [FBLogger logFmt:@"[SmartAlert] 点击按钮 '%@' 失败: %@", btn, error.description];
              }
              return YES;
            }
          }
        }
        return NO;
      };

    BOOL clicked = NO;

    // ━━━━━━━━━━ 弹窗类型识别与按钮选择 ━━━━━━━━━━

    // 🎤 听写弹窗 → 点"以后"
    if (has(@[@"dictado", @"dictation", @"听写", @"语音", @"diktierfunktion",
              @"dettatura", @"dictée", @"音声入力"])) {
      clicked = clickBtn(@[@"以后", @"ahora no", @"not now", @"以后再说",
                           @"plus tard", @"今はしない", @"agora não",
                           @"nicht jetzt", @"non ora"], nil);
    }
    // 📸 照片/相册 → 允许完全访问
    else if (has(@[@"photo", @"照片", @"相片", @"相册", @"写真", @"foto", @"フォト"])) {
      clicked = clickBtn(@[@"完全", @"所有", @"full", @"すべて", @"vollen zugriff",
                           @"accès complet", @"accesso completo", @"acceso total",
                           @"acesso a todas"], nil);
      if (!clicked) clicked = clickBtn(@[@"允许", @"allow", @"許可", @"erlauben",
                                         @"autoriser", @"consenti", @"permitir",
                                         @"zulassen"], denyWords);
    }
    // 📍 定位 → 拒绝
    else if (has(@[@"location", @"位置", @"定位", @"standort", @"localização",
                   @"ubicación", @"posizione", @"position", @"位置情報"])) {
      clicked = clickBtn(@[@"不允许", @"don't allow", @"許可しない", @"nicht erlauben",
                           @"nicht zulassen", @"ne pas autoriser", @"non consentire",
                           @"no permitir", @"não permitir"], nil);
    }
    // 📶 网络/蜂窝 → 允许
    else if (has(@[@"wlan", @"cellular", @"wi-fi", @"network", @"网络", @"局域网",
                   @"蜂窝", @"ネット", @"netzwerk", @"rede", @"red", @"rete",
                   @"réseau", @"モバイルデータ"])) {
      clicked = clickBtn(@[@"蜂窝", @"cellular", @"モバイルデータ", @"wlan &",
                           @"celular", @"cellulare", @"cellulaires", @"mobilfunk"], nil);
      if (!clicked) clicked = clickBtn(@[@"允许", @"allow", @"ok", @"好", @"許可",
                                         @"erlauben", @"autoriser", @"consenti",
                                         @"permitir", @"zulassen"], denyWords);
    }
    // 📅 日历/备忘录 → 允许
    else if (has(@[@"calendar", @"reminder", @"日历", @"备忘录", @"カレンダー",
                   @"kalender", @"erinnerungen", @"calendário", @"calendario",
                   @"promemoria", @"calendrier", @"リマインダー"])) {
      clicked = clickBtn(@[@"完全", @"full", @"フル", @"vollen", @"complet",
                           @"completo", @"total"], nil);
      if (!clicked) clicked = clickBtn(@[@"允许", @"allow", @"ok", @"好", @"許可",
                                         @"erlauben", @"autoriser", @"consenti",
                                         @"permitir", @"zulassen"], denyWords);
    }
    // 🔒 追踪 → 拒绝
    else if (has(@[@"track", @"跟踪", @"追踪", @"トラッキング", @"rastrear",
                   @"rastreo", @"tracciamento", @"suivi", @"tracking"])) {
      clicked = clickBtn(@[@"不跟踪", @"not to track", @"トラッキングしないよう",
                           @"ablehnen", @"ne pas suivre", @"non consentire",
                           @"no permitir", @"não rastrear", @"nicht erlauben"], nil);
    }
    // 👥 通讯录/联系人 → 拒绝
    else if (has(@[@"contact", @"通讯录", @"联系人", @"連絡先", @"kontakte",
                   @"contato", @"contacto", @"contatti", @"contacts"])) {
      clicked = clickBtn(@[@"不允许", @"don't allow", @"許可しない", @"nicht erlauben",
                           @"nicht zulassen", @"ne pas autoriser", @"non consentire",
                           @"no permitir", @"não permitir", @"refuser"], nil);
    }
    // 📋 粘贴/蓝牙/相机/麦克风/通知/VPN/描述文件 → 允许
    else if (has(@[@"paste", @"粘贴", @"剪贴板", @"local network", @"本地",
                   @"ローカル", @"bluetooth", @"camera", @"microphone",
                   @"蓝牙", @"相机", @"摄像头", @"麦克风", @"マイク", @"カメラ",
                   @"notification", @"通知", @"vpn", @"profile", @"描述文件",
                   @"benachrichtigung", @"notifica"])) {
      clicked = clickBtn(@[@"允许", @"allow", @"許可", @"好", @"ok",
                           @"erlauben", @"autoriser", @"consenti", @"permitir",
                           @"zulassen", @"aceptar"], denyWords);
    }

    // ━━━━━━━━━━ 兜底：尝试点击通用的确认类按钮 ━━━━━━━━━━
    if (!clicked) {
      clicked = clickBtn(@[@"好", @"ok", @"是", @"yes", @"はい", @"允许", @"allow",
                           @"erlauben", @"autoriser", @"consenti", @"permitir",
                           @"zulassen", @"accept", @"同意", @"aceptar",
                           @"ja", @"sì", @"oui"], denyWords);
    }

    // 最后手段：直接 accept
    if (!clicked) {
      NSError *error;
      [alert acceptWithError:&error];
    }

    [FBLogger logFmt:@"[SmartAlert] 处理弹窗 | 内容: %@ | 按钮: %@ | 已点击: %@",
     msg, buttons, clicked ? @"YES" : @"fallback-accept"];

  } @catch (NSException *e) {
    [FBLogger logFmt:@"[SmartAlert] 处理异常: %@ — 尝试 fallback accept", e.reason];
    @try {
      NSError *error;
      [alert acceptWithError:&error];
    } @catch (NSException *ignored) {}
  }
}

@end

@implementation FBSession

static FBSession *_activeSession = nil;

+ (instancetype)activeSession
{
  return _activeSession;
}

+ (void)markSessionActive:(FBSession *)session
{
  if (_activeSession) {
    [_activeSession kill];
  }
  _activeSession = session;
}

+ (instancetype)sessionWithIdentifier:(NSString *)identifier
{
  if (!identifier) {
    return nil;
  }
  if (![identifier isEqualToString:_activeSession.identifier]) {
    return nil;
  }
  return _activeSession;
}

+ (instancetype)initWithApplication:(XCUIApplication *)application
{
  FBSession *session = [FBSession new];
  session.useNativeCachingStrategy = YES;
  session.alertsMonitor = nil;
  session.defaultAlertAction = nil;
  session.elementsVisibilityCache = [NSMutableDictionary dictionary];
  session.identifier = [[NSUUID UUID] UUIDString];
  session.defaultActiveApplication = FBDefaultApplicationAuto;
  session.testedApplication = nil;
  session.isTestedApplicationExpectedToRun = nil != application && application.running;
  if (application) {
    session.testedApplication = application;
    session.shouldAppsWaitForQuiescence = application.fb_shouldWaitForQuiescence;
  }
  session.elementCache = [FBElementCache new];
  [FBSession markSessionActive:session];
  return session;
}

+ (instancetype)initWithApplication:(nullable XCUIApplication *)application
                 defaultAlertAction:(NSString *)defaultAlertAction
{
  FBSession *session = [self.class initWithApplication:application];
  session.defaultAlertAction = [defaultAlertAction lowercaseString];
  [session enableAlertsMonitor];
  return session;
}

- (BOOL)enableAlertsMonitor
{
  if (nil != self.alertsMonitor) {
    return NO;
  }

  self.alertsMonitor = [[FBAlertsMonitor alloc] init];
  self.alertsMonitor.delegate = (id<FBAlertsMonitorDelegate>)self;
  [self.alertsMonitor enable];
  return YES;
}

- (BOOL)disableAlertsMonitor
{
  if (nil == self.alertsMonitor) {
    return NO;
  }

  [self.alertsMonitor disable];
  self.alertsMonitor = nil;
  return YES;
}

- (void)kill
{
  if (nil == _activeSession) {
    return;
  }

  [self disableAlertsMonitor];

  FBScreenRecordingPromise *activeScreenRecording = FBScreenRecordingContainer.sharedInstance.screenRecordingPromise;
  if (nil != activeScreenRecording) {
    NSError *error;
    if (![FBXCTestDaemonsProxy stopScreenRecordingWithUUID:activeScreenRecording.identifier error:&error]) {
      [FBLogger logFmt:@"%@", error];
    }
    [FBScreenRecordingContainer.sharedInstance reset];
  }

  if (nil != self.testedApplication
      && FBConfiguration.shouldTerminateApp
      && self.testedApplication.running
      && ![self.testedApplication fb_isSameAppAs:XCUIApplication.fb_systemApplication]) {
    @try {
      [self.testedApplication terminate];
    } @catch (NSException *e) {
      [FBLogger logFmt:@"%@", e.description];
    }
  }

  _activeSession = nil;
}

- (XCUIApplication *)activeApplication
{
  BOOL isAuto = [self.defaultActiveApplication isEqualToString:FBDefaultApplicationAuto];
  NSString *defaultBundleId = isAuto ? nil : self.defaultActiveApplication;

  if (nil != defaultBundleId && [self applicationStateWithBundleId:defaultBundleId] >= XCUIApplicationStateRunningForeground) {
    return [self makeApplicationWithBundleId:defaultBundleId];
  }

  if (nil != self.testedApplication) {
    XCUIApplicationState testedAppState = self.testedApplication.state;
    if (testedAppState >= XCUIApplicationStateRunningForeground) {
      NSPredicate *searchPredicate = [NSPredicate predicateWithFormat:@"%K == %@ OR %K IN {%@, %@}",
                                      @"elementType", @(XCUIElementTypeAlert), 
                                      // To look for `SBTransientOverlayWindow` elements. See https://github.com/appium/WebDriverAgent/pull/946
                                      @"identifier", @"SBTransientOverlayWindow",
                                      // To look for 'criticalAlertSetting' elements https://developer.apple.com/documentation/usernotifications/unnotificationsettings/criticalalertsetting
                                      // See https://github.com/appium/appium/issues/20835
                                      @"NotificationShortLookView"];
      if ([FBConfiguration shouldRespectSystemAlerts]
          && [[XCUIApplication.fb_systemApplication descendantsMatchingType:XCUIElementTypeAny]
              matchingPredicate:searchPredicate].count > 0) {
        return XCUIApplication.fb_systemApplication;
      }
      return (XCUIApplication *)self.testedApplication;
    }
    if (self.isTestedApplicationExpectedToRun && testedAppState <= XCUIApplicationStateNotRunning) {
      NSString *description = [NSString stringWithFormat:@"The application under test with bundle id '%@' is not running, possibly crashed", self.testedApplication.bundleID];
      @throw [NSException exceptionWithName:FBApplicationCrashedException reason:description userInfo:nil];
    }
  }

  return [XCUIApplication fb_activeApplicationWithDefaultBundleId:defaultBundleId];
}

- (XCUIApplication *)launchApplicationWithBundleId:(NSString *)bundleIdentifier
                           shouldWaitForQuiescence:(nullable NSNumber *)shouldWaitForQuiescence
                                         arguments:(nullable NSArray<NSString *> *)arguments
                                       environment:(nullable NSDictionary <NSString *, NSString *> *)environment
{
  XCUIApplication *app = [self makeApplicationWithBundleId:bundleIdentifier];
  if (nil == shouldWaitForQuiescence) {
    // Iherit the quiescence check setting from the main app under test by default
    app.fb_shouldWaitForQuiescence = nil != self.testedApplication && self.shouldAppsWaitForQuiescence;
  } else {
    app.fb_shouldWaitForQuiescence = [shouldWaitForQuiescence boolValue];
  }
  if (!app.running) {
    app.launchArguments = arguments ?: @[];
    app.launchEnvironment = environment ?: @{};
    [app launch];
  } else {
    [app activate];
  }
  if ([app fb_isSameAppAs:self.testedApplication]) {
    self.isTestedApplicationExpectedToRun = YES;
  }
  return app;
}

- (XCUIApplication *)activateApplicationWithBundleId:(NSString *)bundleIdentifier
{
  XCUIApplication *app = [self makeApplicationWithBundleId:bundleIdentifier];
  [app activate];
  return app;
}

- (BOOL)terminateApplicationWithBundleId:(NSString *)bundleIdentifier
{
  XCUIApplication *app = [self makeApplicationWithBundleId:bundleIdentifier];
  if ([app fb_isSameAppAs:self.testedApplication]) {
    self.isTestedApplicationExpectedToRun = NO;
  }
  if (app.running) {
    [app terminate];
    return YES;
  }
  return NO;
}

- (NSUInteger)applicationStateWithBundleId:(NSString *)bundleIdentifier
{
  return [self makeApplicationWithBundleId:bundleIdentifier].state;
}

- (XCUIApplication *)makeApplicationWithBundleId:(NSString *)bundleIdentifier
{
  return nil != self.testedApplication && [bundleIdentifier isEqualToString:(NSString *)self.testedApplication.bundleID]
    ? self.testedApplication
    : [[XCUIApplication alloc] initWithBundleIdentifier:bundleIdentifier];
}

@end
