//
//  ECBackgroundManager.m
//  ECMAIN
//
//  Created for Background Keep-Alive
//

#import "ECBackgroundManager.h"
#import "../../ECBuildInfo.h"
#import "../../TrollStoreCore/TSApplicationsManager.h"
#import "ECLogManager.h"
#import "ECScriptParser.h"
#import "ECTaskPollManager.h"
#import "ECVPNConfigManager.h"
#import <AVFoundation/AVFoundation.h>
#import <NetworkExtension/NetworkExtension.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <ifaddrs.h>

// 自动更新防重入标志
static BOOL _isUpdating = NO;

@interface ECBackgroundManager () <CLLocationManagerDelegate,
                                   AVPictureInPictureControllerDelegate,
                                   NSURLSessionDataDelegate>

// VPN
@property(nonatomic, strong) NETunnelProviderManager *vpnManager;

// Location
@property(nonatomic, strong) CLLocationManager *locationManager;

// PiP
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic, strong) AVPlayerLayer *playerLayer;
@property(nonatomic, strong) AVPlayer *player;

// Audio
@property(nonatomic, strong) AVAudioRecorder *audioRecorder;

@end

@implementation ECBackgroundManager {
  BOOL _isAudioActive;
  BOOL _isLocationActive;
  BOOL _isPiPActive;
  NSURLSessionWebSocketTask *_webSocketTask;
  BOOL _isTunnelConnected;
  NSURLSessionDataTask *_streamTask;
  NSURLSession *_streamSession;
  NSURLSession *_tunnelSession;
  BOOL _isTunnelConnecting;
  NSTimer *_wsPingTimer; // 30 秒 Ping 保活定时器，防止 TCP 空闲超时
  dispatch_source_t _heartbeatGCDTimer; // 修复 GCD 定时器提前释放的问题
}


+ (instancetype)sharedManager {
  static ECBackgroundManager *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[ECBackgroundManager alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    [self setupVPN]; // Restore auto-setup on launch

    // 默认开启麦克风保活（除非用户手动关闭过）
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"EC_AUTO_MIC_ALIVE"] == nil) {
      [defaults setBool:YES forKey:@"EC_AUTO_MIC_ALIVE"];
      [defaults synchronize];
    }
    if ([defaults boolForKey:@"EC_AUTO_MIC_ALIVE"]) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self toggleMicrophoneKeepAlive:YES];
      });
    }

    // 监听后台/息屏事件，确保联网保活不中断
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(ensureBackgroundNetworkAlive)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];
  }
  return self;
}

#pragma mark - 后台息屏联网保活

- (void)ensureBackgroundNetworkAlive {
  // 综合检查当前保活层状态，若全部未激活则自动启动麦克风保活作为兜底
  if (_isAudioActive) {
    NSLog(@"[ECBackground] ✅ 后台保活已就绪（麦克风录音活跃）");
    return;
  }

  // 麦克风保活是息屏后最强效的持久后台联网手段，自动激活
  NSLog(@"[ECBackground] 🔄 检测到进入后台/息屏，自动激活麦克风保活以维持联网...");
  dispatch_async(dispatch_get_main_queue(), ^{
    [self toggleMicrophoneKeepAlive:YES];
    // 同步刷新用户设置，避免下次启动时被关闭
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setBool:YES forKey:@"EC_AUTO_MIC_ALIVE"];
    [defaults synchronize];
  });
}

#pragma mark - VPN Keep-Alive

- (void)setupVPN {
  [[ECLogManager sharedManager] log:@"[ECBackground] Setting up VPN..."];
  [NETunnelProviderManager
      loadAllFromPreferencesWithCompletionHandler:^(
          NSArray<NETunnelProviderManager *> *_Nullable managers,
          NSError *_Nullable error) {
        if (error) {
          NSLog(@"[ECBackground] Error loading VPN preferences: %@", error);
          [[ECLogManager sharedManager]
              log:@"[ECBackground] Error loading VPN prefs: %@", error];
          return;
        }

        if (managers.count > 0) {
          self.vpnManager = managers.firstObject;
          // 主动派发一次状态通知，让首页同步真实连通状态
          dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                postNotificationName:NEVPNStatusDidChangeNotification
                              object:self.vpnManager.connection];

            // 检查之前是否因为更新而掉线，如果是则自动重连
            NSUserDefaults *updateDefaults =
                [NSUserDefaults standardUserDefaults];
            if ([updateDefaults
                    boolForKey:@"ECMAIN_VPN_WAS_CONNECTED_BEFORE_UPDATE"]) {
              [updateDefaults
                  setBool:NO
                   forKey:@"ECMAIN_VPN_WAS_CONNECTED_BEFORE_UPDATE"];
              [updateDefaults synchronize];
              [[ECLogManager sharedManager]
                  log:@"[ECBackground] 检测到应用刚完成更新且更新前 VPN "
                      @"处于连接状态，将自动恢复连接..."];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                           (int64_t)(1.5 * NSEC_PER_SEC)),
                             dispatch_get_main_queue(), ^{
                               [self startVPN];
                             });
            }
          });
        }
        // Always ensure configuration is up to date and saved
        [self updateVPNConfiguration];
      }];

  // Observer for VPN status changes
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(vpnStatusDidChange:)
             name:NEVPNStatusDidChangeNotification
           object:nil];
}

- (void)connectVPNWithConfig:(NSDictionary *)config {
  [[ECLogManager sharedManager]
      log:@"[ECBackground] connectVPNWithConfig: %@", config];

  // 1. Save config to App Group so Tunnel can read it
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  [defaults setObject:config forKey:@"VPNConfig"];
  [defaults synchronize];

  // 2. Check if VPN is active and stop it if necessary
  if ([self isVPNActive]) {
    [[ECLogManager sharedManager] log:@"[ECBackground] Switching VPN Config "
                                      @"(Stopping current session)..."];
    [self stopVPN];

    // Give it a moment to stop completely before restarting
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [self _applyConfigAndStart];
        });
  } else {
    [self _applyConfigAndStart];
  }
}

- (void)_applyConfigAndStart {
  [self updateVPNConfigurationWithCompletion:^(BOOL success) {
    if (success) {
      [[ECLogManager sharedManager]
          log:@"[ECBackground] Config applied. Starting VPN..."];
      // Slightly delayed start to ensure preferences flush
      dispatch_after(
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
          dispatch_get_main_queue(), ^{
            [self startVPN];
          });
    } else {
      [[ECLogManager sharedManager]
          log:@"[ECBackground] Failed to apply config. Aborting start."];
    }
  }];
}

- (void)updateVPNConfiguration {
  [self updateVPNConfigurationWithCompletion:nil];
}

