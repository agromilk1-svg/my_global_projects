#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ECAppInstallCompletion)(BOOL success, NSString *_Nullable error);

@interface ECAppManager : NSObject

+ (instancetype)sharedManager;

// Install an IPA file from the given path
- (void)installAppFromIPA:(NSString *)ipaPath
               completion:(ECAppInstallCompletion)completion;

// Register an app at the given path (e.g. /Applications/MyApp.app)
- (void)registerAppAt:(NSString *)appPath
           completion:(ECAppInstallCompletion)completion;

+ (NSString *)getAppVersionByBundleID:(NSString *)bundleID;

@end

NS_ASSUME_NONNULL_END
