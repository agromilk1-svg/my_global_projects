//
//  ECNetworkConfigViewController.m
//  ECMAIN
//

#import "ECNetworkConfigViewController.h"
#import "../Core/ECLogManager.h"
#import "../Core/ECVPNConfigManager.h"
#import "ConfigCells.h"
#import <NetworkExtension/NetworkExtension.h>
#import <arpa/inet.h>
#import <ifaddrs.h>

// Declare rootHelper tools
extern int spawnRoot(NSString *path, NSArray *args, NSString **stdOut,
                     NSString **stdErr);
extern NSString *rootHelperPath(void);

@interface ECNetworkConfigViewController () <
    UITableViewDelegate, UITableViewDataSource, UITextFieldDelegate>

@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSMutableDictionary *configData;
@property(nonatomic, strong) NSArray *sections;

@end

@implementation ECNetworkConfigViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"全局网络配置";
  self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

  // Load global config
  self.configData =
      [[[ECVPNConfigManager sharedManager] globalNetworkSettings] mutableCopy];
  if (!self.configData) {
    self.configData = [NSMutableDictionary dictionary];
  }
  // Set default mode if not exists
  if (!self.configData[@"ip_config_mode"]) {
    self.configData[@"ip_config_mode"] = @NO; // Default is Automatic
  }

  // Setup Save button
  UIBarButtonItem *saveButton =
      [[UIBarButtonItem alloc] initWithTitle:@"保存"
                                       style:UIBarButtonItemStyleDone
                                      target:self
                                      action:@selector(saveConfigAndPop)];
  self.navigationItem.rightBarButtonItem = saveButton;

  [self setupTableView];
  [self loadCurrentNetworkInfo];
  [self rebuildSections];
}

- (void)setupTableView {
  self.tableView =
      [[UITableView alloc] initWithFrame:self.view.bounds
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
  self.tableView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.tableView];

  [self.tableView registerClass:[ConfigInputCell class]
         forCellReuseIdentifier:@"InputCell"];
  [self.tableView registerClass:[ConfigSwitchCell class]
         forCellReuseIdentifier:@"SwitchCell"];
  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"ActionCell"];
}

