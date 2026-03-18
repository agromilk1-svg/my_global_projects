#import "ECKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>

@interface ECKeepAlive ()
@property(strong, nonatomic) AVAudioPlayer *audioPlayer;
@property(assign, nonatomic) UIBackgroundTaskIdentifier bgTask;
@end

@implementation ECKeepAlive

+ (instancetype)sharedInstance {
  static ECKeepAlive *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ECKeepAlive alloc] init];
    [sharedInstance setupAudioSession];
  });
  return sharedInstance;
}

- (void)setupAudioSession {
  // 使用 PlayAndRecord 获得更高后台存活优先级（与麦克风保活对齐）
  [[AVAudioSession sharedInstance]
      setCategory:AVAudioSessionCategoryPlayAndRecord
      withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                  AVAudioSessionCategoryOptionDefaultToSpeaker
            error:nil];
  [[AVAudioSession sharedInstance] setActive:YES error:nil];
  
  // BUILD #402: 监听 AudioSession 中断事件，中断恢复后自动续播
  [[NSNotificationCenter defaultCenter]
      addObserver:self
         selector:@selector(handleAudioInterruption:)
             name:AVAudioSessionInterruptionNotification
           object:nil];
}

// BUILD #402: 音频中断恢复处理（来电/闹钟/Siri 结束后自动恢复播放）
- (void)handleAudioInterruption:(NSNotification *)notification {
  NSUInteger type = [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
  if (type == AVAudioSessionInterruptionTypeEnded) {
    NSLog(@"[ECKeepAlive] 音频中断结束，自动恢复静音播放...");
    [[AVAudioSession sharedInstance] setActive:YES error:nil];
    if (self.audioPlayer && !self.audioPlayer.isPlaying) {
      [self.audioPlayer play];
    }
  }
}

- (void)start {
  // BUILD #402: 优先使用外部 silent.wav，如果不存在或过短则编程生成 30 秒静音缓冲
  NSURL *url = [[NSBundle mainBundle] URLForResource:@"silent"
                                       withExtension:@"wav"];
  
  if (url) {
    // 检查文件时长是否足够（至少 10 秒）
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
  self.audioPlayer.volume = 0.0;       // 静音
  [self.audioPlayer play];

  // 申请后台任务
  [self registerBackgroundTask];
}

// BUILD #402: 编程生成 30 秒静音 PCM 音频（不依赖外部文件）
- (AVAudioPlayer *)createSilentAudioPlayer {
  // 生成 30 秒单声道 16kHz 的静音 PCM 数据
  NSUInteger sampleRate = 16000;
  NSUInteger durationSec = 30;
  NSUInteger totalSamples = sampleRate * durationSec;
  NSUInteger dataSize = totalSamples * 2; // 16-bit = 2 bytes/sample
  
  // WAV 文件头 (44 bytes)
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
  uint16_t audioFormat = 1; // PCM
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

- (void)registerBackgroundTask {
  // 使用 __block 变量，允许在 block 内部修改
  __block UIBackgroundTaskIdentifier oldTask = self.bgTask;
  self.bgTask = [[UIApplication sharedApplication]
      beginBackgroundTaskWithExpirationHandler:^{
        // 递归续命
        [self registerBackgroundTask];
      }];

  if (oldTask != UIBackgroundTaskInvalid) {
    [[UIApplication sharedApplication] endBackgroundTask:oldTask];
  }
}

@end

