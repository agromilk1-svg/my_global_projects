#import <Foundation/Foundation.h>

@interface TSInstallationController : NSObject

+ (void)presentInstallationAlertIfEnabledForFile:(NSString *)pathToIPA
                                 isRemoteInstall:(BOOL)remoteInstall
                                      completion:(void (^)(BOOL, NSError *))
                                                     completionBlock;

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                      completion:(void (^)(BOOL, NSError *))completion;

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
                      completion:(void (^)(BOOL, NSError *))completion;

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
               customDisplayName:(NSString *)customDisplayName
                      completion:(void (^)(BOOL, NSError *))completion;

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
               customDisplayName:(NSString *)customDisplayName
                     skipSigning:(BOOL)skipSigning
              installationMethod:(int)installationMethod
                      completion:(void (^)(BOOL, NSError *))completion;

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                    forceInstall:(BOOL)force
                registrationType:(NSString *)registrationType
                  customBundleId:(NSString *)customBundleId
               customDisplayName:(NSString *)customDisplayName
                     skipSigning:(BOOL)skipSigning
                      completion:(void (^)(BOOL, NSError *))completion;

+ (void)handleAppInstallFromFile:(NSString *)pathToIPA
                      completion:(void (^)(BOOL, NSError *))completion;

+ (void)handleAppInstallFromRemoteURL:(NSURL *)remoteURL
                           completion:(void (^)(BOOL, NSError *))completion;

+ (void)installLdid;
+ (void)installLdidSilently;

@end