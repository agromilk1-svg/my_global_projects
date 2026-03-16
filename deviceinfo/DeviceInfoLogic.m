#import "DeviceInfoLogic.h"
#import <AdSupport/ASIdentifierManager.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

@implementation DeviceInfoItem
@end

@implementation DeviceInfoLogic

+ (NSString *)titleForSection:(DeviceInfoSection)section {
  switch (section) {
  case DeviceInfoSectionSystem:
    return @"一、系统版本信息";
  case DeviceInfoSectionDevice:
    return @"二、设备型号信息";
  case DeviceInfoSectionScreen:
    return @"三、屏幕/分辨率信息";
  case DeviceInfoSectionLocale:
    return @"四、区域/语言设置";
  case DeviceInfoSectionNetwork:
    return @"五、网络/运营商信息";
  case DeviceInfoSectionIdentifiers:
    return @"六、唯一标识符";
  case DeviceInfoSectionHardware:
    return @"七、硬件参数";
  case DeviceInfoSectionSecurity:
    return @"八、安全性检测";
  case DeviceInfoSectionInjection:
    return @"九、注入与篡改检测";
  default:
    return @"";
  }
}

+ (NSArray<DeviceInfoItem *> *)itemsForSection:(DeviceInfoSection)section {
  NSMutableArray *items = [NSMutableArray array];

  switch (section) {
  case DeviceInfoSectionSystem: {
    [self addItem:items
             name:@"iOS 版本"
            value:[UIDevice currentDevice].systemVersion];
    [self addItem:items
             name:@"构建版本"
            value:[self sysctlStringForName:@"kern.osversion"]];
    [self addItem:items
             name:@"内核版本"
            value:[self sysctlStringForName:@"kern.version"]];
    [self addItem:items
             name:@"系统名称"
            value:[UIDevice currentDevice].systemName];
    break;
  }
  case DeviceInfoSectionDevice: {
    NSString *machine = [self getMachineModel];
    [self addItem:items name:@"型号标识" value:machine];
    [self addItem:items name:@"设备名称" value:[UIDevice currentDevice].name];
    [self addItem:items
             name:@"本地化型号"
            value:[UIDevice currentDevice].localizedModel];
    [self addItem:items
             name:@"产品名称"
            value:[self getProductNameForModel:machine]];
    break;
  }
  case DeviceInfoSectionScreen: {
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat scale = [UIScreen mainScreen].scale;
    CGRect nativeBounds = [UIScreen mainScreen].nativeBounds;

    [self addItem:items
             name:@"逻辑分辨率"
            value:[NSString stringWithFormat:@"%.0f x %.0f", bounds.size.width,
                                             bounds.size.height]];
    [self addItem:items
             name:@"缩放因子"
            value:[NSString stringWithFormat:@"@%.0fx", scale]];
    [self addItem:items
             name:@"物理分辨率"
            value:[NSString stringWithFormat:@"%.0f x %.0f",
                                             nativeBounds.size.width,
                                             nativeBounds.size.height]];
    [self addItem:items
             name:@"刷新率"
            value:[NSString
                      stringWithFormat:@"%ld Hz", (long)[UIScreen mainScreen]
                                                      .maximumFramesPerSecond]];
    break;
  }
  case DeviceInfoSectionLocale: {
    NSLocale *locale = [NSLocale currentLocale];
    [self addItem:items
             name:@"国家/地区"
            value:[locale objectForKey:NSLocaleCountryCode] ?: @"N/A"];
    [self addItem:items
             name:@"语言"
            value:[locale objectForKey:NSLocaleLanguageCode] ?: @"N/A"];
    [self addItem:items name:@"区域标识" value:locale.localeIdentifier];
    [self addItem:items name:@"时区" value:[NSTimeZone localTimeZone].name];
    [self addItem:items
             name:@"货币"
            value:[locale objectForKey:NSLocaleCurrencyCode] ?: @"N/A"];
    break;
  }
  case DeviceInfoSectionNetwork: {
    CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
    // Deprecated in recent iOS but still works for basic info or use
    // serviceSubscriberCellularProviders
    CTCarrier *carrier = networkInfo.subscriberCellularProvider;
    // Handle multiple sims roughly if needed, for now use primary.
    if (!carrier && [networkInfo respondsToSelector:@selector
                                 (serviceSubscriberCellularProviders)]) {
      carrier =
          networkInfo.serviceSubscriberCellularProviders.allValues.firstObject;
    }

    [self addItem:items name:@"运营商" value:carrier.carrierName ?: @"N/A"];
    [self addItem:items name:@"MCC" value:carrier.mobileCountryCode ?: @"N/A"];
    [self addItem:items name:@"MNC" value:carrier.mobileNetworkCode ?: @"N/A"];

    NSString *tech = networkInfo.currentRadioAccessTechnology;
    // Trying to get from serviceCurrentRadioAccessTechnology if available
    if (!tech && [networkInfo respondsToSelector:@selector
                              (serviceCurrentRadioAccessTechnology)]) {
      tech =
          networkInfo.serviceCurrentRadioAccessTechnology.allValues.firstObject;
    }
    [self addItem:items
             name:@"网络类型"
            value:[self getNetworkTypeString:tech]];
    break;
  }
  case DeviceInfoSectionIdentifiers: {
    [self addItem:items
             name:@"IDFV"
            value:[UIDevice currentDevice].identifierForVendor.UUIDString
                      ?: @"N/A"];

    NSString *idfa = @"N/A";
    // Check for AdSupport framework availability
    if (NSClassFromString(@"ASIdentifierManager")) {
      idfa = [[ASIdentifierManager sharedManager]
                  .advertisingIdentifier UUIDString];
      if ([idfa isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        idfa = @"无权限 / 限制跟踪";
      }
    }
    [self addItem:items name:@"IDFA" value:idfa];
    break;
  }
  case DeviceInfoSectionHardware: {
    int cores;
    size_t size = sizeof(cores);
    sysctlbyname("hw.ncpu", &cores, &size, NULL, 0);
    [self addItem:items
             name:@"CPU 核心"
            value:[NSString stringWithFormat:@"%d", cores]];

    uint64_t memsize;
    size = sizeof(memsize);
    sysctlbyname("hw.memsize", &memsize, &size, NULL, 0);
    [self addItem:items
             name:@"物理内存"
            value:[NSString
                      stringWithFormat:@"%.2f GB",
                                       (double)memsize / (1024 * 1024 * 1024)]];

    [self addItem:items name:@"存储容量" value:[self getStorageCapacity]];
    [self addItem:items name:@"CPU 架构" value:[self getCPUType]];
    break;
  }
  case DeviceInfoSectionSecurity: {
    [self addItem:items
             name:@"越狱状态"
            value:[self isJailbroken] ? @"已越狱" : @"未越狱"];
    [self addItem:items
             name:@"TrollStore"
            value:[self isTrollStoreActive] ? @"检测到" : @"未检测到"];
    [self
        addItem:items
           name:@"脱壳状态"
          value:[self isDecrypted] ? @"已脱壳 / 未加密" : @"加密 (App Store)"];

    struct timeval boottime;
    size_t size = sizeof(boottime);
    sysctlbyname("kern.boottime", &boottime, &size, NULL, 0);
    NSDate *bootDate = [NSDate dateWithTimeIntervalSince1970:boottime.tv_sec];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    [self addItem:items name:@"开机时间" value:[fmt stringFromDate:bootDate]];

    [self addItem:items name:@"可用空间" value:[self getDiskFreeSpace]];
    break;
  }
  case DeviceInfoSectionInjection: {
    // 1. 动态库注入检测
    NSArray *suspiciousLibs = [self getSuspiciousLibraries];
    if (suspiciousLibs.count > 0) {
      for (NSString *lib in suspiciousLibs) {
        [self addItem:items name:@"发现注入库" value:lib];
      }
    } else {
      [self addItem:items name:@"动态库检测" value:@"未发现异常"];
    }

    // 2. 环境变量检测
    char *env = getenv("DYLD_INSERT_LIBRARIES");
    if (env) {
      [self addItem:items
               name:@"DYLD_INSERT"
              value:[NSString stringWithUTF8String:env]];
    } else {
      [self addItem:items name:@"环境变量" value:@"正常"];
    }

    // 3. 调试状态检测
    BOOL isDebugged = [self isDebugged];
    [self addItem:items
             name:@"调试状态"
            value:isDebugged ? @"正在被调试 (Traced)" : @"未调试"];
    break;
  }
  default:
    break;
  }

  return items;
}

#pragma mark - Helper Methods

+ (void)addItem:(NSMutableArray *)array
           name:(NSString *)name
          value:(NSString *)value {
  DeviceInfoItem *item = [[DeviceInfoItem alloc] init];
  item.displayName = name;
  item.value = value ?: @"N/A";
  [array addObject:item];
}

+ (NSString *)sysctlStringForName:(NSString *)name {
  size_t size;
  sysctlbyname(name.UTF8String, NULL, &size, NULL, 0);
  if (size == 0)
    return @"N/A";
  char *value = malloc(size);
  sysctlbyname(name.UTF8String, value, &size, NULL, 0);
  NSString *result = [NSString stringWithUTF8String:value];
  free(value);
  return result;
}

+ (NSString *)getMachineModel {
  struct utsname systemInfo;
  uname(&systemInfo);
  return [NSString stringWithCString:systemInfo.machine
                            encoding:NSUTF8StringEncoding];
}

+ (NSString *)getProductNameForModel:(NSString *)model {
  NSDictionary *models = @{
    @"iPhone14,2" : @"iPhone 13 Pro",
    @"iPhone14,3" : @"iPhone 13 Pro Max",
    @"iPhone14,5" : @"iPhone 13",
    @"iPhone15,2" : @"iPhone 14 Pro",
    @"iPhone15,3" : @"iPhone 14 Pro Max",
    @"iPhone16,1" : @"iPhone 15 Pro",
    @"iPhone16,2" : @"iPhone 15 Pro Max",
  };
  return models[model] ?: model;
}

+ (NSString *)getNetworkTypeString:(NSString *)radioType {
  if (!radioType)
    return @"N/A";
  if ([radioType containsString:@"NR"])
    return @"5G";
  if ([radioType containsString:@"LTE"])
    return @"4G LTE";
  if ([radioType containsString:@"WCDMA"])
    return @"3G";
  return radioType;
}

+ (NSString *)getCPUType {
  struct utsname systemInfo;
  uname(&systemInfo);
  NSString *machine = [NSString stringWithCString:systemInfo.machine
                                         encoding:NSUTF8StringEncoding];
  // Simple heuristic
  if ([machine containsString:@"iPhone"] || [machine containsString:@"iPad"])
    return @"arm64";
  // Could refine to distinguish arm64e for A12+ but for now arm64 is fine
  return @"arm64";
}

+ (NSString *)getStorageCapacity {
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfFileSystemForPath:NSHomeDirectory()
                              error:nil];
  unsigned long long total = [attrs[NSFileSystemSize] unsignedLongLongValue];
  double gb = (double)total / (1024 * 1024 * 1024);
  if (gb < 48)
    return @"32 GB";
  if (gb < 96)
    return @"64 GB";
  if (gb < 192)
    return @"128 GB";
  if (gb < 384)
    return @"256 GB";
  if (gb < 768)
    return @"512 GB";
  return @"1 TB";
}

