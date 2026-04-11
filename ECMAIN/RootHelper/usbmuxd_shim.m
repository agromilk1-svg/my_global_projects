// usbmuxd_shim.m - v1904 原生 TLS 隧道 + 完全仿射 lockdownd
#import "usbmuxd_shim.h"
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <pthread.h>
#import <spawn.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

// --- TLS PEM 转换辅助 ---
static NSData *pemToDER(NSData *pemData) {
    if (!pemData) return nil;
    NSString *pemStr = [[NSString alloc] initWithData:pemData encoding:NSUTF8StringEncoding];
    if (!pemStr || ![pemStr hasPrefix:@"-----BEGIN "]) return pemData; // 假设非 PEM 已经是 DER
    
    NSArray *lines = [pemStr componentsSeparatedByString:@"\n"];
    NSMutableString *base64Str = [NSMutableString string];
    for (NSString *line in lines) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trim hasPrefix:@"-----"]) continue;
        [base64Str appendString:trim];
    }
    
    if (base64Str.length > 0) {
        NSData *der = [[NSData alloc] initWithBase64EncodedString:base64Str options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (der.length > 26) {
            const uint8_t *bytes = der.bytes;
            // 简单的 PKCS#8 RSA OID 检查
            uint8_t rsa_oid[] = {0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00};
            if (memcmp(bytes + 9, rsa_oid, 13) == 0) {
                // 这是一个 PKCS#8 包装的 RSA 私钥，剥离前 26 字节，提取纯 PKCS#1 核心
                der = [der subdataWithRange:NSMakeRange(26, der.length - 26)];
            }
        }
        return der ? der : pemData;
    }
    return pemData;
}

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
static NSString *g_bundleDir = nil; // [v1806] echelper 所在目录，用于查找内嵌配对记录
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