- (void)rebuildSections {
  NSMutableArray *sect = [NSMutableArray array];

  // --- Category 1: Wi-Fi Configuration ---
  NSMutableArray *wifiRows = [NSMutableArray array];
  [wifiRows addObject:@{
    @"id" : @"wifi_ssid",
    @"label" : @"Wi-Fi 名称",
    @"type" : @"text",
    @"placeholder" : @"SSID"
  }];
  [wifiRows addObject:@{
    @"id" : @"wifi_password",
    @"label" : @"Wi-Fi 密码",
    @"type" : @"text",
    @"placeholder" : @"密码 (8位以上)"
  }];
  [wifiRows addObject:@{
    @"id" : @"action_configure_wifi",
    @"label" : @"应用 Wi-Fi 配置",
    @"type" : @"action",
    @"color" : [UIColor systemOrangeColor]
  }];
  [sect addObject:@{@"title" : @"Wi-Fi 配置", @"rows" : wifiRows}];

  // --- Category 2: IP Configuration ---
  NSMutableArray *ipRows = [NSMutableArray array];

  // 2.1 Mode Switch
  [ipRows addObject:@{
    @"id" : @"ip_config_mode",
    @"label" : @"手动 IP 模式",
    @"type" : @"switch",
    @"value" : @"手动"
  }];

  // 2.2 Manual Fields
  BOOL isManualIP = [self.configData[@"ip_config_mode"] boolValue];
  if (isManualIP) {
    [ipRows addObject:@{
      @"id" : @"wifi_ip",
      @"label" : @"IP 地址",
      @"type" : @"text",
      @"placeholder" : @"192.168.1.50"
    }];
    [ipRows addObject:@{
      @"id" : @"wifi_subnet",
      @"label" : @"子网掩码",
      @"type" : @"text",
      @"placeholder" : @"255.255.255.0"
    }];
    [ipRows addObject:@{
      @"id" : @"wifi_gateway",
      @"label" : @"路由器",
      @"type" : @"text",
      @"placeholder" : @"192.168.1.1"
    }];
    [ipRows addObject:@{
      @"id" : @"wifi_dns",
      @"label" : @"DNS",
      @"type" : @"text",
      @"placeholder" : @"8.8.8.8,1.1.1.1"
    }];
  }

  // 2.3 Apply Button
  [ipRows addObject:@{
    @"id" : @"apply_ip_config",
    @"label" : @"⚙️ 提交静态 IP 设定",
    @"type" : @"action",
    @"action" : @"applyIPConfig"
  }];

  [sect addObject:@{@"title" : @"IP 配置", @"rows" : ipRows}];

  self.sections = sect;
  [self.tableView reloadData];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return [self.sections[section][@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
  return self.sections[section][@"title"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
  NSString *rowType = row[@"type"];
  NSString *key = row[@"id"];

  if ([rowType isEqualToString:@"button"] ||
      [rowType isEqualToString:@"action"]) {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"ActionCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = row[@"label"];
    cell.backgroundColor = row[@"color"] ?: [UIColor systemBlueColor];
    cell.textLabel.textColor = [UIColor whiteColor];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
  } else if ([rowType isEqualToString:@"text"]) {
    ConfigInputCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"InputCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = row[@"label"];
    cell.textLabel.textColor = [UIColor blackColor];
    cell.backgroundColor = [UIColor whiteColor];
    cell.textField.placeholder = row[@"placeholder"];
    id value = self.configData[key];
    cell.textField.text = (value && ![value isKindOfClass:[NSNull class]])
                              ? [NSString stringWithFormat:@"%@", value]
                              : @"";
    cell.textField.textColor = [UIColor darkGrayColor];
    cell.textField.tag = indexPath.section * 1000 + indexPath.row;
    cell.textField.delegate = self;
    cell.textField.keyboardType = UIKeyboardTypeDefault;
    [cell.textField addTarget:self
                       action:@selector(textFieldDidChange:)
             forControlEvents:UIControlEventEditingChanged];
    return cell;
  } else if ([rowType isEqualToString:@"switch"]) {
    ConfigSwitchCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = row[@"label"];
    cell.textLabel.textColor = [UIColor blackColor];
    cell.backgroundColor = [UIColor whiteColor];
    cell.toggle.on = [self.configData[key] boolValue];
    cell.toggle.tag = indexPath.section * 1000 + indexPath.row;
    [cell.toggle removeTarget:nil
                       action:NULL
             forControlEvents:UIControlEventAllEvents];
    [cell.toggle addTarget:self
                    action:@selector(switchValueDidChange:)
          forControlEvents:UIControlEventValueChanged];
    return cell;
  }

  return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [self.view endEditing:YES];
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];

  if ([row[@"id"] isEqualToString:@"action_configure_wifi"]) {
    [self configureWifi];
  } else if ([row[@"id"] isEqualToString:@"apply_ip_config"]) {
    [self applyIPConfig];
  } else if ([row[@"type"] isEqualToString:@"text"]) {
    ConfigInputCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [cell.textField becomeFirstResponder];
  }
}

#pragma mark - Input Handlers

- (void)textFieldDidChange:(UITextField *)sender {
  NSInteger section = sender.tag / 1000;
  NSInteger row = sender.tag % 1000;
  NSDictionary *rowData = self.sections[section][@"rows"][row];
  self.configData[rowData[@"id"]] = sender.text;
}

- (void)switchValueDidChange:(UISwitch *)sender {
  NSInteger section = sender.tag / 1000;
  NSInteger row = sender.tag % 1000;
  NSDictionary *rowData = self.sections[section][@"rows"][row];
  NSString *key = rowData[@"id"];

  self.configData[key] = @(sender.isOn);

  if ([key isEqualToString:@"ip_config_mode"]) {
    [self rebuildSections];
  }
}

- (void)saveConfigAndPop {
  [self.view endEditing:YES];
  [[ECVPNConfigManager sharedManager]
      saveGlobalNetworkSettings:self.configData];

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"成功"
                                          message:@"配置已全局保存。"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"确定"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self.navigationController
                                     popViewControllerAnimated:YES];
                               }]];
  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Network Setup Methods