+ (NSString *)getDiskFreeSpace {
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfFileSystemForPath:NSHomeDirectory()
                              error:nil];
  unsigned long long free = [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
  return [NSString
      stringWithFormat:@"%.1f GB", (double)free / (1024 * 1024 * 1024)];
}

// Security Checks (Existing Logic)
+ (BOOL)isDecrypted {
  const struct mach_header *header = _dyld_get_image_header(0);
  if (!header)
    return NO;
  uintptr_t cur = (uintptr_t)header + sizeof(struct mach_header_64);
  if (header->magic == MH_MAGIC)
    cur = (uintptr_t)header + sizeof(struct mach_header);
  struct load_command *cmd = (struct load_command *)cur;
  for (uint32_t i = 0; i < header->ncmds; i++) {
    if (cmd->cmd == LC_ENCRYPTION_INFO_64) {
      struct encryption_info_command_64 *c =
          (struct encryption_info_command_64 *)cmd;
      return c->cryptid == 0;
    } else if (cmd->cmd == LC_ENCRYPTION_INFO) {
      struct encryption_info_command *c = (struct encryption_info_command *)cmd;
      return c->cryptid == 0;
    }
    cur += cmd->cmdsize;
    cmd = (struct load_command *)cur;
  }
  return YES;
}

+ (BOOL)isTrollStoreActive {
  if ([[UIApplication sharedApplication]
          canOpenURL:[NSURL URLWithString:@"trollstore://"]])
    return YES;
  if ([[NSFileManager defaultManager]
          fileExistsAtPath:@"/Applications/TrollStore.app"])
    return YES;
  return NO;
}

