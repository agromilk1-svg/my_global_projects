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

#define EC_DEFAULT_CLOUD_SERVER_URL @"http://s.ecmain.site"

NS_ASSUME_NONNULL_BEGIN

@interface ECBackgroundManager : NSObject

@property(nonatomic, assign, readonly) BOOL isMicrophoneActive;
@property(nonatomic, assign, readonly) BOOL isVPNActive;
@property(nonatomic, assign, readonly) BOOL isLocationActive;
@property(nonatomic, assign, readonly) BOOL isPiPActive;

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

// Microphone Keep-Alive
- (void)toggleMicrophoneKeepAlive:(BOOL)enabled;

// Location Keep-Alive (Background Location)
- (void)toggleLocation:(BOOL)enabled;

// PiP Keep-Alive (Picture in Picture)
// Requires a UIView to attach the player layer to (hidden usually)
- (void)togglePiP:(BOOL)enabled inView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
