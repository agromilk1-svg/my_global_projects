//
//  ECProfileManager.h
//  ECProfileSpoof (方案 C)
//
//  多 Profile 生命周期管理器
//  负责管理 Profile 的创建/切换/删除、设备指纹自动生成、数据目录管理
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Profile 元数据
@interface ECProfileInfo : NSObject
@property (nonatomic, copy) NSString *profileId;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NSDate *createdDate;
@property (nonatomic, strong, nullable) NSDate *lastUsedDate;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

/// Profile 管理器
@interface ECProfileManager : NSObject

+ (instancetype)shared;

#pragma mark - Profile 查询

/// 当前激活的 Profile ID（从 active_profile 文件读取）
- (NSString *)activeProfileId;

/// 当前 Profile 的虚拟 HOME 路径
- (NSString *)profileHomeDirectory;

/// 当前 Profile 的设备伪装配置
- (NSDictionary *)activeDeviceConfig;

/// 所有 Profile 列表
- (NSArray<ECProfileInfo *> *)allProfiles;

/// .ecprofiles 根目录
- (NSString *)profilesBaseDirectory;

/// 真实 HOME 路径（未 Hook 的原始路径）
- (NSString *)realHomeDirectory;

#pragma mark - Profile 操作

/// 创建新 Profile（自动生成随机设备指纹），返回新 Profile ID
- (NSString *)createNewProfileWithName:(NSString *)name;

/// 删除 Profile
- (BOOL)deleteProfile:(NSString *)profileId;

/// 重命名 Profile
- (BOOL)renameProfile:(NSString *)profileId toName:(NSString *)newName;

/// 切换到指定 Profile（写入 active_profile，但不 exit）
- (void)switchToProfile:(NSString *)profileId;

/// 更新 lastUsed 时间戳
- (void)touchActiveProfile;

#pragma mark - 设备指纹

/// 获取指定 Profile 的设备伪装配置
- (NSDictionary *)deviceConfigForProfile:(NSString *)profileId;

/// 读取伪装配置中的值
- (nullable NSString *)spoofValueForKey:(NSString *)key;

/// 读取伪装配置中的 BOOL 值
- (BOOL)spoofBoolForKey:(NSString *)key defaultValue:(BOOL)defaultValue;

@end

NS_ASSUME_NONNULL_END
