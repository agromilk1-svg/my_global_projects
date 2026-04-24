//
//  ECAppInjector.m
//  ECMAIN
//
//  应用注入管理器实现
//

#import "ECAppInjector.h"
#import "../../TrollStoreCore/TSUtil.h"
#import "ECDeviceInfoManager.h"
#import <sys/stat.h>

extern int spawnRoot(NSString *path, NSArray *args, NSString **stdOut,
                     NSString **stdErr);
extern NSString *rootHelperPath(void);
#import <mach-o/fat.h>
#import <mach-o/loader.h>

// 配置文件基础目录
static NSString *const kECSpoofBaseDir =
    @"/var/mobile/Documents/.com.apple.UIKit.pboard";

// 注入标记文件
static NSString *const kInjectionMarker = @".ecspoof_injected";

// dylib 路径（相对于 APP 包）
static NSString *const kSpoofDylibName = @"libswiftCompatibilityPacks.dylib";

// 日志通知名称
NSNotificationName const kECLogNotification = @"kECLogNotification";

// 内部日志宏
#define ECLog(format, ...)                                                     \
  [[ECAppInjector sharedInstance] log:format, ##__VA_ARGS__]

@implementation ECInjectionResult
@end

@implementation ECAppInjector

+ (instancetype)sharedInstance {
  static ECAppInjector *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECAppInjector alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // 确保配置目录存在
    [self ensureBaseDirExists];
  }
  return self;
}

- (void)ensureBaseDirExists {
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:kECSpoofBaseDir]) {
    NSError *error;
    [fm createDirectoryAtPath:kECSpoofBaseDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:&error];
    if (error) {
      NSLog(@"[ECAppInjector] 创建配置目录失败: %@", error);
    }
  }
}

- (void)log:(NSString *)format, ... {
  va_list args;
  va_start(args, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  // 控制台输出
  NSLog(@"[ECAppInjector] %@", message);

  // 发送通知
  dispatch_async(dispatch_get_main_queue(), ^{
    [[NSNotificationCenter defaultCenter]
        postNotificationName:kECLogNotification
                      object:nil
                    userInfo:@{@"message" : message}];
  });
}

#pragma mark - Mach-O 操作

/// 从 APP 路径获取主二进制文件路径
- (NSString *)mainBinaryPathForApp:(NSString *)appPath {
  NSString *infoPlistPath =
      [appPath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *infoPlist =
      [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
  NSString *executableName = infoPlist[@"CFBundleExecutable"];

  if (!executableName) {
    return nil;
  }

  return [appPath stringByAppendingPathComponent:executableName];
}

/// 检查 Mach-O 是否已包含指定的 dylib load command
- (BOOL)machOHasLoadCommand:(NSString *)binaryPath
                   forDylib:(NSString *)dylibPath {
  NSFileHandle *fileHandle =
      [NSFileHandle fileHandleForReadingAtPath:binaryPath];
  if (!fileHandle) {
    return NO;
  }

  // 只读取前 32KB (足够包含 Load Commands)
  NSData *data = [fileHandle readDataOfLength:32 * 1024];
  [fileHandle closeFile];

  if (!data || data.length < sizeof(struct mach_header_64)) {
    return NO;
  }

  const void *bytes = data.bytes;
  const struct mach_header_64 *header = (const struct mach_header_64 *)bytes;

  // 检查是否是 64 位 Mach-O
  if (header->magic != MH_MAGIC_64) {
    return NO;
  }

  // 遍历 load commands
  // 确保不越界
  if (sizeof(struct mach_header_64) + header->sizeofcmds > data.length) {
    // 如果 header 大小超过 32KB，则认为异常或文件特殊，保守返回 NO
    return NO;
  }

  const uint8_t *ptr = (const uint8_t *)bytes + sizeof(struct mach_header_64);

  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)ptr;

    // Bounds check
    if ((const uint8_t *)lc + sizeof(struct load_command) >
        (const uint8_t *)bytes + data.length) {
      break;
    }

    if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
      const struct dylib_command *dylib_cmd = (const struct dylib_command *)ptr;

      // Bounds check for name offset
      if ((const uint8_t *)lc + dylib_cmd->dylib.name.offset <
          (const uint8_t *)bytes + data.length) {
        const char *name = (const char *)ptr + dylib_cmd->dylib.name.offset;
        // Ensure name string is within buffer
        if (strstr(name, dylibPath.UTF8String) != NULL) {
          return YES;
        }
      }
    }

    ptr += lc->cmdsize;
  }

  return NO;
}

/// 修补 Mach-O 的 cryptid 字段，使脱壳二进制"看起来"仍然加密
/// 这可以欺骗 TikTok 等应用的完整性检测
/// @param binaryPath 二进制文件路径
/// @return YES 如果成功修补或无需修补，NO 如果失败
- (BOOL)patchCryptidForBinary:(NSString *)binaryPath {
  ECLog(@"[Cryptid] 开始检查二进制: %@", [binaryPath lastPathComponent]);

  // 使用 root helper 读取文件，因为目标可能在只读目录
  NSData *data = [NSData dataWithContentsOfFile:binaryPath];
  if (!data || data.length < sizeof(struct mach_header_64)) {
    ECLog(@"[Cryptid] ❌ 无法读取二进制或文件太小");
    return NO;
  }

  const void *bytes = data.bytes;
  uint32_t magic = *(const uint32_t *)bytes;

  // 处理 FAT 二进制 (Universal Binary)
  uint32_t offset = 0;
  if (magic == FAT_CIGAM || magic == FAT_MAGIC) {
    // FAT 头: 需要找到 arm64 slice
    const struct fat_header *fatHeader = (const struct fat_header *)bytes;
    uint32_t nfat_arch = OSSwapBigToHostInt32(fatHeader->nfat_arch);

    for (uint32_t i = 0; i < nfat_arch; i++) {
      const struct fat_arch *arch =
          (const struct fat_arch *)(bytes + sizeof(struct fat_header) +
                                    i * sizeof(struct fat_arch));
      cpu_type_t cputype = OSSwapBigToHostInt32(arch->cputype);
      if (cputype == CPU_TYPE_ARM64) {
        offset = OSSwapBigToHostInt32(arch->offset);
        ECLog(@"[Cryptid] 📦 FAT binary, arm64 slice at offset: %u", offset);
        break;
      }
    }
    if (offset == 0) {
      ECLog(@"[Cryptid] ⚠️ FAT binary 中未找到 arm64 架构");
      return YES; // 不是错误，只是没有 arm64
    }
  }

  // 验证 Mach-O 64-bit magic
  const struct mach_header_64 *header =
      (const struct mach_header_64 *)(bytes + offset);
  if (header->magic != MH_MAGIC_64) {
    ECLog(@"[Cryptid] ⚠️ 不是 64 位 Mach-O，跳过");
    return YES;
  }

  // 遍历 load commands 查找 LC_ENCRYPTION_INFO_64
  const uint8_t *ptr =
      (const uint8_t *)bytes + offset + sizeof(struct mach_header_64);
  uint32_t encryptionCmdOffset = 0;
  uint32_t currentCryptid = UINT32_MAX;

  for (uint32_t i = 0; i < header->ncmds; i++) {
    const struct load_command *lc = (const struct load_command *)ptr;

    // 边界检查
    if ((ptr - (const uint8_t *)bytes) + sizeof(struct load_command) >
        data.length) {
      break;
    }

    if (lc->cmd == LC_ENCRYPTION_INFO_64) {
      const struct encryption_info_command_64 *enc =
          (const struct encryption_info_command_64 *)ptr;
      currentCryptid = enc->cryptid;
      encryptionCmdOffset = (uint32_t)(ptr - (const uint8_t *)bytes);

      ECLog(@"[Cryptid] 📍 找到 LC_ENCRYPTION_INFO_64, cryptid = %u",
            currentCryptid);
      break;
    }

    ptr += lc->cmdsize;
  }

  if (encryptionCmdOffset == 0) {
    ECLog(@"[Cryptid] ⚠️ 未找到 LC_ENCRYPTION_INFO_64 (可能是 App Store "
          @"版本或纯净编译)");
    return YES; // 不是错误，只是没有加密信息段
  }

  if (currentCryptid == 1) {
    ECLog(@"[Cryptid] ✅ cryptid 已经是 1 (显示为加密)，无需修补");
    return YES;
  }

  // cryptid == 0 表示已解密，需要修补为 1
  ECLog(@"[Cryptid] 🔧 cryptid = 0 (脱壳状态)，开始修补为 1...");

  // 计算 cryptid 字段在文件中的偏移
  // LC_ENCRYPTION_INFO_64 结构: cmd(4) + cmdsize(4) + cryptoff(4) +
  // cryptsize(4)
  // + cryptid(4) cryptid 的偏移 = encryptionCmdOffset + 16 bytes
  uint32_t cryptidFieldOffset =
      encryptionCmdOffset +
      offsetof(struct encryption_info_command_64, cryptid);

  // 创建修改后的数据
  NSMutableData *modifiedData = [data mutableCopy];
  uint32_t newCryptid = 1; // 伪装为加密状态
  [modifiedData replaceBytesInRange:NSMakeRange(cryptidFieldOffset, 4)
                          withBytes:&newCryptid];

  // 写入临时文件
  NSString *tempPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"cryptid_patch_%@.bin",
                                     [[NSUUID UUID] UUIDString]]];

  if (![modifiedData writeToFile:tempPath atomically:YES]) {
    ECLog(@"[Cryptid] ❌ 写入临时文件失败");
    return NO;
  }

  // 使用 root helper 复制回原位置
  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(rootHelperPath(), @[ @"copy-file", tempPath, binaryPath ],
                      &stdOut, &stdErr);

  // 清理临时文件
  [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

  if (ret == 0) {
    ECLog(@"[Cryptid] ✅ 成功修补 cryptid 为 1");
    return YES;
  } else {
    ECLog(@"[Cryptid] ❌ 复制失败 (ret=%d): %@ / %@", ret, stdOut, stdErr);
    return NO;
  }
}

