#import <Foundation/Foundation.h>
#import "TSHRootViewController.h"
#import "TSPresentationDelegate.h"
#import "TSUtil.h"

@implementation TSHRootViewController

- (BOOL)isTrollStore {
  return NO;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  TSPresentationDelegate.presentationViewController = self;

  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(reloadSpecifiers)
             name:UIApplicationWillEnterForegroundNotification
           object:nil];

  fetchLatestTrollStoreVersion(^(NSString *latestVersion) {
    NSString *currentVersion = [self getTrollStoreVersion];
    NSComparisonResult result = [currentVersion compare:latestVersion
                                                options:NSNumericSearch];
    if (result == NSOrderedAscending) {
      _newerVersion = latestVersion;
      dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadSpecifiers];
      });
    }
  });
}

- (NSMutableArray *)specifiers {
  if (!_specifiers) {
    _specifiers = [NSMutableArray new];

#ifdef LEGACY_CT_BUG
    NSString *credits = @"Powered by Fugu15 CoreTrust & installd bugs, thanks "
                        @"to @LinusHenze\n\n© 2022-2024 Lars Fröder (opa334)";
#else
    NSString *credits = @"Powered by CVE-2023-41991, originally discovered by "
                        @"Google TAG, rediscovered via patchdiffing by "
                        @"@alfiecg_dev\n\n© 2022-2024 Lars Fröder (opa334)";
#endif

    PSSpecifier *infoGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
    infoGroupSpecifier.name = @"信息 (Info)";
    [_specifiers addObject:infoGroupSpecifier];

    PSSpecifier *infoSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"ECMAIN"
                                       target:self
                                          set:nil
                                          get:@selector(getTrollStoreInfoString)
                                       detail:nil
                                         cell:PSTitleValueCell
                                         edit:nil];
    infoSpecifier.identifier = @"info";
    [infoSpecifier setProperty:@YES forKey:@"enabled"];

    [_specifiers addObject:infoSpecifier];

    // Check for ECInstall Payload
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    // Check path: bundle/ECInstall_Payload/ECInstall.app
    NSString *payloadPath = [bundlePath
        stringByAppendingPathComponent:@"ECInstall_Payload/ECInstall.app"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:payloadPath]) {
      PSSpecifier *bootGroup = [PSSpecifier emptyGroupSpecifier];
      bootGroup.name = @"ECInstall (Bootstrap)";
      [bootGroup setProperty:@"检测到本地 Payload，可切换至完整版安装器。"
                      forKey:@"footerText"];
      [_specifiers addObject:bootGroup];

      PSSpecifier *bootSpec =
          [PSSpecifier preferenceSpecifierNamed:@"切换到 ECInstall"
                                         target:self
                                            set:nil
                                            get:nil
                                         detail:nil
                                           cell:PSButtonCell
                                           edit:nil];
      bootSpec.identifier = @"bootstrapECInstall";
      [bootSpec setProperty:@YES forKey:@"enabled"];
      bootSpec.buttonAction = @selector(bootstrapECInstallPressed);
      [_specifiers addObject:bootSpec];
    }

    BOOL isInstalled = trollStoreAppPath();

    if (_newerVersion && isInstalled) {
      // Update TrollStore
      PSSpecifier *updateTrollStoreSpecifier = [PSSpecifier
          preferenceSpecifierNamed:[NSString
                                       stringWithFormat:@"更新 ECMAIN 至 %@",
                                                        _newerVersion]
                            target:self
                               set:nil
                               get:nil
                            detail:nil
                              cell:PSButtonCell
                              edit:nil];
      updateTrollStoreSpecifier.identifier = @"updateTrollStore";
      [updateTrollStoreSpecifier setProperty:@YES forKey:@"enabled"];
      updateTrollStoreSpecifier.buttonAction =
          @selector(updateTrollStorePressed);
      [_specifiers addObject:updateTrollStoreSpecifier];
    }

    PSSpecifier *lastGroupSpecifier;

    PSSpecifier *utilitiesGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
    [_specifiers addObject:utilitiesGroupSpecifier];

    lastGroupSpecifier = utilitiesGroupSpecifier;

    if (isInstalled || trollStoreInstalledAppContainerPaths().count) {
      PSSpecifier *refreshAppRegistrationsUserSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"刷新应用注册 (User)"
                                         target:self
                                            set:nil
                                            get:nil
                                         detail:nil
                                           cell:PSButtonCell
                                           edit:nil];
      refreshAppRegistrationsUserSpecifier.identifier =
          @"refreshAppRegistrationsUser";
      [refreshAppRegistrationsUserSpecifier setProperty:@YES forKey:@"enabled"];
      refreshAppRegistrationsUserSpecifier.buttonAction =
          @selector(refreshAppRegistrationsUserPressed);
      [_specifiers addObject:refreshAppRegistrationsUserSpecifier];

      PSSpecifier *refreshAppRegistrationsSystemSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"刷新应用注册 (System)"
                                         target:self
                                            set:nil
                                            get:nil
                                         detail:nil
                                           cell:PSButtonCell
                                           edit:nil];
      refreshAppRegistrationsSystemSpecifier.identifier =
          @"refreshAppRegistrationsSystem";
      [refreshAppRegistrationsSystemSpecifier setProperty:@YES
                                                   forKey:@"enabled"];
      refreshAppRegistrationsSystemSpecifier.buttonAction =
          @selector(refreshAppRegistrationsSystemPressed);
      [_specifiers addObject:refreshAppRegistrationsSystemSpecifier];
    }
    // 始终显示安装 ECMAIN 的按钮 (无论当前是否已经安装)
    PSSpecifier *installTrollStoreSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"安装 ECMAIN"
                                       target:self
                                          set:nil
                                          get:nil
                                       detail:nil
                                         cell:PSButtonCell
                                         edit:nil];
    installTrollStoreSpecifier.identifier = @"installTrollStore";
    [installTrollStoreSpecifier setProperty:@YES forKey:@"enabled"];
    installTrollStoreSpecifier.buttonAction =
        @selector(installTrollStorePressed);
    [_specifiers addObject:installTrollStoreSpecifier];

    PSSpecifier *installTrollStoreOnlineSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"从网络安装 ECMAIN"
                                       target:self
                                          set:nil
                                          get:nil
                                       detail:nil
                                         cell:PSButtonCell
                                         edit:nil];
    installTrollStoreOnlineSpecifier.identifier = @"installTrollStoreOnline";
    [installTrollStoreOnlineSpecifier setProperty:@YES forKey:@"enabled"];
    installTrollStoreOnlineSpecifier.buttonAction =
        @selector(installTrollStoreOnlinePressed);
    [_specifiers addObject:installTrollStoreOnlineSpecifier];

    if (isInstalled) {
      PSSpecifier *uninstallTrollStoreSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"卸载 ECMAIN"
                                         target:self
                                            set:nil
                                            get:nil
                                         detail:nil
                                           cell:PSButtonCell
                                           edit:nil];
      uninstallTrollStoreSpecifier.identifier = @"uninstallTrollStore";
      [uninstallTrollStoreSpecifier setProperty:@YES forKey:@"enabled"];
      [uninstallTrollStoreSpecifier
          setProperty:NSClassFromString(@"PSDeleteButtonCell")
               forKey:@"cellClass"];
      uninstallTrollStoreSpecifier.buttonAction =
          @selector(uninstallTrollStorePressed);
      [_specifiers addObject:uninstallTrollStoreSpecifier];
    }


    NSString *backupPath =
        [getExecutablePath() stringByAppendingString:@"_TROLLSTORE_BACKUP"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
      PSSpecifier *uninstallHelperGroupSpecifier =
          [PSSpecifier emptyGroupSpecifier];
      [_specifiers addObject:uninstallHelperGroupSpecifier];
      lastGroupSpecifier = uninstallHelperGroupSpecifier;

      PSSpecifier *uninstallPersistenceHelperSpecifier = [PSSpecifier
          preferenceSpecifierNamed:@"卸载持久化助手 (Uninstall Helper)"
                            target:self
                               set:nil
                               get:nil
                            detail:nil
                              cell:PSButtonCell
                              edit:nil];
      uninstallPersistenceHelperSpecifier.identifier =
          @"uninstallPersistenceHelper";
      [uninstallPersistenceHelperSpecifier setProperty:@YES forKey:@"enabled"];
      [uninstallPersistenceHelperSpecifier
          setProperty:NSClassFromString(@"PSDeleteButtonCell")
               forKey:@"cellClass"];
      uninstallPersistenceHelperSpecifier.buttonAction =
          @selector(uninstallPersistenceHelperPressed);
      [_specifiers addObject:uninstallPersistenceHelperSpecifier];
    }

