#import "ECKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>

@interface ECKeepAlive ()
@property(strong, nonatomic) AVAudioPlayer *audioPlayer;
@property(strong, nonatomic) dispatch_source_t selfCheckGCDTimer;
@end

@implementation ECKeepAlive

+ (instancetype)sharedInstance {
  static ECKeepAlive *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ECKeepAlive alloc] init];
    [sharedInstance setupObservers];
  });
  return sharedInstance;
}

// 注册所有音频相关的系统通知监听
- (void)setupObservers {
  // 监听音频中断（电话/Siri/闹钟）
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleAudioInterruption:)
             name:AVAudioSessionInterruptionNotification
           object:nil];
  
  // 监听音频路由变化（耳机插拔/蓝牙连接断开）
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleRouteChange:)
             name:AVAudioSessionRouteChangeNotification
           object:nil];
  
  // 监听 MediaServer 重置（极端情况下系统重启音频服务）
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleMediaServerReset:)
             name:AVAudioSessionMediaServicesWereResetNotification
           object:nil];
  
  // 监听应用从后台恢复前台
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleAppWillEnterForeground)
             name:UIApplicationWillEnterForegroundNotification
           object:nil];
}

#pragma mark - 音频中断恢复

- (void)handleAudioInterruption:(NSNotification *)notification {
  NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
  if (type == AVAudioSessionInterruptionTypeEnded) {
    NSLog(@"[ECKeepAlive] 🔄 音频中断结束，自动恢复静音播放...");
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (self.audioPlayer && !self.audioPlayer.isPlaying) {
      [self.audioPlayer play];
    }
  }
}

#pragma mark - 音频路由变化恢复

- (void)handleRouteChange:(NSNotification *)notification {
  NSUInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
  NSLog(@"[ECKeepAlive] 🔊 音频路由发生变化 (reason: %lu)", (unsigned long)reason);
  
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        if (self.audioPlayer && !self.audioPlayer.isPlaying) {
          NSLog(@"[ECKeepAlive] ⚠️ 路由变化导致播放停止，自动恢复...");
          [[AVAudioSession sharedInstance] setActive:YES error:nil];
          [self.audioPlayer play];
        }
      });
}

#pragma mark - MediaServer 重置恢复

- (void)handleMediaServerReset:(NSNotification *)notification {
  NSLog(@"[ECKeepAlive] ⚠️ MediaServer 被系统重置，完全重建音频播放...");
  self.audioPlayer = nil;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        [self start];
      });
}

#pragma mark - 前台恢复

- (void)handleAppWillEnterForeground {
  if (self.audioPlayer && !self.audioPlayer.isPlaying) {
    NSLog(@"[ECKeepAlive] 📱 应用回到前台，检测到播放已停止，自动恢复...");
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    [self.audioPlayer play];
  }
}

#pragma mark - 启动

- (void)start {
  // ========== 第 1 步：配置 AVAudioSession ==========
  // 必须在 start 中主动设置 category，确保不论调用顺序如何都能获得后台播放权限
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *sessionError = nil;
  
  [session setCategory:AVAudioSessionCategoryPlayAndRecord
           withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                       AVAudioSessionCategoryOptionAllowBluetooth |
                       AVAudioSessionCategoryOptionDefaultToSpeaker
                 error:&sessionError];
  if (sessionError) {
    NSLog(@"[ECKeepAlive] ⚠️ AVAudioSession setCategory 失败: %@", sessionError);
  }
  
  [session setActive:YES error:&sessionError];
  if (sessionError) {
    NSLog(@"[ECKeepAlive] ⚠️ AVAudioSession setActive 失败: %@", sessionError);
  }
  
  // ========== 第 2 步：创建音频播放器 ==========
  NSURL *url = [[NSBundle mainBundle] URLForResource:@"silent"
                                       withExtension:@"wav"];
  
  if (url) {
    AVURLAsset *asset = [AVURLAsset assetWithURL:url];
    CMTime duration = asset.duration;
    Float64 seconds = CMTimeGetSeconds(duration);
    
    if (seconds >= 10.0) {
      self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:nil];
    } else {
      NSLog(@"[ECKeepAlive] silent.wav 时长仅 %.1f 秒，使用编程生成的 30 秒静音缓冲", seconds);
      self.audioPlayer = [self createSilentAudioPlayer];
    }
  } else {
    NSLog(@"[ECKeepAlive] silent.wav 不存在，使用编程生成的 30 秒静音缓冲");
    self.audioPlayer = [self createSilentAudioPlayer];
  }
  
  if (!self.audioPlayer) return;
  
  self.audioPlayer.numberOfLoops = -1; // 无限循环
  self.audioPlayer.volume = 0.01;      // 极低音量（完全为 0 可能被系统判定为假活跃）
  [self.audioPlayer play];
  
  // ========== 第 3 步：启动 GCD 定时器自检（替代 NSTimer） ==========
  // NSTimer 依赖 RunLoop，后台 RunLoop 被冻结就失效了
  // [优化] selfCheck 已合并到 ECBackgroundManager 心跳回调中，无需独立 GCD Timer
  // [self startSelfCheckGCDTimer];
  
  NSLog(@"[ECKeepAlive] ✅ 静音播放已启动 (volume=0.01, loop=-1)");
}

