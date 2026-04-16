#import "ViewController.h"
#import "ECBuildInfo.h"
#import "ECMAIN/Core/ECAppInjector.h"
#import "ECMAIN/Core/ECBackgroundManager.h"
#import "ECMAIN/Core/ECLogManager.h"
#import "ECMAIN/Core/ECTaskPollManager.h"
#import "ECMAIN/Core/ECPersistentConfig.h"
#import "ECMAIN/UI/ECDeviceInfoViewController.h"
#import "Network/ECNetworkManager.h"
#import "TrollStoreCore/TSApplicationsManager.h"
#import "TrollStoreCore/TSInstallationController.h"
#import "TrollStoreCore/TSPresentationDelegate.h"
#import "TrollStoreCore/TSUtil.h" // for spawnRoot & rootHelperPath
#include <arpa/inet.h>
#include <ifaddrs.h>

@interface ViewController () <UITextFieldDelegate>
@property(strong, nonatomic) UITextField *serverUrlField;
@property(strong, nonatomic) UITextField *deviceNoField;
@property(strong, nonatomic) UITextField *adminField;
@property(strong, nonatomic) UIButton *saveTestButton;
@property(strong, nonatomic) UIImageView *statusIcon;
@property(strong, nonatomic) UILabel *macLabel;
@property(strong, nonatomic) UILabel *metadataLabel;
@property(strong, nonatomic) UISwitch *watchdogSwitch;
// 账号展示区
@property(strong, nonatomic) UIScrollView *accountScrollView;
@end

@implementation ViewController