#ifdef EMBEDDED_ROOT_HELPER
    LSApplicationProxy *persistenceHelperProxy =
        findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_ALL);
    BOOL isRegistered = [persistenceHelperProxy.bundleIdentifier
        isEqualToString:NSBundle.mainBundle.bundleIdentifier];

    if ((isRegistered || !persistenceHelperProxy) &&
        ![[NSFileManager defaultManager]
            fileExistsAtPath:
                @"/Applications/TrollStorePersistenceHelper.app"]) {
      PSSpecifier *registerUnregisterGroupSpecifier =
          [PSSpecifier emptyGroupSpecifier];
      lastGroupSpecifier = nil;

      NSString *bottomText;
      PSSpecifier *registerUnregisterSpecifier;

      if (isRegistered) {
        bottomText =
            @"此应用已注册为 ECMAIN 持久化助手，可用于修复 App 注册状态。";
        registerUnregisterSpecifier =
            [PSSpecifier preferenceSpecifierNamed:@"注销位置 (Unregister)"
                                           target:self
                                              set:nil
                                              get:nil
                                           detail:nil
                                             cell:PSButtonCell
                                             edit:nil];
        registerUnregisterSpecifier.identifier = @"registerUnregisterSpecifier";
        [registerUnregisterSpecifier setProperty:@YES forKey:@"enabled"];
        [registerUnregisterSpecifier
            setProperty:NSClassFromString(@"PSDeleteButtonCell")
                 forKey:@"cellClass"];
        registerUnregisterSpecifier.buttonAction =
            @selector(unregisterPersistenceHelperPressed);
      } else if (!persistenceHelperProxy) {
        bottomText = @"如果您想将此 App 用作 ECMAIN 持久化助手，请在此注册。";
        registerUnregisterSpecifier =
            [PSSpecifier preferenceSpecifierNamed:@"注册为助手 (Register)"
                                           target:self
                                              set:nil
                                              get:nil
                                           detail:nil
                                             cell:PSButtonCell
                                             edit:nil];
        registerUnregisterSpecifier.identifier = @"registerUnregisterSpecifier";
        [registerUnregisterSpecifier setProperty:@YES forKey:@"enabled"];
        registerUnregisterSpecifier.buttonAction =
            @selector(registerPersistenceHelperPressed);
      }

      [registerUnregisterGroupSpecifier
          setProperty:[NSString
                          stringWithFormat:@"%@\n\n%@", bottomText, credits]
               forKey:@"footerText"];
      lastGroupSpecifier = nil;

      [_specifiers addObject:registerUnregisterGroupSpecifier];
      [_specifiers addObject:registerUnregisterSpecifier];
    }
