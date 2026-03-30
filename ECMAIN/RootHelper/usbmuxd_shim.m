// usbmuxd_shim.m - v1542 完全仿射 lockdownd + 真实服务对接
#import "usbmuxd_shim.h"
#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <pthread.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

// --- Linker Fix: Stubs for unknown symbols ---
int g_lockdown_network_port = 0;
void clientThreadFunc(void) {
    // Stub to satisfy linker error: _clientThreadFunc referenced from usbmuxd_shim.o
}

extern char **environ;

typedef struct {
  uint32_t length;
  uint32_t version;
  uint32_t request;
  uint32_t tag;
} UsbmuxHeader;

static const char *SOCKET_PATH = "/var/run/usbmuxd_shim.sock";
static NSString *FAKE_UDID = @"00000000-0000000000000000";
static int g_serverFd = -1;
static volatile BOOL g_running = NO;
static pthread_t g_listenThread;

// 服务端口映射：记录 StartService 返回的端口 e 本地 fd
typedef struct {
  uint16_t port;
  int localFd; // socketpair 的本端
} ServicePortMapping;

#define MAX_SERVICE_PORTS 16
static ServicePortMapping g_servicePorts[MAX_SERVICE_PORTS];
static int g_servicePortCount = 0;

#pragma mark - usbmuxd 协议辅助

static BOOL sendMuxResponse(int fd, uint32_t tag, NSData *plistData) {
  UsbmuxHeader h = {(uint32_t)(16 + plistData.length), 1, 8, tag};
  if (write(fd, &h, 16) != 16)
    return NO;
  write(fd, plistData.bytes, plistData.length);
  return YES;
}

static NSData *buildMuxResult(uint32_t num) {
  return [NSPropertyListSerialization
      dataWithPropertyList:@{
        @"MessageType" : @"Result",
        @"Number" : @(num)
      }
                    format:NSPropertyListXMLFormat_v1_0
                   options:0
                     error:nil];
}

#pragma mark - lockdownd 协议辅助

static BOOL sendLockdownPlist(int fd, NSDictionary *dict) {
  NSData *xml = [NSPropertyListSerialization
      dataWithPropertyList:dict
                    format:NSPropertyListXMLFormat_v1_0
                   options:0
                     error:nil];
  if (!xml)
    return NO;
  uint32_t len = htonl((uint32_t)xml.length);
  if (write(fd, &len, 4) != 4)
    return NO;
  if (write(fd, xml.bytes, xml.length) != (ssize_t)xml.length)
    return NO;
  return YES;
}

static NSDictionary *readLockdownPlist(int fd) {
  uint32_t lenBE;
  if (read(fd, &lenBE, 4) != 4)
    return nil;
  uint32_t len = ntohl(lenBE);
  if (len == 0 || len > 1024 * 1024)
    return nil;
  NSMutableData *data = [NSMutableData dataWithLength:len];
  ssize_t total = 0;
  while (total < (ssize_t)len) {
    ssize_t n = read(fd, (uint8_t *)data.mutableBytes + total, len - total);
    if (n <= 0)
      return nil;
    total += n;
  }
  return [NSPropertyListSerialization propertyListWithData:data
                                                   options:0
                                                    format:NULL
                                                     error:nil];
}

#pragma mark - MobileGestalt 设备信息

static NSString *getDeviceValue(NSString *key) {
  static void *mgLib = NULL;
  static CFStringRef (*MGCopyAnswer)(CFStringRef) = NULL;
  if (!mgLib) {
    mgLib = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (mgLib)
      MGCopyAnswer = dlsym(mgLib, "MGCopyAnswer");
  }
  if (!MGCopyAnswer)
    return nil;

  CFStringRef mgKey = NULL;
  if ([key isEqualToString:@"ProductVersion"])
    mgKey = CFSTR("ProductVersion");
  else if ([key isEqualToString:@"ProductType"])
    mgKey = CFSTR("ProductType");
  else if ([key isEqualToString:@"ProductName"])
    mgKey = CFSTR("ProductName");
  else if ([key isEqualToString:@"BuildVersion"])
    mgKey = CFSTR("BuildVersion");
  else if ([key isEqualToString:@"DeviceName"])
    mgKey = CFSTR("UserAssignedDeviceName");
  else if ([key isEqualToString:@"UniqueDeviceID"])
    mgKey = CFSTR("UniqueDeviceID");
  else if ([key isEqualToString:@"DeviceClass"])
    mgKey = CFSTR("DeviceClass");
  else if ([key isEqualToString:@"HardwareModel"])
    mgKey = CFSTR("HardwareModel");
  else if ([key isEqualToString:@"WiFiAddress"])
    mgKey = CFSTR("WifiAddress");
  else
    mgKey = (__bridge CFStringRef)key;

  CFTypeRef val = MGCopyAnswer(mgKey);
  if (!val)
    return nil;
  if (CFGetTypeID(val) == CFStringGetTypeID()) {
    return (__bridge_transfer NSString *)val;
  }
  CFRelease(val);
  return nil;
}

