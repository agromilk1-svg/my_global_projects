#import <UIKit/UIKit.h>

@interface AppDelegate : UIResponder <UIApplicationDelegate>

@property(strong, nonatomic) UIWindow *window;
// BUILD #402: 无限递归后台任务 ID
@property(assign, nonatomic) UIBackgroundTaskIdentifier bgTaskId;
- (void)registerInfiniteBackgroundTask;

@end
