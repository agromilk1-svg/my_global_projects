#import "ECAppListViewController.h"
#import "../../TrollStoreCore/TSAppInfo.h"
#import "../../TrollStoreCore/TSApplicationsManager.h"
#import "../../TrollStoreCore/TSInstallationController.h"
#import "../../TrollStoreCore/TSPresentationDelegate.h"
#import "../../TrollStoreCore/TSUtil.h"
#import "../../TrollStoreCore/ZipWriter.h"
#import "../Core/ECAppInjector.h"
#import "../Core/ECLogManager.h"
#import "../Utils/ECAppLauncher.m"
#import "../Utils/LaunchdResponse.m"
#import "../Utils/MemoryUtilities.m"
#import "ECAppDetailsViewController.h"
#import "ECDeviceInfoViewController.h"
#import "ECDumpBinary.h"
#import "ECFileBrowserViewController.h"
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/wait.h>

// Persona spawn declarations (for root execution)
#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t *__restrict,
                                          uid_t, uint32_t);
extern int
posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *__restrict, uid_t);
extern int
posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *__restrict, uid_t);

// --- libproc private declarations ---
#define PROC_PIDTASKINFO 4
#define PROC_PIDPATHINFO_MAXSIZE 1024

struct proc_taskinfo {
    uint64_t        pti_virtual_size;   
    uint64_t        pti_resident_size;  
    uint64_t        pti_total_user;     
    uint64_t        pti_total_system;
    uint64_t        pti_threads_user;   
    uint64_t        pti_threads_system;
    int32_t         pti_policy;     
    int32_t         pti_faults;     
    int32_t         pti_pageins;        
    int32_t         pti_cow_faults;     
    int32_t         pti_messages_sent;  
    int32_t         pti_messages_received;  
    int32_t         pti_syscalls_mach;  
    int32_t         pti_syscalls_unix;  
    int32_t         pti_csw;            
    int32_t         pti_threadnum;      
    int32_t         pti_numrunning;     
    int32_t         pti_priority;       
};

int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
// ------------------------------------

@interface ECAppListViewController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) NSMutableArray<TSAppInfo *> *apps;
@property(nonatomic, strong) NSMutableArray<NSString *> *downloadedIPAs;
@property(nonatomic, strong) NSURLSession *downloadSession;
@property(nonatomic, strong) UIAlertController *downloadAlert;
@property(nonatomic, strong) UIProgressView *downloadProgressView;

// 分阶段脱壳状态
@property(nonatomic, strong) TSAppInfo *decryptingApp; // 正在脱壳的应用
@property(nonatomic, strong)
    NSDictionary<NSString *, NSNumber *> *runningProcesses;
@property(nonatomic, strong) NSString *decryptTempDir;     // 临时目录
@property(nonatomic, strong) NSString *decryptDestAppPath; // 目标 app 路径
@property(nonatomic, assign) pid_t decryptTargetPID;       // 目标应用 PID
@property(nonatomic, assign)
    mach_port_t decryptTargetTask; // 目标应用 task port
@property(nonatomic, strong) NSMutableArray *runningExtensions; // 保持扩展活跃

@property (nonatomic, assign) NSInteger currentTabIndex;
@property (nonatomic, strong) NSArray *processList;
@property (nonatomic, assign) NSInteger processSortType; // 0: Mem, 1: CPU
@property (nonatomic, strong) NSArray<NSDictionary *> *orphanedContainers;

- (void)installIPA:(NSString *)path
      registrationType:(NSString *)regType
        customBundleId:(NSString *)customBundleId
     customDisplayName:(NSString *)customDisplayName
    installationMethod:(int)installationMethod;

- (void)installOriginalIPA:(NSString *)path;

- (void)showAdvancedInjectionConfigForPath:(NSString *)path
                          originalBundleId:(NSString *)originalBundleId
                              originalName:(NSString *)originalName
                          workingDirectory:(NSString *)workingDirectory
                     useFrameworkInjection:(BOOL)useFrameworkInjection;

- (void)showDeviceSpoofConfigForPath:(NSString *)path
                      customBundleId:(NSString *)customBundleId
                   customDisplayName:(NSString *)customDisplayName
                    workingDirectory:(NSString *)workingDirectory
               useFrameworkInjection:(BOOL)useFrameworkInjection;

- (void)performInjectInstall:(NSString *)path
              customBundleId:(NSString *)customBundleId
           customDisplayName:(NSString *)customDisplayName
            workingDirectory:(NSString *)workingDirectory
       useFrameworkInjection:(BOOL)useFrameworkInjection;

@end

// Shim for NSExtension to avoid import issues
@interface NSExtension : NSObject
+ (instancetype)extensionWithIdentifier:(NSString *)identifier
                                  error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems
                                 completion:
                                     (void (^)(NSUUID *requestIdentifier,
                                               NSError *error))completion;
@end

extern int spawnRoot(NSString *path, NSArray *args, NSString **stdOut,
                     NSString **stdErr);
extern NSString *rootHelperPath(void);

@implementation ECAppListViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  
  UISegmentedControl *segment = [[UISegmentedControl alloc] initWithItems:@[@"应用", @"运行中"]];
  segment.selectedSegmentIndex = 0;
  [segment addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
  self.navigationItem.titleView = segment;

  UIBarButtonItem *addButton = [[UIBarButtonItem alloc]
      initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                           target:self
                           action:@selector(addButtonPressed)];
  self.navigationItem.rightBarButtonItem = addButton;

  // 添加左侧文件浏览入口
  UIBarButtonItem *fileBrowserBtn = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"folder.badge.questionmark"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(openFileBrowser)];
  self.navigationItem.leftBarButtonItem = fileBrowserBtn;

  self.apps = [NSMutableArray array];
  self.downloadedIPAs = [NSMutableArray array];

  UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
  [refreshControl addTarget:self
                     action:@selector(loadData)
           forControlEvents:UIControlEventValueChanged];
  self.refreshControl = refreshControl;

  NSURLSessionConfiguration *config =
      [NSURLSessionConfiguration defaultSessionConfiguration];
  self.downloadSession =
      [NSURLSession sessionWithConfiguration:config
                                    delegate:self
                               delegateQueue:[NSOperationQueue mainQueue]];
                               
  // 监听来自文件浏览器的 IPA 点击安装请求
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleInstallNotification:)
                                               name:@"ECInstallIPANotification"
                                             object:nil];
}

- (void)handleInstallNotification:(NSNotification *)note {
  NSString *path = note.object;
  if ([path isKindOfClass:[NSString class]]) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [self showInstallOptionsForPath:path isURL:NO];
    });
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];

  // 检查并安装 ldid 到 Documents 目录
  [self ensureLdidInstalled];

  [self loadData];
}

- (void)openFileBrowser {
  ECFileBrowserViewController *fileBrowserVC =
      [[ECFileBrowserViewController alloc] initWithPath:@"/"];
  [self.navigationController pushViewController:fileBrowserVC animated:YES];
}

- (void)ensureLdidInstalled {
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *destLdid = [docsDir stringByAppendingPathComponent:@"ldid"];

  // 检查 Documents/ldid 是否存在
  if ([[NSFileManager defaultManager] fileExistsAtPath:destLdid]) {
    NSLog(@"[ECAppList] ldid 已存在于: %@", destLdid);
    return;
  }

  NSLog(@"[ECAppList] ldid 不存在，开始安装...");

  // 从包内复制 ldid 到 Documents
  NSString *bundleLdid = [[NSBundle mainBundle] pathForResource:@"ldid"
                                                         ofType:nil];
  if (!bundleLdid) {
    bundleLdid = [[NSBundle mainBundle].bundlePath
        stringByAppendingPathComponent:@"ldid"];
  }

  if (!bundleLdid ||
      ![[NSFileManager defaultManager] fileExistsAtPath:bundleLdid]) {
    NSLog(@"[ECAppList] 警告: 包内找不到 ldid 文件");
    return;
  }

  NSError *error = nil;
  BOOL success = [[NSFileManager defaultManager] copyItemAtPath:bundleLdid
                                                         toPath:destLdid
                                                          error:&error];
  if (success) {
    // 设置可执行权限
    chmod(destLdid.UTF8String, 0755);
    NSLog(@"[ECAppList] ldid 安装成功: %@", destLdid);
  } else {
    NSLog(@"[ECAppList] ldid 安装失败: %@", error);
  }
}

- (void)loadData {
  NSLog(@"[ECAppList] loadData called");
  if (self.currentTabIndex == 1) {
    [self loadProcesses];
  } else {
    [self loadDownloadedIPAs];
    [self loadApps];
  }
}

- (void)segmentChanged:(UISegmentedControl *)sender {
  self.currentTabIndex = sender.selectedSegmentIndex;
  if (self.currentTabIndex == 1) {
    UIBarButtonItem *sortBtn = [[UIBarButtonItem alloc] initWithTitle:@"排序" style:UIBarButtonItemStylePlain target:self action:@selector(sortProcesses)];
    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadProcesses)];
    self.navigationItem.rightBarButtonItems = @[sortBtn, refreshBtn];
    [self loadProcesses];
  } else {
    UIBarButtonItem *addButton = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                             target:self
                             action:@selector(addButtonPressed)];
    self.navigationItem.rightBarButtonItems = nil;
    self.navigationItem.rightBarButtonItem = addButton;
    [self.tableView reloadData];
  }
}

- (void)sortProcesses {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"排序方式" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
  [alert addAction:[UIAlertAction actionWithTitle:@"按内存占用排序" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
      self.processSortType = 0;
      [self sortAndReloadProcesses];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"按 CPU 占用排序" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
      self.processSortType = 1;
      [self sortAndReloadProcesses];
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
  
  if (alert.popoverPresentationController) {
      alert.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
  }
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)sortAndReloadProcesses {
  if (!self.processList) return;
  
  NSArray *sorted = [self.processList sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *obj1, NSDictionary *obj2) {
      if (self.processSortType == 1) {
          return [obj2[@"cpu"] compare:obj1[@"cpu"]];
      } else {
          return [obj2[@"mem"] compare:obj1[@"mem"]];
      }
  }];
  self.processList = sorted;
  [self.tableView reloadData];
}

- (void)loadProcesses {
  // 手动刷新逻辑
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSMutableArray *result = [NSMutableArray array];
    
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != -1) {
      struct kinfo_proc *processes = malloc(size);
      if (processes && sysctl(mib, 4, processes, &size, NULL, 0) != -1) {
        int count = size / sizeof(struct kinfo_proc);
        for (int i = 0; i < count; i++) {
          pid_t pid = processes[i].kp_proc.p_pid;
          if (pid == 0) continue;
          
          NSString *procName = [NSString stringWithUTF8String:processes[i].kp_proc.p_comm] ?: @"Unknown";
          NSString *appName = procName;
          NSString *bundleID = @"";
          
          char pathBuffer[1024]; // PROC_PIDPATHINFO_MAXSIZE
          if (proc_pidpath(pid, pathBuffer, sizeof(pathBuffer)) > 0) {
            NSString *path = [NSString stringWithUTF8String:pathBuffer];
            if ([path containsString:@".app/"]) {
              NSBundle *bundle = [NSBundle bundleWithPath:[path stringByDeletingLastPathComponent]];
              if (bundle) {
                bundleID = [bundle bundleIdentifier] ?: @"";
                appName = [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: 
                          [bundle objectForInfoDictionaryKey:@"CFBundleName"] ?: procName;
              }
            }
          }
          
          struct proc_taskinfo pti;
          uint64_t memBytes = 0;
          if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &pti, sizeof(pti)) == sizeof(pti)) {
            memBytes = pti.pti_resident_size;
          }
          
          float cpuUsage = 0;
          mach_port_t task;
          if (task_for_pid(mach_task_self(), pid, &task) == KERN_SUCCESS) {
            thread_array_t thread_list;
            mach_msg_type_number_t thread_count;
            if (task_threads(task, &thread_list, &thread_count) == KERN_SUCCESS) {
              for (int j = 0; j < thread_count; j++) {
                thread_info_data_t thinfo;
                mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
                if (thread_info(thread_list[j], THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count) == KERN_SUCCESS) {
                  thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
                  if (!(basic_info_th->flags & TH_FLAGS_IDLE)) {
                    cpuUsage += basic_info_th->cpu_usage / (float)TH_USAGE_SCALE * 100.0;
                  }
                }
              }
              for (size_t j = 0; j < thread_count; j++) {
                mach_port_deallocate(mach_task_self(), thread_list[j]);
              }
              vm_deallocate(mach_task_self(), (vm_address_t)thread_list, thread_count * sizeof(thread_t));
            }
            mach_port_deallocate(mach_task_self(), task);
          }
          
          [result addObject:@{
            @"pid": @(pid),
            @"name": appName,
            @"proc_name": procName,
            @"bundleID": bundleID,
            @"cpu": @(cpuUsage),
            @"mem": @(memBytes)
          }];
        }
        free(processes);
      } else if (processes) {
        free(processes);
      }
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
      self.processList = result;
      [self sortAndReloadProcesses];
      [self.refreshControl endRefreshing];
    });
  });
}

- (void)loadDownloadedIPAs {
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *importDir =
      [docsDir stringByAppendingPathComponent:@"ImportedIPAs"];

  NSLog(@"[ECAppList] Import Dir: %@", importDir);

  // Create if not exists
  if (![[NSFileManager defaultManager] fileExistsAtPath:importDir]) {
    NSError *createError;
    [[NSFileManager defaultManager] createDirectoryAtPath:importDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&createError];
    NSLog(@"[ECAppList] Created import dir. Error: %@", createError);
  }

  NSArray *files =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:importDir
                                                          error:nil];
  NSLog(@"[ECAppList] Files found: %@", files);

  self.downloadedIPAs = [NSMutableArray array];
  for (NSString *file in files) {
    if ([file.pathExtension.lowercaseString isEqualToString:@"ipa"]) {
      [self.downloadedIPAs
          addObject:[importDir stringByAppendingPathComponent:file]];
    }
  }
  NSLog(@"[ECAppList] IPAs loaded: %lu",
        (unsigned long)self.downloadedIPAs.count);
  [self.tableView reloadData];
}

- (void)loadApps {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self refreshRunningProcesses];
        self.orphanedContainers = [[TSApplicationsManager sharedInstance] scanOrphanedContainers];
        NSArray *paths =
            [[TSApplicationsManager sharedInstance] allUserAppPaths];
        NSMutableArray *newApps = [NSMutableArray array];

        for (NSString *path in paths) {
          TSAppInfo *appInfo = [[TSAppInfo alloc] initWithAppBundlePath:path];
          if (appInfo) {
            [newApps addObject:appInfo];
          }
        }

        // Load info
        dispatch_group_t group = dispatch_group_create();
        for (TSAppInfo *app in newApps) {
          dispatch_group_enter(group);
          [app loadInfoWithCompletion:^(NSError *error) {
            dispatch_group_leave(group);
          }];
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
          self.apps = newApps;
          [self.tableView reloadData];
          [self.refreshControl endRefreshing];
        });
      });
}

- (void)addButtonPressed {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"安装应用"
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"安装 IPA 文件"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *_Nonnull action) {
// Use non-deprecated init if available, or suppress warning
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                        UIDocumentPickerViewController *picker =
                            [[UIDocumentPickerViewController alloc]
                                initWithDocumentTypes:@[
                                  @"com.apple.itunes.ipa", @"public.item"
                                ]
                                               inMode:
                                                   UIDocumentPickerModeImport];
#pragma clang diagnostic pop
                        picker.delegate = self;
                        [self presentViewController:picker
                                           animated:YES
                                         completion:nil];
                      }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"从 URL 安装"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self showURLInstallAlert];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"🧹 清理系统垃圾"
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *_Nonnull action) {
                                 dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                     NSString *result = [[TSApplicationsManager sharedInstance] cleanSystemData];
                                     unsigned long long freed = 0;
                                     if (result) {
                                         NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
                                         if (data) {
                                             NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                                             freed = [json[@"freed"] unsignedLongLongValue];
                                         }
                                     }
                                     dispatch_async(dispatch_get_main_queue(), ^{
                                         NSString *msg = [NSString stringWithFormat:@"已清理 %.2f MB 系统垃圾数据\n(含 /tmp 残留、统一日志库、installd 日志、App 缓存、WebKit 缓存)", freed / 1024.0 / 1024.0];
                                         UIAlertController *doneAlert = [UIAlertController alertControllerWithTitle:@"清理完成" message:msg preferredStyle:UIAlertControllerStyleAlert];
                                         [doneAlert addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
                                         [self presentViewController:doneAlert animated:YES completion:nil];
                                     });
                                 });
                               }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  // iPad popover fix
  if (alert.popoverPresentationController) {
    alert.popoverPresentationController.barButtonItem =
        self.navigationItem.rightBarButtonItem;
  }

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)showURLInstallAlert {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"从 URL 安装"
                                          message:@"请输入 IPA 文件的下载链接"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert
      addTextFieldWithConfigurationHandler:^(UITextField *_Nonnull textField) {
        textField.placeholder = @"https://example.com/app.ipa";
      }];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"下载"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 NSString *urlStr =
                                     alert.textFields.firstObject.text;
                                 if (urlStr.length > 0) {
                                   NSURL *url = [NSURL URLWithString:urlStr];
                                   if (url) {
                                     [self startURLDownload:url];
                                   }
                                 }
                               }]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAppDetails:(TSAppInfo *)app {
  ECAppDetailsViewController *detailsVC =
      [[ECAppDetailsViewController alloc] initWithAppInfo:app];
  UINavigationController *nav =
      [[UINavigationController alloc] initWithRootViewController:detailsVC];
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)refreshRunningProcesses {
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size;
  if (sysctl(mib, 4, NULL, &size, NULL, 0) == -1)
    return;

  struct kinfo_proc *processes = malloc(size);
  if (processes == NULL)
    return;

  if (sysctl(mib, 4, processes, &size, NULL, 0) == -1) {
    free(processes);
    return;
  }

  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  int count = size / sizeof(struct kinfo_proc);
  for (int i = 0; i < count; i++) {
    if (processes[i].kp_proc.p_comm[0] != '\0') {
      NSString *name =
          [NSString stringWithUTF8String:processes[i].kp_proc.p_comm];
      int pid = processes[i].kp_proc.p_pid;
      dict[name] = @(pid);
    }
  }
  free(processes);
  self.runningProcesses = dict;
}

- (void)startURLDownload:(NSURL *)url {
  [[ECLogManager sharedManager] log:@"[下载] 开始下载: %@", url];
  self.downloadAlert =
      [UIAlertController alertControllerWithTitle:@"正在下载..."
                                          message:@"\n\n"
                                   preferredStyle:UIAlertControllerStyleAlert];

  self.downloadProgressView = [[UIProgressView alloc]
      initWithProgressViewStyle:UIProgressViewStyleDefault];
  self.downloadProgressView.frame = CGRectMake(10, 55, 250, 2);
  [self.downloadAlert.view addSubview:self.downloadProgressView];

  [self.downloadAlert
      addAction:[UIAlertAction
                    actionWithTitle:@"取消"
                              style:UIAlertActionStyleCancel
                            handler:^(UIAlertAction *_Nonnull action) {
                              [[ECLogManager sharedManager]
                                  log:@"[下载] 用户取消下载"];
                              [self.downloadSession
                                  getAllTasksWithCompletionHandler:^(
                                      NSArray<NSURLSessionTask *>
                                          *_Nonnull tasks) {
                                    for (NSURLSessionTask *task in tasks)
                                      [task cancel];
                                  }];
                            }]];

  [self presentViewController:self.downloadAlert animated:YES completion:nil];

  NSURLSessionDownloadTask *task =
      [self.downloadSession downloadTaskWithURL:url];
  [task resume];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  float progress = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.downloadProgressView.progress = progress;
    self.downloadAlert.message =
        [NSString stringWithFormat:@"\n%.0f%%", progress * 100];
  });
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:(NSURL *)location {
  [[ECLogManager sharedManager] log:@"[下载] 下载完成，临时路径: %@", location];

  // Perform file operations IMMEDIATELY before method returns
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *importDir =
      [docsDir stringByAppendingPathComponent:@"ImportedIPAs"];

  NSError *createDirError;
  if (![[NSFileManager defaultManager] fileExistsAtPath:importDir]) {
    [[ECLogManager sharedManager] log:@"[下载] 尝试创建目录: %@", importDir];
    [[NSFileManager defaultManager] createDirectoryAtPath:importDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&createDirError];
    if (createDirError) {
      [[ECLogManager sharedManager]
          log:@"[下载] 创建目录失败: %@", createDirError];
    }
  }

  NSString *filename =
      downloadTask.response.suggestedFilename ?: @"downloaded.ipa";
  NSString *destPath = [importDir stringByAppendingPathComponent:filename];

  // Ensure unique name
  int i = 1;
  while ([[NSFileManager defaultManager] fileExistsAtPath:destPath]) {
    destPath = [importDir
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_%d.ipa",
                                       [filename stringByDeletingPathExtension],
                                       i++]];
  }

  NSError *moveError;
  // Use copy then remove to be safer across volumes, though move is usually
  // fine. We use move here.
  [[NSFileManager defaultManager] moveItemAtURL:location
                                          toURL:[NSURL fileURLWithPath:destPath]
                                          error:&moveError];

  if (moveError) {
    [[ECLogManager sharedManager] log:@"[下载] 移动文件失败: %@", moveError];
  } else {
    [[ECLogManager sharedManager] log:@"[下载] 文件已保存至: %@", destPath];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [self.downloadAlert
        dismissViewControllerAnimated:YES
                           completion:^{
                             if (moveError) {
                               UIAlertController *err = [UIAlertController
                                   alertControllerWithTitle:@"保存失败"
                                                    message:
                                                        moveError
                                                            .localizedDescription
                                             preferredStyle:
                                                 UIAlertControllerStyleAlert];
                               [err
                                   addAction:
                                       [UIAlertAction
                                           actionWithTitle:@"OK"
                                                     style:
                                                         UIAlertActionStyleDefault
                                                   handler:nil]];
                               [self presentViewController:err
                                                  animated:YES
                                                completion:nil];
                             } else {
                               // Refresh list
                               [self loadDownloadedIPAs];

                               UIAlertController *toast = [UIAlertController
                                   alertControllerWithTitle:@"下载完成"
                                                    message:
                                                        [NSString
                                                            stringWithFormat:
                                                                @"已保存至“已"
                                                                @"下"
                                                                @"载"
                                                                @"”列表:\n%@",
                                                                destPath
                                                                    .lastPathComponent]
                                             preferredStyle:
                                                 UIAlertControllerStyleAlert];
                               [self presentViewController:toast
                                                  animated:YES
                                                completion:nil];
                               dispatch_after(
                                   dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                                     [toast dismissViewControllerAnimated:YES
                                                               completion:nil];
                                   });
                             }
                           }];
  });
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  if (error) {
    [[ECLogManager sharedManager] log:@"[下载] 任务失败: %@", error];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self.downloadAlert
          dismissViewControllerAnimated:YES
                             completion:^{
                               UIAlertController *errAlert = [UIAlertController
                                   alertControllerWithTitle:@"下载失败"
                                                    message:
                                                        error
                                                            .localizedDescription
                                             preferredStyle:
                                                 UIAlertControllerStyleAlert];
                               [errAlert
                                   addAction:
                                       [UIAlertAction
                                           actionWithTitle:@"OK"
                                                     style:
                                                         UIAlertActionStyleDefault
                                                   handler:nil]];
                               [self presentViewController:errAlert
                                                  animated:YES
                                                completion:nil];
                             }];
    });
  }
}