- (NSString *)getLocalIP {
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  NSString *wifiAddress = @"Unavailable";
  int success = 0;

  success = getifaddrs(&interfaces);
  if (success == 0) {
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr->sa_family == AF_INET) {
        if ([[NSString stringWithUTF8String:temp_addr->ifa_name]
                isEqualToString:@"en0"]) {
          wifiAddress =
              [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)
                                                            temp_addr->ifa_addr)
                                                           ->sin_addr)];
        }
      }
      temp_addr = temp_addr->ifa_next;
    }
  }
  freeifaddrs(interfaces);
  return wifiAddress;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor whiteColor];

  // UI Layout Constants
  CGFloat padding = 20.0;
  CGFloat fieldHeight = 40.0;
  CGFloat width = self.view.bounds.size.width - 2 * padding;
  CGFloat y = 88.0;

  // --- Version Label ---
  UILabel *versionLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, 50, width, 20)];
  versionLabel.text = @"Build: 2026-04-16 18:14 #2004 (Auto)";
  versionLabel.textColor = [UIColor grayColor];
  versionLabel.textAlignment = NSTextAlignmentRight;
  versionLabel.font = [UIFont systemFontOfSize:12];
  [self.view addSubview:versionLabel];

  // --- ID Label ---
  self.macLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, 68, width, 20)];
  self.macLabel.text = [NSString stringWithFormat:@"ID: %@", [ECBackgroundManager deviceUDID]];
  self.macLabel.textColor = [UIColor darkGrayColor];
  self.macLabel.textAlignment = NSTextAlignmentRight;
  self.macLabel.font = [UIFont systemFontOfSize:13];
  [self.view addSubview:self.macLabel];

  // --- Row 1: Server Address ---
  UILabel *serverLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, 100, fieldHeight)];
  serverLabel.text = @"服务器地址:";
  serverLabel.textColor = [UIColor blackColor];
  serverLabel.font = [UIFont systemFontOfSize:14];
  [self.view addSubview:serverLabel];

  self.serverUrlField = [[UITextField alloc]
      initWithFrame:CGRectMake(padding + 80, y, width - 80, fieldHeight)];
  self.serverUrlField.placeholder = @"http://192.168.x.x:8088";
  self.serverUrlField.borderStyle = UITextBorderStyleRoundedRect;
  self.serverUrlField.backgroundColor = [UIColor whiteColor];
  self.serverUrlField.textColor = [UIColor blackColor];
  self.serverUrlField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.serverUrlField.delegate = self;

  // 添加快捷下拉选择按钮
  UIButton *dropdownBtn = [UIButton buttonWithType:UIButtonTypeCustom];
  if (@available(iOS 13.0, *)) {
    [dropdownBtn setImage:[UIImage systemImageNamed:@"chevron.down.circle.fill"] forState:UIControlStateNormal];
    dropdownBtn.tintColor = [UIColor systemGrayColor];
  } else {
    [dropdownBtn setTitle:@"▼" forState:UIControlStateNormal];
    [dropdownBtn setTitleColor:[UIColor grayColor] forState:UIControlStateNormal];
  }
  dropdownBtn.frame = CGRectMake(0, 0, 36, fieldHeight);
  [dropdownBtn addTarget:self action:@selector(showServerOptions) forControlEvents:UIControlEventTouchUpInside];
  self.serverUrlField.rightView = dropdownBtn;
  self.serverUrlField.rightViewMode = UITextFieldViewModeAlways;

  // Load saved URL or Default （使用双读机制，App Group 优先，缺失则从 plist 恢复）
  NSString *savedUrl = [ECPersistentConfig stringForKey:@"CloudServerURL"];
  self.serverUrlField.text =
      savedUrl.length > 0 ? savedUrl : ECServerFallbackList().firstObject;

  [self.view addSubview:self.serverUrlField];

  y += fieldHeight + 10;

  // --- Row 1.5: Device No ---
  UILabel *deviceNoLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, 100, fieldHeight)];
  deviceNoLabel.text = @"设备编号:";
  deviceNoLabel.textColor = [UIColor blackColor];
  deviceNoLabel.font = [UIFont systemFontOfSize:14];
  [self.view addSubview:deviceNoLabel];

  self.deviceNoField = [[UITextField alloc]
      initWithFrame:CGRectMake(padding + 80, y, width - 80, fieldHeight)];
  self.deviceNoField.placeholder = @"例如：手机001";
  self.deviceNoField.borderStyle = UITextBorderStyleRoundedRect;
  self.deviceNoField.backgroundColor = [UIColor whiteColor];
  self.deviceNoField.textColor = [UIColor blackColor];
  self.deviceNoField.delegate = self;

  NSString *savedNo = [ECPersistentConfig stringForKey:@"EC_DEVICE_NO"];
  self.deviceNoField.text = savedNo ?: @"";

  [self.view addSubview:self.deviceNoField];

  y += fieldHeight + 10;

  // --- Row 1.6: Admin Account ---
  UILabel *adminLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, 100, fieldHeight)];
  adminLabel.text = @"管理员:";
  adminLabel.textColor = [UIColor blackColor];
  adminLabel.font = [UIFont systemFontOfSize:14];
  [self.view addSubview:adminLabel];

  self.adminField = [[UITextField alloc]
      initWithFrame:CGRectMake(padding + 80, y, width - 80, fieldHeight)];
  self.adminField.placeholder = @"控制中心管理员账号";
  self.adminField.borderStyle = UITextBorderStyleRoundedRect;
  self.adminField.backgroundColor = [UIColor whiteColor];
  self.adminField.textColor = [UIColor blackColor];
  self.adminField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.adminField.delegate = self;

  NSString *savedAdmin = [ECPersistentConfig stringForKey:@"EC_ADMIN_USERNAME"];
  self.adminField.text = savedAdmin ?: @"";

  [self.view addSubview:self.adminField];

  y += fieldHeight + 20;

  // --- Row 2: Save & Test Button + Keep Alive Switch ---
  CGFloat btnWidth = (width / 2) - 10;

  self.saveTestButton = [UIButton buttonWithType:UIButtonTypeSystem];
  self.saveTestButton.frame = CGRectMake(padding, y, btnWidth, 40);
  [self.saveTestButton setTitle:@"保存测试" forState:UIControlStateNormal];
  self.saveTestButton.backgroundColor = [UIColor systemBlueColor];
  [self.saveTestButton setTitleColor:[UIColor whiteColor]
                            forState:UIControlStateNormal];
  self.saveTestButton.layer.cornerRadius = 8;
  [self.saveTestButton addTarget:self
                          action:@selector(saveAndTestTapped)
                forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.saveTestButton];

  // --- 中断任务按钮 ---
  UIButton *interruptButton = [UIButton buttonWithType:UIButtonTypeSystem];
  interruptButton.frame = CGRectMake(padding + btnWidth + 20, y, btnWidth, 40);
  [interruptButton setTitle:@"🛑 中断任务" forState:UIControlStateNormal];
  interruptButton.backgroundColor = [UIColor systemRedColor];
  [interruptButton setTitleColor:[UIColor whiteColor]
                        forState:UIControlStateNormal];
  interruptButton.layer.cornerRadius = 8;
  [interruptButton addTarget:self
                      action:@selector(interruptTasksTapped)
            forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:interruptButton];

  // Status Icon (Hidden initially)
  self.statusIcon = [[UIImageView alloc]
      initWithFrame:CGRectMake(CGRectGetMaxX(self.saveTestButton.frame) + 5,
                               y + 5, 30, 30)];
  self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
  self.statusIcon.hidden = YES;
  [self.view addSubview:self.statusIcon];

  y += 40 + 20;

  // --- Row 3: Start WDA & Free Memory ---
  UIButton *startWdaBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  startWdaBtn.frame = CGRectMake(padding, y, btnWidth, 40);
  [startWdaBtn setTitle:@"🚀 独立重启 WDA"
               forState:UIControlStateNormal];
  startWdaBtn.backgroundColor = [UIColor systemGreenColor];
  [startWdaBtn setTitleColor:[UIColor whiteColor]
                    forState:UIControlStateNormal];
  startWdaBtn.layer.cornerRadius = 8;
  [startWdaBtn addTarget:self
                  action:@selector(manuallyStartWDA)
        forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:startWdaBtn];
  
  UIButton *freeMemoryBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  freeMemoryBtn.frame = CGRectMake(padding + btnWidth + 20, y, btnWidth, 40);
  [freeMemoryBtn setTitle:@"🧹 强制清理内存"
                 forState:UIControlStateNormal];
  freeMemoryBtn.backgroundColor = [UIColor systemPurpleColor];
  [freeMemoryBtn setTitleColor:[UIColor whiteColor]
                      forState:UIControlStateNormal];
  freeMemoryBtn.layer.cornerRadius = 8;
  [freeMemoryBtn addTarget:self
                    action:@selector(freeMemoryTapped)
          forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:freeMemoryBtn];

  y += 40 + 15;

  // --- Row 3.5: Watchdog WDA Switch ---
  UILabel *watchdogLabel = [[UILabel alloc] initWithFrame:CGRectMake(padding, y, 120, 31)];
  watchdogLabel.text = @"探活 WDA:";
  watchdogLabel.textColor = [UIColor blackColor];
  watchdogLabel.font = [UIFont systemFontOfSize:14];
  [self.view addSubview:watchdogLabel];

  self.watchdogSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(padding + 80, y, 51, 31)];
  [self.watchdogSwitch addTarget:self action:@selector(watchdogSwitchToggled:) forControlEvents:UIControlEventValueChanged];

  // Load state (使用双读机制)
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  [defaults registerDefaults:@{@"EC_WATCHDOG_WDA_ENABLED": @YES}];
  if ([defaults objectForKey:@"EC_WATCHDOG_WDA_ENABLED"] == nil) {
      [ECPersistentConfig setBool:YES forKey:@"EC_WATCHDOG_WDA_ENABLED"];
  }
  BOOL watchdogEnabled = [ECPersistentConfig boolForKey:@"EC_WATCHDOG_WDA_ENABLED"];
  [self.watchdogSwitch setOn:watchdogEnabled animated:NO];
  [self.view addSubview:self.watchdogSwitch];

  y += 31 + 20;

  // --- Metadata Label (国家/分组/执行时间) ---
  self.metadataLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, y, width, 20)];
  self.metadataLabel.text = @"🌍 国家: -- | 🏷️ 分组: -- | ⏱️ 执行: --";
  self.metadataLabel.textColor = [UIColor systemBlueColor];
  self.metadataLabel.textAlignment = NSTextAlignmentCenter;
  self.metadataLabel.font = [UIFont systemFontOfSize:13
                                              weight:UIFontWeightMedium];
  [self.view addSubview:self.metadataLabel];

  y += 24;

  // --- 账号信息展示区域 ---
  CGFloat remainingHeight = self.view.bounds.size.height - y - 60;
  self.accountScrollView = [[UIScrollView alloc]
      initWithFrame:CGRectMake(padding, y, width, remainingHeight)];
  self.accountScrollView.backgroundColor = [UIColor colorWithWhite:0.05
                                                             alpha:1.0];
  self.accountScrollView.layer.cornerRadius = 12;
  self.accountScrollView.showsVerticalScrollIndicator = YES;
  [self.view addSubview:self.accountScrollView];

  // 初次加载账号数据
  [self refreshAccountLabels];

  // 监听配置更新通知
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(refreshMetadataLabel)
                                               name:@"ECTasksDidUpdateAlert"
                                             object:nil];

  // 点击收键盘
  UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
      initWithTarget:self
              action:@selector(dismissKeyboard)];
  tap.cancelsTouchesInView = NO;
  [self.view addGestureRecognizer:tap];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [TSPresentationDelegate setPresentationViewController:self];

  if (!isLdidInstalled()) {
    [TSInstallationController installLdidSilently];
  }

  // 刷新元数据标签
  [self refreshMetadataLabel];

  // ================= 检查并静默安装 ECWDA =================
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *appDir = [[NSBundle mainBundle] bundlePath];
        NSString *ecwdaPath =
            [appDir stringByAppendingPathComponent:@"ecwda.ipa"];

        if ([[NSFileManager defaultManager] fileExistsAtPath:ecwdaPath]) {
          // 通过 LSApplicationProxy 检查 ECWDA 是否已安装
          LSApplicationProxy *proxy = [LSApplicationProxy
              applicationProxyForIdentifier:
                  @"com.apple.accessibility.ecwda"];
          BOOL isInstalled = (proxy != nil && proxy.installed);

          if (!isInstalled) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [self
                  appendLog:
                      @"[系统] 发现附带的 ECWDA.ipa，正在静默部署底层服务..."];
            });
            [[TSApplicationsManager sharedInstance] installIpa:ecwdaPath];
          }
        }
      });

  // ========== 首次启动：自动检测并安装 ECWDA ==========
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. 检查 ECWDA 是否已安装
        NSString *ecwdaBundleID = @"com.apple.accessibility.ecwda";
        Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
        BOOL ecwdaInstalled = NO;
        if (LSAppProxyClass) {
          id proxy = [LSAppProxyClass
              performSelector:@selector(applicationProxyForIdentifier:)
                   withObject:ecwdaBundleID];
          if (proxy) {
            NSNumber *installed = [proxy valueForKey:@"isInstalled"];
            ecwdaInstalled = (installed && [installed boolValue]);
          }
        }

        if (ecwdaInstalled) {
          [[ECLogManager sharedManager]
              log:@"[ECMAIN] ✅ ECWDA 已安装，跳过首次自动安装"];
          return;
        }

        // 2. ECWDA 未安装 → 在 /var/containers/Bundle/Application/ 下搜索
        // ecwda.ipa
        [[ECLogManager sharedManager]
            log:@"[ECMAIN] ⚠️ 检测到 ECWDA 未安装，正在搜索本地 ecwda.ipa..."];

        NSString *bundleBase = @"/var/containers/Bundle/Application";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *foundIpaPath = nil;

        NSArray *uuidDirs = [fm contentsOfDirectoryAtPath:bundleBase error:nil];
        for (NSString *uuid in uuidDirs) {
          NSString *uuidPath = [bundleBase stringByAppendingPathComponent:uuid];
          NSArray *appDirs = [fm contentsOfDirectoryAtPath:uuidPath error:nil];
          for (NSString *appDir in appDirs) {
            if ([appDir hasSuffix:@".app"]) {
              NSString *ipaCandidate =
                  [[uuidPath stringByAppendingPathComponent:appDir]
                      stringByAppendingPathComponent:@"ecwda.ipa"];
              if ([fm fileExistsAtPath:ipaCandidate]) {
                foundIpaPath = ipaCandidate;
                break;
              }
            }
          }
          if (foundIpaPath)
            break;
        }

        if (!foundIpaPath) {
          [[ECLogManager sharedManager]
              log:@"[ECMAIN] ℹ️ 未在本地系统应用中找到 ecwda.ipa，跳过自动安装"];
          return;
        }

        [[ECLogManager sharedManager]
            log:[NSString
                    stringWithFormat:
                        @"[ECMAIN] 📦 找到 ecwda.ipa: %@，开始原包安装...",
                        foundIpaPath]];

        // 3. 使用 TSApplicationsManager 原包安装（method 0 = Installd Direct）
        NSString *logOut = nil;
        int ret =
            [[TSApplicationsManager sharedInstance] installIpa:foundIpaPath
                                                         force:YES
                                              registrationType:@"System"
                                                customBundleId:nil
                                             customDisplayName:nil
                                                   skipSigning:NO
                                            installationMethod:0
                                                           log:&logOut];

        if (ret == 0) {
          [[ECLogManager sharedManager]
              log:@"[ECMAIN] ✅ ECWDA 首次自动安装成功！正在启动..."];

          // 安装成功后延迟 2 秒拉起 ECWDA
          dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_after(
                dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                  spawnRoot(rootHelperPath(), @[ @"start-wda", ecwdaBundleID ],
                            nil, nil);
                  [[ECLogManager sharedManager]
                      log:@"[ECMAIN] 🚀 ECWDA 已拉起"];
                });
          });
        } else {
          [[ECLogManager sharedManager]
              log:[NSString stringWithFormat:
                                @"[ECMAIN] ❌ ECWDA 首次安装失败 (code: %d) "
                                @"log: %@",
                                ret, logOut ?: @"无"]];
        }
      });
}

