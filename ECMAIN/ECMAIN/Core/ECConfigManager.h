//
//  ECConfigManager.h
//  ECMAIN
//
//  用于解耦本地配置和服务器下发配置的独立存储管理器
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ECConfigManager : NSObject

+ (instancetype)sharedManager;

/// 返回当前服务端完整配置 JSON 数据存放的物理文件路径
@property (nonatomic, readonly) NSString *serverConfigFilePath;

#pragma mark - Local App Settings
/// 均为本地读写配置，内部仍然使用 NSUserDefaults
@property (nonatomic, copy) NSString *cloudServerURL;
@property (nonatomic, copy) NSString *deviceNo;
@property (nonatomic, copy) NSString *adminUsername;

#pragma mark - Server Sync Settings
/// 核心方法：提供全新的服务器字典全量写入更新机制
/// @param newConfig 上游心跳返回的 push_config
/// @return 若发生了实质变动并覆写成功返回 YES，否则返回 NO
- (BOOL)updateServerConfigIfNeeded:(NSDictionary *)newConfig;

/// 拉取当前落盘的服务端全量配置，返回 NSDictionary
- (NSDictionary *)currentServerConfig;

/// 读取单项服务端属性（如 @"country", @"tiktok_accounts" 等）
- (nullable id)serverConfigForKey:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