- (void)updateVPNConfigurationWithCompletion:
    (void (^)(BOOL success))completion {
  [NETunnelProviderManager
      loadAllFromPreferencesWithCompletionHandler:^(
          NSArray<NETunnelProviderManager *> *_Nullable managers,
          NSError *_Nullable error) {
        if (error) {
          [[ECLogManager sharedManager]
              log:@"[ECBackground] Error loading VPN prefs: %@", error];
          if (completion)
            completion(NO);
          return;
        }

        NETunnelProviderManager *manager;
        if (managers.count > 0) {
          manager = managers.firstObject;
        } else {
          manager = [[NETunnelProviderManager alloc] init];
        }

        [manager loadFromPreferencesWithCompletionHandler:^(
                     NSError *_Nullable error) {
          if (error) {
            [[ECLogManager sharedManager]
                log:@"[ECBackground] Failed to re-load VPN prefs: %@", error];
            // Don't abort, try to continue
          }

          NETunnelProviderProtocol *protocol =
              [[NETunnelProviderProtocol alloc] init];
          protocol.providerBundleIdentifier = @"com.ecmain.app.Tunnel";

          // 1. 服务器名称 (Server)
          protocol.serverAddress = @"ECMAIN";

          // 2. 账户名称 (Account) - Shadowrocket 风格
          protocol.username = @"ECMAIN Proxy";

          // CRITICAL: Pass config via providerConfiguration
          NSUserDefaults *defaults = [[NSUserDefaults alloc]
              initWithSuiteName:@"group.com.ecmain.shared"];
          NSDictionary *vpnConfig = [defaults dictionaryForKey:@"VPNConfig"];

          // 添加额外元数据以模仿 Shadowrocket 丰富度
          NSMutableDictionary *enhancedConfig =
              [vpnConfig mutableCopy] ?: [NSMutableDictionary dictionary];
          enhancedConfig[@"gui_mode"] = @"shadowrocket_style";

          // 将前置代理节点完整配置嵌入，避免 Tunnel 扩展查找失败
          NSString *throughID = enhancedConfig[@"proxy_through_id"];
          if (throughID.length > 0) {
            NSDictionary *throughNode =
                [[ECVPNConfigManager sharedManager] nodeWithID:throughID];
            if (throughNode) {
              enhancedConfig[@"proxy_through_node"] = throughNode;
              NSLog(@"[ECBackground] 嵌入前置代理节点: %@",
                    throughNode[@"server"]);
            } else {
              NSLog(@"[ECBackground] ⚠️ 前置代理节点未找到: %@", throughID);
            }
          }

          if (vpnConfig) {
            protocol.providerConfiguration = enhancedConfig;
          }

          manager.protocolConfiguration = protocol;
          manager.localizedDescription = @"ECMAIN Proxy"; // Profile Name
          manager.enabled = YES;

          [manager saveToPreferencesWithCompletionHandler:^(
                       NSError *_Nullable error) {
            if (error) {
              NSLog(@"[ECBackground] Failed to save VPN prefs: %@", error);
              [[ECLogManager sharedManager]
                  log:@"[ECBackground] Failed to save VPN prefs: %@", error];
              if (completion)
                completion(NO);
            } else {
              NSLog(@"[ECBackground] VPN Configuration Saved Successfully.");
              self.vpnManager = manager;
              if (completion)
                completion(YES);
            }
          }];
        }];
      }];
}

- (void)startVPN {
  [[ECLogManager sharedManager]
      log:@"[ECBackground] startVPN called (User Action)"];

  if (!self.vpnManager) {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] VPN Manager not ready, setting up..."];
    [self setupVPN];
    // Retry after a short delay
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [self startVPNInternal];
        });
    return;
  }

  [self startVPNInternal];
}

- (void)startVPNInternal {
  if (!self.vpnManager) {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] ERROR: VPN Manager still nil!"];
    return;
  }

  // 严格拦截：判断设备上是否存在真实的代理节点或下发的有效配置
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSDictionary *vpnConfig = [defaults dictionaryForKey:@"VPNConfig"];
  BOOL hasNodes = ([[ECVPNConfigManager sharedManager] allNodes].count > 0);
  BOOL hasValidConfig = NO;
  if (vpnConfig && [vpnConfig isKindOfClass:[NSDictionary class]]) {
    if (vpnConfig[@"proxies"] || vpnConfig[@"server"] || vpnConfig[@"type"] ||
        vpnConfig[@"url"] || vpnConfig[@"proxy_through_id"]) {
      hasValidConfig = YES;
    }
  }

  if (!hasNodes && !hasValidConfig) {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] 🚫 "
            @"设备目前未分配任何节点配置，拒绝盲目拔号以防止虚假连通。"];
    // 清理幽灵标记
    [[NSUserDefaults standardUserDefaults]
        setBool:NO
         forKey:@"ECMAIN_VPN_WAS_CONNECTED_BEFORE_UPDATE"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    return;
  }

  // Log current status
  [[ECLogManager sharedManager] log:@"[ECBackground] Current Status: %ld",
                                    (long)self.vpnManager.connection.status];

  if (self.vpnManager.connection.status == NEVPNStatusConnected) {
    [[ECLogManager sharedManager] log:@"[ECBackground] VPN already connected."];
    return;
  }

  NSError *error = nil;
  if ([self.vpnManager.connection
          isKindOfClass:[NETunnelProviderSession class]]) {
    NETunnelProviderSession *session =
        (NETunnelProviderSession *)self.vpnManager.connection;
    [[ECLogManager sharedManager]
        log:@"[ECBackground] Starting tunnel session..."];
    [session startTunnelWithOptions:nil andReturnError:&error];
  } else {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] Starting generic tunnel..."];
    [self.vpnManager.connection startVPNTunnelAndReturnError:&error];
  }

  if (error) {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] ❌ Failed to start VPN: %@", error];
  } else {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] ✅ VPN Start Requested."];
  }
}

- (void)stopVPN {
  NSLog(@"[ECBackground] Stopping VPN...");
  [self.vpnManager.connection stopVPNTunnel];
  // Auto-stop logic REMOVED as per user request
}

- (void)vpnStatusDidChange:(NSNotification *)notification {
  NEVPNConnection *connection = self.vpnManager.connection;
  NSLog(@"[ECBackground] VPN Status Changed: %ld", (long)connection.status);

  if (connection.status == NEVPNStatusDisconnected) {
    NSLog(@"[ECBackground] VPN Disconnected.");
  }
}

// Replaces toggleAudio exposed method
- (void)toggleVPN:(BOOL)enabled {
  // We repurpose this call from the UI/Controller to toggle VPN instead
  if (enabled) {
    [self startVPN];
  } else {
    [self stopVPN];
  }
}

- (BOOL)isVPNActive {
  if (!self.vpnManager)
    return NO;
  return self.vpnManager.connection.status == NEVPNStatusConnected ||
         self.vpnManager.connection.status == NEVPNStatusConnecting;
}

#pragma mark - Microphone Keep-Alive

- (void)toggleMicrophoneKeepAlive:(BOOL)enabled {
  if (enabled) {
    if (self.audioRecorder && self.audioRecorder.isRecording) {
      return;
    }

    NSLog(@"[ECBackground] Starting Microphone Keep-Alive...");

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;

    // Use PlayAndRecord to allow background persistence
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                         AVAudioSessionCategoryOptionAllowBluetooth
                   error:&error];
    if (error)
      NSLog(@"[ECBackground] AudioSession Error 1: %@", error);

    [session setActive:YES error:&error];
    if (error)
      NSLog(@"[ECBackground] AudioSession Error 2: %@", error);

    // Record to a temp file
    NSString *tempDir = NSTemporaryDirectory();
    NSString *soundFilePath =
        [tempDir stringByAppendingPathComponent:@"keepalive.caf"];
    NSURL *soundFileURL = [NSURL fileURLWithPath:soundFilePath];

    NSDictionary *recordSettings = @{
      AVFormatIDKey : @(kAudioFormatAppleIMA4),
      AVSampleRateKey : @44100.0f,
      AVNumberOfChannelsKey : @1,
      AVEncoderBitDepthHintKey : @16,
      AVEncoderAudioQualityKey : @(AVAudioQualityLow)
    };

    self.audioRecorder = [[AVAudioRecorder alloc] initWithURL:soundFileURL
                                                     settings:recordSettings
                                                        error:&error];
    if (error) {
      NSLog(@"[ECBackground] Recorder Init Error: %@", error);
      return;
    }

    [self.audioRecorder prepareToRecord];
    BOOL success = [self.audioRecorder record];

    if (success) {
      _isAudioActive = YES;
      NSLog(@"[ECBackground] 🎙️ Microphone Keep-Alive STARTED (Recording)");
    } else {
      NSLog(@"[ECBackground] ❌ Failed to start recording");
    }

  } else {
    if (self.audioRecorder) {
      [self.audioRecorder stop];
      self.audioRecorder = nil;
    }

    [[AVAudioSession sharedInstance]
          setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
              error:nil];

    _isAudioActive = NO;
    NSLog(@"[ECBackground] 🛑 Microphone Keep-Alive STOPPED");
  }
}