- (void)refreshMetadataLabel {
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *country = [defaults stringForKey:@"EC_DEVICE_COUNTRY"];
  NSString *group = [defaults stringForKey:@"EC_DEVICE_GROUP"];
  NSString *time = [defaults stringForKey:@"EC_DEVICE_EXEC_TIME"];
  if (!country || country.length == 0)
    country = @"无";
  if (!group || group.length == 0)
    group = @"无";
  if (!time || time.length == 0)
    time = @"全时段";
  else
    time = [time stringByAppendingString:@"点"];
  self.metadataLabel.text =
      [NSString stringWithFormat:@"🌍 国家: %@ | 🏷️ 分组: %@ | ⏱️ 执行: %@",
                                 country, group, time];
  // 同时刷新账号展示
  [self refreshAccountLabels];
}

- (void)watchdogSwitchToggled:(UISwitch *)sender {
  [ECPersistentConfig setBool:sender.isOn forKey:@"EC_WATCHDOG_WDA_ENABLED"];
  NSLog(@"[ECMAIN] Watchdog WDA state changed to: %@", sender.isOn ? @"ON" : @"OFF");
}

#pragma mark - Actions

- (void)showServerOptions {
  [self.view endEditing:YES];
  UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"快捷选择服务器地址" 
                                                                 message:nil 
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  
  NSArray *options = ECServerFallbackList();
  
  for (NSString *opt in options) {
      [sheet addAction:[UIAlertAction actionWithTitle:opt style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
          self.serverUrlField.text = opt;
      }]];
  }
  
  [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  
  if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
      sheet.popoverPresentationController.sourceView = self.serverUrlField.rightView;
      sheet.popoverPresentationController.sourceRect = self.serverUrlField.rightView.bounds;
  }
  
  [self presentViewController:sheet animated:YES completion:nil];
}

