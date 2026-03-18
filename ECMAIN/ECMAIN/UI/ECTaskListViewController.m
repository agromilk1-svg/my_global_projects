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

  // 获取执行日志记录（用于判断成功/失败）
  NSDictionary *logRecord =
      [[ECTaskPollManager sharedManager] getTaskExecutionLog:taskId];
  BOOL hasLog = (logRecord != nil);
  BOOL lastSuccess = [logRecord[@"success"] boolValue];

  NSString *statusText;
  if (executed && completionTime && hasLog) {
    statusText = [NSString
        stringWithFormat:@"%@ 完成于 %@",
        lastSuccess ? @"✅" : @"❌", completionTime];
  } else if (executed) {
    statusText = @"✅ 已完成";
  } else {
    statusText = @"⏳ 等待执行";
  }

  // 如果上次执行失败，追加错误摘要
  if (hasLog && !lastSuccess) {
    NSString *errInfo = logRecord[@"error"] ?: @"";
    if (errInfo.length > 0) {
      // 截取前 60 个字符的错误摘要
      NSString *errPreview = errInfo.length > 60
          ? [[errInfo substringToIndex:60] stringByAppendingString:@"..."]
          : errInfo;
      errPreview = [errPreview stringByReplacingOccurrencesOfString:@"\n"
                                                        withString:@" "];
      statusText = [statusText stringByAppendingFormat:@"\n⚠️ %@", errPreview];
    }
  }

  // iOS 14+ 支持直接设置 defaultContentConfiguration
  UIListContentConfiguration *config = [cell defaultContentConfiguration];
  config.text =
      [NSString stringWithFormat:@"[%@] %@", taskId, name];
  config.secondaryText =
      [NSString stringWithFormat:@"%@\n%@", statusText, codePreview];
  config.secondaryTextProperties.numberOfLines = 4;
  config.secondaryTextProperties.color = (hasLog && !lastSuccess)
      ? [UIColor systemRedColor]
      : [UIColor darkGrayColor];
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
  NSNumber *taskId = task[@"id"];

  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:name
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  // === 查看执行日志按钮 ===
  [sheet addAction:[UIAlertAction
      actionWithTitle:@"📋 查看执行日志"
                style:UIAlertActionStyleDefault
              handler:^(UIAlertAction *_Nonnull action) {
                [self showLogForTaskId:taskId taskName:name];
              }]];

  // === 立即执行按钮 ===
  [sheet addAction:[UIAlertAction
      actionWithTitle:@"▶️ 立即执行"
                style:UIAlertActionStyleDestructive
              handler:^(UIAlertAction *_Nonnull action) {
                [[ECTaskPollManager sharedManager] suspendPolling];
                [[ECScriptParser sharedParser]
                    executeScript:code
                       completion:^(BOOL success,
                                    NSArray *_Nonnull results) {
                         dispatch_async(dispatch_get_main_queue(), ^{
                           [[ECTaskPollManager sharedManager] resumePolling];
                         });
                       }];
              }]];

  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 日志查看

- (void)showLogForTaskId:(NSNumber *)taskId taskName:(NSString *)name {
  NSDictionary *logRecord =
      [[ECTaskPollManager sharedManager] getTaskExecutionLog:taskId];

  if (!logRecord) {
    UIAlertController *noLog = [UIAlertController
        alertControllerWithTitle:@"暂无日志"
                         message:[NSString stringWithFormat:
                             @"任务 [%@] 尚未执行过，暂无日志记录。", name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [noLog addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:noLog animated:YES completion:nil];
    return;
  }

  BOOL success = [logRecord[@"success"] boolValue];
  NSString *errorInfo = logRecord[@"error"] ?: @"";
  NSString *lastCmd = logRecord[@"last_command"] ?: @"（无）";
  NSString *timestamp = logRecord[@"timestamp"] ?: @"未知";
  NSArray *logs = logRecord[@"logs"] ?: @[];

  // 构建日志消息
  NSMutableString *message = [NSMutableString string];
  [message appendFormat:@"执行时间: %@\n", timestamp];
  [message appendFormat:@"执行结果: %@\n\n", success ? @"✅ 成功" : @"❌ 失败"];

  if (!success && errorInfo.length > 0) {
    [message appendFormat:@"🔴 错误信息:\n%@\n\n", errorInfo];
  }

  [message appendFormat:@"📌 最后执行的指令:\n%@\n\n", lastCmd];

  // 完整展示所有日志
  [message appendFormat:@"📝 完整日志 (共 %lu 条):\n",
      (unsigned long)logs.count];
  for (NSInteger i = 0; i < (NSInteger)logs.count; i++) {
    NSString *logLine = logs[i];
    [message appendFormat:@"%ld. %@\n", (long)(i + 1), logLine];
  }

  UIAlertController *logAlert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"%@ 执行日志\n%@",
          success ? @"✅" : @"❌", name]
                       message:message
                preferredStyle:UIAlertControllerStyleAlert];

  [logAlert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];

  [self presentViewController:logAlert animated:YES completion:nil];
}

@end

#endif // !ECMAIN_EXTENSION
