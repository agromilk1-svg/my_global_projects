//
//  ECBackgroundManager.h
//  ECMAIN
//
//  Created for Background Keep-Alive
//

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreLocation/CoreLocation.h>
#import <Foundation/Foundation.h>

// 固定候选服务器地址列表（心跳失败时自动轮换）
static inline NSArray<NSString *> *ECServerFallbackList(void) {
    return @[
        @"http://s.ecmain.site:8088",
        @"http://l.ecmain.site:8088"
    ];
}

NS_ASSUME_NONNULL_BEGIN

@class UIView;

@interface ECBackgroundManager : NSObject

@property(nonatomic, assign, readonly) BOOL isMicrophoneActive;
@property(nonatomic, assign) BOOL isAudioActive; // 兼容 .m 合成
@property(nonatomic, assign, readonly) BOOL isVPNActive;
@property(nonatomic, assign) BOOL watchdogWdaEnabled;
@property(nonatomic, assign) BOOL isPiPActive;
@property(nonatomic, assign) BOOL isTunnelConnected;
@property(nonatomic, strong, nullable) NSURLSessionWebSocketTask *webSocketTask;

+ (instancetype)sharedManager;
+ (NSString *)deviceUDID;

// VPN Keep-Alive (Network Extension)
- (void)toggleVPN:(BOOL)enabled;
- (void)updateVPNConfiguration;
- (void)connectVPNWithConfig:(NSDictionary *)config;

// Cloud Control (Heartbeat)
- (NSString *)getDeviceIPAddress;
- (void)startCloudHeartbeat;
- (void)sendHeartbeat:(NSString *)urlString;
- (void)handleHeartbeatResponse:(NSData *)data;
- (NSInteger)getLocalEcwdaVersion;
- (BOOL)isVPNActive;

// Microphone Keep-Alive
- (void)toggleMicrophoneKeepAlive:(BOOL)enabled;

// PiP Keep-Alive (Picture in Picture)
// Requires a UIView to attach the player layer to (hidden usually)
- (void)togglePiP:(BOOL)enabled inView:(UIView *)view;

// 后台息屏联网保活 - 确保后台/息屏时网络不中断
- (void)ensureBackgroundNetworkAlive;

// 自动更新专用增强下载器（带重试机制）
- (void)downloadAndUpdateWithURL:(NSURL *)url
                          toPath:(NSString *)targetPath
                      retryCount:(NSInteger)retryCount
                      completion:
                          (void (^)(BOOL success,
                                    NSString *_Nullable filePath))completion;

// 触发自动/手动更新进程 (.tar + RootHelper)
- (void)performSelfUpdate:(NSDictionary *)updateInfo;

@end

NS_ASSUME_NONNULL_END
