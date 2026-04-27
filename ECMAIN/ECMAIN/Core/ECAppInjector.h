//
//  ECAppInjector.h
//  ECMAIN
//
//  应用注入管理器 - 向目标 APP 注入 dylib
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 注入状态
typedef NS_ENUM(NSInteger, ECInjectionStatus) {
  ECInjectionStatusNotInjected = 0, // 未注入
  ECInjectionStatusInjected,        // 已注入
  ECInjectionStatusError            // 注入出错
};

/// 日志通知（UserInfo 包含 @"message"）
extern NSNotificationName const kECLogNotification;

/// 注入结果
@interface ECInjectionResult : NSObject
@property(nonatomic, assign) BOOL success;
@property(nonatomic, strong, nullable) NSError *error;
@property(nonatomic, copy, nullable) NSString *message;
@end

@interface ECAppInjector : NSObject

/// 获取单例
+ (instancetype)sharedInstance;

#pragma mark - 注入管理

/// 向指定 APP 注入 spoof dylib
/// @param appPath APP 的完整路径（如
/// /var/containers/Bundle/Application/.../App.app）
/// @param error 错误信息
/// 注入伪装 dylib 到目标 APP
- (BOOL)injectSpoofDylibIntoApp:(NSString *)appPath error:(NSError **)error;

/// 注入伪装 dylib 到目标 APP (包含手动指定 Team ID)
- (BOOL)injectSpoofDylibIntoApp:(NSString *)appPath
                   manualTeamID:(nullable NSString *)teamID
                          error:(NSError **)error;

/// 注入伪装 dylib (指定可执行文件路径)
- (BOOL)injectSpoofDylibIntoApp:(NSString *)appPath
                 executablePath:(nullable NSString *)executablePath
                   manualTeamID:(nullable NSString *)teamID
                          error:(NSError **)error;

/// [方案 C] 注入 Profile 切换 dylib（原版多 Profile 模式）
- (BOOL)injectProfileCDylibIntoApp:(NSString *)appPath
                    executablePath:(nullable NSString *)executablePath
                      manualTeamID:(nullable NSString *)teamID
                             error:(NSError **)error;

/// 从目标 App 移除伪装 dylib
- (BOOL)ejectDylibFromApp:(NSString *)appPath error:(NSError **)error;

/// 检查是否已注入
- (BOOL)isDylibInjectedIntoApp:(NSString *)appPath;

/// 保存二进制的 Team ID 到记录 (供脱壳后调用)
- (BOOL)saveTeamIDForBinary:(NSString *)binaryPath error:(NSError **)error;

/// 使用指定 Team ID 重签二进制 (Fallback 策略)
- (BOOL)resignBinary:(NSString *)binaryPath
          withTeamID:(NSString *)teamID
               error:(NSError **)error;

/// 检查 APP 是否已被注入
/// @param appPath APP 的完整路径
/// @return 注入状态
- (ECInjectionStatus)injectionStatusForApp:(NSString *)appPath;

#pragma mark - 批量操作

/// 获取所有已注入的 APP 列表
- (NSArray<NSString *> *)injectedApps;

/// 为指定 APP 创建设备伪装配置 (直接写入 App Bundle)
/// @param appPath APP 的完整路径
/// @param config 配置字典
/// @return 是否成功
- (BOOL)createSpoofConfigForAppPath:(NSString *)appPath
                             config:(NSDictionary *)config
                              error:(NSError **)error;

/// 获取指定 APP 的设备伪装配置
/// @param bundleId APP 的 Bundle ID
/// @return 配置字典，如果不存在返回 nil
- (nullable NSDictionary *)spoofConfigForApp:(NSString *)bundleId;

#pragma mark - 分身管理

/// 为指定 APP 创建分身配置
/// @param bundleId APP 的 Bundle ID
/// @param cloneId 分身 ID
/// @param config 配置字典
/// @return 是否成功
- (BOOL)createCloneConfigForApp:(NSString *)bundleId
                        cloneId:(NSString *)cloneId
                         config:(NSDictionary *)config
                          error:(NSError **)error;

/// 获取指定 APP 的所有分身 ID
/// @param bundleId APP 的 Bundle ID
/// @return 分身 ID 列表
- (NSArray<NSString *> *)cloneIdsForApp:(NSString *)bundleId;

/// 删除分身配置
/// @param bundleId APP 的 Bundle ID
/// @param cloneId 分身 ID
/// @return 是否成功
- (BOOL)deleteCloneForApp:(NSString *)bundleId
                  cloneId:(NSString *)cloneId
                    error:(NSError **)error;

/**
 * Prepares an IPA for installation by injecting the dylib and signing it.
 * Returns the path to the modified App Bundle (not IPA) in a temporary
 * directory.
 *
 * @param customBundleId Optional custom Bundle ID for cloning (nil = keep
 * original)
 * @param customDisplayName Optional custom display name for cloning (nil = keep
 * original)
 */
- (nullable NSString *)
    prepareIPAForInjection:(NSString *)ipaPath
              manualTeamID:(nullable NSString *)manualTeamID
            customBundleId:(nullable NSString *)customBundleId
         customDisplayName:(nullable NSString *)customDisplayName
          workingDirectory:(nullable NSString *)workingDirectory
                     error:(NSError **)error;

/**
 * Post-install fix: 对已安装 App Bundle 的 Frameworks/ loose .dylib 重签。
 * 用于修复 TrollStore CTLoop 二次 bypass 产生的无效签名。
 * @param installedAppBundlePath 已安装的 .app 完整路径（如 /var/containers/Bundle/.../TikTok.app）
 */
- (void)fixLooseDylibSignaturesForInstalledBundle:(NSString *)installedAppBundlePath;

/**
 * 解压 IPA 到临时目录
 */
- (nullable NSString *)extractIPAToTemp:(NSString *)ipaPath
                                  error:(NSError **)error;

/**
 * 从解压后的 App Bundle 获取信息
 */
- (nullable NSDictionary<NSString *, id> *)getAppInfoFromBundlePath:
    (NSString *)bundlePath;

@end

NS_ASSUME_NONNULL_END
