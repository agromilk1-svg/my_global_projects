//
//  SCPrefLoader.m
//  ECDeviceSpoof
//
//  配置读取模块实现 - 支持按 Bundle ID + Clone ID 读取配置
//

#import "SCPrefLoader.h"
#import <Security/Security.h>

// 文件日志（与 ECDeviceSpoof.m 共享同一个日志文件）
// ⚠️ 2026-02-03: 禁用文件写入，避免高频调用导致 I/O 性能问题
static void ECConfigLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ECConfigLog(NSString *format, ...) {
#if 1 // 开启日志以排查分身隔离失效问题
  va_list args;
  va_start(args, format);
  NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  NSLog(@"[ECDeviceSpoof] %@", logMsg);
#endif
}

@interface SCPrefLoader ()
@property(nonatomic, strong) NSDictionary *config;
@property(nonatomic, strong) NSString *currentBundleId;
@property(nonatomic, strong) NSString *currentCloneId;
@end

@implementation SCPrefLoader

+ (instancetype)shared {
  static SCPrefLoader *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[SCPrefLoader alloc] init];
  });
  return instance;
}

+ (void)prewarmConfig {
  // 异步初始化，避免阻塞主线程或 constructor
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   [[SCPrefLoader shared] originalBundleId];
                 });
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // [v2254 致命漏洞修复]: 在极早期的 C constructor 中，[[NSBundle mainBundle] infoDictionary]
    // 往往返回缓存甚至原版的数据。为了获取克隆包被修改后的绝对真实 Bundle ID，
    // 我们必须直接从磁盘读取 Info.plist 以绕过内存缓存和潜在的 Hook 冲突！
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *infoPlistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *physicalInfo = [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    
    _currentBundleId = physicalInfo[@"CFBundleIdentifier"] ?: @"unknown";

    // 获取 Clone ID（从环境变量或启动参数或正则表达式）
    _currentCloneId = [self detectCloneId];

    ECConfigLog(@" 物理读取 Bundle ID: %@", _currentBundleId);
    ECConfigLog(@" 解析出 Clone ID: %@", _currentCloneId ?: @"(主应用/无分身标志)");

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
    // [v2260] 修复 Sandbox deny 问题
    // 之前使用 /var/mobile/Documents/ 会被 App Sandbox 策略拒绝写入
    // 现在改用 App 自身沙盒的 Documents 目录（getenv("HOME")/Documents/）
    // TrollStore 安装的 App 对自身沙盒有完整读写权限
    const char *homeEnv = getenv("HOME");
    NSString *sandboxPath;
    if (homeEnv) {
      sandboxPath = [[NSString stringWithUTF8String:homeEnv]
          stringByAppendingPathComponent:@"Documents/.ecdata"];
    } else {
      // 兜底：使用 NSSearchPath
      NSString *docDir = [NSSearchPathForDirectoriesInDomains(
          NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
      sandboxPath = [docDir stringByAppendingPathComponent:@".ecdata"];
    }
    cachedDataDir = [NSString stringWithFormat:@"%@/session_%@", sandboxPath, self.currentCloneId];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 确保分身数据目录存在
    if (![fm fileExistsAtPath:cachedDataDir]) {
      [fm createDirectoryAtPath:cachedDataDir withIntermediateDirectories:YES attributes:nil error:nil];
      ECConfigLog(@" ✅ 创建分身数据目录: %@", cachedDataDir);
    }
    
    // =========================================================================
    // [v2297 修复] 基于标记文件的清洗触发机制
    // 之前仅靠 session_XX 目录是否存在来判断，但同一 Clone ID 重复使用时
    // 目录已存在，清洗永远不会触发，导致旧数据泄漏。
    // 新策略：在 session_XX 内放 .clean_done_{cloneId} 标记文件，
    // 如果标记不存在则说明需要清洗（新克隆或需要重置）。
    // =========================================================================
    NSString *cleanMarker = [cachedDataDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@".clean_done_%@", self.currentCloneId]];
    
    if (![fm fileExistsAtPath:cleanMarker]) {
        ECConfigLog(@" 🧹 [沙盒清洗] 未检测到清洗标记，开始清理旧数据...");
        
        // 1. 内存及域级别的清除
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults removePersistentDomainForName:bundleID];
        [defaults synchronize];
        [NSUserDefaults resetStandardUserDefaults];
        
        // 2. 物理文件的彻底绞杀
        if (homeEnv) {
            NSString *homePath = [NSString stringWithUTF8String:homeEnv];
            
            // 2.1 智能核弹清理 Library 目录 (终极修复：避免 UIKit 状态恢复崩溃)
            NSString *libDir = [homePath stringByAppendingPathComponent:@"Library"];
            NSArray *libFiles = [fm contentsOfDirectoryAtPath:libDir error:nil];
            
            // 需要清空内容，但保留目录本身的系统路径
            NSSet *emptyOnlyDirs = [NSSet setWithObjects:@"Caches", @"Application Support", @"Cookies", @"WebKit", @"HTTPStorages", nil];
            // 绝对不能碰的系统 UI 状态路径（删除会导致 _handleDelegateCallbacksWithOptions 崩溃）
            NSSet *ignoreDirs = [NSSet setWithObjects:@"Saved Application State", @"SplashBoard", nil];
            
            for (NSString *file in libFiles) {
                NSString *fullPath = [libDir stringByAppendingPathComponent:file];
                
                if ([ignoreDirs containsObject:file]) {
                    ECConfigLog(@" 🛡️ [核弹清理] 跳过系统 UI 状态目录: Library/%@", file);
                    continue;
                }
                else if ([file isEqualToString:@"Preferences"]) {
                    // 对于 Preferences，只删除特定的 plist，不全清以避免 cfprefsd 崩溃
                    NSArray *prefFiles = [fm contentsOfDirectoryAtPath:fullPath error:nil];
                    for (NSString *p in prefFiles) {
                        if ([p hasPrefix:@"com.ss."] || [p hasPrefix:@"group.com.ss."] || [p containsString:@"tiktok"] || [p containsString:@"stability"] || [p containsString:@"hts."]) {
                            [fm removeItemAtPath:[fullPath stringByAppendingPathComponent:p] error:nil];
                        }
                    }
                    ECConfigLog(@" 🧹 [核弹清理] 已精细清理 Library/Preferences");
                } 
                else if ([emptyOnlyDirs containsObject:file]) {
                    // 对于系统目录，清空其内部所有内容
                    BOOL isDir = NO;
                    if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
                        NSArray *innerFiles = [fm contentsOfDirectoryAtPath:fullPath error:nil];
                        for (NSString *innerFile in innerFiles) {
                            [fm removeItemAtPath:[fullPath stringByAppendingPathComponent:innerFile] error:nil];
                        }
                        ECConfigLog(@" 🧹 [核弹清理] 已清空系统保留目录: Library/%@", file);
                    }
                } 
                else {
                    // 对于 ByteDance 创建的各种垃圾目录（Heimdallr, AWEStorage 等）直接删除
                    [fm removeItemAtPath:fullPath error:nil];
                    ECConfigLog(@" 🧹 [核弹清理] 已直接删除: Library/%@", file);
                }
            }
            
            // 2.2 核弹级清理 Documents (保留我们的数据目录 .ecdata 和 FakeAppGroup)
            NSString *docDir = [homePath stringByAppendingPathComponent:@"Documents"];
            NSArray *docFiles = [fm contentsOfDirectoryAtPath:docDir error:nil];
            for (NSString *file in docFiles) {
                if (![file isEqualToString:@".ecdata"] && ![file isEqualToString:@"FakeAppGroup"]) {
                    [fm removeItemAtPath:[docDir stringByAppendingPathComponent:file] error:nil];
                    ECConfigLog(@" 🧹 [核弹清理] 已删除 Documents/%@", file);
                }
            }
            
            // 2.3 清理 tmp
            NSString *tmpDir = [homePath stringByAppendingPathComponent:@"tmp"];
            NSArray *tmpFiles = [fm contentsOfDirectoryAtPath:tmpDir error:nil];
            for (NSString *file in tmpFiles) {
                [fm removeItemAtPath:[tmpDir stringByAppendingPathComponent:file] error:nil];
            }
            
            // 2.6 清理 FakeAppGroup 中旧号的数据
            NSString *fakeGroupDir = [homePath stringByAppendingPathComponent:
                [NSString stringWithFormat:@"Documents/FakeAppGroup/%@", self.currentCloneId]];
            if ([fm fileExistsAtPath:fakeGroupDir]) {
                [fm removeItemAtPath:fakeGroupDir error:nil];
                ECConfigLog(@" 🧹 已清理旧 FakeAppGroup 数据: %@", fakeGroupDir);
            }
            
            // 2.7 [致命修复] 清除持久化的伪装指纹 (IDFV, device_id 等)
            // 如果不清除，即使沙盒空了，生成的旧 IDFV 也会让服务端识别为同一台设备并下发旧的账号数据。
            NSArray *ecDataFiles = [fm contentsOfDirectoryAtPath:cachedDataDir error:nil];
            for (NSString *file in ecDataFiles) {
                if ([file hasPrefix:@".com.ec_"] && [file hasSuffix:@".dat"]) {
                    [fm removeItemAtPath:[cachedDataDir stringByAppendingPathComponent:file] error:nil];
                    ECConfigLog(@" 🧹 [指纹重置] 已删除旧指纹数据: %@", file);
                }
            }
            
            ECConfigLog(@" 🧹 [全面清洗] 成功清空了旧沙盒遗留的所有目录及硬件指纹。");
        }
        
        // 3. Keychain 清理 — ByteDance SDK 在 Keychain 中存储 device_id/install_id
        // 这是导致"新克隆仍读取旧数据"的根因！即使文件全删，Keychain 残留会让 SDK
        // 认为这是旧设备。
        ECConfigLog(@" 🔐 [Keychain] 开始清理旧的设备标识...");
        NSDictionary *kcQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword
        };
        OSStatus kcStatus = SecItemDelete((__bridge CFDictionaryRef)kcQuery);
        ECConfigLog(@" 🔐 [Keychain] GenericPassword 清理完成 (status: %d)", (int)kcStatus);
        
        // 针对 ByteDance 特定 service 精准清理
        NSArray *bdServices = @[
            @"com.bytedance.device.id",
            @"com.ss.iphone.ugc.aweme.device_id",
            @"com.bytedance.pass.token",
            @"com.ss.iphone.ugc.aweme"
        ];
        for (NSString *svc in bdServices) {
            NSDictionary *svcQuery = @{
                (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                (__bridge id)kSecAttrService: svc
            };
            SecItemDelete((__bridge CFDictionaryRef)svcQuery);
            ECConfigLog(@" 🔐 [Keychain] 已清理 service: %@", svc);
        }
        
        ECConfigLog(@" 🧹 [沙盒清洗] 完成！已彻底切断旧 device_id 及缓存的源头。");
        
        // 写入清洗标记，防止下次启动重复清洗
        [@"done" writeToFile:cleanMarker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        
        // [修复] 不再强制终止进程，清洗完直接继续运行
        // 原因：_exit(0) 导致多一次重启循环，增加闪退风险
        // 清洗已完成，后续 ECDeviceSpoof 初始化会重建所有 Hook 和伪装
        ECConfigLog(@" ✅ [环境重置] 沙盒清洗完成，继续正常启动流程");
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
