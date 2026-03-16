#import "ECNodeSelectionViewController.h"
#import "../Core/ECVPNConfigManager.h"

@interface ECNodeSelectionViewController () <UITableViewDelegate,
                                             UITableViewDataSource>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSArray<NSDictionary *> *nodes;
@end

@implementation ECNodeSelectionViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"选择代理通过节点";
  self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

  // 我们过滤掉当前可能正在编辑的节点以防止环路，但这需要传入编辑的nodeID。暂取所有节点。
  self.nodes = [[ECVPNConfigManager sharedManager] allNodes];

  self.tableView =
      [[UITableView alloc] initWithFrame:self.view.bounds
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"Cell"];
  [self.view addSubview:self.tableView];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return 2; // Section 0: 直连（无代理通过）, Section 1: 节点
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  if (section == 0)
    return 1;
  return self.nodes.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:@"Cell"
                                      forIndexPath:indexPath];
  cell.backgroundColor = [UIColor whiteColor];

  if (indexPath.section == 0) {
    cell.textLabel.text = @"无 (直连)";
    cell.accessoryType = (self.currentSelectedID.length == 0)
                             ? UITableViewCellAccessoryCheckmark
                             : UITableViewCellAccessoryNone;
  } else {
    NSDictionary *node = self.nodes[indexPath.row];
    NSString *name = node[@"name"] ?: node[@"server"] ?: @"未知节点";
    cell.textLabel.text =
        [NSString stringWithFormat:@"%@ - %@", node[@"type"], name];

    if ([node[@"id"] isEqualToString:self.currentSelectedID]) {
      cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
      cell.accessoryType = UITableViewCellAccessoryNone;
    }
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  NSString *selectedID = nil;
  if (indexPath.section == 1) {
    selectedID = self.nodes[indexPath.row][@"id"];
  }

  if (self.delegate &&
      [self.delegate respondsToSelector:@selector(didSelectNodeID:)]) {
    [self.delegate didSelectNodeID:selectedID];
  }
  [self.navigationController popViewControllerAnimated:YES];
}

@end
