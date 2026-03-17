#import "ViewController.h"
#import "ECMAIN/Core/ECAppInjector.h"
#import "ECMAIN/Core/ECBackgroundManager.h"
#import "ECMAIN/Core/ECLogManager.h"
#import "ECMAIN/UI/ECDeviceInfoViewController.h"
#import "Network/ECNetworkManager.h"
#import "TrollStoreCore/TSInstallationController.h"
#import "TrollStoreCore/TSPresentationDelegate.h"
#import "TrollStoreCore/TSApplicationsManager.h"
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
  versionLabel.text = @"Build: 2026-03-17 16:50 #1197 (Auto)";
  versionLabel.textColor = [UIColor grayColor];
  versionLabel.textAlignment = NSTextAlignmentRight;
  versionLabel.font = [UIFont systemFontOfSize:12];
  [self.view addSubview:versionLabel];

  // --- MAC Label ---
  self.macLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(padding, 68, width, 20)];
  self.macLabel.text = @"MAC: 获取中...";
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

  // Load saved URL or Default
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  self.serverUrlField.text =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;

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

  NSString *savedNo = [defaults stringForKey:@"EC_DEVICE_NO"];
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

  NSString *savedAdmin = [defaults stringForKey:@"EC_ADMIN_USERNAME"];
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

  // Status Icon (Hidden initially)
  self.statusIcon = [[UIImageView alloc]
      initWithFrame:CGRectMake(CGRectGetMaxX(self.saveTestButton.frame) + 5,
                               y + 5, 30, 30)];
  self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
  self.statusIcon.hidden = YES;
  [self.view addSubview:self.statusIcon];

  // Mic Switch (Moved from Config)
  UILabel *micLabel = [[UILabel alloc]
      initWithFrame:CGRectMake(padding + width / 2 + 20, y, 100, 40)];
  micLabel.text = @"保活(Mic)";
  micLabel.textColor = [UIColor blackColor];
  micLabel.font = [UIFont systemFontOfSize:14];
  [self.view addSubview:micLabel];

  UISwitch *micSwitch = [[UISwitch alloc]
      initWithFrame:CGRectMake(CGRectGetMaxX(micLabel.frame), y + 5, 0, 0)];
  [micSwitch sizeToFit]; // Auto size
  micSwitch.on = [ECBackgroundManager sharedManager].isMicrophoneActive;
  [micSwitch addTarget:self
                action:@selector(micSwitchChanged:)
      forControlEvents:UIControlEventValueChanged];
  [self.view addSubview:micSwitch];

  y += 40 + 20;

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
  CGFloat remainingHeight = self.view.bounds.size.height - y - 100;
  self.accountScrollView = [[UIScrollView alloc]
      initWithFrame:CGRectMake(padding, y, width, remainingHeight)];
  self.accountScrollView.backgroundColor = [UIColor colorWithWhite:0.05
                                                             alpha:1.0];
  self.accountScrollView.layer.cornerRadius = 12;
  self.accountScrollView.showsVerticalScrollIndicator = YES;
  [self.view addSubview:self.accountScrollView];

  // 初次加载账号数据
  [self refreshAccountLabels];

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

  // Fetch MAC Address
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *output = nil;
        NSString *helperPath = rootHelperPath();
        if (helperPath &&
            [[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
          spawnRoot(helperPath, @[ @"get-device-info" ], &output, nil);
        }

        NSString *mac = @"Unknown";
        if (output) {
          NSArray *lines = [output componentsSeparatedByString:@"\n"];
          for (NSString *line in lines) {
            if ([line hasPrefix:@"MAC:"]) {
              mac = [line substringFromIndex:4];
              break;
            }
          }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
          self.macLabel.text = [NSString stringWithFormat:@"MAC: %@", mac];
        });
      });

  // ========== 首次启动：自动检测并安装 ECWDA ==========
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. 检查 ECWDA 是否已安装
        NSString *ecwdaBundleID =
            @"com.facebook.WebDriverAgentRunner.ecwda";
        Class LSAppProxyClass =
            NSClassFromString(@"LSApplicationProxy");
        BOOL ecwdaInstalled = NO;
        if (LSAppProxyClass) {
          id proxy = [LSAppProxyClass
              performSelector:@selector(applicationProxyForIdentifier:)
                   withObject:ecwdaBundleID];
          if (proxy) {
            NSNumber *installed = [proxy valueForKey:@"isInstalled"];
            ecwdaInstalled =
                (installed && [installed boolValue]);
          }
        }

        if (ecwdaInstalled) {
          [[ECLogManager sharedManager]
              log:@"[ECMAIN] ✅ ECWDA 已安装，跳过首次自动安装"];
          return;
        }

        // 2. ECWDA 未安装 → 在 /var/containers/Bundle/Application/ 下搜索 ecwda.ipa
        [[ECLogManager sharedManager]
            log:@"[ECMAIN] ⚠️ 检测到 ECWDA 未安装，正在搜索本地 ecwda.ipa..."];

        NSString *bundleBase = @"/var/containers/Bundle/Application";
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *foundIpaPath = nil;

        NSArray *uuidDirs =
            [fm contentsOfDirectoryAtPath:bundleBase error:nil];
        for (NSString *uuid in uuidDirs) {
          NSString *uuidPath =
              [bundleBase stringByAppendingPathComponent:uuid];
          NSArray *appDirs =
              [fm contentsOfDirectoryAtPath:uuidPath error:nil];
          for (NSString *appDir in appDirs) {
            if ([appDir hasSuffix:@".app"]) {
              NSString *ipaCandidate = [[uuidPath
                  stringByAppendingPathComponent:appDir]
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
        int ret = [[TSApplicationsManager sharedInstance]
                    installIpa:foundIpaPath
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
                dispatch_time(DISPATCH_TIME_NOW,
                              (int64_t)(2.0 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                  [[TSApplicationsManager sharedInstance]
                      openApplicationWithBundleID:ecwdaBundleID];
                  [[ECLogManager sharedManager]
                      log:@"[ECMAIN] 🚀 ECWDA 已拉起"];
                });
          });
        } else {
          [[ECLogManager sharedManager]
              log:[NSString
                      stringWithFormat:
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

#pragma mark - Actions

- (void)saveAndTestTapped {
  [self.view endEditing:YES];
  NSString *url = self.serverUrlField.text;

  // 1. Basic Validation
  if (url.length < 5 || ![url hasPrefix:@"http"]) {
    [self appendLog:@"错误: URL 格式无效 (需以 http 开头)"];
    return;
  }

  // 2. Save Shared Defaults
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  [defaults setObject:url forKey:@"CloudServerURL"];
  NSString *deviceNo = self.deviceNoField.text ?: @"";
  [defaults setObject:deviceNo forKey:@"EC_DEVICE_NO"];
  NSString *adminUsername = self.adminField.text ?: @"";
  [defaults setObject:adminUsername forKey:@"EC_ADMIN_USERNAME"];
  [defaults synchronize];
  [self appendLog:[NSString stringWithFormat:@"已保存 URL: %@  编号: %@  管理员: %@", url,
                                             deviceNo, adminUsername]];

  // 3. Test Connection
  self.statusIcon.hidden = YES;
  [self appendLog:@"正在测试连接..."];

  // Construct Heartbeat URL (Append path if user only gave root)
  NSString *testUrl = url;
  if (![testUrl containsString:@"/heartbeat"]) {
    if ([testUrl hasSuffix:@"/"]) {
      testUrl = [testUrl stringByAppendingString:@"devices/heartbeat"];
    } else {
      testUrl = [testUrl stringByAppendingString:@"/devices/heartbeat"];
    }
  }

  NSDictionary *payload = @{
    @"udid" : @"TEST-PING",
    @"status" : @"ping",
    @"local_ip" : @"127.0.0.1",
    @"device_no" : deviceNo
  };
  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:nil];

  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:testUrl]];
  [request setHTTPMethod:@"POST"];
  [request setHTTPBody:jsonData];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  request.timeoutInterval = 5.0; // Short timeout

  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
              [self appendLog:[NSString
                                  stringWithFormat:@"连接失败: %@",
                                                   error.localizedDescription]];
              [self showStatus:NO];
            } else {
              NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
              if (httpResp.statusCode == 200) {
                [self appendLog:@"✅ 连接成功!"];
                [self showStatus:YES];

                // Restart Heartbeat with new URL
                [[ECBackgroundManager sharedManager] startCloudHeartbeat];
              } else {
                [self
                    appendLog:[NSString
                                  stringWithFormat:@"服务器返回错误: %ld",
                                                   (long)httpResp.statusCode]];
                [self showStatus:NO];
              }
            }
          });
        }] resume];
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

- (void)micSwitchChanged:(UISwitch *)sender {
  [[ECBackgroundManager sharedManager] toggleMicrophoneKeepAlive:sender.isOn];
  [[NSUserDefaults standardUserDefaults] setBool:sender.isOn
                                          forKey:@"EC_AUTO_MIC_ALIVE"];
  [[NSUserDefaults standardUserDefaults] synchronize];
  [self appendLog:[NSString stringWithFormat:@"麦克风保活: %@",
                                             sender.isOn ? @"开启" : @"关闭"]];
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
