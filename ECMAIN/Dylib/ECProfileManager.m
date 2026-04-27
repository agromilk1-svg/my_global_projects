//
//  ECProfileManager.m
//  ECProfileSpoof (方案 C)
//
//  多 Profile 生命周期管理器实现
//

#import "ECProfileManager.h"
#import <Security/Security.h>

// 日志宏
static void ECPLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void ECPLog(NSString *format, ...) {
  va_list args;
  va_start(args, format);
  NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);
  NSLog(@"[ECProfileC] %@", msg);
}

// Profile 数据根目录名
static NSString *const kProfilesDir = @"Documents/.ecprofiles";
static NSString *const kActiveProfileFile = @"active_profile";
static NSString *const kProfilesListFile = @"profiles.plist";
static NSString *const kDeviceConfigFile = @"device.plist";
static NSString *const kProfileDirPrefix = @"profile_";
static NSString *const kProfileHomeSubdir = @"Home";

#pragma mark - ECProfileInfo

@implementation ECProfileInfo

- (NSDictionary *)toDictionary {
  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  dict[@"id"] = self.profileId ?: @"0";
  dict[@"name"] = self.name ?: @"默认";
  if (self.createdDate) dict[@"created"] = self.createdDate;
  if (self.lastUsedDate) dict[@"lastUsed"] = self.lastUsedDate;
  return dict;
}

+ (instancetype)fromDictionary:(NSDictionary *)dict {
  ECProfileInfo *info = [[ECProfileInfo alloc] init];
  info.profileId = dict[@"id"] ?: @"0";
  info.name = dict[@"name"] ?: @"默认";
  info.createdDate = dict[@"created"];
  info.lastUsedDate = dict[@"lastUsed"];
  return info;
}

@end

#pragma mark - ECProfileManager

@interface ECProfileManager ()
@property (nonatomic, copy) NSString *cachedRealHome;
@property (nonatomic, copy) NSString *cachedProfileHome;
@property (nonatomic, copy) NSString *cachedActiveId;
@property (nonatomic, strong) NSDictionary *cachedDeviceConfig;
@end

@implementation ECProfileManager

+ (instancetype)shared {
  static ECProfileManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECProfileManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    // 保存真实 HOME（在 Hook 生效前调用）
    const char *homeEnv = getenv("HOME");
    _cachedRealHome = homeEnv ? [NSString stringWithUTF8String:homeEnv] : @"/var/mobile";
    
    // 初始化 Profile 系统
    [self ensureProfilesDirectory];
    [self ensureDefaultProfile];
    
    // 加载当前 Profile
    _cachedActiveId = [self loadActiveProfileId];
    _cachedProfileHome = [self buildProfileHomePath:_cachedActiveId];
    _cachedDeviceConfig = [self loadDeviceConfig:_cachedActiveId];
    
    // 确保目录存在
    [self ensureProfileDirectoryStructure:_cachedActiveId];
    
    ECPLog(@"✅ ProfileManager 初始化完成");
    ECPLog(@"   真实 HOME: %@", _cachedRealHome);
    ECPLog(@"   活跃 Profile: %@ (ID: %@)", [self activeProfileName], _cachedActiveId);
    ECPLog(@"   虚拟 HOME: %@", _cachedProfileHome);
    
    // 更新最后使用时间
    [self touchActiveProfile];
  }
  return self;
}

#pragma mark - 目录管理

- (NSString *)profilesBaseDirectory {
  return [self.cachedRealHome stringByAppendingPathComponent:kProfilesDir];
}

- (NSString *)realHomeDirectory {
  return self.cachedRealHome;
}

- (void)ensureProfilesDirectory {
  NSString *baseDir = [self profilesBaseDirectory];
  NSFileManager *fm = [NSFileManager defaultManager];
  if (![fm fileExistsAtPath:baseDir]) {
    [fm createDirectoryAtPath:baseDir
        withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];
    ECPLog(@"📁 创建 Profile 根目录: %@", baseDir);
  }
}

