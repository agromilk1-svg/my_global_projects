//
//  ECDeviceDatabase.m
//  ECMAIN
//
//  Device Model, iOS Version, and Carrier Database Implementation
//  Updated 2026-02-04 with verified real-world data
//

#import "ECDeviceDatabase.h"

@implementation ECDeviceModel
@end

@implementation ECSystemVersion
@end

@implementation ECCarrierInfo
@end

@implementation ECDeviceDatabase {
  NSArray<ECDeviceModel *> *_models;
  NSDictionary<NSString *, NSArray<ECSystemVersion *> *> *_versionMap;
  NSArray<ECCarrierInfo *> *_carriers;
}

+ (instancetype)shared {
  static ECDeviceDatabase *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECDeviceDatabase alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    [self loadModels];
    [self loadVersions];
    [self loadCarriers];
  }
  return self;
}

#pragma mark - Data Loading

- (void)loadModels {
  NSMutableArray *list = [NSMutableArray array];

// Updated helper macro with Hardware Specs
#define ADD_MODEL(name, machine, w, h, scale, nativeW, nativeH, fps, cores,    \
                  ram, storage, arch)                                          \
  {                                                                            \
    ECDeviceModel *m = [[ECDeviceModel alloc] init];                           \
    m.displayName = name;                                                      \
    m.machineId = machine;                                                     \
    m.marketingName = name;                                                    \
    m.screenWidth = w;                                                         \
    m.screenHeight = h;                                                        \
    m.screenScale = scale;                                                     \
    m.nativeWidth = nativeW;                                                   \
    m.nativeHeight = nativeH;                                                  \
    m.maxFPS = fps;                                                            \
    m.isOLED = (scale == 3.0);                                                 \
    m.cpuCount = cores;                                                        \
    m.ramSize = ram;                                                           \
    m.storageSize = storage;                                                   \
    m.cpuArchitecture = arch;                                                  \
    [list addObject:m];                                                        \
  }

  // ========== iPhone 17 Series (Anticipated - 2025) ==========
  // A19 Pro (6 cores), 12GB RAM
  ADD_MODEL(@"iPhone 17 Pro Max", @"iPhone18,2", 440, 956, 3.0, 1320, 2868, 120,
            6, 12, 256, @"arm64e");
  ADD_MODEL(@"iPhone 17 Pro", @"iPhone18,1", 402, 874, 3.0, 1206, 2622, 120, 6,
            12, 256, @"arm64e");
  // A19 (6 cores), 8GB RAM
  ADD_MODEL(@"iPhone 17 Plus", @"iPhone18,4", 430, 932, 3.0, 1290, 2796, 60, 6,
            8, 128, @"arm64e");
  ADD_MODEL(@"iPhone 17", @"iPhone18,3", 393, 852, 3.0, 1179, 2556, 60, 6, 8,
            128, @"arm64e");

  // ========== iPhone 16 Series (2024) ==========
  // A18 Pro (6 cores), 8GB RAM
  ADD_MODEL(@"iPhone 16 Pro Max", @"iPhone17,2", 440, 956, 3.0, 1320, 2868, 120,
            6, 8, 256, @"arm64e");
  ADD_MODEL(@"iPhone 16 Pro", @"iPhone17,1", 402, 874, 3.0, 1206, 2622, 120, 6,
            8, 128, @"arm64e");
  // A18 (6 cores), 8GB RAM
  ADD_MODEL(@"iPhone 16 Plus", @"iPhone17,4", 430, 932, 3.0, 1290, 2796, 60, 6,
            8, 128, @"arm64e");
  ADD_MODEL(@"iPhone 16", @"iPhone17,3", 393, 852, 3.0, 1179, 2556, 60, 6, 8,
            128, @"arm64e");
  ADD_MODEL(@"iPhone 16e", @"iPhone17,5", 390, 844, 3.0, 1170, 2532, 60, 6, 8,
            128, @"arm64e");

  // ========== iPhone 15 Series (2023) ==========
  // A17 Pro (6 cores), 8GB RAM
  ADD_MODEL(@"iPhone 15 Pro Max", @"iPhone16,2", 430, 932, 3.0, 1290, 2796, 120,
            6, 8, 256, @"arm64e");
  ADD_MODEL(@"iPhone 15 Pro", @"iPhone16,1", 393, 852, 3.0, 1179, 2556, 120, 6,
            8, 128, @"arm64e");
  // A16 (6 cores), 6GB RAM
  ADD_MODEL(@"iPhone 15 Plus", @"iPhone15,5", 430, 932, 3.0, 1290, 2796, 60, 6,
            6, 128, @"arm64e");
  ADD_MODEL(@"iPhone 15", @"iPhone15,4", 393, 852, 3.0, 1179, 2556, 60, 6, 6,
            128, @"arm64e");

  // ========== iPhone 14 Series (2022) ==========
  // A16 (6 cores), 6GB RAM
  ADD_MODEL(@"iPhone 14 Pro Max", @"iPhone15,3", 430, 932, 3.0, 1290, 2796, 120,
            6, 6, 128, @"arm64e");
  ADD_MODEL(@"iPhone 14 Pro", @"iPhone15,2", 393, 852, 3.0, 1179, 2556, 120, 6,
            6, 128, @"arm64e");
  // A15 (6 cores), 6GB RAM
  ADD_MODEL(@"iPhone 14 Plus", @"iPhone14,8", 428, 926, 3.0, 1284, 2778, 60, 6,
            6, 128, @"arm64e");
  ADD_MODEL(@"iPhone 14", @"iPhone14,7", 390, 844, 3.0, 1170, 2532, 60, 6, 6,
            128, @"arm64e");

  // ========== iPhone 13 Series (2021) ==========
  // A15 (6 cores), 6GB RAM
  ADD_MODEL(@"iPhone 13 Pro Max", @"iPhone14,3", 428, 926, 3.0, 1284, 2778, 120,
            6, 6, 128, @"arm64e");
  ADD_MODEL(@"iPhone 13 Pro", @"iPhone14,2", 390, 844, 3.0, 1170, 2532, 120, 6,
            6, 128, @"arm64e");
  // A15 (6 cores), 4GB RAM
  ADD_MODEL(@"iPhone 13", @"iPhone14,5", 390, 844, 3.0, 1170, 2532, 60, 6, 4,
            128, @"arm64e");
  ADD_MODEL(@"iPhone 13 mini", @"iPhone14,4", 375, 812, 3.0, 1080, 2340, 60, 6,
            4, 128, @"arm64e");

  // ========== iPhone 12 Series (2020) ==========
  // A14 (6 cores), 6GB RAM
  ADD_MODEL(@"iPhone 12 Pro Max", @"iPhone13,4", 428, 926, 3.0, 1284, 2778, 60,
            6, 6, 128, @"arm64e");
  ADD_MODEL(@"iPhone 12 Pro", @"iPhone13,3", 390, 844, 3.0, 1170, 2532, 60, 6,
            6, 128, @"arm64e");
  // A14 (6 cores), 4GB RAM
  ADD_MODEL(@"iPhone 12", @"iPhone13,2", 390, 844, 3.0, 1170, 2532, 60, 6, 4,
            64, @"arm64e");
  ADD_MODEL(@"iPhone 12 mini", @"iPhone13,1", 375, 812, 3.0, 1080, 2340, 60, 6,
            4, 64, @"arm64e");

  // ========== iPhone 11 Series (2019) ==========
  // A13 (6 cores), 4GB RAM
  ADD_MODEL(@"iPhone 11 Pro Max", @"iPhone12,5", 414, 896, 3.0, 1242, 2688, 60,
            6, 4, 64, @"arm64e");
  ADD_MODEL(@"iPhone 11 Pro", @"iPhone12,3", 375, 812, 3.0, 1125, 2436, 60, 6,
            4, 64, @"arm64e");
  ADD_MODEL(@"iPhone 11", @"iPhone12,1", 414, 896, 2.0, 828, 1792, 60, 6, 4, 64,
            @"arm64e");

  // ========== iPhone SE Series ==========
  // SE3: A15 (6 cores), 4GB RAM
  ADD_MODEL(@"iPhone SE (3rd)", @"iPhone14,6", 375, 667, 2.0, 750, 1334, 60, 6,
            4, 64, @"arm64e");
  // SE2: A13 (6 cores), 3GB RAM
  ADD_MODEL(@"iPhone SE (2nd)", @"iPhone12,8", 375, 667, 2.0, 750, 1334, 60, 6,
            3, 64, @"arm64e");

  // ========== iPhone XS/XR Series (2018) ==========
  // A12 (6 cores), 4GB RAM
  ADD_MODEL(@"iPhone XS Max", @"iPhone11,6", 414, 896, 3.0, 1242, 2688, 60, 6,
            4, 64, @"arm64e");
  // 4GB RAM
  ADD_MODEL(@"iPhone XS", @"iPhone11,2", 375, 812, 3.0, 1125, 2436, 60, 6, 4,
            64, @"arm64e");
  // 3GB RAM
  ADD_MODEL(@"iPhone XR", @"iPhone11,8", 414, 896, 2.0, 828, 1792, 60, 6, 3, 64,
            @"arm64e");

  // ========== iPhone X (2017) ==========
  // A11 (6 cores), 3GB RAM, arm64 (Non-E)
  ADD_MODEL(@"iPhone X", @"iPhone10,6", 375, 812, 3.0, 1125, 2436, 60, 6, 3, 64,
            @"arm64");
  ADD_MODEL(@"iPhone X (GSM)", @"iPhone10,3", 375, 812, 3.0, 1125, 2436, 60, 6,
            3, 64, @"arm64");

  // ========== iPhone 8 Series (2017) ==========
  // A11 (6 cores), 3GB RAM
  ADD_MODEL(@"iPhone 8 Plus", @"iPhone10,5", 414, 736, 3.0, 1242, 2208, 60, 6,
            3, 64, @"arm64");
  ADD_MODEL(@"iPhone 8 Plus (GSM)", @"iPhone10,2", 414, 736, 3.0, 1242, 2208,
            60, 6, 3, 64, @"arm64");
  // 2GB RAM
  ADD_MODEL(@"iPhone 8", @"iPhone10,4", 375, 667, 2.0, 750, 1334, 60, 6, 2, 64,
            @"arm64");
  ADD_MODEL(@"iPhone 8 (GSM)", @"iPhone10,1", 375, 667, 2.0, 750, 1334, 60, 6,
            2, 64, @"arm64");

  // ========== iPhone 7 Series (2016) ==========
  // A10 (4 cores), 3GB RAM
  ADD_MODEL(@"iPhone 7 Plus", @"iPhone9,2", 414, 736, 3.0, 1242, 2208, 60, 4, 3,
            32, @"arm64");
  ADD_MODEL(@"iPhone 7 Plus (GSM)", @"iPhone9,4", 414, 736, 3.0, 1242, 2208, 60,
            4, 3, 32, @"arm64");
  // 2GB RAM
  ADD_MODEL(@"iPhone 7", @"iPhone9,1", 375, 667, 2.0, 750, 1334, 60, 4, 2, 32,
            @"arm64");
  ADD_MODEL(@"iPhone 7 (GSM)", @"iPhone9,3", 375, 667, 2.0, 750, 1334, 60, 4, 2,
            32, @"arm64");

  // ========== Older Models ==========
  // A9 (2 cores), 2GB RAM
  ADD_MODEL(@"iPhone SE (1st)", @"iPhone8,4", 320, 568, 2.0, 640, 1136, 60, 2,
            2, 32, @"arm64");
  ADD_MODEL(@"iPhone 6s Plus", @"iPhone8,2", 414, 736, 3.0, 1242, 2208, 60, 2,
            2, 32, @"arm64");
  ADD_MODEL(@"iPhone 6s", @"iPhone8,1", 375, 667, 2.0, 750, 1334, 60, 2, 2, 32,
            @"arm64");

  _models = list;
}