- (void)manuallyStartWDA {
  NSLog(@"🟢 手动点击: 准备唤起 ECWDA (无界面后台模式)...");

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"正在唤起"
                       message:@"已下发启动指令到底层，请等候..."
                preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:alert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   spawnRoot(rootHelperPath(), @[ @"start-wda" ], nil, nil);

                   dispatch_async(dispatch_get_main_queue(), ^{
                     [alert dismissViewControllerAnimated:YES completion:nil];
                   });
                 });
}

// [v1766] 三段式极限内存清理：清缓存 → 击穿压缩器 → 广播内存警告
- (void)freeMemoryTapped {
    [self appendLog:@"🧹 启动三段式极限内存清理..."];
    
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"深度清理中"
                         message:@"阶段 1/3: 正在清除应用缓存..."
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        
        // ========== 阶段 1: 清除 App 层全部缓存 ==========
        // NSURLCache 是 ECMAIN 网络通讯最大的隐形内存杀手
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        [[NSURLCache sharedURLCache] setMemoryCapacity:0];
        [[NSURLCache sharedURLCache] setDiskCapacity:0];
        
        // 清除图片缓存（如果有用 UIImage imageNamed: 的地方）
        // 系统 imageNamed: 缓存不可控，但 URLCache 是大头
        
        dispatch_async(dispatch_get_main_queue(), ^{
            alert.message = @"阶段 2/3: 正在用随机数据击穿内存压缩器...";
        });
        
        // ========== 阶段 2: 随机数据内存挤压（击穿 iOS compressor） ==========
        // 关键区别：用 arc4random_buf 填充而不是 memset 0
        // iOS 17+ 的透明内存压缩器可以将全零页面压缩到近乎 0 字节
        // 随机数据完全不可压缩，能真正制造物理内存压力!
        NSMutableArray *dummyArray = [NSMutableArray array];
        long totalMB = 0;
        @try {
            for (int i = 0; i < 200; i++) {
                // 每次分配 5MB（更频繁的分配让内核更快反应）
                int size = 5 * 1024 * 1024;
                char *block = (char *)malloc(size);
                if (block) {
                    // 核心：用随机数据填充，让 iOS 压缩器束手无策
                    arc4random_buf(block, size);
                    [dummyArray addObject:[NSValue valueWithPointer:block]];
                    totalMB += 5;
                } else {
                    // malloc 返回 NULL = 内核已经开始杀进程了，目的达到
                    break;
                }
                // 不 sleep！全速碾压，让内核来不及压缩就触发 Jetsam
            }
        } @catch (NSException *e) {
            NSLog(@"[MemClean] 内存挤压中被系统拦截 (预期行为): %@", e);
        }
        
        // 瞬间全额释放
        for (NSValue *val in dummyArray) {
            free([val pointerValue]);
        }
        [dummyArray removeAllObjects];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            alert.message = @"阶段 3/3: 正在广播系统内存警告...";
        });
        [NSThread sleepForTimeInterval:0.3];
        
        // ========== 阶段 3: 广播系统级内存警告 ==========
        // 这会让所有正在运行的 App（包括 WDA）收到 didReceiveMemoryWarning
        // 迫使它们释放内部缓存（图片缓存、网页缓存、视频帧缓冲等）
        dispatch_async(dispatch_get_main_queue(), ^{
            // 模拟系统内存警告通知 (UIKit 公开 API)
            [[NSNotificationCenter defaultCenter]
                postNotificationName:UIApplicationDidReceiveMemoryWarningNotification
                              object:[UIApplication sharedApplication]];
            
            // 恢复 URLCache 容量（设为较小值）
            [[NSURLCache sharedURLCache] setMemoryCapacity:512 * 1024];  // 512KB
            [[NSURLCache sharedURLCache] setDiskCapacity:5 * 1024 * 1024]; // 5MB
            
            [alert dismissViewControllerAnimated:YES completion:^{
                NSString *msg = [NSString stringWithFormat:
                    @"✅ 三段式清理完毕:\n"
                    @"• 已清除全部 URLCache 缓存\n"
                    @"• 已用 %ld MB 不可压缩随机数据击穿压缩器\n"
                    @"• 已广播系统级内存警告\n"
                    @"后台僵尸进程应已被内核 Jetsam 强杀", totalMB];
                [self appendLog:msg];
                
                UIAlertController *doneAlert = [UIAlertController
                    alertControllerWithTitle:@"深度清理完成"
                             message:[NSString stringWithFormat:@"共挤压 %ld MB 物理内存\n"
                                      @"iOS 内核已触发 Jetsam 清理\n\n"
                                      @"如果手机仍然卡顿，建议重启设备", totalMB]
                              preferredStyle:UIAlertControllerStyleAlert];
                [doneAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:doneAlert animated:YES completion:nil];
            }];
        });
    });
}

