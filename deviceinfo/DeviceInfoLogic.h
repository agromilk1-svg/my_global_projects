#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DeviceInfoSection) {
  DeviceInfoSectionSystem = 0,
  DeviceInfoSectionDevice,
  DeviceInfoSectionScreen,
  DeviceInfoSectionLocale,
  DeviceInfoSectionNetwork,
  DeviceInfoSectionIdentifiers,
  DeviceInfoSectionHardware,
  DeviceInfoSectionSecurity,
  DeviceInfoSectionInjection,
  DeviceInfoSectionCount
};

@interface DeviceInfoItem : NSObject
@property(nonatomic, copy) NSString *key;
@property(nonatomic, copy) NSString *displayName;
@property(nonatomic, copy) NSString *value;
@end

@interface DeviceInfoLogic : NSObject

+ (NSArray<DeviceInfoItem *> *)itemsForSection:(DeviceInfoSection)section;
+ (NSString *)titleForSection:(DeviceInfoSection)section;

// 原始检测方法保留供内部或单独使用
+ (BOOL)isDecrypted;
+ (BOOL)isTrollStoreActive;
+ (BOOL)isJailbroken;

@end

NS_ASSUME_NONNULL_END
