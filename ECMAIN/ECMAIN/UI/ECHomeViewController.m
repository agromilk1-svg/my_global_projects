#import "ECHomeViewController.h"
#import "../Core/ECBackgroundManager.h"
#import "../Core/ECConnectionTester.h"
#import "../Core/ECProxyURIParser.h" // Added this import
#import "../Core/ECVPNConfigManager.h"
#import "ECNetworkConfigViewController.h" // Added this import
#import "ECQRScannerViewController.h"
#import "VPNConfigViewController.h"
#import <NetworkExtension/NetworkExtension.h>

@interface ECHomeViewController () <UITableViewDelegate, UITableViewDataSource,
                                    ECQRScannerDelegate>

@property(nonatomic, strong) UISegmentedControl *routingSegment;
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) UISwitch *vpnSwitch;

@property(nonatomic, strong) NSArray<NSDictionary *> *nodes;
@property(nonatomic, strong) NSArray<NSArray<NSDictionary *> *> *groupedNodes;
@property(nonatomic, strong) NSArray<NSString *> *groupNames;
@property(nonatomic, copy) NSString *activeNodeID;

@property(nonatomic, strong) NSMutableSet<NSString *> *collapsedSections;
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, NSNumber *> *pingCache;
@property(nonatomic, strong) UIBarButtonItem *deleteSelectedButton;
@property(nonatomic, strong) UIBarButtonItem *cancelEditButton;

@end

@implementation ECHomeViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"代理";
  self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

  self.collapsedSections = [NSMutableSet set];
  self.pingCache = [NSMutableDictionary dictionary];

  [self setupNavigationBar];
  [self setupHeaderView];
  [self setupTableView];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reloadData];
  [self updateStatus];

  // Status Observer
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(updateStatus)
             name:NEVPNStatusDidChangeNotification
           object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  [[NSNotificationCenter defaultCenter]
      removeObserver:self
                name:NEVPNStatusDidChangeNotification
              object:nil];
}

- (void)setupNavigationBar {
  self.navigationItem.leftBarButtonItem = self.editButtonItem;
  [self setupNavigationBarItems];
}

- (void)setupNavigationBarItems {
  UIBarButtonItem *addButton = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                           target:self
                           action:@selector(addActionTapped)];

  UIBarButtonItem *testButton = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"bolt.horizontal.circle"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(testAllNodesConnection)];

  self.navigationItem.rightBarButtonItems = @[ addButton, testButton ];
}

- (void)setEditing:(BOOL)editing animated:(BOOL)animated {
  [super setEditing:editing animated:animated];
  [self.tableView setEditing:editing animated:animated];
  if (editing) {
    if (!self.deleteSelectedButton) {
      self.deleteSelectedButton = [[UIBarButtonItem alloc]
          initWithTitle:@"删除所选"
                  style:UIBarButtonItemStylePlain
                 target:self
                 action:@selector(deleteSelectedNodes)];
      self.deleteSelectedButton.tintColor = [UIColor systemRedColor];
    }
    if (!self.cancelEditButton) {
      self.cancelEditButton =
          [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                           style:UIBarButtonItemStyleDone
                                          target:self
                                          action:@selector(cancelEditing)];
    }
    self.navigationItem.rightBarButtonItems =
        @[ self.deleteSelectedButton, self.cancelEditButton ];
  } else {
    [self setupNavigationBarItems];
  }
}

- (void)cancelEditing {
  [self setEditing:NO animated:YES];
}

- (void)deleteSelectedNodes {
  NSArray *selectedPaths = self.tableView.indexPathsForSelectedRows;
  if (!selectedPaths || selectedPaths.count == 0) {
    [self setEditing:NO animated:YES];
    return;
  }

  for (NSIndexPath *indexPath in selectedPaths) {
    if (indexPath.section == self.groupNames.count)
      continue; // Skip network config
    NSDictionary *node = self.groupedNodes[indexPath.section][indexPath.row];
    [[ECVPNConfigManager sharedManager] deleteNodeWithID:node[@"id"]];
  }

  [self setEditing:NO animated:YES];
  [self reloadData];
}

