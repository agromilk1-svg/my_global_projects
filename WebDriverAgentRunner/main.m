/**
 * Custom main.m for WebDriverAgentRunner
 * This entry point is used when the app is launched manually (Clicking icon)
 */

#import <UIKit/UIKit.h>
#import "FBStandaloneAppDelegate.h"

int main(int argc, char * argv[]) {
  @autoreleasepool {
    // 强制使用我们自定义的 FBStandaloneAppDelegate
    // 这样点击图标时就能触发 WDA Server 启动，而不是显示一个空白页
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([FBStandaloneAppDelegate class]));
  }
}