- (void)loadCurrentNetworkInfo {
  NSString *helperPath = rootHelperPath();
  if (!helperPath)
    return;

  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(helperPath, @[ @"get-network-info" ], &stdOut, &stdErr);
  NSLog(
      @"[ECNetworkConfig] get-network-info ret='%d', stdout='%@', stderr='%@'",
      ret, stdOut, stdErr);

  if (ret == 0 && stdOut.length > 0) {
    NSData *jsonData = [stdOut dataUsingEncoding:NSUTF8StringEncoding];
    if (jsonData) {
      NSError *jsonError = nil;
      NSDictionary *info = [NSJSONSerialization JSONObjectWithData:jsonData
                                                           options:0
                                                             error:&jsonError];
      if ([info isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ECNetworkConfig] Parsed Config: %@", info);

        // 1. IP Config Mode
        NSString *mode = info[@"ip_config_mode"];
        if (mode) {
          BOOL isManual = [mode isEqualToString:@"Manual"];
          self.configData[@"ip_config_mode"] = @(isManual);
        }

        // 2. IP, Subnet, Gateway, DNS
        if (info[@"wifi_ip"])
          self.configData[@"wifi_ip"] = info[@"wifi_ip"];
        if (info[@"wifi_subnet"])
          self.configData[@"wifi_subnet"] = info[@"wifi_subnet"];
        if (info[@"wifi_gateway"])
          self.configData[@"wifi_gateway"] = info[@"wifi_gateway"];
        if (info[@"wifi_dns"])
          self.configData[@"wifi_dns"] = info[@"wifi_dns"];

      } else {
        NSLog(@"[ECNetworkConfig] JSON parse error: %@", jsonError);
      }
    }
  }

  // Fallback 兜底逻辑：如果拿到的 IP 或 DNS 为空，给点初始值防崩溃
  NSString *ip = self.configData[@"wifi_ip"];
  if (ip && ip.length > 0 &&
      (!self.configData[@"wifi_gateway"] ||
       [self.configData[@"wifi_gateway"] length] == 0)) {
    NSArray *parts = [ip componentsSeparatedByString:@"."];
    if (parts.count == 4) {
      self.configData[@"wifi_gateway"] = [NSString
          stringWithFormat:@"%@.%@.%@.1", parts[0], parts[1], parts[2]];
    }
  }

  if (!self.configData[@"wifi_dns"] ||
      [self.configData[@"wifi_dns"] length] == 0) {
    self.configData[@"wifi_dns"] = @"8.8.8.8,1.1.1.1";
  }

  // 异步获取 SSID 并刷新 UI
  if (@available(iOS 14.0, *)) {
    [NEHotspotNetwork fetchCurrentWithCompletionHandler:^(
                          NEHotspotNetwork *_Nullable currentNetwork) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (currentNetwork && currentNetwork.SSID) {
          self.configData[@"wifi_ssid"] = currentNetwork.SSID;
          NSLog(@"[ECNetworkConfig] Fetched SSID: %@", currentNetwork.SSID);
        } else {
          NSLog(@"[ECNetworkConfig] SSID could not be fetched (nil)");
        }
        [self rebuildSections];
        [self.tableView reloadData];
      });
    }];
  } else {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self rebuildSections];
      [self.tableView reloadData];
    });
  }
}

- (void)configureWifi {
  [self.view endEditing:YES];
  NSString *ssid = self.configData[@"wifi_ssid"];
  NSString *password = self.configData[@"wifi_password"];

  if (!ssid.length) {
    [self showAlert:@"错误" message:@"请输入 Wi-Fi 名称"];
    return;
  }

  NEHotspotConfiguration *config = nil;
  if (password.length >= 8) {
    config = [[NEHotspotConfiguration alloc] initWithSSID:ssid
                                               passphrase:password
                                                    isWEP:NO];
  } else if (password.length == 0) {
    config = [[NEHotspotConfiguration alloc] initWithSSID:ssid];
  } else {
    [self showAlert:@"错误" message:@"密码长度至少 8 位，或留空表示开放网络"];
    return;
  }

  config.joinOnce = NO;

  [[NEHotspotConfigurationManager sharedManager]
      applyConfiguration:config
       completionHandler:^(NSError *error) {
         dispatch_async(dispatch_get_main_queue(), ^{
           if (error) {
             NSString *message =
                 (error.code == NEHotspotConfigurationErrorAlreadyAssociated)
                     ? @"已连接到该 Wi-Fi"
                     : [NSString stringWithFormat:@"连接失败: %@",
                                                  error.localizedDescription];
             [self showAlert:@"Wi-Fi 配置" message:message];
           } else {
             [self showAlert:@"成功"
                     message:[NSString stringWithFormat:@"已配置连接 Wi-Fi: %@",
                                                        ssid]];
           }
         });
       }];

  // Auto-save
  [[ECVPNConfigManager sharedManager]
      saveGlobalNetworkSettings:self.configData];
}