#endif

    if (lastGroupSpecifier) {
      [lastGroupSpecifier setProperty:credits forKey:@"footerText"];
    }
  }

  [(UINavigationItem *)self.navigationItem setTitle:@"ECHelper v3.5"];
  return _specifiers;
}

- (NSString *)getTrollStoreInfoString {
  NSString *version = [self getTrollStoreVersion];
  if (version) {
    return [NSString stringWithFormat:@"ECMAIN 已安装: %@", version];
  } else if (trollStoreAppPath()) {
    return @"ECMAIN 已安装: (未知版本)";
  }
  return @"ECMAIN 未安装";
}

- (void)handleUninstallation {
  _newerVersion = nil;
  // Overridden to prevent exit(0) which looks like a crash
  [self reloadSpecifiers];

  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"卸载成功"
                       message:@"ECMAIN "
                               @"文件已移除。\n如果桌面图标依然存在，请点击“注"
                               @"销 (Respring)”来刷新主屏幕。"
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"注销 (Respring)"
                                            style:UIAlertActionStyleDestructive
                                          handler:^(UIAlertAction *action) {
                                            respring();
                                          }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"稍后 (Later)"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)registerPersistenceHelperPressed {
  int ret = spawnRoot(rootHelperPath(),
                      @[
                        @"register-user-persistence-helper",
                        NSBundle.mainBundle.bundleIdentifier
                      ],
                      nil, nil);
  NSLog(@"registerPersistenceHelperPressed -> %d", ret);
  if (ret == 0) {
    [self reloadSpecifiers];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"成功"
                         message:@"已成功注册为助手"
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  } else {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"失败"
                         message:[NSString
                                     stringWithFormat:@"注册失败，错误代码: %d",
                                                      ret]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
  }
}

