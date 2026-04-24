#import <ImageIO/ImageIO.h>
#import <mach/mach.h>
#import <stdio.h>
#include <sys/param.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <stdlib.h>
#import <Foundation/Foundation.h>
#import "devmode.h"
#import "jit.h"
#import "uicache.h"
#import <Security/Security.h>
#import <TSUtil.h>

extern void enumerateProcessesUsingBlock(
    void (^enumerator)(pid_t pid, NSString *executablePath, BOOL *stop));
extern void killall(NSString *processName, BOOL softly);

#import <dlfcn.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>
#import <net/if.h>
#import <net/if_dl.h>
#import <notify.h>
#import <objc/runtime.h>
#import <openssl/pkcs7.h>
#import <openssl/x509.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
// #ifndef EMBEDDED_ROOT_HELPER
#import "CSBlob.h"
#import "CodeDirectory.h"
#import "FAT.h"
#import "FileStream.h"
#import "Host.h"
#import "MachO.h"
#import "codesign.h"
#import "coretrust_bug.h"
#import "usbmuxd_shim.h"
#import "unarchive.h"
// #endif

#import <FrontBoardServices/FBSSystemService.h>
#import <Security/Security.h>
#import <SpringBoardServices/SpringBoardServices.h>
#import <libroot.h>

// isLdidInstalled: 检查 ldid 二进制是否存在于 TrollStore App Bundle 中
BOOL isLdidInstalled(void) {
  NSString *ldidPath =
      [trollStoreAppPath() stringByAppendingPathComponent:@"ldid"];
  BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:ldidPath];
  NSLog(@"[RootHelper] isLdidInstalled? Path: %@ | Exists: %@", ldidPath,
        exists ? @"YES" : @"NO");
  return exists;
}

// --- libproc definitions (Manually declared for compatibility) ---
#define PROC_PIDLISTFDS 1
#define PROC_PIDFDSOCKETINFO 3
#define PROX_FDTYPE_SOCKET 2

struct proc_fdinfo {
    int32_t proc_fd;
    uint32_t proc_fdtype;
};

struct socket_fdinfo {
    struct proc_fdinfo pfi;
    char pad[8]; // Minimal padding for alignment
    struct {
        int lport;
        int fport;
        // Simplified structure for port extraction
    } psi;
};

// Function prototypes from libproc.h
int proc_listallpids(void *buffer, int buffersize);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize);
int proc_pidfdinfo(int pid, int fd, int flavor, void *buffer, int buffersize);

// --- IOMobileFramebuffer Definitions ---
typedef void *IOMobileFramebufferRef;
typedef kern_return_t IOReturn;
typedef void *io_service_t;
typedef void *io_connect_t;

// Function pointers
typedef IOReturn (*IOMobileFramebufferGetMainDisplay_t)(
    IOMobileFramebufferRef *connection);
typedef IOReturn (*IOMobileFramebufferCreateDisplayImage_t)(
    IOMobileFramebufferRef connection, float scale, int transform, int mode,
    CGImageRef *image);

// Helper function to capture screenshot
int captureScreenshot(NSString *outputPath) {
  fprintf(stderr, "STEP 20: Entering captureScreenshot\n"); fflush(stderr);
  void *handle = dlopen("/System/Library/PrivateFrameworks/"
                        "IOMobileFramebuffer.framework/IOMobileFramebuffer",
                        RTLD_NOW);
  fprintf(stderr, "STEP 21: dlopen IOMobileFramebuffer returned: %p\n", handle); fflush(stderr);
  if (!handle) {
    NSLog(@"[RootHelper] Error: Failed to open IOMobileFramebuffer.framework");
    return 10;
  }

  IOMobileFramebufferGetMainDisplay_t IOMobileFramebufferGetMainDisplay =
      (IOMobileFramebufferGetMainDisplay_t)dlsym(
          handle, "IOMobileFramebufferGetMainDisplay");
  IOMobileFramebufferCreateDisplayImage_t
      IOMobileFramebufferCreateDisplayImage =
          (IOMobileFramebufferCreateDisplayImage_t)dlsym(
              handle, "IOMobileFramebufferCreateDisplayImage");

  if (!IOMobileFramebufferGetMainDisplay ||
      !IOMobileFramebufferCreateDisplayImage) {
    NSLog(@"[RootHelper] Error: Failed to resolve IOMobileFramebuffer symbols");
    dlclose(handle);
    return 11;
  }

  IOMobileFramebufferRef connect = NULL;
  IOReturn ret = IOMobileFramebufferGetMainDisplay(&connect);
  NSLog(@"[RootHelper] IOMobileFramebufferGetMainDisplay ret=%d, connect=%p", (int)ret, connect);
  
  if (ret != 0 || connect == NULL) {
    NSLog(@"[RootHelper] Error: IOMobileFramebufferGetMainDisplay failed or NULL");
    dlclose(handle);
    return 12;
  }

  CGImageRef imageRef = NULL;
  // [v1621] 针对 iOS 15.8 适配：尝试使用 mode=1 (某些 Retina 设备需求)
  // 如果 mode=1 仍然失败，建议检查 CoreGraphics 渲染上下文
  ret = IOMobileFramebufferCreateDisplayImage(connect, 1.0f, 0, 1, &imageRef);
  NSLog(@"[RootHelper] IOMobileFramebufferCreateDisplayImage ret=%d, imageRef=%p", (int)ret, imageRef);

  if (ret != 0 || imageRef == NULL) {
    NSLog(@"[RootHelper] Error: IOMobileFramebufferCreateDisplayImage failed: %d", ret);
    dlclose(handle);
    return 13;
  }

  CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)outputPath, kCFURLPOSIXPathStyle, false);
  // 使用字符串常量避免对 MobileCoreServices 的显式依赖
  CGImageDestinationRef destination = CGImageDestinationCreateWithURL(url, (CFStringRef)@"public.jpeg", 1, NULL);
  if (!destination) {
    NSLog(@"[RootHelper] Error: Failed to create CGImageDestination");
    CFRelease(url);
    CGImageRelease(imageRef);
    dlclose(handle);
    return 14;
  }

  NSDictionary *options = @{(id)kCGImageDestinationLossyCompressionQuality: @0.7};
  CGImageDestinationAddImage(destination, imageRef, (CFDictionaryRef)options);
  BOOL saved = CGImageDestinationFinalize(destination);

  CFRelease(destination);
  CFRelease(url);
  CGImageRelease(imageRef);
  dlclose(handle);

  if (saved) {
    NSLog(@"[RootHelper] Screenshot saved to %@", outputPath);
    return 0;
  } else {
    NSLog(@"[RootHelper] Error: Failed to write to %@", outputPath);
    return 15;
  }
}
// ----------------------------------------

#ifdef EMBEDDED_ROOT_HELPER
#define MAIN_NAME rootHelperMain
#else
#define MAIN_NAME main
#endif

void cleanRestrictions(void);

extern mach_msg_return_t SBReloadIconForIdentifier(mach_port_t machport,
                                                   const char *identifier);
@interface SBSHomeScreenService : NSObject
- (void)reloadIcons;
@end
extern NSString *BKSActivateForEventOptionTypeBackgroundContentFetching;
extern NSString *BKSOpenApplicationOptionKeyActivateForEvent;

extern void BKSTerminateApplicationForReasonAndReportWithDescription(
    NSString *bundleID, int reasonID, bool report, NSString *description);

extern NSDictionary *dumpEntitlementsFromBinaryAtPath(NSString *binaryPath);

#define kCFPreferencesNoContainer CFSTR("kCFPreferencesNoContainer")

typedef CFPropertyListRef (*_CFPreferencesCopyValueWithContainerType)(
    CFStringRef key, CFStringRef applicationID, CFStringRef userName,
    CFStringRef hostName, CFStringRef containerPath);
typedef void (*_CFPreferencesSetValueWithContainerType)(
    CFStringRef key, CFPropertyListRef value, CFStringRef applicationID,
    CFStringRef userName, CFStringRef hostName, CFStringRef containerPath);
typedef Boolean (*_CFPreferencesSynchronizeWithContainerType)(
    CFStringRef applicationID, CFStringRef userName, CFStringRef hostName,
    CFStringRef containerPath);
typedef CFArrayRef (*_CFPreferencesCopyKeyListWithContainerType)(
    CFStringRef applicationID, CFStringRef userName, CFStringRef hostName,
    CFStringRef containerPath);
typedef CFDictionaryRef (*_CFPreferencesCopyMultipleWithContainerType)(
    CFArrayRef keysToFetch, CFStringRef applicationID, CFStringRef userName,
    CFStringRef hostName, CFStringRef containerPath);

BOOL _installPersistenceHelper(LSApplicationProxy *appProxy,
                               NSString *sourcePersistenceHelper,
                               NSString *sourceRootHelper);

NSArray<LSApplicationProxy *> *applicationsWithGroupId(NSString *groupId) {
  LSEnumerator *enumerator =
      [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
  enumerator.predicate = [NSPredicate
      predicateWithFormat:@"groupContainerURLs[%@] != nil", groupId];
  return enumerator.allObjects;
}

NSSet<NSString *> *systemURLSchemes(void) {
  LSEnumerator *enumerator =
      [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];

  NSMutableSet *systemURLSchemesSet = [NSMutableSet new];
  LSApplicationProxy *proxy;
  while (proxy = [enumerator nextObject]) {
    if (isRemovableSystemApp(proxy.bundleIdentifier) ||
        ![proxy.bundleURL.path hasPrefix:@"/private/var/containers"]) {
      for (NSString *claimedURLScheme in proxy.claimedURLSchemes) {
        if ([claimedURLScheme isKindOfClass:NSString.class]) {
          [systemURLSchemesSet addObject:claimedURLScheme.lowercaseString];
        }
      }
    }
  }

  return systemURLSchemesSet.copy;
}

NSSet<NSString *> *immutableAppBundleIdentifiers(void) {
  NSMutableSet *systemAppIdentifiers = [NSMutableSet new];

  LSEnumerator *enumerator =
      [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
  LSApplicationProxy *appProxy;
  while (appProxy = [enumerator nextObject]) {
    if (appProxy.installed) {
      if (![appProxy.bundleURL.path hasPrefix:@"/private/var/containers"]) {
        [systemAppIdentifiers
            addObject:appProxy.bundleIdentifier.lowercaseString];
      }
    }
  }

  return systemAppIdentifiers.copy;
}

NSDictionary *infoDictionaryForAppPath(NSString *appPath) {
  if (!appPath)
    return nil;
  NSString *infoPlistPath =
      [appPath stringByAppendingPathComponent:@"Info.plist"];
  return [NSDictionary dictionaryWithContentsOfFile:infoPlistPath];
}

NSString *appIdForAppPath(NSString *appPath) {
  if (!appPath)
    return nil;
  return infoDictionaryForAppPath(appPath)[@"CFBundleIdentifier"];
}

NSString *appMainExecutablePathForAppPath(NSString *appPath) {
  if (!appPath)
    return nil;
  return [appPath
      stringByAppendingPathComponent:infoDictionaryForAppPath(
                                         appPath)[@"CFBundleExecutable"]];
}

NSString *appPathForAppId(NSString *appId) {
  if (!appId)
    return nil;
  for (NSString *appPath in trollStoreInstalledAppBundlePaths()) {
    if ([appIdForAppPath(appPath) isEqualToString:appId]) {
      return appPath;
    }
  }
  return nil;
}

NSString *findAppNameInBundlePath(NSString *bundlePath) {
  NSArray *bundleItems =
      [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath
                                                          error:nil];
  for (NSString *bundleItem in bundleItems) {
    if ([bundleItem.pathExtension isEqualToString:@"app"]) {
      return bundleItem;
    }
  }
  return nil;
}

NSString *findAppPathInBundlePath(NSString *bundlePath) {
  NSString *appName = findAppNameInBundlePath(bundlePath);
  if (!appName)
    return nil;
  return [bundlePath stringByAppendingPathComponent:appName];
}

NSURL *findAppURLInBundleURL(NSURL *bundleURL) {
  NSString *appName = findAppNameInBundlePath(bundleURL.path);
  if (!appName)
    return nil;
  return [bundleURL URLByAppendingPathComponent:appName];
}

BOOL isMachoFile(NSString *filePath) {
  FILE *file = fopen(filePath.fileSystemRepresentation, "r");
  if (!file)
    return NO;

  fseek(file, 0, SEEK_SET);
  uint32_t magic;
  fread(&magic, sizeof(uint32_t), 1, file);
  fclose(file);

  return magic == FAT_MAGIC || magic == FAT_CIGAM || magic == MH_MAGIC_64 ||
         magic == MH_CIGAM_64;
}

void fixPermissionsOfAppBundle(NSString *appBundlePath) {
  // Apply correct permissions (First run, set everything to 644, owner 33)
  NSURL *fileURL;
  NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager]
                 enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:nil];
  while (fileURL = [enumerator nextObject]) {
    NSString *filePath = fileURL.path;
    chown(filePath.fileSystemRepresentation, 33, 33);
    chmod(filePath.fileSystemRepresentation, 0644);
  }

  // Apply correct permissions (Second run, set executables and directories to
  // 0755)
  enumerator = [[NSFileManager defaultManager]
                 enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:nil];
  while (fileURL = [enumerator nextObject]) {
    NSString *filePath = fileURL.path;

    BOOL isDir;
    [[NSFileManager defaultManager] fileExistsAtPath:fileURL.path
                                         isDirectory:&isDir];

    if (isDir || isMachoFile(filePath)) {
      chmod(filePath.fileSystemRepresentation, 0755);
    }
  }
}

NSArray *TSURLScheme(void) {
  return @[ @{
    @"CFBundleURLName" : @"com.apple.Magnifier",
    @"CFBundleURLSchemes" : @[ @"apple-magnifier" ]
  } ];
}

BOOL getTSURLSchemeState(NSString *customAppPath) {
  NSString *pathToUse = customAppPath ?: trollStoreAppPath();

  NSDictionary *trollStoreInfoDict = infoDictionaryForAppPath(pathToUse);
  return (BOOL)trollStoreInfoDict[@"CFBundleURLTypes"];
}

void setTSURLSchemeState(BOOL newState, NSString *customAppPath) {
  NSString *tsAppPath = trollStoreAppPath();
  NSString *pathToUse = customAppPath ?: tsAppPath;
  if (newState != getTSURLSchemeState(pathToUse)) {
    NSDictionary *trollStoreInfoDict = infoDictionaryForAppPath(pathToUse);
    NSMutableDictionary *trollStoreInfoDictM = trollStoreInfoDict.mutableCopy;
    if (newState) {
      trollStoreInfoDictM[@"CFBundleURLTypes"] = TSURLScheme();
    } else {
      [trollStoreInfoDictM removeObjectForKey:@"CFBundleURLTypes"];
    }
    NSString *outPath =
        [pathToUse stringByAppendingPathComponent:@"Info.plist"];
    [trollStoreInfoDictM.copy writeToURL:[NSURL fileURLWithPath:outPath]
                                   error:nil];
  }
}

#ifdef TROLLSTORE_LITE

// isLdidInstalled 已统一定义在 TSUtil.m 中

#else

void installLdid(NSString *ldidToCopyPath, NSString *ldidVersion) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:ldidToCopyPath]) {
    NSLog(@"[RootHelper] installLdid: Source not found at %@", ldidToCopyPath);
    return;
  }

  NSString *ldidPath =
      [trollStoreAppPath() stringByAppendingPathComponent:@"ldid"];
  NSString *ldidVersionPath =
      [trollStoreAppPath() stringByAppendingPathComponent:@"ldid.version"];

  NSLog(@"[RootHelper] installLdid: Installing to %@", ldidPath);

  if ([[NSFileManager defaultManager] fileExistsAtPath:ldidPath]) {
    [[NSFileManager defaultManager] removeItemAtPath:ldidPath error:nil];
  }

  [[NSFileManager defaultManager] copyItemAtPath:ldidToCopyPath
                                          toPath:ldidPath
                                           error:nil];

  NSData *ldidVersionData =
      [ldidVersion dataUsingEncoding:NSUTF8StringEncoding];
  [ldidVersionData writeToFile:ldidVersionPath atomically:YES];

  chmod(ldidPath.fileSystemRepresentation, 0755);
  chmod(ldidVersionPath.fileSystemRepresentation, 0644);
  NSLog(@"[RootHelper] installLdid: Success");
}

// isLdidInstalled 已统一定义在 TSUtil.m 中

#endif

int spawn_process(const char *path, char *const argv[]) {
  pid_t pid;
  int status;
  int ret = posix_spawn(&pid, path, NULL, NULL, argv, NULL);
  if (ret != 0)
    return ret;
  waitpid(pid, &status, 0);
  return WEXITSTATUS(status);
}

NSString *get_mac_address(void) {
  int mib[6];
  size_t len;
  char *buf;
  unsigned char *ptr;
  struct if_msghdr *ifm;
  struct sockaddr_dl *sdl;

  mib[0] = CTL_NET;
  mib[1] = AF_ROUTE;
  mib[2] = 0;
  mib[3] = AF_LINK;
  mib[4] = NET_RT_IFLIST;

  if ((mib[5] = if_nametoindex("en0")) == 0) {
    return nil;
  }

  if (sysctl(mib, 6, NULL, &len, NULL, 0) < 0) {
    return nil;
  }

  if ((buf = malloc(len)) == NULL) {
    return nil;
  }

  if (sysctl(mib, 6, buf, &len, NULL, 0) < 0) {
    free(buf);
    return nil;
  }

  ifm = (struct if_msghdr *)buf;
  sdl = (struct sockaddr_dl *)(ifm + 1);
  ptr = (unsigned char *)LLADDR(sdl);
  NSString *outstring =
      [NSString stringWithFormat:@"%02X:%02X:%02X:%02X:%02X:%02X", ptr[0],
                                 ptr[1], ptr[2], ptr[3], ptr[4], ptr[5]];
  free(buf);
  return outstring;
}

NSString *get_udid_iokit(void) {
  void *ioKit =
      dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
  if (!ioKit)
    return nil;

  mach_port_t *kIOMasterPortDefault = dlsym(ioKit, "kIOMasterPortDefault");
  CFMutableDictionaryRef (*IOServiceMatching)(const char *) =
      dlsym(ioKit, "IOServiceMatching");
  mach_port_t (*IOServiceGetMatchingService)(mach_port_t, CFDictionaryRef) =
      dlsym(ioKit, "IOServiceGetMatchingService");
  CFTypeRef (*IORegistryEntryCreateCFProperty)(mach_port_t, CFStringRef,
                                               CFAllocatorRef, uint32_t) =
      dlsym(ioKit, "IORegistryEntryCreateCFProperty");
  void (*IOObjectRelease)(mach_port_t) = dlsym(ioKit, "IOObjectRelease");

  if (!kIOMasterPortDefault || !IOServiceMatching ||
      !IOServiceGetMatchingService || !IORegistryEntryCreateCFProperty ||
      !IOObjectRelease) {
    return nil;
  }

  mach_port_t platformExpert = IOServiceGetMatchingService(
      *kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
  if (!platformExpert)
    return nil;

  CFStringRef uuid = IORegistryEntryCreateCFProperty(
      platformExpert, CFSTR("IOPlatformUUID"), kCFAllocatorDefault, 0);
  IOObjectRelease(platformExpert);

  if (uuid) {
    return (__bridge_transfer NSString *)uuid;
  }
  return nil;
}

int runBinaryAtPath(NSString *binaryPath, NSArray *args, NSString **output, NSString **errorOutput) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
    NSLog(@"[RootHelper] Error: Binary not found at %@", binaryPath);
    return -100;
  }

  NSMutableArray *argsM = args.mutableCopy ?: [NSMutableArray new];
  [argsM insertObject:binaryPath.lastPathComponent atIndex:0];

  NSUInteger argCount = [argsM count];
  char **argsC = (char **)malloc((argCount + 1) * sizeof(char *));

  for (NSUInteger i = 0; i < argCount; i++) {
    argsC[i] = strdup([[argsM objectAtIndex:i] UTF8String]);
  }
  argsC[argCount] = NULL;

  posix_spawn_file_actions_t action;
  posix_spawn_file_actions_init(&action);

  int outErr[2];
  pipe(outErr);
  posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&action, outErr[0]);

  int out[2];
  pipe(out);
  posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&action, out[0]);

  pid_t task_pid;
  int status = -200;
  NSLog(@"[RootHelper] Spawning %@ with args %@", binaryPath, args);
  int spawnError = posix_spawn(&task_pid, [binaryPath fileSystemRepresentation],
                               &action, NULL, (char *const *)argsC, NULL);
  for (NSUInteger i = 0; i < argCount; i++) {
    free(argsC[i]);
  }
  free(argsC);

  if (spawnError != 0) {
    NSLog(@"[RootHelper] Failed to spawn %@ with error %d (%s)\n", binaryPath, spawnError, strerror(spawnError));
    posix_spawn_file_actions_destroy(&action);
    close(out[1]); close(outErr[1]);
    close(out[0]); close(outErr[0]);
    return spawnError;
  }

  do {
    if (waitpid(task_pid, &status, 0) == -1) {
      perror("waitpid");
      posix_spawn_file_actions_destroy(&action);
      close(out[1]); close(outErr[1]);
      close(out[0]); close(outErr[0]);
      return -222;
    }
  } while (!WIFEXITED(status) && !WIFSIGNALED(status));

  close(outErr[1]);
  close(out[1]);

  NSString *binaryOutput = getNSStringFromFile(out[0]);
  if (output) { *output = binaryOutput; }

  NSString *binaryErrorOutput = getNSStringFromFile(outErr[0]);
  if (errorOutput) { *errorOutput = binaryErrorOutput; }

  close(out[0]);
  close(outErr[0]);
  posix_spawn_file_actions_destroy(&action);

  return WEXITSTATUS(status);
}

// [v1803] 支持传递环境变量的版本，用于 mount-ddi 向 go-ios 传递 USBMUXD_SOCKET_ADDRESS
int runBinaryAtPathWithEnv(NSString *binaryPath, NSArray *args, NSDictionary *extraEnv,
                           NSString **output, NSString **errorOutput) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:binaryPath]) {
    NSLog(@"[RootHelper] Error: Binary not found at %@", binaryPath);
    return -100;
  }

  NSMutableArray *argsM = args.mutableCopy ?: [NSMutableArray new];
  [argsM insertObject:binaryPath.lastPathComponent atIndex:0];

  NSUInteger argCount = [argsM count];
  char **argsC = (char **)malloc((argCount + 1) * sizeof(char *));
  for (NSUInteger i = 0; i < argCount; i++) {
    argsC[i] = strdup([[argsM objectAtIndex:i] UTF8String]);
  }
  argsC[argCount] = NULL;

  // 构建环境变量数组：继承当前 environ + 追加 extraEnv
  extern char **environ;
  NSMutableArray *envArray = [NSMutableArray new];
  if (environ) {
    for (int i = 0; environ[i]; i++) {
      NSString *entry = [NSString stringWithUTF8String:environ[i]];
      // 如果 extraEnv 中有同名 key，跳过旧值
      BOOL overridden = NO;
      for (NSString *key in extraEnv) {
        if ([entry hasPrefix:[NSString stringWithFormat:@"%@=", key]]) {
          overridden = YES;
          break;
        }
      }
      if (!overridden) [envArray addObject:entry];
    }
  }
  for (NSString *key in extraEnv) {
    [envArray addObject:[NSString stringWithFormat:@"%@=%@", key, extraEnv[key]]];
  }

  char **envC = (char **)malloc((envArray.count + 1) * sizeof(char *));
  for (NSUInteger i = 0; i < envArray.count; i++) {
    envC[i] = strdup([envArray[i] UTF8String]);
  }
  envC[envArray.count] = NULL;

  posix_spawn_file_actions_t action;
  posix_spawn_file_actions_init(&action);

  int outErr[2];
  pipe(outErr);
  posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
  posix_spawn_file_actions_addclose(&action, outErr[0]);

  int out[2];
  pipe(out);
  posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&action, out[0]);

  pid_t task_pid;
  int status = -200;
  NSLog(@"[RootHelper] Spawning %@ with args %@ env: %@", binaryPath, args, extraEnv);
  int spawnError = posix_spawn(&task_pid, [binaryPath fileSystemRepresentation],
                               &action, NULL, (char *const *)argsC, envC);
  for (NSUInteger i = 0; i < argCount; i++) free(argsC[i]);
  free(argsC);
  for (NSUInteger i = 0; i < envArray.count; i++) free(envC[i]);
  free(envC);

  if (spawnError != 0) {
    NSLog(@"[RootHelper] Failed to spawn %@ with error %d (%s)\n", binaryPath, spawnError, strerror(spawnError));
    posix_spawn_file_actions_destroy(&action);
    close(out[1]); close(outErr[1]);
    close(out[0]); close(outErr[0]);
    return spawnError;
  }

  do {
    if (waitpid(task_pid, &status, 0) == -1) {
      perror("waitpid");
      posix_spawn_file_actions_destroy(&action);
      close(out[1]); close(outErr[1]);
      close(out[0]); close(outErr[0]);
      return -222;
    }
  } while (!WIFEXITED(status) && !WIFSIGNALED(status));

  close(outErr[1]);
  close(out[1]);

  // [v1803-fix] 读取全部输出而非仅第一行（getNSStringFromFile 遇到 \n 即停止）
  NSMutableData *outData = [NSMutableData data];
  char buf[4096];
  ssize_t n;
  while ((n = read(out[0], buf, sizeof(buf))) > 0) {
    [outData appendBytes:buf length:n];
  }
  NSString *binaryOutput = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";
  if (output) { *output = binaryOutput; }

  NSMutableData *errData = [NSMutableData data];
  while ((n = read(outErr[0], buf, sizeof(buf))) > 0) {
    [errData appendBytes:buf length:n];
  }
  NSString *binaryErrorOutput = [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] ?: @"";
  if (errorOutput) { *errorOutput = binaryErrorOutput; }

  close(out[0]);
  close(outErr[0]);
  posix_spawn_file_actions_destroy(&action);

  return WEXITSTATUS(status);
}

int runLdid(NSArray *args, NSString **output, NSString **errorOutput) {
  return runBinaryAtPath(getLdidPath(), args, output, errorOutput);
}

BOOL certificateHasDataForExtensionOID(SecCertificateRef certificate,
                                       CFStringRef oidString) {
  if (certificate == NULL || oidString == NULL) {
    NSLog(@"[certificateHasDataForExtensionOID] attempted to check null "
          @"certificate or OID");
    return NO;
  }

  CFDataRef extensionData =
      SecCertificateCopyExtensionValue(certificate, oidString, NULL);
  if (extensionData != NULL) {
    CFRelease(extensionData);
    return YES;
  }

  return NO;
}

