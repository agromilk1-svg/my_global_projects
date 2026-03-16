#import "ECSystemManager.h"
#import <NetworkExtension/NetworkExtension.h>

#import "../Shared/TSUtil.h" // Import TSUtil for spawnRoot
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/utsname.h>

extern char **environ;

@implementation ECSystemManager

+ (instancetype)sharedManager {
  static ECSystemManager *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ECSystemManager alloc] init];
  });
  return sharedInstance;
}

- (BOOL)takeScreenshot:(NSString *)outputPath {
  NSLog(@"[ECSystem] Requesting screenshot to %@", outputPath);
  NSString *helper = rootHelperPath();
  if (!helper) {
    NSLog(@"[ECSystem] Error: Root helper not found");
    return NO;
  }

  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(helper, @[ @"screenshot", outputPath ], &stdOut, &stdErr);

  if (ret != 0) {
    NSLog(@"[ECSystem] Screenshot failed with code %d", ret);
    if (stdErr)
      NSLog(@"[ECSystem] Stderr: %@", stdErr);
    return NO;
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
    NSLog(@"[ECSystem] Error: Screenshot file not created at %@", outputPath);
    return NO;
  }

  return YES;
}

- (BOOL)simulateTouchX:(NSInteger)x Y:(NSInteger)y {
  NSLog(@"[ECSystem] Simulating touch at %ld, %ld", (long)x, (long)y);
  NSString *helper = rootHelperPath();
  if (!helper)
    return NO;

  NSString *stdOut = nil;
  NSString *stdErr = nil;
  int ret = spawnRoot(helper,
                      @[
                        @"touch", [NSString stringWithFormat:@"%ld", (long)x],
                        [NSString stringWithFormat:@"%ld", (long)y]
                      ],
                      &stdOut, &stdErr);

  if (ret != 0) {
    NSLog(@"[ECSystem] Touch failed: %@", stdErr);
    return NO;
  }
  return YES;
}

- (NSDictionary *)getDeviceInfo {
  // Model
  struct utsname systemInfo;
  uname(&systemInfo);
  NSString *modelCode = [NSString stringWithCString:systemInfo.machine
                                           encoding:NSUTF8StringEncoding];

  // System Version
  NSOperatingSystemVersion version =
      [[NSProcessInfo processInfo] operatingSystemVersion];
  NSString *systemVersion = [NSString
      stringWithFormat:@"%ld.%ld.%ld", (long)version.majorVersion,
                       (long)version.minorVersion, (long)version.patchVersion];
  NSString *systemName = @"iOS"; // Assumed

  // IP Address
  NSString *ipAddress = [self getIPAddress];

  // Device Name
  char hostname[256];
  if (gethostname(hostname, sizeof(hostname)) != 0) {
    strncpy(hostname, "Unknown", sizeof(hostname));
  }

  return @{
    @"model" : modelCode ?: @"Unknown",
    @"systemName" : systemName,
    @"systemVersion" : systemVersion ?: @"Unknown",
    @"ip" : ipAddress ?: @"0.0.0.0",
    @"name" : [NSString stringWithUTF8String:hostname]
  };
}

