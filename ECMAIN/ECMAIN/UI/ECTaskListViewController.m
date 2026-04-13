//
//  ECTaskListViewController.m
//  ECMAIN
//
//  显示从云控中心同步下来的全局执行任务列表，底部附带实时日志窗口。
//  日志由 ECScriptParser 持久化写入 Documents/ec_script_log.txt，
//  本页面仅负责读取显示，不再依赖 ViewController 存活状态。
//

#import "ECTaskListViewController.h"
#import "../Core/ECScriptParser.h"
#import "../Core/ECTaskPollManager.h"

#ifndef ECMAIN_EXTENSION

// 日志文件路径（与 ECScriptParser.m 保持一致）
static NSString *ECScriptLogFilePath(void) {
  static NSString *path = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    path = [docsDir stringByAppendingPathComponent:@"ec_script_log.txt"];
  });
  return path;
}

@interface ECTaskListViewController () <UITableViewDelegate,
                                        UITableViewDataSource>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSArray<NSDictionary *> *tasks;

// 实时日志窗口
@property(nonatomic, strong) UIView *logContainerView;
@property(nonatomic, strong) UILabel *logHeaderLabel;
@property(nonatomic, strong) UITextView *logTextView;
@end

@implementation ECTaskListViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"自动任务";
  self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.10 alpha:1.0];

  // 计算布局尺寸
  CGFloat screenWidth = self.view.bounds.size.width;
  CGFloat screenHeight = self.view.bounds.size.height;
  CGFloat logViewHeight = 220;  // 日志窗口高度
  CGFloat tableHeight = screenHeight - logViewHeight;

  // --- 任务列表 (上半部分) ---
  self.tableView = [[UITableView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, tableHeight)
                                                style:UITableViewStylePlain];
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tableView.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.10 alpha:1.0];
  self.tableView.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];
  [self.tableView registerClass:[UITableViewCell class]
         forCellReuseIdentifier:@"TaskCell"];
  [self.view addSubview:self.tableView];

  // --- 实时日志窗口 (底部) ---
  [self setupLogView];

  // 监听任务更新通知
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(loadTasks)
                                               name:@"ECTasksDidUpdateAlert"
                                             object:nil];

  // 监听脚本实时日志通知（仅更新内存中的界面显示）
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(onScriptLogAppend:)
                                               name:@"ECScriptLogDidAppend"
                                             object:nil];

  // 监听任务执行开始通知（清空界面显示）
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(onTaskBeginExecution:)
                                               name:@"ECTaskDidBeginExecution"
                                             object:nil];
}

#pragma mark - 日志窗口构建

- (void)setupLogView {
  CGFloat screenWidth = self.view.bounds.size.width;
  CGFloat screenHeight = self.view.bounds.size.height;
  CGFloat logViewHeight = 220;

  // 容器视图
  self.logContainerView = [[UIView alloc] initWithFrame:CGRectMake(0, screenHeight - logViewHeight, screenWidth, logViewHeight)];
  self.logContainerView.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.05 alpha:1.0];
  self.logContainerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
  [self.view addSubview:self.logContainerView];

  // 分隔线
  UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, screenWidth, 1)];
  separator.backgroundColor = [UIColor colorWithRed:0.15 green:0.35 blue:0.25 alpha:1.0];
  separator.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.logContainerView addSubview:separator];

  // 标题栏（缩短宽度，为右侧按钮留空间）
  self.logHeaderLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, screenWidth - 160, 24)];
  self.logHeaderLabel.text = @"📋 实时执行日志";
  self.logHeaderLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.5 alpha:1.0];
  self.logHeaderLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
  self.logHeaderLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
  [self.logContainerView addSubview:self.logHeaderLabel];

  // 「读取日志」按钮
  UIButton *loadBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  loadBtn.frame = CGRectMake(screenWidth - 148, 3, 70, 26);
  [loadBtn setTitle:@"读取日志" forState:UIControlStateNormal];
  [loadBtn setTitleColor:[UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0] forState:UIControlStateNormal];
  loadBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
  loadBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.15 blue:0.25 alpha:1.0];
  loadBtn.layer.cornerRadius = 6;
  loadBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  [loadBtn addTarget:self action:@selector(onLoadLogButtonTapped) forControlEvents:UIControlEventTouchUpInside];
  [self.logContainerView addSubview:loadBtn];

  // 「清空日志」按钮
  UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  clearBtn.frame = CGRectMake(screenWidth - 74, 3, 70, 26);
  [clearBtn setTitle:@"清空日志" forState:UIControlStateNormal];
  [clearBtn setTitleColor:[UIColor colorWithRed:1.0 green:0.5 blue:0.5 alpha:1.0] forState:UIControlStateNormal];
  clearBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
  clearBtn.backgroundColor = [UIColor colorWithRed:0.2 green:0.08 blue:0.08 alpha:1.0];
  clearBtn.layer.cornerRadius = 6;
  clearBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
  [clearBtn addTarget:self action:@selector(onClearLogButtonTapped) forControlEvents:UIControlEventTouchUpInside];
  [self.logContainerView addSubview:clearBtn];

  // 日志文本视图
  self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(8, 32, screenWidth - 16, logViewHeight - 36)];
  self.logTextView.backgroundColor = [UIColor clearColor];
  self.logTextView.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
  self.logTextView.font = [UIFont fontWithName:@"Menlo" size:10];
  if (!self.logTextView.font) {
    self.logTextView.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
  }
  self.logTextView.editable = NO;
  self.logTextView.selectable = YES;
  self.logTextView.showsVerticalScrollIndicator = YES;
  self.logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
  self.logTextView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.logTextView.text = @"等待任务执行...\n点击「读取日志」可加载上次执行记录\n";
  [self.logContainerView addSubview:self.logTextView];
}

