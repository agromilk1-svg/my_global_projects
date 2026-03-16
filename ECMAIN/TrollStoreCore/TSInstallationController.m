#import "TSInstallationController.h"
#import <UIKit/UIKit.h>

// #import "../ECMAIN/Core/ECLogManager.h"

#import "TSAppInfo.h"
#import "TSApplicationsManager.h"
#import "TSPresentationDelegate.h"
#import "TSUtil.h"
#import "ZipWriter.h"

extern NSUserDefaults *trollStoreUserDefaults(void);

@implementation TSInstallationController

// Helper to bridge logs to ECLogManager via Notification
static void TSLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  NSLog(@"%@", msg); // Keep system console log
  [[NSNotificationCenter defaultCenter]
      postNotificationName:@"TSLogNotification"
                    object:msg];
}

#pragma mark - SC_Info Injection Helper

// 尝试注入 SC_Info 到 IPA，返回注入后的 IPA
// 路径（如果成功）或原路径（如果不需要注入）
+ (NSString *)injectSCInfoIntoIPAIfNeeded:(NSString *)pathToIPA {
  TSLog(@"[SC_Info] 检查是否需要注入 SC_Info...");

  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *docsDir = [NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
  NSString *scInfoExportDir =
      [docsDir stringByAppendingPathComponent:@"SC_Info_Export"];

  // 如果没有 SC_Info 导出目录，直接返回原路径
  if (![fm fileExistsAtPath:scInfoExportDir]) {
    TSLog(@"[SC_Info] 无 SC_Info_Export 目录，跳过注入");
    return pathToIPA;
  }

  // 解压 IPA 到临时目录
  NSString *tempDir = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"SCInfoInject_%@",
                                                          [[NSUUID UUID]
                                                              UUIDString]]];
  NSString *payloadDir = [tempDir stringByAppendingPathComponent:@"Payload"];

  TSLog(@"[SC_Info] 解压 IPA 到临时目录: %@", tempDir);

  // 使用 unzip 命令解压
  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int unzipResult =
      spawnRoot(@"/usr/bin/unzip", @[ @"-o", @"-q", pathToIPA, @"-d", tempDir ],
                &stdOut, &stdErr);

  if (unzipResult != 0) {
    TSLog(@"[SC_Info] 解压失败 (exit=%d): %@", unzipResult, stdErr);
    // 解压失败，返回原路径
    [fm removeItemAtPath:tempDir error:nil];
    return pathToIPA;
  }

  // 查找 .app 目录
  NSArray *payloadContents = [fm contentsOfDirectoryAtPath:payloadDir
                                                     error:nil];
  NSString *appDir = nil;
  for (NSString *item in payloadContents) {
    if ([item hasSuffix:@".app"]) {
      appDir = [payloadDir stringByAppendingPathComponent:item];
      break;
    }
  }

  if (!appDir) {
    TSLog(@"[SC_Info] 未找到 .app 目录");
    [fm removeItemAtPath:tempDir error:nil];
    return pathToIPA;
  }

  // 读取 Info.plist 获取 bundleId
  NSString *infoPlistPath =
      [appDir stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *infoPlist =
      [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
  NSString *bundleId = infoPlist[@"CFBundleIdentifier"];

  if (!bundleId) {
    TSLog(@"[SC_Info] 无法读取 bundleId");
    [fm removeItemAtPath:tempDir error:nil];
    return pathToIPA;
  }

  TSLog(@"[SC_Info] Bundle ID: %@", bundleId);

  // 检查是否有对应的 SC_Info
  NSString *scInfoSource =
      [scInfoExportDir stringByAppendingPathComponent:bundleId];
  if (![fm fileExistsAtPath:scInfoSource]) {
    TSLog(@"[SC_Info] 未找到 %@ 的 SC_Info，跳过注入", bundleId);
    [fm removeItemAtPath:tempDir error:nil];
    return pathToIPA;
  }

  // 检查源目录中是否有 sinf 文件
  NSArray *scInfoFiles = [fm contentsOfDirectoryAtPath:scInfoSource error:nil];
  BOOL hasSinf = NO;
  for (NSString *file in scInfoFiles) {
    if ([file hasSuffix:@".sinf"] || [file hasSuffix:@".supf"]) {
      hasSinf = YES;
      break;
    }
  }

  if (!hasSinf) {
    TSLog(@"[SC_Info] SC_Info 目录中无 sinf/supf 文件");
    [fm removeItemAtPath:tempDir error:nil];
    return pathToIPA;
  }

  // 删除现有 SC_Info 目录（如果存在）
  NSString *targetSCInfo = [appDir stringByAppendingPathComponent:@"SC_Info"];
  if ([fm fileExistsAtPath:targetSCInfo]) {
    [fm removeItemAtPath:targetSCInfo error:nil];
  }

  // 复制 SC_Info
  NSError *error = nil;
  if (![fm copyItemAtPath:scInfoSource toPath:targetSCInfo error:&error]) {
    TSLog(@"[SC_Info] 复制 SC_Info 失败: %@", error);
    [fm removeItemAtPath:tempDir error:nil];
    return pathToIPA;
  }

  TSLog(@"[SC_Info] ✅ 成功注入 SC_Info！");

  // 重新打包 IPA
  NSString *newIpaPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"injected_%@.ipa",
                                                          [[NSUUID UUID]
                                                              UUIDString]]];

  TSLog(@"[SC_Info] 重新打包 IPA: %@", newIpaPath);

  NSError *zipError = nil;
  BOOL zipSuccess = [ZipWriter createZipAtPath:newIpaPath
                             fromDirectoryPath:tempDir
                                         error:&zipError];

  // 清理临时目录
  [fm removeItemAtPath:tempDir error:nil];

  if (!zipSuccess) {
    TSLog(@"[SC_Info] 打包失败: %@", zipError);
    return pathToIPA;
  }

  TSLog(@"[SC_Info] ✅ IPA 打包成功，使用新 IPA 安装");
  return newIpaPath;
}