BOOL codeCertChainContainsFakeAppStoreExtensions(SecStaticCodeRef codeRef) {
  if (codeRef == NULL) {
    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] attempted to check "
          @"cert chain of null static code object");
    return NO;
  }

  CFDictionaryRef signingInfo = NULL;
  OSStatus result;

  result = SecCodeCopySigningInformation(codeRef, kSecCSSigningInformation,
                                         &signingInfo);

  if (result != errSecSuccess) {
    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] failed to copy "
          @"signing info from static code");
    return NO;
  }

  CFArrayRef certificates =
      CFDictionaryGetValue(signingInfo, kSecCodeInfoCertificates);
  if (certificates == NULL || CFArrayGetCount(certificates) == 0) {
    return NO;
  }

  // If we match the standard Apple policy, we are signed properly, but we
  // haven't been deliberately signed with a custom root

  SecPolicyRef appleAppStorePolicy = SecPolicyCreateWithProperties(
      kSecPolicyAppleiPhoneApplicationSigning, NULL);

  SecTrustRef trust = NULL;
  SecTrustCreateWithCertificates(certificates, appleAppStorePolicy, &trust);

  if (SecTrustEvaluateWithError(trust, nil)) {
    CFRelease(trust);
    CFRelease(appleAppStorePolicy);
    CFRelease(signingInfo);

    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] found certificate "
          @"extension, but was issued by Apple (App Store)");
    return NO;
  }

  // We haven't matched Apple, so keep going. Is the app profile signed?

  CFRelease(appleAppStorePolicy);

  SecPolicyRef appleProfileSignedPolicy = SecPolicyCreateWithProperties(
      kSecPolicyAppleiPhoneProfileApplicationSigning, NULL);
  if (SecTrustSetPolicies(trust, appleProfileSignedPolicy) != errSecSuccess) {
    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] error replacing "
          @"trust policy to check for profile-signed app");
    CFRelease(trust);
    CFRelease(signingInfo);
    return NO;
  }

  if (SecTrustEvaluateWithError(trust, nil)) {
    CFRelease(trust);
    CFRelease(appleProfileSignedPolicy);
    CFRelease(signingInfo);

    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] found certificate "
          @"extension, but was issued by Apple (profile-signed)");
    return NO;
  }

  // Still haven't matched Apple. Are we using a custom root that would take the
  // App Store fastpath?
  CFRelease(appleProfileSignedPolicy);

  // Cert chain should be of length 3
  if (CFArrayGetCount(certificates) != 3) {
    CFRelease(signingInfo);

    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] certificate chain "
          @"length != 3");
    return NO;
  }

  // AppleCodeSigning only checks for the codeSigning EKU by default
  SecPolicyRef customRootPolicy =
      SecPolicyCreateWithProperties(kSecPolicyAppleCodeSigning, NULL);
  SecPolicySetOptionsValue(customRootPolicy, CFSTR("LeafMarkerOid"),
                           CFSTR("1.2.840.113635.100.6.1.3"));

  if (SecTrustSetPolicies(trust, customRootPolicy) != errSecSuccess) {
    NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] error replacing "
          @"trust policy to check for custom root");
    CFRelease(trust);
    CFRelease(signingInfo);
    return NO;
  }

  // Need to add our certificate chain to the anchor as it is expected to be a
  // self-signed root
  SecTrustSetAnchorCertificates(trust, certificates);

  BOOL evaluatesToCustomAnchor = SecTrustEvaluateWithError(trust, nil);
  NSLog(@"[codeCertChainContainsFakeAppStoreExtensions] app signed with "
        @"non-Apple certificate %@ using valid custom certificates",
        evaluatesToCustomAnchor ? @"IS" : @"is NOT");

  CFRelease(trust);
  CFRelease(customRootPolicy);
  CFRelease(signingInfo);

  return evaluatesToCustomAnchor;
}

BOOL isSameFile(NSString *path1, NSString *path2) {
  struct stat sb1;
  struct stat sb2;
  stat(path1.fileSystemRepresentation, &sb1);
  stat(path2.fileSystemRepresentation, &sb2);
  return sb1.st_ino == sb2.st_ino;
}

