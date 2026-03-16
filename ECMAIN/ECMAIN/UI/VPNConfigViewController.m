#import "VPNConfigViewController.h"
#import "../../TrollStoreCore/TSUtil.h"
#import "../Core/ECBackgroundManager.h"
#import "../Core/ECLogManager.h"
#import "../Core/ECProxyURIParser.h"
#import "../Core/ECVPNConfigManager.h"
#import "ECNodeSelectionViewController.h"
#import "ECQRScannerViewController.h"
#import "ProxyTypeSelectionViewController.h"
#import <NetworkExtension/NetworkExtension.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>

#import "ConfigCells.h"

@implementation ConfigInputCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
  if (self) {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor whiteColor];

    self.textLabel.textColor = [UIColor labelColor];
    self.textLabel.font = [UIFont systemFontOfSize:16];

    self.textField = [[UITextField alloc] init];
    self.textField.textColor = [UIColor blackColor];
    self.textField.textAlignment =
        NSTextAlignmentRight; // Right aligned for "Value" style
    self.textField.returnKeyType = UIReturnKeyDone;
    self.textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.textField.autocorrectionType = UITextAutocorrectionTypeNo;

    // Crucial for interactivity if cell captures touches
    self.textField.userInteractionEnabled = YES;

    [self.contentView addSubview:self.textField];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];

  CGFloat width = self.contentView.bounds.size.width;
  CGFloat height = self.contentView.bounds.size.height;
  CGFloat padding = 16.0;

  [self.textLabel sizeToFit];
  CGRect labelFrame = self.textLabel.frame;

  // Start input field right after the label with some padding
  CGFloat inputX = CGRectGetMaxX(labelFrame) + padding;

  // Ensure a minimum gap if label is very short, but priority is maximizing
  // space Ensure input doesn't overlap label

  CGFloat inputWidth = width - inputX - padding;

  // Safety: ensure positive width
  if (inputWidth < 50)
    inputWidth = 50;

  self.textField.frame = CGRectMake(inputX, 0, inputWidth, height);

  // Vertically Center Text Field logic (often handled by the field itself but
  // frame height matters) Ensure text field is on top
  [self.contentView bringSubviewToFront:self.textField];
}
@end

// Switch Cell
@implementation ConfigSwitchCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
  if (self) {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.textLabel.textColor = [UIColor labelColor];

    self.toggle = [[UISwitch alloc] init];
    self.accessoryView = self.toggle;
  }
  return self;
}
@end

@interface VPNConfigViewController () <
    UITableViewDelegate, UITableViewDataSource, ProxyTypeSelectionDelegate,
    UITextFieldDelegate, ECQRScannerDelegate, ECNodeSelectionDelegate>

@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSMutableDictionary
    *configData; // Stores the actual values { "server": "1.2.3.4" }
@property(nonatomic, strong) NSArray *sections; // Array of Section Dictionaries

// Forward declarations to fix build order issues

- (void)executeRootCommandWithIP:(NSString *)ip
                          subnet:(NSString *)subnet
                         gateway:(NSString *)gateway
                             dns:(NSString *)dns;
- (void)applyRootStaticIPWithSSID:(NSString *)ssid
                               ip:(NSString *)ip
                           subnet:(NSString *)subnet
                          gateway:(NSString *)gateway
                              dns:(NSString *)dns;
- (void)showAlert:(NSString *)title message:(NSString *)message;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UISwitch *vpnSwitch;

@end

@implementation VPNConfigViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.navigationItem.title = @"配置";
  self.view.backgroundColor =
      [UIColor systemGroupedBackgroundColor]; // User requested White

  // Load from Manager
  if (self.nodeID) {
    NSDictionary *node =
        [[ECVPNConfigManager sharedManager] nodeWithID:self.nodeID];
    if (node) {
      self.configData = [node mutableCopy];
    } else {
      self.configData = [NSMutableDictionary dictionary];
    }
  } else {
    self.configData = [NSMutableDictionary dictionary];
    self.configData[@"type"] = @"Shadowsocks";
  }

  // Ensure default Local Proxy Port is visible (Backend handles 0->7890, but UI
  // should show it)
  if (!self.configData[@"proxy_port"] ||
      [self.configData[@"proxy_port"] intValue] == 0) {
    self.configData[@"proxy_port"] = @(7890);
  }

  [self setupUI];
  [self rebuildSections];

  // Tap to dismiss keyboard
  UITapGestureRecognizer *tap =
      [[UITapGestureRecognizer alloc] initWithTarget:self.view
                                              action:@selector(endEditing:)];
  tap.cancelsTouchesInView = NO; // Allow table selection
  [self.view addGestureRecognizer:tap];

  // Status Observer
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(updateStatus)
             name:NEVPNStatusDidChangeNotification
           object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self updateStatus];
  [self setNeedsStatusBarAppearanceUpdate];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
  return UIStatusBarStyleDefault;
}