- (NSString *)getOutputFromHelper:(NSArray *)args {
  NSString *stdOut = nil;
  NSString *stdErr = nil;

  NSString *helperPath = rootHelperPath();

  // 1. 检查辅助工具路径是否存在
  if (![[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
    NSString *err =
        [NSString stringWithFormat:@"❌ Helper 缺失: %@", helperPath];
    ECLog(@"%@", err);
    return err;
  }

  int ret = spawnRoot(helperPath, args, &stdOut, &stdErr);

  NSMutableString *output = [NSMutableString string];
  if (stdOut)
    [output appendString:stdOut];
  if (stdErr) {
    if (output.length > 0)
      [output appendString:@"\n"];
    [output appendString:stdErr];
  }

  // 2. 如果输出为空但返回码非0，补全信息
  if (output.length == 0 && ret != 0) {
    [output appendFormat:@"❌ spawnRoot 失败，代码: %d (无输出捕获)", ret];
  }

  ECLog(@"[Helper] spawnRoot 返回: %d. 输出: %@", ret, output);

  return output;
}

- (NSString *)fetchMainAppTeamID:(NSString *)appPath {
  NSString *executableName =
      [[NSBundle bundleWithPath:appPath] infoDictionary][@"CFBundleExecutable"];
  if (!executableName) {
    NSDictionary *plist = [NSDictionary
        dictionaryWithContentsOfFile:
            [appPath stringByAppendingPathComponent:@"Info.plist"]];
    executableName = plist[@"CFBundleExecutable"];
  }
  if (!executableName) {
    ECLog(@"[TeamID] ❌ 无法获取 CFBundleExecutable");
    return nil;
  }

  NSString *binaryPath =
      [appPath stringByAppendingPathComponent:executableName];
  ECLog(@"[TeamID] === 尝试所有方法获取 Team ID ===");
  ECLog(@"[TeamID] App路径: %@", appPath);
  ECLog(@"[TeamID] 二进制: %@", binaryPath);

  NSString *result = nil;

  // ========== 方法 0: 检查已保存的 Team ID (最高优先级) ==========
  // 这个文件由 root helper 的 "save-teamid" 命令写入
  // 仅在手动脱壳并记录 ID 后有效
  NSString *plistPath =
      @"/var/mobile/Library/Preferences/com.ecmain.teamids.plist";
  if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
    NSDictionary *savedIds =
        [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *bundleID = [[NSBundle bundleWithPath:appPath] bundleIdentifier];
    if (!bundleID) {
      NSDictionary *plist = [NSDictionary
          dictionaryWithContentsOfFile:
              [appPath stringByAppendingPathComponent:@"Info.plist"]];
      bundleID = plist[@"CFBundleIdentifier"];
    }
    if (bundleID && savedIds[bundleID]) {
      result = savedIds[bundleID];
      ECLog(@"[TeamID] ✅ 从已保存记录中找到 Team ID: %@", result);
      return result;
    }
  }

  // ========== 方法 1: Native dumpEntitlements (ECMain internal) ==========
  ECLog(@"[TeamID] 方法1: Native dumpEntitlements...");

  NSDictionary *entitlements = dumpEntitlementsFromBinaryAtPath(binaryPath);
  if (entitlements) {
    NSString *tid = entitlements[@"com.apple.developer.team-identifier"];
    if (tid && [tid isKindOfClass:[NSString class]] && tid.length > 0) {
      ECLog(@"[TeamID] ✅ Native Success: %@", tid);
      return tid;
    }
  }
  ECLog(@"[TeamID] ❌ Native Method failed");

  // ========== 方法 2: embedded.mobileprovision ==========
  ECLog(@"[TeamID] 方法2: embedded.mobileprovision...");
  result = [self extractTeamIDFromProvisioningProfile:appPath];
  if (result && result.length > 0) {
    ECLog(@"[TeamID] ✅ 方法2成功: %@", result);
    return result;
  }
  ECLog(@"[TeamID] ❌ 方法2失败");

  // ========== 方法 3: iTunesMetadata.plist ==========
  ECLog(@"[TeamID] 方法3: iTunesMetadata.plist...");
  result = [self extractTeamIDFromiTunesMetadata:appPath];
  if (result && result.length > 0) {
    ECLog(@"[TeamID] ✅ 方法3成功: %@", result);
    return result;
  }
  ECLog(@"[TeamID] ❌ 方法3失败");

  // ========== 方法 4: 尝试 Frameworks 目录中的其他二进制 ==========
  ECLog(@"[TeamID] 方法4: 遍历所有 Frameworks...");
  result = [self extractTeamIDFromFrameworks:appPath];
  if (result && result.length > 0) {
    ECLog(@"[TeamID] ✅ 方法4成功: %@", result);
    return result;
  }
  ECLog(@"[TeamID] ❌ 方法4失败");

  ECLog(@"[TeamID] ❌ 所有4种方法均失败，无法获取 Team ID");
  return nil;
}

/// 从 Framework 二进制提取 Team ID
- (NSString *)fetchTeamIDFromBinary:(NSString *)binaryPath {
  ECLog(@"[TeamID] 尝试从二进制提取: %@", binaryPath);
  NSString *output =
      [self getOutputFromHelper:@[ @"print-teamid", binaryPath ]];
  if (output) {
    NSString *trimmed = [output
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 0) {
      ECLog(@"[TeamID] ✅ 找到 Team ID: %@", trimmed);
      return trimmed;
    }
  }
  ECLog(@"[TeamID] ❌ 未找到 Team ID");
  return nil;
}

/// 方法2: 从 embedded.mobileprovision 提取 Team ID
- (NSString *)extractTeamIDFromProvisioningProfile:(NSString *)appPath {
  NSString *provisionPath =
      [appPath stringByAppendingPathComponent:@"embedded.mobileprovision"];
  NSFileManager *fm = [NSFileManager defaultManager];

  if (![fm fileExistsAtPath:provisionPath]) {
    ECLog(@"[TeamID] embedded.mobileprovision 不存在");
    return nil;
  }

  NSData *data = [NSData dataWithContentsOfFile:provisionPath];
  if (!data)
    return nil;

  // mobileprovision 是 CMS 签名的 plist，提取 plist 部分
  NSString *content = [[NSString alloc] initWithData:data
                                            encoding:NSASCIIStringEncoding];
  if (!content)
    content = [[NSString alloc] initWithData:data
                                    encoding:NSUTF8StringEncoding];
  if (!content)
    return nil;

  NSRange plistStart = [content rangeOfString:@"<?xml"];
  if (plistStart.location == NSNotFound)
    plistStart = [content rangeOfString:@"<plist"];
  NSRange plistEnd = [content rangeOfString:@"</plist>"];

  if (plistStart.location == NSNotFound || plistEnd.location == NSNotFound)
    return nil;

  NSRange plistRange =
      NSMakeRange(plistStart.location,
                  plistEnd.location + plistEnd.length - plistStart.location);
  NSString *plistString = [content substringWithRange:plistRange];
  NSData *plistData = [plistString dataUsingEncoding:NSUTF8StringEncoding];

  NSDictionary *plist =
      [NSPropertyListSerialization propertyListWithData:plistData
                                                options:0
                                                 format:nil
                                                  error:nil];
  if (!plist)
    return nil;

  // 1. TeamIdentifier 数组
  NSArray *teamIds = plist[@"TeamIdentifier"];
  if (teamIds.count > 0) {
    ECLog(@"[TeamID] 从 TeamIdentifier 获取: %@", teamIds.firstObject);
    return teamIds.firstObject;
  }

  // 2. Entitlements 中的 team-identifier
  NSDictionary *entitlements = plist[@"Entitlements"];
  if (entitlements) {
    NSString *tid = entitlements[@"com.apple.developer.team-identifier"];
    if (tid.length > 0) {
      ECLog(@"[TeamID] 从 Entitlements 获取: %@", tid);
      return tid;
    }

    // 3. application-identifier 前缀
    NSString *appId = entitlements[@"application-identifier"];
    if (appId && [appId containsString:@"."]) {
      NSString *prefix = [[appId componentsSeparatedByString:@"."] firstObject];
      if (prefix.length == 10) {
        ECLog(@"[TeamID] 从 application-identifier 前缀获取: %@", prefix);
        return prefix;
      }
    }
  }

  return nil;
}

/// 方法3: 从 iTunesMetadata.plist 提取 Team ID
- (NSString *)extractTeamIDFromiTunesMetadata:(NSString *)appPath {
  // 尝试 App 目录和上级目录
  NSArray *paths = @[
    [appPath stringByAppendingPathComponent:@"iTunesMetadata.plist"],
    [[appPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"iTunesMetadata.plist"]
  ];

  for (NSString *metadataPath in paths) {
    NSDictionary *metadata =
        [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    if (metadata) {
      ECLog(@"[TeamID] 找到 iTunesMetadata: %@", metadataPath);
      // 尝试各种可能的字段
      NSString *teamId = metadata[@"TeamID"];
      if (teamId.length > 0)
        return teamId;

      teamId = metadata[@"teamID"];
      if (teamId.length > 0)
        return teamId;

      // 打印所有 key 供调试
      ECLog(@"[TeamID] iTunesMetadata keys: %@",
            [metadata.allKeys componentsJoinedByString:@", "]);
    }
  }
  return nil;
}

/// 方法4: 遍历 Frameworks 目录尝试提取 Team ID
- (NSString *)extractTeamIDFromFrameworks:(NSString *)appPath {
  NSString *frameworksDir =
      [appPath stringByAppendingPathComponent:@"Frameworks"];
  NSFileManager *fm = [NSFileManager defaultManager];

  if (![fm fileExistsAtPath:frameworksDir])
    return nil;

  NSArray *contents = [fm contentsOfDirectoryAtPath:frameworksDir error:nil];
  for (NSString *item in contents) {
    if ([item.pathExtension isEqualToString:@"framework"]) {
      NSString *fwPath = [frameworksDir stringByAppendingPathComponent:item];
      NSString *fwName = [item stringByDeletingPathExtension];
      NSString *binaryPath = [fwPath stringByAppendingPathComponent:fwName];

      if ([fm fileExistsAtPath:binaryPath]) {
        ECLog(@"[TeamID] 尝试 Framework: %@", item);
        NSString *output =
            [self getOutputFromHelper:@[ @"print-teamid", binaryPath ]];
        if (output) {
          NSString *trimmed =
              [output stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          if (trimmed.length > 0) {
            ECLog(@"[TeamID] ✅ 从 Framework %@ 获取: %@", item, trimmed);
            return trimmed;
          }
        }
      }
    }
  }
  return nil;
}

#pragma mark - 注入操作

- (BOOL)saveTeamIDForBinary:(NSString *)binaryPath error:(NSError **)error {
  ECLog(@"[TeamID] 保存 Team ID: %@", binaryPath);
  NSString *output = [self getOutputFromHelper:@[ @"save-teamid", binaryPath ]];
  // trim whitespace
  NSString *trimmed = [output
      stringByTrimmingCharactersInSet:[NSCharacterSet
                                          whitespaceAndNewlineCharacterSet]];

  // check for success in output? Helper returns 0 on success.
  // Actually getOutputFromHelper returns stdout. Our helper prints
  // "[save-teamid] ✅ Saved mapping..." on success.

  if ([trimmed containsString:@"Saved mapping"]) {
    ECLog(@"[TeamID] ✅ 保存成功");
    return YES;
  }

  ECLog(@"[TeamID] ❌ 保存失败: %@", trimmed);
  if (error) {
    *error = [NSError
        errorWithDomain:@"ECAppInjector"
                   code:3
               userInfo:@{NSLocalizedDescriptionKey : @"保存 Team ID 失败"}];
  }
  return NO;
}

- (BOOL)resignBinary:(NSString *)binaryPath
          withTeamID:(NSString *)teamID
               error:(NSError **)error {
  ECLog(@"[Resign] 重签二进制: %@, TeamID: %@", binaryPath, teamID);

  // Call helper with force Team ID arg
  NSString *output =
      [self getOutputFromHelper:@[ @"sign-binary", binaryPath, teamID ]];

  if ([output containsString:@"CoreTrust bypass applied!"]) {
    ECLog(@"[Resign] ✅ 重签成功. 新 Team ID 已注入 entitlements.");

    // Also save this Team ID to plist for future use
    [self getOutputFromHelper:@[
      @"save-teamid", binaryPath
    ]]; // This might fail extraction again, but we should manually update plist
    // Actually save-teamid command extracts from binary. Since we just resigned
    // it with new TeamID, the new Entitlements SHOULD have it, so save-teamid
    // should work now!

    return YES;
  }

  ECLog(@"[Resign] ❌ 重签失败: %@", output);
  if (error) {
    *error =
        [NSError errorWithDomain:@"ECAppInjector"
                            code:5
                        userInfo:@{
                          NSLocalizedDescriptionKey : [NSString stringWithFormat:@"重签失败: %@", output]
                        }];
  }
  return NO;
}

/// 重签 App Bundle 内的所有二进制文件 (Frameworks, PlugIns, dylibs)
- (void)resignAllBundleBinaries:(NSString *)appPath teamID:(NSString *)teamID {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSMutableArray *binariesToSign = [NSMutableArray array];

  // 1. 收集 Frameworks 目录下的二进制
  NSString *frameworksDir =
      [appPath stringByAppendingPathComponent:@"Frameworks"];
  if ([fm fileExistsAtPath:frameworksDir]) {
    NSArray *frameworks = [fm contentsOfDirectoryAtPath:frameworksDir
                                                  error:nil];
    for (NSString *item in frameworks) {
      NSString *itemPath = [frameworksDir stringByAppendingPathComponent:item];

      if ([item hasSuffix:@".framework"]) {
        // Framework: 读取 Info.plist 获取可执行文件名
        NSString *infoPlistPath =
            [itemPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info =
            [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *execName = info[@"CFBundleExecutable"];
        if (!execName) {
          // 默认使用 Framework 名称（去掉 .framework 后缀）
          execName = [item stringByDeletingPathExtension];
        }
        NSString *binaryPath =
            [itemPath stringByAppendingPathComponent:execName];
        if ([fm fileExistsAtPath:binaryPath]) {
          [binariesToSign addObject:binaryPath];
        }
      } else if ([item hasSuffix:@".dylib"]) {
        // 独立 dylib
        [binariesToSign addObject:itemPath];
      }
    }
  }

  // 2. 收集 PlugIns 目录下的 App Extension 二进制
  NSString *pluginsDir = [appPath stringByAppendingPathComponent:@"PlugIns"];
  if ([fm fileExistsAtPath:pluginsDir]) {
    NSArray *plugins = [fm contentsOfDirectoryAtPath:pluginsDir error:nil];
    for (NSString *plugin in plugins) {
      if ([plugin hasSuffix:@".appex"]) {
        NSString *pluginPath =
            [pluginsDir stringByAppendingPathComponent:plugin];
        NSString *infoPlistPath =
            [pluginPath stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *info =
            [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
        NSString *execName = info[@"CFBundleExecutable"];
        if (!execName) {
          execName = [plugin stringByDeletingPathExtension];
        }
        NSString *binaryPath =
            [pluginPath stringByAppendingPathComponent:execName];
        if ([fm fileExistsAtPath:binaryPath]) {
          [binariesToSign addObject:binaryPath];
        }
      }
    }
  }

  ECLog(@"[Bundle Resign] 找到 %lu 个二进制需要重签",
        (unsigned long)binariesToSign.count);

  // 3. 逐个签名
  for (NSString *binaryPath in binariesToSign) {
    ECLog(@"[Bundle Resign] 签名: %@", binaryPath.lastPathComponent);

    // ★ 在签名前先修补 cryptid (使脱壳二进制看起来仍然加密)
    [self patchCryptidForBinary:binaryPath];

    int ret;
    if (teamID && teamID.length > 0) {
      // 有 Team ID：使用 sign-binary 命令
      NSMutableArray *signArgs =
          [NSMutableArray arrayWithObjects:@"sign-binary", binaryPath, nil];
      [signArgs addObject:teamID];
      ret = spawnRoot(rootHelperPath(), signArgs, nil, nil);
    } else {
      // 无 Team ID：使用 ct-bypass 命令 (TrollStore adhoc 签名)
      // 这适用于已脱壳的应用
      ret =
          spawnRoot(rootHelperPath(), @[ @"ct-bypass", binaryPath ], nil, nil);
    }

    if (ret != 0) {
      ECLog(@"[Bundle Resign] ⚠️ 签名失败: %@ (ret=%d)",
            binaryPath.lastPathComponent, ret);
    }
  }

  ECLog(@"[Bundle Resign] ✅ Bundle 重签完成");
}

- (BOOL)injectSpoofDylibIntoApp:(NSString *)appPath error:(NSError **)error {
  return [self injectSpoofDylibIntoApp:appPath
                        executablePath:nil
                          manualTeamID:nil
                                 error:error];
}

- (BOOL)injectSpoofDylibIntoApp:(NSString *)appPath
                   manualTeamID:(NSString *)teamID
                          error:(NSError **)error {
  return [self injectSpoofDylibIntoApp:appPath
                        executablePath:nil
                          manualTeamID:teamID
                                 error:error];
}

- (BOOL)injectSpoofDylibIntoApp:(NSString *)appPath
                 executablePath:(NSString *)executablePath
                   manualTeamID:(NSString *)manualTeamID
                          error:(NSError **)error {
  NSString *appName = appPath.lastPathComponent;
  ECLog(@"[注入开始] 目标: %@", appName);
  ECLog(@"[Injector] 开始处理 APP: %@", appPath);

  // 1. 获取主二进制路径
  NSFileManager *fm = [NSFileManager defaultManager];

  // 验证 APP 路径
  BOOL isDir;
  if (![fm fileExistsAtPath:appPath isDirectory:&isDir] || !isDir) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"APP 路径不存在"}];
    }
    return NO;
  }

  NSString *binaryPath = executablePath;
  // 如果未提供或文件不存在，尝试自动解析
  if (!binaryPath || ![fm fileExistsAtPath:binaryPath]) {
    binaryPath = [self mainBinaryPathForApp:appPath];
  }

  if (!binaryPath || ![fm fileExistsAtPath:binaryPath]) {
    NSString *msg = @"无法找到主二进制文件 (Info.plist 读取失败?)";
    ECLog(@"[注入失败] ❌ %@, 原因: %@", appName, msg);
    if (error) {
      *error = [NSError errorWithDomain:@"ECAppInjector"
                                   code:2
                               userInfo:@{NSLocalizedDescriptionKey : msg}];
    }
    return NO;
  }

  ECLog(@"[Injector] 主二进制: %@", binaryPath);

  // 3. 检查是否已注入
  if ([self machOHasLoadCommand:binaryPath forDylib:kSpoofDylibName]) {
    ECLog(@"APP 已注入，跳过: %@", appPath.lastPathComponent);
    return YES;
  }

  // 4. 复制 dylib 到 APP 包
  // 优先级 1: Dylibs 目录（tar 包结构）
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  NSString *sourceDylib =
      [bundlePath stringByAppendingPathComponent:
                      @"Dylibs/libswiftCompatibilityPacks.dylib"];

  // 优先级 2: 根目录（开发环境）
  if (![fm fileExistsAtPath:sourceDylib]) {
    sourceDylib = [bundlePath
        stringByAppendingPathComponent:@"libswiftCompatibilityPacks.dylib"];
  }

  // 优先级 3: 资源文件
  if (![fm fileExistsAtPath:sourceDylib]) {
    sourceDylib =
        [[NSBundle mainBundle] pathForResource:@"libswiftCompatibilityPacks"
                                        ofType:@"dylib"];
  }

  if (![fm fileExistsAtPath:sourceDylib]) {
    ECLog(@"错误: 找不到 libswiftCompatibilityPacks.dylib，搜索路径: %@",
          sourceDylib);
    if (error) {
      *error =
          [NSError errorWithDomain:@"ECAppInjector"
                              code:3
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"找不到 libswiftCompatibilityPacks.dylib 文件"
                          }];
    }
    return NO;
  }

  ECLog(@"找到 dylib: %@", sourceDylib);

  NSString *destDylib =
      [appPath stringByAppendingPathComponent:kSpoofDylibName];

  // Refactor: Sign dylib in TEMP directory instead of directly in App Bundle.
  // This avoids potential sandbox/permission issues causing ldid/codesign error
  // 175.
  NSString *tempDylibUUID = [[NSUUID UUID] UUIDString];
  NSString *tempDylibPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.dylib",
                                                                tempDylibUUID]];

  // Copy to temp
  [[NSFileManager defaultManager] removeItemAtPath:tempDylibPath error:nil];
  [[NSFileManager defaultManager] copyItemAtPath:sourceDylib
                                          toPath:tempDylibPath
                                           error:nil];

  // 获取主程序 Team ID (统一使用，解决依赖库TeamID不一致问题)
  NSString *teamID = manualTeamID;
  if (teamID && teamID.length > 0) {
    ECLog(@"✅ 使用手动指定的 Team ID: %@", teamID);
  } else {
    teamID = [self fetchMainAppTeamID:appPath];
  }

  if (teamID) {
    ECLog(@"✅ 获取到 Team ID: %@", teamID);
  } else {
    ECLog(@"⚠️ 未能获取主程序 Team ID，使用默认签名 (可能导致 crash)");
  }

  // 5. 尝试注入主二进制
  // We pass tempDylibPath here. processBinary will sign this file.
  NSError *mainInjectError = nil;
  NSString *lcPath =
      [@"@executable_path" stringByAppendingPathComponent:kSpoofDylibName];

  BOOL injectSuccess = [self processBinary:binaryPath
                      injectingDylibAtPath:tempDylibPath
                           loadCommandPath:lcPath
                                    teamID:teamID
                                     error:&mainInjectError];

  if (injectSuccess) {
    // 6. Sign success, now move temp dylib to App Bundle
    ECLog(@"[Injector] Dylib signed in temp, moving to bundle...");

    spawnRoot(rootHelperPath(), @[ @"remove-file", destDylib ], nil, nil);
    int cpRet =
        spawnRoot(rootHelperPath(), @[ @"copy-file", tempDylibPath, destDylib ],
                  nil, nil);

    if (cpRet != 0) {
      ECLog(@"❌ Failed to copy signed dylib to bundle: %d", cpRet);
      if (error)
        *error = [NSError
            errorWithDomain:@"ECAppInjector"
                       code:cpRet
                   userInfo:@{
                     NSLocalizedDescriptionKey : @"Failed to copy signed dylib"
                   }];
      [[NSFileManager defaultManager] removeItemAtPath:tempDylibPath error:nil];
      return NO;
    }

    spawnRoot(rootHelperPath(), @[ @"chmod-file", @"755", destDylib ], nil,
              nil);

    ECLog(@"✅ Dylib installed successfully: %@", destDylib);
    [[NSFileManager defaultManager] removeItemAtPath:tempDylibPath error:nil];

    // NOTE: We do NOT resign other binaries in the bundle.
    // ...
  } else {
    ECLog(@"❌ Injection/Signing process failed.");
    if (error)
      *error = mainInjectError;
    [[NSFileManager defaultManager] removeItemAtPath:tempDylibPath error:nil];
    return NO;
  }

  if (injectSuccess) { // Just simpler logic structure to match original flow
                       // where next step is marker creation

    // ── loose .dylib 签名策略 ────────────────────────────────────────────────
    // 注意: 不要在这里预签名 Frameworks/ 下的 loose .dylib！
    // 原因: "分身安装(System)" 能正常工作说明 TrollStore CTLoop 可以正确处理
    //       原始 App Store 签名的 dylib。
    // 预签名（sign-binary ad-hoc）会破坏 App Store CodeDirectory 的结构，
    // 导致 CTLoop 二次 bypass 时产生 sliceOffset=0x0 的无效签名。
    // 正确做法: 保留原始 App Store 签名，由 CTLoop 在安装时做一次 bypass 即可。

    // 7. 创建注入标记
    // touch-file replacement (Use Helper for Root Permission)
    NSString *markerPath =
        [appPath stringByAppendingPathComponent:kInjectionMarker];
    int markerRet =
        spawnRoot(rootHelperPath(), @[ @"touch-file", markerPath ], nil, nil);
    // Ensure readable by mobile (666)
    spawnRoot(rootHelperPath(), @[ @"chmod-file", @"666", markerPath ], nil,
              nil);
    ECLog(@"[Injection] Marker creation ret: %d, Path: %@", markerRet,
          markerPath);

    ECLog(@"✅ 注入主程序成功: %@", appPath.lastPathComponent);
    return YES;
  }

  // 注入失败，检查是否因为加密 (Code 20)
  if (mainInjectError.code == 20) {
    ECLog(@"⚠️ 主程序已加密 (FairPlay)，尝试注入 Frameworks (Bypass Scheme)...");
    NSError *fwError = nil;
    if ([self injectIntoFrameworksOfApp:appPath teamID:teamID error:&fwError]) {
      ECLog(@"✅ 通过 Framework 注入成功 workaround!");
      return YES;
    } else {
      ECLog(@"❌ Framework 注入也失败: %@", fwError);
      // 返回主程序的加密错误，让用户明确知道是因为加密导致
      if (error)
        *error = mainInjectError;

      ECLog(@"[注入失败] ❌ %@, 原因: 主程序加密且 Framework 注入失败",
            appName);
      return NO;
    }
  }

  if (error)
    *error = mainInjectError;
  return NO;
}

/// Post-install fix: 对已安装 bundle 的 Frameworks/ loose .dylib 做最终重签
/// TrollStore CTLoop 二次 bypass 后 libswiftCompatibilityPacks.dylib 等签名会损坏
/// 调用此方法可覆盖 CTLoop 产生的错误签名
- (void)fixLooseDylibSignaturesForInstalledBundle:(NSString *)installedAppBundlePath {
  NSString *fwDir = [installedAppBundlePath stringByAppendingPathComponent:@"Frameworks"];
  NSArray *fwContents = [[NSFileManager defaultManager]
      contentsOfDirectoryAtPath:fwDir error:nil];
  if (!fwContents) {
    ECLog(@"[FixLooseDylib] Frameworks 目录不存在或无法读取: %@", fwDir);
    return;
  }
  for (NSString *item in fwContents) {
    if (![item hasSuffix:@".dylib"]) continue;
    NSString *dylibFullPath = [fwDir stringByAppendingPathComponent:item];
    ECLog(@"[FixLooseDylib] 最终重签 (post-install, no TeamID): %@", item);
    // 不传 TeamID → sign-binary 走 ad-hoc+CT bypass 路径
    // 这样可以清除 CTLoop 留下的错误签名结构
    int fixRet = spawnRoot(rootHelperPath(),
        @[@"sign-binary", dylibFullPath], nil, nil);
    ECLog(@"[FixLooseDylib] sign-binary ret=%d for %@", fixRet, item);
  }
  ECLog(@"[FixLooseDylib] ✅ 修复完成: %@", installedAppBundlePath);
}


- (BOOL)injectLoadCommandIntoBinary:(NSString *)binaryPath
                          dylibPath:(NSString *)dylibPath
                              error:(NSError **)error {
  // 使用 NSFileHandle 进行原地编辑，避免在大文件时消耗过多内存
  NSFileHandle *fileHandle =
      [NSFileHandle fileHandleForUpdatingAtPath:binaryPath];
  if (!fileHandle) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:10
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"无法打开二进制文件进行写入"
                 }];
    }
    return NO;
  }

  // 1. 读取 Mach-O Header
  NSData *headerData =
      [fileHandle readDataOfLength:sizeof(struct mach_header_64)];
  if (headerData.length < sizeof(struct mach_header_64)) {
    [fileHandle closeFile];
    if (error)
      *error =
          [NSError errorWithDomain:@"ECAppInjector"
                              code:11
                          userInfo:@{NSLocalizedDescriptionKey : @"文件过小"}];
    return NO;
  }

  // 必须使用 mutableBytes 以便后续修改 header
  NSMutableData *mutableHeaderData = [headerData mutableCopy];
  struct mach_header_64 *header =
      (struct mach_header_64 *)mutableHeaderData.mutableBytes;

  if (header->magic != MH_MAGIC_64) {
    [fileHandle closeFile];
    if (error) {
      *error =
          [NSError errorWithDomain:@"ECAppInjector"
                              code:11
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"不支持的 Mach-O 格式"
                          }];
    }
    return NO;
  }

  // 2. 读取 Load Commands
  // 仅读取 Load Commands 区域，通常只有几 KB，而不是整个文件
  [fileHandle seekToFileOffset:sizeof(struct mach_header_64)];
  NSData *lcData = [fileHandle readDataOfLength:header->sizeofcmds];
  if (lcData.length < header->sizeofcmds) {
    [fileHandle closeFile];
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:12
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Load Commands 读取失败"
                 }];
    return NO;
  }

  const uint8_t *lcBytes = lcData.bytes;
  uint32_t lcOffset = 0;

  // 检查是否加密 (FairPlay)
  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (lcOffset + sizeof(struct load_command) > lcData.length)
      break;

    const struct load_command *lc =
        (const struct load_command *)(lcBytes + lcOffset);
    if (lc->cmd == LC_ENCRYPTION_INFO_64) {
      const struct encryption_info_command_64 *enc =
          (const struct encryption_info_command_64 *)lc;
      if (enc->cryptid != 0) {
        [fileHandle closeFile];
        ECLog(@"错误: 二进制文件已加密 (cryptid=%d). 无法直接注入.",
              enc->cryptid);
        if (error) {
          *error = [NSError
              errorWithDomain:@"ECAppInjector"
                         code:20
                     userInfo:@{
                       NSLocalizedDescriptionKey :
                           @"应用已加密 (FairPlay)。请先解密应用再进行注入。"
                     }];
        }
        return NO;
      }
    }
    lcOffset += lc->cmdsize;
  }

  // 查找第一个 Segment 的偏移量，计算可用空间
  size_t loadCmdsEnd = sizeof(struct mach_header_64) + header->sizeofcmds;
  size_t firstSegmentOffset = 0;
  // [v2260] 同时查找第一个 LC_LOAD_DYLIB 的偏移量，用于前置插入
  size_t firstLoadDylibOffset = 0;
  lcOffset = 0;

  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (lcOffset + sizeof(struct load_command) > lcData.length)
      break;
    const struct load_command *lc =
        (const struct load_command *)(lcBytes + lcOffset);

    if (lc->cmd == LC_SEGMENT_64) {
      const struct segment_command_64 *seg =
          (const struct segment_command_64 *)lc;
      if (seg->fileoff > 0 &&
          (firstSegmentOffset == 0 || seg->fileoff < firstSegmentOffset)) {
        firstSegmentOffset = seg->fileoff;
      }
    }
    // [v2260] 记录第一个 LC_LOAD_DYLIB 的位置
    if ((lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) &&
        firstLoadDylibOffset == 0) {
      firstLoadDylibOffset = lcOffset;
    }
    lcOffset += lc->cmdsize;
  }

  if (firstSegmentOffset == 0) {
    firstSegmentOffset = 0x4000; // Default 16KB
  }

  // 计算构建新命令所需的空间
  const char *dylibPathCStr = dylibPath.UTF8String;
  size_t dylibPathLen = strlen(dylibPathCStr) + 1;
  size_t cmdSize = sizeof(struct dylib_command) + dylibPathLen;
  cmdSize = (cmdSize + 7) & ~7; // Align 8

  size_t availableSpace = firstSegmentOffset - loadCmdsEnd;

  if (availableSpace < cmdSize) {
    [fileHandle closeFile];
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:13
                 userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:
                           @"Load commands 空间不足 (需要 %zu, 可用 %zu)",
                           cmdSize, availableSpace]
                 }];
    return NO;
  }

  // 3. 写入新 Load Command
  // 构建数据
  NSMutableData *newCmdData = [NSMutableData dataWithLength:cmdSize];
  struct dylib_command *dylib = (struct dylib_command *)newCmdData.mutableBytes;

  dylib->cmd = LC_LOAD_DYLIB;
  dylib->cmdsize = (uint32_t)cmdSize;
  dylib->dylib.name.offset = sizeof(struct dylib_command);
  dylib->dylib.timestamp = 0;
  dylib->dylib.current_version = 0x10000;
  dylib->dylib.compatibility_version = 0x10000;

  memcpy((char *)dylib + sizeof(struct dylib_command), dylibPathCStr,
         dylibPathLen);

  // [v2260] 关键修复：将 LC_LOAD_DYLIB 插入到第一个 dylib 加载命令之前
  // 这样 dyld 会优先加载我们的 dylib，使 constructor 在所有 TikTok 原生
  // Framework 的 +load 方法之前执行，彻底消除 5+ 秒的初始化延迟
  size_t insertFileOffset; // 在文件中的绝对偏移量
  if (firstLoadDylibOffset > 0) {
    // 找到了第一个 LC_LOAD_DYLIB，在其前面插入
    insertFileOffset = sizeof(struct mach_header_64) + firstLoadDylibOffset;

    // 需要将 [firstLoadDylibOffset, loadCmdsEnd) 的数据向后移动 cmdSize 字节
    // 先读取需要移动的数据
    size_t tailSize = loadCmdsEnd - insertFileOffset;
    [fileHandle seekToFileOffset:insertFileOffset];
    NSData *tailData = [fileHandle readDataOfLength:tailSize];

    // 写入我们的新 LC（占据原来第一个 LC_LOAD_DYLIB 的位置）
    [fileHandle seekToFileOffset:insertFileOffset];
    [fileHandle writeData:newCmdData];

    // 把原来的数据写回到新位置（紧跟在我们的新 LC 后面）
    [fileHandle writeData:tailData];

    ECLog(@"[v2260] ✅ LC_LOAD_DYLIB 插入到偏移 %zu (第一个 dylib LC 之前)", firstLoadDylibOffset);
  } else {
    // 没有找到任何 LC_LOAD_DYLIB（不太可能），回退到追加模式
    [fileHandle seekToFileOffset:loadCmdsEnd];
    [fileHandle writeData:newCmdData];
    ECLog(@"[v2260] ⚠️ 未找到 LC_LOAD_DYLIB，回退到追加模式");
  }

  // 4. 更新 Header
  header->ncmds += 1;
  header->sizeofcmds += cmdSize;

  [fileHandle seekToFileOffset:0];
  [fileHandle writeData:mutableHeaderData];

  [fileHandle closeFile];
  return YES;
}