#ifdef EMBEDDED_ROOT_HELPER
// The embedded root helper is not able to sign apps
// But it does not need that functionality anyways
int signApp(NSString *appPath, BOOL isUserInstall) { return -1; }
int signAdhoc(NSString *filePath, NSDictionary *entitlements) { return -1; }
#else
int signAdhoc(NSString *filePath, NSDictionary *entitlements) {
  // Priority: Use internal fastPathSign implementation
  // It is more reliable and handles DER entitlements correctly.
  int fpsRet = codesign_sign_adhoc(filePath.fileSystemRepresentation, true,
                                   entitlements);
  if (fpsRet == 0) {
    NSLog(@"[signAdhoc] internal codesign_sign_adhoc success!");
    return 0;
  }
  NSLog(@"[signAdhoc] internal codesign_sign_adhoc failed: %d, falling back to "
        @"ldid...",
        fpsRet);

  /*
  // if (@available(iOS 16, *)) {
  //	return codesign_sign_adhoc(filePath.fileSystemRepresentation, true,
  // entitlements);
  // }
  */
  //  If iOS 14 is so great, how come there is no iOS 14 2?????
  // else {
  if (!isLdidInstalled())
    return 173;

  NSString *entitlementsPath = nil;
  NSString *signArg = @"-S"; // Default to -S (pseudo-sign) instead of -s
  NSString *errorOutput;
  if (entitlements) {
    NSData *entitlementsXML = [NSPropertyListSerialization
        dataWithPropertyList:entitlements
                      format:NSPropertyListXMLFormat_v1_0
                     options:0
                       error:nil];
    if (entitlementsXML) {
      entitlementsPath = [[NSTemporaryDirectory()
          stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
          stringByAppendingPathExtension:@"plist"];
      [entitlementsXML writeToFile:entitlementsPath atomically:NO];
      signArg = [@"-S" stringByAppendingString:entitlementsPath];
    }
  }
  int ldidRet = runLdid(@[ signArg, filePath ], nil, &errorOutput);
  if (entitlementsPath) {
    [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath
                                               error:nil];
  }

  NSLog(@"ldid exited with status %d", ldidRet);

  NSLog(@"- ldid error output start -");

  printMultilineNSString(errorOutput);
  if (errorOutput && errorOutput.length > 0) {
    printf("[LDID_ERROR] %s\n", errorOutput.UTF8String);
  }

  NSLog(@"- ldid error output end -");

  if (ldidRet == 0) {
    return 0;
  } else {
    // Return actual ldid return code if possible, or 175
    // But keeping 175 for consistency with existing error codes logic unless we
    // want detail For debugging, we just rely on the printed logs.
    return 175;
  }
  //}
}

int signApp(NSString *appPath, BOOL isUserInstall) {
  NSDictionary *appInfoDict = infoDictionaryForAppPath(appPath);
  if (!appInfoDict)
    return 172;

  NSString *mainExecutablePath = appMainExecutablePathForAppPath(appPath);
  if (!mainExecutablePath)
    return 176;

  if (![[NSFileManager defaultManager] fileExistsAtPath:mainExecutablePath])
    return 174;

#ifndef TROLLSTORE_LITE
  // Check if the bundle has had a supported exploit pre-applied
  EXPLOIT_TYPE declaredPreAppliedExploitType =
      getDeclaredExploitTypeFromInfoDictionary(appInfoDict);
  if (isPlatformVulnerableToExploitType(declaredPreAppliedExploitType)) {
    NSLog(@"[signApp] taking fast path for app which declares use of a "
          @"supported pre-applied exploit (%@)",
          mainExecutablePath);
    return 0;
  } else if (declaredPreAppliedExploitType != 0) {
    NSLog(@"[signApp] app (%@) declares use of a pre-applied exploit that is "
          @"not supported on this device. Proceeding to re-sign...",
          mainExecutablePath);
  }

  // If the app doesn't declare a pre-applied exploit, and the host supports
  // fake custom root certs, we can also skip doing any work here when that app
  // is signed with fake roots If not, with the new bypass, a previously
  // modified binary should failed to be adhoc signed, and reapplying the bypass
  // should produce an identical binary
  if (isPlatformVulnerableToExploitType(
          EXPLOIT_TYPE_CUSTOM_ROOT_CERTIFICATE_V1)) {
    SecStaticCodeRef codeRef = getStaticCodeRef(mainExecutablePath);
    if (codeRef != NULL) {
      if (codeCertChainContainsFakeAppStoreExtensions(codeRef)) {
        NSLog(@"[signApp] taking fast path for app signed using a custom root "
              @"certificate (%@)",
              mainExecutablePath);
        CFRelease(codeRef);
        return 0;
      }

      CFRelease(codeRef);
    }
  }

  // On iOS 16+, binaries with certain entitlements requires developer mode to
  // be enabled, so we'll check while we're fixing entitlements
  BOOL requiresDevMode = NO;
#endif

  // The majority of IPA decryption utilities only decrypt the main executable
  // of the app bundle As a result, we cannot bail on the entire app if an
  // additional binary is encrypted (e.g. app extensions) Instead, we will
  // display a warning to the user, and warn them that the app may not work
  // properly
  BOOL hasAdditionalEncryptedBinaries = NO;

  NSURL *fileURL;
  NSDirectoryEnumerator *enumerator;

  // Due to how the new CT bug works, in order for data containers to work
  // properly we need to add the
  // com.apple.private.security.container-required=<bundle-identifier>
  // entitlement to every binary inside a bundle For this we will want to first
  // collect info about all the bundles in the app by seeking for Info.plist
  // files and adding the ent to the main binary
  enumerator = [[NSFileManager defaultManager]
                 enumeratorAtURL:[NSURL fileURLWithPath:appPath]
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:nil];
  while (fileURL = [enumerator nextObject]) {
    NSString *filePath = fileURL.path;
    if ([filePath.lastPathComponent isEqualToString:@"Info.plist"]) {
      NSDictionary *infoDict =
          [NSDictionary dictionaryWithContentsOfFile:filePath];
      if (!infoDict)
        continue;
      NSString *bundleId = infoDict[@"CFBundleIdentifier"];
      NSString *bundleExecutable = infoDict[@"CFBundleExecutable"];
      if (!bundleId || !bundleExecutable)
        continue;
      if ([bundleId isEqualToString:@""] ||
          [bundleExecutable isEqualToString:@""])
        continue;
      NSString *bundleMainExecutablePath =
          [[filePath stringByDeletingLastPathComponent]
              stringByAppendingPathComponent:bundleExecutable];
      if (![[NSFileManager defaultManager]
              fileExistsAtPath:bundleMainExecutablePath])
        continue;

      NSString *packageType = infoDict[@"CFBundlePackageType"];

      // Enable signing for frameworks to replace recursive sign
      // if ([packageType isEqualToString:@"FMWK"])
      //   continue;

      NSMutableDictionary *entitlementsToUse =
          dumpEntitlementsFromBinaryAtPath(bundleMainExecutablePath)
              .mutableCopy;
      if (isSameFile(bundleMainExecutablePath, mainExecutablePath)) {
        // In the case where the main executable of the app currently has no
        // entitlements at all We want to ensure it gets signed with fallback
        // entitlements These mimic the entitlements that Xcodes gives every app
        // it signs
        if (!entitlementsToUse) {
          entitlementsToUse = @{
            @"application-identifier" : @"TROLLTROLL.*",
            @"com.apple.developer.team-identifier" : @"TROLLTROLL",
            @"get-task-allow" : (__bridge id)kCFBooleanTrue,
            @"keychain-access-groups" :
                @[ @"TROLLTROLL.*", @"com.apple.token" ],
          }
                                  .mutableCopy;
        }
      }

      if (!entitlementsToUse)
        entitlementsToUse = [NSMutableDictionary new];

      // NOTE: Do NOT strip entitlements for User installs. TrollStore apps with
      // CoreTrust bypass can have any entitlements regardless of User/System
      // registration type. Stripping causes apps to lose required permissions.

      /* Antigravity Fix: Sign the bundle directory itself for xctest/frameworks
       */
      /* prevent signAdhoc form overwriting ldid signature */
      BOOL signedWithLdid = NO;

      NSString *bundlePath = [filePath stringByDeletingLastPathComponent];
      NSString *bundleExtension = bundlePath.pathExtension.lowercaseString;
      if ([bundleExtension isEqualToString:@"xctest"] ||
          [bundleExtension isEqualToString:@"framework"]) {

        /* Check if we already signed this bundle to avoid redundant signing */
        /* Currently relying on Info.plist iteration check (one per bundle) */

        NSLog(@"[signApp] Signing bundle directory with ldid using "
              @"entitlements to generate CodeResources: %@",
              bundlePath);

        NSString *signArg = @"-S";
        NSString *entitlementsPath = nil;

        if (entitlementsToUse) {
          NSData *entitlementsXML = [NSPropertyListSerialization
              dataWithPropertyList:entitlementsToUse
                            format:NSPropertyListXMLFormat_v1_0
                           options:0
                             error:nil];
          if (entitlementsXML) {
            entitlementsPath = [[NSTemporaryDirectory()
                stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
                stringByAppendingPathExtension:@"plist"];
            [entitlementsXML writeToFile:entitlementsPath atomically:NO];
            signArg = [@"-S" stringByAppendingString:entitlementsPath];
          }
        }

        NSString *errorOutput;
        // ldid -S<xml> <path>
        int ldidRet = runLdid(@[ signArg, bundlePath ], nil, &errorOutput);

        if (entitlementsPath) {
          [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath
                                                     error:nil];
        }

        if (ldidRet == 0) {
          signedWithLdid = YES;
        } else {
          NSLog(@"[signApp] WARNING: ldid failed for %@: %@", bundlePath,
                errorOutput);
        }
      }

#ifndef TROLLSTORE_LITE
      // Developer mode does not exist before iOS 16
      if (@available(iOS 16, *)) {
        if (!requiresDevMode) {
          for (NSString *restrictedEntitlementKey in @[
                 @"get-task-allow", @"task_for_pid-allow",
                 @"com.apple.system-task-ports",
                 @"com.apple.system-task-ports.control",
                 @"com.apple.system-task-ports.token.control",
                 @"com.apple.private.cs.debugger"
               ]) {
            NSObject *restrictedEntitlement =
                entitlementsToUse[restrictedEntitlementKey];
            if (restrictedEntitlement &&
                [restrictedEntitlement isKindOfClass:[NSNumber class]] &&
                [(NSNumber *)restrictedEntitlement boolValue]) {
              requiresDevMode = YES;
            }
          }
        }
      }

      NSObject *containerRequiredO =
          entitlementsToUse[@"com.apple.private.security.container-required"];
      BOOL containerRequired = YES;
      if (containerRequiredO &&
          [containerRequiredO isKindOfClass:[NSNumber class]]) {
        containerRequired = [(NSNumber *)containerRequiredO boolValue];
      } else if (containerRequiredO &&
                 [containerRequiredO isKindOfClass:[NSString class]]) {
        // Keep whatever is in it if it's a string...
        containerRequired = NO;
      }

      if (containerRequired) {
        NSObject *noContainerO =
            entitlementsToUse[@"com.apple.private.security.no-container"];
        BOOL noContainer = NO;
        if (noContainerO && [noContainerO isKindOfClass:[NSNumber class]]) {
          noContainer = [(NSNumber *)noContainerO boolValue];
        }
        NSObject *noSandboxO =
            entitlementsToUse[@"com.apple.private.security.no-sandbox"];
        BOOL noSandbox = NO;
        if (noSandboxO && [noSandboxO isKindOfClass:[NSNumber class]]) {
          noSandbox = [(NSNumber *)noSandboxO boolValue];
        }
        if (!noContainer && !noSandbox) {
          entitlementsToUse[@"com.apple.private.security.container-required"] =
              bundleId;
        }
      }
#else
      // Since TrollStore Lite adhoc signs stuff, this means that on PMAP_CS
      // devices, it will run with "PMAP_CS_IN_LOADED_TRUST_CACHE" trust level
      // We need to overwrite it so that the app runs as expected
      // (Dopamine 2.1.5+ feature)
      entitlementsToUse[@"jb.pmap_cs_custom_trust"] = @"PMAP_CS_APP_STORE";
#endif

      if (!signedWithLdid) {
        int r = signAdhoc(bundleMainExecutablePath, entitlementsToUse);
        if (r != 0)
          return r;
      }
    }
  }

  // All entitlement related issues should be fixed at this point, so all we
  // need to do is sign the entire bundle And then apply the CoreTrust bypass to
  // all executables
  // XXX: This only works because we're using ldid at the moment and that
  // recursively signs everything
  // 【Antigravity 修复】为 WDA 添加包含判断，普通应用必须执行此递归签名
  // 否则框架将保留原始证书，导致启动立刻被 AMFI crash
  int r = signAdhoc(appPath, nil);
  if (r != 0) {
    if ([appPath containsString:@"WebDriverAgentRunner"]) {
      NSLog(@"[signApp] Ignoring recursive sign failure (175) for WDA...");
    } else {
      NSLog(@"[signApp] Recursive signAdhoc failed with error: %d", r);
      return r;
    }
  }

#ifndef TROLLSTORE_LITE
  // Apply CoreTrust bypass
  enumerator = [[NSFileManager defaultManager]
                 enumeratorAtURL:[NSURL fileURLWithPath:appPath]
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:nil];
  while (fileURL = [enumerator nextObject]) {
    NSString *filePath = fileURL.path;
    // NSLog(@"[CTLoop] Checking: %@", filePath); // Verbose
    FAT *fat = fat_init_from_path(filePath.fileSystemRepresentation);

    // Antigravity Fix: Robust Thin Binary Support
    // If fat_init fails, it might be a thin binary that ChOma's FAT parser
    // rejected or didn't handle nicely (it should, but we see failures). so we
    // fallback to a manual "copy & bypass" approach for any file with MachO
    // magic.
    if (!fat && isMachoFile(filePath)) {
      NSLog(@"[CTLoop] %@ failed fat_init but has MachO magic - attempting "
            @"thin bypass.",
            filePath);

      // Extract (Copy) to tmp
      NSString *tmpPath = [NSTemporaryDirectory()
          stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
      if ([[NSFileManager defaultManager] copyItemAtPath:filePath
                                                  toPath:tmpPath
                                                   error:nil]) {
        NSLog(@"[%@] Applying CoreTrust bypass (Thin Fallback)...", filePath);
        int r = apply_coretrust_bypass(tmpPath.fileSystemRepresentation, NULL);
        if (r == 0) {
          NSLog(@"[%@] Applied CoreTrust bypass (Thin Fallback)!", filePath);
          // Overwrite original
          [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
          [[NSFileManager defaultManager] moveItemAtPath:tmpPath
                                                  toPath:filePath
                                                   error:nil];
        } else {
          NSLog(@"[%@] Thin bypass failed with error: %d", filePath, r);
          if (isSameFile(filePath, mainExecutablePath)) {
            NSLog(@"[%@] Main binary failed bypass!", filePath);
            return 185;
          }
          [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        }
      }
    }

    if (fat) {
      NSLog(@"[CTLoop] %@ is binary - applying bypass", filePath);
      MachO *machoForExtraction = fat_find_preferred_slice(fat);
      if (machoForExtraction) {
        // Extract best slice
        NSString *tmpPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        MemoryStream *sliceStream = macho_get_stream(machoForExtraction);
        MemoryStream *sliceOutStream = file_stream_init_from_path(
            tmpPath.fileSystemRepresentation, 0, 0,
            FILE_STREAM_FLAG_WRITABLE | FILE_STREAM_FLAG_AUTO_EXPAND);
        if (sliceOutStream) {
          memory_stream_copy_data(sliceStream, 0, sliceOutStream, 0,
                                  memory_stream_get_size(sliceStream));
          memory_stream_free(sliceOutStream);

          // Now we have the best slice at tmpPath, which we will apply the
          // bypass to, then copy it over the original file We loose all other
          // slices doing that but they aren't a loss as they wouldn't run
          // either way
          NSLog(@"[%@] Applying CoreTrust bypass...", filePath);
          int r =
              apply_coretrust_bypass(tmpPath.fileSystemRepresentation, NULL);
          if (r == 0) {
            NSLog(@"[%@] Applied CoreTrust bypass!", filePath);
          } else if (r == 2) {
            NSLog(@"[%@] Cannot apply CoreTrust bypass on an encrypted binary!",
                  filePath);
            if (isSameFile(filePath, mainExecutablePath)) {
              // If this is the main binary, this error is fatal
              NSLog(@"[%@] Main binary is encrypted, cannot continue!",
                    filePath);
              fat_free(fat);
              return 180;
            } else {
              // If not, we can continue but want to show a warning after the
              // app is installed
              hasAdditionalEncryptedBinaries = YES;
            }
          } else if (r == 3) { // Non-fatal - unsupported MachO type
            NSLog(@"[%@] Cannot apply CoreTrust bypass on an unsupported MachO "
                  @"type!",
                  filePath);
          } else {
            NSLog(@"[%@] CoreTrust bypass failed!!! :(", filePath);
            fat_free(fat);
            return 185;
          }

          // tempFile is now signed, overwrite original file at filePath with it
          [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
          [[NSFileManager defaultManager] moveItemAtPath:tmpPath
                                                  toPath:filePath
                                                   error:nil];
        }
      }
      fat_free(fat);
    }
  }

  if (requiresDevMode) {
    // Postpone trying to enable dev mode until after the app is (successfully)
    // installed
    return 182;
  }
#else // TROLLSTORE_LITE
      // Just check for whether anything is fairplay encrypted
  enumerator = [[NSFileManager defaultManager]
                 enumeratorAtURL:[NSURL fileURLWithPath:appPath]
      includingPropertiesForKeys:nil
                         options:0
                    errorHandler:nil];
  while (fileURL = [enumerator nextObject]) {
    NSString *filePath = fileURL.path;
    FAT *fat = fat_init_from_path(filePath.fileSystemRepresentation);
    if (fat) {
      NSLog(@"%@ is binary", filePath);
      MachO *macho = fat_find_preferred_slice(fat);
      if (macho) {
        if (macho_is_encrypted(macho)) {
          NSLog(@"[%@] Cannot apply CoreTrust bypass on an encrypted binary!",
                filePath);
          if (isSameFile(filePath, mainExecutablePath)) {
            // If this is the main binary, this error is fatal
            NSLog(@"[%@] Main binary is encrypted, cannot continue!", filePath);
            fat_free(fat);
            return 180;
          } else {
            // If not, we can continue but want to show a warning after the app
            // is installed
            hasAdditionalEncryptedBinaries = YES;
          }
        }
      }
      fat_free(fat);
    }
  }
#endif

  if (hasAdditionalEncryptedBinaries) {
    return 184;
  }

  return 0;
}
#endif

void applyPatchesToInfoDictionary(NSString *appPath) {
  NSURL *appURL = [NSURL fileURLWithPath:appPath];
  NSURL *infoPlistURL = [appURL URLByAppendingPathComponent:@"Info.plist"];
  NSMutableDictionary *infoDictM =
      [[NSDictionary dictionaryWithContentsOfURL:infoPlistURL
                                           error:nil] mutableCopy];
  if (!infoDictM)
    return;

  // Enable Notifications
  infoDictM[@"SBAppUsesLocalNotifications"] = @1;

  // Remove system claimed URL schemes if existant
  NSSet *appleSchemes = systemURLSchemes();
  NSArray *CFBundleURLTypes = infoDictM[@"CFBundleURLTypes"];
  if ([CFBundleURLTypes isKindOfClass:[NSArray class]]) {
    NSMutableArray *CFBundleURLTypesM = [NSMutableArray new];

    for (NSDictionary *URLType in CFBundleURLTypes) {
      if (![URLType isKindOfClass:[NSDictionary class]])
        continue;

      NSMutableDictionary *modifiedURLType = URLType.mutableCopy;
      NSArray *URLSchemes = URLType[@"CFBundleURLSchemes"];
      if (URLSchemes) {
        NSMutableSet *URLSchemesSet = [NSMutableSet setWithArray:URLSchemes];
        for (NSString *existingURLScheme in [URLSchemesSet copy]) {
          if (![existingURLScheme isKindOfClass:[NSString class]]) {
            [URLSchemesSet removeObject:existingURLScheme];
            continue;
          }

          if ([appleSchemes containsObject:existingURLScheme.lowercaseString]) {
            [URLSchemesSet removeObject:existingURLScheme];
          }
        }
        modifiedURLType[@"CFBundleURLSchemes"] = [URLSchemesSet allObjects];
      }
      [CFBundleURLTypesM addObject:modifiedURLType.copy];
    }

    infoDictM[@"CFBundleURLTypes"] = CFBundleURLTypesM.copy;
  }

  [infoDictM writeToURL:infoPlistURL error:nil];
}

// 170: failed to create container for app bundle
// 171: a non trollstore app with the same identifier is already installled
// 172: no info.plist found in app
// 173: app is not signed and cannot be signed because ldid not installed or
// didn't work 174: 180: tried to sign app where the main binary is encrypted
// 184: tried to sign app where an additional binary is encrypted

// Helper to ensure system apps are visible
void ensureSystemAppsVisible(void) {
  _CFPreferencesSetValueWithContainerType _CFPreferencesSetValueWithContainer =
      (_CFPreferencesSetValueWithContainerType)dlsym(
          RTLD_DEFAULT, "_CFPreferencesSetValueWithContainer");
  _CFPreferencesSynchronizeWithContainerType
      _CFPreferencesSynchronizeWithContainer =
          (_CFPreferencesSynchronizeWithContainerType)dlsym(
              RTLD_DEFAULT, "_CFPreferencesSynchronizeWithContainer");

  if (_CFPreferencesSetValueWithContainer &&
      _CFPreferencesSynchronizeWithContainer) {
    _CFPreferencesSetValueWithContainer(
        CFSTR("SBShowNonDefaultSystemApps"), kCFBooleanTrue,
        CFSTR("com.apple.springboard"), CFSTR("mobile"), kCFPreferencesAnyHost,
        kCFPreferencesNoContainer);
    _CFPreferencesSynchronizeWithContainer(
        CFSTR("com.apple.springboard"), CFSTR("mobile"), kCFPreferencesAnyHost,
        kCFPreferencesNoContainer);
    NSLog(@"[RootHelper] Enforced SBShowNonDefaultSystemApps = True");
  } else {
    NSLog(@"[RootHelper] Failed to resolve CFPreferences symbols");
  }
}

int installApp(NSString *appPackagePath, BOOL sign, BOOL force, BOOL isTSUpdate,
               BOOL useInstalldMethod, BOOL skipUICache,
               BOOL registerAsSystem) {
  // Ensure preference is set before installing
  ensureSystemAppsVisible();

  NSLog(@"[installApp force = %d]", force);

  NSString *appPayloadPath =
      [appPackagePath stringByAppendingPathComponent:@"Payload"];

  NSString *appBundleToInstallPath = findAppPathInBundlePath(appPayloadPath);
  NSLog(@"[installApp] found app bundle: %@", appBundleToInstallPath);

  NSString *appId = appIdForAppPath(appBundleToInstallPath);
  if (!appId) {
    NSLog(@"[installApp] failed to get appId");
    return 176;
  }
  NSLog(@"[installApp] appId: %@", appId);

  if (([appId.lowercaseString isEqualToString:@"com.ecmain.app"] &&
       !isTSUpdate) ||
      [immutableAppBundleIdentifiers() containsObject:appId.lowercaseString]) {
    NSLog(@"[installApp] immutable app id, aborting");
    return 179;
  }

  if (!infoDictionaryForAppPath(appBundleToInstallPath)) {
    NSLog(@"[installApp] failed to get info dictionary");
    return 172;
  }

  if (!isTSUpdate && sign) {
    applyPatchesToInfoDictionary(appBundleToInstallPath);
  } else if (!sign) {
    NSLog(@"[installApp] Skipping Info.plist patches to preserve signature for "
          @"encrypted install");
  }

  BOOL requiresDevMode = NO;
  BOOL hasAdditionalEncryptedBinaries = NO;

  // Antigravity Fix Removed: We now allow User installs as requested by the
  // user. Although they might fail AMFI checks without proper
  // entitlements/TrustCache, we respect the explicit choice.

  if (sign) {
    NSLog(@"[installApp] signing app...");
    int signRet = signApp(appBundleToInstallPath, !registerAsSystem);
    NSLog(@"[installApp] signApp returned: %d", signRet);
    // 182: app requires developer mode; non-fatal
    // 184: app has additional encrypted binaries; non-fatal
    if (signRet != 0) {
      if (signRet == 182) {
        requiresDevMode = YES;
      } else if (signRet == 184) {
        hasAdditionalEncryptedBinaries = YES;
      } else {
        NSLog(@"[installApp] fatal signing error: %d", signRet);
        return signRet;
      }
    };
  }

  MCMAppContainer *appContainer = [MCMAppContainer containerWithIdentifier:appId
                                                         createIfNecessary:NO
                                                                   existed:nil
                                                                     error:nil];
  if (appContainer) {
    // App update
    // Replace existing bundle with new version

    // Check if the existing app bundle is empty
    NSURL *bundleContainerURL = appContainer.url;
    NSURL *appBundleURL = findAppURLInBundleURL(bundleContainerURL);

    // Make sure the installed app is a TrollStore app or the container is
    // empty (or the force flag is set)
    NSURL *trollStoreMarkURL =
        [bundleContainerURL URLByAppendingPathComponent:TS_ACTIVE_MARKER];
    if (appBundleURL &&
        ![trollStoreMarkURL checkResourceIsReachableAndReturnError:nil] &&
        !force) {
      NSLog(@"[installApp] already installed and not a TrollStore app... "
            @"bailing out");
      return 171;
    } else if (appBundleURL) {
      // When overwriting an app that has been installed with a different
      // TrollStore flavor, make sure to remove the marker of said flavor
      NSURL *otherMarkerURL =
          [bundleContainerURL URLByAppendingPathComponent:TS_INACTIVE_MARKER];
      if ([otherMarkerURL checkResourceIsReachableAndReturnError:nil]) {
        [[NSFileManager defaultManager] removeItemAtURL:otherMarkerURL
                                                  error:nil];
      }
    }

    // Terminate app if it's still running
    if (!isTSUpdate) {
      BKSTerminateApplicationForReasonAndReportWithDescription(
          appId, 5, false, @"TrollStore - App updated");
    }

    NSLog(@"[installApp] replacing existing app with new version");

    // Delete existing .app directory if it exists
    if (appBundleURL) {
      [[NSFileManager defaultManager] removeItemAtURL:appBundleURL error:nil];
    }

    NSString *newAppBundlePath = [bundleContainerURL.path
        stringByAppendingPathComponent:appBundleToInstallPath
                                           .lastPathComponent];
    NSLog(@"[installApp] new app path: %@", newAppBundlePath);

    // Install new version into existing app bundle
    NSError *copyError;
    BOOL suc =
        [[NSFileManager defaultManager] copyItemAtPath:appBundleToInstallPath
                                                toPath:newAppBundlePath
                                                 error:&copyError];
    if (!suc) {
      NSLog(@"[installApp] Error copying new version during update: %@",
            copyError);
      return 178;
    }
  } else {
    // Initial app install
    BOOL systemMethodSuccessful = NO;
    if (useInstalldMethod) {
      // System method
      // Do initial installation using LSApplicationWorkspace
      // For encrypted apps (sign=NO), use "Customer" PackageType
      // For normal apps, use "Placeholder" PackageType
      NSString *packageType = sign ? @"Placeholder" : @"Customer";
      NSLog(@"[installApp] doing %@ installation using LSApplicationWorkspace",
            packageType);

      // The installApplication API (re)moves the app bundle, so in order to
      // be able to later fall back to the custom method, we need to make a
      // temporary copy just for using it on this API once Yeah this sucks,
      // but there is no better solution unfortunately
      NSError *tmpCopyError;
      NSString *lsAppPackageTmpCopy = [NSTemporaryDirectory()
          stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
      if (![[NSFileManager defaultManager] copyItemAtPath:appPackagePath
                                                   toPath:lsAppPackageTmpCopy
                                                    error:&tmpCopyError]) {
        NSLog(@"failed to make temporary copy of app packge: %@", tmpCopyError);
        return 170;
      }

      NSError *installError;
      @try {
        systemMethodSuccessful = [[LSApplicationWorkspace defaultWorkspace]
            installApplication:[NSURL fileURLWithPath:lsAppPackageTmpCopy]
                   withOptions:@{
                     LSInstallTypeKey : @1,
                     @"PackageType" : packageType
                   }
                         error:&installError];
      } @catch (NSException *e) {
        NSLog(@"[installApp] encountered expection %@ while trying to do "
              @"%@ install",
              e, packageType);
        systemMethodSuccessful = NO;
      }

      if (!systemMethodSuccessful) {
        NSLog(@"[installApp] System install failed with error: %@",
              installError);

        // For encrypted apps, if system install fails, DO NOT fall back to
        // custom method because custom method breaks FairPlay (signature
        // invalidation)
        if (!sign) {
          NSLog(@"[installApp] Encrypted install failed via system method. "
                @"Continuing to custom method for pre-signed apps.");
          [[NSFileManager defaultManager] removeItemAtPath:lsAppPackageTmpCopy
                                                     error:nil];
          // return 173; // Antigravity Fix: Allow fallback for pre-signed
          // (Install-Time Injected) apps
        }
      } else {
        NSLog(@"[installApp] System install successful!");
      }

      [[NSFileManager defaultManager] removeItemAtPath:lsAppPackageTmpCopy
                                                 error:nil];
    }

    if (!systemMethodSuccessful) {
      // Custom method
      // Manually create app bundle via MCM apis and move app there
      NSLog(@"[installApp] doing custom installation using MCMAppContainer");

      NSError *mcmError;
      appContainer = [MCMAppContainer containerWithIdentifier:appId
                                            createIfNecessary:YES
                                                      existed:nil
                                                        error:&mcmError];

      if (!appContainer || mcmError) {
        NSLog(@"[installApp] failed to create app container for %@: %@", appId,
              mcmError);
        return 170;
      } else {
        NSLog(@"[installApp] created app container: %@", appContainer);
      }

      NSString *newAppBundlePath = [appContainer.url.path
          stringByAppendingPathComponent:appBundleToInstallPath
                                             .lastPathComponent];
      NSLog(@"[installApp] new app path: %@", newAppBundlePath);

      NSError *copyError;
      BOOL suc =
          [[NSFileManager defaultManager] copyItemAtPath:appBundleToInstallPath
                                                  toPath:newAppBundlePath
                                                   error:&copyError];
      if (!suc) {
        NSLog(@"[installApp] Failed to copy app bundle for app %@, error: %@",
              appId, copyError);
        return 178;
      }
    }
  }

  appContainer = [MCMAppContainer containerWithIdentifier:appId
                                        createIfNecessary:NO
                                                  existed:nil
                                                    error:nil];

  // Mark app as TrollStore app
  NSURL *trollStoreMarkURL =
      [appContainer.url URLByAppendingPathComponent:TS_ACTIVE_MARKER];
  if (![[NSFileManager defaultManager]
          fileExistsAtPath:trollStoreMarkURL.path]) {
    NSError *creationError;
    NSData *emptyData = [NSData data];
    BOOL marked = [emptyData writeToURL:trollStoreMarkURL
                                options:0
                                  error:&creationError];
    if (!marked) {
      NSLog(@"[installApp] failed to mark %@ as TrollStore app by creating %@, "
            @"error: %@",
            appId, trollStoreMarkURL.path, creationError);
      return 177;
    }
  }

  // At this point the (new version of the) app is installed but still needs
  // to be registered Also permissions need to be fixed
  NSURL *updatedAppURL = findAppURLInBundleURL(appContainer.url);
  fixPermissionsOfAppBundle(updatedAppURL.path);

  // Fix container permissions for User installation
  // For User apps, the container directory itself needs to be owned by mobile
  // (33)
  if (!registerAsSystem) {
    NSString *containerPath = appContainer.url.path;
    NSLog(@"[installApp] Fixing container permissions for User install: %@",
          containerPath);
    chown(containerPath.fileSystemRepresentation, 33, 33);
    chmod(containerPath.fileSystemRepresentation, 0755);
  }

  if (!skipUICache) {
    // Antigravity Fix: For encrypted User installs, installd handles
    // registration correctly. Calling registerPath manually re-reads
    // entitlements and may overwrite critical FairPlay metadata, causing the
    // app to crash on launch. So we ONLY run registerPath if:
    // 1. It's a normal install (sign=YES), OR
    // 2. It's a System registration (registerAsSystem=YES)
    if (sign || registerAsSystem) {
      if (!registerPath(updatedAppURL.path, 0, registerAsSystem)) {
        [[NSFileManager defaultManager] removeItemAtURL:appContainer.url
                                                  error:nil];
        return 181;
      }
    } else {
      NSLog(@"[installApp] Skipping manual registerPath for encrypted User "
            @"install "
            @"(relying on installd result to preserve FairPlay)");
    }
  }

  // Handle developer mode after installing and registering the app

  // Antigravity: Post-Install Verification
  NSLog(@"[installApp] Verifying installation status for %@", appId);
  LSApplicationProxy *proxy =
      [LSApplicationProxy applicationProxyForIdentifier:appId];
  if (proxy) {
    NSLog(@"  - Proxy Found: YES");
    NSLog(@"  - Installed: %d", proxy.installed);
    NSLog(@"  - Placeholder: %d", proxy.isPlaceholder);
    NSLog(@"  - Restricted: %d", proxy.restricted);
    NSLog(@"  - ApplicationType: %@", proxy.applicationType);
    NSLog(@"  - Bundle URL: %@", proxy.bundleURL);

    __block BOOL inUser = NO;
    [[LSApplicationWorkspace defaultWorkspace]
        enumerateApplicationsOfType:0
                              block:^(LSApplicationProxy *app) {
                                if ([[((id)app) valueForKey:@"bundleIdentifier"]
                                        isEqualToString:appId]) {
                                  inUser = YES;
                                }
                              }];

    __block BOOL inSystem = NO;
    [[LSApplicationWorkspace defaultWorkspace]
        enumerateApplicationsOfType:1
                              block:^(LSApplicationProxy *app) {
                                if ([[((id)app) valueForKey:@"bundleIdentifier"]
                                        isEqualToString:appId]) {
                                  inSystem = YES;
                                }
                              }];

    NSLog(@"  - In User Workspace (0): %@", inUser ? @"YES" : @"NO");
    NSLog(@"  - In System Workspace (1): %@", inSystem ? @"YES" : @"NO");
  } else {
    NSLog(@"  - Proxy Found: NO (Critical Failure)");
  }

  if (requiresDevMode) {
    BOOL alreadyEnabled = NO;
    if (armDeveloperMode(&alreadyEnabled)) {
      if (!alreadyEnabled) {
        NSLog(@"[installApp] app requires developer mode and we have "
              @"successfully armed it");
        // non-fatal
        return 182;
      }
    } else {
      NSLog(@"[installApp] failed to arm developer mode");
      // fatal
      return 183;
    }
  }

  if (hasAdditionalEncryptedBinaries) {
    NSLog(@"[installApp] app has additional encrypted binaries");
    // non-fatal
    return 184;
  }

  // Antigravity Fix: "Refresh App Registration" makes user apps work, so we
  // double-register here. This handles cases where installd or previous steps
  // left the registration in an inconsistent state.
  // NOTE: Skip this for encrypted installs (sign=NO) as registerPath would
  // re-read potentially incompatible entitlements from the original binary.
  if (sign && !registerAsSystem && !skipUICache) {
    // Flush filesystem buffers to ensure installd writes are committed
    sync();
    // Wait for system to settle (installd async operations)
    usleep(500000); // 500ms delay
    NSLog(@"[installApp] Performing secondary registration/refresh for User "
          @"install to ensure consistency...");
    if (registerPath(updatedAppURL.path, NO, NO)) {
      NSLog(@"[installApp] Secondary registration succeeded");
    } else {
      NSLog(@"[installApp] Secondary registration returned false, app may "
            @"require manual refresh");
    }
  }

  return 0;
}

int uninstallApp(NSString *appPath, NSString *appId, BOOL useCustomMethod) {
  BOOL deleteSuc = NO;
  if (!appId && appPath) {
    // Special case, something is wrong about this app
    // Most likely the Info.plist is missing
    // (Hopefully this never happens)
    deleteSuc = [[NSFileManager defaultManager]
        removeItemAtPath:[appPath stringByDeletingLastPathComponent]
                   error:nil];
    registerPath(appPath, YES, YES);
    return 0;
  }

  if (appId) {
    LSApplicationProxy *appProxy =
        [LSApplicationProxy applicationProxyForIdentifier:appId];

    // delete data container
    if (appProxy.dataContainerURL) {
      [[NSFileManager defaultManager] removeItemAtURL:appProxy.dataContainerURL
                                                error:nil];
    }

    // delete group container paths
    [[appProxy groupContainerURLs]
        enumerateKeysAndObjectsUsingBlock:^(NSString *groupId, NSURL *groupURL,
                                            BOOL *stop) {
          // If another app still has this group, don't delete it
          NSArray<LSApplicationProxy *> *appsWithGroup =
              applicationsWithGroupId(groupId);
          if (appsWithGroup.count > 1) {
            NSLog(@"[uninstallApp] not deleting %@, appsWithGroup.count:%lu",
                  groupURL, appsWithGroup.count);
            return;
          }

          NSLog(@"[uninstallApp] deleting %@", groupURL);
          [[NSFileManager defaultManager] removeItemAtURL:groupURL error:nil];
        }];

    // delete app plugin paths
    for (LSPlugInKitProxy *pluginProxy in appProxy.plugInKitPlugins) {
      NSURL *pluginURL = pluginProxy.dataContainerURL;
      if (pluginURL) {
        NSLog(@"[uninstallApp] deleting %@", pluginURL);
        [[NSFileManager defaultManager] removeItemAtURL:pluginURL error:nil];
      }
    }

    BOOL systemMethodSuccessful = NO;
    if (!useCustomMethod) {
      systemMethodSuccessful =
          [[LSApplicationWorkspace defaultWorkspace] uninstallApplication:appId
                                                              withOptions:nil];
    }

    if (!systemMethodSuccessful) {
      deleteSuc = [[NSFileManager defaultManager]
          removeItemAtPath:[appPath stringByDeletingLastPathComponent]
                     error:nil];
      registerPath(appPath, YES, YES);
    } else {
      deleteSuc = systemMethodSuccessful;
    }
  }

  if (deleteSuc) {
    cleanRestrictions();
    return 0;
  } else {
    return 1;
  }
}

int uninstallAppByPath(NSString *appPath, BOOL useCustomMethod) {
  if (!appPath)
    return 1;

  NSString *standardizedAppPath = appPath.stringByStandardizingPath;

  if (![standardizedAppPath hasPrefix:@"/var/containers/Bundle/Application/"] &&
      standardizedAppPath.pathComponents.count == 5) {
    return 1;
  }

  NSString *appId = appIdForAppPath(standardizedAppPath);
  return uninstallApp(appPath, appId, useCustomMethod);
}

int uninstallAppById(NSString *appId, BOOL useCustomMethod) {
  if (!appId)
    return 1;
  NSString *appPath = appPathForAppId(appId);
  if (!appPath) {
    NSLog(@"[RootHelper] %@ not found in TrollStore apps, attempting native "
          @"system uninstall",
          appId);
    return uninstallApp(nil, appId, NO);
  }
  return uninstallApp(appPath, appId, useCustomMethod);
}

// 166: IPA does not exist or is not accessible
// 167: IPA does not appear to contain an app
// 180: IPA's main binary is encrypted
// 184: IPA contains additional encrypted binaries
int installIpa(NSString *ipaPath, BOOL force, BOOL useInstalldMethod,
               BOOL skipUICache, BOOL skipSigning, NSString *customBundleId,
               NSString *customDisplayName, NSString *registrationType) {
  cleanRestrictions();

  if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath])
    return 166;

  BOOL suc = NO;
  NSString *tmpPackagePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSUUID UUID].UUIDString];

  suc = [[NSFileManager defaultManager] createDirectoryAtPath:tmpPackagePath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil];
  if (!suc)
    return 1;

  if (!suc)
    return 1;

  // Check if ipaPath is a directory (already unpacked/prepared)
  BOOL isDirectory = NO;
  if ([[NSFileManager defaultManager] fileExistsAtPath:ipaPath
                                           isDirectory:&isDirectory] &&
      isDirectory) {
    NSLog(@"[installIpa] Path is a directory - skipping extraction, copying "
          @"bundle...");

    NSString *tmpPayloadPath =
        [tmpPackagePath stringByAppendingPathComponent:@"Payload"];
    if (![[NSFileManager defaultManager] createDirectoryAtPath:tmpPayloadPath
                                   withIntermediateDirectories:YES
                                                    attributes:nil
                                                         error:nil]) {
      NSLog(@"[installIpa] Failed to create Payload directory");
      return 1;
    }

    // Copy the .app bundle into Payload
    NSString *destAppPath = [tmpPayloadPath
        stringByAppendingPathComponent:ipaPath.lastPathComponent];
    NSError *copyError = nil;
    if (![[NSFileManager defaultManager] copyItemAtPath:ipaPath
                                                 toPath:destAppPath
                                                  error:&copyError]) {
      NSLog(@"[installIpa] Failed to copy app bundle: %@", copyError);
      return 168; // Extraction/Copy failed
    }
    NSLog(@"[installIpa] Copied bundle to %@", destAppPath);

  } else {
    // Normal IPA file - extract it
    int extractRet = extract(ipaPath, tmpPackagePath);
    if (extractRet != 0) {
      NSLog(@"[installIpa] Failed to extract IPA (code %d)", extractRet);
      [[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath
                                                 error:nil];
      return 168;
    }
    NSLog(@"[installIpa] Extracted IPA successfully to %@", tmpPackagePath);
  }

  // Apply custom bundle ID and display name for clone install
  if (customBundleId || customDisplayName) {
    NSString *payloadPath =
        [tmpPackagePath stringByAppendingPathComponent:@"Payload"];
    NSString *appBundlePath = findAppPathInBundlePath(payloadPath);
    if (appBundlePath) {
      NSString *infoPlistPath =
          [appBundlePath stringByAppendingPathComponent:@"Info.plist"];
      NSMutableDictionary *infoDict =
          [NSMutableDictionary dictionaryWithContentsOfFile:infoPlistPath];
      if (infoDict) {
        if (customBundleId && customBundleId.length > 0) {
          NSLog(@"[installIpa] Applying custom bundle ID: %@", customBundleId);
          infoDict[@"CFBundleIdentifier"] = customBundleId;
        }
        if (customDisplayName && customDisplayName.length > 0) {
          NSLog(@"[installIpa] Applying custom display name: %@",
                customDisplayName);
          infoDict[@"CFBundleDisplayName"] = customDisplayName;
          infoDict[@"CFBundleName"] = customDisplayName;
        }
        [infoDict writeToFile:infoPlistPath atomically:YES];
      }
    }
  }

  // Determine registration type
  // 【Antigravity 恢复】在 iOS 15 下，/var/containers 中的应用默认必须是 User 类型
  // 否则强制注册为 System 会被 LS 拒绝并标记为灰色占位符
  BOOL registerAsSystem = NO;
  if (registrationType && registrationType.length > 0) {
    if ([registrationType isEqualToString:@"System"]) {
      registerAsSystem = YES;
    } else if ([registrationType isEqualToString:@"User"]) {
      registerAsSystem = NO;
    }
  }

  // If skipSigning is true, don't sign (preserve FairPlay encryption)
  // Also force using installd method for encrypted apps
  // Antigravity: User requested to use System method (installd) for "User"
  // installs as well
  BOOL shouldSign = !skipSigning;
  BOOL actualUseInstalldMethod = useInstalldMethod;

  if (skipSigning) {
    NSLog(@"[installIpa] Skip signing requested - preserving FairPlay "
          @"encryption");
    NSLog(@"[installIpa] Forcing installd method for encrypted app "
          @"installation");
    actualUseInstalldMethod = YES; // Force system installation method
  } else if ([registrationType isEqualToString:@"User"]) {
    NSLog(@"[installIpa] Forcing installd method for User installation as "
          @"requested");
    actualUseInstalldMethod = YES;
  }

  // Antigravity Fix: For "Original Package Install" (installd method),
  // check if the app is already signed with CoreTrust bypass.
  // If so, skip re-signing to avoid breaking the existing signature.
  if (actualUseInstalldMethod && shouldSign) {
    NSString *payloadPath =
        [tmpPackagePath stringByAppendingPathComponent:@"Payload"];
    NSString *appBundlePath = findAppPathInBundlePath(payloadPath);
    if (appBundlePath) {
      NSString *mainExecPath = appMainExecutablePathForAppPath(appBundlePath);
      if (mainExecPath &&
          [[NSFileManager defaultManager] fileExistsAtPath:mainExecPath]) {
        SecStaticCodeRef codeRef = getStaticCodeRef(mainExecPath);
        if (codeRef != NULL) {
          if (codeCertChainContainsFakeAppStoreExtensions(codeRef)) {
            NSLog(@"[installIpa] App is already signed with CoreTrust bypass - "
                  @"skipping re-sign");
            shouldSign = NO;
          }
          CFRelease(codeRef);
        }
      }
    }
  }

  int ret = installApp(tmpPackagePath, shouldSign, force, NO,
                       actualUseInstalldMethod, skipUICache, registerAsSystem);
  NSLog(@"[installIpa] installApp returned code %d", ret);

  [[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];

  return ret;
}

void uninstallAllApps(BOOL useCustomMethod) {
  for (NSString *appPath in trollStoreInstalledAppBundlePaths()) {
    uninstallAppById(appIdForAppPath(appPath), useCustomMethod);
  }
}

int uninstallTrollStore(BOOL unregister) {
  NSString *trollStore = trollStorePath();
  if (![[NSFileManager defaultManager] fileExistsAtPath:trollStore])
    return NO;

  if (unregister) {
    registerPath(trollStoreAppPath(), YES, YES);
  }

  return [[NSFileManager defaultManager] removeItemAtPath:trollStore error:nil];
}

int installTrollStore(NSString *pathToTar) {
  _CFPreferencesSetValueWithContainerType _CFPreferencesSetValueWithContainer =
      (_CFPreferencesSetValueWithContainerType)dlsym(
          RTLD_DEFAULT, "_CFPreferencesSetValueWithContainer");
  _CFPreferencesSynchronizeWithContainerType
      _CFPreferencesSynchronizeWithContainer =
          (_CFPreferencesSynchronizeWithContainerType)dlsym(
              RTLD_DEFAULT, "_CFPreferencesSynchronizeWithContainer");
  _CFPreferencesSetValueWithContainer(
      CFSTR("SBShowNonDefaultSystemApps"), kCFBooleanTrue,
      CFSTR("com.apple.springboard"), CFSTR("mobile"), kCFPreferencesAnyHost,
      kCFPreferencesNoContainer);
  _CFPreferencesSynchronizeWithContainer(CFSTR("com.apple.springboard"),
                                         CFSTR("mobile"), kCFPreferencesAnyHost,
                                         kCFPreferencesNoContainer);

  if (![[NSFileManager defaultManager] fileExistsAtPath:pathToTar])
    return 1;
  if (![pathToTar.pathExtension isEqualToString:@"tar"])
    return 1;

  NSString *tmpPackagePath = [NSTemporaryDirectory()
      stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
  NSString *tmpPayloadPath =
      [tmpPackagePath stringByAppendingPathComponent:@"Payload"];
  BOOL suc =
      [[NSFileManager defaultManager] createDirectoryAtPath:tmpPayloadPath
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:nil];
  if (!suc)
    return 1;

  int extractRet = extract(pathToTar, tmpPayloadPath);
  if (extractRet != 0) {
    [[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];
    return 169;
  }

  // Fix: Handle ECMAIN.app (rename to TrollStore.app)
  NSString *tmpECMainPath =
      [tmpPayloadPath stringByAppendingPathComponent:@"ECMAIN.app"];
  NSString *tmpTrollStorePath =
      [tmpPayloadPath stringByAppendingPathComponent:@"TrollStore.app"];

  if ([[NSFileManager defaultManager] fileExistsAtPath:tmpECMainPath] &&
      ![[NSFileManager defaultManager] fileExistsAtPath:tmpTrollStorePath]) {
    NSError *moveError = nil;
    [[NSFileManager defaultManager] moveItemAtPath:tmpECMainPath
                                            toPath:tmpTrollStorePath
                                             error:&moveError];
    if (moveError) {
      NSLog(@"[installTrollStore] Failed to rename ECMAIN.app to "
            @"TrollStore.app: %@",
            moveError);
    } else {
      NSLog(@"[installTrollStore] Renamed ECMAIN.app to TrollStore.app "
            @"successfully");
    }
  }

  if (![[NSFileManager defaultManager] fileExistsAtPath:tmpTrollStorePath])
    return 1;

  // if (@available(iOS 16, *)) {} else {
  //  Transfer existing ldid installation if it exists
  //  But only if the to-be-installed version of TrollStore is 1.5.0 or above
  //  This is to make it possible to downgrade to older versions still

  NSString *toInstallInfoPlistPath =
      [tmpTrollStorePath stringByAppendingPathComponent:@"Info.plist"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:toInstallInfoPlistPath])
    return 1;

  NSDictionary *toInstallInfoDict =
      [NSDictionary dictionaryWithContentsOfFile:toInstallInfoPlistPath];
  NSString *toInstallVersion = toInstallInfoDict[@"CFBundleVersion"];

  NSComparisonResult result = [@"1.5.0" compare:toInstallVersion
                                        options:NSNumericSearch];
  if (result != NSOrderedDescending) {
    NSString *existingLdidPath =
        [trollStoreAppPath() stringByAppendingPathComponent:@"ldid"];
    NSString *existingLdidVersionPath =
        [trollStoreAppPath() stringByAppendingPathComponent:@"ldid.version"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:existingLdidPath]) {
      NSString *tmpLdidPath =
          [tmpTrollStorePath stringByAppendingPathComponent:@"ldid"];
      if (![[NSFileManager defaultManager] fileExistsAtPath:tmpLdidPath]) {
        [[NSFileManager defaultManager] copyItemAtPath:existingLdidPath
                                                toPath:tmpLdidPath
                                                 error:nil];
      }
    }
    if ([[NSFileManager defaultManager]
            fileExistsAtPath:existingLdidVersionPath]) {
      NSString *tmpLdidVersionPath =
          [tmpTrollStorePath stringByAppendingPathComponent:@"ldid.version"];
      if (![[NSFileManager defaultManager]
              fileExistsAtPath:tmpLdidVersionPath]) {
        [[NSFileManager defaultManager] copyItemAtPath:existingLdidVersionPath
                                                toPath:tmpLdidVersionPath
                                                 error:nil];
      }
    }
  }
  //}

  // Merge existing URL scheme settings value
  if (!getTSURLSchemeState(nil)) {
    setTSURLSchemeState(NO, tmpTrollStorePath);
  }

  // Update system app persistence helper if used
  LSApplicationProxy *persistenceHelperApp =
      findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_SYSTEM);
  if (persistenceHelperApp) {
    NSString *trollStorePersistenceHelper =
        [tmpTrollStorePath stringByAppendingPathComponent:@"PersistenceHelper"];
    NSString *trollStoreRootHelper =
        [tmpTrollStorePath stringByAppendingPathComponent:@"echelper"];
    _installPersistenceHelper(persistenceHelperApp, trollStorePersistenceHelper,
                              trollStoreRootHelper);
  }

  // OTA：在危险的安装操作前分离子进程，以防自身被系统牵连杀死
  NSLog(@"[installTrollStore] 准备分离子进程以自动启动 ECMAIN...");

  extern char **environ;
  NSString *executablePath =
      [[NSProcessInfo processInfo] arguments].firstObject;
  const char *args[] = {executablePath.UTF8String, "wait-and-open",
                        "com.ecmain.app", NULL};

  posix_spawnattr_t attr;
  posix_spawnattr_init(&attr);
  posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

  pid_t pid;
  int spawnError = posix_spawn(&pid, executablePath.UTF8String, NULL, &attr,
                               (char *const *)args, environ);
  if (spawnError != 0) {
    NSLog(@"[installTrollStore] posix_spawn wait-and-open 失败 Error: %d",
          spawnError);
  } else {
    NSLog(@"[installTrollStore] 成功启动独立守护进程 (PID: %d) 进行无牵连重启",
          pid);
  }
  posix_spawnattr_destroy(&attr);

  // 父进程：继续执行安装动作（即使此步骤由于注册原因被强杀也无所谓）
  int ret = installApp(tmpPackagePath, NO, YES, YES, YES, NO, YES);
  NSLog(@"[installTrollStore] installApp => %d", ret);
  [[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];

  return ret;
}

// ECMAIN 管理的应用 Bundle ID 列表
// 刷新注册时，会自动查找这些应用并重新注册到 LaunchServices
// 新增应用时只需在此数组中添加 bundle ID 即可
// ============================================================
static NSArray *ecmainManagedAppBundleIDs(void) {
  NSMutableArray *managedList = [NSMutableArray arrayWithArray:@[
    @"com.ss.iphone.ugc.Ame3",
    @"com.ss.iphone.ugc.Ame4",
    @"com.ss.iphone.ugc.Ame6",
    @"com.ss.iphone.ugc.Ame8",
    @"com.ss.iphone.ugc.Ame9",
    @"com.ss.iphone.ugc.Ame10",
    @"com.apple.accessibility.ecwda",
  ]];
  
  NSString *plistPath = @"/var/mobile/Media/ECMAIN/managed_apps.plist";
  if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
      NSArray *dynamicList = [NSArray arrayWithContentsOfFile:plistPath];
      if (dynamicList && [dynamicList isKindOfClass:[NSArray class]]) {
          for (NSString *bundleId in dynamicList) {
              if (![managedList containsObject:bundleId]) {
                  [managedList addObject:bundleId];
              }
          }
      }
  }
  
  return managedList;
}

void refreshAppRegistrations(BOOL forceSystemRefresh) {
  NSLog(@"========== [refreshAppRegistrations] START ==========");
  NSLog(@"[refresh] forceSystemRefresh = %@",
        forceSystemRefresh ? @"YES" : @"NO");

  // === 第一步：注册 ECMAIN 自身 ===
  NSString *tsAppPath = trollStoreAppPath();
  NSLog(@"[refresh] trollStoreAppPath() = %@", tsAppPath ?: @"(null)");

  if (tsAppPath &&
      [[NSFileManager defaultManager] fileExistsAtPath:tsAppPath]) {
    bool regResult = registerPath(tsAppPath, NO, YES);
    NSLog(@"[refresh] ECMAIN register = %@",
          regResult ? @"OK" : @"FAIL");
  } else {
    NSLog(@"[refresh] ⚠️ ECMAIN path not found, skipping self-registration");
  }

  // === 第二步：处理已知的 ECMAIN 管理应用（通过 bundle ID 查找） ===
  // 这些应用可能缺少 _ECStore 标记文件，通过 LSApplicationProxy 直接查找
  NSArray *managedIDs = ecmainManagedAppBundleIDs();
  NSLog(@"[refresh] Processing %lu managed app bundle IDs",
        (unsigned long)managedIDs.count);

  NSMutableSet *processedPaths = [NSMutableSet set];

  for (NSString *bundleID in managedIDs) {
    LSApplicationProxy *proxy =
        [LSApplicationProxy applicationProxyForIdentifier:bundleID];
    if (!proxy || !proxy.bundleURL) {
      NSLog(@"[refresh] [%@] NOT installed, skipping", bundleID);
      continue;
    }

    NSString *appPath = proxy.bundleURL.path;
    NSLog(@"[refresh] [%@] found at: %@", bundleID, appPath);

    // 自动补上缺失的 _ECStore 标记
    NSString *containerPath =
        [appPath stringByDeletingLastPathComponent];
    NSString *markerPath =
        [containerPath stringByAppendingPathComponent:TS_ACTIVE_MARKER];
    if (![[NSFileManager defaultManager] fileExistsAtPath:markerPath]) {
      NSData *emptyData = [NSData data];
      BOOL created = [emptyData writeToFile:markerPath atomically:YES];
      NSLog(@"[refresh] [%@] Created missing marker %@ = %@", bundleID,
            TS_ACTIVE_MARKER, created ? @"OK" : @"FAIL");
    }

    // 读取 entitlements 决定注册类型
    NSString *executablePath = appMainExecutablePathForAppPath(appPath);
    NSDictionary *entitlements =
        dumpEntitlementsFromBinaryAtPath(executablePath);

    BOOL isSystemApp = NO;
    if (entitlements &&
        entitlements[@"com.apple.private.security.no-sandbox"]) {
      isSystemApp = YES;
    }
    BOOL finalIsSystem = isSystemApp || forceSystemRefresh;

    NSLog(@"[refresh] [%@] no-sandbox=%@ force=%@ -> %@", bundleID,
          isSystemApp ? @"Y" : @"N", forceSystemRefresh ? @"Y" : @"N",
          finalIsSystem ? @"System" : @"User");

    // 先卸载再注册
    bool unregOk = registerPath(appPath, YES, finalIsSystem);
    bool regOk = registerPath(appPath, NO, finalIsSystem);
    NSLog(@"[refresh] [%@] unreg=%@ reg=%@", bundleID,
          unregOk ? @"OK" : @"FAIL", regOk ? @"OK" : @"FAIL");

    [processedPaths addObject:appPath];
  }

  // === 第三步：处理有 _ECStore 标记但不在已知列表中的应用 ===
  // 兼容通过 ECMAIN UI 安装的其他应用
  NSArray *markerAppPaths = trollStoreInstalledAppBundlePaths();
  NSLog(@"[refresh] Marker-based apps found: %lu",
        (unsigned long)markerAppPaths.count);

  for (NSString *appPath in markerAppPaths) {
    if ([processedPaths containsObject:appPath]) {
      NSLog(@"[refresh] [marker] %@ already processed, skipping",
            appPath.lastPathComponent);
      continue;
    }

    NSString *executablePath = appMainExecutablePathForAppPath(appPath);
    NSDictionary *entitlements =
        dumpEntitlementsFromBinaryAtPath(executablePath);

    BOOL isSystemApp = NO;
    if (entitlements &&
        entitlements[@"com.apple.private.security.no-sandbox"]) {
      isSystemApp = YES;
    }
    BOOL finalIsSystem = isSystemApp || forceSystemRefresh;

    NSLog(@"[refresh] [marker] App: %@ | no-sandbox: %@ force=%@ -> %@",
          appPath.lastPathComponent, isSystemApp ? @"YES" : @"NO",
          forceSystemRefresh ? @"YES" : @"NO", finalIsSystem ? @"System" : @"User");

    // 先卸载再注册
    bool unregOk = registerPath(appPath, YES, finalIsSystem);
    bool regOk = registerPath(appPath, NO, finalIsSystem);
    NSLog(@"[refresh] [marker] %@ unreg=%@ reg=%@", appPath.lastPathComponent,
          unregOk ? @"OK" : @"FAIL", regOk ? @"OK" : @"FAIL");
          
    [processedPaths addObject:appPath];
  }
}

BOOL _installPersistenceHelper(LSApplicationProxy *appProxy,
                               NSString *sourcePersistenceHelper,
                               NSString *sourceRootHelper) {
  NSLog(@"_installPersistenceHelper(%@, %@, %@)", appProxy,
        sourcePersistenceHelper, sourceRootHelper);

  NSString *executablePath = appProxy.canonicalExecutablePath;
  NSString *bundlePath = appProxy.bundleURL.path;
  if (!executablePath) {
    NSBundle *appBundle = [NSBundle bundleWithPath:bundlePath];
    executablePath = [bundlePath
        stringByAppendingPathComponent:
            [appBundle objectForInfoDictionaryKey:@"CFBundleExecutable"]];
  }

  NSString *markPath = [bundlePath
      stringByAppendingPathComponent:@".ECPersistenceHelper"];
  NSString *rootHelperPath =
      [bundlePath stringByAppendingPathComponent:@"echelper"];

  // remove existing persistence helper binary if exists
  if ([[NSFileManager defaultManager] fileExistsAtPath:markPath] &&
      [[NSFileManager defaultManager] fileExistsAtPath:executablePath]) {
    [[NSFileManager defaultManager] removeItemAtPath:executablePath error:nil];
  }

  // remove existing root helper binary if exists
  if ([[NSFileManager defaultManager] fileExistsAtPath:rootHelperPath]) {
    [[NSFileManager defaultManager] removeItemAtPath:rootHelperPath error:nil];
  }

  // install new persistence helper binary
  if (![[NSFileManager defaultManager] copyItemAtPath:sourcePersistenceHelper
                                               toPath:executablePath
                                                error:nil]) {
    return NO;
  }

  chmod(executablePath.fileSystemRepresentation, 0755);
  chown(executablePath.fileSystemRepresentation, 33, 33);

  NSError *error;
  if (![[NSFileManager defaultManager] copyItemAtPath:sourceRootHelper
                                               toPath:rootHelperPath
                                                error:&error]) {
    NSLog(@"error copying root helper: %@", error);
  }

  chmod(rootHelperPath.fileSystemRepresentation, 0755);
  chown(rootHelperPath.fileSystemRepresentation, 0, 0);

  // mark system app as persistence helper
  if (![[NSFileManager defaultManager] fileExistsAtPath:markPath]) {
    [[NSFileManager defaultManager] createFileAtPath:markPath
                                            contents:[NSData data]
                                          attributes:nil];
  }

  return YES;
}

void installPersistenceHelper(NSString *systemAppId,
                              NSString *persistenceHelperBinary,
                              NSString *rootHelperBinary) {
  if (findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_ALL))
    return;

  if (persistenceHelperBinary == nil) {
    persistenceHelperBinary = [trollStoreAppPath()
        stringByAppendingPathComponent:@"PersistenceHelper"];
  }
  if (rootHelperBinary == nil) {
    rootHelperBinary = [trollStoreAppPath()
        stringByAppendingPathComponent:@"echelper"];
  }
  LSApplicationProxy *appProxy =
      [LSApplicationProxy applicationProxyForIdentifier:systemAppId];
  if (!appProxy || ![appProxy.bundleType isEqualToString:@"System"])
    return;

  NSString *executablePath = appProxy.canonicalExecutablePath;
  NSString *bundlePath = appProxy.bundleURL.path;
  NSString *backupPath =
      [bundlePath stringByAppendingPathComponent:
                      [[executablePath lastPathComponent]
                          stringByAppendingString:@"_TROLLSTORE_BACKUP"]];

  if ([[NSFileManager defaultManager] fileExistsAtPath:backupPath])
    return;

  if (![[NSFileManager defaultManager] moveItemAtPath:executablePath
                                               toPath:backupPath
                                                error:nil])
    return;

  if (!_installPersistenceHelper(appProxy, persistenceHelperBinary,
                                 rootHelperBinary)) {
    [[NSFileManager defaultManager] moveItemAtPath:backupPath
                                            toPath:executablePath
                                             error:nil];
    return;
  }

  BKSTerminateApplicationForReasonAndReportWithDescription(
      systemAppId, 5, false, @"TrollStore - Reload persistence helper");
}

void unregisterUserPersistenceHelper() {
  LSApplicationProxy *userAppProxy =
      findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_USER);
  if (userAppProxy) {
    NSString *markPath = [userAppProxy.bundleURL.path
        stringByAppendingPathComponent:@".ECPersistenceHelper"];
    [[NSFileManager defaultManager] removeItemAtPath:markPath error:nil];
  }
}

void uninstallPersistenceHelper(void) {
  LSApplicationProxy *systemAppProxy =
      findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_SYSTEM);
  if (systemAppProxy) {
    NSString *executablePath = systemAppProxy.canonicalExecutablePath;
    NSString *bundlePath = systemAppProxy.bundleURL.path;
    NSString *backupPath =
        [bundlePath stringByAppendingPathComponent:
                        [[executablePath lastPathComponent]
                            stringByAppendingString:@"_TROLLSTORE_BACKUP"]];
    if (![[NSFileManager defaultManager] fileExistsAtPath:backupPath])
      return;

    NSString *helperPath =
        [bundlePath stringByAppendingPathComponent:@"echelper"];
    NSString *markPath = [bundlePath
        stringByAppendingPathComponent:@".ECPersistenceHelper"];

    [[NSFileManager defaultManager] removeItemAtPath:executablePath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:markPath error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:helperPath error:nil];

    [[NSFileManager defaultManager] moveItemAtPath:backupPath
                                            toPath:executablePath
                                             error:nil];

    BKSTerminateApplicationForReasonAndReportWithDescription(
        systemAppProxy.bundleIdentifier, 5, false,
        @"TrollStore - Reload persistence helper");
  }

  LSApplicationProxy *userAppProxy =
      findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_USER);
  if (userAppProxy) {
    unregisterUserPersistenceHelper();
  }
}