- (BOOL)isMicrophoneActive {
  return _isAudioActive;
}

#pragma mark - Location Keep-Alive

- (void)toggleLocation:(BOOL)enabled {
  _isLocationActive = enabled;

  if (enabled) {
    if (!self.locationManager) {
      self.locationManager = [[CLLocationManager alloc] init];
      self.locationManager.delegate = self;
      self.locationManager.desiredAccuracy = kCLLocationAccuracyThreeKilometers;
      self.locationManager.allowsBackgroundLocationUpdates = YES;
      self.locationManager.pausesLocationUpdatesAutomatically = NO;
    }

    [self.locationManager requestAlwaysAuthorization];
    [self.locationManager startUpdatingLocation];
    NSLog(@"[ECBackground] Location Keep-Alive STARTED");
  } else {
    [self.locationManager stopUpdatingLocation];
    NSLog(@"[ECBackground] Location Keep-Alive STOPPED");
  }
}

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {
  // Do nothing, just keep alive
}

#pragma mark - PiP Keep-Alive

- (void)togglePiP:(BOOL)enabled inView:(UIView *)view {
  if (enabled) {
    if (!self.pipController) {
      if (![AVPictureInPictureController isPictureInPictureSupported]) {
        NSLog(@"[ECBackground] PiP not supported on this device");
        return;
      }
      NSURL *videoURL = [[NSBundle mainBundle] URLForResource:@"dummy"
                                                withExtension:@"mp4"];
      if (!videoURL) {
        NSLog(@"[ECBackground] PiP Video 'dummy.mp4' not found!");
        return;
      }

      self.player = [AVPlayer playerWithURL:videoURL];
      self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
      self.playerLayer.frame = CGRectMake(0, 0, 1, 1);
      self.playerLayer.hidden = YES;
      if (view) {
        [view.layer addSublayer:self.playerLayer];
      }

      self.pipController = [[AVPictureInPictureController alloc]
          initWithPlayerLayer:self.playerLayer];
      self.pipController.delegate = self;
    }

    if (self.pipController.isPictureInPictureActive) {
      return;
    }

    [self.player play];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          [self.pipController startPictureInPicture];
          _isPiPActive = YES;
          NSLog(@"[ECBackground] PiP Keep-Alive STARTED");
        });

  } else {
    [self.pipController stopPictureInPicture];
    [self.player pause];
    _isPiPActive = NO;
    NSLog(@"[ECBackground] PiP Keep-Alive STOPPED");
  }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
  NSLog(@"[ECBackground] PiP Did Start");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:
    (AVPictureInPictureController *)pictureInPictureController {
  NSLog(@"[ECBackground] PiP Did Stop");
  _isPiPActive = NO;
}

// 旧版心跳已拔除，由 ECBackgroundManager_Heartbeat 分出类别接管

#pragma mark - WebSocket Tunnel

// Dedicated dispatch queue for all WebSocket operations
static dispatch_queue_t _tunnelQueue = nil;
// Cached device UDID (initialized on main queue at first access)
static NSString *_cachedDeviceUDID = nil;

+ (dispatch_queue_t)tunnelQueue {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    _tunnelQueue =
        dispatch_queue_create("com.ecmain.tunnel", DISPATCH_QUEUE_SERIAL);
  });
  return _tunnelQueue;
}

// Helper for Persistent UDID
+ (NSString *)getPersistentUUID {
  NSString *udid = nil;
  void *lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
  if (lib) {
    CFTypeRef (*_MGCopyAnswer)(CFStringRef) = dlsym(lib, "MGCopyAnswer");
    if (_MGCopyAnswer) {
      CFStringRef uniqueId =
          (CFStringRef)_MGCopyAnswer(CFSTR("UniqueDeviceID"));
      if (uniqueId) {
        udid = [NSString stringWithString:(__bridge NSString *)uniqueId];
        CFRelease(uniqueId);
      }
    }
    dlclose(lib);
  }

  if (udid) {
    return udid;
  }

  // 降级保护：如果由于某种原因未能读取到工厂 UDID，退回 vendor id
  return [[[UIDevice currentDevice] identifierForVendor] UUIDString]
             ?: [[NSUUID UUID] UUIDString];
}
// Get cached UDID - Uses Keychain for persistence
+ (NSString *)deviceUDID {
  // This static is set once and never changes
  if (!_cachedDeviceUDID) {
    _cachedDeviceUDID = [self getPersistentUUID];
  }
  return _cachedDeviceUDID;
}

// 获取持久化 NSURLSession（单例，永不销毁，避免内部状态竞态崩溃）
- (NSURLSession *)_persistentTunnelSession {
  static NSURLSession *session = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSOperationQueue *wsQueue = [[NSOperationQueue alloc] init];
    wsQueue.maxConcurrentOperationCount = 1;
    wsQueue.name = @"com.ecmain.websocket";

    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    // 120 秒超时，避免正常 heartbeat 间隔内误触超时
    config.timeoutIntervalForRequest = 120.0;
    config.timeoutIntervalForResource = 600.0;

    session = [NSURLSession sessionWithConfiguration:config
                                            delegate:self
                                       delegateQueue:wsQueue];
  });
  return session;
}

// 启动 WebSocket Ping 保活定时器（每 30 秒发送一次 Ping 帧）
// 这是防止 iOS 15 上 CFNetwork 底层 TCP 空闲 60 秒后被系统回收的关键措施
- (void)_startPingTimer {
  [self _stopPingTimer];
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_wsPingTimer = [NSTimer
        scheduledTimerWithTimeInterval:30.0
                               repeats:YES
                                 block:^(NSTimer *_Nonnull timer) {
                                   NSURLSessionWebSocketTask *task = nil;
                                   @synchronized(self) {
                                     task = self->_webSocketTask;
                                   }
                                   if (task) {
                                     // 使用系统原生 Ping，不走应用层数据通道
                                     [task sendPingWithPongReceiveHandler:^(
                                               NSError *_Nullable error) {
                                       if (error) {
                                         NSLog(@"[Tunnel] Ping 失败: %@",
                                               error.localizedDescription);
                                       }
                                     }];
                                   } else {
                                     // task 已经没了，停止定时器
                                     [self _stopPingTimer];
                                   }
                                 }];
  });
}

