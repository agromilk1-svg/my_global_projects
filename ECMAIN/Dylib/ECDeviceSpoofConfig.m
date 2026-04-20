//
//  ECDeviceSpoofConfig.m
//  ECDeviceSpoof
//
//  配置读取模块实现 - 支持按 Bundle ID + Clone ID 读取配置
//

#import "ECDeviceSpoofConfig.h"

// 文件日志（与 ECDeviceSpoof.m 共享同一个日志文件）
// ⚠️ 2026-02-03: 禁用文件写入，避免高频调用导致 I/O 性能问题
static void ECConfigLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ECConfigLog(NSString *format, ...) {
#if 0 // 临时禁用日志
  va_list args;
  va_start(args, format);
  NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  NSLog(@"[ECDeviceSpoof] %@", logMsg);
#endif
}

@interface ECDeviceSpoofConfig ()
@property(nonatomic, strong) NSDictionary *config;
@property(nonatomic, strong) NSString *currentBundleId;
@property(nonatomic, strong) NSString *currentCloneId;
@end

@implementation ECDeviceSpoofConfig

+ (instancetype)shared {
  static ECDeviceSpoofConfig *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECDeviceSpoofConfig alloc] init];
  });
  return instance;
}

+ (void)prewarmConfig {
  // 异步初始化，避免阻塞主线程或 constructor
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   [[ECDeviceSpoofConfig shared] originalBundleId];
                 });
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // 获取当前 Bundle ID (直接从 infoDictionary 读取，避免触发 Hook 递归)
    _currentBundleId = [[NSBundle mainBundle]
                           infoDictionary][@"CFBundleIdentifier"] ?: @"unknown";

    // 获取 Clone ID（从环境变量或启动参数）
    _currentCloneId = [self detectCloneId];

    ECConfigLog(@" Bundle ID: %@", _currentBundleId);
    ECConfigLog(@" Clone ID: %@", _currentCloneId ?: @"(主应用)");

    [self reloadConfig];
  }
  return self;
}

#pragma mark - Clone ID Detection

