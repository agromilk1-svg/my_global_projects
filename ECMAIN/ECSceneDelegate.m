#import "ECSceneDelegate.h"
#import "ECMAIN/UI/MainTabBarController.h"

@implementation ECSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
  if (![scene isKindOfClass:[UIWindowScene class]])
    return;

  UIWindowScene *windowScene = (UIWindowScene *)scene;
  self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
  self.window.rootViewController = [[MainTabBarController alloc] init];
  [self.window makeKeyAndVisible];

  NSLog(@"[ECMAIN] Scene Connected & Window Created");
}

- (void)sceneDidDisconnect:(UIScene *)scene {
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
}
- (void)sceneWillResignActive:(UIScene *)scene {
}
- (void)sceneWillEnterForeground:(UIScene *)scene {
}
- (void)sceneDidEnterBackground:(UIScene *)scene {
}

@end
