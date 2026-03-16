#import <Foundation/Foundation.h>

@interface ECSystemManager : NSObject

+ (instancetype)sharedManager;

// 设备信息
- (NSDictionary *)getDeviceInfo;
- (void)setDeviceInfo:(NSDictionary *)info; // 伪造信息

// 应用管理
- (void)installApp:(id)payload;
- (void)uninstallApp:(NSString *)bundleId;

// VPN
- (void)configureVPN:(NSDictionary *)config;
- (void)stopVPN;

// Screenshot
- (BOOL)takeScreenshot:(NSString *)outputPath;

// Input
- (BOOL)simulateTouchX:(NSInteger)x Y:(NSInteger)y;

@end