- (void)setupHeaderView {
  UIView *headerView = [[UIView alloc] init];
  headerView.tag = 888;
  headerView.backgroundColor = [UIColor clearColor];
  headerView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:headerView];

  [NSLayoutConstraint activateConstraints:@[
    [headerView.topAnchor
        constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [headerView.trailingAnchor
        constraintEqualToAnchor:self.view.trailingAnchor],
    [headerView.heightAnchor constraintEqualToConstant:140]
  ]];

  // Connection Status Switch
  UIView *switchContainer = [[UIView alloc] init];
  switchContainer.backgroundColor = [UIColor whiteColor];
  switchContainer.layer.cornerRadius = 10;
  switchContainer.translatesAutoresizingMaskIntoConstraints = NO;
  [headerView addSubview:switchContainer];

  [NSLayoutConstraint activateConstraints:@[
    [switchContainer.topAnchor constraintEqualToAnchor:headerView.topAnchor
                                              constant:16],
    [switchContainer.leadingAnchor
        constraintEqualToAnchor:headerView.leadingAnchor
                       constant:16],
    [switchContainer.trailingAnchor
        constraintEqualToAnchor:headerView.trailingAnchor
                       constant:-16],
    [switchContainer.heightAnchor constraintEqualToConstant:60]
  ]];

  UIImageView *iconView = [[UIImageView alloc]
      initWithImage:[UIImage systemImageNamed:@"paperplane.fill"]];
  iconView.frame = CGRectMake(16, 15, 30, 30);
  iconView.tintColor = [UIColor systemBlueColor];
  [switchContainer addSubview:iconView];

  UILabel *titleLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(60, 20, 200, 20)];
  titleLabel.text = @"未连接";
  titleLabel.tag = 999;
  titleLabel.font = [UIFont boldSystemFontOfSize:17];
  [switchContainer addSubview:titleLabel];

  self.vpnSwitch = [[UISwitch alloc] init];
  self.vpnSwitch.translatesAutoresizingMaskIntoConstraints = NO;
  [self.vpnSwitch addTarget:self
                     action:@selector(vpnSwitchToggled:)
           forControlEvents:UIControlEventValueChanged];
  [switchContainer addSubview:self.vpnSwitch];

  [NSLayoutConstraint activateConstraints:@[
    [self.vpnSwitch.centerYAnchor
        constraintEqualToAnchor:switchContainer.centerYAnchor],
    [self.vpnSwitch.trailingAnchor
        constraintEqualToAnchor:switchContainer.trailingAnchor
                       constant:-16]
  ]];

  // Routing Segment
  self.routingSegment =
      [[UISegmentedControl alloc] initWithItems:@[ @"配置", @"代理", @"直连" ]];
  self.routingSegment.translatesAutoresizingMaskIntoConstraints = NO;
  self.routingSegment.selectedSegmentIndex =
      [[ECVPNConfigManager sharedManager] routingMode];
  [self.routingSegment addTarget:self
                          action:@selector(routingSegmentChanged:)
                forControlEvents:UIControlEventValueChanged];
  [headerView addSubview:self.routingSegment];

  [NSLayoutConstraint activateConstraints:@[
    [self.routingSegment.topAnchor
        constraintEqualToAnchor:switchContainer.bottomAnchor
                       constant:14],
    [self.routingSegment.leadingAnchor
        constraintEqualToAnchor:headerView.leadingAnchor
                       constant:16],
    [self.routingSegment.trailingAnchor
        constraintEqualToAnchor:headerView.trailingAnchor
                       constant:-16],
    [self.routingSegment.heightAnchor constraintEqualToConstant:32]
  ]];
}