// showInstallConfirmation removed as flow changed

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
  if (urls.count == 0)
    return;

  NSURL *url = urls.firstObject;

  // 检查是否是 SC_Info 导入模式
  TSAppInfo *scInfoApp = objc_getAssociatedObject(self, "currentImportApp");
  if (scInfoApp) {
    // SC_Info 导入模式
    BOOL accessing = [url startAccessingSecurityScopedResource];

    NSString *sourcePath = url.path;
    NSFileManager *fm = [NSFileManager defaultManager];

    // 检查是否是有效的 SC_Info 目录
    NSArray *files = [fm contentsOfDirectoryAtPath:sourcePath error:nil];
    BOOL hasSinf = NO;
    for (NSString *file in files) {
      if ([file.pathExtension isEqualToString:@"sinf"] ||
          [file.pathExtension isEqualToString:@"supp"]) {
        hasSinf = YES;
        break;
      }
    }

    if (!hasSinf) {
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:@"❌ 无效的 SC_Info 目录"
                           message:
                               @"选择的文件夹不包含有效的 FairPlay 授权文件 "
                               @"(.sinf, .supp)。\n\n"
                               @"请选择包含应用 SC_Info 文件的目录。"
                    preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                style:UIAlertActionStyleDefault
                                              handler:nil]];
      [self presentViewController:alert animated:YES completion:nil];

      if (accessing)
        [url stopAccessingSecurityScopedResource];
      objc_setAssociatedObject(self, "currentImportApp", nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      return;
    }

    // 复制文件到临时目录
    NSString *tempDir =
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"SCInfoImport"];
    [fm removeItemAtPath:tempDir error:nil];
    [fm createDirectoryAtPath:tempDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];

    for (NSString *file in files) {
      NSString *srcPath = [sourcePath stringByAppendingPathComponent:file];
      NSString *dstPath = [tempDir stringByAppendingPathComponent:file];
      [fm copyItemAtPath:srcPath toPath:dstPath error:nil];
    }

    if (accessing)
      [url stopAccessingSecurityScopedResource];

    // 执行导入
    [self doImportSCInfoFromPath:tempDir toApp:scInfoApp];
    objc_setAssociatedObject(self, "currentImportApp", nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return;
  }

  // 普通 IPA 导入模式
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *importDir =
      [docsDir stringByAppendingPathComponent:@"ImportedIPAs"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:importDir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:importDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  NSString *destPath =
      [importDir stringByAppendingPathComponent:url.lastPathComponent];
  [[NSFileManager defaultManager] copyItemAtURL:url
                                          toURL:[NSURL fileURLWithPath:destPath]
                                          error:nil];

  [self loadDownloadedIPAs];
  [self showInstallOptionsForPath:destPath isURL:NO];
}

#pragma mark - Installation Logic

- (void)showInstallOptionsForPath:(NSString *)path isURL:(BOOL)isURL {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"安装选项"
                       message:path.lastPathComponent
                preferredStyle:UIAlertControllerStyleActionSheet];

  // 普通安装 (User) - Hidden by User Request
  /*
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"普通安装 (User)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 [self installIPA:path
                                     registrationType:@"User"
                                       customBundleId:nil];
                               }]];
  */

  // 普通安装 (System) - Hidden by User Request
  /*
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"普通安装 (System)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 [self installIPA:path
                                     registrationType:@"System"
                                       customBundleId:nil];
                               }]];
  */
  /*
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"普通安装 (User)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self installIPA:path
                                     registrationType:@"User"
                                       customBundleId:nil];
                               }]];
  */

  // 普通安装 (User) - Replaces "TrollStore 安装"
  [alert addAction:[UIAlertAction actionWithTitle:@"安装User"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self installIPA:path
                                                registrationType:@"User"
                                                  customBundleId:nil];
                                          }]];

  // 普通安装 (System) - New Button
  [alert addAction:[UIAlertAction actionWithTitle:@"安装System"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self installIPA:path
                                                registrationType:@"System"
                                                  customBundleId:nil];
                                          }]];

  // 原包安装 (Original - Installd) - New Feature
  // 原包安装 (Original - Installd) - New Feature
  [alert addAction:[UIAlertAction actionWithTitle:@"原包安装 (Original)"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self installOriginalIPA:path];
                                          }]];

  // 注入安装 (System) - 修改主程序
  [alert addAction:[UIAlertAction actionWithTitle:@"注入并安装 (主程序)"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            [self installIPAWithInjection:path useFrameworkInjection:NO];
                                          }]];

  // 注入安装 (方案C) - 新功能：注入 Framework 并安装
  [alert addAction:[UIAlertAction actionWithTitle:@"原版注入安装 (方案C)"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            [self installIPAWithInjection:path useFrameworkInjection:YES];
                                          }]];

  // 分身安装 (User) - Hidden by User Request
  /*
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"分身安装 (User)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self showCloneInstallAlertForPath:path
                                                   registrationType:@"User"
                                                        skipSigning:NO];
                               }]];
  */

  // 分身安装 (System)
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"分身安装 (System)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self showCloneInstallAlertForPath:path
                                                   registrationType:@"System"
                                                        skipSigning:NO];
                               }]];

  // ===== 加密应用安装选项 (跳过签名，保留 FairPlay) =====
  // 加密安装 (User)
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"🔐 加密安装 (User)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self installIPAEncrypted:path
                                          registrationType:@"User"
                                            customBundleId:nil];
                               }]];

  // 加密安装 (System) - Hidden by User Request
  /*
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"🔐 加密安装 (System)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self installIPAEncrypted:path
                                          registrationType:@"System"
                                            customBundleId:nil];
                               }]];
  */

  // 删除文件
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"删除文件 (Delete)"
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [[NSFileManager defaultManager]
                                     removeItemAtPath:path
                                                error:nil];
                                 [self loadDownloadedIPAs];
                               }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  if (alert.popoverPresentationController) {
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2,
                   self.view.bounds.size.height / 2, 0, 0);
  }

  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Original Install Helper

- (void)installOriginalIPA:(NSString *)path {
  NSLog(@"[ECAppList] installOriginalIPA called with path: %@", path);
  [TSPresentationDelegate setPresentationViewController:self];
  @try {
    NSLog(@"[ECAppList] Calling _performInstallIPA (Method 0 Direct)...");
    [self _performInstallIPA:path
            registrationType:@"System"
              customBundleId:nil
           customDisplayName:nil
          installationMethod:0];
    NSLog(@"[ECAppList] _performInstallIPA called successfully");
  } @catch (NSException *exception) {
    NSLog(@"[ECAppList] Exception: %@", exception);
  }
}

#pragma mark - Install with Injection

- (void)installIPAWithInjection:(NSString *)path useFrameworkInjection:(BOOL)useFrameworkInjection {
  // 1. 显示加载中
  UIAlertController *loadingAlert =
      [UIAlertController alertControllerWithTitle:@"正在读取 IPA..."
                                          message:@"正在解压并读取应用信息..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:loadingAlert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                 ^{
                   NSError *error = nil;
                   ECAppInjector *injector = [ECAppInjector sharedInstance];

                   // 2. 预解压 IPA
                   NSString *tempDir = [injector extractIPAToTemp:path
                                                            error:&error];

                   dispatch_async(dispatch_get_main_queue(),
                                  ^{
                                    [loadingAlert dismissViewControllerAnimated:
                                                      YES
                                                                     completion:^{
                                                                       if (!tempDir) {
                                                                         [self
                                                                             showErrorMessage:
                                                                                 error.localizedDescription
                                                                                     ?: @"IPA 读取失败"];
                                                                         return;
                                                                       }

                                                                       // 3.
                                                                       // 读取信息
                                                                       NSDictionary
                                                                           *info = [injector
                                                                               getAppInfoFromBundlePath:
                                                                                   tempDir];
                                                                       NSString *originalBundleId =
                                                                           info[@"CFBundleIdentifier"]
                                                                               ?: @"N/A";
                                                                       NSString *originalName =
                                                                           info[@"CFBundleDisplayName"]
                                                                               ?: @"Unknown";

                                                                       // 4.
                                                                       // 显示配置对话框
                                                                       // -
                                                                       // 简化版：只需输入编号
                                                                       UIAlertController *configDialog = [UIAlertController
                                                                           alertControllerWithTitle:
                                                                               @"🔄 分身配置"
                                                                                            message:
                                                                                                [NSString
                                                                                                    stringWithFormat:
                                                                                                        @"原 Bundle ID: %@\n原名称: %@\n\n"
                                                                                                        @"输入分身编号，系统自动配置隔离\n"
                                                                                                        @"留空或输入0表示保持原 App 信息",
                                                                                                        originalBundleId,
                                                                                                        originalName]
                                                                                     preferredStyle:
                                                                                         UIAlertControllerStyleAlert];

                                                                       [configDialog addTextFieldWithConfigurationHandler:^(
                                                                                         UITextField
                                                                                             *textField) {
                                                                         textField
                                                                             .placeholder =
                                                                             @"分身编号（如 1, 2, 8）或留空";
                                                                         textField
                                                                             .text =
                                                                             @"";
                                                                         textField
                                                                             .keyboardType =
                                                                             UIKeyboardTypeNumberPad;
                                                                         textField
                                                                             .autocapitalizationType =
                                                                             UITextAutocapitalizationTypeNone;
                                                                         textField
                                                                             .autocorrectionType =
                                                                             UITextAutocorrectionTypeNo;
                                                                       }];

                                                                       [configDialog
                                                                           addAction:
                                                                               [UIAlertAction
                                                                                   actionWithTitle:
                                                                                       @"取消"
                                                                                             style:
                                                                                                 UIAlertActionStyleCancel
                                                                                           handler:^(
                                                                                               UIAlertAction
                                                                                                   *_Nonnull action) {
                                                                                             // 取消时清理临时文件
                                                                                             [[NSFileManager
                                                                                                 defaultManager]
                                                                                                 removeItemAtPath:
                                                                                                     tempDir
                                                                                                            error:
                                                                                                                nil];
                                                                                           }]];

                                                                       __weak typeof(self)
                                                                           weakSelf =
                                                                               self;
                                                                       [configDialog
                                                                           addAction:[UIAlertAction
                                                                                         actionWithTitle:
                                                                                             @"下一步 (配置伪装)"
                                                                                                   style:
                                                                                                       UIAlertActionStyleDefault
                                                                                                 handler:
                                                                                                     ^(UIAlertAction
                                                                                                           *action) {
                                                                                                       NSString *cloneNumber =
                                                                                                           configDialog
                                                                                                               .textFields
                                                                                                                   [0]
                                                                                                               .text;

                                                                                                       NSString
                                                                                                           *customBundleId =
                                                                                                               nil;
                                                                                                       NSString
                                                                                                           *customDisplayName =
                                                                                                               nil;

                                                                                                       // 如果输入了有效的编号，自动生成
                                                                                                       if (cloneNumber
                                                                                                                   .length >
                                                                                                               0 &&
                                                                                                           [cloneNumber
                                                                                                               integerValue] >
                                                                                                               0) {
                                                                                                         // 自动生成 Bundle ID: com.zhiliaoapp.musically -> com.zhiliaoapp.musically8
                                                                                                         customBundleId = [NSString
                                                                                                             stringWithFormat:
                                                                                                                 @"%@%@",
                                                                                                                 originalBundleId,
                                                                                                                 cloneNumber];
                                                                                                         // 自动生成显示名称: TikTok -> TikTok 8
                                                                                                         customDisplayName = [NSString
                                                                                                             stringWithFormat:
                                                                                                                 @"%@ %@",
                                                                                                                 originalName,
                                                                                                                 cloneNumber];

                                                                                                         NSLog(
                                                                                                             @"[注入安装] 分身编号=%@, Bundle ID=%@, 名称=%@",
                                                                                                             cloneNumber,
                                                                                                             customBundleId,
                                                                                                             customDisplayName);
                                                                                                       } else {
                                                                                                         NSLog(
                                                                                                             @"[注入安装] 保持原 App 信息");
                                                                                                       }

                                                                                                       // 弹出设备伪装配置页面
                                                                                                       [weakSelf
                                                                                                           showDeviceSpoofConfigForPath:
                                                                                                               path
                                                                                                                         customBundleId:
                                                                                                                             customBundleId
                                                                                                                      customDisplayName:
                                                                                                                          customDisplayName
                                                                                                                       workingDirectory:
                                                                                                                           tempDir
                                                                                                                   useFrameworkInjection:
                                                                                                                        useFrameworkInjection];
                                                                                                     }]];

                                                                       // 高级选项：手动输入
                                                                       // Bundle
                                                                       // ID
                                                                       // 和名称
                                                                       [configDialog
                                                                           addAction:
                                                                               [UIAlertAction
                                                                                   actionWithTitle:
                                                                                       @"高级..."
                                                                                             style:
                                                                                                 UIAlertActionStyleDefault
                                                                                           handler:^(
                                                                                               UIAlertAction
                                                                                                   *action) {
                                                                                             [weakSelf
                                                                                                 showAdvancedInjectionConfigForPath:
                                                                                                     path
                                                                                                                   originalBundleId:
                                                                                                                       originalBundleId
                                                                                                                       originalName:
                                                                                                                           originalName
                                                                                                                   workingDirectory:
                                                                                                                       tempDir
                                                                                                              useFrameworkInjection:
                                                                                                                   useFrameworkInjection];
                                                                                           }]];

                                                                       [self
                                                                           presentViewController:
                                                                               configDialog
                                                                                        animated:
                                                                                            YES
                                                                                      completion:
                                                                                          nil];
                                                                     }];
                                  });
                 });
}

// 高级注入安装配置 - 手动输入 Bundle ID 和名称
- (void)showAdvancedInjectionConfigForPath:(NSString *)path
                          originalBundleId:(NSString *)originalBundleId
                              originalName:(NSString *)originalName
                          workingDirectory:(NSString *)workingDirectory
                     useFrameworkInjection:(BOOL)useFrameworkInjection {
  UIAlertController *configDialog = [UIAlertController
      alertControllerWithTitle:@"🔧 高级配置"
                       message:@"手动设置 Bundle ID 和桌面名称"
                preferredStyle:UIAlertControllerStyleAlert];

  [configDialog addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"Bundle ID";
    textField.text = originalBundleId;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
  }];

  [configDialog addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"桌面显示名称";
    textField.text = originalName;
  }];

  [configDialog
      addAction:[UIAlertAction actionWithTitle:@"取消"
                                         style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action) {
                                         [[NSFileManager defaultManager]
                                             removeItemAtPath:workingDirectory
                                                        error:nil];
                                       }]];

  __weak typeof(self) weakSelf = self;
  [configDialog
      addAction:[UIAlertAction
                    actionWithTitle:@"下一步 (配置伪装)"
                              style:UIAlertActionStyleDefault
                            handler:^(UIAlertAction *action) {
                              NSString *customBundleId =
                                  configDialog.textFields[0].text;
                              NSString *customDisplayName =
                                  configDialog.textFields[1].text;

                              if (customBundleId.length == 0)
                                customBundleId = nil;
                              if (customDisplayName.length == 0)
                                customDisplayName = nil;

                              [weakSelf
                                  showDeviceSpoofConfigForPath:path
                                                customBundleId:customBundleId
                                             customDisplayName:customDisplayName
                                              workingDirectory:
                                                  workingDirectory
                                         useFrameworkInjection:
                                              useFrameworkInjection];
                            }]];

  [self presentViewController:configDialog animated:YES completion:nil];
}

// 显示设备伪装配置页面
- (void)showDeviceSpoofConfigForPath:(NSString *)path
                      customBundleId:(NSString *)customBundleId
                   customDisplayName:(NSString *)customDisplayName
                    workingDirectory:(NSString *)workingDirectory
               useFrameworkInjection:(BOOL)useFrameworkInjection {
  // 创建设备信息配置页面
  ECDeviceInfoViewController *configVC =
      [[ECDeviceInfoViewController alloc] init];
  configVC.title = @"配置伪装参数";
  configVC.isEditingMode = YES;

  // 关键：设置目标配置路径为工作目录中的 device.plist
  // 这样用户的设置会直接保存到目标 App 中
  NSString *payloadPath =
      [workingDirectory stringByAppendingPathComponent:@"Payload"];
  NSArray *payloadContents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadPath
                                                          error:nil];
  NSString *appBundleName = nil;
  for (NSString *item in payloadContents) {
    if ([item.pathExtension isEqualToString:@"app"]) {
      appBundleName = item;
      break;
    }
  }
  if (appBundleName) {
    NSString *appBundlePath =
        [payloadPath stringByAppendingPathComponent:appBundleName];

    // 确保 Frameworks 目录存在（用于保存配置）
    NSString *frameworksDir =
        [appBundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:frameworksDir]) {
      [fm createDirectoryAtPath:frameworksDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
      NSLog(@"[ECAppList] 创建 Frameworks 目录: %@", frameworksDir);
    }

    // 统一使用 Frameworks/device.plist 路径
    NSString *configPath =
        [appBundlePath stringByAppendingPathComponent:
                           @"Frameworks/com.apple.preferences.display.plist"];
    configVC.targetConfigPath = configPath;
    NSLog(@"[ECAppList] 配置将保存到: %@", configPath);
  }

  // 设置完成回调，用户点击保存后继续安装
  __weak typeof(self) weakSelf = self;
  configVC.completionBlock = ^{
    // 用户完成配置后，执行安装
    [weakSelf performInjectInstall:path
                    customBundleId:customBundleId
                 customDisplayName:customDisplayName
                  workingDirectory:workingDirectory
             useFrameworkInjection:useFrameworkInjection];
  };

  // 设置取消回调
  configVC.cancelBlock = ^{
    // 用户取消时，清理临时文件
    [[NSFileManager defaultManager] removeItemAtPath:workingDirectory
                                               error:nil];
  };

  // 使用导航控制器包装
  UINavigationController *navController =
      [[UINavigationController alloc] initWithRootViewController:configVC];
  navController.modalPresentationStyle = UIModalPresentationFullScreen;

  [self presentViewController:navController animated:YES completion:nil];
}

- (void)performInjectInstall:(NSString *)path
              customBundleId:(NSString *)customBundleId
           customDisplayName:(NSString *)customDisplayName
            workingDirectory:(NSString *)workingDirectory
       useFrameworkInjection:(BOOL)useFrameworkInjection {
  UIAlertController *progress =
      [UIAlertController alertControllerWithTitle:@"正在准备注入..."
                                          message:@"正在处理 IPA，请稍候..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progress animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    NSError *error = nil;
    // 1. Prepare IPA (使用预解压目录)
    NSString *preparedBundlePath = [[ECAppInjector sharedInstance]
        prepareIPAForInjection:path
                  manualTeamID:nil // Auto-detect from cert
                customBundleId:customBundleId
             customDisplayName:customDisplayName
              workingDirectory:workingDirectory
         useFrameworkInjection:useFrameworkInjection
                         error:&error];

    if (!preparedBundlePath) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [progress
            dismissViewControllerAnimated:YES
                               completion:^{
                                 [self
                                     showErrorMessage:error.localizedDescription
                                                          ?: @"IPA 处理失败"];
                               }];
      });
      return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
      progress.message = @"正在安装...";
    });

    // 2. Install the modified bundle using System registration
    // Note: We do NOT skip signing because signApp needs to iterate
    // through ALL binaries (frameworks, extensions) and apply CoreTrust
    // bypass. Only the main binary was signed by ECAppInjector.
    // Frameworks need signing too.
    int ret = [[TSApplicationsManager sharedInstance]
               installIpa:preparedBundlePath
                    force:YES
         registrationType:@"System"
           customBundleId:nil
        customDisplayName:nil
              skipSigning:NO // Let installApp sign ALL binaries including
                             // frameworks
                      log:nil];

    // 3. Cleanup is handled by ECAppInjector or we should do it here if
    // it returned a temp path For now assuming ECAppInjector returns a
    // path in NSTemporaryDirectory/CleanupLater

    dispatch_async(dispatch_get_main_queue(), ^{
      [progress
          dismissViewControllerAnimated:YES
                             completion:^{
                               if (ret == 0) {
                                 [self
                                     showSuccessMessage:@"注入并安装成功！\n请"
                                                        @"尝试启动应用。"];
                                 [self loadApps];
                               } else {
                                 [self
                                     showErrorMessage:
                                         [NSString stringWithFormat:
                                                       @"安装失败 (错误码: %d)",
                                                       ret]];
                               }
                             }];
    });
  });
}

#pragma mark - Clone Install Helper

- (void)showCloneInstallAlertForPath:(NSString *)path
                    registrationType:(NSString *)regType
                         skipSigning:(BOOL)skipSigning {
  // 先解析 IPA 获取原始包名和 APP 名字
  TSAppInfo *appInfo = [[TSAppInfo alloc] initWithIPAPath:path];
  [appInfo loadBasicInfoWithCompletion:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      NSString *originalBundleId =
          [appInfo bundleIdentifier] ?: @"com.example.app";
      NSString *originalDisplayName = [appInfo displayName] ?: @"App";

      // 生成默认分身值 - 简化版：只需输入编号
      UIAlertController *alert = [UIAlertController
          alertControllerWithTitle:skipSigning ? @"🔐 加密分身安装"
                                               : @"🔄 分身安装"
                           message:[NSString
                                       stringWithFormat:
                                           @"原始 Bundle ID: %@\n原始名称: "
                                           @"%@"
                                           @"\n\n只需输入分身编号，系统自动配置"
                                           @"隔离",
                                           originalBundleId,
                                           originalDisplayName]
                    preferredStyle:UIAlertControllerStyleAlert];

      // 分身编号输入框
      [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"分身编号（如 1, 2, 8）";
        textField.text = @"1";
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
      }];

      [alert
          addAction:
              [UIAlertAction
                  actionWithTitle:@"安装"
                            style:UIAlertActionStyleDefault
                          handler:^(UIAlertAction *action) {
                            NSString *cloneNumber = alert.textFields[0].text;

                            // 验证输入
                            if (cloneNumber.length == 0 ||
                                [cloneNumber integerValue] <= 0) {
                              cloneNumber = @"1";
                            }

                            // 自动生成 Bundle ID: com.zhiliaoapp.musically ->
                            // com.zhiliaoapp.musically8
                            NSString *customBundleId = [NSString
                                stringWithFormat:@"%@%@", originalBundleId,
                                                 cloneNumber];

                            // 自动生成显示名称: TikTok -> TikTok 8
                            NSString *customDisplayName = [NSString
                                stringWithFormat:@"%@ %@", originalDisplayName,
                                                 cloneNumber];

                            NSLog(@"[分身安装] 编号=%@, Bundle ID=%@, 名称=%@",
                                  cloneNumber, customBundleId,
                                  customDisplayName);

                            if (skipSigning) {
                              [self installIPAEncrypted:path
                                       registrationType:regType
                                         customBundleId:customBundleId
                                      customDisplayName:customDisplayName];
                            } else {
                              [self installIPA:path
                                   registrationType:regType
                                     customBundleId:customBundleId
                                  customDisplayName:customDisplayName];
                            }
                          }]];

      // 高级选项：手动输入
      [alert
          addAction:
              [UIAlertAction
                  actionWithTitle:@"高级..."
                            style:UIAlertActionStyleDefault
                          handler:^(UIAlertAction *action) {
                            // 显示高级输入对话框
                            [self
                                showAdvancedCloneInstallForPath:path
                                               registrationType:regType
                                                    skipSigning:skipSigning
                                               originalBundleId:originalBundleId
                                            originalDisplayName:
                                                originalDisplayName];
                          }]];

      [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                style:UIAlertActionStyleCancel
                                              handler:nil]];

      [self presentViewController:alert animated:YES completion:nil];
    });
  }];
}

// 高级分身安装 - 手动输入 Bundle ID 和名称
- (void)showAdvancedCloneInstallForPath:(NSString *)path
                       registrationType:(NSString *)regType
                            skipSigning:(BOOL)skipSigning
                       originalBundleId:(NSString *)originalBundleId
                    originalDisplayName:(NSString *)originalDisplayName {
  NSString *defaultCloneBundleId =
      [NSString stringWithFormat:@"%@.clone", originalBundleId];
  NSString *defaultCloneDisplayName =
      [NSString stringWithFormat:@"%@ 分身", originalDisplayName];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"🔧 高级分身安装"
                       message:@"手动设置 Bundle ID 和桌面名称"
                preferredStyle:UIAlertControllerStyleAlert];

  // 包名输入框
  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"Bundle ID";
    textField.text = defaultCloneBundleId;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
  }];

  // APP 名字输入框
  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"桌面显示名称";
    textField.text = defaultCloneDisplayName;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
  }];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"安装"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 NSString *customBundleId =
                                     alert.textFields[0].text;
                                 NSString *customDisplayName =
                                     alert.textFields[1].text;

                                 if (customBundleId.length == 0) {
                                   customBundleId = defaultCloneBundleId;
                                 }
                                 if (customDisplayName.length == 0) {
                                   customDisplayName = defaultCloneDisplayName;
                                 }

                                 if (skipSigning) {
                                   [self installIPAEncrypted:path
                                            registrationType:regType
                                              customBundleId:customBundleId
                                           customDisplayName:customDisplayName];
                                 } else {
                                   [self installIPA:path
                                        registrationType:regType
                                          customBundleId:customBundleId
                                       customDisplayName:customDisplayName];
                                 }
                               }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)installIPA:(NSString *)path
     registrationType:(NSString *)regType
       customBundleId:(NSString *)customBundleId
    customDisplayName:(NSString *)customDisplayName {
  [self installIPA:path
        registrationType:regType
          customBundleId:customBundleId
       customDisplayName:customDisplayName
      installationMethod:-1];
}

