#import <Foundation/Foundation.h>
#import "TSListControllerShared.h"
#import "TSPresentationDelegate.h"
#import "TSUtil.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>

@interface TSListControllerShared () <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) void (^downloadCompletionHandler)(NSString *);
@property(nonatomic, strong) NSURLSession *downloadSession;
@end

@implementation TSListControllerShared

- (BOOL)isTrollStore {
  return YES;
}

- (NSString *)getTrollStoreVersion {
  if ([self isTrollStore]) {
    return [NSBundle.mainBundle
               objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
               ?: [NSBundle.mainBundle
                      objectForInfoDictionaryKey:@"CFBundleVersion"];
  } else {
    NSString *trollStorePath = trollStoreAppPath();
    if (!trollStorePath)
      return nil;

    NSString *plistPath =
        [trollStorePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoDict =
        [NSDictionary dictionaryWithContentsOfFile:plistPath];

    if (!infoDict)
      return nil;

    return infoDict[@"CFBundleShortVersionString"]
               ?: infoDict[@"CFBundleVersion"];
  }
}

- (void)downloadTrollStoreAndRun:
    (void (^)(NSString *localTrollStoreTarPath))doHandler {
        
  // 检测是否有内嵌的原包
  NSString *bundlePath = [NSBundle mainBundle].bundlePath;
  NSString *localPayloadPath = [bundlePath stringByAppendingPathComponent:@"ecmain.tar"];
  NSString *localWdaPath = [bundlePath stringByAppendingPathComponent:@"ecwda.ipa"];
  
  BOOL hasMain = [[NSFileManager defaultManager] fileExistsAtPath:localPayloadPath];

  if (!hasMain) {
      // 本地无包，直接走网络下载逻辑
      [self _showOnlineDownloadPromptWithHandler:doHandler];
      return;
  }

  // 有本地包，直接走离线安装（不弹任何诊断或选择弹窗）
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      BOOL wdaExists = [[NSFileManager defaultManager] fileExistsAtPath:localWdaPath];
      
      if (wdaExists) {
          dispatch_async(dispatch_get_main_queue(), ^{
              // 将 ecwda.ipa 复制到临时目录供分享面板使用
              NSString *ipaTmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ecwda_export.ipa"];
              [[NSFileManager defaultManager] removeItemAtPath:ipaTmpPath error:nil];
              [[NSFileManager defaultManager] copyItemAtPath:localWdaPath toPath:ipaTmpPath error:nil];
              
              NSURL *ipaURL = [NSURL fileURLWithPath:ipaTmpPath];
              UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:@[ipaURL] applicationActivities:nil];
              
              // iPad 适配
              if ([activityVC respondsToSelector:@selector(popoverPresentationController)] && activityVC.popoverPresentationController) {
                  if ([self respondsToSelector:@selector(view)]) {
                      activityVC.popoverPresentationController.sourceView = [(UIViewController *)self view];
                      activityVC.popoverPresentationController.sourceRect = CGRectMake([(UIViewController *)self view].bounds.size.width / 2, [(UIViewController *)self view].bounds.size.height / 2, 0, 0);
                  }
              }
              
              // 分享面板关闭后，自动继续部署 ECMAIN
              activityVC.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed, NSArray *returnedItems, NSError *activityError) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                      [TSPresentationDelegate startActivity:@"正在部署控制核(ECMAIN)..."];
                      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                          NSString *tarTmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TrollStore.tar"];
                          [[NSFileManager defaultManager] removeItemAtPath:tarTmpPath error:nil];
                          [[NSFileManager defaultManager] copyItemAtPath:localPayloadPath toPath:tarTmpPath error:nil];
                          dispatch_async(dispatch_get_main_queue(), ^{
                              if (doHandler) doHandler(tarTmpPath);
                          });
                      });
                  });
              };
              
              // 直接弹出分享面板
              [TSPresentationDelegate presentViewController:activityVC animated:YES completion:nil];
          });
      } else {
          // ecwda.ipa 不存在，跳过直接安装 ECMAIN
          dispatch_async(dispatch_get_main_queue(), ^{
              [TSPresentationDelegate startActivity:@"正在部署控制核(ECMAIN)..."];
          });
          NSString *tarTmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TrollStore.tar"];
          [[NSFileManager defaultManager] removeItemAtPath:tarTmpPath error:nil];
          [[NSFileManager defaultManager] copyItemAtPath:localPayloadPath toPath:tarTmpPath error:nil];
          dispatch_async(dispatch_get_main_queue(), ^{
              if (doHandler) doHandler(tarTmpPath);
          });
      }
  });
}