- (BOOL)ejectDylibFromApp:(NSString *)appPath error:(NSError **)error {
  // 1. 尝试从备份恢复二进制
  NSString *binaryPath = [self mainBinaryPathForApp:appPath];
  if (binaryPath) {
    NSString *backupPath = [binaryPath stringByAppendingString:@".ec_bak"];
    NSFileManager *fm = [NSFileManager defaultManager];
    // 注意：RootHelper 运行在 root 权限，但检查文件可能受限？通常不会。
    // 这里最好使用 rootHelper 检查或直接尝试恢复

    // 简单起见，我们假设如果存在备份就恢复
    ECLog(@"[Eject] 尝试从备份恢复: %@", backupPath);
    spawnRoot(rootHelperPath(), @[ @"move-file", backupPath, binaryPath ], nil,
              nil);
    spawnRoot(rootHelperPath(), @[ @"chmod-file", @"755", binaryPath ], nil,
              nil);
    // 恢复后，备份文件被移动（消失），这也是合理的
  }

  // 2. 使用 trollstorehelper 删除 dylib 文件 & 标记
  NSString *dylibPath =
      [appPath stringByAppendingPathComponent:kSpoofDylibName];
  spawnRoot(rootHelperPath(), @[ @"remove-file", dylibPath ], nil, nil);

  // 3. 删除注入标记
  NSString *markerPath =
      [appPath stringByAppendingPathComponent:kInjectionMarker];
  spawnRoot(rootHelperPath(), @[ @"remove-file", markerPath ], nil, nil);

  // 4. 删除 Bundle 内的配置文件 (Frameworks/device.plist)
  NSString *configPath =
      [appPath stringByAppendingPathComponent:
                   @"Frameworks/com.apple.preferences.display.plist"];
  spawnRoot(rootHelperPath(), @[ @"remove-file", configPath ], nil, nil);

  ECLog(@"✅ 已移除注入 (及恢复备份): %@", appPath.lastPathComponent);
  return YES;
}