- (void)installIPA:(NSString *)path
      registrationType:(NSString *)regType
        customBundleId:(NSString *)customBundleId
     customDisplayName:(NSString *)customDisplayName
    installationMethod:(int)installationMethod {
  // Logic: "Ordinary Install (User)" -> Install as System first -> Then
  // switch to User This mimics official TrollStore behavior and avoids
  // permission issues during install
  if ([regType isEqualToString:@"User"]) {
    NSLog(@"[ECAppList] User registration requested. Parsing IPA to get Bundle "
          @"ID...");
    TSAppInfo *tempInfo = [[TSAppInfo alloc] initWithIPAPath:path];
    [tempInfo loadBasicInfoWithCompletion:^(NSError *error) {
      if (error) {
        NSLog(@"[ECAppList] Failed to parse IPA: %@", error);
        // Fallback to direct install (will likely default to System or fail
        // if User logic is broken in root helper)
        [self _performInstallIPA:path
                registrationType:regType
                  customBundleId:customBundleId
               customDisplayName:customDisplayName
              installationMethod:installationMethod];
        return;
      }

      NSString *targetBundleId = customBundleId ?: tempInfo.bundleIdentifier;
      NSLog(@"[ECAppList] Target Bundle ID: %@", targetBundleId);

      // Step 1: Install as System
      // NOTE: "User" install logic forces System first.
      // If installationMethod is provided (e.g. 0 for installd), we should
      // respect it? "installd" installs to /Applications? No, installd installs
      // to /var/containers/... If using installd (method 0), we probably don't
      // need the System->User switch hack? But the "Original Package Install"
      // uses method 0 (installd). installd handles permissions correctly. So if
      // method == 0, we might just want to call direct install? However, to be
      // safe and consistent, we can pass it down. But "System" registrationType
      // implies /Applications... If we use installd, we can't easily force
      // /Applications (System). installd installs as User by default unless
      // specialized entitled?

      // If installationMethod is 0 (installd), we should just install directly.
      if (installationMethod == 0) {
        [self _performInstallIPA:path
                registrationType:regType
                  customBundleId:customBundleId
               customDisplayName:customDisplayName
              installationMethod:installationMethod];
        return;
      }

      [self _performInstallIPA:path
              registrationType:@"System"
                customBundleId:customBundleId
             customDisplayName:customDisplayName
            installationMethod:installationMethod
                    completion:^(BOOL success) {
                      if (success) {
                        // Step 2: Switch to User
                        NSLog(@"[ECAppList] Install success. Switching %@ to "
                              @"User registration...",
                              targetBundleId);
                        [self _switchAppToUserRegistration:targetBundleId];
                      }
                    }];
    }];
  } else {
    [self _performInstallIPA:path
            registrationType:regType
              customBundleId:customBundleId
           customDisplayName:customDisplayName
          installationMethod:installationMethod];
  }
}

- (void)_performInstallIPA:(NSString *)path
          registrationType:(NSString *)regType
            customBundleId:(NSString *)customBundleId
         customDisplayName:(NSString *)customDisplayName {
  [self _performInstallIPA:path
          registrationType:regType
            customBundleId:customBundleId
         customDisplayName:customDisplayName
        installationMethod:-1];
}

- (void)_performInstallIPA:(NSString *)path
          registrationType:(NSString *)regType
            customBundleId:(NSString *)customBundleId
         customDisplayName:(NSString *)customDisplayName
                completion:(void (^)(BOOL success))completion {
  [self _performInstallIPA:path
          registrationType:regType
            customBundleId:customBundleId
         customDisplayName:customDisplayName
        installationMethod:-1
                completion:completion];
}

- (void)_performInstallIPA:(NSString *)path
          registrationType:(NSString *)regType
            customBundleId:(NSString *)customBundleId
         customDisplayName:(NSString *)customDisplayName
        installationMethod:(int)installationMethod {
  [self _performInstallIPA:path
          registrationType:regType
            customBundleId:customBundleId
         customDisplayName:customDisplayName
        installationMethod:installationMethod
                completion:nil];
}

- (void)_performInstallIPA:(NSString *)path
          registrationType:(NSString *)regType
            customBundleId:(NSString *)customBundleId
         customDisplayName:(NSString *)customDisplayName
        installationMethod:(int)installationMethod
                completion:(void (^)(BOOL success))completion {
    [TSInstallationController
      handleAppInstallFromFile:path
                  forceInstall:NO
              registrationType:regType
                customBundleId:customBundleId
             customDisplayName:customDisplayName
                   skipSigning:NO
            installationMethod:installationMethod
                    completion:^(BOOL success, NSError *error) {
                      // 清理 tmp 目录下的安装残留
                      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
                          NSFileManager *fm = [NSFileManager defaultManager];
                          NSString *tmpDir = NSTemporaryDirectory();
                          NSArray *tmpFiles = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
                          for (NSString *file in tmpFiles) {
                              NSString *fullPath = [tmpDir stringByAppendingPathComponent:file];
                              [fm removeItemAtPath:fullPath error:nil];
                          }
                          NSLog(@"[ECAppList] Auto-cleaned temporary installation files in %@", tmpDir);
                      });

                      if (success) {
                        if (completion) {
                          completion(YES);
                        }
                        [self loadApps];
                      } else {
                        if (completion) {
                          completion(NO);
                        }
                      }
                    }];
}

- (void)_switchAppToUserRegistration:(NSString *)bundleId {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Find app path
        NSArray *appPaths =
            [[TSApplicationsManager sharedInstance] installedAppPaths];
        NSString *targetPath = nil;

        for (NSString *path in appPaths) {
          NSBundle *bundle = [NSBundle bundleWithPath:path];
          if ([bundle.bundleIdentifier isEqualToString:bundleId]) {
            targetPath = path;
            break;
          }
        }

        if (targetPath) {
          int ret = [[TSApplicationsManager sharedInstance]
              changeAppRegistration:targetPath
                            toState:@"User"];
          if (ret == 0) {
            NSLog(@"[ECAppList] Successfully switched %@ to User.", bundleId);
            dispatch_async(dispatch_get_main_queue(), ^{
              [self loadApps]; // Reload to reflect status change
            });
          } else {
            NSLog(@"[ECAppList] Failed to switch to User. Error code: %d", ret);
            dispatch_async(dispatch_get_main_queue(), ^{
              UIAlertController *alert = [UIAlertController
                  alertControllerWithTitle:@"Warning"
                                   message:[NSString
                                               stringWithFormat:
                                                   @"App installed as System, "
                                                   @"but failed to switch to "
                                                   @"User registration (Code "
                                                   @"%d). You can manually "
                                                   @"switch it in App Details.",
                                                   ret]
                            preferredStyle:UIAlertControllerStyleAlert];
              [alert addAction:[UIAlertAction
                                   actionWithTitle:@"OK"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
              [self presentViewController:alert animated:YES completion:nil];
            });
          }
        } else {
          NSLog(@"[ECAppList] Could not find installed app path for %@",
                bundleId);
        }
      });
}

// 加密应用安装方法 (跳过签名保留 FairPlay 加密)
- (void)installIPAEncrypted:(NSString *)path
           registrationType:(NSString *)regType
             customBundleId:(NSString *)customBundleId {
  [self installIPAEncrypted:path
           registrationType:regType
             customBundleId:customBundleId
          customDisplayName:nil];
}

- (void)installIPAEncrypted:(NSString *)path
           registrationType:(NSString *)regType
             customBundleId:(NSString *)customBundleId
          customDisplayName:(NSString *)customDisplayName {
  [TSInstallationController
      handleAppInstallFromFile:path
                  forceInstall:NO
              registrationType:regType
                customBundleId:customBundleId
             customDisplayName:customDisplayName
                   skipSigning:YES
                    completion:^(BOOL success, NSError *error) {
                      if (success) {
                        [self loadApps];
                      }
                    }];
}

- (void)installIPA:(NSString *)path
    registrationType:(NSString *)regType
      customBundleId:(NSString *)customBundleId {
  [self installIPA:path
       registrationType:regType
         customBundleId:customBundleId
      customDisplayName:nil];
}

#pragma mark - App Management

- (void)showAppActions:(TSAppInfo *)app {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:app.displayName
                       message:app.bundleIdentifier
                preferredStyle:UIAlertControllerStyleActionSheet];

  // 1. 打开应用
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"打开 (Open)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [ECAppLauncher
                                     launchAppWithBundleIdentifier:
                                         app.bundleIdentifier
                                                    executablePath:nil];
                               }]];

  // 2. 注入管理
  ECAppInjector *injector = [ECAppInjector sharedInstance];
  ECInjectionStatus status = [injector injectionStatusForApp:app.bundlePath];

  if (status == ECInjectionStatusInjected) {
    [alert addAction:[UIAlertAction actionWithTitle:@"🔴 移除注入 / 卸载伪装"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                              [self ejectFromApp:app];
                                            }]];
  } else {
    [alert addAction:[UIAlertAction actionWithTitle:@"💉 注入伪装 dylib"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [self showInjectOptionsForApp:app];
                                            }]];
    // 即使检测为未注入，也提供强制卸载按钮作为兜底
    [alert addAction:[UIAlertAction actionWithTitle:@"🧹 强制卸载伪装 (恢复原版)"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
                                              [self ejectFromApp:app];
                                            }]];
  }

  // 3. ECMAIN 托管状态切换
  NSString *managedPlistPath = @"/var/mobile/Media/ECMAIN/managed_apps.plist";
  NSMutableArray *managedApps = [NSMutableArray arrayWithContentsOfFile:managedPlistPath] ?: [NSMutableArray array];
  BOOL isManaged = [managedApps containsObject:app.bundleIdentifier];

  [alert addAction:[UIAlertAction actionWithTitle:isManaged ? @"⛔️ 取消 ECMAIN 托管" : @"🛡️ 设为 ECMAIN 托管 (防重启丢失)"
                                            style:isManaged ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            if (isManaged) {
                                                [managedApps removeObject:app.bundleIdentifier];
                                            } else {
                                                [managedApps addObject:app.bundleIdentifier];
                                                // 如果目录不存在则创建
                                                [[NSFileManager defaultManager] createDirectoryAtPath:@"/var/mobile/Media/ECMAIN" withIntermediateDirectories:YES attributes:nil error:nil];
                                            }
                                            [managedApps writeToFile:managedPlistPath atomically:YES];
                                            UIAlertController *toast = [UIAlertController alertControllerWithTitle:@"设置成功" message:isManaged ? @"已取消托管，刷新时将不再强制保护此应用" : @"已设为托管，下次刷新应用将自动保护并可启动" preferredStyle:UIAlertControllerStyleAlert];
                                            [toast addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                                                [self.tableView reloadData];
                                            }]];
                                            [self presentViewController:toast animated:YES completion:nil];
                                          }]];

  // Debug: 手动检测注入状态
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"🔍 检测注入状态 (Debug)"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *action) {
                        ECInjectionStatus debugStatus =
                            [injector injectionStatusForApp:app.bundlePath];
                        NSString *statusStr =
                            (debugStatus == ECInjectionStatusInjected)
                                ? @"已注入 (Injected)"
                                : @"未注入 (Not Injected)";
                        UIAlertController *debugAlert = [UIAlertController
                            alertControllerWithTitle:@"状态检测"
                                             message:
                                                 [NSString
                                                     stringWithFormat:
                                                         @"当前检测结果:\n%@",
                                                         statusStr]
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];
                        [debugAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
                        [self presentViewController:debugAlert
                                           animated:YES
                                         completion:nil];
                      }]];

  // 3. 配置设备伪装
  [alert addAction:[UIAlertAction actionWithTitle:@"⚙️ 配置设备伪装"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self configureSpooferForApp:app];
                                          }]];

  // 4. 分身管理 - Hidden by User Request
  /*
  NSArray *cloneIds = [injector cloneIdsForApp:app.bundleIdentifier];
  NSString *cloneTitle =
      cloneIds.count > 0
          ? [NSString stringWithFormat:@"👥 分身管理 (%lu)",
                                       (unsigned long)cloneIds.count]
          : @"👥 创建分身";
  [alert addAction:[UIAlertAction actionWithTitle:cloneTitle
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self manageClonesForApp:app];
                                          }]];
  */

  // 5. 应用详情
  [alert addAction:[UIAlertAction actionWithTitle:@"ℹ️ 应用详情"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self showAppDetails:app];
                                          }]];

  // 5. 导出 IPA
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"导出 IPA (Export)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self exportApp:app];
                               }]];

  // 6. 脱壳并导出 (Decrypt & Export)
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"脱壳并导出 (Decrypt & Export)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self decryptAndExportApp:app];
                               }]];

  // 7. 越狱脱壳
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"越狱脱壳 (Jailbreak Decrypt)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self decryptAndExportAppJailbroken:app];
                               }]];

  // 8. 切换注册状态
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"切换到 System 注册"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self changeAppRegistration:app
                                                     toState:@"System"];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"切换到 User 注册"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self changeAppRegistration:app
                                                     toState:@"User"];
                               }]];

  // 9. 更多导出选项
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"📋 导出详细信息"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self exportAppDetailedInfo:app];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"📦 导出完整包 (含授权)"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self exportAppFullPackage:app];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"🔐 导出 SC_Info 授权"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self exportSCInfo:app];
                               }]];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"🔑 导入 SC_Info 授权"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self importSCInfo:app];
                               }]];

  // 10. 卸载应用
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"卸载应用 (Uninstall)"
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *_Nonnull action) {
                                 int ret =
                                     [[TSApplicationsManager sharedInstance]
                                         uninstallApp:app.bundleIdentifier];
                                 if (ret == 0) {
                                   [self loadApps];
                                 } else {
                                   NSString *errorStr = [NSString
                                       stringWithFormat:@"Error code: %d", ret];
                                   NSError *errObj =
                                       [[TSApplicationsManager sharedInstance]
                                           errorForCode:ret];
                                   if (errObj)
                                     errorStr = [errObj localizedDescription];
                                   [self showErrorMessage:errorStr];
                                 }
                               }]];

  // 11. 彻底卸载应用 (带数据抹除)
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"彻底卸载应用 (Uninstall & Wipe Data)"
                        style:UIAlertActionStyleDestructive
                      handler:^(UIAlertAction *_Nonnull action) {
                        // 先弹窗确认，因为这个操作不可逆
                        UIAlertController *confirmAlert = [UIAlertController
                            alertControllerWithTitle:@"警告"
                                             message:@"确定要彻底卸载该应用并抹"
                                                     @"除所有的 Keychain/沙盒 "
                                                     @"残留信息吗？\n\n此操作不"
                                                     @"可逆！"
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];

                        [confirmAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"确定"
                                              style:
                                                  UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction
                                                          *_Nonnull action) {
                                              // 1. 调用 wipe-app
                                              // 强制清除所有底层关联数据
                                              NSString *stdOut;
                                              NSString *stdErr;
                                              int wipeRet = spawnRoot(
                                                  rootHelperPath(),
                                                  @[
                                                    @"wipe-app",
                                                    app.bundleIdentifier ?: @""
                                                  ],
                                                  &stdOut, &stdErr);

                                              if (wipeRet != 0) {
                                                NSLog(
                                                    @"[ECAppList] WipeApp "
                                                    @"failed: Code %d, Err: %@",
                                                    wipeRet, stdErr);
                                              } else {
                                                NSLog(@"[ECAppList] WipeApp "
                                                      @"succeeded for %@",
                                                      app.bundleIdentifier);
                                              }

                                              // 2. 正常卸载本体包
                                              int ret = [[TSApplicationsManager
                                                  sharedInstance]
                                                  uninstallApp:
                                                      app.bundleIdentifier];
                                              if (ret == 0) {
                                                [self loadApps];
                                              } else {
                                                NSString *errorStr = [NSString
                                                    stringWithFormat:
                                                        @"Uninstall Error "
                                                        @"code: %d",
                                                        ret];
                                                NSError *errObj =
                                                    [[TSApplicationsManager
                                                        sharedInstance]
                                                        errorForCode:ret];
                                                if (errObj)
                                                  errorStr = [errObj
                                                      localizedDescription];
                                                [self
                                                    showErrorMessage:errorStr];
                                              }
                                            }]];

                        [confirmAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
                        [self presentViewController:confirmAlert
                                           animated:YES
                                         completion:nil];
                      }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  if (alert.popoverPresentationController) {
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2,
                   self.view.bounds.size.height / 2, 0, 0);
  }

  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Decrypt Logic

