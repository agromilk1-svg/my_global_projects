//
//  ECConfigManager.m
//  ECMAIN
//
//  用于解耦本地配置和服务器下发配置的独立存储管理器
//

#import "ECConfigManager.h"

#define EC_APP_GROUP_ID @"group.com.ecmain.shared"
#define EC_SERVER_CONFIG_JSON_NAME @"server_sync_config.json"

@interface ECConfigManager ()
@property (nonatomic, strong) NSUserDefaults *localDefaults;
@property (nonatomic, strong) dispatch_queue_t ioQueue;
@property (nonatomic, copy) NSString *configPath;
@end

@implementation ECConfigManager

+ (instancetype)sharedManager {
    static ECConfigManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _localDefaults = [[NSUserDefaults alloc] initWithSuiteName:EC_APP_GROUP_ID];
        _ioQueue = dispatch_queue_create("com.ecmain.config.ioq", DISPATCH_QUEUE_SERIAL);
        
        NSURL *containerURL = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:EC_APP_GROUP_ID];
        if (containerURL) {
            _configPath = [[containerURL path] stringByAppendingPathComponent:EC_SERVER_CONFIG_JSON_NAME];
        } else {
            // 回退到 Documents 目录（一般 App Group 配置在越狱环境下极少失败）
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            _configPath = [paths.firstObject stringByAppendingPathComponent:EC_SERVER_CONFIG_JSON_NAME];
        }
    }
    return self;
}

- (NSString *)serverConfigFilePath {
    return self.configPath;
}

#pragma mark - Local App Settings

- (NSString *)cloudServerURL {
    return [self.localDefaults stringForKey:@"CloudServerURL"] ?: @"http://s.ecmain.site:8088";
}

- (void)setCloudServerURL:(NSString *)url {
    [self.localDefaults setObject:url forKey:@"CloudServerURL"];
    [self.localDefaults synchronize];
}

- (NSString *)deviceNo {
    return [self.localDefaults stringForKey:@"EC_DEVICE_NO"] ?: @"";
}

- (void)setDeviceNo:(NSString *)deviceNo {
    [self.localDefaults setObject:deviceNo forKey:@"EC_DEVICE_NO"];
    [self.localDefaults synchronize];
}

- (NSString *)adminUsername {
    return [self.localDefaults stringForKey:@"EC_ADMIN_USERNAME"] ?: @"";
}

- (void)setAdminUsername:(NSString *)adminUsername {
    [self.localDefaults setObject:adminUsername forKey:@"EC_ADMIN_USERNAME"];
    [self.localDefaults synchronize];
}

#pragma mark - Server Sync Settings

- (BOOL)updateServerConfigIfNeeded:(NSDictionary *)newConfig {
    if (!newConfig || ![newConfig isKindOfClass:[NSDictionary class]]) {
        return NO;
    }
    
    __block BOOL isUpdated = NO;
    dispatch_sync(self.ioQueue, ^{
        NSDictionary *currentConfig = [self _currentServerConfigUnsafe];
        
        // 此处对比可以直接用 isEqualToDictionary（若新老 NSDictionary 树状内容完全一样则返回 YES）
        if (currentConfig && [currentConfig isEqualToDictionary:newConfig]) {
            isUpdated = NO;
        } else {
            // 数据有差异，启动覆写
            NSError *err = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:newConfig options:NSJSONWritingPrettyPrinted error:&err];
            if (!err && jsonData) {
                [jsonData writeToFile:self.configPath atomically:YES];
                isUpdated = YES;
                NSLog(@"[ECConfigManager] 服务器配置内容有更新，已成功覆写独立配置文件.");
            } else {
                NSLog(@"[ECConfigManager] 写入服务器配置失败: %@", err);
            }
        }
    });
    
    return isUpdated;
}

- (NSDictionary *)currentServerConfig {
    __block NSDictionary *config = nil;
    dispatch_sync(self.ioQueue, ^{
        config = [self _currentServerConfigUnsafe];
    });
    return config ?: @{};
}

- (nullable id)serverConfigForKey:(NSString *)key {
    NSDictionary *config = [self currentServerConfig];
    return config[key];
}

// 内部不加锁的方法
- (NSDictionary *)_currentServerConfigUnsafe {
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.configPath]) {
        return @{};
    }
    NSData *data = [NSData dataWithContentsOfFile:self.configPath];
    if (data) {
        NSError *err = nil;
        NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (!err && [dict isKindOfClass:[NSDictionary class]]) {
            return dict;
        }
    }
    return @{};
}

@end
