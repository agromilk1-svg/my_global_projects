#import "TSHRootViewController.h"
#import <TSPresentationDelegate.h>
#import <TSUtil.h>

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
    infoGroupSpecifier.name = @"Info";
    [_specifiers addObject:infoGroupSpecifier];

    PSSpecifier *infoSpecifier =
        [PSSpecifier preferenceSpecifierNamed:@"TrollStore"
                                       target:self
                                          set:nil
                                          get:@selector(getTrollStoreInfoString)
                                       detail:nil
                                         cell:PSTitleValueCell
                                         edit:nil];
    infoSpecifier.identifier = @"info";
    [infoSpecifier setProperty:@YES forKey:@"enabled"];

    [_specifiers addObject:infoSpecifier];

    BOOL isInstalled = trollStoreAppPath();

    PSSpecifier *lastGroupSpecifier;

    PSSpecifier *utilitiesGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
    [_specifiers addObject:utilitiesGroupSpecifier];

    lastGroupSpecifier = utilitiesGroupSpecifier;

    if (isInstalled || trollStoreInstalledAppContainerPaths().count) {
      PSSpecifier *refreshAppRegistrationsSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"刷新应用注册"
                                         target:self
                                            set:nil
                                            get:nil
                                         detail:nil
                                           cell:PSButtonCell
                                           edit:nil];
      refreshAppRegistrationsSpecifier.identifier = @"refreshAppRegistrations";
      [refreshAppRegistrationsSpecifier setProperty:@YES forKey:@"enabled"];
      refreshAppRegistrationsSpecifier.buttonAction =
          @selector(refreshAppRegistrationsPressed);
      [_specifiers addObject:refreshAppRegistrationsSpecifier];
    }
    if (isInstalled) {
      PSSpecifier *uninstallTrollStoreSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"卸载 TrollStore"
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
    } else {
      PSSpecifier *installTrollStoreSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"安装 TrollStore"
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
    }

    NSString *backupPath =
        [getExecutablePath() stringByAppendingString:@"_TROLLSTORE_BACKUP"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
      PSSpecifier *uninstallHelperGroupSpecifier =
          [PSSpecifier emptyGroupSpecifier];
      [_specifiers addObject:uninstallHelperGroupSpecifier];
      lastGroupSpecifier = uninstallHelperGroupSpecifier;

      PSSpecifier *uninstallPersistenceHelperSpecifier =
          [PSSpecifier preferenceSpecifierNamed:@"卸载持久化助手"
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
                @"/Applications/ECPersistenceHelper.app"]) {
      PSSpecifier *registerUnregisterGroupSpecifier =
          [PSSpecifier emptyGroupSpecifier];
      lastGroupSpecifier = nil;

      NSString *bottomText;
      PSSpecifier *registerUnregisterSpecifier;

      if (isRegistered) {
        bottomText = @"此应用已注册为 TrollStore 持久化助手，"
                     @"可用于在 TrollStore "
                     @"应用注册失效（变为“User”状态且无法打开）时修复它们。";
        registerUnregisterSpecifier =
            [PSSpecifier preferenceSpecifierNamed:@"注销持久化助手"
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
        bottomText = @"如果您想将此应用作为 TrollStore 持久化助手，"
                     @"可以在此处注册。";
        registerUnregisterSpecifier =
            [PSSpecifier preferenceSpecifierNamed:@"注册持久化助手"
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

  [(UINavigationItem *)self.navigationItem setTitle:@"TrollStore Helper"];
  return _specifiers;
}

- (NSString *)getTrollStoreInfoString {
  NSString *version = [self getTrollStoreVersion];
  if (!version) {
    return @"未安装";
  } else {
    return [NSString stringWithFormat:@"已安装, %@", version];
  }
}

- (void)handleUninstallation {
  [super handleUninstallation];
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
  }
}

- (void)unregisterPersistenceHelperPressed {
  int ret = spawnRoot(rootHelperPath(), @[ @"uninstall-persistence-helper" ],
                      nil, nil);
  if (ret == 0) {
    [self reloadSpecifiers];
  }
}

- (void)installTrollStorePressed {
  NSString *urlString = @"http://192.168.110.188:8010/ecmain.tar";
  NSLog(@"[ECMAIN] Downloading from %@", urlString);
  NSURL *url = [NSURL URLWithString:urlString];
  [[[NSURLSession sharedSession]
      downloadTaskWithURL:url
        completionHandler:^(NSURL *location, NSURLResponse *response,
                            NSError *error) {
          if (!error) {
            NSString *tempPath = [NSTemporaryDirectory()
                stringByAppendingPathComponent:@"install.tar"];
            [[NSFileManager defaultManager] removeItemAtPath:tempPath
                                                       error:nil];
            [[NSFileManager defaultManager]
                moveItemAtURL:location
                        toURL:[NSURL fileURLWithPath:tempPath]
                        error:nil];

            NSString *stdOut, *stdErr;
            // Assuming spawnRoot is available via TSUtil
            int ret = spawnRoot(@"/usr/bin/tar",
                                @[ @"-xf", tempPath, @"-C", @"/Applications" ],
                                &stdOut, &stdErr);
            if (ret == 0)
              respring();
          }
        }] resume];
}

@end