- (BOOL)isDylibInjectedIntoApp:(NSString *)appPath {
  return [self injectionStatusForApp:appPath] == ECInjectionStatusInjected;
}

- (ECInjectionStatus)injectionStatusForApp:(NSString *)appPath {
  NSFileManager *fm = [NSFileManager defaultManager];

  // 检查注入标记
  NSString *markerPath =
      [appPath stringByAppendingPathComponent:kInjectionMarker];
  if ([fm fileExistsAtPath:markerPath]) {
    ECLog(@"[Status] ✅ Found marker for: %@", appPath.lastPathComponent);
    return ECInjectionStatusInjected;
  } else {
    ECLog(@"[Status] ❌ Marker not found at: %@", markerPath);
  }

  // 检查 load command
  NSString *binaryPath = [self mainBinaryPathForApp:appPath];
  if (binaryPath) {
    BOOL hasLC = [self machOHasLoadCommand:binaryPath forDylib:kSpoofDylibName];
    if (hasLC) {
      ECLog(@"[Status] ✅ Found Load Command in: %@",
            binaryPath.lastPathComponent);
      return ECInjectionStatusInjected;
    } else {
      ECLog(@"[Status] ❌ Load Command not found in: %@",
            binaryPath.lastPathComponent);
    }
  } else {
    ECLog(@"[Status] ⚠️ Main binary not found for: %@",
          appPath.lastPathComponent);
  }

  return ECInjectionStatusNotInjected;
}