// Internal method to perform the actual install
+ (void)_performAppInstallFromFile:(NSString *)pathToIPA
                      forceInstall:(BOOL)force
                  registrationType:(NSString *)registrationType
                    customBundleId:(NSString *)customBundleId
                 customDisplayName:(NSString *)customDisplayName
                       skipSigning:(BOOL)skipSigning
                installationMethod:(int)installationMethod
                        completion:(void (^)(BOOL, NSError *))completionBlock {
  TSLog(@"[安装服务] 请求安装: %@", pathToIPA.lastPathComponent);
  if (skipSigning) {
    TSLog(@"[安装服务] 🔐 加密应用模式 - 跳过签名以保留 FairPlay 加密");
  }

  // ===== SC_Info 注入 =====
  // 尝试注入 SC_Info（如果有匹配的导出）
  NSString *actualIPAPath = [self injectSCInfoIntoIPAIfNeeded:pathToIPA];
  NSString *injectedTempPath = nil;
  if (![actualIPAPath isEqualToString:pathToIPA]) {
    TSLog(@"[安装服务] 使用注入 SC_Info 后的 IPA");
    injectedTempPath = actualIPAPath; // 记录临时文件，安装后清理
  }
  // ===== SC_Info 注入结束 =====

  if (registrationType) {
    TSLog(@"[安装服务] 注册类型: %@", registrationType);
  }
  if (customBundleId) {
    TSLog(@"[安装服务] 自定义包名: %@", customBundleId);
  }
  if (customDisplayName) {
    TSLog(@"[安装服务] 自定义名称: %@", customDisplayName);
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [TSPresentationDelegate
        startActivity:skipSigning ? @"安装加密应用中" : @"安装中"];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      // Install IPA (使用可能注入了 SC_Info 的路径)
      NSString *log;
      int ret =
          [[TSApplicationsManager sharedInstance] installIpa:actualIPAPath
                                                       force:force
                                            registrationType:registrationType
                                              customBundleId:customBundleId
                                           customDisplayName:customDisplayName
                                                 skipSigning:skipSigning
                                          installationMethod:installationMethod
                                                         log:&log];

      // 清理注入后的临时 IPA
      if (injectedTempPath) {
        TSLog(@"[SC_Info] 清理临时 IPA: %@", injectedTempPath);
        [[NSFileManager defaultManager] removeItemAtPath:injectedTempPath
                                                   error:nil];
      }

      NSError *error;
      if (ret != 0) {
        error = [[TSApplicationsManager sharedInstance] errorForCode:ret];
        TSLog(@"[安装服务] 安装失败 (code %d): %@", ret, error);
        if (log) {
          TSLog(@"[安装服务] 详细日志:\n%@", log);
        }
      } else {
        TSLog(@"[安装服务] 安装成功!");
        if (log) {
          TSLog(@"[安装服务] 详细日志 (Success):\n%@", log);
        }

        // ---------------------------
      }

      dispatch_async(dispatch_get_main_queue(), ^{
        [TSPresentationDelegate stopActivityWithCompletion:^{
          if (ret == 0) {
            // success
            if (completionBlock)
              completionBlock(YES, nil);
          } else if (ret == 171) {
            // recoverable error
            NSLog(@"[安装服务] 遇到可恢复错误 (171)");
            // ... (alerts)
            UIAlertController *errorAlert = [UIAlertController
                alertControllerWithTitle:[NSString
                                             stringWithFormat:@"安装错误 %d",
                                                              ret]
                                 message:[error localizedDescription]
                          preferredStyle:UIAlertControllerStyleAlert];
            // ... (actions)
            UIAlertAction *closeAction =
                [UIAlertAction actionWithTitle:@"关闭"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *action) {
                                         if (completionBlock)
                                           completionBlock(NO, error);
                                       }];
            [errorAlert addAction:closeAction];

            UIAlertAction *forceInstallAction = [UIAlertAction
                actionWithTitle:@"Force Installation"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                          NSLog(@"[安装服务] 用户选择强制安装");
                          [self handleAppInstallFromFile:pathToIPA
                                            forceInstall:YES
                                              completion:completionBlock];
                        }];
            [errorAlert addAction:forceInstallAction];

            [TSPresentationDelegate presentViewController:errorAlert
                                                 animated:YES
                                               completion:nil];
          } else if (ret == 182) {
            // non-fatal informative message (Reboot required)
            NSLog(@"[安装服务] 需要重启生效 (182)");
            UIAlertController *rebootNotification = [UIAlertController
                alertControllerWithTitle:@"需要重启"
                                 message:[error localizedDescription]
                          preferredStyle:UIAlertControllerStyleAlert];
            // ... (actions)
            UIAlertAction *closeAction =
                [UIAlertAction actionWithTitle:@"关闭"
                                         style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action) {
                                         if (completionBlock)
                                           completionBlock(YES, nil);
                                       }];
            [rebootNotification addAction:closeAction];

            UIAlertAction *rebootAction = [UIAlertAction
                actionWithTitle:@"立即重启"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                          if (completionBlock)
                            completionBlock(YES, nil);
                          spawnRoot(rootHelperPath(), @[ @"reboot" ], nil, nil);
                        }];
            [rebootNotification addAction:rebootAction];

            [TSPresentationDelegate presentViewController:rebootNotification
                                                 animated:YES
                                               completion:nil];
          } else if (ret == 180) {
            NSLog(@"[安装服务] 加密应用无法安装 (180)");
            UIAlertController *encryptedAlert = [UIAlertController
                alertControllerWithTitle:@"无法安装"
                                 message:@"该 IPA 的主二进制文件已加密 "
                                         @"(Encrypted)。\nTrollStore 无法安装 "
                                         @"App Store 加密应用，请先解密 "
                                         @"(Decrypted) 后再试。"
                          preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *okAction =
                [UIAlertAction actionWithTitle:@"明白了"
                                         style:UIAlertActionStyleDefault
                                       handler:^(UIAlertAction *action) {
                                         if (completionBlock)
                                           completionBlock(NO, error);
                                       }];
            [encryptedAlert addAction:okAction];
            [TSPresentationDelegate presentViewController:encryptedAlert
                                                 animated:YES
                                               completion:nil];

          } else if (ret == 173 || ret == 175) {
            NSLog(@"[安装服务] 签名错误 (173/175)");
            UIAlertController *signAlert = [UIAlertController
                alertControllerWithTitle:@"签名组件错误"
                                 message:
                                     [NSString
                                         stringWithFormat:
                                             @"%@"
                                             @"\n建议尝试“修复签名组件”功能。",
                                             [error localizedDescription]]
                          preferredStyle:UIAlertControllerStyleAlert];

            UIAlertAction *repairAction = [UIAlertAction
                actionWithTitle:@"立即修复"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                          [self _installLdidWithCompletion:^(BOOL success) {
                            // Retry or just info
                            if (!success) {
                              // Show fail
                            }
                          }];
                          if (completionBlock)
                            completionBlock(NO, error);
                        }];
            [signAlert addAction:repairAction];

            UIAlertAction *cancelAction =
                [UIAlertAction actionWithTitle:@"取消"
                                         style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action) {
                                         if (completionBlock)
                                           completionBlock(NO, error);
                                       }];
            [signAlert addAction:cancelAction];

            [TSPresentationDelegate presentViewController:signAlert
                                                 animated:YES
                                               completion:nil];
          } else if (ret == 184) {
            NSLog(@"[安装服务] 警告 (184): %@", error);
            // warning
            UIAlertController *warningAlert = [UIAlertController
                alertControllerWithTitle:@"警告"
                                 message:[error localizedDescription]
                          preferredStyle:UIAlertControllerStyleAlert];
            // ...
            UIAlertAction *closeAction =
                [UIAlertAction actionWithTitle:@"关闭"
                                         style:UIAlertActionStyleCancel
                                       handler:^(UIAlertAction *action) {
                                         if (completionBlock)
                                           completionBlock(YES, nil);
                                       }];
            [warningAlert addAction:closeAction];

            [TSPresentationDelegate presentViewController:warningAlert
                                                 animated:YES
                                               completion:nil];
          } else {
            // unrecoverable error (or 255)
            TSLog(@"[安装服务] 严重错误 (code %d): %@", ret, error);

            NSString *title = [NSString stringWithFormat:@"安装失败 (%d)", ret];
            NSString *msg = [error localizedDescription];

            // Detailed diagnosis for 255
            if (ret == 255) {
              title = @"签名组件异常 (Error 255)";
              msg = @"底层签名工具 (ldid) 或 helper "
                    @"进程意外退出。\n这通常是因为 ldid "
                    @"未正确安装或权限不足。\n建议：先点击“修复签名组件”，然后"
                    @"重试安装。";
            }

            UIAlertController *errorAlert = [UIAlertController
                alertControllerWithTitle:title
                                 message:msg
                          preferredStyle:UIAlertControllerStyleAlert];

            // Option 1: Close
            UIAlertAction *closeAction =
                [UIAlertAction actionWithTitle:@"关闭"
                                         style:UIAlertActionStyleCancel
                                       handler:nil];
            [errorAlert addAction:closeAction];

            // Option 2: Repair Ldid (Targeted fix for 255)
            UIAlertAction *repairLdidAction = [UIAlertAction
                actionWithTitle:@"修复签名组件 (Reinstall ldid)"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                          TSLog(@"[安装服务] 用户尝试修复签名组件 (ldid)...");
                          [self _installLdidWithCompletion:nil];

                          dispatch_after(
                              dispatch_time(DISPATCH_TIME_NOW,
                                            (int64_t)(1.0 * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                                UIAlertController *hint = [UIAlertController
                                    alertControllerWithTitle:@"正在修复"
                                                     message:
                                                         @"已触发 ldid "
                                                         @"重装任务，请等待几秒"
                                                         @"后再次尝试安装 IPA。"
                                              preferredStyle:
                                                  UIAlertControllerStyleAlert];
                                [hint
                                    addAction:
                                        [UIAlertAction
                                            actionWithTitle:@"OK"
                                                      style:
                                                          UIAlertActionStyleDefault
                                                    handler:nil]];
                                [TSPresentationDelegate
                                    presentViewController:hint
                                                 animated:YES
                                               completion:nil];
                              });
                        }];
            [errorAlert addAction:repairLdidAction];

            // Option 3: Force Install (Cache invalidation)
            UIAlertAction *forceAction = [UIAlertAction
                actionWithTitle:@"强制安装 (忽略缓存)"
                          style:UIAlertActionStyleDestructive
                        handler:^(UIAlertAction *action) {
                          TSLog(@"[安装服务] 用户选择强制安装");
                          [self handleAppInstallFromFile:pathToIPA
                                            forceInstall:YES
                                              completion:completionBlock];
                        }];
            [errorAlert addAction:forceAction];

            // Option 4: System Install (Fallback)
            UIAlertAction *systemAction = [UIAlertAction
                actionWithTitle:@"系统模式安装 (Installd)"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                          TSLog(@"[安装服务] 用户选择系统安装模式");
                          [trollStoreUserDefaults()
                              setObject:@(0)
                                 forKey:@"installationMethod"];
                          [trollStoreUserDefaults() synchronize];

                          [self
                              handleAppInstallFromFile:pathToIPA
                                          forceInstall:force
                                            completion:^(BOOL success,
                                                         NSError *err) {
                                              [trollStoreUserDefaults()
                                                  setObject:@(1)
                                                     forKey:
                                                         @"installationMethod"];
                                              [trollStoreUserDefaults()
                                                  synchronize];
                                              if (completionBlock)
                                                completionBlock(success, err);
                                            }];
                        }];
            [errorAlert addAction:systemAction];

            // Option 5: Copy Log
            UIAlertAction *copyLogAction = [UIAlertAction
                actionWithTitle:@"复制调试日志"
                          style:UIAlertActionStyleDefault
                        handler:^(UIAlertAction *action) {
                          UIPasteboard *pasteboard =
                              [UIPasteboard generalPasteboard];
                          pasteboard.string = log ?: @"(Empty Log)";
                        }];
            [errorAlert addAction:copyLogAction];

            [TSPresentationDelegate presentViewController:errorAlert
                                                 animated:YES
                                               completion:nil];

            if (completionBlock)
              completionBlock(NO, error);
          }
        }];
      });
    });
  });
}

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                      completion:(void (^)(BOOL, NSError *))completionBlock {
  [self handleAppInstallFromFile:pathToIPA
                    forceInstall:force
                registrationType:nil
                  customBundleId:nil
                      completion:completionBlock];
}

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
                      completion:(void (^)(BOOL, NSError *))completionBlock {
  [self handleAppInstallFromFile:pathToIPA
                    forceInstall:force
                registrationType:registrationType
                  customBundleId:customBundleId
               customDisplayName:nil
                      completion:completionBlock];
}

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
               customDisplayName:(NSString *)customDisplayName
                      completion:(void (^)(BOOL, NSError *))completionBlock {
  [self handleAppInstallFromFile:pathToIPA
                    forceInstall:force
                registrationType:registrationType
                  customBundleId:customBundleId
               customDisplayName:customDisplayName
                     skipSigning:NO
                      completion:completionBlock];
}

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
               customDisplayName:(NSString *)customDisplayName
                     skipSigning:(BOOL)skipSigning
                      completion:(void (^)(BOOL, NSError *))completionBlock {
  [self handleAppInstallFromFile:pathToIPA
                    forceInstall:force
                registrationType:registrationType
                  customBundleId:customBundleId
               customDisplayName:customDisplayName
                     skipSigning:skipSigning
              installationMethod:-1
                      completion:completionBlock];
}

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
               customDisplayName:(NSString *)customDisplayName
                     skipSigning:(BOOL)skipSigning
              installationMethod:(int)installationMethod
                      completion:(void (^)(BOOL, NSError *))completionBlock {
  // For encrypted apps (skipSigning=YES), skip ldid check
  if (skipSigning) {
    TSLog(@"[安装服务] 加密应用模式 - 跳过签名组件检查");
    [self _performAppInstallFromFile:pathToIPA
                        forceInstall:force
                    registrationType:registrationType
                      customBundleId:customBundleId
                   customDisplayName:customDisplayName
                         skipSigning:YES
                  installationMethod:installationMethod
                          completion:completionBlock];
    return;
  }

  // Check if ldid is installed
  if (!isLdidInstalled()) {
    TSLog(@"[安装服务] 检测到签名组件 (ldid) 缺失，正在自动修复...");
    [self _installLdidWithCompletion:^(BOOL success) {
      if (success) {
        TSLog(@"[安装服务] 自动修复成功，继续安装...");
      } else {
        TSLog(@"[安装服务] 自动修复失败，尝试继续安装...");
      }
      [self _performAppInstallFromFile:pathToIPA
                          forceInstall:force
                      registrationType:registrationType
                        customBundleId:customBundleId
                     customDisplayName:customDisplayName
                           skipSigning:NO
                    installationMethod:installationMethod
                            completion:completionBlock];
    }];
  } else {
    [self _performAppInstallFromFile:pathToIPA
                        forceInstall:force
                    registrationType:registrationType
                      customBundleId:customBundleId
                   customDisplayName:customDisplayName
                         skipSigning:NO
                  installationMethod:installationMethod
                          completion:completionBlock];
  }
}