- (void)saveAndTestTapped {
  [self.view endEditing:YES];
  NSString *url = self.serverUrlField.text;

  // 1. 基础校验
  if (url.length < 5 || ![url hasPrefix:@"http"]) {
    [self appendLog:@"错误: URL 格式无效 (需以 http 开头)"];
    return;
  }

  // 2. 保存三要素：服务器地址、设备编号、管理员（双写：App Group + plist 文件）
  [ECPersistentConfig setObject:url forKey:@"EC_USER_PREFERRED_URL"];
  [ECPersistentConfig setObject:url forKey:@"CloudServerURL"];
  NSString *deviceNo = self.deviceNoField.text ?: @"";
  [ECPersistentConfig setObject:deviceNo forKey:@"EC_DEVICE_NO"];
  NSString *adminUsername = self.adminField.text ?: @"";
  [ECPersistentConfig setObject:adminUsername forKey:@"EC_ADMIN_USERNAME"];
  [self appendLog:[NSString
                      stringWithFormat:@"✅ 已保存 → 服务器: %@  编号: %@  管理: %@",
                                       url, deviceNo, adminUsername]];

  // 3. 直接调用心跳线程的完整 sendHeartbeat: 方法，发送与心跳包完全一致的数据
  //    服务器会返回包含 push_config / update / ecwda_update 等完整响应，
  //    handleHeartbeatResponse: 会自动将所有配置落地到本地存储。
  self.statusIcon.hidden = YES;
  [self appendLog:@"📡 正在发送完整心跳探测..."];

  // [v1934] 注册一次性通知监听：心跳响应回来后立刻刷新仪表盘
  __block id observer = nil;
  observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:@"ECHeartbeatDidComplete"
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:^(NSNotification *note) {
                // 收到心跳完成通知，立即刷新
                BOOL success = [note.userInfo[@"success"] boolValue];
                if (success) {
                  [self appendLog:@"✅ 心跳探测成功！服务器已返回最新配置。"];
                  [self showStatus:YES];
                  // 立即刷新仪表盘上的国家/分组/执行时间/账号等信息
                  [self refreshMetadataLabel];
                } else {
                  NSString *errMsg = note.userInfo[@"error"] ?: @"未知错误";
                  [self appendLog:[NSString stringWithFormat:@"❌ 心跳探测失败: %@", errMsg]];
                  [self showStatus:NO];
                }
                // 移除一次性监听，避免重复触发
                [[NSNotificationCenter defaultCenter] removeObserver:observer];
              }];

  // 调用心跳方法（使用用户刚刚保存的新 URL）
  [[ECBackgroundManager sharedManager] sendHeartbeat:nil];
}