- (void)applyIPConfig {
  [self.view endEditing:YES];
  NSString *ssid = self.configData[@"wifi_ssid"];
  BOOL isManual = [self.configData[@"ip_config_mode"] boolValue];

  if (!isManual) {
    [self showAlert:@"提示"
            message:@"若要使用自动 IP (DHCP)，请在设置 > 通用 > VPN "
                    @"与设备管理中移除已安装的描述文件，或使用 '忘记网络'。"];
    return;
  }

  NSString *ip = self.configData[@"wifi_ip"];
  NSString *subnet = self.configData[@"wifi_subnet"];
  NSString *gateway = self.configData[@"wifi_gateway"];
  NSString *dns = self.configData[@"wifi_dns"];

  if (!ssid || ssid.length == 0 || !ip || ip.length == 0 || !subnet ||
      subnet.length == 0) {
    [self showAlert:@"错误" message:@"请填写 Wi-Fi 名称、IP 地址和子网掩码。"];
    return;
  }

  // Auto-save before apply
  [[ECVPNConfigManager sharedManager]
      saveGlobalNetworkSettings:self.configData];

  void (^runProfileGen)(void) = ^{
    NSString *profile =
        [self generateMobileConfigWithSSID:ssid
                                  password:self.configData[@"wifi_password"]
                                        ip:ip
                                    subnet:subnet
                                   gateway:gateway
                                       dns:dns];
    NSString *docsPath = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *profilePath = [docsPath
        stringByAppendingPathComponent:@"wifi_static_ip.mobileconfig"];
    NSError *error;
    [profile writeToFile:profilePath
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&error];
    if (error) {
      [self showAlert:@"错误"
              message:[NSString stringWithFormat:@"无法保存描述文件: %@",
                                                 error.localizedDescription]];
      return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"描述文件已生成"
                         message:@"描述文件已保存。\n\n如果 IP 未生效:\n1. "
                                 @"设置 > 无线局域网 > (i) > 忽略此网络\n2. "
                                 @"重新连接\n\n安装步骤:\n1. 复制路径/分享\n2. "
                                 @"在 Filza 中打开或使用 AirDrop\n3. 设置 > "
                                 @"通用 > VPN 与设备管理"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制路径"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [[UIPasteboard generalPasteboard]
                                                  setString:profilePath];
                                            }]];
    [alert addAction:[UIAlertAction
                         actionWithTitle:@"Share"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                   NSURL *fileURL =
                                       [NSURL fileURLWithPath:profilePath];
                                   UIActivityViewController *activityVC =
                                       [[UIActivityViewController alloc]
                                           initWithActivityItems:@[ fileURL ]
                                           applicationActivities:nil];
                                   [self presentViewController:activityVC
                                                      animated:YES
                                                    completion:nil];
                                 }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  };

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"选择配置方式"
                       message:@"请选择应用静态 IP 配置的方式。"
                preferredStyle:UIAlertControllerStyleActionSheet];
  [alert addAction:[UIAlertAction actionWithTitle:@"标准模式 (生成描述文件)"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            runProfileGen();
                                          }]];
  [alert
      addAction:[UIAlertAction actionWithTitle:@"Root 模式 (直接修改系统)"
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *action) {
                                         [self applyRootStaticIPWithSSID:ssid
                                                                      ip:ip
                                                                  subnet:subnet
                                                                 gateway:gateway
                                                                     dns:dns];
                                       }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  if ([alert respondsToSelector:@selector(popoverPresentationController)]) {
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2.0,
                   self.view.bounds.size.height / 2.0, 1.0, 1.0);
  }
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyRootStaticIPWithSSID:(NSString *)ssid
                               ip:(NSString *)ip
                           subnet:(NSString *)subnet
                          gateway:(NSString *)gateway
                              dns:(NSString *)dns {
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"警告"
                       message:@"此操作将直接修改系统文件 "
                               @"(preferences.plist)。\nWi-Fi "
                               @"将自动重置以应用更改。\n确认继续？"
                preferredStyle:UIAlertControllerStyleAlert];
  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
  [confirm
      addAction:[UIAlertAction actionWithTitle:@"继续"
                                         style:UIAlertActionStyleDestructive
                                       handler:^(UIAlertAction *action) {
                                         [self executeRootCommandWithIP:ip
                                                                 subnet:subnet
                                                                gateway:gateway
                                                                    dns:dns];
                                       }]];
  [self presentViewController:confirm animated:YES completion:nil];
}