#pragma mark - GCD 定时器自检

- (void)startSelfCheckGCDTimer {
  if (_selfCheckGCDTimer) {
    dispatch_source_cancel(_selfCheckGCDTimer);
    _selfCheckGCDTimer = nil;
  }
  
  dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);
  _selfCheckGCDTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
  
  // 每 120 秒检查一次（原来是 300 秒 NSTimer，现在更频繁且不会被冻结）
  dispatch_source_set_timer(_selfCheckGCDTimer,
      dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC),
      120 * NSEC_PER_SEC,
      5 * NSEC_PER_SEC);
  
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(_selfCheckGCDTimer, ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf) return;
    [strongSelf selfCheck];
  });
  
  dispatch_resume(_selfCheckGCDTimer);
}

- (void)selfCheck {
  if (!self.audioPlayer || !self.audioPlayer.isPlaying) {
    NSLog(@"[ECKeepAlive] ⚠️ [定时自检] 静音播放已失效，自动重启...");
    dispatch_async(dispatch_get_main_queue(), ^{
      [[AVAudioSession sharedInstance] setActive:YES error:nil];
      if (self.audioPlayer) {
        [self.audioPlayer play];
      } else {
        [self start]; // 完全重建
      }
    });
  } else {
    NSLog(@"[ECKeepAlive] ✅ [定时自检] 静音播放正常运行中");
  }
}

// 编程生成 30 秒静音 PCM 音频
- (AVAudioPlayer *)createSilentAudioPlayer {
  NSUInteger sampleRate = 16000;
  NSUInteger durationSec = 30;
  NSUInteger totalSamples = sampleRate * durationSec;
  NSUInteger dataSize = totalSamples * 2;
  
  NSMutableData *wavData = [NSMutableData dataWithCapacity:44 + dataSize];
  
  // RIFF Header
  [wavData appendBytes:"RIFF" length:4];
  uint32_t fileSize = (uint32_t)(36 + dataSize);
  [wavData appendBytes:&fileSize length:4];
  [wavData appendBytes:"WAVE" length:4];
  
  // fmt chunk
  [wavData appendBytes:"fmt " length:4];
  uint32_t fmtSize = 16;
  [wavData appendBytes:&fmtSize length:4];
  uint16_t audioFormat = 1;
  [wavData appendBytes:&audioFormat length:2];
  uint16_t numChannels = 1;
  [wavData appendBytes:&numChannels length:2];
  uint32_t sr = (uint32_t)sampleRate;
  [wavData appendBytes:&sr length:4];
  uint32_t byteRate = (uint32_t)(sampleRate * 2);
  [wavData appendBytes:&byteRate length:4];
  uint16_t blockAlign = 2;
  [wavData appendBytes:&blockAlign length:2];
  uint16_t bitsPerSample = 16;
  [wavData appendBytes:&bitsPerSample length:2];
  
  // data chunk
  [wavData appendBytes:"data" length:4];
  uint32_t ds = (uint32_t)dataSize;
  [wavData appendBytes:&ds length:4];
  
  // 30 秒静音数据（全零）
  NSMutableData *silence = [NSMutableData dataWithLength:dataSize];
  [wavData appendData:silence];
  
  return [[AVAudioPlayer alloc] initWithData:wavData error:nil];
}

- (void)dealloc {
  if (_selfCheckGCDTimer) {
    dispatch_source_cancel(_selfCheckGCDTimer);
    _selfCheckGCDTimer = nil;
  }
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
