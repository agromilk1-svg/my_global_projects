//
//  ECTaskListViewController.m
//  ECMAIN
//
//  显示从云控中心同步下来的全局执行任务列表。
//

#import "ECTaskListViewController.h"
#import "../Core/ECScriptParser.h"
#import "../Core/ECTaskPollManager.h"

#ifndef ECMAIN_EXTENSION

@interface ECTaskListViewController () <UITableViewDelegate,
                                        UITableViewDataSource>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSArray<NSDictionary *> *tasks;
@end

@implementation ECTaskListViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"自动任务";
  self.view.backgroundColor = [UIColor whiteColor];

  self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                style:UITableViewStylePlain];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"TaskCell"];
  [self.view addSubview:self.tableView];

  // 监听任务有更新的数据广播
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(loadTasks)
                                               name:@"ECTasksDidUpdateAlert"
                                             object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self loadTasks];
}

- (void)loadTasks {
  self.tasks = [[ECTaskPollManager sharedManager] getAllLocalTasks];
  [self.tableView reloadData];
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  return self.tasks.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:@"TaskCell"
                                      forIndexPath:indexPath];
  NSDictionary *task = self.tasks[indexPath.row];

  NSString *name = task[@"name"] ?: @"无名任务";
  NSNumber *taskId = task[@"id"];

  // 粗略截取前 80 个字符展示代码
  NSString *codePreview = task[@"code"] ?: @"";
  if (codePreview.length > 80) {
    codePreview =
        [[codePreview substringToIndex:80] stringByAppendingString:@"..."];
  }

  codePreview = [codePreview stringByReplacingOccurrencesOfString:@"\n"
                                                       withString:@" "];

  // 判断该任务今天是否已执行过
  BOOL executed =
      [[ECTaskPollManager sharedManager] isTaskExecutedToday:taskId];

  // 获取执行完成时间
  NSString *completionTime =
      [[ECTaskPollManager sharedManager] taskCompletionTime:taskId];

  NSString *statusText;
  if (executed && completionTime) {
    statusText = [NSString
        stringWithFormat:@"✅ 完成于 %@", completionTime];
  } else if (executed) {
    statusText = @"✅ 已完成";
  } else {
    statusText = @"⏳ 等待执行";
  }

  // iOS 14+ 支持直接设置 defaultContentConfiguration
  UIListContentConfiguration *config = [cell defaultContentConfiguration];
  config.text =
      [NSString stringWithFormat:@"[%@] %@", taskId, name];
  config.secondaryText =
      [NSString stringWithFormat:@"%@\n%@", statusText, codePreview];
  config.secondaryTextProperties.numberOfLines = 3;
  config.secondaryTextProperties.color = [UIColor darkGrayColor];
  cell.contentConfiguration = config;

  return cell;
}

- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  return YES;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle == UITableViewCellEditingStyleDelete) {
    NSDictionary *task = self.tasks[indexPath.row];
    NSNumber *taskId = task[@"id"];
    if (taskId) {
      [[ECTaskPollManager sharedManager] deleteTaskWithId:taskId];
    }
  }
}

- (NSString *)tableView:(UITableView *)tableView
    titleForDeleteConfirmationButtonForRowAtIndexPath:(NSIndexPath *)indexPath {
  return @"删除";
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  NSDictionary *task = self.tasks[indexPath.row];
  NSString *name = task[@"name"] ?: @"无名任务";
  NSString *code = task[@"code"];

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:name
                                          message:@"需要手动再次执行该任务吗？"
                                   preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert
      addAction:[UIAlertAction
                    actionWithTitle:@"立即执行"
                              style:UIAlertActionStyleDestructive
                            handler:^(UIAlertAction *_Nonnull action) {
                              // 先挂起自动轮询
                              [[ECTaskPollManager sharedManager]
                                  suspendPolling];
                              [[ECScriptParser sharedParser]
                                  executeScript:code
                                     completion:^(BOOL success,
                                                  NSArray *_Nonnull results) {
                                       dispatch_async(
                                           dispatch_get_main_queue(), ^{
                                             [[ECTaskPollManager sharedManager]
                                                 resumePolling];
                                           });
                                     }];
                            }]];

  [self presentViewController:alert animated:YES completion:nil];
}

@end

#endif // !ECMAIN_EXTENSION