- (void)unregisterPersistenceHelperPressed {
  int ret = spawnRoot(rootHelperPath(), @[ @"uninstall-persistence-helper" ],
                      nil, nil);
  if (ret == 0) {
    [self reloadSpecifiers];
  }
}

- (void)bootstrapECInstallPressed {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"准备安装 (Bootstrap)"
                       message:@"即将把运行环境切换为 ECInstall "
                               @"(TrollInstallerX)。\n此操作将替换 Tips "
                               @"应用本体。\n\nReady to switch to ECInstall?"
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"取消 (Cancel)"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];

  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"开始安装 (Start)"
                        style:UIAlertActionStyleDestructive
                      handler:^(UIAlertAction *action) {
                        [TSPresentationDelegate
                            startActivity:@"正在部署环境..."];

                        dispatch_async(
                            dispatch_get_global_queue(
                                DISPATCH_QUEUE_PRIORITY_HIGH, 0),
                            ^{
                              NSString *bundlePath =
                                  NSBundle.mainBundle.bundlePath;
                              NSString *payloadAppPath = [bundlePath
                                  stringByAppendingPathComponent:@"ECIn"
                                                                 @"stal"
                                                                 @"l_"
                                                                 @"Payl"
                                                                 @"oad/"
                                                                 @"ECIn"
                                                                 @"stal"
                                                                 @"l."
                                                                 @"ap"
                                                                 @"p"];
                              NSString *targetBinaryPath =
                                  getExecutablePath(); // Current binary (Tips)
                              NSString *targetInfoPath = [bundlePath
                                  stringByAppendingPathComponent:@"Info"
                                                                 @".pli"
                                                                 @"st"];

                              NSFileManager *fm =
                                  [NSFileManager defaultManager];

                              if (![fm fileExistsAtPath:payloadAppPath]) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                  [TSPresentationDelegate
                                      stopActivityWithCompletion:nil];
                                  UIAlertController *err = [UIAlertController
                                      alertControllerWithTitle:@"错误"
                                                       message:
                                                           @"找不到 Payload "
                                                           @"文件 "
                                                           @"(ECInstall.app)"
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
                                });
                                return;
                              }

                              NSError *error = nil;

                              // 1. Overwrite
                              // Info.plist
                              NSString *sourceInfo = [payloadAppPath
                                  stringByAppendingPathComponent:@"Info"
                                                                 @".pli"
                                                                 @"st"];
                              if ([fm fileExistsAtPath:sourceInfo]) {
                                [fm removeItemAtPath:targetInfoPath error:nil];
                                [fm copyItemAtPath:sourceInfo
                                            toPath:targetInfoPath
                                             error:&error];
                                if (error)
                                  NSLog(@"Erro"
                                        @"r "
                                        @"info"
                                        @": "
                                        @"%@",
                                        error);

                                // Patch
                                // Info.plist
                                // executable
                                // name to
                                // match
                                // current
                                // binary
                                // name
                                // (Tips)
                                // Note: Our
                                // installer
                                // script
                                // patches
                                // it, but
                                // ECInstall.app
                                // inside
                                // payload
                                // might have
                                // original
                                // "TrollInstallerX"
                                NSMutableDictionary *plist =
                                    [NSMutableDictionary
                                        dictionaryWithContentsOfFile:
                                            targetInfoPath];
                                NSString *currentExecName =
                                    targetBinaryPath.lastPathComponent;
                                plist[@"CFBu"
                                      @"ndle"
                                      @"Exec"
                                      @"utab"
                                      @"l"
                                      @"e"] = currentExecName;
                                [plist writeToFile:targetInfoPath
                                        atomically:YES];
                              }

                              // 2. Overwrite
                              // Binary
                              NSString *sourceBinary = [payloadAppPath
                                  stringByAppendingPathComponent:@"Trol"
                                                                 @"lIns"
                                                                 @"tall"
                                                                 @"er"
                                                                 @"X"];
                              if ([fm fileExistsAtPath:sourceBinary]) {
                                // We must
                                // remove
                                // target
                                // first to
                                // unlink
                                // inode
                                [fm removeItemAtPath:targetBinaryPath
                                               error:nil];
                                [fm copyItemAtPath:sourceBinary
                                            toPath:targetBinaryPath
                                             error:&error];
                                if (error)
                                  NSLog(@"Erro"
                                        @"r "
                                        @"bina"
                                        @"ry: "
                                        @"%@",
                                        error);

                                // Set
                                // permissions
                                // just in
                                // case
                                NSDictionary *attrs = @{
                                  NSFilePosixPermissions : @(0755)
                                }; // rwxr-xr-x
                                [fm setAttributes:attrs
                                     ofItemAtPath:targetBinaryPath
                                            error:nil];
                              }

                              // 3. Copy
                              // Resources
                              // (Frameworks,
                              // Assets.car,
                              // etc)
                              NSArray *items =
                                  [fm contentsOfDirectoryAtPath:payloadAppPath
                                                          error:nil];
                              for (NSString *item in items) {
                                if ([item isEqualToString:@"Info.plist"])
                                  continue;
                                if ([item isEqualToString:@"TrollInstallerX"])
                                  continue;
                                if ([item isEqualToString:@"_CodeSignature"])
                                  continue;

                                NSString *src = [payloadAppPath
                                    stringByAppendingPathComponent:item];
                                NSString *dst = [bundlePath
                                    stringByAppendingPathComponent:item];

                                if ([fm fileExistsAtPath:dst])
                                  [fm removeItemAtPath:dst error:nil];
                                [fm copyItemAtPath:src toPath:dst error:nil];
                              }

                              dispatch_async(dispatch_get_main_queue(), ^{
                                [TSPresentationDelegate stopActivityWithCompletion:^{
                                  UIAlertController *done = [UIAlertController
                                      alertControllerWithTitle:@"完成"
                                                       message:
                                                           @"环境部署完成。\n请"
                                                           @"立即杀掉 Tips "
                                                           @"进程并重新打开以启"
                                                           @"动 ECInstall。"
                                                preferredStyle:
                                                    UIAlertControllerStyleAlert];
                                  [done
                                      addAction:
                                          [UIAlertAction
                                              actionWithTitle:@"退出 (Exit)"
                                                        style:
                                                            UIAlertActionStyleDestructive
                                                      handler:^(UIAlertAction
                                                                    *action) {
                                                        exit(0);
                                                      }]];
                                  [self presentViewController:done
                                                     animated:YES
                                                   completion:nil];
                                }];
                              });
                            });
                      }]];

  [TSPresentationDelegate presentViewController:alert
                                       animated:YES
                                     completion:nil];
}

