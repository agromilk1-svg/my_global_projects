#import "PacketTunnelProvider.h"
#import "ECHevTunnel.h"
#import "ECTun2Proxy.h"
#import "ECUDPBridge.h"
#import <Mihomo/Mihomo.h>
#import <os/log.h>

#import <arpa/inet.h>
#import <netdb.h>

extern BOOL BridgeStart(NSString *config, NSError **error);

@interface PacketTunnelProvider ()
@property(atomic) BOOL isTunnelRunning;
@property(nonatomic, strong) NSFileHandle *logFileHandle;
@property(nonatomic, assign)
    int tunFD; // Native TUN FD from iOS (0 = fallback to bridge)
@property(nonatomic, strong) ECHevTunnel *hevTunnel;
@property(nonatomic, strong) ECUDPBridge *udpBridge;
@property(nonatomic, strong) ECTun2Proxy *tun2proxy;
// 代理健康检查
@property(nonatomic, strong) NSTimer *proxyHealthTimer;
@property(nonatomic, assign) NSInteger consecutiveProxyFailures;
@property(nonatomic, copy) NSDictionary *activeConfigDict; // 保存当前配置供健康检查使用
@end

@implementation PacketTunnelProvider

- (void)redirectConsoleLogToDocumentFolder {
  // BUILD #415: 强制捕获被吞噬的 Go 内核底层日志
  // 警告：NSLog 会写往 stderr，如果此时 dup2 劫持了 stderr，会诱发无线递归死锁。
  // 解决：使用 os_log (iOS 10+) 绕过标准流直接写入系统日志。
  NSPipe *pipe = [NSPipe pipe];
  NSFileHandle *pipeReadHandle = [pipe fileHandleForReading];
  int writeFD = [[pipe fileHandleForWriting] fileDescriptor];
  dup2(writeFD, fileno(stdout));
  dup2(writeFD, fileno(stderr));
  
  os_log_t logger = os_log_create("com.ecmain.app", "Mihomo-Go");

  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
    char buffer[4096];
    while (YES) {
      ssize_t bytesRead = read([pipeReadHandle fileDescriptor], buffer, sizeof(buffer) - 1);
      if (bytesRead > 0) {
        buffer[bytesRead] = '\0';
        NSString *str = [NSString stringWithUTF8String:buffer];
        if (str) {
          str = [str stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
          os_log(logger, "%{public}@", str);
        }
      } else {
        break; 
      }
    }
  });
}

- (void)logToFile:(NSString *)message {
  NSLog(@"[ECMAIN Tunnel] %@", message);
}

- (NSArray<NSString *> *)resolveHostToIPs:(NSString *)hostname {
  if (hostname.length == 0)
    return @[];

  struct addrinfo hints, *res, *p;
  char ipstr[INET6_ADDRSTRLEN];
  NSMutableArray *results = [NSMutableArray array];

  memset(&hints, 0, sizeof hints);
  hints.ai_family = AF_INET; // IPv4 only
  hints.ai_socktype = SOCK_STREAM;

  if (getaddrinfo([hostname UTF8String], NULL, &hints, &res) != 0) {
    return @[];
  }

  for (p = res; p != NULL; p = p->ai_next) {
    void *addr;
    if (p->ai_family == AF_INET) {
      struct sockaddr_in *ipv4 = (struct sockaddr_in *)p->ai_addr;
      addr = &(ipv4->sin_addr);
      inet_ntop(p->ai_family, addr, ipstr, sizeof ipstr);
      NSString *ip = [NSString stringWithUTF8String:ipstr];
      if (ip && ![results containsObject:ip]) {
        [results addObject:ip];
      }
    }
  }

  freeaddrinfo(res);
  return results;
}

- (NSInteger)getMTUFrom:(NSDictionary *)dict {
    // BUILD #415: 强制使用 1280 (IPv6 最小 MTU)
    // 理由：经过 Chained Proxy (SS+HTTP+Socks5) 三层封装后，原始 1500 报文极易分片
    // iOS 虚拟网卡对分片包的重组效率极低且易导致断流，1280 是最稳妥的选择。
    return 1280;
}

- (void)startTunnelWithOptions:(NSDictionary *)options
             completionHandler:(void (^)(NSError *))completionHandler {

  [self redirectConsoleLogToDocumentFolder];
  [self logToFile:@"startTunnelWithOptions called (Stdout Redirected)"];

  // 1. PRIMARY: Get config from protocolConfiguration (passed by main app)
  NETunnelProviderProtocol *tunnelProtocol =
      (NETunnelProviderProtocol *)self.protocolConfiguration;
  NSDictionary *configDict = tunnelProtocol.providerConfiguration;

  [self logToFile:[NSString
                      stringWithFormat:@"protocolConfiguration 读取: %@",
                                       configDict ? @"成功" : @"失败(nil)"]];

  // 2. FALLBACK: Try App Group (may not work due to sandbox)
  if (!configDict) {
    [self logToFile:@"尝试从 App Group 读取..."];
    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
    configDict = [defaults dictionaryForKey:@"VPNConfig"];

    [self logToFile:[NSString
                        stringWithFormat:@"App Group 读取: %@",
                                         configDict ? @"成功" : @"失败(nil)"]];
  }

  // 3. LAST RESORT: Use default fallback config
  if (!configDict) {
    [self logToFile:@"⚠️ 使用默认备用配置"];
    configDict = @{
      @"type" : @"Shadowsocks",
      @"server" : @"127.0.0.1",
      @"port" : @"80",
      @"password" : @"",
      @"cipher" : @"aes-256-gcm"
    };
  } else {
    [self logToFile:[NSString stringWithFormat:
                                  @"✅ 配置详情: type=%@, server=%@, port=%@",
                                  configDict[@"type"], configDict[@"server"],
                                  configDict[@"port"]]];
  }

  // MTU Configuration (Build #396)

  NSString *type = configDict[@"type"];
  if ([type isEqualToString:@"Local"]) {
    [self logToFile:@"Starting Local Keep-Alive Mode (Fake VPN)"];

    // Fake Tunnel Settings
    NEPacketTunnelNetworkSettings *settings =
        [[NEPacketTunnelNetworkSettings alloc]
            initWithTunnelRemoteAddress:@"127.0.0.1"];
    settings.IPv4Settings =
        [[NEIPv4Settings alloc] initWithAddresses:@[ @"198.18.0.1" ]
                                      subnetMasks:@[ @"255.255.255.255" ]];
    // Empty routes = No traffic routed = Split tunnel with nothing included
    settings.IPv4Settings.includedRoutes = @[];
    settings.MTU = @([self getMTUFrom:configDict]);

    __weak typeof(self) weakSelf = self;
    [self setTunnelNetworkSettings:settings
                 completionHandler:^(NSError *_Nullable error) {
                   if (error) {
                     [weakSelf
                         logToFile:[NSString
                                       stringWithFormat:
                                           @"Failed to set Local settings: %@",
                                           error]];
                     completionHandler(error);
                   } else {
                     [weakSelf logToFile:@"Local Tunnel Started."];
                     weakSelf.isTunnelRunning = YES;
                     // No readPackets needed for empty route
                     completionHandler(nil);
                   }
                 }];
    return;
  }

  // BUILD #382: NATIVE TUN INTEGRATION
  // New Flow: Set Network Settings FIRST → Get FD → Generate Config with FD →
  // Start Mihomo This allows Mihomo to use its native TUN stack (gVisor) for
  // proper UDP/QUIC handling.

  [self logToFile:@"🚀 BUILD #382: Native TUN Mode Enabled"];

  // 2. Configure tunnel network settings FIRST to get FD
  [self configureTunnelSettingsWithConfig:configDict
                        completionHandler:completionHandler];
}