- (void)ensureDefaultProfile {
  NSArray *profiles = [self allProfiles];
  if (profiles.count == 0) {
    ECPLog(@"📝 首次启动，创建默认 Profile...");
    [self createNewProfileWithName:@"主号"];
    
    // 设置为默认激活
    NSString *activePath = [[self profilesBaseDirectory]
        stringByAppendingPathComponent:kActiveProfileFile];
    [@"0" writeToFile:activePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
}

- (void)ensureProfileDirectoryStructure:(NSString *)profileId {
  NSString *profileHome = [self buildProfileHomePath:profileId];
  NSFileManager *fm = [NSFileManager defaultManager];
  
  NSArray *dirs = @[
    profileHome,
    [profileHome stringByAppendingPathComponent:@"Documents"],
    [profileHome stringByAppendingPathComponent:@"Library"],
    [profileHome stringByAppendingPathComponent:@"Library/Preferences"],
    [profileHome stringByAppendingPathComponent:@"Library/Caches"],
    [profileHome stringByAppendingPathComponent:@"Library/Application Support"],
    [profileHome stringByAppendingPathComponent:@"Library/Cookies"],
    [profileHome stringByAppendingPathComponent:@"Library/WebKit"],
    [profileHome stringByAppendingPathComponent:@"tmp"],
  ];
  
  for (NSString *dir in dirs) {
    if (![fm fileExistsAtPath:dir]) {
      [fm createDirectoryAtPath:dir
          withIntermediateDirectories:YES
                          attributes:nil
                               error:nil];
    }
  }
}

- (NSString *)buildProfileHomePath:(NSString *)profileId {
  return [NSString stringWithFormat:@"%@/%@%@/%@",
      [self profilesBaseDirectory], kProfileDirPrefix, profileId, kProfileHomeSubdir];
}

#pragma mark - Active Profile

- (NSString *)loadActiveProfileId {
  NSString *activePath = [[self profilesBaseDirectory]
      stringByAppendingPathComponent:kActiveProfileFile];
  NSString *profileId = [NSString stringWithContentsOfFile:activePath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
  profileId = [profileId stringByTrimmingCharactersInSet:
      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  
  if (!profileId || profileId.length == 0) {
    return @"0"; // 默认 Profile
  }
  return profileId;
}

- (NSString *)activeProfileId {
  return self.cachedActiveId ?: @"0";
}

- (NSString *)activeProfileName {
  NSArray<ECProfileInfo *> *profiles = [self allProfiles];
  for (ECProfileInfo *p in profiles) {
    if ([p.profileId isEqualToString:self.cachedActiveId]) {
      return p.name;
    }
  }
  return @"默认";
}

- (NSString *)profileHomeDirectory {
  return self.cachedProfileHome;
}

- (NSDictionary *)activeDeviceConfig {
  return self.cachedDeviceConfig ?: @{};
}

#pragma mark - Profile CRUD

- (NSArray<ECProfileInfo *> *)allProfiles {
  NSString *listPath = [[self profilesBaseDirectory]
      stringByAppendingPathComponent:kProfilesListFile];
  NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:listPath];
  
  NSArray *profileDicts = plist[@"profiles"];
  if (!profileDicts) return @[];
  
  NSMutableArray<ECProfileInfo *> *results = [NSMutableArray array];
  for (NSDictionary *dict in profileDicts) {
    [results addObject:[ECProfileInfo fromDictionary:dict]];
  }
  return results;
}

- (void)saveProfilesList:(NSArray<ECProfileInfo *> *)profiles {
  NSMutableArray *dicts = [NSMutableArray array];
  for (ECProfileInfo *p in profiles) {
    [dicts addObject:[p toDictionary]];
  }
  NSDictionary *plist = @{@"profiles": dicts};
  
  NSString *listPath = [[self profilesBaseDirectory]
      stringByAppendingPathComponent:kProfilesListFile];
  [plist writeToFile:listPath atomically:YES];
}

- (NSString *)createNewProfileWithName:(NSString *)name {
  NSArray<ECProfileInfo *> *existing = [self allProfiles];
  
  // 计算新 ID：取已存在的最大 ID + 1
  int maxId = -1;
  for (ECProfileInfo *p in existing) {
    int pid = [p.profileId intValue];
    if (pid > maxId) maxId = pid;
  }
  NSString *newId = [NSString stringWithFormat:@"%d", maxId + 1];
  
  // 创建 Profile 元数据
  ECProfileInfo *newProfile = [[ECProfileInfo alloc] init];
  newProfile.profileId = newId;
  newProfile.name = name ?: [NSString stringWithFormat:@"账号 %@", newId];
  newProfile.createdDate = [NSDate date];
  
  // 保存到列表
  NSMutableArray *updated = [existing mutableCopy];
  [updated addObject:newProfile];
  [self saveProfilesList:updated];
  
  // 创建目录结构
  [self ensureProfileDirectoryStructure:newId];
  
  // 生成随机设备指纹
  [self generateRandomDeviceConfig:newId];
  
  ECPLog(@"✅ 创建 Profile: %@ (ID: %@)", newProfile.name, newId);
  return newId;
}

- (BOOL)deleteProfile:(NSString *)profileId {
  if ([profileId isEqualToString:@"0"]) {
    ECPLog(@"❌ 不允许删除默认 Profile");
    return NO;
  }
  if ([profileId isEqualToString:self.cachedActiveId]) {
    ECPLog(@"❌ 不允许删除当前激活的 Profile");
    return NO;
  }
  
  // 从列表中移除
  NSMutableArray<ECProfileInfo *> *profiles = [[self allProfiles] mutableCopy];
  NSInteger idx = NSNotFound;
  for (NSUInteger i = 0; i < profiles.count; i++) {
    if ([profiles[i].profileId isEqualToString:profileId]) {
      idx = i;
      break;
    }
  }
  if (idx != NSNotFound) {
    [profiles removeObjectAtIndex:idx];
    [self saveProfilesList:profiles];
  }
  
  // 删除目录
  NSString *profileDir = [NSString stringWithFormat:@"%@/%@%@",
      [self profilesBaseDirectory], kProfileDirPrefix, profileId];
  [[NSFileManager defaultManager] removeItemAtPath:profileDir error:nil];
  
  // 清理 Keychain
  [self cleanKeychainForProfile:profileId];
  
  ECPLog(@"🗑️ 已删除 Profile: %@", profileId);
  return YES;
}

- (BOOL)renameProfile:(NSString *)profileId toName:(NSString *)newName {
  NSMutableArray<ECProfileInfo *> *profiles = [[self allProfiles] mutableCopy];
  for (ECProfileInfo *p in profiles) {
    if ([p.profileId isEqualToString:profileId]) {
      p.name = newName;
      [self saveProfilesList:profiles];
      ECPLog(@"✏️ Profile %@ 已重命名为: %@", profileId, newName);
      return YES;
    }
  }
  return NO;
}

- (void)switchToProfile:(NSString *)profileId {
  NSString *activePath = [[self profilesBaseDirectory]
      stringByAppendingPathComponent:kActiveProfileFile];
  [profileId writeToFile:activePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
  ECPLog(@"🔄 已写入 active_profile: %@，等待重启生效", profileId);
}

- (void)touchActiveProfile {
  NSMutableArray<ECProfileInfo *> *profiles = [[self allProfiles] mutableCopy];
  for (ECProfileInfo *p in profiles) {
    if ([p.profileId isEqualToString:self.cachedActiveId]) {
      p.lastUsedDate = [NSDate date];
      [self saveProfilesList:profiles];
      break;
    }
  }
}

#pragma mark - 设备指纹

- (NSDictionary *)deviceConfigForProfile:(NSString *)profileId {
  NSString *configPath = [NSString stringWithFormat:@"%@/%@%@/%@",
      [self profilesBaseDirectory], kProfileDirPrefix, profileId, kDeviceConfigFile];
  NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath];
  return config ?: @{};
}

- (NSDictionary *)loadDeviceConfig:(NSString *)profileId {
  NSDictionary *config = [self deviceConfigForProfile:profileId];
  if (config.count == 0) {
    // 没有配置，生成默认
    [self generateRandomDeviceConfig:profileId];
    config = [self deviceConfigForProfile:profileId];
  }
  return config ?: @{};
}

- (nullable NSString *)spoofValueForKey:(NSString *)key {
  id value = self.cachedDeviceConfig[key];
  if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
    return value;
  }
  return nil;
}

- (BOOL)spoofBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue {
  id value = self.cachedDeviceConfig[key];
  if ([value respondsToSelector:@selector(boolValue)]) {
    return [value boolValue];
  }
  return defaultValue;
}

- (void)generateRandomDeviceConfig:(NSString *)profileId {
  // 随机生成设备指纹
  NSString *vendorId = [[NSUUID UUID] UUIDString];
  NSString *idfa = [[NSUUID UUID] UUIDString];
  NSString *openudid = [self generateRandomHex:40];
  
  // 随机选择一个设备型号
  NSArray *models = @[
    @"iPhone12,1", @"iPhone12,3", @"iPhone12,5",  // iPhone 11 系列
    @"iPhone13,1", @"iPhone13,2", @"iPhone13,3", @"iPhone13,4",  // iPhone 12 系列
    @"iPhone14,2", @"iPhone14,3", @"iPhone14,4", @"iPhone14,5",  // iPhone 13 系列
    @"iPhone14,7", @"iPhone14,8",  // iPhone 14 系列
    @"iPhone15,2", @"iPhone15,3",  // iPhone 14 Pro 系列
    @"iPhone15,4", @"iPhone15,5",  // iPhone 15 系列
    @"iPhone16,1", @"iPhone16,2",  // iPhone 15 Pro 系列
  ];
  NSString *model = models[arc4random_uniform((uint32_t)models.count)];
  
  // 随机选择系统版本
  NSArray *versions = @[@"16.5", @"16.6", @"16.7", @"17.0", @"17.1", @"17.2", @"17.3", @"17.4", @"17.5"];
  NSString *version = versions[arc4random_uniform((uint32_t)versions.count)];
  
  // 随机设备名
  NSArray *names = @[@"iPhone", @"My iPhone", @"Phone"];
  NSString *deviceName = names[arc4random_uniform((uint32_t)names.count)];
  
  NSDictionary *config = @{
    @"vendorId": vendorId,
    @"idfv": vendorId,
    @"idfa": idfa,
    @"tiktokIdfa": idfa,
    @"openudid": openudid,
    @"machineModel": model,
    @"systemVersion": version,
    @"deviceName": deviceName,
    @"preferredLanguage": @"en-US",
    @"localeIdentifier": @"en_US",
    @"languageCode": @"en",
    @"countryCode": @"US",
    // 网络设置
    @"disableQUIC": @YES,
    @"enableNetworkInterception": @NO,
  };
  
  NSString *configPath = [NSString stringWithFormat:@"%@/%@%@/%@",
      [self profilesBaseDirectory], kProfileDirPrefix, profileId, kDeviceConfigFile];
  
  // 确保父目录存在
  NSString *parentDir = [configPath stringByDeletingLastPathComponent];
  [[NSFileManager defaultManager] createDirectoryAtPath:parentDir
      withIntermediateDirectories:YES attributes:nil error:nil];
  
  [config writeToFile:configPath atomically:YES];
  ECPLog(@"🎲 已生成随机设备指纹 for Profile %@: model=%@, ver=%@", profileId, model, version);
}

- (NSString *)generateRandomHex:(NSUInteger)length {
  NSMutableString *hex = [NSMutableString stringWithCapacity:length];
  for (NSUInteger i = 0; i < length; i++) {
    [hex appendFormat:@"%x", arc4random_uniform(16)];
  }
  return hex;
}

#pragma mark - Keychain 隔离

- (void)cleanKeychainForProfile:(NSString *)profileId {
  // 删除该 Profile 前缀的所有 Keychain 条目
  NSString *prefix = [NSString stringWithFormat:@"profile_%@_", profileId];
  
  NSDictionary *query = @{
    (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
    (__bridge id)kSecReturnAttributes: @YES,
  };
  
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  
  if (status == errSecSuccess && result) {
    NSArray *items = (__bridge_transfer NSArray *)result;
    for (NSDictionary *item in items) {
      NSString *service = item[(__bridge id)kSecAttrService];
      NSString *account = item[(__bridge id)kSecAttrAccount];
      if ([service hasPrefix:prefix] || [account hasPrefix:prefix]) {
        NSDictionary *deleteQuery = @{
          (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
          (__bridge id)kSecAttrService: service ?: @"",
          (__bridge id)kSecAttrAccount: account ?: @"",
        };
        SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
      }
    }
    ECPLog(@"🔐 已清理 Profile %@ 的 Keychain 数据", profileId);
  }
}

@end
