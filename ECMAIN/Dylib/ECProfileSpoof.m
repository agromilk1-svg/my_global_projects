//
//  ECProfileSpoof.m
//  ECProfileSpoof (方案 C)
//
//  核心 Hook 引擎 — 数据隔离 + 设备伪装 + 安全防护
//  不修改 Bundle ID，使用原版 TikTok 沙盒
//

#import "ECProfileSpoof.h"
#import "ECProfileManager.h"
#import "ECProfileSwitcherUI.h"
#import "fishhook.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AdSupport/AdSupport.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/mman.h>
#import <mach/mach.h>

// ============================================================================
#pragma mark - 日志
// ============================================================================

static void ECPSLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ECPSLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  NSLog(@"[ECProfileC] %@", msg);
}

// ============================================================================
#pragma mark - 全局状态
// ============================================================================

static NSString *g_profileHome = nil;   // 当前 Profile 虚拟 HOME
static NSString *g_realHome = nil;      // 真实 HOME
static NSString *g_profileId = nil;     // 当前 Profile ID
static NSString *g_keychainPrefix = nil; // Keychain 前缀

// ============================================================================
#pragma mark - 越狱路径检测
// ============================================================================

static bool is_jailbreak_path(const char *path) {
  if (!path) return false;
  static const char *jb_paths[] = {
    "/Applications/Cydia.app",
    "/Library/MobileSubstrate",
    "/usr/sbin/sshd",
    "/usr/bin/sshd",
    "/usr/libexec/ssh-keysign",
    "/etc/apt",
    "/private/var/lib/apt",
    "/bin/bash",
    "/usr/bin/ssh",
    "/usr/bin/ldid",
    "/bin/sh",
    "/usr/libexec/sftp-server",
    "/private/etc/ssh/sshd_config",
    "/private/var/stash",
    "/private/var/mobileLibrary",
    "/jb",
    "/.installed_trollstore",
    "/var/jb",
    "/var/LIB",
    "/var/containers/Bundle/trollstoreapps",
    "/private/preboot/jb",
    NULL
  };
  for (int i = 0; jb_paths[i]; i++) {
    if (strcmp(path, jb_paths[i]) == 0) return true;
  }
  // 动态模式匹配
  if (strstr(path, "substrate") || strstr(path, "Substrate") ||
      strstr(path, "ellekit") || strstr(path, "substitute") ||
      strstr(path, "libhooker") || strstr(path, "trollstore") ||
      strstr(path, "TrollStore") || strstr(path, "jailbreak") ||
      strstr(path, "Sileo.app") || strstr(path, "Zebra.app") ||
      strstr(path, "Dopamine.app") || strstr(path, "palera1n")) {
    return true;
  }
  return false;
}

// ============================================================================
#pragma mark - Mach-O Header 清理（抹除注入痕迹）
// ============================================================================

static void sanitizeMainBinaryHeader(void) {
  const struct mach_header_64 *header =
      (const struct mach_header_64 *)_dyld_get_image_header(0);
  if (!header || header->magic != MH_MAGIC_64) return;

  const uint8_t *ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)ptr;
    if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
      const struct dylib_command *dc = (const struct dylib_command *)ptr;
      const char *name = (const char *)ptr + dc->dylib.name.offset;
      if (name && (strstr(name, "ECProfile") || strstr(name, "Spoof") ||
                   strstr(name, "inject") || strstr(name, "substrate") ||
                   strstr(name, "fishhook"))) {
        // 将路径字符串清零
        char *mutableName = (char *)name;
        size_t nameLen = strlen(name);
        memset(mutableName, 0, nameLen);
        ECPSLog(@"🧹 已清理注入痕迹 LC #%u", i);
      }
    }
    ptr += lc->cmdsize;
  }
}

// ============================================================================
#pragma mark - 反脱壳检测 (Anti-Dump Detection)
// ============================================================================