// Extracted method for configuring tunnel settings
- (void)configureTunnelSettingsWithConfig:(NSDictionary *)configDict
                        completionHandler:
                            (void (^)(NSError *))completionHandler {

  [self logToFile:
            @"Configuring Tunnel Network Settings (Full Tunnel + Tun Mode)..."];

  // BUILD #415: tunnelRemoteAddress 必须使用代理服务器真实 IP
  // 使用 127.0.0.1 会导致 iOS 系统反复报 "address is loopback" 并破坏路由表
  id serverVal = configDict[@"server"];
  NSString *tunnelRemoteAddr = serverVal ? [NSString stringWithFormat:@"%@", serverVal] : @"192.0.2.1";

  // 将供应商域名显式地提前解析为 IP 以适配底层 Network Extension 路由表的限制
  NSArray<NSString *> *resolvedAddrs = [self resolveHostToIPs:tunnelRemoteAddr];
  if (resolvedAddrs.count > 0) {
      tunnelRemoteAddr = resolvedAddrs.firstObject;
  }

  NEPacketTunnelNetworkSettings *settings =
      [[NEPacketTunnelNetworkSettings alloc]
          initWithTunnelRemoteAddress:tunnelRemoteAddr];
  [self logToFile:[NSString stringWithFormat:@"📦 tunnelRemoteAddress = %@", tunnelRemoteAddr]];

  // IPv4: 198.18.0.1/16 (Virtual TUN Address)
  settings.IPv4Settings =
      [[NEIPv4Settings alloc] initWithAddresses:@[ @"198.18.0.1" ]
                                    subnetMasks:@[ @"255.255.0.0" ]];
  // IMPORTANT: Must include default route for VPN icon to appear in status bar
  // (Like Shadowrocket)
  // ipv4Settings.includedRoutes = @[ [NEIPv4Route defaultRoute] ]; // Commented
  // out to allow UDP Direct
  // ipv4Settings.includedRoutes = @[ [NEIPv4Route defaultRoute] ]; // Commented
  // out to allow UDP Direct
  settings.IPv4Settings.includedRoutes =
      @[ [NEIPv4Route defaultRoute] ]; // Restore Default Route for UDP Hijack

  // IPv6: Enabled
  // IPv6: DISABLED (Build #380)
  // We completely disable IPv6 on the tunnel interface to force apps to use
  // IPv4. This avoids "Blackhole" issues where apps see an IPv6 interface and
  // try to use it but traffic is dropped (ICMPv6 issues).
  settings.IPv6Settings = nil;

  /*
  settings.IPv6Settings =
      [[NEIPv6Settings alloc] initWithAddresses:@[ @"fd00:1234:ffff::10" ]
                           networkPrefixLengths:@[ @128 ]];
  settings.IPv6Settings.includedRoutes = @[ [NEIPv6Route defaultRoute] ];
  settings.IPv6Settings.excludedRoutes =
      @[ [[NEIPv6Route alloc] initWithDestinationAddress:@"fe80::"
                                     networkPrefixLength:@10] ];
  */

  // DNS: Use Public DNS (8.8.8.8) to ensure traffic is routable/hijackable
  // 198.18.0.1 might be dropped if not explicitly intercepted by SOCKS server
  NEDNSSettings *dnsSettings =
      [[NEDNSSettings alloc] initWithServers:@[ @"8.8.8.8", @"1.1.1.1" ]];
  dnsSettings.matchDomains = @[ @"" ]; // Catch all DNS queries
  settings.DNSSettings = dnsSettings;

  // NEProxySettings: Route HTTP/HTTPS to local Mihomo proxy
  // User configurable port (default 7890)
  id proxyPortVal = configDict[@"proxy_port"];
  NSString *proxyPortStr =
      (proxyPortVal) ? [NSString stringWithFormat:@"%@", proxyPortVal] : @"";
  NSInteger proxyPort =
      (proxyPortStr.length > 0) ? [proxyPortStr integerValue] : 7890;
  if (proxyPort <= 0 || proxyPort > 65535)
    proxyPort = 7890;
  [self logToFile:[NSString stringWithFormat:@"Using Proxy Port: %ld",
                                             (long)proxyPort]];

  NEProxySettings *proxySettings = [[NEProxySettings alloc] init];
  NEProxyServer *localProxy =
      [[NEProxyServer alloc] initWithAddress:@"127.0.0.1" port:proxyPort];
  proxySettings.HTTPEnabled = YES;
  proxySettings.HTTPSEnabled = YES;
  proxySettings.HTTPServer = localProxy;
  proxySettings.HTTPSServer = localProxy;
  proxySettings.excludeSimpleHostnames = YES;
  proxySettings.excludeSimpleHostnames = YES;
  // Note: iOS NEProxySettings does not support SOCKSEnabled property.
  // We rely on HTTP proxy for TCP, and Tun for UDP (if Tun works).
  // BUILD #361: RESTORE HYBRID MODE
  // TCP -> HTTP Proxy (Reliable)
  // UDP -> TUN -> ECUDPBridge (TikTok)
  settings.proxySettings = proxySettings;
  [self logToFile:@"✅ Hybrid Mode Restored (Proxy + TUN)"];

  // EXCLUDE PROXY SERVER TO PREVENT LOOP
  id serverHostVal = configDict[@"server"];
  NSString *serverHost =
      (serverHostVal) ? [NSString stringWithFormat:@"%@", serverHostVal] : @"";
  NSMutableArray<NSString *> *excludeIPs = [NSMutableArray array];

  NSMutableArray<NSString *> *hostsToResolve = [NSMutableArray array];
  if (serverHost.length > 0) {
    [hostsToResolve addObject:serverHost];
  }

  // BUILD #412: 链式代理排除逻辑
  // 如果当前是链式代理，前置节点 (FrontProxyNode) 的物理 IP 也必须加 excludedRoutes，否则同样引发 Loop
  NSString *proxyThroughID = configDict[@"proxy_through_id"];
  if (proxyThroughID.length > 0) {
    NSDictionary *frontNode = configDict[@"proxy_through_node"];
    if (!frontNode || ![frontNode isKindOfClass:[NSDictionary class]]) {
       NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
       NSArray *allNodes = [defaults arrayForKey:@"VPNNodeList"];
       if (allNodes) {
           for (NSDictionary *n in allNodes) {
               if ([n[@"id"] isEqualToString:proxyThroughID] || [n[@"name"] isEqualToString:proxyThroughID]) {
                   frontNode = n;
                   break;
               }
           }
       }
    }
    if (frontNode && frontNode[@"server"]) {
      NSString *frontHost = [NSString stringWithFormat:@"%@", frontNode[@"server"]];
      if (frontHost.length > 0 && ![hostsToResolve containsObject:frontHost]) {
          [hostsToResolve addObject:frontHost];
          [self logToFile:[NSString stringWithFormat:@"🔗 链式代理：检测到前置节点 %@，一同纳入排除路由", frontHost]];
      }
    }
  }

  // BUILD #415: DNS 服务器加入 excludedRoutes 循环防御逻辑
  // 确保所有 DNS 服务器 IP 都被排除，防止 DNS 查询流量被 TUN 拦截导致解析失败
  NSArray<NSString *> *dnsServers = settings.DNSSettings.servers;
  for (NSString *dnsIP in dnsServers) {
      if (dnsIP.length > 0 && ![hostsToResolve containsObject:dnsIP]) {
          [hostsToResolve addObject:dnsIP];
          [self logToFile:[NSString stringWithFormat:@"🛡️ DNS 防御：将 DNS 服务器 %@ 加入排除列表", dnsIP]];
      }
  }

  for (NSString *host in hostsToResolve) {
      NSArray<NSString *> *resolvedIPs = [self resolveHostToIPs:host];
      if (resolvedIPs.count == 0) {
          [self logToFile:[NSString stringWithFormat:@"⚠️ DNS Resolution failed for '%@', using fallback check", host]];
          NSRegularExpression *regex = [NSRegularExpression
              regularExpressionWithPattern:@"^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$"
                                    options:0
                                      error:nil];
          NSTextCheckingResult *match = [regex firstMatchInString:host options:0 range:NSMakeRange(0, host.length)];
          if (match) {
            [excludeIPs addObject:host];
          }
      } else {
          [excludeIPs addObjectsFromArray:resolvedIPs];
          [self logToFile:[NSString stringWithFormat:@"✅ Resolved '%@' -> %@", host, [resolvedIPs componentsJoinedByString:@", "]]];
      }
  }

  if (excludeIPs.count > 0) {
    [self logToFile:[NSString
                        stringWithFormat:@"Excluding Loop IPs: %@", [excludeIPs componentsJoinedByString:@", "]]];
    NSMutableArray<NEIPv4Route *> *excludedRoutes = [NSMutableArray array];
    for (NSString *ip in excludeIPs) {
        [excludedRoutes addObject:[[NEIPv4Route alloc] initWithDestinationAddress:ip
                                                                       subnetMask:@"255.255.255.255"]];
    }



    // BUILD #415: 移除 DNS 直连路由排除
    // 理由：在中国网络环境下，直连 8.8.8.8 会遭到 DNS 污染。
    // 必须让 DNS 请求通过 TUN 隧道，由 Mihomo 内核进行加密解密后再安全解析。
    
    settings.IPv4Settings.excludedRoutes = excludedRoutes;
    [self logToFile:[NSString stringWithFormat:@"🛡️ 排除路由已设置 (排除节点 IP: %lu 个)", (unsigned long)excludedRoutes.count]];

    // CAPTURE ALL TRAFFIC
    settings.IPv4Settings.includedRoutes = @[ [NEIPv4Route defaultRoute] ];

    // DNS: 使用 standard Public DNS (将通过 TUN 隧道被 Mihomo 拦截)
    NEDNSSettings *dnsSettings =
        [[NEDNSSettings alloc] initWithServers:@[ @"8.8.8.8", @"1.1.1.1" ]];
    dnsSettings.matchDomains = @[ @"" ];
    settings.DNSSettings = dnsSettings;
    [self logToFile:@"📌 DNS set to 8.8.8.8 / 1.1.1.1 (物理网卡直连，绕过 TUN)"];

  } else {
    [self logToFile:[NSString stringWithFormat:@"⚠️ Cannot exclude server '%@' "
                                               @"- PROBABLE ROUTING LOOP!",
                                               serverHost]];
  }

  settings.MTU = @([self getMTUFrom:configDict]);

  __weak typeof(self) weakSelf = self;
  [self
      setTunnelNetworkSettings:settings
             completionHandler:^(NSError *_Nullable error) {
               __strong typeof(weakSelf) strongSelf = weakSelf;
               if (!strongSelf)
                 return;
               if (error) {
                 [strongSelf
                     logToFile:[NSString stringWithFormat:
                                             @"❌ Failed to set settings: %@",
                                             error]];
                 completionHandler(error);
               } else {
                 [strongSelf
                     logToFile:
                         @"✅ Tunnel settings applied. Proxy Mode Active."];
                 strongSelf.isTunnelRunning = YES;

                 // Copy Country.mmdb to Shared Container
                 NSURL *containerURL = [[NSFileManager defaultManager]
                     containerURLForSecurityApplicationGroupIdentifier:
                         @"group.com.ecmain.shared"];
                 NSString *mmdbDest = [[containerURL path]
                     stringByAppendingPathComponent:@"Country.mmdb"];
                 NSString *mmdbSource = [[NSBundle mainBundle].bundlePath
                     stringByAppendingPathComponent:@"Country.mmdb"];

                 // RESTORED GEOIP COPY (Build #353) - Duplicates removed.

                 // Check if source exists (it should be in the AppEx bundle)
                 if ([[NSFileManager defaultManager]
                         fileExistsAtPath:mmdbSource]) {
                   if (![[NSFileManager defaultManager]
                           fileExistsAtPath:mmdbDest]) {
                     [[NSFileManager defaultManager] copyItemAtPath:mmdbSource
                                                             toPath:mmdbDest
                                                              error:nil];
                     [strongSelf
                         logToFile:@"📦 Country.mmdb copied to container"];
                   }
                 } else {
                   [strongSelf
                       logToFile:@"⚠️ Country.mmdb not found in bundle!"];
                 }

                 // BUILD #391: Copy GeoIP.dat for DNS fallback-filter
                 NSString *geoipDest = [[containerURL path]
                     stringByAppendingPathComponent:@"GeoIP.dat"];
                 NSString *geoipSource = [[NSBundle mainBundle].bundlePath
                     stringByAppendingPathComponent:@"GeoIP.dat"];
                 if ([[NSFileManager defaultManager]
                         fileExistsAtPath:geoipSource]) {
                   if (![[NSFileManager defaultManager]
                           fileExistsAtPath:geoipDest]) {
                     [[NSFileManager defaultManager] copyItemAtPath:geoipSource
                                                             toPath:geoipDest
                                                              error:nil];
                     [strongSelf logToFile:@"📦 GeoIP.dat copied to container"];
                   }
                 } else {
                   [strongSelf logToFile:@"⚠️ GeoIP.dat not found in bundle!"];
                 }

                 // ============================================================
                 // BUILD #382: NATIVE TUN MODE
                 // ============================================================
                 // Get TUN File Descriptor via KVC (unofficial but widely used)
                 int tunFD = [[strongSelf.packetFlow
                     valueForKeyPath:@"socket.fileDescriptor"] intValue];
                 strongSelf.tunFD = tunFD;
                 [strongSelf
                     logToFile:[NSString
                                   stringWithFormat:@"📦 TUN FD: %d", tunFD]];

                 if (tunFD <= 0) {
                   [strongSelf
                       logToFile:
                           @"⚠️ TUN FD=0, falling back to SOCKS5 Bridge Mode"];

                   // BUILD #415: Shadowrocket 模型 —— DNS 已在 excludedRoutes 中直连
                   // 无需额外重置 DNS，主逻辑已设置 8.8.8.8/1.1.1.1 走物理网卡
                   [strongSelf logToFile:@"📌 tun2proxy 降级模式：DNS 走物理网卡直连 8.8.8.8（Shadowrocket 模型）"];

                   // ============================================================
                   // BUILD #384: SOCKS5 BRIDGE FALLBACK
                   // ============================================================
                   // When iOS doesn't provide TUN FD, use HevSocks5Tunnel +
                   // ECUDPBridge to bridge packets to Mihomo's SOCKS5 port.

                   // Generate config WITHOUT TUN section
                   NSString *clashConfig =
                       [strongSelf generateClashConfigFrom:configDict
                                                 withTunFD:0];
                   [strongSelf
                       logToFile:[NSString
                                     stringWithFormat:@"Generated Config "
                                                      @"(Bridge Mode):\n%@",
                                                      clashConfig]];

                   // Start Mihomo first
                   dispatch_async(
                       dispatch_get_global_queue(
                           DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                       ^{
                         NSError *startError = nil;
                         BOOL success = BridgeStart(clashConfig, &startError);
                         if (!success || startError) {
                           [strongSelf
                               logToFile:[NSString stringWithFormat:
                                                       @"❌ Mihomo Failed: %@",
                                                       startError]];
                           completionHandler(startError);
                           return;
                         }

                         [strongSelf
                             logToFile:@"✅ Mihomo Started (Bridge Mode)"];

                         // ============================================================
                         // BUILD #386: tun2proxy Bridge Mode
                         // ============================================================
                         // Use tun2proxy instead of ECHevTunnel + ECUDPBridge
                         // tun2proxy uses socketpair to bridge
                         // NEPacketTunnelFlow to SOCKS5 This provides proper
                         // native UDP support!

                         dispatch_async(dispatch_get_main_queue(), ^{
                           NSString *proxyURL = [NSString
                               stringWithFormat:@"socks5://127.0.0.1:%ld",
                                                (long)proxyPort];
                           strongSelf.tun2proxy =
                               [[ECTun2Proxy alloc] initWithProxyURL:proxyURL];

                           __weak typeof(strongSelf) weakSelf3 = strongSelf;
                           [strongSelf.tun2proxy
                               startBridgeModeWithMTU:(uint16_t)[self
                                                          getMTUFrom:configDict]
                                         writeHandler:^(NSData *packet,
                                                        int family) {
                                           __strong typeof(weakSelf3)
                                               strongSelf3 = weakSelf3;
                                           if (strongSelf3 &&
                                               strongSelf3.isTunnelRunning) {
                                             [strongSelf3.packetFlow
                                                  writePackets:@[ packet ]
                                                 withProtocols:@[ @(family) ]];
                                           }
                                         }];

                           [strongSelf logToFile:@"🚀 tun2proxy Started "
                                                 @"(TCP+UDP via socketpair)"];

                           // 启动代理健康检查
                           [strongSelf startProxyHealthCheck];

                           // Start packet forwarding loop to tun2proxy
                           [strongSelf readPacketsForTun2Proxy];
                           completionHandler(nil);
                         });
                       });
                   return;
                 }

                 // Generate Config WITH TUN section
                 NSString *clashConfig =
                     [strongSelf generateClashConfigFrom:configDict
                                               withTunFD:tunFD];
                 [strongSelf
                     logToFile:[NSString stringWithFormat:@"Generated Config "
                                                          @"(Native TUN):\n%@",
                                                          clashConfig]];

                 // Start Mihomo with Native TUN stack
                 dispatch_async(
                     dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,
                                               0),
                     ^{
                       [strongSelf
                           logToFile:@"Starting Mihomo (Native TUN)..."];
                       NSError *startError = nil;
                       BOOL success = BridgeStart(clashConfig, &startError);

                       dispatch_async(dispatch_get_main_queue(), ^{
                         if (!success || startError) {
                           [strongSelf
                               logToFile:[NSString stringWithFormat:
                                                       @"❌ Mihomo Native "
                                                       @"TUN Failed: %@",
                                                       startError]];
                           completionHandler(startError);
                         } else {
                           [strongSelf
                               logToFile:@"✅ Mihomo Native TUN Started - "
                                         @"UDP/QUIC should work!"];
                           [strongSelf startProxyHealthCheck];
                           completionHandler(nil);
                         }
                       });
                     });
               }
             }];
}

