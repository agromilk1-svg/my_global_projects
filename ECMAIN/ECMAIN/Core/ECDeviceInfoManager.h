//
//  ECDeviceInfoManager.h
//  ECMAIN
//
//  设备信息管理器 - 获取和管理设备参数
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 设备信息分类 — 按用户需求重构为 6 大伪装类别
typedef NS_ENUM(NSInteger, ECDeviceInfoSection) {
  ECDeviceInfoSectionCountry = 0, // 0. 国家/地区快速选择
  ECDeviceInfoSectionDevice,      // 1. iPhone 设备伪装
  ECDeviceInfoSectionSystem,      // 2. iOS 版本伪装
  ECDeviceInfoSectionCarrier,     // 3. 运营商伪装
  ECDeviceInfoSectionRegion,      // 4. 区域伪装
  ECDeviceInfoSectionLanguage,    // 5. 语言伪装
  ECDeviceInfoSectionNetwork,     // 6. 网络拦截
  ECDeviceInfoSectionCount
};

/// 单个设备信息项
@interface ECDeviceInfoItem : NSObject
@property(nonatomic, copy) NSString *key;           // 内部标识
@property(nonatomic, copy) NSString *displayName;   // 显示名称
@property(nonatomic, copy) NSString *originalValue; // 真实值
@property(nonatomic, copy) NSString *currentValue;  // 当前值（可能已修改）
@property(nonatomic, assign) BOOL isModified;       // 是否已修改
@end

/// 设备信息管理器
@interface ECDeviceInfoManager : NSObject

+ (instancetype)sharedManager;

/// 获取指定分类的所有信息项
- (NSArray<ECDeviceInfoItem *> *)itemsForSection:(ECDeviceInfoSection)section;

/// 获取分类标题
- (NSString *)titleForSection:(ECDeviceInfoSection)section;

/// "仅伪装克隆"模式：只保留克隆隔离，不伪装设备
@property(nonatomic, assign) BOOL cloneOnlyMode;

/// 保存所有修改到配置文件
- (BOOL)saveChanges;

/// 保存配置到指定路径
- (BOOL)saveConfigToPath:(NSString *)path;

/// 从指定路径加载配置
- (void)loadConfigFromPath:(NSString *)path;

/// 还原所有值为默认值
- (void)resetToDefaults;

/// 刷新获取真实设备信息
- (void)refreshDeviceInfo;

/// 获取配置文件路径
- (NSString *)configFilePath;

/// 检查是否有修改
- (BOOL)hasModifications;

/// 获取所有信息项的字典 (Key: Config Key)
- (NSDictionary<NSString *, ECDeviceInfoItem *> *)getAllItems;

/// 获取所有设备信息的字典表示 (Key: Config Key, Value: Original Value)
- (NSDictionary<NSString *, id> *)dictionaryRepresentation;

/// 获取国家预设配置字典
+ (NSDictionary<NSString *, NSDictionary *> *)countryPresets;

/// 根据国家代码应用预设配置 (自动填充语言、时区、货币等)
- (void)applyCountryPreset:(NSString *)countryCode;

/// 获取支持的国家代码列表
+ (NSArray<NSString *> *)supportedCountryCodes;

@end

NS_ASSUME_NONNULL_END