- (void)setupUI {
  // 1. TableView
  self.tableView =
      [[UITableView alloc] initWithFrame:self.view.bounds
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
  [self.tableView registerClass:[ConfigInputCell class]
         forCellReuseIdentifier:@"InputCell"];
  [self.tableView registerClass:[ConfigSwitchCell class]
         forCellReuseIdentifier:@"SwitchCell"];
  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"ActionCell"];
  [self.view addSubview:self.tableView];

  // Adjust logic for iPhone X+ safety area if needed, but tableview handles it
  // mostly.
}

#pragma mark - Schema Generation

- (void)rebuildSections {
  NSString *type = self.configData[@"type"] ?: @"Shadowsocks";
  NSMutableArray *sect = [NSMutableArray array];

  // --- Category 1: VPN Configuration ---
  NSMutableArray *vpnRows = [NSMutableArray array];

  // 1.1 Basic
  [vpnRows addObject:@{
    @"id" : @"type",
    @"label" : @"类型",
    @"type" : @"selector",
    @"value" : type
  }];
  [vpnRows addObject:@{
    @"id" : @"action_scan_qr",
    @"label" : @"📷 扫描二维码",
    @"type" : @"action",
    @"color" : [UIColor systemGreenColor]
  }];
  [vpnRows addObject:@{
    @"id" : @"server",
    @"label" : @"服务器",
    @"type" : @"text",
    @"placeholder" : @"example.com"
  }];
  [vpnRows addObject:@{
    @"id" : @"port",
    @"label" : @"端口",
    @"type" : @"number",
    @"placeholder" : @"8080"
  }];
  [vpnRows addObject:@{
    @"id" : @"name",
    @"label" : @"备注",
    @"type" : @"text",
    @"placeholder" : @"可选的"
  }];

  // 1.2 Auth & Core
  if ([type isEqualToString:@"Shadowsocks"]) {
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"cipher",
      @"label" : @"加密",
      @"type" : @"text",
      @"placeholder" : @"aes-256-gcm"
    }];
  } else if ([type isEqualToString:@"ShadowsocksR"]) {
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"cipher",
      @"label" : @"加密",
      @"type" : @"text",
      @"placeholder" : @"aes-256-cfb"
    }];
    [vpnRows addObject:@{
      @"id" : @"protocol",
      @"label" : @"协议",
      @"type" : @"text",
      @"placeholder" : @"origin"
    }];
    [vpnRows addObject:@{
      @"id" : @"obfs",
      @"label" : @"混淆",
      @"type" : @"text",
      @"placeholder" : @"plain"
    }];
    [vpnRows addObject:@{
      @"id" : @"protocol-param",
      @"label" : @"协议参数",
      @"type" : @"text"
    }];
    [vpnRows addObject:@{
      @"id" : @"obfs-param",
      @"label" : @"混淆参数",
      @"type" : @"text"
    }];
  } else if ([type isEqualToString:@"VMess"]) {
    [vpnRows
        addObject:@{@"id" : @"uuid", @"label" : @"UUID", @"type" : @"text"}];
    [vpnRows addObject:@{
      @"id" : @"alterId",
      @"label" : @"AlterID",
      @"type" : @"number",
      @"placeholder" : @"0"
    }];
    [vpnRows addObject:@{
      @"id" : @"cipher",
      @"label" : @"加密",
      @"type" : @"text",
      @"placeholder" : @"auto"
    }];
  } else if ([type isEqualToString:@"VLESS"]) {
    [vpnRows
        addObject:@{@"id" : @"uuid", @"label" : @"UUID", @"type" : @"text"}];
    [vpnRows addObject:@{
      @"id" : @"flow",
      @"label" : @"流控",
      @"type" : @"text",
      @"placeholder" : @"xtls-rprx-vision"
    }];
  } else if ([type isEqualToString:@"Trojan"]) {
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{@"id" : @"sni", @"label" : @"SNI", @"type" : @"text"}];
  } else if ([type isEqualToString:@"Hysteria"] ||
             [type isEqualToString:@"Hysteria2"]) {
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码/Token",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{@"id" : @"sni", @"label" : @"SNI", @"type" : @"text"}];
    [vpnRows addObject:@{
      @"id" : @"up",
      @"label" : @"上行(Mbps)",
      @"type" : @"number"
    }];
    [vpnRows addObject:@{
      @"id" : @"down",
      @"label" : @"下行(Mbps)",
      @"type" : @"number"
    }];
  } else if ([type isEqualToString:@"WireGuard"]) {
    [vpnRows addObject:@{
      @"id" : @"ip",
      @"label" : @"本机 IP",
      @"type" : @"text",
      @"placeholder" : @"10.0.0.2/32"
    }];
    [vpnRows addObject:@{
      @"id" : @"private-key",
      @"label" : @"私钥",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"public-key",
      @"label" : @"对端公钥",
      @"type" : @"text"
    }];
    [vpnRows addObject:@{
      @"id" : @"mtu",
      @"label" : @"MTU",
      @"type" : @"number",
      @"placeholder" : @"1420"
    }];
  } else if ([type isEqualToString:@"Tuic"]) {
    [vpnRows
        addObject:@{@"id" : @"uuid", @"label" : @"UUID", @"type" : @"text"}];
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"congestion_controller",
      @"label" : @"拥塞控制",
      @"type" : @"text",
      @"placeholder" : @"bbr"
    }];
  } else if ([type isEqualToString:@"Socks5"]) {
    [vpnRows
        addObject:@{@"id" : @"user", @"label" : @"用户", @"type" : @"text"}];
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"cipher",
      @"label" : @"算法",
      @"type" : @"text",
      @"placeholder" : @"auto"
    }];
    [vpnRows addObject:@{
      @"id" : @"plugin",
      @"label" : @"插件",
      @"type" : @"text",
      @"placeholder" : @"none"
    }];
    [vpnRows addObject:@{
      @"id" : @"tfo",
      @"label" : @"TCP 快速打开",
      @"type" : @"switch"
    }];
    [vpnRows addObject:@{
      @"id" : @"udp",
      @"label" : @"UDP 转发",
      @"type" : @"switch"
    }];
  } else if ([type isEqualToString:@"Snell"]) {
    [vpnRows addObject:@{
      @"id" : @"psk",
      @"label" : @"PSK",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"version",
      @"label" : @"版本",
      @"type" : @"text",
      @"placeholder" : @"2"
    }];
  } else if ([type isEqualToString:@"HTTP"] ||
             [type isEqualToString:@"HTTPS"]) {
    [vpnRows
        addObject:@{@"id" : @"user", @"label" : @"用户", @"type" : @"text"}];
    [vpnRows addObject:@{
      @"id" : @"password",
      @"label" : @"密码",
      @"type" : @"text",
      @"secure" : @NO
    }];
    [vpnRows addObject:@{
      @"id" : @"tfo",
      @"label" : @"TCP 快速打开",
      @"type" : @"switch"
    }];
    [vpnRows addObject:@{
      @"id" : @"udp",
      @"label" : @"UDP 转发",
      @"type" : @"switch"
    }];
    if ([type isEqualToString:@"HTTPS"]) {
      [vpnRows
          addObject:@{@"id" : @"tls", @"label" : @"TLS", @"type" : @"switch"}];
      [vpnRows
          addObject:@{@"id" : @"sni", @"label" : @"SNI", @"type" : @"text"}];
    }
  }

  // 1.3 Transport
  if ([type isEqualToString:@"VMess"] || [type isEqualToString:@"VLESS"] ||
      [type isEqualToString:@"Trojan"]) {
    [vpnRows addObject:@{
      @"id" : @"network",
      @"label" : @"传输协议",
      @"type" : @"text",
      @"placeholder" : @"ws/tcp/grpc"
    }];
    [vpnRows
        addObject:@{@"id" : @"tls", @"label" : @"TLS", @"type" : @"switch"}];
    [vpnRows addObject:@{
      @"id" : @"ws-path",
      @"label" : @"WS 路径",
      @"type" : @"text"
    }];
    [vpnRows addObject:@{
      @"id" : @"ws-host",
      @"label" : @"WS Host",
      @"type" : @"text"
    }];
  }
  if ([type isEqualToString:@"Shadowsocks"]) {
    [vpnRows addObject:@{
      @"id" : @"udp",
      @"label" : @"UDP 转发",
      @"type" : @"switch"
    }];
    [vpnRows addObject:@{
      @"id" : @"plugin",
      @"label" : @"插件",
      @"type" : @"text",
      @"placeholder" : @"obfs"
    }];
    [vpnRows addObject:@{
      @"id" : @"plugin-opts",
      @"label" : @"插件参数",
      @"type" : @"text"
    }];
  }

  // ShadowsocksR / Shadowsocks
  if ([type isEqualToString:@"Socks5"] || [type isEqualToString:@"HTTP"] ||
      [type isEqualToString:@"HTTPS"] ||
      [type isEqualToString:@"Shadowsocks"] ||
      [type isEqualToString:@"ShadowsocksR"] ||
      [type isEqualToString:@"Trojan"] || [type isEqualToString:@"VMess"] ||
      [type isEqualToString:@"VLESS"]) {
    NSString *throughID = self.configData[@"proxy_through_id"];
    NSString *throughName = @"无 (直连)";
    if (throughID) {
      NSDictionary *n =
          [[ECVPNConfigManager sharedManager] nodeWithID:throughID];
      if (n)
        throughName = n[@"name"] ?: n[@"server"];
    }
    [vpnRows addObject:@{
      @"id" : @"proxy_through_id",
      @"label" : @"代理通过",
      @"type" : @"selector",
      @"value" : throughName
    }];
  }

  // 1.3.2 MTU (Added based on user request)
  [vpnRows addObject:@{
    @"id" : @"mtu",
    @"label" : @"MTU",
    @"type" : @"number",
    @"placeholder" : @"1400"
  }];

  // 1.4 Proxy Settings
  [vpnRows addObject:@{
    @"id" : @"proxy_type",
    @"label" : @"代理类型",
    @"type" : @"selector",
    @"value" : @"HTTP & Socks5"
  }];
  [vpnRows addObject:@{
    @"id" : @"proxy_port",
    @"label" : @"代理端口",
    @"type" : @"number",
    @"placeholder" : @"7890"
  }];
  [vpnRows addObject:@{
    @"id" : @"proxy_address",
    @"label" : @"代理地址",
    @"type" : @"selector",
    @"value" : @"127.0.0.1"
  }];

  // 1.5 Actions
  [vpnRows addObject:@{
    @"id" : @"action_save",
    @"label" : @"保存代理节点",
    @"type" : @"action",
    @"color" : [UIColor systemBlueColor]
  }];
  // Removed "vpn_switch" as it belongs to the dashboard list now

  // Add VPN Section
  [sect addObject:@{@"title" : @"VPN 配置", @"rows" : vpnRows}];

  self.sections = sect;
  [self.tableView reloadData];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  NSDictionary *sect = self.sections[section];
  return [sect[@"rows"] count];
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
  return self.sections[section][@"title"];
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
  if ([row[@"type"] isEqualToString:@"log_text"]) {
    return 500; // Fixed height for log viewer (Increased from 220)
  }
  return 44; // Default row height
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
  NSString *rowType = row[@"type"];
  NSString *key = row[@"id"];
  if ([rowType isEqualToString:@"selector"]) {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"ActionCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text =
        [NSString stringWithFormat:@"%@: %@", row[@"label"], row[@"value"]];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.backgroundColor = [UIColor whiteColor];
    cell.textLabel.textColor = [UIColor blackColor];
    return cell;
  } else if ([rowType isEqualToString:@"button"] ||
             [rowType isEqualToString:@"action"]) {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"ActionCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = row[@"label"];

    // Filled Button Style
    if ([rowType isEqualToString:@"action"]) {
      cell.backgroundColor = row[@"color"] ?: [UIColor systemBlueColor];
      cell.textLabel.textColor = [UIColor whiteColor];
      cell.textLabel.font = [UIFont boldSystemFontOfSize:17];
    } else {
      // Legacy/Standard Button
      cell.backgroundColor = [UIColor whiteColor];
      cell.textLabel.textColor = row[@"color"] ?: [UIColor systemBlueColor];
      cell.textLabel.font = [UIFont systemFontOfSize:17];
    }

    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
  } else if ([rowType isEqualToString:@"vpn_switch"]) {
    ConfigSwitchCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = @"VPN 连接";
    cell.textLabel.textColor = [UIColor blackColor];
    cell.backgroundColor = [UIColor whiteColor];
    cell.toggle.on = [ECBackgroundManager sharedManager].isVPNActive;
    [cell.toggle removeTarget:nil
                       action:NULL
             forControlEvents:UIControlEventAllEvents];
    [cell.toggle addTarget:self
                    action:@selector(vpnSwitchToggled:)
          forControlEvents:UIControlEventValueChanged];
    self.vpnSwitch = cell.toggle;
    return cell;
  } else if ([rowType isEqualToString:@"text"] ||
             [rowType isEqualToString:@"number"]) {
    ConfigInputCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"InputCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = row[@"label"];
    cell.textLabel.textColor = [UIColor blackColor];
    cell.backgroundColor = [UIColor whiteColor];
    cell.textField.placeholder = row[@"placeholder"];
    // Safe string assignment to prevent crash if value is NSNumber or nil
    id value = self.configData[key];
    if (value && ![value isKindOfClass:[NSNull class]]) {
      cell.textField.text = [NSString stringWithFormat:@"%@", value];
    } else {
      cell.textField.text = @"";
    }
    cell.textField.textColor = [UIColor darkGrayColor];
    cell.textField.tag = indexPath.section * 1000 + indexPath.row;
    cell.textField.delegate = self;
    cell.textField.keyboardType = [rowType isEqualToString:@"number"]
                                      ? UIKeyboardTypeNumberPad
                                      : UIKeyboardTypeDefault;
    cell.textField.secureTextEntry = [row[@"secure"] boolValue];
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
  } else if ([rowType isEqualToString:@"log_text"]) {
    // Create a custom cell with UITextView for log display
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                               reuseIdentifier:@"LogCell"];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.backgroundColor = [UIColor colorWithWhite:0.95 alpha:1.0];

    UITextView *textView = [[UITextView alloc]
        initWithFrame:CGRectMake(10, 5, tableView.frame.size.width - 20, 480)];
    textView.font = [UIFont fontWithName:@"Menlo" size:10];
    textView.textColor = [UIColor darkGrayColor];
    textView.backgroundColor = [UIColor clearColor];
    textView.editable = NO;
    textView.text = [self readLogContent];
    textView.tag = 9999; // For later retrieval
    [cell.contentView addSubview:textView];

    return cell;
  } else if ([rowType isEqualToString:@"keep_alive_switch"]) {
    ConfigSwitchCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"SwitchCell"
                                        forIndexPath:indexPath];
    cell.textLabel.text = row[@"label"];
    cell.textLabel.textColor = [UIColor blackColor];
    cell.backgroundColor = [UIColor whiteColor];
    cell.toggle.on = [ECBackgroundManager sharedManager].isMicrophoneActive;
    [cell.toggle removeTarget:nil
                       action:NULL
             forControlEvents:UIControlEventAllEvents];
    [cell.toggle addTarget:self
                    action:@selector(micSwitchToggled:)
          forControlEvents:UIControlEventValueChanged];
    return cell;
  }

  return [[UITableViewCell alloc] init];
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [self.view endEditing:YES]; // Hide keyboard
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
  NSString *rowType = row[@"type"];
  NSString *key = row[@"id"];

  if ([rowType isEqualToString:@"selector"]) {
    if ([key isEqualToString:@"type"]) {
      ProxyTypeSelectionViewController *vc =
          [[ProxyTypeSelectionViewController alloc] init];
      vc.currentType = self.configData[@"type"] ?: @"Shadowsocks";
      vc.delegate = self;
      [self.navigationController pushViewController:vc animated:YES];
    } else if ([key isEqualToString:@"proxy_through_id"]) {
      ECNodeSelectionViewController *vc =
          [[ECNodeSelectionViewController alloc] init];
      vc.currentSelectedID = self.configData[@"proxy_through_id"];
      vc.delegate = self;
      [self.navigationController pushViewController:vc animated:YES];
    }
  } else if ([key isEqualToString:@"action_scan_qr"]) {
    [self openQRScanner];
  } else if ([key isEqualToString:@"action_save"]) {
    [self saveConfig];
  } else if ([row[@"type"] isEqualToString:@"text"]) {
    ConfigInputCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    [cell.textField becomeFirstResponder];
  }
}

