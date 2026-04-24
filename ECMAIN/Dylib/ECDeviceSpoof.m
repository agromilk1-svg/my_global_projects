//
//  ECDeviceSpoof.m
//  ECDeviceSpoof
//
//  设备信息伪装 dylib 主实现
//  使用 Method Swizzling 和 fishhook Hook 系统 API
//

#import "ECDeviceSpoof.h"
#import "SCPrefLoader.h"
#import "ECObfuscation.h"
#import "fishhook.h"
#import <AdSupport/ASIdentifierManager.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTCellularData.h>   // 网络权限触发所需
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <SystemConfiguration/SystemConfiguration.h> // For CNCopyCurrentNetworkInfo
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <stdio.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
// Socket headers — QUIC 禁用需要
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
// Anti-Debug headers
#import <IOKit/IOKitLib.h> // For IORegistryEntry hooks
#import <dlfcn.h>
#import <sys/types.h>

// Forward declarations
static void ecSavePersistentID(NSString *key, NSString *value);
static NSString *ecLoadPersistentID(NSString *key);
static void setupSafeHooks(void);

// Keychain Isolation
#import <Security/Security.h>
#import <libkern/OSAtomic.h>
#import <objc/runtime.h> // Added for Associated Object Caching

#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif

// ===================================
// 防御性机制 - 防止 TikTok SDK 初始化时的类型错乱崩溃 (v2240)
// ===================================
// 根因：TikTok 内部 SDK（ByteDance 崩溃/监控组件）在初始化时查找配置对象，
// 返回了 @[]（全局空数组单例 __NSArray0 0x1fabfb4e8），
// 然后依次调用大量 setter 和 getter。
//
// v2239 的 setter-only 拦截解决了 setter 崩溃，但 TikTok 随后调用 getter
// 读取配置值（如 [config appID]），在 @[] 上返回后解引用 nil 导致 SIGSEGV。
//
// v2240 终极方案：将 resolveInstanceMethod 缩窄到 __NSArray0 类，
// 同时处理 setter（no-op）和 getter（返回 nil），让 @[] 伪装成"空配置对象"。

// 通用 no-op setter — void(id, SEL, id)
static void ec_noop_setter(id self, SEL _cmd, id value) {
    // 静默忽略
}

// ⚠️ [v2253 致命架构修复] 废弃对 __NSArray0 的全局 getter 兜底！
// 原有的 resolveInstanceMethod 会污染 respondsToSelector: 的结果，导致
// TikTok 底层 KVC/KVO 误认为该空数组具备真实模型的所有属性，进而引发
// Foundation 内部的严重崩溃（如 _unionOfArraysForKeyPath: -> characterAtIndex: 越界）。
// 现在我们只保留最基本的 setter 防护（防止意外赋值闪退），对所有 getter
// 保持原样，让系统的 respondsToSelector: 正常返回 NO，以触发 TikTok 自带的安全降级分支。

// 原始的 +[__NSArray0 resolveInstanceMethod:]
static BOOL (*_orig_EmptyArray_resolveInstanceMethod)(id, SEL, SEL) = NULL;

static BOOL ec_EmptyArray_resolveInstanceMethod(id self, SEL _cmd, SEL sel) {
    const char *selName = sel_getName(sel);
    if (selName && selName[0] != '_') {
        size_t len = strlen(selName);
        // 只保留对 setter 的兜底拦截（防止对降级的空数组调用 setAppID: 等赋值操作导致闪退）
        if (len > 4 && strncmp(selName, "set", 3) == 0) {
            if (!class_getInstanceMethod([NSArray class], sel)) {
                class_addMethod(self, sel, (IMP)ec_noop_setter, "v@:@");
                NSLog(@"[ECFix] 🛡️ __NSArray0 +setter: %s", selName);
                return YES;
            }
        }
    }
    
    if (_orig_EmptyArray_resolveInstanceMethod) {
        return _orig_EmptyArray_resolveInstanceMethod(self, _cmd, sel);
    }
    return NO;
}


// --- Swizzle NSArray 的 KVO 方法 ---
static IMP _orig_NSArray_addObserver = NULL;

static void ec_NSArray_addObserver(id self, SEL _cmd, NSObject *observer,
                                    NSString *keyPath, NSKeyValueObservingOptions options,
                                    void *context) {
    if ([self count] == 0 && [self isKindOfClass:[NSArray class]] &&
        ![self isKindOfClass:[NSMutableArray class]]) {
        NSLog(@"[ECFix] ⚠️ 拦截 NSArray.addObserver:forKeyPath:%@", keyPath);
        return;
    }
    if (_orig_NSArray_addObserver) {
        ((void (*)(id, SEL, NSObject *, NSString *, NSKeyValueObservingOptions, void *))
         _orig_NSArray_addObserver)(self, _cmd, observer, keyPath, options, context);
    }
}

// removeObserver 也要拦截，否则 dealloc 时会崩
static IMP _orig_NSArray_removeObserver = NULL;

static void ec_NSArray_removeObserver(id self, SEL _cmd, NSObject *observer,
                                       NSString *keyPath) {
    if ([self count] == 0 && [self isKindOfClass:[NSArray class]] &&
        ![self isKindOfClass:[NSMutableArray class]]) {
        return; // 静默忽略
    }
    if (_orig_NSArray_removeObserver) {
        ((void (*)(id, SEL, NSObject *, NSString *))
         _orig_NSArray_removeObserver)(self, _cmd, observer, keyPath);
    }
}

// 安装全部防护（由 ECDeviceSpoofInitialize 调用）
static void installTikTokCrashGuards(void) {
    // 1. 获取 __NSArray0 类（空数组单例的真实类）
    Class emptyArrayClass = [@[] class];
    NSLog(@"[ECFix] 空数组类: %@", NSStringFromClass(emptyArrayClass));

    // 2. 在 __NSArray0 的**元类**上添加 +resolveInstanceMethod:
    //    ⚠️ 不能用 method_setImplementation！因为 class_getClassMethod 会沿元类链
    //    找到 NSObject 的方法，setImplementation 会修改 NSObject → 影响所有类！
    //    必须用 class_addMethod 在 __NSArray0 元类上新增方法，仅覆盖继承。
    Method origResolve = class_getClassMethod(emptyArrayClass, @selector(resolveInstanceMethod:));
    if (origResolve) {
        _orig_EmptyArray_resolveInstanceMethod =
            (BOOL (*)(id, SEL, SEL))method_getImplementation(origResolve);
    }
    Class emptyArrayMeta = object_getClass(emptyArrayClass);
    BOOL added = class_addMethod(emptyArrayMeta,
                                  @selector(resolveInstanceMethod:),
                                  (IMP)ec_EmptyArray_resolveInstanceMethod,
                                  "B@::");
    if (added) {
        NSLog(@"[ECFix] ✅ 已在 %@ 元类添加 +resolveInstanceMethod:", NSStringFromClass(emptyArrayClass));
    } else {
        NSLog(@"[ECFix] ⚠️ %@ 元类已有 +resolveInstanceMethod:，使用 swizzle 替换",
              NSStringFromClass(emptyArrayClass));
        // 如果 __NSArray0 自己已经有了（不太可能），才用 method_setImplementation
        Method existingMethod = class_getClassMethod(emptyArrayClass, @selector(resolveInstanceMethod:));
        if (existingMethod) {
            method_setImplementation(existingMethod, (IMP)ec_EmptyArray_resolveInstanceMethod);
        }
    }

    // 3. Swizzle NSArray 的 addObserver / removeObserver
    Method addM = class_getInstanceMethod([NSArray class],
                @selector(addObserver:forKeyPath:options:context:));
    if (addM) {
        _orig_NSArray_addObserver = method_getImplementation(addM);
        method_setImplementation(addM, (IMP)ec_NSArray_addObserver);
    }

    Method removeM = class_getInstanceMethod([NSArray class],
                @selector(removeObserver:forKeyPath:));
    if (removeM) {
        _orig_NSArray_removeObserver = method_getImplementation(removeM);
        method_setImplementation(removeM, (IMP)ec_NSArray_removeObserver);
    }

    NSLog(@"[ECFix] ✅ 全部防护已安装");
}


// ===================================
// 全局状态 - 纯净化 Hook 专用
// ===================================
// 允许 Hook 直接读取，无需经过 Config 单例初始化
static NSString *g_spoofedBundleId = nil;
static volatile BOOL g_spoofConfigLoaded = NO;

// Phase 27.2: In-Memory Cache for Linkage Spoofing
static NSString *g_cachedDeviceID = nil;
static NSString *g_cachedInstallID = nil;
static NSString *g_cachedIDFV = nil;

// === 真实设备信息缓存 (Hook 安装前捕获) ===
static CGFloat g_realScreenWidth = 0;
static CGFloat g_realScreenHeight = 0;
static CGFloat g_realScreenScale = 0;
static CGFloat g_realNativeWidth = 0;
static CGFloat g_realNativeHeight = 0;
static NSInteger g_realMaxFPS = 0;
static NSString *g_realMachineModel = nil;
static NSString *g_realSystemVersion = nil;
static NSString *g_realDeviceModel = nil;
static NSString *g_realDeviceName = nil;
static NSString *g_realLocaleId = nil;
static NSString *g_realLanguageCode = nil;
static NSString *g_realCountryCode = nil;
static NSString *g_realTimezone = nil;
static NSString *g_realPreferredLang = nil;
static NSString *g_realCurrencyCode = nil;

// ============================================================================
// __NSCFLocale Hook - 使用显式 IMP 存储避免跨类 swizzle 问题
// ============================================================================
// 存储原始 IMP
static IMP _orig_NSCFLocale_objectForKey = NULL;
static IMP _orig_NSCFLocale_localeIdentifier = NULL;
static IMP _orig_NSCFLocale_countryCode = NULL;
static IMP _orig_NSCFLocale_languageCode = NULL;
static IMP _orig_NSCFLocale_currencyCode = NULL;

// 前向声明替换函数
static id hooked_NSCFLocale_objectForKey(id self, SEL _cmd, NSLocaleKey key);
static NSString *hooked_NSCFLocale_localeIdentifier(id self, SEL _cmd);
static NSString *hooked_NSCFLocale_countryCode(id self, SEL _cmd);
static NSString *hooked_NSCFLocale_languageCode(id self, SEL _cmd);
static NSString *hooked_NSCFLocale_currencyCode(id self, SEL _cmd);

// ============================================================================
// TikTok 专用 Hook - AWE/ByteDance 自定义 API
// ============================================================================
// 存储原始 IMP
static IMP _orig_NSUserDefaults_objectForKey_tiktok = NULL;
static IMP _orig_AWELanguageManager_currentLanguage = NULL;
static IMP _orig_isOfficialBundleId = NULL;
static IMP _orig_awe_vendorID = NULL;
static IMP _orig_awe_installID = NULL;
static IMP _orig_tspk_idfa = NULL;
static IMP _orig_resetedVendorID = NULL;
static IMP _orig_fakedBundleID = NULL;
static IMP _orig_btd_bundleIdentifier = NULL;
static IMP _orig_systemLanguage = NULL;
static IMP _orig_btd_currentLanguage = NULL;
static IMP _orig_storeRegion = NULL;
static IMP _orig_priorityRegion = NULL;
static IMP _orig_currentRegion = NULL;
static IMP _orig_containerPath = NULL;
// Passport Config Hook 存储
typedef id (*PassportConfig_POST_IMP)(id, SEL, NSString *, NSDictionary *, id);
typedef id (*PassportConfig_GET_IMP)(id, SEL, NSString *, NSDictionary *, id);
static PassportConfig_POST_IMP _orig_passportConfig_POST = NULL;
static PassportConfig_GET_IMP _orig_passportConfig_GET = NULL;

// TTInstallIDManager Hook 存储
typedef NSString *(*TTInstallIDManager_deviceID_IMP)(id, SEL);
typedef NSString *(*TTInstallIDManager_installID_IMP)(id, SEL);
static TTInstallIDManager_deviceID_IMP _orig_installMgr_deviceID = NULL;
static TTInstallIDManager_installID_IMP _orig_installMgr_installID = NULL;

// BDInstall Hook 存储
typedef void (*BDInstall_setDeviceID_IMP)(id, SEL, NSString *);
typedef void (*BDInstall_setInstallID_IMP)(id, SEL, NSString *);
static BDInstall_setDeviceID_IMP _orig_bdinstall_setDeviceID = NULL;
static BDInstall_setInstallID_IMP _orig_bdinstall_setInstallID = NULL;

typedef NSString *(*BDInstall_deviceID_IMP)(id, SEL);
typedef NSString *(*BDInstall_installID_IMP)(id, SEL);
static BDInstall_deviceID_IMP _orig_bdinstall_deviceID = NULL;
static BDInstall_installID_IMP _orig_bdinstall_installID = NULL;

// 前向声明 - TikTok Hook 函数
static id hooked_NSUserDefaults_objectForKey_tiktok(id self, SEL _cmd,
                                                    NSString *key);
static BOOL hooked_isOfficialBundleId(id self, SEL _cmd);
static NSString *hooked_awe_vendorID(id self, SEL _cmd);
static NSString *hooked_awe_installID(id self, SEL _cmd);
static NSString *hooked_tspk_idfa(id self, SEL _cmd);
static NSString *hooked_resetedVendorID(id self, SEL _cmd);
static NSString *hooked_fakedBundleID(id self, SEL _cmd);
static NSString *hooked_btd_bundleIdentifier(id self, SEL _cmd);
static NSString *hooked_systemLanguage(id self, SEL _cmd);
static NSString *hooked_btd_currentLanguage(id self, SEL _cmd);
static NSString *hooked_storeRegion(id self, SEL _cmd);
static NSString *hooked_priorityRegion(id self, SEL _cmd);
static NSString *hooked_currentRegion(id self, SEL _cmd);
static NSString *hooked_containerPath(id self, SEL _cmd);
static NSString *hooked_awe_deviceID(id self, SEL _cmd);

// Forward declarations
static void setupAntiDetectionHooks(void);
static void setupDataIsolationHooks(void);
static void setupMethodSwizzling(void);
static void setupSysctlHook(void);
static void setupMobileGestaltHook(void);
static void setupLoginDiagnosticHooks(void);
static void setupCloneDetectionBypass(void);
static void setupDeepProtection(void);

// ============================================================================
// 全局 rebind_symbols 合并机制
// 原来各 setup 函数各自调用 rebind_symbols，每次都遍历 200+ 个 images 的符号表
// 现在改为先注册到全局数组，最后统一调用一次 rebind_symbols
// 从 6 次全局遍历 → 1 次全局遍历
// ============================================================================
#define EC_MAX_REBINDINGS 32
static struct rebinding g_pending_rebindings[EC_MAX_REBINDINGS];
static int g_pending_rebinding_count = 0;

// 注册一个待 rebind 的符号（不立即执行 rebind）
static void ec_register_rebinding(const char *name, void *replacement,
                                  void **replaced) {
  if (g_pending_rebinding_count >= EC_MAX_REBINDINGS) {
    // 静默跳过，不输出日志
    return;
  }
  g_pending_rebindings[g_pending_rebinding_count++] =
      (struct rebinding){name, replacement, replaced};
}

// 统一执行所有注册的 rebind（只遍历一次所有 images）
static void performMergedRebind(void) {
  if (g_pending_rebinding_count == 0) {
    // 无待处理符号
    return;
  }
  int result = rebind_symbols(g_pending_rebindings, g_pending_rebinding_count);
  (void)result; // 静默执行
  // 清零计数器（防止重复 rebind）
  g_pending_rebinding_count = 0;
}

// 调试日志开关
// ☁️ 2026-02-26: 启用日志以分析 MSSDK 风控和网络交互
#define EC_DEBUG_LOG_ENABLED 1
#define EC_FILE_LOG_ENABLED 0

static void ECLog(NSString *format, ...) {
#if EC_DEBUG_LOG_ENABLED
  va_list args;
  va_start(args, format);
  NSString *logMsg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  // 同时输出到 NSLog （加入 ecwg 前缀方便控制台过滤）
  NSLog(@"[ecwg][ECDeviceSpoof] %@", logMsg);

#if EC_FILE_LOG_ENABLED
  // 文件日志已禁用，不创建任何日志目录和文件
  static NSString *logPath = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    const char *homeEnv = getenv("HOME");
    if (homeEnv) {
      NSString *logDir = [[NSString stringWithUTF8String:homeEnv]
          stringByAppendingPathComponent:
              @"Library/Caches/.com.apple.nsurlsessiond.cache"];
      [[NSFileManager defaultManager] createDirectoryAtPath:logDir
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
      logPath = [logDir stringByAppendingPathComponent:@"session.log"];
      // 清空旧日志
      [@"" writeToFile:logPath
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:nil];
    });

    if (logPath) {
      NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
      [fmt setDateFormat:@"HH:mm:ss.SSS"];
      NSString *timestamp = [fmt stringFromDate:[NSDate date]];
      NSString *line =
          [NSString stringWithFormat:@"[%@] %@\n", timestamp, logMsg];

      NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
      [fh seekToEndOfFile];
      [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
      [fh closeFile];
    }
#endif
#endif
}

#pragma mark - Method Swizzling Helper

static void swizzleInstanceMethod(Class cls, SEL original, SEL replacement) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method newMethod = class_getInstanceMethod(cls, replacement);

    if (!origMethod || !newMethod) {
      ECLog(@" Swizzle failed: method not found for %@",
            NSStringFromSelector(original));
      return;
    }

    // 1. 尝试将 'original' 添加到 cls (如果 cls
    // 是继承的，这一步会添加一个实现指向 newMethod)
    if (class_addMethod(cls, original, method_getImplementation(newMethod),
                        method_getTypeEncoding(newMethod))) {
      // 这种情况很少见，因为通常我们是 hook 存在的系统方法。
      // 如果加成功了，说明原来没这个方法（可能是父类的），现在加了一个
      // 'original' 名字的方法，实现是 newImpl 那么我们需要把 'replacement'
      // 方法的实现换成 origImpl (父类的实现)

      class_replaceMethod(cls, replacement,
                          method_getImplementation(origMethod),
                          method_getTypeEncoding(origMethod));
    } else {
      // 2. 如果 'original' 已经存在 (class_addMethod 失败)

      // 关键修正：确保 'replacement' 方法也存在于当前 cls 中
      // 如果 replacement 是在分类中定义的（例如 NSLocaleCategory），它是在
      // NSLocale 中。 如果 cls 是 __NSCFLocale (子类)，它可能没有 replacement
      // 方法。 直接交换会导致修改 NSLocale 的 method list。

      BOOL addedReplacement =
          class_addMethod(cls, replacement, method_getImplementation(newMethod),
                          method_getTypeEncoding(newMethod));

      if (addedReplacement) {
        // 如果只要添加到子类了，更新 newMethod 指向子类的方法结构
        newMethod = class_getInstanceMethod(cls, replacement);
      }

      method_exchangeImplementations(origMethod, newMethod);
    }
    ECLog(@" Swizzled: %@ -> %@", NSStringFromSelector(original),
          NSStringFromSelector(replacement));
}

#pragma mark - __NSCFLocale Hook Implementations (使用显式 IMP 存储)

// 这些函数直接替换 __NSCFLocale 的方法，并使用存储的原始 IMP 调用原方法
// 避免了跨类 swizzle 的问题

static id hooked_NSCFLocale_objectForKey(id self, SEL _cmd, NSLocaleKey key) {
    SCPrefLoader *config = [SCPrefLoader shared];

    if ([key isEqualToString:NSLocaleCountryCode]) {
      NSString *spoofed = [config spoofValueForKey:@"countryCode"];
      if (spoofed)
        return spoofed;
    } else if ([key isEqualToString:NSLocaleLanguageCode]) {
      NSString *spoofed = [config spoofValueForKey:@"languageCode"];
      if (spoofed)
        return spoofed;
    } else if ([key isEqualToString:NSLocaleCurrencyCode]) {
      NSString *spoofed = [config spoofValueForKey:@"currencyCode"];
      if (spoofed)
        return spoofed;
    } else if ([key isEqualToString:NSLocaleIdentifier]) {
      NSString *spoofed = [config spoofValueForKey:@"localeIdentifier"];
      if (spoofed)
        return spoofed;
    }

    // 调用原始实现
    if (_orig_NSCFLocale_objectForKey) {
      return ((id(*)(id, SEL, NSLocaleKey))_orig_NSCFLocale_objectForKey)(
          self, _cmd, key);
    }
    return nil;
}

static NSString *hooked_NSCFLocale_localeIdentifier(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"localeIdentifier"];
    if (spoofed)
      return spoofed;

    if (_orig_NSCFLocale_localeIdentifier) {
      return ((NSString * (*)(id, SEL))
                  _orig_NSCFLocale_localeIdentifier)(self, _cmd);
    }
    return nil;
}

static NSString *hooked_NSCFLocale_countryCode(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"countryCode"];
    if (spoofed)
      return spoofed;

    if (_orig_NSCFLocale_countryCode) {
      return ((NSString * (*)(id, SEL)) _orig_NSCFLocale_countryCode)(self,
                                                                      _cmd);
    }
    return nil;
}

static NSString *hooked_NSCFLocale_languageCode(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"languageCode"];
    if (spoofed)
      return spoofed;

    if (_orig_NSCFLocale_languageCode) {
      return ((NSString * (*)(id, SEL)) _orig_NSCFLocale_languageCode)(self,
                                                                       _cmd);
    }
    return nil;
}

static NSString *hooked_NSCFLocale_currencyCode(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"currencyCode"];
    if (spoofed)
      return spoofed;

    if (_orig_NSCFLocale_currencyCode) {
      return ((NSString * (*)(id, SEL)) _orig_NSCFLocale_currencyCode)(self,
                                                                       _cmd);
    }
    return nil;
}

// 设置 __NSCFLocale hooks 的函数
static void setupNSCFLocaleHooks(void) {
    Class nscfLocaleClass = NSClassFromString(EC_CLS_NSCFLocale);
    if (!nscfLocaleClass) {
      ECLog(@" __NSCFLocale class not found, skipping locale hooks");
      return;
    }

    Method m;

    // objectForKey:
    m = class_getInstanceMethod(nscfLocaleClass, @selector(objectForKey:));
    if (m) {
      _orig_NSCFLocale_objectForKey = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_NSCFLocale_objectForKey);
      ECLog(@" Hooked: __NSCFLocale -objectForKey:");
    }

    // localeIdentifier
    m = class_getInstanceMethod(nscfLocaleClass, @selector(localeIdentifier));
    if (m) {
      _orig_NSCFLocale_localeIdentifier = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_NSCFLocale_localeIdentifier);
      ECLog(@" Hooked: __NSCFLocale -localeIdentifier");
    }

    // countryCode
    m = class_getInstanceMethod(nscfLocaleClass, @selector(countryCode));
    if (m) {
      _orig_NSCFLocale_countryCode = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_NSCFLocale_countryCode);
      ECLog(@" Hooked: __NSCFLocale -countryCode");
    }

    // languageCode
    m = class_getInstanceMethod(nscfLocaleClass, @selector(languageCode));
    if (m) {
      _orig_NSCFLocale_languageCode = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_NSCFLocale_languageCode);
      ECLog(@" Hooked: __NSCFLocale -languageCode");
    }

    // currencyCode
    m = class_getInstanceMethod(nscfLocaleClass, @selector(currencyCode));
    if (m) {
      _orig_NSCFLocale_currencyCode = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_NSCFLocale_currencyCode);
      ECLog(@" Hooked: __NSCFLocale -currencyCode");
    }

    ECLog(@" __NSCFLocale hooks installed successfully");
}

#pragma mark - TikTok 专用 Hook Implementations

// Hook: 拦截 NSUserDefaults 读取 TikTok 语言设置
static id hooked_NSUserDefaults_objectForKey_tiktok(id self, SEL _cmd,
                                                    NSString *key) {
    // 拦截 TikTok 专用语言键
    if ([key isEqualToString:@"awe_extensionPreferredLanguage"] ||
        [key containsString:@"preferredLanguage"] ||
        [key containsString:@"currentLanguage"]) {
      NSString *spoofedLang =
          [[SCPrefLoader shared] spoofValueForKey:@"preferredLanguage"];
      if (spoofedLang) {
        // ECLog(@" [TikTok] Intercepted key: %@ -> %@", key, spoofedLang);
        return spoofedLang;
      }
    }

    // 拦截 TikTok 设备相关键
    if ([key containsString:@"installID"] ||
        [key containsString:@"install_id"]) {
      NSString *spoofedId =
          [[SCPrefLoader shared] spoofValueForKey:@"installId"];
      if (spoofedId) {
        // ECLog(@" [TikTok] Intercepted install ID key: %@ -> %@", key,
        // spoofedId);
        return spoofedId;
      }
    }

    // 调用原始实现
    if (_orig_NSUserDefaults_objectForKey_tiktok) {
      return (
          (id(*)(id, SEL, NSString *))_orig_NSUserDefaults_objectForKey_tiktok)(
          self, _cmd, key);
    }
    return nil;
}

// Hook: 始终返回 YES 表示官方 Bundle ID
static BOOL hooked_isOfficialBundleId(id self, SEL _cmd) {
    // ECLog(@" [TikTok] isOfficialBundleId called, returning YES");
    return YES;
}

// Hook: awe_vendorID - 返回伪装的厂商 ID
static NSString *hooked_awe_vendorID(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"vendorId"];
    if (spoofed) {
      // ECLog(@" [TikTok] awe_vendorID -> %@", spoofed);
      return spoofed;
    }

    // 如果没有配置，调用原始实现
    if (_orig_awe_vendorID) {
      return ((NSString * (*)(id, SEL)) _orig_awe_vendorID)(self, _cmd);
    }
    return [[NSUUID UUID] UUIDString]; // 回退到随机值
}

// Hook: awe_installID - 返回伪装的安装 ID
static NSString *hooked_awe_installID(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"installId"];
    if (spoofed) {
      // ECLog(@" [TikTok] awe_installID -> %@", spoofed);
      return spoofed;
    }

    // 如果没有配置，调用原始实现
    if (_orig_awe_installID) {
      return ((NSString * (*)(id, SEL)) _orig_awe_installID)(self, _cmd);
    }
    return nil;
}

// Hook: tspk_idfa_advertisingIdentifier - 返回伪装的广告 ID
static NSString *hooked_tspk_idfa(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"tiktokIdfa"];
    if (spoofed && spoofed.length > 0) {
      // ECLog(@" [TikTok] tspk_idfa -> %@", spoofed);
      return spoofed;
    }
    if (_orig_tspk_idfa) {
      return ((NSString * (*)(id, SEL)) _orig_tspk_idfa)(self, _cmd);
    }
    return @"00000000-0000-0000-0000-000000000000";
}

// Hook: resetedVendorID - 返回伪装的重置后厂商 ID
static NSString *hooked_resetedVendorID(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"resetedVendorId"];
    if (spoofed && spoofed.length > 0) {
      // ECLog(@" [TikTok] resetedVendorID -> %@", spoofed);
      return spoofed;
    }
    if (_orig_resetedVendorID) {
      return ((NSString * (*)(id, SEL)) _orig_resetedVendorID)(self, _cmd);
    }
    return [[NSUUID UUID] UUIDString];
}

// Hook: fakedBundleID - 返回空值表示非伪造
static NSString *hooked_fakedBundleID(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"fakedBundleId"];
    if (spoofed && spoofed.length > 0) {
      // ECLog(@" [TikTok] fakedBundleID -> %@", spoofed);
      return spoofed;
    }
    // 返回 nil 表示这不是伪造的 Bundle ID
    // ECLog(@" [TikTok] fakedBundleID -> nil (正常)");
    return nil;
}

// Hook: btd_bundleIdentifier - 返回官方 Bundle ID
static NSString *hooked_btd_bundleIdentifier(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"btdBundleId"];
    if (spoofed && spoofed.length > 0) {
      // ECLog(@" [TikTok] btd_bundleIdentifier -> %@", spoofed);
      return spoofed;
    }
    
    // 动态获取：优先获取去除了分身后缀的原始应用包名
    NSString *inferredOriginal = [[SCPrefLoader shared] originalBundleId];
    if (inferredOriginal && inferredOriginal.length > 0) {
       return inferredOriginal;
    }

    // 默认回退：非多开环境下，直接获取它真实的 Bundle Identifier
    NSString *realDynamicID = [[NSBundle mainBundle] infoDictionary][@"CFBundleIdentifier"];
    if (realDynamicID && realDynamicID.length > 0) {
       return realDynamicID;
    }

    // 终极兜底策略
    return EC_STR_officialBundleId;
}

// Hook: systemLanguage - 返回伪装的系统语言
static NSString *hooked_systemLanguage(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"systemLanguage"];
    if (spoofed && spoofed.length > 0) {
      return spoofed;
    }
    if (_orig_systemLanguage) {
      return ((NSString * (*)(id, SEL)) _orig_systemLanguage)(self, _cmd);
    }
    // 回退: 从 languageCode 获取，避免硬编码 "en" 导致与目标区域矛盾
    NSString *langFallback =
        [[SCPrefLoader shared] spoofValueForKey:@"languageCode"];
    return langFallback ?: @"en";
}

// Hook: btd_currentLanguage - 返回伪装的 ByteDance 当前语言
static NSString *hooked_btd_currentLanguage(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"btdCurrentLanguage"];
    if (spoofed && spoofed.length > 0) {
      return spoofed;
    }
    if (_orig_btd_currentLanguage) {
      return ((NSString * (*)(id, SEL)) _orig_btd_currentLanguage)(self, _cmd);
    }
    // 回退: 从 preferredLanguage 获取，避免硬编码 "en"
    NSString *langFallback =
        [[SCPrefLoader shared] spoofValueForKey:@"preferredLanguage"];
    if (!langFallback) {
      langFallback =
          [[SCPrefLoader shared] spoofValueForKey:@"languageCode"];
    }
    return langFallback ?: @"en";
}

// Hook: storeRegion - 返回伪装的商店区域 (PNSStoreRegionSource)
static NSString *hooked_storeRegion(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"storeRegion"];
    if (spoofed && spoofed.length > 0) {
      return spoofed;
    }
    if (_orig_storeRegion) {
      return ((NSString * (*)(id, SEL)) _orig_storeRegion)(self, _cmd);
    }
    // 回退: 从 countryCode 获取，避免硬编码 "US"
    NSString *regionFallback =
        [[SCPrefLoader shared] spoofValueForKey:@"countryCode"];
    return regionFallback ?: @"US";
}

// Hook: priorityRegion - 返回伪装的优先区域 (PNSPriorityRegionSource)
static NSString *hooked_priorityRegion(id self, SEL _cmd) {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"priorityRegion"];
    if (spoofed && spoofed.length > 0) {
      return spoofed;
    }
    if (_orig_priorityRegion) {
      return ((NSString * (*)(id, SEL)) _orig_priorityRegion)(self, _cmd);
    }
    // 回退: 从 countryCode 获取
    NSString *regionFallback =
        [[SCPrefLoader shared] spoofValueForKey:@"countryCode"];
    return regionFallback ?: @"US";
}

// Hook: currentRegion - 返回伪装的当前区域 (PNSCurrentRegionSource)
static NSString *hooked_currentRegion(id self, SEL _cmd) {
    // 优先使用 storeRegion，因为 currentRegion 和 storeRegion 语义相同
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"storeRegion"];
    if (!spoofed || spoofed.length == 0) {
      // 回退到 countryCode
      spoofed = [[SCPrefLoader shared] spoofValueForKey:@"countryCode"];
    }
    if (spoofed && spoofed.length > 0) {
      return spoofed;
    }
    if (_orig_currentRegion) {
      return ((NSString * (*)(id, SEL)) _orig_currentRegion)(self, _cmd);
    }
    // 最终回退
    NSString *regionFallback =
        [[SCPrefLoader shared] spoofValueForKey:@"countryCode"];
    return regionFallback ?: @"US";
}

// Hook: containerPath - 返回原始容器路径 (反检测)
static NSString *hooked_containerPath(id self, SEL _cmd) {
    // 返回 nil 或原始路径，防止克隆检测
    // ECLog(@" [TikTok] containerPath called - returning nil");
    return nil;
}

// 设置 TikTok 专用 hooks 的函数
static void setupTikTokHooks(void) {
    ECLog(@" Setting up TikTok-specific hooks...");

    Method m;

    // Hook AWEFakeBundleIDManager 的 isOfficialBundleId 方法
    Class fakeBundleIdClass = NSClassFromString(EC_CLS_AWEFakeBundleIDManager);
    if (fakeBundleIdClass) {
      m = class_getInstanceMethod(fakeBundleIdClass,
                                  NSSelectorFromString(EC_SEL_isOfficialBundleId));
      if (m) {
        _orig_isOfficialBundleId = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_isOfficialBundleId);
        ECLog(@" Hooked: AWEFakeBundleIDManager -isOfficialBundleId");
      }
      // 也尝试类方法
      m = class_getClassMethod(fakeBundleIdClass,
                               NSSelectorFromString(EC_SEL_isOfficialBundleId));
      if (m) {
        method_setImplementation(m, (IMP)hooked_isOfficialBundleId);
        ECLog(@" Hooked: AWEFakeBundleIDManager +isOfficialBundleId");
      }
    }

    // Hook NSUserDefaults 的 awe_vendorID 属性 (可能是分类方法)
    m = class_getInstanceMethod([NSUserDefaults class],
                                NSSelectorFromString(EC_SEL_awe_vendorID));
    if (m) {
      _orig_awe_vendorID = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_awe_vendorID);
      ECLog(@" Hooked: NSUserDefaults -awe_vendorID");
    }

    // Hook awe_installID
    m = class_getInstanceMethod([NSUserDefaults class],
                                NSSelectorFromString(EC_SEL_awe_installID));
    if (m) {
      _orig_awe_installID = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_awe_installID);
      ECLog(@" Hooked: NSUserDefaults -awe_installID");
    }

    // 也尝试 Hook AWELanguageManager
    Class aweLanguageManagerClass = NSClassFromString(EC_CLS_AWELanguageManager);
    if (aweLanguageManagerClass) {
      ECLog(@" Found AWELanguageManager class");
      // 尝试 Hook currentLanguage 方法
      m = class_getInstanceMethod(aweLanguageManagerClass,
                                  NSSelectorFromString(EC_SEL_currentLanguage));
      if (m) {
        _orig_AWELanguageManager_currentLanguage = method_getImplementation(m);
        // 使用通用语言返回
        IMP newImp = imp_implementationWithBlock(^NSString *(id self) {
          NSString *spoofed = [[SCPrefLoader shared]
              spoofValueForKey:@"preferredLanguage"];
          if (spoofed) {
            // ECLog(@" [TikTok] AWELanguageManager.currentLanguage -> %@",
            // spoofed);
            return spoofed;
          }
          if (_orig_AWELanguageManager_currentLanguage) {
            return ((NSString * (*)(id, SEL))
                        _orig_AWELanguageManager_currentLanguage)(
                self, NSSelectorFromString(EC_SEL_currentLanguage));
          }
          // 回退: 从 languageCode 获取，避免硬编码 "en"
          NSString *langFb =
              [[SCPrefLoader shared] spoofValueForKey:@"languageCode"];
          return langFb ?: @"en";
        });
        method_setImplementation(m, newImp);
        ECLog(@" Hooked: AWELanguageManager -currentLanguage");
      }

      // Hook systemLanguage
      m = class_getInstanceMethod(aweLanguageManagerClass,
                                  NSSelectorFromString(EC_SEL_systemLanguage));
      if (m) {
        _orig_systemLanguage = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_systemLanguage);
        ECLog(@" Hooked: AWELanguageManager -systemLanguage");
      }
    }

    // [DISABLED] IDFA 相关 Hook 已禁用 — 克隆环境下无需伪装
    // Class tspkClass = NSClassFromString(@"TSPrivacyKitDeviceInfo");
    // if (tspkClass) { ... tspk_idfa_advertisingIdentifier ... }

    // Hook AWEDeviceManager 相关方法
    Class deviceManagerClass = NSClassFromString(EC_CLS_AWEDeviceManager);
    if (deviceManagerClass) {
      m = class_getInstanceMethod(deviceManagerClass,
                                  NSSelectorFromString(EC_SEL_resetedVendorID));
      if (m) {
        _orig_resetedVendorID = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_resetedVendorID);
        ECLog(@" Hooked: AWEDeviceManager -resetedVendorID");
      }
    }

    // Hook fakedBundleID getter
    if (fakeBundleIdClass) {
      m = class_getInstanceMethod(fakeBundleIdClass,
                                  NSSelectorFromString(EC_SEL_fakedBundleID));
      if (m) {
        _orig_fakedBundleID = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_fakedBundleID);
        ECLog(@" Hooked: AWEFakeBundleIDManager -fakedBundleID");
      }
    }

    // Hook btd_bundleIdentifier (NSBundle 分类方法)
    m = class_getInstanceMethod([NSBundle class],
                                NSSelectorFromString(EC_SEL_btd_bundleIdentifier));
    if (m) {
      _orig_btd_bundleIdentifier = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_btd_bundleIdentifier);
      ECLog(@" Hooked: NSBundle -btd_bundleIdentifier");
    }

    // Hook btd_currentLanguage (可能是 NSLocale 分类)
    m = class_getInstanceMethod([NSLocale class],
                                NSSelectorFromString(EC_SEL_btd_currentLanguage));
    if (m) {
      _orig_btd_currentLanguage = method_getImplementation(m);
      method_setImplementation(m, (IMP)hooked_btd_currentLanguage);
      ECLog(@" Hooked: NSLocale -btd_currentLanguage");
    }

    // Hook PNSRegionSDK 相关类
    Class pnsStoreRegionClass = NSClassFromString(EC_CLS_PNSStoreRegionSource);
    if (pnsStoreRegionClass) {
      m = class_getInstanceMethod(pnsStoreRegionClass,
                                  NSSelectorFromString(EC_SEL_region));
      if (m) {
        _orig_storeRegion = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_storeRegion);
        ECLog(@" Hooked: PNSStoreRegionSource -region");
      }
    }

    Class pnsPriorityRegionClass =
        NSClassFromString(EC_CLS_PNSPriorityRegionSource);
    if (pnsPriorityRegionClass) {
      m = class_getInstanceMethod(pnsPriorityRegionClass,
                                  NSSelectorFromString(EC_SEL_region));
      if (m) {
        _orig_priorityRegion = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_priorityRegion);
        ECLog(@" Hooked: PNSPriorityRegionSource -region");
      }
    }

    Class pnsCurrentRegionClass = NSClassFromString(EC_CLS_PNSCurrentRegionSource);
    if (pnsCurrentRegionClass) {
      m = class_getInstanceMethod(pnsCurrentRegionClass,
                                  NSSelectorFromString(EC_SEL_region));
      if (m) {
        _orig_currentRegion = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_currentRegion);
        ECLog(@" Hooked: PNSCurrentRegionSource -region");
      }
    }

    // Hook containerPath 防止克隆检测
    if (fakeBundleIdClass) {
      m = class_getInstanceMethod(fakeBundleIdClass,
                                  NSSelectorFromString(EC_SEL_containerPath));
      if (m) {
        _orig_containerPath = method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_containerPath);
        ECLog(@" Hooked: AWEFakeBundleIDManager -containerPath");
      }
    }

    ECLog(@" TikTok-specific hooks installed");

    // ============================================================================
    // AAWEBootChecker 安全框架绕过 (TikTok 启动时检查)
    // ============================================================================
    Class bootCheckerClass = NSClassFromString(EC_CLS_AAWEBootChecker);
    if (bootCheckerClass) {
      ECLog(@"🛡️ [Security] Found AAWEBootChecker, installing bypasses...");

      // Hook shouldCheckPlusLoad - 禁用 +load 方法 Hook 检测
      SEL shouldCheckPlusLoadSel = NSSelectorFromString(EC_SEL_shouldCheckPlusLoad);
      Method shouldCheckPlusLoadMethod =
          class_getClassMethod(bootCheckerClass, shouldCheckPlusLoadSel);
      if (shouldCheckPlusLoadMethod) {
        // 返回 NO 禁用检测
        IMP newImp = imp_implementationWithBlock(^BOOL(id self) {
          ECLog(@"🛡️ [AAWEBootChecker] shouldCheckPlusLoad -> NO (bypassed)");
          return NO;
        });
        method_setImplementation(shouldCheckPlusLoadMethod, newImp);
        ECLog(@"✅ Hooked: +[AAWEBootChecker shouldCheckPlusLoad]");
      }

      // Hook shouldCheckTargetPath: - 禁用路径检测
      SEL shouldCheckTargetPathSel =
          NSSelectorFromString(EC_SEL_shouldCheckTargetPath);
      Method shouldCheckTargetPathMethod =
          class_getClassMethod(bootCheckerClass, shouldCheckTargetPathSel);
      if (shouldCheckTargetPathMethod) {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self,
                                                       NSString *path) {
          ECLog(
              @"🛡️ [AAWEBootChecker] shouldCheckTargetPath:%@ -> NO (bypassed)",
              path);
          return NO;
        });
        method_setImplementation(shouldCheckTargetPathMethod, newImp);
        ECLog(@"✅ Hooked: +[AAWEBootChecker shouldCheckTargetPath:]");
      }

      // Hook environment - 返回空/安全的环境信息
      SEL environmentSel = NSSelectorFromString(EC_SEL_environment);
      Method environmentMethod =
          class_getClassMethod(bootCheckerClass, environmentSel);
      if (environmentMethod) {
        IMP newImp = imp_implementationWithBlock(^NSDictionary *(id self) {
          ECLog(@"🛡️ [AAWEBootChecker] environment -> {} (bypassed)");
          return @{}; // 返回空字典
        });
        method_setImplementation(environmentMethod, newImp);
        ECLog(@"✅ Hooked: +[AAWEBootChecker environment]");
      }
    } else {
      ECLog(@"⚠️ [Security] AAWEBootChecker class not found (not TikTok?)");
    }

    // ============================================================================
    // AAWEBootStub 绕过
    // ============================================================================
    Class bootStubClass = NSClassFromString(EC_CLS_AAWEBootStub);
    if (bootStubClass) {
      ECLog(@"🛡️ [Security] Found AAWEBootStub, installing bypasses...");

      // 尝试 Hook run 或 start 方法
      SEL runSel = NSSelectorFromString(EC_SEL_run);
      Method runMethod = class_getInstanceMethod(bootStubClass, runSel);
      if (runMethod) {
        IMP newImp = imp_implementationWithBlock(^(id self) {
          ECLog(@"🛡️ [AAWEBootStub] run -> (bypassed, doing nothing)");
          // 什么都不做
        });
        method_setImplementation(runMethod, newImp);
        ECLog(@"✅ Hooked: -[AAWEBootStub run]");
      }
    }

    // ============================================================================
    // TTSecurityPlugins 安全插件绕过
    // ============================================================================
    Class securityPluginClass =
        NSClassFromString(EC_CLS_TTSecurityPlugins);
    if (securityPluginClass) {
      ECLog(@"🛡️ [Security] Found TTSecurityPluginsAdapterPostLaunchTask...");

      // Hook run 方法 - 禁用启动后安全检查
      SEL runSel = NSSelectorFromString(EC_SEL_run);
      Method runMethod = class_getInstanceMethod(securityPluginClass, runSel);
      if (runMethod) {
        IMP newImp = imp_implementationWithBlock(^(id self) {
          ECLog(@"🛡️ [TTSecurityPlugins] PostLaunchTask run -> (bypassed)");
          // 什么都不做
        });
        method_setImplementation(runMethod, newImp);
        ECLog(@"✅ Hooked: -[TTSecurityPluginsAdapterPostLaunchTask run]");
      }

      // Hook execute 方法 (备选)
      SEL executeSel = NSSelectorFromString(EC_SEL_execute);
      Method executeMethod =
          class_getInstanceMethod(securityPluginClass, executeSel);
      if (executeMethod) {
        IMP newImp = imp_implementationWithBlock(^(id self) {
          ECLog(@"🛡️ [TTSecurityPlugins] PostLaunchTask execute -> (bypassed)");
        });
        method_setImplementation(executeMethod, newImp);
        ECLog(@"✅ Hooked: -[TTSecurityPluginsAdapterPostLaunchTask execute]");
      }
    }

    // ============================================================================
    // AAAASingularity 混淆安全框架绕过
    // 策略：枚举类所有方法，对返回 BOOL 的方法批量 hook
    //   - 看起来像 "check/detect/isXxx/enabled" → 返回 NO（检测不到）
    //   - 看起来像 "pass/allow/valid/safe"       → 返回 YES（通过）
    // ============================================================================
    Class singularityClass = NSClassFromString(EC_CLS_AAAASingularity);
    if (singularityClass) {
      ECLog(@"🛡️ [Security] Found AAAASingularity (Dotg12dbcAfge), installing bulk bypasses...");

      // --- 枚举实例方法 ---
      unsigned int instCount = 0;
      Method *instMethods = class_copyMethodList(singularityClass, &instCount);
      int hookedInst = 0;
      for (unsigned int mi = 0; mi < instCount; mi++) {
        Method m = instMethods[mi];
        const char *retType = method_copyReturnType(m);
        // 只处理返回 BOOL (char 'c' 或 unsigned char 'C') 的方法
        if (retType && (retType[0] == 'c' || retType[0] == 'C' || retType[0] == 'B')) {
          SEL sel = method_getName(m);
          NSString *selName = NSStringFromSelector(sel);
          
          // 【修复 1】：黑名单机制。必须要跳过系统原生 NSObject 协议的基础判断方法。
          // 原本这里会盲目 Hook isEqual: 等方法，全部被强制返回 YES，
          // 直接导致 NSArray、NSDictionary 等内部寻址操作死锁和崩溃 (EXC_BAD_ACCESS)。
          NSArray *blacklistedMethods = @[
            @"isEqual:", 
            @"isKindOfClass:", 
            @"isMemberOfClass:", 
            @"isProxy", 
            @"hash", 
            @"description", 
            @"debugDescription"
          ];
          if ([blacklistedMethods containsObject:selName]) {
            free((void *)retType);
            continue; // 遇基类防崩溃方法，跳过 Hook 安全通过
          }

          // 判断方向：返回 NO（检测类）或 YES（通过类）
          BOOL returnNO = NO;
          NSArray *detectKeywords = @[@"check", @"detect", @"jailbreak",
                                      @"root", @"hook", @"inject",
                                      @"tamper", @"debug", @"enabled",
                                      @"enable", @"active", @"running",
                                      @"risk", @"danger"];
          for (NSString *kw in detectKeywords) {
            if ([[selName lowercaseString] containsString:kw]) {
              returnNO = YES;
              break;
            }
          }
          BOOL finalVal = !returnNO; // 检测类 → NO，其他 → YES
          IMP newImp = imp_implementationWithBlock(^BOOL(id _s) {
            return finalVal;
          });
          method_setImplementation(m, newImp);
          hookedInst++;
        }
        free((void *)retType);
      }
      free(instMethods);

      // --- 枚举类方法 ---
      Class metaClass = object_getClass(singularityClass);
      unsigned int classCount = 0;
      Method *classMethods = class_copyMethodList(metaClass, &classCount);
      int hookedClass = 0;
      for (unsigned int mi = 0; mi < classCount; mi++) {
        Method m = classMethods[mi];
        const char *retType = method_copyReturnType(m);
        if (retType && (retType[0] == 'c' || retType[0] == 'C' || retType[0] == 'B')) {
          SEL sel = method_getName(m);
          NSString *selName = NSStringFromSelector(sel);
          
          NSArray *blacklistedMethods = @[
            @"isEqual:", @"isKindOfClass:", @"isMemberOfClass:", 
            @"isProxy", @"hash", @"description", @"debugDescription"
          ];
          if ([blacklistedMethods containsObject:selName]) {
            free((void *)retType);
            continue;
          }

          IMP newImp = imp_implementationWithBlock(^BOOL(id _s) { return NO; });
          method_setImplementation(m, newImp);
          hookedClass++;
        }
        free((void *)retType);
      }
      free(classMethods);

      ECLog(@"✅ [AAAASingularity] Hooked %d instance + %d class methods",
            hookedInst, hookedClass);
    }

    // --- XCTest 框架检测绕过 ---
    // AAAASingularity 会扫描已加载的 dylib 镜像列表，发现 XCTest 就触发终止
    // 通过 hook _dyld_image_count / _dyld_get_image_name 过滤掉 XCTest 条目
    {
      // 对 NSBundle 注入一个 hook，让 bundleWithIdentifier: 对 XCTest 返回 nil
      Class nsBundleClass = [NSBundle class];
      SEL bundleWithIdSel = @selector(bundleWithIdentifier:);
      Method bundleWithIdMethod = class_getClassMethod(nsBundleClass, bundleWithIdSel);
      if (bundleWithIdMethod) {
        IMP origBundleWithId = method_getImplementation(bundleWithIdMethod);
        IMP newImp = imp_implementationWithBlock(^NSBundle *(id _cls, NSString *identifier) {
          // 隐藏 XCTest 相关 bundle，防止 AAAASingularity 通过 bundle 探测
          if (identifier &&
              ([identifier containsString:EC_STR_XCTest] ||
               [identifier containsString:EC_STR_xctest] ||
               [identifier containsString:EC_STR_Testing])) {
            return nil;
          }
          return ((NSBundle *(*)(id, SEL, NSString *))origBundleWithId)(_cls, bundleWithIdSel, identifier);
        });
        method_setImplementation(bundleWithIdMethod, newImp);
        ECLog(@"✅ [XCTest-Hide] NSBundle bundleWithIdentifier: patched to hide XCTest");
      }
    }

    // TTKSingularityEPAHelper
    Class epaHelperClass = NSClassFromString(EC_CLS_TTKSingularityEPAHelper);
    if (epaHelperClass) {
      ECLog(@"🛡️ [Security] Found TTKSingularityEPAHelper...");

      // Hook isEnabled 或 check 相关方法
      SEL isEnabledSel = NSSelectorFromString(EC_SEL_isEnabled);
      Method isEnabledMethod =
          class_getClassMethod(epaHelperClass, isEnabledSel);
      if (isEnabledMethod) {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self) {
          ECLog(@"🛡️ [TTKSingularityEPAHelper] isEnabled -> NO (bypassed)");
          return NO;
        });
        method_setImplementation(isEnabledMethod, newImp);
        ECLog(@"✅ Hooked: +[TTKSingularityEPAHelper isEnabled]");
      }

      // Hook check 方法
      SEL checkSel = NSSelectorFromString(EC_SEL_check);
      Method checkMethod = class_getInstanceMethod(epaHelperClass, checkSel);
      if (checkMethod) {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self) {
          ECLog(@"🛡️ [TTKSingularityEPAHelper] check -> YES (passed)");
          return YES; // 返回通过
        });
        method_setImplementation(checkMethod, newImp);
        ECLog(@"✅ Hooked: -[TTKSingularityEPAHelper check]");
      }
    }

    // ============================================================================
    // AWERiskControlService 风控服务绕过
    // ============================================================================
    Class riskControlClass = NSClassFromString(EC_CLS_AWERiskControlService);
    if (riskControlClass) {
      ECLog(@"🛡️ [Security] Found AWERiskControlService...");

      // Hook isUnderRiskControl
      SEL isUnderRiskControlSel = NSSelectorFromString(EC_SEL_isUnderRiskControl);
      Method isUnderRiskControlMethod =
          class_getInstanceMethod(riskControlClass, isUnderRiskControlSel);
      if (isUnderRiskControlMethod) {
        IMP newImp = imp_implementationWithBlock(^BOOL(id self) {
          ECLog(@"🛡️ [AWERiskControlService] isUnderRiskControl -> NO");
          return NO; // 返回不在风控中
        });
        method_setImplementation(isUnderRiskControlMethod, newImp);
        ECLog(@"✅ Hooked: -[AWERiskControlService isUnderRiskControl]");
      }
    }

    // ============================================================================
    // Phase 5: Heimdallr 监控致盲（阻止注入信息上报）
    // ============================================================================
    Class hmdInjectedInfoClass = NSClassFromString(EC_CLS_HMDInjectedInfo);
    if (hmdInjectedInfoClass) {
      // Hook injectedInfoArray / injectedLibraries 等方法，返回空数组
      unsigned int hmdMethodCount = 0;
      Method *hmdMethods = class_copyMethodList(object_getClass(hmdInjectedInfoClass), &hmdMethodCount);
      for (unsigned int hi = 0; hi < hmdMethodCount; hi++) {
        const char *retType = method_copyReturnType(hmdMethods[hi]);
        if (retType && retType[0] == '@') {
          // 所有返回对象类型的类方法 → 返回空数组或 nil
          SEL sel = method_getName(hmdMethods[hi]);
          NSString *selName = NSStringFromSelector(sel);
          if ([selName containsString:@"inject"] || [selName containsString:@"Inject"] ||
              [selName containsString:@"image"]  || [selName containsString:@"Image"] ||
              [selName containsString:@"lib"]    || [selName containsString:@"Lib"] ||
              [selName containsString:@"info"]   || [selName containsString:@"Info"]) {
            IMP newImp = imp_implementationWithBlock(^id(id _s) { return @[]; });
            method_setImplementation(hmdMethods[hi], newImp);
          }
        }
        if (retType) free((void *)retType);
      }
      if (hmdMethods) free(hmdMethods);

      // 也 Hook 实例方法
      unsigned int hmdInstCount = 0;
      Method *hmdInstMethods = class_copyMethodList(hmdInjectedInfoClass, &hmdInstCount);
      for (unsigned int hi = 0; hi < hmdInstCount; hi++) {
        const char *retType = method_copyReturnType(hmdInstMethods[hi]);
        if (retType && retType[0] == '@') {
          SEL sel = method_getName(hmdInstMethods[hi]);
          NSString *selName = NSStringFromSelector(sel);
          if ([selName containsString:@"inject"] || [selName containsString:@"Inject"] ||
              [selName containsString:@"name"]   || [selName containsString:@"path"]) {
            IMP newImp = imp_implementationWithBlock(^id(id _s) { return @[]; });
            method_setImplementation(hmdInstMethods[hi], newImp);
          }
        }
        if (retType) free((void *)retType);
      }
      if (hmdInstMethods) free(hmdInstMethods);
    }

    // HMDBinaryImage - 过滤二进制映像列表中我们的 dylib
    Class hmdBinaryImageClass = NSClassFromString(EC_CLS_HMDBinaryImage);
    if (hmdBinaryImageClass) {
      unsigned int biMethodCount = 0;
      Method *biMethods = class_copyMethodList(object_getClass(hmdBinaryImageClass), &biMethodCount);
      for (unsigned int bi = 0; bi < biMethodCount; bi++) {
        const char *retType = method_copyReturnType(biMethods[bi]);
        if (retType && retType[0] == '@') {
          SEL sel = method_getName(biMethods[bi]);
          NSString *selName = NSStringFromSelector(sel);
          if ([selName containsString:@"image"] || [selName containsString:@"Image"] ||
              [selName containsString:@"binary"] || [selName containsString:@"Binary"]) {
            IMP origImp = method_getImplementation(biMethods[bi]);
            SEL origSel = sel;
            IMP newImp = imp_implementationWithBlock(^id(id _s) {
              id result = ((id(*)(id, SEL))origImp)(_s, origSel);
              if ([result isKindOfClass:[NSArray class]]) {
                NSMutableArray *filtered = [NSMutableArray array];
                for (id item in (NSArray *)result) {
                  NSString *desc = [item description];
                  // 过滤掉包含我们 dylib 名称的条目
                  if (![desc containsString:EC_STR_swiftCompatibilityPacks] &&
                      ![desc containsString:EC_STR_spoof_plugin]) {
                    [filtered addObject:item];
                  }
                }
                return [filtered copy];
              }
              return result;
            });
            method_setImplementation(biMethods[bi], newImp);
          }
        }
        if (retType) free((void *)retType);
      }
      if (biMethods) free(biMethods);
    }

    // ============================================================================
    // Phase 6: 增强越狱检测 + 反调试绕过
    // ============================================================================

    // Hook btd_isJailBroken（UIDevice 分类方法，TikTok 核心越狱判断）
    m = class_getInstanceMethod([UIDevice class],
                                NSSelectorFromString(EC_SEL_btd_isJailBroken));
    if (m) {
      method_setImplementation(m, imp_implementationWithBlock(^BOOL(id _s) {
        return NO;
      }));
    }
    // 也尝试类方法
    m = class_getClassMethod([UIDevice class],
                              NSSelectorFromString(EC_SEL_btd_isJailBroken));
    if (m) {
      method_setImplementation(m, imp_implementationWithBlock(^BOOL(id _s) {
        return NO;
      }));
    }

    // Hook deviceIsJailbroken 属性
    m = class_getInstanceMethod([UIDevice class],
                                NSSelectorFromString(EC_SEL_deviceIsJailbroken));
    if (m) {
      method_setImplementation(m, imp_implementationWithBlock(^BOOL(id _s) {
        return NO;
      }));
    }

    // ⚠️ objc_copyClassList 必须延迟执行！(v2224 修复)
    // ⚠️ [v2251 致命 Bug 修复] 即使是延迟执行，objc_copyClassList 在加载海量 
    // Swift 类时依然会导致 VM Fault 内存不足并抛出 SIGSEGV。
    // TikTok 体量太大，这种广撒网的 Hook 极度危险，彻底移除该逻辑！
    /*
    dispatch_async(dispatch_get_main_queue(), ^{
      ... [已移除的暴力扫描逻辑] ...
    });
    */
    ECLog(@"✅ [Security] TikTok security framework bypasses installed (广撒网扫描已移除以防止内存崩溃)");
}


#pragma mark - UIDevice Hooks

// 极速克隆标记 (v2258)
static NSString *g_FastCloneId = nil;
static BOOL g_isCloneMode = NO;
@interface UIDevice (_swiftCompat)
- (NSString *)ec_systemVersion;
- (NSString *)ec_model;
- (NSString *)ec_localizedModel;
- (NSString *)ec_name;
- (NSString *)ec_systemName;
- (NSUUID *)ec_identifierForVendor;
@end

@implementation UIDevice (_swiftCompat)

- (NSString *)ec_systemVersion {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"systemVersion"];
    if (spoofed) {
      return spoofed;
    }
    NSString *result = [self ec_systemVersion];
    return result;
}

- (NSString *)ec_model {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"machineModel"];
    if (spoofed) {
      return spoofed;
    }
    NSString *result = [self ec_model];
    return result;
}

- (NSString *)ec_localizedModel {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"localizedModel"];
    if (spoofed)
      return spoofed;
    return [self ec_localizedModel];
}

- (NSString *)ec_name {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"deviceName"];
    if (spoofed) {
      return spoofed;
    }
    NSString *result = [self ec_name];
    ECLog(@"⊞ UIDevice.name -> %@ (original)", result);
    return result;
}

- (NSString *)ec_systemName {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"systemName"];
    if (spoofed)
      return spoofed;
    return [self ec_systemName];
}

- (NSUUID *)ec_identifierForVendor {
    // Phase 28.1: 优先从 Config（配置页）读取
    NSString *spoofed = [[SCPrefLoader shared] spoofValueForKey:@"idfv"];
    if (spoofed && spoofed.length > 0) {
      NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:spoofed];
      if (uuid)
        return uuid;
    }

    // 再从持久化文件读取
    spoofed = ecLoadPersistentID(@"idfv");
    if (spoofed) {
      NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:spoofed];
      if (uuid)
        return uuid;
    }

    // 最后 fallback 到原始值
    NSUUID *result = [self ec_identifierForVendor];
    return result;
}

@end

#pragma mark - UIScreen Hooks

@interface UIScreen (_swiftCompat)
- (CGRect)ec_bounds;
- (CGFloat)ec_scale;
- (CGRect)ec_nativeBounds;
- (NSInteger)ec_maximumFramesPerSecond;
@end

@implementation UIScreen (_swiftCompat)

- (CGRect)ec_bounds {
    SCPrefLoader *config = [SCPrefLoader shared];
    NSString *widthStr = [config spoofValueForKey:@"screenWidth"];
    NSString *heightStr = [config spoofValueForKey:@"screenHeight"];

    if (widthStr && heightStr) {
      // 配置中的 screenWidth/screenHeight 保存的是逻辑点(Points)，直接使用。
      // [已移除] 之前的 width > 500 判断会错误地认为 390pt(iPhone 14) 是逻辑点
      // 而不做换算，但实际 iPhone 7 屏幕是 375pt，导致坐标系偏差约 15pt，
      // 使滑块验证码的拖动终点始终无法命中服务端期望位置。
      CGFloat width = [self parseScreenDimension:widthStr];
      CGFloat height = [self parseScreenDimension:heightStr];
      if (width > 0 && height > 0) {
        return CGRectMake(0, 0, width, height);
      }
    }
    return [self ec_bounds];
}

- (CGFloat)parseScreenDimension:(NSString *)str {
    // 提取数字部分，如 "390 (逻辑点)" -> 390
    NSScanner *scanner = [NSScanner scannerWithString:str];
    double value = 0;
    [scanner scanDouble:&value];
    return (CGFloat)value;
}

- (CGFloat)ec_scale {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"screenScale"];
    if (spoofed)
      return [spoofed floatValue];
    return [self ec_scale];
}

- (CGRect)ec_nativeBounds {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"nativeBounds"];
    if (spoofed) {
      // 格式: "1170x2532"
      NSArray *parts = [spoofed componentsSeparatedByString:@"x"];
      if (parts.count == 2) {
        CGFloat width = [parts[0] floatValue];
        CGFloat height = [parts[1] floatValue];
        return CGRectMake(0, 0, width, height);
      }
    }
    return [self ec_nativeBounds];
}

- (NSInteger)ec_maximumFramesPerSecond {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"maxFPS"];
    if (spoofed) {
      // 格式: "120 (ProMotion)" -> 120
      NSScanner *scanner = [NSScanner scannerWithString:spoofed];
      NSInteger value = 0;
      [scanner scanInteger:&value];
      return value;
    }
    return [self ec_maximumFramesPerSecond];
}

@end

#pragma mark - NSLocale Hooks

@interface NSLocale (_swiftCompat)
@end

@implementation NSLocale (_swiftCompat)

- (id)ec_locale_objectForKey:(NSLocaleKey)key {
    SCPrefLoader *config = [SCPrefLoader shared];

    if ([key isEqualToString:NSLocaleCountryCode]) {
      NSString *spoofed = [config spoofValueForKey:@"countryCode"];
      if (spoofed)
        return spoofed;
    } else if ([key isEqualToString:NSLocaleLanguageCode]) {
      NSString *spoofed = [config spoofValueForKey:@"languageCode"];
      if (spoofed)
        return spoofed;
    } else if ([key isEqualToString:NSLocaleCurrencyCode]) {
      NSString *spoofed = [config spoofValueForKey:@"currencyCode"];
      if (spoofed)
        return spoofed;
    }

    return [self ec_locale_objectForKey:key];
}

- (NSString *)ec_localeIdentifier {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"localeIdentifier"];
    if (spoofed)
      return spoofed;
    return [self ec_localeIdentifier];
}

// New Hooks
- (NSString *)ec_countryCode {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"countryCode"];
    return spoofed ? spoofed : [self ec_countryCode];
}

- (NSString *)ec_languageCode {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"languageCode"];
    return spoofed ? spoofed : [self ec_languageCode];
}

- (NSString *)ec_currencyCode {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"currencyCode"];
    return spoofed ? spoofed : [self ec_currencyCode];
}

+ (NSArray<NSString *> *)ec_preferredLanguages {
    // ★ 直接使用保存的 preferredLanguage 值，不做任何组合构建
    // 用户要求严格遵守系统 API 格式
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"preferredLanguage"];

    if (spoofed && spoofed.length > 0) {
      // 直接返回保存的值，格式应该是系统 API 原始格式 (如 "zh-Hans-JP")
      return @[ spoofed ];
    }

    // 没有配置，使用原始系统值
    return [self ec_preferredLanguages];
}

// 核心 Hook: +[NSLocale currentLocale] - 返回伪装的 Locale
// 注意: 不能在这里调用 ECLog，因为 ECLog 使用 NSDateFormatter，
// NSDateFormatter 内部会调用 currentLocale，导致无限递归和栈溢出
+ (NSLocale *)ec_currentLocale {
    NSString *identifier =
        [[SCPrefLoader shared] spoofValueForKey:@"localeIdentifier"];
    if (identifier) {
      // 不调用 ECLog 避免递归 -> 使用 NSLog (但 NSLog 也会用 locale?)
      // 使用 printf 或 write 直接输出到 stdout/stderr ?
      // 或者只在 identifier 存在时才返回新对象，如果是 nil 则返回原始
      // 假设 Config 没问题，这里的问题可能是 value 为空
      // 我们暂时不打日志，因为太危险 (Stack Overflow)
      // 但是可以用简单的 C 打印
      // printf("🔍 [NSLocale] currentLocale spoofed: %s\n",
      // identifier.UTF8String);
      return [[NSLocale alloc] initWithLocaleIdentifier:identifier];
    }
    return [self ec_currentLocale];
}

// 核心 Hook: +[NSLocale autoupdatingCurrentLocale] - 返回伪装的 Locale
+ (NSLocale *)ec_autoupdatingCurrentLocale {
    NSString *identifier =
        [[SCPrefLoader shared] spoofValueForKey:@"localeIdentifier"];
    if (identifier) {
      return [[NSLocale alloc] initWithLocaleIdentifier:identifier];
    }
    return [self ec_autoupdatingCurrentLocale];
}

// 核心 Hook: +[NSLocale systemLocale] - 返回伪装的 Locale
+ (NSLocale *)ec_systemLocale {
    NSString *identifier =
        [[SCPrefLoader shared] spoofValueForKey:@"localeIdentifier"];
    if (identifier) {
      return [[NSLocale alloc] initWithLocaleIdentifier:identifier];
    }
    return [self ec_systemLocale];
}

@end

#pragma mark - NSBundle Hooks

@interface NSBundle (_swiftCompat)
- (NSString *)ec_bundleIdentifier;
- (NSDictionary *)ec_infoDictionary;
- (id)ec_objectForInfoDictionaryKey:(NSString *)key;
- (NSString *)ec_pathForResource:(NSString *)name ofType:(NSString *)ext;
- (NSURL *)ec_appStoreReceiptURL;
@end

@implementation NSBundle (_swiftCompat)

- (NSString *)ec_bundleIdentifier {
    // Fast Path: 如果是 Main Bundle，直接返回静态缓存的伪装 ID
    // 这避免了递归调用和不必要的计算，作为 ISA Swizzling 的双重保险
    if (self == [NSBundle mainBundle]) {
      if (g_spoofConfigLoaded && g_spoofedBundleId) {
        // 仅在首次或调试时打印，避免日志爆炸
        // ECLog(@"🔍 [Method Swizzle] Intercepted bundleIdentifier: %@",
        // g_spoofedBundleId);
        return g_spoofedBundleId;
      }
    }
    return [self ec_bundleIdentifier];
}

- (NSArray<NSString *> *)ec_preferredLocalizations {
    // 获取伪装的目标语言 (e.g., "pt-BR" or "zh-Hans-CN")
    NSString *targetLang =
        [[SCPrefLoader shared] spoofValueForKey:@"preferredLanguage"];

    // 如果没有伪装配置，尝试根据 languageCode 自动构建
    if (!targetLang) {
      NSString *langCode =
          [[SCPrefLoader shared] spoofValueForKey:@"languageCode"];
      if (langCode) {
        targetLang = langCode;
      }
    }

    // 获取应用实际包含的本地化文件列表
    NSArray<NSString *> *availableLocales = [self localizations];

    if (targetLang && availableLocales.count > 0) {
      // 1. 尝试精确匹配 (e.g., "pt-BR" == "pt-BR")
      if ([availableLocales containsObject:targetLang]) {
        return @[ targetLang ];
      }

      // 2. 尝试模糊匹配/降级 (e.g., "pt-BR" -> 匹配 "pt")
      NSString *baseLang =
          [targetLang componentsSeparatedByString:@"-"].firstObject;
      if (baseLang) {
        // 特殊处理中文
        if ([baseLang isEqualToString:@"zh"]) {
          if ([targetLang containsString:@"Hans"]) {
            if ([availableLocales containsObject:@"zh-Hans"])
              return @[ @"zh-Hans" ];
            if ([availableLocales containsObject:@"zh-CN"])
              return @[ @"zh-CN" ];
          } else if ([targetLang containsString:@"Hant"]) {
            if ([availableLocales containsObject:@"zh-Hant"])
              return @[ @"zh-Hant" ];
            if ([availableLocales containsObject:@"zh-TW"])
              return @[ @"zh-TW" ];
            if ([availableLocales containsObject:@"zh-HK"])
              return @[ @"zh-HK" ];
          }
        }

        // 通用降级: 查找是否有 "pt"
        if ([availableLocales containsObject:baseLang]) {
          return @[ baseLang ];
        }
      }

      // 3. 如果完全没有匹配 (e.g. target="fr", available=["en", "zh"])
      return @[ targetLang ];
    }

    return [self ec_preferredLocalizations];
}

@end

#pragma mark - Hook Implementations

// 声明 Category 以避免编译器警告
@interface NSBundle (ECAntiDetection)
- (NSString *)ec_bundleIdentifier;
- (NSDictionary *)ec_infoDictionary;
- (id)ec_objectForInfoDictionaryKey:(NSString *)key;
- (NSString *)ec_pathForResource:(NSString *)name ofType:(NSString *)ext;
@end

@implementation NSBundle (ECAntiDetection)

// === 身份伪装 Hook ===
// 让克隆应用返回原始 Bundle ID，欺骗检测
// ⚠️ 2026-02-03: 使用原子标志 + 延迟初始化，彻底避免递归和死锁

- (NSString *)ec_bundleIdentifier {
    // 极简模式：只读变量，无逻辑
    // ⚠️ 只有在配置加载完成后才生效，避免启动期递归/死锁
    if (g_spoofConfigLoaded && g_spoofedBundleId) {
      return g_spoofedBundleId;
    }
    return [self ec_bundleIdentifier];
}

// 伪造 AppStore 收据 (Bypass FairPlay DRM Checks)
// 苹果原生 App Store 安装的应用会包含一个被签名的收据凭证
// TrollStore 侧载的应用会导致调用该 API 时返回 nil，引发系统风控
- (NSURL *)ec_appStoreReceiptURL {
    // 【欺骗级别：基础】返回 Bundle 内的预设验证收据路径。
    // TikTok 会检查该 URL 存在与否作为特征。
    // 我们将其指向 Bundle 内部路径，系统不会因为越权而中止。
    NSString *fakeReceiptPath = [[self bundlePath] stringByAppendingPathComponent:@"StoreKit/sandboxReceipt"];
    // 移除实际写入动作，TrollStore 环境下 Bundle 是只读的，
    // 只要 API 返回该 URL，大多检测就能过去。
    
    // ECLog(@"🧾 [AppStoreReceipt] 伪造 DRM 回执路径: %@", fakeReceiptPath);
    return [NSURL fileURLWithPath:fakeReceiptPath];
}

// === NSBundle infoDictionary Hook ===
// 过滤签名信息，伪装 CFBundleIdentifier
// ⚠️ 2026-02-03: 使用静态缓存，移除日志

- (NSDictionary *)ec_infoDictionary {
    // 1. 尝试从缓存获取
    // 使用静态 key，避免即使是指针比较也带来的开销
    static void *kSpoofedInfoDictionaryKey = &kSpoofedInfoDictionaryKey;
    NSDictionary *cached =
        objc_getAssociatedObject(self, kSpoofedInfoDictionaryKey);
    if (cached) {
      return cached;
    }

    // 2. 获取原始字典
    NSDictionary *original = [self ec_infoDictionary];
    if (!original)
      return original;

    // 3. 检查是否需要伪装
    // 使用 global 变量 g_spoofedBundleId 避免调用 stack
    NSString *spoofedId =
        (g_spoofConfigLoaded && g_spoofedBundleId) ? g_spoofedBundleId : nil;

    BOOL needsModification = (original[@"SignerIdentity"] != nil) ||
                             (spoofedId && ![original[@"CFBundleIdentifier"]
                                               isEqualToString:spoofedId]);

    if (!needsModification) {
      // 即使不需要修改，也建议缓存原始值，避免每次都做上面的检查逻辑
      // 但原值已经是缓存的（大多情况），所以我们只缓存修改后的
      return original;
    }

    // 4. 创建伪装字典并缓存
    NSMutableDictionary *filtered = [original mutableCopy];

    // 4.1 移除 SignerIdentity
    [filtered removeObjectForKey:@"SignerIdentity"];

    // 4.2 伪装 CFBundleIdentifier
    if (spoofedId) {
      filtered[@"CFBundleIdentifier"] = spoofedId;
    }

    // 4.3 存入缓存 (使用 OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    // 这样下次访问直接返回 filtered，不再触发 copy
    objc_setAssociatedObject(self, kSpoofedInfoDictionaryKey, filtered,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return filtered;
}

// === NSBundle objectForInfoDictionaryKey: Hook ===
// 拦截 Bundle ID 查询，返回伪装值

- (id)ec_objectForInfoDictionaryKey:(NSString *)key {
    // CFBundleIdentifier 查询：返回伪装的 Bundle ID
    if ([key isEqualToString:@"CFBundleIdentifier"]) {
      // 使用与 bundleIdentifier hook 相同的全局缓存
      if (g_spoofConfigLoaded && g_spoofedBundleId) {
        ECLog(@"🔍 [Verification] Intercepted CFBundleIdentifier: Returning %@",
              g_spoofedBundleId);
        return g_spoofedBundleId;
      }
    }

    // SignerIdentity 查询：返回 nil 隐藏签名信息
    if ([key isEqualToString:@"SignerIdentity"]) {
      return nil;
    }

    return [self ec_objectForInfoDictionaryKey:key];
}

// === NSBundle pathForResource:ofType: Hook ===
// 屏蔽 mobileprovision 资源查询

- (NSString *)ec_pathForResource:(NSString *)name ofType:(NSString *)ext {
    // 屏蔽 mobileprovision 文件查询
    if ([ext isEqualToString:@"mobileprovision"] ||
        (name && [name containsString:@"mobileprovision"])) {
      return nil;
    }
    return [self ec_pathForResource:name ofType:ext];
}

@end

#pragma mark - UIApplication URL Scheme Hook

@interface UIApplication (ECAntiDetection)
- (BOOL)ec_canOpenURL:(NSURL *)url;
@end

@implementation UIApplication (ECAntiDetection)

// === canOpenURL: Hook ===
// 阻止检测原版应用是否存在
// ⚠️ 2026-02-03: 使用静态缓存，移除日志

// 静态缓存 TikTok URL Schemes
static NSArray *_blockedSchemes = nil;

- (BOOL)ec_canOpenURL:(NSURL *)url {
    if (!url || !url.scheme) {
      return [self ec_canOpenURL:url];
    }

    // 延迟初始化黑名单
    static NSArray *_blockedSchemes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      _blockedSchemes = @[
        // Jailbreak Detection Schemes
        @"cydia", @"sileo", @"zbra", @"filza", @"undecimus", @"activator",
        @"jb",
        // TrollStore
        @"trollstore",
        // WDA (WebDriverAgent) 相关
        @"wda", @"xctrunner",
        // TikTok Mutual Wakeup/Detection Schemes
        @"tiktok", @"snssdk1128", @"snssdk1233", @"musically", @"aweme",
        @"tiktokmusically", @"musical.ly"
      ];
    });

    NSString *scheme = url.scheme.lowercaseString;

    // Debug Log: 打印所有 query，验证 Hook 是否生效
    ECLog(@"🔍 [canOpenURL] Intercepted query: %@", scheme);

    // 检查是否是需要屏蔽的 scheme
    for (NSString *blocked in _blockedSchemes) {
      if ([scheme hasPrefix:blocked]) {
        // 仅当拦截时打印日志，避免刷屏
        ECLog(@"🚫 [canOpenURL] BLOCKED scheme: %@", scheme);
        return NO;
      }
    }

    return [self ec_canOpenURL:url];
}

@end

#pragma mark - NSTimeZone Hooks

@interface NSTimeZone (_swiftCompat)
@end

@implementation NSTimeZone (_swiftCompat)

+ (NSTimeZone *)ec_localTimeZone {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"timezone"];
    if (spoofed) {
      NSTimeZone *tz = [NSTimeZone timeZoneWithName:spoofed];
      if (tz)
        return tz;
    }
    return [self ec_localTimeZone];
}

@end

#pragma mark - CTCarrier Hooks

@interface CTCarrier (_swiftCompat)
@end

@implementation CTCarrier (_swiftCompat)

- (NSString *)ec_carrierName {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"carrierName"];
    if (spoofed) {
      ECLog(@"⊞ CTCarrier.carrierName -> %@", spoofed);
      return spoofed;
    }
    NSString *result = [self ec_carrierName];
    ECLog(@"⊞ CTCarrier.carrierName -> %@ (original)", result);
    return result;
}

- (NSString *)ec_mobileNetworkCode {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"mobileNetworkCode"];
    if (spoofed) {
      ECLog(@"⊞ CTCarrier.mobileNetworkCode -> %@", spoofed);
      return spoofed;
    }
    NSString *result = [self ec_mobileNetworkCode];
    ECLog(@"⊞ CTCarrier.mobileNetworkCode -> %@ (original)", result);
    return result;
}

- (NSString *)ec_mobileCountryCode {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"mobileCountryCode"];
    if (spoofed) {
      ECLog(@"⊞ CTCarrier.mobileCountryCode -> %@", spoofed);
      return spoofed;
    }
    NSString *result = [self ec_mobileCountryCode];
    ECLog(@"⊞ CTCarrier.mobileCountryCode -> %@ (original)", result);
    return result;
}

- (NSString *)ec_isoCountryCode {
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"carrierCountry"];
    if (spoofed) {
      ECLog(@"⊞ CTCarrier.isoCountryCode -> %@", spoofed);
      return spoofed;
    }
    NSString *result = [self ec_isoCountryCode];
    ECLog(@"⊞ CTCarrier.isoCountryCode -> %@ (original)", result);
    return result;
}

@end

#pragma mark - ASIdentifierManager Hooks

@interface ASIdentifierManager (_swiftCompat)
@end

@implementation ASIdentifierManager (_swiftCompat)

- (NSUUID *)ec_advertisingIdentifier {
    NSString *spoofed = [[SCPrefLoader shared] spoofValueForKey:@"idfa"];
    if (spoofed && ![spoofed isEqualToString:@"N/A"] &&
        ![spoofed isEqualToString:@"未授权"]) {
      NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:spoofed];
      ECLog(@"⊞ ASIdentifierManager.advertisingIdentifier -> %@", spoofed);
      return uuid;
    }
    NSUUID *result = [self ec_advertisingIdentifier];
    ECLog(@"⊞ ASIdentifierManager.advertisingIdentifier -> %@ (original)",
          result.UUIDString);
    return result;
}

@end

#pragma mark - uname Hook

// 原始 uname 函数指针
#include <sys/utsname.h>
static int (*original_uname)(struct utsname *) = NULL;

// Hook uname() 以拦截 TikTok 通过 utsname.machine 获取真实机型
static int hooked_uname(struct utsname *name) {
    int result = original_uname(name);
    if (result == 0 && name) {
      SCPrefLoader *config = [SCPrefLoader shared];
      // 替换 machine 字段 (如 iPhone9,1 -> iPhone13,2)
      NSString *spoofedMachine = [config spoofValueForKey:@"machineModel"];
      if (spoofedMachine && spoofedMachine.length > 0) {
        strncpy(name->machine, spoofedMachine.UTF8String,
                sizeof(name->machine) - 1);
        name->machine[sizeof(name->machine) - 1] = '\0';
      }
      // 替换 nodename（设备名称）
      NSString *spoofedName = [config spoofValueForKey:@"deviceName"];
      if (spoofedName && spoofedName.length > 0) {
        strncpy(name->nodename, spoofedName.UTF8String,
                sizeof(name->nodename) - 1);
        name->nodename[sizeof(name->nodename) - 1] = '\0';
      }
    }
    return result;
}

#pragma mark - sysctl Hook

// 原始 sysctl 函数指针，用于屏蔽硬件伪装
static int (*original_sysctl)(int *, u_int, void *, size_t *, void *,
                              size_t) = NULL;

static int hooked_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                         void *newp, size_t newlen) {
    // 缓存调用方传进来的原始 buffer 大小
    size_t in_oldlen = oldlenp ? *oldlenp : 0;
    int result = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

    if (result == 0 && namelen >= 2) {
      SCPrefLoader *config = [SCPrefLoader shared];
      NSString *spoofed = nil;

      // hw.machine — 受 enableSysctlMachine 子开关控制 (移除对 hw.model 的伪装，否则 ARKit 等 Apple 框架会因解析失败而闪退)
      if (name[0] == CTL_HW && name[1] == HW_MACHINE) {
        if ([config spoofBoolForKey:@"enableSysctlMachine" defaultValue:YES]) {
          spoofed = [config spoofValueForKey:@"machineModel"];
        }
      }
      // kern.osversion / kern.version — 受 enableSysctlKern 子开关控制
      else if (name[0] == CTL_KERN && name[1] == KERN_OSVERSION) {
        if ([config spoofBoolForKey:@"enableSysctlKern" defaultValue:YES]) {
          spoofed = [config spoofValueForKey:@"systemBuildVersion"];
        }
      } else if (name[0] == CTL_KERN && name[1] == KERN_VERSION) {
        if ([config spoofBoolForKey:@"enableSysctlKern" defaultValue:YES]) {
          spoofed = [config spoofValueForKey:@"kernelVersion"];
        }
      }

      if (spoofed) {
        size_t spoofLen =
            [spoofed lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;

        if (oldp == NULL && oldlenp != NULL) {
          *oldlenp = spoofLen;
        } else if (oldp != NULL && oldlenp != NULL) {
          if (in_oldlen >= spoofLen) {
            strcpy((char *)oldp, spoofed.UTF8String);
            *oldlenp = spoofLen;
          } else {
            if (in_oldlen > 0) {
              strncpy((char *)oldp, spoofed.UTF8String, in_oldlen - 1);
              ((char *)oldp)[in_oldlen - 1] = '\0';
            }
            *oldlenp = in_oldlen;
          }
        }
      }
    }
    return result;
}

// 原始 sysctlbyname 函数指针，用于屏蔽硬件伪装
static int (*original_sysctlbyname)(const char *, void *, size_t *, void *,
                                    size_t) = NULL;
// Hook 后的 sysctlbyname
static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                               void *newp, size_t newlen) {
    size_t in_oldlen = oldlenp ? *oldlenp : 0;
    int result = original_sysctlbyname(name, oldp, oldlenp, newp, newlen);

    if (result == 0 && name != NULL) {
      SCPrefLoader *config = [SCPrefLoader shared];
      NSString *spoofedStr = nil;

      // 字符串类型的伪装 — 按子开关控制
      if (strcmp(name, "hw.machine") == 0) {
        if ([config spoofBoolForKey:@"enableSysctlMachine" defaultValue:YES]) {
          spoofedStr = [config spoofValueForKey:@"machineModel"];
          // 诊断日志: 确认 hw.machine hook 已拦截并替换
          if (spoofedStr && oldp) {
            ECLog(@"🔧 [sysctlbyname] hw.machine: %s → %@ ✅",
                  (char *)oldp, spoofedStr);
          }
        }
      } else if (strcmp(name, "kern.osversion") == 0) {
        if ([config spoofBoolForKey:@"enableSysctlKern" defaultValue:YES])
          spoofedStr = [config spoofValueForKey:@"systemBuildVersion"];
      } else if (strcmp(name, "kern.version") == 0) {
        if ([config spoofBoolForKey:@"enableSysctlKern" defaultValue:YES])
          spoofedStr = [config spoofValueForKey:@"kernelVersion"];
      }

      if (spoofedStr) {
        size_t spoofLen =
            [spoofedStr lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
        if (oldp == NULL && oldlenp != NULL) {
          *oldlenp = spoofLen;
        } else if (oldp != NULL && oldlenp != NULL) {
          if (in_oldlen >= spoofLen) {
            strcpy((char *)oldp, spoofedStr.UTF8String);
            *oldlenp = spoofLen;
          } else {
            if (in_oldlen > 0) {
              strncpy((char *)oldp, spoofedStr.UTF8String, in_oldlen - 1);
              ((char *)oldp)[in_oldlen - 1] = '\0';
            }
            *oldlenp = in_oldlen;
          }
        }
        return result;
      }

      // 数值/结构体类型的伪装 — 按子开关控制
      if (oldp != NULL && oldlenp != NULL) {
        if ((strcmp(name, "hw.ncpu") == 0 ||
             strcmp(name, "hw.activecpu") == 0) &&
            [config spoofBoolForKey:@"enableSysctlHardware" defaultValue:YES]) {
          NSString *cores = [config spoofValueForKey:@"cpuCores"];
          if (cores && *oldlenp >= sizeof(int)) {
            int value = [cores intValue];
            memcpy(oldp, &value, sizeof(int));
          }
        } else if (strcmp(name, "hw.memsize") == 0 &&
                   [config spoofBoolForKey:@"enableSysctlHardware"
                              defaultValue:YES]) {
          NSString *mem = [config spoofValueForKey:@"physicalMemory"];
          if (mem && *oldlenp >= sizeof(uint64_t)) {
            NSScanner *scanner = [NSScanner scannerWithString:mem];
            double gb = 0;
            [scanner scanDouble:&gb];
            uint64_t bytes = (uint64_t)(gb * 1024 * 1024 * 1024);
            memcpy(oldp, &bytes, sizeof(uint64_t));
          }
        } else if (strcmp(name, "kern.boottime") == 0 &&
                   [config spoofBoolForKey:@"enableSysctlBoottime"
                              defaultValue:YES]) {
          if (*oldlenp >= sizeof(struct timeval)) {
            static struct timeval s_cachedBootTime = {0, 0};
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
              struct timeval now;
              gettimeofday(&now, NULL);
              s_cachedBootTime.tv_sec =
                  now.tv_sec - (3 * 24 * 3600 + arc4random_uniform(345600));
              s_cachedBootTime.tv_usec = arc4random_uniform(1000000);
            });
            memcpy(oldp, &s_cachedBootTime, sizeof(struct timeval));
          }
        }
      }
    }

    return result;
}

#pragma mark - fishhook (简化版，使用 dlsym)

  // 由于无法直接 Hook C 函数，我们使用 rebind_symbols
  // 这里使用简化方案：在 dylib 中导出同名符号来覆盖（需要
  // -force_flat_namespace）

  // 备选方案：使用 Substrate 或 fishhook 库
  // 目前仅 Hook ObjC 方法，sysctl 的 Hook 需要额外处理

#pragma mark - Data Isolation (分身数据隔离)

#include <sys/stat.h>
#include <fcntl.h>

// 诊断 C API 函数指针
static int (*original_open)(const char *path, int oflag, ...);
static int (*original_stat)(const char *restrict path, struct stat *restrict buf);
static char *(*original_getenv)(const char *name);

// Hook 后的 getenv
static char *hooked_getenv(const char *name) {
    if (name && strcmp(name, "HOME") == 0 && g_isCloneMode && g_FastCloneId) {
        NSString *cloneDataDir = [[SCPrefLoader shared] cloneDataDirectory];
        if (cloneDataDir) {
            // 返回分身的目录，欺骗通过 getenv("HOME") 获取路径的 C 代码
            // 注意：因为这里返回静态或持续有效的内存，可以使用 strdup 但会有泄漏，这里暂时直接返回 UTF8String
            // 更好的做法是分配静态 buffer，或者让系统泄漏这点内存。
            static char home_buffer[1024];
            strncpy(home_buffer, cloneDataDir.UTF8String, sizeof(home_buffer) - 1);
            home_buffer[sizeof(home_buffer) - 1] = '\0';
            return home_buffer;
        }
    }
    return original_getenv(name);
}

// Hook 后的 open
static int hooked_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if ((oflag & O_CREAT) != 0) {
        va_list args;
        va_start(args, oflag);
        mode = va_arg(args, int);
        va_end(args);
    }
    
    static __thread bool in_hooked_open = false;
    
    if (path && g_isCloneMode && !in_hooked_open) {
        in_hooked_open = true;
        NSString *pathStr = [NSString stringWithUTF8String:path];
        // 监控所有 Application 和 Preferences 目录的直接访问
        if ([pathStr containsString:@"/Data/Application/"] || [pathStr containsString:@"/Library/Preferences/"]) {
            if (![pathStr containsString:@".ecdata"] && ![pathStr containsString:@"FakeAppGroup"]) {
                ECLog(@"⚠️ [C-API Leak] open() accessed old data: %s", path);
            }
        }
        in_hooked_open = false;
    }
    
    if ((oflag & O_CREAT) != 0) {
        return original_open(path, oflag, mode);
    } else {
        return original_open(path, oflag);
    }
}

// Hook 后的 stat
static int hooked_stat(const char *restrict path, struct stat *restrict buf) {
    static __thread bool in_hooked_stat = false;
    if (path && g_isCloneMode && !in_hooked_stat) {
        in_hooked_stat = true;
        NSString *pathStr = [NSString stringWithUTF8String:path];
        if ([pathStr containsString:@"/Data/Application/"] || [pathStr containsString:@"/Library/Preferences/"]) {
            if (![pathStr containsString:@".ecdata"] && ![pathStr containsString:@"FakeAppGroup"]) {
                ECLog(@"⚠️ [C-API Leak] stat() accessed old data: %s", path);
            }
        }
        in_hooked_stat = false;
    }
    return original_stat(path, buf);
}

// 原始函数指针
static NSString *(*original_NSHomeDirectory)(void) = NULL;
static NSArray *(*original_NSSearchPathForDirectoriesInDomains)(
    NSSearchPathDirectory directory, NSSearchPathDomainMask domainMask,
    BOOL expandTilde) = NULL;

// Hook 后的 NSHomeDirectory
static NSString *hooked_NSHomeDirectory(void) {
    NSString *cloneDataDir = [[SCPrefLoader shared] cloneDataDirectory];
    if (cloneDataDir) {
      return cloneDataDir;
    }
    return original_NSHomeDirectory();
}

// Hook 后的 NSSearchPathForDirectoriesInDomains
static NSArray *
hooked_NSSearchPathForDirectoriesInDomains(NSSearchPathDirectory directory,
                                           NSSearchPathDomainMask domainMask,
                                           BOOL expandTilde) {
    NSString *cloneDataDir = [[SCPrefLoader shared] cloneDataDirectory];

    // 只有分身才重定向
    if (cloneDataDir && (domainMask & NSUserDomainMask)) {
      switch (directory) {
      case NSDocumentDirectory:
        return @[ [cloneDataDir stringByAppendingPathComponent:@"Documents"] ];
      case NSLibraryDirectory:
        return @[ [cloneDataDir stringByAppendingPathComponent:@"Library"] ];
      case NSCachesDirectory:
        return @[ [cloneDataDir
            stringByAppendingPathComponent:@"Library/Caches"] ];
      case NSApplicationSupportDirectory:
        return @[ [cloneDataDir
            stringByAppendingPathComponent:@"Library/Application Support"] ];
      default:
        break;
      }
    }

    return original_NSSearchPathForDirectoriesInDomains(directory, domainMask,
                                                        expandTilde);
}

#pragma mark - NSFileManager Hook (补充隔离)

@interface NSFileManager (ECDataIsolation)
@end

@implementation NSFileManager (ECDataIsolation)

// Hook containerURLForSecurityApplicationGroupIdentifier: 用于 App Group 隔离
- (NSURL *)ec_containerURLForSecurityApplicationGroupIdentifier:
    (NSString *)groupIdentifier {
    
    NSString *cloneId = g_FastCloneId;
    if (g_isCloneMode && cloneId && groupIdentifier) {
        // [修复核心点]：我们必须将伪造的 AppGroup 建立在原生沙盒的白名单目录下（如 Documents / Library）
        // 这样底层的 sqlite 和 MMKV 才会因为同属进程拥有正常的 file-lock 和 mutex POSIX 权限。
        // 如果把目录建在外部非法空间，会导致底层的跨进程通信无法拿到内核特权而抛出 SegFault。
        NSString *realHomeDir = [NSString stringWithUTF8String:getenv("HOME")];
        NSString *cloneGroupPath = [realHomeDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Documents/FakeAppGroup/%@/%@", cloneId, groupIdentifier]];

        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isNew = ![fm fileExistsAtPath:cloneGroupPath];
        if (isNew) {
            [fm createDirectoryAtPath:cloneGroupPath
                withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
        }
        ECLog(@"🔀 [Clone-AppGroup] 跨号强隔离开启: %@ -> %@ %@", groupIdentifier, cloneGroupPath, isNew ? @"(新建)" : @"(已存在)");
        return [NSURL fileURLWithPath:cloneGroupPath];
    }
    
    return [self ec_containerURLForSecurityApplicationGroupIdentifier:groupIdentifier];
}

@end

#pragma mark - NSUserDefaults Hook (偏好隔离 + 语言伪装)

@interface NSUserDefaults (ECDataIsolation)
@end

@implementation NSUserDefaults (ECDataIsolation)

- (instancetype)ec_initWithSuiteName:(NSString *)suitename {
    NSString *cloneId = g_FastCloneId;
    if (g_isCloneMode && cloneId && suitename && [suitename isKindOfClass:[NSString class]]) {
      NSString *suffix = [NSString stringWithFormat:@".clone_%@", cloneId];
      // 防止递归：如果已经包含后缀，直接调用原方法
      if ([suitename hasSuffix:suffix]) {
        return [self ec_initWithSuiteName:suitename];
      }

      if ([suitename hasPrefix:@"group."]) {
        NSString *newSuite = [suitename stringByAppendingString:suffix];
        // 🔍 诊断日志：NSUserDefaults Suite 重定向 (group.*)
        ECLog(@"🔀 [Clone-Defaults] initWithSuiteName: %@ -> %@", suitename,
              newSuite);
        return [self ec_initWithSuiteName:newSuite];
      }
    }
    return [self ec_initWithSuiteName:suitename];
}

+ (NSUserDefaults *)ec_standardUserDefaults {
    NSString *cloneId = g_FastCloneId;
    if (g_isCloneMode && cloneId) {
      // 使用静态变量缓存分身的 UserDefaults 实例，保持单例行为
      static NSUserDefaults *cachedDefaults = nil;
      static NSString *cachedSuiteName = nil;
      static dispatch_once_t onceToken;

      NSString *bundleId = [[SCPrefLoader shared] currentBundleId];
      NSString *suiteName =
          [NSString stringWithFormat:@"%@.clone%@", bundleId, cloneId];

      // 检查是否需要创建新实例（首次或 suite 变化）
      if (!cachedDefaults || ![cachedSuiteName isEqualToString:suiteName]) {
        cachedDefaults = [[NSUserDefaults alloc] initWithSuiteName:suiteName];
        cachedSuiteName = suiteName;
        // 不调用 ECLog 避免递归
      }
      return cachedDefaults;
    }
    return [self ec_standardUserDefaults];
}

// 核心语言伪装 Hook：拦截 AppleLanguages 和 AppleLocale 读取
- (id)ec_objectForKey:(NSString *)key {
    SCPrefLoader *config = [SCPrefLoader shared];

    // Hook AppleLanguages - iOS 确定应用语言的核心 API
    if ([key isEqualToString:@"AppleLanguages"]) {
      NSString *spoofed = [config spoofValueForKey:@"preferredLanguage"];
      if (!spoofed) {
        NSString *langCode = [config spoofValueForKey:@"languageCode"];
        NSString *countryCode = [config spoofValueForKey:@"countryCode"];
        if (langCode) {
          BOOL hasScript = [langCode containsString:@"-"];
          if (countryCode) {
            if (hasScript) {
              spoofed =
                  [NSString stringWithFormat:@"%@-%@", langCode, countryCode];
            } else if ([langCode isEqualToString:@"zh"]) {
              spoofed = [NSString stringWithFormat:@"zh-Hans-%@", countryCode];
            } else {
              spoofed =
                  [NSString stringWithFormat:@"%@-%@", langCode, countryCode];
            }
          } else {
            spoofed = langCode;
          }
        }
      }
      if (spoofed) {
        // 返回语言数组 (TikTok 等应用会读取这个)
        // ECLog(@" AppleLanguages -> %@", spoofed);
        return @[ spoofed ];
      }
    }

    // Hook AppleLocale - 用于确定地区设置
    else if ([key isEqualToString:@"AppleLocale"]) {
      NSString *locale = [config spoofValueForKey:@"localeIdentifier"];
      if (locale) {
        return locale;
      }
    }

    // 其他键正常处理
    return [self ec_objectForKey:key];
}

// 拦截写入：防止应用通过 NSUserDefaults 覆盖语言设置或触发沙盒错误
- (void)ec_setObject:(id)value forKey:(NSString *)key {
    if (!key)
      return;

    // 拦截对全局语言/地区设置的写入尝试，直接丢弃
    // (TikTok 会尝试写入这些键来"修正在它看来错误"的语言配置，这会导致 Sandbox
    // deny)
    if ([key isEqualToString:@"AppleLanguages"] ||
        [key isEqualToString:@"AppleLocale"] ||
        [key isEqualToString:@"AppleKeyboards"] ||
        [key isEqualToString:@"AppleLanguagesDidMigrate"] ||
        [key isEqualToString:@"AppleLanguagesSchemaVersion"]) {
      // 丢弃写入，保护伪装
      // ECLog(@" 🛡️ 拦截并丢弃针对 %@ 的写入操作", key);
      return;
    }

    // 其他键正常写入
    [self ec_setObject:value forKey:key];
}

- (void)ec_removeObjectForKey:(NSString *)key {
    if (!key)
      return;

    if ([key isEqualToString:@"AppleLanguages"] ||
        [key isEqualToString:@"AppleLocale"] ||
        [key isEqualToString:@"AppleKeyboards"] ||
        [key isEqualToString:@"AppleLanguagesDidMigrate"] ||
        [key isEqualToString:@"AppleLanguagesSchemaVersion"]) {
      return; // 保护伪装不被删除
    }

    [self ec_removeObjectForKey:key];
}

@end

#pragma mark - Keychain Isolation Hook (透明 Keychain 隔离)

// 原始 Security.framework 函数指针
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef query,
                                                CFTypeRef *result) = NULL;
static OSStatus (*original_SecItemAdd)(CFDictionaryRef attributes,
                                       CFTypeRef *result) = NULL;
static OSStatus (*original_SecItemUpdate)(
    CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = NULL;
static OSStatus (*original_SecItemDelete)(CFDictionaryRef query) = NULL;

// 选择性 Keychain 隔离
// 策略：只隔离用户账户相关的 Service，安全 SDK 的设备凭证全部放行
// 原因：字节安全 SDK (safeguard/BDTG)
// 需要真实设备凭证，隔离后服务端判定异常设备 → 触发限流 "访问太频繁"

// 需要隔离的 Service 列表（用户账户数据）
static BOOL shouldIsolateKeychainService(NSString *service) {
    if (!service || ![service isKindOfClass:[NSString class]]) {
      return NO;
    }

    // 精确匹配需要隔离的 Service
    static NSSet *isolatedServices = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      isolatedServices = [NSSet setWithArray:@[
        @"kTikTokKeychainService",    // TikTok 登录 session token
        @"account.historyLogin.data", // 登录历史记录
        @"KeychainShareLogin",        // 跨 App 登录共享（防串号）
        @"TTAExtensionToken",         // Extension 访问令牌
        @"TTKKeychainService",        // TikTok 通用 Keychain
        @"TTKOclKeyChainService",     // OCL 认证 Keychain
        @"TTKUserKeyChainService",    // 用户相关 Keychain
        @"OCLKeyChainService",        // 认证 Keychain
      ]];
    });

    if ([isolatedServices containsObject:service]) {
      return YES;
    }

    // 前缀匹配：com.tiktok.keychainItem.* — TikTok UI 状态和偏好
    if ([service hasPrefix:@"com.tiktok.keychainItem"]) {
      return YES;
    }

    // 前缀匹配：com.linecorp.linesdk.tokenstore.* — Line SDK 登录 token
    if ([service hasPrefix:@"com.linecorp.linesdk"]) {
      return YES;
    }

    return NO;
}

static CFDictionaryRef rewriteKeychainQueryForClone(CFDictionaryRef query) {
    // [v2260] 使用极速判定标志，不再依赖延迟初始化的 SCPrefLoader
    NSString *cloneId = g_FastCloneId;
    NSString *originalBundleId = g_spoofedBundleId;

    // 只有配置了原始 Bundle ID 的克隆应用才需要隔离
    if (!g_isCloneMode || !originalBundleId || !cloneId) {
      return query;
    }

    NSDictionary *queryDict = (__bridge NSDictionary *)query;

    NSString *service = queryDict[(__bridge NSString *)kSecAttrService];
    NSString *account = queryDict[(__bridge NSString *)kSecAttrAccount];

    // 如果既没有 Service 也没有 Account，直接放行
    if ((!service || ![service isKindOfClass:[NSString class]]) &&
        (!account || ![account isKindOfClass:[NSString class]])) {
      return query;
    }

    // 核心判断：只有在隔离列表中的 Service 才需要前缀化
    if (!shouldIsolateKeychainService(service)) {
      return query;
    }

    NSMutableDictionary *newQuery = [queryDict mutableCopy];
    BOOL modified = NO;

    // 修改 Service 添加克隆前缀
    if (service && [service isKindOfClass:[NSString class]]) {
      NSString *newService =
          [NSString stringWithFormat:@"clone_%@_%@", cloneId, service];
      newQuery[(__bridge NSString *)kSecAttrService] = newService;
      modified = YES;
    }

    // 修改 Account 添加克隆前缀
    if (account && [account isKindOfClass:[NSString class]]) {
      NSString *newAccount =
          [NSString stringWithFormat:@"clone_%@_%@", cloneId, account];
      newQuery[(__bridge NSString *)kSecAttrAccount] = newAccount;
      modified = YES;
    }

    // 对隔离的条目，移除共享 AccessGroup
    NSString *accessGroup = queryDict[(__bridge NSString *)kSecAttrAccessGroup];
    if (accessGroup && [accessGroup isKindOfClass:[NSString class]]) {
      [newQuery removeObjectForKey:(__bridge NSString *)kSecAttrAccessGroup];
    }

    if (!modified) {
      return query;
    }

    return (__bridge_retained CFDictionaryRef)[newQuery copy];
}

// ==========================================
// 虚拟 Keychain (Virtual Keychain) - 防止 SDK 回读校验导致的崩溃
// ==========================================


// v2256 极速克隆标记

static NSMutableDictionary *g_VirtualKeychain = nil;

static void ec_init_virtual_keychain(void) {
    if (!g_VirtualKeychain) {
        NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"ECVirtualKeychain"];
        if (saved) {
            g_VirtualKeychain = [saved mutableCopy];
        } else {
            g_VirtualKeychain = [NSMutableDictionary dictionary];
        }
    }
}

static void ec_save_virtual_keychain(void) {
    [[NSUserDefaults standardUserDefaults] setObject:g_VirtualKeychain forKey:@"ECVirtualKeychain"];
}

static NSString *ec_keychain_key(NSDictionary *query) {
    NSString *service = query[(__bridge id)kSecAttrService] ?: @"";
    NSString *account = query[(__bridge id)kSecAttrAccount] ?: @"";
    NSString *agroup  = query[(__bridge id)kSecAttrAccessGroup] ?: @"";
    return [NSString stringWithFormat:@"%@_%@_%@", service, account, agroup];
}

// Hook: SecItemCopyMatching
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    if (g_isCloneMode) {
        // [v2255 致命拦截] 只要是分身模式，绝对禁止系统级 Keychain 读写！
        ec_init_virtual_keychain();
        NSDictionary *q = (__bridge NSDictionary *)query;
        NSString *key = ec_keychain_key(q);
        NSDictionary *savedItem = g_VirtualKeychain[key];
        
        if (savedItem) {
            if (result != NULL) {
                if ([q[(__bridge id)kSecReturnData] boolValue]) {
                    NSData *data = savedItem[(__bridge id)kSecValueData];
                    if (data) *result = CFRetain((__bridge CFTypeRef)data);
                } else if ([q[(__bridge id)kSecReturnAttributes] boolValue]) {
                    NSMutableDictionary *attrs = [savedItem mutableCopy];
                    [attrs removeObjectForKey:(__bridge id)kSecValueData];
                    *result = CFRetain((__bridge CFTypeRef)attrs);
                } else {
                    *result = CFRetain((__bridge CFTypeRef)savedItem);
                }
            }
            NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemCopyMatching (虚拟匹配): %@", key);
            return errSecSuccess;
        } else {
            NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemCopyMatching (虚拟未找到): %@", key);
            return errSecItemNotFound;
        }
    }

    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone(query);
    OSStatus status = original_SecItemCopyMatching(modifiedQuery, result);
    if (modifiedQuery != query) { CFRelease(modifiedQuery); }
    return status;
}

// Hook: SecItemAdd
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    if (g_isCloneMode) {
        ec_init_virtual_keychain();
        NSDictionary *attrs = (__bridge NSDictionary *)attributes;
        NSString *key = ec_keychain_key(attrs);
        
        NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:attrs];
        g_VirtualKeychain[key] = item;
        ec_save_virtual_keychain();
        
        NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemAdd -> 存入虚拟 Keychain [%@]", key);
        return errSecSuccess;
    }

    CFDictionaryRef modifiedAttrs = rewriteKeychainQueryForClone(attributes);
    OSStatus status = original_SecItemAdd(modifiedAttrs, result);
    if (modifiedAttrs != attributes) { CFRelease(modifiedAttrs); }
    return status;
}

// Hook: SecItemUpdate
static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    if (g_isCloneMode) {
        ec_init_virtual_keychain();
        NSString *key = ec_keychain_key((__bridge NSDictionary *)query);
        NSDictionary *savedItemImmutable = g_VirtualKeychain[key];
        
        if (savedItemImmutable) {
            NSMutableDictionary *savedItem = [savedItemImmutable mutableCopy];
            NSDictionary *update = (__bridge NSDictionary *)attributesToUpdate;
            [savedItem addEntriesFromDictionary:update];
            g_VirtualKeychain[key] = savedItem;
            ec_save_virtual_keychain();
            NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemUpdate -> 更新虚拟 Keychain [%@]", key);
            return errSecSuccess;
        }
        return errSecItemNotFound;
    }

    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone(query);
    OSStatus status = original_SecItemUpdate(modifiedQuery, attributesToUpdate);
    if (modifiedQuery != query) { CFRelease(modifiedQuery); }
    return status;
}

// Hook: SecItemDelete
static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    if (g_isCloneMode) {
        ec_init_virtual_keychain();
        NSString *key = ec_keychain_key((__bridge NSDictionary *)query);
        [g_VirtualKeychain removeObjectForKey:key];
        ec_save_virtual_keychain();
        NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemDelete -> 从虚拟 Keychain 移除 [%@]", key);
        return errSecSuccess;
    }

    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone(query);
    OSStatus status = original_SecItemDelete(modifiedQuery);
    if (modifiedQuery != query) { CFRelease(modifiedQuery); }
    return status;
}

// 设置 Keychain 隔离 Hooks
static void setupKeychainIsolationHooks(void) {
    // [v2260] 使用已缓存的全局变量
    NSString *originalBundleId = g_spoofedBundleId;
    // ⚠️ 移除跳过逻辑：即使是非克隆应用，重签名后也可能丢失 Keychain 权限报 -34018。
    // 我们必须始终注册 Hook 来兜底 -34018 导致的主动闪退。
    // if (!originalBundleId) {
    //   ECLog(@" 非克隆应用，跳过 Keychain 隔离 Hook");
    //   return;
    // }

    NSLog(@"[ECFix] 🔐 启用 Keychain 兜底防护 (原始 Bundle ID: %@)", originalBundleId ?: @"无");

    // Keychain rebind 已合并到 performMergedRebind() 统一调用
    ec_register_rebinding("SecItemCopyMatching",
                          (void *)hooked_SecItemCopyMatching,
                          (void **)&original_SecItemCopyMatching);
    ec_register_rebinding("SecItemAdd", (void *)hooked_SecItemAdd,
                          (void **)&original_SecItemAdd);
    ec_register_rebinding("SecItemUpdate", (void *)hooked_SecItemUpdate,
                          (void **)&original_SecItemUpdate);
    ec_register_rebinding("SecItemDelete", (void *)hooked_SecItemDelete,
                          (void **)&original_SecItemDelete);
    ECLog(@" ✅ Keychain Isolation 已注册 (延迟到 performMergedRebind)");
}

#pragma mark - Initialization

// ============================================================================
// Network Interception Hooks (网络拦截与抓包) - 三层 Hook 策略
// ============================================================================

// --- Layer 1: NSURLSession Hook (第三方 SDK 流量) ---
static NSURLSessionDataTask *(*original_dataTaskWithRequestCompletion)(
    id, SEL, NSURLRequest *,
    void (^)(NSData *, NSURLResponse *, NSError *)) = NULL;

// Phase 30 Fix C: URL Query 参数伪装替换
// 替换 URL 中的设备标识参数为配置中的伪装值
static NSURLRequest *ec_spoofURLQueryParams(NSURLRequest *originalRequest) {
    NSString *urlStr = originalRequest.URL.absoluteString;
    if (!urlStr || urlStr.length == 0)
      return originalRequest;

    // 只处理包含需要替换参数的 URL
    if (![urlStr containsString:@"openudid"] &&
        ![urlStr containsString:@"idfv"] &&
        ![urlStr containsString:@"device_type"] &&
        ![urlStr containsString:@"os_version"] &&
        ![urlStr containsString:@"device_id"] &&
        ![urlStr containsString:@"iid="])
      return originalRequest;

    SCPrefLoader *config = [SCPrefLoader shared];
    NSURLComponents *components = [NSURLComponents componentsWithString:urlStr];
    if (!components || !components.queryItems)
      return originalRequest;

    BOOL modified = NO;
    NSMutableArray<NSURLQueryItem *> *newItems = [NSMutableArray array];

    for (NSURLQueryItem *item in components.queryItems) {
      NSString *key = item.name;
      NSString *val = item.value;
      NSString *spoofed = nil;

      // 根据参数名查找伪装值
      // openudid/cdid 每个克隆已独立、device_id/iid 由服务器分配不需篡改
      // idfv 所有克隆相同，需要篡改
      if ([key isEqualToString:@"idfv"]) {
        // 使用缓存的克隆独立 IDFV
        if (g_cachedIDFV && g_cachedIDFV.length > 0) {
          spoofed = g_cachedIDFV;
        }
      } else if ([key isEqualToString:@"device_type"]) {
        // device_type 对应配置中的 machineModel (如 iPhone14,5)
        spoofed = [config spoofValueForKey:@"machineModel"];
      } else if ([key isEqualToString:@"os_version"]) {
        spoofed = [config spoofValueForKey:@"systemVersion"];
      }

      if (spoofed && spoofed.length > 0 && ![spoofed isEqualToString:val]) {
        [newItems addObject:[NSURLQueryItem queryItemWithName:key
                                                        value:spoofed]];
        ECLog(@"🔄 [URLSpoof] %@ : %@ → %@", key, val, spoofed);
        modified = YES;
      } else {
        [newItems addObject:item];
      }
    }

    if (!modified)
      return originalRequest;

    components.queryItems = newItems;
    NSURL *newURL = components.URL;
    if (!newURL)
      return originalRequest;

    NSMutableURLRequest *newReq = [originalRequest mutableCopy];
    [newReq setURL:newURL];
    return newReq;
}

static NSURLSessionDataTask *hooked_dataTaskWithRequestCompletion(
    id self, SEL _cmd, NSURLRequest *request,
    void (^completionHandler)(NSData *, NSURLResponse *, NSError *)) {
    // Phase 30 Fix C: 替换 URL 中的设备标识参数
    request = ec_spoofURLQueryParams(request);

    NSString *url = request.URL.absoluteString;
    NSString *method = request.HTTPMethod ?: @"GET";

    // 频率控制：代理超时时 TikTok 高频重试会产生大量日志，每秒可达200+条
    // 非登录请求限速 3 秒一条，防止日志爆炸引发内存压力崩溃
    static CFAbsoluteTime _lastNetLogTime = 0;
    static int _suppressedNetCount = 0;
    BOOL shouldLog = NO;
    BOOL isLoginRelated = NO;

    if (url &&
        ([url containsString:@"passport"] || [url containsString:@"login"] ||
         [url containsString:@"user/login"] ||
         [url containsString:@"sms/code"] || [url containsString:@"token"] ||
         [url containsString:@"device_register"])) {
      isLoginRelated = YES;
      shouldLog = YES;  // 登录请求始终记录
      ECLog(@"🔑🔑🔑 [LOGIN] ★ %@ %@", method, url);
    } else if (url && ([method isEqualToString:@"POST"] ||
                       [url containsString:@"tiktok"] ||
                       [url containsString:@"musical"] ||
                       [url containsString:@"byte"])) {
      CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
      if (now - _lastNetLogTime > 3.0) {
        if (_suppressedNetCount > 0) {
          ECLog(@"🌐 [Net] ... 已静默 %d 条请求，恢复日志", _suppressedNetCount);
          _suppressedNetCount = 0;
        }
        shouldLog = YES;
        _lastNetLogTime = now;
        ECLog(@"🌐 [Net] ➤ REQUEST: %@ %@", method, url);
      } else {
        _suppressedNetCount++;
      }
    }

    // Body 日志已移除（无实际作用，增加内存压力）

    void (^wrappedCompletion)(NSData *, NSURLResponse *, NSError *) = ^(
        NSData *data, NSURLResponse *response, NSError *error) {
      NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
      NSInteger statusCode = 0;
      if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        statusCode = httpResp.statusCode;
      }
      // 错误时无论是否日志模式都记录一行（限速：5秒一条）
      if (error) {
        static CFAbsoluteTime _lastErrTime = 0;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - _lastErrTime > 5.0) {
          ECLog(@"🌐 [Net] ❌ ERROR [%ld] %@ — %@",
                (long)statusCode, url, error.localizedDescription);
          _lastErrTime = t;
        }
      }
      if (shouldLog) {
        ECLog(@"🌐 [Net] ◀ RESPONSE [%ld]: %@", (long)statusCode, url);
        if (isLoginRelated && [response isKindOfClass:[NSHTTPURLResponse class]]) {
          ECLog(@"   Resp Headers: %@", httpResp.allHeaderFields);
        }
        // 保留 device_register 响应解析（提取 device_id / install_id），移除其他 body 打印
        if (data && [url containsString:@"device_register"]) {
          ECLog(@"🔴🔴🔴 [Network] Intercepted device_register response!");
          @try {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                                 options:0
                                                                   error:nil];
            if (json) {
              NSString *did = json[@"device_id"]
                  ? [NSString stringWithFormat:@"%@", json[@"device_id"]] : nil;
              NSString *iid = json[@"install_id"]
                  ? [NSString stringWithFormat:@"%@", json[@"install_id"]] : nil;
              if (!did && [json[@"data"] isKindOfClass:[NSDictionary class]]) {
                NSDictionary *d = json[@"data"];
                if (d[@"device_id"])  did = [NSString stringWithFormat:@"%@", d[@"device_id"]];
                if (d[@"install_id"]) iid = [NSString stringWithFormat:@"%@", d[@"install_id"]];
              }
              if (!did && json[@"device_id_str"]) did = json[@"device_id_str"];
              if (did.length > 0) { ECLog(@"✅ [Network] device_id: %@", did); ecSavePersistentID(@"deviceId", did); }
              if (iid.length > 0) { ECLog(@"✅ [Network] install_id: %@", iid); ecSavePersistentID(@"installId", iid); }
            }
          } @catch (NSException *e) {
            ECLog(@"⚠️ [Network] parse device_register failed: %@", e);
          }
        }
      }

      if (completionHandler) {
        completionHandler(data, response, error);
      }
    };

    return original_dataTaskWithRequestCompletion(self, _cmd, request,
                                                  wrappedCompletion);
}

// --- Layer 2: TTNetworkManager 请求/响应捕获 ---
// TTNet 是字节跳动基于 Chromium 构建的 C++ 网络栈
// 它完全绕过 NSURLSession，因此必须直接 Hook TTNetworkManager
//
// ⚠️ 安全策略：每个目标方法使用精确参数数量的专用 Hook 函数
// 之前的崩溃原因是固定 5 参数的泛型 Hook 用于 4 参数方法导致栈破坏
// 现在为每个方法单独定义 Hook，参数数量严格匹配

// ============================================================================
// TTNet URL 参数伪装: 替换 URL 查询参数中的设备标识
// 由于 TTNet 完全绕过 NSURLSession，必须在这里拦截
// ============================================================================
static NSString *ec_spoofTTNetURL(NSString *urlStr) {
    if (!urlStr || urlStr.length == 0)
      return urlStr;
    // 检查 URL 是否包含需要替换的参数（覆盖 heimdallr 等监控 SDK）
    if (![urlStr containsString:@"device_type="] &&
        ![urlStr containsString:@"os_version="] &&
        ![urlStr containsString:@"display_name="] &&
        ![urlStr containsString:@"device_model="])
      return urlStr;

    SCPrefLoader *config = [SCPrefLoader shared];
    NSURLComponents *components = [NSURLComponents componentsWithString:urlStr];
    if (!components || !components.queryItems)
      return urlStr;

    BOOL modified = NO;
    NSMutableArray<NSURLQueryItem *> *newItems = [NSMutableArray array];

    for (NSURLQueryItem *item in components.queryItems) {
      NSString *key = item.name;
      NSString *val = item.value;
      NSString *spoofed = nil;

      if ([key isEqualToString:@"device_type"] ||
          [key isEqualToString:@"device_model"]) {
        // device_type / device_model 对应 machineModel (如 iPhone13,2)
        spoofed = [config spoofValueForKey:@"machineModel"];
      } else if ([key isEqualToString:@"os_version"]) {
        spoofed = [config spoofValueForKey:@"systemVersion"];
      } else if ([key isEqualToString:@"display_name"]) {
        // 移除克隆后缀（如 "TikTok 67" → "TikTok"）
        if (val && [val containsString:@" "]) {
          // 如果 display_name 包含空格后缀（克隆编号），去掉它
          NSArray *parts = [val componentsSeparatedByString:@" "];
          NSString *lastPart = parts.lastObject;
          // 检查最后一段是否全是数字（克隆编号）
          NSCharacterSet *nonDigits =
              [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
          if ([lastPart rangeOfCharacterFromSet:nonDigits].location ==
                  NSNotFound &&
              lastPart.length > 0) {
            // 去掉克隆编号后缀
            NSMutableArray *cleanParts = [parts mutableCopy];
            [cleanParts removeLastObject];
            spoofed = [cleanParts componentsJoinedByString:@" "];
          }
        }
      }

      if (spoofed && spoofed.length > 0 && ![spoofed isEqualToString:val]) {
        [newItems addObject:[NSURLQueryItem queryItemWithName:key
                                                        value:spoofed]];
        ECLog(@"🔄 [TTNet-URLSpoof] %@ : %@ → %@", key, val, spoofed);
        modified = YES;
      } else {
        [newItems addObject:item];
      }
    }

    if (!modified)
      return urlStr;

    components.queryItems = newItems;
    NSURL *newURL = components.URL;
    return newURL ? newURL.absoluteString : urlStr;
}

// ============================================================================
// TTNet 动态 block 注入: 在每次发起请求入口强制替换 TTNetworkManager 下所有的
// block
// ============================================================================
static void ec_ensure_ttnet_block_replaced(id mgr) {
    if (!mgr)
      return;

    static const char kWrappedKey = '\0';
    if (objc_getAssociatedObject(mgr, &kWrappedKey))
      return;

    static NSMutableArray<NSString *> *targetIvarNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      targetIvarNames = [NSMutableArray array];
      unsigned int ivarCount = 0;
      Ivar *ivars = class_copyIvarList(NSClassFromString(@"TTNetworkManager"),
                                       &ivarCount);
      for (unsigned int i = 0; i < ivarCount; i++) {
        const char *name = ivar_getName(ivars[i]);
        if (!name)
          continue;
        NSString *nameStr = @(name);
        NSString *lower = nameStr.lowercaseString;
        if ([lower containsString:@"common"] &&
            [lower containsString:@"param"] &&
            [lower containsString:@"block"]) {
          [targetIvarNames addObject:nameStr];
        }
      }
      if (ivars)
        free(ivars);
      NSArray *manualIvars = @[
        @"_commonParamsblock", @"_commonParamsblockWithURL",
        @"_getCommonParamsByLevelBlock", @"_commonParamsBlock"
      ];
      for (NSString *mi in manualIvars) {
        if (![targetIvarNames containsObject:mi])
          [targetIvarNames addObject:mi];
      }
    });

    BOOL replacedAny = NO;

    NSDictionary * (^modifyParams)(NSDictionary *) =
        ^NSDictionary *(NSDictionary *origDict) {
          if (![origDict isKindOfClass:[NSDictionary class]])
            return origDict;
          NSMutableDictionary *p = [origDict mutableCopy];
          SCPrefLoader *cfg = [SCPrefLoader shared];
          BOOL modified = NO;
          NSString *m = [cfg spoofValueForKey:@"machineModel"];
          if (m.length > 0 && p[@"device_type"] &&
              ![p[@"device_type"] isEqualToString:m]) {
            p[@"device_type"] = m;
            modified = YES;
          }
          NSString *o = [cfg spoofValueForKey:@"systemVersion"];
          if (o.length > 0 && p[@"os_version"] &&
              ![p[@"os_version"] isEqualToString:o]) {
            p[@"os_version"] = o;
            modified = YES;
          }
          NSString *n = [cfg spoofValueForKey:@"marketName"];
          if (n.length > 0 && p[@"device_model"] &&
              ![p[@"device_model"] isEqualToString:n]) {
            p[@"device_model"] = n;
            modified = YES;
          }
          return modified ? [p copy] : origDict;
        };

    id (^wrapIvarBlock)(NSString *, id) =
        ^id(NSString *ivarName, id originalBlock) {
          if (!originalBlock)
            return nil;
          NSString *lower = ivarName.lowercaseString;
          if ([lower containsString:@"withurl"]) {
            return [^id(id urlObj) {
              id (^origBlock)(id) = (id(^)(id))originalBlock;
              return modifyParams(origBlock(urlObj));
            } copy];
          } else if ([lower containsString:@"level"]) {
            return [^id(NSInteger level) {
              id (^origBlock)(NSInteger) = (id(^)(NSInteger))originalBlock;
              return modifyParams(origBlock(level));
            } copy];
          } else {
            return [^id(void) {
              id (^origBlock)(void) = (id(^)(void))originalBlock;
              return modifyParams(origBlock());
            } copy];
          }
        };

    @try {
      id commonDict = [mgr valueForKey:@"commonParams"];
      if (commonDict && [commonDict isKindOfClass:[NSDictionary class]]) {
        NSDictionary *newD = modifyParams(commonDict);
        if (newD != commonDict) {
          [mgr setValue:newD forKey:@"commonParams"];
          ECLog(@"✅ [CommonParams-Dict] 成功通过 setValue:ForKey: 替换了 "
                @"commonParams 字典!");
          replacedAny = YES;
        }
      }
    } @catch (NSException *e) {
    }

    for (NSString *iName in targetIvarNames) {
      NSString *markKey = [NSString stringWithFormat:@"ECWrapped_%@", iName];
      if (objc_getAssociatedObject(mgr, NSSelectorFromString(markKey)))
        continue;

      id currentBlock = nil;
      Ivar ivar =
          class_getInstanceVariable(object_getClass(mgr), [iName UTF8String]);
      if (ivar) {
        currentBlock = object_getIvar(mgr, ivar);
      } else {
        @try {
          currentBlock = [mgr valueForKey:[iName hasPrefix:@"_"]
                                              ? [iName substringFromIndex:1]
                                              : iName];
        } @catch (NSException *e) {
        }
      }

      if (!currentBlock)
        continue;
      id wrapped = wrapIvarBlock(iName, currentBlock);
      if (!wrapped)
        continue;

      BOOL setOk = NO;
      if (ivar) {
        object_setIvar(mgr, ivar, wrapped);
        setOk = YES;
      } else {
        @try {
          [mgr setValue:wrapped
                 forKey:[iName hasPrefix:@"_"] ? [iName substringFromIndex:1]
                                               : iName];
          setOk = YES;
        } @catch (NSException *e) {
        }
      }

      if (setOk) {
        objc_setAssociatedObject(mgr, NSSelectorFromString(markKey), @YES,
                                 OBJC_ASSOCIATION_RETAIN);
        ECLog(@"✅ [CommonParams] 同步触发：成功通过 ivar '%@' 替换!", iName);
        replacedAny = YES;
      }
    }

    if (replacedAny) {
      objc_setAssociatedObject(mgr, &kWrappedKey, @YES,
                               OBJC_ASSOCIATION_RETAIN);
    }
}

// ============================================================================
// TTNet Hook: requestWithURL:method:params:callback: (4 args)
// 这是 TTNetworkManager 最基础的请求入口
// ============================================================================
typedef id (*TTNet_requestWithURL_IMP)(id, SEL, id, id, id, id);
static TTNet_requestWithURL_IMP _orig_ttnet_requestWithURL = NULL;

static id hooked_ttnet_requestWithURL(id self, SEL _cmd, id urlObj,
                                      id methodObj, id params, id callback) {
    ec_ensure_ttnet_block_replaced(self);
    // TTNet URL 参数伪装: 替换 device_type 等
    @try {
      if ([urlObj isKindOfClass:[NSString class]]) {
        urlObj = ec_spoofTTNetURL((NSString *)urlObj);
      } else if ([urlObj isKindOfClass:[NSURL class]]) {
        NSString *spoofed = ec_spoofTTNetURL([(NSURL *)urlObj absoluteString]);
        if (spoofed) {
          NSURL *newURL = [NSURL URLWithString:spoofed];
          if (newURL)
            urlObj = newURL;
        }
      }
    } @catch (NSException *e) {
      // 安全忽略
    }

    @
    try {
      NSString *url = nil;
      if ([urlObj isKindOfClass:[NSString class]]) {
        url = (NSString *)urlObj;
      } else if ([urlObj isKindOfClass:[NSURL class]]) {
        url = [(NSURL *)urlObj absoluteString];
      } else if (urlObj) {
        url = [urlObj description];
      }

      NSString *method = nil;
      if ([methodObj isKindOfClass:[NSString class]]) {
        method = (NSString *)methodObj;
      } else if ([methodObj isKindOfClass:[NSNumber class]]) {
        // TTNet 可能使用枚举值表示 HTTP 方法
        int val = [(NSNumber *)methodObj intValue];
        switch (val) {
        case 0:
          method = @"GET";
          break;
        case 1:
          method = @"POST";
          break;
        case 2:
          method = @"PUT";
          break;
        case 3:
          method = @"DELETE";
          break;
        case 4:
          method = @"HEAD";
          break;
        default:
          method = [NSString stringWithFormat:@"METHOD(%d)", val];
          break;
        }
      } else if (methodObj) {
        method = [methodObj description];
      }

      if (url) {
        ECLog(@"🔶 [TTNet] ➤ %@ %@", method ?: @"?", url);
        if (params) {
          @try {
            NSString *paramsStr = [params description];
            if (paramsStr.length > 5000) {
              ECLog(@"   TTNet Params: %@... (truncated)",
                    [paramsStr substringToIndex:5000]);
            } else {
              ECLog(@"   TTNet Params: %@", paramsStr);
            }
          } @catch (NSException *e) {
            // 安全忽略
          }
        }
      }
    } @catch (NSException *e) {
      ECLog(@"⚠️ [TTNet] Hook logging error: %@", e);
    }

    return _orig_ttnet_requestWithURL(self, _cmd, urlObj, methodObj, params,
                                      callback);
}

// ============================================================================
// TTNet Hook: bdxbridge_requestWithURL:method:params:callback: (4 args)
// BDXBridge 是另一个常用的请求入口
// ============================================================================
static TTNet_requestWithURL_IMP _orig_ttnet_bdxbridge_request = NULL;

static id hooked_ttnet_bdxbridge_request(id self, SEL _cmd, id urlObj,
                                         id methodObj, id params, id callback) {
    ec_ensure_ttnet_block_replaced(self);
    // TTNet URL 参数伪装
    @try {
      if ([urlObj isKindOfClass:[NSString class]]) {
        urlObj = ec_spoofTTNetURL((NSString *)urlObj);
      } else if ([urlObj isKindOfClass:[NSURL class]]) {
        NSString *spoofed = ec_spoofTTNetURL([(NSURL *)urlObj absoluteString]);
        if (spoofed) {
          NSURL *newURL = [NSURL URLWithString:spoofed];
          if (newURL)
            urlObj = newURL;
        }
      }
    } @catch (NSException *e) {
    }

    @
    try {
      NSString *url = nil;
      if ([urlObj isKindOfClass:[NSString class]]) {
        url = (NSString *)urlObj;
      } else if ([urlObj isKindOfClass:[NSURL class]]) {
        url = [(NSURL *)urlObj absoluteString];
      } else if (urlObj) {
        url = [urlObj description];
      }

      if (url) {
        ECLog(@"🔶 [TTNet-BDX] ➤ %@ %@",
              [methodObj isKindOfClass:[NSString class]]
                  ? methodObj
                  : [methodObj description],
              url);
      }
    } @catch (NSException *e) {
      // 安全忽略
    }

    return _orig_ttnet_bdxbridge_request(self, _cmd, urlObj, methodObj, params,
                                         callback);
}

// ============================================================================
// TTNet Hook: tspk_requestForJSONWithURL_:params:method:needCommonParams:
//             headerField:requestSerializer:responseSerializer:autoResume:
//             verifyRequest:isCustomizedCookie:callback:callbackWithResponse:
//             dispatch_queue: (13 args)
// 这是 TikTok 核心 JSON API 请求方法
// ============================================================================
typedef id (*TTNet_requestForJSON_IMP)(id, SEL, id, id, id, id, id, id, id, id,
                                       id, id, id, id, id);
static TTNet_requestForJSON_IMP _orig_ttnet_requestForJSON = NULL;

static id hooked_ttnet_requestForJSON(id self, SEL _cmd, id url, id params,
                                      id method, id needCommon, id headerField,
                                      id requestSerializer,
                                      id responseSerializer, id autoResume,
                                      id verifyRequest, id isCustomizedCookie,
                                      id callback, id callbackWithResponse,
                                      id dispatch_queue) {
    ec_ensure_ttnet_block_replaced(self);
    // TTNet URL 参数伪装
    @try {
      if ([url isKindOfClass:[NSString class]]) {
        url = ec_spoofTTNetURL((NSString *)url);
      } else if ([url isKindOfClass:[NSURL class]]) {
        NSString *spoofed = ec_spoofTTNetURL([(NSURL *)url absoluteString]);
        if (spoofed) {
          NSURL *newURL = [NSURL URLWithString:spoofed];
          if (newURL)
            url = newURL;
        }
      }
    } @catch (NSException *e) {
    }

    @
    try {
      NSString *urlStr = nil;
      if ([url isKindOfClass:[NSString class]]) {
        urlStr = (NSString *)url;
      } else if ([url isKindOfClass:[NSURL class]]) {
        urlStr = [(NSURL *)url absoluteString];
      } else if (url) {
        urlStr = [url description];
      }

      NSString *methodStr = nil;
      if ([method isKindOfClass:[NSString class]]) {
        methodStr = (NSString *)method;
      } else if ([method isKindOfClass:[NSNumber class]]) {
        int val = [(NSNumber *)method intValue];
        switch (val) {
        case 0:
          methodStr = @"GET";
          break;
        case 1:
          methodStr = @"POST";
          break;
        case 2:
          methodStr = @"PUT";
          break;
        case 3:
          methodStr = @"DELETE";
          break;
        default:
          methodStr = [NSString stringWithFormat:@"METHOD(%d)", val];
          break;
        }
      }

      if (urlStr) {
        ECLog(@"🔶 [TTNet-JSON] ➤ %@ %@", methodStr ?: @"?", urlStr);
        if (params) {
          @try {
            NSString *paramsStr = [params description];
            if (paramsStr.length > 5000) {
              ECLog(@"   Params: %@... (truncated)",
                    [paramsStr substringToIndex:5000]);
            } else {
              ECLog(@"   Params: %@", paramsStr);
            }
          } @catch (NSException *e) {
          }
        }
        if (headerField) {
          @try {
            ECLog(@"   Headers: %@", [headerField description]);
          } @catch (NSException *e) {
          }
        }
      }
    } @catch (NSException *e) {
      ECLog(@"⚠️ [TTNet-JSON] Hook logging error: %@", e);
    }

    return _orig_ttnet_requestForJSON(
        self, _cmd, url, params, method, needCommon, headerField,
        requestSerializer, responseSerializer, autoResume, verifyRequest,
        isCustomizedCookie, callback, callbackWithResponse, dispatch_queue);
}

// ============================================================================
// TTNet Hook: tspk_requestForBinaryWithURL_:... (17 args)
// 视频/图片等二进制数据下载
// ============================================================================
typedef id (*TTNet_requestForBinary_IMP)(id, SEL, id, id, id, id, id, id, id,
                                         id, id, id, id, id, id, id, id, id,
                                         id);
static TTNet_requestForBinary_IMP _orig_ttnet_requestForBinary = NULL;

static id hooked_ttnet_requestForBinary(
    id self, SEL _cmd, id url, id params, id method, id needCommon,
    id headerField, id enableCache, id requestSerializer, id responseSerializer,
    id autoResume, id isCustomizedCookie, id headerCallback, id dataCallback,
    id callback, id callbackWithResponse, id redirectCallback, id progress,
    id dispatch_queue) {
    ec_ensure_ttnet_block_replaced(self);
    // URL 参数伪装（覆盖 heimdallr 等监控 SDK 的请求）
    @try {
      if ([url isKindOfClass:[NSString class]]) {
        url = ec_spoofTTNetURL((NSString *)url);
      } else if ([url isKindOfClass:[NSURL class]]) {
        NSString *spoofed = ec_spoofTTNetURL([(NSURL *)url absoluteString]);
        if (spoofed) {
          NSURL *newURL = [NSURL URLWithString:spoofed];
          if (newURL)
            url = newURL;
        }
      }
    } @catch (NSException *e) {
    }

    @
    try {
      NSString *urlStr = nil;
      if ([url isKindOfClass:[NSString class]]) {
        urlStr = (NSString *)url;
      } else if ([url isKindOfClass:[NSURL class]]) {
        urlStr = [(NSURL *)url absoluteString];
      } else if (url) {
        urlStr = [url description];
      }

      if (urlStr) {
        ECLog(@"🔶 [TTNet-Bin] ➤ %@", urlStr);
      }
    } @catch (NSException *e) {
      // 安全忽略
    }

    return _orig_ttnet_requestForBinary(
        self, _cmd, url, params, method, needCommon, headerField, enableCache,
        requestSerializer, responseSerializer, autoResume, isCustomizedCookie,
        headerCallback, dataCallback, callback, callbackWithResponse,
        redirectCallback, progress, dispatch_queue);
}

// ============================================================================
// TTNet Hook: tspk_requestModel:... (7 args)
// 模型化请求 API - 可能用于登录等结构化请求
// ============================================================================
typedef id (*TTNet_requestModel_IMP)(id, SEL, id, id, id, id, id, id, id);
static TTNet_requestModel_IMP _orig_ttnet_requestModel = NULL;

static id hooked_ttnet_requestModel(id self, SEL _cmd, id requestModel,
                                    id requestSerializer, id responseSerializer,
                                    id autoResume, id callback,
                                    id callbackWithResponse,
                                    id dispatch_queue) {
    ec_ensure_ttnet_block_replaced(self);
    // 尝试对 requestModel 的 URL 进行伪装
    @try {
      if (requestModel) {
        // 很多 requestModel 有 setURLString: 方法
        SEL urlStrSel = NSSelectorFromString(@"urlString");
        SEL setUrlStrSel = NSSelectorFromString(@"setUrlString:");
        if ([requestModel respondsToSelector:urlStrSel] &&
            [requestModel respondsToSelector:setUrlStrSel]) {
          NSString *origURL = [requestModel performSelector:urlStrSel];
          if ([origURL isKindOfClass:[NSString class]]) {
            NSString *spoofed = ec_spoofTTNetURL(origURL);
            if (spoofed && ![spoofed isEqualToString:origURL]) {
              [requestModel performSelector:setUrlStrSel withObject:spoofed];
            }
          }
        }
      }
    } @catch (NSException *e) {
    } @
    try {
      ECLog(@"🟣 [TTNet-Model] ➤ requestModel called");
      if (requestModel) {
        @try {
          // 尝试提取 URL
          if ([requestModel respondsToSelector:NSSelectorFromString(@"URL")]) {
            id urlObj =
                [requestModel performSelector:NSSelectorFromString(@"URL")];
            ECLog(@"   Model URL: %@", urlObj);
          }
          if ([requestModel
                  respondsToSelector:NSSelectorFromString(@"urlString")]) {
            id urlStr = [requestModel
                performSelector:NSSelectorFromString(@"urlString")];
            ECLog(@"   Model urlString: %@", urlStr);
          }
          if ([requestModel
                  respondsToSelector:NSSelectorFromString(@"requestURL")]) {
            id urlStr = [requestModel
                performSelector:NSSelectorFromString(@"requestURL")];
            ECLog(@"   Model requestURL: %@", urlStr);
          }
          // 打印 model 的类名和描述
          ECLog(@"   Model class: %s", class_getName([requestModel class]));
          NSString *desc = [requestModel description];
          if (desc.length > 2000) {
            ECLog(@"   Model desc: %@... (truncated)",
                  [desc substringToIndex:2000]);
          } else {
            ECLog(@"   Model desc: %@", desc);
          }
        } @catch (NSException *e) {
          ECLog(@"   Model introspection error: %@", e);
        }
      }
    } @catch (NSException *e) {
      ECLog(@"⚠️ [TTNet-Model] Hook error: %@", e);
    }

    return _orig_ttnet_requestModel(self, _cmd, requestModel, requestSerializer,
                                    responseSerializer, autoResume, callback,
                                    callbackWithResponse, dispatch_queue);
}

// ============================================================================
// TTNet Hook: tspk_synchronizedRequstForURL:... (9 args)
// 同步请求 API - 可能用于关键初始化/登录
// ============================================================================
typedef id (*TTNet_syncRequest_IMP)(id, SEL, id, id, id, id, id, id, id, id,
                                    id);
static TTNet_syncRequest_IMP _orig_ttnet_syncRequest = NULL;

static id hooked_ttnet_syncRequest(id self, SEL _cmd, id url, id method,
                                   id headerField, id jsonObjParams,
                                   id needCommonParams, id requestSerializer,
                                   id needResponse, id needEncrypt,
                                   id needContentEncoding) {
    ec_ensure_ttnet_block_replaced(self);
    // URL 参数伪装
    @try {
      if ([url isKindOfClass:[NSString class]]) {
        url = ec_spoofTTNetURL((NSString *)url);
      } else if ([url isKindOfClass:[NSURL class]]) {
        NSString *spoofed = ec_spoofTTNetURL([(NSURL *)url absoluteString]);
        if (spoofed) {
          NSURL *newURL = [NSURL URLWithString:spoofed];
          if (newURL)
            url = newURL;
        }
      }
    } @catch (NSException *e) {
    } @
    try {
      NSString *urlStr = nil;
      if ([url isKindOfClass:[NSString class]]) {
        urlStr = (NSString *)url;
      } else if ([url isKindOfClass:[NSURL class]]) {
        urlStr = [(NSURL *)url absoluteString];
      } else if (url) {
        urlStr = [url description];
      }

      if (urlStr) {
        ECLog(@"🟠 [TTNet-Sync] ➤ %@ %@", method ?: @"?", urlStr);
        if (jsonObjParams) {
          @try {
            ECLog(@"   SyncParams: %@", [jsonObjParams description]);
          } @catch (NSException *e) {
          }
        }
        if (headerField) {
          @try {
            ECLog(@"   SyncHeaders: %@", [headerField description]);
          } @catch (NSException *e) {
          }
        }
      }
    } @catch (NSException *e) {
      ECLog(@"⚠️ [TTNet-Sync] Hook error: %@", e);
    }

    return _orig_ttnet_syncRequest(
        self, _cmd, url, method, headerField, jsonObjParams, needCommonParams,
        requestSerializer, needResponse, needEncrypt, needContentEncoding);
}

// ============================================================================
// 运行时搜索：枚举所有 Passport/Login/Auth 相关类
// ============================================================================
// ===================================
// Hook: AWEPassportNetworkManager
// ===================================
typedef id (*AWEPassportNetworkManager_POST_IMP)(id, SEL, id, id, id, id);
static AWEPassportNetworkManager_POST_IMP _orig_passport_POST = NULL;

static id hooked_passport_POST(id self, SEL _cmd, NSString *url,
                               NSDictionary *params, Class modelClass,
                               id completion) {
    @try {
      ECLog(@"🔐 [Passport-Net] POST: %@", url);
      if (params) {
        ECLog(@"   Params: %@", params);
      }
    } @catch (NSException *exception) {
      ECLog(@"❌ [Passport-Net] Error logging: %@", exception);
    }

    if (_orig_passport_POST) {
      return _orig_passport_POST(self, _cmd, url, params, modelClass,
                                 completion);
    }
    return nil;
}

// ===================================
// Hook: AWEPassportServiceImp
// ===================================
typedef id (*AWEPassportServiceImp_login_IMP)(id, SEL, id, id);
static AWEPassportServiceImp_login_IMP _orig_passport_login = NULL;

static id hooked_passport_login(id self, SEL _cmd, id context, id tracker) {
    @try {
      ECLog(@"🔐 [Passport-Service] Login triggered!");
      if (tracker) {
        ECLog(@"   Tracker Info: %@", tracker);
      }
    } @catch (NSException *exception) {
      ECLog(@"❌ [Passport-Service] Error logging: %@", exception);
    }

    if (_orig_passport_login) {
      return _orig_passport_login(self, _cmd, context, tracker);
    }
    return nil;
}

// ===================================
// Hook: AWEPassportConfigurationImplementation POST
// ===================================
static id hooked_passportConfig_POST(id self, SEL _cmd, NSString *url,
                                     NSDictionary *params, id completion) {
    @try {
      ECLog(@"🔐🔐🔐 [Passport-Config] POST: %@", url);
      if (params) {
        ECLog(@"🔐 [Passport-Config] POST Params: %@", params);
      }
    } @catch (NSException *exception) {
      ECLog(@"❌ [Passport-Config] POST log error: %@", exception);
    }

    if (_orig_passportConfig_POST) {
      return _orig_passportConfig_POST(self, _cmd, url, params, completion);
    }
    return nil;
}

// ===================================
// Hook: AWEPassportConfigurationImplementation GET
// ===================================
static id hooked_passportConfig_GET(id self, SEL _cmd, NSString *url,
                                    NSDictionary *params, id completion) {
    @try {
      ECLog(@"🔐🔐🔐 [Passport-Config] GET: %@", url);
      if (params) {
        ECLog(@"🔐 [Passport-Config] GET Params: %@", params);
      }
    } @catch (NSException *exception) {
      ECLog(@"❌ [Passport-Config] GET log error: %@", exception);
    }

    if (_orig_passportConfig_GET) {
      return _orig_passportConfig_GET(self, _cmd, url, params, completion);
    }
    return nil;
}

// ===================================
// 持久化 Device/Install ID 的辅助函数
// ===================================
static NSString *ecPersistentIDPath(NSString *idType) {
    // 使用 clone 数据目录存储 ID（与 clone 隔离一致）
    NSString *cloneDir = [[SCPrefLoader shared] cloneDataDirectory];
    NSString *baseDir = nil;
    if (cloneDir) {
      baseDir = cloneDir;
    } else {
      // 非分身模式：使用沙盒 Library/Application
      // Support/.com.apple.UIKit.pboard
      const char *homeEnv = getenv("HOME");
      if (homeEnv) {
        baseDir = [[NSString stringWithUTF8String:homeEnv]
            stringByAppendingPathComponent:
                @"Library/Application Support/.com.apple.UIKit.pboard"];
      }
    }
    if (!baseDir)
      return nil;

    // 确保目录存在
    [[NSFileManager defaultManager] createDirectoryAtPath:baseDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    return [baseDir
        stringByAppendingPathComponent:
            [NSString stringWithFormat:@".com.apple.uikit.%@.cache", idType]];
}

static void ecSavePersistentID(NSString *key, NSString *value) {
    if (!key || !value)
      return;

    // 1. Update In-Memory Cache & Check for changes
    BOOL changed = NO;
    if ([key isEqualToString:@"deviceId"]) {
      if (![g_cachedDeviceID isEqualToString:value]) {
        g_cachedDeviceID = [value copy];
        changed = YES;
      }
    } else if ([key isEqualToString:@"installId"]) {
      if (![g_cachedInstallID isEqualToString:value]) {
        g_cachedInstallID = [value copy];
        changed = YES;
      }
    } else if ([key isEqualToString:@"idfv"]) {
      if (![g_cachedIDFV isEqualToString:value]) {
        g_cachedIDFV = [value copy];
        changed = YES;
      }
    }

    // 2. Write to disk ONLY if changed
    if (changed) {
      NSString *path = ecPersistentIDPath(key);
      if (!path)
        return;

      NSError *err = nil;
      [value writeToFile:path
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:&err];
      if (err) {
        ECLog(@"❌ [PersistentID] Failed to save %@: %@", key, err);
      } else {
        ECLog(@"💾 [PersistentID] Saved %@ = %@ -> %@", key, value,
              path.lastPathComponent);
      }
    }
}

static NSString *ecLoadPersistentID(NSString *key) {
    // 1. Check Cache first
    if ([key isEqualToString:@"deviceId"] && g_cachedDeviceID)
      return g_cachedDeviceID;
    if ([key isEqualToString:@"installId"] && g_cachedInstallID)
      return g_cachedInstallID;
    if ([key isEqualToString:@"idfv"] && g_cachedIDFV)
      return g_cachedIDFV;

    // 2. Load from disk
    NSString *path = ecPersistentIDPath(key);
    if (!path)
      return nil;

    NSString *value = [NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    // 3. Update Cache
    if (value.length > 0) {
      if ([key isEqualToString:@"deviceId"])
        g_cachedDeviceID = [value copy];
      if ([key isEqualToString:@"installId"])
        g_cachedInstallID = [value copy];
      if ([key isEqualToString:@"idfv"])
        g_cachedIDFV = [value copy];

      // Fix Log Spam: ONLY log if we actually restored from disk (first time)
      // ECLog(@"📂 [PersistentID] Restored %@ = %@", key, value);
      return value;
    }
    return nil;
}

// Phase 27.2: Generate IDFV UUID
static NSString *ecGenerateIDFV(void) {
    return [[NSUUID UUID] UUIDString]; }

// ===================================
// Hook: TTInstallIDManager deviceID

static NSString *hooked_installMgr_deviceID(id self, SEL _cmd) {
    NSString *result = nil;
    if (_orig_installMgr_deviceID) {
      result = _orig_installMgr_deviceID(self, _cmd);
    }

    // 原始方法返回了有效值 -> 持久化保存
    if (result.length) {
      ecSavePersistentID(@"deviceId", result);
      return result;
    }

    // 原始值为空 -> 尝试从 spoof config 获取
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"deviceId"];
    if (spoofed.length) {
      ECLog(
          @"📱 [TTInstallIDManager] deviceID was empty, returning spoofed: %@",
          spoofed);
      return spoofed;
    }

    // spoof 也没有 -> 从持久化文件恢复
    NSString *persisted = ecLoadPersistentID(@"deviceId");
    if (persisted.length) {
      ECLog(@"📱 [TTInstallIDManager] deviceID restored: %@", persisted);
      return persisted;
    }

    // 都没有 -> 返回原始值
    ECLog(
        @"⚠️ [TTInstallIDManager] deviceID is empty and no persistent ID found, "
        @"returning original result to trigger registration.");
    return result;
}

// ===================================
// Hook: TTInstallIDManager installID
// ===================================
static NSString *hooked_installMgr_installID(id self, SEL _cmd) {
    NSString *result = nil;
    if (_orig_installMgr_installID) {
      result = _orig_installMgr_installID(self, _cmd);
    }

    // 原始方法返回了有效值 -> 持久化保存
    if (result.length) {
      ecSavePersistentID(@"installId", result);
      return result;
    }

    // 原始值为空 -> 尝试从 spoof config 获取
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"installId"];
    if (spoofed.length) {
      ECLog(
          @"📱 [TTInstallIDManager] installID was empty, returning spoofed: %@",
          spoofed);
      return spoofed;
    }

    // spoof 也没有 -> 从持久化文件恢复
    NSString *persisted = ecLoadPersistentID(@"installId");
    if (persisted.length) {
      ECLog(@"📱 [TTInstallIDManager] installID restored: %@", persisted);
      return persisted;
    }

    // 都没有 -> 返回原始值
    ECLog(@"⚠️ [TTInstallIDManager] installID is empty and no persistent ID "
          @"found, returning original result to trigger registration.");
    return result;
}

// ===================================
// Hook: BDInstall setDeviceID: - 捕获注册结果
// ===================================
static void hooked_bdinstall_setDeviceID(id self, SEL _cmd,
                                         NSString *deviceID) {
    // ECLog(@"📱 [BDInstall] setDeviceID: %@", deviceID ?: @"(nil)"); // Reduce
    // Log
    if (deviceID.length) {
      ecSavePersistentID(@"deviceId", deviceID);
    }
    if (_orig_bdinstall_setDeviceID) {
      _orig_bdinstall_setDeviceID(self, _cmd, deviceID);
    }
}

// ===================================
// Hook: BDInstall setInstallID: - 捕获注册结果
// ===================================
static void hooked_bdinstall_setInstallID(id self, SEL _cmd,
                                          NSString *installID) {
    // ECLog(@"📱 [BDInstall] setInstallID: %@", installID ?: @"(nil)"); //
    // Reduce Log
    if (installID.length) {
      ecSavePersistentID(@"installId", installID);
    }
    if (_orig_bdinstall_setInstallID) {
      _orig_bdinstall_setInstallID(self, _cmd, installID);
    }
}

// ===================================
// Hook: BDInstall deviceID (Getter)
// ===================================
static NSString *hooked_bdinstall_deviceID(id self, SEL _cmd) {
    NSString *result = nil;
    if (_orig_bdinstall_deviceID) {
      result = _orig_bdinstall_deviceID(self, _cmd);
    }

    if (result.length) {
      ecSavePersistentID(@"deviceId", result);
      return result;
    }

    NSString *persisted = ecLoadPersistentID(@"deviceId");
    if (persisted.length) {
      ECLog(@"📱 [BDInstall] deviceID empty, restored: %@", persisted);
      return persisted;
    }

    // 都没有 -> 返回原始值
    ECLog(@"⚠️ [BDInstall] deviceID is empty and no persistent ID found, "
          @"returning original result.");
    return result;
}

// ===================================
// Hook: BDInstall installID (Getter)
// ===================================
static NSString *hooked_bdinstall_installID(id self, SEL _cmd) {
    NSString *result = nil;
    if (_orig_bdinstall_installID) {
      result = _orig_bdinstall_installID(self, _cmd);
    }

    if (result.length) {
      ecSavePersistentID(@"installId", result);
      return result;
    }

    NSString *persisted = ecLoadPersistentID(@"installId");
    if (persisted.length) {
      ECLog(@"📱 [BDInstall] installID empty, restored: %@", persisted);
      return persisted;
    }
    ECLog(@"⚠️ [BDInstall] installID is empty and no persistent ID found, "
          @"returning original result.");
    return result;
}

// ===================================
// Hook: InstallAndDeviceIDService / AWEPassportServiceImp
// ===================================

// Function Pointers
// Function Pointers
typedef void (*IDSvc_didRegister_IMP)(id, SEL, id);
static IDSvc_didRegister_IMP _orig_idsvc_didRegister = NULL;

typedef NSString *(*IDSvc_deviceID_IMP)(id, SEL);
static IDSvc_deviceID_IMP _orig_idsvc_deviceID = NULL;

typedef NSString *(*IDSvc_installID_IMP)(id, SEL);
static IDSvc_installID_IMP _orig_idsvc_installID = NULL;

typedef void (*IDSvc_setDeviceID_IMP)(id, SEL, NSString *);
static IDSvc_setDeviceID_IMP _orig_idsvc_setDeviceID = NULL;

typedef void (*IDSvc_setInstallID_IMP)(id, SEL, NSString *);
static IDSvc_setInstallID_IMP _orig_idsvc_setInstallID = NULL;

typedef void (*PassportSvc_didFinishLogin_IMP)(id, SEL, id, NSError *);
static PassportSvc_didFinishLogin_IMP _orig_passport_didFinishLogin = NULL;

// Hook Implementations
static void hooked_idsvc_didRegister(id self, SEL _cmd, id context) {
    ECLog(
        @"📱📱📱 [InstallAndDeviceIDService] didRegister: called with context: "
        @"%@",
        context);

    if (_orig_idsvc_didRegister) {
      _orig_idsvc_didRegister(self, _cmd, context);
    }

    // Check if context is a notification
    BOOL foundID = NO;
    NSString *extractedDeviceID = nil;
    NSString *extractedInstallID = nil;

    if ([context isKindOfClass:[NSNotification class]]) {
      NSNotification *notif = (NSNotification *)context;
      NSDictionary *userInfo = notif.userInfo;
      id object = notif.object;

      ECLog(@"📱 [InstallAndDeviceIDService] Notification Name: %@",
            notif.name);
      ECLog(@"📱 [InstallAndDeviceIDService] Notification Object: %@", object);
      ECLog(@"📱 [InstallAndDeviceIDService] UserInfo Keys: %@",
            userInfo.allKeys);

      // 1. Try to get IDs from userInfo
      if (userInfo) {
        // Common keys for device ID
        NSArray *didKeys =
            @[ @"device_id", @"did", @"deviceId", @"kTTInstallIDKeyDeviceID" ];
        for (NSString *key in didKeys) {
          id val = userInfo[key];
          if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            extractedDeviceID = val;
            ECLog(@"✅ [InstallAndDeviceIDService] Found deviceID in "
                  @"userInfo['%@']: %@",
                  key, val);
            break;
          }
        }

        // Common keys for install ID
        NSArray *iidKeys = @[
          @"install_id", @"iid", @"installId", @"kTTInstallIDKeyInstallID"
        ];
        for (NSString *key in iidKeys) {
          id val = userInfo[key];
          if ([val isKindOfClass:[NSString class]] && [val length] > 0) {
            extractedInstallID = val;
            ECLog(@"✅ [InstallAndDeviceIDService] Found installID in "
                  @"userInfo['%@']: %@",
                  key, val);
            break;
          }
        }
      }

      // 2. If not found, try to get from object (TTInstallIDManager)
      if (!extractedDeviceID && object) {
        if ([object respondsToSelector:@selector(deviceID)]) {
          extractedDeviceID = [object performSelector:@selector(deviceID)];
          ECLog(@"✅ [InstallAndDeviceIDService] Retrieved deviceID from "
                @"notification object: %@",
                extractedDeviceID);
        }
      }
      if (!extractedInstallID && object) {
        if ([object respondsToSelector:@selector(installID)]) {
          extractedInstallID = [object performSelector:@selector(installID)];
          ECLog(@"✅ [InstallAndDeviceIDService] Retrieved installID from "
                @"notification object: %@",
                extractedInstallID);
        }
      }

    } else {
      // Context might be the deviceID string itself (old behavior?)
      ECLog(@"⚠️ [InstallAndDeviceIDService] Context is NOT a notification: %@",
            [context class]);
      if ([context isKindOfClass:[NSString class]] && [context length] > 5) {
        extractedDeviceID = context;
        ECLog(@"✅ [InstallAndDeviceIDService] Context appears to be deviceID "
              @"string");
      }
    }

    // Persist if found
    if (extractedDeviceID.length > 0) {
      ecSavePersistentID(@"deviceId", extractedDeviceID);
      foundID = YES;
    }
    if (extractedInstallID.length > 0) {
      ecSavePersistentID(@"installId", extractedInstallID);
    }

    if (foundID) {
      ECLog(@"✅✅✅ [Phase 22] Successfully captured and persisted Device ID "
            @"via didRegister hook!");
    } else {
      ECLog(
          @"⚠️ [Phase 22] Failed to extract Device ID from didRegister context");
    }

    // Also try to get current IDs from the service itself
    if ([self respondsToSelector:@selector(deviceID)]) {
      NSString *did = [self performSelector:@selector(deviceID)];
      if (did && [did isKindOfClass:[NSString class]] && did.length > 0) {
        ECLog(@"✅ [InstallAndDeviceIDService] Current deviceID: %@", did);
        ecSavePersistentID(@"deviceId", did);
      }
    }
}

static NSString *hooked_idsvc_deviceID(id self, SEL _cmd) {
    NSString *result = nil;
    if (_orig_idsvc_deviceID) {
      result = _orig_idsvc_deviceID(self, _cmd);
    }

    if (result.length > 0) {
      ecSavePersistentID(@"deviceId", result);
      return result;
    }

    NSString *persisted = ecLoadPersistentID(@"deviceId");
    if (persisted.length > 0) {
      ECLog(@"📱 [InstallAndDeviceIDService] Restored deviceID: %@", persisted);
      return persisted;
    }

    // No generation
    return result;
}

static NSString *hooked_idsvc_installID(id self, SEL _cmd) {
    NSString *result = nil;
    if (_orig_idsvc_installID) {
      result = _orig_idsvc_installID(self, _cmd);
    }

    if (result.length > 0) {
      ecSavePersistentID(@"installId", result);
      return result;
    }

    NSString *persisted = ecLoadPersistentID(@"installId");
    if (persisted.length > 0) {
      ECLog(@"📱 [InstallAndDeviceIDService] Restored installID: %@",
            persisted);
      return persisted;
    }

    // No generation
    return result;
}

// BDInstall Hooks
typedef void (*BDInstall_startRegister_IMP)(id, SEL, void (^)(BOOL, BOOL),
                                            void (^)(NSError *));
static BDInstall_startRegister_IMP _orig_bdinstall_startRegister = NULL;

// _notifyDeviceRegisterd 无参方法（选择器无冒号）
typedef void (*BDInstall_notify_IMP)(id, SEL);
static BDInstall_notify_IMP _orig_bdinstall_notify = NULL;

// _needRegsiter 返回 BOOL
typedef BOOL (*BDInstall_needRegister_IMP)(id, SEL);
static BDInstall_needRegister_IMP _orig_bdinstall_needRegister = NULL;

typedef BOOL (*BDInstall_isDeviceRegistered_IMP)(id, SEL);
static BDInstall_isDeviceRegistered_IMP _orig_bdinstall_isDeviceRegistered =
    NULL;

typedef BOOL (*BDInstall_isDeviceActivated_IMP)(id, SEL);
static BDInstall_isDeviceActivated_IMP _orig_bdinstall_isDeviceActivated = NULL;

// _registerDeviceWithRetryTimes:failure:
typedef void (*BDInstall_registerRetry_IMP)(id, SEL, NSInteger,
                                            void (^)(NSError *));
static BDInstall_registerRetry_IMP _orig_bdinstall_registerRetry = NULL;

// BDInstall 单例，生命周期与 App 一致，不会被释放
static __unsafe_unretained id g_bdInstallInstance = nil;

static void hooked_bdinstall_startRegister(id self, SEL _cmd,
                                           void (^success)(BOOL, BOOL),
                                           void (^failure)(NSError *)) {
    ECLog(@"📱📱📱 [BDInstall] startRegisterDeviceWithSuccess:failure: called");
    // 保存 BDInstall 实例引用
    g_bdInstallInstance = self;

    void (^wrappedSuccess)(BOOL, BOOL) = ^(BOOL isNewUser, BOOL isNewDevice) {
      ECLog(@"✅ [BDInstall] Register Success Block Called! isNewUser: %d, "
            @"isNewDevice: %d",
            isNewUser, isNewDevice);

      // 从 self 获取 ID
      if ([self respondsToSelector:@selector(deviceID)]) {
        NSString *did = [self performSelector:@selector(deviceID)];
        ECLog(@"✅ [BDInstall] Captured deviceID in success block: %@", did);
        if (did.length > 0)
          ecSavePersistentID(@"deviceId", did);
      }
      if ([self respondsToSelector:@selector(installID)]) {
        NSString *iid = [self performSelector:@selector(installID)];
        ECLog(@"✅ [BDInstall] Captured installID in success block: %@", iid);
        if (iid.length > 0)
          ecSavePersistentID(@"installId", iid);
      }

      if (success)
        success(isNewUser, isNewDevice);
    };

    void (^wrappedFailure)(NSError *) = ^(NSError *error) {
      ECLog(@"❌ [BDInstall] Register FAILURE: %@", error);
      if (failure)
        failure(error);
    };

    if (_orig_bdinstall_startRegister) {
      _orig_bdinstall_startRegister(self, _cmd, wrappedSuccess, wrappedFailure);
    }
}

// 修正：无参方法签名
static void hooked_bdinstall_notify(id self, SEL _cmd) {
    ECLog(@"📱 [BDInstall] _notifyDeviceRegisterd called!");

    // 从 self 获取 ID
    if ([self respondsToSelector:@selector(deviceID)]) {
      NSString *did = [self performSelector:@selector(deviceID)];
      ECLog(@"📱 [BDInstall] _notifyDeviceRegisterd deviceID: %@", did);
      if (did.length > 0) {
        ECLog(@"✅ [BDInstall] _notifyDeviceRegisterd captured deviceID: %@",
              did);
        ecSavePersistentID(@"deviceId", did);
      }
    }
    if ([self respondsToSelector:@selector(installID)]) {
      NSString *iid = [self performSelector:@selector(installID)];
      ECLog(@"📱 [BDInstall] _notifyDeviceRegisterd installID: %@", iid);
      if (iid.length > 0) {
        ecSavePersistentID(@"installId", iid);
      }
    }

    if (_orig_bdinstall_notify) {
      _orig_bdinstall_notify(self, _cmd);
    }
}

// Hook _needRegsiter: 仅日志透传，不修改返回值
// 之前强制返回 YES 会干扰正常的设备注册流程
static BOOL hooked_bdinstall_needRegister(id self, SEL _cmd) {
    BOOL origResult = NO;
    if (_orig_bdinstall_needRegister) {
      origResult = _orig_bdinstall_needRegister(self, _cmd);
    }
    // 保存 BDInstall 实例
    g_bdInstallInstance = self;

    ECLog(@"📱 [BDInstall] _needRegsiter: %d", origResult);
    return origResult;
}

// Hook isDeviceRegistered: 仅日志透传，不修改返回值
static BOOL hooked_bdinstall_isDeviceRegistered(id self, SEL _cmd) {
    BOOL origResult = NO;
    if (_orig_bdinstall_isDeviceRegistered) {
      origResult = _orig_bdinstall_isDeviceRegistered(self, _cmd);
    }
    ECLog(@"📱 [BDInstall] isDeviceRegistered: %d", origResult);
    return origResult;
}

// Hook isDeviceActivated: 仅日志透传，不修改返回值
static BOOL hooked_bdinstall_isDeviceActivated(id self, SEL _cmd) {
    BOOL origResult = NO;
    if (_orig_bdinstall_isDeviceActivated) {
      origResult = _orig_bdinstall_isDeviceActivated(self, _cmd);
    }
    ECLog(@"📱 [BDInstall] isDeviceActivated: %d", origResult);
    return origResult;
}

// Hook _registerDeviceWithRetryTimes:failure:
static void hooked_bdinstall_registerRetry(id self, SEL _cmd,
                                           NSInteger retryTimes,
                                           void (^failure)(NSError *)) {
    ECLog(@"📱📱📱 [BDInstall] _registerDeviceWithRetryTimes:%ld called",
          (long)retryTimes);
    g_bdInstallInstance = self;

    void (^wrappedFailure)(NSError *) = ^(NSError *error) {
      ECLog(@"❌ [BDInstall] _registerDevice FAILURE (retry=%ld): %@",
            (long)retryTimes, error);
      if (failure)
        failure(error);
    };

    if (_orig_bdinstall_registerRetry) {
      _orig_bdinstall_registerRetry(self, _cmd, retryTimes, wrappedFailure);
    }
}

// Phase 27: Active Injection — 仅生成/缓存 OpenUDID、IDFV
// device_id/install_id 不本地生成，由 BDInstall 服务端注册获取
static void injectSpoofedIDs(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      ECLog(@"💉 [Phase 27.1] Active Injection: OpenUDID + IDFV only.");
    });

    SCPrefLoader *config = [SCPrefLoader shared];

    // IDFV: Config → Persistent → Generate
    NSString *idfv = [config spoofValueForKey:@"idfv"];
    if (!idfv || idfv.length == 0)
      idfv = ecLoadPersistentID(@"idfv");
    if (!idfv || idfv.length == 0) {
      idfv = ecGenerateIDFV();
      ecSavePersistentID(@"idfv", idfv);
      ECLog(@"🔗 [Linkage] Generated IDFV: %@", idfv);
    }

    // 同步到缓存，确保 Hook getter 返回一致的值
    if (idfv)
      g_cachedIDFV = [idfv copy];

    ECLog(@"✅ [Linkage] Cached IDFV=%@", idfv);
}

static void scheduleDelayedDeviceIDCheck(void) {
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          ECLog(@"⏰ [DeviceID] Phase 27 Active Check...");

          // Ensure injection happens
          injectSpoofedIDs();

          NSString *did = ecLoadPersistentID(@"deviceId");
          ECLog(@"   Current Spoofed ID: %@", did);
        });
}

static void hooked_idsvc_setDeviceID(id self, SEL _cmd, NSString *deviceID) {
    ECLog(@"📱📱📱 [InstallAndDeviceIDService] setCurrentDeviceID: %@",
          deviceID);
    if (deviceID.length)
      ecSavePersistentID(@"deviceId", deviceID);
    if (_orig_idsvc_setDeviceID)
      _orig_idsvc_setDeviceID(self, _cmd, deviceID);
}

static void hooked_idsvc_setInstallID(id self, SEL _cmd, NSString *installID) {
    ECLog(@"📱📱📱 [InstallAndDeviceIDService] setCurrentInstallID: %@",
          installID);
    if (installID.length)
      ecSavePersistentID(@"installId", installID);
    if (_orig_idsvc_setInstallID)
      _orig_idsvc_setInstallID(self, _cmd, installID);
}

static void hooked_passport_didFinishLogin(id self, SEL _cmd, id model,
                                           NSError *error) {
    SCPrefLoader *config = [SCPrefLoader shared];
    if (error) {
      ECLog(@"🔐❌ [Login] 登录失败! error=%@ code=%ld domain=%@",
            error.localizedDescription, (long)error.code, error.domain);
      ECLog(@"🔐❌ [Login] userInfo=%@", error.userInfo);
    } else {
      ECLog(@"🔐✅ [Login] 登录成功! model=%@", model);
    }
    // 打印当前 Hook 子开关状态快照，用于诊断
    ECLog(@"🔐📊 [Login] Hook 状态快照:");
    ECLog(
        @"  enableMethodSwizzling=%d enableUIDeviceHooks=%d enableIDFVHook=%d",
        [config spoofBoolForKey:@"enableMethodSwizzling" defaultValue:YES],
        [config spoofBoolForKey:@"enableUIDeviceHooks" defaultValue:YES],
        [config spoofBoolForKey:@"enableIDFVHook" defaultValue:YES]);
    ECLog(@"  enableUIScreenHooks=%d enableCarrierHooks=%d "
          @"enableDiskBatteryHooks=%d",
          [config spoofBoolForKey:@"enableUIScreenHooks" defaultValue:YES],
          [config spoofBoolForKey:@"enableCarrierHooks" defaultValue:NO],
          [config spoofBoolForKey:@"enableDiskBatteryHooks" defaultValue:YES]);
    ECLog(@"  enableSysctlHooks=%d enableSysctlMachine=%d enableSysctlKern=%d",
          [config spoofBoolForKey:@"enableSysctlHooks" defaultValue:YES],
          [config spoofBoolForKey:@"enableSysctlMachine" defaultValue:YES],
          [config spoofBoolForKey:@"enableSysctlKern" defaultValue:YES]);
    ECLog(@"  enableSysctlHardware=%d enableSysctlBoottime=%d",
          [config spoofBoolForKey:@"enableSysctlHardware" defaultValue:YES],
          [config spoofBoolForKey:@"enableSysctlBoottime" defaultValue:YES]);

    if (_orig_passport_didFinishLogin)
      _orig_passport_didFinishLogin(self, _cmd, model, error);
}

static void setupPassportHooks(void) {
    ECLog(@"🔐 [Passport] Setting up Passport hooks...");

    // Hook AWEPassportNetworkManager
    Class netManager = objc_getClass("AWEPassportNetworkManager");
    if (netManager) {
      ECLog(@"🔐 [Passport] Found AWEPassportNetworkManager class");
      SEL sel = @selector(POST:parameters:model:completion:);
      Method m = class_getInstanceMethod(netManager, sel);
      if (m) {
        _orig_passport_POST =
            (AWEPassportNetworkManager_POST_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_passport_POST);
        ECLog(@"✅ [Passport] Hooked AWEPassportNetworkManager POST");
      } else {
        ECLog(
            @"❌ [Passport] Method POST:parameters:model:completion: NOT FOUND "
            @"on AWEPassportNetworkManager");
      }
    } else {
      ECLog(@"❌ [Passport] Class AWEPassportNetworkManager NOT FOUND");
    }

    // Hook AWEPassportServiceImp
    Class serviceImp = objc_getClass("AWEPassportServiceImp");
    if (serviceImp) {
      ECLog(@"🔐 [Passport] Found AWEPassportServiceImp class");
      SEL sel = @selector(login:withTrackerInformation:);
      Method m = class_getInstanceMethod(serviceImp, sel);
      if (m) {
        _orig_passport_login =
            (AWEPassportServiceImp_login_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_passport_login);
        ECLog(@"✅ [Passport] Hooked AWEPassportServiceImp login:withTracker:");
      } else {
        ECLog(
            @"❌ [Passport] Method login:withTrackerInformation: NOT FOUND on "
            @"AWEPassportServiceImp");
      }

      // Hook didFinishLogin:error:
      SEL selFinish = NSSelectorFromString(@"didFinishLogin:error:");
      Method mFinish = class_getInstanceMethod(serviceImp, selFinish);
      if (mFinish) {
        _orig_passport_didFinishLogin =
            (PassportSvc_didFinishLogin_IMP)method_getImplementation(mFinish);
        method_setImplementation(mFinish, (IMP)hooked_passport_didFinishLogin);
        ECLog(@"✅ [Passport] Hooked AWEPassportServiceImp "
              @"didFinishLogin:error:");
      } else {
        ECLog(@"⚠️ [Passport] didFinishLogin:error: not found on "
              @"AWEPassportServiceImp");
      }
    } else {
      ECLog(@"❌ [Passport] Class AWEPassportServiceImp NOT FOUND");
    }

    // ===== Hook AWEPassportConfigurationImplementation =====
    Class configImpl = objc_getClass("AWEPassportConfigurationImplementation");
    if (configImpl) {
      ECLog(
          @"🔐 [Passport] Found AWEPassportConfigurationImplementation class");

      // 尝试多种可能的 POST 方法签名
      SEL postSels[] = {
          NSSelectorFromString(@"POSTJSONDictionary:parameters:completion:"),
          NSSelectorFromString(@"postJSONDictionary:parameters:completion:"),
          NSSelectorFromString(@"POST:parameters:completion:"),
      };
      for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(configImpl, postSels[i]);
        if (m) {
          _orig_passportConfig_POST =
              (PassportConfig_POST_IMP)method_getImplementation(m);
          method_setImplementation(m, (IMP)hooked_passportConfig_POST);
          ECLog(
              @"✅ [Passport] Hooked AWEPassportConfigurationImplementation %@",
              NSStringFromSelector(postSels[i]));
          break;
        }
      }
      if (!_orig_passportConfig_POST) {
        ECLog(@"⚠️ [Passport] No POST method found on "
              @"ConfigurationImplementation");
      }

      // 尝试多种可能的 GET 方法签名
      SEL getSels[] = {
          NSSelectorFromString(@"GETJSONDictionary:parameters:completion:"),
          NSSelectorFromString(@"getJSONDictionary:parameters:completion:"),
          NSSelectorFromString(@"GET:parameters:completion:"),
      };
      for (int i = 0; i < 3; i++) {
        Method m = class_getInstanceMethod(configImpl, getSels[i]);
        if (m) {
          _orig_passportConfig_GET =
              (PassportConfig_GET_IMP)method_getImplementation(m);
          method_setImplementation(m, (IMP)hooked_passportConfig_GET);
          ECLog(
              @"✅ [Passport] Hooked AWEPassportConfigurationImplementation %@",
              NSStringFromSelector(getSels[i]));
          break;
        }
      }
      if (!_orig_passportConfig_GET) {
        ECLog(
            @"⚠️ [Passport] No GET method found on ConfigurationImplementation");
      }
    } else {
      ECLog(@"❌ [Passport] Class AWEPassportConfigurationImplementation NOT "
            @"FOUND");
    }

    // ===== TTInstallIDManager =====
    // 注意: deviceID/installID 的 Hook 已在 setupTTInstallIDManagerHooks()
    // 中安装 此处不再重复 Hook，避免双重 Hook 导致 IMP 链断裂
    // TTInstallIDManager 的 Hook 在 setupTTInstallIDManagerHooks 中
    // 方法枚举已移除（减少内存压力）

    // TTKPassportNetwork 方法枚举已移除（减少内存压力）

    // ===== Hook DYAPassportNetworkProtocol 相关类 =====
    Class dyaPassportNet = objc_getClass("DYAPassportNetworkProtocol");
    if (dyaPassportNet) {
      ECLog(@"🔐 [Passport] Found DYAPassportNetworkProtocol");
    }

    // [DISABLED] 彻底禁用 BDInstall 和 InstallAndDeviceIDService 的所有 Hook
    // 原因：v43.7.0 的 TikTok 对设备注册流程做了强化。我们之前的
    // _needRegister (强制返回 YES) / isDeviceRegistered (强制返回 NO)
    // 和 block 拦截（startRegisterDeviceWithSuccess:failure: 等）
    // 破坏了底层的网络注册流程，导致发往服务端的 device_id= 为空
    // 并且报出 "convert deviceid error: strconv.ParseInt: parsing \"\": invalid
    // syntax" 错误。
    //
    // 新的解决方案：不干预注册，让设备用真实信息完成注册。
    // 我们只在 TTInstallIDManager 的 Getter
    // (在 setupTTInstallIDManagerHooks 里) 进行拦截，
    // 第一次正常返回值后，我们将其捕获并持久化。
    Class bdInstall = objc_getClass("BDInstall");
    if (bdInstall) {
      ECLog(@"🔐 [Passport] Found BDInstall class (Hooks DISABLED for "
            @"registration safety)");
    } else {
      ECLog(@"⚠️ [Passport] Class BDInstall NOT FOUND");
    }

    Class instDevIDSvc = objc_getClass("InstallAndDeviceIDService");
    if (instDevIDSvc) {
      ECLog(@"🔐 [Passport] Found InstallAndDeviceIDService class (Hooks "
            @"DISABLED)");
    } else {
      ECLog(@"⚠️ [Passport] Class InstallAndDeviceIDService NOT FOUND");
    }

    // 启动延迟轮询检查
    scheduleDelayedDeviceIDCheck();
}

// ============================================================================
// 运营商/IDFA 伪装 (独立于 enableMethodSwizzling)
// ============================================================================
static void setupCarrierHooks(void) {
    ECLog(@"📡 [Carrier] Setting up carrier/IDFA hooks...");
    swizzleInstanceMethod([CTCarrier class], @selector(carrierName),
                          @selector(ec_carrierName));
    swizzleInstanceMethod([CTCarrier class], @selector(mobileNetworkCode),
                          @selector(ec_mobileNetworkCode));
    swizzleInstanceMethod([CTCarrier class], @selector(mobileCountryCode),
                          @selector(ec_mobileCountryCode));
    swizzleInstanceMethod([CTCarrier class], @selector(isoCountryCode),
                          @selector(ec_isoCountryCode));
    // [DISABLED] IDFA Hook 已禁用 — 克隆环境下无需伪装
    // swizzleInstanceMethod([ASIdentifierManager class],
    //                       @selector(advertisingIdentifier),
    //                       @selector(ec_advertisingIdentifier));
    ECLog(@"✅ [Carrier] CTCarrier hooks installed (IDFA hook disabled)");
}

// searchPassportClasses 已删除：objc_copyClassList 遍历全部类会导致
// 内存暴涨 + CODESIGNING SIGKILL 崩溃

// ============================================================================
// TTNet Hook 安装函数
// ============================================================================
static void installTTNetHooks(Class ttNetClass) {
    ECLog(@"🕸️ [TTNet] Installing hooks on %s...", class_getName(ttNetClass));

    int hooked = 0;

    // Hook 1: requestWithURL:method:params:callback:
    {
      SEL sel = @selector(requestWithURL:method:params:callback:);
      Method m = class_getInstanceMethod(ttNetClass, sel);
      if (m) {
        _orig_ttnet_requestWithURL =
            (TTNet_requestWithURL_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_ttnet_requestWithURL);
        ECLog(@"  ✅ [TTNet] Hooked: requestWithURL:method:params:callback:");
        hooked++;
      }
    }

    // Hook 2: bdxbridge_requestWithURL:method:params:callback:
    {
      SEL sel = @selector(bdxbridge_requestWithURL:method:params:callback:);
      Method m = class_getInstanceMethod(ttNetClass, sel);
      if (m) {
        _orig_ttnet_bdxbridge_request =
            (TTNet_requestWithURL_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_ttnet_bdxbridge_request);
        ECLog(@"  ✅ [TTNet] Hooked: "
              @"bdxbridge_requestWithURL:method:params:callback:");
        hooked++;
      }
    }

    // Hook 3:
    // tspk_requestForJSONWithURL_:params:method:needCommonParams:headerField:
    //          requestSerializer:responseSerializer:autoResume:verifyRequest:
    //          isCustomizedCookie:callback:callbackWithResponse:dispatch_queue:
    {
      SEL sel = @selector
          (tspk_requestForJSONWithURL_:
                                params:method:needCommonParams:headerField
                                      :requestSerializer:responseSerializer
                                      :autoResume:verifyRequest
                                      :isCustomizedCookie:callback
                                      :callbackWithResponse:dispatch_queue:);
      Method m = class_getInstanceMethod(ttNetClass, sel);
      if (m) {
        _orig_ttnet_requestForJSON =
            (TTNet_requestForJSON_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_ttnet_requestForJSON);
        ECLog(@"  ✅ [TTNet] Hooked: "
              @"tspk_requestForJSONWithURL_:...:dispatch_queue:");
        hooked++;
      }
    }

    // Hook 4:
    // tspk_requestForBinaryWithURL_:params:method:needCommonParams:headerField:
    //          enableHttpCache:requestSerializer:responseSerializer:autoResume:
    //          isCustomizedCookie:headerCallback:dataCallback:callback:
    //          callbackWithResponse:redirectCallback:progress:dispatch_queue:
    {
      SEL sel = @selector
          (tspk_requestForBinaryWithURL_:
                                  params:method:needCommonParams:headerField
                                        :enableHttpCache:requestSerializer
                                        :responseSerializer:autoResume
                                        :isCustomizedCookie:headerCallback
                                        :dataCallback:callback
                                        :callbackWithResponse:redirectCallback
                                        :progress:dispatch_queue:);
      Method m = class_getInstanceMethod(ttNetClass, sel);
      if (m) {
        _orig_ttnet_requestForBinary =
            (TTNet_requestForBinary_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_ttnet_requestForBinary);
        ECLog(@"  ✅ [TTNet] Hooked: "
              @"tspk_requestForBinaryWithURL_:...:dispatch_queue:");
        hooked++;
      }
    }

    // Hook 5:
    // tspk_requestModel:requestSerializer:responseSerializer:autoResume:callback:callbackWithResponse:dispatch_queue:
    // (7 args) - 模型化请求 API
    {
      SEL sel = NSSelectorFromString(
          @"tspk_requestModel:requestSerializer:responseSerializer:autoResume:"
          @"callback:callbackWithResponse:dispatch_queue:");
      Method m = class_getInstanceMethod(ttNetClass, sel);
      if (m) {
        _orig_ttnet_requestModel =
            (TTNet_requestModel_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_ttnet_requestModel);
        ECLog(@"  ✅ [TTNet] Hooked: tspk_requestModel:...:dispatch_queue:");
        hooked++;
      } else {
        ECLog(@"  ⚠️ [TTNet] Not found: tspk_requestModel:...");
      }
    }

    // Hook 6:
    // tspk_synchronizedRequstForURL:method:headerField:jsonObjParams:needCommonParams:requestSerializer:needResponse:needEncrypt:needContentEncodingAfterEncrypt:
    // (9 args) - 同步请求 API
    {
      SEL sel = NSSelectorFromString(
          @"tspk_synchronizedRequstForURL:method:headerField:jsonObjParams:"
          @"needCommonParams:requestSerializer:needResponse:needEncrypt:"
          @"needContentEncodingAfterEncrypt:");
      Method m = class_getInstanceMethod(ttNetClass, sel);
      if (m) {
        _orig_ttnet_syncRequest =
            (TTNet_syncRequest_IMP)method_getImplementation(m);
        method_setImplementation(m, (IMP)hooked_ttnet_syncRequest);
        ECLog(@"  ✅ [TTNet] Hooked: tspk_synchronizedRequstForURL:...");
        hooked++;
      } else {
        ECLog(@"  ⚠️ [TTNet] Not found: tspk_synchronizedRequstForURL:...");
      }
    }

    // ★★★ 核心 Hook: CommonParamsByLevelBlock — 全量 ivar 直接替换 ★★★
    //
    // 背景分析：
    //   1) getter / setter 都不被内部直接调用。
    //   2) 包含多个相关 block ivar: _commonParamsblock,
    //   _commonParamsblockWithURL, _getCommonParamsByLevelBlock等 3)
    //   提前发出请求，需高频定时器拦截
    //
    // 方案: 遍历所有匹配名称的 ivar → 高频重试等待非空 → 针对性包装并直接替换
    {
      // ═══ Layer A: Hook getter 方法（作为第一层保护）═══
      SEL getterSel = NSSelectorFromString(@"getCommonParamsByLevelBlock");
      Method getterM = class_getInstanceMethod(ttNetClass, getterSel);
      if (getterM) {
        typedef id (*GetterIMP)(id, SEL);
        static GetterIMP _orig_getCommonParams = NULL;
        _orig_getCommonParams = (GetterIMP)method_getImplementation(getterM);

        IMP newGetterIMP = imp_implementationWithBlock(^id(id self_) {
          id originalBlock = _orig_getCommonParams(self_, getterSel);
          if (!originalBlock)
            return nil;

          return ^id(NSInteger level) {
            id (^origBlock)(NSInteger) = (id(^)(NSInteger))originalBlock;
            id result = origBlock(level);

            if ([result isKindOfClass:[NSDictionary class]]) {
              NSMutableDictionary *p = [result mutableCopy];
              SCPrefLoader *cfg = [SCPrefLoader shared];

              NSString *m = [cfg spoofValueForKey:@"machineModel"];
              if (m.length > 0 && p[@"device_type"] &&
                  ![p[@"device_type"] isEqualToString:m])
                p[@"device_type"] = m;

              NSString *o = [cfg spoofValueForKey:@"systemVersion"];
              if (o.length > 0 && p[@"os_version"] &&
                  ![p[@"os_version"] isEqualToString:o])
                p[@"os_version"] = o;

              NSString *n = [cfg spoofValueForKey:@"marketName"];
              if (n.length > 0 && p[@"device_model"] &&
                  ![p[@"device_model"] isEqualToString:n])
                p[@"device_model"] = n;

              // 【网络层伪装】让 TTNet 认为当前本身就不支持 QUIC 或主动关闭了 QUIC
              // 这会极大程度减少因为 UDP 强杀带来的“被劫持”风控判刑
              if (p[@"enable_quic"] || p[@"enable_http3"]) {
                p[@"enable_quic"] = @"0";
                p[@"enable_http3"] = @"0";
              }

              return (id)[p copy];
            }
            return result;
          };
        });
        method_setImplementation(getterM, newGetterIMP);
        ECLog(@"  ✅ [TTNet] Layer-A: getter hook 已安装");
        hooked++;
      }

      // ═══ Layer B: 已移除原来缓慢的 GCD
      // 定时器，全部改为在钩子方法的同步请求中即刻拦截执行 ═══
      // 对分享实例立即来一发兜底替换
      @try {
        id mgr = nil;
        if ([ttNetClass
                respondsToSelector:NSSelectorFromString(@"shareInstance")]) {
          mgr = [ttNetClass
              performSelector:NSSelectorFromString(@"shareInstance")];
        }
        if (!mgr && [ttNetClass respondsToSelector:NSSelectorFromString(
                                                       @"sharedInstance")]) {
          mgr = [ttNetClass
              performSelector:NSSelectorFromString(@"sharedInstance")];
        }
        if (mgr) {
          ec_ensure_ttnet_block_replaced(mgr);
        }
      } @catch (NSException *e) {
      }
    }

    ECLog(@"🕸️ [TTNet] %d hooks installed on %s", hooked,
          class_getName(ttNetClass));

    // searchPassportClasses 已删除（objc_copyClassList 导致崩溃）

    // Install Passport Hooks
    setupPassportHooks();

    // 登录诊断 Hook（2026-02-24 新增）
    setupLoginDiagnosticHooks();
}

// ============================================================================
// 登录排查专用诊断 Hook（2026-02-24）
// 纯日志记录，不修改任何数据
// ============================================================================

static void setupLoginDiagnosticHooks(void) {
    ECLog(@"🔍 [LoginDiag] 安装登录诊断 Hook...");

    // ═══ 1-5 部分移除 ═══
    // 原有的 1~5 部分（TTAccountNetworkManager、AWERiskControlService、
    // didFinishPassportQueryButFailAweme、TTAccountSessionTask、TTAccountStore）
    // 仅用于诊断日志，且大量使用了 class_copyMethodList 和动态
    // imp_implementationWithBlock， 非常容易导致 OOM (内存不足崩溃)。已被清理。

    // ═══ 6. Hook TTHttpTaskChromium.resume ═══
    // Chromium HTTP 任务 — passport 登录请求走此通道（已验证可用）
    // 只 Hook resume，不做任何方法枚举（避免 OOM）
    Class chromiumTask = objc_getClass("TTHttpTaskChromium");
    if (chromiumTask) {
      ECLog(@"🔍 [LoginDiag] 发现 TTHttpTaskChromium");
      SEL resumeSel = NSSelectorFromString(@"resume");
      Method resumeM = class_getInstanceMethod(chromiumTask, resumeSel);
      if (resumeM) {
        IMP origResume = method_getImplementation(resumeM);
        IMP newResume = imp_implementationWithBlock(^(id self_) {
          @try {
            // 提取 TTHttpRequestChromium 对象
            id reqObj = nil;
            if ([self_ respondsToSelector:NSSelectorFromString(@"request")]) {
              reqObj = [self_ performSelector:NSSelectorFromString(@"request")];
            }
            if (reqObj) {
              // 提取 URL
              NSString *urlStr = @"<unknown>";
              SEL urlSels[] = {
                  NSSelectorFromString(@"URL"),
                  NSSelectorFromString(@"url"),
                  NSSelectorFromString(@"URLString"),
                  NSSelectorFromString(@"urlString"),
              };
              for (int j = 0; j < 4; j++) {
                if ([reqObj respondsToSelector:urlSels[j]]) {
                  id val = [reqObj performSelector:urlSels[j]];
                  if (val) {
                    urlStr = [val description];
                    break;
                  }
                }
              }
              // ═══ URL 参数反泄漏篡改 ═══
              // 修复已知的信息泄漏：ad_user_agent（真实iOS版本）、
              // os_boot_time（真实开机时间）、carrier_region/mcc_mnc（运营商信息）
              {
                NSString *spoofedOsVer = [[SCPrefLoader shared]
                                             spoofValueForKey:@"systemVersion"]
                                             ?: @"16.7.10";
                // 将 16.7.10 转换为 16_7_10 格式（WebView UA 用下划线）
                NSString *spoofedOsVerUA =
                    [spoofedOsVer stringByReplacingOccurrencesOfString:@"."
                                                            withString:@"_"];
                BOOL urlModified = NO;
                NSString *newUrlStr = urlStr;

                // (1) ad_user_agent 中的真实 iOS 版本
                // 检测 "iPhone%20OS%20XX_X_X" 格式（URL encoded）
                NSRegularExpression *adUaRegex = [NSRegularExpression
                    regularExpressionWithPattern:
                        @"(iPhone%20OS%20)([0-9]+_[0-9]+(?:_[0-9]+)?)"
                                         options:0
                                           error:nil];
                if (adUaRegex) {
                  NSString *replaced = [adUaRegex
                      stringByReplacingMatchesInString:newUrlStr
                                               options:0
                                                 range:NSMakeRange(
                                                           0, newUrlStr.length)
                                          withTemplate:[NSString
                                                           stringWithFormat:
                                                               @"$1%@",
                                                               spoofedOsVerUA]];
                  if (![replaced isEqualToString:newUrlStr]) {
                    newUrlStr = replaced;
                    urlModified = YES;
                    ECLog(@"🔒 [反泄漏] ad_user_agent iOS 版本已篡改 → %@",
                          spoofedOsVerUA);
                  }
                }

                // (2) os_boot_time — 替换为伪装值
                // 为每个克隆包生成固定的伪装 boot_time（基于 cdid hash）
                NSRegularExpression *bootRegex =
                    [NSRegularExpression regularExpressionWithPattern:
                                             @"os_boot_time=[0-9]+\\.?[0-9]*"
                                                              options:0
                                                                error:nil];
                if (bootRegex) {
                  NSString *spoofedBootTime = [NSString
                      stringWithFormat:@"os_boot_time=%u",
                                       (unsigned int)(
                                           [[[SCPrefLoader shared]
                                               spoofValueForKey:@"cdid"] hash] %
                                               900000000 +
                                           1700000000)];
                  NSString *replaced = [bootRegex
                      stringByReplacingMatchesInString:newUrlStr
                                               options:0
                                                 range:NSMakeRange(
                                                           0, newUrlStr.length)
                                          withTemplate:spoofedBootTime];
                  if (![replaced isEqualToString:newUrlStr]) {
                    newUrlStr = replaced;
                    urlModified = YES;
                    ECLog(@"🔒 [反泄漏] os_boot_time 已篡改");
                  }
                }

                // (3) carrier_region 和 mcc_mnc — 清空值
                NSRegularExpression *carrierRegex = [NSRegularExpression
                    regularExpressionWithPattern:@"carrier_region=[^&]*"
                                         options:0
                                           error:nil];
                if (carrierRegex) {
                  NSString *replaced = [carrierRegex
                      stringByReplacingMatchesInString:newUrlStr
                                               options:0
                                                 range:NSMakeRange(
                                                           0, newUrlStr.length)
                                          withTemplate:@"carrier_region="];
                  if (![replaced isEqualToString:newUrlStr]) {
                    newUrlStr = replaced;
                    urlModified = YES;
                  }
                }
                NSRegularExpression *mccRegex = [NSRegularExpression
                    regularExpressionWithPattern:@"mcc_mnc=[^&]*"
                                         options:0
                                           error:nil];
                if (mccRegex) {
                  NSString *replaced = [mccRegex
                      stringByReplacingMatchesInString:newUrlStr
                                               options:0
                                                 range:NSMakeRange(
                                                           0, newUrlStr.length)
                                          withTemplate:@"mcc_mnc="];
                  if (![replaced isEqualToString:newUrlStr]) {
                    newUrlStr = replaced;
                    urlModified = YES;
                  }
                }

                // 将篡改后的 URL 写回 request 对象
                if (urlModified) {
                  NSURL *newURL = [NSURL URLWithString:newUrlStr];
                  if (newURL) {
                    SEL setUrlSel = NSSelectorFromString(@"setURL:");
                    SEL setUrlStrSel = NSSelectorFromString(@"setUrlString:");
                    if ([reqObj respondsToSelector:setUrlSel]) {
                      [reqObj performSelector:setUrlSel withObject:newURL];
                    } else if ([reqObj respondsToSelector:setUrlStrSel]) {
                      [reqObj performSelector:setUrlStrSel
                                   withObject:newUrlStr];
                    }
                    urlStr = newUrlStr; // 更新日志显示的 URL
                  }
                }
              }
              // 检查是否是 passport/login 相关请求（只匹配路径关键词，不匹配
              // query 参数） 之前 "account" 会误匹配 URL 中的 account_region=jp
              // 参数
              NSString *urlPath = urlStr;
              NSRange qRange = [urlStr rangeOfString:@"?"];
              if (qRange.location != NSNotFound) {
                urlPath = [urlStr substringToIndex:qRange.location];
              }
              NSString *lowerPath = [urlPath lowercaseString];
              BOOL isPassport = [lowerPath containsString:@"passport"] ||
                                [lowerPath containsString:@"/login"] ||
                                [lowerPath containsString:@"/register"] ||
                                [lowerPath containsString:@"send_code"] ||
                                [lowerPath containsString:@"device_register"];
              // passport 日志也已静默（减少内存压力）
              // 如需调试登录问题，可临时恢复下面的 ECLog
              if (isPassport) {
                // ECLog(@"🔴🔑 [ChromiumTask-PASSPORT] URL: %@", urlStr);
              }
            } else {
              ECLog(@"🌐 [ChromiumTask] resume (no request obj)");
            }
          } @catch (NSException *e) {
            ECLog(@"⚠️ [ChromiumTask] error: %@", e);
          }
          // ═══ MSSDK 安全上报增强拦截 ═══
          // MSSDK 通过多种通道上报设备指纹和风控事件：
          // 1. URL 包含 mssdk 关键字（如 mssdk-*.tiktokv.com/ri/report）
          // 2. 风控接口 /ri/report、/ri/config、/ri/init
          // 3. 安全 SDK 数据采集 /sec_did_t、/risk_sdk
          // 4. POST body 包含设备指纹加密数据
          // 拦截策略：丢弃所有风控上报请求，不调用原始 resume。
          {
            NSString *blockUrl = nil;
            @try {
              id reqCheck = nil;
              if ([self_ respondsToSelector:NSSelectorFromString(@"request")]) {
                reqCheck =
                    [self_ performSelector:NSSelectorFromString(@"request")];
              }
              if (reqCheck) {
                SEL urlSels2[] = {
                    NSSelectorFromString(@"URL"),
                    NSSelectorFromString(@"url"),
                    NSSelectorFromString(@"URLString"),
                    NSSelectorFromString(@"urlString"),
                };
                for (int j = 0; j < 4; j++) {
                  if ([reqCheck respondsToSelector:urlSels2[j]]) {
                    id val2 = [reqCheck performSelector:urlSels2[j]];
                    if (val2) {
                      blockUrl = [[val2 description] lowercaseString];
                      break;
                    }
                  }
                }
              }
            } @catch (NSException *e2) {
              // 忽略
            }
            if (blockUrl) {
              // 增强 MSSDK 拦截：多维度匹配
              BOOL shouldBlock = NO;
              // (1) MSSDK 服务端域名（排除 webmssdk.js 登录验证码 JS）
              if ([blockUrl containsString:@"mssdk-"] ||
                  [blockUrl containsString:@"mssdk."])
                shouldBlock = YES;
              // 排除 webmssdk.js — 这是登录验证码必需的 JS 文件
              if ([blockUrl containsString:@"webmssdk"])
                shouldBlock = NO;
              // (2) 风控上报端点 /ri/report、/ri/config、/ri/init
              if ([blockUrl containsString:@"/ri/report"])
                shouldBlock = YES;
              if ([blockUrl containsString:@"/ri/config"])
                shouldBlock = YES;
              if ([blockUrl containsString:@"/ri/init"])
                shouldBlock = YES;
              // (3) 安全 SDK 端点
              if ([blockUrl containsString:@"sec_did_t"])
                shouldBlock = YES;
              if ([blockUrl containsString:@"/riskcontrol"])
                shouldBlock = YES;
              if ([blockUrl containsString:@"/risk_sdk"])
                shouldBlock = YES;
              // (4) 设备指纹采集端点
              if ([blockUrl containsString:@"/device/info"])
                shouldBlock = YES;
              if ([blockUrl containsString:@"applog.snssdk"])
                shouldBlock = YES;
              // (5) 安全验证服务（密码提交时的额外校验）
              if ([blockUrl containsString:@"verify.snssdk"])
                shouldBlock = YES;
              if ([blockUrl containsString:@"/passport/token"])
                shouldBlock = YES;

              if (shouldBlock) {
                // MSSDK 阻止策略：纯 return，不调用 origResume
                // ⚠️ 不使用 dispatch_after cancel — 会导致 wakeups_resource
                // 超限崩溃
                static int mssdkBlockCount = 0;
                mssdkBlockCount++;
                if (mssdkBlockCount <= 20) {
                  ECLog(@"🛡️ [MSSDK-BLOCK #%d] 已拦截: %@", mssdkBlockCount,
                        blockUrl);
                }
                return; // 不调用 origResume，请求不发出
              }
            }
          }

          ((void (*)(id, SEL))origResume)(self_, resumeSel);
        });
        method_setImplementation(resumeM, newResume);
        ECLog(@"✅ [TTHttpTaskChromium] Hooked resume");
      }
    } else {
      ECLog(@"⚠️ [LoginDiag] TTHttpTaskChromium 未找到");
    }
    }

    // ============================================================================
    // Layer 4: SSL 层 fishhook (BoringSSL SSL_write/SSL_read)
    // 拦截加密前/解密后的明文数据，捕获所有 TLS 流量
    // ============================================================================

    // BoringSSL 类型声明 (不需要导入头文件)
    typedef struct ssl_st SSL;
    typedef struct ssl_ctx_st SSL_CTX;

    // 原始函数指针
    static int (*orig_SSL_write)(SSL *ssl, const void *buf, int num) = NULL;
    static int (*orig_SSL_read)(SSL *ssl, void *buf, int num) = NULL;

    // 外部 BoringSSL 函数声明 (从 boringssl.framework 导出)
    extern const char *SSL_get_servername(const SSL *ssl, int type);
    extern int SSL_get_fd(const SSL *ssl);

    // ===================================
    // QUIC 禁用 — Hook connect() 阻断 UDP:443
    // ===================================
    static int (*orig_connect)(int, const struct sockaddr *, socklen_t) = NULL;

    static int hooked_connect(int sockfd, const struct sockaddr *addr,
                              socklen_t addrlen) {
    // 检查是否为 UDP socket + 端口 443（QUIC）
    if (addr && addr->sa_family == AF_INET) {
      const struct sockaddr_in *addr4 = (const struct sockaddr_in *)addr;
      uint16_t port = ntohs(addr4->sin_port);
      if (port == 443) {
        // 检查 socket 类型是否为 DGRAM（UDP）
        int sockType = 0;
        socklen_t optLen = sizeof(sockType);
        getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sockType, &optLen);
        if (sockType == SOCK_DGRAM) {
          char ipStr[INET_ADDRSTRLEN];
          inet_ntop(AF_INET, &addr4->sin_addr, ipStr, sizeof(ipStr));
          ECLog(@"🚫 [QUIC] 阻断 UDP:443 连接 -> %s (强制回退 TCP/TLS)", ipStr);
          ECLog(@"⚠️【诊断】极高风控警告：你正在阻断 TTNet QUIC。当代 TikTok Cronet 引擎检测到被强行阻挡 UDP 后，极其容易将此行为判定为网络代理(VPN)或黑产拦截，从而频发验证码！");
          errno = ECONNREFUSED;
          return -1;
        }
      }
    } else if (addr && addr->sa_family == AF_INET6) {
      const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6 *)addr;
      uint16_t port = ntohs(addr6->sin6_port);
      if (port == 443) {
        int sockType = 0;
        socklen_t optLen = sizeof(sockType);
        getsockopt(sockfd, SOL_SOCKET, SO_TYPE, &sockType, &optLen);
        if (sockType == SOCK_DGRAM) {
          char ipStr[INET6_ADDRSTRLEN];
          inet_ntop(AF_INET6, &addr6->sin6_addr, ipStr, sizeof(ipStr));
          ECLog(@"🚫 [QUIC] 阻断 UDP:443 (IPv6) -> %s (强制回退 TCP/TLS)",
                ipStr);
          ECLog(@"⚠️【诊断】极高风控警告：你正在阻断 TTNet QUIC (IPv6)。这将容易引发严重验证码及降权！");
          errno = ECONNREFUSED;
          return -1;
        }
      }
    }
    return orig_connect(sockfd, addr, addrlen);
    }

    // 用于追踪每个 SSL 连接的简单缓存
    // key = SSL* 指针地址, value = 连接信息
    static NSMutableDictionary *_sslConnectionInfo = nil;
    static dispatch_queue_t _sslLogQueue = nil;

    static void ensureSSLLogQueue(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      _sslLogQueue =
          dispatch_queue_create("com.ec.ssl.log", DISPATCH_QUEUE_SERIAL);
      _sslConnectionInfo = [NSMutableDictionary new];
    });
    }

    // 判断缓冲区是否包含 HTTP 特征
    static BOOL isHTTPData(const void *buf, int num) {
    if (num < 4)
      return NO;
    const char *data = (const char *)buf;
    // 检查 HTTP 方法或响应头
    return (strncmp(data, "GET ", 4) == 0 || strncmp(data, "POST", 4) == 0 ||
            strncmp(data, "PUT ", 4) == 0 || strncmp(data, "HEAD", 4) == 0 ||
            strncmp(data, "DELE", 4) == 0 || strncmp(data, "PATC", 4) == 0 ||
            strncmp(data, "HTTP", 4) == 0);
    }

    // SSL_write hook — 日志已静默（不修改数据，减少内存压力）
    // 原来此处有完整的 TLS 明文请求转储（header 逐行 + body 完整输出）
    // 因峰值 1357 条/秒导致内存压力，已移除。如需调试登录问题可临时恢复。
    static int hooked_SSL_write(SSL * ssl, const void *buf, int num) {
    return orig_SSL_write(ssl, buf, num);
    }

    // SSL_read hook — 日志已静默（不修改数据，减少内存压力）
    // 原来此处有完整的 TLS 明文响应转储 + JSON 解析。已移除。
    static int hooked_SSL_read(SSL * ssl, void *buf, int num) {
    return orig_SSL_read(ssl, buf, num);
    }
    static void setupSSLHooks(void) {
    // SSL_write/SSL_read 是空操作（不再做日志转储），不需要安装 fishhook
    // 节省一次全局 rebind_symbols 遍历
    ECLog(@"🔐 [L4] SSL hooks 已跳过（空操作，无需 rebind）");

    // [已移除] L5: connect() Hook 阻断 UDP:443
    // 原因：已通过应用层 TTNet CommonParams 注入 enable_quic=0 实现 QUIC 禁用。
    // socket 层的暴力 connect() 拦截是冗余的，且会在 Cronet 引擎中
    // 留下 ECONNREFUSED 指纹，被风控识别为网络劫持/黑产拦截。
    // 特别是首次启动时，CommonParams 尚未就绪，Cronet 的 QUIC 探测会
    // 被 connect hook 反复强杀，引发启动延迟和异常重试。
    ECLog(@"ℹ️ [L5] QUIC 禁用已改用应用层方案 (TTNet enable_quic=0)，socket connect hook 已移除");
    }

    // --- Layer 3: NSURLProtocol 全局拦截器 ---
    // NSURLProtocol 可以拦截任何通过 URL Loading System 的请求
    // 即使 TTNet 内部可能将某些请求回传给 NSURLSession

    @interface ECNetworkInterceptorProtocol : NSURLProtocol
    @end

    @implementation ECNetworkInterceptorProtocol

    +(BOOL)canInitWithRequest : (NSURLRequest *)request {
    // 避免递归: 已标记的请求不再处理
    if ([NSURLProtocol propertyForKey:@"ECIntercepted" inRequest:request]) {
      return NO;
    }

    NSString *url = request.URL.absoluteString ?: @"";

    // 只拦截 TikTok 相关域名
    if ([url containsString:@"tiktok"] || [url containsString:@"musical"] ||
        [url containsString:@"bytedance"] || [url containsString:@"byteimg"] ||
        [url containsString:@"bytegecko"] || [url containsString:@"byted"] ||
        [url containsString:@"passport"] || [url containsString:@"login"] ||
        [url containsString:@"snssdk"] || [url containsString:@"pstatp"] ||
        [url containsString:@"ibyteimg"] || [url containsString:@"ttlivecdn"] ||
        [url containsString:@"ibytedtos"]) {

      NSString *method = request.HTTPMethod ?: @"GET";
      ECLog(@"🔵 [Proto] ➤ %@ %@", method, url);

      // Body/Headers 日志已移除（无实际作用）
    }

    return NO; // 返回 NO: 我们只做记录，不拦截实际请求
    }

    +(NSURLRequest *)canonicalRequestForRequest : (NSURLRequest *)request {
    return request;
    }

    -(void)startLoading {
      // 不会被调用 (canInitWithRequest 返回 NO)
    }

    -(void)stopLoading {
    // 不会被调用
    }

    @end

    // --- Main Setup ---
    static void setupNetworkInterception(void) {
    ECLog(@"🕸️ [Network] Setting up network interception...");

    SCPrefLoader *config = [SCPrefLoader shared];

    // ═══════════════════════════════════════════════
    // Layer 1: NSURLSession Hook (第三方 SDK 流量)
    // 开关: enableNetworkL1 (默认开启)
    // ═══════════════════════════════════════════════
    if ([config spoofBoolForKey:@"enableNetworkL1" defaultValue:YES]) {
      Class sessionClass = [NSURLSession class];
      SEL selector = @selector(dataTaskWithRequest:completionHandler:);
      Method method = class_getInstanceMethod(sessionClass, selector);

      if (method) {
        original_dataTaskWithRequestCompletion =
            (NSURLSessionDataTask *
             (*)(id, SEL, NSURLRequest *,
                 void (^)(NSData *, NSURLResponse *, NSError *)))
                method_getImplementation(method);

        method_setImplementation(method,
                                 (IMP)hooked_dataTaskWithRequestCompletion);
        ECLog(@"  ✅ [L1] Hooked NSURLSession "
              @"-dataTaskWithRequest:completionHandler:");
      } else {
        ECLog(@"  ❌ [L1] Failed to hook NSURLSession");
      }
    } else {
      ECLog(@"  ⏭️ [L1] NSURLSession Hook DISABLED (enableNetworkL1=NO)");
    }

    // ═══════════════════════════════════════════════
    // Layer 2: TTNetworkManager 请求/响应 Hook
    // 开关: enableNetworkL2 (默认开启)
    // 包含: TTHttpTaskChromium MSSDK 拦截、Passport 登录记录
    // ═══════════════════════════════════════════════
    if ([config spoofBoolForKey:@"enableNetworkL2" defaultValue:YES]) {
      Class ttNetworkClass = NSClassFromString(@"TTNetworkManager");
      if (ttNetworkClass) {
        ECLog(@"  ✅ [L2] Found TTNetworkManager - installing hooks...");
        installTTNetHooks(ttNetworkClass);
      } else {
        ECLog(@"  ℹ️ [L2] TTNetworkManager not found");
      }
    } else {
      ECLog(@"  ⏭️ [L2] TTNet Hooks DISABLED (enableNetworkL2=NO)");
    }

    // ═══════════════════════════════════════════════
    // Layer 3: NSURLProtocol 全局注册 (请求日志记录)
    // 开关: enableNetworkL3 (默认开启)
    // ═══════════════════════════════════════════════
    if ([config spoofBoolForKey:@"enableNetworkL3" defaultValue:YES]) {
      [NSURLProtocol registerClass:[ECNetworkInterceptorProtocol class]];
      ECLog(@"  ✅ [L3] Registered ECNetworkInterceptorProtocol");
    } else {
      ECLog(@"  ⏭️ [L3] NSURLProtocol DISABLED (enableNetworkL3=NO)");
    }

    // ═══════════════════════════════════════════════
    // Layer 4: SSL 层 fishhook (BoringSSL)
    // 拦截加密前/解密后的明文数据
    // 开关: enableNetworkL2 (与 TTNet 共用开关)
    // ═══════════════════════════════════════════════
    if ([config spoofBoolForKey:@"enableNetworkL2" defaultValue:YES]) {
      setupSSLHooks();
    } else {
      ECLog(@"  ⏭️ [L4] SSL Hooks DISABLED (enableNetworkL2=NO)");
    }

    ECLog(@"🕸️ [Network] Interception setup complete!");
    }

    // Phase 28.2: TTInstallIDManager Hooks (TikTok specific)
    // Phase 29: Hook TTInstallIDManager.deviceID getter
    // 确保 TikTok URL 公共参数中的 device_id 使用伪装值
    static NSString *hooked_TTInstallIDManager_deviceID(id self, SEL _cmd) {
    if (g_cachedDeviceID && g_cachedDeviceID.length > 0)
      return g_cachedDeviceID;
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"deviceId"];
    if (spoofed && spoofed.length > 0)
      return spoofed;
    spoofed = ecLoadPersistentID(@"deviceId");
    if (spoofed && spoofed.length > 0)
      return spoofed;
    // Fallback to original
    SEL origSel = NSSelectorFromString(@"ec_orig_deviceID");
    if ([self respondsToSelector:origSel]) {
      NSString *(*imp)(id, SEL) =
          (NSString * (*)(id, SEL))[self methodForSelector:origSel];
      NSString *origResult = imp(self, origSel);
      if (origResult && origResult.length > 0) {
        ecSavePersistentID(@"deviceId", origResult);
      }
      return origResult;
    }
    return nil;
    }

    // Phase 29: Hook TTInstallIDManager.installID getter
    static NSString *hooked_TTInstallIDManager_installID(id self, SEL _cmd) {
    if (g_cachedInstallID && g_cachedInstallID.length > 0)
      return g_cachedInstallID;
    NSString *spoofed =
        [[SCPrefLoader shared] spoofValueForKey:@"installId"];
    if (spoofed && spoofed.length > 0)
      return spoofed;
    spoofed = ecLoadPersistentID(@"installId");
    if (spoofed && spoofed.length > 0)
      return spoofed;
    // Fallback to original
    SEL origSel = NSSelectorFromString(@"ec_orig_installID");
    if ([self respondsToSelector:origSel]) {
      NSString *(*imp)(id, SEL) =
          (NSString * (*)(id, SEL))[self methodForSelector:origSel];
      NSString *origResult = imp(self, origSel);
      if (origResult && origResult.length > 0) {
        ecSavePersistentID(@"installId", origResult);
      }
      return origResult;
    }
    return nil;
    }

    // Phase 29: Hook TTInstallIDManager.idfv getter
    static NSString *hooked_TTInstallIDManager_idfv(id self, SEL _cmd) {
    if (g_cachedIDFV && g_cachedIDFV.length > 0)
      return g_cachedIDFV;
    NSString *spoofed = [[SCPrefLoader shared] spoofValueForKey:@"idfv"];
    if (spoofed && spoofed.length > 0)
      return spoofed;
    spoofed = ecLoadPersistentID(@"idfv");
    if (spoofed && spoofed.length > 0)
      return spoofed;
    // Fallback to original
    SEL origSel = NSSelectorFromString(@"ec_orig_idfv");
    if ([self respondsToSelector:origSel]) {
      NSString *(*imp)(id, SEL) =
          (NSString * (*)(id, SEL))[self methodForSelector:origSel];
      NSString *origResult = imp(self, origSel);
      if (origResult && origResult.length > 0) {
        ecSavePersistentID(@"idfv", origResult);
      }
      return origResult;
    }
    return nil;
    }

    static void setupTTInstallIDManagerHooks(void) {
    Class cls = NSClassFromString(@"TTInstallIDManager");
    if (!cls)
      return;

    // 使用 method_setImplementation + class_addMethod 保存原始实现
    // 注意: swizzleInstanceMethod 需要两个 SEL，此处改用直接 Hook

    // Phase 29: Hook deviceID getter
    SEL selDID = NSSelectorFromString(@"deviceID");
    Method mDID = class_getInstanceMethod(cls, selDID);
    if (mDID) {
      IMP origIMP = method_setImplementation(
          mDID, (IMP)hooked_TTInstallIDManager_deviceID);
      class_addMethod(cls, NSSelectorFromString(@"ec_orig_deviceID"), origIMP,
                      method_getTypeEncoding(mDID));
      ECLog(@"  ✅ [TTInstallIDManager] Hooked deviceID");
    }

    // Phase 29: Hook installID getter
    SEL selIID = NSSelectorFromString(@"installID");
    Method mIID = class_getInstanceMethod(cls, selIID);
    if (mIID) {
      IMP origIMP = method_setImplementation(
          mIID, (IMP)hooked_TTInstallIDManager_installID);
      class_addMethod(cls, NSSelectorFromString(@"ec_orig_installID"), origIMP,
                      method_getTypeEncoding(mIID));
      ECLog(@"  ✅ [TTInstallIDManager] Hooked installID");
    }

    // Phase 29: Hook idfv getter (TikTok 用 TTInstallIDManager 缓存 IDFV)
    SEL selIDFV = NSSelectorFromString(@"idfv");
    Method mIDFV = class_getInstanceMethod(cls, selIDFV);
    if (mIDFV) {
      IMP origIMP =
          method_setImplementation(mIDFV, (IMP)hooked_TTInstallIDManager_idfv);
      class_addMethod(cls, NSSelectorFromString(@"ec_orig_idfv"), origIMP,
                      method_getTypeEncoding(mIDFV));
      ECLog(@"  ✅ [TTInstallIDManager] Hooked idfv");
    }
    }

    static void setupMethodSwizzling(void) {
    SCPrefLoader *config = [SCPrefLoader shared];

    // UIDevice hooks — 受 enableUIDeviceHooks 子开关控制
    if ([config spoofBoolForKey:@"enableUIDeviceHooks" defaultValue:YES]) {
      swizzleInstanceMethod([UIDevice class], @selector(systemVersion),
                            @selector(ec_systemVersion));
      swizzleInstanceMethod([UIDevice class], @selector(model),
                            @selector(ec_model));
      swizzleInstanceMethod([UIDevice class], @selector(localizedModel),
                            @selector(ec_localizedModel));
      swizzleInstanceMethod([UIDevice class], @selector(name),
                            @selector(ec_name));
      swizzleInstanceMethod([UIDevice class], @selector(systemName),
                            @selector(ec_systemName));
      ECLog(@"  ✅ UIDevice hooks 已启用");
    } else {
      ECLog(@"  ⚠️ UIDevice hooks 已禁用 (enableUIDeviceHooks=NO)");
    }

    // NSProcessInfo hooks — 确保通过 NSProcessInfo 获取 OS 版本也返回伪装值
    // heimdallr 监控 SDK 就是通过此路径获取 os_version 的
    if ([config spoofBoolForKey:@"enableUIDeviceHooks" defaultValue:YES]) {
      NSString *spoofedVersion = [config spoofValueForKey:@"systemVersion"];
      if (spoofedVersion.length > 0) {
        // Hook operatingSystemVersionString
        SEL versionStringSel = @selector(operatingSystemVersionString);
        Method versionStringMethod =
            class_getInstanceMethod([NSProcessInfo class], versionStringSel);
        if (versionStringMethod) {
          typedef NSString *(*VersionStringIMP)(id, SEL);
          __block VersionStringIMP origVersionString =
              (VersionStringIMP)method_getImplementation(versionStringMethod);
          IMP newVersionStringIMP =
              imp_implementationWithBlock(^NSString *(id self_) {
                SCPrefLoader *cfg = [SCPrefLoader shared];
                NSString *sv = [cfg spoofValueForKey:@"systemVersion"];
                if (sv.length > 0) {
                  return [NSString stringWithFormat:@"Version %@", sv];
                }
                return origVersionString(self_, versionStringSel);
              });
          method_setImplementation(versionStringMethod, newVersionStringIMP);
        }

        // Hook operatingSystemVersion (返回 NSOperatingSystemVersion 结构体)
        SEL osVerSel = @selector(operatingSystemVersion);
        Method osVerMethod =
            class_getInstanceMethod([NSProcessInfo class], osVerSel);
        if (osVerMethod) {
          typedef NSOperatingSystemVersion (*OSVerIMP)(id, SEL);
          __block OSVerIMP origOSVer =
              (OSVerIMP)method_getImplementation(osVerMethod);
          IMP newOSVerIMP =
              imp_implementationWithBlock(^NSOperatingSystemVersion(id self_) {
                SCPrefLoader *cfg = [SCPrefLoader shared];
                NSString *sv = [cfg spoofValueForKey:@"systemVersion"];
                if (sv.length > 0) {
                  NSArray *parts = [sv componentsSeparatedByString:@"."];
                  NSOperatingSystemVersion ver;
                  ver.majorVersion =
                      parts.count > 0 ? [parts[0] integerValue] : 16;
                  ver.minorVersion =
                      parts.count > 1 ? [parts[1] integerValue] : 0;
                  ver.patchVersion =
                      parts.count > 2 ? [parts[2] integerValue] : 0;
                  return ver;
                }
                return origOSVer(self_, osVerSel);
              });
          method_setImplementation(osVerMethod, newOSVerIMP);
        }
        ECLog(@"  ✅ NSProcessInfo OS version hooks 已启用 → %@",
              spoofedVersion);
      }
    }

    // IDFV Hook — 受 enableIDFVHook 子开关控制（建议始终开启）
    if ([config spoofBoolForKey:@"enableIDFVHook" defaultValue:YES]) {
      swizzleInstanceMethod([UIDevice class], @selector(identifierForVendor),
                            @selector(ec_identifierForVendor));
      ECLog(@"  ✅ IDFV hook 已启用");
    } else {
      ECLog(@"  ⚠️ IDFV hook 已禁用 (enableIDFVHook=NO)");
    }

    // UIScreen hooks — 受 enableUIScreenHooks 子开关控制
    if ([config spoofBoolForKey:@"enableUIScreenHooks" defaultValue:YES]) {
      swizzleInstanceMethod([UIScreen class], @selector(bounds),
                            @selector(ec_bounds));
      swizzleInstanceMethod([UIScreen class], @selector(scale),
                            @selector(ec_scale));
      swizzleInstanceMethod([UIScreen class], @selector(nativeBounds),
                            @selector(ec_nativeBounds));
      swizzleInstanceMethod([UIScreen class], @selector(maximumFramesPerSecond),
                            @selector(ec_maximumFramesPerSecond));
      ECLog(@"  ✅ UIScreen hooks 已启用");
    } else {
      ECLog(@"  ⚠️ UIScreen hooks 已禁用 (enableUIScreenHooks=NO)");
    }

    /* [DISABLED] NSLocale 实例方法 Hook - 跨类 swizzle 导致无限递归
    // 问题分析：
    // 1. ec_locale_objectForKey: 定义在 NSLocale category 中
    // 2. 当 swizzle __NSCFLocale 时，IMP 交换发生，但回调 [self
    ec_locale_objectForKey:]
    //    会尝试查找 __NSCFLocale 的原始实现，而它实际存储的是 NSLocale
    基类的实现
    // 3. 这导致无限递归或 IMP 查找失败
    //
    // 解决方案：通过其他方式实现语言伪装：
    // - +[NSLocale preferredLanguages] (类方法，已启用)
    // - -[NSUserDefaults objectForKey:] AppleLanguages (已启用)
    // - -[NSBundle preferredLocalizations] (已启用)
    // swizzleInstanceMethod([NSLocale class], @selector(objectForKey:),
    //                      @selector(ec_locale_objectForKey:));
    //                      @selector(ec_languageCode));
    //                      swizzleInstanceMethod([NSLocale class],
    //                                            @selector(currencyCode),
    //                                            @selector(ec_currencyCode));
    //                      ECLog(@" Swizzled: NSLocale instance methods");
    //
    //                      Class nscfLocaleClass =
    //                          NSClassFromString(@"__NSCFLocale");
    //                      if (nscfLocaleClass) {
    //                        ECLog(@" Swizzling __NSCFLocale directly");
    //                        swizzleInstanceMethod(
    //                            nscfLocaleClass, @selector(objectForKey:),
    //                            @selector(ec_locale_objectForKey:));
    //                        swizzleInstanceMethod(nscfLocaleClass,
    // @selector(localeIdentifier),
    // @selector(ec_localeIdentifier));
    //                        swizzleInstanceMethod(nscfLocaleClass,
    //                                              @selector(countryCode),
    // @selector(ec_countryCode));
    //                        swizzleInstanceMethod(nscfLocaleClass,
    //                                              @selector(languageCode),
    // @selector(ec_languageCode));
    //                        swizzleInstanceMethod(nscfLocaleClass,
    //                                              @selector(currencyCode),
    // @selector(ec_currencyCode));
    //                      }
    */

    /* [DISABLED] NSLocale 动态子类检测 -
    导致崩溃（内存耗尽/无限递归）
    // 问题：Swizzle 多个类后可能导致递归调用或内存问题
    id currentLocale = [NSLocale currentLocale];
    Class currentLocaleClass = [currentLocale class];
    if (currentLocaleClass && currentLocaleClass !=
    [NSLocale class]) { ECLog(@" Detected NSLocale
    subclass: %@",
            NSStringFromClass(currentLocaleClass));
      swizzleInstanceMethod(currentLocaleClass,
    @selector(objectForKey:),
                            @selector(ec_locale_objectForKey:));
      swizzleInstanceMethod(currentLocaleClass,
    @selector(localeIdentifier),
                            @selector(ec_localeIdentifier));
      swizzleInstanceMethod(currentLocaleClass,
    @selector(countryCode),
                            @selector(ec_countryCode));
      swizzleInstanceMethod(currentLocaleClass,
    @selector(languageCode),
                            @selector(ec_languageCode));
      swizzleInstanceMethod(currentLocaleClass,
    @selector(currencyCode),
                            @selector(ec_currencyCode));
    }

    id systemLocale = [NSLocale systemLocale];
    Class systemLocaleClass = [systemLocale class];
    if (systemLocaleClass && systemLocaleClass !=
    currentLocaleClass && systemLocaleClass != [NSLocale
    class]) { ECLog(@" Detected system NSLocale
    subclass: %@",
            NSStringFromClass(systemLocaleClass));
      swizzleInstanceMethod(systemLocaleClass,
    @selector(objectForKey:),
                            @selector(ec_locale_objectForKey:));
      swizzleInstanceMethod(systemLocaleClass,
    @selector(localeIdentifier),
                            @selector(ec_localeIdentifier));
      swizzleInstanceMethod(systemLocaleClass,
    @selector(countryCode),
                            @selector(ec_countryCode));
      swizzleInstanceMethod(systemLocaleClass,
    @selector(languageCode),
                            @selector(ec_languageCode));
      swizzleInstanceMethod(systemLocaleClass,
    @selector(currencyCode),
                            @selector(ec_currencyCode));
    }

    id autoLocale = [NSLocale
    autoupdatingCurrentLocale]; Class autoLocaleClass =
    [autoLocale class]; if (autoLocaleClass &&
    autoLocaleClass != currentLocaleClass &&
        autoLocaleClass != systemLocaleClass &&
        autoLocaleClass != [NSLocale class]) {
      ECLog(@" Detected autoupdating NSLocale subclass:
    %@", NSStringFromClass(autoLocaleClass));
      swizzleInstanceMethod(autoLocaleClass,
    @selector(objectForKey:),
                            @selector(ec_locale_objectForKey:));
      swizzleInstanceMethod(autoLocaleClass,
    @selector(localeIdentifier),
                            @selector(ec_localeIdentifier));
      swizzleInstanceMethod(autoLocaleClass,
    @selector(countryCode),
                            @selector(ec_countryCode));
      swizzleInstanceMethod(autoLocaleClass,
    @selector(languageCode),
                            @selector(ec_languageCode));
      swizzleInstanceMethod(autoLocaleClass,
    @selector(currencyCode),
                            @selector(ec_currencyCode));
    }

    Class nscfLocaleClass =
    NSClassFromString(EC_CLS_NSCFLocale); if
    (nscfLocaleClass && nscfLocaleClass !=
    currentLocaleClass && nscfLocaleClass !=
    systemLocaleClass && nscfLocaleClass !=
    autoLocaleClass) { ECLog(@" Explicitly swizzling
    __NSCFLocale");
      swizzleInstanceMethod(nscfLocaleClass,
    @selector(objectForKey:),
                            @selector(ec_locale_objectForKey:));
      swizzleInstanceMethod(nscfLocaleClass,
    @selector(localeIdentifier),
                            @selector(ec_localeIdentifier));
      swizzleInstanceMethod(nscfLocaleClass,
    @selector(countryCode),
                            @selector(ec_countryCode));
      swizzleInstanceMethod(nscfLocaleClass,
    @selector(languageCode),
                            @selector(ec_languageCode));
      swizzleInstanceMethod(nscfLocaleClass,
    @selector(currencyCode),
                            @selector(ec_currencyCode));
    }
    */

    // ⚠️ 语言相关 Hook 已移至独立函数
    // setupLanguageSwizzling()， 不再受
    // enableMethodSwizzling
    // 开关控制，确保语言伪装始终生效

    // [TESTING] NSTimeZone hooks (class method)
    /*
    Method origLocal = class_getClassMethod([NSTimeZone
    class],
    @selector(localTimeZone)); Method newLocal =
    class_getClassMethod([NSTimeZone class],
    @selector(ec_localTimeZone)); if (origLocal &&
    newLocal) method_exchangeImplementations(origLocal,
    newLocal);

    Method origDefault =
    class_getClassMethod([NSTimeZone class],
    @selector(defaultTimeZone)); Method newDefault =
    class_getClassMethod([NSTimeZone class],
    @selector(ec_defaultTimeZone)); if (origDefault &&
    newDefault)
    method_exchangeImplementations(origDefault,
    newDefault);

    Method origSystem = class_getClassMethod([NSTimeZone
    class],
    @selector(systemTimeZone)); Method newSystem =
    class_getClassMethod([NSTimeZone class],
    @selector(ec_systemTimeZone)); if (origSystem &&
    newSystem)
    method_exchangeImplementations(origSystem,
    newSystem);

    Method origReset = class_getClassMethod([NSTimeZone
    class],
    @selector(resetSystemTimeZone)); Method newReset =
    class_getClassMethod([NSTimeZone class],
    @selector(ec_resetSystemTimeZone)); if (origReset &&
    newReset) method_exchangeImplementations(origReset,
    newReset);
    */
    // ⚠️ CTCarrier + IDFA hooks 已移至独立函数
    // setupCarrierHooks() 不再受 enableMethodSwizzling
    // 开关控制，确保运营商/IDFA 伪装始终生效

    // ⚠️ [MOVED] NSBundle 身份伪装 Hook 和 UIApplication canOpenURL Hook
    // 已移至 setupAntiDetectionHooks()，不受 enableMethodSwizzling 开关控制
    // 确保克隆 Bundle ID 伪装始终生效
    }

#import <ifaddrs.h> // 编译器作用域重置（历史遗留结构问题）
#import <net/if_dl.h>

#pragma mark - CFLocale Hooks

    static CFTypeRef (*original_CFLocaleGetValue)(CFLocaleRef locale,
                                                  CFLocaleKey key);
    static CFArrayRef (*original_CFLocaleCopyPreferredLanguages)(void);

    static CFTypeRef hooked_CFLocaleGetValue(CFLocaleRef locale,
                                             CFLocaleKey key) {
    SCPrefLoader *config = [SCPrefLoader shared];

    if (key == kCFLocaleCountryCode) {
      NSString *spoofed = [config spoofValueForKey:@"countryCode"];
      if (spoofed)
        return (__bridge CFTypeRef)spoofed;
    } else if (key == kCFLocaleLanguageCode) {
      NSString *spoofed = [config spoofValueForKey:@"languageCode"];
      if (spoofed)
        return (__bridge CFTypeRef)spoofed;
    } else if (key == kCFLocaleCurrencyCode) {
      NSString *spoofed = [config spoofValueForKey:@"currencyCode"];
      if (spoofed)
        return (__bridge CFTypeRef)spoofed;
    } else if (key == kCFLocaleIdentifier) {
      NSString *spoofed = [config spoofValueForKey:@"localeIdentifier"];
      if (spoofed)
        return (__bridge CFTypeRef)spoofed;
    }

    return original_CFLocaleGetValue(locale, key);
    }

    static CFArrayRef hooked_CFLocaleCopyPreferredLanguages(void) {
    SCPrefLoader *config = [SCPrefLoader shared];

    // 优先使用 preferredLanguage（完整语言标识符）
    NSString *spoofed = [config spoofValueForKey:@"preferredLanguage"];
    if (!spoofed) {
      // 回退到 languageCode 并构建完整标识符
      NSString *langCode = [config spoofValueForKey:@"languageCode"];
      NSString *countryCode = [config spoofValueForKey:@"countryCode"];

      if (langCode) {
        // 检查 languageCode 是否已经包含脚本后缀（如 zh-Hans）
        BOOL hasScript = [langCode containsString:@"-"];

        if (countryCode) {
          if (hasScript) {
            // 已有脚本后缀: zh-Hans + CN -> zh-Hans-CN
            spoofed =
                [NSString stringWithFormat:@"%@-%@", langCode, countryCode];
          } else if ([langCode isEqualToString:@"zh"]) {
            // 中文特殊处理: zh + CN -> zh-Hans-CN
            spoofed = [NSString stringWithFormat:@"zh-Hans-%@", countryCode];
          } else {
            // 其他语言: en + US -> en-US
            spoofed =
                [NSString stringWithFormat:@"%@-%@", langCode, countryCode];
          }
        } else {
          spoofed = langCode;
        }
      }
    }

    if (spoofed) {
      return (__bridge_retained CFArrayRef) @[ spoofed ];
    }
    return original_CFLocaleCopyPreferredLanguages();
    }

    static CFLocaleRef (*original_CFLocaleCopyCurrent)(void) = NULL;

    static CFLocaleRef hooked_CFLocaleCopyCurrent(void) {
    SCPrefLoader *config = [SCPrefLoader shared];
    NSString *identifier =
        [config spoofValueForKey:@"localeIdentifier"]; // "en_US"
    if (identifier) {
      CFLocaleRef spoofed =
          CFLocaleCreate(kCFAllocatorDefault, (__bridge CFStringRef)identifier);
      if (spoofed)
        return spoofed;
    }
    return original_CFLocaleCopyCurrent();
    }

    static void setupCFLocaleHooks(void) {
    // CFLocale rebind 已合并到 performMergedRebind() 统一调用
    ec_register_rebinding("CFLocaleCopyPreferredLanguages",
                          (void *)hooked_CFLocaleCopyPreferredLanguages,
                          (void **)&original_CFLocaleCopyPreferredLanguages);
    ec_register_rebinding("CFLocaleCopyCurrent",
                          (void *)hooked_CFLocaleCopyCurrent,
                          (void **)&original_CFLocaleCopyCurrent);
    ECLog(@" ✅ CFLocale 已注册 (延迟到 performMergedRebind)");
    }

    // ============================================================================
    // 语言伪装专用 Hook (独立于 enableMethodSwizzling)
    // ============================================================================
    static void setupLanguageSwizzling(void) {
    ECLog(@"🌍 [Language] Setting up language swizzling hooks...");

    // NSLocale class hooks
    Method origPreferredLangs =
        class_getClassMethod([NSLocale class], @selector(preferredLanguages));
    Method newPreferredLangs = class_getClassMethod([NSLocale class], @selector
                                                    (ec_preferredLanguages));
    if (origPreferredLangs && newPreferredLangs) {
      method_exchangeImplementations(origPreferredLangs, newPreferredLangs);
      ECLog(@"  ✅ Swizzled: +[NSLocale preferredLanguages]");
    }

    // +[NSLocale currentLocale] Hook
    Method origCurrentLocale =
        class_getClassMethod([NSLocale class], @selector(currentLocale));
    Method newCurrentLocale =
        class_getClassMethod([NSLocale class], @selector(ec_currentLocale));
    if (origCurrentLocale && newCurrentLocale) {
      method_exchangeImplementations(origCurrentLocale, newCurrentLocale);
      ECLog(@"  ✅ Swizzled: +[NSLocale currentLocale]");
    }

    // +[NSLocale autoupdatingCurrentLocale] Hook
    Method origAutoLocale = class_getClassMethod([NSLocale class], @selector
                                                 (autoupdatingCurrentLocale));
    Method newAutoLocale = class_getClassMethod([NSLocale class], @selector
                                                (ec_autoupdatingCurrentLocale));
    if (origAutoLocale && newAutoLocale) {
      method_exchangeImplementations(origAutoLocale, newAutoLocale);
      ECLog(@"  ✅ Swizzled: +[NSLocale autoupdatingCurrentLocale]");
    }

    // +[NSLocale systemLocale] Hook
    Method origSystemLocale =
        class_getClassMethod([NSLocale class], @selector(systemLocale));
    Method newSystemLocale =
        class_getClassMethod([NSLocale class], @selector(ec_systemLocale));
    if (origSystemLocale && newSystemLocale) {
      method_exchangeImplementations(origSystemLocale, newSystemLocale);
      ECLog(@"  ✅ Swizzled: +[NSLocale systemLocale]");
    }

    // NSBundle preferredLocalizations hook
    swizzleInstanceMethod([NSBundle class], @selector(preferredLocalizations),
                          @selector(ec_preferredLocalizations));
    ECLog(@"  ✅ Swizzled: -[NSBundle preferredLocalizations]");

    // NSUserDefaults objectForKey: hook (AppleLanguages 语言伪装)
    swizzleInstanceMethod([NSUserDefaults class], @selector(objectForKey:),
                          @selector(ec_objectForKey:));
    ECLog(@"  ✅ Swizzled: -[NSUserDefaults objectForKey:] (AppleLanguages)");

    swizzleInstanceMethod([NSUserDefaults class], @selector(setObject:forKey:),
                          @selector(ec_setObject:forKey:));
    ECLog(@"  ✅ Swizzled: -[NSUserDefaults setObject:forKey:] (AppleLanguages "
          @"Protection)");

    swizzleInstanceMethod([NSUserDefaults class],
                          @selector(removeObjectForKey:),
                          @selector(ec_removeObjectForKey:));
    ECLog(@"  ✅ Swizzled: -[NSUserDefaults removeObjectForKey:] "
          @"(AppleLanguages Protection)");

    // [DRM Bypass] 注册 appStoreReceiptURL swizzle
    // 让 TrollStore 侧载的应用拥有合法的 App Store 收据路径
    swizzleInstanceMethod([NSBundle class], @selector(appStoreReceiptURL),
                          @selector(ec_appStoreReceiptURL));
    ECLog(@"  ✅ Swizzled: -[NSBundle appStoreReceiptURL] (DRM Bypass)");

    ECLog(@"🌍 [Language] Language swizzling complete!");
    }

    static void safe_rebind_symbols_for_image(
        const struct mach_header *header,
        intptr_t slide);              // Will be defined later
    static void setupSafeHooks(void); // Will be defined later

#pragma mark - CNCopyCurrentNetworkInfo Hook

    static CFDictionaryRef (*original_CNCopyCurrentNetworkInfo)(
        CFStringRef interfaceName) = NULL;

    static CFDictionaryRef hooked_CNCopyCurrentNetworkInfo(
        CFStringRef interfaceName) {
    // ECLog(@"🔌 [Network] Intercepted CNCopyCurrentNetworkInfo for %@",
    // interfaceName);

    SCPrefLoader *config = [SCPrefLoader shared];
    // 如果没有启用 Wi-Fi 伪装，返回原始值
    // 但为了安全，如果有配置 SSID，直接伪装
    NSString *spoofedSSID = [config spoofValueForKey:@"wifiSSID"];
    NSString *spoofedBSSID = [config spoofValueForKey:@"wifiBSSID"];

    if (spoofedSSID || spoofedBSSID) {
      // ECLog(@"   -> Spoofing SSID: %@, BSSID: %@", spoofedSSID,
      // spoofedBSSID);
      NSMutableDictionary *dict = [NSMutableDictionary dictionary];
      if (spoofedSSID)
        dict[(__bridge NSString *)kCNNetworkInfoKeySSID] = spoofedSSID;
      if (spoofedBSSID)
        dict[(__bridge NSString *)kCNNetworkInfoKeyBSSID] = spoofedBSSID;
      // 添加 SSIDData (可选)
      if (spoofedSSID) {
        dict[(__bridge NSString *)kCNNetworkInfoKeySSIDData] =
            [spoofedSSID dataUsingEncoding:NSUTF8StringEncoding];
      }
      return (__bridge_retained CFDictionaryRef)dict;
    }

    return original_CNCopyCurrentNetworkInfo(interfaceName);
    }

    // 保留原始 setup 函数为空，或者被 setupSafeHooks 替代
    static void setupSysctlHook(void) {
    // 已合并到 setupSafeHooks
    }

    static void setupMobileGestaltHook(void) {
    // 已合并到 setupSafeHooks
    }

    // [已移除] IOKit 诊断 Hook — 日志证明 MSSDK 不通过 IORegistryEntry 获取数据

    // getifaddrs 诊断 Hook — 记录 MAC 地址读取
    static int (*original_getifaddrs)(struct ifaddrs **ifap) = NULL;

    static int hooked_getifaddrs(struct ifaddrs * *ifap) {
    int result = original_getifaddrs(ifap);

    static int ifLogCount = 0;
    ifLogCount++;
    if (result == 0 && ifap && *ifap && ifLogCount <= 10) {
      struct ifaddrs *ifa = *ifap;
      while (ifa) {
        // 只记录 Link Layer 地址（MAC 地址）
        if (ifa->ifa_addr && ifa->ifa_addr->sa_family == AF_LINK) {
          struct sockaddr_dl *sdl = (struct sockaddr_dl *)ifa->ifa_addr;
          if (sdl->sdl_alen == 6) {
            unsigned char *mac = (unsigned char *)LLADDR(sdl);
            ECLog(@"🔬 [MAC-DIAG #%d] iface=%s "
                  @"MAC=%02x:%02x:%02x:%02x:%02x:%02x",
                  ifLogCount, ifa->ifa_name, mac[0], mac[1], mac[2], mac[3],
                  mac[4], mac[5]);
          }
        }
        ifa = ifa->ifa_next;
      }
    }
    return result;
    }

#pragma mark - MobileGestalt Hook

    static CFStringRef (*original_MGCopyAnswer)(CFStringRef key) = NULL;

    static CFStringRef hooked_MGCopyAnswer(CFStringRef key) {
    SCPrefLoader *config = [SCPrefLoader shared];
    NSString *keyStr = (__bridge NSString *)key;
    // ECLog(@"MGCopyAnswer called for key: %@", keyStr); // Verbose log
    NSString *spoofValue = nil;

    if ([keyStr isEqualToString:@"ProductType"]) {
      spoofValue = [config spoofValueForKey:@"machineModel"];
    } else if ([keyStr isEqualToString:@"UserAssignedDeviceName"]) {
      spoofValue = [config spoofValueForKey:@"deviceName"];
    } else if ([keyStr isEqualToString:@"BuildVersion"]) {
      spoofValue = [config spoofValueForKey:@"systemBuildVersion"];
    } else if ([keyStr isEqualToString:@"UniqueDeviceID"]) {
      spoofValue = [config spoofValueForKey:@"udid"];
      if (!spoofValue)
        spoofValue = @"00008030-001A598C0E04802E"; // Default fake UDID
    } else if ([keyStr isEqualToString:@"SerialNumber"]) {
      spoofValue = [config spoofValueForKey:@"serialNumber"];
      if (!spoofValue)
        spoofValue = @"F2LXY0C9j0"; // Default fake Serial
    } else if ([keyStr isEqualToString:@"WifiAddress"]) {
      spoofValue = [config spoofValueForKey:@"wifiAddress"];
      if (!spoofValue)
        spoofValue = @"a4:c3:f0:88:99:aa";
    } else if ([keyStr isEqualToString:@"BluetoothAddress"]) {
      spoofValue = [config spoofValueForKey:@"bluetoothAddress"];
      if (!spoofValue)
        spoofValue = @"a4:c3:f0:88:99:ab";
    }

    if (spoofValue) {
      return (__bridge_retained CFStringRef)spoofValue;
    }
    return original_MGCopyAnswer(key);
    }

  // Duplicate setupMobileGestaltHook removed

#pragma mark - Disk Space Spoofing

    @implementation NSFileManager (ECDiskSpoof)

    -(NSDictionary *)ec_attributesOfFileSystemForPath : (NSString *)path error
        : (NSError **)error {
    NSDictionary *orig = [self ec_attributesOfFileSystemForPath:path
                                                          error:error];
    NSString *diskSize =
        [[SCPrefLoader shared] spoofValueForKey:@"diskSize"];
    if (diskSize && orig) {
      NSMutableDictionary *spoofed = [orig mutableCopy];
      // Parse "256GB" -> bytes
      NSScanner *scanner = [NSScanner scannerWithString:diskSize];
      double gb = 0;
      [scanner scanDouble:&gb];
      if (gb > 0) {
        unsigned long long bytes =
            (unsigned long long)(gb * 1024 * 1024 * 1024);
        spoofed[NSFileSystemSize] = @(bytes);
        // Fake 70% free space
        spoofed[NSFileSystemFreeSize] = @((unsigned long long)(bytes * 0.7));
        // ECLog(@"💾 [DiskSpoof] Spoofed disk size to %.0fGB", gb);
        return spoofed;
      }
    }
    return orig;
    }

    @end

#pragma mark - Battery Spoofing

    @implementation UIDevice (_pwrMgmt)

    -(float)ec_batteryLevel {
    // 从配置读取电池电量（格式: "98%" → 0.98）
    NSString *val =
        [[SCPrefLoader shared] spoofValueForKey:@"batteryCapacity"];
    if (val.length > 0) {
      NSScanner *scanner = [NSScanner scannerWithString:val];
      double pct = 0;
      [scanner scanDouble:&pct];
      if (pct > 1.0)
        pct = pct / 100.0; // "98%" → 0.98, "0.98" → 0.98
      if (pct > 0 && pct <= 1.0)
        return (float)pct;
    }
    // 默认 97-100%
    return 0.97f + (arc4random_uniform(4) / 100.0f);
    }

    -(UIDeviceBatteryState)ec_batteryState {
    // Return unplugged state to appear as normal usage
    return UIDeviceBatteryStateUnplugged;
    }

    @end

    static void setupDiskAndBatteryHooks(void) {
    ECLog(@"💾 Setting up Disk, Battery and Jailbreak spoofing hooks...");

    // Disk space spoofing
    swizzleInstanceMethod([NSFileManager class],
                          @selector(attributesOfFileSystemForPath:error:),
                          @selector(ec_attributesOfFileSystemForPath:error:));
    ECLog(@"  ✅ Swizzled: -[NSFileManager "
          @"attributesOfFileSystemForPath:error:]");

    // Battery level spoofing
    swizzleInstanceMethod([UIDevice class], @selector(batteryLevel),
                          @selector(ec_batteryLevel));
    ECLog(@"  ✅ Swizzled: -[UIDevice batteryLevel]");

    // Battery state spoofing
    swizzleInstanceMethod([UIDevice class], @selector(batteryState),
                          @selector(ec_batteryState));
    ECLog(@"  ✅ Swizzled: -[UIDevice batteryState]");

    // btd_isJailBroken 已在 setupTikTokHooks Phase 6 中通过 method_setImplementation 处理
    }

    
#pragma mark - UIPasteboard Isolation
@interface UIPasteboard (ec_Isolation)
+ (UIPasteboard *)ec_pasteboardWithName:(NSString *)pasteboardName create:(BOOL)create;
+ (UIPasteboard *)ec_generalPasteboard;
@end

@implementation UIPasteboard (ec_Isolation)
+ (UIPasteboard *)ec_pasteboardWithName:(NSString *)pasteboardName create:(BOOL)create {
    if (g_isCloneMode && g_FastCloneId) {
        NSString *isolatedName = [NSString stringWithFormat:@"%@_clone_%@", pasteboardName, g_FastCloneId];
        NSLog(@"[ecwg][ECDeviceSpoof] 🛡️ 强制隔离 UIPasteboard: %@ -> %@", pasteboardName, isolatedName);
        return [self ec_pasteboardWithName:isolatedName create:create];
    }
    return [self ec_pasteboardWithName:pasteboardName create:create];
}
+ (UIPasteboard *)ec_generalPasteboard {
    if (g_isCloneMode && g_FastCloneId) {
        NSString *isolatedName = [NSString stringWithFormat:@"general_clone_%@", g_FastCloneId];
        NSLog(@"[ecwg][ECDeviceSpoof] 🛡️ 强制隔离 UIPasteboard general: -> %@", isolatedName);
        // 使用 withName 来获取一个虚假的 general
        return [self ec_pasteboardWithName:isolatedName create:YES];
    }
    return [self ec_generalPasteboard];
}
@end

static void setupDataIsolationHooks(void) {
    // 只有分身才需要数据隔离
    NSString *cloneId = g_FastCloneId;
    if (!g_isCloneMode || !cloneId) {
        ECLog(@" 非分身模式，跳过数据隔离 Hook");
        return;
    }

    ECLog(@" 🔀 分身模式 (Clone ID: %@)，启用数据隔离", cloneId);

    // [v2260] 关键修复：重新启用文件系统 Hook
    // 这是数据隔离的核心！没有这两个 Hook，TikTok 的 MMKV、SQLite、plist
    // 等本地持久化文件会直接从原始沙盒读取旧账号数据，导致分身"共享状态"。
    // 使用 ec_register_rebinding 统一机制，在 performMergedRebind() 中一次性绑定。
    ec_register_rebinding("NSHomeDirectory", (void *)hooked_NSHomeDirectory,
                          (void **)&original_NSHomeDirectory);
    ec_register_rebinding("NSSearchPathForDirectoriesInDomains",
                          (void *)hooked_NSSearchPathForDirectoriesInDomains,
                          (void **)&original_NSSearchPathForDirectoriesInDomains);
    
    // 注册 C API 诊断和劫持钩子
    ec_register_rebinding("getenv", (void *)hooked_getenv, (void **)&original_getenv);
    ec_register_rebinding("open", (void *)hooked_open, (void **)&original_open);
    ec_register_rebinding("stat", (void *)hooked_stat, (void **)&original_stat);
    
    ECLog(@" ✅ 文件系统 Hook 已注册 (NSHomeDirectory + NSSearchPath + getenv + open + stat)");

    // NSFileManager swizzle (App Group 隔离)
    swizzleInstanceMethod(
        [NSFileManager class],
        @selector(containerURLForSecurityApplicationGroupIdentifier:),
        @selector(ec_containerURLForSecurityApplicationGroupIdentifier:));
    ECLog(@" Swizzled: -[NSFileManager "
          @"containerURLForSecurityApplicationGroupIdentifier:]");

    // [DISABLED] standardUserDefaults Hook 已移除
    // 原因: 独立安装的克隆包有独立沙盒，系统默认 plist 天然 per-app 隔离
    // 额外的 suite 重定向反而导致数据分裂（BDInstall 写入的 awe_deviceID
    // 读不到）
    ECLog(@" ℹ️ standardUserDefaults: 使用系统默认 (独立沙盒天然隔离)");
    // [NEW v2256] UIPasteboard Swizzle
    swizzleInstanceMethod(object_getClass((id)[UIPasteboard class]), @selector(pasteboardWithName:create:), @selector(ec_pasteboardWithName:create:));
    swizzleInstanceMethod(object_getClass((id)[UIPasteboard class]), @selector(generalPasteboard), @selector(ec_generalPasteboard));
    ECLog(@" Swizzled: +[UIPasteboard pasteboardWithName/generalPasteboard]");


    // [NEW] initWithSuiteName 隔离 (启用 App Group 数据隔离)
    swizzleInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:),
                          @selector(ec_initWithSuiteName:));
    ECLog(@" Swizzled: -[NSUserDefaults initWithSuiteName:]");

    // 确保分身数据目录存在
    NSString *cloneDataDir = [[SCPrefLoader shared] cloneDataDirectory];
    if (cloneDataDir) {
      NSFileManager *fm = [NSFileManager defaultManager];
      NSArray *subdirs = @[
        @"Documents", @"Library", @"Library/Caches", @"Library/Preferences",
        @"Library/Application Support"
      ];
      for (NSString *subdir in subdirs) {
        NSString *path = [cloneDataDir stringByAppendingPathComponent:subdir];
        if (![fm fileExistsAtPath:path]) {
          [fm createDirectoryAtPath:path
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
        }
      }
      ECLog(@" 分身数据目录已准备: %@", cloneDataDir);
    }
    }

    // ===================================
    // ===================================
    // CFBundleGetIdentifier Fishhook (DISABLED - Build 521)
    // ===================================
    /* Test 36 Failed: No logs observed.
    static CFStringRef (*original_CFBundleGetIdentifier)(CFBundleRef bundle);

    static CFStringRef hooked_CFBundleGetIdentifier(CFBundleRef bundle) {
      if (bundle == CFBundleGetMainBundle()) {
        if (g_spoofConfigLoaded && g_spoofedBundleId) {
          ECLog(@"🔍 [Fishhook] Intercepted CFBundleGetIdentifier for MainBundle
    ->
    %@", g_spoofedBundleId); return (__bridge CFStringRef)g_spoofedBundleId;
        }
      }
      return original_CFBundleGetIdentifier(bundle);
    }

    static void setupCFBundleHooks(void) {
      ECLog(@" 🎣 正在通过 fishhook 拦截 CFBundleGetIdentifier...");
      struct rebinding rebindings[] = {{"CFBundleGetIdentifier", (void
    *)hooked_CFBundleGetIdentifier, (void **)&original_CFBundleGetIdentifier}};
      rebind_symbols(rebindings, 1);
    }
    */

    // ===================================
    // CFBundle C-API Fishhook (Test 39)
    // ===================================

    static const void *(*original_CFBundleGetValueForInfoDictionaryKey)(
        CFBundleRef bundle, CFStringRef key);

    static const void *hooked_CFBundleGetValueForInfoDictionaryKey(
        CFBundleRef bundle, CFStringRef key) {
    // 1. 检查是否为 Main Bundle
    if (bundle == CFBundleGetMainBundle()) {
      // 2. 检查 Key 是否为 CFBundleIdentifier
      // kCFBundleIdentifierKey 是 CFStringRef 常量
      if (key && CFStringCompare(key, kCFBundleIdentifierKey, 0) ==
                     kCFCompareEqualTo) {
        if (g_spoofConfigLoaded && g_spoofedBundleId) {
          ECLog(@"🔍 [Fishhook] Intercepted "
                @"CFBundleGetValueForInfoDictionaryKey: %@",
                g_spoofedBundleId);
          return (__bridge const void *)g_spoofedBundleId;
        }
      }
    }
    return original_CFBundleGetValueForInfoDictionaryKey(bundle, key);
    }

    static void setupCFBundleFishhook(void) {
    // CFBundle rebind 已合并到 performMergedRebind() 统一调用
    ec_register_rebinding(
        "CFBundleGetValueForInfoDictionaryKey",
        (void *)hooked_CFBundleGetValueForInfoDictionaryKey,
        (void **)&original_CFBundleGetValueForInfoDictionaryKey);
    ECLog(@"✅ [Fishhook] CFBundleGetValueForInfoDictionaryKey 已注册 (延迟到 "
          @"performMergedRebind)");
    }

    // ============================================================================
    // [REFACTOR] Method Swizzling 实现 - 替代 ISA Swizzling
    // 使用 method_exchangeImplementations 直接 swizzle NSBundle 方法
    // 优势: 不改变类指针，object_getClass() 返回原始 NSBundle 类
    // ============================================================================

    // 只保留 bundleIdentifier 的 IMP 存储
    static IMP s_originalBundleIdentifierIMP = NULL;

    // Swizzled bundleIdentifier - 仅此一个 Hook 生效
    static NSString *ec_swizzled_bundleIdentifier(id self, SEL _cmd) {
    // 仅对 mainBundle 生效
    if (self == [NSBundle mainBundle] && g_spoofConfigLoaded &&
        g_spoofedBundleId) {
      // ECLog(@"🔍 [MethodSwizzle] bundleIdentifier -> %@",
      // g_spoofedBundleId);
      return g_spoofedBundleId;
    }
    // 调用原始实现
    return ((NSString * (*)(id, SEL)) s_originalBundleIdentifierIMP)(self,
                                                                     _cmd);
    }

    static void setupBundleMethodSwizzling(void) {
    ECLog(@"🔧 [MethodSwizzle] Setting up NSBundle method swizzling "
          @"(minimal)...");

    Class bundleClass = [NSBundle class];

    // 1. Swizzle bundleIdentifier - 核心伪装
    {
      Method original =
          class_getInstanceMethod(bundleClass, @selector(bundleIdentifier));
      if (original) {
        s_originalBundleIdentifierIMP = method_getImplementation(original);
        method_setImplementation(original, (IMP)ec_swizzled_bundleIdentifier);
        ECLog(@"  ✅ bundleIdentifier swizzled");
      }
    }

    // [FIX] infoDictionary Hook 已移除
    // 原因: 即使只修改 CFBundleIdentifier，TikTok 仍能检测到字典被篡改
    // bundleIdentifier + CFBundleFishhook 已足够完成包名伪装

    ECLog(@"✅ [MethodSwizzle] NSBundle swizzling complete (bundleIdentifier "
          @"only)!");
    }

    // [DEPRECATED] 保留旧函数名以保持兼容性，内部调用新实现
    static void setupISASwizzling(void) {
    setupBundleMethodSwizzling(); }

    // Phase 26: Keychain Cleaner
    // 当 Device ID 缺失时，主动清理 Keychain 以强制 SDK 重新注册
    static void cleanKeychainIfNeeded(void) {
    NSString *did = ecLoadPersistentID(@"deviceId");
    if (did.length > 0) {
      ECLog(@"✅ [Keychain] DeviceID exists (%@), skipping cleanup.", did);
      return;
    }

    ECLog(@"🧹 [Keychain] DeviceID missing! Cleaning Keychain to force new "
          @"install...");

    // 1. Delete Generic Password items for this app's bundle seed
    NSDictionary *query = @{
      (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitAll
    };

    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    if (status == errSecSuccess || status == errSecItemNotFound) {
      ECLog(@"   ✅ Generic Password items cleared (Status: %d)", (int)status);
    } else {
      ECLog(@"   ⚠️ Failed to clear Generic Password items (Status: %d)",
            (int)status);
    }

    // 2. Target specific ByteDance keys (just in case they are Internet
    // Password items)
    NSArray *targetServices = @[
      @"com.bytedance.device.id", @"com.ss.iphone.ugc.aweme.device_id",
      @"com.bytedance.pass.token", @"com.ss.iphone.ugc.aweme"
    ];

    for (NSString *svc in targetServices) {
      NSDictionary *specQuery = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : svc
      };
      SecItemDelete((__bridge CFDictionaryRef)specQuery);
      ECLog(@"   🧹 Attempted delete for service: %@", svc);
    }

    ECLog(@"✨ [Keychain] Cleanup complete. SDK should treat this as a fresh "
          @"install.");
    }

    // ================================================================
    // 真实设备信息捕获 (必须在任何 Hook 安装前调用)
    // ================================================================
    static void captureRealDeviceInfo(void) {
      struct utsname si;
      uname(&si);
      g_realMachineModel = [NSString stringWithCString:si.machine encoding:NSUTF8StringEncoding];
      g_realSystemVersion = [UIDevice currentDevice].systemVersion;
      g_realDeviceModel = [UIDevice currentDevice].model;
      g_realDeviceName = [UIDevice currentDevice].name;

      CGRect bounds = [UIScreen mainScreen].bounds;
      g_realScreenWidth = bounds.size.width;
      g_realScreenHeight = bounds.size.height;
      g_realScreenScale = [UIScreen mainScreen].scale;
      CGRect nb = [UIScreen mainScreen].nativeBounds;
      g_realNativeWidth = nb.size.width;
      g_realNativeHeight = nb.size.height;
      g_realMaxFPS = [UIScreen mainScreen].maximumFramesPerSecond;

      NSLocale *locale = [NSLocale currentLocale];
      g_realLocaleId = [locale localeIdentifier];
      g_realLanguageCode = [locale objectForKey:NSLocaleLanguageCode];
      g_realCountryCode = [locale objectForKey:NSLocaleCountryCode];
      g_realCurrencyCode = [locale objectForKey:NSLocaleCurrencyCode];
      g_realTimezone = [NSTimeZone localTimeZone].name;
      g_realPreferredLang = [NSLocale preferredLanguages].firstObject;
    }

    // ================================================================
    // 综合诊断日志：真实信息 vs 伪装信息 全量对比
    // ================================================================
    static void printComprehensiveDiagnostics(void) {
      SCPrefLoader *config = [SCPrefLoader shared];

      ECLog(@"");
      ECLog(@"╔══════════════════════════════════════════════════════╗");
      ECLog(@"║          📋 设备真实信息 (Hook 前原始值)             ║");
      ECLog(@"╚══════════════════════════════════════════════════════╝");
      ECLog(@"  hw.machine:        %@", g_realMachineModel);
      ECLog(@"  systemVersion:     %@", g_realSystemVersion);
      ECLog(@"  deviceModel:       %@", g_realDeviceModel);
      ECLog(@"  deviceName:        %@", g_realDeviceName);
      ECLog(@"  screenBounds:      %.0fx%.0f @%.1fx", g_realScreenWidth, g_realScreenHeight, g_realScreenScale);
      ECLog(@"  nativeBounds:      %.0fx%.0f", g_realNativeWidth, g_realNativeHeight);
      ECLog(@"  maxFPS:            %ld", (long)g_realMaxFPS);
      ECLog(@"  localeIdentifier:  %@", g_realLocaleId);
      ECLog(@"  languageCode:      %@", g_realLanguageCode);
      ECLog(@"  countryCode:       %@", g_realCountryCode);
      ECLog(@"  currencyCode:      %@", g_realCurrencyCode);
      ECLog(@"  timezone:          %@", g_realTimezone);
      ECLog(@"  preferredLang:     %@", g_realPreferredLang);
      ECLog(@"  bundleId:          %@", [[NSBundle mainBundle] bundleIdentifier]);

      ECLog(@"");
      ECLog(@"╔══════════════════════════════════════════════════════╗");
      ECLog(@"║          🎭 伪装后信息 (Config 配置值)              ║");
      ECLog(@"╚══════════════════════════════════════════════════════╝");

      // 全量 key 列表 — 覆盖所有已知和可能遗漏的伪装项
      NSArray *allKeys = @[
        // 设备型号
        @"machineModel", @"deviceModel", @"deviceName", @"productName",
        // 系统版本
        @"systemVersion", @"systemBuildVersion", @"kernelVersion", @"systemName",
        // 屏幕
        @"screenWidth", @"screenHeight", @"screenScale", @"nativeBounds", @"maxFPS",
        // 区域
        @"countryCode", @"localeIdentifier", @"timezone", @"currencyCode",
        @"storeRegion", @"priorityRegion",
        // 语言
        @"languageCode", @"preferredLanguage", @"systemLanguage", @"btdCurrentLanguage",
        // 运营商
        @"carrierName", @"mobileCountryCode", @"mobileNetworkCode", @"carrierCountry",
        // 网络
        @"networkType", @"enableNetworkInterception", @"disableQUIC",
        // 标识符
        @"deviceId", @"installId", @"idfv", @"openudid",
      ];

      for (NSString *key in allKeys) {
        NSString *val = [config spoofValueForKey:key];
        ECLog(@"  %-24s %@", [key UTF8String], val ?: @"⚠️ (未配置)");
      }

      // 额外检查：BundleID 伪装
      ECLog(@"  %-24s %@", "[bundleId-spoofed]", g_spoofedBundleId ?: @"⚠️ (未配置)");
      ECLog(@"  %-24s %@", "[cachedIDFV]", g_cachedIDFV ?: @"(待分配)");
      ECLog(@"  %-24s %@", "[cachedDeviceID]", g_cachedDeviceID ?: @"(待服务端分配)");
      ECLog(@"  %-24s %@", "[cachedInstallID]", g_cachedInstallID ?: @"(待服务端分配)");

      // 屏幕一致性检查
      NSString *sw = [config spoofValueForKey:@"screenWidth"];
      NSString *sh = [config spoofValueForKey:@"screenHeight"];
      NSString *ss = [config spoofValueForKey:@"screenScale"];
      ECLog(@"");
      if (sw && sh) {
        CGFloat spoofW = [sw floatValue];
        CGFloat spoofH = [sh floatValue];
        CGFloat spoofS = ss ? [ss floatValue] : g_realScreenScale;
        BOOL widthMatch = fabs(spoofW - g_realScreenWidth) < 1.0;
        BOOL heightMatch = fabs(spoofH - g_realScreenHeight) < 1.0;
        BOOL scaleMatch = fabs(spoofS - g_realScreenScale) < 0.1;

        if (!widthMatch || !heightMatch || !scaleMatch) {
          ECLog(@"╔══════════════════════════════════════════════════════════╗");
          ECLog(@"║  🔴 [CRITICAL] 屏幕尺寸不一致 — 设备指纹矛盾           ║");
          ECLog(@"╚══════════════════════════════════════════════════════════╝");
          ECLog(@"  真实屏幕: %.0f x %.0f @%.1fx (native: %.0fx%.0f)",
                g_realScreenWidth, g_realScreenHeight, g_realScreenScale,
                g_realNativeWidth, g_realNativeHeight);
          ECLog(@"  伪装屏幕: %.0f x %.0f @%.1fx (native: %@)",
                spoofW, spoofH, spoofS,
                [config spoofValueForKey:@"nativeBounds"] ?: @"?");
          ECLog(@"  宽度比: %.3f  高度比: %.3f",
                spoofW / g_realScreenWidth, spoofH / g_realScreenHeight);
          ECLog(@"  ❗ 影响 [1]: 滑块验证码坐标系错位 — 验证码必定失败");
          ECLog(@"  ❗ 影响 [2]: TikTok 设备指纹矛盾 — 可能导致商城(Shop)不显示");
          ECLog(@"  💡 修复建议: 在 ECMAIN 中选择与真实屏幕一致的机型");
          ECLog(@"             iPhone 7 (375x667) → 选 iPhone SE 3 (iPhone14,6)");
        } else {
          ECLog(@"  ✅ 屏幕参数一致: 真实=%.0fx%.0f 伪装=%.0fx%.0f — 触摸坐标安全",
                g_realScreenWidth, g_realScreenHeight, spoofW, spoofH);
        }
      } else {
        ECLog(@"  ⚠️ screenWidth/screenHeight 未在配置中设置，使用真实屏幕值");
      }
      ECLog(@"");
    }

    void ECDeviceSpoofInitialize(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      // 🛡️ 最先安装：TikTok 类型错乱崩溃防护
      // 必须在任何 TikTok SDK 初始化之前部署
      installTikTokCrashGuards();

      ECLog(@"====================================");
      ECLog(@"ECDeviceSpoof 初始化中... (Build: Debug)");
      ECLog(@"====================================");

      // Phase 30 Fix B: 先加载配置，再做 ID 注入
      // 这样 injectSpoofedIDs 内部的 spoofValueForKey 能读到配置值
      SCPrefLoader *config = [SCPrefLoader shared];

      // 打印配置加载详情
      ECLog(@" 📂 配置文件路径: %@", [config configPath]);
      ECLog(@" 📊 配置状态: enabled=%@", [config isEnabled] ? @"YES" : @"NO");

      if ([config isEnabled]) {
        ECLog(@"配置已加载，共 %lu 项", (unsigned long)config.config.count);

        // 打印关键 ID 配置项（用于验证配置一致性）
        ECLog(@" 🔑 关键 ID 配置:");
        ECLog(@"   - deviceId: %@",
              [config spoofValueForKey:@"deviceId"] ?: @"(无)");
        ECLog(@"   - installId: %@",
              [config spoofValueForKey:@"installId"] ?: @"(无)");
        ECLog(@"   - idfv: %@", [config spoofValueForKey:@"idfv"] ?: @"(无)");
        ECLog(@"   - openudid: %@",
              [config spoofValueForKey:@"openudid"] ?: @"(无)");
        ECLog(@"   - systemVersion: %@",
              [config spoofValueForKey:@"systemVersion"] ?: @"(无)");
        ECLog(@"   - deviceModel: %@",
              [config spoofValueForKey:@"deviceModel"] ?: @"(无)");
      }

      // Phase 27.1: 配置加载后进行 ID 注入
      // 生成/加载 OpenUDID、IDFV 隔离值并缓存到 g_cached* 全局变量
      // device_id/install_id 不本地生成，由 BDInstall 服务端注册获取
      injectSpoofedIDs();

      // Phase 27.2: Linkage Spoofing Hooks
      // Hook TTInstallIDManager（deviceID/installID/openUDID/idfv getter）
      setupTTInstallIDManagerHooks();
      ECLog(@"✅ [Init] 标识符 Hook 已启用 (IDFV/OpenUDID/deviceID/installID)");

      // [DEBUG MODE] 开启：设备信息伪造
      ECLog(@" 🧪 调试模式：开启设备信息伪造 (UIDevice/sysctl/MG)");

      // [ENABLED] 设备信息伪造
      if ([config isEnabled]) {

        // 打印语言配置
        ECLog(@" 🌍 语言配置:");
        ECLog(@"   - languageCode: %@",
              [config spoofValueForKey:@"languageCode"] ?: @"(无)");
        ECLog(@"   - countryCode: %@",
              [config spoofValueForKey:@"countryCode"] ?: @"(无)");
        ECLog(@"   - localeIdentifier: %@",
              [config spoofValueForKey:@"localeIdentifier"] ?: @"(无)");
        ECLog(@"   - timezone: %@",
              [config spoofValueForKey:@"timezone"] ?: @"(无)");
        ECLog(@"   - preferredLanguage: %@",
              [config spoofValueForKey:@"preferredLanguage"] ?: @"(无)");

        // ═══ 设备伪装一致性说明 ═══
        // TikTok
        // 通过多源交叉验证（sysctl/UIDevice/MobileGestalt/NSProcessInfo）
        // 计算设备指纹 hash。各开关默认全部
        // YES，确保所有层面返回一致的伪装数据。
        // 如需排查问题可单独关闭某个开关，但要注意数据一致性。

        // [1] 网络拦截
        if ([config spoofBoolForKey:@"enableNetworkInterception"
                       defaultValue:YES]) {
          setupNetworkInterception();
        } else {
          ECLog(@"⚠️ FeatureFlag: Network Interception DISABLED");
        }

        // [DIAG] 在所有 Hook 安装前捕获真实设备信息
        captureRealDeviceInfo();
        ECLog(@"📋 真实设备信息已缓存 (hw.machine=%@ screen=%.0fx%.0f @%.1fx)",
              g_realMachineModel, g_realScreenWidth, g_realScreenHeight, g_realScreenScale);

        // [2] Method Swizzling (UIDevice/UIScreen/IDFV)
        if ([config spoofBoolForKey:@"enableMethodSwizzling"
                       defaultValue:YES]) {
          setupMethodSwizzling();
        } else {
          ECLog(@"⚠️ FeatureFlag: Method Swizzling DISABLED");
        }

        // [2] __NSCFLocale 直接 Hook (使用显式 IMP 存储，安全方式)
        if ([config spoofBoolForKey:@"enableNSCFLocaleHooks"
                       defaultValue:YES]) {
          setupNSCFLocaleHooks();
        } else {
          ECLog(@"⚠️ FeatureFlag: __NSCFLocale Hooks DISABLED");
        }

        // [CRITICAL] CFLocaleCopyPreferredLanguages C Hook + 语言 Swizzling
        if ([config spoofBoolForKey:@"enableCFLocaleHooks" defaultValue:YES]) {
          setupCFLocaleHooks();
        } else {
          ECLog(@"⚠️ FeatureFlag: CFLocale Hooks DISABLED");
        }

        // [5] 语言伪装 Hook (NSLocale/NSBundle/NSUserDefaults/NSTimeZone)
        // 跟随 enableCFLocaleHooks 开关（与 CFLocale C 层 Hook 联动）
        if ([config spoofBoolForKey:@"enableCFLocaleHooks" defaultValue:YES]) {
          setupLanguageSwizzling();
        } else {
          ECLog(@"⚠️ FeatureFlag: Language Swizzling DISABLED");
        }

        // [CRITICAL] 运营商/IDFA 伪装 (CTCarrier)
        // 自动检测：当配置中设置了运营商名称时自动启用
        BOOL carrierConfigured =
            [config spoofValueForKey:@"carrierName"] != nil;
        if ([config spoofBoolForKey:@"enableMethodSwizzling"
                       defaultValue:YES] &&
            (carrierConfigured || [config spoofBoolForKey:@"enableCarrierHooks"
                                             defaultValue:NO])) {
          setupCarrierHooks();
          ECLog(@"✅ CTCarrier Hook 已启用 (carrierConfigured=%d)",
                carrierConfigured);
        } else {
          ECLog(@"⚠️ CTCarrier Hook 未启用 (未配置运营商信息)");
        }

        // [3] TikTok 专用 Hook (AWE/ByteDance 自定义 API)
        if ([config spoofBoolForKey:@"enableTikTokHooks" defaultValue:YES]) {
          setupTikTokHooks();
        } else {
          ECLog(@"⚠️ FeatureFlag: TikTok Hooks DISABLED");
        }

        // [8] sysctl Hook (sysctlbyname/uname)
        if ([config spoofBoolForKey:@"enableSysctlHooks" defaultValue:YES]) {
          setupSysctlHook();
        } else {
          ECLog(@"⚠️ FeatureFlag: Sysctl Hooks DISABLED");
        }

        // [9] MobileGestalt Hook (硬件指纹)
        if ([config spoofBoolForKey:@"enableMobileGestaltHooks"
                       defaultValue:YES]) {
          setupMobileGestaltHook();
        } else {
          ECLog(@"⚠️ FeatureFlag: MobileGestalt Hooks DISABLED");
        }

        // [4] CFBundle C-API Hook (Test 39)
        if ([config spoofBoolForKey:@"enableCFBundleFishhook"
                       defaultValue:YES]) {
          setupCFBundleFishhook();
        } else {
          ECLog(@"⚠️ FeatureFlag: CFBundle Fishhook DISABLED");
        }

        // [5] ISA Swizzling Hook (Test 38)
        if ([config spoofBoolForKey:@"enableISASwizzling" defaultValue:YES]) {
          setupISASwizzling();
        } else {
          ECLog(@"⚠️ FeatureFlag: ISA Swizzling DISABLED");
        }

        ECLog(@"✅ 设备伪造初始化完成！(UIDevice + "
              @"CFLocaleCopyPreferredLanguages)");

        // [12] 磁盘空间和电池伪装
        if ([config spoofBoolForKey:@"enableDiskBatteryHooks"
                       defaultValue:YES]) {
          setupDiskAndBatteryHooks();
        } else {
          ECLog(@"⚠️ FeatureFlag: Disk/Battery Hooks DISABLED");
        }

        // [5] 反检测 Hooks (dyld/access/stat/fopen/getenv)
        if ([config spoofBoolForKey:@"enableAntiDetectionHooks"
                       defaultValue:YES]) {
          setupAntiDetectionHooks();
        } else {
          ECLog(@"⚠️ FeatureFlag: Anti-Detection Hooks DISABLED");
        }

        // [5.5] 安全 Per-Image Hook (dyld 隐藏 + sysctl/MobileGestalt/IOKit)
        // 使用 _dyld_register_func_for_add_image 对每个 app image 单独 rebind
        // 比全局 rebind_symbols 更安全，避免 guard page 崩溃
        setupSafeHooks();

        // [5.6] 脱壳/克隆检测绕过 (Phase 8)
        // cryptid 伪造 + App Store Receipt + Keychain AccessGroup + appStoreReceiptURL
        setupCloneDetectionBypass();

        // [5.7] 深度防护 (Phase 9-13)
        // IMP 越界、bdfishhook、TSPK、DeviceCheck、AppAttest
        setupDeepProtection();

        // [6] Keychain 隔离 (SecItem* APIs)
        // 仅当启用反检测时检查 Keychain 隔离子开关
        if ([config spoofBoolForKey:@"enableAntiDetectionHooks"
                       defaultValue:YES]) {
          if ([config spoofBoolForKey:@"enableKeychainIsolation"
                         defaultValue:YES]) {
            setupKeychainIsolationHooks();
          } else {
            ECLog(@"⚠️ FeatureFlag: Keychain 隔离 DISABLED");
          }
        }

        // [CRITICAL] 统一执行所有延迟注册的 fishhook rebind
        // 必须在所有 setup 函数注册完毕后才能调用！
        // 将原来 6 次分散的 rebind_symbols 合并为 1 次统一遍历
        performMergedRebind();

        // [DIAG] 打印完整的 真实 vs 伪装 对比诊断日志
        printComprehensiveDiagnostics();

      } else {
        ECLog(@"未找到配置文件或配置为空，跳过设备伪造 Hook");
        ECLog(@" ⚠️ 配置内容: %@", config.config ?: @"(nil)");
      }

      // [7] 内存补丁：直接修改 NSBundle 缓存的 infoDictionary
      // 替代 infoDictionary Hook（该 Hook 导致 Watchdog 死锁 0x8badf00d）
      // 原理：NSBundle 内部缓存的字典实际上是 NSMutableDictionary，
      // 启动时直接修改一次即可，无需 Hook，无锁竞争
      if (g_spoofConfigLoaded && g_spoofedBundleId) {
        NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
        if ([info isKindOfClass:[NSMutableDictionary class]]) {
          NSMutableDictionary *mutableInfo = (NSMutableDictionary *)info;
          NSString *origBid = mutableInfo[@"CFBundleIdentifier"];
          mutableInfo[@"CFBundleIdentifier"] = g_spoofedBundleId;
          [mutableInfo removeObjectForKey:@"SignerIdentity"];
          ECLog(@"✅ [MemPatch] infoDictionary 已补丁: %@ -> %@", origBid,
                g_spoofedBundleId);

          // 修复 User-Agent 泄露：去掉 CFBundleDisplayName / CFBundleName
          // 中的克隆编号 例如 "TikTok 1001" → "TikTok"，否则 UA 会暴露克隆号
          NSArray *displayKeys = @[ @"CFBundleDisplayName", @"CFBundleName" ];
          for (NSString *dkey in displayKeys) {
            NSString *displayName = mutableInfo[dkey];
            if (displayName && [displayName containsString:@" "]) {
              NSArray *parts = [displayName componentsSeparatedByString:@" "];
              NSString *lastPart = parts.lastObject;
              // 检查最后一段是否全是数字（即克隆编号）
              NSCharacterSet *nonDigits =
                  [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
              if ([lastPart rangeOfCharacterFromSet:nonDigits].location ==
                      NSNotFound &&
                  lastPart.length > 0) {
                // 去掉克隆编号后缀
                NSMutableArray *cleanParts = [parts mutableCopy];
                [cleanParts removeLastObject];
                NSString *cleanName =
                    [cleanParts componentsJoinedByString:@" "];
                mutableInfo[dkey] = cleanName;
                ECLog(@"✅ [MemPatch] %@ 去克隆号: \"%@\" → \"%@\"", dkey,
                      displayName, cleanName);
              }
            }
          }
        } else {
          ECLog(@"⚠️ [MemPatch] infoDictionary 不是 NSMutableDictionary，"
                @"无法直接补丁 (class: %@)",
                [info class]);
        }
      }

      // [4] 数据隔离
      // (NSHomeDirectory/NSSearchPath/NSFileManager/NSUserDefaults) ⚠️
      // 必须始终启用以支持分身数据隔离，除非完全禁用插件
      // 但如果用户希望完全“纯净”启动，可能需要一个总开关。
      // 目前保留在外面，但仅在检测到 Clone ID 时生效 (内部逻辑)
      setupDataIsolationHooks();

      // ⚠️ 关键: Clone 初始化后重新加载配置
      // 原因: 首次 configPath 调用时 cloneId 还未检测到，从 Bundle
      // 读取了旧配置 此时 cloneId 已确定，cloneDataDirectory
      // 能返回正确的沙盒路径 重新加载可以从 clone 目录的 device.plist
      // 读取用户保存的最新配置
      if (g_isCloneMode) {
        ECLog(@"🔄 [ConfigReload] Clone 初始化完成，重新加载配置...");
        NSString *oldPath = [[SCPrefLoader shared] configPath];
        [[SCPrefLoader shared] reloadConfig];
        NSString *newPath = [[SCPrefLoader shared] configPath];
        ECLog(@"🔄 [ConfigReload] 配置路径: %@", newPath);
        if (![oldPath isEqualToString:newPath]) {
          ECLog(@"✅ [ConfigReload] 配置路径已变更！旧: %@ → 新: %@", oldPath,
                newPath);
        }
        // 打印重新加载后的关键配置值
        ECLog(@"🔄 [ConfigReload] machineModel: %@",
              [[SCPrefLoader shared] spoofValueForKey:@"machineModel"]
                  ?: @"(无)");
        ECLog(@"🔄 [ConfigReload] systemVersion: %@",
              [[SCPrefLoader shared] spoofValueForKey:@"systemVersion"]
                  ?: @"(无)");
        ECLog(@"🔄 [ConfigReload] deviceModel: %@",
              [[SCPrefLoader shared] spoofValueForKey:@"deviceModel"]
                  ?: @"(无)");
      }

      ECLog(@"✅ Hook 初始化流程结束");
    }); // dispatch_once END
    }

#pragma mark - Anti-Detection Hooks

  // 移除被检测的高危 Hook 的原始指针对 (lstat/fopen/getenv/access/stat 已删)

  // ============================================================================
  // [已移除] 文件系统和环境变量的 Blacklist Hook, 以及 getenv Hook
  // 由于会导致 TikTok 的 AAAASingularity 等安全 SDK 检测到 GOT 修改而被风控
  // ============================================================================

#import <mach-o/dyld.h>

    static uint32_t (*original_dyld_image_count)(void) = NULL;
    static const char *(*original_dyld_get_image_name)(uint32_t image_index) =
        NULL;
    static const struct mach_header *(*original_dyld_get_image_header)(
        uint32_t image_index) = NULL;

    static uint32_t g_spoof_dylib_index = UINT32_MAX;

    static uint32_t hooked_dyld_image_count(void) {
    uint32_t count = original_dyld_image_count();
    if (g_spoof_dylib_index != UINT32_MAX && count > g_spoof_dylib_index) {
      return count - 1;
    }
    return count;
    }

    static const char *hooked_dyld_get_image_name(uint32_t image_index) {
    if (g_spoof_dylib_index != UINT32_MAX) {
      if (image_index == g_spoof_dylib_index) {
        // 如果请求的是我们要隐藏的 dylib，返回下一个（或者空，视情况而定）
        // 为了保持连续性，通常我们伪装成列表缩短了一位
        // 这里如果调用者按 count 遍历，不应访问到此 index（因为 count 减 1
        // 了） 但如果它非要访问这个 index，不仅要防崩溃，还要防露馅
        // 策略：返回下一个 dylib 的 name
        return original_dyld_get_image_name(image_index + 1);
      } else if (image_index > g_spoof_dylib_index) {
        return original_dyld_get_image_name(image_index + 1);
      }
    }
    return original_dyld_get_image_name(image_index);
    }

    static const struct mach_header *hooked_dyld_get_image_header(
        uint32_t image_index) {
    if (g_spoof_dylib_index != UINT32_MAX) {
      if (image_index == g_spoof_dylib_index) {
        return original_dyld_get_image_header(image_index + 1);
      } else if (image_index > g_spoof_dylib_index) {
        return original_dyld_get_image_header(image_index + 1);
      }
    }
    return original_dyld_get_image_header(image_index);
    }

    // ★ Hook: _dyld_get_image_vmaddr_slide - 隐藏注入库的内存地址偏移
    static intptr_t (*original_dyld_get_image_vmaddr_slide)(
        uint32_t image_index) = NULL;

    static intptr_t hooked_dyld_get_image_vmaddr_slide(uint32_t image_index) {
    if (g_spoof_dylib_index != UINT32_MAX) {
      if (image_index == g_spoof_dylib_index) {
        // 返回下一个 image 的 slide
        return original_dyld_get_image_vmaddr_slide(image_index + 1);
      } else if (image_index > g_spoof_dylib_index) {
        return original_dyld_get_image_vmaddr_slide(image_index + 1);
      }
    }
    return original_dyld_get_image_vmaddr_slide(image_index);
    }

    // ★ Hook: fork() - 阻止沙盒完整性检测
    // 越狱环境允许 fork()，但正常 App 沙盒禁止 fork
    // 返回 -1 并设置 errno = ENOSYS 可以模拟正常沙盒行为
    static pid_t (*original_fork)(void) = NULL;

    static pid_t hooked_fork(void) {
    // 模拟沙盒环境: fork 不被允许
    errno = ENOSYS; // Function not implemented
    return -1;
    }

    // ★ Hook: vfork() - 同样阻止
    static pid_t (*original_vfork)(void) = NULL;

    static pid_t hooked_vfork(void) {
    errno = ENOSYS;
    return -1;
    }

#import <dlfcn.h>

    static int (*original_dladdr)(const void *, Dl_info *);

    static int hooked_dladdr(const void *addr, Dl_info *info) {
    static _Thread_local BOOL _reentry_guard = NO;
    if (_reentry_guard) {
      return original_dladdr(addr, info);
    }
    _reentry_guard = YES;

    int result = original_dladdr(addr, info);
    if (result != 0 && info->dli_fname) {
      char *_dn1 = EC_CSTR_libswiftDylib;
      if (strstr(info->dli_fname, _dn1) != NULL) {
        // 伪装成 UIKit
        info->dli_fname = "/System/Library/Frameworks/UIKit.framework/UIKit";
      }
    }

    _reentry_guard = NO;
    return result;
    }
#pragma mark - Anti-Debug Specific Hooks

    // [已移除] ptrace 和 sysctl(用于反调试清理 P_TRACED 标志) 的 Hook
    // 由于会导致 TikTok 的 AAAASingularity 等安全 SDK 检测到 GOT 修改而被风控
    // sysctlbyname 保留，用于获取伪装硬件信息 (hw.machine 等)

    // ============================================================================
    // fork() Hook - 已移至 line ~3064 与 vfork 一起定义
    // ============================================================================

    static void setupAntiDetectionHooks(void) {
    SCPrefLoader *config = [SCPrefLoader shared];

    // 1. 找到自身 dylib 的索引 (用于 dylib 隐藏)
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
      const char *name = _dyld_get_image_name(i);
      char *_dn2 = EC_CSTR_libswiftDylib;
      if (name && (strstr(name, _dn2) != NULL)) {
        g_spoof_dylib_index = i;
        ECLog(@" 🛡️ 发现自身 dylib 索引: %u, 启动隐藏模式", i);
        break;
      }
    }

    if (g_spoof_dylib_index == UINT32_MAX) {
      ECLog(@" ⚠️ 未找到自身 dylib 索引，dylib 隐藏 Hook 跳过");
    }

    ECLog(@" ⚠️ dyld 函数 Hook 已禁用 (iOS 15+ 兼容性)");

    // 2-4. 文件系统/环境变量/反调试 Hook 已彻底移除 (防风控)
    ECLog(@"📋 [AntiDetect] 文件系统/环境变量/反调试 高危Hook 已移除");

    // 5. fork()/vfork() Hook — 沙盒完整性
    if ([config spoofBoolForKey:@"enableForkHooks" defaultValue:YES]) {
      // fork/vfork rebind 已合并到 performMergedRebind() 统一调用
      ec_register_rebinding("fork", (void *)hooked_fork,
                            (void **)&original_fork);
      ec_register_rebinding("vfork", (void *)hooked_vfork,
                            (void **)&original_vfork);
      ECLog(@"✅ [AntiDetect] fork/vfork 已注册 (延迟到 performMergedRebind)");
    } else {
      ECLog(@"⚠️ FeatureFlag: fork/vfork Hook DISABLED");
    }

    // 6. NSBundle objectForInfoDictionaryKey: Hook — BundleID 查询伪装
    if ([config spoofBoolForKey:@"enableBundleIDHook" defaultValue:YES]) {
      swizzleInstanceMethod([NSBundle class],
                            @selector(objectForInfoDictionaryKey:),
                            @selector(ec_objectForInfoDictionaryKey:));
      ECLog(@"✅ [AntiDetect] NSBundle objectForInfoDictionaryKey Hook 已启用");
    } else {
      ECLog(@"⚠️ FeatureFlag: BundleID 查询 Hook DISABLED");
    }

    // 7. canOpenURL: Hook — URL Scheme 隐藏
    if ([config spoofBoolForKey:@"enableCanOpenURLHook" defaultValue:YES]) {
      swizzleInstanceMethod([UIApplication class], @selector(canOpenURL:),
                            @selector(ec_canOpenURL:));
      ECLog(@"✅ [AntiDetect] canOpenURL Hook 已启用");
    } else {
      ECLog(@"⚠️ FeatureFlag: canOpenURL Hook DISABLED");
    }

    ECLog(@"✅ [AntiDetect] 反检测模块初始化完成");
    }

    static void safe_rebind_symbols_for_image(const struct mach_header *header,
                                              intptr_t slide) {
    // 1. 获取镜像路径
    const char *imagePath = NULL;
    Dl_info info;
    if (dladdr(header, &info) && info.dli_fname) {
      imagePath = info.dli_fname;
    }

    if (!imagePath)
      return;

    // 2. 过滤：只 Hook 应用自身和它的 Frameworks（排除自身 dylib）
    BOOL shouldHook = NO;
    NSString *pathStr = [NSString stringWithUTF8String:imagePath];

    // 跳过自身 dylib，避免不必要的 Hook
    if ([pathStr containsString:EC_STR_libswiftDylib]) {
      return;
    }

    if ([pathStr containsString:@"/Application/"] ||
        [pathStr containsString:@"/Bundle/"]) {
      shouldHook = YES;
    } else if ([pathStr containsString:@"/Desktop/"] ||
               [pathStr containsString:@"/build_antigravity/"]) {
      shouldHook = YES;
    }

    if (!shouldHook) {
      return;
    }

    ECLog(@"🎣 Hooking app image: %@", [pathStr lastPathComponent]);

    // 定义 Rebindings (动态构建)
    struct rebinding rebindings[40];
    int count = 0;

    // 设备伪装开关状态读取
    SCPrefLoader *config = [SCPrefLoader shared];

    // (1) MobileGestalt Hooks
    if ([config spoofBoolForKey:@"enableMobileGestaltHooks" defaultValue:YES]) {
      rebindings[count++] =
          (struct rebinding){"MGCopyAnswer", (void *)hooked_MGCopyAnswer,
                             (void **)&original_MGCopyAnswer};
    }

    // (1.5) Sysctl + uname Hooks
    if ([config spoofBoolForKey:@"enableSysctlHooks" defaultValue:YES]) {
      // 联动模式下强制全部 rebind
      rebindings[count++] =
          (struct rebinding){"sysctlbyname", (void *)hooked_sysctlbyname,
                             (void **)&original_sysctlbyname};
      rebindings[count++] = (struct rebinding){"sysctl", (void *)hooked_sysctl,
                                               (void **)&original_sysctl};
      rebindings[count++] = (struct rebinding){"uname", (void *)hooked_uname,
                                               (void **)&original_uname};
    }

    // (2) [已移除] IOKit 诊断 Hooks — 日志证明 MSSDK 不使用

    // (2.5) getifaddrs 诊断 Hook — 记录 MAC 地址读取
    rebindings[count++] = (struct rebinding){
        "getifaddrs", (void *)hooked_getifaddrs, (void **)&original_getifaddrs};

    // (3) Network Hooks
    if ([config spoofBoolForKey:@"enableNetworkHooks" defaultValue:YES]) {
      rebindings[count++] = (struct rebinding){
          "CNCopyCurrentNetworkInfo", (void *)hooked_CNCopyCurrentNetworkInfo,
          (void **)&original_CNCopyCurrentNetworkInfo};
    }

    // (4)(5) 文件系统反检测 Hook & 环境变量 Hook
    // 这些在此前通过 config 控制，现已因 AAAASingularity 检测而完全移除

    // (6) 反调试 Hook — per-image (ptrace/sysctl) [已因风控移除]

    /* [NOTE] 以下符号已在全局 rebind_symbols 中 Hook，不可 per-image rebind：
     * - dyld 枚举: _dyld_image_count, _dyld_get_image_name 等
     * - SSL: SSL_write, SSL_read (setupNetworkInterception)
     * - QUIC: connect (setupNetworkInterception)
     */

    // 4. 执行 Rebind
    if (count > 0) {
      rebind_symbols_image((void *)header, slide, rebindings, count);
    }
    }

    static void image_add_callback(const struct mach_header *header,
                                   intptr_t slide) {
    safe_rebind_symbols_for_image(header, slide);
    }

    static void setupSafeHooks(void) {
    ECLog(@"🛡️ 启用安全 Hook 机制 (Image Filtering Mode)");
    // 注册回调，对所有已加载和后续加载的镜像进行过滤 Hook
    _dyld_register_func_for_add_image(image_add_callback);
    }

#import <mach/mach.h>
#import <sys/mman.h>

    /// 在内存中抹除 Main Binary Header 中的注入痕迹
    /// 防止应用读取自己的 Mach-O Header 发现被注入的 dylib
    // 内部辅助：覆盖单条 LC_LOAD_DYLIB 路径字符串
    static void _sanitizeDylibName(char *name) {
      size_t len = strlen(name);
      const char *fakeName = "/usr/lib/libSystem.B.dylib";
      size_t fakeLen = strlen(fakeName);
      if (len < fakeLen) {
        ECLog(@"[Sanitize] ⚠️ 路径太短无法安全覆盖: %s", name);
        return;
      }
      uintptr_t pageStart = (uintptr_t)name & ~(PAGE_SIZE - 1);
      uintptr_t pageEnd   = ((uintptr_t)name + len + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
      size_t size = pageEnd - pageStart;
      kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)pageStart,
                                    (vm_size_t)size, FALSE,
                                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
      if (kr != KERN_SUCCESS) {
        ECLog(@"[Sanitize] ❌ vm_protect failed: %d", kr);
        return;
      }
      memcpy(name, fakeName, fakeLen);
      memset(name + fakeLen, 0, len - fakeLen);
      ECLog(@"[Sanitize] ✅ Sanitized: → %s", name);
      vm_protect(mach_task_self(), (vm_address_t)pageStart, (vm_size_t)size,
                 FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    }

    static void sanitizeMainBinaryHeader(void) {
      // 修复：遍历所有 LC_LOAD_DYLIB，清理全部可疑注入项（不再 break 后提前退出）
      const struct mach_header_64 *header =
          (const struct mach_header_64 *)_dyld_get_image_header(0);
      if (!header || header->magic != MH_MAGIC_64) return;

      // 可疑路径关键词（运行时 XOR 解密，避免明文出现在二进制中）
      // "ECDeviceSpoof" XOR 0x5A
      static const unsigned char _ek0[] = {0x1f,0x19,0x1e,0x3f,0x2c,0x33,0x39,0x3f,0x09,0x2a,0x35,0x35,0x3c};
      // "spoof_plugin" XOR 0x5A
      static const unsigned char _ek1[] = {0x29,0x2a,0x35,0x35,0x3c,0x05,0x2a,0x36,0x2f,0x3d,0x33,0x34};
      // "CydiaSubstrate" XOR 0x5A
      static const unsigned char _ek2[] = {0x19,0x23,0x3e,0x33,0x3b,0x09,0x2f,0x38,0x29,0x2e,0x28,0x3b,0x2e,0x3f};
      // "SubstrateLoader" XOR 0x5A
      static const unsigned char _ek3[] = {0x09,0x2f,0x38,0x29,0x2e,0x28,0x3b,0x2e,0x3f,0x16,0x35,0x3b,0x3e,0x3f,0x28};
      // "TweakInject" XOR 0x5A
      static const unsigned char _ek4[] = {0x0e,0x2d,0x3f,0x3b,0x31,0x13,0x34,0x30,0x3f,0x39,0x2e};

      char *dk0 = ec_deobf_c(_ek0, 13);
      char *dk1 = ec_deobf_c(_ek1, 12);
      char *dk2 = ec_deobf_c(_ek2, 14);
      char *dk3 = ec_deobf_c(_ek3, 15);
      char *dk4 = ec_deobf_c(_ek4, 11);
      const char *suspiciousKeywords[] = {dk0, dk1, dk2, dk3, dk4, NULL};

      uintptr_t cmdPtr = (uintptr_t)(header + 1);
      int found = 0;
      for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cmdPtr;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
          struct dylib_command *dc = (struct dylib_command *)lc;
          char *name = (char *)dc + dc->dylib.name.offset;
          // 匹配任意可疑关键词
          for (int k = 0; suspiciousKeywords[k] != NULL; k++) {
            if (strstr(name, suspiciousKeywords[k]) != NULL) {
              ECLog(@"[Sanitize] 🚨 Found injected LC_LOAD_DYLIB in header: %s", name);
              _sanitizeDylibName(name);
              found++;
              break;
            }
          }
        }
        cmdPtr += lc->cmdsize;
      }
      if (found == 0) {
        // ECLog(@"[Sanitize] No injected dylib found (clean)");
      } else {
        ECLog(@"[Sanitize] ✅ 共清理 %d 条注入 dylib 路径", found);
      }
    }

// ============================================================
// Phase 8: 脱壳/克隆检测绕过
// ============================================================

// 8.1 LC_ENCRYPTION_INFO_64 cryptid 伪造
// 脱壳后 cryptid=0，TikTok 通过遍历 load commands 检测此值
// 将其修改回 1 伪装成仍处于加密状态
#import <mach-o/loader.h>

static void fixEncryptionInfo(void) {
    const struct mach_header_64 *header =
        (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64) return;

    uintptr_t cmdPtr = (uintptr_t)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cmdPtr;
        if (lc->cmd == LC_ENCRYPTION_INFO_64) {
            struct encryption_info_command_64 *enc =
                (struct encryption_info_command_64 *)lc;
            if (enc->cryptid == 0) {
                // 解除内存写保护
                uintptr_t pageStart = (uintptr_t)enc & ~(PAGE_SIZE - 1);
                uintptr_t pageEnd = ((uintptr_t)enc + sizeof(*enc) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
                size_t size = pageEnd - pageStart;
                kern_return_t kr = vm_protect(mach_task_self(),
                    (vm_address_t)pageStart, (vm_size_t)size, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr == KERN_SUCCESS) {
                    enc->cryptid = 1;
                    vm_protect(mach_task_self(), (vm_address_t)pageStart,
                        (vm_size_t)size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
                    ECLog(@"🔐 [AntiDump] LC_ENCRYPTION_INFO_64 cryptid: 0 → 1 (伪装加密)");
                } else {
                    ECLog(@"🔐 [AntiDump] vm_protect 失败: %d", kr);
                }
            } else {
                ECLog(@"🔐 [AntiDump] cryptid 已为 %u，无需修改", enc->cryptid);
            }
            break;
        }
        // 也处理 32 位版本（兼容性）
        if (lc->cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *enc32 =
                (struct encryption_info_command *)lc;
            if (enc32->cryptid == 0) {
                uintptr_t pageStart = (uintptr_t)enc32 & ~(PAGE_SIZE - 1);
                uintptr_t pageEnd = ((uintptr_t)enc32 + sizeof(*enc32) + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
                size_t size = pageEnd - pageStart;
                kern_return_t kr = vm_protect(mach_task_self(),
                    (vm_address_t)pageStart, (vm_size_t)size, FALSE,
                    VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                if (kr == KERN_SUCCESS) {
                    enc32->cryptid = 1;
                    vm_protect(mach_task_self(), (vm_address_t)pageStart,
                        (vm_size_t)size, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
                    ECLog(@"🔐 [AntiDump] LC_ENCRYPTION_INFO cryptid: 0 → 1 (32-bit)");
                }
            }
            break;
        }
        cmdPtr += lc->cmdsize;
    }
}

// 8.2 App Store Receipt 占位 (v2225 修复)
// 写入到用户可写的 tmp 目录，而非只读的 App Bundle 目录
// Phase 8.4 的 appStoreReceiptURL Hook 负责将 TikTok 的查询路径重定向到此处
static NSString *g_fakeReceiptPath = nil;

static void fixAppStoreReceipt(void) {
    // 使用用户沙盒可写的 tmp 目录，而非 Bundle 目录
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *receiptDir = [tmpDir stringByAppendingPathComponent:@"_MASReceipt"];
    NSString *receiptFile = [receiptDir stringByAppendingPathComponent:@"receipt"];
    g_fakeReceiptPath = receiptFile; // 全局保存供 Hook 使用

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:receiptFile]) {
        NSError *dirErr = nil;
        [fm createDirectoryAtPath:receiptDir
      withIntermediateDirectories:YES attributes:nil error:&dirErr];
        if (dirErr) {
            ECLog(@"🧾 [AntiClone] 创建 Receipt 目录失败: %@", dirErr);
            return;
        }
        // 写入最小 PKCS7 容器占位
        const unsigned char fakeReceipt[] = {
            0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86,
            0xf7, 0x0d, 0x01, 0x07, 0x02, 0xa0, 0x80, 0x30,
            0x80, 0x02, 0x01, 0x01, 0x31, 0x00, 0x30, 0x80,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d,
            0x01, 0x07, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x31, 0x00, 0x00, 0x00, 0x00, 0x00
        };
        NSData *receiptData = [NSData dataWithBytes:fakeReceipt length:sizeof(fakeReceipt)];
        BOOL ok = [receiptData writeToFile:receiptFile atomically:YES];
        ECLog(@"🧾 [AntiClone] Receipt 占位文件 %@: %@", ok ? @"创建成功" : @"创建失败", receiptFile);
    } else {
        ECLog(@"🧾 [AntiClone] Receipt 占位文件已存在: %@", receiptFile);
    }
}
// 8.3 Keychain Access Group 拦截
// 已由 setupKeychainIsolationHooks() (line ~2508) 中的 rewriteKeychainQueryForClone 处理
// 该函数在第 2432 行自动移除 kSecAttrAccessGroup，无需重复 Hook

// 8.4 appStoreReceiptURL Hook — 确保返回存在的路径
static IMP _orig_appStoreReceiptURL = NULL;

static NSURL *hooked_appStoreReceiptURL(id self, SEL _cmd) {
    // 优先返回我们写入到 tmp 目录的 receipt（v2225 修复：沙盒安全路径）
    if (g_fakeReceiptPath && [[NSFileManager defaultManager] fileExistsAtPath:g_fakeReceiptPath]) {
        return [NSURL fileURLWithPath:g_fakeReceiptPath];
    }
    // 降级：返回 Bundle 内路径（即使不存在，也比返回 nil 好）
    NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString *receiptPath = [bundlePath stringByAppendingPathComponent:@"_MASReceipt/receipt"];
    return [NSURL fileURLWithPath:receiptPath];
}

static void setupCloneDetectionBypass(void) {
    ECLog(@"🛡️ [Phase 8] 启动脱壳/克隆检测绕过...");

    // 8.1 修复加密标志 — ⚠️ 已禁用 (v2227)
    // vm_protect 修改 Mach-O 内存中 LC_ENCRYPTION_INFO_64 的 cryptid 字段，
    // 在 iOS 16+ 的 PAC/TPRO 保护下会触发延迟内存保护错误：
    // dyld 锁定已签名页后，任何对可执行页的写操作都会在 UIWindowScene 初始化时爆发 SIGSEGV
    // 日志特征：client_died 紧跟 kExcludedFromBackupXattrName 之后
    // @try { fixEncryptionInfo(); }
    // @catch (NSException *e) { ECLog(@"❌ Phase 8.1 cryptid 异常: %@", e); }
    ECLog(@"🛡️ [Phase 8.1] cryptid 伪装已禁用（iOS PAC/TPRO 内存保护限制）");

    // 8.2 创建收据占位文件 — v2225 修复：写到 tmp 目录，安全可写
    @try { fixAppStoreReceipt(); }
    @catch (NSException *e) { ECLog(@"❌ Phase 8.2 receipt 异常: %@", e); }

    // 8.3 Keychain AccessGroup 已由 setupKeychainIsolationHooks 处理（无需重复）

    // 8.4 Hook appStoreReceiptURL — 安全的 ObjC Method Swizzle
    @try {
        Method m = class_getInstanceMethod([NSBundle class], @selector(appStoreReceiptURL));
        if (m) {
            _orig_appStoreReceiptURL = method_getImplementation(m);
            method_setImplementation(m, (IMP)hooked_appStoreReceiptURL);
            ECLog(@"  ✅ Hooked: -[NSBundle appStoreReceiptURL]");
        }
    } @catch (NSException *e) { ECLog(@"❌ Phase 8.4 receiptURL 异常: %@", e); }

    ECLog(@"🛡️ [Phase 8] 脱壳/克隆检测绕过完成");
}

// ============================================================
// Phase 9: IMP 地址越界检测绕过
// ============================================================
// TikTok 用 class_getMethodImplementation() 获取关键方法 IMP，
// 校验地址是否在 TikTokCore __TEXT 段内。
// 策略：用纯 C 数组存储 Hook 映射（避免 ObjC 递归），
//       仅在被 Hook 的 selector 被查询时返回原始 IMP。

#include <os/lock.h>

// 纯 C 实现的 IMP 映射表 — 避免 NSString/NSDictionary 触发 ObjC 递归
typedef struct {
    Class cls;
    SEL sel;
    IMP origIMP;
} ECIMPEntry;

#define EC_IMP_MAP_MAX 128
static ECIMPEntry g_impEntries[EC_IMP_MAP_MAX];
static int g_impEntryCount = 0;
static os_unfair_lock g_impLock = OS_UNFAIR_LOCK_INIT;

// 注册原始 IMP（纯 C，线程安全）
void ec_registerOriginalIMP(Class cls, SEL sel, IMP origIMP) {
    os_unfair_lock_lock(&g_impLock);
    if (g_impEntryCount < EC_IMP_MAP_MAX) {
        g_impEntries[g_impEntryCount].cls = cls;
        g_impEntries[g_impEntryCount].sel = sel;
        g_impEntries[g_impEntryCount].origIMP = origIMP;
        g_impEntryCount++;
    }
    os_unfair_lock_unlock(&g_impLock);
}

// 纯 C 查找（O(n) 但 n ≤ 128，无 ObjC 调用）
static IMP ec_lookupOriginalIMP(Class cls, SEL sel) {
    // 快速路径：如果映射表为空，立即返回
    if (g_impEntryCount == 0) return NULL;

    // 注意：读取期间不加锁（写入只发生在启动期，启动后表是只读的）
    int count = g_impEntryCount;
    for (int i = 0; i < count; i++) {
        if (g_impEntries[i].cls == cls && g_impEntries[i].sel == sel) {
            return g_impEntries[i].origIMP;
        }
    }
    return NULL;
}

// 纯 C 按 selector 查找（用于 method_getImplementation 不带 class 参数）
static IMP ec_lookupOriginalIMPBySel(SEL sel) {
    if (g_impEntryCount == 0) return NULL;
    int count = g_impEntryCount;
    for (int i = 0; i < count; i++) {
        if (g_impEntries[i].sel == sel) {
            return g_impEntries[i].origIMP;
        }
    }
    return NULL;
}

// Hook: class_getMethodImplementation — 纯 C 路径，零 ObjC 开销
static IMP (*orig_runtime_class_getMethodImpl)(Class, SEL) = NULL;
static IMP hooked_runtime_class_getMethodImpl(Class cls, SEL sel) {
    IMP origIMP = ec_lookupOriginalIMP(cls, sel);
    if (origIMP) return origIMP;
    return orig_runtime_class_getMethodImpl(cls, sel);
}

// Hook: method_getImplementation — ⚠️ 已禁用 (v2228)
// 根本原因：ec_lookupOriginalIMPBySel 只按 SEL 名称匹配（不区分 Class），
// 当 TikTok analytics SDK 调用 method_getImplementation 时，若我们映射表中有
// 同名 SEL，会错误地返回其他类的 IMP，导致运行时类型错乱。
// 具体表现：__NSArray0 收到 setAppID: → NSInvalidArgumentException → 崩溃
// 保留 class_getMethodImplementation Hook（使用 Class+SEL 双重匹配，安全）
static IMP (*orig_runtime_method_getImpl)(Method) = NULL;

static void setupIMPSpoofing(void) {
    ECLog(@"🛡️ [Phase 9] IMP 地址越界检测绕过（仅 class_getMethodImplementation）...");

    // v2225 修复：用 dlsym 预存原始符号作为兜底
    if (!orig_runtime_class_getMethodImpl) {
        orig_runtime_class_getMethodImpl =
            (IMP (*)(Class, SEL))dlsym(RTLD_DEFAULT, "class_getMethodImplementation");
    }

    if (!orig_runtime_class_getMethodImpl) {
        ECLog(@"  ❌ Phase 9: dlsym 获取 class_getMethodImplementation 失败，跳过");
        return;
    }

    // v2228 修复：仅 Hook class_getMethodImplementation（Class+SEL 双重匹配，安全）
    // method_getImplementation 已移除 — 其 SEL-only 匹配会导致返回错误 IMP
    struct rebinding impRebindings[] = {
        {"class_getMethodImplementation", (void *)hooked_runtime_class_getMethodImpl,
         (void **)&orig_runtime_class_getMethodImpl},
    };
    rebind_symbols(impRebindings, 1);

    if (!orig_runtime_class_getMethodImpl) {
        ECLog(@"  ❌ Phase 9: rebind_symbols 后指针为 NULL");
        return;
    }
    ECLog(@"  ✅ Hooked: class_getMethodImplementation (method_getImplementation 已移除)");
}

// ============================================================
// Phase 10: bdfishhook GOT 表监控绕过
// ============================================================
// 禁用 TikTok 自研 bdfishhook 的 GOT 完整性校验

static void setupBDFishhookBypass(void) {
    ECLog(@"🛡️ [Phase 10] bdfishhook GOT 监控绕过...");

    // 方案：Hook AWEFishhookInitTask 的所有方法，让它什么都不做
    Class fishhookTaskCls = NSClassFromString(EC_P9_AWEFishhookInitTask);
    if (fishhookTaskCls) {
        // Hook 常见的 Task 启动方法
        NSArray *taskSelectors = @[@"start", @"run", @"execute",
                                   @"startWithCompletionHandler:",
                                   @"runWithContext:"];
        for (NSString *selName in taskSelectors) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getInstanceMethod(fishhookTaskCls, sel);
            if (m) {
                method_setImplementation(m,
                    imp_implementationWithBlock(^(id self_) {
                        // 空实现 — 禁止 bdfishhook 初始化
                    }));
                ECLog(@"  ✅ Disabled: -[AWEFishhookInitTask %@]", selName);
            }
        }

        // 也 Hook 类方法
        for (NSString *selName in taskSelectors) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getClassMethod(fishhookTaskCls, sel);
            if (m) {
                method_setImplementation(m,
                    imp_implementationWithBlock(^(id self_) {
                        // 空实现
                    }));
                ECLog(@"  ✅ Disabled: +[AWEFishhookInitTask %@]", selName);
            }
        }
    } else {
        ECLog(@"  ⚠️ AWEFishhookInitTask 类不存在，跳过");
    }

    // 额外：扫描 fishhookConflict 方法并致盲 — 延迟到主队列执行（避免 Swift 元数据崩溃）
    NSString *conflictKey = EC_P9_fishhookConflictFixEnable;
    NSString *conflictKey2 = EC_P9_fishhookConflict;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            unsigned int classCount = 0;
            Class *classes = objc_copyClassList(&classCount);
            int disabledCount = 0;
            for (unsigned int i = 0; i < classCount; i++) {
                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(classes[i], &methodCount);
                for (unsigned int j = 0; j < methodCount; j++) {
                    NSString *methodName = NSStringFromSelector(method_getName(methods[j]));
                    if ([methodName containsString:conflictKey] ||
                        [methodName containsString:conflictKey2]) {
                        method_setImplementation(methods[j],
                            imp_implementationWithBlock(^BOOL(id self_) { return NO; }));
                        disabledCount++;
                    }
                }
                if (methods) free(methods);
            }
            if (classes) free(classes);
            ECLog(@"🛡️ [Phase 10 延迟] bdfishhook conflict 方法致盲完成: %d 个", disabledCount);
        } @catch (NSException *e) {
            ECLog(@"❌ [Phase 10 延迟] 扫描异常: %@", e);
        }
    });

    ECLog(@"🛡️ [Phase 10] bdfishhook 绕过完成（conflict 扫描已延迟到主队列）");
}

// ============================================================
// Phase 11: TSPK 拦截链双向校验绕过
// ============================================================

static void setupTSPKBypass(void) {
    ECLog(@"🛡️ [Phase 11] TSPK 拦截链校验绕过...");

    // 1. Hook TSPKInterceptorCheckerImpl.isIntercepted → NO
    Class tspkCls = NSClassFromString(EC_P9_TSPKInterceptorCheckerImpl);
    if (tspkCls) {
        // Hook isIntercepted 属性 getter
        SEL isInterceptedSel = NSSelectorFromString(EC_P9_isIntercepted);
        Method m = class_getInstanceMethod(tspkCls, isInterceptedSel);
        if (m) {
            method_setImplementation(m,
                imp_implementationWithBlock(^BOOL(id self_) {
                    return NO; // 永远报告"未被拦截"
                }));
            ECLog(@"  ✅ Hooked: TSPKInterceptorCheckerImpl.isIntercepted → NO");
        }

        // Hook validateModifiedDictionary 让它直接返回（不标记异常）
        SEL validateSel = NSSelectorFromString(EC_P9_enableInterceptorCheckerReport);
        Method mReport = class_getInstanceMethod(tspkCls, validateSel);
        if (!mReport) mReport = class_getClassMethod(tspkCls, validateSel);
        if (mReport) {
            method_setImplementation(mReport,
                imp_implementationWithBlock(^BOOL(id self_) {
                    return NO; // 禁用上报
                }));
            ECLog(@"  ✅ Disabled: TSPK interceptor report");
        }
    } else {
        ECLog(@"  ⚠️ TSPKInterceptorCheckerImpl 不存在，跳过");
    }

    // 2. 批量扫描 TSPK 前缀类 — 延迟到主队列执行（避免 Swift 元数据崩溃）
    NSString *interceptedKey = EC_P9_isIntercepted;
    NSString *interceptorCheckKey = EC_P9_interceptorCheck;
    NSString *hookDetectKey = EC_P9_hookDetect;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            unsigned int classCount = 0;
            Class *classes = objc_copyClassList(&classCount);
            int disabledCount = 0;
            for (unsigned int i = 0; i < classCount; i++) {
                NSString *className = NSStringFromClass(classes[i]);
                if (![className hasPrefix:@"TSPK"]) continue;

                unsigned int methodCount = 0;
                Method *methods = class_copyMethodList(classes[i], &methodCount);
                for (unsigned int j = 0; j < methodCount; j++) {
                    NSString *selName = NSStringFromSelector(method_getName(methods[j]));
                    if ([selName containsString:interceptedKey] ||
                        [selName containsString:interceptorCheckKey] ||
                        [selName containsString:hookDetectKey]) {
                        method_setImplementation(methods[j],
                            imp_implementationWithBlock(^BOOL(id self_) { return NO; }));
                        disabledCount++;
                    }
                }
                if (methods) free(methods);
            }
            if (classes) free(classes);
            ECLog(@"🛡️ [Phase 11 延迟] TSPK 拦截检测方法致盲完成: %d 个", disabledCount);
        } @catch (NSException *e) {
            ECLog(@"❌ [Phase 11 延迟] 扫描异常: %@", e);
        }
    });

    ECLog(@"🛡️ [Phase 11] TSPK 绕过完成（批量扫描已延迟到主队列）");
}

// ============================================================
// Phase 12-13: DeviceCheck + AppAttest 绕过
// ============================================================

static void setupDeviceCheckBypass(void) {
    ECLog(@"🛡️ [Phase 12-13] DeviceCheck/AppAttest 绕过...");

    // 12.1 禁用 TTKDeviceCheckInitTask（阻止 DeviceCheck 初始化）
    Class dcTaskCls = NSClassFromString(EC_P9_TTKDeviceCheckInitTask);
    if (dcTaskCls) {
        NSArray *taskSels = @[@"start", @"run", @"execute",
                              @"startWithCompletionHandler:"];
        for (NSString *selName in taskSels) {
            SEL sel = NSSelectorFromString(selName);
            Method m = class_getInstanceMethod(dcTaskCls, sel);
            if (m) {
                method_setImplementation(m,
                    imp_implementationWithBlock(^(id self_) {
                        // 空实现 — 跳过 DeviceCheck
                    }));
                ECLog(@"  ✅ Disabled: -[TTKDeviceCheckInitTask %@]", selName);
                break;
            }
        }
    }

    // 12.2 Hook DCDevice.generateTokenWithCompletionHandler:
    // 让 completion handler 收到一个 error，TikTok 会走降级路径
    Class dcDeviceCls = NSClassFromString(EC_P9_DCDevice);
    if (dcDeviceCls) {
        SEL genTokenSel = NSSelectorFromString(EC_P9_generateTokenWithCompletion);
        Method m = class_getInstanceMethod(dcDeviceCls, genTokenSel);
        if (m) {
            method_setImplementation(m,
                imp_implementationWithBlock(^(id self_, void (^completion)(NSData *token, NSError *error)) {
                    if (completion) {
                        // 返回"设备不支持"错误，触发 TikTok 的降级逻辑
                        NSError *err = [NSError errorWithDomain:@"DCErrorDomain"
                                                          code:1
                                                      userInfo:@{NSLocalizedDescriptionKey:
                                                                 @"Device not supported"}];
                        completion(nil, err);
                    }
                }));
            ECLog(@"  ✅ Hooked: -[DCDevice generateTokenWithCompletionHandler:] → error");
        }
    }

    // 13.1 Hook AppAttest attestKey 和 generateAssertion
    // 返回错误让 TikTok 走 fallback 路径
    Class asServerCls = NSClassFromString(@"ASAuthorizationAppleIDProvider");
    // AppAttest 更多通过 DeviceCheck framework 的 DCAppAttestService
    Class attestCls = NSClassFromString(EC_P9_DCAppAttestService);
    if (attestCls) {
        // Hook attestKey:clientDataHash:completionHandler:
        SEL attestKeySel = NSSelectorFromString(EC_P9_attestKey);
        Method m1 = class_getInstanceMethod(attestCls, attestKeySel);
        if (m1) {
            method_setImplementation(m1,
                imp_implementationWithBlock(^(id self_, NSString *keyId, NSData *hash,
                                             void (^completion)(NSData *attestObj, NSError *error)) {
                    if (completion) {
                        NSError *err = [NSError errorWithDomain:@"DCErrorDomain"
                                                          code:2
                                                      userInfo:@{NSLocalizedDescriptionKey:
                                                                 @"AppAttest not available"}];
                        completion(nil, err);
                    }
                }));
            ECLog(@"  ✅ Hooked: -[DCAppAttestService attestKey:...] → error");
        }

        // Hook generateAssertion:clientDataHash:completionHandler:
        SEL genAssertSel = NSSelectorFromString(EC_P9_generateAssertion);
        Method m2 = class_getInstanceMethod(attestCls, genAssertSel);
        if (m2) {
            method_setImplementation(m2,
                imp_implementationWithBlock(^(id self_, NSString *keyId, NSData *hash,
                                             void (^completion)(NSData *assertion, NSError *error)) {
                    if (completion) {
                        NSError *err = [NSError errorWithDomain:@"DCErrorDomain"
                                                          code:3
                                                      userInfo:@{NSLocalizedDescriptionKey:
                                                                 @"Assertion generation failed"}];
                        completion(nil, err);
                    }
                }));
            ECLog(@"  ✅ Hooked: -[DCAppAttestService generateAssertion:...] → error");
        }

        // Hook isSupported 属性 → NO
        SEL isSupportedSel = NSSelectorFromString(@"isSupported");
        Method mSupported = class_getInstanceMethod(attestCls, isSupportedSel);
        if (!mSupported) mSupported = class_getClassMethod(attestCls, isSupportedSel);
        if (mSupported) {
            method_setImplementation(mSupported,
                imp_implementationWithBlock(^BOOL(id self_) {
                    return NO; // AppAttest 不可用
                }));
            ECLog(@"  ✅ Hooked: DCAppAttestService.isSupported → NO");
        }
    }

    ECLog(@"🛡️ [Phase 12-13] DeviceCheck/AppAttest 绕过完成");
}

// ============================================================
// Phase 14: Info.plist 物理文件读取拦截
// ============================================================
// TikTok 的 AWEFakeBundleIDManager 会绕过 NSBundle API，
// 直接通过 open()/read() 读取物理 Info.plist 校验 Bundle ID。
// 方案：在启动时直接修改沙盒中的 Info.plist 文件，将
// CFBundleIdentifier 从克隆 ID (如 com.zhiliaoapp.musically1)
// 改为官方 ID (com.zhiliaoapp.musically)。
// 这比 Hook open() 更安全，不会触发 GOT 监控。

static void fixInfoPlistBundleId(void) {
    ECLog(@"🛡️ [Phase 14] Info.plist 物理文件修复...");

    NSString *plistPath = [[[NSBundle mainBundle] bundlePath]
                           stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *plist =
        [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
    if (!plist) {
        ECLog(@"  ⚠️ 无法读取 Info.plist: %@", plistPath);
        return;
    }

    NSString *currentBundleId = plist[@"CFBundleIdentifier"];
    if (!currentBundleId) return;

    // 计算官方 Bundle ID（去除数字后缀）
    NSString *officialId = nil;

    // 匹配 com.zhiliaoapp.musically1 → com.zhiliaoapp.musically
    // 匹配 com.ss.iphone.ugc.Ame2 → com.ss.iphone.ugc.Ame
    NSRegularExpression *regex =
        [NSRegularExpression regularExpressionWithPattern:@"^(.+?)(\\d+)$"
                                                  options:0 error:nil];
    NSTextCheckingResult *match =
        [regex firstMatchInString:currentBundleId
                          options:0
                            range:NSMakeRange(0, currentBundleId.length)];
    if (match && match.numberOfRanges > 1) {
        officialId = [currentBundleId substringWithRange:[match rangeAtIndex:1]];
    }

    // 如果已经是官方 ID（无数字后缀），无需修改
    if (!officialId || [officialId isEqualToString:currentBundleId]) {
        ECLog(@"  ✅ Bundle ID 已是官方: %@", currentBundleId);
        return;
    }

    // 修改 Info.plist 中的 Bundle ID
    plist[@"CFBundleIdentifier"] = officialId;

    // 同时修改 CFBundleURLTypes 中包含克隆 ID 的 URL Scheme
    NSArray *urlTypes = plist[@"CFBundleURLTypes"];
    if ([urlTypes isKindOfClass:[NSArray class]]) {
        NSMutableArray *newUrlTypes = [NSMutableArray array];
        for (NSDictionary *urlType in urlTypes) {
            NSMutableDictionary *mutableType = [urlType mutableCopy];
            NSArray *schemes = mutableType[@"CFBundleURLSchemes"];
            if ([schemes isKindOfClass:[NSArray class]]) {
                NSMutableArray *newSchemes = [NSMutableArray array];
                for (NSString *scheme in schemes) {
                    // 去除 scheme 中的数字后缀
                    NSString *cleanScheme = [scheme stringByReplacingOccurrencesOfString:currentBundleId
                                                                             withString:officialId];
                    [newSchemes addObject:cleanScheme];
                }
                mutableType[@"CFBundleURLSchemes"] = newSchemes;
            }
            [newUrlTypes addObject:mutableType];
        }
        plist[@"CFBundleURLTypes"] = newUrlTypes;
    }

    // 写回文件
    BOOL success = [plist writeToFile:plistPath atomically:YES];
    if (success) {
        ECLog(@"  ✅ Info.plist CFBundleIdentifier: %@ → %@", currentBundleId, officialId);
    } else {
        ECLog(@"  ❌ Info.plist 写入失败（可能沙盒只读）");
    }
}

// ============================================================
// Phase 9-14 总装入口
// ============================================================
static void setupDeepProtection(void) {
    // v2229: 临时全部禁用 Phase 9-14
    // 14:38 崩溃日志显示在 UIWindowScene 初始化后 SIGSEGV，
    // 无法确定是哪个 Phase 导致。先建立稳定基线，后续逐个启用二分排查。
    ECLog(@"🛡️ [Phase 9-14] 深度防护暂时全部禁用 — 二分排查崩溃源");

    // 仅保留 Phase 12-13（纯 ObjC method swizzle，最安全）
    @try { setupDeviceCheckBypass(); }
    @catch (NSException *e) { ECLog(@"❌ Phase 12-13 异常: %@", e); }

    // Phase 9 (IMP rebind) — 暂时禁用，rebind_symbols 可能破坏 GOT
    // @try { setupIMPSpoofing(); }
    // @catch (NSException *e) { ECLog(@"❌ Phase 9 异常: %@", e); }

    // Phase 10 (bdfishhook) — 暂时禁用
    // 静态部分 Hook AWEFishhookInitTask 是安全的，但 dispatch_async 中的 objc_copyClassList 需要验证
    // @try { setupBDFishhookBypass(); }
    // @catch (NSException *e) { ECLog(@"❌ Phase 10 异常: %@", e); }

    // Phase 11 (TSPK) — 暂时禁用
    // @try { setupTSPKBypass(); }
    // @catch (NSException *e) { ECLog(@"❌ Phase 11 异常: %@", e); }

    // Phase 14 — 保持禁用（写 Bundle 文件不安全）
    // @try { fixInfoPlistBundleId(); }
    // @catch (NSException *e) { ECLog(@"❌ Phase 14 异常: %@", e); }
}

// ============================================================
// CTCellularData 网络权限绕过
// ─────────────────────────────────────────────────────────────
// 问题：CommCenter 因无法识别本 App（bundleID hook 导致名称查询失败）
//       立即返回 kCTCellularDataRestricted，TikTok 显示"无网络"且无弹窗
// 解决：Swizzle CTCellularData 的 setCellularDataRestrictionDidUpdateNotifier:
//       拦截所有"已限制"回调，强制改为 kCTCellularDataNotRestricted
//       实际连接已通过代理正常运作，仅需告知 TikTok "权限已允许" 即可
// ============================================================

// ── CTCellularData Setter Swizzle ────────────────────────────
static IMP g_orig_setCellularDataNotifier = nil;

static void ec_hooked_setCellularDataNotifier(id self, SEL _cmd,
    CellularDataRestrictionDidUpdateNotifier userNotifier) {
  if (!userNotifier) {
    if (g_orig_setCellularDataNotifier) {
      ((void (*)(id, SEL, CellularDataRestrictionDidUpdateNotifier))
          g_orig_setCellularDataNotifier)(self, _cmd, nil);
    }
    return;
  }

  // 包装用户 block：拦截任何"已限制"回调，强制改为"未限制"
  CellularDataRestrictionDidUpdateNotifier wrappedNotifier =
      ^(CTCellularDataRestrictedState state) {
    if (state != kCTCellularDataNotRestricted) {
      ECLog(@"🔓 [CTCellularData-Hook] CommCenter 状态 %ld → 强制覆盖为 NotRestricted", (long)state);
    }
    userNotifier(kCTCellularDataNotRestricted);
  };

  // 安装拦截后的 block
  if (g_orig_setCellularDataNotifier) {
    ((void (*)(id, SEL, CellularDataRestrictionDidUpdateNotifier))
        g_orig_setCellularDataNotifier)(self, _cmd, wrappedNotifier);
  }

  // 立即主线程触发一次"允许"回调，让 TikTok 尽快解除"无网络"状态
  dispatch_async(dispatch_get_main_queue(), ^{
    ECLog(@"🔓 [CTCellularData-Hook] 立即回调 kCTCellularDataNotRestricted");
    userNotifier(kCTCellularDataNotRestricted);
  });
}

// 安装 CTCellularData Hook（在 ECDeviceSpoofInitialize 中调用一次）
static void ec_install_cellular_data_hook(void) {
  Class cls = NSClassFromString(@"CTCellularData");
  if (!cls) {
    ECLog(@"⚠️ [CTCellularData-Hook] CTCellularData 类未找到，跳过");
    return;
  }
  SEL sel = NSSelectorFromString(@"setCellularDataRestrictionDidUpdateNotifier:");
  Method method = class_getInstanceMethod(cls, sel);
  if (!method) {
    ECLog(@"⚠️ [CTCellularData-Hook] 方法未找到，跳过");
    return;
  }
  g_orig_setCellularDataNotifier = method_setImplementation(
      method, (IMP)ec_hooked_setCellularDataNotifier);
  ECLog(@"✅ [CTCellularData-Hook] Hook 已安装：所有 Restricted 回调将被覆盖为 NotRestricted");
}

// ── 探针请求（辅助触发 CommCenter 注册）──────────────────────
static void ec_trigger_network_permission_once(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    ECLog(@"🌐 [NetworkPerm] 等待主窗口后发送探针请求...");

    __block id obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *_) {
      [[NSNotificationCenter defaultCenter] removeObserver:obs];
      obs = nil;

      // 延迟 1.5s 确保 rootViewController 已显示
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
        @try {
          // 实例化 CTCellularData：此时 Hook 已安装，回调会立即返回 NotRestricted
          CTCellularData *cd = [[CTCellularData alloc] init];
          __unused CTCellularData *strongCD = cd; // 防止 ARC 过早释放
          [cd setCellularDataRestrictionDidUpdateNotifier:^(CTCellularDataRestrictedState s) {
            ECLog(@"🌐 [NetworkPerm] CTCellularData 状态: %ld (Hook 后应为 0)", (long)s);
          }];

          // captive.apple.com 探针请求：进一步刺激 CommCenter 完成注册
          NSURL *probeURL =
              [NSURL URLWithString:@"https://captive.apple.com/hotspot-detect.html"];
          NSMutableURLRequest *req =
              [NSMutableURLRequest requestWithURL:probeURL
                                     cachePolicy:NSURLRequestReloadIgnoringCacheData
                                 timeoutInterval:5.0];
          [req setValue:@"CaptiveNetworkSupport/1.0 wispr"
              forHTTPHeaderField:@"User-Agent"];
          NSURLSession *sess =
              [NSURLSession sessionWithConfiguration:
                  [NSURLSessionConfiguration ephemeralSessionConfiguration]];
          [[sess dataTaskWithRequest:req
              completionHandler:^(NSData *d, NSURLResponse *r, NSError *err) {
            ECLog(@"🌐 [NetworkPerm] 探针完成: %@",
                  err ? err.localizedDescription : @"成功");
          }] resume];

          ECLog(@"🌐 [NetworkPerm] 探针序列已发射");
        } @catch (NSException *ex) {
          ECLog(@"⚠️ [NetworkPerm] 触发异常: %@", ex);
        }
      });
    }];
  });
}

// dylib 加载时自动执行
    __attribute__((constructor(101))) static void constructor(void) {
    @autoreleasepool {
      // 0. [CRITICAL] 立即抹除注入痕迹
      sanitizeMainBinaryHeader();

      // [极速克隆标记 v2257] 在最早期拦截开始前，强制确定身份！
      NSString *__fastBid = [[NSBundle mainBundle] bundleIdentifier];
      if (!__fastBid) {
          NSString *__infoPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Info.plist"];
          NSDictionary *__infoDict = [NSDictionary dictionaryWithContentsOfFile:__infoPath];
          __fastBid = __infoDict[@"CFBundleIdentifier"];
      }
      if (__fastBid) {
          NSRegularExpression *__regex = [NSRegularExpression regularExpressionWithPattern:@"\\.([a-zA-Z]{3,})(\\d+)$" options:0 error:nil];
          NSTextCheckingResult *__match = [__regex firstMatchInString:__fastBid options:0 range:NSMakeRange(0, __fastBid.length)];
          if (__match && __match.numberOfRanges > 2) {
              g_FastCloneId = [__fastBid substringWithRange:[__match rangeAtIndex:2]];
              g_isCloneMode = YES;
              NSLog(@"[ecwg][ECDeviceSpoof] 🚀 极速判定启动：当前是克隆环境 CloneID: %@", g_FastCloneId);
          } else {
              // Try .cloneX format
              __regex = [NSRegularExpression regularExpressionWithPattern:@"\\.clone(\\d+)$" options:0 error:nil];
              __match = [__regex firstMatchInString:__fastBid options:0 range:NSMakeRange(0, __fastBid.length)];
              if (__match && __match.numberOfRanges > 1) {
                  g_FastCloneId = [__fastBid substringWithRange:[__match rangeAtIndex:1]];
                  g_isCloneMode = YES;
                  NSLog(@"[ecwg][ECDeviceSpoof] 🚀 极速判定启动：当前是克隆环境 CloneID: %@", g_FastCloneId);
              }
          }
      }


      // [Audit] 记录启动信息到隐蔽的缓存文件（异步执行，避免阻塞 constructor）
      // 首次安装时 Documents 目录可能尚未完全就绪，同步写入会增加启动延迟
      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        @try {
          NSString *docDir = [NSSearchPathForDirectoriesInDomains(
              NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
          if (docDir) {
            NSString *logPath = [docDir
                stringByAppendingPathComponent:@".com.apple.nsurlsessiond.plist"];
            NSDateFormatter *df = [[NSDateFormatter alloc] init];
            [df setDateFormat:@"yyyy-MM-dd HH:mm:ss"];
            NSString *log = [NSString
                stringWithFormat:@"[%@] %@ (%d)\n",
                                 [df stringFromDate:[NSDate date]],
                                 [[NSBundle mainBundle] bundleIdentifier],
                                 getpid()];

            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (fh) {
              [fh seekToEndOfFile];
              [fh writeData:[log dataUsingEncoding:NSUTF8StringEncoding]];
              [fh closeFile];
            } else {
              [log writeToFile:logPath
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:nil];
            }
          }
        } @catch (NSException *e) {
          // 忽略
        }
      });

      // 1. [FIX] 同步加载 Config - 修复竞态条件
      // 必须在 Hook 生效前完成配置加载，否则早期 Bundle 访问会返回真实包名
      {
        NSString *spoofedId = [SCPrefLoader shared].originalBundleId;
        if (spoofedId) {
          g_spoofedBundleId = spoofedId;
          g_spoofConfigLoaded = YES;
          ECLog(@"✅ [Sync Load] Config loaded. Spoofed ID: %@",
                g_spoofedBundleId);
        } else {
          g_spoofConfigLoaded = YES; // 即使没配置也标记完成
          ECLog(@"⚠️ [Sync Load] No spoofed ID configured.");
        }
      }

      // 2. 初始化 Hook
      ECDeviceSpoofInitialize();

      // 3. [NETWORK-BYPASS] 安装 CTCellularData 拦截 Hook
      //    CommCenter 无法识别本 App 名称（bundleID hook 副作用），
      //    导致 kCTCellularDataRestricted 立即返回且不弹授权弹窗。
      //    Hook 在此注入：将所有 Restricted 回调强制改为 NotRestricted，
      //    让 TikTok 始终认为已获得网络权限（实际流量已通过代理运作）。
      ec_install_cellular_data_hook();

      // 4. [NETWORK] 发起探针请求辅助 CommCenter 完成 App 注册
      ec_trigger_network_permission_once();
    }
    }