// 停止 Ping 定时器
- (void)_stopPingTimer {
  dispatch_async(dispatch_get_main_queue(), ^{
    [self->_wsPingTimer invalidate];
    self->_wsPingTimer = nil;
  });
}

// 安排重连（统一入口，60 秒间隔）
- (void)_scheduleReconnectWithDelay:(NSTimeInterval)delay {
  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:@"[Tunnel] %.0f秒后尝试重连...", delay]];
  });

  __unsafe_unretained typeof(self) weakSelf = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [weakSelf startTunnel];
      });
}

- (void)startTunnel {
  dispatch_async([ECBackgroundManager tunnelQueue], ^{
    @synchronized(self) {
      if (self->_isTunnelConnecting || self->_isTunnelConnected) {
        return;
      }
      // 如果已经有 task 在等待握手，也不要重复创建
      if (self->_webSocketTask) {
        return;
      }
      self->_isTunnelConnecting = YES;
      // 仅 Cancel 旧 Task，绝不触碰 Session
      if (self->_webSocketTask) {
        [self->_webSocketTask
            cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure
                         reason:nil];
        self->_webSocketTask = nil;
      }
    }

    NSString *rawUrl = [self getBaseURL];
    NSURLComponents *components = [NSURLComponents componentsWithString:rawUrl];
    if (!components.scheme || components.scheme.length == 0) {
      components = [NSURLComponents
          componentsWithString:[NSString
                                   stringWithFormat:@"https://%@", rawUrl]];
    }
    if ([components.scheme.lowercaseString isEqualToString:@"https"] ||
        [components.scheme.lowercaseString isEqualToString:@"wss"]) {
      components.scheme = @"wss";
    } else {
      components.scheme = @"ws";
    }
    NSString *baseUrl = components.URL.absoluteString;
    if (!baseUrl || baseUrl.length == 0) {
      baseUrl = [EC_DEFAULT_CLOUD_SERVER_URL
          stringByReplacingOccurrencesOfString:@"https://"
                                    withString:@"wss://"];
    }

    // Get cached UDID (initialized on main queue)
    NSString *udid = [ECBackgroundManager deviceUDID];
    if (!udid || udid.length == 0) {
      // UDID not yet initialized, retry from main queue
      dispatch_async(dispatch_get_main_queue(), ^{
        // Force initialization
        (void)[ECBackgroundManager deviceUDID];
        // Retry tunnel connection after a short delay
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              @synchronized(self) {
                self->_isTunnelConnecting = NO;
              }
              [self startTunnel];
            });
      });
      return;
    }

    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    NSString *savedNo = [defaults stringForKey:@"EC_DEVICE_NO"];
    NSString *deviceKey = savedNo.length > 0 ? savedNo : udid;

    NSString *wsUrl =
        [NSString stringWithFormat:@"%@/tunnel/ws/%@", baseUrl, deviceKey];

    NSString *wsUrlEscaped =
        [wsUrl stringByAddingPercentEncodingWithAllowedCharacters:
                   [NSCharacterSet URLQueryAllowedCharacterSet]];

    if (!wsUrlEscaped) {
      NSLog(@"[Tunnel] Failed to escape URL: %@", wsUrl);
      @synchronized(self) {
        self->_isTunnelConnecting = NO;
      }
      [self _scheduleReconnectWithDelay:60.0];
      return;
    }

    @synchronized(self) {
      self->_tunnelSession = [self _persistentTunnelSession];

      NSURL *targetURL = [NSURL URLWithString:wsUrlEscaped];
      if (!targetURL) {
        NSLog(@"[Tunnel] Invalid escaped URL: %@", wsUrlEscaped);
        self->_isTunnelConnecting = NO;
        [self _scheduleReconnectWithDelay:60.0];
        return;
      }
      self->_webSocketTask =
          [self->_tunnelSession webSocketTaskWithURL:targetURL];
      [self->_webSocketTask resume];
      // 注意：不在此处设置 _isTunnelConnected = YES 或 _isTunnelConnecting =
      // NO！ 必须等待 didOpenWithProtocol: 回调确认 WebSocket
      // 握手完成后才能操作 task 保持 _isTunnelConnecting = YES
      // 防止心跳定时器在握手期间重复触发
    }
  });
}

// NSURLSessionWebSocketDelegate
- (void)URLSession:(NSURLSession *)session
          webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didOpenWithProtocol:(NSString *)protocol {
  // WebSocket HTTP Upgrade 握手已完成，现在可以安全地操作 task
  @synchronized(self) {
    // 忽略来自旧 task 的回调
    if (self->_webSocketTask != webSocketTask) {
      return;
    }
    self->_isTunnelConnected = YES;
    self->_isTunnelConnecting = NO;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECLogManager sharedManager] log:@"[Tunnel] ✅ WebSocket 已连接！"];
  });

  // 握手完成后才开始监听消息和 Ping 保活
  [self receiveTunnelMessage];
  [self _startPingTimer];
}

- (void)URLSession:(NSURLSession *)session
       webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
    didCloseWithCode:(NSURLSessionWebSocketCloseCode)code
              reason:(NSData *)reason {
  NSString *reasonStr = nil;
  if (reason) {
    reasonStr = [[NSString alloc] initWithData:reason
                                      encoding:NSUTF8StringEncoding];
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECLogManager sharedManager]
        log:[NSString stringWithFormat:
                          @"[Tunnel] ❌ WebSocket 断开 (Code: %ld, Reason: %@)",
                          (long)code, reasonStr ?: @"Unknown"]];
  });

  @synchronized(self) {
    // 忽略来自旧 task 的回调
    if (self->_webSocketTask != webSocketTask) {
      return;
    }
    self->_webSocketTask = nil;
    self->_isTunnelConnected = NO;
    self->_isTunnelConnecting = NO;
  }
  [self _stopPingTimer];

  // 60秒后重连
  [self _scheduleReconnectWithDelay:60.0];
}

// 处理 session 级别的连接错误（如 TLS 握手失败、DNS 解析失败、超时等）
- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  // 先处理 streamTask 的清理
  @synchronized(self) {
    if (task == _streamTask) {
      _streamTask = nil;
    }
  }

  if (!error)
    return;

  // 忽略主动取消的错误
  if (error.code == NSURLErrorCancelled)
    return;

  NSLog(@"[Tunnel] 连接任务完成，错误: %@", error.localizedDescription);

  @synchronized(self) {
    // 忽略来自旧 task 的回调
    if (task != self->_webSocketTask)
      return;

    self->_webSocketTask = nil;
    self->_isTunnelConnected = NO;
    self->_isTunnelConnecting = NO;
  }
  [self _stopPingTimer];

  // 60秒后重连
  [self _scheduleReconnectWithDelay:60.0];
}

// session 被 invalidate 后的清理回调（安全钩子）
- (void)URLSession:(NSURLSession *)session
    didBecomeInvalidWithError:(NSError *)error {
  NSLog(@"[Tunnel] Session 已失效 %@",
        error ? error.localizedDescription : @"(正常)");
}