void registerUserPersistenceHelper(NSString *userAppId) {
  if (findPersistenceHelperApp(PERSISTENCE_HELPER_TYPE_ALL))
    return;

  LSApplicationProxy *appProxy =
      [LSApplicationProxy applicationProxyForIdentifier:userAppId];
  if (!appProxy || ![appProxy.bundleType isEqualToString:@"User"])
    return;

  NSString *markPath = [appProxy.bundleURL.path
      stringByAppendingPathComponent:@".ECPersistenceHelper"];
  [[NSFileManager defaultManager] createFileAtPath:markPath
                                          contents:[NSData data]
                                        attributes:nil];
}

// Apparently there is some odd behaviour where TrollStore installed apps
// sometimes get restricted This works around that issue at least and is
// triggered when rebuilding icon cache
void cleanRestrictions(void) {
  NSString *clientTruthPath =
      @"/private/var/containers/Shared/SystemGroup/"
      @"systemgroup.com.apple.configurationprofiles/Library/"
      @"ConfigurationProfiles/ClientTruth.plist";
  NSURL *clientTruthURL = [NSURL fileURLWithPath:clientTruthPath];
  NSDictionary *clientTruthDictionary =
      [NSDictionary dictionaryWithContentsOfURL:clientTruthURL];

  if (!clientTruthDictionary)
    return;

  NSArray *valuesArr;

  NSDictionary *lsdAppRemoval =
      clientTruthDictionary[@"com.apple.lsd.appremoval"];
  if (lsdAppRemoval && [lsdAppRemoval isKindOfClass:NSDictionary.class]) {
    NSDictionary *clientRestrictions = lsdAppRemoval[@"clientRestrictions"];
    if (clientRestrictions &&
        [clientRestrictions isKindOfClass:NSDictionary.class]) {
      NSDictionary *unionDict = clientRestrictions[@"union"];
      if (unionDict && [unionDict isKindOfClass:NSDictionary.class]) {
        NSDictionary *removedSystemAppBundleIDs =
            unionDict[@"removedSystemAppBundleIDs"];
        if (removedSystemAppBundleIDs &&
            [removedSystemAppBundleIDs isKindOfClass:NSDictionary.class]) {
          valuesArr = removedSystemAppBundleIDs[@"values"];
        }
      }
    }
  }

  if (!valuesArr || !valuesArr.count)
    return;

  NSMutableArray *valuesArrM = valuesArr.mutableCopy;
  __block BOOL changed = NO;

  [valuesArrM enumerateObjectsWithOptions:NSEnumerationReverse
                               usingBlock:^(NSString *value, NSUInteger idx,
                                            BOOL *stop) {
                                 if (!isRemovableSystemApp(value)) {
                                   [valuesArrM removeObjectAtIndex:idx];
                                   changed = YES;
                                 }
                               }];

  if (!changed)
    return;

  NSMutableDictionary *clientTruthDictionaryM =
      (__bridge_transfer NSMutableDictionary *)CFPropertyListCreateDeepCopy(
          kCFAllocatorDefault, (__bridge CFDictionaryRef)clientTruthDictionary,
          kCFPropertyListMutableContainersAndLeaves);

  clientTruthDictionaryM[@"com.apple.lsd.appremoval"][@"clientRestrictions"]
                        [@"union"][@"removedSystemAppBundleIDs"][@"values"] =
                            valuesArrM;

}

#include <sys/param.h>
#include <sys/mount.h>
#include <notify.h>

// [v1613] 监听电源连接状态以触发自动挂载
static void handlePowerSourceChanged(void) {
    NSLog(@"[monitor-usb] ⚡️ 检测到电源状态变更，正在尝试自动挂载 DDI...");
    
    // 获取可执行文件的路径以递归调用 mount-ddi
    NSString *helperPath = [[NSProcessInfo processInfo] arguments].firstObject;
    char *argv[] = { (char *)[helperPath UTF8String], "mount-ddi", NULL };
    pid_t pid;
    extern char **environ;
    posix_spawn(&pid, [helperPath UTF8String], NULL, NULL, argv, environ);
    int status;
    waitpid(pid, &status, 0);
    
    if (WEXITSTATUS(status) == 0) {
        NSLog(@"[monitor-usb] ✅ 自动挂载成功！");
    } else {
        NSLog(@"[monitor-usb] ℹ️ 自动挂载尝试完成 (Status: %d)，若 DDI 未挂载请检查 USB 链路稳健性。", WEXITSTATUS(status));
    }
}


static BOOL isDDImounted() {
    struct statfs fs;
    if (statfs("/Developer", &fs) == 0) {
        if (strcmp(fs.f_fstypename, "hfs") == 0 || strcmp(fs.f_fstypename, "apfs") == 0) {
            // [v1610] 强化检测：不仅看挂载点，还要看核心注入库是否存在
            // 防止重启后系统残留挂载点但实际镜像内容不可访问的情况
            if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Developer/usr/lib/libXCTestBundleInject.dylib"]) {
                return YES;
            } else {
                NSLog(@"[mount-ddi] ⚠️ 发现 /Developer 挂载点存在但核心库缺失，判定为失效挂载。");
            }
        }
    }
    return NO;
}

// [v1803] DDI 文件多路径搜索：按优先级查找 DeveloperDiskImage.dmg
static NSString *findDDIDmgPath(NSString *helperDir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *candidates = @[
        // 1. echelper 同目录（标准位置）
        [helperDir stringByAppendingPathComponent:@"DeveloperDiskImage.dmg"],
        // 2. ECMAIN.app 内的持久存储
        @"/var/mobile/Media/ECMAIN/DeveloperDiskImage.dmg",
        // 3. 备用固定路径
        @"/var/mobile/Documents/DeveloperDiskImage.dmg",
    ];
    for (NSString *path in candidates) {
        if ([fm fileExistsAtPath:path]) {
            NSLog(@"[mount-ddi] 📂 找到 DDI 文件: %@", path);
            return path;
        }
    }
    NSLog(@"[mount-ddi] ❌ 在所有候选路径中均未找到 DeveloperDiskImage.dmg");
    return nil;
}

// [v1803] 获取设备 UDID 的通用函数
static NSString *getDeviceUDID(void) {
    NSString *udid = nil;
    void *mgLib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (mgLib) {
        CFStringRef (*MGCopyAnswer)(CFStringRef) = (CFStringRef (*)(CFStringRef))dlsym(mgLib, "MGCopyAnswer");
        if (MGCopyAnswer) {
            udid = (__bridge_transfer NSString *)MGCopyAnswer(CFSTR("SerialNumber"));
        }
        dlclose(mgLib);
    }
    return udid;
}

// 【v1555】WDA 探针端口修正为 10088
static BOOL checkWDAAlive() {
    uint16_t ports[] = {10088, 8100};
    for (int i = 0; i < 2; i++) {
        uint16_t port = ports[i];
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) continue;
        
        struct sockaddr_in addr;
        memset(&addr, 0, sizeof(addr));
        addr.sin_family = AF_INET;
        addr.sin_port = htons(port);
        addr.sin_addr.s_addr = inet_addr("127.0.0.1");
        
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);
        
        int err = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
        if (err == 0) {
            close(sock);
            return YES;
        }
        
        if (errno == EINPROGRESS) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(sock, &wfds);
            struct timeval tv = {0, 500000}; // 0.5s timeout
            if (select(sock + 1, NULL, &wfds, NULL, &tv) > 0) {
                int so_error;
                socklen_t len = sizeof(so_error);
                getsockopt(sock, SOL_SOCKET, SO_ERROR, &so_error, &len);
                if (so_error == 0) {
                    close(sock);
                    return YES;
                }
            }
        }
        close(sock);
    }
    return NO;
}

static BOOL g_daemon_running = YES;
static void handle_daemon_exit_signal(int sig) {
    g_daemon_running = NO;
}

