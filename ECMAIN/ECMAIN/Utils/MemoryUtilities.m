#import "MemoryUtilities.h"
#import <errno.h>
#import <fcntl.h>
// #import <mach/mach_vm.h>
#import <mach-o/fat.h>
#import <stdlib.h>
#import <sys/types.h>
#import <unistd.h>

#define MAX_DYLD_INFO_RETRIES 300
#define DYLD_INFO_RETRY_DELAY_US 10000

#define MALLOC_CHUNK_SIZE (1 << 20) // 1 MB

kern_return_t mach_vm_read_overwrite(vm_map_read_t target_task,
                                     mach_vm_address_t address,
                                     mach_vm_size_t size,
                                     mach_vm_address_t data,
                                     mach_vm_size_t *outsize);
kern_return_t mach_vm_region(vm_map_read_t target_task,
                             mach_vm_address_t *address, mach_vm_size_t *size,
                             vm_region_flavor_t flavor, vm_region_info_t info,
                             mach_msg_type_number_t *infoCnt,
                             mach_port_t *object_name);

static void removePrefix(char *str, const char *prefix) {
  size_t len_str = strlen(str);
  size_t len_prefix = strlen(prefix);

  if (len_str >= len_prefix && strncmp(str, prefix, len_prefix) == 0) {
    memmove(str, str + len_prefix, len_str - len_prefix + 1);
  }
}

static bool readFully(int fd, void *buffer, size_t size) {
  size_t totalRead = 0;
  while (totalRead < size) {
    ssize_t bytesRead =
        read(fd, (uint8_t *)buffer + totalRead, size - totalRead);
    if (bytesRead <= 0) {
      return NO;
    }
    totalRead += bytesRead;
  }
  return YES;
}

static bool writeFully(int fd, const void *buffer, size_t size) {
  size_t totalWritten = 0;
  while (totalWritten < size) {
    ssize_t bytesWritten =
        write(fd, (const uint8_t *)buffer + totalWritten, size - totalWritten);
    if (bytesWritten <= 0) {
      return NO;
    }
    totalWritten += bytesWritten;
  }
  return YES;
}

static BOOL readProcessMemory(vm_map_t task, uint64_t address, void *buffer,
                              size_t size) {
  if (!buffer || size == 0) {
    NSLog(@"invalid buffer or size");
    return NO;
  }

  // 尝试直接读取，如果跨 region 则分块读取
  kern_return_t kr;
  mach_vm_size_t outSize = 0;

  // 先尝试直接读取
  kr = mach_vm_read_overwrite((task_t)task, address, size,
                              (mach_vm_address_t)buffer, &outSize);
  if (kr == KERN_SUCCESS && outSize == size) {
    return YES;
  }

  // 直接读取失败，尝试分块读取跨 region 的数据
  NSLog(@"Direct read failed (kr=%d), trying chunked read for %zu bytes at "
        @"0x%llx",
        kr, size, address);

  uint8_t *dest = (uint8_t *)buffer;
  uint64_t currentAddr = address;
  size_t remaining = size;

  while (remaining > 0) {
    // 获取当前地址所在的 region 信息
    mach_vm_address_t regionAddress = currentAddr;
    mach_vm_size_t regionSize = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t objectName = MACH_PORT_NULL;

    kr = mach_vm_region((task_t)task, &regionAddress, &regionSize,
                        VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info,
                        &infoCount, &objectName);

    if (kr != KERN_SUCCESS || !(info.protection & VM_PROT_READ)) {
      NSLog(@"mach_vm_region failed or region not readable (kr=%d) at 0x%llx",
            kr, currentAddr);
      return NO;
    }

    // 确保 currentAddr 在 region 内
    if (currentAddr < regionAddress) {
      NSLog(@"Address 0x%llx is before region 0x%llx", currentAddr,
            regionAddress);
      return NO;
    }

    // 计算本次可以读取的字节数
    uint64_t bytesInRegion = (regionAddress + regionSize) - currentAddr;
    size_t toRead =
        (remaining < bytesInRegion) ? remaining : (size_t)bytesInRegion;

    outSize = 0;
    kr = mach_vm_read_overwrite((task_t)task, currentAddr, toRead,
                                (mach_vm_address_t)dest, &outSize);

    if (kr != KERN_SUCCESS || outSize != toRead) {
      NSLog(
          @"mach_vm_read_overwrite failed (kr=%d out=%llu want=%zu) at 0x%llx",
          kr, outSize, toRead, currentAddr);
      return NO;
    }

    dest += toRead;
    currentAddr += toRead;
    remaining -= toRead;
  }

  return YES;
}