#pragma mark - 批量操作

- (NSArray<NSString *> *)injectedApps {
  // 扫描已注入的 APP
  NSMutableArray *result = [NSMutableArray array];

  // 扫描 /var/containers/Bundle/Application/
  NSString *appsDir = @"/var/containers/Bundle/Application";
  NSFileManager *fm = [NSFileManager defaultManager];

  NSArray *uuids = [fm contentsOfDirectoryAtPath:appsDir error:nil];
  for (NSString *uuid in uuids) {
    NSString *uuidPath = [appsDir stringByAppendingPathComponent:uuid];
    NSArray *contents = [fm contentsOfDirectoryAtPath:uuidPath error:nil];

    for (NSString *item in contents) {
      if ([item hasSuffix:@".app"]) {
        NSString *appPath = [uuidPath stringByAppendingPathComponent:item];
        if ([self injectionStatusForApp:appPath] == ECInjectionStatusInjected) {
          [result addObject:appPath];
        }
      }
    }
  }

  return result;
}

#pragma mark - 配置管理

- (BOOL)createSpoofConfigForAppPath:(NSString *)appPath
                             config:(NSDictionary *)config
                              error:(NSError **)error {
  // 直接写入 App Bundle 的 Frameworks 目录
  NSString *configPath =
      [appPath stringByAppendingPathComponent:
                   @"Frameworks/com.apple.preferences.display.plist"];

  // 检查是否需要增强配置（克隆身份伪装）
  NSMutableDictionary *enhancedConfig =
      [config mutableCopy] ?: [NSMutableDictionary dictionary];

  // 如果配置中有 originalBundleId，确保启用身份伪装
  NSString *originalBundleId = enhancedConfig[@"originalBundleId"];
  if (originalBundleId && originalBundleId.length > 0) {
    ECLog(@"[Config] 检测到克隆身份伪装配置, 原始 Bundle ID: %@",
          originalBundleId);
  }

  // App Bundle 通常是只读的，需要使用 Root Helper
  // 首先尝试直接写入
  BOOL success = [enhancedConfig writeToFile:configPath atomically:YES];

  if (!success) {
    // 使用 Root Helper 写入
    ECLog(@"[Config] 直接写入失败，尝试使用 Root Helper...");

    NSData *plistData = [NSPropertyListSerialization
        dataWithPropertyList:enhancedConfig
                      format:NSPropertyListXMLFormat_v1_0
                     options:0
                       error:nil];
    if (plistData) {
      NSString *tempConfig = [NSTemporaryDirectory()
          stringByAppendingPathComponent:
              [NSString stringWithFormat:@"device_%@.plist",
                                         [[NSUUID UUID] UUIDString]]];
      [plistData writeToFile:tempConfig atomically:YES];

      NSString *out, *err;
      int ret =
          spawnRoot(rootHelperPath(), @[ @"copy-file", tempConfig, configPath ],
                    &out, &err);
      if (ret == 0) {
        spawnRoot(rootHelperPath(), @[ @"chmod-file", @"644", configPath ], nil,
                  nil);
        success = YES;
        ECLog(@"[Config] ✅ 通过 Root Helper 写入成功");
      } else {
        ECLog(@"[Config] ❌ Root Helper 写入失败: %@", err);
      }

      [[NSFileManager defaultManager] removeItemAtPath:tempConfig error:nil];
    }
  }

  if (!success && error) {
    *error = [NSError
        errorWithDomain:@"ECAppInjector"
                   code:20
               userInfo:@{
                 NSLocalizedDescriptionKey : @"保存配置到 App Bundle 失败"
               }];
  }

  if (success) {
    ECLog(@"[Config] 已保存设备配置到: %@", configPath);
  }

  return success;
}

- (nullable NSDictionary *)spoofConfigForApp:(NSString *)bundleId {
  NSString *configPath = [kECSpoofBaseDir
      stringByAppendingPathComponent:
          [NSString stringWithFormat:@"%@/com.apple.preferences.display.plist",
                                     bundleId]];
  return [NSDictionary dictionaryWithContentsOfFile:configPath];
}

#pragma mark - 分身管理

- (BOOL)createCloneConfigForApp:(NSString *)bundleId
                        cloneId:(NSString *)cloneId
                         config:(NSDictionary *)config
                          error:(NSError **)error {
  NSString *cloneDir = [kECSpoofBaseDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/session_%@",
                                                          bundleId, cloneId]];
  NSString *configPath = [cloneDir
      stringByAppendingPathComponent:@"com.apple.preferences.display.plist"];

  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:cloneDir]) {
    [fm createDirectoryAtPath:cloneDir
        withIntermediateDirectories:YES
                         attributes:nil
                              error:nil];
  }

  // 增强配置：自动添加原始 Bundle ID 用于身份伪装
  NSMutableDictionary *enhancedConfig =
      [config mutableCopy] ?: [NSMutableDictionary dictionary];

  // 添加原始 Bundle ID（用于克隆身份伪装和 Keychain 隔离）
  if (!enhancedConfig[@"originalBundleId"]) {
    enhancedConfig[@"originalBundleId"] = bundleId;
    ECLog(@"[Clone] 添加身份伪装配置 originalBundleId: %@", bundleId);
  }

  // 添加克隆 ID（用于数据隔离）
  if (!enhancedConfig[@"cloneId"]) {
    enhancedConfig[@"cloneId"] = cloneId;
  }

  BOOL success = [enhancedConfig writeToFile:configPath atomically:YES];
  if (!success && error) {
    *error = [NSError
        errorWithDomain:@"ECAppInjector"
                   code:21
               userInfo:@{NSLocalizedDescriptionKey : @"保存分身配置失败"}];
  }

  if (success) {
    ECLog(@"[Clone] ✅ 增强配置已保存: %@ (含身份伪装)", configPath);
  }

  return success;
}

- (NSArray<NSString *> *)cloneIdsForApp:(NSString *)bundleId {
  NSString *appDir = [kECSpoofBaseDir stringByAppendingPathComponent:bundleId];
  NSFileManager *fm = [NSFileManager defaultManager];

  NSMutableArray *cloneIds = [NSMutableArray array];
  NSArray *contents = [fm contentsOfDirectoryAtPath:appDir error:nil];

  for (NSString *item in contents) {
    if ([item hasPrefix:@"session_"]) {
      NSString *cloneId = [item substringFromIndex:8];
      [cloneIds addObject:cloneId];
    }
  }

  return cloneIds;
}

- (BOOL)deleteCloneForApp:(NSString *)bundleId
                  cloneId:(NSString *)cloneId
                    error:(NSError **)error {
  NSString *cloneDir = [kECSpoofBaseDir
      stringByAppendingPathComponent:[NSString
                                         stringWithFormat:@"%@/session_%@",
                                                          bundleId, cloneId]];

  NSFileManager *fm = [NSFileManager defaultManager];
  return [fm removeItemAtPath:cloneDir error:error];
}

#pragma mark - 内部注入辅助方法