- (void)setupTableView {
  self.tableView =
      [[UITableView alloc] initWithFrame:CGRectZero
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
  self.tableView.allowsMultipleSelectionDuringEditing = YES;
  self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.tableView];

  UIView *headerView = [self.view viewWithTag:888];
  if (headerView) {
    [NSLayoutConstraint activateConstraints:@[
      [self.tableView.topAnchor
          constraintEqualToAnchor:headerView.bottomAnchor],
      [self.tableView.leadingAnchor
          constraintEqualToAnchor:self.view.leadingAnchor],
      [self.tableView.trailingAnchor
          constraintEqualToAnchor:self.view.trailingAnchor],
      [self.tableView.bottomAnchor
          constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
  } else {
    [NSLayoutConstraint activateConstraints:@[
      [self.tableView.topAnchor
          constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
      [self.tableView.leadingAnchor
          constraintEqualToAnchor:self.view.leadingAnchor],
      [self.tableView.trailingAnchor
          constraintEqualToAnchor:self.view.trailingAnchor],
      [self.tableView.bottomAnchor
          constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
  }
}

- (void)reloadData {
  self.nodes = [[ECVPNConfigManager sharedManager] allNodes];
  self.activeNodeID = [[ECVPNConfigManager sharedManager] activeNodeID];

  NSMutableDictionary<NSString *, NSMutableArray *> *groupDict =
      [NSMutableDictionary dictionary];
  for (NSDictionary *node in self.nodes) {
    NSString *group = node[@"group"];
    if (!group || group.length == 0)
      group = @"Default";
    if (!groupDict[group])
      groupDict[group] = [NSMutableArray array];
    [groupDict[group] addObject:node];
  }

  self.groupNames = [[groupDict allKeys]
      sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  NSMutableArray *grouped = [NSMutableArray array];
  for (NSString *gn in self.groupNames) {
    [grouped addObject:groupDict[gn]];
  }
  self.groupedNodes = grouped;

  [self.tableView reloadData];
  [self updateHeaderStatus];
}

- (void)updateHeaderStatus {
  UIView *headerView = [self.view viewWithTag:888];
  if (!headerView)
    return;

  UILabel *titleLabel = [headerView viewWithTag:999];
  if (titleLabel && self.vpnSwitch) {
    if (self.vpnSwitch.isOn) {
      NSString *nodeID = [[ECVPNConfigManager sharedManager] activeNodeID];
      if (nodeID) {
        NSDictionary *nodeDict =
            [[ECVPNConfigManager sharedManager] nodeWithID:nodeID];
        NSString *name = nodeDict[@"name"] ?: nodeDict[@"server"] ?: @"已连接";
        titleLabel.text = name;
        titleLabel.textColor = [UIColor systemGreenColor];
      } else {
        titleLabel.text = @"已打开 (无活动节点)";
        titleLabel.textColor = [UIColor systemOrangeColor];
      }
    } else {
      titleLabel.text = @"未连接";
      titleLabel.textColor = [UIColor blackColor];
    }
  }
}

- (void)updateStatus {
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL isActive = [ECBackgroundManager sharedManager].isVPNActive;
    self.vpnSwitch.on = isActive;

    UILabel *titleLabel = [self.view viewWithTag:999];
    if (titleLabel) {
      if (isActive) {
        NSString *activeID = [[ECVPNConfigManager sharedManager] activeNodeID];
        NSDictionary *activeNode = nil;
        for (NSDictionary *n in [[ECVPNConfigManager sharedManager] allNodes]) {
          if ([n[@"id"] isEqualToString:activeID]) {
            activeNode = n;
            break;
          }
        }
        if (activeNode) {
          titleLabel.text = activeNode[@"name"] ?: activeNode[@"server"] ?: @"已连接";
        } else {
          titleLabel.text = @"已连接";
        }
      } else {
        titleLabel.text = @"未连接";
      }
      [titleLabel sizeToFit];
    }
  });
}

// 长按标题查看 Tunnel 调试日志
- (void)showTunnelDebugLog:(UILongPressGestureRecognizer *)gesture {
  if (gesture.state != UIGestureRecognizerStateBegan)
    return;
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSURL *groupURL = [[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:
          @"group.com.ecmain.shared"];
  NSString *logContent = @"(无日志)";
  if (groupURL) {
    NSURL *logURL = [groupURL URLByAppendingPathComponent:@"tunnel_debug.log"];
    NSString *content = [NSString stringWithContentsOfURL:logURL
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (content.length > 0) {
      // 截取最后 3000 字符避免 Alert 过长
      if (content.length > 3000)
        content = [content substringFromIndex:content.length - 3000];
      logContent = content;
    }
  }
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"Tunnel 调试日志"
                                          message:logContent
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"复制"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 [UIPasteboard generalPasteboard].string =
                                     logContent;
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

// 导航栏按钮触发的调试日志查看
- (void)showTunnelDebugLogTapped {
  NSURL *groupURL = [[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:
          @"group.com.ecmain.shared"];
  NSString *logContent = @"(无日志 - 请先连接一次 VPN 再查看)";
  if (groupURL) {
    NSURL *logURL = [groupURL URLByAppendingPathComponent:@"tunnel_debug.log"];
    NSString *content = [NSString stringWithContentsOfURL:logURL
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil];
    if (content.length > 0) {
      if (content.length > 3000)
        content = [content substringFromIndex:content.length - 3000];
      logContent = content;
    }
  }
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"Tunnel 调试日志"
                                          message:logContent
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"复制全部"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 [UIPasteboard generalPasteboard].string =
                                     logContent;
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Actions

- (void)addActionTapped {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"添加节点"
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"手动添加"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 VPNConfigViewController *vc =
                                     [[VPNConfigViewController alloc] init];
                                 [self.navigationController
                                     pushViewController:vc
                                               animated:YES];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"扫描二维码"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self scanActionTapped];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"从剪贴板导入配资或链接"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 UIPasteboard *pasteboard =
                                     [UIPasteboard generalPasteboard];
                                 if (pasteboard.string) {
                                   [self importFromURI:pasteboard.string];
                                 } else {
                                   [self showAlert:@"剪贴板为空"];
                                 }
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"从输入链接下载订阅"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self showURLInputDialog];
                               }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)testAllNodesConnection {
  if (self.groupNames.count == 0)
    return;

  // 1. 设置所有节点为 "测速中" (-2)
  for (NSInteger section = 0; section < self.groupNames.count; section++) {
    NSArray *nodes = self.groupedNodes[section];
    for (NSDictionary *node in nodes) {
      NSString *nodeID = node[@"id"];
      if (nodeID) {
        self.pingCache[nodeID] = @(-2);
      }
    }
  }

  // 2. 刷新整个表格以显示 "..." 状态
  [self.tableView reloadData];

  // 3. 开始异步测速
  for (NSInteger section = 0; section < self.groupNames.count; section++) {
    NSArray *nodes = self.groupedNodes[section];
    for (NSInteger row = 0; row < nodes.count; row++) {
      NSDictionary *node = nodes[row];
      NSString *host = node[@"server"] ?: @"";
      int port = [node[@"port"] intValue];

      NSIndexPath *indexPath = [NSIndexPath indexPathForRow:row
                                                  inSection:section];

      NSString *nodeID = node[@"id"];
      if (!nodeID)
        continue;

      [ECConnectionTester
            pingHost:host
                port:port
          completion:^(NSInteger timingMs, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              if (error || timingMs < 0) {
                self.pingCache[nodeID] = @(-1); // -1 represents timeout/error
              } else {
                self.pingCache[nodeID] = @(timingMs);
              }
              // Only reload the specific row to update UI, regardless of
              // visibility Data source table view methods will pick up the
              // value from pingCache
              [self.tableView
                  reloadRowsAtIndexPaths:@[ indexPath ]
                        withRowAnimation:UITableViewRowAnimationNone];
            });
          }];
    }
  }
}

- (void)showURLInputDialog {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"输入订阅链接"
                                          message:nil
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert
      addTextFieldWithConfigurationHandler:^(UITextField *_Nonnull textField) {
        textField.placeholder = @"https://...";
        textField.keyboardType = UIKeyboardTypeURL;
      }];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"下载"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 NSString *urlStr =
                                     alert.textFields.firstObject.text;
                                 [self downloadSubscriptionFromURL:urlStr];
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)scanActionTapped {
  ECQRScannerViewController *scanner = [[ECQRScannerViewController alloc] init];
  scanner.delegate = self;
  [self presentViewController:scanner animated:YES completion:nil];
}

- (void)vpnSwitchToggled:(UISwitch *)sender {
  if (sender.isOn) {
    // Need to ensure there is an active node
    if (!self.activeNodeID) {
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"未选择节点"
                           message:@"请先选择一个代理节点"
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];
      [sender setOn:NO animated:YES];
    } else {
      NSDictionary *activeNode =
          [[ECVPNConfigManager sharedManager] activeNode];
      [[ECBackgroundManager sharedManager] connectVPNWithConfig:activeNode];
    }
  } else {
    [[ECBackgroundManager sharedManager] toggleVPN:NO];
  }
  [self updateHeaderStatus];
}

- (void)routingSegmentChanged:(UISegmentedControl *)sender {
  [[ECVPNConfigManager sharedManager]
      setRoutingMode:sender.selectedSegmentIndex];
  // Needs to trigger a config rebuild/reload in background manager
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return self.groupNames.count +
         1; // +1 for the Global Network Settings section
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  if (section == self.groupNames.count) {
    return 1; // Only 1 row for Network settings
  }
  NSString *groupName = self.groupNames[section];
  if ([self.collapsedSections containsObject:groupName]) {
    return 0;
  }
  return self.groupedNodes[section].count;
}

- (UIView *)tableView:(UITableView *)tableView
    viewForHeaderInSection:(NSInteger)section {
  if (section == self.groupNames.count) {
    return nil; // Fallback to titleForHeaderInSection
  }

  NSString *groupName = self.groupNames[section];
  BOOL isCollapsed = [self.collapsedSections containsObject:groupName];

  UIView *header = [[UIView alloc]
      initWithFrame:CGRectMake(0, 0, tableView.bounds.size.width, 40)];
  header.backgroundColor = [UIColor clearColor];

  UILabel *titleLabel = [[UILabel alloc]
      initWithFrame:CGRectMake(16, 10, tableView.bounds.size.width - 60, 20)];
  titleLabel.text = groupName;
  titleLabel.font = [UIFont boldSystemFontOfSize:13];
  titleLabel.textColor = [UIColor darkGrayColor];
  [header addSubview:titleLabel];

  UILabel *arrowLabel = [[UILabel alloc]
      initWithFrame:CGRectMake(header.bounds.size.width - 36, 10, 20, 20)];
  arrowLabel.text = isCollapsed ? @"▼" : @"▲";
  arrowLabel.font = [UIFont systemFontOfSize:12];
  arrowLabel.textColor = [UIColor darkGrayColor];
  arrowLabel.textAlignment = NSTextAlignmentRight;
  arrowLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  [header addSubview:arrowLabel];

  UITapGestureRecognizer *tap =
      [[UITapGestureRecognizer alloc] initWithTarget:self
                                              action:@selector(headerTapped:)];
  header.tag = section;
  [header addGestureRecognizer:tap];

  return header;
}

- (CGFloat)tableView:(UITableView *)tableView
    heightForHeaderInSection:(NSInteger)section {
  if (section == self.groupNames.count)
    return 30; // system settings default height
  return 40;
}

- (void)headerTapped:(UITapGestureRecognizer *)sender {
  NSInteger section = sender.view.tag;
  if (section >= self.groupNames.count)
    return;

  NSString *groupName = self.groupNames[section];
  if ([self.collapsedSections containsObject:groupName]) {
    [self.collapsedSections removeObject:groupName];
  } else {
    [self.collapsedSections addObject:groupName];
  }
  [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:section]
                withRowAnimation:UITableViewRowAnimationFade];
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
  if (section == self.groupNames.count) {
    return @"系统全局设置";
  }
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == self.groupNames.count) {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"ActionCell"];
    if (!cell) {
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                    reuseIdentifier:@"ActionCell"];
    }
    cell.backgroundColor = [UIColor whiteColor];
    cell.textLabel.text = @"🌐 Wi-Fi 与静态 IP 设置";
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.textLabel.textAlignment = NSTextAlignmentCenter;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }

  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:@"NodeCell"];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:@"NodeCell"];
  }
  cell.backgroundColor = [UIColor whiteColor];

  NSDictionary *node = self.groupedNodes[indexPath.section][indexPath.row];
  NSString *name = node[@"name"] ?: node[@"server"];
  if (!name)
    name = @"[未知节点]";

  NSString *flag = @"";
  if ([name containsString:@"香港"] || [name containsString:@"HK"])
    flag = @"🇭🇰 ";
  else if ([name containsString:@"台湾"] || [name containsString:@"TW"])
    flag = @"🇹🇼 ";
  else if ([name containsString:@"日本"] || [name containsString:@"JP"])
    flag = @"🇯🇵 ";
  else if ([name containsString:@"韩国"] || [name containsString:@"KR"])
    flag = @"🇰🇷 ";
  else if ([name containsString:@"美国"] || [name containsString:@"US"])
    flag = @"🇺🇸 ";
  else if ([name containsString:@"新加坡"] || [name containsString:@"SG"])
    flag = @"🇸🇬 ";
  else if ([name containsString:@"英国"] || [name containsString:@"UK"])
    flag = @"🇬🇧 ";
  else if ([name containsString:@"巴西"] || [name containsString:@"BR"])
    flag = @"🇧🇷 ";
  else if ([name containsString:@"德国"] || [name containsString:@"DE"])
    flag = @"🇩🇪 ";
  else if ([name containsString:@"法国"] || [name containsString:@"FR"])
    flag = @"🇫🇷 ";

  NSString *trimmedFlag = [flag
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (trimmedFlag.length > 0 && [name containsString:trimmedFlag]) {
    flag = @"";
  }

  cell.textLabel.text = [NSString stringWithFormat:@"%@%@", flag, name];
  cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];

  // Subtitle format: TYPE / PROTOCOL INFO
  NSString *type = node[@"type"] ?: @"Unknown";
  NSString *subtitle = @"";
  if ([type isEqualToString:@"Shadowsocks"])
    subtitle = [NSString
        stringWithFormat:@"%@ / %@", type, node[@"cipher"] ?: @"auto"];
  else
    subtitle = [NSString stringWithFormat:@"%@ / Default", type];

  cell.detailTextLabel.text = subtitle;
  cell.detailTextLabel.textColor = [UIColor grayColor];

  // Custom Accessory View (Speed Test Label + Info Button)
  UIView *accView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 90, 44)];
  accView.backgroundColor = [UIColor clearColor];

  UILabel *pingLabel =
      [[UILabel alloc] initWithFrame:CGRectMake(0, 12, 50, 20)];
  pingLabel.tag = 888; // Tag to update later
  pingLabel.textAlignment = NSTextAlignmentRight;
  pingLabel.userInteractionEnabled = YES;
  pingLabel.font = [UIFont systemFontOfSize:13];

  // Apply Cache State
  NSNumber *cachedPing = self.pingCache[node[@"id"]];
  if (!cachedPing) {
    pingLabel.text = @"- ms";
    pingLabel.textColor = [UIColor lightGrayColor];
  } else if ([cachedPing intValue] == -2) {
    pingLabel.text = @"...";
    pingLabel.textColor = [UIColor lightGrayColor];
  } else if ([cachedPing intValue] == -1) {
    pingLabel.text = @"超时";
    pingLabel.textColor = [UIColor systemRedColor];
  } else {
    pingLabel.text =
        [NSString stringWithFormat:@"%ldms", (long)[cachedPing integerValue]];
    if ([cachedPing integerValue] < 100)
      pingLabel.textColor = [UIColor systemGreenColor];
    else if ([cachedPing integerValue] < 300)
      pingLabel.textColor = [UIColor systemOrangeColor];
    else
      pingLabel.textColor = [UIColor systemRedColor];
  }

  [accView addSubview:pingLabel];

  // Invisible button overlaying pingLabel for speed test
  UIButton *pingBtn = [UIButton buttonWithType:UIButtonTypeCustom];
  pingBtn.frame = pingLabel.frame;
  pingBtn.tag = indexPath.row;
  pingBtn.accessibilityValue =
      [NSString stringWithFormat:@"%ld", (long)indexPath.section];
  [pingBtn addTarget:self
                action:@selector(pingButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];
  [accView addSubview:pingBtn];

  UIButton *infoBtn = [UIButton buttonWithType:UIButtonTypeInfoLight];
  infoBtn.frame = CGRectMake(55, 6, 30, 32);
  // Replicate accessoryButtonTappedForRowWithIndexPath logic
  infoBtn.tag = indexPath.row;
  infoBtn.accessibilityValue =
      [NSString stringWithFormat:@"%ld", (long)indexPath.section];
  [infoBtn addTarget:self
                action:@selector(infoButtonTapped:)
      forControlEvents:UIControlEventTouchUpInside];
  [accView addSubview:infoBtn];

  cell.accessoryView = accView;

  // Highlight active node background slightly
  if ([node[@"id"] isEqualToString:self.activeNodeID]) {
    cell.backgroundColor = [UIColor colorWithRed:0.9
                                           green:0.95
                                            blue:1.0
                                           alpha:1.0];
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  if (tableView.isEditing) {
    // 处于多选编辑模式时，系统原生框架负责打钩和收集
    // `indexPathsForSelectedRows`，我们直接返回
    return;
  }

  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  if (indexPath.section == self.groupNames.count) {
    // Jump to Global Network Settings
    ECNetworkConfigViewController *vc =
        [[ECNetworkConfigViewController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
    return;
  }

  NSDictionary *node = self.groupedNodes[indexPath.section][indexPath.row];
  NSString *nodeName = node[@"name"] ?: node[@"server"] ?: @"节点";

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:nodeName
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  if ([alert respondsToSelector:@selector(popoverPresentationController)]) {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    alert.popoverPresentationController.sourceView = cell;
    alert.popoverPresentationController.sourceRect = cell.bounds;
  }

  // 连接此节点
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"连接此节点"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [[ECVPNConfigManager sharedManager]
                                     setActiveNodeID:node[@"id"]];
                                 [self reloadData];
                                 // 自动打开顶部开关
                                 [self.vpnSwitch setOn:YES animated:YES];
                                 [[ECBackgroundManager sharedManager]
                                     connectVPNWithConfig:node];
                                 [self updateHeaderStatus];
                               }]];

  // 导出节点配置到剪贴板
  [alert
      addAction:[UIAlertAction
                    actionWithTitle:@"导出节点配置"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *_Nonnull action) {
                              NSString *uri =
                                  [ECProxyURIParser exportNodeToURI:node];
                              if (uri) {
                                [UIPasteboard generalPasteboard].string = uri;
                                [self showAlert:[NSString
                                                    stringWithFormat:
                                                        @"已复制到剪贴板\n%@",
                                                        uri]];
                              } else {
                                [self showAlert:@"导出失败：不支持的协议类型"];
                              }
                            }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)infoButtonTapped:(UIButton *)sender {
  NSInteger row = sender.tag;
  NSInteger section = [sender.accessibilityValue integerValue];
  if (section == self.groupNames.count)
    return;

  NSDictionary *node = self.groupedNodes[section][row];
  VPNConfigViewController *vc = [[VPNConfigViewController alloc] init];
  vc.nodeID = node[@"id"];
  [self.navigationController pushViewController:vc animated:YES];
}

- (void)pingButtonTapped:(UIButton *)sender {
  NSInteger row = sender.tag;
  NSInteger section = [sender.accessibilityValue integerValue];
  if (section == self.groupNames.count)
    return;

  NSDictionary *node = self.groupedNodes[section][row];
  NSString *host = node[@"server"] ?: @"";
  int port = [node[@"port"] intValue];
  NSString *nodeID = node[@"id"];

  // Find the ping label in the same accessory view
  UILabel *pingLabel = (UILabel *)[sender.superview viewWithTag:888];
  if (pingLabel) {
    pingLabel.text = @"...";
    pingLabel.textColor = [UIColor lightGrayColor];
  }

  self.pingCache[nodeID] = @(-1);

  [ECConnectionTester pingHost:host
                          port:port
                    completion:^(NSInteger timingMs, NSError *error) {
                      dispatch_async(dispatch_get_main_queue(), ^{
                        if (error || timingMs < 0) {
                          self.pingCache[nodeID] = @(-2);
                          if (pingLabel) {
                            pingLabel.text = @"超时";
                            pingLabel.textColor = [UIColor systemRedColor];
                          }
                        } else {
                          self.pingCache[nodeID] = @(timingMs);
                          if (pingLabel) {
                            pingLabel.text = [NSString
                                stringWithFormat:@"%ldms", (long)timingMs];
                            if (timingMs < 100)
                              pingLabel.textColor = [UIColor systemGreenColor];
                            else if (timingMs < 300)
                              pingLabel.textColor = [UIColor systemOrangeColor];
                            else
                              pingLabel.textColor = [UIColor systemRedColor];
                          }
                        }
                      });
                    }];
}

- (void)tableView:(UITableView *)tableView
    accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == self.groupNames.count)
    return;
  // Open editor
  NSDictionary *node = self.groupedNodes[indexPath.section][indexPath.row];
  VPNConfigViewController *vc = [[VPNConfigViewController alloc] init];
  vc.nodeID = node[@"id"];
  [self.navigationController pushViewController:vc animated:YES];
}

