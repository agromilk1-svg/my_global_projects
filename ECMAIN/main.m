#import "AppDelegate.h"
#include "ECSceneDelegate.m" // Hack: Include implementation directly since we can't edit project file
#import "TrollStoreCore/TrollStoreIncludes.m"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

// Logic adapted from TrollHelper to support running inside system apps (like
// Tips) that expect a SceneDelegate defined in their Info.plist.
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
        if (UIWindowSceneSessionRoleApplication.count > 0) {
          // Just take the first one or look for default
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
    // Dynamically register ECSceneDelegate as the expected class name
    NSLog(@"[ECMAIN] Dynamic Scene Fix: Mapping %@ to ECSceneDelegate",
          sceneDelegateClassName);
    Class newClass = objc_allocateClassPair(
        [ECSceneDelegate class], sceneDelegateClassName.UTF8String, 0);
    if (newClass) {
      objc_registerClassPair(newClass);
      return YES;
    } else {
      NSLog(@"[ECMAIN] Failed to allocate class pair for %@",
            sceneDelegateClassName);
      // It might already exist if we are reloading?
      return NO;
    }
  }

  return NO;
}

int main(int argc, char *argv[]) {
  @autoreleasepool {
    sceneDelegateFix();
    return UIApplicationMain(argc, argv, nil,
                             NSStringFromClass([AppDelegate class]));
  }
}