- (void)decryptAndExportApp:(TSAppInfo *)app {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"脱壳并导出"
                       message:@"即将启动目标应用进行脱壳。\n应用可能会在前台"
                               @"闪现，请勿操作设备。\n\n这可能需要几秒钟。"
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"开始"
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self startDecryptProcess:app];
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)startDecryptProcess:(TSAppInfo *)app {
  // TrollStore 脱壳：使用 launchd 启动应用 + task_for_pid 读取内存
  // 这种方式不需要越狱，只需要 TrollStore 提供的 entitlements

  UIAlertController *progressAlert =
      [UIAlertController alertControllerWithTitle:@"正在脱壳..."
                                          message:@"正在启动应用..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progressAlert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   NSFileManager *fm = [NSFileManager defaultManager];

                   // 日志辅助 block - 使用 ECLogManager 以便在仪表盘显示
                   void (^writeLog)(NSString *) = ^(NSString *msg) {
                     [[ECLogManager sharedManager]
                         log:@"[TrollStore脱壳] %@", msg];
                     ECDecryptLog(@"[TrollStore脱壳] %@", msg);
                   };

                   // 更新进度的 block
                   void (^updateProgress)(NSString *) = ^(NSString *msg) {
                     dispatch_async(dispatch_get_main_queue(), ^{
                       progressAlert.message = msg;
                     });
                   };

                   // 清空日志文件
                   ECDecryptLogClear();

                   writeLog(@"========== TrollStore 脱壳开始 ==========");
                   writeLog([NSString stringWithFormat:@"目标应用: %@ (%@)",
                                                       app.displayName,
                                                       app.bundleIdentifier]);
                   writeLog([NSString
                       stringWithFormat:@"Bundle路径: %@", app.bundlePath]);

                   // 获取可执行文件路径
                   NSString *binaryPath = [ECAppLauncher
                       executablePathForAppAtPath:app.bundlePath];
                   NSString *executableName = [binaryPath lastPathComponent];

                   writeLog([NSString
                       stringWithFormat:@"可执行文件: %@", executableName]);
                   writeLog([NSString
                       stringWithFormat:@"Binary路径: %@", binaryPath]);

                   // 检查文件是否存在
                   if (![fm fileExistsAtPath:binaryPath]) {
                     writeLog(@"错误: 可执行文件不存在!");
                     dispatch_async(dispatch_get_main_queue(), ^{
                       [progressAlert
                           dismissViewControllerAnimated:YES
                                              completion:^{
                                                [self showErrorMessage:
                                                          @"可执行文件不存在"];
                                              }];
                     });
                     return;
                   }

                   // 1. 使用 launchd 启动应用
                   writeLog(@"正在通过 launchd 启动应用...");
                   updateProgress(@"正在通过 launchd 启动应用...");

                   LaunchdResponse_t response = [ECAppLauncher
                       launchAppWithBundleIdentifier:app.bundleIdentifier
                                      executablePath:binaryPath];

                   writeLog([NSString
                       stringWithFormat:@"launchd 响应: pid=%d, job_state=%lu",
                                        response.pid,
                                        (unsigned long)response.job_state]);

                   if (response.pid == -1) {
                     writeLog(@"错误: launchd 启动应用失败!");
                     writeLog(@"可能原因: ");
                     writeLog(@"  1. 缺少必要的 entitlements");
                     writeLog(@"  2. 应用未正确安装");
                     writeLog(@"  3. launchd 拒绝提交任务");
                     dispatch_async(dispatch_get_main_queue(), ^{
                       [progressAlert
                           dismissViewControllerAnimated:YES
                                              completion:^{
                                                [self showErrorMessage:
                                                          @"无法通过 launchd "
                                                          @"启动应用。\n\n请"
                                                          @"查看"
                                                          @"仪"
                                                          @"表盘日志获取详情"
                                                          @"。"];
                                              }];
                     });
                     return;
                   }

                   pid_t pid = response.pid;
                   writeLog(
                       [NSString stringWithFormat:@"应用已启动, PID: %d", pid]);

                   // 等待应用初始化
                   [NSThread sleepForTimeInterval:2.0];

                   // 2. 获取 task port (TrollStore entitlements 提供此权限)
                   updateProgress(@"正在获取进程控制权...");
                   mach_port_t task = MACH_PORT_NULL;
                   kern_return_t kr =
                       task_for_pid(mach_task_self(), pid, &task);

                   if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
                     kill(pid, SIGKILL);
                     writeLog(
                         [NSString stringWithFormat:
                                       @"错误: task_for_pid 失败: %s (kr=%d)",
                                       mach_error_string(kr), kr]);
                     writeLog(@"可能原因: 缺少 task_for_pid-allow entitlement");
                     dispatch_async(dispatch_get_main_queue(), ^{
                       [progressAlert
                           dismissViewControllerAnimated:YES
                                              completion:^{
                                                [self showErrorMessage:
                                                          @"task_for_pid "
                                                          @"失败。\n\n请检查:"
                                                          @"\n1."
                                                          @" "
                                                          @"应用是否通过 "
                                                          @"TrollStore "
                                                          @"安装\n2. "
                                                          @"entitlements "
                                                          @"是否包含 "
                                                          @"task_for_pid-"
                                                          @"allow"];
                                              }];
                     });
                     return;
                   }

                   writeLog([NSString
                       stringWithFormat:@"成功获取 task port: %d", task]);

                   // 3. 读取主程序内存信息
                   writeLog(@"正在读取主程序内存信息...");
                   updateProgress(@"正在读取内存信息...");
                   MainImageInfo_t mainInfo = imageInfoForPIDWithRetry(
                       binaryPath.UTF8String, task, pid);

                   if (!mainInfo.ok) {
                     kill(pid, SIGKILL);
                     dispatch_async(dispatch_get_main_queue(), ^{
                       [progressAlert
                           dismissViewControllerAnimated:YES
                                              completion:^{
                                                [self showErrorMessage:
                                                          @"无法找到主程序内存"
                                                          @"基地址"];
                                              }];
                     });
                     return;
                   }

                   writeLog(
                       [NSString stringWithFormat:@"主程序加载地址: 0x%llx",
                                                  mainInfo.loadAddress]);

                   // 4. 读取加密信息
                   struct encryption_info_command encInfo;
                   uint64_t loadCmdAddr = 0;
                   BOOL foundEnc = NO;

                   if (!readEncryptionInfo(task, mainInfo.loadAddress, &encInfo,
                                           &loadCmdAddr, &foundEnc)) {
                     kill(pid, SIGKILL);
                     dispatch_async(dispatch_get_main_queue(), ^{
                       [progressAlert
                           dismissViewControllerAnimated:YES
                                              completion:^{
                                                [self showErrorMessage:
                                                          @"无法读取加密信息"];
                                              }];
                     });
                     return;
                   }

                   // 检查是否需要脱壳
                   BOOL needsDecryption = (foundEnc && encInfo.cryptid != 0);
                   NSLog(@"[TrollStore Decrypt] cryptid=%d, needsDecryption=%d",
                         encInfo.cryptid, needsDecryption);

                   // 5. 创建临时目录和目标路径
                   NSString *tempDir = [NSTemporaryDirectory()
                       stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
                   NSString *payloadDir =
                       [tempDir stringByAppendingPathComponent:@"Payload"];
                   [fm createDirectoryAtPath:payloadDir
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:nil];

                   NSString *destAppPath = [payloadDir
                       stringByAppendingPathComponent:app.bundlePath
                                                          .lastPathComponent];
                   [fm copyItemAtPath:app.bundlePath
                               toPath:destAppPath
                                error:nil];

                   NSString *destBinaryPath = [destAppPath
                       stringByAppendingPathComponent:executableName];

                   // 6. 脱壳主程序
                   if (needsDecryption) {
                     updateProgress(@"正在脱壳主程序...");
                     NSString *decryptedPath = [tempDir
                         stringByAppendingPathComponent:@"decrypted_main"];

                     BOOL success = rebuildDecryptedImageAtPath(
                         binaryPath, task, mainInfo.loadAddress, &encInfo,
                         loadCmdAddr, decryptedPath);
                     if (success) {
                       [fm removeItemAtPath:destBinaryPath error:nil];
                       [fm copyItemAtPath:decryptedPath
                                   toPath:destBinaryPath
                                    error:nil];
                       chmod(destBinaryPath.UTF8String, 0755);
                       [fm removeItemAtPath:decryptedPath error:nil];
                       NSLog(@"[TrollStore Decrypt] Main binary decrypted "
                             @"successfully");
                     } else {
                       NSLog(@"[TrollStore Decrypt] Failed to decrypt main "
                             @"binary");
                     }
                   }

                   // 7. 脱壳 Frameworks (使用已运行的进程)
                   NSString *frameworksPath = [destAppPath
                       stringByAppendingPathComponent:@"Frameworks"];
                   if ([fm fileExistsAtPath:frameworksPath]) {
                     updateProgress(@"正在脱壳 Frameworks...");
                     NSString *frameworksPrefix = [app.bundlePath
                         stringByAppendingPathComponent:@"Frameworks"];
                     NSArray *items =
                         [fm contentsOfDirectoryAtPath:frameworksPath
                                                 error:nil];

                     for (NSString *item in items) {
                       NSString *fwExecName = nil;
                       NSString *fwBinaryPath = nil;
                       NSString *originalFwPath = nil;

                       if ([item hasSuffix:@".framework"]) {
                         fwExecName = [item stringByDeletingPathExtension];
                         fwBinaryPath = [[frameworksPath
                             stringByAppendingPathComponent:item]
                             stringByAppendingPathComponent:fwExecName];
                         originalFwPath = [[frameworksPrefix
                             stringByAppendingPathComponent:item]
                             stringByAppendingPathComponent:fwExecName];
                       } else if ([item hasSuffix:@".dylib"]) {
                         fwExecName = item;
                         fwBinaryPath = [frameworksPath
                             stringByAppendingPathComponent:item];
                         originalFwPath = [frameworksPrefix
                             stringByAppendingPathComponent:item];
                       }

                       if (!fwBinaryPath || ![fm fileExistsAtPath:fwBinaryPath])
                         continue;

                       // 查找 Framework 在内存中的加载地址
                       uint64_t fwLoadAddress = 0;
                       NSString *foundPath = nil;
                       if (findImageLoadAddress(frameworksPrefix.UTF8String,
                                                fwExecName.UTF8String, task,
                                                pid, &fwLoadAddress,
                                                &foundPath) &&
                           fwLoadAddress != 0) {

                         struct encryption_info_command fwEncInfo;
                         uint64_t fwLoadCmdAddr = 0;
                         BOOL fwFoundEnc = NO;

                         if (readEncryptionInfo(task, fwLoadAddress, &fwEncInfo,
                                                &fwLoadCmdAddr, &fwFoundEnc) &&
                             fwFoundEnc && fwEncInfo.cryptid != 0) {

                           NSString *fwDecryptedPath = [tempDir
                               stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"fw_%@", item]];
                           if (rebuildDecryptedImageAtPath(
                                   originalFwPath, task, fwLoadAddress,
                                   &fwEncInfo, fwLoadCmdAddr,
                                   fwDecryptedPath)) {
                             [fm removeItemAtPath:fwBinaryPath error:nil];
                             [fm copyItemAtPath:fwDecryptedPath
                                         toPath:fwBinaryPath
                                          error:nil];
                             chmod(fwBinaryPath.UTF8String, 0755);
                             [fm removeItemAtPath:fwDecryptedPath error:nil];
                             NSLog(@"[TrollStore Decrypt] Framework decrypted: "
                                   @"%@",
                                   item);
                           }
                         }
                       }
                     }
                   }

                   // 7.3 脱壳 Watch App (如果存在)
                   NSString *watchPath =
                       [destAppPath stringByAppendingPathComponent:@"Watch"];
                   if ([fm fileExistsAtPath:watchPath]) {
                     writeLog(@"正在处理 Watch App...");
                     updateProgress(@"正在脱壳 Watch App...");

                     NSString *watchPrefix = [app.bundlePath
                         stringByAppendingPathComponent:@"Watch"];
                     NSArray *watchItems =
                         [fm contentsOfDirectoryAtPath:watchPath error:nil];

                     for (NSString *watchItem in watchItems) {
                       if (![watchItem hasSuffix:@".app"])
                         continue;

                       NSString *watchAppPath =
                           [watchPath stringByAppendingPathComponent:watchItem];
                       NSString *originalWatchAppPath = [watchPrefix
                           stringByAppendingPathComponent:watchItem];

                       // 获取 Watch App 的可执行文件名
                       NSString *watchInfoPlist = [watchAppPath
                           stringByAppendingPathComponent:@"Info.plist"];
                       NSDictionary *watchInfo = [NSDictionary
                           dictionaryWithContentsOfFile:watchInfoPlist];
                       NSString *watchExecName =
                           watchInfo[@"CFBundleExecutable"];
                       if (!watchExecName) {
                         watchExecName =
                             [watchItem stringByDeletingPathExtension];
                       }

                       writeLog(
                           [NSString stringWithFormat:@"  处理 Watch App: %@",
                                                      watchItem]);

                       // 处理 Watch App 主二进制
                       NSString *watchBinaryPath = [watchAppPath
                           stringByAppendingPathComponent:watchExecName];
                       NSString *originalWatchBinaryPath = [originalWatchAppPath
                           stringByAppendingPathComponent:watchExecName];

                       if ([fm fileExistsAtPath:watchBinaryPath]) {
                         uint64_t watchLoadAddress = 0;
                         NSString *foundPath = nil;

                         if (findImageLoadAddress(watchPrefix.UTF8String,
                                                  watchExecName.UTF8String,
                                                  task, pid, &watchLoadAddress,
                                                  &foundPath) &&
                             watchLoadAddress != 0) {

                           struct encryption_info_command watchEncInfo;
                           uint64_t watchLoadCmdAddr = 0;
                           BOOL watchFoundEnc = NO;

                           if (readEncryptionInfo(
                                   task, watchLoadAddress, &watchEncInfo,
                                   &watchLoadCmdAddr, &watchFoundEnc) &&
                               watchFoundEnc && watchEncInfo.cryptid != 0) {

                             NSString *watchDecryptedPath = [tempDir
                                 stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"watch_%@",
                                                                watchExecName]];

                             if (rebuildDecryptedImageAtPath(
                                     originalWatchBinaryPath, task,
                                     watchLoadAddress, &watchEncInfo,
                                     watchLoadCmdAddr, watchDecryptedPath)) {
                               [fm removeItemAtPath:watchBinaryPath error:nil];
                               [fm copyItemAtPath:watchDecryptedPath
                                           toPath:watchBinaryPath
                                            error:nil];
                               chmod(watchBinaryPath.UTF8String, 0755);
                               [fm removeItemAtPath:watchDecryptedPath
                                              error:nil];
                               writeLog([NSString
                                   stringWithFormat:
                                       @"    ✅ Watch App 主程序脱壳成功"]);
                             }
                           }
                         } else {
                           writeLog([NSString
                               stringWithFormat:
                                   @"    ⚠️ Watch App 未在内存中加载"]);
                         }
                       }

                       // 处理 Watch App 内的 Frameworks
                       NSString *watchFwPath = [watchAppPath
                           stringByAppendingPathComponent:@"Frameworks"];
                       if ([fm fileExistsAtPath:watchFwPath]) {
                         NSString *originalWatchFwPath = [originalWatchAppPath
                             stringByAppendingPathComponent:@"Frameworks"];
                         NSArray *watchFwItems =
                             [fm contentsOfDirectoryAtPath:watchFwPath
                                                     error:nil];

                         for (NSString *fwItem in watchFwItems) {
                           NSString *fwExecName = nil;
                           NSString *fwBinaryPath = nil;
                           NSString *originalFwPath = nil;

                           if ([fwItem hasSuffix:@".framework"]) {
                             fwExecName =
                                 [fwItem stringByDeletingPathExtension];
                             fwBinaryPath = [[watchFwPath
                                 stringByAppendingPathComponent:fwItem]
                                 stringByAppendingPathComponent:fwExecName];
                             originalFwPath = [[originalWatchFwPath
                                 stringByAppendingPathComponent:fwItem]
                                 stringByAppendingPathComponent:fwExecName];
                           } else if ([fwItem hasSuffix:@".dylib"]) {
                             fwExecName = fwItem;
                             fwBinaryPath = [watchFwPath
                                 stringByAppendingPathComponent:fwItem];
                             originalFwPath = [originalWatchFwPath
                                 stringByAppendingPathComponent:fwItem];
                           }

                           if (!fwBinaryPath ||
                               ![fm fileExistsAtPath:fwBinaryPath])
                             continue;

                           // 尝试脱壳
                           uint64_t fwLoadAddress = 0;
                           NSString *foundPath = nil;
                           if (findImageLoadAddress(
                                   originalWatchFwPath.UTF8String,
                                   fwExecName.UTF8String, task, pid,
                                   &fwLoadAddress, &foundPath) &&
                               fwLoadAddress != 0) {

                             struct encryption_info_command fwEncInfo;
                             uint64_t fwLoadCmdAddr = 0;
                             BOOL fwFoundEnc = NO;

                             if (readEncryptionInfo(task, fwLoadAddress,
                                                    &fwEncInfo, &fwLoadCmdAddr,
                                                    &fwFoundEnc) &&
                                 fwFoundEnc && fwEncInfo.cryptid != 0) {

                               NSString *fwDecryptedPath = [tempDir
                                   stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"watchfw_%@",
                                                                  fwItem]];

                               if (rebuildDecryptedImageAtPath(
                                       originalFwPath, task, fwLoadAddress,
                                       &fwEncInfo, fwLoadCmdAddr,
                                       fwDecryptedPath)) {
                                 [fm removeItemAtPath:fwBinaryPath error:nil];
                                 [fm copyItemAtPath:fwDecryptedPath
                                             toPath:fwBinaryPath
                                              error:nil];
                                 chmod(fwBinaryPath.UTF8String, 0755);
                                 [fm removeItemAtPath:fwDecryptedPath
                                                error:nil];
                                 writeLog([NSString
                                     stringWithFormat:@"    ✅ Watch Framework "
                                                      @"脱壳成功: %@",
                                                      fwItem]);
                               }
                             }
                           }
                         }
                       }

                       // 处理 Watch App 内的 PlugIns
                       NSString *watchPlugInsPath = [watchAppPath
                           stringByAppendingPathComponent:@"PlugIns"];
                       if ([fm fileExistsAtPath:watchPlugInsPath]) {
                         writeLog(
                             [NSString stringWithFormat:
                                           @"    Watch App 包含 "
                                           @"PlugIns，将在分阶段脱壳中处理"]);
                       }
                     }
                   }

                   // 7.5 检查是否有需要脱壳的 PlugIns (App Extensions)
                   NSString *plugInsPath =
                       [destAppPath stringByAppendingPathComponent:@"PlugIns"];
                   BOOL hasEncryptedExtensions = NO;
                   NSMutableArray *encryptedExtNames = [NSMutableArray array];

                   if ([fm fileExistsAtPath:plugInsPath]) {
                     writeLog(@"正在检查 PlugIns (App Extensions)...");
                     NSString *plugInsPrefix = [app.bundlePath
                         stringByAppendingPathComponent:@"PlugIns"];
                     NSArray *extensions =
                         [fm contentsOfDirectoryAtPath:plugInsPath error:nil];

                     for (NSString *extItem in extensions) {
                       if (![extItem hasSuffix:@".appex"])
                         continue;

                       NSString *extPath =
                           [plugInsPath stringByAppendingPathComponent:extItem];
                       NSString *extInfoPlist = [extPath
                           stringByAppendingPathComponent:@"Info.plist"];
                       NSDictionary *extInfo = [NSDictionary
                           dictionaryWithContentsOfFile:extInfoPlist];
                       NSString *extExecName = extInfo[@"CFBundleExecutable"];

                       if (!extExecName) {
                         extExecName = [extItem stringByDeletingPathExtension];
                       }

                       NSString *originalExtPath = [[plugInsPrefix
                           stringByAppendingPathComponent:extItem]
                           stringByAppendingPathComponent:extExecName];

                       // 检查扩展是否加密
                       NSData *extData =
                           [NSData dataWithContentsOfFile:originalExtPath];
                       if (!extData ||
                           extData.length < sizeof(struct mach_header_64)) {
                         continue;
                       }

                       const uint8_t *bytes = extData.bytes;
                       BOOL isEncrypted = NO;

                       // 检查是否是 FAT binary
                       const struct fat_header *fatHeader =
                           (const struct fat_header *)bytes;
                       const uint8_t *machStart = bytes;

                       if (OSSwapBigToHostInt32(fatHeader->magic) ==
                               FAT_MAGIC ||
                           OSSwapBigToHostInt32(fatHeader->magic) ==
                               FAT_CIGAM) {
                         uint32_t nArch =
                             OSSwapBigToHostInt32(fatHeader->nfat_arch);
                         const struct fat_arch *archs =
                             (const struct fat_arch *)(bytes +
                                                       sizeof(
                                                           struct fat_header));
                         for (uint32_t i = 0; i < nArch; i++) {
                           cpu_type_t cputype =
                               OSSwapBigToHostInt32(archs[i].cputype);
                           if (cputype == CPU_TYPE_ARM64) {
                             uint32_t offset =
                                 OSSwapBigToHostInt32(archs[i].offset);
                             machStart = bytes + offset;
                             break;
                           }
                         }
                       }

                       const struct mach_header_64 *mh =
                           (const struct mach_header_64 *)machStart;
                       if (mh->magic == MH_MAGIC_64) {
                         const uint8_t *cmdPtr =
                             machStart + sizeof(struct mach_header_64);
                         for (uint32_t i = 0; i < mh->ncmds; i++) {
                           const struct load_command *lc =
                               (const struct load_command *)cmdPtr;
                           if (lc->cmd == LC_ENCRYPTION_INFO_64 ||
                               lc->cmd == LC_ENCRYPTION_INFO) {
                             const struct encryption_info_command *enc =
                                 (const struct encryption_info_command *)cmdPtr;
                             if (enc->cryptid != 0) {
                               isEncrypted = YES;
                             }
                             break;
                           }
                           cmdPtr += lc->cmdsize;
                         }
                       }

                       if (isEncrypted) {
                         hasEncryptedExtensions = YES;
                         [encryptedExtNames addObject:extItem];
                         writeLog([NSString
                             stringWithFormat:@"  发现加密扩展: %@", extItem]);
                       }
                     }
                   }

                   // 如果有加密的扩展，进入自动脱壳流程
                   if (hasEncryptedExtensions) {
                     writeLog(@"检测到加密的 App Extensions，准备自动启动...");
                     writeLog([NSString
                         stringWithFormat:@"需要脱壳的扩展: %@",
                                          [encryptedExtNames
                                              componentsJoinedByString:@", "]]);

                     // 保存状态到属性（需要在主线程）
                     dispatch_async(dispatch_get_main_queue(),
                                    ^{
                                      self.decryptingApp = app;
                                      self.decryptTempDir = tempDir;
                                      self.decryptDestAppPath = destAppPath;
                                      self.decryptTargetPID = pid;
                                      self.decryptTargetTask = task;
                                      self.runningExtensions =
                                          [NSMutableArray array];

                                      [progressAlert dismissViewControllerAnimated:
                                                         YES
                                                                        completion:^{
                                                                          // 显示自动脱壳提示
                                                                          UIAlertController *autoAlert = [UIAlertController
                                                                              alertControllerWithTitle:
                                                                                  @"正在自动脱壳扩展"
                                                                                               message:
                                                                                                   [NSString
                                                                                                       stringWithFormat:
                                                                                                           @"正在自动启动 %lu 个扩展进程...\n请稍候。",
                                                                                                           (unsigned long)encryptedExtNames
                                                                                                               .count]
                                                                                        preferredStyle:
                                                                                            UIAlertControllerStyleAlert];

                                                                          [self
                                                                              presentViewController:
                                                                                  autoAlert
                                                                                           animated:
                                                                                               YES
                                                                                         completion:
                                                                                             nil];

                                                                           // 使用递归顺序启动扩展，避免并发冲突
                                                                           [self launchExtensionsSequentially:encryptedExtNames
                                                                                                      atIndex:0
                                                                                                          app:app
                                                                                                    autoAlert:autoAlert
                                                                                                launchedCount:0
                                                                                                   totalCount:(int)encryptedExtNames.count
                                                                                                   completion:^{
                                                                                                     writeLog(@"所有扩展启动尝试完成，切换回主程序并脱壳...");
                                                                                                     // 切换回 ecmain 前台，确保脱壳操作在前台环境中执行
                                                                                                     [ECAppLauncher wakeScreenAndBringMainAppToFront];
                                                                                                     // 稍作延迟等待 ecmain 回到前台 (iOS 切换应用需要约1s)
                                                                                                     dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                                                                                                         dispatch_get_main_queue(), ^{
                                                                                                           [self continueDecryptExtensions];
                                                                                                         });
                                                                                                   }];
                                                                         }];
                                    });
                     return; // 返回，等待异步操作
                   }

                   // 没有加密扩展，直接完成
                   writeLog(@"没有需要脱壳的扩展，直接完成打包");

                   // 终止进程
                   kill(pid, SIGKILL);

                   // 8. 删除 SC_Info
                   NSString *scInfoPath =
                       [destAppPath stringByAppendingPathComponent:@"SC_Info"];
                   if ([fm fileExistsAtPath:scInfoPath]) {
                     [fm removeItemAtPath:scInfoPath error:nil];
                   }

                   // 9. 打包 IPA
                   updateProgress(@"正在打包 IPA...");
                   NSString *exportDocsDir =
                       [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                            NSUserDomainMask,
                                                            YES) firstObject];
                   NSString *exportDir =
                       [exportDocsDir stringByAppendingPathComponent:@"Export"];
                   [fm createDirectoryAtPath:exportDir
                       withIntermediateDirectories:YES
                                        attributes:nil
                                             error:nil];

                   NSString *ipaName = [NSString
                       stringWithFormat:@"%@_Decrypted.ipa", app.displayName];
                   NSString *ipaPath =
                       [exportDir stringByAppendingPathComponent:ipaName];

                   NSError *zipError = nil;
                   BOOL zipSuccess = [ZipWriter createIPAAtPath:ipaPath
                                                  fromAppBundle:destAppPath
                                                          error:&zipError];

                   // 清理临时目录
                   [fm removeItemAtPath:tempDir error:nil];

                   dispatch_async(dispatch_get_main_queue(), ^{
                     [progressAlert
                         dismissViewControllerAnimated:YES
                                            completion:^{
                                              if (zipSuccess) {
                                                UIAlertController *doneAlert = [UIAlertController
                                                    alertControllerWithTitle:
                                                        @"脱壳导出成功"
                                                                     message:
                                                                         [NSString
                                                                             stringWithFormat:
                                                                                 @"已保存至:"
                                                                                 @"\nDocuments"
                                                                                 @"/Export/%@",
                                                                                 ipaName]
                                                              preferredStyle:
                                                                  UIAlertControllerStyleAlert];
                                                [doneAlert
                                                    addAction:
                                                        [UIAlertAction
                                                            actionWithTitle:
                                                                @"确定"
                                                                      style:
                                                                          UIAlertActionStyleDefault
                                                                    handler:
                                                                        nil]];
                                                [self
                                                    presentViewController:
                                                        doneAlert
                                                                 animated:YES
                                                               completion:nil];
                                              } else {
                                                [self
                                                    showErrorMessage:
                                                        [NSString
                                                            stringWithFormat:
                                                                @"打包失败: "
                                                                @"%@",
                                                                zipError
                                                                    .localizedDescription]];
                                              }
                                            }];
                   });
                 });
}

#pragma mark - Extension Auto-Launch Helper

- (void)launchAppExtensionWithBundleIdentifier:(NSString *)bundleId
                                    completion:
                                        (void (^)(BOOL success))completion {
  void (^writeLog)(NSString *) = ^(NSString *msg) {
    ECDecryptLog(@"[NSExtension] %@", msg);
  };

  writeLog([NSString stringWithFormat:@"正在尝试唤醒扩展: %@", bundleId]);

  NSError *error = nil;
  NSExtension *extension =
      [NSExtension extensionWithIdentifier:bundleId error:&error];
  if (error || !extension) {
    writeLog([NSString stringWithFormat:@"❌ 找不到扩展对象: %@ (%@)", bundleId,
                                        error.localizedDescription]);
    if (completion)
      completion(NO);
    return;
  }

  @try {
    // 根据苹果官方文档，如果没有需要传递的 inputItems，必须传入 nil 而非空数组 @[] 或空的 NSExtensionItem，
    // 否则在部分特定类型的扩展（如 iMessage 扩展 TikTokMessageExtension）内部处理序列化时
    // 会抛出 `*** -[__NSDictionaryM setObject:forKey:]: key cannot be nil` 异常导致主应用崩溃。
    [extension beginExtensionRequestWithInputItems:nil
                                        completion:^(
                                            NSUUID *requestIdentifier,
                                            NSError *launchError) {
                                          if (launchError) {
                                            writeLog([NSString
                                                stringWithFormat:
                                                    @"❌ 启动请求失败: %@ (%@)",
                                                    bundleId,
                                                    launchError.localizedDescription]);
                                          } else {
                                            writeLog([NSString
                                                stringWithFormat:@"✅ 成功发送启动请求: %@",
                                                                 bundleId]);
                                          }
                                          if (completion)
                                            completion(launchError == nil);
                                        }];
  } @catch (NSException *exception) {
    writeLog([NSString stringWithFormat:@"⚠️ 启动时发生异常: %@", exception.reason]);
    if (completion)
      completion(NO);
  }
}

// 安全启动不兼容的扩展（iMessage、Widget 等）
// 策略：三层降级: PKHostPlugIn -> NSExtension._plugIn -> posix_spawn 直接拉起扩展可执行文件
- (void)launchUnsafeExtensionWithBundleIdentifier:(NSString *)bundleId
                                        extensionBinaryPath:(NSString *)extBinaryPath
                                        completion:
                                            (void (^)(BOOL success))completion {
  void (^writeLog)(NSString *) = ^(NSString *msg) {
    [[ECLogManager sharedManager] log:@"[NSExtension-Safe] %@", msg];
    ECDecryptLog(@"[NSExtension-Safe] %@", msg);
  };

  writeLog([NSString stringWithFormat:@"尝试安全启动不兼容扩展: %@", bundleId]);

  // 方案 1: PKHostPlugIn
  Class PKHostPlugInClass = NSClassFromString(@"PKHostPlugIn");
  if (PKHostPlugInClass) {
    SEL createSel = NSSelectorFromString(@"hostPlugInWithIdentifier:error:");
    if ([PKHostPlugInClass respondsToSelector:createSel]) {
      NSError *pkError = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      NSMethodSignature *sig = [PKHostPlugInClass methodSignatureForSelector:createSel];
      NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
      [inv setTarget:PKHostPlugInClass];
      [inv setSelector:createSel];
      [inv setArgument:&bundleId atIndex:2];
      [inv setArgument:&pkError atIndex:3];
      [inv invoke];
      __unsafe_unretained id plugIn = nil;
      [inv getReturnValue:&plugIn];
#pragma clang diagnostic pop
      if (plugIn && !pkError) {
        SEL beginSel = NSSelectorFromString(@"beginUsing");
        if ([plugIn respondsToSelector:beginSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
          [plugIn performSelector:beginSel];
#pragma clang diagnostic pop
          writeLog([NSString stringWithFormat:@"✅ PKHostPlugIn 启动成功: %@", bundleId]);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                SEL endSel = NSSelectorFromString(@"endUsing");
                if ([plugIn respondsToSelector:endSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                  [plugIn performSelector:endSel];
#pragma clang diagnostic pop
                }
                if (completion) completion(YES);
              });
          return;
        }
      }
    }
  }

  // 方案 2: NSExtension._plugIn
  NSError *error = nil;
  NSExtension *extension = [NSExtension extensionWithIdentifier:bundleId error:&error];
  if (extension) {
    SEL plugInSel = NSSelectorFromString(@"_plugIn");
    if ([extension respondsToSelector:plugInSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      id internalPlugIn = [extension performSelector:plugInSel];
#pragma clang diagnostic pop
      if (internalPlugIn) {
        SEL beginSel = NSSelectorFromString(@"beginUsing");
        if ([internalPlugIn respondsToSelector:beginSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
          [internalPlugIn performSelector:beginSel];
#pragma clang diagnostic pop
          writeLog([NSString stringWithFormat:@"✅ _plugIn.beginUsing 成功: %@", bundleId]);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                SEL endSel = NSSelectorFromString(@"endUsing");
                if ([internalPlugIn respondsToSelector:endSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                  [internalPlugIn performSelector:endSel];
#pragma clang diagnostic pop
                }
                if (completion) completion(YES);
              });
          return;
        }
      }
    }
  }

  // 方案 3 (最后保障): posix_spawn 直接拉起扩展进稌
  // 原理: 硬点启动扩展可执行文件，让 iOS 系统赋予进稌委码后再证明自身，不依赖 Extension Host 协议
  if (extBinaryPath && [[NSFileManager defaultManager] fileExistsAtPath:extBinaryPath]) {
    writeLog([NSString stringWithFormat:@"方案 3: posix_spawn 直接启动: %@", extBinaryPath.lastPathComponent]);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      pid_t extPid = 0;
      const char *argv[] = {extBinaryPath.UTF8String, NULL};
      const char *envp[] = {"HOME=/var/mobile", NULL};
      posix_spawnattr_t attr;
      posix_spawnattr_init(&attr);
      // 不使用 SUSPENDED 方式，让扩展进稌正常运行几秒让系统完成委托初始化
      int spawnRet = posix_spawn(&extPid, extBinaryPath.UTF8String, NULL, &attr, (char *const *)argv, (char *const *)envp);
      posix_spawnattr_destroy(&attr);
      dispatch_async(dispatch_get_main_queue(), ^{
        if (spawnRet == 0 && extPid > 0) {
          writeLog([NSString stringWithFormat:@"✅ posix_spawn 扩展成功, PID=%d: %@", extPid, bundleId]);
          // 让扩展进稌运行 2 秒再回调
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                if (completion) completion(YES);
              });
        } else {
          writeLog([NSString stringWithFormat:@"⚠️ posix_spawn 失败 (ret=%d): %@", spawnRet, bundleId]);
          if (completion) completion(NO);
        }
      });
    });
    return;
  }

  writeLog([NSString stringWithFormat:@"⚠️ 所有方案均失败: %@，将跳过该扩展脱壳", bundleId]);
  if (completion)
    completion(NO);
}

