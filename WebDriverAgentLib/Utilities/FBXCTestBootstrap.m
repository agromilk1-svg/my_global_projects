/**
 * FBXCTestBootstrap - Attempt to bootstrap XCTest session
 * Tries to activate existing XCTest session or report unavailability
 */

#import "FBXCTestBootstrap.h"
#import "FBErrorBuilder.h"
#import "FBLogger.h"
#import "XCTRunnerDaemonSession.h"
#import <objc/runtime.h>

static BOOL _sessionBootstrapped = NO;
static BOOL _sessionChecked = NO;

@implementation FBXCTestBootstrap

+ (BOOL)bootstrapWithError:(NSError **)error {
  if (_sessionBootstrapped) {
    [FBLogger log:@"[FBXCTestBootstrap] Session already bootstrapped"];
    return YES;
  }

  if (_sessionChecked) {
    // Already tried and failed
    if (error) {
      *error = [[FBErrorBuilder builder]
                   withDescription:
                       @"XCTest session not available in standalone mode"]
                   .build;
    }
    return NO;
  }

  _sessionChecked = YES;
  [FBLogger log:@"[FBXCTestBootstrap] Checking for existing XCTest session..."];

  // Method 1: Try to get existing shared session (works if XCTest is already
  // running)
  @try {
    XCTRunnerDaemonSession *existingSession =
        [XCTRunnerDaemonSession sharedSession];
    if (existingSession) {
      [FBLogger
          log:@"[FBXCTestBootstrap] Found existing XCTRunnerDaemonSession"];

      // Check if daemon proxy is available
      id daemonProxy = existingSession.daemonProxy;
      if (daemonProxy) {
        [FBLogger log:@"[FBXCTestBootstrap] Daemon proxy is available - XCTest "
                      @"session active!"];
        _sessionBootstrapped = YES;
        return YES;
      } else {
        [FBLogger log:@"[FBXCTestBootstrap] Daemon proxy is nil - session "
                      @"exists but not connected"];
      }
    } else {
      [FBLogger
          log:@"[FBXCTestBootstrap] No existing XCTRunnerDaemonSession found"];
    }
  } @catch (NSException *exception) {
    [FBLogger logFmt:@"[FBXCTestBootstrap] Exception accessing session: %@",
                     exception.reason];
  }

  // Method 2: Try to trigger session initialization via XCUIDevice
  @
  try {
    Class xcuiDeviceClass = NSClassFromString(@"XCUIDevice");
    if (xcuiDeviceClass) {
      SEL sharedDeviceSel = NSSelectorFromString(@"sharedDevice");
      if ([xcuiDeviceClass respondsToSelector:sharedDeviceSel]) {
        id sharedDevice = [xcuiDeviceClass performSelector:sharedDeviceSel];
        if (sharedDevice) {
          [FBLogger
              log:@"[FBXCTestBootstrap] XCUIDevice.sharedDevice accessible"];

          // Try to access eventSynthesizer to trigger session
          SEL eventSynthSel = NSSelectorFromString(@"eventSynthesizer");
          if ([sharedDevice respondsToSelector:eventSynthSel]) {
            id synth = [sharedDevice performSelector:eventSynthSel];
            if (synth) {
              [FBLogger
                  log:@"[FBXCTestBootstrap] Event synthesizer available!"];
              _sessionBootstrapped = YES;
              return YES;
            }
          }
        }
      }
    }
  } @catch (NSException *exception) {
    [FBLogger logFmt:@"[FBXCTestBootstrap] Exception with XCUIDevice: %@",
                     exception.reason];
  }

  // All methods failed
  [FBLogger log:@"[FBXCTestBootstrap] XCTest session bootstrap failed - "
                @"running in fallback mode"];

  if (error) {
    *error = [[FBErrorBuilder builder]
                 withDescription:@"XCTest daemon not available. "
                                 @"Touch/screenshot features may be limited."]
                 .build;
  }

  return NO;
}

+ (BOOL)isSessionActive {
  if (!_sessionChecked) {
    [self bootstrapWithError:nil];
  }
  return _sessionBootstrapped;
}

@end