/// 处理单个二进制的注入流程：复制->Temp->注入LC->签名->覆盖
- (BOOL)processBinary:(NSString *)binaryPath
    injectingDylibAtPath:(NSString *)dylibPath
         loadCommandPath:(NSString *)lcPath
                  teamID:(NSString *)teamID
                   error:(NSError **)error {

  // 0. 备份原始二进制 (如果不存在备份)
  NSString *backupPath = [binaryPath stringByAppendingString:@".ec_bak"];

  if (![[NSFileManager defaultManager] fileExistsAtPath:backupPath]) {
    ECLog(@"[ProcessBinary] 创建备份: %@", backupPath);
    NSString *backupOut, *backupErr;
    int ret =
        spawnRoot(rootHelperPath(), @[ @"copy-file", binaryPath, backupPath ],
                  &backupOut, &backupErr);
    if (ret != 0) {
      ECLog(@"[ProcessBinary] ⚠️ 备份失败: ret=%d, err:%@", ret, backupErr);
    } else {
      ECLog(@"[ProcessBinary] ✅ 备份成功");
    }
  } else {
    ECLog(@"[ProcessBinary] 备份已存在，跳过备份: %@", backupPath);
  }

  // 1. 创建 Temp Binary
  NSString *tempUUID = [[NSUUID UUID] UUIDString];
  NSString *tempBinary =
      [NSTemporaryDirectory() stringByAppendingPathComponent:tempUUID];
  ECLog(@"[ProcessBinary] 创建 Temp: %@", tempBinary);

  NSString *cpOut, *cpErr;
  int cpRet =
      spawnRoot(rootHelperPath(), @[ @"copy-file", binaryPath, tempBinary ],
                &cpOut, &cpErr);
  if (cpRet != 0) {
    ECLog(@"[ProcessBinary] ❌ 复制失败: ret=%d, err:%@", cpRet, cpErr);
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:100
                 userInfo:@{NSLocalizedDescriptionKey : @"Helper copy failed"}];
    return NO;
  }
  ECLog(@"[ProcessBinary] ✅ Temp复制成功");

  // 2. 注入 Load Command (使用 Root Helper)
  ECLog(@"[ProcessBinary] 注入 LC via Helper...");
  NSString *injectOut, *injectErr;
  int injectRet =
      spawnRoot(rootHelperPath(), @[ @"inject-lc", tempBinary, lcPath ],
                &injectOut, &injectErr);
  if (injectRet != 0) {
    ECLog(@"[ProcessBinary] ❌ 注入失败: ret=%d, err:%@", injectRet, injectErr);
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:injectRet
                 userInfo:@{
                   NSLocalizedDescriptionKey : injectErr ?: @"inject-lc failed"
                 }];
    [[NSFileManager defaultManager] removeItemAtPath:tempBinary error:nil];
    return NO;
  }
  ECLog(@"[ProcessBinary] ✅ 注入成功");

  // 3. 签名 & CT Bypass
  ECLog(@"[ProcessBinary] 签名 TeamID: %@", teamID ?: @"(none)");
  // Pass backupPath as the source for entitlements to avoid issues with
  // modified binary
  NSMutableArray *signArgs =
      [NSMutableArray arrayWithObjects:@"sign-binary", tempBinary,
                                       teamID ?: @"", backupPath, nil];

  NSString *signOut, *signErr;
  int signRet = spawnRoot(rootHelperPath(), signArgs, &signOut, &signErr);
  ECLog(@"[ProcessBinary] sign-binary ret=%d", signRet);

  if (signRet != 0) {
    ECLog(@"[ProcessBinary] ❌ Main binary signing failed: ret=%d, err:%@",
          signRet, signErr);
    if (error)
      *error = [NSError errorWithDomain:@"ECAppInjector"
                                   code:signRet
                               userInfo:@{
                                 NSLocalizedDescriptionKey : [NSString
                                     stringWithFormat:@"sign-binary failed: %@",
                                                      signErr ?: @"unknown"]
                               }];
    [[NSFileManager defaultManager] removeItemAtPath:tempBinary error:nil];
    return NO;
  }
  ECLog(@"[ProcessBinary] ✅ Main binary signed with CT bypass");

  // 4. Sign injected dylib with pure ad-hoc (NO TeamID, NO CT bypass pre-applied)
  // 策略: 让 CTLoop 在安装时对 dylib 做唯一一次 CT bypass。
  // sign-binary 总是做 ldid+CT bypass，CTLoop 再做一次就产生无效签名。
  // sign-adhoc-only 只做 ldid ad-hoc，产生标准 SHA256 CD，
  // CTLoop 从这个干净的 ad-hoc 签名做一次 CT bypass 即可正常加载。
  ECLog(@"[ProcessBinary] Signing dylib (sign-adhoc-only, no CT pre-bypass): %@", dylibPath);

  NSString *dylibSignOut, *dylibSignErr;
  int dylibSignRet = spawnRoot(rootHelperPath(),
      @[@"sign-adhoc-only", dylibPath], &dylibSignOut, &dylibSignErr);
  ECLog(@"[ProcessBinary] sign-adhoc-only ret=%d", dylibSignRet);

  if (dylibSignRet != 0) {
    ECLog(@"[ProcessBinary] ⚠️ Dylib ad-hoc-only signing failed: %@, trying sign-binary fallback",
          dylibSignErr);
    // Fallback: sign-binary without TeamID（仍可能有二次 bypass 问题，但至少签了）
    int fallbackRet = spawnRoot(rootHelperPath(),
        @[@"sign-binary", dylibPath], &dylibSignOut, &dylibSignErr);
    ECLog(@"[ProcessBinary] sign-binary fallback ret=%d", fallbackRet);
    if (fallbackRet == 0) {
      ECLog(@"[ProcessBinary] ✅ Fallback sign-binary succeeded");
    } else {
      ECLog(@"[ProcessBinary] ❌ Both signing methods failed for dylib");
    }
  } else {
    ECLog(@"[ProcessBinary] ✅ Dylib signed (CTLoop will do CT bypass on install)");
  }



  // [Fix] 5. Embed configuration file into the App Bundle
  // This ensures that even if the app sandbox is cleared (reinstall), the dylib
  // has a default config.
  NSString *sourceConfig = @"/var/mobile/Documents/.com.apple.UIKit.pboard/"
                           @"com.apple.preferences.display.plist";
  if ([[NSFileManager defaultManager] fileExistsAtPath:sourceConfig]) {
    NSString *appBundlePath = [binaryPath stringByDeletingLastPathComponent];
    NSString *frameworksDir =
        [appBundlePath stringByAppendingPathComponent:@"Frameworks"];

    // Ensure Frameworks directory exists
    spawnRoot(rootHelperPath(), @[ @"mkdir", frameworksDir ], nil, nil);
    spawnRoot(rootHelperPath(), @[ @"chmod-file", @"755", frameworksDir ], nil,
              nil);

    NSString *destConfig = [frameworksDir
        stringByAppendingPathComponent:@"com.apple.preferences.display.plist"];
    ECLog(@"[ProcessBinary] 📄 Embedding config: %@ -> %@", sourceConfig,
          destConfig);

    spawnRoot(rootHelperPath(), @[ @"copy-file", sourceConfig, destConfig ],
              nil, nil);
    spawnRoot(rootHelperPath(), @[ @"chmod-file", @"644", destConfig ], nil,
              nil);
  } else {
    ECLog(@"[ProcessBinary] ⚠️ Config file not found at %@, skipping embed.",
          sourceConfig);
  }

  // 5. 覆盖回原文件
  NSString *moveOut, *moveErr;
  int moveRet =
      spawnRoot(rootHelperPath(), @[ @"move-file", tempBinary, binaryPath ],
                &moveOut, &moveErr);
  if (moveRet != 0) {
    ECLog(@"[ProcessBinary] ❌ 覆盖失败: ret=%d, err:%@", moveRet, moveErr);
    [[NSFileManager defaultManager] removeItemAtPath:tempBinary error:nil];
    return NO;
  }
  ECLog(@"[ProcessBinary] ✅ 覆盖成功");

  spawnRoot(rootHelperPath(), @[ @"chmod-file", @"755", binaryPath ], nil, nil);
  return YES;
}

/// 回退方案：尝试注入 Frameworks
- (BOOL)injectIntoFrameworksOfApp:(NSString *)appPath
                           teamID:(NSString *)teamID
                            error:(NSError **)error {
  NSString *frameworksDir =
      [appPath stringByAppendingPathComponent:@"Frameworks"];
  NSFileManager *fm = [NSFileManager defaultManager];

  // 检查 Frameworks 目录是否存在
  BOOL isDir;
  if (![fm fileExistsAtPath:frameworksDir isDirectory:&isDir] || !isDir) {
    if (error)
      *error = [NSError errorWithDomain:@"ECAppInjector"
                                   code:21
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"无 Frameworks 目录，无法进行回退注入"
                               }];
    return NO;
  }

  NSArray *contents = [fm contentsOfDirectoryAtPath:frameworksDir error:nil];
  if (contents.count == 0) {
    if (error)
      *error =
          [NSError errorWithDomain:@"ECAppInjector"
                              code:22
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"Frameworks 目录为空"
                          }];
    return NO;
  }

  for (NSString *item in contents) {
    if ([item.pathExtension isEqualToString:@"framework"]) {
      NSString *fwPath = [frameworksDir stringByAppendingPathComponent:item];
      NSString *fwName = [item stringByDeletingPathExtension];
      NSString *binaryPath = [fwPath stringByAppendingPathComponent:fwName];

      if ([fm fileExistsAtPath:binaryPath]) {
        ECLog(@"尝试注入 Framework: %@", item);

        // 将 dylib 复制到 Framework 内部 (最稳妥)
        NSString *dylibDest =
            [fwPath stringByAppendingPathComponent:kSpoofDylibName];

        // 源 dylib 路径
        NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
        NSString *sourceDylib =
            [bundlePath stringByAppendingPathComponent:
                            @"Dylibs/libswiftCompatibilityPacks.dylib"];
        if (![fm fileExistsAtPath:sourceDylib])
          sourceDylib = [bundlePath stringByAppendingPathComponent:
                                        @"libswiftCompatibilityPacks.dylib"];

        // 复制 dylib
        spawnRoot(rootHelperPath(), @[ @"remove-file", dylibDest ], nil, nil);
        spawnRoot(rootHelperPath(), @[ @"copy-file", sourceDylib, dylibDest ],
                  nil, nil);
        spawnRoot(rootHelperPath(), @[ @"chmod-file", @"755", dylibDest ], nil,
                  nil);

        // 如果主程序 Team ID 获取失败（加密），尝试从 Framework 获取
        NSString *effectiveTeamID = teamID;
        if (!effectiveTeamID || effectiveTeamID.length == 0) {
          ECLog(@"[FrameworkInject] 主程序 Team ID 为空，尝试从 Framework "
                @"提取...");
          effectiveTeamID = [self fetchTeamIDFromBinary:binaryPath];
        }
        if (effectiveTeamID) {
          ECLog(@"[FrameworkInject] 使用 Team ID: %@", effectiveTeamID);
        } else {
          ECLog(@"[FrameworkInject] ⚠️ 无法获取任何 Team ID，将使用默认签名");
        }

        // 注入 Load Command: @loader_path/libswiftCompatibilityPacks.dylib
        NSError *fwError = nil;
        if ([self processBinary:binaryPath
                injectingDylibAtPath:dylibDest
                     loadCommandPath:
                         @"@loader_path/libswiftCompatibilityPacks.dylib"
                              teamID:effectiveTeamID
                               error:&fwError]) {
          ECLog(@"✅ 成功注入到 Framework: %@", item);

          // 创建标记，表明通过 Framework 注入
          NSString *markerPath =
              [appPath stringByAppendingPathComponent:kInjectionMarker];
          spawnRoot(rootHelperPath(), @[ @"touch-file", markerPath ], nil, nil);

          return YES;
        } else {
          ECLog(@"Framework %@ 注入失败 (Code %ld): %@", item,
                (long)fwError.code, fwError.localizedDescription);
        }
      }
    }
  }

  if (error)
    *error = [NSError errorWithDomain:@"ECAppInjector"
                                 code:23
                             userInfo:@{
                               NSLocalizedDescriptionKey :
                                   @"所有 Framework 均已加密或注入失败"
                             }];
  return NO;
}

#pragma mark - Install-Time Injection (Prepare IPA)

- (nullable NSString *)
    prepareIPAForInjection:(NSString *)ipaPath
              manualTeamID:(nullable NSString *)teamID
            customBundleId:(nullable NSString *)customBundleId
         customDisplayName:(nullable NSString *)customDisplayName
                     error:(NSError **)error {
  return [self prepareIPAForInjection:ipaPath
                         manualTeamID:teamID
                       customBundleId:customBundleId
                    customDisplayName:customDisplayName
                     workingDirectory:nil
                                error:error];
}

