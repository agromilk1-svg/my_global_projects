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
                           completionHandler(nil);
                         }
                       });
                     });
               }
             }];
}

- (void)appendProxyConfigForNode:(NSDictionary *)dict
                        withName:(NSString *)name
                     dialerProxy:(NSString *)dialerProxy
                          toYAML:(NSMutableString *)yaml {
  NSString *type = dict[@"type"] ?: @"Shadowsocks";
  NSString *server = dict[@"server"] ?: @"";
  NSString *port = dict[@"port"] ?: @"";

  [yaml appendString:[NSString stringWithFormat:@"  - name: %@\n", name]];
  [yaml appendString:[NSString stringWithFormat:@"    server: %@\n", server]];
  [yaml appendString:[NSString stringWithFormat:@"    port: %@\n", port]];

  // 全局注入 TCP Fast Open (TFO) 降低握手延迟 (类似 Shadowrocket 提速秘诀)
  BOOL tfoEnabled = (dict[@"tfo"] != nil) ? [dict[@"tfo"] boolValue] : YES;
  if (tfoEnabled) {
    [yaml appendString:@"    tfo: true\n"];
  }

  if (dialerProxy.length > 0) {
    [yaml appendString:[NSString stringWithFormat:@"    dialer-proxy: %@\n",
                                                  dialerProxy]];
  }

  if ([type isEqualToString:@"Shadowsocks"]) {
    [yaml appendString:@"    type: ss\n"];
    [yaml appendString:[NSString
                           stringWithFormat:@"    cipher: %@\n",
                                            dict[@"cipher"] ?: @"aes-256-gcm"]];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    if ([dict[@"plugin"] length] > 0) {
      [yaml appendString:[NSString stringWithFormat:@"    plugin: %@\n",
                                                    dict[@"plugin"]]];
      // 解析 plugin-opts 字符串，生成标准 YAML 多行格式
      NSString *optsStr = dict[@"plugin-opts"] ?: @"";
      // 清理花括号（兼容旧格式）
      optsStr = [optsStr stringByReplacingOccurrencesOfString:@"{" withString:@""];
      optsStr = [optsStr stringByReplacingOccurrencesOfString:@"}" withString:@""];
      optsStr = [optsStr stringByTrimmingCharactersInSet:
          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
      
      if (optsStr.length > 0) {
        [yaml appendString:@"    plugin-opts:\n"];
        // 按逗号分割 key: value 对
        NSArray *parts = [optsStr componentsSeparatedByString:@","];
        for (NSString *part in parts) {
          NSString *trimmed = [part stringByTrimmingCharactersInSet:
              [NSCharacterSet whitespaceAndNewlineCharacterSet]];
          if (trimmed.length > 0) {
            [yaml appendString:[NSString stringWithFormat:@"      %@\n", trimmed]];
          }
        }
      }
    } else if ([dict[@"obfs"] length] > 0) {
      // 回退: 从 obfs/obfs-param 字段自动生成 plugin 配置
      [yaml appendString:@"    plugin: obfs\n"];
      [yaml appendString:@"    plugin-opts:\n"];
      [yaml appendString:[NSString stringWithFormat:@"      mode: %@\n",
                                                    dict[@"obfs"]]];
      
      // Mihomo 的 simple-obfs 插件严格要求必须有 host 参数
      NSString *obfsHost = dict[@"obfs-param"] ?: @"";
      if (obfsHost.length == 0) {
        obfsHost = @"bing.com"; // 默认兜底混淆域名
      }
      [yaml appendString:[NSString stringWithFormat:@"      host: %@\n", obfsHost]];
    } else if ([dict[@"ws-path"] length] > 0) {
      // 智能识别: 存在 ws-path 意味着必须走 v2ray-plugin (WebSocket 传输)
      [yaml appendString:@"    plugin: v2ray-plugin\n"];
      [yaml appendString:@"    plugin-opts:\n"];
      [yaml appendString:@"      mode: websocket\n"];
      [yaml appendString:[NSString stringWithFormat:@"      path: %@\n", dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0) {
        [yaml appendString:[NSString stringWithFormat:@"      host: %@\n", dict[@"ws-host"]]];
      }
      if ([dict[@"tls"] boolValue]) {
        [yaml appendString:@"      tls: true\n"];
      }
    }
    // Respect 'udp' setting, default to true
    BOOL udpEnabled = (dict[@"udp"] != nil) ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString
                           stringWithFormat:@"    udp: %@\n",
                                            udpEnabled ? @"true" : @"false"]];
  } else if ([type isEqualToString:@"ShadowsocksR"]) {
    [yaml appendString:@"    type: ssr\n"];
    [yaml appendString:[NSString
                           stringWithFormat:@"    cipher: %@\n",
                                            dict[@"cipher"] ?: @"aes-256-cfb"]];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    [yaml appendString:[NSString
                           stringWithFormat:@"    protocol: %@\n",
                                            dict[@"protocol"] ?: @"origin"]];
    if ([dict[@"protocol-param"] length] > 0) {
      [yaml appendString:[NSString stringWithFormat:@"    protocol-param: %@\n",
                                                    dict[@"protocol-param"]]];
    }
    [yaml appendString:[NSString stringWithFormat:@"    obfs: %@\n",
                                                  dict[@"obfs"] ?: @"plain"]];
    if ([dict[@"obfs-param"] length] > 0) {
      [yaml appendString:[NSString stringWithFormat:@"    obfs-param: %@\n",
                                                    dict[@"obfs-param"]]];
    }
    // Respect 'udp' setting, default to true
    BOOL udpEnabled = (dict[@"udp"] != nil) ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString
                           stringWithFormat:@"    udp: %@\n",
                                            udpEnabled ? @"true" : @"false"]];
  } else if ([type isEqualToString:@"VMess"]) {
    [yaml appendString:@"    type: vmess\n"];
    [yaml appendString:[NSString stringWithFormat:@"    uuid: %@\n",
                                                  dict[@"uuid"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    alterId: %@\n",
                                                  dict[@"alterId"] ?: @"0"]];
    [yaml appendString:[NSString stringWithFormat:@"    cipher: %@\n",
                                                  dict[@"cipher"] ?: @"auto"]];
    if ([dict[@"tls"] boolValue])
      [yaml appendString:@"    tls: true\n"];
    // Respect 'udp' setting, default to true
    BOOL udpEnabled = (dict[@"udp"] != nil) ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString
                           stringWithFormat:@"    udp: %@\n",
                                            udpEnabled ? @"true" : @"false"]];
    if ([dict[@"network"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    network: %@\n",
                                                    dict[@"network"]]];
    if ([dict[@"ws-path"] length] > 0 || [dict[@"ws-host"] length] > 0) {
      [yaml appendString:@"    ws-opts:\n"];
      if ([dict[@"ws-path"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      path: %@\n",
                                                      dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:
                                         @"      headers:\n        Host: %@\n",
                                         dict[@"ws-host"]]];
    }
  } else if ([type isEqualToString:@"VLESS"]) {
    [yaml appendString:@"    type: vless\n"];
    [yaml appendString:[NSString stringWithFormat:@"    uuid: %@\n",
                                                  dict[@"uuid"] ?: @""]];
    if ([dict[@"flow"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    flow: %@\n",
                                                    dict[@"flow"]]];
    // Respect 'udp' setting, default to true
    BOOL udpEnabled = (dict[@"udp"] != nil) ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString
                           stringWithFormat:@"    udp: %@\n",
                                            udpEnabled ? @"true" : @"false"]];
    if ([dict[@"tls"] boolValue])
      [yaml appendString:@"    tls: true\n"];
    if ([dict[@"network"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    network: %@\n",
                                                    dict[@"network"]]];
    // Reuse WS logic if network is ws, simplified for now
    if ([dict[@"network"] isEqualToString:@"ws"] &&
        ([dict[@"ws-path"] length] > 0 || [dict[@"ws-host"] length] > 0)) {
      [yaml appendString:@"    ws-opts:\n"];
      if ([dict[@"ws-path"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:@"      path: %@\n",
                                                      dict[@"ws-path"]]];
      if ([dict[@"ws-host"] length] > 0)
        [yaml appendString:[NSString stringWithFormat:
                                         @"      headers:\n        Host: %@\n",
                                         dict[@"ws-host"]]];
    }

    // New VLESS Reality & Fingerprint Support
    if ([dict[@"servername"] length] > 0) {
      [yaml appendString:[NSString stringWithFormat:@"    servername: %@\n",
                                                    dict[@"servername"]]];
    }

    if ([dict[@"client-fingerprint"] length] > 0) {
      [yaml appendString:[NSString
                             stringWithFormat:@"    client-fingerprint: %@\n",
                                              dict[@"client-fingerprint"]]];
    }

    NSDictionary *realityOpts = dict[@"reality-opts"];
    if (realityOpts && [realityOpts isKindOfClass:[NSDictionary class]]) {
      [yaml appendString:@"    reality-opts:\n"];
      if ([realityOpts[@"public-key"] length] > 0) {
        [yaml appendString:[NSString
                               stringWithFormat:@"      public-key: %@\n",
                                                realityOpts[@"public-key"]]];
      }
      if ([realityOpts[@"short-id"] length] > 0) {
        [yaml
            appendString:[NSString stringWithFormat:@"      short-id: %@\n",
                                                    realityOpts[@"short-id"]]];
      }
    }
  } else if ([type isEqualToString:@"Trojan"]) {
    [yaml appendString:@"    type: trojan\n"];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString
                             stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
    if ([dict[@"network"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    network: %@\n",
                                                    dict[@"network"]]];
    // BUILD #415: Add missing UDP support for Trojan (Crucial for TikTok/QUIC)
    BOOL udpEnabled = (dict[@"udp"] != nil) ? [dict[@"udp"] boolValue] : YES;
    [yaml appendString:[NSString
                           stringWithFormat:@"    udp: %@\n",
                                            udpEnabled ? @"true" : @"false"]];

  } else if ([type isEqualToString:@"Hysteria"]) {
    [yaml appendString:@"    type: hysteria\n"];
    [yaml appendString:[NSString stringWithFormat:@"    auth_str: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString
                             stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
    [yaml appendString:[NSString stringWithFormat:@"    up: %@\n",
                                                  dict[@"up"] ?: @"100"]];
    [yaml appendString:[NSString stringWithFormat:@"    down: %@\n",
                                                  dict[@"down"] ?: @"100"]];
  } else if ([type isEqualToString:@"Hysteria2"]) {
    [yaml appendString:@"    type: hysteria2\n"];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString
                             stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
  } else if ([type isEqualToString:@"WireGuard"]) {
    [yaml appendString:@"    type: wireguard\n"];
    [yaml appendString:[NSString stringWithFormat:@"    ip: %@\n",
                                                  dict[@"ip"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    private-key: %@\n",
                                                  dict[@"private-key"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    public-key: %@\n",
                                                  dict[@"public-key"] ?: @""]];
    if ([dict[@"mtu"] integerValue] > 0)
      [yaml appendString:[NSString
                             stringWithFormat:@"    mtu: %@\n", dict[@"mtu"]]];
    [yaml appendString:@"    udp: true\n"];
  } else if ([type isEqualToString:@"Tuic"]) {
    [yaml appendString:@"    type: tuic\n"];
    [yaml appendString:[NSString stringWithFormat:@"    uuid: %@\n",
                                                  dict[@"uuid"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                  dict[@"password"] ?: @""]];
    if ([dict[@"congestion_controller"] length] > 0)
      [yaml
          appendString:[NSString
                           stringWithFormat:@"    congestion-controller: %@\n",
                                            dict[@"congestion_controller"]]];
  } else if ([type isEqualToString:@"Socks5"]) {
    [yaml appendString:@"    type: socks5\n"];
    if ([dict[@"user"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    username: \"%@\"\n",
                                                    dict[@"user"]]];
    if ([dict[@"password"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                    dict[@"password"]]];
    [yaml appendString:@"    udp: true\n"];
  } else if ([type isEqualToString:@"Snell"]) {
    [yaml appendString:@"    type: snell\n"];
    [yaml appendString:[NSString stringWithFormat:@"    psk: %@\n",
                                                  dict[@"psk"] ?: @""]];
    [yaml appendString:[NSString stringWithFormat:@"    version: %@\n",
                                                  dict[@"version"] ?: @"2"]];
  } else if ([type isEqualToString:@"HTTP"] ||
             [type isEqualToString:@"HTTPS"]) {
    [yaml appendString:@"    type: http\n"];

    // TLS Logic
    BOOL isHttpsType = [type isEqualToString:@"HTTPS"];
    BOOL tlsEnabled = isHttpsType;
    if (dict[@"tls"]) {
      tlsEnabled = [dict[@"tls"] boolValue];
    }
    if (tlsEnabled) {
      [yaml appendString:@"    tls: true\n"];
    }

    if ([dict[@"user"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    username: %@\n",
                                                    dict[@"user"]]];
    if ([dict[@"password"] length] > 0)
      [yaml appendString:[NSString stringWithFormat:@"    password: \"%@\"\n",
                                                    dict[@"password"]]];
    if ([dict[@"sni"] length] > 0)
      [yaml appendString:[NSString
                             stringWithFormat:@"    sni: %@\n", dict[@"sni"]]];
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
  [self logToFile:@"Stopping tunnel..."];

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