// 绕过 TikTok 启动时的砸壳检测。TikTok 会解析内存中自身的 Mach-O Header，
// 如果发现 LC_ENCRYPTION_INFO_64 的 cryptid == 0，即判定被砸壳。
// 我们在它读取之前，直接将内存里的 cryptid 改回 1。
static void bypassDumpDetection(void) {
  const struct mach_header_64 *header =
      (const struct mach_header_64 *)_dyld_get_image_header(0);
  if (!header || header->magic != MH_MAGIC_64) return;

  const uint8_t *ptr = (const uint8_t *)header + sizeof(struct mach_header_64);
  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)ptr;
    if (lc->cmd == LC_ENCRYPTION_INFO_64 || lc->cmd == LC_ENCRYPTION_INFO) {
      struct encryption_info_command_64 *enc = (struct encryption_info_command_64 *)lc;
      if (enc->cryptid == 0) {
        // 计算所在的内存页地址
        vm_address_t page_start = (vm_address_t)enc & ~(vm_page_size - 1);
        // 修改页权限为可写
        if (mprotect((void *)page_start, vm_page_size, PROT_READ | PROT_WRITE) == 0) {
          enc->cryptid = 1;
          // 恢复原始权限 (通常 Header 是 R/X)
          mprotect((void *)page_start, vm_page_size, PROT_READ | PROT_EXEC);
          ECPSLog(@"🛡️ Anti-Dump: 成功将内存中 cryptid 恢复为 1，绕过脱壳风控！");
        } else {
          ECPSLog(@"🛡️ Anti-Dump: mprotect 解除写保护失败");
        }
      } else {
        ECPSLog(@"🛡️ Anti-Dump: 当前应用带有 DRM 加密壳 (cryptid=%d)", enc->cryptid);
      }
      break;
    }
    ptr += lc->cmdsize;
  }
}

// ============================================================================
#pragma mark - 文件系统 Hook
// ============================================================================

// --- NSHomeDirectory ---
static NSString *(*original_NSHomeDirectory)(void) = NULL;
static NSString *hooked_NSHomeDirectory(void) {
  if (g_profileHome) return g_profileHome;
  return original_NSHomeDirectory();
}

// --- NSSearchPathForDirectoriesInDomains ---
static NSArray *(*original_NSSearchPath)(NSSearchPathDirectory, NSSearchPathDomainMask, BOOL) = NULL;
static NSArray *hooked_NSSearchPath(NSSearchPathDirectory dir, NSSearchPathDomainMask mask, BOOL expand) {
  if (!g_profileHome || !(mask & NSUserDomainMask)) {
    return original_NSSearchPath(dir, mask, expand);
  }
  NSString *subdir = nil;
  switch (dir) {
    case NSDocumentDirectory: subdir = @"Documents"; break;
    case NSLibraryDirectory: subdir = @"Library"; break;
    case NSCachesDirectory: subdir = @"Library/Caches"; break;
    case NSApplicationSupportDirectory: subdir = @"Library/Application Support"; break;
    default: return original_NSSearchPath(dir, mask, expand);
  }
  return @[[g_profileHome stringByAppendingPathComponent:subdir]];
}

// --- getenv ---
static char *(*original_getenv)(const char *) = NULL;
static char *hooked_getenv(const char *name) {
  if (!name) return original_getenv(name);
  if (strcmp(name, "HOME") == 0 && g_profileHome) {
    return (char *)g_profileHome.UTF8String;
  }
  if (strcmp(name, "TMPDIR") == 0 && g_profileHome) {
    static char tmpBuf[512];
    snprintf(tmpBuf, sizeof(tmpBuf), "%s/tmp/", g_profileHome.UTF8String);
    return tmpBuf;
  }
  // 隐藏注入相关环境变量
  if (strstr(name, "DYLD") || strstr(name, "INJECT") || strstr(name, "_MSSafe")) {
    return NULL;
  }
  return original_getenv(name);
}

// --- open ---
static int (*original_open)(const char *, int, ...) = NULL;
static int hooked_open(const char *path, int oflag, ...) {
  mode_t mode = 0;
  if (oflag & O_CREAT) {
    va_list ap;
    va_start(ap, oflag);
    mode = (mode_t)va_arg(ap, int);
    va_end(ap);
  }

  // 越狱路径拦截
  if (path && is_jailbreak_path(path)) {
    errno = ENOENT;
    return -1;
  }

  // 环境探针拦截
  if (path && (oflag & (O_CREAT | O_WRONLY | O_RDWR)) != 0) {
    if (strcmp(path, "/hmd_tmp_file") == 0 ||
        strstr(path, "com.apple.mobileInfo") != NULL ||
        strstr(path, "hmd_tmp") != NULL) {
      errno = EACCES;
      return -1;
    }
  }

  if (oflag & O_CREAT) {
    return original_open(path, oflag, mode);
  }
  return original_open(path, oflag);
}

// --- stat ---
static int (*original_stat)(const char *, struct stat *) = NULL;
static int hooked_stat(const char *path, struct stat *buf) {
  if (path && is_jailbreak_path(path)) {
    errno = ENOENT;
    return -1;
  }
  return original_stat(path, buf);
}

