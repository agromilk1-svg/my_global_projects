#import "LaunchdResponse.h"
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECAppLauncher : NSObject

/**
 * 使用 FrontBoard/BackBoard 启动应用程序
 * 这是 TrollStore 脱壳方式的核心：通过 FrontBoard 启动应用，然后用 task_for_pid 读取内存
 *
 * @param bundleIdentifier 应用的 Bundle ID
 * @param executablePath 可执行文件的路径（可选，用于回退方案）
 * @return LaunchdResponse_t 包含 pid 等信息，如果 pid == -1 表示失败
 */
+ (LaunchdResponse_t)launchAppWithBundleIdentifier:(NSString *)bundleIdentifier
                                    executablePath:(nullable NSString *)executablePath;

/**
 * 强行点亮黑屏并将 ECMAIN 拉到前台（基于 FBSSystemService 底层接口）
 * 主要用于脚本准备执行前，确保设备环境处于活跃亮屏状态
 */
+ (void)wakeScreenAndBringMainAppToFront;

/**
 * 从 Info.plist 获取可执行文件路径
 */
+ (nullable NSString *)executablePathForAppAtPath:(NSString *)bundlePath;

@end

NS_ASSUME_NONNULL_END