NSString *NSStringFromMainImageInfo(MainImageInfo_t info) {
  return [NSString
      stringWithFormat:@"MainImageInfo: loadAddress=0x%llx, path=%@, ok=%d",
                       info.loadAddress, info.path, info.ok];
}

MainImageInfo_t imageInfoForPIDWithRetry(const char *sourcePath, vm_map_t task,
                                         pid_t pid) {
  for (int i = 0; i < MAX_DYLD_INFO_RETRIES; i++) {
    task_dyld_info_data_t taskInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr =
        task_info((task_t)task, TASK_DYLD_INFO, (task_info_t)&taskInfo, &count);
    if (kr != KERN_SUCCESS || taskInfo.all_image_info_addr == 0) {
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    struct dyld_all_image_infos infos = {0};
    if (!readProcessMemory(task, taskInfo.all_image_info_addr, &infos,
                           sizeof(infos))) {
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    // dyld not ready yet
    if (infos.infoArrayCount == 0 || infos.infoArray == NULL ||
        infos.dyldImageLoadAddress == NULL) {
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    mach_vm_size_t imageInfoSize =
        sizeof(struct dyld_image_info) * infos.infoArrayCount;
    void *imageInfoData = malloc(imageInfoSize);
    if (!readProcessMemory(task, (mach_vm_address_t)infos.infoArray,
                           imageInfoData, imageInfoSize)) {
      NSLog(@"failed to read dyld_image_info array for pid %d", pid);
      free(imageInfoData);
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    struct dyld_image_info *imageInfos =
        (struct dyld_image_info *)imageInfoData;
    NSLog(@"dyld has %u images for pid %d", infos.infoArrayCount, pid);
    NSLog(@"dyld main executable load address: 0x%llx",
          (uint64_t)infos.dyldImageLoadAddress);

    NSLog(@"expecting main executable path: %s", sourcePath);
    for (uint32_t j = 0; j < infos.infoArrayCount; j++) {
      char pathBuffer[PATH_MAX] = {0};
      if (!readProcessMemory(task, (uint64_t)imageInfos[j].imageFilePath,
                             pathBuffer, sizeof(pathBuffer) - 1)) {
        NSLog(@"failed to read image file path for pid %d", pid);
        continue;
      }

      // sometimes pathbuffer is /private prefixed
      // sometimes sourcePath is /private prefixed
      bool match = strcmp(pathBuffer, sourcePath) == 0;
      if (!match)
        removePrefix(pathBuffer, "/private");

      if (strcmp(pathBuffer, sourcePath) == 0) {
        NSString *pathString = [NSString stringWithUTF8String:pathBuffer];
        NSLog(@"found main executable image for pid %d: %@", pid, pathString);
        MainImageInfo_t result = {
            .loadAddress = (mach_vm_address_t)imageInfos[j].imageLoadAddress,
            .path = pathString,
            .ok = YES};

        free(imageInfoData);
        return result;
      }
    }
    free(imageInfoData); // Free memory if not found in this iteration (or loop
                         // continues? Logic check: original code frees it
                         // inside the loop on return, but if not returned, it
                         // leaks? Ah, it returns inside the loop. If loop
                         // finishes, it proceeds to retry. We should free
                         // before continue/retry. The original code allocates
                         // inside the retry loop. Wait, the original code
                         // `free(imageInfoData)` inside the loop is at line
                         // 147. If loop finishes without return,
                         // `imageInfoData` is leaked. I should fix this fix.)
  }

  NSLog(@"dyld images not ready for pid %d (timed out)", pid);
  return (MainImageInfo_t){.ok = NO};
}

BOOL readEncryptionInfo(vm_map_t task, uint64_t address,
                        struct encryption_info_command *encryptionInfo,
                        uint64_t *loadCommandAddress, BOOL *foundEncryption) {
  // 初始化输出参数
  if (foundEncryption)
    *foundEncryption = NO;

  if (!encryptionInfo || !loadCommandAddress) {
    NSLog(@"invalid encryptionInfo or loadCommandAddress");
    return NO;
  }

  struct mach_header_64 machHeader;
  if (!readProcessMemory(task, address, &machHeader, sizeof(machHeader))) {
    NSLog(@"failed to read mach header");
    return NO;
  }

  uint64_t offset = 0;
  switch (machHeader.magic) {
  case MH_MAGIC_64:
    offset = sizeof(struct mach_header_64);
    break;
  case MH_MAGIC:
    offset = sizeof(struct mach_header);
    break;
  default:
    NSLog(@"unknown Mach-O magic: 0x%x", machHeader.magic);
    return NO;
  }

  if (machHeader.ncmds == 0) {
    NSLog(@"no load commands found");
    return NO;
  }

  for (uint32_t i = 0; i < machHeader.ncmds; i++) {
    struct load_command loadCommand;
    if (!readProcessMemory(task, address + offset, &loadCommand,
                           sizeof(loadCommand))) {
      NSLog(@"failed to read load command");
      return NO;
    }

    if (loadCommand.cmd == LC_ENCRYPTION_INFO ||
        loadCommand.cmd == LC_ENCRYPTION_INFO_64) {
      struct encryption_info_command encInfo;
      if (!readProcessMemory(task, address + offset, &encInfo,
                             sizeof(encInfo))) {
        NSLog(@"failed to read encryption info command");
        return NO;
      }

      *encryptionInfo = encInfo;
      *loadCommandAddress = address + offset;
      if (foundEncryption)
        *foundEncryption = YES;
      return YES;
    }

    offset += loadCommand.cmdsize;
  }

  // 未找到加密命令，返回 YES 表示读取成功，但 foundEncryption 为 NO
  return YES;
}

BOOL rebuildDecryptedImageAtPath(NSString *sourcePath, vm_map_t task,
                                 uint64_t loadAddress,
                                 struct encryption_info_command *encryptionInfo,
                                 uint64_t loadCommandAddress,
                                 NSString *outputPath) {
  if (!encryptionInfo) {
    NSLog(@"encryptionInfo is NULL");
    return NO;
  }

  uint32_t cryptoff = encryptionInfo->cryptoff;
  uint32_t cryptsize = encryptionInfo->cryptsize;

  NSLog(@"Rebuilding decrypted image: %@", sourcePath);
  NSLog(@"Load address: 0x%llx", loadAddress);
  NSLog(@"cryptoff=0x%x cryptsize=0x%x cryptid=%d", cryptoff, cryptsize,
        encryptionInfo->cryptid);

  int fd = open(sourcePath.UTF8String, O_RDONLY);
  if (fd < 0) {
    NSLog(@"open source failed (%d): %@", errno, sourcePath);
    return NO;
  }

  off_t fileSize = lseek(fd, 0, SEEK_END);
  if (fileSize < 0) {
    NSLog(@"lseek end failed (%d)", errno);
    close(fd);
    return NO;
  }

  lseek(fd, 0, SEEK_SET);

  uint64_t cryptEnd = (uint64_t)cryptoff + (uint64_t)cryptsize;
  if (cryptEnd > (uint64_t)fileSize) {
    NSLog(@"crypt region outside file: cryptEnd=0x%llx fileSize=0x%llx",
          cryptEnd, (uint64_t)fileSize);
    close(fd);
    return NO;
  }

  // NSString *debugOutputPath = [outputPath
  // stringByAppendingString:@".decrypted"];
  int outputFd = open(outputPath.UTF8String, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (outputFd < 0) {
    NSLog(@"open output failed (%d): %@", errno, outputPath);
    close(fd);
    return NO;
  }

  // Leading [0, cryptoff)
  if (lseek(fd, 0, SEEK_SET) < 0) {
    NSLog(@"lseek set failed (%d)", errno);
    close(fd);
    close(outputFd);
    return NO;
  }

  if (cryptoff > 0) {
    void *leading = malloc(cryptoff);
    if (!leading) {
      NSLog(@"malloc leading failed");
      close(fd);
      close(outputFd);
      return NO;
    }

    if (!readFully(fd, leading, cryptoff)) {
      NSLog(@"read leading failed (%d)", errno);
      free(leading);
      close(fd);
      close(outputFd);
      return NO;
    }

    if (!writeFully(outputFd, leading, cryptoff)) {
      NSLog(@"write leading failed (%d)", errno);
      free(leading);
      close(fd);
      close(outputFd);
      return NO;
    }

    free(leading);
  }

  // [cryptoff .. cryptoff+cryptsize)
  if (cryptsize > 0) {
    void *decrypted = malloc(cryptsize);
    if (!decrypted) {
      NSLog(@"malloc decrypted failed");
      close(fd);
      close(outputFd);
      return NO;
    }

    // IMPORTANT: read from mapped memory at loadAddress + cryptoff
    if (!readProcessMemory(task, loadAddress + (uint64_t)cryptoff, decrypted,
                           cryptsize)) {
      NSLog(@"failed to read decrypted bytes from task memory");
      free(decrypted);
      close(fd);
      close(outputFd);
      return NO;
    }

    if (!writeFully(outputFd, decrypted, cryptsize)) {
      NSLog(@"write decrypted failed (%d)", errno);
      free(decrypted);
      close(fd);
      close(outputFd);
      return NO;
    }

    free(decrypted);
  }

  // Trailing [cryptEnd, EOF)
  uint64_t trailingSize = (uint64_t)fileSize - cryptEnd;
  if (trailingSize > 0) {
    uint8_t *buf = malloc(MALLOC_CHUNK_SIZE);
    if (!buf) {
      NSLog(@"malloc trailing buf failed");
      close(fd);
      close(outputFd);
      return NO;
    }

    if (lseek(fd, (off_t)cryptEnd, SEEK_SET) < 0) {
      NSLog(@"lseek to trailing failed (%d)", errno);
      free(buf);
      close(fd);
      close(outputFd);
      return NO;
    }

    uint64_t left = trailingSize;
    while (left > 0) {
      size_t toRead =
          (left > MALLOC_CHUNK_SIZE) ? MALLOC_CHUNK_SIZE : (size_t)left;

      if (!readFully(fd, buf, toRead)) {
        NSLog(@"read trailing failed (%d)", errno);
        free(buf);
        close(fd);
        close(outputFd);
        return NO;
      }

      if (!writeFully(outputFd, buf, toRead)) {
        NSLog(@"write trailing failed (%d)", errno);
        free(buf);
        close(fd);
        close(outputFd);
        return NO;
      }

      left -= toRead;
    }

    free(buf);
  }

  if (loadCommandAddress) {
    off_t cmdOff =
        (off_t)((uint64_t)loadCommandAddress - (uint64_t)loadAddress);

    if (lseek(outputFd, cmdOff, SEEK_SET) < 0) {
      NSLog(@"lseek to enc cmd failed (%d)", errno);
      close(fd);
      close(outputFd);
      return NO;
    }

    struct encryption_info_command outputEncInfo = {0};
    if (!readFully(outputFd, &outputEncInfo, sizeof(outputEncInfo))) {
      NSLog(@"read enc cmd failed (%d)", errno);
      close(fd);
      close(outputFd);
      return NO;
    }

    outputEncInfo.cryptid = 0;

    if (lseek(outputFd, cmdOff, SEEK_SET) < 0) {
      NSLog(@"lseek back to enc cmd failed (%d)", errno);
      close(fd);
      close(outputFd);
      return NO;
    }

    if (!writeFully(outputFd, &outputEncInfo, sizeof(outputEncInfo))) {
      NSLog(@"write enc cmd failed (%d)", errno);
      close(fd);
      close(outputFd);
      return NO;
    }
  }

  close(fd);
  close(outputFd);

  return YES;
}

// 在 dyld image list 中按路径前缀和镜像名称查找加载地址
BOOL findImageLoadAddress(const char *pathPrefix, const char *imageName,
                          vm_map_t task, pid_t pid, uint64_t *outLoadAddress,
                          NSString **outFullPath) {
  if (!pathPrefix || !imageName || !outLoadAddress) {
    NSLog(@"findImageLoadAddress: invalid arguments");
    return NO;
  }

  for (int i = 0; i < MAX_DYLD_INFO_RETRIES; i++) {
    task_dyld_info_data_t taskInfo;
    mach_msg_type_number_t count = TASK_DYLD_INFO_COUNT;
    kern_return_t kr =
        task_info((task_t)task, TASK_DYLD_INFO, (task_info_t)&taskInfo, &count);
    if (kr != KERN_SUCCESS || taskInfo.all_image_info_addr == 0) {
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    struct dyld_all_image_infos infos = {0};
    if (!readProcessMemory(task, taskInfo.all_image_info_addr, &infos,
                           sizeof(infos))) {
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    // dyld not ready yet
    if (infos.infoArrayCount == 0 || infos.infoArray == NULL) {
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    mach_vm_size_t imageInfoSize =
        sizeof(struct dyld_image_info) * infos.infoArrayCount;
    void *imageInfoData = malloc(imageInfoSize);
    if (!readProcessMemory(task, (mach_vm_address_t)infos.infoArray,
                           imageInfoData, imageInfoSize)) {
      free(imageInfoData);
      usleep(DYLD_INFO_RETRY_DELAY_US);
      continue;
    }

    struct dyld_image_info *imageInfos =
        (struct dyld_image_info *)imageInfoData;

    // 遍历所有镜像，查找匹配的路径
    for (uint32_t j = 0; j < infos.infoArrayCount; j++) {
      char pathBuffer[PATH_MAX] = {0};
      if (!readProcessMemory(task, (uint64_t)imageInfos[j].imageFilePath,
                             pathBuffer, sizeof(pathBuffer) - 1)) {
        continue;
      }

      // 移除可能的 /private 前缀
      char *checkPath = pathBuffer;
      if (strncmp(checkPath, "/private", 8) == 0) {
        checkPath += 8;
      }

      // 检查路径是否以 pathPrefix 开头，并且包含 imageName
      if (strncmp(checkPath, pathPrefix, strlen(pathPrefix)) == 0) {
        // 检查 imageName 是否在路径中
        if (strstr(checkPath, imageName) != NULL) {
          *outLoadAddress = (uint64_t)imageInfos[j].imageLoadAddress;
          if (outFullPath) {
            *outFullPath = [NSString stringWithUTF8String:pathBuffer];
          }
          NSLog(@"findImageLoadAddress: found '%s' at 0x%llx, path: %s",
                imageName, *outLoadAddress, pathBuffer);
          free(imageInfoData);
          return YES;
        }
      }
    }

    free(imageInfoData);
    // 如果已经成功读取了 image list 但没找到，不需要继续重试
    // 说明镜像确实没有加载
    NSLog(@"findImageLoadAddress: '%s' not found in %u loaded images",
          imageName, infos.infoArrayCount);
    return NO;
  }

  NSLog(@"findImageLoadAddress: timed out waiting for dyld info");
  return NO;
}

#pragma mark - Extension Process Handling

#import <sys/sysctl.h>

// 扫描所有运行中的与目标应用相关的扩展进程
BOOL findRunningExtensionProcesses(NSString *bundlePath,
                                   ExtensionProcessInfo_t **outProcesses,
                                   int *outCount) {
  if (!bundlePath || !outProcesses || !outCount) {
    NSLog(@"findRunningExtensionProcesses: invalid arguments");
    return NO;
  }

  *outProcesses = NULL;
  *outCount = 0;

  // 获取应用的 PlugIns 目录下的所有扩展
  NSString *plugInsPath =
      [bundlePath stringByAppendingPathComponent:@"PlugIns"];
  NSFileManager *fm = [NSFileManager defaultManager];

  if (![fm fileExistsAtPath:plugInsPath]) {
    NSLog(@"findRunningExtensionProcesses: no PlugIns directory");
    return YES; // 没有扩展目录，不是错误
  }

  NSArray *extensions = [fm contentsOfDirectoryAtPath:plugInsPath error:nil];
  if (!extensions || extensions.count == 0) {
    return YES;
  }

  // 收集所有扩展的可执行文件名
  NSMutableDictionary *extNameToBundle = [NSMutableDictionary dictionary];
  for (NSString *extItem in extensions) {
    if (![extItem hasSuffix:@".appex"])
      continue;

    NSString *extPath = [plugInsPath stringByAppendingPathComponent:extItem];
    NSString *infoPlistPath =
        [extPath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info =
        [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
    NSString *execName = info[@"CFBundleExecutable"];
    if (!execName) {
      execName = [extItem stringByDeletingPathExtension];
    }
    extNameToBundle[execName] = extItem;
  }

  if (extNameToBundle.count == 0) {
    return YES;
  }

  // 使用 sysctl 遍历所有进程
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
  size_t size;

  if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
    NSLog(@"findRunningExtensionProcesses: sysctl size failed");
    return NO;
  }

  struct kinfo_proc *procs = malloc(size);
  if (!procs) {
    NSLog(@"findRunningExtensionProcesses: malloc failed");
    return NO;
  }

  if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
    NSLog(@"findRunningExtensionProcesses: sysctl failed");
    free(procs);
    return NO;
  }

  int procCount = (int)(size / sizeof(struct kinfo_proc));
  NSLog(@"findRunningExtensionProcesses: scanning %d processes for %lu "
        @"extensions",
        procCount, (unsigned long)extNameToBundle.count);

  // 临时数组存储找到的扩展进程
  ExtensionProcessInfo_t *foundProcesses =
      malloc(sizeof(ExtensionProcessInfo_t) * extNameToBundle.count);
  int foundCount = 0;

  for (int i = 0; i < procCount && foundCount < (int)extNameToBundle.count;
       i++) {
    pid_t pid = procs[i].kp_proc.p_pid;
    if (pid <= 0 || pid == getpid()) {
      continue;
    }

    char *procName = procs[i].kp_proc.p_comm;
    NSString *procNameStr = [NSString stringWithUTF8String:procName];

    // 检查是否匹配任何扩展可执行文件名
    NSString *matchedBundle = nil;

    // 精确匹配
    matchedBundle = extNameToBundle[procNameStr];

    // 如果没有精确匹配，尝试截断匹配（进程名可能被截断为16字符）
    if (!matchedBundle) {
      for (NSString *execName in extNameToBundle) {
        if (execName.length > 15) {
          NSString *truncated = [execName substringToIndex:15];
          if ([procNameStr isEqualToString:truncated]) {
            matchedBundle = extNameToBundle[execName];
            procNameStr = execName; // 使用完整名称
            break;
          }
        }
      }
    }

    if (matchedBundle) {
      NSLog(@"findRunningExtensionProcesses: found extension process PID=%d, "
            @"name=%@, bundle=%@",
            pid, procNameStr, matchedBundle);

      ExtensionProcessInfo_t *info = &foundProcesses[foundCount];
      info->pid = pid;
      strncpy(info->executableName, procNameStr.UTF8String,
              sizeof(info->executableName) - 1);
      strncpy(info->extBundleName, matchedBundle.UTF8String,
              sizeof(info->extBundleName) - 1);
      foundCount++;
    }
  }

  free(procs);

  if (foundCount > 0) {
    *outProcesses = foundProcesses;
    *outCount = foundCount;
  } else {
    free(foundProcesses);
  }

  NSLog(@"findRunningExtensionProcesses: found %d running extension processes",
        foundCount);
  return YES;
}

// 通过进程 PID 获取扩展的加载地址并脱壳
BOOL decryptExtensionProcess(pid_t pid, NSString *extBinaryPath,
                             NSString *outputPath, NSString **errorMessage) {
  if (pid <= 0 || !extBinaryPath || !outputPath) {
    if (errorMessage)
      *errorMessage = @"Invalid arguments";
    return NO;
  }

  NSLog(@"decryptExtensionProcess: PID=%d, path=%@", pid, extBinaryPath);

  // 1. 获取 task port
  mach_port_t task = MACH_PORT_NULL;
  kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);

  if (kr != KERN_SUCCESS || task == MACH_PORT_NULL) {
    NSLog(@"decryptExtensionProcess: task_for_pid failed: %s",
          mach_error_string(kr));
    if (errorMessage)
      *errorMessage = [NSString
          stringWithFormat:@"task_for_pid failed: %s", mach_error_string(kr)];
    return NO;
  }

  // 2. 找到扩展在内存中的加载地址
  MainImageInfo_t imageInfo =
      imageInfoForPIDWithRetry(extBinaryPath.UTF8String, task, pid);

  if (!imageInfo.ok) {
    NSLog(@"decryptExtensionProcess: failed to find image load address");
    if (errorMessage)
      *errorMessage = @"Failed to find image in memory";
    return NO;
  }

  NSLog(@"decryptExtensionProcess: load address = 0x%llx",
        imageInfo.loadAddress);

  // 3. 读取加密信息
  struct encryption_info_command encInfo;
  uint64_t loadCmdAddr = 0;
  BOOL foundEnc = NO;

  if (!readEncryptionInfo(task, imageInfo.loadAddress, &encInfo, &loadCmdAddr,
                          &foundEnc)) {
    NSLog(@"decryptExtensionProcess: failed to read encryption info");
    if (errorMessage)
      *errorMessage = @"Failed to read encryption info";
    return NO;
  }

  if (!foundEnc || encInfo.cryptid == 0) {
    NSLog(@"decryptExtensionProcess: extension is not encrypted");
    // 扩展未加密，直接复制
    NSError *copyError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:outputPath error:nil];
    BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:extBinaryPath
                                                          toPath:outputPath
                                                           error:&copyError];
    if (!copied) {
      if (errorMessage)
        *errorMessage = copyError.localizedDescription;
      return NO;
    }
    return YES;
  }

  // 4. 执行脱壳
  NSLog(@"decryptExtensionProcess: decrypting (cryptoff=0x%x, cryptsize=0x%x)",
        encInfo.cryptoff, encInfo.cryptsize);

  BOOL success =
      rebuildDecryptedImageAtPath(extBinaryPath, task, imageInfo.loadAddress,
                                  &encInfo, loadCmdAddr, outputPath);

  if (!success) {
    NSLog(@"decryptExtensionProcess: rebuildDecryptedImageAtPath failed");
    if (errorMessage)
      *errorMessage = @"Failed to rebuild decrypted image";
    return NO;
  }

  NSLog(@"decryptExtensionProcess: successfully decrypted extension");
  return YES;
}

#pragma mark - Encryption Detection

EncryptionStatus checkBinaryEncryptionStatus(NSString *binaryPath) {
  if (!binaryPath ||
      ![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
    return EncryptionStatusUnknown;
  }

  int fd = open(binaryPath.UTF8String, O_RDONLY);
  if (fd < 0) {
    NSLog(@"checkBinaryEncryptionStatus: cannot open file %@", binaryPath);
    return EncryptionStatusUnknown;
  }

  // 读取魔数
  uint32_t magic = 0;
  if (read(fd, &magic, sizeof(magic)) != sizeof(magic)) {
    close(fd);
    return EncryptionStatusUnknown;
  }

  // 处理 FAT 二进制
  uint32_t headerOffset = 0;
  if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
    // FAT 二进制，找到 arm64 slice
    lseek(fd, 0, SEEK_SET);
    struct fat_header fatHeader;
    if (read(fd, &fatHeader, sizeof(fatHeader)) != sizeof(fatHeader)) {
      close(fd);
      return EncryptionStatusUnknown;
    }

    uint32_t nfat = OSSwapBigToHostInt32(fatHeader.nfat_arch);
    for (uint32_t i = 0; i < nfat; i++) {
      struct fat_arch arch;
      if (read(fd, &arch, sizeof(arch)) != sizeof(arch)) {
        break;
      }
      cpu_type_t cputype = OSSwapBigToHostInt32(arch.cputype);
      if (cputype == CPU_TYPE_ARM64) {
        headerOffset = OSSwapBigToHostInt32(arch.offset);
        break;
      }
    }

    if (headerOffset == 0) {
      // 没找到 arm64，尝试第一个 slice
      lseek(fd, sizeof(struct fat_header), SEEK_SET);
      struct fat_arch firstArch;
      if (read(fd, &firstArch, sizeof(firstArch)) == sizeof(firstArch)) {
        headerOffset = OSSwapBigToHostInt32(firstArch.offset);
      }
    }

    // 读取实际的 Mach-O magic
    lseek(fd, headerOffset, SEEK_SET);
    if (read(fd, &magic, sizeof(magic)) != sizeof(magic)) {
      close(fd);
      return EncryptionStatusUnknown;
    }
  }

  // 检查是否是有效的 Mach-O
  BOOL is64 = NO;
  if (magic == MH_MAGIC_64 || magic == MH_CIGAM_64) {
    is64 = YES;
  } else if (magic != MH_MAGIC && magic != MH_CIGAM) {
    close(fd);
    return EncryptionStatusUnknown;
  }

  // 读取 Mach-O header
  lseek(fd, headerOffset, SEEK_SET);

  uint32_t ncmds = 0;
  uint32_t sizeofcmds = 0;

  if (is64) {
    struct mach_header_64 header;
    if (read(fd, &header, sizeof(header)) != sizeof(header)) {
      close(fd);
      return EncryptionStatusUnknown;
    }
    ncmds = header.ncmds;
    sizeofcmds = header.sizeofcmds;
  } else {
    struct mach_header header;
    if (read(fd, &header, sizeof(header)) != sizeof(header)) {
      close(fd);
      return EncryptionStatusUnknown;
    }
    ncmds = header.ncmds;
    sizeofcmds = header.sizeofcmds;
  }

  // 遍历 load commands 查找加密信息
  EncryptionStatus result = EncryptionStatusNotFound;

  for (uint32_t i = 0; i < ncmds; i++) {
    struct load_command lc;
    off_t lcOffset = lseek(fd, 0, SEEK_CUR);

    if (read(fd, &lc, sizeof(lc)) != sizeof(lc)) {
      break;
    }

    if (lc.cmd == LC_ENCRYPTION_INFO || lc.cmd == LC_ENCRYPTION_INFO_64) {
      // 回到命令开始位置读取完整结构
      lseek(fd, lcOffset, SEEK_SET);

      struct encryption_info_command encCmd;
      if (read(fd, &encCmd, sizeof(encCmd)) == sizeof(encCmd)) {
        if (encCmd.cryptid == 0) {
          result = EncryptionStatusDecrypted;
        } else {
          result = EncryptionStatusEncrypted;
        }
      }
      break;
    }

    // 跳到下一个命令
    lseek(fd, lcOffset + lc.cmdsize, SEEK_SET);
  }

  close(fd);
  return result;
}

NSString *encryptionStatusDescription(EncryptionStatus status) {
  switch (status) {
  case EncryptionStatusEncrypted:
    return @"🔒 加密";
  case EncryptionStatusDecrypted:
    return @"🔓 已脱壳";
  case EncryptionStatusNotFound:
    return @"📦 无加密";
  case EncryptionStatusUnknown:
  default:
    return @"❓ 未知";
  }
}