#pragma mark - Phased Decrypt Helper Methods

- (void)showContinueDecryptAlert {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"完成脱壳"
                       message:@"请确认您已经触发了需要的扩展功能。\n\n"
                               @"点击\"完成脱壳\"将扫描并脱壳已加载的扩展。"
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"完成脱壳"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self continueDecryptExtensions];
                                          }]];

  [alert
      addAction:[UIAlertAction
                    actionWithTitle:@"继续等待"
                              style:UIAlertActionStyleCancel
                            handler:^(UIAlertAction *action) {
                              // 再次显示此对话框
                              dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                           0.5 * NSEC_PER_SEC),
                                             dispatch_get_main_queue(), ^{
                                               [self showContinueDecryptAlert];
                                             });
                            }]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)continueDecryptExtensions {
  if (!self.decryptingApp || !self.decryptTempDir || !self.decryptDestAppPath) {
    [self showErrorMessage:@"脱壳状态丢失，请重新开始"];
    return;
  }

  UIAlertController *progressAlert =
      [UIAlertController alertControllerWithTitle:@"正在完成脱壳..."
                                          message:@"正在扫描扩展进程..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progressAlert animated:YES completion:nil];

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        TSAppInfo *app = self.decryptingApp;
        NSString *destAppPath = self.decryptDestAppPath;
        NSString *tempDir = self.decryptTempDir;

        void (^writeLog)(NSString *) = ^(NSString *msg) {
          [[ECLogManager sharedManager] log:@"[扩展脱壳] %@", msg];
          ECDecryptLog(@"[扩展脱壳] %@", msg);
        };

        void (^updateProgress)(NSString *) = ^(NSString *msg) {
          dispatch_async(dispatch_get_main_queue(), ^{
            progressAlert.message = msg;
          });
        };

        writeLog(@"========== 开始扫描和脱壳扩展 ==========");

        // 扫描运行中的扩展进程
        ExtensionProcessInfo_t *extProcesses = NULL;
        int extCount = 0;

        if (findRunningExtensionProcesses(app.bundlePath, &extProcesses,
                                          &extCount)) {
          writeLog([NSString
              stringWithFormat:@"找到 %d 个运行中的扩展进程", extCount]);

          NSString *plugInsPath =
              [destAppPath stringByAppendingPathComponent:@"PlugIns"];
          NSString *plugInsPrefix =
              [app.bundlePath stringByAppendingPathComponent:@"PlugIns"];

          for (int i = 0; i < extCount; i++) {
            ExtensionProcessInfo_t *info = &extProcesses[i];
            NSString *extBundleName =
                [NSString stringWithUTF8String:info->extBundleName];
            NSString *execName =
                [NSString stringWithUTF8String:info->executableName];

            writeLog([NSString stringWithFormat:@"处理扩展: %@ (PID=%d)",
                                                extBundleName, info->pid]);
            updateProgress(
                [NSString stringWithFormat:@"正在脱壳: %@", extBundleName]);

            // 构建路径
            NSString *originalExtPath =
                [[plugInsPrefix stringByAppendingPathComponent:extBundleName]
                    stringByAppendingPathComponent:execName];
            NSString *destExtPath =
                [[plugInsPath stringByAppendingPathComponent:extBundleName]
                    stringByAppendingPathComponent:execName];
            NSString *decryptedPath = [tempDir
                stringByAppendingPathComponent:[NSString
                                                   stringWithFormat:@"ext_%@",
                                                                    execName]];

            NSString *errorMsg = nil;
            if (decryptExtensionProcess(info->pid, originalExtPath,
                                        decryptedPath, &errorMsg)) {
              // 替换扩展二进制
              [fm removeItemAtPath:destExtPath error:nil];
              [fm copyItemAtPath:decryptedPath toPath:destExtPath error:nil];
              chmod(destExtPath.UTF8String, 0755);
              [fm removeItemAtPath:decryptedPath error:nil];
              writeLog([NSString
                  stringWithFormat:@"  ✅ 扩展脱壳成功: %@", extBundleName]);
            } else {
              writeLog([NSString stringWithFormat:@"  ⚠️ 扩展脱壳失败: %@ - %@",
                                                  extBundleName,
                                                  errorMsg ?: @"未知错误"]);
            }
          }

          if (extProcesses) {
            free(extProcesses);
          }
        } else {
          writeLog(@"扫描扩展进程失败");
        }

        // 终止目标进程
        if (self.decryptTargetPID > 0) {
          kill(self.decryptTargetPID, SIGKILL);
        }

        writeLog(@"扩展脱壳完成");

        // 完成打包
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert dismissViewControllerAnimated:YES
                                            completion:^{
                                              [self finishDecryptAndPackage];
                                            }];
        });
      });
}

- (void)finishDecryptAndPackage {
  if (!self.decryptTempDir || !self.decryptDestAppPath || !self.decryptingApp) {
    [self showErrorMessage:@"脱壳状态丢失"];
    [self clearDecryptState];
    return;
  }

  UIAlertController *progressAlert =
      [UIAlertController alertControllerWithTitle:@"正在打包..."
                                          message:@"正在生成 IPA 文件..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progressAlert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destAppPath = self.decryptDestAppPath;
    NSString *tempDir = self.decryptTempDir;
    TSAppInfo *app = self.decryptingApp;

    void (^writeLog)(NSString *) = ^(NSString *msg) {
      [[ECLogManager sharedManager] log:@"[打包] %@", msg];
      ECDecryptLog(@"[打包] %@", msg);
    };

    // 删除 SC_Info
    NSString *scInfoPath =
        [destAppPath stringByAppendingPathComponent:@"SC_Info"];
    if ([fm fileExistsAtPath:scInfoPath]) {
      [fm removeItemAtPath:scInfoPath error:nil];
      writeLog(@"已删除 SC_Info");
    }

    // 打包 IPA
    NSString *exportDocsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *exportDir =
        [exportDocsDir stringByAppendingPathComponent:@"Export"];
    [fm createDirectoryAtPath:exportDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];

    NSString *ipaName =
        [NSString stringWithFormat:@"%@_Decrypted.ipa", app.displayName];
    NSString *ipaPath = [exportDir stringByAppendingPathComponent:ipaName];

    // 自动记录 Team ID (在打包前记录)
    NSString *executableName = [[NSBundle bundleWithPath:destAppPath]
        infoDictionary][@"CFBundleExecutable"];
    if (executableName) {
      NSString *binaryPath =
          [destAppPath stringByAppendingPathComponent:executableName];
      writeLog(@"正在记录 Team ID...");
      if ([[ECAppInjector sharedInstance] saveTeamIDForBinary:binaryPath
                                                        error:nil]) {
        // 成功时已经在 saveTeamIDForBinary 里面打印了日志
        // 这里可以再确认一下
        writeLog(@"✅ Team ID 已保存到配置");
      } else {
        // 脱壳导出流程不需要重签，跳过重签直接打包
        // 原因: sign-binary 在大体积二进制上会耗时20+秒且经常失败, 而导出 IPA 本身不需要重签
        writeLog(@"⚠️ Team ID 提取失败, 跳过重签直接打包 (脱壳导出 IPA 不需要重签)");
      }
    }

    writeLog([NSString stringWithFormat:@"正在打包: %@", ipaName]);

    NSError *zipError = nil;
    BOOL zipSuccess = [ZipWriter createIPAAtPath:ipaPath
                                   fromAppBundle:destAppPath
                                           error:&zipError];

    // 清理临时目录
    [fm removeItemAtPath:tempDir error:nil];
    writeLog(@"已清理临时目录");

    // 清理状态
    dispatch_async(dispatch_get_main_queue(), ^{
      [self clearDecryptState];

      [progressAlert
          dismissViewControllerAnimated:YES
                             completion:^{
                               if (zipSuccess) {
                                 writeLog(
                                     [NSString stringWithFormat:@"打包成功: %@",
                                                                ipaPath]);

                                 UIAlertController *doneAlert = [UIAlertController
                                     alertControllerWithTitle:@"脱壳导出成功"
                                                      message:
                                                          [NSString
                                                              stringWithFormat:
                                                                  @"已保存至:"
                                                                  @"\nDocumen"
                                                                  @"ts"
                                                                  @"/Export/"
                                                                  @"%@",
                                                                  ipaName]
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];
                                 [doneAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"确定"
                                                       style:
                                                           UIAlertActionStyleDefault
                                                     handler:nil]];
                                 [self presentViewController:doneAlert
                                                    animated:YES
                                                  completion:nil];
                               } else {
                                 writeLog([NSString
                                     stringWithFormat:
                                         @"打包失败: %@",
                                         zipError.localizedDescription]);
                                 [self showErrorMessage:
                                           [NSString
                                               stringWithFormat:
                                                   @"打包失败: %@",
                                                   zipError
                                                       .localizedDescription]];
                               }
                             }];
    });
  });
}

- (void)clearDecryptState {
  self.decryptingApp = nil;
  self.decryptTempDir = nil;
  self.decryptDestAppPath = nil;
  self.decryptTargetPID = 0;
  self.decryptTargetTask = MACH_PORT_NULL;
  self.runningExtensions = nil;
}

#pragma mark - Jailbreak Decrypt Logic