- (void)loadVersions {
  NSMutableDictionary *map = [NSMutableDictionary dictionary];

// Helper: Add versions
#define VER(v, b)                                                              \
  {                                                                            \
    ECSystemVersion *sv = [[ECSystemVersion alloc] init];                      \
    sv.osVersion = v;                                                          \
    sv.buildVersion = b;                                                       \
    [vers addObject:sv];                                                       \
  }

  NSMutableArray *vers;

  // ========== iOS 26 (September 2025 - Latest) ==========
  vers = [NSMutableArray array];
  VER(@"26.0", @"30A301"); // Estimated
  map[@"26"] = [vers copy];

  // ========== iOS 18 (2024) ==========
  vers = [NSMutableArray array];
  VER(@"18.3.2", @"22D82");
  VER(@"18.3.1", @"22D72");
  VER(@"18.3", @"22D63");
  VER(@"18.2.1", @"22C161");
  VER(@"18.2", @"22C152");
  VER(@"18.1.1", @"22B91");
  VER(@"18.1", @"22B83");
  VER(@"18.0.1", @"22A3370");
  VER(@"18.0", @"22A3354");
  map[@"18"] = [vers copy];

  // ========== iOS 17 (2023) ==========
  vers = [NSMutableArray array];
  VER(@"17.7.2", @"21H221");
  VER(@"17.7.1", @"21H216");
  VER(@"17.7", @"21H16");
  VER(@"17.6.1", @"21G93");
  VER(@"17.6", @"21G80");
  VER(@"17.5.1", @"21F90");
  VER(@"17.5", @"21F79");
  VER(@"17.4.1", @"21E236");
  VER(@"17.4", @"21E219");
  VER(@"17.3.1", @"21D61");
  VER(@"17.3", @"21D50");
  VER(@"17.2.1", @"21C66");
  VER(@"17.2", @"21C62");
  VER(@"17.1.2", @"21B101");
  VER(@"17.1.1", @"21B91");
  VER(@"17.1", @"21B74");
  VER(@"17.0.3", @"21A360");
  VER(@"17.0.2", @"21A350");
  VER(@"17.0.1", @"21A340");
  VER(@"17.0", @"21A329");
  map[@"17"] = [vers copy];

  // ========== iOS 16 (2022) - Max for iPhone X/8 ==========
  vers = [NSMutableArray array];
  VER(@"16.7.10", @"20H350");
  VER(@"16.7.8", @"20H343");
  VER(@"16.7.7", @"20H330");
  VER(@"16.7.6", @"20H320");
  VER(@"16.7.5", @"20H307");
  VER(@"16.7.4", @"20H240");
  VER(@"16.7.3", @"20H232");
  VER(@"16.7.2", @"20H115");
  VER(@"16.7.1", @"20H30");
  VER(@"16.7", @"20H19");
  VER(@"16.6.1", @"20G81");
  VER(@"16.6", @"20G75");
  VER(@"16.5.1", @"20F75");
  VER(@"16.5", @"20F66");
  VER(@"16.4.1", @"20E252");
  VER(@"16.4", @"20E247");
  VER(@"16.3.1", @"20D67");
  VER(@"16.3", @"20D47");
  VER(@"16.2", @"20C65");
  VER(@"16.1.2", @"20B110");
  VER(@"16.1.1", @"20B101");
  VER(@"16.1", @"20B82");
  VER(@"16.0.3", @"20A392");
  VER(@"16.0.2", @"20A380");
  VER(@"16.0.1", @"20A371");
  VER(@"16.0", @"20A362");
  map[@"16"] = [vers copy];

  // ========== iOS 15 (2021) - Max for iPhone 7/SE1/6s ==========
  vers = [NSMutableArray array];
  VER(@"15.8.6", @"19H402"); // Latest for iPhone 7 (Jan 2026)
  VER(@"15.8.5", @"19H394");
  VER(@"15.8.4", @"19H390");
  VER(@"15.8.3", @"19H386");
  VER(@"15.8.2", @"19H384");
  VER(@"15.8.1", @"19H380");
  VER(@"15.8", @"19H12");
  VER(@"15.7.9", @"19H365");
  VER(@"15.7.8", @"19H364");
  VER(@"15.7.7", @"19H357");
  VER(@"15.7.6", @"19H349");
  VER(@"15.7.5", @"19H332");
  VER(@"15.7.4", @"19H321");
  VER(@"15.7.3", @"19H307");
  VER(@"15.7.2", @"19H218");
  VER(@"15.7.1", @"19H117");
  VER(@"15.7", @"19H12");
  VER(@"15.6.1", @"19G82");
  VER(@"15.6", @"19G71");
  VER(@"15.5", @"19F77");
  VER(@"15.4.1", @"19E258");
  VER(@"15.4", @"19E241");
  VER(@"15.3.1", @"19D52");
  VER(@"15.3", @"19D50");
  VER(@"15.2.1", @"19C63");
  VER(@"15.2", @"19C56");
  VER(@"15.1.1", @"19B81");
  VER(@"15.1", @"19B74");
  VER(@"15.0.2", @"19A404");
  VER(@"15.0.1", @"19A348");
  VER(@"15.0", @"19A346");
  map[@"15"] = [vers copy];

  // ========== iOS 14 (2020) ==========
  vers = [NSMutableArray array];
  VER(@"14.8.1", @"18H107");
  VER(@"14.8", @"18H17");
  VER(@"14.7.1", @"18G82");
  VER(@"14.7", @"18G69");
  VER(@"14.6", @"18F72");
  VER(@"14.5.1", @"18E212");
  VER(@"14.5", @"18E199");
  VER(@"14.4.2", @"18D70");
  VER(@"14.4.1", @"18D61");
  VER(@"14.4", @"18D52");
  VER(@"14.3", @"18C66");
  VER(@"14.2.1", @"18B121");
  VER(@"14.2", @"18B92");
  VER(@"14.1", @"18A8395");
  VER(@"14.0.1", @"18A393");
  VER(@"14.0", @"18A373");
  map[@"14"] = [vers copy];

  _versionMap = map;
}

