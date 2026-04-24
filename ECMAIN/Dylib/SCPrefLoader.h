//
//  SCPrefLoader.h
//  ECDeviceSpoof
//
//  配置读取模块 - 支持按 Bundle ID + Clone ID 读取设备伪装配置
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 配置文件基础目录（伪装为 UIKit 系统缓存）
#define EC_SPOOF_BASE_DIR @"/var/mobile/Documents/.com.apple.UIKit.pboard"

// 全局配置文件路径 (伪装为系统偏好)
#define EC_SPOOF_GLOBAL_CONFIG_PATH                                            \
  EC_SPOOF_BASE_DIR @"/com.apple.preferences.display.plist"

// 沙盒环境配置目录 (相对于 Home，伪装为 UIKit 缓存)
#define EC_SPOOF_SANDBOX_DIR @"Documents/.com.apple.UIKit.pboard"

// Clone ID 环境变量（伪装为 CoreFoundation 内部变量）
#define EC_SPOOF_CLONE_ENV @"__CFUID"

@interface SCPrefLoader : NSObject

/// 获取单例
+ (instancetype)shared;

/// 预热配置（在 +load 或 constructor 中调用） - 异步初始化
+ (void)prewarmConfig;

/// 配置字典
@property(nonatomic, readonly) NSDictionary *config;

/// 当前 Bundle ID
@property(nonatomic, readonly) NSString *currentBundleId;

/// 当前 Clone ID (nil 表示主应用)
@property(nonatomic, readonly, nullable) NSString *currentCloneId;

/// 获取指定 key 的伪装值，如果没有配置则返回 nil
- (nullable NSString *)spoofValueForKey:(NSString *)key;

/// 获取指定 key 的布尔值，如果没有配置则返回 defaultValue

/// "仅伪装克隆"模式：开启后只保留克隆隔离 Hook，关闭设备伪装
@property(nonatomic, readonly) BOOL cloneOnlyMode;
- (BOOL)spoofBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;

/// 重新加载配置
- (void)reloadConfig;

/// 是否启用伪装（配置文件存在且非空）
- (BOOL)isEnabled;

/// 获取当前配置文件路径
- (NSString *)configPath;

/// 获取当前数据隔离目录（分身专属）
- (nullable NSString *)cloneDataDirectory;

/// 获取配置的原始 Bundle ID（用于克隆身份伪装）
/// 如果配置了此值，表示当前应用是克隆版，应伪装成原始应用
- (nullable NSString *)originalBundleId;

@end

NS_ASSUME_NONNULL_END
