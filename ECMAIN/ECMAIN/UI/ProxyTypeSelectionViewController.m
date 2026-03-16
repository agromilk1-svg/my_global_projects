#import "ProxyTypeSelectionViewController.h"

@interface ProxyTypeSelectionViewController ()
@property(nonatomic, strong) NSArray<NSString *> *proxyTypes;
@property(nonatomic, strong) NSArray<NSString *> *proxySubtitles;
@end

@implementation ProxyTypeSelectionViewController

- (void)viewDidLoad {
  [super viewDidLoad];

  self.title = @"类型"; // Localized: Type
  self.view.backgroundColor = [UIColor whiteColor];

  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"Cell"];

  self.proxyTypes = @[
    @"Shadowsocks", @"ShadowsocksR", @"VMess", @"VLESS", @"Trojan", @"Hysteria",
    @"Hysteria2", @"WireGuard", @"Tuic", @"Socks5", @"HTTP", @"HTTPS", @"Snell",
    @"Local"
  ];
  self.proxySubtitles = @[
    @"经典协议，支持广泛", @"支持混淆插件", @"v2ray 核心协议",
    @"轻量级传输协议", @"高效稳健", @"基于 QUIC 的高速协议", @"Hysteria 改版",
    @"现代 VPN 协议", @"基于 QUIC", @"通用代理协议", @"HTTP 代理",
    @"HTTPS 代理", @"Surge 专属协议", @"本地保活模式 (虚假连接)"
  ];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 1;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.proxyTypes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell =
      [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                             reuseIdentifier:@"Cell"];

  NSString *type = self.proxyTypes[indexPath.row];
  cell.textLabel.text = type;
  cell.detailTextLabel.text = self.proxySubtitles[indexPath.row];
  cell.detailTextLabel.textColor = [UIColor grayColor];

  if ([type isEqualToString:self.currentType]) {
    cell.accessoryType = UITableViewCellAccessoryCheckmark;
  } else {
    cell.accessoryType = UITableViewCellAccessoryNone;
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  NSString *selectedType = self.proxyTypes[indexPath.row];
  self.currentType = selectedType;
  [tableView reloadData]; // Update checkmark

  if (self.delegate &&
      [self.delegate respondsToSelector:@selector(didSelectProxyType:)]) {
    [self.delegate didSelectProxyType:selectedType];
  }

  [self.navigationController popViewControllerAnimated:YES];
}

@end
