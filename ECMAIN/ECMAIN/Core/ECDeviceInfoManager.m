//
//  ECDeviceInfoManager.m
//  ECMAIN
//
//  设备信息管理器实现 - 完整版
//

#import "ECDeviceInfoManager.h"
#import <AdSupport/ASIdentifierManager.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import "ECPersistentConfig.h"

@implementation ECDeviceInfoItem
@end

@interface ECDeviceInfoManager ()
@property(nonatomic, strong)
    NSMutableDictionary<NSString *, ECDeviceInfoItem *> *allItems;
@property(nonatomic, strong)
    NSDictionary<NSNumber *, NSArray<NSString *> *> *sectionKeys;

// Helper to generate a random MAC address
- (NSString *)generateRandomMACAddress;

@end

@implementation ECDeviceInfoManager

+ (instancetype)sharedManager {
  static ECDeviceInfoManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECDeviceInfoManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _allItems = [NSMutableDictionary dictionary];
    [self setupSectionKeys];
    [self refreshDeviceInfo];
    [self loadSavedConfig];
  }
  return self;
}

- (void)setupSectionKeys {
  _sectionKeys = @{
    // ★ 国家/地区快速选择 (选择后自动填充运营商、区域、语言)
    @(ECDeviceInfoSectionCountry) : @[ @"countryCode" ],

    // 1. iPhone 设备伪装 (UIDevice + sysctl + UIScreen)
    @(ECDeviceInfoSectionDevice) : @[
      @"machineModel", // sysctl hw.machine → iPhone14,2
      @"deviceModel",  // UIDevice.model → iPhone
      @"deviceName",   // UIDevice.name → iPhone 13 Pro
      @"productName",  // sysctl ProductName
      @"screenWidth",  // UIScreen.bounds.width
      @"screenHeight", // UIScreen.bounds.height
      @"screenScale",  // UIScreen.scale
      @"nativeBounds", // UIScreen.nativeBounds
      @"maxFPS"        // UIScreen.maximumFramesPerSecond
    ],

    // 2. iOS 版本伪装 (UIDevice + NSProcessInfo + sysctl)
    @(ECDeviceInfoSectionSystem) : @[
      @"systemVersion",      // UIDevice.systemVersion → 18.3.2
      @"systemBuildVersion", // sysctl kern.osversion → 22D82
      @"kernelVersion",      // sysctl kern.version
      @"systemName"          // UIDevice.systemName → iOS
    ],

    // 3. 运营商伪装 (CTCarrier swizzle)
    @(ECDeviceInfoSectionCarrier) : @[
      @"carrierName",       // CTCarrier.carrierName → NTT docomo
      @"mobileCountryCode", // CTCarrier.mobileCountryCode → 440
      @"mobileNetworkCode", // CTCarrier.mobileNetworkCode → 10
      @"carrierCountry"     // CTCarrier.isoCountryCode → JP
    ],

    // 4. 区域伪装 (NSLocale + CFLocale + NSTimeZone)
    @(ECDeviceInfoSectionRegion) : @[
      @"localeIdentifier", // NSLocale.localeIdentifier → ja_JP
      @"timezone",         // NSTimeZone.localTimeZone → Asia/Tokyo
      @"currencyCode",     // NSLocale.currencyCode → JPY
      @"storeRegion",      // TikTok App Store 区域
      @"priorityRegion"    // TikTok 优先区域
    ],

    // 5. 语言伪装 (NSLocale + CFLocale + __NSCFLocale)
    @(ECDeviceInfoSectionLanguage) : @[
      @"languageCode",      // NSLocale.languageCode → ja
      @"preferredLanguage", // NSLocale.preferredLanguages[0] → ja-JP
      @"systemLanguage",    // TikTok systemLanguage
      @"btdCurrentLanguage" // TikTok BTD 语言
    ],

    // 6. 网络拦截 (NSURLSession + TTNet + TTHttpTaskChromium + QUIC)
    @(ECDeviceInfoSectionNetwork) : @[
      @"enableNetworkInterception", // 总开关
      @"disableQUIC",               // 禁用 QUIC/UDP:443
      @"networkType"                // 网络类型 WiFi/5G
    ],
  };
}

#pragma mark - Country Presets