#pragma mark - 日志文件读取

// 从文件读取全部日志内容
- (NSString *)readLogFile {
  NSString *path = ECScriptLogFilePath();
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    return nil;
  }
  NSError *err = nil;
  NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
  if (err || !content || content.length == 0) {
    return nil;
  }
  return content;
}

// 清空日志文件
- (void)clearLogFile {
  NSString *path = ECScriptLogFilePath();
  [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - 按钮事件

// 读取日志按钮：从磁盘文件加载日志到界面
- (void)onLoadLogButtonTapped {
  NSString *content = [self readLogFile];
  if (!content) {
    self.logTextView.text = @"（暂无日志文件，请等待任务执行后再试）\n";
    return;
  }
  self.logTextView.text = content;
  self.logHeaderLabel.text = @"📋 实时执行日志 · 已加载文件";
  self.logHeaderLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];

  // 自动滚动到底部
  if (content.length > 1) {
    NSRange bottom = NSMakeRange(content.length - 1, 1);
    [self.logTextView scrollRangeToVisible:bottom];
  }
}

// 清空日志按钮：清除磁盘文件 + 界面
- (void)onClearLogButtonTapped {
  [self clearLogFile];
  self.logTextView.text = @"日志已清空。\n";
  self.logHeaderLabel.text = @"📋 实时执行日志";
  self.logHeaderLabel.textColor = [UIColor colorWithRed:0.3 green:0.85 blue:0.5 alpha:1.0];
}

#pragma mark - 脚本日志通知处理

// 新任务开始：清空界面（文件已由 ECScriptParser 在 executeScript: 中清空）
- (void)onTaskBeginExecution:(NSNotification *)notification {
  NSString *taskName = notification.userInfo[@"name"] ?: @"未知任务";
  NSString *taskType = notification.userInfo[@"type"] ?: @"regular";

  NSString *typeTag = [taskType isEqualToString:@"oneshot"] ? @"⚡ 一次性任务" : @"🎬 常规任务";

  // 清空界面显示
  self.logTextView.text = @"";

  // 更新标题栏
  self.logHeaderLabel.text = [NSString stringWithFormat:@"📋 %@ · ⏳ %@", typeTag, taskName];
  self.logHeaderLabel.textColor = [UIColor colorWithRed:1.0 green:0.75 blue:0.2 alpha:1.0];
}

// 实时日志追加：仅更新界面显示（文件写入已由 ECScriptParser 完成）
- (void)onScriptLogAppend:(NSNotification *)notification {
  NSString *message = notification.userInfo[@"message"];
  if (!message || message.length == 0) return;

  // 获取当前时间戳
  NSDateFormatter *df = [[NSDateFormatter alloc] init];
  [df setDateFormat:@"HH:mm:ss"];
  NSString *timeStr = [df stringFromDate:[NSDate date]];

  // 根据内容类型着色标记
  NSString *prefix = @"→";
  if ([message containsString:@"✅"]) {
    prefix = @"✅";
  } else if ([message containsString:@"❌"] || [message containsString:@"Error"] || [message containsString:@"失败"]) {
    prefix = @"❌";
  } else if ([message containsString:@"⚠️"]) {
    prefix = @"⚠️";
  } else if ([message containsString:@"Sleep"]) {
    prefix = @"💤";
  } else if ([message containsString:@"Tap"] || [message containsString:@"tap"]) {
    prefix = @"👆";
  } else if ([message containsString:@"Swipe"] || [message containsString:@"swipe"]) {
    prefix = @"👉";
  } else if ([message containsString:@"Launch"] || [message containsString:@"launch"]) {
    prefix = @"🚀";
  } else if ([message containsString:@"Terminate"] || [message containsString:@"终止"]) {
    prefix = @"⏹";
  }

  // 追加到界面显示
  NSString *logLine = [NSString stringWithFormat:@"[%@] %@ %@\n", timeStr, prefix, message];
  self.logTextView.text = [self.logTextView.text stringByAppendingString:logLine];

  // 自动滚动到底部
  if (self.logTextView.text.length > 1) {
    NSRange bottom = NSMakeRange(self.logTextView.text.length - 1, 1);
    [self.logTextView scrollRangeToVisible:bottom];
  }

  // 检测任务完成标记
  if ([message containsString:@"执行完毕"] || [message containsString:@"执行超时"]) {
    BOOL isSuccess = [message containsString:@"✅"];
    self.logHeaderLabel.text = isSuccess
        ? @"📋 实时执行日志 · ✅ 执行完成"
        : @"📋 实时执行日志 · ❌ 执行异常";
    self.logHeaderLabel.textColor = isSuccess
        ? [UIColor colorWithRed:0.3 green:0.85 blue:0.5 alpha:1.0]
        : [UIColor colorWithRed:0.9 green:0.3 blue:0.3 alpha:1.0];
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self loadTasks];

  // 每次进入页面时自动从文件加载日志（防止切换页面后界面空白）
  NSString *content = [self readLogFile];
  if (content) {
    self.logTextView.text = content;
    // 自动滚动到底部
    dispatch_async(dispatch_get_main_queue(), ^{
      if (self.logTextView.text.length > 1) {
        NSRange bottom = NSMakeRange(self.logTextView.text.length - 1, 1);
        [self.logTextView scrollRangeToVisible:bottom];
      }
    });
  }
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
      NSString *errPreview = errInfo.length > 60
          ? [[errInfo substringToIndex:60] stringByAppendingString:@"..."]
          : errInfo;
      errPreview = [errPreview stringByReplacingOccurrencesOfString:@"\n"
                                                        withString:@" "];
      statusText = [statusText stringByAppendingFormat:@"\n⚠️ %@", errPreview];
    }
  }

  // 深色主题单元格
  cell.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1.0];

  UIListContentConfiguration *config = [cell defaultContentConfiguration];
  config.text =
      [NSString stringWithFormat:@"[%@] %@", taskId, name];
  config.textProperties.color = [UIColor colorWithWhite:0.9 alpha:1.0];
  config.textProperties.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
  config.secondaryText =
      [NSString stringWithFormat:@"%@\n%@", statusText, codePreview];
  config.secondaryTextProperties.numberOfLines = 4;
  config.secondaryTextProperties.color = (hasLog && !lastSuccess)
      ? [UIColor systemRedColor]
      : [UIColor colorWithWhite:0.5 alpha:1.0];
  config.secondaryTextProperties.font = [UIFont fontWithName:@"Menlo" size:10]
      ?: [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
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
  NSString *duration = logRecord[@"duration"] ?: @"";

  NSMutableString *message = [NSMutableString string];
  [message appendFormat:@"执行时间: %@\n", timestamp];
  if (duration.length > 0) {
    [message appendFormat:@"执行耗时: %@\n", duration];
  }
  [message appendFormat:@"执行结果: %@\n\n", success ? @"✅ 成功" : @"❌ 失败"];

  if (!success && errorInfo.length > 0) {
    [message appendFormat:@"🔴 错误信息:\n%@\n\n", errorInfo];
  }

  [message appendFormat:@"📌 最后执行的指令:\n%@\n\n", lastCmd];

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