- (void)setDeviceInfo:(NSDictionary *)info {
  // 危险操作：直接修改 SystemVersion.plist 需要挂载读写权限
  // 这里仅做演示，建议配合 Root 权限 helper 使用
  NSString *path = @"/System/Library/CoreServices/SystemVersion.plist";
  if ([[NSFileManager defaultManager] isWritableFileAtPath:path]) {
    NSMutableDictionary *dict =
        [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (info[@"version"])
      dict[@"ProductVersion"] = info[@"version"];
    if (info[@"build"])
      dict[@"ProductBuildVersion"] = info[@"build"];
    [dict writeToFile:path atomically:YES];
    NSLog(@"[ECSystem] SystemVersion.plist updated (Requires Respring)");
  } else {
    NSLog(@"[ECSystem] Error: SystemVersion.plist is not writable. "
          @"Root/Remount required.");
  }
}

#import "ECEmbeddedTools.h"

- (void)bootstrapSigningTools {
  NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                       NSUserDomainMask, YES);
  NSString *docsDir = [paths firstObject];

  NSString *destLdid = [docsDir stringByAppendingPathComponent:@"ldid"];
  NSString *destCert = [docsDir stringByAppendingPathComponent:@"victim.p12"];

  // Ensure Documents directory exists
  if (![[NSFileManager defaultManager] fileExistsAtPath:docsDir]) {
    [[NSFileManager defaultManager] createDirectoryAtPath:docsDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
  }

  // 1. Extract ldid from memory if needed
  if (![[NSFileManager defaultManager] fileExistsAtPath:destLdid]) {
    NSLog(@"[ECSystem] Extracting ldid from binary...");
    NSData *ldidData = [NSData dataWithBytes:embedded_ldid_bytes
                                      length:embedded_ldid_len];
    if ([ldidData writeToFile:destLdid atomically:YES]) {
      // chmod +x
      const char *ldidPathC = [destLdid UTF8String];
      chmod(ldidPathC, 0755);
      NSLog(@"[ECSystem] Extracted and chmod +x ldid");
    } else {
      NSLog(@"[ECSystem] Failed to write ldid!");
    }
  }

  // 2. Extract victim.p12 from memory if needed
  if (![[NSFileManager defaultManager] fileExistsAtPath:destCert]) {
    NSLog(@"[ECSystem] Extracting victim.p12 from binary...");
    NSData *certData = [NSData dataWithBytes:embedded_p12_bytes
                                      length:embedded_p12_len];
    if ([certData writeToFile:destCert atomically:YES]) {
      NSLog(@"[ECSystem] Extracted victim.p12");
    } else {
      NSLog(@"[ECSystem] Failed to write victim.p12!");
    }
  }
}

- (void)installApp:(id)payload {
  [self bootstrapSigningTools];

  NSString *ipaPath = nil;
  __block NSString *mode =
      @"User"; // Default: /var/containers/Bundle/Application

  if ([payload isKindOfClass:[NSString class]]) {
    ipaPath = payload;
  } else if ([payload isKindOfClass:[NSDictionary class]]) {
    ipaPath = payload[@"path"];
    if (payload[@"mode"]) {
      mode = payload[@"mode"];
    }
  }

  if (!ipaPath || ![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) {
    NSLog(@"[ECSystem] IPA not found: %@", ipaPath);
    return;
  }

  NSLog(@"[ECSystem] Installing IPA (%@ Mode) from: %@", mode,
        ipaPath.lastPathComponent);

  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. Create Temp Directory
        NSString *tempDir = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];

        // 2. Unzip IPA
        NSLog(@"[ECSystem] Extracting IPA...");
        int unzipRet = [self runCommand:@"/usr/bin/unzip"
                                   args:@[ @"-q", ipaPath, @"-d", tempDir ]];
        if (unzipRet != 0) {
          NSLog(@"[ECSystem] Failed to unzip IPA");
          return;
        }

        // 3. Find .app Bundle
        NSString *payloadDir =
            [tempDir stringByAppendingPathComponent:@"Payload"];
        NSArray *contents =
            [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDir
                                                                error:nil];
        NSString *appBundleName = nil;
        for (NSString *item in contents) {
          if ([item.pathExtension isEqualToString:@"app"]) {
            appBundleName = item;
            break;
          }
        }

        if (!appBundleName) {
          NSLog(@"[ECSystem] Payload directory does not contain .app bundle");
          return;
        }

        NSString *appBundlePath =
            [payloadDir stringByAppendingPathComponent:appBundleName];
        NSLog(@"[ECSystem] Found app bundle: %@", appBundleName);

        // 4. Sign with ldid (CoreTrust Bypass)
        NSString *ldidPath = [[NSBundle mainBundle] pathForResource:@"ldid"
                                                             ofType:nil];
        NSString *certPath = [[NSBundle mainBundle] pathForResource:@"victim"
                                                             ofType:@"p12"];

        // Fallback: Check Documents Directory
        if (!ldidPath || !certPath) {
          NSArray *paths = NSSearchPathForDirectoriesInDomains(
              NSDocumentDirectory, NSUserDomainMask, YES);
          NSString *docsDir = [paths firstObject];

          if (!ldidPath)
            ldidPath = [docsDir stringByAppendingPathComponent:@"ldid"];
          if (!certPath)
            certPath = [docsDir stringByAppendingPathComponent:@"victim.p12"];
        }

        if (![[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
          NSLog(@"[ECSystem] Error: ldid not found in Bundle or Documents.");
          return;
        }

        if (ldidPath) {
          NSLog(@"[ECSystem] Signing app recursively...");

          // 1. Sign Frameworks
          NSString *frameworksDir =
              [appBundlePath stringByAppendingPathComponent:@"Frameworks"];
          if ([[NSFileManager defaultManager] fileExistsAtPath:frameworksDir]) {
            NSArray *frameworks = [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:frameworksDir
                                    error:nil];
            for (NSString *fw in frameworks) {
              NSString *fwPath =
                  [frameworksDir stringByAppendingPathComponent:fw];
              // Handle .framework
              if ([fw.pathExtension isEqualToString:@"framework"]) {
                NSString *fwName = [fw stringByDeletingPathExtension];
                NSString *fwBinary =
                    [fwPath stringByAppendingPathComponent:fwName];
                if ([[NSFileManager defaultManager]
                        fileExistsAtPath:fwBinary]) {
                  [self signBinary:fwBinary withLdid:ldidPath cert:certPath];
                }
              }
              // Handle .dylib
              else if ([fw.pathExtension isEqualToString:@"dylib"]) {
                [self signBinary:fwPath withLdid:ldidPath cert:certPath];
              }
            }
          }

          // 2. Sign PlugIns
          NSString *pluginsDir =
              [appBundlePath stringByAppendingPathComponent:@"PlugIns"];
          if ([[NSFileManager defaultManager] fileExistsAtPath:pluginsDir]) {
            NSArray *plugins = [[NSFileManager defaultManager]
                contentsOfDirectoryAtPath:pluginsDir
                                    error:nil];
            for (NSString *plugin in plugins) {
              if ([plugin.pathExtension isEqualToString:@"appex"]) {
                NSString *pluginPath =
                    [pluginsDir stringByAppendingPathComponent:plugin];
                NSDictionary *pluginInfo = [NSDictionary
                    dictionaryWithContentsOfFile:
                        [pluginPath
                            stringByAppendingPathComponent:@"Info.plist"]];
                NSString *pluginExec = pluginInfo[@"CFBundleExecutable"];
                if (pluginExec) {
                  NSString *pluginBinary =
                      [pluginPath stringByAppendingPathComponent:pluginExec];
                  [self signBinary:pluginBinary
                          withLdid:ldidPath
                              cert:certPath];
                }
              }
            }
          }

          // 3. Sign Main Binary
          NSDictionary *infoPlist = [NSDictionary
              dictionaryWithContentsOfFile:
                  [appBundlePath stringByAppendingPathComponent:@"Info.plist"]];
          NSString *execName = infoPlist[@"CFBundleExecutable"];
          if (execName) {
            NSString *execPath =
                [appBundlePath stringByAppendingPathComponent:execName];
            [self signBinary:execPath withLdid:ldidPath cert:certPath];
          }
        } else {
          NSLog(
              @"[ECSystem] Warning: ldid binary not found. Skipping signing.");
        }

        // 5. Determine Target Directory
        NSString *targetDir = nil;
        NSString *targetAppPath = nil;

        if ([mode isEqualToString:@"System"]) {
          targetDir = @"/Applications";
          if (![[NSFileManager defaultManager]
                  isWritableFileAtPath:targetDir]) {
            NSLog(@"[ECSystem] Warning: /Applications is not writable. "
                  @"Fallback to User mode.");
            mode = @"User";
          } else {
            targetAppPath =
                [targetDir stringByAppendingPathComponent:appBundleName];
          }
        }

        if ([mode isEqualToString:@"User"]) {
          NSString *targetUUID = [[NSUUID UUID] UUIDString];
          targetDir = [@"/var/containers/Bundle/Application"
              stringByAppendingPathComponent:targetUUID];

          NSError *err = nil;
          [[NSFileManager defaultManager] createDirectoryAtPath:targetDir
                                    withIntermediateDirectories:YES
                                                     attributes:nil
                                                          error:&err];
          if (err) {
            NSLog(@"[ECSystem] Failed to create install dir: %@", err);
            return;
          }
          targetAppPath =
              [targetDir stringByAppendingPathComponent:appBundleName];
        }

        NSLog(@"[ECSystem] Moving to target: %@", targetAppPath);

        // Remove if exists
        if ([[NSFileManager defaultManager] fileExistsAtPath:targetAppPath]) {
          [[NSFileManager defaultManager] removeItemAtPath:targetAppPath
                                                     error:nil];
        }

        NSError *err = nil;
        [[NSFileManager defaultManager] moveItemAtPath:appBundlePath
                                                toPath:targetAppPath
                                                 error:&err];

        if (err) {
          NSLog(@"[ECSystem] Failed to move app bundle: %@", err);
          return;
        }

        // 6. Register
        NSLog(@"[ECSystem] Registering app via lsregister...");
        NSString *lsregisterPath =
            @"/System/Library/Frameworks/CoreServices.framework/Frameworks/"
            @"LaunchServices.framework/Support/lsregister";
        int ret = [self runCommand:lsregisterPath
                              args:@[ @"-f", @"-p", @"-u", targetAppPath ]];

        if (ret == 0) {
          NSLog(@"[ECSystem] Installation Successful (%@)!", mode);
        } else {
          NSLog(@"[ECSystem] lsregister failed with code %d", ret);
        }
      });
}

- (int)runCommand:(NSString *)cmdPath args:(NSArray<NSString *> *)args {
  pid_t pid;
  const char *argv[args.count + 2];
  argv[0] = cmdPath.UTF8String;
  for (int i = 0; i < args.count; i++) {
    argv[i + 1] = [args[i] UTF8String];
  }
  argv[args.count + 1] = NULL;

  posix_spawn_file_actions_t child_fd_actions;
  posix_spawn_file_actions_init(&child_fd_actions);

  int result = posix_spawn(&pid, cmdPath.UTF8String, &child_fd_actions, NULL,
                           (char *const *)argv, NULL);
  if (result == 0) {
    int status;
    waitpid(pid, &status, 0);
    return WEXITSTATUS(status);
  }
  return result;
}

- (void)uninstallApp:(NSString *)bundleId {
  NSLog(@"[ECSystem] Uninstalling App: %@", bundleId);
}

- (void)configureVPN:(NSDictionary *)config {
  NSLog(@"[ECSystem] Configuring VPN with config: %@", config);

  [[NEVPNManager sharedManager]
      loadFromPreferencesWithCompletionHandler:^(NSError *_Nullable error) {
        if (error) {
          NSLog(@"[ECSystem] VPN Load Error: %@", error);
          return;
        }

        NEVPNProtocolIPSec *p = [[NEVPNProtocolIPSec alloc] init];
        p.username = config[@"account"];
        p.passwordReference =
            [config[@"password"] dataUsingEncoding:NSUTF8StringEncoding];
        p.serverAddress = config[@"server"];
        p.authenticationMethod = NEVPNIKEAuthenticationMethodSharedSecret;
        p.sharedSecretReference =
            [config[@"secret"] dataUsingEncoding:NSUTF8StringEncoding];
        p.useExtendedAuthentication = YES;
        p.disconnectOnSleep = NO;

        [[NEVPNManager sharedManager] setProtocol:p];
        [[NEVPNManager sharedManager] setOnDemandEnabled:NO];
        [[NEVPNManager sharedManager] setEnabled:YES];

        [[NEVPNManager sharedManager]
            saveToPreferencesWithCompletionHandler:^(NSError *_Nullable error) {
              if (error) {
                NSLog(@"[ECSystem] VPN Save Error: %@", error);
              } else {
                NSLog(@"[ECSystem] VPN Saved Successfully. Connecting...");

                NSError *connError;
                [[[NEVPNManager sharedManager] connection]
                    startVPNTunnelAndReturnError:&connError];
                if (connError) {
                  NSLog(@"[ECSystem] VPN Connect Error: %@", connError);
                }
              }
            }];
      }];
}

- (void)stopVPN {
  NSLog(@"[ECSystem] Stopping VPN...");
  [[[NEVPNManager sharedManager] connection] stopVPNTunnel];
}

// Helper: Sign a binary with ldid
- (void)signBinary:(NSString *)binaryPath
          withLdid:(NSString *)ldidPath
              cert:(NSString *)certPath {
  NSLog(@"[ECSystem] Signing: %@", binaryPath.lastPathComponent);

  // Ensure 755
  [self runCommand:@"/bin/chmod" args:@[ @"755", binaryPath ]];
  [self runCommand:@"/bin/chmod" args:@[ @"755", ldidPath ]];

  NSMutableArray *ldidArgs = [NSMutableArray arrayWithObject:@"-S"];
  if (certPath && [[NSFileManager defaultManager] fileExistsAtPath:certPath]) {
    [ldidArgs addObject:[NSString stringWithFormat:@"-K%@", certPath]];
  }
  [ldidArgs addObject:binaryPath];

  int ret = [self runCommand:ldidPath args:ldidArgs];
  if (ret != 0) {
    NSLog(@"[ECSystem] Failed to sign %@ (code %d)",
          binaryPath.lastPathComponent, ret);
  }
}

// Helper: Get IP Address
- (NSString *)getIPAddress {
  NSString *address = @"error";
  struct ifaddrs *interfaces = NULL;
  struct ifaddrs *temp_addr = NULL;
  int success = 0;

  success = getifaddrs(&interfaces);
  if (success == 0) {
    temp_addr = interfaces;
    while (temp_addr != NULL) {
      if (temp_addr->ifa_addr->sa_family == AF_INET) {
        if ([[NSString stringWithUTF8String:temp_addr->ifa_name]
                isEqualToString:@"en0"]) {
          address =
              [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)
                                                            temp_addr->ifa_addr)
                                                           ->sin_addr)];
        }
      }
      temp_addr = temp_addr->ifa_next;
    }
  }
  freeifaddrs(interfaces);
  return address;
}

@end