- (void)executeRootCommandWithIP:(NSString *)ip
                          subnet:(NSString *)subnet
                         gateway:(NSString *)gateway
                             dns:(NSString *)dns {
  NSString *helperPath = rootHelperPath();
  NSMutableArray *args = [NSMutableArray
      arrayWithObjects:@"set-static-ip", ip, subnet, gateway, nil];
  if (dns && dns.length > 0)
    [args addObject:dns];
  else
    [args addObject:@""];

  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(helperPath, args, &stdOut, &stdErr);

  if (ret == 0) {
    spawnRoot(helperPath, @[ @"toggle-wifi" ], nil, nil);
    [self showAlert:@"成功"
            message:@"配置已更新，Wi-Fi 已自动重置。\n无需重启设备。"];
  } else {
    [self showAlert:@"错误"
            message:[NSString
                        stringWithFormat:@"辅助程序执行失败 "
                                         @"(ret=%d)。\nSTDOUT: %@\nSTDERR: %@",
                                         ret, stdOut, stdErr]];
  }
}

- (NSString *)generateMobileConfigWithSSID:(NSString *)ssid
                                  password:(NSString *)password
                                        ip:(NSString *)ip
                                    subnet:(NSString *)subnet
                                   gateway:(NSString *)gateway
                                       dns:(NSString *)dns {
  NSString *uuid1 = [[NSUUID UUID] UUIDString];
  NSString *uuid2 = [[NSUUID UUID] UUIDString];

  NSMutableString *dnsArrayStr = [NSMutableString string];
  NSArray *dnsServers = [dns componentsSeparatedByString:@","];
  for (NSString *server in dnsServers) {
    NSString *trimmed =
        [server stringByTrimmingCharactersInSet:[NSCharacterSet
                                                    whitespaceCharacterSet]];
    if (trimmed.length > 0)
      [dnsArrayStr appendFormat:@"<string>%@</string>", trimmed];
  }

  NSString *passwordEntry = @"";
  if (password && password.length >= 8) {
    passwordEntry = [NSString
        stringWithFormat:@"<key>Password</key><string>%@</string>", password];
  }

  NSString *routerEntry = @"";
  if (gateway && gateway.length > 0) {
    routerEntry = [NSString
        stringWithFormat:@"<key>Router</key><string>%@</string>", gateway];
  }

  NSString *profile = [NSString
      stringWithFormat:
          @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
           "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
           "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
           "<plist version=\"1.0\">\n"
           "<dict>\n"
           "  <key>PayloadContent</key>\n"
           "  <array>\n"
           "    <dict>\n"
           "      <key>AutoJoin</key><true/>\n"
           "      <key>EncryptionType</key><string>%@</string>\n"
           "      <key>HIDDEN_NETWORK</key><false/>\n"
           "      <key>PayloadDescription</key><string>配置 Wi-Fi "
           "设置</string>\n"
           "      <key>PayloadDisplayName</key><string>Wi-Fi (%@)</string>\n"
           "      "
           "<key>PayloadIdentifier</key><string>com.ecmain.wifi.%@</string>\n"
           "      "
           "<key>PayloadType</key><string>com.apple.wifi.managed</string>\n"
           "      <key>PayloadUUID</key><string>%@</string>\n"
           "      <key>PayloadVersion</key><integer>1</integer>\n"
           "      <key>SSID_STR</key><string>%@</string>\n"
           "      %@\n"
           "      <key>IPv4</key>\n"
           "      <dict>\n"
           "        <key>ConfigMethod</key><string>Manual</string>\n"
           "        <key>Addresses</key><array><string>%@</string></array>\n"
           "        <key>SubnetMasks</key><array><string>%@</string></array>\n"
           "        %@\n"
           "      </dict>\n"
           "      <key>DNSServerAddresses</key>\n"
           "      <array>%@</array>\n"
           "    </dict>\n"
           "  </array>\n"
           "  <key>PayloadDescription</key><string>ECMAIN Wi-Fi 静态 IP "
           "配置</string>\n"
           "  <key>PayloadDisplayName</key><string>ECMAIN Wi-Fi 配置</string>\n"
           "  "
           "<key>PayloadIdentifier</key><string>com.ecmain.wifiprofile</"
           "string>\n"
           "  <key>PayloadRemovalDisallowed</key><false/>\n"
           "  <key>PayloadType</key><string>Configuration</string>\n"
           "  <key>PayloadUUID</key><string>%@</string>\n"
           "  <key>PayloadVersion</key><integer>1</integer>\n"
           "</dict>\n"
           "</plist>",
          (password && password.length >= 8) ? @"Any" : @"None", ssid, uuid1,
          uuid1, ssid, passwordEntry, ip, subnet, routerEntry, dnsArrayStr,
          uuid2];

  return profile;
}

- (void)showAlert:(NSString *)title message:(NSString *)msg {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:msg
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end