+ (NSDictionary<NSString *, NSDictionary *> *)countryPresets {
  static NSDictionary *presets = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    presets = @{
      @"BR" : @{
        @"language" : @"pt-BR",
        @"timezone" : @"America/Sao_Paulo",
        @"currency" : @"BRL",
        @"mcc" : @"724",
        @"mnc" : @"11",
        @"carrier" : @"Vivo",
        @"name" : @"巴西"
      },
      @"US" : @{
        @"language" : @"en-US",
        @"timezone" : @"America/New_York",
        @"currency" : @"USD",
        @"mcc" : @"310",
        @"mnc" : @"260",
        @"carrier" : @"T-Mobile",
        @"name" : @"美国"
      },
      @"CN" : @{
        @"language" : @"zh-Hans",
        @"timezone" : @"Asia/Shanghai",
        @"currency" : @"CNY",
        @"mcc" : @"460",
        @"mnc" : @"00",
        @"carrier" : @"中国移动",
        @"name" : @"中国"
      },
      @"JP" : @{
        @"language" : @"ja-JP",
        @"timezone" : @"Asia/Tokyo",
        @"currency" : @"JPY",
        @"mcc" : @"440",
        @"mnc" : @"10",
        @"carrier" : @"NTT DoCoMo",
        @"name" : @"日本"
      },
      @"KR" : @{
        @"language" : @"ko-KR",
        @"timezone" : @"Asia/Seoul",
        @"currency" : @"KRW",
        @"mcc" : @"450",
        @"mnc" : @"05",
        @"carrier" : @"SK Telecom",
        @"name" : @"韩国"
      },
      @"DE" : @{
        @"language" : @"de-DE",
        @"timezone" : @"Europe/Berlin",
        @"currency" : @"EUR",
        @"mcc" : @"262",
        @"mnc" : @"01",
        @"carrier" : @"Telekom",
        @"name" : @"德国"
      },
      @"FR" : @{
        @"language" : @"fr-FR",
        @"timezone" : @"Europe/Paris",
        @"currency" : @"EUR",
        @"mcc" : @"208",
        @"mnc" : @"01",
        @"carrier" : @"Orange",
        @"name" : @"法国"
      },
      @"GB" : @{
        @"language" : @"en-GB",
        @"timezone" : @"Europe/London",
        @"currency" : @"GBP",
        @"mcc" : @"234",
        @"mnc" : @"10",
        @"carrier" : @"O2",
        @"name" : @"英国"
      },
      @"RU" : @{
        @"language" : @"ru-RU",
        @"timezone" : @"Europe/Moscow",
        @"currency" : @"RUB",
        @"mcc" : @"250",
        @"mnc" : @"01",
        @"carrier" : @"MTS",
        @"name" : @"俄罗斯"
      },
      @"IN" : @{
        @"language" : @"hi-IN",
        @"timezone" : @"Asia/Kolkata",
        @"currency" : @"INR",
        @"mcc" : @"404",
        @"mnc" : @"10",
        @"carrier" : @"AirTel",
        @"name" : @"印度"
      },
      @"ID" : @{
        @"language" : @"id-ID",
        @"timezone" : @"Asia/Jakarta",
        @"currency" : @"IDR",
        @"mcc" : @"510",
        @"mnc" : @"10",
        @"carrier" : @"Telkomsel",
        @"name" : @"印度尼西亚"
      },
      @"TH" : @{
        @"language" : @"th-TH",
        @"timezone" : @"Asia/Bangkok",
        @"currency" : @"THB",
        @"mcc" : @"520",
        @"mnc" : @"01",
        @"carrier" : @"AIS",
        @"name" : @"泰国"
      },
      @"VN" : @{
        @"language" : @"vi-VN",
        @"timezone" : @"Asia/Ho_Chi_Minh",
        @"currency" : @"VND",
        @"mcc" : @"452",
        @"mnc" : @"01",
        @"carrier" : @"Mobifone",
        @"name" : @"越南"
      },
      @"PH" : @{
        @"language" : @"fil-PH",
        @"timezone" : @"Asia/Manila",
        @"currency" : @"PHP",
        @"mcc" : @"515",
        @"mnc" : @"02",
        @"carrier" : @"Globe",
        @"name" : @"菲律宾"
      },
      @"MY" : @{
        @"language" : @"ms-MY",
        @"timezone" : @"Asia/Kuala_Lumpur",
        @"currency" : @"MYR",
        @"mcc" : @"502",
        @"mnc" : @"12",
        @"carrier" : @"Maxis",
        @"name" : @"马来西亚"
      },
      @"SG" : @{
        @"language" : @"en-SG",
        @"timezone" : @"Asia/Singapore",
        @"currency" : @"SGD",
        @"mcc" : @"525",
        @"mnc" : @"01",
        @"carrier" : @"SingTel",
        @"name" : @"新加坡"
      },
      @"TW" : @{
        @"language" : @"zh-Hant",
        @"timezone" : @"Asia/Taipei",
        @"currency" : @"TWD",
        @"mcc" : @"466",
        @"mnc" : @"92",
        @"carrier" : @"Chunghwa Telecom",
        @"name" : @"台湾"
      },
      @"HK" : @{
        @"language" : @"zh-Hant-HK",
        @"timezone" : @"Asia/Hong_Kong",
        @"currency" : @"HKD",
        @"mcc" : @"454",
        @"mnc" : @"00",
        @"carrier" : @"CSL",
        @"name" : @"香港"
      },
      @"AU" : @{
        @"language" : @"en-AU",
        @"timezone" : @"Australia/Sydney",
        @"currency" : @"AUD",
        @"mcc" : @"505",
        @"mnc" : @"01",
        @"carrier" : @"Telstra",
        @"name" : @"澳大利亚"
      },
      @"MX" : @{
        @"language" : @"es-MX",
        @"timezone" : @"America/Mexico_City",
        @"currency" : @"MXN",
        @"mcc" : @"334",
        @"mnc" : @"020",
        @"carrier" : @"Telcel",
        @"name" : @"墨西哥"
      },
      @"AR" : @{
        @"language" : @"es-AR",
        @"timezone" : @"America/Buenos_Aires",
        @"currency" : @"ARS",
        @"mcc" : @"722",
        @"mnc" : @"310",
        @"carrier" : @"Claro",
        @"name" : @"阿根廷"
      },
    };
  });
  return presets;
}