// Receive message loop
- (void)receiveTunnelMessage {
  NSURLSessionWebSocketTask *currentTask = nil;
  @synchronized(self) {
    currentTask = self->_webSocketTask;
  }
  if (!currentTask)
    return;

  __unsafe_unretained typeof(self) weakSelf = self;

  [currentTask receiveMessageWithCompletionHandler:^(
                   NSURLSessionWebSocketMessage *_Nullable message,
                   NSError *_Nullable error) {
    ECBackgroundManager *strongSelf = weakSelf;
    if (!strongSelf)
      return;

    // 如果此任务已经不是当前激活的最新任务，则立刻剪断闭环，放弃处理
    @synchronized(strongSelf) {
      if (strongSelf->_webSocketTask != currentTask) {
        return;
      }
    }

    if (error) {
      @synchronized(strongSelf) {
        if (strongSelf->_webSocketTask == currentTask) {
          // 仅解除引用，不调用 cancel
          strongSelf->_webSocketTask = nil;
          strongSelf->_isTunnelConnected = NO;
          strongSelf->_isTunnelConnecting = NO;
        }
      }
      [strongSelf _stopPingTimer];

      // 60秒后重连
      [strongSelf _scheduleReconnectWithDelay:60.0];
      return;
    }

    if (message.type == NSURLSessionWebSocketMessageTypeString) {
      NSString *msgStr = message.string;
      // Truncate long messages for logging
      NSString *logMsg =
          msgStr.length > 100 ? [msgStr substringToIndex:100] : msgStr;

      // Log received message (on main queue for UI logging)
      dispatch_async(dispatch_get_main_queue(), ^{
        [[ECLogManager sharedManager]
            log:[NSString stringWithFormat:@"[Tunnel] 收到消息: %@", logMsg]];
      });

      NSData *data = [msgStr dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil];
      if (json) {
        [weakSelf handleTunnelRequest:json];
      }
    }

    [weakSelf receiveTunnelMessage]; // Keep listening
  }];
}

- (void)handleTunnelRequest:(NSDictionary *)req {
  NSString *reqId = req[@"id"];
  NSString *method = req[@"method"];
  NSString *url = req[@"url"]; // Target URL
  NSDictionary *body = req[@"body"];

  // Log request details (skip noisy screenshot requests)
  BOOL isScreenshotRequest = url && [url containsString:@"screenshot"];

  if (!isScreenshotRequest) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [[ECLogManager sharedManager]
          log:[NSString stringWithFormat:@"[Tunnel] 处理请求: %@ %@", method,
                                         url ? url : @"(No URL)"]];
    });
  }

  // Validate required fields
  if (!reqId || !method || !url) {
    if (![method isEqualToString:@"START_STREAM"] &&
        ![method isEqualToString:@"STOP_STREAM"]) {
      NSLog(@"[Tunnel] Invalid request: missing id/method/url");
      return;
    }
  }

  // Streaming Interception
  if ([method isEqualToString:@"START_STREAM"]) {
    [self startMJPEGStream:url];
    // Send ack
    NSDictionary *resp = @{
      @"type" : @"response",
      @"id" : reqId,
      @"status" : @200,
      @"body" : @{@"status" : @"started"}
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:resp
                                                options:0
                                                  error:nil];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc]
                                    initWithString:
                                        [[NSString alloc]
                                            initWithData:d
                                                encoding:NSUTF8StringEncoding]]
              completionHandler:nil];
    return;
  }
  if ([method isEqualToString:@"STOP_STREAM"]) {
    [self stopMJPEGStream];
    // Send ack
    NSDictionary *resp = @{
      @"type" : @"response",
      @"id" : reqId,
      @"status" : @200,
      @"body" : @{@"status" : @"stopped"}
    };
    NSData *d = [NSJSONSerialization dataWithJSONObject:resp
                                                options:0
                                                  error:nil];
    [self.webSocketTask sendMessage:[[NSURLSessionWebSocketMessage alloc]
                                    initWithString:
                                        [[NSString alloc]
                                            initWithData:d
                                                encoding:NSUTF8StringEncoding]]
              completionHandler:nil];
    return;
  }

  // ========== 截图请求专用高速通道（极致压缩，适配慢速 VPN/Cloudflare 网络） ==========
  if (isScreenshotRequest) {
    __unsafe_unretained typeof(self) weakSelf = self;
    NSURL *targetURL = [NSURL URLWithString:url];
    if (!targetURL) {
      NSLog(@"[Tunnel] 截图 URL 无效: %@", url);
      return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:targetURL];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 5.0;

    [[NSURLSession.sharedSession
        dataTaskWithRequest:request
          completionHandler:^(NSData *_Nullable data,
                              NSURLResponse *_Nullable response,
                              NSError *_Nullable error) {
            dispatch_async([ECBackgroundManager tunnelQueue], ^{
              __strong typeof(weakSelf) strongSelf = weakSelf;
              if (!strongSelf || !strongSelf.webSocketTask) return;

              NSMutableDictionary *respPayload = [NSMutableDictionary dictionary];
              respPayload[@"type"] = @"response";
              respPayload[@"id"] = reqId;

              if (error || !data) {
                respPayload[@"status"] = @500;
                respPayload[@"body"] = @{@"error" : error.localizedDescription ?: @"无数据"};
              } else {
                // WDA 的 /screenshot 返回 JSON: {"value": "<base64 PNG>", ...}
                // 先解析 JSON 以提取 base64 原始数据
                NSDictionary *wdaJSON = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                NSString *b64PNG = nil;
                if (wdaJSON && wdaJSON[@"value"]) {
                  b64PNG = wdaJSON[@"value"];
                }

                if (b64PNG) {
                  // 将 Base64 PNG 解码成 UIImage，缩小并压缩为超低质量 JPEG
                  NSData *pngData = [[NSData alloc] initWithBase64EncodedString:b64PNG options:NSDataBase64DecodingIgnoreUnknownCharacters];
                  UIImage *fullImage = pngData ? [UIImage imageWithData:pngData] : nil;

                  if (fullImage) {
                    // 缩小到 50% 分辨率以大幅减少像素数
                    CGFloat scaleFactor = 0.5;
                    CGSize newSize = CGSizeMake(fullImage.size.width * scaleFactor,
                                               fullImage.size.height * scaleFactor);
                    UIGraphicsBeginImageContextWithOptions(newSize, YES, 1.0);
                    [fullImage drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
                    UIImage *resizedImage = UIGraphicsGetImageFromCurrentImageContext();
                    UIGraphicsEndImageContext();

                    // 压缩为极低质量 JPEG (quality=0.15), 约 30-80KB
                    NSData *jpegData = UIImageJPEGRepresentation(resizedImage ?: fullImage, 0.15);
                    NSString *b64JPEG = [jpegData base64EncodedStringWithOptions:0];

                    respPayload[@"status"] = @200;
                    respPayload[@"body"] = @{@"value" : b64JPEG ?: @""};
                  } else {
                    // 解码失败，原样回传（降级）
                    respPayload[@"status"] = @200;
                    respPayload[@"body"] = wdaJSON ?: @{@"error": @"decode_fail"};
                  }
                } else {
                  // 非标准格式，原样回传
                  NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                  respPayload[@"status"] = @(httpResp ? httpResp.statusCode : 500);
                  respPayload[@"body"] = wdaJSON ?: @{@"error": @"no_value_field"};
                }
              }

              // 通过 WebSocket 回传压缩后的截图
              NSData *respData = [NSJSONSerialization dataWithJSONObject:respPayload options:0 error:nil];
              if (!respData) return;
              NSString *respStr = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
              [strongSelf.webSocketTask
                        sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:respStr]
                  completionHandler:^(NSError *_Nullable sendError) {
                    if (sendError)
                      NSLog(@"[Tunnel] 截图回传失败: %@", sendError);
                  }];
            });
          }] resume];
    return;
  }

  // ========== 通用请求透传通道 ==========
  NSURL *targetURL = [NSURL URLWithString:url];
  if (!targetURL) {
    // 拦截后端的实时推流唤醒信号，实现脚本秒杀下发
    if ([url isEqualToString:@"/api/wakeup_task"]) {
      static NSTimeInterval lastWakeTime = 0;
      NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
      
      dispatch_async(dispatch_get_main_queue(), ^{
        if (now - lastWakeTime < 5.0) {
            return;
        }
        lastWakeTime = now;
        
        [[ECLogManager sharedManager]
            log:@"[Tunnel] 收到实时任务推流波！开始本地即刻执行..."];
        NSDictionary *resp = @{
          @"type" : @"response",
          @"id" : reqId,
          @"status" : @200,
          @"body" : @{@"status" : @"wake_ok"}
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:resp
                                                    options:0
                                                      error:nil];
        [self->_webSocketTask
                  sendMessage:
                      [[NSURLSessionWebSocketMessage alloc]
                          initWithString:[[NSString alloc]
                                             initWithData:d
                                                 encoding:NSUTF8StringEncoding]]
            completionHandler:nil];

        if (body && body[@"script"]) {
          NSDictionary *mockJson = @{
            @"task" : @{
              @"id" : @(999999),
              @"type" : @"script",
              @"script" : body[@"script"]
            }
          };
          NSData *mockData = [NSJSONSerialization dataWithJSONObject:mockJson
                                                             options:0
                                                               error:nil];
          [self handleHeartbeatResponse:mockData];
        } else {
          [self sendHeartbeat:nil];
        }
      });
      return;
    }

    NSLog(@"[Tunnel] Invalid URL: %@", url);
    return;
  }

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:targetURL];
  request.HTTPMethod = method;
  if (body && [body isKindOfClass:[NSDictionary class]]) {
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body
                                                       options:0
                                                         error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  request.timeoutInterval = 5.0;

  __unsafe_unretained typeof(self) weakSelf = self;
  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          dispatch_async([ECBackgroundManager tunnelQueue], ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.webSocketTask) {
              NSLog(
                  @"[Tunnel] Self or WebSocket deallocated, skipping response");
              return;
            }

            NSMutableDictionary *respPayload = [NSMutableDictionary dictionary];
            respPayload[@"type"] = @"response";
            respPayload[@"id"] = reqId;

            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            respPayload[@"status"] = @(httpResp ? httpResp.statusCode : 500);

            if (error) {
              respPayload[@"body"] =
                  @{@"error" : error.localizedDescription ?: @"Unknown error"};
            } else if (data) {
              id jsonBody = [NSJSONSerialization JSONObjectWithData:data
                                                            options:0
                                                              error:nil];
              if (jsonBody) {
                respPayload[@"body"] = jsonBody;
              } else {
                respPayload[@"body"] =
                    @{@"value" : [data base64EncodedStringWithOptions:0]};
              }
            }

            NSError *jsonError = nil;
            NSData *respData =
                [NSJSONSerialization dataWithJSONObject:respPayload
                                                options:0
                                                  error:&jsonError];
            if (!respData) {
              NSLog(@"[Tunnel] Failed to serialize response: %@", jsonError);
              return;
            }

            NSString *respStr =
                [[NSString alloc] initWithData:respData
                                      encoding:NSUTF8StringEncoding];
            NSURLSessionWebSocketMessage *wsMsg =
                [[NSURLSessionWebSocketMessage alloc] initWithString:respStr];

            [strongSelf.webSocketTask
                      sendMessage:wsMsg
                completionHandler:^(NSError *_Nullable sendError) {
                  if (sendError)
                    NSLog(@"[Tunnel] Send Error: %@", sendError);
                }];
          });
        }] resume];
}