+ (void)_installLdidWithCompletion:(void (^)(BOOL))completion {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. Locate ldid in bundle
        NSString *bundledLdidPath =
            [[NSBundle mainBundle] pathForResource:@"ldid" ofType:nil];

        // Fallback: Check bundle root directly (since we inject it manually)
        if (!bundledLdidPath) {
          bundledLdidPath = [[NSBundle mainBundle].bundlePath
              stringByAppendingPathComponent:@"ldid"];
        }

        if (!bundledLdidPath || ![[NSFileManager defaultManager]
                                    fileExistsAtPath:bundledLdidPath]) {
          NSLog(@"[安装服务] 静默安装 ldid 失败: 未找到包内文件 (path: %@)",
                bundledLdidPath);
          // Don't return, let it fail naturally or try anyway?
          // If we return here, we avoid 255 but we still fail.
          if (completion)
            completion(NO);
          return;
        }

        // 2. Install using helper
        NSString *version = @"2.1.5-pro";
        int ret =
            spawnRoot(rootHelperPath(),
                      @[ @"install-ldid", bundledLdidPath, version ], nil, nil);

        if (ret == 0) {
          NSLog(@"[安装服务] ldid 静默安装成功");
          dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:@"TrollStoreReloadSettingsNotification"
                              object:nil
                            userInfo:nil];
          });
          if (completion)
            completion(YES);
        } else {
          NSLog(@"[安装服务] ldid 静默安装失败, code: %d", ret);
          if (completion)
            completion(NO);
        }
      });
}

