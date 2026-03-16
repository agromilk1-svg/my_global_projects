#import "ECKeepAlive.h"
#import <AVFoundation/AVFoundation.h>
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
  [[AVAudioSession sharedInstance]
      setCategory:AVAudioSessionCategoryPlayback
      withOptions:AVAudioSessionCategoryOptionMixWithOthers
            error:nil];
  [[AVAudioSession sharedInstance] setActive:YES error:nil];
}

- (void)start {
  // 播放无声音乐以保持后台运行
  NSURL *url = [[NSBundle mainBundle] URLForResource:@"silent"
                                       withExtension:@"wav"];
  if (!url)
    return;

  self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url
                                                            error:nil];
  self.audioPlayer.numberOfLoops = -1; // 无限循环
  self.audioPlayer.volume = 0.0;       // 静音
  [self.audioPlayer play];

  // 申请后台任务
  [self registerBackgroundTask];
}

- (void)registerBackgroundTask {
  self.bgTask = [[UIApplication sharedApplication]
      beginBackgroundTaskWithExpirationHandler:^{
        [[UIApplication sharedApplication] endBackgroundTask:self.bgTask];
        self.bgTask = UIBackgroundTaskInvalid;
        [self registerBackgroundTask]; // 重新申请
      }];
}

@end