#pragma mark - Streaming

static BOOL _isStreamingActive = NO;

- (void)startMJPEGStream:(NSString *)urlString {
  // MJPEG streaming via WebSocket tunnel is disabled due to iOS
  // NSURLSession/NSOperationQueue threading issues that cause EXC_BAD_ACCESS.
  // Backend should automatically fall back to screenshot polling mode.
  dispatch_async(dispatch_get_main_queue(), ^{
    [[ECLogManager sharedManager]
        log:@"[Stream] ⚠️ MJPEG隧道暂不可用，请使用截图模式"];
  });
  NSLog(@"[Stream] MJPEG tunnel forwarding disabled - use screenshot mode");
}

- (void)stopMJPEGStream {
  @synchronized(self) {
    _isStreamingActive = NO;
    if (_streamTask) {
      [_streamTask cancel];
      _streamTask = nil;
      NSLog(@"[Tunnel] Stopped MJPEG Stream");
    }
    if (_streamSession) {
      [_streamSession invalidateAndCancel];
      _streamSession = nil;
    }
  }
}

// 旧的 stream 错误处理已合并到新的 URLSession:task:didCompleteWithError: 方法中

// Property synthesis for weak reference access - SYNCHRONIZED
- (void)setWebSocketTask:(NSURLSessionWebSocketTask *)task {
  @synchronized(self) {
    _webSocketTask = task;
  }
}
- (NSURLSessionWebSocketTask *)webSocketTask {
  @synchronized(self) {
    return _webSocketTask;
  }
}
- (void)setIsTunnelConnected:(BOOL)connected {
  @synchronized(self) {
    _isTunnelConnected = connected;
  }
}

- (NSString *)getBaseURL {
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  if (!savedUrl || savedUrl.length == 0)
    return EC_DEFAULT_CLOUD_SERVER_URL;

  // Strip trailing slash
  if ([savedUrl hasSuffix:@"/"]) {
    savedUrl = [savedUrl substringToIndex:savedUrl.length - 1];
  }

  // Strip commonly mistakenly entered paths to extract base
  if ([savedUrl hasSuffix:@"/devices/heartbeat"]) {
    savedUrl =
        [savedUrl stringByReplacingOccurrencesOfString:@"/devices/heartbeat"
                                            withString:@""];
  }

  return savedUrl;
}

- (NSString *)getDeviceIPAddress {
  NSString *address = @"error";
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = 0;
  // retrieve the current interfaces - returns 0 on success
  success = getifaddrs(&interfaces);
  if (success == 0) {
    // Loop through linked list of interfaces
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr->sa_family == AF_INET) {
        // Check if interface is en0 which is the wifi connection on the iPhone
        if ([[NSString stringWithUTF8String:temp_addr->ifa_name]
                isEqualToString:@"en0"]) {
          // Get NSString from C String
          address =
              [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)
                                                            temp_addr->ifa_addr)
                                                           ->sin_addr)];
        }
      }
      temp_addr = temp_addr->ifa_next;
    }
  }
  // Free memory
  freeifaddrs(interfaces);
  return address;
}

#pragma mark - Cloud Control (Heartbeat)