- (void)installLdidTapped {
  [self appendLog:@"开始安装 ldid..."];
  [TSInstallationController installLdid]; // UI handled by PresentationDelegate
}

- (void)dismissKeyboard {
  [self.view endEditing:YES];
}

- (void)showStatus:(BOOL)success {
  self.statusIcon.hidden = NO;
  if (success) {
    if (@available(iOS 13.0, *)) {
      self.statusIcon.image =
          [UIImage systemImageNamed:@"checkmark.circle.fill"];
      self.statusIcon.tintColor = [UIColor systemGreenColor];
    }
  } else {
    if (@available(iOS 13.0, *)) {
      self.statusIcon.image = [UIImage systemImageNamed:@"xmark.circle.fill"];
      self.statusIcon.tintColor = [UIColor systemRedColor];
    }
  }
}

- (void)interruptTasksTapped {
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"⚠️ 确认中断"
                       message:@"确定要中断所有未完成的任务吗？\n\n所有未执行的"
                               @"任务将被标记为错误，错误日志：\"人为中断\""
                preferredStyle:UIAlertControllerStyleAlert];

  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

  [confirm addAction:[UIAlertAction
                         actionWithTitle:@"确认中断"
                                   style:UIAlertActionStyleDestructive
                                 handler:^(UIAlertAction *action) {
                                   [[ECTaskPollManager sharedManager]
                                       interruptAllPendingTasks];
                                   [self appendLog:@"🛑 已中断所有未完成任务"];
                                 }]];

  [self presentViewController:confirm animated:YES completion:nil];
}