- (void)loadCarriers {
  NSMutableArray *list = [NSMutableArray array];

#define CARRIER(ctry, code, m, n, name, iso, lang, loc)                        \
  {                                                                            \
    ECCarrierInfo *c = [[ECCarrierInfo alloc] init];                           \
    c.countryName = ctry;                                                      \
    c.countryCode = code;                                                      \
    c.mcc = m;                                                                 \
    c.mnc = n;                                                                 \
    c.carrierName = name;                                                      \
    c.isoCountryCode = iso;                                                    \
    c.languageCode = lang;                                                     \
    c.localeID = loc;                                                          \
    [list addObject:c];                                                        \
  }

  // ==================== North America ====================
  CARRIER(@"United States (AT&T)", @"US", @"310", @"410", @"AT&T", @"us", @"en",
          @"en_US");
  CARRIER(@"United States (T-Mobile)", @"US", @"310", @"260", @"T-Mobile",
          @"us", @"en", @"en_US");
  CARRIER(@"United States (Verizon)", @"US", @"311", @"480", @"Verizon", @"us",
          @"en", @"en_US");
  CARRIER(@"United States (Sprint)", @"US", @"310", @"120", @"Sprint", @"us",
          @"en", @"en_US");
  CARRIER(@"Canada (Rogers)", @"CA", @"302", @"720", @"Rogers", @"ca", @"en",
          @"en_CA");
  CARRIER(@"Canada (Bell)", @"CA", @"302", @"610", @"Bell", @"ca", @"en",
          @"en_CA");
  CARRIER(@"Canada (Telus)", @"CA", @"302", @"220", @"TELUS", @"ca", @"en",
          @"en_CA");
  CARRIER(@"Mexico (Telcel)", @"MX", @"334", @"020", @"Telcel", @"mx", @"es",
          @"es_MX");
  CARRIER(@"Mexico (Movistar)", @"MX", @"334", @"030", @"Movistar", @"mx",
          @"es", @"es_MX");

  // ==================== South America ====================
  CARRIER(@"Brazil (Vivo)", @"BR", @"724", @"06", @"Vivo", @"br", @"pt",
          @"pt_BR");
  CARRIER(@"Brazil (Claro)", @"BR", @"724", @"05", @"Claro", @"br", @"pt",
          @"pt_BR");
  CARRIER(@"Brazil (TIM)", @"BR", @"724", @"02", @"TIM", @"br", @"pt",
          @"pt_BR");
  CARRIER(@"Argentina (Claro)", @"AR", @"722", @"310", @"Claro", @"ar", @"es",
          @"es_AR");
  CARRIER(@"Argentina (Personal)", @"AR", @"722", @"340", @"Personal", @"ar",
          @"es", @"es_AR");
  CARRIER(@"Chile (Entel)", @"CL", @"730", @"01", @"Entel", @"cl", @"es",
          @"es_CL");
  CARRIER(@"Colombia (Claro)", @"CO", @"732", @"101", @"Claro", @"co", @"es",
          @"es_CO");
  CARRIER(@"Peru (Movistar)", @"PE", @"716", @"06", @"Movistar", @"pe", @"es",
          @"es_PE");

  // ==================== Europe ====================
  CARRIER(@"United Kingdom (EE)", @"GB", @"234", @"30", @"EE", @"gb", @"en",
          @"en_GB");
  CARRIER(@"United Kingdom (Vodafone)", @"GB", @"234", @"15", @"Vodafone UK",
          @"gb", @"en", @"en_GB");
  CARRIER(@"United Kingdom (O2)", @"GB", @"234", @"10", @"O2 - UK", @"gb",
          @"en", @"en_GB");
  CARRIER(@"United Kingdom (Three)", @"GB", @"234", @"20", @"3 UK", @"gb",
          @"en", @"en_GB");
  CARRIER(@"Germany (Telekom)", @"DE", @"262", @"01", @"Telekom.de", @"de",
          @"de", @"de_DE");
  CARRIER(@"Germany (Vodafone)", @"DE", @"262", @"02", @"Vodafone.de", @"de",
          @"de", @"de_DE");
  CARRIER(@"Germany (O2)", @"DE", @"262", @"07", @"o2 - de", @"de", @"de",
          @"de_DE");
  CARRIER(@"France (Orange)", @"FR", @"208", @"01", @"Orange F", @"fr", @"fr",
          @"fr_FR");
  CARRIER(@"France (SFR)", @"FR", @"208", @"10", @"SFR", @"fr", @"fr",
          @"fr_FR");
  CARRIER(@"France (Bouygues)", @"FR", @"208", @"20", @"Bouygues", @"fr", @"fr",
          @"fr_FR");
  CARRIER(@"France (Free)", @"FR", @"208", @"15", @"Free Mobile", @"fr", @"fr",
          @"fr_FR");
  CARRIER(@"Italy (TIM)", @"IT", @"222", @"01", @"TIM", @"it", @"it", @"it_IT");
  CARRIER(@"Italy (Vodafone)", @"IT", @"222", @"10", @"Vodafone IT", @"it",
          @"it", @"it_IT");
  CARRIER(@"Italy (WindTre)", @"IT", @"222", @"88", @"WINDTRE", @"it", @"it",
          @"it_IT");
  CARRIER(@"Spain (Movistar)", @"ES", @"214", @"07", @"Movistar", @"es", @"es",
          @"es_ES");
  CARRIER(@"Spain (Vodafone)", @"ES", @"214", @"01", @"Vodafone ES", @"es",
          @"es", @"es_ES");
  CARRIER(@"Spain (Orange)", @"ES", @"214", @"03", @"Orange", @"es", @"es",
          @"es_ES");
  CARRIER(@"Netherlands (KPN)", @"NL", @"204", @"08", @"KPN", @"nl", @"nl",
          @"nl_NL");
  CARRIER(@"Netherlands (Vodafone)", @"NL", @"204", @"04", @"Vodafone NL",
          @"nl", @"nl", @"nl_NL");
  CARRIER(@"Belgium (Proximus)", @"BE", @"206", @"01", @"Proximus", @"be",
          @"nl", @"nl_BE");
  CARRIER(@"Switzerland (Swisscom)", @"CH", @"228", @"01", @"Swisscom", @"ch",
          @"de", @"de_CH");
  CARRIER(@"Austria (A1)", @"AT", @"232", @"01", @"A1", @"at", @"de", @"de_AT");
  CARRIER(@"Poland (Plus)", @"PL", @"260", @"01", @"Plus", @"pl", @"pl",
          @"pl_PL");
  CARRIER(@"Poland (Orange)", @"PL", @"260", @"03", @"Orange PL", @"pl", @"pl",
          @"pl_PL");
  CARRIER(@"Sweden (Telia)", @"SE", @"240", @"01", @"Telia", @"se", @"sv",
          @"sv_SE");
  CARRIER(@"Norway (Telenor)", @"NO", @"242", @"01", @"Telenor", @"no", @"nb",
          @"nb_NO");
  CARRIER(@"Denmark (TDC)", @"DK", @"238", @"01", @"TDC", @"dk", @"da",
          @"da_DK");
  CARRIER(@"Finland (Elisa)", @"FI", @"244", @"05", @"Elisa", @"fi", @"fi",
          @"fi_FI");
  CARRIER(@"Russia (MTS)", @"RU", @"250", @"01", @"MTS", @"ru", @"ru",
          @"ru_RU");
  CARRIER(@"Russia (MegaFon)", @"RU", @"250", @"02", @"MegaFon", @"ru", @"ru",
          @"ru_RU");
  CARRIER(@"Russia (Beeline)", @"RU", @"250", @"99", @"Beeline", @"ru", @"ru",
          @"ru_RU");
  CARRIER(@"Turkey (Turkcell)", @"TR", @"286", @"01", @"Turkcell", @"tr", @"tr",
          @"tr_TR");
  CARRIER(@"Turkey (Vodafone)", @"TR", @"286", @"02", @"Vodafone TR", @"tr",
          @"tr", @"tr_TR");
  CARRIER(@"Greece (Cosmote)", @"GR", @"202", @"01", @"COSMOTE", @"gr", @"el",
          @"el_GR");
  CARRIER(@"Portugal (NOS)", @"PT", @"268", @"03", @"NOS", @"pt", @"pt",
          @"pt_PT");
  CARRIER(@"Ireland (Vodafone)", @"IE", @"272", @"01", @"Vodafone IE", @"ie",
          @"en", @"en_IE");

  // ==================== Asia ====================
  CARRIER(@"China (China Mobile)", @"CN", @"460", @"00", @"中国移动", @"cn",
          @"zh-Hans", @"zh_CN");
  CARRIER(@"China (China Unicom)", @"CN", @"460", @"01", @"中国联通", @"cn",
          @"zh-Hans", @"zh_CN");
  CARRIER(@"China (China Telecom)", @"CN", @"460", @"03", @"中国电信", @"cn",
          @"zh-Hans", @"zh_CN");
  CARRIER(@"Japan (NTT Docomo)", @"JP", @"440", @"10", @"NTT DOCOMO", @"jp",
          @"ja", @"ja_JP");
  CARRIER(@"Japan (SoftBank)", @"JP", @"440", @"20", @"SoftBank", @"jp", @"ja",
          @"ja_JP");
  CARRIER(@"Japan (au/KDDI)", @"JP", @"440", @"50", @"au", @"jp", @"ja",
          @"ja_JP");
  CARRIER(@"Japan (Rakuten)", @"JP", @"440", @"11", @"Rakuten", @"jp", @"ja",
          @"ja_JP");
  CARRIER(@"South Korea (SK Telecom)", @"KR", @"450", @"05", @"SKT", @"kr",
          @"ko", @"ko_KR");
  CARRIER(@"South Korea (KT)", @"KR", @"450", @"08", @"KT", @"kr", @"ko",
          @"ko_KR");
  CARRIER(@"South Korea (LG U+)", @"KR", @"450", @"06", @"LG U+", @"kr", @"ko",
          @"ko_KR");
  CARRIER(@"Taiwan (Chunghwa)", @"TW", @"466", @"92", @"中華電信", @"tw",
          @"zh-Hant", @"zh_TW");
  CARRIER(@"Taiwan (Taiwan Mobile)", @"TW", @"466", @"97", @"台灣大哥大", @"tw",
          @"zh-Hant", @"zh_TW");
  CARRIER(@"Taiwan (FarEasTone)", @"TW", @"466", @"01", @"遠傳電信", @"tw",
          @"zh-Hant", @"zh_TW");
  CARRIER(@"Hong Kong (CSL)", @"HK", @"454", @"00", @"CSL", @"hk", @"zh-Hant",
          @"zh_HK");
  CARRIER(@"Hong Kong (3HK)", @"HK", @"454", @"03", @"3HK", @"hk", @"zh-Hant",
          @"zh_HK");
  CARRIER(@"Hong Kong (SmarTone)", @"HK", @"454", @"06", @"SmarTone", @"hk",
          @"zh-Hant", @"zh_HK");
  CARRIER(@"Singapore (Singtel)", @"SG", @"525", @"01", @"Singtel", @"sg",
          @"en", @"en_SG");
  CARRIER(@"Singapore (StarHub)", @"SG", @"525", @"05", @"StarHub", @"sg",
          @"en", @"en_SG");
  CARRIER(@"Singapore (M1)", @"SG", @"525", @"03", @"M1", @"sg", @"en",
          @"en_SG");
  CARRIER(@"Malaysia (Maxis)", @"MY", @"502", @"12", @"Maxis", @"my", @"ms",
          @"ms_MY");
  CARRIER(@"Malaysia (Celcom)", @"MY", @"502", @"13", @"Celcom", @"my", @"ms",
          @"ms_MY");
  CARRIER(@"Malaysia (Digi)", @"MY", @"502", @"16", @"Digi", @"my", @"ms",
          @"ms_MY");
  CARRIER(@"Thailand (AIS)", @"TH", @"520", @"01", @"AIS", @"th", @"th",
          @"th_TH");
  CARRIER(@"Thailand (DTAC)", @"TH", @"520", @"05", @"DTAC", @"th", @"th",
          @"th_TH");
  CARRIER(@"Thailand (True Move)", @"TH", @"520", @"04", @"TrueMove H", @"th",
          @"th", @"th_TH");
  CARRIER(@"Vietnam (Viettel)", @"VN", @"452", @"04", @"Viettel", @"vn", @"vi",
          @"vi_VN");
  CARRIER(@"Vietnam (Vinaphone)", @"VN", @"452", @"02", @"Vinaphone", @"vn",
          @"vi", @"vi_VN");
  CARRIER(@"Vietnam (Mobifone)", @"VN", @"452", @"01", @"MobiFone", @"vn",
          @"vi", @"vi_VN");
  CARRIER(@"Philippines (Globe)", @"PH", @"515", @"02", @"Globe", @"ph", @"en",
          @"en_PH");
  CARRIER(@"Philippines (Smart)", @"PH", @"515", @"03", @"Smart", @"ph", @"en",
          @"en_PH");
  CARRIER(@"Indonesia (Telkomsel)", @"ID", @"510", @"10", @"Telkomsel", @"id",
          @"id", @"id_ID");
  CARRIER(@"Indonesia (Indosat)", @"ID", @"510", @"01", @"Indosat", @"id",
          @"id", @"id_ID");
  CARRIER(@"Indonesia (XL)", @"ID", @"510", @"11", @"XL Axiata", @"id", @"id",
          @"id_ID");
  CARRIER(@"India (Jio)", @"IN", @"405", @"840", @"Jio", @"in", @"hi",
          @"hi_IN");
  CARRIER(@"India (Airtel)", @"IN", @"404", @"10", @"Airtel", @"in", @"hi",
          @"hi_IN");
  CARRIER(@"India (Vi)", @"IN", @"404", @"20", @"Vi", @"in", @"hi", @"hi_IN");
  CARRIER(@"Bangladesh (Grameenphone)", @"BD", @"470", @"01", @"Grameenphone",
          @"bd", @"bn", @"bn_BD");
  CARRIER(@"Pakistan (Jazz)", @"PK", @"410", @"01", @"Jazz", @"pk", @"ur",
          @"ur_PK");
  CARRIER(@"Pakistan (Telenor)", @"PK", @"410", @"06", @"Telenor PK", @"pk",
          @"ur", @"ur_PK");

  // ==================== Oceania ====================
  CARRIER(@"Australia (Telstra)", @"AU", @"505", @"01", @"Telstra", @"au",
          @"en", @"en_AU");
  CARRIER(@"Australia (Optus)", @"AU", @"505", @"02", @"Optus", @"au", @"en",
          @"en_AU");
  CARRIER(@"Australia (Vodafone)", @"AU", @"505", @"03", @"Vodafone AU", @"au",
          @"en", @"en_AU");
  CARRIER(@"New Zealand (Spark)", @"NZ", @"530", @"01", @"Spark", @"nz", @"en",
          @"en_NZ");
  CARRIER(@"New Zealand (Vodafone)", @"NZ", @"530", @"24", @"Vodafone NZ",
          @"nz", @"en", @"en_NZ");

  // ==================== Middle East ====================
  CARRIER(@"UAE (Etisalat)", @"AE", @"424", @"02", @"Etisalat", @"ae", @"ar",
          @"ar_AE");
  CARRIER(@"UAE (du)", @"AE", @"424", @"03", @"du", @"ae", @"ar", @"ar_AE");
  CARRIER(@"Saudi Arabia (STC)", @"SA", @"420", @"01", @"STC", @"sa", @"ar",
          @"ar_SA");
  CARRIER(@"Saudi Arabia (Mobily)", @"SA", @"420", @"03", @"Mobily", @"sa",
          @"ar", @"ar_SA");
  CARRIER(@"Saudi Arabia (Zain)", @"SA", @"420", @"04", @"Zain SA", @"sa",
          @"ar", @"ar_SA");
  CARRIER(@"Israel (Cellcom)", @"IL", @"425", @"02", @"Cellcom", @"il", @"he",
          @"he_IL");
  CARRIER(@"Israel (Partner)", @"IL", @"425", @"01", @"Partner", @"il", @"he",
          @"he_IL");
  CARRIER(@"Qatar (Ooredoo)", @"QA", @"427", @"01", @"Ooredoo", @"qa", @"ar",
          @"ar_QA");
  CARRIER(@"Kuwait (Zain)", @"KW", @"419", @"02", @"Zain KW", @"kw", @"ar",
          @"ar_KW");
  CARRIER(@"Bahrain (Batelco)", @"BH", @"426", @"01", @"Batelco", @"bh", @"ar",
          @"ar_BH");
  CARRIER(@"Oman (Omantel)", @"OM", @"422", @"02", @"Omantel", @"om", @"ar",
          @"ar_OM");
  CARRIER(@"Egypt (Vodafone)", @"EG", @"602", @"02", @"Vodafone EG", @"eg",
          @"ar", @"ar_EG");
  CARRIER(@"Egypt (Orange)", @"EG", @"602", @"01", @"Orange EG", @"eg", @"ar",
          @"ar_EG");

  // ==================== Africa ====================
  CARRIER(@"South Africa (Vodacom)", @"ZA", @"655", @"01", @"Vodacom", @"za",
          @"en", @"en_ZA");
  CARRIER(@"South Africa (MTN)", @"ZA", @"655", @"10", @"MTN SA", @"za", @"en",
          @"en_ZA");
  CARRIER(@"Nigeria (MTN)", @"NG", @"621", @"30", @"MTN NG", @"ng", @"en",
          @"en_NG");
  CARRIER(@"Nigeria (Glo)", @"NG", @"621", @"50", @"Glo", @"ng", @"en",
          @"en_NG");
  CARRIER(@"Nigeria (Airtel)", @"NG", @"621", @"20", @"Airtel NG", @"ng", @"en",
          @"en_NG");
  CARRIER(@"Kenya (Safaricom)", @"KE", @"639", @"02", @"Safaricom", @"ke",
          @"en", @"en_KE");
  CARRIER(@"Morocco (Maroc Telecom)", @"MA", @"604", @"01", @"Maroc Telecom",
          @"ma", @"ar", @"ar_MA");
  CARRIER(@"Algeria (Mobilis)", @"DZ", @"603", @"01", @"Mobilis", @"dz", @"ar",
          @"ar_DZ");
  CARRIER(@"Ghana (MTN)", @"GH", @"620", @"01", @"MTN GH", @"gh", @"en",
          @"en_GH");
  CARRIER(@"Tanzania (Vodacom)", @"TZ", @"640", @"04", @"Vodacom TZ", @"tz",
          @"sw", @"sw_TZ");

  _carriers = list;
}