+ (NSArray<NSString *> *)supportedCountryCodes {
  return [[self countryPresets] allKeys];
}

- (void)applyCountryPreset:(NSString *)countryCode {
  if (!countryCode || countryCode.length == 0) {
    return;
  }

  NSDictionary *preset = [ECDeviceInfoManager countryPresets][countryCode];
  if (!preset) {
    NSLog(@"[ECDeviceInfoManager] 未找到国家预设: %@", countryCode);
    return;
  }

  NSString *fullLanguage = preset[@"language"]; // 例如 "pt-BR" 或 "zh-Hans"
  NSString *timezone = preset[@"timezone"];
  NSString *currency = preset[@"currency"];

  // 提取纯语言代码 (iOS 的 languageCode API 行为)
  // pt-BR -> pt, zh-Hans -> zh-Hans (脚本后缀保留), en-US -> en
  NSString *pureLanguageCode;
  NSArray *langComponents = [fullLanguage componentsSeparatedByString:@"-"];
  if (langComponents.count >= 2) {
    NSString *firstPart = langComponents[0];
    NSString *secondPart = langComponents[1];
    // 检查第二部分是否是脚本后缀 (Hans, Hant 等，首字母大写+3个小写)
    BOOL isScript = (secondPart.length == 4 &&
                     [[NSCharacterSet uppercaseLetterCharacterSet]
                         characterIsMember:[secondPart characterAtIndex:0]]);
    if (isScript) {
      // zh-Hans, zh-Hant 等：保留脚本后缀作为 languageCode
      pureLanguageCode =
          [NSString stringWithFormat:@"%@-%@", firstPart, secondPart];
    } else {
      // pt-BR, en-US 等：只取语言部分
      pureLanguageCode = firstPart;
    }
  } else {
    pureLanguageCode = fullLanguage;
  }

  // 构建 localeIdentifier (例如 pt_BR, zh_Hans_CN)
  // 使用纯语言代码 + 国家代码
  NSString *localeId;
  if ([pureLanguageCode containsString:@"-"]) {
    // zh-Hans + CN -> zh_Hans_CN
    NSString *langPart =
        [pureLanguageCode stringByReplacingOccurrencesOfString:@"-"
                                                    withString:@"_"];
    localeId = [NSString stringWithFormat:@"%@_%@", langPart, countryCode];
  } else {
    // pt + BR -> pt_BR
    localeId =
        [NSString stringWithFormat:@"%@_%@", pureLanguageCode, countryCode];
  }

  // 更新所有相关参数
  NSDictionary *updates = @{
    @"countryCode" : countryCode,
    @"languageCode" : pureLanguageCode, // 纯语言代码 (pt, en, zh-Hans)
    @"localeIdentifier" : localeId,     // 区域标识符 (pt_BR, en_US, zh_Hans_CN)
    @"timezone" : timezone,
    @"currencyCode" : currency,
    @"preferredLanguage" : fullLanguage,  // 完整格式 (pt-BR, en-US, zh-Hans)
    @"systemLanguage" : pureLanguageCode, // TikTok 系统语言
    @"btdCurrentLanguage" : fullLanguage, // BTD 当前语言
    @"storeRegion" : countryCode,
    @"priorityRegion" : countryCode,
    @"carrierCountry" : countryCode, // 运营商国家也同步更新
  };

  // 同步更新运营商信息 (MCC/MNC/carrierName)
  NSMutableDictionary *mutableUpdates = [updates mutableCopy];
  if (preset[@"mcc"]) {
    mutableUpdates[@"mobileCountryCode"] = preset[@"mcc"];
  }
  if (preset[@"mnc"]) {
    mutableUpdates[@"mobileNetworkCode"] = preset[@"mnc"];
  }
  if (preset[@"carrier"]) {
    mutableUpdates[@"carrierName"] = preset[@"carrier"];
  }
  updates = mutableUpdates;

  for (NSString *key in updates) {
    ECDeviceInfoItem *item = self.allItems[key];
    if (item) {
      item.currentValue = updates[key];
      item.isModified = ![item.currentValue isEqualToString:item.originalValue];
    }
  }

  NSLog(@"[ECDeviceInfoManager] 已应用国家预设: %@ (%@)", countryCode,
        preset[@"name"]);
}

#pragma mark - Public Methods

- (NSArray<ECDeviceInfoItem *> *)itemsForSection:(ECDeviceInfoSection)section {
  NSArray *keys = self.sectionKeys[@(section)];
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *key in keys) {
    ECDeviceInfoItem *item = self.allItems[key];
    if (item) {
      [items addObject:item];
    }
  }
  return items;
}