#pragma mark - 服务启动器

static int spawnServiceWithSocketPair(NSString *service) {
  int socks[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, socks) != 0) {
    NSLog(@"[v1544-svc] ❌ socketpair 创建失败: %s", strerror(errno));
    return -1;
  }

  NSMutableArray *candidates = [NSMutableArray new];
  if ([service isEqualToString:@"com.apple.testmanagerd.lockdown.secure"] ||
      [service isEqualToString:@"com.apple.testmanagerd.lockdown"]) {
    [candidates addObjectsFromArray:@[
      @"/Developer/usr/libexec/testmanagerd",
      @"/Developer/usr/bin/testmanagerd",
      @"/Developer/usr/bin/DTServiceHub",
      @"/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework/Support/testmanagerd",
      @"/System/Developer/usr/libexec/testmanagerd",
      @"/usr/libexec/testmanagerd"
    ]];
  } else if ([service isEqualToString:@"com.apple.mobile.installation_proxy"]) {
    [candidates addObject:@"/usr/libexec/mobile_installation_proxy"];
  } else {
    NSLog(@"[v1544-svc] ⚠️ 未知的服务请求: %@", service);
  }

  NSString *execPath = nil;
  for (NSString *path in candidates) {
    if (access([path UTF8String], F_OK) == 0) {
      execPath = path;
      break;
    } else {
      NSLog(@"[v1544-svc]   探测路径失败: %@ (errno: %d, %s)", path, errno, strerror(errno));
    }
  }

  // --- [v1593 增强] 递归搜索逻辑 ---
  if (!execPath && ([service containsString:@"testmanagerd"] || [service containsString:@"DTServiceHub"])) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtURL:[NSURL fileURLWithPath:@"/Developer"]
                                 includingPropertiesForKeys:nil
                                                    options:0
                                               errorHandler:nil];
    for (NSURL *url in enumerator) {
      NSString *filename = [url lastPathComponent];
      if ([filename isEqualToString:@"testmanagerd"] || [filename isEqualToString:@"DTServiceHub"]) {
        execPath = [url path];
        NSLog(@"[v1544-svc] 🎉 发现野生服务！定位成功: %@", execPath);
        break;
      }
    }
  }

  if (!execPath) {
    NSLog(@"[v1544-svc] ⚠️ 最终未能在设备上找到服务 %@ 的可执行文件", service);
    close(socks[1]);
    return socks[0];
  }

  NSLog(@"[v1544-svc] 🚀 准备注入启动: %@ (fd=%d)", execPath, socks[1]);

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, socks[1], 0);
  posix_spawn_file_actions_adddup2(&actions, socks[1], 1);
  posix_spawn_file_actions_addclose(&actions, socks[0]);
  posix_spawn_file_actions_addclose(&actions, socks[1]);

  char *argv[] = {(char *)[execPath UTF8String], NULL};
  pid_t pid;
  int ret = posix_spawn(&pid, [execPath UTF8String], &actions, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  close(socks[1]);

  if (ret == 0) {
    NSLog(@"[v1544-svc] ✅ 服务 %@ 已成功拉起 pid=%d", service, pid);
  } else {
    NSLog(@"[v1544-svc] ❌ 服务启动失败: %s (%d)", strerror(ret), ret);
    close(socks[0]);
    return -1;
  }

  return socks[0];
}

#pragma mark - handleFakeLockdown