// --- lstat ---
static int (*original_lstat)(const char *, struct stat *) = NULL;
static int hooked_lstat(const char *path, struct stat *buf) {
  if (path && is_jailbreak_path(path)) {
    errno = ENOENT;
    return -1;
  }
  return original_lstat(path, buf);
}

// --- access ---
static int (*original_access)(const char *, int) = NULL;
static int hooked_access(const char *path, int mode) {
  if (path && is_jailbreak_path(path)) {
    errno = ENOENT;
    return -1;
  }
  return original_access(path, mode);
}

// ============================================================================
#pragma mark - sysctl Hook（硬件伪装 + 进程枚举拦截）
// ============================================================================

static int (*original_sysctl)(int *, u_int, void *, size_t *, void *, size_t) = NULL;
static int hooked_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                         void *newp, size_t newlen) {
  // 拦截进程枚举
  if (namelen >= 3 && name[0] == CTL_KERN && name[1] == KERN_PROC && name[2] == 0) {
    errno = EPERM;
    return -1;
  }

  size_t in_oldlen = oldlenp ? *oldlenp : 0;
  int result = original_sysctl(name, namelen, oldp, oldlenp, newp, newlen);

  if (result == 0 && namelen >= 2) {
    ECProfileManager *mgr = [ECProfileManager shared];
    NSString *spoofed = nil;

    if (name[0] == CTL_HW && name[1] == HW_MACHINE) {
      spoofed = [mgr spoofValueForKey:@"machineModel"];
    } else if (name[0] == CTL_KERN && name[1] == KERN_OSVERSION) {
      spoofed = [mgr spoofValueForKey:@"systemBuildVersion"];
    }

    if (spoofed && oldp && oldlenp) {
      size_t spoofLen = [spoofed lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
      if (in_oldlen >= spoofLen) {
        strcpy((char *)oldp, spoofed.UTF8String);
        *oldlenp = spoofLen;
      }
    }
  }
  return result;
}

static int (*original_sysctlbyname)(const char *, void *, size_t *, void *, size_t) = NULL;
static int hooked_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                               void *newp, size_t newlen) {
  int result = original_sysctlbyname(name, oldp, oldlenp, newp, newlen);
  if (result == 0 && name && oldp && oldlenp) {
    ECProfileManager *mgr = [ECProfileManager shared];
    NSString *spoofed = nil;

    if (strcmp(name, "hw.machine") == 0) {
      spoofed = [mgr spoofValueForKey:@"machineModel"];
    } else if (strcmp(name, "hw.model") == 0) {
      spoofed = [mgr spoofValueForKey:@"machineModel"];
    }

    if (spoofed) {
      size_t spoofLen = [spoofed lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + 1;
      if (*oldlenp >= spoofLen) {
        strcpy((char *)oldp, spoofed.UTF8String);
        *oldlenp = spoofLen;
      }
    }
  }
  return result;
}

// --- uname ---
static int (*original_uname)(struct utsname *) = NULL;
static int hooked_uname(struct utsname *buf) {
  int result = original_uname(buf);
  if (result == 0 && buf) {
    NSString *model = [[ECProfileManager shared] spoofValueForKey:@"machineModel"];
    if (model) {
      strlcpy(buf->machine, model.UTF8String, sizeof(buf->machine));
    }
  }
  return result;
}

// ============================================================================
#pragma mark - Keychain 隔离 Hook
// ============================================================================

static OSStatus (*original_SecItemAdd)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*original_SecItemCopyMatching)(CFDictionaryRef, CFTypeRef *) = NULL;
static OSStatus (*original_SecItemUpdate)(CFDictionaryRef, CFDictionaryRef) = NULL;
static OSStatus (*original_SecItemDelete)(CFDictionaryRef) = NULL;

static NSMutableDictionary *prefixKeychainQuery(CFDictionaryRef query) {
  if (!g_keychainPrefix) return [(__bridge NSDictionary *)query mutableCopy];
  
  NSMutableDictionary *mod = [(__bridge NSDictionary *)query mutableCopy];
  NSString *svc = mod[(__bridge id)kSecAttrService];
  if (svc) {
    mod[(__bridge id)kSecAttrService] = [g_keychainPrefix stringByAppendingString:svc];
  } else {
    mod[(__bridge id)kSecAttrService] = g_keychainPrefix;
  }
  return mod;
}

static OSStatus hooked_SecItemAdd(CFDictionaryRef attrs, CFTypeRef *result) {
  NSMutableDictionary *mod = prefixKeychainQuery(attrs);
  return original_SecItemAdd((__bridge CFDictionaryRef)mod, result);
}