#include <ifaddrs.h>
#include <arpa/inet.h>
static NSString *getWiFiIPFromHelper(void) {
    NSString *address = @"";
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *temp_addr = NULL;
    int success = 0;
    
    success = getifaddrs(&interfaces);
    if (success == 0) {
        temp_addr = interfaces;
        while(temp_addr != NULL) {
            if(temp_addr->ifa_addr->sa_family == AF_INET) {
                if([[NSString stringWithUTF8String:temp_addr->ifa_name] isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
            temp_addr = temp_addr->ifa_next;
        }
    }
    freeifaddrs(interfaces);
    return address;
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
      
      NSLog(@"[v1909] 🏎️ 收到 Connect %d，启动原生 TLS 隧道...", port);
      
      // ========== [v1904] 原生 TLS 隧道 ==========
      // remoted 在 62078 上要求 TLS 客户端认证（使用 pair record 证书）
      // 之后在 TLS 层上走标准 usbmuxd 协议
      // 完全用 Apple SecureTransport 实现，替代外部 tls_proxy_arm64
      
      NSString *targetIP = @"127.0.0.1";
      // 如果 localhost 不通则尝试 WiFi IP
      NSString *wifiIP = getWiFiIPFromHelper();
      
      NSString *pairRecordPath = [g_bundleDir stringByAppendingPathComponent:@"ecwda_pair_record.plist"];
      NSDictionary *pairRecord = [NSDictionary dictionaryWithContentsOfFile:pairRecordPath];
      if (!pairRecord) {
          NSLog(@"[v1904] ❌ 无法加载配稳记录: %@", pairRecordPath);
          sendMuxResponse(c, h.tag, buildMuxResult(1));
          break;
      }
      
      NSData *hostCert = pemToDER(pairRecord[@"HostCertificate"]);
      NSData *hostKey  = pemToDER(pairRecord[@"HostPrivateKey"]);
      NSData *rootCert = pemToDER(pairRecord[@"RootCertificate"]);
      
      if (!hostCert || !hostKey) {
          NSLog(@"[v1904] ❌ 配对记录缺少 HostCertificate 或 HostPrivateKey");
          sendMuxResponse(c, h.tag, buildMuxResult(1));
          break;
      }
      
      // 构建 SecIdentity (证书 + 私钥)
      SecCertificateRef certRef = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)hostCert);
      if (!certRef) {
          NSLog(@"[v1904] ❌ 无法解析 HostCertificate");
          sendMuxResponse(c, h.tag, buildMuxResult(1));
          break;
      }
      
      // 导入私钥到 Keychain (解决 -50 errSecParam 问题)
      NSDictionary *keyAttrs = @{
          (__bridge id)kSecAttrKeyType: (__bridge id)kSecAttrKeyTypeRSA,
          (__bridge id)kSecAttrKeyClass: (__bridge id)kSecAttrKeyClassPrivate,
          (__bridge id)kSecAttrKeySizeInBits: @2048, // Apple 强制要求指定密钥长度
          (__bridge id)kSecAttrIsPermanent: @NO,
      };
      CFErrorRef keyError = NULL;
      SecKeyRef privateKeyRef = SecKeyCreateWithData((__bridge CFDataRef)hostKey, (__bridge CFDictionaryRef)keyAttrs, &keyError);
      if (!privateKeyRef) {
          NSLog(@"[v1904] ❌ 无法解析 HostPrivateKey: %@", keyError);
          if (keyError) CFRelease(keyError);
          CFRelease(certRef);
          sendMuxResponse(c, h.tag, buildMuxResult(1));
          break;
      }
      
      // 尝试连接 remoted (先 localhost 再 WiFi IP)
            // ==========================================================
      // 【终极降维打击方案】v1920 物理级 TLS 剥离策略
      // Apple 的 `NSStream` 存在不可调和的底层证书拦截 Bug，
      // 我们在此彻底废弃原生的 Objective-C TLS 引擎。
      // 改为在底层以守护进程方式唤醒极其健壮的 Go `tls_proxy_arm64`！
      // ==========================================================
      
      int proxy_port = 30000 + (arc4random() % 10000);
      NSString *portStr = [NSString stringWithFormat:@"%d", proxy_port];
      
      NSString *helperPath = [[NSProcessInfo processInfo] arguments].firstObject;
      NSString *tlsProxyPath = [[helperPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"tls_proxy_arm64"];
      
      pid_t proxy_pid;
      char *proxy_argv[] = { (char *)[tlsProxyPath UTF8String], (char *)[portStr UTF8String], "127.0.0.1", "62078", (char *)[pairRecordPath UTF8String], NULL };
      extern char **environ;
      int spawn_ret = posix_spawn(&proxy_pid, [tlsProxyPath UTF8String], NULL, NULL, proxy_argv, environ);
      
      if (spawn_ret != 0) {
          NSLog(@"[v1920] ❌ 无法启动本地 TLS 清道夫引擎 (tls_proxy_arm64), error: %d", spawn_ret);
          sendMuxResponse(c, h.tag, buildMuxResult(1));
          break;
      }
      
      NSLog(@"[v1920] 🚀 已拉起降维 TLS 清道夫 (pid: %d)，绑定本地隐形端口: %d", proxy_pid, proxy_port);
      
      int t = -1;
      struct sockaddr_in addr = {0};
      addr.sin_family = AF_INET;
      addr.sin_port = htons(proxy_port);
      addr.sin_addr.s_addr = inet_addr("127.0.0.1");
      
      // 暴力轮询重试连接清道夫引擎 (等待 Go 启动完毕，最多 2 秒)
      for (int i = 0; i < 40; i++) {
          usleep(50000); // 50ms
          t = socket(AF_INET, SOCK_STREAM, 0);
          if (connect(t, (struct sockaddr *)&addr, sizeof(addr)) == 0) break;
          close(t);
          t = -1;
      }
      
      if (t < 0) {
          NSLog(@"[v1920] ❌ 致命错误：清道夫代理超时未上线");
          sendMuxResponse(c, h.tag, buildMuxResult(1));
          kill(proxy_pid, SIGKILL);
          break;
      }
      
      NSLog(@"[v1920] ✅ TCP 管线已同清道夫咬合完毕");
      
      // 告诉 go-ios，买票成功，列车进站
      sendMuxResponse(c, h.tag, buildMuxResult(0));
      NSLog(@"[v1920] 📋 已向 go-ios 下发 Connect 放行令 (Result 0)");
      
      // 开始极速纯文本双向透传 (由外部 Go 引擎自动承担极其复杂的 TLS 封包压力)
      fd_set fds; uint8_t buf[8192];
      while (g_running) {
          FD_ZERO(&fds); FD_SET(c, &fds); FD_SET(t, &fds);
          int max_fd = (c > t) ? c : t;
          
          struct timeval tv = {1, 0}; // 1秒超时保证能够检测 g_running
          int sel = select(max_fd + 1, &fds, 0, 0, &tv);
          if (sel <= 0) continue;
          
          // 前方高能：go-ios 驶入管线
          if (FD_ISSET(c, &fds)) {
              ssize_t n = read(c, buf, sizeof(buf));
              if (n <= 0) { NSLog(@"[v1920] 🏁 go-ios 断开输入"); break; }
              if (write(t, buf, n) != n) { NSLog(@"[v1920] ❌ 管线断裂"); break; }
          }
          // 后方高能：服务端(经由清道夫) 返回
          if (FD_ISSET(t, &fds)) {
              ssize_t n = read(t, buf, sizeof(buf));
              if (n <= 0) { NSLog(@"[v1920] 🏁 服务端断开返回"); break; }
              if (write(c, buf, n) != n) { NSLog(@"[v1920] ❌ 管线断裂"); break; }
          }
      }
      
      NSLog(@"[v1920] 🧹 管线废弃，执行降解清理作业...");
      kill(proxy_pid, SIGKILL);
      close(t);
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
      // [v1806] 优先读系统配对记录，找不到则回退到 app bundle 内嵌的 ecwda_pair_record.plist
      NSString *pairId = req[@"PairRecordID"] ?: FAKE_UDID;
      NSString *path = [NSString stringWithFormat:@"/var/db/lockdown/%@.plist", pairId];
      NSData *rd = [NSData dataWithContentsOfFile:path];
      if (!rd && g_bundleDir) {
        // 回退：尝试 echelper 同目录下打包的配对记录
        NSString *bundlePair = [g_bundleDir stringByAppendingPathComponent:@"ecwda_pair_record.plist"];
        rd = [NSData dataWithContentsOfFile:bundlePair];
        if (rd) NSLog(@"[usbmuxd_shim] ReadPairRecord: 系统记录不存在，使用 bundle 内嵌配对记录: %@", bundlePair);
      }
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
  // [v1806] 记录 echelper 所在目录，用于查找内嵌的 ecwda_pair_record.plist
  NSString *execPath = [[NSProcessInfo processInfo] arguments].firstObject;
  if (execPath) g_bundleDir = [execPath stringByDeletingLastPathComponent];
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