- (void)_showOnlineDownloadPromptWithHandler:(void (^)(NSString *localTrollStoreTarPath))doHandler {
  // 弹出输入框让用户输入 URL
  UIAlertController *inputAlert = [UIAlertController
      alertControllerWithTitle:@"安装配置"
                       message:@"请输入 ECMAIN 下载地址 (tar)"
                preferredStyle:UIAlertControllerStyleAlert];
  [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"http://...";
    textField.text = @"http://tar.ecmain.site:8010/ecmain.tar"; // Default
  }];

  UIAlertAction *installAction = [UIAlertAction
      actionWithTitle:@"安装 (Install)"
                style:UIAlertActionStyleDefault
              handler:^(UIAlertAction *action) {
                NSString *urlStr = inputAlert.textFields.firstObject.text;
                if (!urlStr || urlStr.length == 0)
                  return;

                NSURL *trollStoreURL = [NSURL URLWithString:urlStr];

                [TSPresentationDelegate startActivity:@"准备下载..."];

                self.downloadCompletionHandler = doHandler;

                NSURLSessionConfiguration *configuration =
                    [NSURLSessionConfiguration defaultSessionConfiguration];
                self.downloadSession =
                    [NSURLSession sessionWithConfiguration:configuration
                                                  delegate:self
                                             delegateQueue:nil];

                NSURLSessionDownloadTask *downloadTask =
                    [self.downloadSession downloadTaskWithURL:trollStoreURL];
                [downloadTask resume];
              }];

  [inputAlert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
  [inputAlert addAction:installAction];

  [TSPresentationDelegate presentViewController:inputAlert
                                       animated:YES
                                     completion:nil];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
  float progress = 0.0f;
  if (totalBytesExpectedToWrite > 0) {
    progress = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    if (totalBytesExpectedToWrite > 0) {
      [TSPresentationDelegate
          startActivity:[NSString stringWithFormat:@"下载中: %.0f%%",
                                                   progress * 100]];
    } else {
      [TSPresentationDelegate
          startActivity:[NSString stringWithFormat:@"下载中 (%.1f MB)...",
                                                   (float)totalBytesWritten /
                                                       1024.0f / 1024.0f]];
    }
  });
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
    didFinishDownloadingToURL:(NSURL *)location {
  // 移动到临时目录
  NSString *tarTmpPath =
      [NSTemporaryDirectory() stringByAppendingPathComponent:@"TrollStore.tar"];
  [[NSFileManager defaultManager] removeItemAtPath:tarTmpPath error:nil];
  [[NSFileManager defaultManager] copyItemAtPath:location.path
                                          toPath:tarTmpPath
                                           error:nil];

  dispatch_async(dispatch_get_main_queue(), ^{
    // 下载完成，开始安装
    [TSPresentationDelegate startActivity:@"下载完成，开始安装..."];
    if (self.downloadCompletionHandler) {
      self.downloadCompletionHandler(tarTmpPath);
    }
    [self.downloadSession finishTasksAndInvalidate];
  });
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  if (error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      UIAlertController *errorAlert = [UIAlertController
          alertControllerWithTitle:@"下载失败"
                           message:[NSString
                                       stringWithFormat:
                                           @"错误信息: %@\n(请检查 URL 或网络)",
                                           error.localizedDescription]
                    preferredStyle:UIAlertControllerStyleAlert];
      [errorAlert
          addAction:[UIAlertAction actionWithTitle:@"关闭"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];

      [TSPresentationDelegate stopActivityWithCompletion:^{
        [TSPresentationDelegate presentViewController:errorAlert
                                             animated:YES
                                           completion:nil];
      }];
    });
    [self.downloadSession finishTasksAndInvalidate];
  }
}

- (void)_installTrollStoreComingFromUpdateFlow:(BOOL)update {
  // Removed startActivity to allow Input Alert to show
  [self downloadTrollStoreAndRun:^(NSString *tmpTarPath) {
    NSString *stdErr = nil;
    int ret = spawnRoot(rootHelperPath(),
                        @[ @"install-trollstore", tmpTarPath ], nil, &stdErr);
    [[NSFileManager defaultManager] removeItemAtPath:tmpTarPath error:nil];

    if (ret == 0) {
      // System-level respring: kill backboardd instead of SpringBoard
      killall(@"backboardd", YES);

      if ([self isTrollStore]) {
        exit(0);
      } else {
        dispatch_async(dispatch_get_main_queue(), ^{
          [TSPresentationDelegate stopActivityWithCompletion:^{
            [self reloadSpecifiers];
          }];
        });
      }
    } else {
      dispatch_async(dispatch_get_main_queue(), ^{
        [TSPresentationDelegate stopActivityWithCompletion:^{
          UIAlertController *errorAlert = [UIAlertController
              alertControllerWithTitle:@"安装失败 (Fail)"
                               message:[NSString
                                           stringWithFormat:
                                               @"Trollhelper returned error "
                                               @"code: %d\n\nStderr:\n%@",
                                               ret,
                                               stdErr ?: @"(No stderr output)"]
                        preferredStyle:UIAlertControllerStyleAlert];
          UIAlertAction *closeAction =
              [UIAlertAction actionWithTitle:@"Close"
                                       style:UIAlertActionStyleDefault
                                     handler:nil];
          [errorAlert addAction:closeAction];
          [TSPresentationDelegate presentViewController:errorAlert
                                               animated:YES
                                             completion:nil];
        }];
      });
    }
  }];
}

- (void)installTrollStorePressed {
  [self _installTrollStoreComingFromUpdateFlow:NO];
}