static void handleFakeLockdown(int clientFd) {
  NSLog(@"[v1542-LD] 🎭 启动本地 lockdownd 仿射器 fd=%d", clientFd);

  while (g_running) {
    NSDictionary *req = readLockdownPlist(clientFd);
    if (!req) break;

    NSString *request = req[@"Request"];
    if ([request isEqualToString:@"QueryType"]) {
      sendLockdownPlist(clientFd, @{@"Request" : @"QueryType", @"Type" : @"com.apple.mobile.lockdown"});
    } else if ([request isEqualToString:@"GetValue"]) {
      NSString *key = req[@"Key"];
      if (key) {
        NSString *val = getDeviceValue(key);
        if (val) {
          sendLockdownPlist(clientFd, @{@"Request" : @"GetValue", @"Key" : key, @"Value" : val});
        } else {
          sendLockdownPlist(clientFd, @{@"Request" : @"GetValue", @"Key" : key, @"Error" : @"MissingValue"});
        }
      } else {
        NSMutableDictionary *vals = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"DeviceName", @"ProductVersion", @"ProductType", @"ProductName", @"BuildVersion", @"UniqueDeviceID", @"DeviceClass", @"HardwareModel"]) {
          NSString *v = getDeviceValue(k);
          if (v) vals[k] = v;
        }
        sendLockdownPlist(clientFd, @{@"Request" : @"GetValue", @"Value" : vals});
      }
    } else if ([request isEqualToString:@"StartSession"]) {
      sendLockdownPlist(clientFd, @{@"Request" : @"StartSession", @"SessionID" : [[NSUUID UUID] UUIDString], @"EnableSessionSSL" : @NO});
    } else if ([request isEqualToString:@"StartService"]) {
      NSString *service = req[@"Service"];
      int localFd = spawnServiceWithSocketPair(service);
      int listenFd = socket(AF_INET, SOCK_STREAM, 0);
      struct sockaddr_in saddr;
      memset(&saddr, 0, sizeof(saddr));
      saddr.sin_family = AF_INET;
      saddr.sin_addr.s_addr = inet_addr("127.0.0.1");
      saddr.sin_port = 0;
      bind(listenFd, (struct sockaddr *)&saddr, sizeof(saddr));
      listen(listenFd, 1);
      socklen_t slen = sizeof(saddr);
      getsockname(listenFd, (struct sockaddr *)&saddr, &slen);
      uint16_t servicePort = ntohs(saddr.sin_port);
      if (g_servicePortCount < MAX_SERVICE_PORTS) {
        g_servicePorts[g_servicePortCount].port = servicePort;
        g_servicePorts[g_servicePortCount].localFd = localFd;
        g_servicePortCount++;
      }
      sendLockdownPlist(clientFd, @{@"Request" : @"StartService", @"Service" : service, @"Port" : @(servicePort), @"EnableServiceSSL" : @NO});
      dispatch_async(dispatch_get_global_queue(0, 0), ^{
        struct timeval tv = {10, 0};
        setsockopt(listenFd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        int conn = accept(listenFd, NULL, NULL);
        close(listenFd);
        if (conn >= 0 && localFd >= 0) {
          fd_set f;
          unsigned char b[16384];
          while (g_running) {
            FD_ZERO(&f); FD_SET(conn, &f); FD_SET(localFd, &f);
            int mx = (conn > localFd ? conn : localFd) + 1;
            struct timeval stv = {30, 0};
            if (select(mx, &f, 0, 0, &stv) <= 0) break;
            if (FD_ISSET(conn, &f)) {
              ssize_t n = read(conn, b, sizeof(b));
              if (n <= 0 || write(localFd, b, n) != n) break;
            }
            if (FD_ISSET(localFd, &f)) {
              ssize_t n = read(localFd, b, sizeof(b));
              if (n <= 0 || write(conn, b, n) != n) break;
            }
          }
          close(localFd);
        }
        if (conn >= 0) close(conn);
      });
    } else if ([request isEqualToString:@"StopSession"]) {
      sendLockdownPlist(clientFd, @{@"Request" : @"StopSession"});
      break;
    } else {
      sendLockdownPlist(clientFd, @{@"Request" : request ?: @"Unknown"});
    }
  }
}

#pragma mark - handleClient

