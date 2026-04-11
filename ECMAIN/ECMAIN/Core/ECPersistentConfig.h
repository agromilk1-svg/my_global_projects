#import <Foundation/Foundation.h>

// =====================================================================
// ECPersistentConfig - 更新无损配置持久化
//
// 问题：TrollStore OTA 更新时，registerPath 会重建 App Group 容器，
//       导致 NSUserDefaults(group.com.ecmain.shared) 中的所有数据丢失。
//
// 解决：关键配置数据实行"双写双读"策略：
//   写入时 → 同时写入 App Group + /var/mobile/Media/ecmain_config.plist
//   读取时 → 先读 App Group，若为空则从 plist 文件恢复
//
// 此文件路径 /var/mobile/Media/ 不受任何安装/卸载/容器重建影响。
// =====================================================================

@interface ECPersistentConfig : NSObject

// 保存关键配置到双存储
+ (void)setObject:(id)value forKey:(NSString *)key;
+ (void)setBool:(BOOL)value forKey:(NSString *)key;

// 从双存储读取（App Group 优先，缺失则从 plist 恢复）
+ (NSString *)stringForKey:(NSString *)key;
+ (BOOL)boolForKey:(NSString *)key;
+ (id)objectForKey:(NSString *)key;

// 启动时调用：检查 App Group 是否为空，若空则从 plist 全量恢复
+ (void)restoreIfNeeded;

// 强制同步
+ (void)synchronize;

@end