// Editable Rules
- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section == self.groupNames.count) {
    return NO;
  }
  return YES;
}

// Swipe Actions
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:
        (NSIndexPath *)indexPath {
  if (indexPath.section == self.groupNames.count)
    return nil;

  NSDictionary *node = self.groupedNodes[indexPath.section][indexPath.row];

  UIContextualAction *deleteAction = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleDestructive
                          title:@"删除"
                        handler:^(UIContextualAction *action,
                                  UIView *sourceView,
                                  void (^completionHandler)(BOOL)) {
                          [[ECVPNConfigManager sharedManager]
                              deleteNodeWithID:node[@"id"]];
                          [self reloadData];
                          completionHandler(YES);
                        }];

  UIContextualAction *exportAction = [UIContextualAction
      contextualActionWithStyle:UIContextualActionStyleNormal
                          title:@"导出"
                        handler:^(UIContextualAction *action,
                                  UIView *sourceView,
                                  void (^completionHandler)(BOOL)) {
                          NSString *uri =
                              [ECProxyURIParser exportNodeToURI:node];
                          if (uri) {
                            [UIPasteboard generalPasteboard].string = uri;
                            [self showAlert:[NSString stringWithFormat:
                                                          @"已复制到剪贴板\n%@",
                                                          uri]];
                          } else {
                            [self showAlert:@"导出失败：不支持的协议类型"];
                          }
                          completionHandler(YES);
                        }];
  exportAction.backgroundColor = [UIColor systemBlueColor];

  UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration
      configurationWithActions:@[ deleteAction, exportAction ]];
  config.performsFirstActionWithFullSwipe = NO;
  return config;
}