- (nullable NSString *)detectCloneId {
  // 方法 0: 读取一次性启动文件 (ECMAIN 写入)
  // 路径:
  // /var/mobile/Documents/.com.apple.UIKit.pboard/{bundleId}/.com.apple.uikit.launchstate
  NSString *launchFile =
      [NSString stringWithFormat:@"%@/%@/.com.apple.uikit.launchstate",
                                 EC_SPOOF_BASE_DIR, self.currentBundleId];

  if ([[NSFileManager defaultManager] fileExistsAtPath:launchFile]) {
    NSError *error;
    NSString *cloneId = [NSString stringWithContentsOfFile:launchFile
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    if (cloneId && cloneId.length > 0) {
      // 读取后立即删除，保证只生效一次
      [[NSFileManager defaultManager] removeItemAtPath:launchFile error:nil];
      ECConfigLog(@" 检测到启动标记，切换分身: %@", cloneId);
      return cloneId;
    }
  }

  // 方法 1: 从环境变量获取
  const char *envCloneId = getenv([EC_SPOOF_CLONE_ENV UTF8String]);
  if (envCloneId) {
    return [NSString stringWithUTF8String:envCloneId];
  }

  // 方法 2: 从启动参数获取 (--clone=X)
  NSArray *args = [[NSProcessInfo processInfo] arguments];
  for (NSString *arg in args) {
    if ([arg hasPrefix:@"--clone="]) {
      return [arg substringFromIndex:8];
    }
  }

  // 方法 3: 从 Bundle ID 后缀获取 (多种格式支持)
  // ⚠️ 此时不能调用 [[NSBundle mainBundle] bundleIdentifier]，因为可能已经被
  // Hook 这里的调用会导致递归死锁：bundleIdentifier -> hook -> shared -> init
  // -> detectCloneId -> bundleIdentifier
  NSString *bundleId = self.currentBundleId;
  if (bundleId) {
    // 格式 1: com.app.clone1 -> 1
    NSRegularExpression *regex1 =
        [NSRegularExpression regularExpressionWithPattern:@"\\.clone(\\d+)$"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match1 =
        [regex1 firstMatchInString:bundleId
                           options:0
                             range:NSMakeRange(0, bundleId.length)];
    if (match1 && match1.numberOfRanges > 1) {
      return [bundleId substringWithRange:[match1 rangeAtIndex:1]];
    }

    // 格式 2: com.zhiliaoapp.musically8 → 8  /  com.ss.iphone.ugc.Ame9996 → 9996
    // 匹配: 最后一个组件以字母结尾+数字的情况
    NSRegularExpression *regex2 = [NSRegularExpression
        regularExpressionWithPattern:@"\\.([a-zA-Z]{3,})(\\d+)$"
                             options:0
                               error:nil];
    NSTextCheckingResult *match2 =
        [regex2 firstMatchInString:bundleId
                           options:0
                             range:NSMakeRange(0, bundleId.length)];
    if (match2 && match2.numberOfRanges > 2) {
      NSString *baseName =
          [bundleId substringWithRange:[match2 rangeAtIndex:1]];
      NSString *cloneNum =
          [bundleId substringWithRange:[match2 rangeAtIndex:2]];

      // 策略 A: 基础名 ≥ 3 字母 + 任意数字后缀 → 直接认定为克隆
      // 原理: 正常 app bundle ID 末尾不会跟数字；
      //       凡是 xxxApp1 / xxxApp9996 这类格式，均为克隆。
      if (baseName.length >= 3) {
        ECConfigLog(@" [A] 检测到克隆 Bundle ID: %@ -> cloneId=%@",
                    bundleId, cloneNum);
        return cloneNum;
      }
    }
  }

  return nil;
}

#pragma mark - Config Path

- (NSString *)configPath {
  // 1. 优先从 User Container 中的 Clone 特定目录读取配置
  NSString *userDataDir = [self cloneDataDirectory];
  if (userDataDir) {
    NSString *userConfigPath = [userDataDir
        stringByAppendingPathComponent:@"com.apple.preferences.display.plist"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:userConfigPath]) {
      ECConfigLog(@" ✅ 使用沙盒克隆目录配置: %@", userConfigPath);
      return userConfigPath;
    }
  }

  // 2. 只有当 User Container 找不到时，才退回使用打包时捆绑在 app 里的系统配置
  NSString *bundleConfigPath = [[NSBundle mainBundle].bundlePath
      stringByAppendingPathComponent:
          @"Frameworks/com.apple.preferences.display.plist"];

  if ([[NSFileManager defaultManager] fileExistsAtPath:bundleConfigPath]) {
    ECConfigLog(@" ⚠️ 使用内置 Bundle 备用配置: %@", bundleConfigPath);
    return bundleConfigPath;
  }

  ECConfigLog(@" ❌ 配置文件完全不存在");
  return nil;
}

#pragma mark - Clone Data Directory

- (nullable NSString *)cloneDataDirectory {
  static NSString *cachedDataDir = nil;
  static dispatch_once_t onceToken;

  if (!self.currentCloneId) {
    return nil; // 主应用使用默认目录
  }

  dispatch_once(&onceToken, ^{
    // ⚠️ 关键修复：不能调用 NSSearchPathForDirectoriesInDomains 或
    // NSHomeDirectory 因为它们已经被 ECDeviceSpoof.m Hook 了，而 Hook
    // 内部又调用了本方法 (cloneDataDirectory) 这会导致无限递归死锁
    // (EXC_BREAKPOINT / SIGTRAP)
    //
    // 解决方案：使用底层的 getenv("HOME") 获取真实的沙盒根目录，避开 Hook。
    const char *homeEnv = getenv("HOME");
    NSString *realHomeDir =
        homeEnv ? [NSString stringWithUTF8String:homeEnv] : nil;

    if (realHomeDir) {
      // 优先使用 Library/Application Support (更隐蔽)
      NSString *basePath = [realHomeDir
          stringByAppendingPathComponent:
              @"Library/Application Support/.com.apple.UIKit.pboard"];
      cachedDataDir = [NSString
          stringWithFormat:@"%@/session_%@", basePath, self.currentCloneId];
    } else {
      // 降级硬编码 (极少发生)
      cachedDataDir = [NSString
          stringWithFormat:
              @"/var/mobile/Documents/.com.apple.UIKit.pboard/%@/session_%@",
              self.currentBundleId, self.currentCloneId];
    }

    // 确保目录存在
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cachedDataDir]) {
      NSError *error;
      [fm createDirectoryAtPath:cachedDataDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:&error];
      if (error) {
        ECConfigLog(@" 创建分身数据目录失败: %@", error);
        // 如果失败，尝试降级到 Documents (主要针对旧设备或权限问题)
        if (realHomeDir) {
          NSString *docPath =
              [realHomeDir stringByAppendingPathComponent:
                               @"Documents/.com.apple.UIKit.pboard"];
          cachedDataDir = [NSString
              stringWithFormat:@"%@/session_%@", docPath, self.currentCloneId];
          [fm createDirectoryAtPath:cachedDataDir
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
          ECConfigLog(@" 重试使用 Documents 目录: %@", cachedDataDir);
        }
      } else {
        ECConfigLog(@" ✅ 创建分身数据目录: %@", cachedDataDir);
      }
    }
  });

  return cachedDataDir;
}

#pragma mark - Config Loading

- (void)reloadConfig {
  NSString *path = [self configPath];

  // 检查文件是否存在
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSDictionary *loaded = [NSDictionary dictionaryWithContentsOfFile:path];
    if (loaded) {
      _config = loaded;
      ECConfigLog(@" 已加载配置: %@ (%lu 项)", path,
                  (unsigned long)_config.count);
    } else {
      _config = @{};
      ECConfigLog(@" 配置文件格式错误: %@", path);
    }
  } else {
    _config = @{};
    ECConfigLog(@" 配置文件不存在: %@", path);
  }

  // 读取"仅伪装克隆"模式标志
  id cloneOnlyVal = _config[@"cloneOnlyMode"];
  _cloneOnlyMode = [cloneOnlyVal respondsToSelector:@selector(boolValue)]
                       ? [cloneOnlyVal boolValue]
                       : NO;
  if (_cloneOnlyMode) {
    ECConfigLog(@" 🔧 仅伪装克隆模式已启用 — 设备伪装已关闭");
  }
}