- (NSString *)titleForSection:(ECDeviceInfoSection)section {
  switch (section) {
  case ECDeviceInfoSectionCountry:
    return @"★ 选择目标国家/地区";
  case ECDeviceInfoSectionDevice:
    return @"1. iPhone 设备伪装";
  case ECDeviceInfoSectionSystem:
    return @"2. iOS 版本伪装";
  case ECDeviceInfoSectionCarrier:
    return @"3. 运营商伪装";
  case ECDeviceInfoSectionRegion:
    return @"4. 区域伪装";
  case ECDeviceInfoSectionLanguage:
    return @"5. 语言伪装";
  case ECDeviceInfoSectionNetwork:
    return @"6. 网络拦截";
  default:
    return @"";
  }
}

- (void)refreshDeviceInfo {
  [self.allItems removeAllObjects];

  // ========== 一、系统版本信息 ==========
  [self addItemWithKey:@"systemVersion"
                  name:@"iOS 版本号"
                 value:[UIDevice currentDevice].systemVersion];

  [self addItemWithKey:@"systemBuildVersion"
                  name:@"系统构建版本"
                 value:[self sysctlStringForName:@"kern.osversion"]];

  [self addItemWithKey:@"kernelVersion"
                  name:@"内核版本"
                 value:[self sysctlStringForName:@"kern.version"]];

  [self addItemWithKey:@"systemName"
                  name:@"系统名称"
                 value:[UIDevice currentDevice].systemName];

  // ========== 二、设备型号信息 ==========
  [self addItemWithKey:@"machineModel"
                  name:@"设备型号标识"
                 value:[self getMachineModel]];

  [self addItemWithKey:@"deviceModel"
                  name:@"设备类型名称 (如iPhone)"
                 value:[UIDevice currentDevice].model];

  [self addItemWithKey:@"deviceName"
                  name:@"用户设置的设备名"
                 value:[UIDevice currentDevice].name];

  NSString *machineModel = [self getMachineModel];

  [self addItemWithKey:@"productName"
                  name:@"产品名称"
                 value:[self getProductNameForModel:machineModel]];

  // ========== 三、屏幕/分辨率信息 ==========
  CGRect bounds = [UIScreen mainScreen].bounds;
  CGFloat scale = [UIScreen mainScreen].scale;
  CGRect nativeBounds = [UIScreen mainScreen].nativeBounds;

  [self addItemWithKey:@"screenWidth"
                  name:@"屏幕宽度"
                 value:[NSString stringWithFormat:@"%.0f", bounds.size.width]];

  [self addItemWithKey:@"screenHeight"
                  name:@"屏幕高度"
                 value:[NSString stringWithFormat:@"%.0f", bounds.size.height]];

  [self addItemWithKey:@"screenScale"
                  name:@"屏幕缩放比例"
                 value:[NSString stringWithFormat:@"%.1f", scale]];

  [self addItemWithKey:@"nativeBounds"
                  name:@"原生分辨率"
                 value:[NSString stringWithFormat:@"%.0fx%.0f",
                                                  nativeBounds.size.width,
                                                  nativeBounds.size.height]];

  NSInteger fps = [UIScreen mainScreen].maximumFramesPerSecond;
  NSString *fpsStr = [NSString stringWithFormat:@"%ld", (long)fps];
  [self addItemWithKey:@"maxFPS" name:@"刷新率" value:fpsStr];

  // ========== ★ 国家/地区选择 ==========
  NSLocale *locale = [NSLocale currentLocale];

  // ★ 所有值都直接使用系统 API 返回值，不做任何组合或转换！

  // 国家/地区代码：[locale objectForKey:NSLocaleCountryCode]
  NSString *countryCode = [locale objectForKey:NSLocaleCountryCode] ?: @"US";
  [self addItemWithKey:@"countryCode" name:@"国家/地区代码" value:countryCode];

  // ========== 四、区域/语言设置 (纯系统 API 原始值) ==========

  // ★ 语言代码：直接从 locale API 获取 (不从 preferredLanguages 提取！)
  NSString *languageCode = [locale objectForKey:NSLocaleLanguageCode] ?: @"en";

  // ★ 区域标识符：直接从 locale API 获取 (不手动拼接！)
  NSString *localeIdentifier = [locale localeIdentifier] ?: @"en_US";

  // ★ 首选语言：直接从系统 API 获取完整值
  NSArray *preferredLangs = [NSLocale preferredLanguages];
  NSString *fullPreferredLanguage = preferredLangs.firstObject ?: @"en";

  // 时区：系统 API 原始值
  NSString *timezoneName = [NSTimeZone localTimeZone].name;

  // 货币代码：系统 API 原始值
  NSString *currencyCode = [locale objectForKey:NSLocaleCurrencyCode] ?: @"USD";

  // === 4. 区域伪装 ===
  [self addItemWithKey:@"localeIdentifier"
                  name:@"区域标识符"
                 value:localeIdentifier];
  [self addItemWithKey:@"timezone" name:@"时区" value:timezoneName];
  [self addItemWithKey:@"currencyCode" name:@"货币代码" value:currencyCode];
  [self addItemWithKey:@"storeRegion" name:@"商店区域" value:countryCode];
  [self addItemWithKey:@"priorityRegion" name:@"优先区域" value:countryCode];

  // === 5. 语言伪装 ===
  [self addItemWithKey:@"languageCode" name:@"语言代码" value:languageCode];
  [self addItemWithKey:@"preferredLanguage"
                  name:@"首选语言"
                 value:fullPreferredLanguage];
  [self addItemWithKey:@"systemLanguage"
                  name:@"系统语言 (TikTok)"
                 value:languageCode];
  [self addItemWithKey:@"btdCurrentLanguage"
                  name:@"BTD 当前语言"
                 value:fullPreferredLanguage];

  // === 3. 运营商伪装 ===
  CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
  CTCarrier *carrier = networkInfo.subscriberCellularProvider;
  NSString *carrierCountry = carrier.isoCountryCode ?: countryCode;
  [self addItemWithKey:@"carrierName" name:@"运营商名称" value:@""];
  [self addItemWithKey:@"mobileCountryCode" name:@"移动国家代码 MCC" value:@""];
  [self addItemWithKey:@"mobileNetworkCode" name:@"移动网络代码 MNC" value:@""];
  [self addItemWithKey:@"carrierCountry"
                  name:@"运营商国家"
                 value:carrierCountry];

  // === 6. 网络拦截 ===
  [self addItemWithKey:@"enableNetworkInterception"
                  name:@"网络拦截总开关"
                 value:@"YES"];
  [self addItemWithKey:@"disableQUIC" name:@"禁用 QUIC/UDP" value:@"YES"];
  NSString *radioType = networkInfo.currentRadioAccessTechnology ?: @"N/A";
  NSString *networkTypeStr = [self getNetworkTypeString:radioType];
  [self addItemWithKey:@"networkType" name:@"网络类型" value:networkTypeStr];
}