// 兼容老版本的 commitEditingStyle，以防在特殊情况下直接调用
- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle == UITableViewCellEditingStyleDelete) {
    if (indexPath.section == self.groupNames.count)
      return;
    NSDictionary *node = self.groupedNodes[indexPath.section][indexPath.row];
    [[ECVPNConfigManager sharedManager] deleteNodeWithID:node[@"id"]];
    [self reloadData];
  }
}

#pragma mark - Import Helpers

- (void)importFromURI:(NSString *)uri {
  if ([uri hasPrefix:@"http://"] || [uri hasPrefix:@"https://"]) {
    [self downloadSubscriptionFromURL:uri];
  } else {
    // Try to parse single URI
    NSDictionary *parsed = [ECProxyURIParser parseProxyURI:uri];
    if (parsed) {
      NSMutableDictionary *node = [parsed mutableCopy];
      node[@"id"] = [[NSUUID UUID] UUIDString];
      [[ECVPNConfigManager sharedManager] addNode:node];
      [self reloadData];
      [self showAlert:@"节点已添加"];
    } else {
      // Try parse multi-line block
      NSArray *parsedArray =
          [ECProxyURIParser parseSubscriptionContent:uri
                                           withGroup:@"Clipboard"];
      if (parsedArray && parsedArray.count > 0) {
        for (NSDictionary *n in parsedArray) {
          NSMutableDictionary *node = [n mutableCopy];
          node[@"id"] = [[NSUUID UUID] UUIDString];
          [[ECVPNConfigManager sharedManager] addNode:node];
        }
        [self reloadData];
        [self showAlert:[NSString stringWithFormat:@"已添加 %ld 个节点",
                                                   (long)parsedArray.count]];
      } else {
        [self showAlert:@"无法识别的内容"];
      }
    }
  }
}