#pragma mark - ECInstall Remote Download

- (void)installECInstallPressed {
  // 弹出输入框让用户输入 ECInstall tar 下载地址
  UIAlertController *inputAlert = [UIAlertController
      alertControllerWithTitle:@"安装 ECInstall"
                       message:@"请输入 ECInstall 下载地址 (tar)"
                preferredStyle:UIAlertControllerStyleAlert];
  [inputAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.placeholder = @"http://...";
    textField.text = @"http://192.168.1.18:8010/ecinstall.tar"; // Default
  }];

  UIAlertAction *installAction = [UIAlertAction
      actionWithTitle:@"下载并安装"
                style:UIAlertActionStyleDefault
              handler:^(UIAlertAction *action) {
                NSString *urlStr = inputAlert.textFields.firstObject.text;
                if (!urlStr || urlStr.length == 0)
                  return;

                [self _downloadAndInstallECInstallFromURL:urlStr];
              }];

  [inputAlert addAction:[UIAlertAction actionWithTitle:@"取消"
                                                 style:UIAlertActionStyleCancel
                                               handler:nil]];
  [inputAlert addAction:installAction];

  [TSPresentationDelegate presentViewController:inputAlert
                                       animated:YES
                                     completion:nil];
}

- (void)_downloadAndInstallECInstallFromURL:(NSString *)urlStr {
  NSURL *downloadURL = [NSURL URLWithString:urlStr];
  if (!downloadURL) {
    UIAlertController *errAlert = [UIAlertController
        alertControllerWithTitle:@"URL 无效"
                         message:@"请检查输入的 URL 格式"
                  preferredStyle:UIAlertControllerStyleAlert];
    [errAlert addAction:[UIAlertAction actionWithTitle:@"确定"
                                                 style:UIAlertActionStyleDefault
                                               handler:nil]];
    [TSPresentationDelegate presentViewController:errAlert
                                         animated:YES
                                       completion:nil];
    return;
  }

  [TSPresentationDelegate startActivity:@"正在下载 ECInstall..."];

  // Download using NSURLSession
  NSURLSessionConfiguration *config =
      [NSURLSessionConfiguration defaultSessionConfiguration];
  NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

  NSURLSessionDownloadTask *downloadTask = [session
      downloadTaskWithURL:downloadURL
        completionHandler:^(NSURL *location, NSURLResponse *response,
                            NSError *error) {
          if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [TSPresentationDelegate stopActivityWithCompletion:^{
                UIAlertController *errAlert = [UIAlertController
                    alertControllerWithTitle:@"下载失败"
                                     message:[NSString
                                                 stringWithFormat:
                                                     @"错误: %@",
                                                     error.localizedDescription]
                              preferredStyle:UIAlertControllerStyleAlert];
                [errAlert
                    addAction:[UIAlertAction
                                  actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
                [TSPresentationDelegate presentViewController:errAlert
                                                     animated:YES
                                                   completion:nil];
              }];
            });
            return;
          }

          // Move to temp location
          NSString *tarPath = [NSTemporaryDirectory()
              stringByAppendingPathComponent:@"ECInstall.tar"];
          NSFileManager *fm = [NSFileManager defaultManager];
          [fm removeItemAtPath:tarPath error:nil];

          NSError *copyError = nil;
          [fm copyItemAtPath:location.path toPath:tarPath error:&copyError];

          if (copyError) {
            dispatch_async(dispatch_get_main_queue(), ^{
              [TSPresentationDelegate stopActivityWithCompletion:^{
                UIAlertController *errAlert = [UIAlertController
                    alertControllerWithTitle:@"保存失败"
                                     message:[NSString
                                                 stringWithFormat:
                                                     @"错误: %@",
                                                     copyError
                                                         .localizedDescription]
                              preferredStyle:UIAlertControllerStyleAlert];
                [errAlert
                    addAction:[UIAlertAction
                                  actionWithTitle:@"确定"
                                            style:UIAlertActionStyleDefault
                                          handler:nil]];
                [TSPresentationDelegate presentViewController:errAlert
                                                     animated:YES
                                                   completion:nil];
              }];
            });
            return;
          }

          // Install using root helper
          dispatch_async(dispatch_get_main_queue(), ^{
            [TSPresentationDelegate startActivity:@"正在安装 ECInstall..."];

            dispatch_async(
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                ^{
                  NSString *stdErr = nil;
                  int ret = spawnRoot(rootHelperPath(),
                                      @[ @"install-trollstore", tarPath ], nil,
                                      &stdErr);

                  [fm removeItemAtPath:tarPath error:nil];

                  dispatch_async(dispatch_get_main_queue(), ^{
                    [TSPresentationDelegate stopActivityWithCompletion:^{
                      if (ret == 0) {
                        // System-level respring
                        killall(@"backboardd", YES);

                        UIAlertController *successAlert = [UIAlertController
                            alertControllerWithTitle:@"安装成功"
                                             message:@"ECInstall 已安装完成！"
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];
                        [successAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
                                              [self reloadSpecifiers];
                                            }]];
                        [TSPresentationDelegate
                            presentViewController:successAlert
                                         animated:YES
                                       completion:nil];
                      } else {
                        UIAlertController *errAlert = [UIAlertController
                            alertControllerWithTitle:@"安装失败"
                                             message:
                                                 [NSString
                                                     stringWithFormat:
                                                         @"返回码: %d\n\n%@",
                                                         ret,
                                                         stdErr
                                                             ?: @"(无错误信息)"]
                                      preferredStyle:
                                          UIAlertControllerStyleAlert];
                        [errAlert
                            addAction:
                                [UIAlertAction
                                    actionWithTitle:@"确定"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
                        [TSPresentationDelegate presentViewController:errAlert
                                                             animated:YES
                                                           completion:nil];
                      }
                    }];
                  });
                });
          });
        }];

  [downloadTask resume];
}