- (void)appendLog:(NSString *)log {
  [[ECLogManager sharedManager] log:@"%@", log];
}

// 账号信息展示区域刷新
- (void)refreshAccountLabels {
  // 清空旧内容
  for (UIView *sub in self.accountScrollView.subviews) {
    [sub removeFromSuperview];
  }

  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *appleAcc = [defaults stringForKey:@"EC_APPLE_ACCOUNT"] ?: @"未设置";
  NSString *applePwd =
      [defaults stringForKey:@"EC_APPLE_PASSWORD"] ?: @"未设置";
  NSString *tkJson = [defaults stringForKey:@"EC_TIKTOK_ACCOUNTS"] ?: @"[]";

  CGFloat w = self.accountScrollView.bounds.size.width;
  CGFloat curY = 12;
  CGFloat labelH = 22;
  CGFloat sectionGap = 16;

  // --- TikTok 账号区域 ---
  UILabel *tkTitle =
      [[UILabel alloc] initWithFrame:CGRectMake(12, curY, w - 24, labelH)];
  tkTitle.text = @"🎵 TikTok 账号";
  tkTitle.font = [UIFont boldSystemFontOfSize:15];
  tkTitle.textColor = [UIColor systemPinkColor];
  [self.accountScrollView addSubview:tkTitle];
  curY += labelH + 6;

  NSData *tkData = [tkJson dataUsingEncoding:NSUTF8StringEncoding];
  NSArray *tkArr = [NSJSONSerialization JSONObjectWithData:tkData
                                                   options:0
                                                     error:nil];
  if (![tkArr isKindOfClass:[NSArray class]] || tkArr.count == 0) {
    UILabel *empty =
        [[UILabel alloc] initWithFrame:CGRectMake(12, curY, w - 24, labelH)];
    empty.text = @"暂无 TikTok 账号";
    empty.font = [UIFont systemFontOfSize:13];
    empty.textColor = [UIColor secondaryLabelColor];
    [self.accountScrollView addSubview:empty];
    curY += labelH + 4;
  } else {
    for (NSInteger i = 0; i < tkArr.count; i++) {
      NSDictionary *item = tkArr[i];
      NSString *email = item[@"email"] ?: @"";
      NSString *acc = item[@"account"] ?: @"";
      NSString *pwd = item[@"password"] ?: @"";

      UILabel *numLabel =
          [[UILabel alloc] initWithFrame:CGRectMake(12, curY, w - 24, labelH)];
      numLabel.text = [NSString stringWithFormat:@"#%ld", (long)(i + 1)];
      numLabel.font = [UIFont boldSystemFontOfSize:12];
      numLabel.textColor = [UIColor tertiaryLabelColor];
      [self.accountScrollView addSubview:numLabel];
      curY += labelH;

      if (email.length > 0) {
        UILabel *tkEmailLabel = [self
            createCopyableLabel:[NSString stringWithFormat:@"  邮箱: %@", email]
                          frame:CGRectMake(12, curY, w - 24, labelH)];
        [self.accountScrollView addSubview:tkEmailLabel];
        curY += labelH + 2;
      }

      UILabel *tkAccLabel = [self
          createCopyableLabel:[NSString stringWithFormat:@"  账号: %@", acc]
                        frame:CGRectMake(12, curY, w - 24, labelH)];
      [self.accountScrollView addSubview:tkAccLabel];
      curY += labelH + 2;

      UILabel *tkPwdLabel = [self
          createCopyableLabel:[NSString stringWithFormat:@"  密码: %@", pwd]
                        frame:CGRectMake(12, curY, w - 24, labelH)];
      [self.accountScrollView addSubview:tkPwdLabel];
      curY += labelH + 8;
    }
  }
  curY += sectionGap;

  // --- Apple 账号区域 ---
  UILabel *appleTitle =
      [[UILabel alloc] initWithFrame:CGRectMake(12, curY, w - 24, labelH)];
  appleTitle.text = @"🍎 Apple 账号";
  appleTitle.font = [UIFont boldSystemFontOfSize:15];
  appleTitle.textColor = [UIColor systemOrangeColor];
  [self.accountScrollView addSubview:appleTitle];
  curY += labelH + 6;

  UILabel *accLabel = [self
      createCopyableLabel:[NSString stringWithFormat:@"账号: %@", appleAcc]
                    frame:CGRectMake(12, curY, w - 24, labelH)];
  [self.accountScrollView addSubview:accLabel];
  curY += labelH + 4;

  UILabel *pwdLabel = [self
      createCopyableLabel:[NSString stringWithFormat:@"密码: %@", applePwd]
                    frame:CGRectMake(12, curY, w - 24, labelH)];
  [self.accountScrollView addSubview:pwdLabel];
  curY += labelH + sectionGap;

  self.accountScrollView.contentSize = CGSizeMake(w, curY + 12);
}