static void handleClient(int c) {
  while (g_running) {
    UsbmuxHeader h;
    if (read(c, &h, 16) != 16) break;
    uint32_t pl = h.length - 16;
    if (pl > 1024 * 1024) break;
    NSMutableData *pd = [NSMutableData dataWithLength:pl];
    read(c, pd.mutableBytes, pl);
    NSDictionary *req = [NSPropertyListSerialization propertyListWithData:pd options:0 format:NULL error:nil];
    if (!req) break;
    NSString *mt = req[@"MessageType"];
    if ([mt isEqualToString:@"Connect"]) {
      uint16_t port = ntohs([req[@"PortNumber"] unsignedShortValue]);
      sendMuxResponse(c, h.tag, buildMuxResult(0));
      if (port == 62078) {
        handleFakeLockdown(c);
      } else {
        int t = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in s; memset(&s, 0, sizeof(s));
        s.sin_family = AF_INET; s.sin_port = htons(port); s.sin_addr.s_addr = inet_addr("127.0.0.1");
        if (connect(t, (void *)&s, sizeof(s)) == 0) {
          fd_set f; unsigned char b[8192];
          while (g_running) {
            FD_ZERO(&f); FD_SET(c, &f); FD_SET(t, &f);
            int mx = (c > t ? c : t) + 1;
            if (select(mx, &f, 0, 0, 0) <= 0) break;
            if (FD_ISSET(c, &f)) {
              ssize_t n = read(c, b, 8192);
              if (n <= 0 || write(t, b, n) != n) break;
            }
            if (FD_ISSET(t, &f)) {
              ssize_t n = read(t, b, 8192);
              if (n <= 0 || write(c, b, n) != n) break;
            }
          }
        }
        close(t);
      }
      break;
    } else if ([mt isEqualToString:@"Listen"]) {
      sendMuxResponse(c, h.tag, buildMuxResult(0));
      NSDictionary *ae = @{@"MessageType":@"Attached",@"DeviceID":@(1),@"Properties":@{@"SerialNumber":FAKE_UDID,@"ConnectionType":@"USB",@"DeviceID":@(1),@"ProductID":@(4776),@"LocationID":@(0)}};
      sendMuxResponse(c, 0, [NSPropertyListSerialization dataWithPropertyList:ae format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
      char b[1]; while (g_running && read(c, b, 1) > 0);
      break;
    } else if ([mt isEqualToString:@"ReadBUID"]) {
      NSDictionary *resp = @{@"MessageType":@"Result",@"Number":@(0),@"BUID":@"33333333-3333-3333-3333-333333333333"};
      sendMuxResponse(c, h.tag, [NSPropertyListSerialization dataWithPropertyList:resp format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
    } else if ([mt isEqualToString:@"ListDevices"]) {
      NSDictionary *dev = @{@"DeviceID":@(1),@"MessageType":@"Attached",@"Properties":@{@"SerialNumber":FAKE_UDID,@"ConnectionType":@"USB",@"DeviceID":@(1),@"ProductID":@(4776),@"LocationID":@(0)}};
      sendMuxResponse(c, h.tag, [NSPropertyListSerialization dataWithPropertyList:@{@"MessageType":@"DeviceList",@"DeviceList":@[dev]} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
    } else if ([mt isEqualToString:@"ReadPairRecord"]) {
      NSString *path = [NSString stringWithFormat:@"/var/db/lockdown/%@.plist", req[@"PairRecordID"] ?: FAKE_UDID];
      NSData *rd = [NSData dataWithContentsOfFile:path];
      if (rd) sendMuxResponse(c, h.tag, [NSPropertyListSerialization dataWithPropertyList:@{@"MessageType":@"Result",@"Number":@(0),@"PairRecordData":rd} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]);
      else sendMuxResponse(c, h.tag, buildMuxResult(1));
    } else if ([mt isEqualToString:@"SavePairRecord"] || [mt isEqualToString:@"DeletePairRecord"]) {
      sendMuxResponse(c, h.tag, buildMuxResult(0));
    } else {
      sendMuxResponse(c, h.tag, buildMuxResult(0));
    }
  }
  close(c);
}

#pragma mark - 生命周期

static void *listenThreadFunc(void *arg) {
  while (g_running) {
    int c = accept(g_serverFd, NULL, NULL);
    if (c >= 0) dispatch_async(dispatch_get_global_queue(0, 0), ^{ handleClient(c); });
  }
  return NULL;
}

BOOL startUsbmuxdShimWithUDID(NSString *udid) {
  if (udid) FAKE_UDID = [udid copy];
  g_servicePortCount = 0;
  unlink(SOCKET_PATH);
  g_serverFd = socket(AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX; strcpy(addr.sun_path, SOCKET_PATH);
  if (bind(g_serverFd, (struct sockaddr *)&addr, sizeof(addr)) < 0) return NO;
  chmod(SOCKET_PATH, 0777);
  listen(g_serverFd, 10);
  g_running = YES;
  pthread_create(&g_listenThread, NULL, listenThreadFunc, NULL);
  return YES;
}

void stopUsbmuxdShim(void) {
  g_running = NO;
  if (g_serverFd >= 0) close(g_serverFd);
  unlink(SOCKET_PATH);
}