- (void)decryptAndExportAppJailbroken:(TSAppInfo *)app {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"越狱脱壳"
                       message:@"此功能需要越狱环境。\n将以 root 权限启动目标应"
                               @"用进行脱壳。\n\n请确保设备已越狱。"
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"开始脱壳"
                                 style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *_Nonnull action) {
                                 [self startJailbrokenDecryptProcess:app];
                               }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)startJailbrokenDecryptProcess:(TSAppInfo *)app {
  // 显示进度
  UIAlertController *progressAlert =
      [UIAlertController alertControllerWithTitle:@"正在脱壳..."
                                          message:@"正在准备环境..."
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progressAlert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    // 共享目录和输出文件路径
    NSString *sharedDumpDir = @"/var/mobile/Documents/ECMAINDump";
    NSString *decryptedPath =
        [sharedDumpDir stringByAppendingPathComponent:@"decrypted.bin"];

    void (^writeLog)(NSString *) = ^(NSString *msg) {
      [[ECLogManager sharedManager] log:@"[脱壳] %@", msg];
      ECDecryptLog(@"[脱壳] %@", msg);
    };

    ECDecryptLogClear();

    writeLog(@"========== 越狱脱壳开始 (task_for_pid 方式) ==========");
    writeLog([NSString stringWithFormat:@"目标应用: %@ (%@)", app.displayName,
                                        app.bundleIdentifier]);
    writeLog([NSString stringWithFormat:@"Bundle路径: %@", app.bundlePath]);

    // 1. 确保共享目录存在
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:sharedDumpDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&dirError];
    writeLog([NSString stringWithFormat:@"共享目录: %@", sharedDumpDir]);

    // 清理旧文件
    [[NSFileManager defaultManager] removeItemAtPath:decryptedPath error:nil];
    writeLog(@"已清理旧的 decrypted.bin");

    // 2. 获取可执行文件路径
    NSDictionary *infoPlist = [NSDictionary
        dictionaryWithContentsOfFile:
            [app.bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *executableName = infoPlist[@"CFBundleExecutable"];
    if (!executableName) {
      executableName =
          app.bundlePath.lastPathComponent.stringByDeletingPathExtension;
    }
    NSString *binaryPath =
        [app.bundlePath stringByAppendingPathComponent:executableName];

    writeLog([NSString stringWithFormat:@"可执行文件: %@", executableName]);
    writeLog([NSString stringWithFormat:@"Binary路径: %@", binaryPath]);

    // 检查 binary 是否存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
      writeLog(
          [NSString stringWithFormat:@"错误: Binary 不存在: %@", binaryPath]);
      dispatch_async(dispatch_get_main_queue(), ^{
        [progressAlert
            dismissViewControllerAnimated:YES
                               completion:^{
                                 [self showErrorMessage:@"Binary 文件不存在"];
                               }];
      });
      return;
    }

    // 3. 读取磁盘上的原始二进制文件
    writeLog(@"读取原始二进制文件...");
    NSData *originalBinary = [NSData dataWithContentsOfFile:binaryPath];
    if (!originalBinary ||
        originalBinary.length < sizeof(struct mach_header_64)) {
      writeLog(@"错误: 无法读取二进制文件");
      dispatch_async(dispatch_get_main_queue(), ^{
        [progressAlert
            dismissViewControllerAnimated:YES
                               completion:^{
                                 [self showErrorMessage:@"无法读取二进制文件"];
                               }];
      });
      return;
    }
    writeLog([NSString stringWithFormat:@"二进制文件大小: %lu 字节",
                                        (unsigned long)originalBinary.length]);

    // 4. 解析 Mach-O 找到加密区域信息
    const uint8_t *fileBytes = (const uint8_t *)originalBinary.bytes;
    uint32_t magic = *(uint32_t *)fileBytes;

    // 处理 FAT binary - 找到 arm64 slice
    uint32_t archOffset = 0;
    if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
      writeLog(@"FAT binary detected, 寻找 arm64 切片...");
      struct fat_header *fatHeader = (struct fat_header *)fileBytes;
      uint32_t nArch = OSSwapBigToHostInt32(fatHeader->nfat_arch);
      struct fat_arch *arches =
          (struct fat_arch *)(fileBytes + sizeof(struct fat_header));

      for (uint32_t i = 0; i < nArch; i++) {
        cpu_type_t cpuType = OSSwapBigToHostInt32(arches[i].cputype);
        if (cpuType == CPU_TYPE_ARM64) {
          archOffset = OSSwapBigToHostInt32(arches[i].offset);
          writeLog([NSString
              stringWithFormat:@"找到 arm64 切片，偏移: 0x%x", archOffset]);
          break;
        }
      }
      if (archOffset == 0) {
        writeLog(@"错误: 未找到 arm64 切片");
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self showErrorMessage:@"未找到 arm64 切片"];
                                 }];
        });
        return;
      }
    }

    // 解析 mach_header_64
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)(fileBytes + archOffset);

    if (header->magic != MH_MAGIC_64) {
      writeLog(
          [NSString stringWithFormat:@"错误: 不是 64 位 Mach-O (magic=0x%x)",
                                     header->magic]);
      dispatch_async(dispatch_get_main_queue(), ^{
        [progressAlert
            dismissViewControllerAnimated:YES
                               completion:^{
                                 [self showErrorMessage:@"不支持的二进制格式"];
                               }];
      });
      return;
    }

    // 找到 LC_ENCRYPTION_INFO_64
    const uint8_t *cmdPtr = (const uint8_t *)(header + 1);
    uint32_t cryptoff = 0;
    uint32_t cryptsize = 0;
    uint32_t cryptid = 0;

    for (uint32_t i = 0; i < header->ncmds; i++) {
      const struct load_command *cmd = (const struct load_command *)cmdPtr;
      if (cmd->cmd == LC_ENCRYPTION_INFO_64) {
        const struct encryption_info_command_64 *encCmd =
            (const struct encryption_info_command_64 *)cmdPtr;
        cryptoff = encCmd->cryptoff;
        cryptsize = encCmd->cryptsize;
        cryptid = encCmd->cryptid;
        writeLog(
            [NSString stringWithFormat:@"LC_ENCRYPTION_INFO_64: cryptid=%u, "
                                       @"cryptoff=0x%x, cryptsize=0x%x",
                                       cryptid, cryptoff, cryptsize]);
        break;
      }
      cmdPtr += cmd->cmdsize;
    }

    // 标记是否需要脱壳
    BOOL needsDecryption = (cryptid != 0 && cryptoff != 0 && cryptsize != 0);

    if (cryptid == 0) {
      writeLog(@"Binary 未加密 (cryptid=0)，无需脱壳");
      // 直接复制文件
      [[NSFileManager defaultManager] copyItemAtPath:binaryPath
                                              toPath:decryptedPath
                                               error:nil];
    }

    if (needsDecryption) {
      if (cryptoff == 0 || cryptsize == 0) {
        writeLog(@"未找到加密信息");
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self showErrorMessage:@"未找到加密信息"];
                                 }];
        });
        return;
      }

      // 5. 启动目标应用（不注入 dylib）
      writeLog(@"启动目标应用...");
      dispatch_async(dispatch_get_main_queue(), ^{
        progressAlert.message = @"正在启动目标应用...";
      });

      pid_t pid;
      const char *argv[] = {binaryPath.UTF8String, NULL};
      // 设置最小环境，不注入任何 dylib
      const char *envp[] = {"HOME=/var/mobile", NULL};

      posix_spawnattr_t attr;
      posix_spawnattr_init(&attr);

      // 设置 POSIX_SPAWN_START_SUSPENDED 让进程启动后暂停
      short spawnFlags = POSIX_SPAWN_START_SUSPENDED;
      posix_spawnattr_setflags(&attr, spawnFlags);

      int spawnResult = posix_spawn(&pid, binaryPath.UTF8String, NULL, &attr,
                                    (char *const *)argv, (char *const *)envp);
      posix_spawnattr_destroy(&attr);

      writeLog([NSString
          stringWithFormat:@"posix_spawn 返回: %d, PID: %d", spawnResult, pid]);

      if (spawnResult != 0) {
        writeLog(
            [NSString stringWithFormat:@"错误: 无法启动目标应用，错误码: %d",
                                       spawnResult]);
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self showErrorMessage:
                                             [NSString
                                                 stringWithFormat:
                                                     @"启动应用失败 (错误:%d)",
                                                     spawnResult]];
                                 }];
        });
        return;
      }

      // 6. 恢复进程，等待 iOS 解密代码段到内存
      writeLog(@"恢复进程执行，等待解密...");
      kill(pid, SIGCONT);

      // 等待一段时间让应用启动并解密
      [NSThread sleepForTimeInterval:2.0];

      dispatch_async(dispatch_get_main_queue(), ^{
        progressAlert.message = @"正在读取解密数据...";
      });

      // 7. 使用 task_for_pid 获取目标进程的 task port
      writeLog(@"尝试获取 task port...");
      mach_port_t task = MACH_PORT_NULL;
      kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);

      writeLog([NSString stringWithFormat:@"task_for_pid 返回: %d (%s)", kr,
                                          mach_error_string(kr)]);

      if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
        // task_for_pid 失败，终止目标进程
        kill(pid, SIGKILL);
        writeLog(@"错误: task_for_pid 失败，无法读取目标进程内存");
        writeLog(@"可能原因: 缺少 task_for_pid-allow entitlement 或设备未越狱");
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self
                                       showErrorMessage:@"task_for_pid 失败\n\n"
                                                        @"可能原因:\n"
                                                        @"1. 设备未越狱\n"
                                                        @"2. 缺少 entitlement\n"
                                                        @"3. 系统安全策略限制"];
                                 }];
        });
        return;
      }

      writeLog(@"成功获取 task port，正在读取内存...");

      // 8. 使用 MemoryUtilities 进行解密
      writeLog(@"正在解析主程序内存信息...");
      MainImageInfo_t mainInfo =
          imageInfoForPIDWithRetry(binaryPath.UTF8String, task, pid);

      if (!mainInfo.ok) {
        kill(pid, SIGKILL);
        writeLog(@"错误: 无法找到主程序内存基地址");
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self showErrorMessage:
                                             @"无法找到主程序内存基地址"];
                                 }];
        });
        return;
      }

      writeLog([NSString
          stringWithFormat:@"主程序基地址: 0x%llu", mainInfo.loadAddress]);

      struct encryption_info_command encInfo;
      uint64_t loadCmdAddr = 0;
      BOOL foundEnc = NO;
      if (!readEncryptionInfo(task, mainInfo.loadAddress, &encInfo,
                              &loadCmdAddr, &foundEnc) ||
          !foundEnc) {
        kill(pid, SIGKILL);
        writeLog(@"错误: 无法读取加密信息或二进制未加密");
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self showErrorMessage:@"无法读取加密信息"];
                                 }];
        });
        return;
      }

      writeLog(@"正在重构并写入解密后的二进制...");
      BOOL rebuildSuccess =
          rebuildDecryptedImageAtPath(binaryPath, task, mainInfo.loadAddress,
                                      &encInfo, loadCmdAddr, decryptedPath);

      // Kill process
      kill(pid, SIGKILL);

      if (!rebuildSuccess) {
        writeLog(@"错误: 重构解密文件失败");
        dispatch_async(dispatch_get_main_queue(), ^{
          [progressAlert
              dismissViewControllerAnimated:YES
                                 completion:^{
                                   [self showErrorMessage:@"重构解密文件失败"];
                                 }];
        });
        return;
      }

      writeLog(@"脱壳成功！");
    } // end if (needsDecryption)

    // ========== 开始打包导出 ==========
    writeLog(@"========== 开始打包导出 ==========");
    dispatch_async(dispatch_get_main_queue(), ^{
      progressAlert.message =
          needsDecryption ? @"脱壳成功！正在打包 IPA..." : @"正在打包 IPA...";
    });

    // 创建临时导出目录
    NSString *tempDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
    NSString *payloadDir = [tempDir stringByAppendingPathComponent:@"Payload"];
    [[NSFileManager defaultManager] createDirectoryAtPath:payloadDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // 复制 .app 到 Payload
    NSString *destAppPath = [payloadDir
        stringByAppendingPathComponent:app.bundlePath.lastPathComponent];
    [[NSFileManager defaultManager] copyItemAtPath:app.bundlePath
                                            toPath:destAppPath
                                             error:nil];

    // 替换二进制文件
    NSString *destBinaryPath =
        [destAppPath stringByAppendingPathComponent:executableName];
    [[NSFileManager defaultManager] removeItemAtPath:destBinaryPath error:nil];
    [[NSFileManager defaultManager] copyItemAtPath:decryptedPath
                                            toPath:destBinaryPath
                                             error:nil];

    // 授予执行权限
    chmod(destBinaryPath.UTF8String, 0755);

    // ========== 脱壳 Frameworks ==========
    // 优化：只启动一次主应用进程，脱壳所有 Frameworks（Frameworks
    // 随主应用加载）
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *frameworksPath =
        [destAppPath stringByAppendingPathComponent:@"Frameworks"];
    if ([fm fileExistsAtPath:frameworksPath]) {
      writeLog(@"========== 开始脱壳 Frameworks ==========");
      dispatch_async(dispatch_get_main_queue(), ^{
        progressAlert.message = @"正在分析 Frameworks...";
      });

      NSArray *items = [fm contentsOfDirectoryAtPath:frameworksPath error:nil];

      // 第一阶段：收集所有需要脱壳的加密 Frameworks
      NSMutableArray<NSDictionary *> *encryptedFrameworks =
          [NSMutableArray array];

      for (NSString *item in items) {
        NSString *fullPath =
            [frameworksPath stringByAppendingPathComponent:item];
        NSString *fwBinaryPath = nil;
        NSString *originalFwBinaryPath = nil;
        NSString *fwExecName = nil;

        // 处理 .framework bundle
        if ([item hasSuffix:@".framework"]) {
          fwExecName = [item stringByDeletingPathExtension];
          fwBinaryPath = [fullPath stringByAppendingPathComponent:fwExecName];
          originalFwBinaryPath =
              [[app.bundlePath stringByAppendingPathComponent:@"Frameworks"]
                  stringByAppendingPathComponent:item];
          originalFwBinaryPath =
              [originalFwBinaryPath stringByAppendingPathComponent:fwExecName];
        }
        // 处理独立 .dylib
        else if ([item hasSuffix:@".dylib"]) {
          fwExecName = item;
          fwBinaryPath = fullPath;
          originalFwBinaryPath =
              [[app.bundlePath stringByAppendingPathComponent:@"Frameworks"]
                  stringByAppendingPathComponent:item];
        }

        if (!fwBinaryPath || ![fm fileExistsAtPath:fwBinaryPath]) {
          continue;
        }

        // 检查 Framework 是否加密
        NSData *fwData = [NSData dataWithContentsOfFile:originalFwBinaryPath];
        if (!fwData) {
          writeLog([NSString stringWithFormat:@"  无法读取原始 Framework: %@",
                                              originalFwBinaryPath]);
          continue;
        }

        // 解析 Framework 的加密信息
        const uint8_t *fwBytes = (const uint8_t *)fwData.bytes;
        uint32_t fwMagic = *(uint32_t *)fwBytes;
        uint32_t fwArchOffset = 0;

        // 处理 FAT binary
        if (fwMagic == FAT_MAGIC || fwMagic == FAT_CIGAM) {
          struct fat_header *fwFatHeader = (struct fat_header *)fwBytes;
          uint32_t fwNArch = OSSwapBigToHostInt32(fwFatHeader->nfat_arch);
          struct fat_arch *fwArches =
              (struct fat_arch *)(fwBytes + sizeof(struct fat_header));
          for (uint32_t i = 0; i < fwNArch; i++) {
            cpu_type_t fwCpuType = OSSwapBigToHostInt32(fwArches[i].cputype);
            if (fwCpuType == CPU_TYPE_ARM64) {
              fwArchOffset = OSSwapBigToHostInt32(fwArches[i].offset);
              break;
            }
          }
        }

        const struct mach_header_64 *fwHeader =
            (const struct mach_header_64 *)(fwBytes + fwArchOffset);
        if (fwHeader->magic != MH_MAGIC_64) {
          writeLog([NSString
              stringWithFormat:@"  跳过非 arm64 Framework: %@", item]);
          continue;
        }

        // 找 LC_ENCRYPTION_INFO_64
        const uint8_t *fwCmdPtr = (const uint8_t *)(fwHeader + 1);
        uint32_t fwCryptid = 0;
        for (uint32_t i = 0; i < fwHeader->ncmds; i++) {
          const struct load_command *fwCmd =
              (const struct load_command *)fwCmdPtr;
          if (fwCmd->cmd == LC_ENCRYPTION_INFO_64) {
            const struct encryption_info_command_64 *fwEncCmd =
                (const struct encryption_info_command_64 *)fwCmdPtr;
            fwCryptid = fwEncCmd->cryptid;
            break;
          }
          fwCmdPtr += fwCmd->cmdsize;
        }

        if (fwCryptid == 0) {
          writeLog([NSString
              stringWithFormat:@"  Framework 未加密，跳过: %@", item]);
          continue;
        }

        // 加入待脱壳列表
        [encryptedFrameworks addObject:@{
          @"item" : item,
          @"fwBinaryPath" : fwBinaryPath,
          @"originalFwBinaryPath" : originalFwBinaryPath,
          @"fwExecName" : fwExecName
        }];
        writeLog(
            [NSString stringWithFormat:@"  发现加密 Framework: %@ (cryptid=%u)",
                                       item, fwCryptid]);
      }

      // 第二阶段：如果有加密的 Frameworks，只启动一次进程来脱壳所有
      if (encryptedFrameworks.count > 0) {
        writeLog(
            [NSString stringWithFormat:
                          @"共发现 %lu 个加密 Framework，启动进程统一脱壳...",
                          (unsigned long)encryptedFrameworks.count]);
        dispatch_async(dispatch_get_main_queue(), ^{
          progressAlert.message = [NSString
              stringWithFormat:@"正在脱壳 %lu 个 Frameworks...",
                               (unsigned long)encryptedFrameworks.count];
        });

        // 启动一次主应用
        pid_t fwPid;
        const char *fwArgv[] = {binaryPath.UTF8String, NULL};
        const char *fwEnvp[] = {"HOME=/var/mobile", NULL};

        posix_spawnattr_t fwAttr;
        posix_spawnattr_init(&fwAttr);
        posix_spawnattr_setflags(&fwAttr, POSIX_SPAWN_START_SUSPENDED);

        int fwSpawnResult =
            posix_spawn(&fwPid, binaryPath.UTF8String, NULL, &fwAttr,
                        (char *const *)fwArgv, (char *const *)fwEnvp);
        posix_spawnattr_destroy(&fwAttr);

        if (fwSpawnResult != 0) {
          writeLog(
              [NSString stringWithFormat:@"  启动进程失败: %d", fwSpawnResult]);
        } else {
          kill(fwPid, SIGCONT);
          [NSThread sleepForTimeInterval:2.0];

          mach_port_t fwTask = MACH_PORT_NULL;
          kern_return_t fwKr = task_for_pid(mach_task_self(), fwPid, &fwTask);

          if (fwKr != KERN_SUCCESS) {
            kill(fwPid, SIGKILL);
            writeLog(
                [NSString stringWithFormat:@"  task_for_pid 失败: %d", fwKr]);
          } else {
            // 获取 Frameworks 路径前缀用于查找
            NSString *frameworksPrefix =
                [app.bundlePath stringByAppendingPathComponent:@"Frameworks"];

            // 遍历所有加密 Frameworks 进行脱壳
            NSInteger fwCount = 0;
            NSInteger fwTotal = encryptedFrameworks.count;

            for (NSDictionary *fwInfo in encryptedFrameworks) {
              fwCount++;
              NSString *item = fwInfo[@"item"];
              NSString *fwBinaryPath = fwInfo[@"fwBinaryPath"];
              NSString *originalFwBinaryPath = fwInfo[@"originalFwBinaryPath"];
              NSString *fwExecName = fwInfo[@"fwExecName"];

              writeLog([NSString
                  stringWithFormat:@"[%ld/%ld] 脱壳 Framework: %@",
                                   (long)fwCount, (long)fwTotal, item]);

              // 使用 findImageLoadAddress 按路径前缀和镜像名称查找加载地址
              uint64_t loadAddress = 0;
              NSString *foundPath = nil;
              BOOL found = findImageLoadAddress(
                  frameworksPrefix.UTF8String, fwExecName.UTF8String, fwTask,
                  fwPid, &loadAddress, &foundPath);

              if (!found || loadAddress == 0) {
                writeLog([NSString
                    stringWithFormat:@"  未找到 Framework 加载地址: %@", item]);
                continue;
              }

              writeLog(
                  [NSString stringWithFormat:@"  Framework 加载地址: 0x%llx",
                                             loadAddress]);

              struct encryption_info_command fwEncInfo;
              uint64_t fwLoadCmdAddr = 0;
              BOOL fwFoundEnc = NO;
              if (!readEncryptionInfo(fwTask, loadAddress, &fwEncInfo,
                                      &fwLoadCmdAddr, &fwFoundEnc) ||
                  !fwFoundEnc) {
                writeLog(@"  读取加密信息失败或未加密");
                continue;
              }

              // 脱壳 Framework
              NSString *fwDecryptedPath = [sharedDumpDir
                  stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"fw_decrypted_%@", item]];
              BOOL fwDecryptSuccess = rebuildDecryptedImageAtPath(
                  originalFwBinaryPath, fwTask, loadAddress, &fwEncInfo,
                  fwLoadCmdAddr, fwDecryptedPath);

              if (fwDecryptSuccess) {
                // 替换目标 Framework
                [fm removeItemAtPath:fwBinaryPath error:nil];
                [fm copyItemAtPath:fwDecryptedPath
                            toPath:fwBinaryPath
                             error:nil];
                chmod(fwBinaryPath.UTF8String, 0755);
                [fm removeItemAtPath:fwDecryptedPath error:nil];
                writeLog([NSString
                    stringWithFormat:@"  Framework 脱壳成功: %@", item]);
              } else {
                writeLog([NSString
                    stringWithFormat:@"  Framework 脱壳失败: %@", item]);
              }
            }

            // 所有 Frameworks 处理完毕，终止进程
            kill(fwPid, SIGKILL);
          }
        }
      } else {
        writeLog(@"  没有发现需要脱壳的加密 Frameworks");
      }
    }

    // ========== 脱壳 PlugIns (App Extensions) ==========
    NSString *pluginsPath =
        [destAppPath stringByAppendingPathComponent:@"PlugIns"];
    if ([fm fileExistsAtPath:pluginsPath]) {
      writeLog(@"========== 开始脱壳 PlugIns ==========");
      dispatch_async(dispatch_get_main_queue(), ^{
        progressAlert.message = @"正在脱壳 App Extensions...";
      });

      NSArray *pluginItems = [fm contentsOfDirectoryAtPath:pluginsPath
                                                     error:nil];
      NSInteger plCount = 0;
      NSInteger plTotal = 0;

      // 统计 appex 数量
      for (NSString *plItem in pluginItems) {
        if ([plItem hasSuffix:@".appex"])
          plTotal++;
      }

      for (NSString *plItem in pluginItems) {
        if (![plItem hasSuffix:@".appex"])
          continue;

        plCount++;
        NSString *appexPath =
            [pluginsPath stringByAppendingPathComponent:plItem];
        NSString *originalAppexPath =
            [[app.bundlePath stringByAppendingPathComponent:@"PlugIns"]
                stringByAppendingPathComponent:plItem];

        // 读取 appex 的 Info.plist 获取可执行文件名
        NSString *appexInfoPath =
            [originalAppexPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *appexInfo =
            [NSDictionary dictionaryWithContentsOfFile:appexInfoPath];
        NSString *appexExecName = appexInfo[@"CFBundleExecutable"];
        if (!appexExecName) {
          appexExecName = [plItem stringByDeletingPathExtension];
        }

        NSString *appexBinaryPath =
            [originalAppexPath stringByAppendingPathComponent:appexExecName];
        NSString *destAppexBinaryPath =
            [appexPath stringByAppendingPathComponent:appexExecName];

        writeLog([NSString stringWithFormat:@"[%ld/%ld] 脱壳 Extension: %@",
                                            (long)plCount, (long)plTotal,
                                            plItem]);

        if (![fm fileExistsAtPath:appexBinaryPath]) {
          writeLog([NSString stringWithFormat:@"  Extension 二进制不存在: %@",
                                              appexBinaryPath]);
          continue;
        }

        // 检查 Extension 是否加密
        NSData *appexData = [NSData dataWithContentsOfFile:appexBinaryPath];
        if (!appexData)
          continue;

        const uint8_t *appexBytes = (const uint8_t *)appexData.bytes;
        uint32_t appexMagic = *(uint32_t *)appexBytes;
        uint32_t appexArchOffset = 0;

        if (appexMagic == FAT_MAGIC || appexMagic == FAT_CIGAM) {
          struct fat_header *appexFatHeader = (struct fat_header *)appexBytes;
          uint32_t appexNArch = OSSwapBigToHostInt32(appexFatHeader->nfat_arch);
          struct fat_arch *appexArches =
              (struct fat_arch *)(appexBytes + sizeof(struct fat_header));
          for (uint32_t i = 0; i < appexNArch; i++) {
            cpu_type_t appexCpuType =
                OSSwapBigToHostInt32(appexArches[i].cputype);
            if (appexCpuType == CPU_TYPE_ARM64) {
              appexArchOffset = OSSwapBigToHostInt32(appexArches[i].offset);
              break;
            }
          }
        }

        const struct mach_header_64 *appexHeader =
            (const struct mach_header_64 *)(appexBytes + appexArchOffset);
        if (appexHeader->magic != MH_MAGIC_64) {
          writeLog([NSString
              stringWithFormat:@"  跳过非 arm64 Extension: %@", plItem]);
          continue;
        }

        const uint8_t *appexCmdPtr = (const uint8_t *)(appexHeader + 1);
        uint32_t appexCryptid = 0;
        for (uint32_t i = 0; i < appexHeader->ncmds; i++) {
          const struct load_command *appexCmd =
              (const struct load_command *)appexCmdPtr;
          if (appexCmd->cmd == LC_ENCRYPTION_INFO_64) {
            const struct encryption_info_command_64 *appexEncCmd =
                (const struct encryption_info_command_64 *)appexCmdPtr;
            appexCryptid = appexEncCmd->cryptid;
            break;
          }
          appexCmdPtr += appexCmd->cmdsize;
        }

        if (appexCryptid == 0) {
          writeLog([NSString
              stringWithFormat:@"  Extension 未加密，跳过: %@", plItem]);
          continue;
        }

        writeLog(
            [NSString stringWithFormat:
                          @"  Extension 已加密 (cryptid=%u)，启动进程脱壳...",
                          appexCryptid]);

        // 启动 Extension 进程（App Extensions 必须独立启动）
        pid_t appexPid;
        const char *appexArgv[] = {appexBinaryPath.UTF8String, NULL};
        const char *appexEnvp[] = {"HOME=/var/mobile", NULL};

        posix_spawnattr_t appexAttr;
        posix_spawnattr_init(&appexAttr);
        posix_spawnattr_setflags(&appexAttr, POSIX_SPAWN_START_SUSPENDED);

        int appexSpawnResult =
            posix_spawn(&appexPid, appexBinaryPath.UTF8String, NULL, &appexAttr,
                        (char *const *)appexArgv, (char *const *)appexEnvp);
        posix_spawnattr_destroy(&appexAttr);

        if (appexSpawnResult != 0) {
          writeLog([NSString stringWithFormat:@"  启动 Extension 进程失败: %d",
                                              appexSpawnResult]);
          continue;
        }

        kill(appexPid, SIGCONT);
        [NSThread sleepForTimeInterval:1.5];

        mach_port_t appexTask = MACH_PORT_NULL;
        kern_return_t appexKr =
            task_for_pid(mach_task_self(), appexPid, &appexTask);
        if (appexKr != KERN_SUCCESS) {
          kill(appexPid, SIGKILL);
          writeLog([NSString
              stringWithFormat:@"  Extension task_for_pid 失败: %d", appexKr]);
          continue;
        }

        MainImageInfo_t appexMainInfo = imageInfoForPIDWithRetry(
            appexBinaryPath.UTF8String, appexTask, appexPid);
        if (!appexMainInfo.ok) {
          kill(appexPid, SIGKILL);
          writeLog([NSString
              stringWithFormat:@"  未找到 Extension 加载地址: %@", plItem]);
          continue;
        }

        writeLog([NSString stringWithFormat:@"  Extension 加载地址: 0x%llx",
                                            appexMainInfo.loadAddress]);

        struct encryption_info_command appexEncInfo;
        uint64_t appexLoadCmdAddr = 0;
        BOOL appexFoundEnc = NO;
        if (!readEncryptionInfo(appexTask, appexMainInfo.loadAddress,
                                &appexEncInfo, &appexLoadCmdAddr,
                                &appexFoundEnc) ||
            !appexFoundEnc) {
          kill(appexPid, SIGKILL);
          writeLog(@"  读取加密信息失败或未加密");
          continue;
        }

        NSString *appexDecryptedPath = [sharedDumpDir
            stringByAppendingPathComponent:
                [NSString stringWithFormat:@"appex_decrypted_%@", plItem]];
        BOOL appexDecryptSuccess = rebuildDecryptedImageAtPath(
            appexBinaryPath, appexTask, appexMainInfo.loadAddress,
            &appexEncInfo, appexLoadCmdAddr, appexDecryptedPath);
        kill(appexPid, SIGKILL);

        if (appexDecryptSuccess) {
          [fm removeItemAtPath:destAppexBinaryPath error:nil];
          [fm copyItemAtPath:appexDecryptedPath
                      toPath:destAppexBinaryPath
                       error:nil];
          chmod(destAppexBinaryPath.UTF8String, 0755);
          [fm removeItemAtPath:appexDecryptedPath error:nil];
          writeLog(
              [NSString stringWithFormat:@"  Extension 脱壳成功: %@", plItem]);
        } else {
          writeLog(
              [NSString stringWithFormat:@"  Extension 脱壳失败: %@", plItem]);
        }
      }
    }

    // 删除 SC_Info 目录（DRM 签名信息）
    NSString *scInfoPath =
        [destAppPath stringByAppendingPathComponent:@"SC_Info"];
    if ([fm fileExistsAtPath:scInfoPath]) {
      [fm removeItemAtPath:scInfoPath error:nil];
      writeLog(@"已删除 SC_Info 目录");
    }

    writeLog(@"========== 脱壳完成，开始打包 ==========");

    // 压缩 IPA
    NSString *exportDocsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *exportDir =
        [exportDocsDir stringByAppendingPathComponent:@"Export"];
    [[NSFileManager defaultManager] createDirectoryAtPath:exportDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *ipaName =
        [NSString stringWithFormat:@"%@_Decrypted_JB.ipa", app.displayName];
    NSString *ipaPath = [exportDir stringByAppendingPathComponent:ipaName];

    // 使用 ZipWriter 打包
    NSError *zipError = nil;
    BOOL zipSuccess = [ZipWriter createIPAAtPath:ipaPath
                                   fromAppBundle:destAppPath
                                           error:&zipError];

    // 清理临时目录
    [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
    // 清理共享目录中的 dump 文件
    [[NSFileManager defaultManager] removeItemAtPath:decryptedPath error:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
      [progressAlert
          dismissViewControllerAnimated:YES
                             completion:^{
                               if (zipSuccess) {
                                 UIAlertController *doneAlert = [UIAlertController
                                     alertControllerWithTitle:@"越狱脱壳成功"
                                                      message:
                                                          [NSString
                                                              stringWithFormat:
                                                                  @"已保存至:"
                                                                  @" "
                                                                  @"Export/"
                                                                  @"%@",
                                                                  ipaName]
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];
                                 [doneAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"确定"
                                                       style:
                                                           UIAlertActionStyleDefault
                                                     handler:nil]];
                                 [self presentViewController:doneAlert
                                                    animated:YES
                                                  completion:nil];
                               } else {
                                 [self showErrorMessage:
                                           [NSString
                                               stringWithFormat:
                                                   @"打包失败: %@",
                                                   zipError
                                                       .localizedDescription]];
                               }
                             }];
    });
  });
}

