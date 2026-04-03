/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "XCUIDevice+FBHealthCheck.h"

#import "XCUIDevice+FBRotation.h"
#import "XCUIApplication+FBHelpers.h"
#import "FBUnattachedAppLauncher.h"

static NSInteger _ecmainFailureCount = 0;
static NSTimeInterval _lastEcmainLaunchTime = 0;

@implementation XCUIDevice (FBHealthCheck)

+ (void)load
{
  // Wait 30 seconds for the network stack and ECMAIN to initialize
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [NSTimer scheduledTimerWithTimeInterval:30.0
                                    repeats:YES
                                      block:^(NSTimer * _Nonnull timer) {
      [self fb_checkEcmainHealth];
    }];
  });
}

+ (void)fb_checkEcmainHealth
{
  NSURL *url = [NSURL URLWithString:@"http://127.0.0.1:8089/ping"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"GET";
  request.timeoutInterval = 10.0;

  [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    @synchronized (self) {
      if (error || httpResponse.statusCode != 200) {
        _ecmainFailureCount++;
        NSLog(@"[ECWDA] ECMAIN health check failed (%ld/3): %@", (long)_ecmainFailureCount, error.localizedDescription ?: @"Invalid Status Code");

        if (_ecmainFailureCount >= 3) {
          [self fb_relaunchEcmain];
        }
      } else {
        if (_ecmainFailureCount > 0) {
          NSLog(@"[ECWDA] ECMAIN health recovered.");
        }
        _ecmainFailureCount = 0;
      }
    }
  }] resume];
}

+ (void)fb_relaunchEcmain
{
  @synchronized (self) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastEcmainLaunchTime < 60.0) {
      NSLog(@"[ECWDA] ECMAIN relaunch skipped (cooldown active).");
      return;
    }

    _lastEcmainLaunchTime = now;
    _ecmainFailureCount = 0;
  }

  NSLog(@"[ECWDA] Attempting to relaunch ECMAIN (com.ecmain.app)...");
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL launched = [FBUnattachedAppLauncher launchAppInBackgroundWithBundleId:@"com.ecmain.app"];
    NSLog(@"[ECWDA] ECMAIN relaunch result: %@", launched ? @"SUCCESS" : @"FAILED");
  });
}

@end
