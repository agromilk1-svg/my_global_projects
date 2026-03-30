
#import "ECFileBrowserViewController.h"
#import "ECFileViewerViewController.h"

// TikTok 检测的关键路径列表
static NSArray *_jailbreakPaths = nil;

static NSArray *jailbreakDetectionPaths(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _jailbreakPaths = @[
      @"/usr/bin/ldid",          // TrollStore 签名工具
      @"/usr/bin/sshd",          // SSH 服务
      @"/usr/bin/ssh",           // SSH 客户端
      @"/bin/bash",              // Bash
      @"/bin/sh",                // Shell
      @"/bin/zsh",               // Zsh
      @"/private/etc/apt",       // APT 包管理
      @"/private/etc/ssh",       // SSH 配置目录
      @"/Library/LaunchDaemons", // 守护进程
      @"/private/preboot",       // TrollStore/KFD 数据
      @"/Applications/Cydia.app",
      @"/Applications/Sileo.app",
      @"/var/jb",      // rootless 越狱
      @"/var/binpack", // Fugu15 越狱
      @"/usr/lib/TweakInject",
      @"/Library/MobileSubstrate",
    ];
  });
  return _jailbreakPaths;
}

@interface ECFileBrowserViewController ()
@property(nonatomic, strong) NSString *currentPath;
@property(nonatomic, strong) NSArray *files;
@property(nonatomic, assign) BOOL isRoot; // 是否是根浏览器（显示快捷导航）
@end

@implementation ECFileBrowserViewController

- (instancetype)initWithPath:(NSString *)path {
  if (self = [super initWithStyle:UITableViewStylePlain]) {
    _currentPath = path;
    _isRoot = [path isEqualToString:@"/"];
    self.title = _isRoot ? @"文件浏览器" : [path lastPathComponent];
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.tableView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:1.0];
  self.tableView.separatorColor = [UIColor colorWithWhite:0.2 alpha:1.0];

  // 添加扫描按钮（只在根目录显示）
  if (self.isRoot) {
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"🔍 检测扫描"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(scanDetectionPaths)];
  }

  // 添加路径输入按钮
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"跳转"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(jumpToPath)];

  [self loadFiles];
}

#pragma mark - 一键扫描检测路径