// ============================================================================
// 代理健康检查
// 每 30 秒探测 Mihomo 本地 SOCKS5 端口是否可用
// 连续 5 次失败 → 主动调用 cancelTunnelWithError 退出，让主 App 自动重连
// 注意：VPN 本身对 SSL 透明，SSL 错误是代理节点故障的症状，不是原因
// ============================================================================
- (void)startProxyHealthCheck {
  [self.proxyHealthTimer invalidate];
  self.consecutiveProxyFailures = 0;
  __weak typeof(self) weakSelf = self;
  // 在主线程上安排定时器（Network Extension 的主 Runloop）
  self.proxyHealthTimer =
      [NSTimer scheduledTimerWithTimeInterval:30.0
                                       target:weakSelf
                                     selector:@selector(runProxyHealthCheck)
                                     userInfo:nil
                                      repeats:YES];
  [self logToFile:@"🩺 [ProxyHealth] 已启动代理健康检查（每 30 秒）"];
}

- (void)stopProxyHealthCheck {
  [self.proxyHealthTimer invalidate];
  self.proxyHealthTimer = nil;
}

- (void)runProxyHealthCheck {
  if (!self.isTunnelRunning) return;

  // 直接 TCP 连接测试 Mihomo 本地 SOCKS5 端口（127.0.0.1:7890）
  // 只检测端口是否 accept，不发送任何数据，不触发代理转发
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        BOOL alive = [self _checkLocalPort:7890];
        dispatch_async(dispatch_get_main_queue(), ^{
          if (!self.isTunnelRunning) return;

          if (alive) {
            if (self.consecutiveProxyFailures > 0) {
              [self logToFile:
                        [NSString stringWithFormat:
                             @"🩺 [ProxyHealth] ✅ Mihomo 恢复正常（之前连续失败 "
                             @"%ld 次）",
                             (long)self.consecutiveProxyFailures]];
            }
            self.consecutiveProxyFailures = 0;
          } else {
            self.consecutiveProxyFailures++;
            [self logToFile:
                      [NSString
                          stringWithFormat:
                              @"🩺 [ProxyHealth] ⚠️ Mihomo 端口不响应（连续第 "
                              @"%ld 次）",
                              (long)self.consecutiveProxyFailures]];

            // 连续 5 次失败（约 150 秒）→ 主动退出，让主 App 重连
            if (self.consecutiveProxyFailures >= 5) {
              [self logToFile:@"🩺 [ProxyHealth] ❌ 代理连续失败 5 次，主动终止 "
                              @"Tunnel，触发主 App 自动重连..."];
              [self stopProxyHealthCheck];
              self.isTunnelRunning = NO;
              NSError *healthErr = [NSError
                  errorWithDomain:@"com.ecmain.tunnel"
                             code:1001
                         userInfo:@{
                           NSLocalizedDescriptionKey :
                               @"代理节点连续 5 次无响应，主动重启 VPN"
                         }];
              [self cancelTunnelWithError:healthErr];
            }
          }
        });
      });
}

