#import "MainTabBarController.h"
#import "ECAppListViewController.h"
#import "ECDeviceInfoViewController.h"
#import "ECFileBrowserViewController.h"
#import "ECHomeViewController.h"
#import "ECTaskListViewController.h"
#import "VPNConfigViewController.h"
#import "ViewController.h"

@implementation MainTabBarController

- (void)viewDidLoad {
  [super viewDidLoad];

  // Tab 1: Dashboard (Keep-Alive)
  ViewController *dashboardVC = [[ViewController alloc] init];
  dashboardVC.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"仪表盘"
              image:[UIImage systemImageNamed:@"speedometer"]
                tag:0];

  // Tab 2: VPN Config (Mihomo)
  ECHomeViewController *vpnVC = [[ECHomeViewController alloc] init];
  UINavigationController *vpnNav =
      [[UINavigationController alloc] initWithRootViewController:vpnVC];
  vpnNav.tabBarItem =
      [[UITabBarItem alloc] initWithTitle:@"代理配置"
                                    image:[UIImage systemImageNamed:@"network"]
                                      tag:1];

  // Tab 3: App Manager
  ECAppListViewController *appListVC = [[ECAppListViewController alloc] init];
  UINavigationController *appListNav =
      [[UINavigationController alloc] initWithRootViewController:appListVC];
  appListNav.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"应用管理"
              image:[UIImage systemImageNamed:@"square.grid.2x2"]
                tag:2];

  // Tab 4: Device Info (Hidden per user request)
  /*
  ECDeviceInfoViewController *deviceInfoVC = [[ECDeviceInfoViewController alloc]
      initWithStyle:UITableViewStyleGrouped];
  UINavigationController *deviceInfoNav =
      [[UINavigationController alloc] initWithRootViewController:deviceInfoVC];
  deviceInfoNav.tabBarItem =
      [[UITabBarItem alloc] initWithTitle:@"设备信息"
                                    image:[UIImage systemImageNamed:@"iphone"]
                                      tag:3];
  */

  // Tab 4: File Browser (Moved to App Manager)
  /*
  ECFileBrowserViewController *fileBrowserVC =
      [[ECFileBrowserViewController alloc] initWithPath:@"/"];
  UINavigationController *fileBrowserNav =
      [[UINavigationController alloc] initWithRootViewController:fileBrowserVC];
  fileBrowserNav.tabBarItem = [[UITabBarItem alloc]
      initWithTitle:@"文件浏览"
              image:[UIImage systemImageNamed:@"folder.badge.questionmark"]
                tag:3];
  */

  // Tab 5: 自动任务管理
  ECTaskListViewController *taskVC = [[ECTaskListViewController alloc] init];
  UINavigationController *taskNav =
      [[UINavigationController alloc] initWithRootViewController:taskVC];
  taskNav.tabBarItem =
      [[UITabBarItem alloc] initWithTitle:@"任务管理"
                                    image:[UIImage systemImageNamed:@"scroll"]
                                      tag:4];

  // Set controllers
  self.viewControllers = @[ dashboardVC, vpnNav, appListNav, taskNav ];
  //  Style
  self.tabBar.barStyle = UIBarStyleBlack;
  self.tabBar.tintColor = [UIColor systemBlueColor];
  if (@available(iOS 15.0, *)) {
    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1.0];
    self.tabBar.standardAppearance = appearance;
    self.tabBar.scrollEdgeAppearance = appearance;
  }
}

@end
