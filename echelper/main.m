#import "TSHAppDelegateNoScene.h"
#import "TSHAppDelegateWithScene.h"
#import "TSHSceneDelegate.h"
#import <Foundation/Foundation.h>
#import <TSUtil.h>
#import <objc/runtime.h>
#import <sys/types.h>
#import <unistd.h>

BOOL sceneDelegateFix(void) {
  NSString *sceneDelegateClassName = nil;

  NSDictionary *UIApplicationSceneManifest = [NSBundle.mainBundle
      objectForInfoDictionaryKey:@"UIApplicationSceneManifest"];
  if (UIApplicationSceneManifest &&
      [UIApplicationSceneManifest isKindOfClass:NSDictionary.class]) {
    NSDictionary *UISceneConfiguration =
        UIApplicationSceneManifest[@"UISceneConfigurations"];
    if (UISceneConfiguration &&
        [UISceneConfiguration isKindOfClass:NSDictionary.class]) {
      NSArray *UIWindowSceneSessionRoleApplication =
          UISceneConfiguration[@"UIWindowSceneSessionRoleApplication"];
      if (UIWindowSceneSessionRoleApplication &&
          [UIWindowSceneSessionRoleApplication isKindOfClass:NSArray.class]) {
        NSDictionary *sceneToUse = nil;
        if (UIWindowSceneSessionRoleApplication.count > 1) {
          for (NSDictionary *scene in UIWindowSceneSessionRoleApplication) {
            if ([scene isKindOfClass:NSDictionary.class]) {
              NSString *UISceneConfigurationName =
                  scene[@"UISceneConfigurationName"];
              if ([UISceneConfigurationName isKindOfClass:NSString.class]) {
                if ([UISceneConfigurationName
                        isEqualToString:@"Default Configuration"]) {
                  sceneToUse = scene;
                  break;
                }
              }
            }
          }

          if (!sceneToUse) {
            sceneToUse = UIWindowSceneSessionRoleApplication.firstObject;
          }
        } else {
          sceneToUse = UIWindowSceneSessionRoleApplication.firstObject;
        }

        if (sceneToUse && [sceneToUse isKindOfClass:NSDictionary.class]) {
          sceneDelegateClassName = sceneToUse[@"UISceneDelegateClassName"];
        }
      }
    }
  }

  if (sceneDelegateClassName &&
      [sceneDelegateClassName isKindOfClass:NSString.class]) {
    Class newClass = objc_allocateClassPair(
        [TSHSceneDelegate class], sceneDelegateClassName.UTF8String, 0);
    objc_registerClassPair(newClass);
    return YES;
  }

  return NO;
}

int main(int argc, char *argv[], char *envp[]) {
  @autoreleasepool {
    NSLog(@"========== [echelper main] ENTRY ==========");
    NSLog(@"[echelper main] uid=%d euid=%d pid=%d", getuid(), geteuid(), getpid());
    NSLog(@"[echelper main] argc=%d argv[0]=%s", argc,
          argc > 0 ? argv[0] : "(null)");
    NSLog(@"[echelper main] bundle=%@",
          [NSBundle mainBundle].bundlePath ?: @"(null)");
    NSLog(@"[echelper main] executable=%@",
          [NSBundle mainBundle].executablePath ?: @"(null)");

#ifdef EMBEDDED_ROOT_HELPER
    NSLog(@"[echelper main] EMBEDDED_ROOT_HELPER=1");
    extern int rootHelperMain(int argc, char *argv[], char *envp[]);
    if (getuid() == 0) {
      NSLog(@"[echelper main] Running as ROOT → rootHelperMain");
      return rootHelperMain(argc, argv, envp);
    }
    NSLog(@"[echelper main] Running as USER → GUI mode");
#else
    NSLog(@"[echelper main] EMBEDDED_ROOT_HELPER not defined");
#endif

    NSLog(@"[echelper main] Calling chineseWifiFixup...");
    chineseWifiFixup();
    NSLog(@"[echelper main] chineseWifiFixup done");

    NSLog(@"[echelper main] Calling sceneDelegateFix...");
    if (sceneDelegateFix()) {
      NSLog(@"[echelper main] sceneDelegateFix=YES → WithScene");
      return UIApplicationMain(
          argc, argv, nil, NSStringFromClass(TSHAppDelegateWithScene.class));
    } else {
      NSLog(@"[echelper main] sceneDelegateFix=NO → NoScene");
      return UIApplicationMain(argc, argv, nil,
                               NSStringFromClass(TSHAppDelegateNoScene.class));
    }
  }
}