#pragma mark - Public Methods

- (NSArray<ECDeviceModel *> *)alliPhoneModels {
  return _models;
}

- (NSArray<ECSystemVersion *> *)versionsForModel:(ECDeviceModel *)model {
  NSMutableArray *result = [NSMutableArray array];

  // Determine max supported iOS based on device
  // iPhone 7/SE1/6s: Max iOS 15 (15.8.6)
  // iPhone 8/X: Max iOS 16 (16.7.10)
  // iPhone XS/XR+: iOS 17, 18+
  // iPhone 11+: iOS 26

  NSArray *majorVersions = @[ @"26", @"18", @"17", @"16", @"15", @"14" ];

  for (NSString *major in majorVersions) {
    int v = [major intValue];

    // ===== Min Version Checks (Device launched with this iOS) =====
    // iPhone 17: Min iOS 19 (estimated)
    if ([model.machineId hasPrefix:@"iPhone18"]) {
      if (v < 19)
        continue;
    }
    // iPhone 16: Min iOS 18
    else if ([model.machineId hasPrefix:@"iPhone17"]) {
      if (v < 18)
        continue;
    }
    // iPhone 15: Min iOS 17
    else if ([model.machineId hasPrefix:@"iPhone16"]) {
      if (v < 17)
        continue;
    }
    // iPhone 14 / SE3: Min iOS 16 / 15
    else if ([model.machineId hasPrefix:@"iPhone15"]) {
      if (v < 16)
        continue;
    }
    // iPhone 13: Min iOS 15
    else if ([model.machineId hasPrefix:@"iPhone14"]) {
      if (v < 15)
        continue;
    }
    // iPhone 12: Min iOS 14
    else if ([model.machineId hasPrefix:@"iPhone13"]) {
      if (v < 14)
        continue;
    }

    // ===== Max Version Checks (Device no longer updated) =====
    // iPhone 7/7Plus (iPhone9,x), SE1/6s (iPhone8,x): Max iOS 15
    if ([model.machineId hasPrefix:@"iPhone9"] ||
        [model.machineId hasPrefix:@"iPhone8"]) {
      if (v > 15)
        continue;
    }
    // iPhone 8/X (iPhone10,x): Max iOS 16
    else if ([model.machineId hasPrefix:@"iPhone10"]) {
      if (v > 16)
        continue;
    }
    // iPhone XS/XR (iPhone11,x): Max iOS 18 (Currently no iOS 26 support)
    else if ([model.machineId hasPrefix:@"iPhone11"]) {
      if (v > 18)
        continue;
    }

    NSArray *vers = _versionMap[major];
    if (vers) {
      [result addObjectsFromArray:vers];
    }
  }

  return result;
}