- (void)scanDetectionPaths {
  NSMutableString *report = [NSMutableString string];
  NSFileManager *fm = [NSFileManager defaultManager];
  int foundCount = 0;

  for (NSString *path in jailbreakDetectionPaths()) {
    BOOL exists = [fm fileExistsAtPath:path];
    if (exists) {
      foundCount++;
      BOOL isDir = NO;
      [fm fileExistsAtPath:path isDirectory:&isDir];
      [report
          appendFormat:@"🔴 存在: %@ (%@)\n", path, isDir ? @"目录" : @"文件"];
    } else {
      [report appendFormat:@"✅ 不存在: %@\n", path];
    }
  }

  NSString *title =
      foundCount > 0
          ? [NSString stringWithFormat:@"⚠️ 发现 %d 个可疑路径", foundCount]
          : @"✅ 未发现可疑路径";

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:title
                                          message:report
                                   preferredStyle:UIAlertControllerStyleAlert];

  if (foundCount > 0) {
    // 添加"逐一查看"按钮
    [alert addAction:[UIAlertAction
                         actionWithTitle:@"查看详情"
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                   [self showDetectionResults];
                                 }]];
  }

  [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)showDetectionResults {
  // 显示一个 TableView 列出所有检测路径及状态
  UIAlertController *sheet = [UIAlertController
      alertControllerWithTitle:@"快速导航到检测路径"
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  NSFileManager *fm = [NSFileManager defaultManager];
  for (NSString *path in jailbreakDetectionPaths()) {
    BOOL exists = [fm fileExistsAtPath:path];
    NSString *label =
        [NSString stringWithFormat:@"%@ %@", exists ? @"🔴" : @"✅", path];

    [sheet
        addAction:
            [UIAlertAction
                actionWithTitle:label
                          style:exists ? UIAlertActionStyleDestructive
                                       : UIAlertActionStyleDefault
                        handler:^(UIAlertAction *_Nonnull action) {
                          // 如果存在，导航到该路径的父目录
                          if (exists) {
                            BOOL isDir = NO;
                            [fm fileExistsAtPath:path isDirectory:&isDir];
                            if (isDir) {
                              ECFileBrowserViewController *vc =
                                  [[ECFileBrowserViewController alloc]
                                      initWithPath:path];
                              [self.navigationController
                                  pushViewController:vc
                                            animated:YES];
                            } else {
                              ECFileBrowserViewController *vc =
                                  [[ECFileBrowserViewController alloc]
                                      initWithPath:
                                          [path
                                              stringByDeletingLastPathComponent]];
                              [self.navigationController
                                  pushViewController:vc
                                            animated:YES];
                            }
                          }
                        }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 跳转到指定路径

- (void)jumpToPath {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"跳转到路径"
                                          message:@"输入绝对路径"
                                   preferredStyle:UIAlertControllerStyleAlert];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"/usr/bin";
    textField.text = self.currentPath;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
  }];

  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"前往"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *_Nonnull action) {
                        NSString *path = alert.textFields.firstObject.text;
                        if (path.length > 0) {
                          BOOL isDir = NO;
                          BOOL exists = [[NSFileManager defaultManager]
                              fileExistsAtPath:path
                                   isDirectory:&isDir];
                          if (exists && isDir) {
                            ECFileBrowserViewController *vc =
                                [[ECFileBrowserViewController alloc]
                                    initWithPath:path];
                            [self.navigationController pushViewController:vc
                                                                 animated:YES];
                          } else if (exists) {
                            ECFileViewerViewController *viewer =
                                [[ECFileViewerViewController alloc]
                                    initWithPath:path];
                            [self.navigationController pushViewController:viewer
                                                                 animated:YES];
                          } else {
                            UIAlertController *err = [UIAlertController
                                alertControllerWithTitle:@"路径不存在"
                                                 message:path
                                          preferredStyle:
                                              UIAlertControllerStyleAlert];
                            [err addAction:
                                     [UIAlertAction
                                         actionWithTitle:@"确定"
                                                   style:
                                                       UIAlertActionStyleDefault
                                                 handler:nil]];
                            [self presentViewController:err
                                               animated:YES
                                             completion:nil];
                          }
                        }
                      }]];

  // 添加常用路径快捷方式
  NSArray *shortcuts = @[
    @"/usr/bin", @"/Library", @"/private/etc", @"/var/mobile", @"/Applications",
    @"/private/preboot"
  ];
  for (NSString *shortcut in shortcuts) {
    [alert addAction:[UIAlertAction
                         actionWithTitle:shortcut
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                   BOOL isDir = NO;
                                   if ([[NSFileManager defaultManager]
                                           fileExistsAtPath:shortcut
                                                isDirectory:&isDir] &&
                                       isDir) {
                                     ECFileBrowserViewController *vc =
                                         [[ECFileBrowserViewController alloc]
                                             initWithPath:shortcut];
                                     [self.navigationController
                                         pushViewController:vc
                                                   animated:YES];
                                   }
                                 }]];
  }

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 加载文件列表