+ (void)presentInstallationAlertIfEnabledForFile:(NSString *)pathToIPA
                                 isRemoteInstall:(BOOL)remoteInstall
                                      completion:(void (^)(BOOL, NSError *))
                                                     completionBlock {
  NSNumber *installAlertConfigurationNum =
      [trollStoreUserDefaults() objectForKey:@"installAlertConfiguration"];
  NSUInteger installAlertConfiguration = 0;
  if (installAlertConfigurationNum) {
    installAlertConfiguration =
        installAlertConfigurationNum.unsignedIntegerValue;
    if (installAlertConfiguration > 2) {
      // broken pref? revert to 0
      installAlertConfiguration = 0;
    }
  }

  // Check if user disabled alert for this kind of install
  if (installAlertConfiguration > 0) {
    if (installAlertConfiguration == 2 ||
        (installAlertConfiguration == 1 && !remoteInstall)) {
      [self handleAppInstallFromFile:pathToIPA completion:completionBlock];
      return;
    }
  }

  TSAppInfo *appInfo = [[TSAppInfo alloc] initWithIPAPath:pathToIPA];
  [appInfo loadInfoWithCompletion:^(NSError *error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!error) {
        UIAlertController *installAlert = [UIAlertController
            alertControllerWithTitle:@""
                             message:@""
                      preferredStyle:UIAlertControllerStyleAlert];
        installAlert.attributedTitle = [appInfo detailedInfoTitle];
        installAlert.attributedMessage = [appInfo detailedInfoDescription];
        UIAlertAction *installAction = [UIAlertAction
            actionWithTitle:@"安装"
                      style:UIAlertActionStyleDefault
                    handler:^(UIAlertAction *action) {
                      [self handleAppInstallFromFile:pathToIPA
                                          completion:completionBlock];
                    }];
        [installAlert addAction:installAction];

        UIAlertAction *cancelAction =
            [UIAlertAction actionWithTitle:@"取消"
                                     style:UIAlertActionStyleCancel
                                   handler:^(UIAlertAction *action) {
                                     if (completionBlock)
                                       completionBlock(NO, nil);
                                   }];
        [installAlert addAction:cancelAction];

        [TSPresentationDelegate presentViewController:installAlert
                                             animated:YES
                                           completion:nil];
      } else {
        UIAlertController *errorAlert = [UIAlertController
            alertControllerWithTitle:[NSString stringWithFormat:@"解析错误 %ld",
                                                                error.code]
                             message:error.localizedDescription
                      preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *closeAction =
            [UIAlertAction actionWithTitle:@"Close"
                                     style:UIAlertActionStyleDefault
                                   handler:nil];
        [errorAlert addAction:closeAction];

        [TSPresentationDelegate presentViewController:errorAlert
                                             animated:YES
                                           completion:nil];
      }
    });
  }];
}

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                      completion:(void (^)(BOOL, NSError *))completionBlock {
  [self handleAppInstallFromFile:pathToIPA
                    forceInstall:NO
                      completion:completionBlock];
}