- (void)showErrorMessage:(NSString *)msg {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"错误"
                                          message:msg
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - App Registration Helper

- (void)changeAppRegistration:(TSAppInfo *)app toState:(NSString *)newState {
  // 1. 自我保护：禁止将 ECMain 自身切换为 User
  if ([newState isEqualToString:@"User"]) {
    NSString *currentBundleID = [[NSBundle mainBundle] bundleIdentifier];
    if ([app.bundleIdentifier isEqualToString:currentBundleID]) {
      UIAlertController *stopAlert = [UIAlertController
          alertControllerWithTitle:@"禁止操作"
                           message:@"为了防止应用“自杀”，禁止将 "
                                   @"ECMain 自身切换为 User 注册。\n\n"
                                   @"一旦切换，应用将立即无法启动，且无"
                                   @"法自行恢复。"
                    preferredStyle:UIAlertControllerStyleAlert];
      [stopAlert
          addAction:[UIAlertAction actionWithTitle:@"好"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
      [self presentViewController:stopAlert animated:YES completion:nil];
      return;
    }
  }

  // 2. 警告：切换到 User 会导致无法启动
  if ([newState isEqualToString:@"User"]) {
    NSString *msg = [NSString
        stringWithFormat:
            @"您即将把 “%@” 切换为 User 注册。\n\n"
            @"⚠️ 严重警告：\nTrollStore 应用在 User "
            @"模式下通常无法启动！\n\n"
            @"此功能仅用于临时让应用在“设置”中可见（例如修复权限或通知）。"
            @"完成后，您必须将其切回 System 才能再次使用应用。",
            app.displayName];

    UIAlertController *warnAlert = [UIAlertController
        alertControllerWithTitle:@"潜在风险"
                         message:msg
                  preferredStyle:UIAlertControllerStyleAlert];

    [warnAlert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

    [warnAlert
        addAction:[UIAlertAction
                      actionWithTitle:@"仍然切换 (导致无法启动)"
                                style:UIAlertActionStyleDestructive
                              handler:^(UIAlertAction *_Nonnull action) {
                                [self _performChangeAppRegistration:app
                                                            toState:newState];
                              }]];

    [self presentViewController:warnAlert animated:YES completion:nil];
    return;
  }

  // 其他情况直接执行
  [self _performChangeAppRegistration:app toState:newState];
}

- (void)_performChangeAppRegistration:(TSAppInfo *)app
                              toState:(NSString *)newState {
  int ret = [[TSApplicationsManager sharedInstance]
      changeAppRegistration:app.bundlePath
                    toState:newState];

  if (ret == 0) {
    UIAlertController *successAlert = [UIAlertController
        alertControllerWithTitle:@"切换成功"
                         message:[NSString
                                     stringWithFormat:
                                         @"已切换到 %@ 注册\n重启应用后生效",
                                         newState]
                  preferredStyle:UIAlertControllerStyleAlert];
    [successAlert
        addAction:[UIAlertAction actionWithTitle:@"确定"
                                           style:UIAlertActionStyleDefault
                                         handler:nil]];
    [self presentViewController:successAlert animated:YES completion:nil];
    [self loadApps];
  } else {
    UIAlertController *errAlert = [UIAlertController
        alertControllerWithTitle:@"切换失败"
                         message:[NSString
                                     stringWithFormat:@"错误代码: %d", ret]
                  preferredStyle:UIAlertControllerStyleAlert];
    [errAlert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
    [self presentViewController:errAlert animated:YES completion:nil];
  }
}

- (void)exportApp:(TSAppInfo *)app {
  // 创建导出目录
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *exportDir = [docsDir stringByAppendingPathComponent:@"Export"];

  if (![[NSFileManager defaultManager] fileExistsAtPath:exportDir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:exportDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  // 生成 IPA 文件名
  NSString *appName = app.displayName ?: @"App";
  NSString *version = app.versionString ?: @"1.0";
  NSString *ipaName =
      [NSString stringWithFormat:@"%@_%@.ipa", appName, version];
  NSString *ipaPath = [exportDir stringByAppendingPathComponent:ipaName];

  // 确保文件名唯一
  int idx = 1;
  while ([[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) {
    ipaPath = [exportDir
        stringByAppendingPathComponent:[NSString
                                           stringWithFormat:@"%@_%@_%d.ipa",
                                                            appName, version,
                                                            idx++]];
  }

  // 显示进度
  UIAlertController *progressAlert =
      [UIAlertController alertControllerWithTitle:@"正在导出..."
                                          message:@"请稍候"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progressAlert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSError *error = nil;
    BOOL success = [ZipWriter createIPAAtPath:ipaPath
                                fromAppBundle:app.bundlePath
                                        error:&error];

    dispatch_async(dispatch_get_main_queue(), ^{
      [progressAlert
          dismissViewControllerAnimated:YES
                             completion:^{
                               if (success) {
                                 UIAlertController *successAlert = [UIAlertController
                                     alertControllerWithTitle:@"导出成功"
                                                      message:
                                                          [NSString
                                                              stringWithFormat:
                                                                  @"IPA "
                                                                  @"已保存至:"
                                                                  @"\nDocumen"
                                                                  @"ts"
                                                                  @"/Export/"
                                                                  @"%@",
                                                                  ipaName]
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];

                                 [successAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"分享"
                                                       style:
                                                           UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction
                                                                   *action) {
                                                       NSURL *fileURL = [NSURL
                                                           fileURLWithPath:
                                                               ipaPath];
                                                       UIActivityViewController
                                                           *activityVC = [[UIActivityViewController
                                                               alloc]
                                                               initWithActivityItems:
                                                                   @[ fileURL ]
                                                               applicationActivities:
                                                                   nil];
                                                       if (activityVC
                                                               .popoverPresentationController) {
                                                         activityVC
                                                             .popoverPresentationController
                                                             .sourceView =
                                                             self.view;
                                                         activityVC
                                                             .popoverPresentationController
                                                             .sourceRect =
                                                             CGRectMake(
                                                                 self.view
                                                                         .bounds
                                                                         .size
                                                                         .width /
                                                                     2,
                                                                 self.view
                                                                         .bounds
                                                                         .size
                                                                         .height /
                                                                     2,
                                                                 0, 0);
                                                       }
                                                       [self
                                                           presentViewController:
                                                               activityVC
                                                                        animated:
                                                                            YES
                                                                      completion:
                                                                          nil];
                                                     }]];

                                 [successAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"完成"
                                                       style:
                                                           UIAlertActionStyleCancel
                                                     handler:nil]];
                                 [self presentViewController:successAlert
                                                    animated:YES
                                                  completion:nil];
                               } else {
                                 UIAlertController *errAlert = [UIAlertController
                                     alertControllerWithTitle:@"导出失败"
                                                      message:
                                                          error.localizedDescription
                                                              ?: @"未知错误"
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];
                                 [errAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"确定"
                                                       style:
                                                           UIAlertActionStyleDefault
                                                     handler:nil]];
                                 [self presentViewController:errAlert
                                                    animated:YES
                                                  completion:nil];
                               }
                             }];
    });
  });
}

#pragma mark - Table view data source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  if (self.currentTabIndex == 1) return 1;
  int sections = 2;
  if (self.orphanedContainers.count > 0) sections++;
  return sections;
}

- (NSString *)tableView:(UITableView *)tableView
    titleForHeaderInSection:(NSInteger)section {
  if (self.currentTabIndex == 1) return @"运行中的进程 (Processes)";
  if (section == 0)
    return @"已下载 (Downloaded)";
  if (section == 1)
    return @"已安装 (Installed)";
  return @"⚠️ 垃圾残留 (Orphaned Data)";
}

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  if (self.currentTabIndex == 1) return self.processList.count;
  if (section == 0)
    return self.downloadedIPAs.count;
  if (section == 1)
    return self.apps.count;
  return self.orphanedContainers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  if (self.currentTabIndex == 1) {
    static NSString *ProcessCellId = @"ProcessCell";
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:ProcessCellId];
    if (!cell) {
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                    reuseIdentifier:ProcessCellId];
      cell.detailTextLabel.numberOfLines = 2;
    }
    NSDictionary *dict = self.processList[indexPath.row];
    NSString *bundleID = dict[@"bundleID"];
    float cpu = [dict[@"cpu"] floatValue];
    uint64_t mem = [dict[@"mem"] unsignedLongLongValue];
    NSString *memStr = [NSString stringWithFormat:@"%.1f MB", mem / 1024.0 / 1024.0];
    
    if (bundleID && bundleID.length > 0) {
      cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", dict[@"name"], dict[@"pid"]];
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\nCPU: %.1f%% | Mem: %@", bundleID, cpu, memStr];
      cell.detailTextLabel.textColor = [UIColor systemBlueColor];
    } else {
      cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)", dict[@"proc_name"], dict[@"pid"]];
      cell.detailTextLabel.text = [NSString stringWithFormat:@"CPU: %.1f%% | Mem: %@", cpu, memStr];
      cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }
    cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
    return cell;
  }

  static NSString *CellIdentifier = @"AppCell";
  UITableViewCell *cell =
      [tableView dequeueReusableCellWithIdentifier:CellIdentifier];
  if (!cell) {
    cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                  reuseIdentifier:CellIdentifier];
  }

  if (indexPath.section == 0) {
    NSString *path = self.downloadedIPAs[indexPath.row];
    cell.textLabel.text = path.lastPathComponent;
    NSDictionary *attrs =
        [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    long long size = [attrs fileSize];
    cell.detailTextLabel.text =
        [NSString stringWithFormat:@"%.2f MB", size / 1024.0 / 1024.0];
    cell.imageView.image =
        [UIImage systemImageNamed:@"doc.fill"]; // Placeholder
  } else if (indexPath.section == 1) {
    TSAppInfo *app = self.apps[indexPath.row];
    cell.textLabel.text = [app displayName];

    // 显示权限标志 (System/User)
    NSString *regState = [app registrationState];
    NSString *regBadge = @"";
    if ([regState isEqualToString:@"System"]) {
      regBadge = @" [S]";
    } else if ([regState isEqualToString:@"User"]) {
      regBadge = @" [U]";
    }

    // 检测加密状态
    NSString *bundlePath = [app bundlePath];
    NSString *executableName = [[NSBundle bundleWithPath:bundlePath]
        objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if (!executableName) {
      executableName =
          [[bundlePath lastPathComponent] stringByDeletingPathExtension];
    }
    NSString *executablePath =
        [bundlePath stringByAppendingPathComponent:executableName];

    EncryptionStatus encStatus = checkBinaryEncryptionStatus(executablePath);
    NSString *encBadge = @"";
    switch (encStatus) {
    case EncryptionStatusEncrypted:
      encBadge = @" 🔒";
      break;
    case EncryptionStatusDecrypted:
      encBadge = @" 🔓";
      break;
    case EncryptionStatusNotFound:
      encBadge = @" 📦";
      break;
    default:
      encBadge = @"";
      break;
    }

    // 显示 ECMAIN 托管标志
    NSString *managedPlistPath = @"/var/mobile/Media/ECMAIN/managed_apps.plist";
    NSArray *managedApps = [NSArray arrayWithContentsOfFile:managedPlistPath];
    BOOL isManaged = managedApps && [managedApps containsObject:[app bundleIdentifier]];
    NSString *managedBadge = isManaged ? @" 🛡️" : @"";

    cell.detailTextLabel.text =
        [NSString stringWithFormat:@"%@ (%@)%@%@%@", [app bundleIdentifier],
                                   [app versionString], regBadge, encBadge, managedBadge];

    // PID Check
    NSString *matchName = executableName;
    if (matchName.length > 15) {
      matchName = [matchName substringToIndex:15];
    }
    NSNumber *pid = self.runningProcesses[matchName];
    if (!pid)
      pid = self.runningProcesses[executableName];

    if (pid) {
      cell.detailTextLabel.text = [cell.detailTextLabel.text
          stringByAppendingFormat:@" [PID: %@]", pid];
      cell.detailTextLabel.textColor = [UIColor systemBlueColor];
    } else {
      cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    }

    cell.imageView.image = [app iconForSize:CGSizeMake(29, 29)];
  } else {
    NSDictionary *orphan = self.orphanedContainers[indexPath.row];
    cell.textLabel.text = orphan[@"bundleId"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"UUID: %@", orphan[@"uuid"]];
    cell.detailTextLabel.textColor = [UIColor systemRedColor];
    cell.imageView.image = [UIImage systemImageNamed:@"trash.fill"];
  }

  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  
  if (self.currentTabIndex == 1) {
    return; // 进程列表点击暂无操作
  }
  
  if (indexPath.section == 0) {
    [self showInstallOptionsForPath:self.downloadedIPAs[indexPath.row]
                              isURL:NO];
  } else if (indexPath.section == 1) {
    TSAppInfo *app = self.apps[indexPath.row];
    [self showAppActions:app];
  } else {
    NSDictionary *orphan = self.orphanedContainers[indexPath.row];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清理残留" message:[NSString stringWithFormat:@"确认物理销毁该容器?\n%@", orphan[@"bundleId"]] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"销毁 (Destroy)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        BOOL suc = [[TSApplicationsManager sharedInstance] deleteOrphanedContainer:orphan[@"path"] bundleId:orphan[@"bundleId"]];
        if (suc) {
            [self loadData];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
  }
}

#pragma mark - App Info Export

- (void)exportAppDetailedInfo:(TSAppInfo *)app {
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString *bundlePath = [app bundlePath];
    NSMutableString *report = [NSMutableString string];

    // 1. 基本信息
    [report appendString:@"═══════════════════════════════════════\n"];
    [report appendFormat:@"📱 应用详细信息报告\n"];
    [report appendFormat:@"═══════════════════════════════════════\n\n"];

    [report appendFormat:@"📌 基本信息\n"];
    [report appendFormat:@"───────────────────────────────────────\n"];
    [report appendFormat:@"应用名称: %@\n", [app displayName]];
    [report appendFormat:@"Bundle ID: %@\n", [app bundleIdentifier]];
    [report appendFormat:@"版本: %@\n", [app versionString]];
    [report appendFormat:@"注册状态: %@\n", [app registrationState]];
    [report appendFormat:@"Bundle 路径: %@\n\n", bundlePath];

    // 2. 加密状态
    NSString *executableName = [[NSBundle bundleWithPath:bundlePath]
        objectForInfoDictionaryKey:@"CFBundleExecutable"];
    if (!executableName) {
      executableName =
          [[bundlePath lastPathComponent] stringByDeletingPathExtension];
    }
    NSString *executablePath =
        [bundlePath stringByAppendingPathComponent:executableName];

    EncryptionStatus encStatus = checkBinaryEncryptionStatus(executablePath);
    [report appendFormat:@"🔐 加密状态\n"];
    [report appendFormat:@"───────────────────────────────────────\n"];
    [report
        appendFormat:@"主二进制: %@\n", encryptionStatusDescription(encStatus)];
    [report appendFormat:@"可执行文件: %@\n\n", executablePath];

    // 3. SC_Info 授权信息
    [report appendFormat:@"🔑 SC_Info 授权信息\n"];
    [report appendFormat:@"───────────────────────────────────────\n"];
    NSString *scInfoPath =
        [bundlePath stringByAppendingPathComponent:@"SC_Info"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:scInfoPath]) {
      NSArray *scFiles =
          [[NSFileManager defaultManager] contentsOfDirectoryAtPath:scInfoPath
                                                              error:nil];
      [report appendFormat:@"SC_Info 目录存在: ✅\n"];
      [report appendFormat:@"文件列表:\n"];
      for (NSString *file in scFiles) {
        NSString *filePath = [scInfoPath stringByAppendingPathComponent:file];
        NSDictionary *attrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:filePath
                                                             error:nil];
        unsigned long long fileSize = [attrs fileSize];
        [report appendFormat:@"  • %@ (%llu bytes)\n", file, fileSize];
      }

      // 尝试读取 .sinf 文件内容
      for (NSString *file in scFiles) {
        if ([file.pathExtension isEqualToString:@"sinf"]) {
          NSString *sinfPath = [scInfoPath stringByAppendingPathComponent:file];
          NSData *sinfData = [NSData dataWithContentsOfFile:sinfPath];
          if (sinfData) {
            [report appendFormat:@"\n📄 %@ 内容 (hex, 前256字节):\n", file];
            NSUInteger len = MIN(256, sinfData.length);
            const unsigned char *bytes = sinfData.bytes;
            for (NSUInteger i = 0; i < len; i++) {
              [report appendFormat:@"%02x", bytes[i]];
              if ((i + 1) % 32 == 0)
                [report appendString:@"\n"];
              else if ((i + 1) % 4 == 0)
                [report appendString:@" "];
            }
            [report appendString:@"\n"];
          }
        }
      }
    } else {
      [report appendFormat:@"SC_Info 目录存在: ❌ (无 FairPlay 授权)\n"];
    }
    [report appendString:@"\n"];

    // 4. Info.plist 关键信息
    [report appendFormat:@"📋 Info.plist 关键信息\n"];
    [report appendFormat:@"───────────────────────────────────────\n"];
    NSString *infoPlistPath =
        [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist =
        [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    if (infoPlist) {
      NSArray *keys = @[
        @"CFBundleIdentifier", @"CFBundleVersion",
        @"CFBundleShortVersionString", @"CFBundleExecutable",
        @"MinimumOSVersion", @"DTSDKName", @"CFBundleSupportedPlatforms",
        @"DTPlatformName"
      ];
      for (NSString *key in keys) {
        id value = infoPlist[key];
        if (value) {
          [report appendFormat:@"%@: %@\n", key, value];
        }
      }
    }
    [report appendString:@"\n"];

    // 5. 文件结构
    [report appendFormat:@"📁 文件结构\n"];
    [report appendFormat:@"───────────────────────────────────────\n"];
    NSArray *topFiles =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath
                                                            error:nil];
    for (NSString *file in topFiles) {
      NSString *filePath = [bundlePath stringByAppendingPathComponent:file];
      BOOL isDir = NO;
      [[NSFileManager defaultManager] fileExistsAtPath:filePath
                                           isDirectory:&isDir];
      if (isDir) {
        [report appendFormat:@"📂 %@/\n", file];
      } else {
        NSDictionary *attrs =
            [[NSFileManager defaultManager] attributesOfItemAtPath:filePath
                                                             error:nil];
        unsigned long long fileSize = [attrs fileSize];
        [report appendFormat:@"📄 %@ (%llu bytes)\n", file, fileSize];
      }
    }
    [report appendString:@"\n"];

    // 6. PlugIns/扩展信息
    NSString *plugInsPath =
        [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:plugInsPath]) {
      [report appendFormat:@"🧩 扩展 (PlugIns)\n"];
      [report appendFormat:@"───────────────────────────────────────\n"];
      NSArray *plugins =
          [[NSFileManager defaultManager] contentsOfDirectoryAtPath:plugInsPath
                                                              error:nil];
      for (NSString *plugin in plugins) {
        if ([plugin.pathExtension isEqualToString:@"appex"]) {
          NSString *pluginPath =
              [plugInsPath stringByAppendingPathComponent:plugin];
          NSString *pluginInfoPath =
              [pluginPath stringByAppendingPathComponent:@"Info.plist"];
          NSDictionary *pluginInfo =
              [NSDictionary dictionaryWithContentsOfFile:pluginInfoPath];
          NSString *pluginBundleId =
              pluginInfo[@"CFBundleIdentifier"] ?: @"未知";

          // 检测扩展加密状态
          NSString *pluginExec =
              pluginInfo[@"CFBundleExecutable"]
                  ?: [[plugin stringByDeletingPathExtension] lastPathComponent];
          NSString *pluginExecPath =
              [pluginPath stringByAppendingPathComponent:pluginExec];
          EncryptionStatus pluginEncStatus =
              checkBinaryEncryptionStatus(pluginExecPath);

          [report appendFormat:@"  • %@ (%@) %@\n", plugin, pluginBundleId,
                               encryptionStatusDescription(pluginEncStatus)];
        }
      }
      [report appendString:@"\n"];
    }

    // 保存报告
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *reportFileName = [NSString
        stringWithFormat:@"%@_info_report.txt", [app bundleIdentifier]];
    NSString *reportPath =
        [docsDir stringByAppendingPathComponent:reportFileName];
    [report writeToFile:reportPath
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
      UIAlertController *resultAlert = [UIAlertController
          alertControllerWithTitle:@"报告已生成"
                           message:[NSString
                                       stringWithFormat:
                                           @"保存位置:\n%@\n\n是否查看报告?",
                                           reportPath]
                    preferredStyle:UIAlertControllerStyleAlert];

      [resultAlert
          addAction:
              [UIAlertAction
                  actionWithTitle:@"查看"
                            style:UIAlertActionStyleDefault
                          handler:^(UIAlertAction *action) {
                            UIAlertController *viewAlert = [UIAlertController
                                alertControllerWithTitle:@"详细信息报告"
                                                 message:report
                                          preferredStyle:
                                              UIAlertControllerStyleAlert];
                            [viewAlert
                                addAction:
                                    [UIAlertAction
                                        actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];
                            [self presentViewController:viewAlert
                                               animated:YES
                                             completion:nil];
                          }]];

      [resultAlert
          addAction:[UIAlertAction
                        actionWithTitle:@"分享"
                                  style:UIAlertActionStyleDefault
                                handler:^(UIAlertAction *action) {
                                  NSURL *fileURL =
                                      [NSURL fileURLWithPath:reportPath];
                                  UIActivityViewController *activityVC =
                                      [[UIActivityViewController alloc]
                                          initWithActivityItems:@[ fileURL ]
                                          applicationActivities:nil];
                                  [self presentViewController:activityVC
                                                     animated:YES
                                                   completion:nil];
                                }]];

      [resultAlert
          addAction:[UIAlertAction actionWithTitle:@"关闭"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
      [self presentViewController:resultAlert animated:YES completion:nil];
    });
  });
}

- (void)exportAppFullPackage:(TSAppInfo *)app {
  UIAlertController *progressAlert = [UIAlertController
      alertControllerWithTitle:@"正在导出..."
                       message:@"正在打包应用 (含授权数据)..."
                preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progressAlert animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSString *bundlePath = [app bundlePath];
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *exportDir =
        [docsDir stringByAppendingPathComponent:@"ExportedApps"];

    [[NSFileManager defaultManager] createDirectoryAtPath:exportDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *appName =
        [[app displayName] stringByReplacingOccurrencesOfString:@"/"
                                                     withString:@"_"];
    NSString *ipaName = [NSString stringWithFormat:@"%@_full.ipa", appName];
    NSString *ipaPath = [exportDir stringByAppendingPathComponent:ipaName];

    // 使用 ZipWriter 创建 IPA
    NSString *tempPayloadDir = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"ExportPayload"];
    NSString *payloadDir =
        [tempPayloadDir stringByAppendingPathComponent:@"Payload"];

    [[NSFileManager defaultManager] removeItemAtPath:tempPayloadDir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:payloadDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // 复制整个 .app 目录
    NSString *destApp = [payloadDir
        stringByAppendingPathComponent:[bundlePath lastPathComponent]];
    NSError *copyError = nil;
    BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:bundlePath
                                                          toPath:destApp
                                                           error:&copyError];

    if (!copied) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [progressAlert
            dismissViewControllerAnimated:YES
                               completion:^{
                                 UIAlertController *errAlert = [UIAlertController
                                     alertControllerWithTitle:@"导出失败"
                                                      message:
                                                          copyError
                                                              .localizedDescription
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];
                                 [errAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"确定"
                                                       style:
                                                           UIAlertActionStyleCancel
                                                     handler:nil]];
                                 [self presentViewController:errAlert
                                                    animated:YES
                                                  completion:nil];
                               }];
      });
      return;
    }

    // 创建 ZIP (IPA)
    [[NSFileManager defaultManager] removeItemAtPath:ipaPath error:nil];
    NSError *zipError = nil;
    BOOL zipSuccess = [ZipWriter createZipAtPath:ipaPath
                               fromDirectoryPath:tempPayloadDir
                                           error:&zipError];

    // 清理临时目录
    [[NSFileManager defaultManager] removeItemAtPath:tempPayloadDir error:nil];

    dispatch_async(dispatch_get_main_queue(), ^{
      [progressAlert
          dismissViewControllerAnimated:YES
                             completion:^{
                               if (zipSuccess) {
                                 NSDictionary *attrs =
                                     [[NSFileManager defaultManager]
                                         attributesOfItemAtPath:ipaPath
                                                          error:nil];
                                 unsigned long long fileSize = [attrs fileSize];

                                 UIAlertController *successAlert = [UIAlertController
                                     alertControllerWithTitle:@"导出成功"
                                                      message:
                                                          [NSString
                                                              stringWithFormat:
                                                                  @"IPA "
                                                                  @"已保存到:"
                                                                  @"\n%@"
                                                                  @"\n\n大小:"
                                                                  @" "
                                                                  @"%.2f MB",
                                                                  ipaPath,
                                                                  fileSize /
                                                                      1024.0 /
                                                                      1024.0]
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];

                                 [successAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"分享"
                                                       style:
                                                           UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction
                                                                   *action) {
                                                       NSURL *fileURL = [NSURL
                                                           fileURLWithPath:
                                                               ipaPath];
                                                       UIActivityViewController
                                                           *activityVC = [[UIActivityViewController
                                                               alloc]
                                                               initWithActivityItems:
                                                                   @[ fileURL ]
                                                               applicationActivities:
                                                                   nil];
                                                       [self
                                                           presentViewController:
                                                               activityVC
                                                                        animated:
                                                                            YES
                                                                      completion:
                                                                          nil];
                                                     }]];

                                 [successAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"确定"
                                                       style:
                                                           UIAlertActionStyleCancel
                                                     handler:nil]];
                                 [self presentViewController:successAlert
                                                    animated:YES
                                                  completion:nil];
                               } else {
                                 UIAlertController *errAlert = [UIAlertController
                                     alertControllerWithTitle:@"导出失败"
                                                      message:@"创建 IPA "
                                                              @"压缩包失败"
                                               preferredStyle:
                                                   UIAlertControllerStyleAlert];
                                 [errAlert
                                     addAction:
                                         [UIAlertAction
                                             actionWithTitle:@"确定"
                                                       style:
                                                           UIAlertActionStyleCancel
                                                     handler:nil]];
                                 [self presentViewController:errAlert
                                                    animated:YES
                                                  completion:nil];
                               }
                             }];
    });
  });
}

#pragma mark - SC_Info Authorization Transfer

- (void)exportSCInfo:(TSAppInfo *)app {
  NSString *bundlePath = [app bundlePath];
  NSString *scInfoPath = [bundlePath stringByAppendingPathComponent:@"SC_Info"];

  if (![[NSFileManager defaultManager] fileExistsAtPath:scInfoPath]) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"❌ 无 SC_Info"
                         message:@"此应用没有 SC_Info "
                                 @"目录，可能是脱壳后的应用或非 "
                                 @"App Store 应用。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }

  // 创建导出目录
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *exportDir =
      [docsDir stringByAppendingPathComponent:@"SC_Info_Export"];
  NSString *appExportDir =
      [exportDir stringByAppendingPathComponent:[app bundleIdentifier]];

  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;

  // 清理旧的导出
  if ([fm fileExistsAtPath:appExportDir]) {
    [fm removeItemAtPath:appExportDir error:nil];
  }
  [fm createDirectoryAtPath:appExportDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];

  // 复制 SC_Info 内容
  NSArray *scFiles = [fm contentsOfDirectoryAtPath:scInfoPath error:nil];
  NSMutableString *report = [NSMutableString string];
  [report appendFormat:@"导出 SC_Info 文件:\n"];

  for (NSString *file in scFiles) {
    NSString *srcPath = [scInfoPath stringByAppendingPathComponent:file];
    NSString *dstPath = [appExportDir stringByAppendingPathComponent:file];

    if ([fm copyItemAtPath:srcPath toPath:dstPath error:&error]) {
      NSDictionary *attrs = [fm attributesOfItemAtPath:srcPath error:nil];
      [report appendFormat:@"✅ %@ (%llu bytes)\n", file, [attrs fileSize]];
    } else {
      [report appendFormat:@"❌ %@ (复制失败: %@)\n", file,
                           error.localizedDescription];
    }
  }

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"🔐 SC_Info 导出成功"
                       message:[NSString stringWithFormat:
                                             @"授权文件已导出到:\n%@\n\n%@"
                                             @"\n\n可以将这些文件导入到同一应用"
                                             @"的其他设备上。",
                                             appExportDir, report]
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction
                       actionWithTitle:@"分享"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 NSURL *dirURL =
                                     [NSURL fileURLWithPath:appExportDir];
                                 UIActivityViewController *activityVC =
                                     [[UIActivityViewController alloc]
                                         initWithActivityItems:@[ dirURL ]
                                         applicationActivities:nil];
                                 [self presentViewController:activityVC
                                                    animated:YES
                                                  completion:nil];
                               }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)importSCInfo:(TSAppInfo *)app {
  // 保存当前应用信息到属性以便在回调中使用
  objc_setAssociatedObject(self, "currentImportApp", app,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  // 提示用户选择 SC_Info 文件夹
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"🔑 导入 SC_Info 授权"
                       message:@"请选择导入方式：\n\n"
                               @"1. 从文件选择器选择 SC_Info 文件夹\n"
                               @"2. 从已导出的授权中选择"
                preferredStyle:UIAlertControllerStyleAlert];

  // 选择文件夹（使用 Document Picker）
  [alert addAction:[UIAlertAction
                       actionWithTitle:@"📁 选择文件夹"
                                 style:UIAlertActionStyleDefault
                               handler:^(UIAlertAction *action) {
                                 // 使用 UIDocumentPickerViewController
                                 // 选择文件夹
                                 UIDocumentPickerViewController *picker =
                                     [[UIDocumentPickerViewController alloc]
                                         initForOpeningContentTypes:@[
                                           UTTypeFolder
                                         ]];
                                 picker.delegate = self;
                                 picker.allowsMultipleSelection = NO;
                                 picker.directoryURL = nil;
                                 [self presentViewController:picker
                                                    animated:YES
                                                  completion:nil];
                               }]];

  // 从已有导出中选择
  [alert addAction:[UIAlertAction actionWithTitle:@"📋 查看已导出的授权"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self
                                                showAvailableSCInfoExports:app];
                                          }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

// 显示已导出的 SC_Info 列表供选择
- (void)showAvailableSCInfoExports:(TSAppInfo *)app {
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *exportDir =
      [docsDir stringByAppendingPathComponent:@"SC_Info_Export"];

  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *exports = [fm contentsOfDirectoryAtPath:exportDir error:nil];

  if (!exports || exports.count == 0) {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"❌ 无可用授权"
                         message:@"Documents/SC_Info_Export/ "
                                 @"目录中没有导出的授权。\n\n"
                                 @"请先在其他设备上导出 "
                                 @"SC_Info，然后通过「文件」app "
                                 @"或其他方式传输到此目录。"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }

  // 显示可选择的导出列表
  UIAlertController *picker = [UIAlertController
      alertControllerWithTitle:@"选择要导入的授权"
                       message:@"以下是已导出的 SC_Info 授权："
                preferredStyle:UIAlertControllerStyleActionSheet];

  for (NSString *bundleId in exports) {
    NSString *exportPath = [exportDir stringByAppendingPathComponent:bundleId];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:exportPath isDirectory:&isDir] && isDir) {
      NSArray *files = [fm contentsOfDirectoryAtPath:exportPath error:nil];
      NSString *title = [NSString stringWithFormat:@"%@ (%lu 文件)", bundleId,
                                                   (unsigned long)files.count];

      [picker addAction:[UIAlertAction
                            actionWithTitle:title
                                      style:UIAlertActionStyleDefault
                                    handler:^(UIAlertAction *action) {
                                      [self doImportSCInfoFromPath:exportPath
                                                             toApp:app];
                                    }]];
    }
  }

  [picker addAction:[UIAlertAction actionWithTitle:@"取消"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

  if (picker.popoverPresentationController) {
    picker.popoverPresentationController.sourceView = self.view;
    picker.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2,
                   self.view.bounds.size.height / 2, 0, 0);
  }

  [self presentViewController:picker animated:YES completion:nil];
}