- (void)loadFiles {
  NSError *error = nil;
  NSArray *contents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:self.currentPath
                                                          error:&error];

  if (error) {
    self.files = @[];
    NSLog(@"[FileBrowser] 读取目录失败: %@ - %@", self.currentPath,
          error.localizedDescription);

    // 显示权限错误提示
    dispatch_async(dispatch_get_main_queue(), ^{
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"无法读取"
                           message:[NSString stringWithFormat:
                                                 @"路径: %@\n错误: %@",
                                                 self.currentPath,
                                                 error.localizedDescription]
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];
    });
  } else {
    // 排序: 目录在前，文件在后
    self.files = [contents sortedArrayUsingComparator:^NSComparisonResult(
                               NSString *obj1, NSString *obj2) {
      NSString *path1 = [self.currentPath stringByAppendingPathComponent:obj1];
      NSString *path2 = [self.currentPath stringByAppendingPathComponent:obj2];

      BOOL isDir1 = NO, isDir2 = NO;
      [[NSFileManager defaultManager] fileExistsAtPath:path1
                                           isDirectory:&isDir1];
      [[NSFileManager defaultManager] fileExistsAtPath:path2
                                           isDirectory:&isDir2];

      if (isDir1 && !isDir2)
        return NSOrderedAscending;
      if (!isDir1 && isDir2)
        return NSOrderedDescending;

      return [obj1 compare:obj2 options:NSCaseInsensitiveSearch];
    }];
  }
  [self.tableView reloadData];
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  // 根目录显示 2 个 section: 快捷导航 + 文件列表
  return self.isRoot ? 2 : 1;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
  if (self.isRoot) {
    return section == 0 ? @"🔍 TikTok 检测路径" : @"📂 根目录内容";
  }
  return [NSString stringWithFormat:@"📂 %@", self.currentPath];
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  if (self.isRoot && section == 0) {
    return jailbreakDetectionPaths().count;
  }
  return self.files.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {

  // 快捷导航 section
  if (self.isRoot && indexPath.section == 0) {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"DetectCell"];
    if (!cell) {
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                    reuseIdentifier:@"DetectCell"];
    }

    NSString *path = jailbreakDetectionPaths()[indexPath.row];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];

    cell.textLabel.text = path;
    cell.textLabel.font =
        [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    cell.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];

    if (exists) {
      cell.detailTextLabel.text = @"🔴 存在 — 可能被 TikTok 检测";
      cell.detailTextLabel.textColor = [UIColor systemRedColor];
      cell.textLabel.textColor = [UIColor systemRedColor];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
      cell.detailTextLabel.text = @"✅ 不存在 — 安全";
      cell.detailTextLabel.textColor = [UIColor systemGreenColor];
      cell.textLabel.textColor = [UIColor systemGreenColor];
      cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
  }

  // 文件列表 section
  static NSString *CellIdentifier = @"FileCell";
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:CellIdentifier];
  }

  NSString *fileName = self.files[indexPath.row];
  NSString *fullPath =
      [self.currentPath stringByAppendingPathComponent:fileName];

  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];

  cell.textLabel.text = fileName;
  cell.textLabel.font = [UIFont monospacedSystemFontOfSize:14
                                                    weight:UIFontWeightRegular];
  cell.textLabel.textColor = [UIColor whiteColor];
  cell.backgroundColor = [UIColor colorWithWhite:0.08 alpha:1.0];

  if (isDir) {
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    cell.detailTextLabel.text = @"目录";
    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
    cell.imageView.tintColor = [UIColor systemYellowColor];
  } else {
    cell.accessoryType = UITableViewCellAccessoryNone;
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:fullPath
                                                         error:nil];
    uint64_t fileSize = [attrs fileSize];
    NSString *perms =
        [attrs objectForKey:NSFilePosixPermissions]
            ? [NSString
                  stringWithFormat:@"%lo",
                                   (unsigned long)[[attrs
                                       objectForKey:NSFilePosixPermissions]
                                       integerValue]]
            : @"---";
    cell.detailTextLabel.text = [NSString
        stringWithFormat:
            @"%@ | %@",
            [NSByteCountFormatter
                stringFromByteCount:fileSize
                         countStyle:NSByteCountFormatterCountStyleFile],
            perms];
    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    cell.imageView.image = [UIImage systemImageNamed:@"doc.text"];
    cell.imageView.tintColor = [UIColor systemBlueColor];
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  // 快捷导航 section
  if (self.isRoot && indexPath.section == 0) {
    NSString *path = jailbreakDetectionPaths()[indexPath.row];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (exists) {
      BOOL isDir = NO;
      [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
      if (isDir) {
        ECFileBrowserViewController *vc =
            [[ECFileBrowserViewController alloc] initWithPath:path];
        [self.navigationController pushViewController:vc animated:YES];
      } else {
        // 导航到文件所在目录，高亮显示该文件
        ECFileBrowserViewController *vc = [[ECFileBrowserViewController alloc]
            initWithPath:[path stringByDeletingLastPathComponent]];
        [self.navigationController pushViewController:vc animated:YES];
      }
    }
    return;
  }

  // 文件列表 section
  NSString *fileName = self.files[indexPath.row];
  NSString *fullPath =
      [self.currentPath stringByAppendingPathComponent:fileName];

  BOOL isDir = NO;
  [[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir];

  if (isDir) {
    ECFileBrowserViewController *nextVC =
        [[ECFileBrowserViewController alloc] initWithPath:fullPath];
    [self.navigationController pushViewController:nextVC animated:YES];
  } else {
    ECFileViewerViewController *viewer =
        [[ECFileViewerViewController alloc] initWithPath:fullPath];
    [self.navigationController pushViewController:viewer animated:YES];
  }
}

#pragma mark - Table view editing

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  if (self.isRoot && indexPath.section == 0) {
    return NO;
  }
  return YES;
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle == UITableViewCellEditingStyleDelete) {
    if (self.isRoot && indexPath.section == 0) return;
    
    NSString *fileName = self.files[indexPath.row];
    NSString *fullPath = [self.currentPath stringByAppendingPathComponent:fileName];
    
    NSError *error = nil;
    BOOL success = [[NSFileManager defaultManager] removeItemAtPath:fullPath error:&error];
    
    if (success) {
      NSMutableArray *newFiles = [self.files mutableCopy];
      [newFiles removeObjectAtIndex:indexPath.row];
      self.files = [newFiles copy];
      [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    } else {
      UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除失败"
                                                                     message:error.localizedDescription
                                                              preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];
    }
  }
}

@end