+ (void)handleAppInstallFromRemoteURL:(NSURL *)remoteURL
                           completion:
                               (void (^)(BOOL, NSError *))completionBlock {
  NSURLRequest *downloadRequest = [NSURLRequest requestWithURL:remoteURL];

  dispatch_async(dispatch_get_main_queue(), ^{
    NSURLSessionDownloadTask *downloadTask = [NSURLSession.sharedSession
        downloadTaskWithRequest:downloadRequest
              completionHandler:^(NSURL *location, NSURLResponse *response,
                                  NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                  [TSPresentationDelegate stopActivityWithCompletion:^{
                    if (error) {
                      UIAlertController *errorAlert = [UIAlertController
                          alertControllerWithTitle:@"错误"
                                           message:[NSString
                                                       stringWithFormat:
                                                           @"下载应用错误: %@",
                                                           error]
                                    preferredStyle:UIAlertControllerStyleAlert];
                      UIAlertAction *closeAction = [UIAlertAction
                          actionWithTitle:@"Close"
                                    style:UIAlertActionStyleDefault
                                  handler:nil];
                      [errorAlert addAction:closeAction];

                      [TSPresentationDelegate
                          presentViewController:errorAlert
                                       animated:YES
                                     completion:^{
                                       if (completionBlock)
                                         completionBlock(NO, error);
                                     }];
                    } else {
                      NSString *tmpIpaPath = [NSTemporaryDirectory()
                          stringByAppendingPathComponent:@"tmp.ipa"];
                      [[NSFileManager defaultManager]
                          removeItemAtPath:tmpIpaPath
                                     error:nil];
                      [[NSFileManager defaultManager]
                          moveItemAtPath:location.path
                                  toPath:tmpIpaPath
                                   error:nil];
                      [self
                          presentInstallationAlertIfEnabledForFile:tmpIpaPath
                                                   isRemoteInstall:YES
                                                        completion:^(
                                                            BOOL success,
                                                            NSError *error) {
                                                          [[NSFileManager
                                                              defaultManager]
                                                              removeItemAtPath:
                                                                  tmpIpaPath
                                                                         error:
                                                                             nil];
                                                          if (completionBlock)
                                                            completionBlock(
                                                                success, error);
                                                        }];
                    }
                  }];
                });
              }];

    [TSPresentationDelegate startActivity:@"下载中"
                        withCancelHandler:^{
                          [downloadTask cancel];
                        }];

    [downloadTask resume];
  });
}

+ (void)installLdidSilently {
  [self _installLdidWithCompletion:nil];
}

+ (void)installLdid {
  // Legacy method, kept for compatibility but redirects to silent install with
  // alerts if needed? Or just implementing it with logging since we removed the
  // button. We can just keep it as is or remove it if not used. Let's wrap
  // silent install for now or just leave it. Actually, to be safe and clean,
  // I'll remove the duplicate installLdidSilently and keep installLdid but add
  // logging.
  [self installLdidSilently];
}

@end