static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
  NSMutableDictionary *mod = prefixKeychainQuery(query);
  return original_SecItemCopyMatching((__bridge CFDictionaryRef)mod, result);
}

static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attrs) {
  NSMutableDictionary *mod = prefixKeychainQuery(query);
  return original_SecItemUpdate((__bridge CFDictionaryRef)mod, attrs);
}

static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
  NSMutableDictionary *mod = prefixKeychainQuery(query);
  return original_SecItemDelete((__bridge CFDictionaryRef)mod);
}

// ============================================================================
#pragma mark - ObjC Swizzle 工具
// ============================================================================

static void swizzleInstanceMethod(Class cls, SEL orig, IMP newImp, IMP *outOrig) {
  Method m = class_getInstanceMethod(cls, orig);
  if (!m) return;
  *outOrig = method_getImplementation(m);
  method_setImplementation(m, newImp);
}

// ============================================================================
#pragma mark - UIDevice 伪装
// ============================================================================

static IMP orig_identifierForVendor = NULL;
static NSUUID *hooked_identifierForVendor(id self, SEL _cmd) {
  NSString *vid = [[ECProfileManager shared] spoofValueForKey:@"vendorId"];
  if (vid) return [[NSUUID alloc] initWithUUIDString:vid];
  return ((NSUUID *(*)(id, SEL))orig_identifierForVendor)(self, _cmd);
}

static IMP orig_deviceName = NULL;
static NSString *hooked_deviceName(id self, SEL _cmd) {
  NSString *name = [[ECProfileManager shared] spoofValueForKey:@"deviceName"];
  if (name) return name;
  return ((NSString *(*)(id, SEL))orig_deviceName)(self, _cmd);
}

static IMP orig_systemVersion = NULL;
static NSString *hooked_systemVersion(id self, SEL _cmd) {
  NSString *ver = [[ECProfileManager shared] spoofValueForKey:@"systemVersion"];
  if (ver) return ver;
  return ((NSString *(*)(id, SEL))orig_systemVersion)(self, _cmd);
}

static IMP orig_deviceModel = NULL;
static NSString *hooked_deviceModel(id self, SEL _cmd) {
  NSString *model = [[ECProfileManager shared] spoofValueForKey:@"deviceModel"];
  if (model) return model;
  return ((NSString *(*)(id, SEL))orig_deviceModel)(self, _cmd);
}

// ============================================================================
#pragma mark - ASIdentifierManager IDFA 伪装
// ============================================================================

static IMP orig_advertisingIdentifier = NULL;
static NSUUID *hooked_advertisingIdentifier(id self, SEL _cmd) {
  NSString *idfa = [[ECProfileManager shared] spoofValueForKey:@"idfa"];
  if (idfa) return [[NSUUID alloc] initWithUUIDString:idfa];
  return ((NSUUID *(*)(id, SEL))orig_advertisingIdentifier)(self, _cmd);
}

// ============================================================================
#pragma mark - NSUserDefaults 隔离
// ============================================================================