- (BOOL)saveChanges {
  return [self saveConfigToPath:[self configFilePath]];
}

- (BOOL)saveConfigToPath:(NSString *)path {
  NSMutableDictionary *config = [NSMutableDictionary dictionary];

  // 定义无需保存的黑名单 (废弃标识符 + 已从 UI 移除的废弃参数)
  NSSet *blacklistKeys = [NSSet setWithArray:@[
    // 废弃标识符
    @"deviceId", @"installId", @"openudid", @"idfv", @"idfa", @"udid",
    @"serialNumber", @"imei",
    // 废弃硬件/系统参数 (无 Hook)
    @"cpuCores", @"physicalMemory", @"batteryCapacity", @"storageCapacity",
    @"cpuType", @"isJailbroken", @"isSimulator", @"bootTime", @"diskFreeSpace",
    @"wifiSSID", @"wifiBSSID",
    // 废弃 TikTok 专用 (已合并到其他 section)
    @"fakedBundleId", @"btdBundleId"
  ]];

  // Hook 开关 key 集合（保存为 BOOL 值）
  // 注意：大多数 Hook 开关已由"全链路联动"自动管理，不再暴露给用户
  // 仅保留用户可控的网络拦截开关
  NSSet *hookSwitchKeys =
      [NSSet setWithArray:@[ @"enableNetworkInterception", @"disableQUIC" ]];

  // 遍历所有项目
  for (ECDeviceInfoItem *item in self.allItems.allValues) {
    // 1. 黑名单中的 key 直接跳过
    if ([blacklistKeys containsObject:item.key]) {
      continue;
    }

    // 2. Hook 开关项：直接保存为 BOOL 值（不受 isModified 限制）
    if ([hookSwitchKeys containsObject:item.key]) {
      BOOL val = [item.currentValue isEqualToString:@"YES"];
      config[item.key] = @(val);
      continue;
    }

    BOOL shouldSave = YES; // 强制保存所有展示的项目（包含未修改的灰色原机值）

    if (shouldSave) {
      // 3. 过滤无效值: 如果值包含 "未授权"、"N/A" 或为空，则不保存
      // (避免写入垃圾数据)
      NSString *val = item.currentValue;
      if (!val || val.length == 0 || [val containsString:@"未授权"] ||
          [val isEqualToString:@"N/A"] ||
          [val isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        continue;
      }

      config[item.key] = val;
    }
  }

  // 确保网络拦截开关有默认值
  if (config[@"enableNetworkInterception"] == nil)
    config[@"enableNetworkInterception"] = @YES;
  if (config[@"disableQUIC"] == nil)
    config[@"disableQUIC"] = @YES;

  // 保存"仅伪装克隆"模式标志
  config[@"cloneOnlyMode"] = @(self.cloneOnlyMode);

  // 先保存到临时位置
  NSString *tempPath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:@"device_spoof_config_temp.plist"];
  BOOL tempSuccess = [config writeToFile:tempPath atomically:YES];

  if (!tempSuccess) {
    NSLog(@"[ECDeviceInfoManager] 保存临时配置失败");
    return NO;
  }

  // 使用 root helper 复制到目标位置
  extern NSString *rootHelperPath(void);
  extern int spawnRoot(NSString * path, NSArray * args, NSString * *stdOut,
                       NSString * *stdErr);

  // 确保目标目录存在
  NSString *dir = [path stringByDeletingLastPathComponent];
  spawnRoot(rootHelperPath(), @[ @"mkdir", @"-p", dir ], nil, nil);

  // 复制文件
  int ret =
      spawnRoot(rootHelperPath(), @[ @"copy-file", tempPath, path ], nil, nil);

  // 清理临时文件
  [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

  if (ret == 0) {
    NSLog(@"[ECDeviceInfoManager] 配置已保存到: %@", path);
    // [New] 同步配置到目标 App (TikTok) 沙盒，解决读取权限问题
    [self syncConfigToTargetApp:path];
    return YES;
  } else {
    NSLog(@"[ECDeviceInfoManager] 保存配置失败 (ret=%d): %@", ret, path);
    return NO;
  }
}

- (void)resetToDefaults {
  for (ECDeviceInfoItem *item in self.allItems.allValues) {
    item.currentValue = item.originalValue;
    item.isModified = NO;
  }

  // 删除配置文件
  NSString *path = [self configFilePath];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  NSLog(@"[ECDeviceInfoManager] 已还原默认值");
}

- (NSString *)configFilePath {
  // 统一使用 /var/mobile/Documents/ECSpoof/device.plist
  NSString *globalPath = @"/var/mobile/Documents/.com.apple.UIKit.pboard/"
                         @"com.apple.preferences.display.plist";

  // 确保目录存在
  NSString *dir = [globalPath stringByDeletingLastPathComponent];
  if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  return globalPath;
}

- (BOOL)hasModifications {
  for (ECDeviceInfoItem *item in self.allItems.allValues) {
    if (item.isModified) {
      return YES;
    }
  }
  return NO;
}

- (void)syncConfigToTargetApp:(NSString *)sourcePath {
  // 获取所有已安装的 TikTok 变体 (从配置中下发读取)
  NSString *targetAppsStr = [ECPersistentConfig stringForKey:@"EC_TARGET_APPS"];
  if (!targetAppsStr || targetAppsStr.length == 0) {
    targetAppsStr = @"com.zhiliaoapp.musically,com.ss.iphone.ugc.Ame,com.ss.iphone.ugc.Aweme";
  }
  NSString *cleanedStr = [targetAppsStr stringByReplacingOccurrencesOfString:@" " withString:@""];
  NSArray *targetPkgs = [cleanedStr componentsSeparatedByString:@","];

  extern NSString *rootHelperPath(void);
  extern int spawnRoot(NSString * path, NSArray * args, NSString * *stdOut,
                       NSString * *stdErr);

  Class proxyClass = NSClassFromString(@"LSApplicationProxy");
  if (!proxyClass)
    return;

  for (NSString *targetPkg in targetPkgs) {
    id proxy = [proxyClass
        performSelector:NSSelectorFromString(@"applicationProxyForIdentifier:")
             withObject:targetPkg];
    if (!proxy)
      continue;

    NSURL *dataURL =
        [proxy performSelector:NSSelectorFromString(@"dataContainerURL")];
    if (!dataURL)
      continue;

    NSString *docDir =
        [[dataURL path] stringByAppendingPathComponent:@"Documents"];

    // 统一路径: ~/Documents/ECSpoof/device.plist
    NSString *ecSpoofDir =
        [docDir stringByAppendingPathComponent:@".com.apple.UIKit.pboard"];
    spawnRoot(rootHelperPath(), @[ @"mkdir", @"-p", ecSpoofDir ], nil, nil);
    NSString *destStd = [ecSpoofDir
        stringByAppendingPathComponent:@"com.apple.preferences.display.plist"];
    spawnRoot(rootHelperPath(), @[ @"copy-file", sourcePath, destStd ], nil,
              nil);
    NSLog(@"[ECDeviceInfoManager] 🔄 同步配置到: %@", destStd);

    // 路径 3: 所有已知 Clone 的分身配置目录
    // 扫描 ecSpoofDir 下的 clone_* 目录
    NSArray *items =
        [[NSFileManager defaultManager] contentsOfDirectoryAtPath:ecSpoofDir
                                                            error:nil];
    for (NSString *item in items) {
      if ([item hasPrefix:@"session_"]) {
        NSString *cloneDest = [[ecSpoofDir stringByAppendingPathComponent:item]
            stringByAppendingPathComponent:
                @"com.apple.preferences.display.plist"];
        spawnRoot(rootHelperPath(), @[ @"copy-file", sourcePath, cloneDest ],
                  nil, nil);
        NSLog(@"[ECDeviceInfoManager] 🔄 同步配置到分身: %@", cloneDest);
      }
    }

    NSLog(@"[ECDeviceInfoManager] ✅ 已同步配置到 %@", targetPkg);
  }
}

#pragma mark - Private Methods

- (void)addItemWithKey:(NSString *)key
                  name:(NSString *)name
                 value:(NSString *)value {
  ECDeviceInfoItem *item = [[ECDeviceInfoItem alloc] init];
  item.key = key;
  item.displayName = name;
  item.originalValue = value ?: @"N/A";
  item.currentValue = item.originalValue;
  item.isModified = NO;
  self.allItems[key] = item;
}

- (void)loadSavedConfig {
  [self loadConfigFromPath:[self configFilePath]];
}

- (void)loadConfigFromPath:(NSString *)path {
  // 先重置为初始值（真实值）
  for (ECDeviceInfoItem *item in self.allItems.allValues) {
    item.currentValue = item.originalValue;
    item.isModified = NO;
  }

  NSLog(@"[ECDeviceInfoManager] 尝试加载配置: %@", path);
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
    NSLog(@"[ECDeviceInfoManager] ⚠️ 文件不存在: %@", path);
    return;
  }

  NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:path];

  if (config) {
    NSLog(@"[ECDeviceInfoManager] ✅ 加载配置成功, 条目数: %lu",
          (unsigned long)config.count);

    // Legacy key 映射表（旧 key → 新 key）
    NSDictionary *keyMigration = @{
      @"vendorId" : @"idfv",
    };

    for (NSString *key in config) {
      // 先尝试直接匹配
      ECDeviceInfoItem *item = self.allItems[key];
      if (!item) {
        // 尝试 legacy key 迁移
        NSString *newKey = keyMigration[key];
        if (newKey) {
          item = self.allItems[newKey];
          if (item) {
            NSLog(@"[ECDeviceInfoManager] 🔄 Key 迁移: %@ → %@", key, newKey);
          }
        }
      }
      if (item) {
        id value = config[key];
        // Hook 开关保存为 @YES/@NO (NSNumber BOOL)，需转为字符串
        if ([value isKindOfClass:[NSNumber class]]) {
          item.currentValue = [value boolValue] ? @"YES" : @"NO";
        } else if ([value isKindOfClass:[NSString class]]) {
          item.currentValue = value;
        } else {
          item.currentValue = [value description] ?: @"";
        }
        // 安全比较 (两者都是 NSString)
        item.isModified =
            ![item.currentValue isEqualToString:item.originalValue ?: @""];
      }
    }
    NSLog(@"[ECDeviceInfoManager] 已从 %@ 加载配置", path);

    // 读取"仅伪装克隆"模式
    id cloneOnlyVal = config[@"cloneOnlyMode"];
    self.cloneOnlyMode = [cloneOnlyVal respondsToSelector:@selector(boolValue)]
                             ? [cloneOnlyVal boolValue]
                             : NO;
  } else {
    NSLog(@"[ECDeviceInfoManager] 路径无配置或加载失败: %@", path);
  }
}