// 执行实际的 SC_Info 导入
- (void)doImportSCInfoFromPath:(NSString *)sourcePath toApp:(TSAppInfo *)app {
  NSString *bundlePath = [app bundlePath];
  NSString *scInfoPath = [bundlePath stringByAppendingPathComponent:@"SC_Info"];
  NSFileManager *fm = [NSFileManager defaultManager];

  // 确认导入
  NSArray *files = [fm contentsOfDirectoryAtPath:sourcePath error:nil];
  NSMutableString *fileList = [NSMutableString string];
  for (NSString *file in files) {
    [fileList appendFormat:@"• %@\n", file];
  }

  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"🔑 确认导入"
                       message:[NSString stringWithFormat:
                                             @"将以下文件导入到应用 "
                                             @"%@：\n\n%@"
                                             @"\n这将替换应用现有的授权信息。",
                                             app.displayName, fileList]
                preferredStyle:UIAlertControllerStyleAlert];

  [confirm
      addAction:
          [UIAlertAction
              actionWithTitle:@"导入"
                        style:UIAlertActionStyleDestructive
                      handler:^(UIAlertAction *action) {
                        BOOL success = YES;
                        NSMutableString *report = [NSMutableString string];
                        NSFileManager *fm = [NSFileManager defaultManager];
                        NSError *error = nil;

                        // 直接用 NSFileManager 删除和创建目录
                        // (应用有 no-sandbox 权限，应该可以直接操作)

                        // 先删除旧目录
                        if ([fm fileExistsAtPath:scInfoPath]) {
                          if (![fm removeItemAtPath:scInfoPath error:&error]) {
                            NSLog(@"[SCInfo] 删除旧目录失败: %@", error);
                            [report appendFormat:@"⚠️ 删除旧目录失败: %@\n",
                                                 error.localizedDescription];
                          } else {
                            NSLog(@"[SCInfo] 成功删除旧目录: %@", scInfoPath);
                          }
                        }

                        // 创建新目录
                        if (![fm createDirectoryAtPath:scInfoPath
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:&error]) {
                          NSLog(@"[SCInfo] 创建目录失败: %@", error);
                          [report appendFormat:@"⚠️ 创建目录失败: %@\n",
                                               error.localizedDescription];
                        }

                        // 复制文件
                        NSArray *importFiles =
                            [fm contentsOfDirectoryAtPath:sourcePath error:nil];

                        for (NSString *file in importFiles) {
                          NSString *srcPath =
                              [sourcePath stringByAppendingPathComponent:file];
                          NSString *dstPath =
                              [scInfoPath stringByAppendingPathComponent:file];

                          // 先删除目标文件（如果存在）
                          if ([fm fileExistsAtPath:dstPath]) {
                            [fm removeItemAtPath:dstPath error:nil];
                          }

                          NSError *copyError = nil;
                          if ([fm copyItemAtPath:srcPath
                                          toPath:dstPath
                                           error:&copyError]) {
                            NSDictionary *attrs =
                                [fm attributesOfItemAtPath:srcPath error:nil];
                            [report appendFormat:@"✅ %@ (%llu bytes)\n", file,
                                                 [attrs fileSize]];
                          } else {
                            [report
                                appendFormat:@"❌ %@ (失败: %@)\n", file,
                                             copyError.localizedDescription];
                            success = NO;
                          }
                        }

                        UIAlertController *resultAlert = [UIAlertController
                            alertControllerWithTitle:success ? @"🔑 导入成功"
                                                             : @"⚠️ 部分失败"
                                             message:[NSString
                                                         stringWithFormat:
                                                             @"SC_Info "
                                                             @"授权导入完成："
                                                             @"\n\n%@"
                                                             @"\n\n"
                                                             @"请尝试打开应用"
                                                             @"，如果"
                                                             @"仍然无法运行，"
                                                             @"可能需"
                                                             @"要重启设备。",
                                                             report]
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];

                        [resultAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"打开应用"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [[TSApplicationsManager
                                                  sharedInstance]
                                                  openApplicationWithBundleID:
                                                      app.bundleIdentifier];
                                            }]];

                        [resultAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"确定"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
                        [self presentViewController:resultAlert
                                           animated:YES
                                         completion:nil];
                      }]];

  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
  [self presentViewController:confirm animated:YES completion:nil];
}

#pragma mark - Injection & Spoof Actions

// 注入方案选择弹窗
- (void)showInjectOptionsForApp:(TSAppInfo *)app {
  UIAlertController *options = [UIAlertController
      alertControllerWithTitle:@"选择注入方案"
                       message:@"方案 B：修改 Bundle ID 克隆多实例\n方案 C：原版注入，多 Profile 切换（推荐）"
                preferredStyle:UIAlertControllerStyleActionSheet];

  [options addAction:[UIAlertAction actionWithTitle:@"💉 方案 B — 克隆多实例"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [self injectIntoApp:app];
                                            }]];

  [options addAction:[UIAlertAction actionWithTitle:@"💉 方案 C — 原版多 Profile（推荐）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [self injectProfileCIntoApp:app];
                                            }]];

  [options addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

  if (options.popoverPresentationController) {
    options.popoverPresentationController.sourceView = self.view;
    options.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 0, 0);
  }

  [self presentViewController:options animated:YES completion:nil];
}

// 方案 C 注入（原版 TikTok + Profile 切换 dylib）
- (void)injectProfileCIntoApp:(TSAppInfo *)app {
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"方案 C 注入"
                       message:@"将注入 Profile 切换 dylib 到原版应用。\n注入后可在 App 内通过悬浮球切换多账号。\n\n确定继续？"
                preferredStyle:UIAlertControllerStyleAlert];

  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

  [confirm addAction:[UIAlertAction
                         actionWithTitle:@"注入"
                                   style:UIAlertActionStyleDestructive
                                 handler:^(UIAlertAction *action) {
                                   [self startProfileCInjection:app teamID:nil];
                                 }]];

  [self presentViewController:confirm animated:YES completion:nil];
}

- (void)startProfileCInjection:(TSAppInfo *)app teamID:(NSString *)manualTeamID {
  UIAlertController *progress =
      [UIAlertController alertControllerWithTitle:@"方案 C 注入中..."
                                          message:@"请稍候"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progress animated:YES completion:nil];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSError *error;
    NSString *executablePath = nil;

    if ([app respondsToSelector:@selector(executablePath)]) {
      executablePath = [app performSelector:@selector(executablePath)];
    } else {
      @try {
        NSDictionary *info = [app valueForKey:@"cachedInfoDictionary"];
        if (info && info[@"CFBundleExecutable"]) {
          executablePath = [app.bundlePath
              stringByAppendingPathComponent:info[@"CFBundleExecutable"]];
        }
      } @catch (NSException *exception) {
        NSLog(@"[ECMain] Failed to get executablePath: %@", exception);
      }
    }

    BOOL success = [[ECAppInjector sharedInstance]
        injectProfileCDylibIntoApp:app.bundlePath
                    executablePath:executablePath
                      manualTeamID:manualTeamID
                             error:&error];

    dispatch_async(dispatch_get_main_queue(), ^{
      [progress dismissViewControllerAnimated:YES
                                   completion:^{
                                     if (success) {
                                       [self loadApps];
                                       [self showSuccessMessage:
                                                 @"方案 C 注入成功！\n请重启目标 APP。\n"
                                                 @"启动后会出现悬浮球用于切换 Profile。"];
                                     } else {
                                       [self showErrorMessage:
                                                 error.localizedDescription
                                                     ?: @"注入失败"];
                                     }
                                   }];
    });
  });
}

- (void)injectIntoApp:(TSAppInfo *)app {
  UIAlertController *confirm = [UIAlertController
      alertControllerWithTitle:@"注入应用"
                       message:@"确定要注入 dylib 到此应用吗？"
                preferredStyle:UIAlertControllerStyleAlert];

  [confirm addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

  [confirm addAction:[UIAlertAction
                         actionWithTitle:@"注入"
                                   style:UIAlertActionStyleDestructive
                                 handler:^(UIAlertAction *_Nonnull action) {
                                   [self startInjectionProcess:app teamID:nil];
                                 }]];

  [self presentViewController:confirm animated:YES completion:nil];
}

- (void)startInjectionProcess:(TSAppInfo *)app teamID:(NSString *)manualTeamID {
  UIAlertController *progress =
      [UIAlertController alertControllerWithTitle:@"注入中..."
                                          message:@"请稍候"
                                   preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:progress animated:YES completion:nil];

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;

        // 防御性获取 executablePath，防止因缓存导致的 Crash
        NSString *executablePath = nil;

        if ([app respondsToSelector:@selector(executablePath)]) {
          executablePath = [app performSelector:@selector(executablePath)];
        } else {
          // Fallback: 尝试通过 KVC 访问私有变量 (如果 TSAppInfo 未重新编译)
          @try {
            NSDictionary *info = [app valueForKey:@"cachedInfoDictionary"];
            if (info && info[@"CFBundleExecutable"]) {
              executablePath = [app.bundlePath
                  stringByAppendingPathComponent:info[@"CFBundleExecutable"]];
            }
          } @catch (NSException *exception) {
            NSLog(@"[ECMain] Failed to get executablePath via KVC: %@",
                  exception);
          }
        }

        BOOL success = [[ECAppInjector sharedInstance]
            injectSpoofDylibIntoApp:app.bundlePath
                     executablePath:executablePath
                       manualTeamID:manualTeamID
                              error:&error];

        dispatch_async(dispatch_get_main_queue(), ^{
          [progress dismissViewControllerAnimated:YES
                                       completion:^{
                                         if (success) {
                                           // 刷新列表以更新状态
                                           [self loadApps];
                                           [self showSuccessMessage:
                                                     @"注入成功！\n请重启目标 "
                                                     @"APP 使其生效。"];
                                         } else {
                                           [self showErrorMessage:
                                                     error.localizedDescription
                                                         ?: @"注入失败"];
                                         }
                                       }];
        });
      });
}

- (void)ejectFromApp:(TSAppInfo *)app {
  NSError *error;
  BOOL success =
      [[ECAppInjector sharedInstance] ejectDylibFromApp:app.bundlePath
                                                  error:&error];

  if (success) {
    [self showSuccessMessage:@"已移除注入"];
  } else {
    [self showErrorMessage:error.localizedDescription ?: @"移除失败"];
  }
}

- (void)configureSpooferForApp:(TSAppInfo *)app {
  // 跳转到设备信息配置界面
  ECDeviceInfoViewController *vc = [[ECDeviceInfoViewController alloc]
      initWithStyle:UITableViewStyleGrouped];
  vc.isEditingMode = YES;

  // 构建配置路径: AppBundle/Frameworks/device.plist
  // 必须与 Dylib (ECDeviceSpoofConfig) 读取路径一致！
  vc.targetConfigPath =
      [app.bundlePath stringByAppendingPathComponent:
                          @"Frameworks/com.apple.preferences.display.plist"];
  NSLog(@"[ECAppList] 配置目标路径: %@", vc.targetConfigPath);

  // 获取 App 容器路径 (用于同步配置到 User App 沙盒)
  // 需要 LSApplicationProxy
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
  id proxy = [NSClassFromString(@"LSApplicationProxy")
      performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")
           withObject:app.bundleIdentifier];
  if (proxy) {
    NSURL *dataContainerURL =
        [proxy performSelector:NSSelectorFromString(@"dataContainerURL")];
    if (dataContainerURL) {
      NSString *containerPath = dataContainerURL.path;
      NSString *ecspoof = [containerPath
          stringByAppendingPathComponent:@"Documents/.com.apple.UIKit.pboard"];
      vc.targetContainerPath =
          [ecspoof stringByAppendingPathComponent:
                       @"com.apple.preferences.display.plist"];
      NSLog(@"[ECAppList] 目标容器路径: %@", vc.targetContainerPath);
    }
  }
#pragma clang diagnostic pop

  [self.navigationController pushViewController:vc animated:YES];
}

- (void)manageClonesForApp:(TSAppInfo *)app {
  ECAppInjector *injector = [ECAppInjector sharedInstance];
  NSArray *cloneIds = [injector cloneIdsForApp:app.bundleIdentifier];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"分身管理"
                       message:app.displayName
                preferredStyle:UIAlertControllerStyleActionSheet];

  // 显示现有分身
  for (NSString *cloneId in cloneIds) {
    [alert addAction:[UIAlertAction
                         actionWithTitle:[NSString stringWithFormat:@"分身 %@",
                                                                    cloneId]
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *action) {
                                   [self showCloneOptionsForApp:app
                                                        cloneId:cloneId];
                                 }]];
  }

  // 创建新分身
  [alert addAction:[UIAlertAction actionWithTitle:@"➕ 创建新分身"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self createCloneForApp:app];
                                          }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  // iPad fix
  if (alert.popoverPresentationController) {
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(self.view.center.x, self.view.center.y, 0, 0);
  }

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)showCloneOptionsForApp:(TSAppInfo *)app cloneId:(NSString *)cloneId {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"分身 %@", cloneId]
                       message:nil
                preferredStyle:UIAlertControllerStyleActionSheet];

  [alert addAction:
             [UIAlertAction
                 actionWithTitle:@"⚙️ 配置设备伪装"
                           style:UIAlertActionStyleDefault
                         handler:^(UIAlertAction *action) {
                           // 配置分身的设备伪装
                           ECDeviceInfoViewController *vc =
                               [[ECDeviceInfoViewController alloc]
                                   initWithStyle:UITableViewStyleGrouped];
                           vc.isEditingMode = YES;

                           // 路径:
                           // .../ECSpoof/{bundleId}/clone_{cloneId}/device.plist
                           NSString *baseDir =
                               @"/var/mobile/Documents/.com.apple.UIKit.pboard";
                           NSString *appDir =
                               [baseDir stringByAppendingPathComponent:
                                            app.bundleIdentifier];
                           NSString *cloneDir = [appDir
                               stringByAppendingPathComponent:
                                   [NSString stringWithFormat:@"session_%@",
                                                              cloneId]];
                           vc.targetConfigPath = [cloneDir
                               stringByAppendingPathComponent:
                                   @"com.apple.preferences.display.plist"];

                           [self.navigationController pushViewController:vc
                                                                animated:YES];
                         }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"🚀 启动分身"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction *action) {
                                            [self launchClone:cloneId
                                                       forApp:app];
                                          }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"🗑️ 删除分身"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            [self deleteClone:cloneId
                                                       forApp:app];
                                          }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  // iPad fix
  if (alert.popoverPresentationController) {
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect =
        CGRectMake(self.view.center.x, self.view.center.y, 0, 0);
  }

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)createCloneForApp:(TSAppInfo *)app {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"创建分身"
                                          message:@"输入分身 ID（数字或字母）"
                                   preferredStyle:UIAlertControllerStyleAlert];

  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"例如: 1, 2, work, game";
  }];

  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"创建"
                        style:UIAlertActionStyleDefault
                      handler:^(UIAlertAction *action) {
                        NSString *cloneId = alert.textFields.firstObject.text;
                        if (cloneId.length > 0) {
                          NSError *error;
                          BOOL success = [[ECAppInjector sharedInstance]
                              createCloneConfigForApp:app.bundleIdentifier
                                              cloneId:cloneId
                                               config:@{}
                                                error:&error];

                          if (success) {
                            [self
                                showSuccessMessage:
                                    [NSString
                                        stringWithFormat:@"分身 %@ 创建成功！",
                                                         cloneId]];
                          } else {
                            [self showErrorMessage:error.localizedDescription
                                                       ?: @"创建失败"];
                          }
                        }
                      }]];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [self presentViewController:alert animated:YES completion:nil];
}

- (void)launchClone:(NSString *)cloneId forApp:(TSAppInfo *)app {
  // 1. 写入下次启动的分身标记
  NSString *baseDir = @"/var/mobile/Documents/.com.apple.UIKit.pboard";
  NSString *appDir =
      [baseDir stringByAppendingPathComponent:app.bundleIdentifier];
  NSString *launchFile =
      [appDir stringByAppendingPathComponent:@".com.apple.uikit.launchstate"];

  // 确保目录存在
  if (![[NSFileManager defaultManager] fileExistsAtPath:appDir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:appDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  NSError *error;
  [cloneId writeToFile:launchFile
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:&error];

  if (error) {
    [self showErrorMessage:[NSString
                               stringWithFormat:@"无法设置启动标记: %@",
                                                error.localizedDescription]];
    return;
  }

  // 2. 尝试启动应用
  [ECAppLauncher launchAppWithBundleIdentifier:app.bundleIdentifier
                                executablePath:nil];

  [self showManualLaunchAlertForApp:app cloneId:cloneId];
}

- (void)showManualLaunchAlertForApp:(TSAppInfo *)app
                            cloneId:(NSString *)cloneId {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"准备就绪"
                       message:[NSString stringWithFormat:
                                             @"已设置分身 %@ 为下次启动项。\n"
                                             @"正在尝试启动...",
                                             cloneId]
                preferredStyle:UIAlertControllerStyleAlert];

  [self presentViewController:alert animated:YES completion:nil];

  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [alert dismissViewControllerAnimated:YES completion:nil];
      });
}

- (void)deleteClone:(NSString *)cloneId forApp:(TSAppInfo *)app {
  NSError *error;
  BOOL success =
      [[ECAppInjector sharedInstance] deleteCloneForApp:app.bundleIdentifier
                                                cloneId:cloneId
                                                  error:&error];

  if (success) {
    [self showSuccessMessage:@"分身已删除"];
  } else {
    [self showErrorMessage:error.localizedDescription ?: @"删除失败"];
  }
}

- (void)showSuccessMessage:(NSString *)message {
  UIAlertController *alert =
      [UIAlertController alertControllerWithTitle:@"✅ 成功"
                                          message:message
                                   preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}


- (void)launchExtensionsSequentially:(NSArray<NSString *> *)names
                                    atIndex:(NSInteger)index
                                        app:(id)app
                                  autoAlert:(UIAlertController *)autoAlert
                              launchedCount:(int)launchedCount
                                 totalCount:(int)totalCount
                                 completion:(void (^)(void))completion {
  void (^writeLog)(NSString *) = ^(NSString *msg) {
    [[ECLogManager sharedManager]
        log:@"[NSExtensionSeq] %@", msg];
    ECDecryptLog(@"[NSExtensionSeq] %@", msg);
  };

  if (index >= names.count) {
    // 所有扩展已处理，等待最终稳定时间
    writeLog(@"所有扩展启动序列已发出，等待 5 秒确保进程稳定...");
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [autoAlert dismissViewControllerAnimated:YES
                                        completion:^{
                                          if (completion)
                                            completion();
                                        }];
        });
    return;
  }

  NSString *extFileName = names[index];
  NSString *plugInsPath =
      [[app bundlePath] stringByAppendingPathComponent:@"PlugIns"];
  NSString *extPath =
      [plugInsPath stringByAppendingPathComponent:extFileName];
  NSDictionary *extInfo = [NSDictionary
      dictionaryWithContentsOfFile:[extPath
                                       stringByAppendingPathComponent:
                                           @"Info.plist"]];
  NSString *realBundleID = extInfo[@"CFBundleIdentifier"];

  if (!realBundleID) {
    writeLog(
        [NSString stringWithFormat:@"无法获取扩展 Bundle ID: %@", extFileName]);
    [self launchExtensionsSequentially:names
                               atIndex:index + 1
                                   app:app
                             autoAlert:autoAlert
                         launchedCount:launchedCount + 1
                            totalCount:totalCount
                            completion:completion];
    return;
  }

  // 检查扩展类型 — 某些类型（iMessage、Widget 等）无法被第三方 app 作为 host 启动，
  // 调用 beginExtensionRequestWithInputItems: 会导致框架内部异步抛出
  // NSInvalidArgumentException (key cannot be nil) 崩溃。
  NSDictionary *nsExtension = extInfo[@"NSExtension"];
  NSString *extensionPointID = nsExtension[@"NSExtensionPointIdentifier"];

  // 这些扩展类型需要特定宿主 app，第三方 app 无法安全启动
  static NSSet *unsafeExtensionPoints = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    unsafeExtensionPoints = [NSSet setWithArray:@[
      @"com.apple.message-payload-provider",     // iMessage
      @"com.apple.messages.MSMessageExtension",  // iMessage (旧)
      @"com.apple.widgetkit-extension",          // WidgetKit
      @"com.apple.widget-extension",             // Today Widget
      @"com.apple.broadcast-services-upload",    // Broadcast Upload
      @"com.apple.broadcast-services-setupui",   // Broadcast Setup UI
      @"com.apple.intents-service",              // Intents (Siri)
      @"com.apple.intents-ui-service",           // Intents UI
    ]];
  });

  BOOL isUnsafe = extensionPointID &&
                  [unsafeExtensionPoints containsObject:extensionPointID];

  if (isUnsafe) {
    // 计算扩展实际二进制路径 (用于 posix_spawn 回退方案)
    NSString *extExecName = extInfo[@"CFBundleExecutable"] ?: [extFileName stringByDeletingPathExtension];
    NSString *extBinaryPath = [extPath stringByAppendingPathComponent:extExecName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:extBinaryPath]) {
      extBinaryPath = nil;
    }
    writeLog([NSString stringWithFormat:
        @"[%ld/%ld] 不兼容扩展，使用安全启动: %@ (type: %@)",
        (long)index + 1, (long)totalCount, extFileName, extensionPointID]);
    [self launchUnsafeExtensionWithBundleIdentifier:realBundleID
                                extensionBinaryPath:extBinaryPath
                                         completion:^(BOOL success) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (success) {
          writeLog([NSString stringWithFormat:@"安全启动成功: %@", realBundleID]);
        } else {
          writeLog([NSString stringWithFormat:@"安全启动失败: %@，将跳过该扩展脱壳",
                                              realBundleID]);
        }
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              [self launchExtensionsSequentially:names
                                       atIndex:index + 1
                                           app:app
                                     autoAlert:autoAlert
                                 launchedCount:launchedCount + (success ? 1 : 0)
                                    totalCount:totalCount
                                    completion:completion];
            });
      });
    }];
    return;
  }

  writeLog([NSString stringWithFormat:@"[%ld/%ld] 正在启动扩展: %@ (%@)...",
                                      (long)index + 1, (long)totalCount,
                                      extFileName, realBundleID]);

  [self launchAppExtensionWithBundleIdentifier:realBundleID
                                    completion:^(BOOL success) {
                                      dispatch_async(
                                          dispatch_get_main_queue(), ^{
                                            if (success) {
                                              writeLog([NSString
                                                  stringWithFormat:
                                                      @"成功启动扩展: %@",
                                                      realBundleID]);
                                            } else {
                                              writeLog([NSString
                                                  stringWithFormat:
                                                      @"启动扩展失败: %@",
                                                      realBundleID]);
                                            }

                                            // 成功或失败都继续下一个，但延迟 1.5 秒确保系统进程服务不拥堵
                                            dispatch_after(
                                                dispatch_time(DISPATCH_TIME_NOW,
                                                              (int64_t)(1.5 *
                                                                        NSEC_PER_SEC)),
                                                dispatch_get_main_queue(), ^{
                                                  [self
                                                      launchExtensionsSequentially:
                                                          names
                                                                           atIndex:
                                                                               index +
                                                                               1
                                                                               app:app
                                                                         autoAlert:
                                                                             autoAlert
                                                                     launchedCount:
                                                                         launchedCount +
                                                                         1
                                                                        totalCount:
                                                                            totalCount
                                                                        completion:
                                                                            completion];
                                                });
                                          });
                                    }];
}
@end
