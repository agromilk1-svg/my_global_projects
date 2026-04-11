#import "ECPersistentConfig.h"

// 持久化文件路径 — /var/mobile/Media/ 目录不受 TrollStore 安装/卸载/容器重建影响
static NSString *const kPersistentFilePath = @"/var/mobile/Media/ecmain_config.plist";
static NSString *const kAppGroupSuite = @"group.com.ecmain.shared";

// 需要持久化的关键 Key 列表
static NSArray<NSString *> *criticalKeys(void) {
  return @[
    @"CloudServerURL",
    @"EC_DEVICE_NO",
    @"EC_ADMIN_USERNAME",
    @"EC_WATCHDOG_WDA_ENABLED",
    @"EC_APPLE_ACCOUNT",
    @"EC_APPLE_PASSWORD",
    @"EC_TIKTOK_ACCOUNTS",
    @"EC_DEVICE_COUNTRY",
    @"EC_DEVICE_GROUP",
    @"EC_DEVICE_EXEC_TIME",
    @"EC_CONFIG_CHECKSUM",
    @"EC_CONFIG_IP_CACHED",
    @"EC_CONFIG_VPN_CACHED",
  ];
}

@implementation ECPersistentConfig

#pragma mark - 内部工具

// 获取 App Group 的 NSUserDefaults
+ (NSUserDefaults *)appGroupDefaults {
  return [[NSUserDefaults alloc] initWithSuiteName:kAppGroupSuite];
}

// 从磁盘读取 plist 字典
+ (NSMutableDictionary *)loadPlistDict {
  NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:kPersistentFilePath];
  return dict ?: [NSMutableDictionary dictionary];
}

// 将字典写入磁盘 plist
+ (void)savePlistDict:(NSDictionary *)dict {
  // 确保父目录存在
  NSString *dir = [kPersistentFilePath stringByDeletingLastPathComponent];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  [dict writeToFile:kPersistentFilePath atomically:YES];
}

#pragma mark - 写入（双写）

+ (void)setObject:(id)value forKey:(NSString *)key {
  if (!key) return;
  
  // 1. 写入 App Group
  NSUserDefaults *defaults = [self appGroupDefaults];
  [defaults setObject:value forKey:key];
  [defaults synchronize];
  
  // 2. 同步写入 plist 文件
  NSMutableDictionary *plist = [self loadPlistDict];
  if (value) {
    plist[key] = value;
  } else {
    [plist removeObjectForKey:key];
  }
  [self savePlistDict:plist];
}

+ (void)setBool:(BOOL)value forKey:(NSString *)key {
  [self setObject:@(value) forKey:key];
}

#pragma mark - 读取（App Group 优先，缺失则从 plist 恢复）

+ (id)objectForKey:(NSString *)key {
  if (!key) return nil;
  
  NSUserDefaults *defaults = [self appGroupDefaults];
  id value = [defaults objectForKey:key];
  
  if (value) return value;
  
  // App Group 中没有 → 尝试从 plist 恢复
  NSDictionary *plist = [self loadPlistDict];
  id fallback = plist[key];
  
  if (fallback) {
    // 恢复到 App Group（下次就不用再读 plist 了）
    NSLog(@"[ECPersistentConfig] 🔄 从 plist 恢复 key=%@ (App Group 数据丢失)", key);
    [defaults setObject:fallback forKey:key];
    [defaults synchronize];
  }
  
  return fallback;
}

+ (NSString *)stringForKey:(NSString *)key {
  id value = [self objectForKey:key];
  return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (BOOL)boolForKey:(NSString *)key {
  id value = [self objectForKey:key];
  return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : NO;
}

#pragma mark - 启动恢复

// 应用启动时调用：检测 App Group 是否被重建（关键数据缺失），若是则全量恢复
+ (void)restoreIfNeeded {
  NSUserDefaults *defaults = [self appGroupDefaults];
  NSDictionary *plist = [self loadPlistDict];
  
  if (plist.count == 0) {
    NSLog(@"[ECPersistentConfig] ℹ️ plist 备份文件为空，无需恢复（首次安装）");
    // 首次安装：将 App Group 中现有的关键数据写入 plist 作为初始备份
    [self backupCurrentState];
    return;
  }
  
  // 检查是否有任何关键 key 在 App Group 中缺失但在 plist 中存在
  BOOL needsRestore = NO;
  for (NSString *key in criticalKeys()) {
    id groupValue = [defaults objectForKey:key];
    id plistValue = plist[key];
    if (!groupValue && plistValue) {
      needsRestore = YES;
      break;
    }
  }
  
  if (!needsRestore) {
    NSLog(@"[ECPersistentConfig] ✅ App Group 数据完整，无需恢复");
    // 确保 plist 备份是最新的
    [self backupCurrentState];
    return;
  }
  
  // 执行全量恢复
  NSLog(@"[ECPersistentConfig] ⚠️ 检测到 App Group 数据丢失（更新后容器重建），正在从 plist 恢复...");
  int restoredCount = 0;
  for (NSString *key in criticalKeys()) {
    id plistValue = plist[key];
    if (plistValue && ![defaults objectForKey:key]) {
      [defaults setObject:plistValue forKey:key];
      restoredCount++;
      NSLog(@"[ECPersistentConfig] 🔄 恢复 %@ = %@", key,
            [key containsString:@"PASSWORD"] ? @"****" : plistValue);
    }
  }
  [defaults synchronize];
  NSLog(@"[ECPersistentConfig] ✅ 恢复完成，共恢复 %d 个配置项", restoredCount);
}

// 将当前 App Group 中的关键数据备份到 plist
+ (void)backupCurrentState {
  NSUserDefaults *defaults = [self appGroupDefaults];
  NSMutableDictionary *plist = [self loadPlistDict];
  BOOL changed = NO;
  
  for (NSString *key in criticalKeys()) {
    id value = [defaults objectForKey:key];
    if (value && ![value isEqual:plist[key]]) {
      plist[key] = value;
      changed = YES;
    }
  }
  
  if (changed) {
    [self savePlistDict:plist];
    NSLog(@"[ECPersistentConfig] 💾 已同步备份到 %@", kPersistentFilePath);
  }
}

+ (void)synchronize {
  [[self appGroupDefaults] synchronize];
  [self backupCurrentState];
}

@end
