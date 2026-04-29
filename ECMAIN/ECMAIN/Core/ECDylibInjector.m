//
//  ECDylibInjector.m
//  ECMAIN
//
//  Dylib 注入工具实现 - 修改 Mach-O 添加 LC_LOAD_DYLIB 命令
//

#import "ECDylibInjector.h"
#import <mach-o/fat.h>
#import <mach-o/loader.h>

// Mach-O 相关常量
#define DYLIB_INSTALL_NAME                                                     \
  @"@executable_path/Frameworks/libswiftCompatibilityEC.dylib"

@implementation ECDylibInjector

+ (BOOL)injectDylib:(NSString *)dylibName
            intoApp:(NSString *)appPath
              error:(NSError **)error {

  NSLog(@"[ECDylibInjector] 开始注入 %@ 到 %@", dylibName, appPath);

  // 1. 找到主二进制文件
  NSString *appName =
      [[appPath lastPathComponent] stringByDeletingPathExtension];
  NSString *binaryPath = [appPath stringByAppendingPathComponent:appName];

  // 也可能在 Info.plist 中指定了不同的 CFBundleExecutable
  NSString *infoPlistPath =
      [appPath stringByAppendingPathComponent:@"Info.plist"];
  NSDictionary *infoPlist =
      [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
  NSString *executableName = infoPlist[@"CFBundleExecutable"];
  if (executableName) {
    binaryPath = [appPath stringByAppendingPathComponent:executableName];
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECDylibInjector"
                     code:1
                 userInfo:@{NSLocalizedDescriptionKey : @"找不到主二进制文件"}];
    }
    return NO;
  }

  // 2. 复制 dylib 到 APP 的 Frameworks 目录
  NSString *frameworksDir =
      [appPath stringByAppendingPathComponent:@"Frameworks"];
  NSString *destDylib =
      [frameworksDir stringByAppendingPathComponent:dylibName];

  // 确保 Frameworks 目录存在
  [[NSFileManager defaultManager] createDirectoryAtPath:frameworksDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];

  // 复制我们打包的 dylib
  NSString *sourceDylib = [self bundledDylibPath];
  if (!sourceDylib ||
      ![[NSFileManager defaultManager] fileExistsAtPath:sourceDylib]) {
    if (error) {
      *error =
          [NSError errorWithDomain:@"ECDylibInjector"
                              code:2
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"找不到源 dylib 文件"
                          }];
    }
    return NO;
  }

  NSError *copyError = nil;
  // 先删除旧的
  [[NSFileManager defaultManager] removeItemAtPath:destDylib error:nil];
  // 复制新的
  if (![[NSFileManager defaultManager] copyItemAtPath:sourceDylib
                                               toPath:destDylib
                                                error:&copyError]) {
    if (error) {
      *error = copyError;
    }
    return NO;
  }

  // 3. 检查是否已经注入
  if ([self isApp:appPath injectedWithDylib:dylibName]) {
    NSLog(@"[ECDylibInjector] Dylib 已存在于加载命令中，跳过注入");
    return YES;
  }

  // 4. 使用 insert_dylib 或手动修改 Mach-O
  // 这里使用简化方案：通过调用外部工具或使用 LC_LOAD_WEAK_DYLIB
  BOOL success = [self insertLoadCommandInBinary:binaryPath
                                       dylibPath:DYLIB_INSTALL_NAME
                                           error:error];

  if (success) {
    NSLog(@"[ECDylibInjector] 注入成功！");

    // 5. 重新签名（使用 ldid）
    [self resignBinary:binaryPath];
  }

  return success;
}

+ (BOOL)isApp:(NSString *)appPath injectedWithDylib:(NSString *)dylibName {
  NSString *appName =
      [[appPath lastPathComponent] stringByDeletingPathExtension];
  NSString *binaryPath = [appPath stringByAppendingPathComponent:appName];

  // 读取 Mach-O 加载命令
  NSData *binaryData = [NSData dataWithContentsOfFile:binaryPath];
  if (!binaryData)
    return NO;

  const void *bytes = binaryData.bytes;
  struct mach_header_64 *header = (struct mach_header_64 *)bytes;

  // 检查是否是 Mach-O 64-bit
  if (header->magic != MH_MAGIC_64) {
    // 可能是 FAT 二进制，这里简化处理
    return NO;
  }

  // 遍历加载命令
  struct load_command *cmd =
      (struct load_command *)((char *)bytes + sizeof(struct mach_header_64));
  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (cmd->cmd == LC_LOAD_DYLIB || cmd->cmd == LC_LOAD_WEAK_DYLIB) {
      struct dylib_command *dylib_cmd = (struct dylib_command *)cmd;
      const char *name = (const char *)cmd + dylib_cmd->dylib.name.offset;
      if (strstr(name, [dylibName UTF8String]) != NULL) {
        return YES;
      }
    }
    cmd = (struct load_command *)((char *)cmd + cmd->cmdsize);
  }

  return NO;
}