- (void)startCloudHeartbeat {
  [[ECLogManager sharedManager]
      log:@"[ECBackground] Starting Cloud Heartbeat Loop..."];

  // Retrieve correct URL and Device Name from App Group Defaults
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;
  NSString *serverUrl = [baseUrl stringByAppendingString:@"/devices/heartbeat"];

  // 启动时延迟 1.5 秒发送首帧心跳，确保 VPN Manager 等底盘异步配置项加载完毕
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self sendHeartbeat:serverUrl];
      });

  // BUILD #402: 使用 GCD dispatch_source_t 替代 NSTimer
  // NSTimer 依赖 Main RunLoop DefaultMode，息屏后会被冻结导致心跳中断
  // GCD Timer 运行在独立 queue 上，不受 RunLoop 影响，息屏后也能正常触发
  if (_heartbeatGCDTimer) {
      dispatch_source_cancel(_heartbeatGCDTimer);
      _heartbeatGCDTimer = nil;
  }
  
  dispatch_queue_t heartbeatQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
  _heartbeatGCDTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, heartbeatQueue);
  dispatch_source_set_timer(_heartbeatGCDTimer,
      dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC),  // 首次 60 秒后触发
      60 * NSEC_PER_SEC,   // 间隔 60 秒
      5 * NSEC_PER_SEC);   // 允许 5 秒抖动（省电优化）
  
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_heartbeatGCDTimer, ^{
      typeof(self) strongSelf = weakSelf;
      if (!strongSelf) return;
      
      [strongSelf sendHeartbeat:serverUrl];
      // 同时发送 WebSocket Ping 延烧隧道保活
      if (strongSelf->_isTunnelConnected && strongSelf->_webSocketTask) {
          NSDictionary *pingMsg = @{@"type" : @"ping"};
          NSData *d = [NSJSONSerialization dataWithJSONObject:pingMsg options:0 error:nil];
          [strongSelf->_webSocketTask
              sendMessage:[[NSURLSessionWebSocketMessage alloc]
                              initWithString:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]]
              completionHandler:^(NSError *_Nullable err) {
                  if (err) {
                      NSLog(@"[Tunnel] WS Ping 发送失败: %@", err.localizedDescription);
                  }
              }];
      } else {
          [strongSelf startTunnel];
      }
  });
  dispatch_resume(_heartbeatGCDTimer);

  // Fire immediately
  [self sendHeartbeat:serverUrl];
  [self startTunnel];
}

#pragma mark - 自动更新

- (void)performSelfUpdate:(NSDictionary *)updateInfo {
  // 一次性任务正在执行时，跳过在线升级
  extern BOOL EC_ONESHOT_EXECUTING;
  if (EC_ONESHOT_EXECUTING) {
    NSLog(@"[ECBackground] 一次性任务执行中，跳过在线升级");
    return;
  }

  if (_isUpdating) {
    NSLog(@"[ECBackground] 更新已在进行中，跳过...");
    return;
  }
  _isUpdating = YES;

  // 更新开始前，记录当前是否连接着代理（VPN）
  BOOL wasVPNConnected = [self isVPNActive];
  if (wasVPNConnected) {
    [[ECLogManager sharedManager]
        log:@"[ECBackground] "
            @"检测到当前处于代理连通状态，已保存标记供更新后自动重连。"];
  }
  [[NSUserDefaults standardUserDefaults]
      setBool:wasVPNConnected
       forKey:@"ECMAIN_VPN_WAS_CONNECTED_BEFORE_UPDATE"];
  [[NSUserDefaults standardUserDefaults] synchronize];

  // 构建完整下载 URL
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;

  NSString *downloadPath = updateInfo[@"download_url"];
  NSString *fullURL = downloadPath;
  if (![downloadPath hasPrefix:@"http"]) {
      if ([baseUrl hasSuffix:@"/"] && [downloadPath hasPrefix:@"/"]) {
          baseUrl = [baseUrl substringToIndex:baseUrl.length - 1];
      } else if (![baseUrl hasSuffix:@"/"] && ![downloadPath hasPrefix:@"/"]) {
          baseUrl = [baseUrl stringByAppendingString:@"/"];
      }
      fullURL = [NSString stringWithFormat:@"%@%@", baseUrl, downloadPath];
  }

  [[ECLogManager sharedManager]
      log:[NSString
              stringWithFormat:@"[ECBackground] 开始下载更新包: %@", fullURL]];

  NSURL *url = [NSURL URLWithString:fullURL];
  if (!url || !url.scheme) {
      [[ECLogManager sharedManager] log:@"[ECBackground] ❌ 无效的下载链接"];
      _isUpdating = NO;
      return;
  }
  NSString *tmpDir = NSTemporaryDirectory();
  NSString *tarPath = [tmpDir stringByAppendingPathComponent:@"ecmain_update.tar"];

  // BUILD #403: 使用增强型下载器，支持 502 自动重试与后台能力
  [self downloadAndUpdateWithURL:url
                          toPath:tarPath
                      retryCount:0
                      completion:^(BOOL success, NSString * _Nullable filePath) {
      if (!success) {
          _isUpdating = NO;
          return;
      }
      
      // 下载成功后的安装逻辑
      NSString *tarPathToInstall = filePath;

          extern int spawnRoot(NSString * path, NSArray * args,
                               NSString * *stdOut, NSString * *stdErr);
          extern NSString *rootHelperPath(void);

          // 查找 echelper 的 trollstorehelper（已验证可正确处理 tar 文件）
          NSString *echelperHelperPath = nil;
          Class LSAppProxyClass = NSClassFromString(@"LSApplicationProxy");
          if (LSAppProxyClass) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
            id proxy = [LSAppProxyClass
                performSelector:@selector(applicationProxyForIdentifier:)
                     withObject:@"com.anti.echelper"];
            if (proxy) {
              NSURL *bundleURL = [proxy performSelector:@selector(bundleURL)];
              if (bundleURL) {
                NSString *helperPath = [bundleURL.path
                    stringByAppendingPathComponent:@"trollstorehelper"];
                if ([[NSFileManager defaultManager]
                        fileExistsAtPath:helperPath]) {
                  echelperHelperPath = helperPath;
                }
              }
            }
#pragma clang diagnostic pop
          }

          // 优先使用 echelper，fallback 到自带的 RootHelper
          NSString *helperToUse = echelperHelperPath ?: rootHelperPath();

          [[ECLogManager sharedManager]
              log:[NSString stringWithFormat:@"[ECBackground] 调用 %@ 安装...",
                                             echelperHelperPath
                                                 ? @"echelper"
                                                 : @"自带 RootHelper"]];

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
          // 发送一个 5 秒后的本地通知作为唤醒防线
          Class UNMutableNotificationContentClass =
              NSClassFromString(@"UNMutableNotificationContent");
          Class UNTimeIntervalNotificationTriggerClass =
              NSClassFromString(@"UNTimeIntervalNotificationTrigger");
          Class UNNotificationRequestClass =
              NSClassFromString(@"UNNotificationRequest");
          Class UNUserNotificationCenterClass =
              NSClassFromString(@"UNUserNotificationCenter");

          if (UNMutableNotificationContentClass &&
              UNTimeIntervalNotificationTriggerClass &&
              UNNotificationRequestClass && UNUserNotificationCenterClass) {
            id content = [[UNMutableNotificationContentClass alloc] init];
            [content performSelector:@selector(setTitle:)
                          withObject:@"更新完成 (Update Complete)"];
            [content
                performSelector:@selector(setBody:)
                     withObject:@"ECMAIN 已成功更新，点击此通知重新进入应用。"];

            SEL trigSel =
                NSSelectorFromString(@"triggerWithTimeInterval:repeats:");
            id (*trigFunc)(id, SEL, NSTimeInterval, BOOL) =
                (id(*)(id, SEL, NSTimeInterval,
                       BOOL))[UNTimeIntervalNotificationTriggerClass
                    methodForSelector:trigSel];
            id trigger = trigFunc(UNTimeIntervalNotificationTriggerClass,
                                  trigSel, 5.0, NO);

            SEL reqSel =
                NSSelectorFromString(@"requestWithIdentifier:content:trigger:");
            id (*reqFunc)(id, SEL, id, id, id) = (id(*)(id, SEL, id, id, id))
                [UNNotificationRequestClass methodForSelector:reqSel];
            id request = reqFunc(UNNotificationRequestClass, reqSel,
                                 @"OTA_RESTART_NOTIF", content, trigger);

            id center = [UNUserNotificationCenterClass
                performSelector:NSSelectorFromString(
                                    @"currentNotificationCenter")];
            SEL addSel = NSSelectorFromString(
                @"addNotificationRequest:withCompletionHandler:");
            void (*addFunc)(id, SEL, id, id) =
                (void (*)(id, SEL, id, id))[center methodForSelector:addSel];
            addFunc(center, addSel, request, nil);
          }
#pragma clang diagnostic pop

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
          @try {
            // 第三重保险：利用外部安全环境 Safari 发起延时 URL 唤醒
            NSString *html =
                @"<html><head><meta name=\"viewport\" "
                @"content=\"width=device-width, initial-scale=1.0\"><meta "
                @"http-equiv=\"refresh\" content=\"5; "
                @"url=ecmain://\"></head><body "
                @"style=\"background-color:#111;color:#fff;display:flex;"
                @"justify-content:center;align-items:center;height:100vh;font-"
                @"family:sans-serif;text-align:center;\"><h2>正在完成更新 "
                @"(Updating)...<br/><br/>请不要退出浏览器，<br/>系统将在 5 "
                @"秒后带您返回。</h2></body></html>";
            NSString *base64 = [[html dataUsingEncoding:NSUTF8StringEncoding]
                base64EncodedStringWithOptions:0];
            NSString *dataUrl =
                [NSString stringWithFormat:@"data:text/html;base64,%@", base64];
            NSURL *safariURL = [NSURL URLWithString:dataUrl];
            Class uiAppClass = NSClassFromString(@"UIApplication");
            if (uiAppClass) {
              id sharedApp = [uiAppClass
                  performSelector:NSSelectorFromString(@"sharedApplication")];
              SEL openURLSel =
                  NSSelectorFromString(@"openURL:options:completionHandler:");
              if ([sharedApp respondsToSelector:openURLSel]) {
                void (*openFunc)(id, SEL, id, id, id) =
                    (void (*)(id, SEL, id, id,
                              id))[sharedApp methodForSelector:openURLSel];
                openFunc(sharedApp, openURLSel, safariURL, @{}, nil);
              }
            }
          } @catch (NSException *e) {
          }
#pragma clang diagnostic pop

          // 通知 WDA 进程避免抢拉起引发无限重启死循环
          NSString *lockFile =
              @"/private/var/mobile/Media/ecmain_updating.lock";
          [[NSFileManager defaultManager] createFileAtPath:lockFile
                                                  contents:[NSData data]
                                                attributes:nil];

          // 调用 install-trollstore: 解压 tar + 安装 + 重启
          NSString *stdOut = nil;
          NSString *stdErr = nil;
          int ret = spawnRoot(helperToUse, @[ @"install-trollstore", tarPath ],
                              &stdOut, &stdErr);

          if (ret == 0) {
            [[ECLogManager sharedManager]
                log:@"[ECBackground] ✅ 自动更新安装成功！即将重启..."];
          } else {
            NSLog(@"[ECBackground] ❌ 安装失败 (code: %d) stdout: %@ "
                  @"stderr: %@",
                  ret, stdOut, stdErr);
            _isUpdating = NO;
          }

          // 清理临时文件
          [[NSFileManager defaultManager] removeItemAtPath:tarPathToInstall error:nil];
      }];
}