- (NSString *)sysctlStringForName:(NSString *)name {
  size_t size;
  sysctlbyname(name.UTF8String, NULL, &size, NULL, 0);

  if (size == 0)
    return @"N/A";

  char *value = malloc(size);
  sysctlbyname(name.UTF8String, value, &size, NULL, 0);
  NSString *result = [NSString stringWithUTF8String:value];
  free(value);

  return result ?: @"N/A";
}

- (NSString *)getMachineModel {
  struct utsname systemInfo;
  uname(&systemInfo);
  return [NSString stringWithCString:systemInfo.machine
                            encoding:NSUTF8StringEncoding];
}

- (NSString *)getProductNameForModel:(NSString *)model {
  // 常见机型映射
  NSDictionary *models = @{
    @"iPhone14,2" : @"iPhone 13 Pro",
    @"iPhone14,3" : @"iPhone 13 Pro Max",
    @"iPhone14,4" : @"iPhone 13 mini",
    @"iPhone14,5" : @"iPhone 13",
    @"iPhone15,2" : @"iPhone 14 Pro",
    @"iPhone15,3" : @"iPhone 14 Pro Max",
    @"iPhone15,4" : @"iPhone 15",
    @"iPhone15,5" : @"iPhone 15 Plus",
    @"iPhone16,1" : @"iPhone 15 Pro",
    @"iPhone16,2" : @"iPhone 15 Pro Max",
    @"iPhone17,1" : @"iPhone 16 Pro",
    @"iPhone17,2" : @"iPhone 16 Pro Max",
    @"iPhone17,3" : @"iPhone 16",
    @"iPhone17,4" : @"iPhone 16 Plus",
  };
  return models[model] ?: model;
}

