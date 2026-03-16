//
//  ECDeviceDatabase.h
//  ECMAIN
//
//  Device Model, iOS Version, and Carrier Database
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// --- Models ---

@interface ECDeviceModel : NSObject
@property(nonatomic, copy) NSString *displayName;     // e.g., "iPhone 13 Pro"
@property(nonatomic, copy) NSString *machineId;       // e.g., "iPhone14,2"
@property(nonatomic, copy) NSString *marketingName;   // e.g., "iPhone 13 Pro"
@property(nonatomic, assign) NSInteger screenWidth;   // e.g., 390
@property(nonatomic, assign) NSInteger screenHeight;  // e.g., 844
@property(nonatomic, assign) CGFloat screenScale;     // e.g., 3.0
@property(nonatomic, assign) NSInteger nativeWidth;   // e.g., 1170
@property(nonatomic, assign) NSInteger nativeHeight;  // e.g., 2532
@property(nonatomic, assign) BOOL isOLED;             // YES/NO
@property(nonatomic, assign) NSInteger maxFPS;        // 60 or 120 (ProMotion)
@property(nonatomic, assign) NSInteger cpuCount;      // e.g., 6 for A11+
@property(nonatomic, assign) NSInteger ramSize;       // e.g., 4 (GB)
@property(nonatomic, assign) NSInteger storageSize;   // e.g., 128 (GB)
@property(nonatomic, copy) NSString *cpuArchitecture; // e.g., "arm64e"
@property(nonatomic, copy) NSString *minOS;           // e.g., "15.0"
@property(nonatomic, copy) NSString *maxOS;           // e.g., "18.0"
@end

@interface ECSystemVersion : NSObject
@property(nonatomic, copy) NSString *osVersion;    // e.g., "15.4"
@property(nonatomic, copy) NSString *buildVersion; // e.g., "19E241"
@property(nonatomic, copy) NSString *releaseDate;  // e.g., "2022-03-14"
@end

@interface ECCarrierInfo : NSObject
@property(nonatomic, copy) NSString *countryName;    // e.g., "United States"
@property(nonatomic, copy) NSString *countryCode;    // e.g., "US"
@property(nonatomic, copy) NSString *mcc;            // e.g., "310"
@property(nonatomic, copy) NSString *mnc;            // e.g., "410"
@property(nonatomic, copy) NSString *carrierName;    // e.g., "AT&T"
@property(nonatomic, copy) NSString *isoCountryCode; // e.g., "us"
@property(nonatomic, copy) NSString *languageCode;   // e.g., "en"
@property(nonatomic, copy) NSString *localeID;       // e.g., "en_US"
@end

// --- Database Manager ---

@interface ECDeviceDatabase : NSObject

+ (instancetype)shared;

/// 获取所有支持的 iPhone 型号列表
- (NSArray<ECDeviceModel *> *)alliPhoneModels;

/// 获取指定设备支持的 iOS 版本列表
- (NSArray<ECSystemVersion *> *)versionsForModel:(ECDeviceModel *)model;

/// 获取支持的国家/运营商列表
- (NSArray<ECCarrierInfo *> *)supportedCarriers;

/// 生成完整的伪装配置字典
/// @param model 选中的设备型号
/// @param version 选中的系统版本
/// @param carrier 选中的运营商/地区
/// @return 用于 device.plist 的字典
- (NSDictionary *)tim_generateConfigForModel:(ECDeviceModel *)model
                                     version:(ECSystemVersion *)version
                                     carrier:(ECCarrierInfo *)carrier;

@end

NS_ASSUME_NONNULL_END