static IMP orig_initWithSuiteName = NULL;
static id hooked_initWithSuiteName(id self, SEL _cmd, NSString *suiteName) {
  // App Group 重定向到 Profile 内部的 FakeAppGroup
  if (suiteName && [suiteName hasPrefix:@"group."]) {
    if (g_profileHome) {
      NSString *fakeGroupDir = [g_profileHome
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"Documents/FakeAppGroup/%@", suiteName]];
      [[NSFileManager defaultManager] createDirectoryAtPath:fakeGroupDir
          withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // 使用 standardUserDefaults 替代 group suite
    return ((id(*)(id, SEL, NSString *))orig_initWithSuiteName)(self, _cmd, nil);
  }
  return ((id(*)(id, SEL, NSString *))orig_initWithSuiteName)(self, _cmd, suiteName);
}

// ============================================================================
#pragma mark - fishhook 注册辅助
// ============================================================================

static void ec_register_rebinding(const char *name, void *replacement, void **original) {
  struct rebinding rb = {name, replacement, original};
  rebind_symbols(&rb, 1);
}

// ============================================================================
#pragma mark - 初始化入口
// ============================================================================

void ECProfileSpoofInitialize(void) {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    ECPSLog(@"🚀 方案 C 初始化开始...");

    // 1. 初始化 Profile Manager
    ECProfileManager *mgr = [ECProfileManager shared];
    g_profileId = [mgr activeProfileId];
    g_profileHome = [mgr profileHomeDirectory];
    g_realHome = [mgr realHomeDirectory];
    g_keychainPrefix = [NSString stringWithFormat:@"profile_%@_", g_profileId];

    ECPSLog(@"📌 Profile ID: %@, HOME: %@", g_profileId, g_profileHome);

    // 2. [v2429 跳过] CFPreferences 覆写已在 ECDeviceSpoof constructor 中异步完成
    //    此处不再重复调用，避免额外的 cfprefsd 同步 IPC 阻塞
    ECPSLog(@"⏭️ 跳过 CFPreferences 覆写（已在 ECDeviceSpoof 中处理）");

    // 3. 注册 fishhook — 合并为单次 rebind_symbols 调用
    //    原来 14 次独立 rebind_symbols 各自遍历全部 image，开销巨大
    //    合并后只遍历一次，显著降低启动耗时
    struct rebinding rebindings[] = {
      {"NSHomeDirectory", (void *)hooked_NSHomeDirectory, (void **)&original_NSHomeDirectory},
      {"NSSearchPathForDirectoriesInDomains", (void *)hooked_NSSearchPath, (void **)&original_NSSearchPath},
      {"getenv", (void *)hooked_getenv, (void **)&original_getenv},
      {"open", (void *)hooked_open, (void **)&original_open},
      {"stat", (void *)hooked_stat, (void **)&original_stat},
      {"lstat", (void *)hooked_lstat, (void **)&original_lstat},
      {"access", (void *)hooked_access, (void **)&original_access},
      {"sysctl", (void *)hooked_sysctl, (void **)&original_sysctl},
      {"sysctlbyname", (void *)hooked_sysctlbyname, (void **)&original_sysctlbyname},
      {"uname", (void *)hooked_uname, (void **)&original_uname},
      {"SecItemAdd", (void *)hooked_SecItemAdd, (void **)&original_SecItemAdd},
      {"SecItemCopyMatching", (void *)hooked_SecItemCopyMatching, (void **)&original_SecItemCopyMatching},
      {"SecItemUpdate", (void *)hooked_SecItemUpdate, (void **)&original_SecItemUpdate},
      {"SecItemDelete", (void *)hooked_SecItemDelete, (void **)&original_SecItemDelete},
    };
    rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));

    ECPSLog(@"✅ fishhook 批量注册完成 (14 项，单次遍历)");

    // 4. ObjC Swizzle
    Class deviceClass = [UIDevice class];
    swizzleInstanceMethod(deviceClass, @selector(identifierForVendor),
                          (IMP)hooked_identifierForVendor, &orig_identifierForVendor);
    swizzleInstanceMethod(deviceClass, @selector(name),
                          (IMP)hooked_deviceName, &orig_deviceName);
    swizzleInstanceMethod(deviceClass, @selector(systemVersion),
                          (IMP)hooked_systemVersion, &orig_systemVersion);
    swizzleInstanceMethod(deviceClass, @selector(model),
                          (IMP)hooked_deviceModel, &orig_deviceModel);

    // IDFA
    Class asmClass = NSClassFromString(@"ASIdentifierManager");
    if (asmClass) {
      swizzleInstanceMethod(asmClass, NSSelectorFromString(@"advertisingIdentifier"),
                            (IMP)hooked_advertisingIdentifier, &orig_advertisingIdentifier);
    }

    // NSUserDefaults
    swizzleInstanceMethod([NSUserDefaults class], @selector(initWithSuiteName:),
                          (IMP)hooked_initWithSuiteName, &orig_initWithSuiteName);

    ECPSLog(@"✅ ObjC Swizzle 完成");

    // 5. 延迟加载切换 UI（等主 Window 就绪）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
      [ECProfileSwitcherUI install];
    });

    ECPSLog(@"✅ 方案 C 初始化完成！Profile: %@ (%@)",
            [mgr activeProfileId], g_profileHome);
  });
}

// ============================================================================
#pragma mark - Constructor
// ============================================================================

// [v2429] 方案 C 总开关 — 设为 NO 可完全跳过此 dylib 的所有初始化
// 用于排查启动崩溃时隔离 ECProfileSpoof 的影响
static const BOOL EC_ENABLE_PROFILE_SPOOF = NO;

__attribute__((constructor(101))) static void profilec_constructor(void) {
  @autoreleasepool {
    if (!EC_ENABLE_PROFILE_SPOOF) {
      ECPSLog(@"⚠️ [ProfileSpoof] 总开关已关闭，跳过全部初始化");
      return;
    }

    // 0. 抹除注入痕迹
    sanitizeMainBinaryHeader();

    // 0.5 绕过脱壳检测
    bypassDumpDetection();

    // 1. 初始化所有 Hook
    ECProfileSpoofInitialize();
  }
}