#pragma mark - Actions

- (void)textFieldDidChange:(UITextField *)sender {
  NSInteger section = sender.tag / 1000;
  NSInteger row = sender.tag % 1000;
  NSDictionary *rowData = self.sections[section][@"rows"][row];
  NSString *key = rowData[@"id"];

  self.configData[key] = sender.text;
}

- (void)switchValueDidChange:(UISwitch *)sender {
  NSInteger section = sender.tag / 1000;
  NSInteger row = sender.tag % 1000;
  NSDictionary *rowData = self.sections[section][@"rows"][row];
  NSString *key = rowData[@"id"];

  self.configData[key] = @(sender.isOn);

  // If IP config mode changed, rebuild sections to show/hide manual IP fields
  if ([key isEqualToString:@"ip_config_mode"]) {
    [self rebuildSections];
  }
}

- (void)didSelectProxyType:(NSString *)type {
  self.configData[@"type"] = type;
  [self rebuildSections];
}

- (void)didSelectNodeID:(NSString *)nodeID {
  if (nodeID) {
    self.configData[@"proxy_through_id"] = nodeID;
  } else {
    [self.configData removeObjectForKey:@"proxy_through_id"];
  }
  [self rebuildSections];
}

- (void)saveConfig {
  [self appendLog:@"正在保存配置..."];

  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];

  [self appendLog:[NSString stringWithFormat:@"保存数据: %@", self.configData]];

  [defaults setObject:self.configData forKey:@"VPNConfig"];
  BOOL syncResult = [defaults synchronize];
  [self appendLog:@"正在保存代理节点配置..."];

  if (self.nodeID) {
    self.configData[@"id"] = self.nodeID;
    [[ECVPNConfigManager sharedManager] updateNode:self.configData];
  } else {
    // It's a new node
    self.configData[@"id"] = [[NSUUID UUID] UUIDString];
    [[ECVPNConfigManager sharedManager] addNode:self.configData];
  }

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"成功"
                                          message:@"节点配置已保存"
                                   preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"OK"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self.navigationController
                                     popViewControllerAnimated:YES];
                               }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)vpnSwitchToggled:(UISwitch *)sender {
  [[ECBackgroundManager sharedManager] toggleVPN:sender.isOn];
}