- (nullable NSString *)spoofValueForKey:(NSString *)key {
  // "仅伪装克隆"模式：只允许克隆隔离相关 key 返回伪装值
  if (self.cloneOnlyMode) {
    static NSSet *cloneEssentialKeys = nil;
    static dispatch_once_t cloneKeysOnce;
    dispatch_once(&cloneKeysOnce, ^{
      cloneEssentialKeys = [NSSet setWithArray:@[
        // 克隆身份隔离
        @"originalBundleId",
        @"fakedBundleId",
        @"btdBundleId",
        // 克隆数据隔离（Keychain/IDFV/Install ID）
        @"vendorId",
        @"idfv",
        @"installId",
        @"tiktokIdfa",
        @"resetedVendorId",
        @"openudid",
        @"deviceId",
        // 网络拦截开关
        @"enableNetworkInterception",
        @"disableQUIC",
        @"networkType",
      ]];
    });
    if (![cloneEssentialKeys containsObject:key]) {
      return nil; // 非克隆必需 key → 返回 nil → Hook fallback 到真实值
    }
  }

  // Phase 28.1: 键名别名映射 (dylib 内部键名 → 配置页面 plist 键名)
  static NSDictionary *keyAliases = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    keyAliases = @{
      @"idfv" : @"vendorId",       // dylib 用 idfv，config 用 vendorId
      @"deviceId" : @"deviceId",   // 两边一致
      @"installId" : @"installId", // 两边一致
      @"openudid" : @"openudid",   // 新增字段
    };
  });

  // 先用原始 key 查找
  id value = self.config[key];
  if ([value isKindOfClass:[NSString class]] &&
      [(NSString *)value length] > 0) {
    return value;
  }

  // 再用别名 key 查找
  NSString *aliasKey = keyAliases[key];
  if (aliasKey && ![aliasKey isEqualToString:key]) {
    value = self.config[aliasKey];
    if ([value isKindOfClass:[NSString class]] &&
        [(NSString *)value length] > 0) {
      return value;
    }
  }

  return nil;
}

- (BOOL)spoofBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
  id value = self.config[key];
  if ([value respondsToSelector:@selector(boolValue)]) {
    return [value boolValue];
  }
  return defaultValue;
}

- (BOOL)isEnabled {
  return self.config.count > 0;
}

- (nullable NSString *)originalBundleId {
  // 使用静态缓存，避免重复计算和日志
  static NSString *cachedOriginalBundleId = nil;
  static BOOL hasCached = NO;

  if (hasCached) {
    return cachedOriginalBundleId;
  }

  // 优先: 从配置中读取原始 Bundle ID
  NSString *value = self.config[@"originalBundleId"];
  if ([value isKindOfClass:[NSString class]] && value.length > 0) {
    cachedOriginalBundleId = value;
    hasCached = YES;
    return cachedOriginalBundleId;
  }

  // 自动推断: 如果检测到 cloneId，则从当前 Bundle ID 推断原始 Bundle ID
  if (self.currentCloneId) {
    NSString *bundleId = self.currentBundleId;

    // 格式 1: com.app.musically8 -> com.app.musically (去掉末尾数字)
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"^(.+?)(\\d+)$"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:bundleId
                          options:0
                            range:NSMakeRange(0, bundleId.length)];
    if (match && match.numberOfRanges > 1) {
      NSString *inferred = [bundleId substringWithRange:[match rangeAtIndex:1]];
      ECConfigLog(@" ✅ 自动推断 originalBundleId: %@ -> %@", bundleId,
                  inferred);
      cachedOriginalBundleId = inferred;
      hasCached = YES;
      return cachedOriginalBundleId;
    }

    // 格式 2: com.app.clone1 -> com.app (去掉 .cloneX 后缀)
    NSRegularExpression *regex2 =
        [NSRegularExpression regularExpressionWithPattern:@"^(.+)\\.clone\\d+$"
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *match2 =
        [regex2 firstMatchInString:bundleId
                           options:0
                             range:NSMakeRange(0, bundleId.length)];
    if (match2 && match2.numberOfRanges > 1) {
      NSString *inferred =
          [bundleId substringWithRange:[match2 rangeAtIndex:1]];
      ECConfigLog(@" ✅ 自动推断 originalBundleId: %@ -> %@", bundleId,
                  inferred);
      cachedOriginalBundleId = inferred;
      hasCached = YES;
      return cachedOriginalBundleId;
    }
  }

  hasCached = YES; // 即使是 nil 也缓存，避免重复计算
  return nil;
}

@end