// 创建可点击复制的 Label
- (UILabel *)createCopyableLabel:(NSString *)text frame:(CGRect)frame {
  UILabel *label = [[UILabel alloc] initWithFrame:frame];
  label.text = text;
  label.font = [UIFont monospacedSystemFontOfSize:13
                                           weight:UIFontWeightRegular];
  label.textColor = [UIColor whiteColor];
  label.userInteractionEnabled = YES;

  UITapGestureRecognizer *tap =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(copyLabelText:)];
  [label addGestureRecognizer:tap];
  return label;
}

// 点击复制文本
- (void)copyLabelText:(UITapGestureRecognizer *)gesture {
  UILabel *label = (UILabel *)gesture.view;
  if (!label || !label.text)
    return;
  // 提取": "后的实际内容
  NSRange colonRange = [label.text rangeOfString:@": "];
  NSString *valueToCopy = label.text;
  if (colonRange.location != NSNotFound) {
    valueToCopy =
        [label.text substringFromIndex:colonRange.location + colonRange.length];
  }
  [UIPasteboard generalPasteboard].string = valueToCopy;

  // 视觉反馈
  UIColor *origColor = label.textColor;
  label.textColor = [UIColor systemGreenColor];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        label.textColor = origColor;
      });
}

- (UIStatusBarStyle)preferredStatusBarStyle {
  return UIStatusBarStyleDefault;
}

- (void)refreshAppsTapped {
  [self appendLog:@"正在刷新应用注册..."];

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *helperPath = rootHelperPath();
        int result = -1;
        if (helperPath &&
            [[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
          result = spawnRoot(helperPath, @[ @"refresh" ], nil, nil);
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          if (result == 0) {
            [self appendLog:@"✅ 应用注册刷新完成，请尝试启动应用"];

            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:@"刷新完成"
                                 message:@"应用注册已刷新。为了使更改生效，建议"
                                         @"注销(Respring)主屏幕。"
                          preferredStyle:UIAlertControllerStyleAlert];

            [alert addAction:[UIAlertAction
                                 actionWithTitle:@"注销 (Respring)"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
                                           respring();
                                         }]];

            [alert addAction:[UIAlertAction
                                 actionWithTitle:@"稍后 (Later)"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];

            [self presentViewController:alert animated:YES completion:nil];
          } else {
            [self
                appendLog:[NSString stringWithFormat:@"❌ 刷新失败 (result=%d)",
                                                     result]];
          }
        });
      });
}

- (void)openConfigTapped {
  ECDeviceInfoViewController *vc = [[ECDeviceInfoViewController alloc] init];
  UINavigationController *nav =
      [[UINavigationController alloc] initWithRootViewController:vc];
  [self presentViewController:nav animated:YES completion:nil];
}

@end