// 快速 TCP connect 探测本地端口是否 listening（不发数据，立即关闭）
- (BOOL)_checkLocalPort:(NSInteger)port {
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

  int sock = socket(AF_INET, SOCK_STREAM, 0);
  if (sock < 0) return NO;

  // 设置 3 秒超时
  struct timeval tv = {.tv_sec = 3, .tv_usec = 0};
  setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
  setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

  int result = connect(sock, (struct sockaddr *)&addr, sizeof(addr));
  close(sock);
  return (result == 0);
}

- (void)appendProxyConfigForNode:(NSDictionary *)dict
                         withName:(NSString *)name
                      dialerProxy:(NSString *)dialerProxy
                           toYAML:(NSMutableString *)yaml {
  NSString *type   = dict[@"type"] ?: @"Shadowsocks";
  NSString *server = dict[@"server"] ?: @"";
  // port: 始终写整数（Mihomo 不接受字符串 port）
  NSInteger port   = [dict[@"port"] integerValue];

  [yaml appendString:[NSString stringWithFormat:@"  - name: %@\n", name]];
  [yaml appendString:[NSString stringWithFormat:@"    server: %@\n", server]];
  [yaml appendString:[NSString stringWithFormat:@"    port: %ld\n", (long)port]];

  // TFO: 对 QUIC 类协议（Hysteria/TUIC）和 Reality 关闭，其余默认开启
  BOOL isTFOUnsafe = [type isEqualToString:@"Hysteria"]  ||
                     [type isEqualToString:@"Hysteria2"] ||
                     [type isEqualToString:@"Tuic"]      ||
                     [type isEqualToString:@"WireGuard"];
  BOOL tfoEnabled = isTFOUnsafe ? NO
      : (dict[@"tfo"] != nil ? [dict[@"tfo"] boolValue] : YES);
  if (tfoEnabled) [yaml appendString:@"    tfo: true\n"];

  if (dialerProxy.length > 0)
    [yaml appendString:[NSString stringWithFormat:@"    dialer-proxy: %@\n", dialerProxy]];

  // skip-cert-verify: 全局支持，所有 TLS 协议都读取此字段
  BOOL skipCert = dict[@"skip-cert-verify"] ? [dict[@"skip-cert-verify"] boolValue] : NO;

  // ──────────────────────────────────────────────────────────────────────────
  // Shadowsocks
  // ──────────────────────────────────────────────────────────────────────────
  if ([type isEqualToString:@"Shadowsocks"]) {
    [yaml appendString:@"    type: ss\n"];
    [yaml appendString:[NSString stringWithFormat:@"    cipher: %@\n",
                                                  dict[@"cipher"] ?: @"aes-256-gcm"]];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];

    // Plugin 处理（plugin-opts 支持 key=value 和 key: value 两种格式）
    if ([dict[@"plugin"] length] > 0) {
      [yaml appendString:[NSString stringWithFormat:@"    plugin: %@\n", dict[@"plugin"]]];
      NSString *optsStr = dict[@"plugin-opts"] ?: @"";
      // 清理花括号
      optsStr = [optsStr stringByReplacingOccurrencesOfString:@"{" withString:@""];
      optsStr = [optsStr stringByReplacingOccurrencesOfString:@"}" withString:@""];
      optsStr = [optsStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
      if (optsStr.length > 0) {
        [yaml appendString:@"    plugin-opts:\n"];
        // 支持分号和逗号两种分隔符（兼容 shadowrocket/quantumult 导出格式）
        NSArray *parts = [optsStr componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@";,"]];
        for (NSString *part in parts) {
          NSString *trimmed = [part stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          if (trimmed.length == 0) continue;
          // 兼容 "key=value" 格式，转为 "key: value"
          NSString *converted = [trimmed stringByReplacingOccurrencesOfString:@"="
                                                                    withString:@": "
                                                                       options:0
                                                                         range:NSMakeRange(0, [trimmed length])];
          // 防止重复转换（已经是 "key: value" 格式的不处理）
          if ([trimmed containsString:@": "]) converted = trimmed;
          [yaml appendString:[NSString stringWithFormat:@"      %@\n", converted]];
        }
        if (skipCert) [yaml appendString:@"      skip-cert-verify: true\n"];
      }
    } else if ([dict[@"obfs"] length] > 0) {
      [yaml appendString:@"    plugin: obfs\n"];
      [yaml appendString:@"    plugin-opts:\n"];
      [yaml appendString:[NSString stringWithFormat:@"      mode: %@\n", dict[@"obfs"]]];
      NSString *obfsHost = dict[@"obfs-param"] ?: @"";
      if (obfsHost.length == 0) obfsHost = @"bing.com";
      [yaml appendString:[NSString stringWithFormat:@"      host: %@\n", obfsHost]];
    } else if ([dict[@"ws-path"] length] > 0) {
      [yaml appendString:@"    plugin: v2ray-plugin\n"];
      [yaml appendString:@"    plugin-opts:\n"];
      [yaml appendString:@"      mode: websocket\n"];
      [yaml appendString:[NSString stringWithFormat:@"      path: %@\n", dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      host: %@\n", dict[@"ws-host"]]];
      if ([dict[@"tls"] boolValue]) {
        [yaml appendString:@"      tls: true\n"];
        if (skipCert) [yaml appendString:@"      skip-cert-verify: true\n"];
      }
    }

    BOOL udpOn = dict[@"udp"] ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString stringWithFormat:@"    udp: %@\n", udpOn ? @"true" : @"false"]];

  // ──────────────────────────────────────────────────────────────────────────
  // ShadowsocksR
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"ShadowsocksR"]) {
    [yaml appendString:@"    type: ssr\n"];
    [yaml appendString:[NSString stringWithFormat:@"    cipher: %@\n",
                                                  dict[@"cipher"] ?: @"aes-256-cfb"]];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    protocol: %@\n",
                                                  dict[@"protocol"] ?: @"origin"]];
    if ([dict[@"protocol-param"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    protocol-param: %@\n",
                                                    dict[@"protocol-param"]]];
    [yaml appendString:[NSString stringWithFormat:@"    obfs: %@\n",
                                                  dict[@"obfs"] ?: @"plain"]];
    if ([dict[@"obfs-param"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    obfs-param: %@\n",
                                                    dict[@"obfs-param"]]];
    BOOL udpOn = dict[@"udp"] ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString stringWithFormat:@"    udp: %@\n", udpOn ? @"true" : @"false"]];

  // ──────────────────────────────────────────────────────────────────────────
  // VMess — Fix: alterId 整数，servername，grpc/h2 传输层
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"VMess"]) {
    [yaml appendString:@"    type: vmess\n"];
    [yaml appendString:[NSString stringWithFormat:@"    uuid: %@\n", dict[@"uuid"] ?: @""]];
    // alterId 必须为整数
    [yaml appendString:[NSString stringWithFormat:@"    alterId: %ld\n",
                                                  (long)[dict[@"alterId"] integerValue]]];
    [yaml appendString:[NSString stringWithFormat:@"    cipher: %@\n",
                                                  dict[@"cipher"] ?: @"auto"]];
    BOOL udpOn = dict[@"udp"] ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString stringWithFormat:@"    udp: %@\n", udpOn ? @"true" : @"false"]];
    if ([dict[@"tls"] boolValue]) {
      [yaml appendString:@"    tls: true\n"];
      if ([dict[@"servername"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"    servername: %@\n", dict[@"servername"]]];
      if (skipCert)
        [yaml appendString:@"    skip-cert-verify: true\n"];
    }
    NSString *network = dict[@"network"] ?: @"";
    if (network.length > 0)
      [yaml appendString:[NSString stringWithFormat:@"    network: %@\n", network]];
    if ([network isEqualToString:@"ws"]) {
      [yaml appendString:@"    ws-opts:\n"];
      if ([dict[@"ws-path"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      path: %@\n", dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      headers:\n        Host: %@\n",
                                                      dict[@"ws-host"]]];
    } else if ([network isEqualToString:@"grpc"]) {
      [yaml appendString:@"    grpc-opts:\n"];
      NSString *svcName = dict[@"grpc-service-name"] ?: dict[@"serviceName"] ?: @"";
      [yaml appendString:[NSString stringWithFormat:@"      grpc-service-name: %@\n", svcName]];
    } else if ([network isEqualToString:@"h2"]) {
      [yaml appendString:@"    h2-opts:\n"];
      if ([dict[@"h2-path"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      path: [\"%@\"]\n", dict[@"h2-path"]]];
      if ([dict[@"h2-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      host: [%@]\n", dict[@"h2-host"]]];
    }

  // ──────────────────────────────────────────────────────────────────────────
  // VLESS — Fix: Reality 自动设 tls, grpc 传输层
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"VLESS"]) {
    [yaml appendString:@"    type: vless\n"];
    [yaml appendString:[NSString stringWithFormat:@"    uuid: %@\n", dict[@"uuid"] ?: @""]];
    if ([dict[@"flow"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    flow: %@\n", dict[@"flow"]]];
    BOOL udpOn = dict[@"udp"] ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString stringWithFormat:@"    udp: %@\n", udpOn ? @"true" : @"false"]];

    // Reality 强制开启 TLS
    NSDictionary *realityOpts = dict[@"reality-opts"];
    BOOL hasReality = realityOpts && [realityOpts isKindOfClass:[NSDictionary class]];
    BOOL tlsOn = [dict[@"tls"] boolValue] || hasReality;
    if (tlsOn) [yaml appendString:@"    tls: true\n"];
    if ([dict[@"servername"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    servername: %@\n", dict[@"servername"]]];
    if ([dict[@"client-fingerprint"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    client-fingerprint: %@\n",
                                                    dict[@"client-fingerprint"]]];
    if (!hasReality && skipCert)
      [yaml appendString:@"    skip-cert-verify: true\n"];
    if (hasReality) {
      [yaml appendString:@"    reality-opts:\n"];
      if ([realityOpts[@"public-key"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      public-key: %@\n",
                                                      realityOpts[@"public-key"]]];
      if ([realityOpts[@"short-id"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      short-id: %@\n",
                                                      realityOpts[@"short-id"]]];
    }

    NSString *network = dict[@"network"] ?: @"";
    if (network.length > 0)
      [yaml appendString:[NSString stringWithFormat:@"    network: %@\n", network]];
    if ([network isEqualToString:@"ws"]) {
      [yaml appendString:@"    ws-opts:\n"];
      if ([dict[@"ws-path"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      path: %@\n", dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      headers:\n        Host: %@\n",
                                                      dict[@"ws-host"]]];
    } else if ([network isEqualToString:@"grpc"]) {
      [yaml appendString:@"    grpc-opts:\n"];
      NSString *svcName = dict[@"grpc-service-name"] ?: dict[@"serviceName"] ?: @"";
      [yaml appendString:[NSString stringWithFormat:@"      grpc-service-name: %@\n", svcName]];
    }

  // ──────────────────────────────────────────────────────────────────────────
  // Trojan — Fix: tls 显式声明, ws-opts 支持
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"Trojan"]) {
    [yaml appendString:@"    type: trojan\n"];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    // Trojan 强制 TLS（协议设计层面不可关闭）
    [yaml appendString:@"    tls: true\n"];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
    if (skipCert)
      [yaml appendString:@"    skip-cert-verify: true\n"];
    NSString *network = dict[@"network"] ?: @"";
    if (network.length > 0)
      [yaml appendString:[NSString stringWithFormat:@"    network: %@\n", network]];
    if ([network isEqualToString:@"ws"]) {
      [yaml appendString:@"    ws-opts:\n"];
      if ([dict[@"ws-path"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      path: %@\n", dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      headers:\n        Host: %@\n",
                                                      dict[@"ws-host"]]];
    } else if ([network isEqualToString:@"grpc"]) {
      [yaml appendString:@"    grpc-opts:\n"];
      NSString *svcName = dict[@"grpc-service-name"] ?: dict[@"serviceName"] ?: @"";
      [yaml appendString:[NSString stringWithFormat:@"      grpc-service-name: %@\n", svcName]];
    }
    BOOL udpOn = dict[@"udp"] ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString stringWithFormat:@"    udp: %@\n", udpOn ? @"true" : @"false"]];

  // ──────────────────────────────────────────────────────────────────────────
  // Hysteria v1 — Fix: protocol, skip-cert-verify, up/down 单位
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"Hysteria"]) {
    [yaml appendString:@"    type: hysteria\n"];
    [yaml appendString:[NSString stringWithFormat:@"    auth_str: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    // protocol: 默认 udp，可选 wechat-video/faketcp
    NSString *proto = dict[@"protocol"] ?: @"udp";
    [yaml appendString:[NSString stringWithFormat:@"    protocol: %@\n", proto]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
    if (skipCert)
      [yaml appendString:@"    skip-cert-verify: true\n"];
    // up/down: 带单位（若已含 Mbps 则直接用，否则追加）
    NSString *up   = dict[@"up"]   ?: @"100";
    NSString *down = dict[@"down"] ?: @"100";
    if (![up containsString:@"Mbps"] && ![up containsString:@"Kbps"])
      up = [up stringByAppendingString:@" Mbps"];
    if (![down containsString:@"Mbps"] && ![down containsString:@"Kbps"])
      down = [down stringByAppendingString:@" Mbps"];
    [yaml appendString:[NSString stringWithFormat:@"    up: \"%@\"\n", up]];
    [yaml appendString:[NSString stringWithFormat:@"    down: \"%@\"\n", down]];

  // ──────────────────────────────────────────────────────────────────────────
  // Hysteria v2 — Fix: skip-cert-verify, obfs, up/down
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"Hysteria2"]) {
    [yaml appendString:@"    type: hysteria2\n"];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
    if (skipCert)
      [yaml appendString:@"    skip-cert-verify: true\n"];
    // 混淆（salamander）
    if ([dict[@"obfs"] length] > 0) {
      [yaml appendString:@"    obfs:\n"];
      [yaml appendString:[NSString stringWithFormat:@"      type: %@\n", dict[@"obfs"]]];
      if ([dict[@"obfs-password"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      password: \"%@\"\n",
                                                      dict[@"obfs-password"]]];
    }
    // 带宽声明（提升 Hysteria2 QUIC 拥塞窗口上限）
    if ([dict[@"up"] length] > 0 || [dict[@"down"] length] > 0) {
      NSString *up   = dict[@"up"]   ?: @"100";
      NSString *down = dict[@"down"] ?: @"100";
      [yaml appendString:@"    bandwidth:\n"];
      [yaml appendString:[NSString stringWithFormat:@"      up: %@\n", up]];
      [yaml appendString:[NSString stringWithFormat:@"      down: %@\n", down]];
    }

  // ──────────────────────────────────────────────────────────────────────────
  // WireGuard — Fix: peers 结构完整化
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"WireGuard"]) {
    [yaml appendString:@"    type: wireguard\n"];
    [yaml appendString:[NSString stringWithFormat:@"    private-key: %@\n",
                                                  dict[@"private-key"] ?: @""]];
    // 本地隧道地址
    NSString *ip = dict[@"ip"] ?: @"";
    if (ip.length > 0)
      [yaml appendString:[NSString stringWithFormat:@"    ip: %@\n", ip]];
    if ([dict[@"ipv6"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    ipv6: %@\n", dict[@"ipv6"]]];
    if ([dict[@"mtu"] integerValue] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    mtu: %ld\n",
                                                    (long)[dict[@"mtu"] integerValue]]];
    // peers 列表（必须项）
    [yaml appendString:@"    peers:\n"];
    NSArray *peers = dict[@"peers"];
    if (peers && [peers isKindOfClass:[NSArray class]] && peers.count > 0) {
      for (NSDictionary *peer in peers) {
        [yaml appendString:[NSString stringWithFormat:@"      - public-key: %@\n",
                                                      peer[@"public-key"] ?: dict[@"public-key"] ?: @""]];
        NSString *endpoint = peer[@"server"] ?
            [NSString stringWithFormat:@"%@:%@", peer[@"server"], peer[@"port"] ?: @"51820"] :
            [NSString stringWithFormat:@"%@:%ld", server, (long)port];
        [yaml appendString:[NSString stringWithFormat:@"        endpoint: %@\n", endpoint]];
        [yaml appendString:@"        allowed-ips:\n"];
        NSArray *allowedIPs = peer[@"allowed-ips"];
        if (!allowedIPs || ![allowedIPs isKindOfClass:[NSArray class]] || allowedIPs.count == 0) {
          NSString *ipv4all = @"0.0.0.0/0";
          NSString *ipv6all = @"::/0";
          allowedIPs = @[ipv4all, ipv6all];
        }
        for (NSString *cidr in allowedIPs)
          [yaml appendString:[NSString stringWithFormat:@"          - %@\n", cidr]];
      }
    } else {
      // 单节点兜底
      [yaml appendString:[NSString stringWithFormat:@"      - public-key: %@\n",
                                                    dict[@"public-key"] ?: @""]];
      [yaml appendString:[NSString stringWithFormat:@"        endpoint: %@:%ld\n",
                                                    server, (long)port]];
      [yaml appendString:@"        allowed-ips:\n          - 0.0.0.0/0\n          - ::/0\n"];
    }
    [yaml appendString:@"    udp: true\n"];

  // ──────────────────────────────────────────────────────────────────────────
  // TUIC v5 — Fix: alpn 必填, sni/skip-cert-verify, 字段名修正
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"Tuic"]) {
    [yaml appendString:@"    type: tuic\n"];
    [yaml appendString:[NSString stringWithFormat:@"    uuid: %@\n",
                                                  dict[@"uuid"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    // sni
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
    if (skipCert)
      [yaml appendString:@"    skip-cert-verify: true\n"];
    // alpn 必填（TUIC 走 QUIC，h3 是标准 ALPN）
    NSArray *alpn = dict[@"alpn"];
    if (alpn && [alpn isKindOfClass:[NSArray class]] && alpn.count > 0) {
      [yaml appendString:@"    alpn:\n"];
      for (NSString *a in alpn)
        [yaml appendString:[NSString stringWithFormat:@"      - %@\n", a]];
    } else {
      [yaml appendString:@"    alpn:\n      - h3\n"];
    }
    // congestion-controller: 兼容连字符和下划线两种键名
    NSString *cc = dict[@"congestion-controller"] ?: dict[@"congestion_controller"] ?: @"";
    if (cc.length > 0)
      [yaml appendString:[NSString stringWithFormat:@"    congestion-controller: %@\n", cc]];
    [yaml appendString:@"    udp-relay-mode: native\n"];

  // ──────────────────────────────────────────────────────────────────────────
  // SOCKS5 — ✅ 无 Bug
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"Socks5"]) {
    [yaml appendString:@"    type: socks5\n"];
    if ([dict[@"user"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    username: \"%@\"\n", dict[@"user"]]];
    if ([dict[@"password"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n", dict[@"password"]]];
    [yaml appendString:@"    udp: true\n"];

  // ──────────────────────────────────────────────────────────────────────────
  // Snell — Fix: obfs-opts 块
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"Snell"]) {
    [yaml appendString:@"    type: snell\n"];
    [yaml appendString:[NSString stringWithFormat:@"    psk: %@\n", dict[@"psk"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    version: %ld\n",
                                                  (long)([dict[@"version"] integerValue] ?: 4)]];
    if ([dict[@"obfs"] length] > 0) {
      [yaml appendString:@"    obfs-opts:\n"];
      [yaml appendString:[NSString stringWithFormat:@"      mode: %@\n", dict[@"obfs"]]];
      if ([dict[@"obfs-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      host: %@\n", dict[@"obfs-host"]]];
    }

  // ──────────────────────────────────────────────────────────────────────────
  // HTTP / HTTPS — Fix: username 加引号
  // ──────────────────────────────────────────────────────────────────────────
  } else if ([type isEqualToString:@"HTTP"] || [type isEqualToString:@"HTTPS"]) {
    [yaml appendString:@"    type: http\n"];
    BOOL tlsOn = [type isEqualToString:@"HTTPS"] || [dict[@"tls"] boolValue];
    if (tlsOn) {
      [yaml appendString:@"    tls: true\n"];
      if (skipCert) [yaml appendString:@"    skip-cert-verify: true\n"];
    }
    // username 和 password 都加引号（防止特殊字符破坏 YAML）
    if ([dict[@"user"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    username: \"%@\"\n", dict[@"user"]]];
    if ([dict[@"password"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n", dict[@"password"]]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
  }
}



- (NSString *)generateClashConfigFrom:(NSDictionary *)dict
                            withTunFD:(int)tunFD {
  NSMutableString *yaml = [NSMutableString string];

  id proxyPortVal = dict[@"proxy_port"];
  NSString *proxyPortStr =
      (proxyPortVal) ? [NSString stringWithFormat:@"%@", proxyPortVal] : @"";
  NSInteger pPort = [proxyPortStr integerValue];
  if (pPort <= 0 || pPort > 65535)
    pPort = 7890;

  [yaml appendString:[NSString
                         stringWithFormat:@"mixed-port: %ld\n", (long)pPort]];
  [yaml appendString:@"allow-lan: false\n"];
  [yaml appendString:@"mode: rule\n"];
  [yaml appendString:@"log-level: debug\n"];
  [yaml appendString:@"ipv6: true\n"];
  [yaml appendString:@"tcp-concurrent: true\n"];
  [yaml appendString:@"geodata-mode: true\n"];

  // TUN 性能核心：从 gvisor 切换为 mixed 模式
  // mixed 模式下 TCP 走 MacOS/iOS 原生 System 协议栈，UDP 走 gvisor，能得到倍数级的 TCP 吞吐提升。
  if (tunFD > 0) {
    [yaml appendString:@"tun:\n"];
    [yaml appendString:@"  enable: true\n"];
    [yaml appendString:@"  stack: mixed\n"];
    [yaml appendString:[NSString
                           stringWithFormat:@"  file-descriptor: %d\n", tunFD]];
    [yaml
        appendString:[NSString stringWithFormat:@"  mtu: %ld\n",
                                                (long)[self getMTUFrom:dict]]];
    [yaml appendString:@"  auto-route: false\n"];
    [yaml appendString:@"  auto-detect-interface: false\n"];
    [yaml appendString:@"  dns-hijack:\n"];
    [yaml appendString:@"    - any:53\n"];
    [yaml appendString:@"    - 198.18.0.2:53\n"];
    [self logToFile:[NSString
                        stringWithFormat:@"📦 TUN Config: FD=%d, Stack=gVisor",
                                         tunFD]];
  } else {
    [self logToFile:@"⚠️ No TUN FD - Running in Proxy-Only Mode"];
  }

  [yaml appendString:@"dns:\n"];
  [yaml appendString:@"  enable: true\n"];
  [yaml appendString:@"  listen: 0.0.0.0:1053\n"];
  [yaml appendString:@"  enhanced-mode: fake-ip\n"];
  [yaml appendString:@"  fake-ip-range: 198.18.0.0/15\n"];
  // 极简名单降低内存
  [yaml appendString:@"  fake-ip-filter: ['+', 'localhost.ptest.com']\n"];
  // BUILD #415: 强制使用 DoH/DoT 加密解析，抵抗 GFW 投毒
  // 日志表明：明文发往 1.1.1.1:53 的节点域名被硬性投毒为 127.0.0.1
  [yaml appendString:@"  nameserver:\n"];
  [yaml appendString:@"    - https://dns.google/dns-query\n"];
  [yaml appendString:@"    - tls://1.1.1.1\n"];
  [yaml appendString:@"    - https://dns.alidns.com/dns-query\n"];
  [yaml appendString:@"  ipv6: true\n"];

  [yaml appendString:@"proxies:\n"];

  NSString *name = @"ProxyNode";
  NSString *proxyThroughID = dict[@"proxy_through_id"];
  NSString *dialerProxyName = nil;

  if (proxyThroughID.length > 0) {
    NSDictionary *frontNode = nil;

    // 优先从主 App 嵌入的完整配置中读取（避免跨进程查找失败）
    NSDictionary *embeddedNode = dict[@"proxy_through_node"];
    if (embeddedNode && [embeddedNode isKindOfClass:[NSDictionary class]]) {
      frontNode = embeddedNode;
      [self logToFile:@"✅ 从嵌入配置中找到前置代理节点"];
    }

    // 降级：从 VPNNodeList 查找
    if (!frontNode) {
      NSUserDefaults *defaults =
          [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
      NSArray *allNodes = [defaults arrayForKey:@"VPNNodeList"];
      if (allNodes) {
        for (NSDictionary *n in allNodes) {
          if ([n[@"id"] isEqualToString:proxyThroughID] ||
              [n[@"name"] isEqualToString:proxyThroughID]) {
            frontNode = n;
            [self logToFile:@"✅ 从 VPNNodeList 查找到前置代理节点"];
            break;
          }
        }
      }
    }

    if (frontNode) {
      dialerProxyName = @"FrontProxyNode";
      [self appendProxyConfigForNode:frontNode
                            withName:dialerProxyName
                         dialerProxy:nil
                              toYAML:yaml];
      [self
          logToFile:[NSString
                        stringWithFormat:@"🔗 Added Front Proxy (Chained): %@",
                                         frontNode[@"server"]]];
    } else {
      // 未命中前置实体，主动抛弃避免诱发核心故障。
      dialerProxyName = nil;
      [self logToFile:[NSString
                          stringWithFormat:@"⚠️ Unresolved Front Proxy, "
                                           @"discarded to prevent crash: %@",
                                           proxyThroughID]];
    }
  }

  if (dialerProxyName.length > 0) {
    // 修复：Mihomo 要求 dialer-proxy 必须精确指向 Proxy Name，禁止指向 Proxy Group。
    [self appendProxyConfigForNode:dict
                          withName:name
                       dialerProxy:dialerProxyName
                            toYAML:yaml];
  } else {
    [self appendProxyConfigForNode:dict
                          withName:name
                       dialerProxy:nil
                            toYAML:yaml];
  }
  
  // 统一输出代理决策组
  [yaml appendString:@"proxy-groups:\n"];
  [yaml appendString:@"  - name: Proxy\n"];
  [yaml appendString:@"    type: select\n"];
  [yaml appendString:@"    proxies:\n"];
  [yaml appendString:[NSString stringWithFormat:@"      - %@\n", name]];
  [yaml appendString:@"      - DIRECT\n"];

  [yaml appendString:@"rules:\n"];
  // 管理域名强制直连白名单 —— 心跳/云控/更新请求不经过代理，避免 502
  [yaml appendString:@"  - DOMAIN-SUFFIX,ecmain.site,DIRECT\n"];
  [yaml appendString:@"  - IP-CIDR,127.0.0.0/8,DIRECT\n"];
  [yaml appendString:@"  - IP-CIDR,10.0.0.0/8,DIRECT\n"];
  [yaml appendString:@"  - IP-CIDR,172.16.0.0/12,DIRECT\n"];
  [yaml appendString:@"  - IP-CIDR,192.168.0.0/16,DIRECT\n"];

  NSArray *customRules = dict[@"rules"];
  if (customRules && [customRules isKindOfClass:[NSArray class]] &&
      customRules.count > 0) {
    for (NSString *rule in customRules) {
      if ([rule isKindOfClass:[NSString class]] && rule.length > 0) {
        [yaml appendString:[NSString stringWithFormat:@"  - %@\n", rule]];
      }
    }
  } else {
    // 任何情况下均通过策略组下发连接，保证可用性统一
    [yaml appendString:@"  - MATCH,Proxy\n"];
  }

  return yaml;
}

- (void)testUDPConnectivity {
  dispatch_async(
      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [NSThread sleepForTimeInterval:2.0];
        [self logToFile:@"🧪 Testing UDP Connectivity to 127.0.0.1:1053 "
                        @"(Mihomo DNS)..."];

        int sockfd = socket(AF_INET, SOCK_DGRAM, 0);
        if (sockfd < 0) {
          [self logToFile:@"❌ socket creation failed"];
          return;
        }

        struct sockaddr_in servaddr;
        memset(&servaddr, 0, sizeof(servaddr));
        servaddr.sin_family = AF_INET;
        servaddr.sin_port = htons(1053);
        inet_pton(AF_INET, "127.0.0.1", &servaddr.sin_addr);

        // Simple DNS query for generated.test
        char query[] = {0xAA, 0xBB, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
                        0x00, 0x00, 0x00, 0x00, 0x09, 'g',  'e',  'n',
                        'e',  'r',  'a',  't',  'e',  'd',  0x04, 't',
                        'e',  's',  't',  0x00, 0x00, 0x01, 0x00, 0x01};

        sendto(sockfd, query, sizeof(query), 0, (struct sockaddr *)&servaddr,
               sizeof(servaddr));
        [self logToFile:@"Sent UDP DNS query..."];

        struct timeval tv;
        tv.tv_sec = 2;
        tv.tv_usec = 0;
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv,
                   sizeof tv);

        char buffer[1024];
        struct sockaddr_in fromAddr;
        socklen_t len = sizeof(fromAddr);
        ssize_t n = recvfrom(sockfd, buffer, sizeof(buffer), 0,
                             (struct sockaddr *)&fromAddr, &len);

        if (n > 0) {
          [self logToFile:[NSString
                              stringWithFormat:@"✅ Received UDP Reply (%zd "
                                               @"bytes). Loopback UDP works!",
                                               n]];
        } else {
          [self
              logToFile:[NSString stringWithFormat:@"❌ UDP Receive failed: %s",
                                                   strerror(errno)]];
        }
        close(sockfd);
      });
}

// ============================================================
// BUILD #384: readPackets RESTORED for SOCKS5 Bridge Fallback
// ============================================================
// When native TUN FD is unavailable (FD=0), we use HevSocks5Tunnel +
// ECUDPBridge to bridge packets to Mihomo's SOCKS5 port.

- (void)readPackets {
  __weak typeof(self) weakSelf = self;
  [self.packetFlow readPacketsWithCompletionHandler:^(
                       NSArray<NSData *> *_Nonnull packets,
                       NSArray<NSNumber *> *_Nonnull protocols) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.isTunnelRunning)
      return;

    for (NSUInteger i = 0; i < packets.count; i++) {
      NSData *packet = packets[i];
      int family = [protocols[i] intValue];

      if (family == 2 && packet.length > 20) { // IPv4
        const uint8_t *bytes = packet.bytes;
        int proto = bytes[9];

        if (proto == 17) { // UDP -> ECUDPBridge
          [strongSelf.udpBridge inputPacket:packet];
        } else {
          // TCP (6) or ICMP (1) -> HevTunnel
          [strongSelf.hevTunnel inputPacket:packet];
        }
      } else if (family == 30 && packet.length > 40) { // IPv6
        const uint8_t *bytes = packet.bytes;
        uint8_t nextHeader = bytes[6];
        int offset = 40;

        // Parse extension headers
        while (offset < packet.length) {
          if (nextHeader == 17 || nextHeader == 6 || nextHeader == 58 ||
              nextHeader == 59)
            break;
          if (packet.length < offset + 2)
            break;

          uint8_t currentNextHeader = bytes[offset];
          int headerLen = 0;

          if (nextHeader == 0 || nextHeader == 43 || nextHeader == 60) {
            headerLen = (bytes[offset + 1] + 1) * 8;
          } else if (nextHeader == 44) {
            headerLen = 8;
          } else if (nextHeader == 51) {
            headerLen = (bytes[offset + 1] + 2) * 4;
          } else {
            break;
          }

          if (packet.length < offset + headerLen)
            break;
          nextHeader = currentNextHeader;
          offset += headerLen;
        }

        if (nextHeader == 17) { // UDP -> ECUDPBridge
          [strongSelf.udpBridge inputPacket:packet];
        } else {
          [strongSelf.hevTunnel inputPacket:packet];
        }
      } else {
        [strongSelf.hevTunnel inputPacket:packet];
      }
    }

    // Continue reading
    [strongSelf readPackets];
  }];
}

// ============================================================
// BUILD #386: readPacketsForTun2Proxy - Forward ALL packets to tun2proxy
// ============================================================
// tun2proxy handles both TCP and UDP, so we don't need to split traffic.

- (void)readPacketsForTun2Proxy {
  __weak typeof(self) weakSelf = self;
  [self.packetFlow readPacketsWithCompletionHandler:^(
                       NSArray<NSData *> *_Nonnull packets,
                       NSArray<NSNumber *> *_Nonnull protocols) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.isTunnelRunning)
      return;

    // Forward all packets to tun2proxy
    for (NSUInteger i = 0; i < packets.count; i++) {
      NSData *packet = packets[i];
      [strongSelf.tun2proxy inputPacket:packet];
    }

    // Continue reading
    [strongSelf readPacketsForTun2Proxy];
  }];
}

- (void)stopTunnelWithReason:(NEProviderStopReason)reason
           completionHandler:(void (^)(void))completionHandler {
  // 将 reason 枚举转换为可读字符串
  NSDictionary *reasonNames = @{
    @(NEProviderStopReasonNone)                   : @"None (正常停止)",
    @(NEProviderStopReasonUserInitiated)           : @"UserInitiated (用户手动关闭)",
    @(NEProviderStopReasonProviderFailed)          : @"ProviderFailed (Tunnel扩展崩溃)",
    @(NEProviderStopReasonNoNetworkAvailable)      : @"NoNetworkAvailable (网络不可用/断网)",
    @(NEProviderStopReasonUnrecoverableNetworkChange): @"UnrecoverableNetworkChange (网络切换，如WiFi→4G)",
    @(NEProviderStopReasonProviderDisabled)        : @"ProviderDisabled (VPN配置被禁用)",
    @(NEProviderStopReasonAuthenticationCanceled)  : @"AuthenticationCanceled (认证被取消)",
    @(NEProviderStopReasonConfigurationFailed)     : @"ConfigurationFailed (配置错误)",
    @(NEProviderStopReasonIdleTimeout)             : @"IdleTimeout (空闲超时)",
    @(NEProviderStopReasonConfigurationDisabled)   : @"ConfigurationDisabled (配置被禁用)",
    @(NEProviderStopReasonConfigurationRemoved)    : @"ConfigurationRemoved (配置被删除)",
    @(NEProviderStopReasonSuperceded)              : @"Superceded (被新VPN配置取代)",
    @(NEProviderStopReasonUserLogout)              : @"UserLogout (用户退出登录)",
    @(NEProviderStopReasonUserSwitch)              : @"UserSwitch (用户切换)",
    @(NEProviderStopReasonConnectionFailed)        : @"ConnectionFailed (连接失败)",
    @(NEProviderStopReasonSleep)                   : @"Sleep (设备进入睡眠)",
    @(NEProviderStopReasonAppUpdate)               : @"AppUpdate (应用更新)",
  };
  NSString *reasonStr = reasonNames[@(reason)]
      ?: [NSString stringWithFormat:@"Unknown (code=%ld)", (long)reason];

  [self logToFile:[NSString stringWithFormat:@"🛑 Stopping tunnel — Reason: %@", reasonStr]];

  // 将 Stop Reason 写入多个位置（按可靠性排序）
  // 先组装日志字符串
  NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
  fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS Z";
  NSString *ts = [fmt stringFromDate:[NSDate date]];
  NSMutableString *log = [NSMutableString string];
  [log appendString:@"====== VPN DISCONNECT LOG (Tunnel) ======\n"];
  [log appendFormat:@"Time            : %@\n", ts];
  [log appendFormat:@"Stop Reason     : %@\n", reasonStr];
  [log appendFormat:@"Reason Code     : %ld\n", (long)reason];
  [log appendFormat:@"Tunnel Running  : %@\n", self.isTunnelRunning ? @"YES" : @"NO"];
  [log appendString:@"=========================================\n"];

  // 方案 1： NSUserDefaults App Group（最可靠，不受 no-container 影响）
  NSUserDefaults *groupDefaults =
      [[NSUserDefaults alloc] initWithSuiteName:@"group.com.ecmain.shared"];
  if (groupDefaults) {
    [groupDefaults setObject:reasonStr forKey:@"TunnelLastStopReason"];
    [groupDefaults setObject:ts forKey:@"TunnelLastStopTime"];
    [groupDefaults setObject:log forKey:@"TunnelLastStopLog"];
    [groupDefaults synchronize];
    [self logToFile:@"✅ Tunnel 断开原因已写入 NSUserDefaults (App Group)"];
  }

  // 方案 2： 直接写入 /var/mobile/Media/（Tunnel 有 no-sandbox，可以尝试）
  NSError *writeErr2 = nil;
  BOOL ok2 = [log writeToFile:@"/var/mobile/Media/vpn_disconnect.log"
                   atomically:YES
                     encoding:NSUTF8StringEncoding
                        error:&writeErr2];
  if (ok2) {
    [self logToFile:@"✅ Tunnel 断开日志已写入 /var/mobile/Media/vpn_disconnect.log"];
  } else {
    [self logToFile:[NSString stringWithFormat:
                         @"⚠️ Tunnel 无法写 /var/mobile/Media/: %@",
                         writeErr2.localizedDescription]];
  }

  // 方案 3： App Group 共享目录（如果 containerURL 可用）
  NSURL *groupURL = [[NSFileManager defaultManager]
      containerURLForSecurityApplicationGroupIdentifier:@"group.com.ecmain.shared"];
  if (groupURL) {
    NSString *sharedLogPath = [[groupURL path]
        stringByAppendingPathComponent:@"tunnel_disconnect.log"];
    NSError *writeErr3 = nil;
    [log writeToFile:sharedLogPath atomically:YES
            encoding:NSUTF8StringEncoding error:&writeErr3];
    if (!writeErr3) {
      [self logToFile:[NSString stringWithFormat:
                           @"✅ Tunnel 断开日志已写入 App Group: %@", sharedLogPath]];
    }
  }
  // Stop proxy health check timer first
  [self stopProxyHealthCheck];

  // Stop tun2proxy if active
  if (self.tun2proxy) {
    [self.tun2proxy stop];
    self.tun2proxy = nil;
  }

  // Stop legacy bridges if active
  if (self.hevTunnel) {
    [self.hevTunnel stop];
    self.hevTunnel = nil;
  }
  if (self.udpBridge) {
    [self.udpBridge stop];
    self.udpBridge = nil;
  }

  self.isTunnelRunning = NO;
  self.tunFD = 0;

  [self logToFile:@"✅ Tunnel stopped."];
  completionHandler();
}

- (NSString *)resolveHost:(NSString *)host {
  const char *hostname = [host UTF8String];
  struct addrinfo hints, *res;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_INET; // Force IPv4 for exclusion
  hints.ai_socktype = SOCK_STREAM;

  if (getaddrinfo(hostname, NULL, &hints, &res) != 0) {
    return nil;
  }

  char ipStr[INET_ADDRSTRLEN];
  struct sockaddr_in *ipv4 = (struct sockaddr_in *)res->ai_addr;
  inet_ntop(AF_INET, &(ipv4->sin_addr), ipStr, INET_ADDRSTRLEN);

  freeaddrinfo(res);
  return [NSString stringWithUTF8String:ipStr];
}

@end