- (void)downloadSubscriptionFromURL:(NSString *)urlStr {
  NSURL *url = [NSURL URLWithString:urlStr];
  if (!url) {
    [self showAlert:@"无效的链接"];
    return;
  }

  // UI indicator
  UIAlertController *loading =
      [UIAlertController alertControllerWithTitle:@"下载中...\n\n"
                                          message:nil
                                   preferredStyle:UIAlertControllerStyleAlert];

  UIProgressView *progressView = [[UIProgressView alloc]
      initWithProgressViewStyle:UIProgressViewStyleDefault];
  progressView.frame = CGRectMake(20, 60, 230, 2);
  progressView.progress = 0.0;
  [loading.view addSubview:progressView];

  [self presentViewController:loading animated:YES completion:nil];

  __block float fakeProgress = 0.0;
  NSTimer *timer = [NSTimer
      scheduledTimerWithTimeInterval:0.1
                             repeats:YES
                               block:^(NSTimer *_Nonnull timer) {
                                 if (fakeProgress < 0.9) {
                                   fakeProgress += 0.05;
                                   [progressView setProgress:fakeProgress
                                                    animated:YES];
                                 }
                               }];

  NSURLSession *session = [NSURLSession sharedSession];
  NSURLSessionDataTask *task = [session
        dataTaskWithURL:url
      completionHandler:^(NSData *_Nullable data,
                          NSURLResponse *_Nullable response,
                          NSError *_Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [timer invalidate];
          [progressView setProgress:1.0 animated:YES];

          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                [loading dismissViewControllerAnimated:YES completion:nil];
                if (error || !data) {
                  [self showAlert:@"下载失败"];
                  return;
                }

                NSString *content =
                    [[NSString alloc] initWithData:data
                                          encoding:NSUTF8StringEncoding];
                if (!content) {
                  [self showAlert:@"编码错误或无效格式"];
                  return;
                }

                NSString *group = url.host ?: @"Subscription";
                NSArray *parsedArray =
                    [ECProxyURIParser parseSubscriptionContent:content
                                                     withGroup:group];
                if (parsedArray && parsedArray.count > 0) {
                  for (NSDictionary *n in parsedArray) {
                    NSMutableDictionary *node = [n mutableCopy];
                    node[@"id"] = [[NSUUID UUID] UUIDString];
                    [[ECVPNConfigManager sharedManager] addNode:node];
                  }
                  [self reloadData];
                  [self showAlert:[NSString stringWithFormat:
                                                @"成功下载并添加 %ld 个节点",
                                                (long)parsedArray.count]];
                } else {
                  [self showAlert:@"未找到任何节点或解析失败"];
                }
              });
        });
      }];
  [task resume];
}

- (void)didScanQRCode:(NSString *)result {
  [self importFromURI:result];
}

- (void)showAlert:(NSString *)msg {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:msg
                                          message:nil
                                   preferredStyle:UIAlertControllerStyleAlert];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
      });
  [self presentViewController:alert animated:YES completion:nil];
}

@end