- (int)getCPUCores {
  int cores;
  size_t size = sizeof(cores);
  sysctlbyname("hw.ncpu", &cores, &size, NULL, 0);
  return cores;
}

- (NSString *)getPhysicalMemoryString {
  uint64_t memsize;
  size_t size = sizeof(memsize);
  sysctlbyname("hw.memsize", &memsize, &size, NULL, 0);

  double gb = (double)memsize / (1024.0 * 1024.0 * 1024.0);
  return [NSString stringWithFormat:@"%.0fGB", gb];
}

- (NSString *)getCPUType {
  struct utsname systemInfo;
  uname(&systemInfo);

  NSString *machine = [NSString stringWithCString:systemInfo.machine
                                         encoding:NSUTF8StringEncoding];

  // A12+ 芯片使用 arm64e
  if ([machine hasPrefix:@"iPhone11"] || [machine hasPrefix:@"iPhone12"] ||
      [machine hasPrefix:@"iPhone13"] || [machine hasPrefix:@"iPhone14"] ||
      [machine hasPrefix:@"iPhone15"] || [machine hasPrefix:@"iPhone16"] ||
      [machine hasPrefix:@"iPhone17"] || [machine hasPrefix:@"iPad8"] ||
      [machine hasPrefix:@"iPad11"] || [machine hasPrefix:@"iPad13"] ||
      [machine hasPrefix:@"iPad14"]) {
    return @"arm64e";
  }

  return @"arm64";
}