+ (BOOL)removeDylib:(NSString *)dylibName
            fromApp:(NSString *)appPath
              error:(NSError **)error {
  // 删除 Frameworks 中的 dylib
  NSString *frameworksDir =
      [appPath stringByAppendingPathComponent:@"Frameworks"];
  NSString *dylibPath =
      [frameworksDir stringByAppendingPathComponent:dylibName];

  NSError *removeError = nil;
  if ([[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
    if (![[NSFileManager defaultManager] removeItemAtPath:dylibPath
                                                    error:&removeError]) {
      if (error)
        *error = removeError;
      return NO;
    }
  }

  // TODO: 也应该从 Mach-O 中移除加载命令，但这比较复杂
  // 通常可以留着加载命令，因为如果 dylib 不存在，iOS 会使用 WEAK 加载策略

  return YES;
}

+ (nullable NSString *)bundledDylibPath {
  // 从我们的 APP bundle 中获取 dylib
  NSBundle *bundle = [NSBundle mainBundle];
  NSString *dylibsDir =
      [bundle.bundlePath stringByAppendingPathComponent:@"Dylibs"];
  NSString *dylibPath = [dylibsDir
      stringByAppendingPathComponent:@"libswiftCompatibilityEC.dylib"];

  if ([[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
    return dylibPath;
  }

  // 备选：直接在 bundle 根目录
  dylibPath = [bundle.bundlePath
      stringByAppendingPathComponent:@"libswiftCompatibilityEC.dylib"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:dylibPath]) {
    return dylibPath;
  }

  return nil;
}

#pragma mark - Private Methods

+ (BOOL)insertLoadCommandInBinary:(NSString *)binaryPath
                        dylibPath:(NSString *)dylibPath
                            error:(NSError **)error {

  // 读取二进制文件
  NSMutableData *binaryData = [NSMutableData dataWithContentsOfFile:binaryPath];
  if (!binaryData) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECDylibInjector"
                     code:3
                 userInfo:@{NSLocalizedDescriptionKey : @"无法读取二进制文件"}];
    }
    return NO;
  }

  void *bytes = binaryData.mutableBytes;
  struct mach_header_64 *header = (struct mach_header_64 *)bytes;

  // 检查是否是 Mach-O 64-bit
  if (header->magic != MH_MAGIC_64) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECDylibInjector"
                     code:4
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"不是 64-bit Mach-O 文件"
                 }];
    }
    return NO;
  }

  // 构造新的 LC_LOAD_WEAK_DYLIB 命令
  // 使用 WEAK 是为了在 dylib 不存在时 APP 不会崩溃
  NSUInteger pathLen = strlen([dylibPath UTF8String]) + 1;
  NSUInteger cmdSize = sizeof(struct dylib_command) + pathLen;
  // 对齐到 8 字节
  cmdSize = (cmdSize + 7) & ~7;

  // 创建新的加载命令
  NSMutableData *newCmd = [NSMutableData dataWithLength:cmdSize];
  struct dylib_command *dylib_cmd = (struct dylib_command *)newCmd.mutableBytes;
  dylib_cmd->cmd = LC_LOAD_WEAK_DYLIB;
  dylib_cmd->cmdsize = (uint32_t)cmdSize;
  dylib_cmd->dylib.name.offset = sizeof(struct dylib_command);
  dylib_cmd->dylib.timestamp = 2;
  dylib_cmd->dylib.current_version = 0x10000;
  dylib_cmd->dylib.compatibility_version = 0x10000;

  // 复制 dylib 路径
  memcpy((char *)newCmd.mutableBytes + sizeof(struct dylib_command),
         [dylibPath UTF8String], pathLen);

  // 找到加载命令的末尾位置
  NSUInteger headerEnd = sizeof(struct mach_header_64);
  NSUInteger cmdsEnd = headerEnd + header->sizeofcmds;

  // 检查是否有足够的空间（需要在 __TEXT segment 开始之前）
  // 简化处理：假设有空间，直接追加
  // 在实际实现中，可能需要扩展头部或使用其他技术

  // 检查是否有足够的 padding
  const char *afterCmds = (const char *)bytes + cmdsEnd;
  NSUInteger paddingNeeded = cmdSize;
  BOOL hasPadding = YES;
  for (NSUInteger i = 0; i < paddingNeeded && (cmdsEnd + i) < binaryData.length;
       i++) {
    if (afterCmds[i] != 0) {
      hasPadding = NO;
      break;
    }
  }

  if (!hasPadding) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECDylibInjector"
                     code:5
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"没有足够的空间插入加载命令"
                 }];
    }
    return NO;
  }

  // 插入新的加载命令
  memcpy((char *)bytes + cmdsEnd, newCmd.bytes, cmdSize);

  // 更新头部
  header->ncmds += 1;
  header->sizeofcmds += cmdSize;

  // 写回文件
  if (![binaryData writeToFile:binaryPath atomically:YES]) {
    if (error) {
      *error = [NSError
          errorWithDomain:@"ECDylibInjector"
                     code:6
                 userInfo:@{NSLocalizedDescriptionKey : @"无法写入二进制文件"}];
    }
    return NO;
  }

  return YES;
}

+ (void)resignBinary:(NSString *)binaryPath {
  // 使用 ldid 重新签名
  NSString *ldidPath =
      [[NSBundle mainBundle].bundlePath stringByAppendingPathComponent:@"ldid"];

  if ([[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = ldidPath;
    task.arguments = @[ @"-S", binaryPath ];

    @try {
      [task launch];
      [task waitUntilExit];
    } @catch (NSException *e) {
      NSLog(@"[ECDylibInjector] ldid 签名失败: %@", e);
    }
  } else {
    NSLog(@"[ECDylibInjector] ldid 不存在，跳过重签名");
  }
}

@end
