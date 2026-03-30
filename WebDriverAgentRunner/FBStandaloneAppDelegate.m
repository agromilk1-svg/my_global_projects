/**
 * FBStandaloneAppDelegate - WDA 独立启动模式的 AppDelegate
 * 点击图标即可启动 WebDriverAgent 服务器，无需 USB 连接
 */

#import <UIKit/UIKit.h>
#import "FBStandaloneAppDelegate.h"
#import "../WebDriverAgentLib/Routing/FBWebServer.h"
#import "../WebDriverAgentLib/Utilities/FBConfiguration.h"
#import "../WebDriverAgentLib/Utilities/FBLogger.h"
#import "../WebDriverAgentLib/Utilities/FBErrorBuilder.h"
#import <objc/runtime.h>

// 前向声明 XCTest 私有类（运行时动态访问）
@interface XCTRunnerDaemonSession : NSObject
+ (instancetype)sharedSession;
- (id)daemonProxy;
@end

#pragma mark - 内联的 XCTest 自引导逻辑

/**
 * 尝试激活已有的 XCTest Session，或通过 XCUIDevice 触发初始化
 * 如果成功，WDA 将具备完整的点击/截屏能力；
 * 如果失败，WDA 仍可提供 HTTP 服务（部分功能受限）
 */
static BOOL FBStandaloneBootstrapXCTest(NSError **outError) {
  // 方法 1：尝试获取已有的 XCTRunnerDaemonSession
  @try {
    Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    if (sessionClass) {
      XCTRunnerDaemonSession *session = [sessionClass sharedSession];
      if (session && [session daemonProxy]) {
        [FBLogger log:@"[ECWDA] ✅ 检测到已有的 XCTest Daemon 连接"];
        return YES;
      }
    }
  } @catch (NSException *exception) {
    [FBLogger logFmt:@"[ECWDA] Session 探测异常: %@", exception.reason];
  }

  // 方法 2：通过 XCUIDevice.sharedDevice 触发 session 初始化
  @try {
    Class xcuiDeviceClass = NSClassFromString(@"XCUIDevice");
    if (xcuiDeviceClass) {
      SEL sharedDeviceSel = NSSelectorFromString(@"sharedDevice");
      if ([xcuiDeviceClass respondsToSelector:sharedDeviceSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id sharedDevice = [xcuiDeviceClass performSelector:sharedDeviceSel];
#pragma clang diagnostic pop
        if (sharedDevice) {
          [FBLogger log:@"[ECWDA] XCUIDevice.sharedDevice 可访问"];
          SEL eventSynthSel = NSSelectorFromString(@"eventSynthesizer");
          if ([sharedDevice respondsToSelector:eventSynthSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id synth = [sharedDevice performSelector:eventSynthSel];
#pragma clang diagnostic pop
            if (synth) {
              [FBLogger log:@"[ECWDA] ✅ Event Synthesizer 已就绪"];
              return YES;
            }
          }
        }
      }
    }
  } @catch (NSException *exception) {
    [FBLogger logFmt:@"[ECWDA] XCUIDevice 探测异常: %@", exception.reason];
  }

  // 所有方法均失败
  [FBLogger log:@"[ECWDA] ⚠️ XCTest Session 不可用，进入降级模式"];
  if (outError) {
    *outError = [[FBErrorBuilder builder]
                    withDescription:@"XCTest daemon 不可达。点击/截屏功能可能受限。"]
                    .build;
  }
  return NO;
}

#pragma mark - AppDelegate 实现

@implementation FBStandaloneAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  [FBLogger logFmt:@"[ECWDA] Standalone 模式正在启动..."];
  [FBLogger logFmt:@"[ECWDA] 目标端口: %lu", (unsigned long)FBConfiguration.bindingPortRange.location];

  // 1. 尝试自引导 XCTest（关键步骤）
  NSError *error = nil;
  BOOL bootstrapped = FBStandaloneBootstrapXCTest(&error);
  if (!bootstrapped) {
    [FBLogger logFmt:@"[ECWDA] 引导结果: %@", error.localizedDescription];
  }

  // 2. 启动 WebDriverAgent HTTP 服务器
  FBWebServer *webServer = [[FBWebServer alloc] init];
  [webServer startServing];
  // 注意: startServing 内部有 RunLoop，下面的代码不会立即执行

  return YES;
}

@end