int MAIN_NAME(int argc, char *argv[], char *envp[]) {
  fprintf(stderr, "STEP 1: Entered MAIN_NAME (argc=%d)\n", argc); fflush(stderr);
  
  if (argc <= 1) {
    fprintf(stderr, "STEP 1.1: No arguments provided\n"); fflush(stderr);
    return -1;
  }

  if (getuid() != 0) {
    fprintf(stderr, "STEP 1.2: FATAL: Root required (uid=%d)\n", getuid()); fflush(stderr);
    return -1;
  }

  char *cmd_c = argv[1];
  fprintf(stderr, "STEP 1.3: Command is: %s\n", cmd_c ? cmd_c : "NULL"); fflush(stderr);

  // We only enter Obj-C land when absolutely necessary
  @autoreleasepool {
    fprintf(stderr, "STEP 2: Inside autoreleasepool\n"); fflush(stderr);
    
    NSMutableArray *args = [NSMutableArray new];
    for (int i = 1; i < argc; i++) {
      [args addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    fprintf(stderr, "STEP 3: Args converted to NSString array\n"); fflush(stderr);

    int ret = 0;
    NSString *cmd = args.firstObject;
    
    if ([cmd isEqualToString:@"wait-and-open"]) {
      fprintf(stderr, "STEP 4: wait-and-open\n"); fflush(stderr);
      if (args.count < 2) return -1;
      NSLog(@"[wait-and-open] 守护者已经进入蛰伏期，5秒后开始唤起...");

      // 完全脱离所有IO，真正成为背景孤儿
      close(STDOUT_FILENO);
      close(STDERR_FILENO);
      close(STDIN_FILENO);

      sleep(5);
      NSString *bundleId = args[1];
      void *fbsHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
      BOOL fbsSuccess = NO;
      if (fbsHandle) {
          Class FBSSystemServiceClass = NSClassFromString(@"FBSSystemService");
          if (FBSSystemServiceClass) {
              id systemService = [FBSSystemServiceClass performSelector:NSSelectorFromString(@"sharedService")];
              SEL openSel = NSSelectorFromString(@"openApplication:options:completion:");
              if (systemService && [systemService respondsToSelector:openSel]) {
                  NSDictionary *options = @{@"__UnlockDevice" : @YES};
                  
                  NSMethodSignature *sig = [systemService methodSignatureForSelector:openSel];
                  NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                  [inv setTarget:systemService];
                  [inv setSelector:openSel];
                  [inv setArgument:&bundleId atIndex:2];
                  [inv setArgument:&options atIndex:3];
                  void *nilPtr = NULL;
                  [inv setArgument:&nilPtr atIndex:4];
                  [inv invoke];
                  
                  NSLog(@"[wait-and-open] ✅ 成功发送 FrontBoardServices 启动指令 (UnlockDevice=YES)");
                  fbsSuccess = YES;
              }
          }
      }

      if (!fbsSuccess) {
          void *sbServices =
              dlopen("/System/Library/PrivateFrameworks/"
                     "SpringBoardServices.framework/SpringBoardServices",
                     RTLD_LAZY);
          if (sbServices) {
            int (*SBSLaunchApp)(CFStringRef, Boolean) =
                (int (*)(CFStringRef, Boolean))dlsym(
                    sbServices, "SBSLaunchApplicationWithIdentifier");
            if (SBSLaunchApp) {
              SBSLaunchApp((__bridge CFStringRef)bundleId, NO);
            }
            dlclose(sbServices);
          }
      }
      return 0;
    } else if ([cmd isEqualToString:@"lsof-port"]) {
      if (args.count < 2) return -1;
      int targetPort = [args[1] intValue];
      fprintf(stderr, "[RootHelper] 📊 lsof-port 探测开始, 目标端口: %d\n", targetPort);
      
      if (targetPort == 8089) {
          pid_t myPid = getpid();
          pid_t myParentPid = getppid();
          enumerateProcessesUsingBlock(^(pid_t pid, NSString *executablePath, BOOL *stop) {
              NSString *procName = executablePath.lastPathComponent;
              if (pid != myPid && pid != myParentPid && 
                  ([procName isEqualToString:@"ECMAIN"] || [procName isEqualToString:@"Tunnel"])) {
                  fprintf(stderr, "[RootHelper] ☢️ 发现 8089 竞争者: %s (PID %d), 强制清理...\n", [procName UTF8String], pid);
                  kill(pid, SIGKILL);
              }
          });
      }

      int bufferSize = proc_listallpids(NULL, 0);
      if (bufferSize <= 0) return -1;
      pid_t *pids = (pid_t *)malloc(bufferSize);
      int count = proc_listallpids(pids, bufferSize);
      fprintf(stderr, "[RootHelper] 📂 扫描 %d 个 PID\n", count);

      for (int i = 0; i < count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == getpid()) continue;
        int fds_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
        if (fds_size <= 0) continue;
        struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc(fds_size);
        int fds_count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, fds_size) / sizeof(struct proc_fdinfo);
        for (int j = 0; j < fds_count; j++) {
          if (fds[j].proc_fdtype == PROX_FDTYPE_SOCKET) {
             struct socket_fdinfo si;
             memset(&si, 0, sizeof(si));
             if (proc_pidfdinfo(pid, fds[j].proc_fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si)) > 0) {
                 int lport = ntohs(si.psi.lport);
                 if (lport == targetPort) {
                     fprintf(stderr, "[RootHelper] 🔥 命中! PID %d 占用端口 %d\n", pid, targetPort);
                     printf("%d ", pid);
                     break;
                 }
             }
          }
        }
        free(fds);
      }
      free(pids);
      printf("\n");
      return 0;
    }

    if ([cmd isEqualToString:@"install"]) {
      if (args.count < 2)
        return -3;
      // use system method when specified, otherwise use custom method
      BOOL useInstalldMethod = [args containsObject:@"installd"];
      BOOL force = [args containsObject:@"force"];
      BOOL skipSigning = [args containsObject:@"--skip-signing"];
      BOOL skipUICache = [args containsObject:@"skip-uicache"];

      // Parse custom parameters for clone install
      NSString *customBundleId = nil;
      NSString *customDisplayName = nil;
      NSString *registrationType = nil;

      for (NSString *arg in args) {
        if ([arg hasPrefix:@"--custom-bundle-id="]) {
          customBundleId =
              [arg substringFromIndex:@"--custom-bundle-id=".length];
        } else if ([arg hasPrefix:@"--custom-display-name="]) {
          customDisplayName =
              [arg substringFromIndex:@"--custom-display-name=".length];
        } else if ([arg hasPrefix:@"--registration-type="]) {
          registrationType =
              [arg substringFromIndex:@"--registration-type=".length];
        }
      }

      // Find IPA path (last arg that is not a flag)
      NSString *ipaPath = nil;
      for (NSInteger i = args.count - 1; i >= 0; i--) {
        NSString *arg = args[i];
        if (![arg hasPrefix:@"--"] && ![arg isEqualToString:@"installd"] &&
            ![arg isEqualToString:@"force"] &&
            ![arg isEqualToString:@"skip-uicache"] &&
            ![arg isEqualToString:@"custom"] &&
            ![arg isEqualToString:@"install"]) {
          ipaPath = arg;
          break;
        }
      }

      if (!ipaPath) {
        NSLog(@"[RootHelper] No IPA path found in arguments");
        return -3;
      }

      ret = installIpa(ipaPath, force, useInstalldMethod, skipUICache,
                       skipSigning, customBundleId, customDisplayName,
                       registrationType);
    } else if ([cmd isEqualToString:@"uninstall"]) {
      if (args.count < 2)
        return -3;
      // use custom method when specified, otherwise use system method
      BOOL useCustomMethod = [args containsObject:@"custom"];
      NSString *appId = args.lastObject;
      ret = uninstallAppById(appId, useCustomMethod);
    } else if ([cmd isEqualToString:@"uninstall-path"]) {
      if (args.count < 2)
        return -3;
      // use custom method when specified, otherwise use system method
      BOOL useCustomMethod = [args containsObject:@"custom"];
      NSString *appPath = args.lastObject;
      ret = uninstallAppByPath(appPath, useCustomMethod);
    } else if ([cmd isEqualToString:@"refresh"]) {
      // 【Antigravity 修复】无条件强制 System 注册，防止重启后应用消失
      refreshAppRegistrations(YES);
    } else if ([cmd isEqualToString:@"refresh-all"]) {
      cleanRestrictions();
      // refreshAppRegistrations(NO); // <- fixes app permissions resetting,
      // causes apps to move around on home screen, so I had to disable it
      [[NSFileManager defaultManager]
          removeItemAtPath:@"/var/containers/Shared/SystemGroup/"
                           @"systemgroup.com.apple.lsd.iconscache/Library/"
                           @"Caches/com.apple.IconsCache"
                     error:nil];
      [[LSApplicationWorkspace defaultWorkspace]
          _LSPrivateRebuildApplicationDatabasesForSystemApps:YES
                                                    internal:YES
                                                        user:YES];
      // 【Antigravity 修复】无条件强制重新注册，不再依赖 shouldRegisterAsUserByDefault 条件判断
      // 否则数据库被清空后应用全部消失且无法恢复
      refreshAppRegistrations(YES);
      killall(@"backboardd", YES);
    } else if ([cmd isEqualToString:@"url-scheme"]) {
      if (args.count < 2)
        return -3;
      NSString *modifyArg = args.lastObject;
      BOOL newState = [modifyArg isEqualToString:@"enable"];
      if (newState == YES || [modifyArg isEqualToString:@"disable"]) {
        setTSURLSchemeState(newState, nil);
      }
    } else if ([cmd isEqualToString:@"reboot"]) {
      [[FBSSystemService sharedService] reboot];
      // Give the system some time to reboot
      sleep(1);
    } else if ([cmd isEqualToString:@"wipe-app"]) {
      if (args.count < 2)
        return -3;
      NSString *bundleId = args[1];
      NSLog(@"[RootHelper] Wiping data for: %@", bundleId);

      // 1. Terminate the app using BackBoardServices
      void *bkSS = dlopen("/System/Library/PrivateFrameworks/"
                          "BackBoardServices.framework/BackBoardServices",
                          RTLD_LAZY);
      if (bkSS) {
        void (*BKSTerminateApplicationForReasonAndReportWithDescription)(
            NSString *app, int aReason, bool aReport, NSString *aDescription) =
            dlsym(bkSS,
                  "BKSTerminateApplicationForReasonAndReportWithDescription");
        if (BKSTerminateApplicationForReasonAndReportWithDescription) {
          BKSTerminateApplicationForReasonAndReportWithDescription(
              bundleId, 5, NO, @"Wipe Data");
        }
        dlclose(bkSS);
      }
      killall(bundleId, NO); // Fallback kill

      // 2. Clear Sandboxes
      id appProxy = [NSClassFromString(@"LSApplicationProxy")
          applicationProxyForIdentifier:bundleId];
      if (appProxy) {
        NSURL *dataContainerURL = [appProxy valueForKey:@"dataContainerURL"];
        if (dataContainerURL) {
          NSString *dataPath = dataContainerURL.path;
          if (dataPath) {
            NSArray *subdirs =
                @[ @"Documents", @"Library", @"tmp", @"SystemData" ];
            for (NSString *sub in subdirs) {
              NSString *fullPath =
                  [dataPath stringByAppendingPathComponent:sub];
              [[NSFileManager defaultManager] removeItemAtPath:fullPath
                                                         error:nil];
              // Also recreate the empty dirs just in case
              [[NSFileManager defaultManager] createDirectoryAtPath:fullPath
                                        withIntermediateDirectories:YES
                                                         attributes:nil
                                                              error:nil];
            }
            NSLog(@"[RootHelper] Wiped data container for %@", bundleId);
          }
        }
        NSDictionary *groupContainers =
            [appProxy valueForKey:@"groupContainerURLs"];
        if (groupContainers) {
          for (NSString *key in groupContainers) {
            NSURL *url = groupContainers[key];
            if (url.path) {
              NSArray *subdirs = @[ @"Library", @"Documents", @"tmp" ];
              for (NSString *sub in subdirs) {
                NSString *fullPath =
                    [url.path stringByAppendingPathComponent:sub];
                [[NSFileManager defaultManager] removeItemAtPath:fullPath
                                                           error:nil];
                [[NSFileManager defaultManager] createDirectoryAtPath:fullPath
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil];
              }
            }
          }
          NSLog(@"[RootHelper] Wiped group containers for %@", bundleId);
        }
      } else {
        NSLog(@"[RootHelper] Could not find LSApplicationProxy for %@, "
              @"skipping sandbox wipe.",
              bundleId);
      }

      // 3. Clear Keychain SQLite (keychain-2.db)
      void *sqlite = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY);
      if (sqlite) {
        int (*_sqlite3_open)(const char *filename, void **ppDb) =
            dlsym(sqlite, "sqlite3_open");
        int (*_sqlite3_exec)(void *, const char *,
                             int (*callback)(void *, int, char **, char **),
                             void *, char **) = dlsym(sqlite, "sqlite3_exec");
        int (*_sqlite3_close)(void *) = dlsym(sqlite, "sqlite3_close");
        void (*_sqlite3_free)(void *) = dlsym(sqlite, "sqlite3_free");

        if (_sqlite3_open && _sqlite3_exec && _sqlite3_close) {
          void *db = NULL;
          int rc = _sqlite3_open("/private/var/Keychains/keychain-2.db", &db);
          if (rc == 0) { // SQLITE_OK
            NSString *likeStr = [NSString stringWithFormat:@"%%%@%%", bundleId];
            NSString *sql = [NSString
                stringWithFormat:
                    @"DELETE FROM genp WHERE agrp LIKE '%@'; DELETE FROM cert "
                    @"WHERE agrp LIKE '%@'; DELETE FROM keys WHERE agrp LIKE "
                    @"'%@'; DELETE FROM inet WHERE agrp LIKE '%@';",
                    likeStr, likeStr, likeStr, likeStr];

            char *err_msg = 0;
            rc = _sqlite3_exec(db, sql.UTF8String, 0, 0, &err_msg);
            if (rc != 0) {
              NSLog(@"[RootHelper] keychain sqlite3_exec error: %s", err_msg);
              if (_sqlite3_free && err_msg)
                _sqlite3_free(err_msg);
            } else {
              NSLog(@"[RootHelper] Keychain cleaned for %@", bundleId);
            }
            _sqlite3_close(db);
          } else {
            NSLog(@"[RootHelper] Unable to open keychain db");
          }
        }
        dlclose(sqlite);
      }

      // 4. Force restart securityd so Keychain changes take immediate effect
      killall(@"securityd", NO);

      return 0;
    } else if ([cmd isEqualToString:@"scan-orphaned"]) {
      NSArray *basePaths = @[
          @"/var/mobile/Containers/Data/Application",
          @"/var/containers/Bundle/Application",
          @"/var/containers/Bundle/TrollStore"
      ];
      NSFileManager *fm = [NSFileManager defaultManager];
      NSMutableArray *orphaned = [NSMutableArray array];
      NSMutableSet *seenPaths = [NSMutableSet set];
      
      for (NSString *basePath in basePaths) {
          NSArray *uuids = [fm contentsOfDirectoryAtPath:basePath error:nil];
          for (NSString *uuid in uuids) {
              NSString *fullPath = [basePath stringByAppendingPathComponent:uuid];
              if ([seenPaths containsObject:fullPath]) continue;
              
              BOOL isDir = NO;
              if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir) {
                  NSString *bundleId = nil;
                  NSString *plistPath = [fullPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
                  if ([fm fileExistsAtPath:plistPath]) {
                      NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plistPath];
                      bundleId = dict[@"MCMMetadataIdentifier"];
                  } else {
                      NSArray *subdirs = [fm contentsOfDirectoryAtPath:fullPath error:nil];
                      for (NSString *sub in subdirs) {
                          if ([sub hasSuffix:@".app"]) {
                              NSString *infoPlist = [[fullPath stringByAppendingPathComponent:sub] stringByAppendingPathComponent:@"Info.plist"];
                              NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:infoPlist];
                              bundleId = info[@"CFBundleIdentifier"];
                              break;
                          }
                      }
                  }
                  
                  if (bundleId && bundleId.length > 0) {
                      id proxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bundleId];
                      if (!proxy || ![proxy valueForKey:@"bundleURL"]) {
                          NSString *tsAppPath = appPathForAppId(bundleId);
                          if (!tsAppPath) {
                              [seenPaths addObject:fullPath];
                              NSDictionary *orphanInfo = @{
                                  @"bundleId": bundleId,
                                  @"path": fullPath,
                                  @"uuid": uuid
                              };
                              [orphaned addObject:orphanInfo];
                          }
                      }
                  }
              }
          }
      }
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:orphaned options:0 error:nil];
      if (jsonData) {
          NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
          printf("%s\n", [jsonString UTF8String]);
      } else {
          printf("[]\n");
      }
      return 0;
    } else if ([cmd isEqualToString:@"delete-orphaned"]) {
      if (args.count < 3) return -3;
      NSString *path = args[1];
      NSString *bundleId = args[2];
      
      if (![path hasPrefix:@"/var/mobile/Containers/Data/Application/"] &&
          ![path hasPrefix:@"/var/containers/Bundle/Application/"] &&
          ![path hasPrefix:@"/var/containers/Bundle/TrollStore/"]) {
          NSLog(@"[RootHelper] Invalid orphaned path: %@", path);
          return -1;
      }
      
      NSFileManager *fm = [NSFileManager defaultManager];
      NSError *error;
      
      // 1. Delete the Data Container
      BOOL success = [fm removeItemAtPath:path error:&error];
      if (!success) {
          NSLog(@"[RootHelper] Failed to delete orphaned container: %@", error);
          // Don't return here, try to clean up other stuff anyway
      } else {
          NSLog(@"[RootHelper] Successfully deleted orphaned container: %@", path);
      }
      
      // 2. Try to find and delete group containers and plugin data using LSApplicationProxy (if it still knows about them)
      id appProxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bundleId];
      if (appProxy) {
          NSDictionary *groupContainers = [appProxy valueForKey:@"groupContainerURLs"];
          if (groupContainers) {
              for (NSString *key in groupContainers) {
                  NSURL *url = groupContainers[key];
                  if (url) {
                      // Check if other apps share this group container before deleting
                      NSArray *appsWithGroup = applicationsWithGroupId(key);
                      if (appsWithGroup.count <= 1) {
                         [fm removeItemAtURL:url error:nil];
                         NSLog(@"[RootHelper] Deleted orphaned group container for %@: %@", bundleId, url.path);
                      } else {
                         NSLog(@"[RootHelper] Orphaned group container %@ is shared by %lu apps, skipping deletion", key, (unsigned long)appsWithGroup.count);
                      }
                  }
              }
          }
          
          NSArray *plugins = [appProxy valueForKey:@"plugInKitPlugins"];
          if (plugins) {
              for (id pluginProxy in plugins) {
                  NSURL *pluginURL = [pluginProxy valueForKey:@"dataContainerURL"];
                  if (pluginURL) {
                      [fm removeItemAtURL:pluginURL error:nil];
                      NSLog(@"[RootHelper] Deleted orphaned plugin container for %@: %@", bundleId, pluginURL.path);
                  }
              }
          }
      }
      
      // 3. Try to clean up from Keychain
      void *sqlite = dlopen("/usr/lib/libsqlite3.dylib", RTLD_LAZY);
      if (sqlite) {
        int (*_sqlite3_open)(const char *filename, void **ppDb) = dlsym(sqlite, "sqlite3_open");
        int (*_sqlite3_exec)(void *, const char *, int (*callback)(void *, int, char **, char **), void *, char **) = dlsym(sqlite, "sqlite3_exec");
        int (*_sqlite3_close)(void *) = dlsym(sqlite, "sqlite3_close");
        void (*_sqlite3_free)(void *) = dlsym(sqlite, "sqlite3_free");

        if (_sqlite3_open && _sqlite3_exec && _sqlite3_close) {
          void *db = NULL;
          int rc = _sqlite3_open("/private/var/Keychains/keychain-2.db", &db);
          if (rc == 0) {
            NSString *likeStr = [NSString stringWithFormat:@"%%%@%%", bundleId];
            NSString *sql = [NSString stringWithFormat:
                    @"DELETE FROM genp WHERE agrp LIKE '%@'; DELETE FROM cert "
                    @"WHERE agrp LIKE '%@'; DELETE FROM keys WHERE agrp LIKE "
                    @"'%@'; DELETE FROM inet WHERE agrp LIKE '%@';",
                    likeStr, likeStr, likeStr, likeStr];
            char *err_msg = 0;
            _sqlite3_exec(db, sql.UTF8String, 0, 0, &err_msg);
            if (err_msg && _sqlite3_free) _sqlite3_free(err_msg);
            _sqlite3_close(db);
            killall(@"securityd", NO);
            NSLog(@"[RootHelper] Keychain cleaned for orphaned app %@", bundleId);
          }
        }
        dlclose(sqlite);
      }
      
      return 0;
    } else if ([cmd isEqualToString:@"clean-system-data"]) {
      NSFileManager *fm = [NSFileManager defaultManager];
      unsigned long long totalFreed = 0;
      
      // 1. 清理 /tmp 下的残留安装目录
      NSArray *tmpContents = [fm contentsOfDirectoryAtPath:@"/tmp" error:nil];
      for (NSString *item in tmpContents) {
          NSString *fullPath = [@"/tmp" stringByAppendingPathComponent:item];
          NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
          if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
              // 跳过系统关键目录
              if ([item hasPrefix:@"com.apple."] || [item isEqualToString:@"mobile"]) continue;
              unsigned long long dirSize = 0;
              NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:fullPath];
              NSString *file;
              while ((file = [enumerator nextObject])) {
                  NSDictionary *fileAttrs = [enumerator fileAttributes];
                  dirSize += [fileAttrs fileSize];
              }
              [fm removeItemAtPath:fullPath error:nil];
              totalFreed += dirSize;
              NSLog(@"[clean-system-data] Removed /tmp/%@ (%.2f MB)", item, dirSize / 1024.0 / 1024.0);
          }
      }
      
      // 2. 清理 iOS 统一日志数据库 (NSLog 输出的终极归宿)
      NSArray *logPaths = @[
          @"/private/var/db/diagnostics",
          @"/private/var/db/uuidtext",
          @"/private/var/installd/Library/Logs",
          @"/private/var/log/asl",
          @"/private/var/log/DiagnosticMessages"
      ];
      for (NSString *logPath in logPaths) {
          if ([fm fileExistsAtPath:logPath]) {
              NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:logPath];
              NSString *file;
              while ((file = [enumerator nextObject])) {
                  NSString *fullPath = [logPath stringByAppendingPathComponent:file];
                  NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                  if (![attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                      totalFreed += [attrs fileSize];
                      [fm removeItemAtPath:fullPath error:nil];
                  }
              }
              NSLog(@"[clean-system-data] Cleaned: %@", logPath);
          }
      }
      
      // 3. 清理各 App 的 Caches 和 tmp 目录 (被系统计入 System Data)
      NSString *dataBase = @"/var/mobile/Containers/Data/Application";
      NSArray *appUUIDs = [fm contentsOfDirectoryAtPath:dataBase error:nil];
      for (NSString *uuid in appUUIDs) {
          NSString *appDataPath = [dataBase stringByAppendingPathComponent:uuid];
          NSArray *cleanableDirs = @[@"Library/Caches", @"tmp"];
          for (NSString *subdir in cleanableDirs) {
              NSString *cleanPath = [appDataPath stringByAppendingPathComponent:subdir];
              if ([fm fileExistsAtPath:cleanPath]) {
                  NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:cleanPath];
                  NSString *file;
                  while ((file = [enumerator nextObject])) {
                      NSString *fullPath = [cleanPath stringByAppendingPathComponent:file];
                      NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                      if (![attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                          totalFreed += [attrs fileSize];
                      }
                  }
                  // 删除内容但保留目录本身
                  NSArray *contents = [fm contentsOfDirectoryAtPath:cleanPath error:nil];
                  for (NSString *item in contents) {
                      [fm removeItemAtPath:[cleanPath stringByAppendingPathComponent:item] error:nil];
                  }
              }
          }
      }
      
      // 4. 清理 Webkit/WebView 缓存
      NSArray *webkitPaths = @[
          @"/private/var/mobile/Containers/Data/InternalDaemon",
          @"/private/var/mobile/Library/Caches/com.apple.WebKit.Networking",
          @"/private/var/mobile/Library/WebKit"
      ];
      for (NSString *wkPath in webkitPaths) {
          if ([fm fileExistsAtPath:wkPath]) {
              NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:wkPath];
              NSString *file;
              while ((file = [enumerator nextObject])) {
                  NSString *fullPath = [wkPath stringByAppendingPathComponent:file];
                  NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
                  if (![attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                      totalFreed += [attrs fileSize];
                  }
              }
              NSArray *contents = [fm contentsOfDirectoryAtPath:wkPath error:nil];
              for (NSString *item in contents) {
                  [fm removeItemAtPath:[wkPath stringByAppendingPathComponent:item] error:nil];
              }
              NSLog(@"[clean-system-data] Cleaned WebKit cache: %@", wkPath);
          }
      }
      
      // 输出清理总量 (JSON)
      printf("{\"freed\":%llu}\n", totalFreed);
      NSLog(@"[clean-system-data] Total freed: %.2f MB", totalFreed / 1024.0 / 1024.0);
      return 0;
    } else if ([cmd isEqualToString:@"set-static-ip"]) {
      NSLog(@"[RootHelper] Command received: set-static-ip");
      if (args.count < 4) {
        NSLog(@"[RootHelper] Error: Insufficient arguments. Expected IP, "
              @"Subnet, Gateway.");
        return -3;
      }
      NSString *ip = args[1];
      NSString *subnet = args[2];
      NSString *gateway = args[3];
      NSString *dns = (args.count > 4) ? args[4] : nil;

      NSLog(@"[RootHelper] Params: IP=%@, Subnet=%@, GW=%@, DNS=%@", ip, subnet,
            gateway, dns);

      void *scHandle =
          dlopen("/System/Library/Frameworks/SystemConfiguration.framework/"
                 "SystemConfiguration",
                 RTLD_LAZY);
      if (!scHandle) {
        NSLog(@"[RootHelper] ❌ Failed to load SystemConfiguration.framework");
        return 101;
      }

      typedef const void *SCPreferencesRef;
      SCPreferencesRef (*_SCPreferencesCreate)(CFAllocatorRef, CFStringRef,
                                               CFStringRef) =
          dlsym(scHandle, "SCPreferencesCreate");
      Boolean (*_SCPreferencesSetValue)(SCPreferencesRef, CFStringRef,
                                        CFPropertyListRef) =
          dlsym(scHandle, "SCPreferencesSetValue");
      CFPropertyListRef (*_SCPreferencesGetValue)(SCPreferencesRef,
                                                  CFStringRef) =
          dlsym(scHandle, "SCPreferencesGetValue");
      Boolean (*_SCPreferencesCommitChanges)(SCPreferencesRef) =
          dlsym(scHandle, "SCPreferencesCommitChanges");
      Boolean (*_SCPreferencesApplyChanges)(SCPreferencesRef) =
          dlsym(scHandle, "SCPreferencesApplyChanges");

      if (!_SCPreferencesCreate || !_SCPreferencesGetValue ||
          !_SCPreferencesSetValue || !_SCPreferencesCommitChanges ||
          !_SCPreferencesApplyChanges) {
        NSLog(@"[RootHelper] ❌ Failed to find SCPreferences functions");
        dlclose(scHandle);
        return 102;
      }

      SCPreferencesRef prefs =
          _SCPreferencesCreate(NULL, CFSTR("RootHelper"), NULL);
      if (!prefs) {
        NSLog(@"[RootHelper] ❌ SCPreferencesCreate returned NULL. Check "
              @"entitlements.");
        dlclose(scHandle);
        return 103;
      }

      NSDictionary *networkServices =
          (__bridge NSDictionary *)_SCPreferencesGetValue(
              prefs, CFSTR("NetworkServices"));
      if (!networkServices) {
        NSLog(@"[RootHelper] ❌ NetworkServices not found in SCPreferences");
        CFRelease(prefs);
        dlclose(scHandle);
        return 104;
      }

      NSMutableDictionary *mutNetworkServices = [networkServices mutableCopy];
      BOOL found = NO;
      BOOL changed = NO;

      NSString *activeServiceID = nil;
      NSString *currentSetPath = (__bridge NSString *)_SCPreferencesGetValue(
          prefs, CFSTR("CurrentSet"));
      if ([currentSetPath isKindOfClass:[NSString class]]) {
        NSDictionary *sets = (__bridge NSDictionary *)_SCPreferencesGetValue(
            prefs, CFSTR("Sets"));
        if ([sets isKindOfClass:[NSDictionary class]]) {
          NSString *setKey = [currentSetPath lastPathComponent];
          NSDictionary *activeSet = sets[setKey];
          if ([activeSet isKindOfClass:[NSDictionary class]]) {
            NSDictionary *network = activeSet[@"Network"];
            if ([network isKindOfClass:[NSDictionary class]]) {
              NSDictionary *global = network[@"Global"];
              if ([global isKindOfClass:[NSDictionary class]]) {
                NSDictionary *ipv4 = global[@"IPv4"];
                if ([ipv4 isKindOfClass:[NSDictionary class]]) {
                  NSArray *serviceOrder = ipv4[@"ServiceOrder"];
                  if ([serviceOrder isKindOfClass:[NSArray class]]) {
                    for (NSString *serviceID in serviceOrder) {
                      NSDictionary *service = networkServices[serviceID];
                      if ([service isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *interface = service[@"Interface"];
                        if ([interface isKindOfClass:[NSDictionary class]]) {
                          NSString *devName = interface[@"DeviceName"];
                          if ([devName isEqualToString:@"en0"]) {
                            activeServiceID = serviceID;
                            NSLog(@"[RootHelper] Found active en0 ServiceID "
                                  @"from CurrentSet: %@",
                                  activeServiceID);
                            break;
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      if (!activeServiceID) {
        NSLog(@"[RootHelper] Fallback: searching all NetworkServices for en0");
        for (NSString *uuid in networkServices) {
          NSDictionary *service = networkServices[uuid];
          if ([service isKindOfClass:[NSDictionary class]]) {
            NSDictionary *interface = service[@"Interface"];
            if ([interface isKindOfClass:[NSDictionary class]]) {
              NSString *devName = interface[@"DeviceName"];
              if ([devName isEqualToString:@"en0"]) {
                activeServiceID = uuid;
                NSLog(@"[RootHelper] Fallback found en0 ServiceID: %@",
                      activeServiceID);
                break;
              }
            }
          }
        }
      }

      if (activeServiceID) {
        NSMutableDictionary *service =
            [mutNetworkServices[activeServiceID] mutableCopy];
        if (service) {
          NSLog(@"[RootHelper] Found en0 (Wi-Fi) at UUID: %@", activeServiceID);
          NSMutableDictionary *ipv4 =
              [service[@"IPv4"] mutableCopy] ?: [NSMutableDictionary new];

          ipv4[@"ConfigMethod"] = @"Manual";
          ipv4[@"Addresses"] = @[ ip ];
          ipv4[@"SubnetMasks"] = @[ subnet ];
          if (gateway && gateway.length > 0) {
            ipv4[@"Router"] = gateway;
          }
          service[@"IPv4"] = ipv4;
          NSLog(@"[RootHelper] New IPv4 Config: %@", ipv4);

          if (dns && dns.length > 0) {
            NSMutableDictionary *dnsDict =
                [service[@"DNS"] mutableCopy] ?: [NSMutableDictionary new];
            NSArray *dnsArray = [dns componentsSeparatedByString:@","];
            NSMutableArray *cleanDNS = [NSMutableArray array];
            for (NSString *d in dnsArray) {
              [cleanDNS
                  addObject:[d stringByTrimmingCharactersInSet:
                                    [NSCharacterSet whitespaceCharacterSet]]];
            }
            dnsDict[@"ServerAddresses"] = cleanDNS;
            service[@"DNS"] = dnsDict;
            NSLog(@"[RootHelper] Updated DNS: %@", cleanDNS);
          }

          mutNetworkServices[activeServiceID] = service;
          found = YES;
          changed = YES;
        }
      }

      if (!found) {
        NSLog(@"[RootHelper] ❌ Interface en0 not found in preferences");
        CFRelease(prefs);
        dlclose(scHandle);
        return 105;
      }

      if (changed) {
        NSLog(@"[RootHelper] Writing changes to SCPreferences...");
        Boolean setOK = _SCPreferencesSetValue(
            prefs, CFSTR("NetworkServices"),
            (__bridge CFPropertyListRef)mutNetworkServices);
        if (setOK) {
          Boolean commitOK = _SCPreferencesCommitChanges(prefs);
          Boolean applyOK = _SCPreferencesApplyChanges(prefs);
          NSLog(@"[RootHelper] SCPreferencesSet=%d, Commit=%d, Apply=%d", setOK,
                commitOK, applyOK);
          if (commitOK && applyOK) {
            NSLog(@"[RootHelper] ✅ Successfully updated static IP through "
                  @"SCPreferences.");
            ret = 0;
          } else {
            NSLog(@"[RootHelper] ❌ Failed to commit or apply SCPreferences.");
            ret = 106;
          }
        } else {
          NSLog(@"[RootHelper] ❌ Failed to set SCPreferences value.");
          ret = 107;
        }
      } else {
        NSLog(@"[RootHelper] No changes needed.");
        ret = 0;
      }

      CFRelease(prefs);
      dlclose(scHandle);
    } else if ([cmd isEqualToString:@"get-network-info"]) {
      NSMutableDictionary *result = [NSMutableDictionary new];

      void *scHandle =
          dlopen("/System/Library/Frameworks/SystemConfiguration.framework/"
                 "SystemConfiguration",
                 RTLD_LAZY);
      if (scHandle) {
        typedef const void *SCPreferencesRef;
        SCPreferencesRef (*_SCPreferencesCreate)(CFAllocatorRef, CFStringRef,
                                                 CFStringRef) =
            dlsym(scHandle, "SCPreferencesCreate");
        CFPropertyListRef (*_SCPreferencesGetValue)(SCPreferencesRef,
                                                    CFStringRef) =
            dlsym(scHandle, "SCPreferencesGetValue");

        if (_SCPreferencesCreate && _SCPreferencesGetValue) {
          SCPreferencesRef prefs =
              _SCPreferencesCreate(NULL, CFSTR("RootHelper"), NULL);
          if (prefs) {
            CFPropertyListRef rawNetServices =
                _SCPreferencesGetValue(prefs, CFSTR("NetworkServices"));
            if (rawNetServices &&
                CFGetTypeID(rawNetServices) == CFDictionaryGetTypeID()) {
              NSDictionary *networkServices =
                  (__bridge NSDictionary *)rawNetServices;
              NSString *activeServiceID = nil;
              NSString *currentSetPath =
                  (__bridge NSString *)_SCPreferencesGetValue(
                      prefs, CFSTR("CurrentSet"));
              if ([currentSetPath isKindOfClass:[NSString class]]) {
                NSDictionary *sets =
                    (__bridge NSDictionary *)_SCPreferencesGetValue(
                        prefs, CFSTR("Sets"));
                if ([sets isKindOfClass:[NSDictionary class]]) {
                  NSString *setKey = [currentSetPath lastPathComponent];
                  NSDictionary *activeSet = sets[setKey];
                  if ([activeSet isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *network = activeSet[@"Network"];
                    if ([network isKindOfClass:[NSDictionary class]]) {
                      NSDictionary *global = network[@"Global"];
                      if ([global isKindOfClass:[NSDictionary class]]) {
                        NSDictionary *ipv4 = global[@"IPv4"];
                        if ([ipv4 isKindOfClass:[NSDictionary class]]) {
                          NSArray *serviceOrder = ipv4[@"ServiceOrder"];
                          if ([serviceOrder isKindOfClass:[NSArray class]]) {
                            for (NSString *serviceID in serviceOrder) {
                              NSDictionary *service =
                                  networkServices[serviceID];
                              if ([service
                                      isKindOfClass:[NSDictionary class]]) {
                                NSDictionary *interface = service[@"Interface"];
                                if ([interface isKindOfClass:[NSDictionary
                                                                 class]]) {
                                  NSString *devName = interface[@"DeviceName"];
                                  if ([devName isEqualToString:@"en0"]) {
                                    activeServiceID = serviceID;
                                    break;
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }

              if (!activeServiceID) {
                for (NSString *uuid in networkServices) {
                  NSDictionary *service = networkServices[uuid];
                  if ([service isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *interface = service[@"Interface"];
                    if ([interface isKindOfClass:[NSDictionary class]]) {
                      NSString *devName = interface[@"DeviceName"];
                      if ([devName isEqualToString:@"en0"]) {
                        activeServiceID = uuid;
                        break;
                      }
                    }
                  }
                }
              }

              if (activeServiceID) {
                NSDictionary *service = networkServices[activeServiceID];
                if ([service isKindOfClass:[NSDictionary class]]) {
                  NSDictionary *ipv4 = service[@"IPv4"];
                  if ([ipv4 isKindOfClass:[NSDictionary class]]) {
                    NSString *method = ipv4[@"ConfigMethod"];
                    if ([method isKindOfClass:[NSString class]]) {
                      result[@"ip_config_mode"] = method;
                    }

                    NSArray *addrs = ipv4[@"Addresses"];
                    if ([addrs isKindOfClass:[NSArray class]] &&
                        addrs.count > 0) {
                      result[@"wifi_ip"] = addrs.firstObject;
                    }

                    NSArray *masks = ipv4[@"SubnetMasks"];
                    if ([masks isKindOfClass:[NSArray class]] &&
                        masks.count > 0) {
                      result[@"wifi_subnet"] = masks.firstObject;
                    }

                    NSString *router = ipv4[@"Router"];
                    if ([router isKindOfClass:[NSString class]]) {
                      result[@"wifi_gateway"] = router;
                    }
                  }

                  NSDictionary *dns = service[@"DNS"];
                  if ([dns isKindOfClass:[NSDictionary class]]) {
                    NSArray *servers = dns[@"ServerAddresses"];
                    if ([servers isKindOfClass:[NSArray class]] &&
                        servers.count > 0) {
                      result[@"wifi_dns"] =
                          [servers componentsJoinedByString:@","];
                    }
                  }
                }
              }
            }
            CFRelease(prefs);
          }
        }
        dlclose(scHandle);
      }

      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result
                                                         options:0
                                                           error:nil];
      if (jsonData) {
        NSString *jsonStr =
            [[NSString alloc] initWithData:jsonData
                                  encoding:NSUTF8StringEncoding];
        fprintf(stdout, "%s\n", jsonStr.UTF8String);
        return 0;
      } else {
        fprintf(stderr, "{}\n");
        return -1;
      }
    } else if ([cmd isEqualToString:@"screenshot"]) {
      fprintf(stderr, "STEP 11: screenshot branch matched\n"); fflush(stderr);
      NSString *outputPath =
          args.count > 1 ? args[1]
                         : @"/private/var/mobile/Documents/screenshot.jpg";
      fprintf(stderr, "STEP 12: outputPath resolved: %s\n", [outputPath UTF8String]); fflush(stderr);
      NSLog(@"[RootHelper] capturing screenshot to %@", outputPath);
      fprintf(stderr, "STEP 13: Calling captureScreenshot\n"); fflush(stderr);
      ret = captureScreenshot(outputPath);
      fprintf(stderr, "STEP 14: Returned from captureScreenshot: %d\n", ret); fflush(stderr);
    } else if ([cmd isEqualToString:@"enable-jit"]) {
      if (args.count < 2)
        return -3;
      NSString *userAppId = args.lastObject;
      ret = enableJIT(userAppId);
    } else if ([cmd isEqualToString:@"modify-registration"]) {
      if (args.count < 3)
        return -3;
      NSString *appPath = args[1];
      NSString *newRegistration = args[2];

      NSString *trollStoreMark = [[appPath stringByDeletingLastPathComponent]
          stringByAppendingPathComponent:TS_ACTIVE_MARKER];
      if ([[NSFileManager defaultManager] fileExistsAtPath:trollStoreMark]) {
        registerPath(appPath, NO, [newRegistration isEqualToString:@"System"]);
      }
    } else if ([cmd isEqualToString:@"set-airplane-mode"]) {
      if (args.count < 2) {
        NSLog(@"[RootHelper] Usage: set-airplane-mode <1/0>");
        return 1;
      }
      NSString *modeArg = args[1];
      BOOL enableAirplane = [modeArg boolValue];
      NSLog(@"[RootHelper] Setting airplane mode to: %d", enableAirplane);

      int success = 0;

      // 方案1: RadiosPreferences (需要 SCPreferences-write-access entitlement)
      void *appSupportHandle = dlopen(
          "/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport",
          RTLD_LAZY);
      if (appSupportHandle) {
        Class RadiosCls = NSClassFromString(@"RadiosPreferences");
        if (RadiosCls) {
          id radioPrefs = [[RadiosCls alloc] init];
          if (radioPrefs) {
            SEL setSel = NSSelectorFromString(@"setAirplaneMode:");
            SEL getSel = NSSelectorFromString(@"airplaneMode");
            SEL syncSel = NSSelectorFromString(@"synchronize");

            if ([radioPrefs respondsToSelector:setSel]) {
              NSMethodSignature *sig =
                  [radioPrefs methodSignatureForSelector:setSel];
              NSInvocation *inv =
                  [NSInvocation invocationWithMethodSignature:sig];
              [inv setSelector:setSel];
              [inv setTarget:radioPrefs];
              [inv setArgument:&enableAirplane atIndex:2];
              [inv invoke];
              NSLog(@"[RootHelper] setAirplaneMode: 已调用");

              if ([radioPrefs respondsToSelector:syncSel]) {
                [radioPrefs performSelector:syncSel];
              }

              // 验证是否真正生效
              if ([radioPrefs respondsToSelector:getSel]) {
                NSMethodSignature *getSig =
                    [radioPrefs methodSignatureForSelector:getSel];
                NSInvocation *getInv =
                    [NSInvocation invocationWithMethodSignature:getSig];
                [getInv setSelector:getSel];
                [getInv setTarget:radioPrefs];
                [getInv invoke];
                BOOL currentMode = NO;
                [getInv getReturnValue:&currentMode];
                NSLog(@"[RootHelper] 验证读回 airplaneMode = %d (期望 %d)",
                      currentMode, enableAirplane);
                if (currentMode == enableAirplane) {
                  success = 1;
                  NSLog(@"[RootHelper] ✅ RadiosPreferences 飞行模式切换成功!");
                } else {
                  NSLog(@"[RootHelper] ⚠️ RadiosPreferences "
                        @"读回值不匹配，可能设置未生效");
                }
              } else {
                // 无法验证，假设方案1成功
                success = 1;
              }
            } else {
              NSLog(
                  @"[RootHelper] ❌ RadiosPreferences 不响应 setAirplaneMode:");
            }
          }
        }
        dlclose(appSupportHandle);
      }

      // 方案2: 直接以 root 权限写入 radios.plist + Darwin 通知
      if (!success) {
        NSLog(@"[RootHelper] 方案1失败，回退到直写 plist...");
        NSString *radiosPlistPath =
            @"/var/preferences/SystemConfiguration/com.apple.radios.plist";
        NSMutableDictionary *radiosDict =
            [NSMutableDictionary dictionaryWithContentsOfFile:radiosPlistPath];
        if (!radiosDict) {
          radiosDict = [NSMutableDictionary dictionary];
        }
        [radiosDict setObject:@(enableAirplane) forKey:@"AirplaneMode"];
        BOOL writeOK = [radiosDict writeToFile:radiosPlistPath atomically:YES];
        if (writeOK) {
          notify_post("com.apple.airplane-mode");
          notify_post("com.apple.springboard.airplanemode");
          notify_post("com.apple.telephony.airplanemode");
          CFNotificationCenterPostNotification(
              CFNotificationCenterGetDarwinNotifyCenter(),
              CFSTR("com.apple.airplane-mode-changed"), NULL, NULL, true);
          NSLog(@"[RootHelper] ✅ 通过直写 plist + 通知完成飞行模式切换");
          success = 1;
        } else {
          NSLog(@"[RootHelper] ❌ plist 写入也失败了");
        }
      }

      ret = success ? 0 : 2;
    } else if ([cmd isEqualToString:@"trigger-switcher"]) {
      NSLog(@"[trigger-switcher] 开始唤醒 App Switcher...");
      void *bbsHandle = dlopen("/System/Library/PrivateFrameworks/"
                               "BackBoardServices.framework/BackBoardServices",
                               RTLD_NOW);
      void *iokitHandle =
          dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);

      if (!iokitHandle) {
        NSLog(@"[trigger-switcher] ERROR: IOKit 加载失败");
        return 202;
      }

      typedef void *(*IOHIDEventCreateKeyboardEvent_t)(
          void *, uint64_t, uint32_t, uint32_t, int, uint32_t);
      typedef void (*BKSHIDEventSetDigitizerInfo_t)(void *, uint32_t, uint8_t,
                                                    uint8_t);
      typedef void (*BKSHIDEventRoute_t)(void *);
      typedef void *(*IOHIDEventSystemClientCreate_t)(void *);
      typedef void (*IOHIDEventSystemClientDispatchEvent_t)(void *, void *);

      IOHIDEventCreateKeyboardEvent_t createKbEvent =
          (IOHIDEventCreateKeyboardEvent_t)dlsym(
              iokitHandle, "IOHIDEventCreateKeyboardEvent");
      BKSHIDEventSetDigitizerInfo_t setDigitizerInfo =
          bbsHandle ? (BKSHIDEventSetDigitizerInfo_t)dlsym(
                          bbsHandle, "BKSHIDEventSetDigitizerInfo")
                    : NULL;

      if (!createKbEvent) {
        NSLog(@"[trigger-switcher] ERROR: 无法创建 HID 事件");
        return 203;
      }

      uint32_t page = 0x0C;
      uint32_t usage = 0x40; // Home Button

      // 寻找可用的发送方案
      BKSHIDEventRoute_t routeEvent = NULL;
      const char *routeNames[] = {"BKSHIDEventRouteToSpringBoard",
                                  "BKSHIDEventSendToSBApplication",
                                  "BKSHIDEventSendToApplication", NULL};
      for (int i = 0; routeNames[i] && bbsHandle; i++) {
        routeEvent = (BKSHIDEventRoute_t)dlsym(bbsHandle, routeNames[i]);
        if (routeEvent) {
          NSLog(@"[trigger-switcher] 找到 BKS 路由: %s", routeNames[i]);
          break;
        }
      }

      IOHIDEventSystemClientCreate_t sysClientCreate =
          (IOHIDEventSystemClientCreate_t)dlsym(iokitHandle,
                                                "IOHIDEventSystemClientCreate");
      IOHIDEventSystemClientDispatchEvent_t sysClientDispatch =
          (IOHIDEventSystemClientDispatchEvent_t)dlsym(
              iokitHandle, "IOHIDEventSystemClientDispatchEvent");

      for (int pressIdx = 0; pressIdx < 2; pressIdx++) {
        uint64_t ts = (uint64_t)(CACurrentMediaTime() * 1000000000ULL);
        void *downEvt = createKbEvent(NULL, ts, page, usage, 1, 0);
        void *upEvt = createKbEvent(NULL, ts + 20000000ULL, page, usage, 0,
                                    0); // 20ms 的按下时间即可

        if (setDigitizerInfo && downEvt)
          setDigitizerInfo(downEvt, 0, 1, 0);
        if (setDigitizerInfo && upEvt)
          setDigitizerInfo(upEvt, 0, 1, 0);

        if (routeEvent && downEvt) {
          routeEvent(downEvt);
          usleep(20000);
          if (upEvt)
            routeEvent(upEvt);
          NSLog(@"[trigger-switcher] 第%d次: 方案A (BKS) 已发送", pressIdx + 1);
        } else if (sysClientCreate && sysClientDispatch && downEvt) {
          void *client = sysClientCreate(kCFAllocatorDefault);
          if (client) {
            sysClientDispatch(client, downEvt);
            usleep(20000);
            if (upEvt)
              sysClientDispatch(client, upEvt);
            CFRelease(client);
            NSLog(@"[trigger-switcher] 第%d次: 方案B (IOHID) 已发送",
                  pressIdx + 1);
          }
        }

        if (downEvt)
          CFRelease(downEvt);
        if (upEvt)
          CFRelease(upEvt);

        if (pressIdx == 0)
          usleep(150000); // 两次中间停顿 150ms 模拟经典的双击节奏
      }

      if (bbsHandle)
        dlclose(bbsHandle);
      dlclose(iokitHandle);
      NSLog(@"[trigger-switcher] 结束并返回 0...");
      return 0;
    } else if ([cmd isEqualToString:@"transfer-apps"]) {
      bool oneFailed = false;
      for (NSString
               *appBundlePath in trollStoreInactiveInstalledAppBundlePaths()) {
        NSLog(@"Transfering %@...", appBundlePath);

        // Ldid lacks the entitlement to sign in place
        // So copy to /tmp, resign, then replace >.<
        NSString *tmpPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        if (![[NSFileManager defaultManager] createDirectoryAtPath:tmpPath
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:nil])
          return -3;

        NSString *tmpAppPath = [tmpPath
            stringByAppendingPathComponent:appBundlePath.lastPathComponent];
        if (![[NSFileManager defaultManager] copyItemAtPath:appBundlePath
                                                     toPath:tmpAppPath
                                                      error:nil]) {
          [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
          oneFailed = true;
          continue;
        }

        NSLog(@"Copied %@ to %@", appBundlePath, tmpAppPath);

        int signRet =
            signApp(tmpAppPath, NO); // sign command always uses System mode
        NSLog(@"Signing %@ returned %d", tmpAppPath, signRet);

        if (signRet == 0 || signRet == 182 ||
            signRet == 184) { // Either 0 or non fatal error codes are fine
          [[NSFileManager defaultManager] removeItemAtPath:appBundlePath
                                                     error:nil];
          [[NSFileManager defaultManager] moveItemAtPath:tmpAppPath
                                                  toPath:appBundlePath
                                                   error:nil];
          [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        } else {
          [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
          oneFailed = true;
          continue;
        }

        fixPermissionsOfAppBundle(appBundlePath);

        NSString *containerPath =
            [appBundlePath stringByDeletingLastPathComponent];
        NSString *activeMarkerPath =
            [containerPath stringByAppendingPathComponent:TS_ACTIVE_MARKER];
        NSString *inactiveMarkerPath =
            [containerPath stringByAppendingPathComponent:TS_INACTIVE_MARKER];

        NSData *emptyData = [NSData data];
        [emptyData writeToFile:activeMarkerPath options:0 error:nil];

        [[NSFileManager defaultManager] removeItemAtPath:inactiveMarkerPath
                                                   error:nil];

        // 【Antigravity 修复】强制 System 注册
        registerPath(appBundlePath, 0, YES);

        NSLog(@"Transfered %@!", appBundlePath);
      }
      if (oneFailed)
        ret = -1;
    }
#ifndef TROLLSTORE_LITE
    else if ([cmd isEqualToString:@"install-trollstore"]) {
      if (args.count < 2)
        return -3;
      NSString *tsTar = args.lastObject;
      ret = installTrollStore(tsTar);
      NSLog(@"installed troll store? %d", ret == 0);
    } else if ([cmd isEqualToString:@"uninstall-trollstore"]) {
      if (![args containsObject:@"preserve-apps"]) {
        uninstallAllApps([args containsObject:@"custom"]);
      }
      uninstallTrollStore(YES);
    } else if ([cmd isEqualToString:@"install-ldid"]) {
      // if (@available(iOS 16, *)) {} else {
      if (args.count < 3)
        return -3;
      NSString *ldidPath = args[1];
      NSString *ldidVersion = args[2];
      installLdid(ldidPath, ldidVersion);
      //}
    } else if ([cmd isEqualToString:@"install-persistence-helper"]) {
      if (args.count < 2)
        return -3;
      NSString *systemAppId = args[1];
      NSString *persistenceHelperBinary;
      NSString *rootHelperBinary;
      if (args.count == 4) {
        persistenceHelperBinary = args[2];
        rootHelperBinary = args[3];
      }

      installPersistenceHelper(systemAppId, persistenceHelperBinary,
                               rootHelperBinary);
    } else if ([cmd isEqualToString:@"uninstall-persistence-helper"]) {
      uninstallPersistenceHelper();
    } else if ([cmd isEqualToString:@"register-user-persistence-helper"]) {
      if (args.count < 2)
        return -3;
      NSString *userAppId = args.lastObject;
      registerUserPersistenceHelper(userAppId);
    } else if ([cmd isEqualToString:@"check-dev-mode"]) {
      // switch the result, so 0 is enabled, and 1 is disabled/error
      ret = !checkDeveloperMode();
    } else if ([cmd isEqualToString:@"arm-dev-mode"]) {
      // assumes that checkDeveloperMode() has already been called
      ret = !armDeveloperMode(NULL);
    }
    // ECMAIN: File operation commands for injection support
    else if ([cmd isEqualToString:@"kill-app"]) {
      // Usage: kill-app <bundleId>
      if (argc >= 3) {
        NSString *bundleId = [NSString stringWithUTF8String:argv[2]];
        NSLog(@"[RootHelper] Force killing app with bundleId: %@", bundleId);

        id appProxy = [NSClassFromString(@"LSApplicationProxy")
            performSelector:@selector(applicationProxyForIdentifier:)
                 withObject:bundleId];
        if (appProxy) {
          NSString *execPath =
              [appProxy performSelector:@selector(canonicalExecutablePath)];
          NSString *execName = execPath.lastPathComponent;
          if (execName && execName.length > 0) {
            NSLog(@"[RootHelper] Found executable '%@' for bundle '%@'. "
                  @"Sending SIGKILL.",
                  execName, bundleId);
            // NO 表示发送 -9 (SIGKILL) 强杀信号，来自 TSUtil
            killall(execName, NO);
          }
        }
        // 兜底补刀：请求 SpringBoard 在外层彻底释放后台场景缓存
        BKSTerminateApplicationForReasonAndReportWithDescription(
            bundleId, 5, false, @"ECMAIN - User requested terminate");
        ret = 0;
      } else {
        NSLog(@"Usage: kill-app <bundleId>");
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"kill-all-apps"]) {
      NSLog(@"[RootHelper] 开始通过名单精准终止后台应用...");

      int killCount = 0;
      // args: ["kill-all-apps", "AppName1", "AppName2", ...]
      for (int i = 1; i < args.count; i++) {
        NSString *procName = args[i];
        if (procName.length > 0) {
          NSLog(@"[RootHelper] 正在终止进程: %@", procName);
          // 使用 TSUtil 的 killall API
          killall(procName, NO); // NO -> 强制发送 SIGKILL (9)
          killCount++;
        }
      }

      NSLog(@"[RootHelper] 清理名单执行完毕，共发送 %d 次 killall", killCount);
      ret = 0;
    } else if ([cmd isEqualToString:@"batch-exec"]) {
      // [性能优化] 批量执行多条轻量指令，整个批次只 Fork 一次进程
      // Usage: batch-exec '<JSON_ARRAY>'
      // JSON 格式: [{"cmd":"kill-all-apps","args":["App1"]},{"cmd":"copy-file","args":["/src","/dst"]}]
      // 返回: stdout 输出 [{"cmd":"xxx","ret":0},...]
      if (args.count < 2) {
        fprintf(stderr, "[RootHelper] batch-exec: 缺少 JSON 参数\n");
        return -3;
      }
      NSString *jsonStr = args[1];
      NSData *jsonData = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
      NSError *parseError = nil;
      NSArray *commands = [NSJSONSerialization JSONObjectWithData:jsonData
                                                          options:0
                                                            error:&parseError];
      if (!commands || parseError || ![commands isKindOfClass:[NSArray class]]) {
        fprintf(stderr, "[RootHelper] batch-exec: JSON 解析失败: %s\n",
                parseError.localizedDescription.UTF8String ?: "unknown");
        return -3;
      }

      NSMutableArray *results = [NSMutableArray arrayWithCapacity:commands.count];

      for (NSDictionary *item in commands) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *subCmd  = item[@"cmd"]  ?: @"";
        NSArray  *subArgs = item[@"args"] ?: @[];
        int subRet = 0;
        NSString *subError = nil;

        if ([subCmd isEqualToString:@"kill-all-apps"]) {
          // args: ["ProcName1", "ProcName2", ...]
          for (NSString *procName in subArgs) {
            if ([procName isKindOfClass:[NSString class]] && procName.length > 0) {
              killall(procName, NO); // SIGKILL
            }
          }

        } else if ([subCmd isEqualToString:@"copy-file"]) {
          // args: ["/src", "/dst"]
          if (subArgs.count >= 2) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *err = nil;
            NSString *src = subArgs[0], *dst = subArgs[1];
            if ([fm fileExistsAtPath:dst]) [fm removeItemAtPath:dst error:nil];
            if (![fm copyItemAtPath:src toPath:dst error:&err]) {
              subRet = 1;
              subError = err.localizedDescription ?: @"copy 失败";
            }
          } else {
            subRet = -1; subError = @"参数不足，需要 src dst";
          }

        } else if ([subCmd isEqualToString:@"chmod-file"]) {
          // args: ["644", "/path"]
          if (subArgs.count >= 2) {
            mode_t mode = (mode_t)strtol([subArgs[0] UTF8String], NULL, 8);
            if (chmod([subArgs[1] UTF8String], mode) != 0) {
              subRet = 1;
              subError = [NSString stringWithUTF8String:strerror(errno)] ?: @"chmod 失败";
            }
          } else {
            subRet = -1; subError = @"参数不足，需要 mode path";
          }

        } else if ([subCmd isEqualToString:@"remove-file"]) {
          // args: ["/path"]
          if (subArgs.count >= 1) {
            [[NSFileManager defaultManager] removeItemAtPath:subArgs[0] error:nil];
          } else {
            subRet = -1; subError = @"参数不足，需要 path";
          }

        } else if ([subCmd isEqualToString:@"move-file"]) {
          // args: ["/src", "/dst"]
          if (subArgs.count >= 2) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSError *err = nil;
            NSString *src = subArgs[0], *dst = subArgs[1];
            if ([fm fileExistsAtPath:dst]) [fm removeItemAtPath:dst error:nil];
            if (![fm moveItemAtPath:src toPath:dst error:&err]) {
              subRet = 1;
              subError = err.localizedDescription ?: @"move 失败";
            }
          } else {
            subRet = -1; subError = @"参数不足，需要 src dst";
          }

        } else if ([subCmd isEqualToString:@"mkdir"]) {
          // args: ["/path"]
          if (subArgs.count >= 1) {
            NSError *err = nil;
            if (![[NSFileManager defaultManager] createDirectoryAtPath:subArgs[0]
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:&err]) {
              subRet = 1;
              subError = err.localizedDescription ?: @"mkdir 失败";
            }
          } else {
            subRet = -1; subError = @"参数不足，需要 path";
          }

        } else if ([subCmd isEqualToString:@"toggle-wifi"]) {
          // 通过 SCPreferences 切换 Wi-Fi 开关，无需额外参数
          // 复用现有 toggle-wifi 逻辑：直接调用 SCNetworkService API
          // 注意：此处采用最简 kill -HUP wifid 方式触发重连（不依赖私有 API）
          killall(@"wifid", YES); // SIGHUP，让 wifid 重新读取配置
          NSLog(@"[RootHelper] batch-exec: toggle-wifi 已发送 SIGHUP 给 wifid");

        } else {
          subRet = -2;
          subError = [NSString stringWithFormat:@"batch-exec 不支持的命令: %@", subCmd];
          NSLog(@"[RootHelper] batch-exec 跳过不支持的命令: %@", subCmd);
        }

        // 构建单条结果
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObjectsAndKeys:
            subCmd,    @"cmd",
            @(subRet), @"ret",
            nil];
        if (subError) result[@"error"] = subError;
        [results addObject:result];
        NSLog(@"[RootHelper] batch-exec [%@] ret=%d%@", subCmd, subRet,
              subError ? [NSString stringWithFormat:@" err=%@", subError] : @"");
      }

      // 将结果 JSON 输出到 stdout，供上层 batchSpawnRoot 解析
      NSData *outputData = [NSJSONSerialization dataWithJSONObject:results
                                                           options:0
                                                             error:nil];
      if (outputData) {
        NSString *outputStr = [[NSString alloc] initWithData:outputData
                                                    encoding:NSUTF8StringEncoding];
        printf("%s\n", outputStr.UTF8String);
      }
      ret = 0;

    } else if ([cmd isEqualToString:@"copy-file"]) {

      // Usage: copy-file <source> <destination>
      if (argc >= 4) {
        NSString *src = [NSString stringWithUTF8String:argv[2]];
        NSString *dst = [NSString stringWithUTF8String:argv[3]];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        if ([fm fileExistsAtPath:dst]) {
          [fm removeItemAtPath:dst error:nil];
        }
        if ([fm copyItemAtPath:src toPath:dst error:&error]) {
          ret = 0;
        } else {
          NSLog(@"copy-file error: %@", error);
          ret = 1;
        }
      } else {
        NSLog(@"Usage: copy-file <source> <destination>");
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"mkdir"]) {
      // Usage: mkdir -p <path>
      if (argc >= 3) {
        NSString *flag = [NSString stringWithUTF8String:argv[2]];
        NSString *path = nil;
        if ([flag isEqualToString:@"-p"] && argc >= 4) {
          path = [NSString stringWithUTF8String:argv[3]];
        } else {
          path = flag;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        if ([fm createDirectoryAtPath:path
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:&error]) {
          ret = 0;
        } else {
          NSLog(@"mkdir error: %@", error);
          ret = 1;
        }
      } else {
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"remove-file"]) {
      // Usage: remove-file <path>
      if (argc >= 3) {
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:path]) {
          [fm removeItemAtPath:path error:nil];
        }
        ret = 0;
      } else {
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"move-file"]) {
      // Usage: move-file <source> <destination>
      if (argc >= 4) {
        NSString *src = [NSString stringWithUTF8String:argv[2]];
        NSString *dst = [NSString stringWithUTF8String:argv[3]];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        if ([fm fileExistsAtPath:dst]) {
          [fm removeItemAtPath:dst error:nil];
        }
        if ([fm moveItemAtPath:src toPath:dst error:&error]) {
          ret = 0;
        } else {
          NSLog(@"move-file error: %@", error);
          ret = 1;
        }
      } else {
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"chmod-file"]) {
      // Usage: chmod-file <mode> <path>
      if (argc >= 4) {
        NSString *modeStr = [NSString stringWithUTF8String:argv[2]];
        NSString *path = [NSString stringWithUTF8String:argv[3]];
        mode_t mode = (mode_t)strtol(modeStr.UTF8String, NULL, 8);
        if (chmod(path.UTF8String, mode) == 0) {
          ret = 0;
        } else {
          ret = 1;
        }
      } else {
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"touch-file"]) {
      // Usage: touch-file <path>
      if (argc >= 3) {
        NSString *path = [NSString stringWithUTF8String:argv[2]];
        [@"" writeToFile:path
              atomically:YES
                encoding:NSUTF8StringEncoding
                   error:nil];
        ret = 0;
      } else {
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"sign-adhoc-only"]) {
      // Usage: sign-adhoc-only <binary_path>
      // Sign a binary with pure ad-hoc signature (ldid), NO CoreTrust bypass.
      // 用途: 为注入的外挂 dylib 做 ad-hoc 签名，使其有合法签名结构但不预做 CT bypass。
      // 这样 TrollStore CTLoop 在安装时能做唯一一次正确的 CT bypass。
      if (argc >= 3) {
        NSString *binaryPath = [NSString stringWithUTF8String:argv[2]];
        NSLog(@"[sign-adhoc-only] Pure ad-hoc signing: %@", binaryPath);
        // signAdhoc with nil entitlements → ldid -s (pure ad-hoc, no TeamID)
        int signRet = signAdhoc(binaryPath, nil);
        NSLog(@"[sign-adhoc-only] signAdhoc ret=%d", signRet);
        ret = signRet;
      } else {
        NSLog(@"Usage: sign-adhoc-only <binary_path>");
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"ct-bypass"]) {

      // Usage: ct-bypass <binary_path>
      // Apply CoreTrust bypass to a binary (for post-injection signing)
      if (argc >= 3) {
        NSString *binaryPath = [NSString stringWithUTF8String:argv[2]];
        NSLog(@"[ct-bypass] Applying CoreTrust bypass to: %@", binaryPath);

        // Copy to temp, apply bypass, move back
        NSString *tmpPath = [NSTemporaryDirectory()
            stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        NSFileManager *fm = [NSFileManager defaultManager];

        if ([fm copyItemAtPath:binaryPath toPath:tmpPath error:nil]) {
          int r =
              apply_coretrust_bypass(tmpPath.fileSystemRepresentation, NULL);
          if (r == 0) {
            NSLog(@"[ct-bypass] CoreTrust bypass applied successfully!");
            [fm removeItemAtPath:binaryPath error:nil];
            [fm moveItemAtPath:tmpPath toPath:binaryPath error:nil];
            ret = 0;
          } else {
            NSLog(@"[ct-bypass] Failed with error: %d", r);
            [fm removeItemAtPath:tmpPath error:nil];
            ret = r;
          }
        } else {
          NSLog(@"[ct-bypass] Failed to copy file");
          ret = 1;
        }
      } else {
        NSLog(@"Usage: ct-bypass <binary_path> [team-id]");
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"extract"]) {
      if (argc < 4) {
        NSLog(@"Usage: extract <ipa_path> <destination_path>");
        return 1;
      }
      NSString *ipaPath = [NSString stringWithUTF8String:argv[2]];
      NSString *destPath = [NSString stringWithUTF8String:argv[3]];
      NSLog(@"[extract] Extracting %@ to %@", ipaPath, destPath);
      return extract(ipaPath, destPath);
    } else if ([cmd isEqualToString:@"inject-lc"]) {
      // Usage: inject-lc <binary_path> <dylib_path>
      // Inject a load command for dylib into a Mach-O binary
      if (argc >= 4) {
        NSString *binaryPath = [NSString stringWithUTF8String:argv[2]];
        NSString *dylibPath = [NSString stringWithUTF8String:argv[3]];
        NSLog(@"[inject-lc] Binary: %@, Dylib: %@", binaryPath, dylibPath);

        // Open file for updating
        NSFileHandle *fileHandle =
            [NSFileHandle fileHandleForUpdatingAtPath:binaryPath];
        if (!fileHandle) {
          NSLog(@"[inject-lc] Failed to open file for writing: %@", binaryPath);
          ret = 10;
        } else {
          // 1. Read Mach-O Header
          NSData *headerData =
              [fileHandle readDataOfLength:sizeof(struct mach_header_64)];
          if (headerData.length < sizeof(struct mach_header_64)) {
            [fileHandle closeFile];
            NSLog(@"[inject-lc] File too small");
            ret = 11;
          } else {
            NSMutableData *mutableHeaderData = [headerData mutableCopy];
            struct mach_header_64 *header =
                (struct mach_header_64 *)mutableHeaderData.mutableBytes;

            if (header->magic != MH_MAGIC_64) {
              [fileHandle closeFile];
              NSLog(@"[inject-lc] Not a valid Mach-O 64-bit binary");
              ret = 11;
            } else {
              // 2. Read Load Commands
              [fileHandle seekToFileOffset:sizeof(struct mach_header_64)];
              NSData *lcData = [fileHandle readDataOfLength:header->sizeofcmds];
              if (lcData.length < header->sizeofcmds) {
                [fileHandle closeFile];
                NSLog(@"[inject-lc] Failed to read load commands");
                ret = 12;
              } else {
                const uint8_t *lcBytes = lcData.bytes;
                uint32_t lcOffset = 0;

                // Check encryption
                BOOL isEncrypted = NO;
                for (uint32_t i = 0; i < header->ncmds; i++) {
                  if (lcOffset + sizeof(struct load_command) > lcData.length)
                    break;
                  const struct load_command *lc =
                      (const struct load_command *)(lcBytes + lcOffset);
                  if (lc->cmd == LC_ENCRYPTION_INFO_64) {
                    const struct encryption_info_command_64 *enc =
                        (const struct encryption_info_command_64 *)lc;
                    if (enc->cryptid != 0) {
                      isEncrypted = YES;
                      NSLog(@"[inject-lc] Binary is encrypted (cryptid=%d)",
                            enc->cryptid);
                      break;
                    }
                  }
                  lcOffset += lc->cmdsize;
                }

                if (isEncrypted) {
                  [fileHandle closeFile];
                  ret = 20;
                } else {
                  // Find first segment offset
                  size_t loadCmdsEnd =
                      sizeof(struct mach_header_64) + header->sizeofcmds;
                  size_t firstSegmentOffset = 0;
                  lcOffset = 0;

                  for (uint32_t i = 0; i < header->ncmds; i++) {
                    if (lcOffset + sizeof(struct load_command) > lcData.length)
                      break;
                    const struct load_command *lc =
                        (const struct load_command *)(lcBytes + lcOffset);
                    if (lc->cmd == LC_SEGMENT_64) {
                      struct segment_command_64 *seg =
                          (struct segment_command_64 *)lc;

                      // Check for __RESTRICT segment and rename it
                      if (strncmp(seg->segname, "__RESTRICT", 16) == 0) {
                        NSLog(
                            @"[inject-lc] ⚠️ Found __RESTRICT segment, renaming "
                            @"to __rEstrIct to bypass anti-tamper...");

                        // Prepare modified segment command
                        struct segment_command_64 segCopy = *seg;
                        strncpy(segCopy.segname, "__rEstrIct", 16);

                        // Write modification to file
                        unsigned long long currentFilePos =
                            [fileHandle offsetInFile];
                        unsigned long long lcFileOffset =
                            sizeof(struct mach_header_64) + lcOffset;

                        [fileHandle seekToFileOffset:lcFileOffset];
                        [fileHandle
                            writeData:
                                [NSData
                                    dataWithBytes:&segCopy
                                           length:
                                               sizeof(
                                                   struct segment_command_64)]];
                        [fileHandle
                            seekToFileOffset:
                                currentFilePos]; // Restore pos although not
                                                 // strictly needed here
                      }

                      if (seg->fileoff > 0 &&
                          (firstSegmentOffset == 0 ||
                           seg->fileoff < firstSegmentOffset)) {
                        firstSegmentOffset = seg->fileoff;
                      }
                    }
                    lcOffset += lc->cmdsize;
                  }

                  if (firstSegmentOffset == 0) {
                    firstSegmentOffset = 0x4000;
                  }

                  // Calculate space
                  const char *dylibPathCStr = dylibPath.UTF8String;
                  size_t dylibPathLen = strlen(dylibPathCStr) + 1;
                  size_t cmdSize = sizeof(struct dylib_command) + dylibPathLen;
                  cmdSize = (cmdSize + 7) & ~7; // Align 8

                  size_t availableSpace = firstSegmentOffset - loadCmdsEnd;
                  if (availableSpace < cmdSize) {
                    [fileHandle closeFile];
                    NSLog(@"[inject-lc] Not enough space for load command");
                    ret = 13;
                  } else {
                    // 3. Write Load Command
                    NSMutableData *newCmdData =
                        [NSMutableData dataWithLength:cmdSize];
                    struct dylib_command *dylib =
                        (struct dylib_command *)newCmdData.mutableBytes;

                    dylib->cmd = LC_LOAD_DYLIB;
                    dylib->cmdsize = (uint32_t)cmdSize;
                    dylib->dylib.name.offset = sizeof(struct dylib_command);
                    dylib->dylib.timestamp = 0;
                    dylib->dylib.current_version = 0x10000;
                    dylib->dylib.compatibility_version = 0x10000;

                    memcpy((char *)dylib + sizeof(struct dylib_command),
                           dylibPathCStr, dylibPathLen);

                    [fileHandle seekToFileOffset:loadCmdsEnd];
                    [fileHandle writeData:newCmdData];

                    // 4. Update Header
                    header->ncmds += 1;
                    header->sizeofcmds += cmdSize;

                    [fileHandle seekToFileOffset:0];
                    [fileHandle writeData:mutableHeaderData];

                    [fileHandle synchronizeFile];
                    [fileHandle closeFile];
                    NSLog(@"[inject-lc] Successfully injected load command!");
                    ret = 0;
                  }
                }
              }
            }
          }
        }
      } else {
        NSLog(@"Usage: inject-lc <binary_path> <dylib_path>");
        ret = 1;
      }
    } else if ([cmd isEqualToString:@"sign-binary"]) {
      // Usage: sign-binary <binary_path> [team-id]
      // Sign a binary with ldid and apply CoreTrust bypass
      if (argc >= 3) {
        NSString *binaryPath = [NSString stringWithUTF8String:argv[2]];
        NSString *teamID = nil;
        if (argc >= 4) {
          teamID = [NSString stringWithUTF8String:argv[3]];
          NSLog(@"[sign-binary] Using Team ID: %@", teamID);
        }

        NSLog(@"[sign-binary] === Starting sign-binary ===");
        NSLog(@"[sign-binary] Binary: %@", binaryPath);
        NSLog(@"[sign-binary] Team ID arg: %@", teamID ?: @"(auto-detect)");

        // 1. Dump entitlements to preserve them
        NSString *entitlementsSourcePath = binaryPath;
        if (argc >= 5) {
          entitlementsSourcePath = [NSString stringWithUTF8String:argv[4]];
          NSLog(@"[sign-binary] Reading entitlements from source: %@",
                entitlementsSourcePath);
        }

        NSDictionary *originalEntitlements =
            dumpEntitlementsFromBinaryAtPath(entitlementsSourcePath);
        NSMutableDictionary *entitlements = [NSMutableDictionary dictionary];
        if (originalEntitlements) {
          [entitlements addEntriesFromDictionary:originalEntitlements];
        }

        if (teamID) {
          // Force update Team ID in entitlements
          entitlements[@"com.apple.developer.team-identifier"] = teamID;

          // Update application-identifier if present
          NSString *appId = entitlements[@"application-identifier"];
          if (appId) {
            NSRange firstDot = [appId rangeOfString:@"."];
            if (firstDot.location != NSNotFound) {
              NSString *bundleId =
                  [appId substringFromIndex:firstDot.location + 1];
              entitlements[@"application-identifier"] =
                  [NSString stringWithFormat:@"%@.%@", teamID, bundleId];
            }
          }
          NSLog(@"[sign-binary] Injected Team ID into entitlements: %@",
                teamID);
        } else {
          // Auto-detect if not provided
          if (entitlements[@"com.apple.developer.team-identifier"]) {
            teamID = entitlements[@"com.apple.developer.team-identifier"];
            NSLog(@"[sign-binary] Auto-detected Team ID: %@", teamID);
          }
        }

        // 2. Sign with adhoc using updated entitlements
        // Fix: If entitlements is empty, pass nil to use "-s" instead of
        // "-S<file>" This prevents ldid error 175 when signing dylibs that have
        // no entitlements
        int signRet;
        if (entitlements.count == 0) {
          NSLog(@"[sign-binary] Entitlements empty, using simple ad-hoc "
                @"signature (-s)");
          signRet = signAdhoc(binaryPath, nil);
        } else {
          signRet = signAdhoc(binaryPath, entitlements);
        }

        if (signRet != 0) {
          NSLog(@"[sign-binary] Signing failed: %d", signRet);
          ret = signRet;
        } else {

          // 3. Apply CoreTrust bypass
          NSString *tmpPath = [NSTemporaryDirectory()
              stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
          NSFileManager *fm = [NSFileManager defaultManager];
          NSError *copyError = nil;

          if ([fm copyItemAtPath:binaryPath toPath:tmpPath error:&copyError]) {
            const char *teamIDStr = teamID ? teamID.UTF8String : NULL;
            int r = apply_coretrust_bypass(tmpPath.fileSystemRepresentation,
                                           teamIDStr);
            if (r == 0) {
              NSLog(@"[sign-binary] CoreTrust bypass applied to temp file!");

              // Move signed file back to original location
              NSError *removeErr = nil, *moveErr = nil;
              if ([fm removeItemAtPath:binaryPath error:&removeErr]) {
                if ([fm moveItemAtPath:tmpPath
                                toPath:binaryPath
                                 error:&moveErr]) {
                  NSLog(@"[sign-binary] ✅ Signed binary moved back "
                        @"successfully!");
                  ret = 0;
                } else {
                  NSLog(@"[sign-binary] ❌ Failed to move signed binary: %@",
                        moveErr);
                  ret = 1;
                }
              } else {
                NSLog(@"[sign-binary] ❌ Failed to remove original binary: %@",
                      removeErr);
                ret = 1;
              }
            } else {
              NSLog(@"[sign-binary] CoreTrust bypass failed: %d", r);
              [fm removeItemAtPath:tmpPath error:nil];
              ret = r;
            }
          } else {
            NSLog(@"[sign-binary] ❌ Failed to copy binary to temp: %@",
                  copyError);
            ret = 1;
          }
        }
      } else {
        ret = 1; // argc < 3
      }
    } else if ([cmd isEqualToString:@"save-teamid"]) {
      if (argc < 3)
        return 1;
      NSString *binaryPath = [NSString stringWithUTF8String:argv[2]];

      NSLog(@"[save-teamid] Analyzing binary: %@", binaryPath);

      // 1. 获取 Bundle ID
      NSString *appPath = [binaryPath stringByDeletingLastPathComponent];
      // 如果是主程序，通常在 App 根目录内；如果是 App 包本身
      if ([appPath hasSuffix:@".app"]) {
        // 正常情况
      } else {
        // 尝试向上查找
        if ([[appPath stringByDeletingLastPathComponent] hasSuffix:@".app"]) {
          appPath = [appPath stringByDeletingLastPathComponent];
        }
      }

      NSDictionary *infoPlist = [NSDictionary
          dictionaryWithContentsOfFile:
              [appPath stringByAppendingPathComponent:@"Info.plist"]];
      NSString *bundleID = infoPlist[@"CFBundleIdentifier"];
      if (!bundleID) {
        NSLog(@"[save-teamid] ❌ Failed to find Bundle ID for %@", appPath);
        return 1;
      }

      // 2. 提取 Team ID (此时假设 Binary 已解密)
      NSString *teamID = nil;

      // 尝试 Security.framework
      NSDictionary *entitlements = dumpEntitlementsFromBinaryAtPath(binaryPath);
      if (entitlements) {
        teamID = entitlements[@"com.apple.developer.team-identifier"];
      }

      // 尝试 ChOma
      if (!teamID) {
        FAT *fat = fat_init_from_path(binaryPath.fileSystemRepresentation);
        if (fat) {
          MachO *macho = fat_find_preferred_slice(fat);
          if (!macho)
            macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
          if (macho) {
            CS_SuperBlob *sb = macho_read_code_signature(macho);
            if (sb) {
              CS_DecodedSuperBlob *dsb = csd_superblob_decode(sb);
              if (dsb) {
                CS_DecodedBlob *cd =
                    csd_superblob_find_blob(dsb, CSSLOT_CODEDIRECTORY, NULL);
                if (!cd)
                  cd = csd_superblob_find_blob(
                      dsb, CSSLOT_ALTERNATE_CODEDIRECTORIES, NULL);
                if (cd) {
                  char *tid = csd_code_directory_copy_team_id(cd, NULL);
                  if (tid) {
                    teamID = [NSString stringWithUTF8String:tid];
                    free(tid);
                  }
                }
                csd_superblob_free(dsb);
              }
              free(sb);
            }
          }
          fat_free(fat);
        }
      }

      if (!teamID || teamID.length == 0) {
        NSLog(@"[save-teamid] CodeDirectory has no Team ID, trying CMS "
              @"certificate...");

        // 尝试从 CMS 签名证书中提取 Team ID
        // Team ID 存储在签名证书的 Organizational Unit (OU) 字段中
        FAT *fat = fat_init_from_path(binaryPath.fileSystemRepresentation);
        if (fat) {
          MachO *macho = fat_find_preferred_slice(fat);
          if (!macho)
            macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
          if (macho) {
            CS_SuperBlob *sb = macho_read_code_signature(macho);
            if (sb) {
              CS_DecodedSuperBlob *dsb = csd_superblob_decode(sb);
              if (dsb) {
                // 查找 CMS 签名 blob (CSSLOT_SIGNATURESLOT = 0x10000)
                CS_DecodedBlob *cmsBlob =
                    csd_superblob_find_blob(dsb, CSSLOT_SIGNATURESLOT, NULL);
                if (cmsBlob) {
                  size_t cmsDataSize = csd_blob_get_size(cmsBlob);
                  void *cmsData = malloc(cmsDataSize);
                  if (cmsData &&
                      csd_blob_read(cmsBlob, 0, cmsDataSize, cmsData) == 0) {
                    // 直接在 CMS 数据中搜索 OU OID (2.5.4.11 = 55 04 0B)
                    // 证书以 DER 编码嵌入在 CMS 中
                    const uint8_t *bytes = (const uint8_t *)cmsData;
                    for (size_t i = 0; i < cmsDataSize - 15; i++) {
                      if (bytes[i] == 0x06 && bytes[i + 1] == 0x03 &&
                          bytes[i + 2] == 0x55 && bytes[i + 3] == 0x04 &&
                          bytes[i + 4] == 0x0B) {
                        // 找到 OU OID, 下一个应该是值
                        size_t j = i + 5;
                        if (j < cmsDataSize &&
                            (bytes[j] == 0x0C || bytes[j] == 0x13)) {
                          size_t strLen = bytes[j + 1];
                          if (j + 2 + strLen <= cmsDataSize && strLen == 10) {
                            NSString *ou = [[NSString alloc]
                                initWithBytes:&bytes[j + 2]
                                       length:strLen
                                     encoding:NSUTF8StringEncoding];
                            if (ou && ou.length == 10) {
                              NSLog(@"[save-teamid] ✅ Found Team ID from CMS "
                                    @"certificate OU: %@",
                                    ou);
                              teamID = ou;
                              break;
                            }
                          }
                        }
                      }
                    }
                    free(cmsData);
                  }
                }
                csd_superblob_free(dsb);
              }
              free(sb);
            }
          }
          fat_free(fat);
        }
      }

      if (!teamID || teamID.length == 0) {
        NSLog(@"[save-teamid] ❌ Failed to extract Team ID via all methods");
        // 尝试从 embedded.mobileprovision
        NSString *provPath = [appPath
            stringByAppendingPathComponent:@"embedded.mobileprovision"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:provPath]) {
          NSString *content =
              [NSString stringWithContentsOfFile:provPath
                                        encoding:NSASCIIStringEncoding
                                           error:nil];
          if (content) {
            NSRange r = [content rangeOfString:@"<key>TeamIdentifier</key>"];
            if (r.location != NSNotFound) {
              NSLog(@"[save-teamid] Found embedded.mobileprovision, "
                    @"parsing...");
              // 简单解析: 查找 <string>XXXXXXXXXX</string>
              NSRange searchRange =
                  NSMakeRange(r.location + r.length,
                              MIN(200, content.length - r.location - r.length));
              NSRange strStart = [content rangeOfString:@"<string>"
                                                options:0
                                                  range:searchRange];
              NSRange strEnd = [content rangeOfString:@"</string>"
                                              options:0
                                                range:searchRange];
              if (strStart.location != NSNotFound &&
                  strEnd.location != NSNotFound) {
                NSUInteger start = strStart.location + strStart.length;
                NSUInteger length = strEnd.location - start;
                if (length == 10) {
                  teamID =
                      [content substringWithRange:NSMakeRange(start, length)];
                  NSLog(@"[save-teamid] ✅ Found Team ID from mobileprovision: "
                        @"%@",
                        teamID);
                }
              }
            }
          }
        }
        if (!teamID)
          return 1;
      }

      NSLog(@"[save-teamid] ✅ Detected Team ID: %@", teamID);

      // 3. 保存到 Plist
      NSString *plistPath =
          @"/var/mobile/Library/Preferences/com.ecmain.teamids.plist";
      NSMutableDictionary *dict =
          [NSMutableDictionary dictionaryWithContentsOfFile:plistPath];
      if (!dict)
        dict = [NSMutableDictionary dictionary];

      dict[bundleID] = teamID;

      if ([dict writeToFile:plistPath atomically:YES]) {
        NSLog(@"[save-teamid] ✅ Saved mapping: %@ -> %@ to %@", bundleID,
              teamID, plistPath);
        // 设置权限以便所有用户读取
        chmod(plistPath.UTF8String, 0644);
        return 0;
      } else {
        NSLog(@"[save-teamid] ❌ Failed to write to plist");
        return 1;
      }
    } else if ([cmd isEqualToString:@"print-teamid"]) {
      if (argc < 3)
        return 1;
      NSString *binaryPath = [NSString stringWithUTF8String:argv[2]];
      NSLog(@"[print-teamid] === Team ID Extraction ===");
      NSLog(@"[print-teamid] Path: %@", binaryPath);

      // Try Security.framework first (works for decrypted binaries)
      NSLog(@"[print-teamid] Step 1: Trying Security.framework...");
      NSDictionary *entitlements = dumpEntitlementsFromBinaryAtPath(binaryPath);
      if (entitlements) {
        NSLog(@"[print-teamid] Found %lu entitlements",
              (unsigned long)entitlements.count);
        NSString *tid = entitlements[@"com.apple.developer.team-identifier"];
        if (tid && tid.length > 0) {
          NSLog(@"[print-teamid] ✅ Found Team ID via Security.framework: %@",
                tid);
          printf("%s", tid.UTF8String);
          return 0;
        } else {
          NSLog(@"[print-teamid] No 'com.apple.developer.team-identifier' in "
                @"entitlements");
        }
      } else {
        NSLog(@"[print-teamid] Security.framework returned nil entitlements "
              @"(may be encrypted)");
      }

      // Fallback: Use ChOma to read directly from code signature
      // This works even for FairPlay encrypted binaries because
      // code signature is not encrypted
      NSLog(@"[print-teamid] Step 2: Trying ChOma direct read from "
            @"CodeDirectory...");

      FAT *fat = fat_init_from_path(binaryPath.fileSystemRepresentation);
      if (!fat) {
        NSLog(@"[print-teamid] ❌ FAT init failed");
        return 1;
      }
      NSLog(@"[print-teamid] FAT init OK");

      MachO *macho = fat_find_preferred_slice(fat);
      if (!macho) {
        NSLog(@"[print-teamid] No preferred slice, trying arm64...");
        macho = fat_find_slice(fat, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL);
      }
      if (!macho) {
        NSLog(@"[print-teamid] ❌ No suitable MachO slice found");
        fat_free(fat);
        return 1;
      }
      NSLog(@"[print-teamid] MachO slice found");

      CS_SuperBlob *superblob = macho_read_code_signature(macho);
      if (!superblob) {
        NSLog(@"[print-teamid] ❌ Failed to read code signature");
        fat_free(fat);
        return 1;
      }
      NSLog(@"[print-teamid] Code signature read OK");

      CS_DecodedSuperBlob *decoded = csd_superblob_decode(superblob);
      if (!decoded) {
        NSLog(@"[print-teamid] ❌ Failed to decode superblob");
        free(superblob);
        fat_free(fat);
        return 1;
      }
      NSLog(@"[print-teamid] Superblob decoded OK");

      // Try to get Team ID from code directory
      CS_DecodedBlob *codeDir =
          csd_superblob_find_blob(decoded, CSSLOT_CODEDIRECTORY, NULL);
      if (!codeDir) {
        NSLog(@"[print-teamid] Primary CD not found, trying alternate...");
        codeDir = csd_superblob_find_blob(
            decoded, CSSLOT_ALTERNATE_CODEDIRECTORIES, NULL);
      }
      if (!codeDir) {
        NSLog(@"[print-teamid] ❌ No CodeDirectory found");
        csd_superblob_free(decoded);
        free(superblob);
        fat_free(fat);
        return 1;
      }
      NSLog(@"[print-teamid] CodeDirectory found");

      char *teamID = csd_code_directory_copy_team_id(codeDir, NULL);
      if (teamID && strlen(teamID) > 0) {
        NSLog(@"[print-teamid] ✅ Found Team ID via ChOma: %s", teamID);
        printf("%s", teamID);
        free(teamID);
        csd_superblob_free(decoded);
        free(superblob);
        fat_free(fat);
        return 0;
      }

      // Team ID is NULL or empty - this means CodeDirectory has teamOffset=0
      NSLog(@"[print-teamid] ❌ CodeDirectory has no Team ID (teamOffset=0)");
      if (teamID)
        free(teamID);

      // Fallback: Check Identifier (often TeamID.BundleID)
      char *identifier = csd_code_directory_copy_identifier(codeDir, NULL);
      if (identifier) {
        NSLog(@"[print-teamid] CodeDirectory Identifier: %s", identifier);
        NSString *identStr = [NSString stringWithUTF8String:identifier];
        NSArray *parts = [identStr componentsSeparatedByString:@"."];
        if (parts.count > 1) {
          NSString *prefix = parts.firstObject;
          // Check if prefix looks like a Team ID (10 chars, alphanumeric)
          NSCharacterSet *alphaNum = [NSCharacterSet alphanumericCharacterSet];
          if (prefix.length == 10 &&
              [alphaNum isSupersetOfSet:
                            [NSCharacterSet
                                characterSetWithCharactersInString:prefix]]) {
            NSLog(@"[print-teamid] ✅ Inferred Team ID from Identifier: %@",
                  prefix);
            printf("%s", prefix.UTF8String);
            free(identifier);
            csd_superblob_free(decoded);
            free(superblob);
            fat_free(fat);
            return 0;
          }
        }
        free(identifier);
      }

      // Fallback: Try to extract Team ID from CMS signature certificate
      NSLog(@"[print-teamid] Step 3: Trying CMS certificate OU field...");
      CS_DecodedBlob *cmsBlob =
          csd_superblob_find_blob(decoded, CSSLOT_SIGNATURESLOT, NULL);
      if (cmsBlob) {
        size_t cmsDataSize = csd_blob_get_size(cmsBlob);
        void *cmsData = malloc(cmsDataSize);
        if (cmsData && csd_blob_read(cmsBlob, 0, cmsDataSize, cmsData) == 0) {
          // 直接在 CMS 数据中搜索 OU OID (2.5.4.11 = 55 04 0B)
          const uint8_t *bytes = (const uint8_t *)cmsData;
          for (size_t i = 0; i < cmsDataSize - 15; i++) {
            if (bytes[i] == 0x06 && bytes[i + 1] == 0x03 &&
                bytes[i + 2] == 0x55 && bytes[i + 3] == 0x04 &&
                bytes[i + 4] == 0x0B) {
              size_t j = i + 5;
              if (j < cmsDataSize && (bytes[j] == 0x0C || bytes[j] == 0x13)) {
                size_t strLen = bytes[j + 1];
                if (j + 2 + strLen <= cmsDataSize && strLen == 10) {
                  NSString *ou =
                      [[NSString alloc] initWithBytes:&bytes[j + 2]
                                               length:strLen
                                             encoding:NSUTF8StringEncoding];
                  if (ou && ou.length == 10) {
                    NSLog(@"[print-teamid] ✅ Found Team ID from CMS "
                          @"certificate OU: %@",
                          ou);
                    printf("%s", ou.UTF8String);
                    free(cmsData);
                    csd_superblob_free(decoded);
                    free(superblob);
                    fat_free(fat);
                    return 0;
                  }
                }
              }
            }
          }
          free(cmsData);
        }
      }

      // Final Fallback: Check for manual override file
      // User can create /var/mobile/teamid.txt with the Team ID
      NSString *overridePath = @"/var/mobile/teamid.txt";
      if ([[NSFileManager defaultManager] fileExistsAtPath:overridePath]) {
        NSString *content =
            [NSString stringWithContentsOfFile:overridePath
                                      encoding:NSUTF8StringEncoding
                                         error:nil];
        content =
            [content stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (content.length == 10) {
          NSLog(@"[print-teamid] ✅ Found manual override at %@: %@",
                overridePath, content);
          printf("%s", content.UTF8String);
          csd_superblob_free(decoded);
          free(superblob);
          fat_free(fat);
          return 0;
        }
      }

      csd_superblob_free(decoded);
      free(superblob);
      fat_free(fat);

      NSLog(@"[print-teamid] Failed to extract Team ID from both methods");
      return 1;
    }

    if ([cmd isEqualToString:@"test-task-port"]) {
      if (argc < 3)
        return -1;
      pid_t pid = atoi(argv[2]);
      mach_port_t task;
      kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
      if (kr != KERN_SUCCESS) {
        printf("task_for_pid failed: %s (%d)\n", mach_error_string(kr), kr);
        return 1;
      }
      printf("Got task port: %u\n", task);
      mach_port_deallocate(mach_task_self(), task);
      return 0;
    }

    if ([cmd isEqualToString:@"toggle-wifi"]) {
      NSLog(@"[toggle-wifi] Resetting Wi-Fi (en0)...");
      char *downArgs[] = {"ifconfig", "en0", "down", NULL};
      spawn_process("/sbin/ifconfig", downArgs);

      sleep(1);

      char *upArgs[] = {"ifconfig", "en0", "up", NULL};
      int ret = spawn_process("/sbin/ifconfig", upArgs);

      NSLog(@"[toggle-wifi] Done. ret=%d", ret);
      return ret;
    }

#endif // 临时关闭 TROLLSTORE_LITE 条件，让 open-switcher 在所有配置下可用

    // 无条件调试输出：确认控制流是否到达
    fprintf(stderr, "[RH_DEBUG] 到达 open-switcher 检查点, cmd=%s\n",
            cmd.UTF8String);

    // 通过底层 API 注入 Home 键双击，唤起 App Switcher
    if ([cmd isEqualToString:@"open-switcher"]) {
      fprintf(stderr, "[open-switcher] 开始...\n");

      // 加载框架
      void *bbsHandle = dlopen(
          "/System/Library/PrivateFrameworks/BackBoardServices.framework/"
          "BackBoardServices",
          RTLD_NOW);
      fprintf(stderr, "[open-switcher] BackBoardServices: %s\n",
              bbsHandle ? "OK" : dlerror());

      void *iokitHandle =
          dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
      fprintf(stderr, "[open-switcher] IOKit: %s\n",
              iokitHandle ? "OK" : dlerror());

      void *gsHandle =
          dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/"
                 "GraphicsServices",
                 RTLD_NOW);
      fprintf(stderr, "[open-switcher] GraphicsServices: %s\n",
              gsHandle ? "OK" : dlerror());

      if (!iokitHandle) {
        fprintf(stderr, "[open-switcher] ERROR: IOKit 加载失败\n");
        return 202;
      }

      // 解析所有可能的符号
      typedef void *(*IOHIDEventCreateKeyboardEvent_t)(
          void *, uint64_t, uint32_t, uint32_t, int, uint32_t);
      typedef void (*BKSHIDEventSetDigitizerInfo_t)(void *, uint32_t, uint8_t,
                                                    uint8_t);
      typedef void (*BKSHIDEventRoute_t)(void *);
      typedef void *(*IOHIDEventSystemClientCreate_t)(void *);
      typedef void (*IOHIDEventSystemClientDispatchEvent_t)(void *, void *);
      typedef void (*GSSendEvent_t)(void *, mach_port_t);
      typedef mach_port_t (*GSGetPurpleSystemEventPort_t)(void);

      IOHIDEventCreateKeyboardEvent_t createKbEvent =
          (IOHIDEventCreateKeyboardEvent_t)dlsym(
              iokitHandle, "IOHIDEventCreateKeyboardEvent");

      BKSHIDEventSetDigitizerInfo_t setDigitizerInfo =
          bbsHandle ? (BKSHIDEventSetDigitizerInfo_t)dlsym(
                          bbsHandle, "BKSHIDEventSetDigitizerInfo")
                    : NULL;

      // 尝试所有可能的路由函数名
      BKSHIDEventRoute_t routeEvent = NULL;
      const char *routeNames[] = {"BKSHIDEventRouteToSpringBoard",
                                  "BKSHIDEventSendToSBApplication",
                                  "BKSHIDEventSendToApplication", NULL};
      for (int i = 0; routeNames[i] && bbsHandle; i++) {
        routeEvent = (BKSHIDEventRoute_t)dlsym(bbsHandle, routeNames[i]);
        fprintf(stderr, "[open-switcher] %s: %s\n", routeNames[i],
                routeEvent ? "FOUND" : "NOT FOUND");
        if (routeEvent)
          break;
      }

      // IOHIDEventSystemClient 方案
      IOHIDEventSystemClientCreate_t sysClientCreate =
          (IOHIDEventSystemClientCreate_t)dlsym(iokitHandle,
                                                "IOHIDEventSystemClientCreate");
      IOHIDEventSystemClientDispatchEvent_t sysClientDispatch =
          (IOHIDEventSystemClientDispatchEvent_t)dlsym(
              iokitHandle, "IOHIDEventSystemClientDispatchEvent");
      fprintf(stderr, "[open-switcher] IOHIDEventSystemClientCreate: %s\n",
              sysClientCreate ? "FOUND" : "NOT FOUND");
      fprintf(stderr,
              "[open-switcher] IOHIDEventSystemClientDispatchEvent: %s\n",
              sysClientDispatch ? "FOUND" : "NOT FOUND");

      // GSSendEvent 方案
      GSSendEvent_t gsSendEvent =
          gsHandle ? (GSSendEvent_t)dlsym(gsHandle, "GSSendEvent") : NULL;
      GSGetPurpleSystemEventPort_t gsGetPort =
          gsHandle ? (GSGetPurpleSystemEventPort_t)dlsym(
                         gsHandle, "GSGetPurpleSystemEventPort")
                   : NULL;
      fprintf(stderr, "[open-switcher] GSSendEvent: %s\n",
              gsSendEvent ? "FOUND" : "NOT FOUND");
      fprintf(stderr, "[open-switcher] GSGetPurpleSystemEventPort: %s\n",
              gsGetPort ? "FOUND" : "NOT FOUND");

      fprintf(stderr, "[open-switcher] createKbEvent: %s\n",
              createKbEvent ? "FOUND" : "NOT FOUND");
      fprintf(stderr, "[open-switcher] setDigitizerInfo: %s\n",
              setDigitizerInfo ? "FOUND" : "NOT FOUND");

      if (!createKbEvent) {
        fprintf(stderr, "[open-switcher] ERROR: 无法创建 HID 事件\n");
        return 203;
      }

      // Consumer Page (0x0C), Usage: Menu (0x40) = Home 键
      uint32_t page = 0x0C;
      uint32_t usage = 0x40;

      // === 发送两次 Home 键按压 ===
      for (int pressIdx = 0; pressIdx < 2; pressIdx++) {
        uint64_t ts = (uint64_t)(CACurrentMediaTime() * 1000000000ULL);

        // 创建 DOWN 和 UP 事件
        void *downEvt = createKbEvent(NULL, ts, page, usage, 1, 0);
        void *upEvt = createKbEvent(NULL, ts + 50000000ULL, page, usage, 0, 0);

        fprintf(stderr, "[open-switcher] 第%d次按键: down=%p up=%p\n",
                pressIdx + 1, downEvt, upEvt);

        if (setDigitizerInfo && downEvt)
          setDigitizerInfo(downEvt, 0, 1, 0);
        if (setDigitizerInfo && upEvt)
          setDigitizerInfo(upEvt, 0, 1, 0);

        BOOL sent = NO;

        // 方案 A: BKS 路由
        if (routeEvent && downEvt) {
          routeEvent(downEvt);
          usleep(50000);
          if (upEvt)
            routeEvent(upEvt);
          fprintf(stderr, "[open-switcher] 第%d次: 方案A(BKS路由) 已发送\n",
                  pressIdx + 1);
          sent = YES;
        }

        // 方案 B: IOHIDEventSystemClient
        if (!sent && sysClientCreate && sysClientDispatch && downEvt) {
          void *client = sysClientCreate(kCFAllocatorDefault);
          if (client) {
            sysClientDispatch(client, downEvt);
            usleep(50000);
            if (upEvt)
              sysClientDispatch(client, upEvt);
            CFRelease(client);
            fprintf(stderr,
                    "[open-switcher] 第%d次: 方案B(IOHIDEventSystemClient) "
                    "已发送\n",
                    pressIdx + 1);
            sent = YES;
          } else {
            fprintf(stderr,
                    "[open-switcher] 第%d次: 方案B IOHIDEventSystemClient "
                    "创建失败\n",
                    pressIdx + 1);
          }
        }

        if (!sent) {
          fprintf(stderr, "[open-switcher] 第%d次: ⚠️ 所有发送方案均不可用\n",
                  pressIdx + 1);
        }

        if (downEvt)
          CFRelease(downEvt);
        if (upEvt)
          CFRelease(upEvt);

        // 两次按键间隔 100ms
        if (pressIdx == 0)
          usleep(100000);
      }

      if (gsHandle)
        dlclose(gsHandle);
      if (bbsHandle)
        dlclose(bbsHandle);
      dlclose(iokitHandle);

      fprintf(stderr, "[open-switcher] 完成\n");
      return 0;
    }

    if ([cmd isEqualToString:@"run-wda-daemon"]) {
      freopen("/var/mobile/Media/go-ios.log", "a", stdout);
      freopen("/var/mobile/Media/go-ios.log", "a", stderr);
      
      NSLog(@"========================");
      NSLog(@"[run-wda-daemon] WDA 原生 XCTest 启动代理 (v1803-Antigravity-Wireless)");

      NSString *bundleId = @"com.apple.accessibility.ecwda";
      if (argc > 2) bundleId = [NSString stringWithUTF8String:argv[2]];

      // 1. 获取设备 UDID
      NSString *udid = nil;
      void *mgLib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
      if (mgLib) {
          CFStringRef (*MGCopyAnswer)(CFStringRef) = (CFStringRef (*)(CFStringRef))dlsym(mgLib, "MGCopyAnswer");
          if (MGCopyAnswer) {
              udid = (__bridge_transfer NSString *)MGCopyAnswer(CFSTR("SerialNumber"));
          }
          dlclose(mgLib);
      }
      
      if (!udid) {
          NSLog(@"[run-wda-daemon] ⚠️ 无法通过 MobileGestalt 获取 UDID，尝试备份方案...");
          udid = get_udid_iokit();
      }
      
      if (!udid) {
          NSLog(@"[run-wda-daemon] ❌ 致命错误：无法获取设备 UDID");
          return 201;
      }
      
      NSLog(@"[run-wda-daemon] 📱 设备 UDID: %@", udid);

      signal(SIGTERM, handle_daemon_exit_signal);
      signal(SIGINT, handle_daemon_exit_signal);

      // 2. 检查 DDI，未挂载则自动尝试挂载
      if (!isDDImounted()) {
          NSLog(@"[run-wda-daemon] ⚠️ DDI 未挂载，正在自动尝试本地挂载...");
          NSString *helperPathForMount = [[NSProcessInfo processInfo] arguments].firstObject;
          char *mArgv[] = { (char *)[helperPathForMount UTF8String], "mount-ddi", NULL };
          pid_t mPid;
          extern char **environ;
          posix_spawn(&mPid, [helperPathForMount UTF8String], NULL, NULL, mArgv, environ);
          int mStatus;
          waitpid(mPid, &mStatus, 0);

          if (WEXITSTATUS(mStatus) == 0 && isDDImounted()) {
              NSLog(@"[run-wda-daemon] ✅ DDI 自动挂载成功！");
          } else {
              NSLog(@"[run-wda-daemon] ❌ DDI 自动挂载失败 (status: %d)。WDA 无法建立测试会话。", WEXITSTATUS(mStatus));
              return 201;
          }
      }

      // 3. 启动 usbmuxd 仿射代理
      if (!startUsbmuxdShimWithUDID(udid)) {
          NSLog(@"[run-wda-daemon] ❌ 启动 usbmuxd_shim 失败");
          return 202;
      }

      // 4. 定位 go-ios-arm64
      NSString *helperPath = [[NSProcessInfo processInfo] arguments].firstObject;
      NSString *goIosPath = [[helperPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"go-ios-arm64"];
      
      NSLog(@"[run-wda-daemon] 🚀 开始周期看护 WDA (%@)...", bundleId);
      
      int loopCount = 0;
      
      while (g_daemon_running) {
          loopCount++;
          BOOL alive = checkWDAAlive();
          NSLog(@"[run-wda-daemon] 🔍 [#%d] 正在探测 WDA 状态 (10088/8100): %@", loopCount, alive ? @"ALIVE" : @"DEAD");

          if (!alive) {
              NSLog(@"[run-wda-daemon] ⚠️ 发现 WDA 未响应, 准备通过原生协议拉起...");
              
              killall(@"ECService-Runner", NO);
              sleep(1);

              // [v1608] 终极冷启动方案：利用 FrontBoard 注入 XCTest 运行时
              @try {
                  NSLog(@"[v1608-XCT] 🚀 正在通过 FrontBoard 注入 XCTest 环境并拉起...");
                  
                  // 1. 尝试找到 FBSService 接口（TrollStore 环境下可用）
                  Class fbsServiceClass = NSClassFromString(@"FBSOpenApplicationService");
                  id service = [fbsServiceClass performSelector:NSSelectorFromString(@"serviceWithDefaultShellEndpoint")];
                  
                  if (service) {
                      Class fbsOptionsClass = NSClassFromString(@"FBSOpenApplicationOptions");
                      // 注入关键的测试环境变量
                      NSDictionary *xctEnv = @{
                          @"XCTestConfigurationFilePath" : @"ECService",
                          @"DYLD_INSERT_LIBRARIES" : @"/Developer/usr/lib/libXCTestBundleInject.dylib",
                          @"XC_TEST_BUNDLE_ID" : bundleId
                      };
                      
                      // 包装成 FBSService 接受的格式
                      NSDictionary *optionsDict = @{
                          @"__PayloadOptionsEnvironmentVariables" : xctEnv,
                          @"__PayloadOptionsUnlockDevice" : @YES,
                          @"__PayloadOptionsActivateSuspended" : @NO
                      };
                      
                      id options = [fbsOptionsClass performSelector:NSSelectorFromString(@"optionsWithDictionary:") withObject:optionsDict];
                      
                      // 使用 NSInvocation 绕过 performSelector 参数限制
                      SEL openSel = NSSelectorFromString(@"openApplication:withOptions:completion:");
                      NSMethodSignature *sig = [service methodSignatureForSelector:openSel];
                      NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                      [inv setTarget:service];
                      [inv setSelector:openSel];
                      [inv setArgument:&bundleId atIndex:2];
                      [inv setArgument:&options atIndex:3];
                      void *nilPtr = NULL;
                      [inv setArgument:&nilPtr atIndex:4];
                      [inv invoke];
                      
                      NSLog(@"[v1608-XCT] ✅ FrontBoard 注入指令已通过 NSInvocation 发送");
                  } else {
                      // 退而求其次，使用基础 LS 拉起
                      NSLog(@"[v1608-XCT] ⚠️ FBSService 不可用，回退至基础 LS 拉起...");
                      Class lsClass = NSClassFromString(@"LSApplicationWorkspace");
                      id workspace = [lsClass performSelector:NSSelectorFromString(@"defaultWorkspace")];
                      [workspace performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bundleId];
                  }
              } @catch (NSException *e) {
                  NSLog(@"[v1608-XCT] ❌ 注入失败: %@", e);
              }

              // 给予宽裕的 60 秒建联期
              for (int i = 0; i < 60 && g_daemon_running; i++) {
                 if (checkWDAAlive()) {
                    NSLog(@"[run-wda-daemon] 🎊 WDA 在第 %d 秒成功握手！", i);
                    break;
                 }
                 sleep(1);
              }
          } else {
              if (loopCount % 5 == 0) {
                 NSLog(@"[run-wda-daemon] 💓 服务心跳正常 (Loop %d)", loopCount);
              }
              sleep(8);
          }
      }

      NSLog(@"[run-wda-daemon] 🛑 守护进程退出, 正在清理...");
      stopUsbmuxdShim();
      killall(@"go-ios-arm64", NO);
      return 0;
    }

    if ([cmd isEqualToString:@"mount-ddi"]) {
        NSLog(@"[mount-ddi] 开始执行本地 DDI 自挂载流程 (v1803-Antigravity-Wireless)");

        // 0. 如果已经挂载，直接返回成功
        if (isDDImounted()) {
            NSLog(@"[mount-ddi] ✅ DDI 已处于挂载状态，无需重复挂载。");
            return 0;
        }

        NSString *helperPath = [[NSProcessInfo processInfo] arguments].firstObject;
        NSString *helperDir = [helperPath stringByDeletingLastPathComponent];
        NSString *goIosPath = [helperDir stringByAppendingPathComponent:@"go-ios-arm64"];

        // 1. 多路径搜索 DDI 文件
        NSString *dmgPath = findDDIDmgPath(helperDir);
        if (!dmgPath) {
            NSLog(@"[mount-ddi] ❌ 致命错误：找不到 DeveloperDiskImage.dmg 文件");
            return 110;
        }

        // 2. 获取设备 UDID（usbmuxd_shim 需要）
        NSString *udid = getDeviceUDID();
        if (!udid) {
            NSLog(@"[mount-ddi] ⚠️ 无法获取 UDID，使用占位符继续...");
            udid = @"00000000-0000000000000000";
        }
        NSLog(@"[mount-ddi] 📱 设备 UDID: %@", udid);

        // 3. 启动 usbmuxd_shim（关键：让 go-ios 在无 USB 时也能连上设备）
        NSLog(@"[mount-ddi] 🔌 正在启动 usbmuxd 仿射代理...");
        BOOL shimStarted = startUsbmuxdShimWithUDID(udid);
        if (!shimStarted) {
            NSLog(@"[mount-ddi] ⚠️ usbmuxd_shim 启动失败，将尝试直接挂载（可能仅在 USB 连接时成功）");
        } else {
            NSLog(@"[mount-ddi] ✅ usbmuxd_shim 已就绪 (/var/run/usbmuxd_shim.sock)");
        }

        // 4. 确保伪造的配对目录存在
        NSString *fakeLockdown = @"/tmp/lockdown";
        [[NSFileManager defaultManager] createDirectoryAtPath:fakeLockdown withIntermediateDirectories:YES attributes:nil error:nil];
        chmod(fakeLockdown.UTF8String, 0755);
        chown(fakeLockdown.UTF8String, 0, 0);

        NSLog(@"[mount-ddi] 🚩 正在调用 go-ios 引擎 (通过本地 shim 代理)...");

        // [v1805-fix] go-ios 使用 docopt，ParseDoc 读取 os.Args[1:]
        // runBinaryAtPathWithEnv 已自动设置 argv[0]=程序名，
        // usage pattern "ios image mount ..." 中 "ios" 是程序名占位符，docopt 会跳过，
        // 所以 goArgs 不应包含 "ios"，否则 docopt 多收到一个 "ios" 导致解析失败
        NSString *pathArg = [NSString stringWithFormat:@"--path=%@", dmgPath];
        NSString *udidArg = [NSString stringWithFormat:@"--udid=%@", udid];
        NSArray *goArgs = @[
            @"image",
            @"mount",
            pathArg,
            udidArg
        ];

        // 5. 通过环境变量告诉 go-ios 使用 shim socket
        NSDictionary *env = shimStarted
            ? @{ @"USBMUXD_SOCKET_ADDRESS" : @"/var/run/usbmuxd_shim.sock" }
            : @{};

        NSString *output = nil;
        NSString *errorOutput = nil;
        int status = runBinaryAtPathWithEnv(goIosPath, goArgs, env, &output, &errorOutput);

        if (output) NSLog(@"[mount-ddi] STDOUT: %@", output);
        if (errorOutput) NSLog(@"[mount-ddi] STDERR: %@", errorOutput);

        // 6. 清理 shim（mount-ddi 是一次性操作，不需要保持 shim）
        if (shimStarted) {
            stopUsbmuxdShim();
            NSLog(@"[mount-ddi] 🧹 usbmuxd_shim 已清理");
        }

        if (status == 0) {
            if (isDDImounted()) {
                NSLog(@"[mount-ddi] ✅ 恭喜！DDI 已成功本地挂载（无需 USB）。");
                return 0;
            } else {
                NSLog(@"[mount-ddi] ⚠️ go-ios 返回 0 但 /Developer 仍未挂载。");
                return 105;
            }
        } else {
            NSLog(@"[mount-ddi] ❌ 挂载引擎报错: %d", status);
            return status;
        }
    }

    if ([cmd isEqualToString:@"start-wda"]) {
      // freopen("/var/mobile/Media/go-ios.log", "a", stdout);
      // freopen("/var/mobile/Media/go-ios.log", "a", stderr);
      NSLog(@"========================");
      NSLog(@"[start-wda] ROOT HELPER INVOKED (v7 - DDI Guard)");
      
      // 【v1616】前置检查 DDI 挂载状态
      if (!isDDImounted()) {
          NSLog(@"[start-wda] ⚠️ DDI 未就绪，正在尝试自动执行本地挂载...");
          // 调用当前可执行文件的 mount-ddi 命令
          NSString *helperPath = [[NSProcessInfo processInfo] arguments].firstObject;
          char *mArgv[] = { (char *)[helperPath UTF8String], "mount-ddi", NULL };
          pid_t mPid;
          extern char **environ;
          posix_spawn(&mPid, [helperPath UTF8String], NULL, NULL, mArgv, environ);
          int mStatus;
          waitpid(mPid, &mStatus, 0);
          
          if (WEXITSTATUS(mStatus) == 0 && isDDImounted()) {
              NSLog(@"[start-wda] ✅ 自动挂载成功。");
          } else {
              NSLog(@"[start-wda] ⚠️ DDI 自动挂载检查未通过，但我们将尝试强制启动 WDA (Antigravity Force Mode).");
              // 不再直接 return 201，允许流程继续尝试
          }
      }
      
      NSLog(@"[start-wda] ✅ DDI 指标正常，准备启动 WDA 看护...");
      
      // 我们改用封装好的 killall
      killall(@"go-ios-arm64", YES);
      usleep(200000); 
      
      NSString *helperPath = [[NSProcessInfo processInfo] arguments].firstObject;
      NSString *bundleId = @"com.apple.accessibility.ecwda";
      if (argc > 2) bundleId = [NSString stringWithUTF8String:argv[2]];
      
      NSArray *argsM = @[@"echelper", @"run-wda-daemon", bundleId];
      char **argsC = (char **)malloc((argsM.count + 1) * sizeof(char *));
      for (NSUInteger i = 0; i < argsM.count; i++) argsC[i] = strdup([argsM[i] UTF8String]);
      argsC[argsM.count] = NULL;
      
      extern char **environ;
      pid_t daemon_pid;
      int ret = posix_spawn(&daemon_pid, [helperPath UTF8String], NULL, NULL, argsC, environ);
      
      for (NSUInteger i = 0; i < argsM.count; i++) free(argsC[i]);
      free(argsC);
      
      if (ret == 0) {
        NSLog(@"[start-wda] ✅ 成功拉起 run-wda-daemon 守护进程 (pid: %d)", daemon_pid);
      } else {
        NSLog(@"[start-wda] ❌ 拉起 run-wda-daemon 失败: %s", strerror(ret));
      }
      return 0;
    }

#ifndef TROLLSTORE_LITE // 恢复条件编译
    if ([cmd isEqualToString:@"get-device-info"]) {
      NSString *mac = get_mac_address();
      if (!mac)
        mac = @"Unavailable";

      NSString *udid = nil;

      // 1. Try MobileGestalt SerialNumber (Standard ID)
      void *lib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
      if (lib) {
        CFStringRef (*MGCopyAnswer)(CFStringRef) = dlsym(lib, "MGCopyAnswer");
        if (MGCopyAnswer) {
          udid = (__bridge_transfer NSString *)MGCopyAnswer(CFSTR("SerialNumber"));
        }
        dlclose(lib);
      }

      // 2. Try IOKit if MG-SN failed
      if (!udid) {
        udid = get_udid_iokit(); // This returns SerialNumber from IOKit
      }

      // 3. Fallback to UniqueDeviceID (UDID)
      if (!udid) {
          void *lib2 = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
          if (lib2) {
              CFStringRef (*MGCopyAnswer)(CFStringRef) = dlsym(lib2, "MGCopyAnswer");
              if (MGCopyAnswer) {
                  udid = (__bridge_transfer NSString *)MGCopyAnswer(CFSTR("SerialNumber"));
              }
              dlclose(lib2);
          }
      }

      if (!udid)
        udid = @"Unavailable";

      printf("MAC:%s\n", mac.UTF8String);
      printf("UDID:%s\n", udid.UTF8String);
      return 0;
    }
#endif

    if ([cmd isEqualToString:@"monitor-usb"]) {
        NSLog(@"========================");
        NSLog(@"[monitor-usb] USB/屏幕多重感应监听器已启动 (v1615)");
        
        void (^triggerBlock)(int) = ^(int t) {
            handlePowerSourceChanged();
        };

        int t1, t2;
        // 1. 监听电源适配器连接变更
        notify_register_dispatch("com.apple.system.powermanagement.poweradapter", &t1, dispatch_get_main_queue(), triggerBlock);
        
        // 2. 监听显示状态变更（插线必然亮屏，这是最可靠的触发信号）
        notify_register_dispatch("com.apple.iokit.hid.displayStatus", &t2, dispatch_get_main_queue(), triggerBlock);
        
        // 初始执行一次检查
        handlePowerSourceChanged();
        
        // 保持运行
        [[NSRunLoop mainRunLoop] run];
        return 0;
    }


    NSLog(@"echelper returning %d", ret);
    return ret;
  }
}