- (NSString *)getStorageCapacity {
  NSError *error = nil;
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfFileSystemForPath:NSHomeDirectory()
                              error:&error];
  if (error)
    return @"N/A";

  unsigned long long totalSize =
      [attrs[NSFileSystemSize] unsignedLongLongValue];
  double gb = (double)totalSize / (1024.0 * 1024.0 * 1024.0);

  // 四舍五入到常见容量
  if (gb < 48)
    return @"32GB";
  if (gb < 96)
    return @"64GB";
  if (gb < 192)
    return @"128GB";
  if (gb < 384)
    return @"256GB";
  if (gb < 768)
    return @"512GB";
  return @"1TB";
}

- (NSString *)getDiskFreeSpace {
  NSError *error = nil;
  NSDictionary *attrs = [[NSFileManager defaultManager]
      attributesOfFileSystemForPath:NSHomeDirectory()
                              error:&error];
  if (error)
    return @"N/A";

  unsigned long long freeSize =
      [attrs[NSFileSystemFreeSize] unsignedLongLongValue];
  double gb = (double)freeSize / (1024.0 * 1024.0 * 1024.0);
  return [NSString stringWithFormat:@"%.1fGB", gb];
}

- (BOOL)checkJailbreak {
  // 简单的越狱检测
  NSArray *jailbreakPaths = @[
    @"/Applications/Cydia.app",
    @"/Library/MobileSubstrate/MobileSubstrate.dylib", @"/bin/bash",
    @"/usr/sbin/sshd", @"/etc/apt", @"/private/var/lib/apt/", @"/var/jb"
  ];

  for (NSString *path in jailbreakPaths) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return YES;
    }
  }
  return NO;
}

- (NSString *)getBootTimeString {
  struct timeval boottime;
  size_t size = sizeof(boottime);
  sysctlbyname("kern.boottime", &boottime, &size, NULL, 0);

  NSDate *bootDate = [NSDate dateWithTimeIntervalSince1970:boottime.tv_sec];
  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
  formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
  return [formatter stringFromDate:bootDate];
}

- (NSString *)getNetworkTypeString:(NSString *)radioType {
  if ([radioType containsString:@"NR"])
    return @"5G";
  if ([radioType containsString:@"LTE"])
    return @"LTE";
  if ([radioType containsString:@"WCDMA"])
    return @"3G";
  if ([radioType containsString:@"CDMA"])
    return @"CDMA";
  if ([radioType containsString:@"GPRS"])
    return @"2G";
  if ([radioType containsString:@"Edge"])
    return @"Edge";
  return radioType;
}

- (NSDictionary<NSString *, ECDeviceInfoItem *> *)getAllItems {
  return [self.allItems copy];
}

- (NSDictionary<NSString *, id> *)dictionaryRepresentation {
  NSMutableDictionary *dict = [NSMutableDictionary dictionary];
  for (NSString *key in self.allItems) {
    ECDeviceInfoItem *item = self.allItems[key];
    // 优先使用修改后的值 (currentValue)，如果没有则使用原始值 (originalValue)
    if (item.currentValue) {
      dict[key] = item.currentValue;
    } else if (item.originalValue) {
      dict[key] = item.originalValue;
    }
  }
  return [dict copy];
}

- (NSString *)generateRandomMACAddress {
  NSMutableString *macAddress = [NSMutableString string];
  for (NSInteger i = 0; i < 6; i++) {
    int byte = arc4random_uniform(256);
    // 第一个字节: 确保是单播 (unicast) 且本地管理 (locally administered) ?
    // Bit 0 (Unicast/Multicast): Unicast (0) -> Avoid multicast (1)
    // Bit 1 (Universal/Local): Local (1) -> Use local (1)
    // (byte & 0xFC) | 0x02; ensures x2, x6, xA, xE in the last nibble of the
    // first byte
    if (i == 0) {
      byte = (byte & 0xFC) | 0x02;
    }
    [macAddress appendFormat:@"%02X%@", byte, (i < 5 ? @":" : @"")];
  }
  return macAddress;
}

@end
