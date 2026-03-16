/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import <XCTest/XCTest.h>

#import <AVFoundation/AVFoundation.h>
#import <WebDriverAgentLib/FBConfiguration.h>
#import <WebDriverAgentLib/FBDebugLogDelegateDecorator.h>
#import <WebDriverAgentLib/FBFailureProofTestCase.h>
#import <WebDriverAgentLib/FBWebServer.h>
#import <WebDriverAgentLib/XCTestCase.h>


static AVAudioRecorder *wda_audioRecorder;

static void WDAStartMicrophoneKeepAlive(void) {
  NSLog(@"[WDAKeepAlive] Starting Microphone Keep-Alive...");
  AVAudioSession *session = [AVAudioSession sharedInstance];
  NSError *error = nil;

  [session setCategory:AVAudioSessionCategoryPlayAndRecord
           withOptions:AVAudioSessionCategoryOptionMixWithOthers |
                       AVAudioSessionCategoryOptionAllowBluetooth
                 error:&error];
  if (error)
    NSLog(@"[WDAKeepAlive] AudioSession Error 1: %@", error);

  [session setActive:YES error:&error];
  if (error)
    NSLog(@"[WDAKeepAlive] AudioSession Error 2: %@", error);

  NSString *tempDir = NSTemporaryDirectory();
  NSString *soundFilePath =
      [tempDir stringByAppendingPathComponent:@"wda_keepalive.caf"];
  NSURL *soundFileURL = [NSURL fileURLWithPath:soundFilePath];

  NSDictionary *recordSettings = @{
    AVFormatIDKey : @(kAudioFormatAppleIMA4),
    AVSampleRateKey : @44100.0f,
    AVNumberOfChannelsKey : @1,
    AVEncoderBitDepthHintKey : @16,
    AVEncoderAudioQualityKey : @(AVAudioQualityLow)
  };

  wda_audioRecorder = [[AVAudioRecorder alloc] initWithURL:soundFileURL
                                                  settings:recordSettings
                                                     error:&error];
  if (error) {
    NSLog(@"[WDAKeepAlive] Recorder Init Error: %@", error);
    return;
  }

  [wda_audioRecorder prepareToRecord];
  BOOL success = [wda_audioRecorder record];

  if (success) {
    NSLog(@"[WDAKeepAlive] 🎙️ Microphone Keep-Alive STARTED (Recording)");
  } else {
    NSLog(@"[WDAKeepAlive] ❌ Failed to start recording");
  }
}

@interface UITestingUITests : FBFailureProofTestCase <FBWebServerDelegate>
@end

@implementation UITestingUITests

+ (void)setUp {
  [FBDebugLogDelegateDecorator decorateXCTestLogger];
  [FBConfiguration disableRemoteQueryEvaluation];
  [FBConfiguration configureDefaultKeyboardPreferences];
  [FBConfiguration disableApplicationUIInterruptionsHandling];
  if (NSProcessInfo.processInfo
          .environment[@"ENABLE_AUTOMATIC_SCREEN_RECORDINGS"]) {
    [FBConfiguration enableScreenRecordings];
  } else {
    [FBConfiguration disableScreenRecordings];
  }
  if (NSProcessInfo.processInfo.environment[@"ENABLE_AUTOMATIC_SCREENSHOTS"]) {
    [FBConfiguration enableScreenshots];
  } else {
    [FBConfiguration disableScreenshots];
  }
  [super setUp];
}

/**
 Never ending test used to start WebDriverAgent
 */
- (void)testRunner {
  WDAStartMicrophoneKeepAlive();
  FBWebServer *webServer = [[FBWebServer alloc] init];
  webServer.delegate = self;
  [webServer startServing];
}

#pragma mark - FBWebServerDelegate

- (void)webServerDidRequestShutdown:(FBWebServer *)webServer {
  [webServer stopServing];
}

@end