- (NSArray<ECCarrierInfo *> *)supportedCarriers {
  return _carriers;
}

- (NSDictionary *)tim_generateConfigForModel:(ECDeviceModel *)model
                                     version:(ECSystemVersion *)version
                                     carrier:(ECCarrierInfo *)carrier {
  NSMutableDictionary *dict = [NSMutableDictionary dictionary];

  // 1. Device Info
  dict[@"deviceName"] = model.displayName;
  dict[@"machineModel"] = model.machineId;
  dict[@"localizedModel"] = @"iPhone"; // 用于 UIDevice.localizedModel
  dict[@"deviceModel"] = @"iPhone";    // 用于 UIDevice.model

  // 2. System Version
  dict[@"systemVersion"] = version.osVersion;
  dict[@"systemBuildVersion"] = version.buildVersion;
  dict[@"systemName"] = @"iOS";

  // 3. Screen
  dict[@"screenWidth"] =
      [NSString stringWithFormat:@"%ld", (long)model.screenWidth];
  dict[@"screenHeight"] =
      [NSString stringWithFormat:@"%ld", (long)model.screenHeight];
  dict[@"screenScale"] = [NSString stringWithFormat:@"%.1f", model.screenScale];
  dict[@"nativeBounds"] =
      [NSString stringWithFormat:@"%ldx%ld", (long)model.nativeWidth,
                                 (long)model.nativeHeight];
  dict[@"maxFPS"] = [NSString stringWithFormat:@"%ld", (long)model.maxFPS];

  // 4. Carrier / Network / Locale (合并:
  // languageCode/btdCurrentLanguage/systemLanguage)
  dict[@"carrierName"] = carrier.carrierName;
  dict[@"mobileCountryCode"] = carrier.mcc;
  dict[@"mobileNetworkCode"] = carrier.mnc;
  dict[@"isoCountryCode"] = carrier.isoCountryCode;
  dict[@"countryCode"] = carrier.countryCode;
  dict[@"languageCode"] = carrier.languageCode; // 统一语言代码
  dict[@"localeIdentifier"] = carrier.localeID;

  // Construct User-Agent style preferred language
  dict[@"preferredLanguage"] = [NSString
      stringWithFormat:@"%@-%@", carrier.languageCode, carrier.countryCode];

  // BTD specific (使用统一的 languageCode)
  dict[@"btdBundleId"] = @"com.zhiliaoapp.musically";

  // 5. Randomize Identifiers (合并: vendorId 用于 IDFV; tiktokIdfa 固定为零)
  NSString *generatedVendorId = [[NSUUID UUID] UUIDString];
  dict[@"vendorId"] = generatedVendorId; // 用于 UIDevice.identifierForVendor
  dict[@"installId"] = [NSString
      stringWithFormat:@"%llu",
                       (unsigned long long)(
                           [[NSDate date] timeIntervalSince1970] * 1000) +
                           arc4random() % 10000];
  dict[@"tiktokIdfa"] =
      @"00000000-0000-0000-0000-000000000000"; // IDFA 固定禁用

  // 5. Hardware Specs (for sysctl spoofing)
  dict[@"cpuCores"] = [NSString stringWithFormat:@"%ld", (long)model.cpuCount];
  dict[@"physicalMemory"] =
      [NSString stringWithFormat:@"%ldGB", (long)model.ramSize];
  dict[@"diskSize"] =
      [NSString stringWithFormat:@"%ldGB", (long)model.storageSize];

  // 6. Unique Identifiers (randomized per config generation)
  dict[@"udid"] = [NSString
      stringWithFormat:@"%08X-%04X%04X%04X-%012llX", arc4random(),
                       arc4random() % 0xFFFF, arc4random() % 0xFFFF,
                       arc4random() % 0xFFFF,
                       (unsigned long long)arc4random() << 16 | arc4random()];

  // Serial Number format: F + 9 alphanumeric chars
  NSString *serialChars = @"ABCDEFGHJKLMNPQRSTUVWXYZ0123456789";
  NSMutableString *serial = [NSMutableString stringWithString:@"F"];
  for (int i = 0; i < 11; i++) {
    [serial
        appendFormat:@"%C",
                     [serialChars
                         characterAtIndex:arc4random_uniform(
                                              (uint32_t)serialChars.length)]];
  }
  dict[@"serialNumber"] = serial;

  // 7. Network Identifiers (randomized)
  NSArray *ssidPrefixes =
      @[ @"HOME-", @"TP-Link_", @"NETGEAR-", @"Wifi_", @"HUAWEI-" ];
  dict[@"wifiSSID"] =
      [NSString stringWithFormat:@"%@%04X",
                                 ssidPrefixes[arc4random_uniform(
                                     (uint32_t)ssidPrefixes.count)],
                                 arc4random() % 0xFFFF];
  dict[@"wifiBSSID"] =
      [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X",
                                 arc4random() % 256, arc4random() % 256,
                                 arc4random() % 256, arc4random() % 256,
                                 arc4random() % 256, arc4random() % 256];

  return dict;
}

@end