- (nullable NSString *)
    prepareIPAForInjection:(NSString *)ipaPath
              manualTeamID:(nullable NSString *)teamID
            customBundleId:(nullable NSString *)customBundleId
         customDisplayName:(nullable NSString *)customDisplayName
          workingDirectory:(nullable NSString *)workingDirectory
                     error:(NSError **)error {
  ECLog(@"[PrepareIPA] 开始处理 IPA: %@", ipaPath);
  if (customBundleId) {
    ECLog(@"[PrepareIPA] 分身 Bundle ID: %@", customBundleId);
  }
  if (customDisplayName) {
    ECLog(@"[PrepareIPA] 分身名称: %@", customDisplayName);
  }

  NSString *tempDir = workingDirectory;
  NSFileManager *fm = [NSFileManager defaultManager];

  if (!tempDir) {
    // 1. 创建临时解压目录
    tempDir = [self extractIPAToTemp:ipaPath error:error];
    if (!tempDir) {
      return nil;
    }
  } else {
    ECLog(@"[PrepareIPA] 使用已有工作目录: %@", tempDir);
  }

  // 3. Find App Bundle
  // ... rest of logic ...

  // 3. 查找 App Bundle (Payload/*.app)
  NSString *payloadPath = [tempDir stringByAppendingPathComponent:@"Payload"];
  NSArray *payloadContents = [fm contentsOfDirectoryAtPath:payloadPath
                                                     error:nil];
  ECLog(@"[PrepareIPA] Payload contents: %@", payloadContents);

  NSString *appBundleName = nil;
  for (NSString *item in payloadContents) {
    if ([item.pathExtension isEqualToString:@"app"]) {
      appBundleName = item;
      break;
    }
  }

  if (!appBundleName) {
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:167
                 userInfo:@{NSLocalizedDescriptionKey : @"IPA 中未找到 .app"}];
    [fm removeItemAtPath:tempDir error:nil];
    return nil;
  }

  NSString *appBundlePath =
      [payloadPath stringByAppendingPathComponent:appBundleName];
  ECLog(@"[PrepareIPA] 找到 App Bundle: %@", appBundlePath);

  // 3.5 修改 Info.plist (分身功能)
  NSString *infoPlistPath =
      [appBundlePath stringByAppendingPathComponent:@"Info.plist"];
  NSMutableDictionary *infoPlist =
      [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];

  if (infoPlist) {
    BOOL modified = NO;
    NSString *originalBundleId = infoPlist[@"CFBundleIdentifier"];
    NSString *originalName =
        infoPlist[@"CFBundleDisplayName"] ?: infoPlist[@"CFBundleName"];

    // 修改 Bundle ID
    if (customBundleId && customBundleId.length > 0) {
      infoPlist[@"CFBundleIdentifier"] = customBundleId;
      ECLog(@"[PrepareIPA] 修改 Bundle ID: %@ -> %@", originalBundleId,
            customBundleId);
      modified = YES;
    }

    // 修改显示名称
    if (customDisplayName && customDisplayName.length > 0) {
      infoPlist[@"CFBundleDisplayName"] = customDisplayName;
      infoPlist[@"CFBundleName"] = customDisplayName;
      ECLog(@"[PrepareIPA] 修改显示名称: %@ -> %@", originalName,
            customDisplayName);
      modified = YES;
    }

    if (modified) {
      if ([infoPlist writeToFile:infoPlistPath atomically:YES]) {
        ECLog(@"[PrepareIPA] ✅ Info.plist 修改成功");
      } else {
        ECLog(@"[PrepareIPA] ⚠️ Info.plist 写入失败，尝试使用 Helper");
        // 使用 Helper 写入
        NSData *plistData = [NSPropertyListSerialization
            dataWithPropertyList:infoPlist
                          format:NSPropertyListXMLFormat_v1_0
                         options:0
                           error:nil];
        if (plistData) {
          NSString *tempPlist = [NSTemporaryDirectory()
              stringByAppendingPathComponent:@"Info_temp.plist"];
          [plistData writeToFile:tempPlist atomically:YES];
          spawnRoot(rootHelperPath(),
                    @[ @"copy-file", tempPlist, infoPlistPath ], nil, nil);
          [fm removeItemAtPath:tempPlist error:nil];
        }
      }
    }
  }

  // 4. 准备 Frameworks/libswiftCompatibilityPacks.dylib
  NSString *frameworksDir =
      [appBundlePath stringByAppendingPathComponent:@"Frameworks"];

  // 确保 Frameworks 目录存在
  if (![fm fileExistsAtPath:frameworksDir]) {
    NSError *dirError = nil;
    BOOL created = [fm createDirectoryAtPath:frameworksDir
                 withIntermediateDirectories:YES
                                  attributes:nil
                                       error:&dirError];
    if (!created) {
      ECLog(@"[PrepareIPA] ⚠️ 创建 Frameworks 目录失败: %@, 尝试使用 Helper",
            dirError);
      // 使用 Helper 创建目录
      spawnRoot(rootHelperPath(), @[ @"mkdir", frameworksDir ], nil, nil);
    }
  }
  ECLog(@"[PrepareIPA] Frameworks 目录: %@", frameworksDir);

  // Copy our dylib to Frameworks
  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
  // 优先查找 Frameworks (新打包策略)
  // 1. Try new stealth strategy: spoof_plugin.dat in Root
  // This bypasses iOS/TrollStore app thinning/stripping rules for dylibs
  NSString *datPath =
      [bundlePath stringByAppendingPathComponent:@"spoof_plugin.dat"];
  NSString *sourceDylib = nil;

  if ([fm fileExistsAtPath:datPath]) {
    sourceDylib = datPath;
    ECLog(@"[PrepareIPA] ✅ Found dylib as .dat: %@", sourceDylib);
  }

  // 2. Try legacy paths
  if (!sourceDylib) {
    if ([fm fileExistsAtPath:
                [bundlePath
                    stringByAppendingPathComponent:
                        @"Frameworks/libswiftCompatibilityPacks.dylib"]]) {
      sourceDylib =
          [bundlePath stringByAppendingPathComponent:
                          @"Frameworks/libswiftCompatibilityPacks.dylib"];
    } else if ([fm fileExistsAtPath:
                       [bundlePath
                           stringByAppendingPathComponent:
                               @"Dylibs/libswiftCompatibilityPacks.dylib"]]) {
      sourceDylib = [bundlePath stringByAppendingPathComponent:
                                    @"Dylibs/libswiftCompatibilityPacks.dylib"];
    } else if ([fm fileExistsAtPath:
                       [bundlePath stringByAppendingPathComponent:
                                       @"libswiftCompatibilityPacks.dylib"]]) {
      sourceDylib = [bundlePath
          stringByAppendingPathComponent:@"libswiftCompatibilityPacks.dylib"];
    }
  }

  // Recursive search if still not found
  if (!sourceDylib) {
    ECLog(@"[PrepareIPA] ⚠️ Standard paths failed, searching recursively in %@",
          bundlePath);
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:bundlePath];
    NSString *file;
    while (file = [enumerator nextObject]) {
      NSString *name = file.lastPathComponent;
      if ([name isEqualToString:@"libswiftCompatibilityPacks.dylib"] ||
          [name isEqualToString:@"spoof_plugin.dat"]) {
        sourceDylib = [bundlePath stringByAppendingPathComponent:file];
        ECLog(@"[PrepareIPA] ✅ Found dylib recursively at: %@", sourceDylib);
        break;
      }
    }
  }

  if (!sourceDylib || ![fm fileExistsAtPath:sourceDylib]) {
    ECLog(
        @"[PrepareIPA] ❌ Critical Error: Dylib NOT found anywhere in bundle!");
    ECLog(@"[PrepareIPA] Bundle Path: %@", bundlePath);
    // List contents of root for debugging
    NSError *lsError = nil;
    NSArray *contents = [fm contentsOfDirectoryAtPath:bundlePath
                                                error:&lsError];
    ECLog(@"[PrepareIPA] Bundle Root Contents: %@", contents);

    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:404
                 userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:
                           @"Missing libswiftCompatibilityPacks.dylib in host "
                           @"app (path: %@, contents: %@)",
                           bundlePath, contents]
                 }];
    return nil;
  }

  ECLog(@"[PrepareIPA] 源 dylib: %@", sourceDylib);

  NSString *destDylibPath = [frameworksDir
      stringByAppendingPathComponent:@"libswiftCompatibilityPacks.dylib"];
  ECLog(@"[PrepareIPA] 目标路径: %@", destDylibPath);

  // Use Helper to copy/ensure permissions (root)
  NSString *copyOut, *copyErr;
  int copyRet =
      spawnRoot(rootHelperPath(), @[ @"copy-file", sourceDylib, destDylibPath ],
                &copyOut, &copyErr);
  if (copyRet != 0) {
    ECLog(@"[PrepareIPA] ❌ 复制 dylib 失败: ret=%d, err=%@", copyRet, copyErr);
    // 尝试直接复制
    NSError *cpError = nil;
    if ([fm copyItemAtPath:sourceDylib toPath:destDylibPath error:&cpError]) {
      ECLog(@"[PrepareIPA] ✅ 直接复制成功");
    } else {
      ECLog(@"[PrepareIPA] ❌ 直接复制也失败: %@", cpError);
    }
  } else {
    ECLog(@"[PrepareIPA] ✅ dylib 复制成功");
  }
  spawnRoot(rootHelperPath(), @[ @"chmod-file", @"755", destDylibPath ], nil,
            nil);

  // 验证 dylib 是否存在
  if (![fm fileExistsAtPath:destDylibPath]) {
    ECLog(@"[PrepareIPA] ❌ dylib 不存在于目标路径!");
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:500
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"Failed to copy libswiftCompatibilityPacks.dylib to "
                       @"Frameworks"
                 }];
    return nil;
  }

  // Phase 30 Fix A: 嵌入配置文件到 Frameworks/device.plist
  // 这确保 dylib 启动时读到的是用户配置，而非空模板
  NSString *configSource = @"/var/mobile/Documents/ECSpoof/device.plist";
  NSString *destConfigPath =
      [frameworksDir stringByAppendingPathComponent:@"device.plist"];
  if ([fm fileExistsAtPath:configSource]) {
    int cfgRet =
        spawnRoot(rootHelperPath(),
                  @[ @"copy-file", configSource, destConfigPath ], nil, nil);
    if (cfgRet == 0) {
      ECLog(@"[PrepareIPA] ✅ 配置文件已嵌入: %@", destConfigPath);
    } else {
      // 直接复制 fallback
      NSError *cfgErr = nil;
      if ([fm fileExistsAtPath:destConfigPath]) {
        [fm removeItemAtPath:destConfigPath error:nil];
      }
      if ([fm copyItemAtPath:configSource
                      toPath:destConfigPath
                       error:&cfgErr]) {
        ECLog(@"[PrepareIPA] ✅ 配置文件直接复制成功");
      } else {
        ECLog(@"[PrepareIPA] ⚠️ 配置文件嵌入失败: %@", cfgErr);
      }
    }
  } else {
    ECLog(@"[PrepareIPA] ⚠️ 未找到配置文件 (%@)，将使用默认模板", configSource);
  }

  // 5. 注入主二进制
  // Find executable
  NSDictionary *plistForExec = [NSDictionary
      dictionaryWithContentsOfFile:
          [appBundlePath stringByAppendingPathComponent:@"Info.plist"]];
  NSString *execName = plistForExec[@"CFBundleExecutable"];
  if (!execName) {
    if (error)
      *error = [NSError errorWithDomain:@"ECAppInjector"
                                   code:174
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Info.plist missing CFBundleExecutable"
                               }];
    return nil;
  }

  NSString *binaryPath =
      [appBundlePath stringByAppendingPathComponent:execName];

  // Determine TeamID (Scan binary if not provided)
  if (!teamID) {
    NSDictionary *entitlements = dumpEntitlementsFromBinaryAtPath(binaryPath);
    if (entitlements) {
      teamID = entitlements[@"com.apple.developer.team-identifier"];
    }
    ECLog(@"[PrepareIPA] Auto-detected TeamID: %@", teamID);
  }

  ECLog(@"[PrepareIPA] Injecting binary: %@", binaryPath);

  // Call processBinary
  // dylibPath: Absolute path to the dylib INSIDE the temp bundle (this will be
  // signed) lcPath:
  // @executable_path/Frameworks/libswiftCompatibilityPacks.dylib (this is the
  // LC)
  BOOL injectSuccess = [self
             processBinary:binaryPath
      injectingDylibAtPath:destDylibPath
           loadCommandPath:
               @"@executable_path/Frameworks/libswiftCompatibilityPacks.dylib"
                    teamID:teamID
                     error:error];

  if (!injectSuccess) {
    ECLog(@"[PrepareIPA] 注入失败");
    [fm removeItemAtPath:tempDir error:nil];
    return nil;
  }

  // Clean up backup file created by processBinary
  NSString *backupPath = [binaryPath stringByAppendingString:@".ec_bak"];
  [fm removeItemAtPath:backupPath error:nil];

  // 6. 写入配置文件 (device.plist) - 强制覆盖
  // 将配置文件写入 Frameworks 目录，确保不被系统安装过程清理
  NSString *configPath =
      [appBundlePath stringByAppendingPathComponent:
                         @"Frameworks/com.apple.preferences.display.plist"];

  // 检查用户是否已通过配置界面保存了配置文件
  // 如果已存在，说明用户已保存，直接使用用户的配置
  if ([fm fileExistsAtPath:configPath]) {
    NSDictionary *existingConfig =
        [NSDictionary dictionaryWithContentsOfFile:configPath];
    ECLog(@"[PrepareIPA] ✅ 使用用户已保存的配置 (%lu 项): %@",
          (unsigned long)existingConfig.count, configPath);
    ECLog(@"[PrepareIPA]   - languageCode: %@",
          existingConfig[@"languageCode"]);
    ECLog(@"[PrepareIPA]   - countryCode: %@", existingConfig[@"countryCode"]);
  } else {
    // 用户未保存配置，使用 ECDeviceInfoManager 的当前值
    ECDeviceInfoManager *infoMgr = [ECDeviceInfoManager sharedManager];
    NSMutableDictionary *defaultConfig =
        [[infoMgr dictionaryRepresentation] mutableCopy];

    // 确保启用开关 - 用户要求移除默认值
    // defaultConfig[@"enabled"] = @YES;
    // defaultConfig[@"hideJailbreak"] = @YES;
    // defaultConfig[@"isolateData"] = @YES;

    // ---------------------------------------------------------
    // 自动化开关逻辑 (Auto-Enable Feature Flags) - 同步自 ECDeviceInfoManager
    // ---------------------------------------------------------

    // 1. Method Swizzling (UIDevice/UIScreen)
    {
      NSArray *keys = @[
        @"deviceName", @"systemName", @"systemVersion", @"model",
        @"localizedModel", @"identifierForVendor", @"batteryLevel", @"diskSize"
      ];
      for (NSString *key in keys) {
        if (defaultConfig[key]) {
          defaultConfig[@"enableMethodSwizzling"] = @YES;
          break;
        }
      }
    }

    // 2. Sysctl Hooks (Hardware Info)
    {
      NSArray *keys = @[
        @"machineModel", @"systemBuildVersion", @"kernelVersion", @"cpuCores",
        @"physicalMemory", @"bootTime"
      ];
      for (NSString *key in keys) {
        if (defaultConfig[key]) {
          defaultConfig[@"enableSysctlHooks"] = @YES;
          break;
        }
      }
    }

    // 3. MobileGestalt / IOKit (Hardware IDs)
    {
      NSArray *keys = @[
        @"udid", @"serialNumber", @"imei", @"meid", @"ecid",
        @"bluetoothAddress", @"wifiAddress"
      ];
      for (NSString *key in keys) {
        if (defaultConfig[key]) {
          defaultConfig[@"enableMobileGestaltHooks"] = @YES;
          break;
        }
      }
    }

    // 4. Network Hooks (WiFi Info)
    {
      NSArray *keys = @[ @"wifiSSID", @"wifiBSSID" ];
      for (NSString *key in keys) {
        if (defaultConfig[key]) {
          defaultConfig[@"enableNetworkHooks"] = @YES;
          break;
        }
      }
    }

    // 5. Locale Hooks (Language/Region)
    {
      NSArray *keys = @[
        @"languageCode", @"countryCode", @"localeIdentifier",
        @"preferredLanguage", @"currencyCode", @"timezone"
      ];
      for (NSString *key in keys) {
        if (defaultConfig[key]) {
          defaultConfig[@"enableNSCFLocaleHooks"] = @YES;
          defaultConfig[@"enableCFLocaleHooks"] = @YES;
          break;
        }
      }
    }

    // 6. TikTok Specific Hooks
    {
      NSArray *keys = @[
        @"vendorId", @"installId", @"tiktokIdfa", @"storeRegion",
        @"priorityRegion", @"btdCurrentLanguage"
      ];
      for (NSString *key in keys) {
        if (defaultConfig[key]) {
          defaultConfig[@"enableTikTokHooks"] = @YES;
          break;
        }
      }
    }

    // 7. Bundle ID Spoofing
    {
      if (defaultConfig[@"fakedBundleId"] || defaultConfig[@"btdBundleId"]) {
        defaultConfig[@"enableCFBundleFishhook"] = @YES;
        defaultConfig[@"enableISASwizzling"] = @YES;
      }
    }

    // Phase 28: 默认开启所有 Hook 开关（之前默认 @NO 导致登录失败）
    if (defaultConfig[@"enableMethodSwizzling"] == nil)
      defaultConfig[@"enableMethodSwizzling"] = @YES;
    if (defaultConfig[@"enableNSCFLocaleHooks"] == nil)
      defaultConfig[@"enableNSCFLocaleHooks"] = @YES;
    if (defaultConfig[@"enableCFLocaleHooks"] == nil)
      defaultConfig[@"enableCFLocaleHooks"] = @YES;
    if (defaultConfig[@"enableTikTokHooks"] == nil)
      defaultConfig[@"enableTikTokHooks"] = @YES;
    if (defaultConfig[@"enableSysctlHooks"] == nil)
      defaultConfig[@"enableSysctlHooks"] = @YES;
    if (defaultConfig[@"enableMobileGestaltHooks"] == nil)
      defaultConfig[@"enableMobileGestaltHooks"] = @YES;
    if (defaultConfig[@"enableNetworkHooks"] == nil)
      defaultConfig[@"enableNetworkHooks"] = @YES;

    // [User Request] 默认开启反检测 Hook 和 CFBundle Hook
    if (defaultConfig[@"enableCFBundleFishhook"] == nil)
      defaultConfig[@"enableCFBundleFishhook"] = @YES;
    if (defaultConfig[@"enableISASwizzling"] == nil)
      defaultConfig[@"enableISASwizzling"] = @YES;
    if (defaultConfig[@"enableAntiDetectionHooks"] == nil)
      defaultConfig[@"enableAntiDetectionHooks"] = @YES;
    // 反检测子开关默认值
    if (defaultConfig[@"enableForkHooks"] == nil)
      defaultConfig[@"enableForkHooks"] = @YES;
    if (defaultConfig[@"enableBundleIDHook"] == nil)
      defaultConfig[@"enableBundleIDHook"] = @YES;
    if (defaultConfig[@"enableCanOpenURLHook"] == nil)
      defaultConfig[@"enableCanOpenURLHook"] = @YES;
    if (defaultConfig[@"enableKeychainIsolation"] == nil)
      defaultConfig[@"enableKeychainIsolation"] = @YES;

    if ([defaultConfig writeToFile:configPath atomically:YES]) {
      ECLog(@"[PrepareIPA] ✅ 写入默认配置: %@", configPath);
      ECLog(@"[PrepareIPA] 配置内容: languageCode=%@, countryCode=%@, "
            @"localeIdentifier=%@",
            defaultConfig[@"languageCode"], defaultConfig[@"countryCode"],
            defaultConfig[@"localeIdentifier"]);
    } else {
      ECLog(@"[PrepareIPA] ⚠️ 写入配置失败，尝试使用 Helper...");
      // 使用 Root Helper 写入
      NSData *plistData = [NSPropertyListSerialization
          dataWithPropertyList:defaultConfig
                        format:NSPropertyListXMLFormat_v1_0
                       options:0
                         error:nil];
      if (plistData) {
        NSString *tempConfig = [NSTemporaryDirectory()
            stringByAppendingPathComponent:@"device_temp.plist"];
        [plistData writeToFile:tempConfig atomically:YES];
        spawnRoot(rootHelperPath(), @[ @"copy-file", tempConfig, configPath ],
                  nil, nil);
        spawnRoot(rootHelperPath(), @[ @"chmod-file", @"644", configPath ], nil,
                  nil);
        [fm removeItemAtPath:tempConfig error:nil];
      }
    }
  }

  // 验证 device.plist 是否成功写入
  if ([fm fileExistsAtPath:configPath]) {
    NSDictionary *savedConfig =
        [NSDictionary dictionaryWithContentsOfFile:configPath];
    ECLog(@"[PrepareIPA] ✅ device.plist 验证成功，包含 %lu 项",
          (unsigned long)savedConfig.count);
    ECLog(@"[PrepareIPA]   - enabled: %@", savedConfig[@"enabled"]);
    ECLog(@"[PrepareIPA]   - languageCode: %@", savedConfig[@"languageCode"]);
    ECLog(@"[PrepareIPA]   - countryCode: %@", savedConfig[@"countryCode"]);
  } else {
    ECLog(@"[PrepareIPA] ❌ device.plist 不存在于: %@", configPath);
  }

  // 验证 dylib 是否存在
  NSString *dylibInFrameworks =
      [appBundlePath stringByAppendingPathComponent:
                         @"Frameworks/libswiftCompatibilityPacks.dylib"];
  if ([fm fileExistsAtPath:dylibInFrameworks]) {
    ECLog(@"[PrepareIPA] ✅ dylib 存在: %@", dylibInFrameworks);
  } else {
    ECLog(@"[PrepareIPA] ❌ dylib 不存在: %@", dylibInFrameworks);
  }

  ECLog(@"[PrepareIPA] 准备完成: %@", appBundlePath);

  // IMPORTANT: We return the path to the .app bundle, NOT the IPA.
  // TSApplicationsManager installIpa supports directory paths if they end in
  // .app (or via internal logic)
  return appBundlePath;
}

