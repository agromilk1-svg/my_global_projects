#import "ViewController.h"
#import "DeviceInfoLogic.h"

@interface ViewController ()
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSArray *data; // 未使用，直接从 Logic 获取
@end

@implementation ViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"详细设备信息";
  self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

  [self setupTableView];
  [self setupRefreshButton];
}

- (void)setupTableView {
  self.tableView =
      [[UITableView alloc] initWithFrame:self.view.bounds
                                   style:UITableViewStyleInsetGrouped];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:self.tableView];
}

- (void)setupRefreshButton {
  UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                           target:self.tableView
                           action:@selector(reloadData)];
  self.navigationItem.rightBarButtonItem = refreshItem;

  if (!self.navigationController) {
    UINavigationBar *navBar = [[UINavigationBar alloc]
        initWithFrame:CGRectMake(0,
                                 [UIApplication sharedApplication]
                                     .statusBarFrame.size.height,
                                 self.view.frame.size.width, 44)];
    UINavigationItem *navItem =
        [[UINavigationItem alloc] initWithTitle:@"设备信息"];
    navItem.rightBarButtonItem = refreshItem;
    [navBar pushNavigationItem:navItem animated:NO];
    [self.view addSubview:navBar];
    self.tableView.contentInset = UIEdgeInsetsMake(
        44 + [UIApplication sharedApplication].statusBarFrame.size.height, 0, 0,
        0);
  }
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return DeviceInfoSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return [DeviceInfoLogic itemsForSection:section].count;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
  return [DeviceInfoLogic titleForSection:section];
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  static NSString *cellID = @"Cell";
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellID];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1
                                  reuseIdentifier:cellID];
  }

  NSArray *items = [DeviceInfoLogic itemsForSection:indexPath.section];
  DeviceInfoItem *item = items[indexPath.row];

  cell.textLabel.text = item.displayName;
  cell.detailTextLabel.text = item.value;

  // Safety checks highlighting
  if (indexPath.section == DeviceInfoSectionSecurity) {
    if ([item.displayName containsString:@"越狱"] &&
        [item.value containsString:@"已越狱"]) {
      cell.detailTextLabel.textColor = [UIColor systemRedColor];
    } else if ([item.displayName containsString:@"TrollStore"] &&
               [item.value containsString:@"检测到"]) {
      cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
    } else if ([item.displayName containsString:@"脱壳"] &&
               [item.value containsString:@"已脱壳"]) {
      cell.detailTextLabel.textColor = [UIColor systemRedColor];
    } else {
      cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    }
  } else if (indexPath.section == DeviceInfoSectionInjection) {
    if ([item.displayName containsString:@"发现"] ||
        [item.displayName containsString:@"DYLD"] ||
        ([item.displayName containsString:@"调试"] &&
         [item.value containsString:@"正在"])) {
      cell.detailTextLabel.textColor = [UIColor systemRedColor];
    } else {
      cell.detailTextLabel.textColor = [UIColor systemGreenColor];
    }
  } else {
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  NSArray *items = [DeviceInfoLogic itemsForSection:indexPath.section];
  DeviceInfoItem *item = items[indexPath.row];

  UIPasteboard.generalPasteboard.string = item.value;

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"已复制"
                       message:[NSString stringWithFormat:@"%@: %@",
                                                          item.displayName,
                                                          item.value]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end