- (void)micSwitchToggled:(UISwitch *)sender {
  [[ECBackgroundManager sharedManager] toggleMicrophoneKeepAlive:sender.isOn];
  [[NSUserDefaults standardUserDefaults] setBool:sender.isOn
                                          forKey:@"EC_AUTO_MIC_ALIVE"];
  [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - QR Code Scanner

- (void)openQRScanner {
  ECQRScannerViewController *scanner = [[ECQRScannerViewController alloc] init];
  scanner.delegate = self;
  UINavigationController *nav =
      [[UINavigationController alloc] initWithRootViewController:scanner];
  nav.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)didScanQRCode:(NSString *)code {
  [[ECLogManager sharedManager] log:@"[QR] 扫描到: %@", code];

  NSDictionary *parsed = [ECProxyURIParser parseProxyURI:code];
  if (!parsed) {
    [self showAlert:@"解析失败" message:@"无法识别的代理链接格式"];
    return;
  }

  // Set parsed data to current editing node instead of saving globally
  self.configData = [parsed mutableCopy];
  if (self.nodeID) {
    self.configData[@"id"] = self.nodeID; // keep same ID
  }

  [self rebuildSections];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"添加成功"
                       message:[NSString stringWithFormat:@"已识别到 %@ 节点",
                                                          parsed[@"type"]]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateStatus {
  if (self.vpnSwitch) {
    self.vpnSwitch.on = [ECBackgroundManager sharedManager].isVPNActive;
  }
}

#pragma mark - Log Management

- (NSString *)readLogContent {
  [[ECLogManager sharedManager] syncToDocuments];
  return [[ECLogManager sharedManager] readLog];
}

- (void)appendLog:(NSString *)message {
  [[ECLogManager sharedManager] log:@"%@", message];
}

- (void)showDeviceInfo {
  NSString *helperPath = rootHelperPath();
  NSString *stdOut = nil;
  NSString *stdErr = nil;

  [[ECLogManager sharedManager] log:@"[VPNConfig] Getting Device Info..."];
  int ret = spawnRoot(helperPath, @[ @"get-device-info" ], &stdOut, &stdErr);

  if (ret == 0 && stdOut && stdOut.length > 0) {
    // Format the output for alert
    NSString *msg = [NSString stringWithFormat:@"设备基本信息:\n\n%@", stdOut];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"设备信息"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction
                         actionWithTitle:@"复制"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                   [UIPasteboard generalPasteboard].string =
                                       stdOut;
                                   [self showAlert:@"提示"
                                           message:@"已复制到剪贴板"];
                                 }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  } else {
    [self showAlert:@"错误"
            message:@"无法获取设备信息，请检查 RootHelper 状态。"];
  }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end