- (nullable NSString *)extractIPAToTemp:(NSString *)ipaPath
                                  error:(NSError **)error {
  // 1. 创建临时解压目录
  NSString *tempDir = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm createDirectoryAtPath:tempDir
          withIntermediateDirectories:YES
                           attributes:nil
                                error:error]) {
    return nil;
  }

  // 2. 解压 IPA (使用 RootHelper extract)
  NSString *outStr, *errStr;
  int ret = spawnRoot(rootHelperPath(), @[ @"extract", ipaPath, tempDir ],
                      &outStr, &errStr);
  if (ret != 0) {
    ECLog(@"[ExtractIPA] 解压失败: %@", errStr);
    if (error)
      *error = [NSError
          errorWithDomain:@"ECAppInjector"
                     code:ret
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       [NSString stringWithFormat:@"IPA 解压失败: %@", errStr]
                 }];
    [fm removeItemAtPath:tempDir error:nil];
    return nil;
  }
  return tempDir;
}

- (nullable NSDictionary<NSString *, id> *)getAppInfoFromBundlePath:
    (NSString *)bundlePath {
  // Find .app in Payload
  NSString *payloadPath =
      [bundlePath stringByAppendingPathComponent:@"Payload"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:payloadPath]) {
    return nil;
  }

  NSArray *contents =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadPath
                                                          error:nil];
  NSString *appBundleName = nil;
  for (NSString *name in contents) {
    if ([name.pathExtension isEqualToString:@"app"]) {
      appBundleName = name;
      break;
    }
  }

  if (!appBundleName)
    return nil;
  NSString *appPath =
      [payloadPath stringByAppendingPathComponent:appBundleName];
  NSString *plistPath = [appPath stringByAppendingPathComponent:@"Info.plist"];

  NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
  if (!info)
    return nil;

  NSMutableDictionary *result = [NSMutableDictionary dictionary];
  if (info[@"CFBundleIdentifier"])
    result[@"CFBundleIdentifier"] = info[@"CFBundleIdentifier"];
  if (info[@"CFBundleDisplayName"])
    result[@"CFBundleDisplayName"] = info[@"CFBundleDisplayName"];
  else if (info[@"CFBundleName"])
    result[@"CFBundleDisplayName"] = info[@"CFBundleName"]; // Fallback

  return result;
}

@end