- (void)updateTrollStorePressed {
  [self _installTrollStoreComingFromUpdateFlow:YES];
}

- (void)rebuildIconCachePressed {
  [TSPresentationDelegate startActivity:@"Rebuilding Icon Cache"];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   spawnRoot(rootHelperPath(), @[ @"refresh-all" ], nil, nil);

                   dispatch_async(dispatch_get_main_queue(), ^{
                     [TSPresentationDelegate stopActivityWithCompletion:nil];
                   });
                 });
}

- (void)refreshAppRegistrationsPressed {
  [TSPresentationDelegate startActivity:@"Refreshing"];

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   spawnRoot(rootHelperPath(), @[ @"refresh" ], nil, nil);
                   respring();

                   dispatch_async(dispatch_get_main_queue(), ^{
                     [TSPresentationDelegate stopActivityWithCompletion:nil];
                   });
                 });
}

- (void)uninstallPersistenceHelperPressed {
  if ([self isTrollStore]) {
    spawnRoot(rootHelperPath(), @[ @"uninstall-persistence-helper" ], nil, nil);
    [self reloadSpecifiers];
  } else {
    UIAlertController *uninstallWarningAlert = [UIAlertController
        alertControllerWithTitle:@"Warning"
                         message:@"Uninstalling the persistence helper will "
                                 @"revert this app back to it's original "
                                 @"state, you will however no longer be able "
                                 @"to persistently refresh the TrollStore app "
                                 @"registrations. Continue?"
                  preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *cancelAction =
        [UIAlertAction actionWithTitle:@"Cancel"
                                 style:UIAlertActionStyleCancel
                               handler:nil];
    [uninstallWarningAlert addAction:cancelAction];

    UIAlertAction *continueAction = [UIAlertAction
        actionWithTitle:@"Continue"
                  style:UIAlertActionStyleDestructive
                handler:^(UIAlertAction *action) {
                  spawnRoot(rootHelperPath(),
                            @[ @"uninstall-persistence-helper" ], nil, nil);
                  exit(0);
                }];
    [uninstallWarningAlert addAction:continueAction];

    [TSPresentationDelegate presentViewController:uninstallWarningAlert
                                         animated:YES
                                       completion:nil];
  }
}

- (void)handleUninstallation {
  if ([self isTrollStore]) {
    exit(0);
  } else {
    [self reloadSpecifiers];
  }
}

- (NSMutableArray *)argsForUninstallingTrollStore {
  return @[ @"uninstall-trollstore" ].mutableCopy;
}

- (void)uninstallTrollStorePressed {
  UIAlertController *uninstallAlert = [UIAlertController
      alertControllerWithTitle:@"卸载 (Uninstall)"
                       message:@"您即将卸载 "
                               @"ECMAIN，是否保留通过它安装的应用？"
                preferredStyle:UIAlertControllerStyleAlert];

  void (^handleUninstall)(BOOL) = ^(BOOL preserveApps) {
    NSMutableArray *args = [self argsForUninstallingTrollStore];
    if (preserveApps) {
      [args addObject:@"preserve-apps"];
    }

    [TSPresentationDelegate startActivity:@"正在卸载..."];

    dispatch_async(
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
          NSString *stdErr = nil;
          NSString *stdOut = nil;
          int ret = spawnRoot(rootHelperPath(), args, &stdOut, &stdErr);

          dispatch_async(dispatch_get_main_queue(), ^{
            [TSPresentationDelegate stopActivityWithCompletion:^{
              if (ret == 0) {
                [self handleUninstallation];
              } else {
                UIAlertController *errAlert = [UIAlertController
                    alertControllerWithTitle:@"卸载失败"
                                     message:[NSString stringWithFormat:
                                                           @"错误代码: "
                                                           @"%d\n\nStderr:\n%@"
                                                           @"\n\nStdout:\n%@",
                                                           ret, stdErr, stdOut]
                              preferredStyle:UIAlertControllerStyleAlert];
                [errAlert
                    addAction:[UIAlertAction
                                  actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
                [self presentViewController:errAlert
                                   animated:YES
                                 completion:nil];
              }
            }];
          });
        });
  };

  UIAlertAction *uninstallAllAction =
      [UIAlertAction actionWithTitle:@"卸载 ECMAIN 并删除应用"
                               style:UIAlertActionStyleDestructive
                             handler:^(UIAlertAction *action) {
                               handleUninstall(NO);
                             }];
  [uninstallAlert addAction:uninstallAllAction];

  UIAlertAction *preserveAppsAction =
      [UIAlertAction actionWithTitle:@"卸载 ECMAIN 但保留应用"
                               style:UIAlertActionStyleDestructive
                             handler:^(UIAlertAction *action) {
                               handleUninstall(YES);
                             }];
  [uninstallAlert addAction:preserveAppsAction];

  UIAlertAction *cancelAction =
      [UIAlertAction actionWithTitle:@"取消"
                               style:UIAlertActionStyleCancel
                             handler:nil];
  [uninstallAlert addAction:cancelAction];

  [TSPresentationDelegate presentViewController:uninstallAlert
                                       animated:YES
                                     completion:nil];
}

@end