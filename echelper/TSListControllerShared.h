#import <Foundation/Foundation.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>

@interface TSListControllerShared : PSListController
- (BOOL)isTrollStore;
- (NSString *)getTrollStoreVersion;
- (void)downloadTrollStoreAndRun:
    (void (^)(NSString *localTrollStoreTarPath))doHandler;
- (void)installTrollStorePressed;
- (void)updateTrollStorePressed;
- (void)rebuildIconCachePressed;
- (void)refreshAppRegistrationsPressed;
- (void)uninstallPersistenceHelperPressed;
- (void)handleUninstallation;
- (NSMutableArray *)argsForUninstallingTrollStore;
- (void)uninstallTrollStorePressed;
@end