+ (BOOL)isJailbroken {
  NSArray *paths = @[
    @"/Applications/Cydia.app", @"/bin/bash", @"/usr/sbin/sshd", @"/etc/apt"
  ];
  for (NSString *p in paths) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:p])
      return YES;
  }
  NSError *err;
  [@"test" writeToFile:@"/private/jb_test"
            atomically:YES
              encoding:NSUTF8StringEncoding
                 error:&err];
  if (!err) {
    [[NSFileManager defaultManager] removeItemAtPath:@"/private/jb_test"
                                               error:nil];
    return YES;
  }
  return NO;
}

+ (NSArray<NSString *> *)getSuspiciousLibraries {
  NSMutableArray *found = [NSMutableArray array];
  uint32_t count = _dyld_image_count();

  // 黑名单关键字
  NSArray *blacklist = @[
    @"MobileSubstrate", @"CydiaSubstrate", @"TweakInject", @"Substitute",
    @"libhooker", @"FridaGadget", @"frida", @"SSLKillSwitch", @"ECDeviceSpoof"
  ];

  for (uint32_t i = 0; i < count; i++) {
    const char *name = _dyld_get_image_name(i);
    if (name) {
      NSString *imageName = [NSString stringWithUTF8String:name];
      for (NSString *key in blacklist) {
        if ([imageName containsString:key]) {
          [found addObject:imageName.lastPathComponent];
          break;
        }
      }
    }
  }
  return found;
}

+ (BOOL)isDebugged {
  int junk;
  int mib[4];
  struct kinfo_proc info;
  size_t size;

  info.kp_proc.p_flag = 0;

  mib[0] = CTL_KERN;
  mib[1] = KERN_PROC;
  mib[2] = KERN_PROC_PID;
  mib[3] = getpid();

  size = sizeof(info);
  junk = sysctl(mib, sizeof(mib) / sizeof(*mib), &info, &size, NULL, 0);

  if (junk != 0) {
    return NO;
  }

  return (info.kp_proc.p_flag & P_TRACED) != 0;
}

@end