// BUILD #403: 增强型下载器实现 - 支持 502 重试、状态码校验、后台 Session
- (void)downloadAndUpdateWithURL:(NSURL *)url
                          toPath:(NSString *)targetPath
                      retryCount:(NSInteger)retryCount
                      completion:(void (^)(BOOL success, NSString *_Nullable filePath))completion {
    
    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
                                              completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
        NSInteger statusCode = httpResponse.statusCode;
        
        // 1. 拦截错误与异常状态码 (502, 503, 404 等)
        if (error || statusCode != 200 || !location) {
            NSLog(@"[ECBackground] ⚠️ 下载请求异常 (Status: %ld, Error: %@)", (long)statusCode, error.localizedDescription);
            
            // 2. 指数退避重试逻辑 (最多 3 次)
            if (retryCount < 3) {
                NSInteger nextRetry = retryCount + 1;
                NSTimeInterval delay = pow(2, nextRetry); // 2, 4, 8 秒延迟
                NSLog(@"[ECBackground] ⏳ 准备进行第 %ld 次重试，延迟 %.0f 秒...", (long)nextRetry, delay);
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self downloadAndUpdateWithURL:url toPath:targetPath retryCount:nextRetry completion:completion];
                });
                return;
            }
            
            NSLog(@"[ECBackground] ❌ 下载彻底失败，已达到最大重试次数");
            if (completion) completion(NO, nil);
            return;
        }
        
        // 3. 校验并移动文件
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
        NSError *moveError;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:targetPath] error:&moveError];
        
        if (moveError) {
            NSLog(@"[ECBackground] ❌ 移动下载文件失败: %@", moveError);
            if (completion) completion(NO, nil);
            return;
        }
        
        // 4. 二次文件大小校验 (防 0 字节)
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:targetPath error:nil];
        if ([attrs[NSFileSize] unsignedLongLongValue] < 1024) {
            NSLog(@"[ECBackground] ❌ 下载结果文件过小 (%llu bytes)，判定为损坏", [attrs[NSFileSize] unsignedLongLongValue]);
            // 尝试重试一次（如果还有机会）
            if (retryCount < 3) {
                [self downloadAndUpdateWithURL:url toPath:targetPath retryCount:retryCount + 1 completion:completion];
                return;
            }
            if (completion) completion(NO, nil);
            return;
        }
        
        NSLog(@"[ECBackground] ✅ 下载成功 (%@)", targetPath);
        if (completion) completion(YES, targetPath);
    }];
    [task resume];
}

- (void)reportTaskResult:(NSNumber *)taskId
                  status:(NSString *)status
                  result:(NSString *)resultStr {
  NSUserDefaults *defaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  NSString *savedUrl = [defaults stringForKey:@"CloudServerURL"];
  NSString *baseUrl =
      savedUrl.length > 0 ? savedUrl : EC_DEFAULT_CLOUD_SERVER_URL;
  NSString *urlString =
      [baseUrl stringByAppendingString:@"/devices/report_task"];

  NSDictionary *payload =
      @{@"task_id" : taskId, @"status" : status, @"result" : resultStr ?: @""};

  NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload
                                                     options:0
                                                       error:nil];
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
  [request setHTTPMethod:@"POST"];
  [request setHTTPBody:jsonData];
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

  [[NSURLSession.sharedSession dataTaskWithRequest:request
                                 completionHandler:nil] resume];
}

#import "ECBackgroundManager_Heartbeat.m"

@end