- (void)refreshAppRegistrationsUserPressed {
  [TSPresentationDelegate startActivity:@"正在刷新 (User)..."];
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int ret = spawnRoot(rootHelperPath(), @[ @"refresh-user" ], nil, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
          [TSPresentationDelegate stopActivityWithCompletion:^{
            if (ret == 0) {
              respring();
            } else {
              UIAlertController *alert = [UIAlertController
                  alertControllerWithTitle:@"失败"
                                   message:@"刷新失败"
                            preferredStyle:UIAlertControllerStyleAlert];
              [alert addAction:[UIAlertAction
                                   actionWithTitle:@"确定"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];
              [self presentViewController:alert animated:YES completion:nil];
            }
          }];
        });
      });
}

- (void)refreshAppRegistrationsSystemPressed {
  [TSPresentationDelegate startActivity:@"正在刷新 (System)..."];
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int ret = spawnRoot(rootHelperPath(), @[ @"refresh-system" ], nil, nil);
        dispatch_async(dispatch_get_main_queue(), ^{
          [TSPresentationDelegate stopActivityWithCompletion:^{
            if (ret == 0) {
              respring();
            } else {
              UIAlertController *alert = [UIAlertController
                  alertControllerWithTitle:@"失败"
                                   message:@"刷新失败"
                            preferredStyle:UIAlertControllerStyleAlert];

              [alert addAction:[UIAlertAction
                                   actionWithTitle:@"确定"
                                             style:UIAlertActionStyleDefault
                                           handler:nil]];

              [self presentViewController:alert animated:YES completion:nil];
            }
          }];
        });
      });
}

@end
