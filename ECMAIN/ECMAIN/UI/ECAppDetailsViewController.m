#import "ECAppDetailsViewController.h"
#import "../../TrollStoreCore/TSAppInfo.h"
#import "../Utils/MemoryUtilities.h"
#import "ECFileBrowserViewController.h"
#import "ECFileViewerViewController.h"

#import <objc/runtime.h>

@interface ECAppDetailsViewController ()
@property(nonatomic, strong) TSAppInfo *appInfo;
@property(nonatomic, strong) NSDictionary *entitlements;
@property(nonatomic, strong) NSArray *sections;
@end

@implementation ECAppDetailsViewController

- (instancetype)initWithAppInfo:(TSAppInfo *)appInfo {
  if (self = [super initWithStyle:UITableViewStyleInsetGrouped]) {
    _appInfo = appInfo;
    _entitlements = [appInfo entitlements];
    self.title = @"应用详情";
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];

  // Setup Navigation
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                           target:self
                           action:@selector(doneTapped)];
  self.navigationItem.leftBarButtonItem =
      [[UIBarButtonItem alloc] initWithTitle:@"复制全部"
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(copyAllInfo)];

  [self setupData];
}

- (void)doneTapped {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)copyAllInfo {
  NSMutableString *fullText = [NSMutableString string];
  for (NSDictionary *section in self.sections) {
    [fullText appendFormat:@"\n[%@]\n", section[@"title"]];
    for (NSDictionary *row in section[@"rows"]) {
      [fullText appendFormat:@"%@: %@\n", row[@"title"] ?: row[@"text"],
                             row[@"detail"] ?: @""];
    }
  }
  [UIPasteboard generalPasteboard].string = fullText;

  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"已复制"
                                          message:@"完整应用信息已复制到剪贴板"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)setupData {
  NSMutableArray *sections = [NSMutableArray new];

  // --- Section 1: Basic Info ---
  NSMutableArray *basicRows = [NSMutableArray new];
  [basicRows addObject:@{
    @"title" : @"应用名称",
    @"detail" : self.appInfo.displayName ?: @""
  }];
  [basicRows addObject:@{
    @"title" : @"Bundle ID",
    @"detail" : self.appInfo.bundleIdentifier ?: @""
  }];
  [basicRows addObject:@{
    @"title" : @"应用版本",
    @"detail" : self.appInfo.versionString ?: @""
  }];

  // Try to get Min OS Version & SDK Version from Info.plist
  NSString *plistPath =
      [self.appInfo.bundlePath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *infoPlist =
      [NSDictionary dictionaryWithContentsOfFile:plistPath];
  if (infoPlist[@"DTPlatformVersion"]) {
    [basicRows addObject:@{
      @"title" : @"SDK 版本",
      @"detail" : infoPlist[@"DTPlatformVersion"]
    }];
  }
  if (infoPlist[@"MinimumOSVersion"]) {
    [basicRows addObject:@{
      @"title" : @"最低系统要求",
      @"detail" : infoPlist[@"MinimumOSVersion"]
    }];
  }

  [sections addObject:@{@"title" : @"基本信息", @"rows" : basicRows}];

  // --- Section 2: Paths ---
  NSMutableArray *pathRows = [NSMutableArray new];
  [pathRows addObject:@{
    @"title" : @"Bundle 路径",
    @"detail" : self.appInfo.bundlePath ?: @"",
    @"subtitle" : @YES,
    @"action" : @"browse"
  }];

  if (self.appInfo.dataContainerURL) {
    [pathRows addObject:@{
      @"title" : @"Data 路径",
      @"detail" : self.appInfo.dataContainerURL.path,
      @"subtitle" : @YES,
      @"action" : @"browse" // Custom tag for action
    }];
  }

  [sections addObject:@{@"title" : @"路径信息", @"rows" : pathRows}];

  // --- Section 3: Security & Status ---
  NSMutableArray *secRows = [NSMutableArray new];

  // Encryption Status
  // Use built-in executablePath
  NSString *execPath = [self.appInfo executablePath];
  EncryptionStatus status = checkBinaryEncryptionStatus(execPath);
  NSString *statusStr = encryptionStatusDescription(status);
  NSString *statusEmoji = (status == EncryptionStatusEncrypted) ? @"🔒" : @"🔓";
  [secRows addObject:@{
    @"title" : @"二进制加密",
    @"detail" : [NSString stringWithFormat:@"%@ %@", statusEmoji, statusStr]
  }];
  // SC_Info Presence
  NSString *scInfoPath =
      [self.appInfo.bundlePath stringByAppendingPathComponent:@"SC_Info"];
  BOOL hasSCInfo = [[NSFileManager defaultManager] fileExistsAtPath:scInfoPath];
  [secRows addObject:@{
    @"title" : @"App Store 授权",
    @"detail" : hasSCInfo ? @"✅ 存在 (SC_Info)" : @"❌ 不存在"
  }];

  // Registration State
  [secRows addObject:@{
    @"title" : @"注册类型",
    @"detail" : self.appInfo.registrationState ?: @"Unknown"
  }];

  [sections addObject:@{@"title" : @"安全与状态", @"rows" : secRows}];

  // --- Section 4: Privacy Permissions ---
  NSMutableArray *privacyRows = [NSMutableArray new];
  NSDictionary *privacyMap = @{
    @"NSCameraUsageDescription" : @"📷 相机",
    @"NSPhotoLibraryUsageDescription" : @"🖼 相册",
    @"NSPhotoLibraryAddUsageDescription" : @"🖼 相册写入",
    @"NSMicrophoneUsageDescription" : @"🎤 麦克风",
    @"NSLocationWhenInUseUsageDescription" : @"📍 使用时定位",
    @"NSLocationAlwaysAndWhenInUseUsageDescription" : @"📍 始终定位",
    @"NSContactsUsageDescription" : @"📒 通讯录",
    @"NSCalendarsUsageDescription" : @"📅 日历",
    @"NSRemindersUsageDescription" : @"⏰ 提醒事项",
    @"NSFaceIDUsageDescription" : @"🙂 FaceID",
    @"NSUserTrackingUsageDescription" : @"👤 广告追踪",
    @"NSBluetoothAlwaysUsageDescription" : @"🦷 蓝牙",
    @"NSLocalNetworkUsageDescription" : @"🌐 本地网络"
  };

  for (NSString *key in privacyMap) {
    if (infoPlist[key]) {
      [privacyRows addObject:@{
        @"title" : privacyMap[key],
        @"detail" : infoPlist[key],
        @"subtitle" : @YES
      }];
    }
  }

  if (privacyRows.count > 0) {
    [sections addObject:@{@"title" : @"隐私权限声明", @"rows" : privacyRows}];
  } else {
    [sections addObject:@{
      @"title" : @"隐私权限声明",
      @"rows" : @[ @{@"text" : @"未检测到敏感权限声明"} ]
    }];
  }

  // --- Section 5: Capabilities (Entitlements) ---
  NSMutableArray *capRows = [NSMutableArray new];

  // Sandbox Check
  BOOL isSandboxed = YES;
  if (self.entitlements) {
    if (self.entitlements[@"com.apple.private.security.no-container"] ||
        [self.entitlements[@"com.apple.private.security.container-required"]
            isEqual:@0]) {
      isSandboxed = NO;
    }
  }
  [capRows addObject:@{
    @"title" : @"沙盒状态",
    @"detail" : isSandboxed ? @"📦 受在沙盒中 (Sandboxed)"
                            : @"🔓 无沙盒限制 (Unsandboxed)"
  }];

  // Other Entitlements
  if (self.entitlements[@"get-task-allow"])
    [capRows
        addObject:@{@"title" : @"调试权限", @"detail" : @"✅ get-task-allow"}];
  if (self.entitlements[@"platform-application"])
    [capRows addObject:@{
      @"title" : @"平台应用",
      @"detail" : @"✅ platform-application"
    }];
  if (self.entitlements[@"com.apple.private.security.no-container"])
    [capRows addObject:@{@"title" : @"无容器", @"detail" : @"✅ no-container"}];

  [sections addObject:@{@"title" : @"能力与权限", @"rows" : capRows}];

  // --- Section 6: App Groups ---
  NSArray *groups = self.entitlements[@"com.apple.security.application-groups"];
  if (groups && groups.count > 0) {
    NSMutableArray *groupRows = [NSMutableArray new];
    for (NSString *g in groups) {
      [groupRows addObject:@{@"text" : g}];
    }
    [sections
        addObject:@{@"title" : @"App Groups (共享容器)", @"rows" : groupRows}];
  }

  // --- Section 7: URL Schemes ---
  NSArray *urlTypes = infoPlist[@"CFBundleURLTypes"];
  if (urlTypes && urlTypes.count > 0) {
    NSMutableArray *schemeRows = [NSMutableArray new];
    for (NSDictionary *type in urlTypes) {
      NSArray *schemes = type[@"CFBundleURLSchemes"];
      for (NSString *s in schemes) {
        [schemeRows addObject:@{@"text" : s}];
      }
    }
    if (schemeRows.count > 0) {
      [sections addObject:@{
        @"title" : @"URL Schemes (调用协议)",
        @"rows" : schemeRows
      }];
    }
  }

  self.sections = sections;
}

#pragma mark - Table view data source

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
  static NSString *DetailCell = @"DetailCell";
  static NSString *SubtitleCell = @"SubtitleCell";
  static NSString *BasicCell = @"BasicCell";

  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];
  BOOL isSubtitle = [row[@"subtitle"] boolValue];
  BOOL isTextOnly = (row[@"title"] == nil);

  NSString *identifier =
      isTextOnly ? BasicCell : (isSubtitle ? SubtitleCell : DetailCell);
  UITableViewCellStyle style = isTextOnly
                                   ? UITableViewCellStyleDefault
                                   : (isSubtitle ? UITableViewCellStyleSubtitle
                                                 : UITableViewCellStyleValue1);

  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:identifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:style
                                  reuseIdentifier:identifier];
    cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    cell.detailTextLabel.minimumScaleFactor = 0.6;
  }

  if (isTextOnly) {
    cell.textLabel.text = row[@"text"];
    cell.textLabel.font = [UIFont systemFontOfSize:14];
    cell.textLabel.numberOfLines = 0;
  } else {
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];
    if (isSubtitle) {
      cell.detailTextLabel.numberOfLines = 0;
      cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    } else {
      cell.detailTextLabel.numberOfLines = 1;
    }
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];

  NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row];

  if ([row[@"action"] isEqualToString:@"browse"]) {
    NSString *path = row[@"detail"];
    // Import header or implement it
    ECFileBrowserViewController *browser =
        [[ECFileBrowserViewController alloc] initWithPath:path];
    [self.navigationController pushViewController:browser animated:YES];
    return;
  }

  NSString *content = row[@"detail"] ?: row[@"text"];

  if (content.length > 0) {
    [UIPasteboard generalPasteboard].string = content;

    UIAlertController *toast = [UIAlertController
        alertControllerWithTitle:nil
                         message:@"已复制到剪贴板"
                  preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:toast animated:YES completion:nil];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [toast dismissViewControllerAnimated:YES completion:nil];
        });
  }
}

@end

// FORCE INCLUDE IMPLEMENTATION TO FIX MISSING SYMBOL
// (Because these files are not in the Xcode project compile sources)
#import "ECFileBrowserViewController.m"
#import "ECFileViewerViewController.m"
