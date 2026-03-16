
#import "ECUDPBridge.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>

#define MAX_BUFFER_SIZE 4096

// Simple IP Header Parsing
struct ip_header {
  uint8_t ver_ihl;
  uint8_t tos;
  uint16_t total_length;
  uint16_t id;
  uint16_t flags_fo;
  uint8_t ttl;
  uint8_t protocol;
  uint16_t checksum;
  uint32_t src_addr;
  uint32_t dst_addr;
};

struct udp_header {
  uint16_t src_port;
  uint16_t dst_port;
  uint16_t length;
  uint16_t checksum;
};

// IPv6 Header Definition (Localized to avoid import issues if missing)
struct ip6_header {
  union {
    struct ip6_hdrctl {
      uint32_t ip6_un1_flow; /* 20 bits of flow-ID */
      uint16_t ip6_un1_plen; /* payload length */
      uint8_t ip6_un1_nxt;   /* next header */
      uint8_t ip6_un1_hlim;  /* hop limit */
    } ip6_un1;
    uint8_t ip6_un2_vfc; /* 4 bits version, top 4 bits class */
  } ip6_ctlun;
  struct in6_addr ip6_src; /* source address */
  struct in6_addr ip6_dst; /* destination address */
};

#define ip6_vfc ip6_ctlun.ip6_un2_vfc
#define ip6_flow ip6_ctlun.ip6_un1.ip6_un1_flow
#define ip6_plen ip6_ctlun.ip6_un1.ip6_un1_plen
#define ip6_nxt ip6_ctlun.ip6_un1.ip6_un1_nxt
#define ip6_hlim ip6_ctlun.ip6_un1.ip6_un1_hlim
#define ip6_hops ip6_ctlun.ip6_un1.ip6_un1_hlim

@interface ECUDPBridge () {
  NSString *_proxyHost;
  uint16_t _proxyPort;
  dispatch_queue_t _queue;

  // SOCKS5 State
  int _tcpSocket;
  NSString *_relayIP;
  uint16_t _relayPort;
  BOOL _isReady;

  // NAT Table: "SrcIP:SrcPort" -> SocketFD
  NSMutableDictionary<NSString *, NSNumber *> *_flowMap;
  // Reverse Map: SocketFD -> "SrcIP:SrcPort"
  NSMutableDictionary<NSNumber *, NSString *> *_reverseMap;

  dispatch_source_t _tcpSource;
}
@end

@implementation ECUDPBridge

- (instancetype)initWithProxyHost:(NSString *)host port:(uint16_t)port {
  self = [super init];
  if (self) {
    _proxyHost = host;
    _proxyPort = port;
    _queue =
        dispatch_queue_create("com.ecmain.udpbridge", DISPATCH_QUEUE_SERIAL);
    _flowMap = [NSMutableDictionary dictionary];
    _reverseMap = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)start {
  dispatch_async(_queue, ^{
    [self connectToProxy];
  });
}

- (void)stop {
  dispatch_async(_queue, ^{
    if (self->_tcpSource) {
      dispatch_source_cancel(self->_tcpSource);
      self->_tcpSource = nil;
    }
    if (self->_tcpSocket > 0) {
      close(self->_tcpSocket);
      self->_tcpSocket = 0;
    }
    for (NSNumber *fdNum in self->_flowMap.allValues) {
      close(fdNum.intValue);
    }
    [self->_flowMap removeAllObjects];
    [self->_reverseMap removeAllObjects];
    self->_isReady = NO;
    NSLog(@"[ECUDPBridge] Stopped.");
  });
}

- (void)connectToProxy {
  // 1. Create TCP Socket
  _tcpSocket = socket(AF_INET, SOCK_STREAM, 0);
  if (_tcpSocket < 0) {
    NSLog(@"[ECUDPBridge] Failed to create TCP socket");
    return;
  }

  struct sockaddr_in serverAddr;
  serverAddr.sin_family = AF_INET;
  serverAddr.sin_port = htons(_proxyPort);
  inet_pton(AF_INET, [_proxyHost UTF8String], &serverAddr.sin_addr);

  // 2. Connect
  if (connect(_tcpSocket, (struct sockaddr *)&serverAddr, sizeof(serverAddr)) <
      0) {
    NSLog(@"[ECUDPBridge] Failed to connect to proxy");
    close(_tcpSocket);
    _tcpSocket = 0;
    // Retry logic could be added here
    return;
  }

  NSLog(@"[ECUDPBridge] Connected to Proxy TCP");

  // 3. Handshake (No Auth)
  uint8_t handshake[] = {0x05, 0x01,
                         0x00}; // VER=5, NMETHODS=1, METHOD=0 (No Auth)
  send(_tcpSocket, handshake, sizeof(handshake), 0);

  uint8_t response[2];
  recv(_tcpSocket, response, sizeof(response), 0);
  if (response[0] != 0x05 || response[1] != 0x00) {
    NSLog(@"[ECUDPBridge] Proxy Handshake Failed or requires Auth");
    close(_tcpSocket);
    return;
  }

  // 4. UDP Associate
  // CMD=3 (UDP Associate), ATYP=1 (IPv4), Addr=0.0.0.0, Port=0
  uint8_t request[] = {0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0};
  send(_tcpSocket, request, sizeof(request), 0);

  uint8_t udpResp[10]; // Minimum size
  // Note: Actual response might be larger if IPv6/Domain, but Mihomo usually
  // returns IPv4 for local
  ssize_t len = recv(_tcpSocket, udpResp, sizeof(udpResp), 0);
  if (len < 10 || udpResp[1] != 0x00) {
    NSLog(@"[ECUDPBridge] UDP Associate Failed");
    close(_tcpSocket);
    return;
  }

  // Parse Relay Address
  if (udpResp[3] == 0x01) { // IPv4
    struct in_addr relayAddr;
    memcpy(&relayAddr, &udpResp[4], 4);
    char addrStr[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &relayAddr, addrStr, INET_ADDRSTRLEN);
    _relayIP = [NSString stringWithUTF8String:addrStr];
    _relayPort = ntohs(*(uint16_t *)&udpResp[8]);
    NSLog(@"[ECUDPBridge] UDP Relay Ready at %@:%d", _relayIP, _relayPort);
    _isReady = YES;

    // Keep TCP Alive
    [self monitorTCPSocket];

  } else {
    NSLog(@"[ECUDPBridge] Unsupported Relay Address Type: %d", udpResp[3]);
    close(_tcpSocket);
  }
}

- (void)monitorTCPSocket {
  // Watch for disconnect
  _tcpSource =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, _tcpSocket, 0, _queue);
  dispatch_source_set_event_handler(_tcpSource, ^{
    char buf[1];
    if (recv(self->_tcpSocket, buf, 1, MSG_PEEK) == 0) {
      NSLog(@"[ECUDPBridge] TCP Connection Closed by Proxy");
      [self stop];
      // Reconnect?
      [self performSelector:@selector(start) withObject:nil afterDelay:2.0];
    }
  });
  dispatch_resume(_tcpSource);
}

- (void)inputPacket:(NSData *)packet {
  // BUILD #385: DIAGNOSTIC LOG - Confirm UDP arrival
  static int udpCount = 0;
  udpCount++;
  if (udpCount <= 20 || udpCount % 100 == 0) {
    NSLog(@"[ECUDPBridge] 📥 InputPacket #%d len:%lu isReady:%d", udpCount,
          (unsigned long)packet.length, _isReady);
  }

  if (!_isReady) {
    NSLog(@"[ECUDPBridge] ⚠️ Dropped - Not Ready");
    return;
  }
  if (packet.length < 20) {
    NSLog(@"[ECUDPBridge] ⚠️ Dropped - Too short: %lu",
          (unsigned long)packet.length);
    return;
  }

  const uint8_t *bytes = packet.bytes;
  uint8_t version = (bytes[0] >> 4);

  uint32_t srcIPv4 = 0;
  struct in6_addr srcIPv6;
  uint16_t srcPort = 0;
  uint16_t dstPort = 0;
  NSData *dstAddrData = nil; // For SOCKS5
  const uint8_t *payload = NULL;
  NSInteger payloadLen = 0;

  BOOL isV6 = (version == 6);

  if (isV6) {
    if (packet.length < 40)
      return;
    struct ip6_header *ip6h = (struct ip6_header *)bytes;

    // Extension Header Walking (Robust)
    uint8_t nextHeader = ip6h->ip6_nxt;
    int offset = 40;

    while (offset < packet.length) {
      if (nextHeader == 17)
        break; // Found UDP
      if (nextHeader == 58)
        break; // ICMPv6 - Bridge doesn't handle, bail
      if (nextHeader == 59)
        break; // No Next Header

      if (packet.length < offset + 2)
        return;

      uint8_t currentNextHeader = bytes[offset];
      int headerLen = 0;

      if (nextHeader == 0 || nextHeader == 43 || nextHeader == 60) {
        // Standard: (Len + 1) * 8
        uint8_t extLen = bytes[offset + 1];
        headerLen = (extLen + 1) * 8;
      } else if (nextHeader == 44) {
        // Fragment: 8 bytes
        // If Offset != 0, we can't process as we need UDP info
        uint16_t fragOff = ntohs(*(uint16_t *)(bytes + offset + 2));
        if ((fragOff & 0xFFF8) != 0) {
          return; // Not first fragment, cannot map to flow
        }
        headerLen = 8;
      } else if (nextHeader == 51) {
        // AH: (Len + 2) * 4
        uint8_t extLen = bytes[offset + 1];
        headerLen = (extLen + 2) * 4;
      } else {
        break; // Unknown
      }

      if (packet.length < offset + headerLen)
        return;

      nextHeader = currentNextHeader;
      offset += headerLen;
    }

    if (nextHeader != 17)
      return; // UDP Not Found

    if (packet.length < offset + 8)
      return;
    struct udp_header *udph = (struct udp_header *)(bytes + offset);

    srcIPv6 = ip6h->ip6_src;
    srcPort = udph->src_port;
    dstPort = udph->dst_port;
    dstAddrData = [NSData dataWithBytes:&ip6h->ip6_dst length:16];

    uint16_t udpLen = ntohs(udph->length);
    // UDP length includes UDP header (8 bytes).
    // packet.length must be at least offset + udpLen
    if (udpLen < 8 || packet.length < offset + udpLen)
      return;

    payload = bytes + offset + 8;
    payloadLen = udpLen - 8;

  } else {
    struct ip_header *iph = (struct ip_header *)bytes;
    if (version != 4)
      return;
    if (iph->protocol != 17)
      return;

    uint8_t ihl = (iph->ver_ihl & 0x0F) * 4;
    if (packet.length < ihl + 8)
      return;
    struct udp_header *udph = (struct udp_header *)(bytes + ihl);

    srcIPv4 = iph->src_addr;
    srcPort = udph->src_port;
    dstPort = udph->dst_port;
    dstAddrData = [NSData dataWithBytes:&iph->dst_addr length:4];

    uint16_t udpLen = ntohs(udph->length);
    if (udpLen < 8 || packet.length < ihl + udpLen)
      return;
    payload = bytes + ihl + 8;
    payloadLen = udpLen - 8;
  }

  // Diagnostic Log
  static int packetCount = 0;
  packetCount++;
  if (packetCount <= 100 || packetCount % 500 == 0) {
    if (isV6) {
      char srcStr[INET6_ADDRSTRLEN];
      inet_ntop(AF_INET6, &srcIPv6, srcStr, INET6_ADDRSTRLEN);
      NSLog(@"[ECUDPBridge] UDPv6 #%d Len:%lu Src:%s:%d", packetCount,
            (unsigned long)packet.length, srcStr, ntohs(srcPort));
    } else {
      NSLog(@"[ECUDPBridge] UDPv4 #%d Len:%lu", packetCount,
            (unsigned long)packet.length);
    }
  }

  // Flow Key Construction
  NSString *flowKey;
  if (isV6) {
    char srcStr[INET6_ADDRSTRLEN];
    inet_ntop(AF_INET6, &srcIPv6, srcStr, INET6_ADDRSTRLEN);
    flowKey = [NSString stringWithFormat:@"[%s]:%u", srcStr, srcPort];
  } else {
    flowKey = [NSString stringWithFormat:@"%u:%u", srcIPv4, srcPort];
  }

  __block int socketFD = 0;
  dispatch_sync(_queue, ^{
    NSNumber *fdNum = self->_flowMap[flowKey];
    if (fdNum) {
      socketFD = fdNum.intValue;
    } else {
      socketFD = [self createSocketForFlow:flowKey];
    }
  });

  if (socketFD > 0) {
    // Send to Relay
    struct sockaddr_in relayAddr;
    relayAddr.sin_family = AF_INET;
    relayAddr.sin_port = htons(_relayPort);
    inet_pton(AF_INET, [_relayIP UTF8String], &relayAddr.sin_addr);

    // SOCKS5 UDP Header Construction
    NSMutableData *socksPacket = [NSMutableData data];

    if (isV6) {
      uint8_t header[] = {
          0x00, 0x00, 0x01,
          0x04}; // RSV, FRAG, ATYP=IPv6(4) -> Wait, ATYP is byte 3
      // Correct SOCKS5 UDP: RSV(2), FRAG(1), ATYP(1)
      uint8_t h[] = {0x00, 0x00, 0x00, 0x04};
      [socksPacket appendBytes:h length:4];
    } else {
      uint8_t h[] = {0x00, 0x00, 0x00, 0x01}; // ATYP=IPv4(1)
      [socksPacket appendBytes:h length:4];
    }

    [socksPacket appendData:dstAddrData];
    [socksPacket appendBytes:&dstPort length:2];
    [socksPacket appendBytes:payload length:payloadLen];

    // BUILD #385: Log sendto result
    ssize_t sent = sendto(socketFD, socksPacket.bytes, socksPacket.length, 0,
                          (struct sockaddr *)&relayAddr, sizeof(relayAddr));
    static int sendCount = 0;
    sendCount++;
    if (sendCount <= 20 || sendCount % 100 == 0) {
      NSLog(@"[ECUDPBridge] 📤 Sent #%d len:%lu to relay result:%zd", sendCount,
            (unsigned long)socksPacket.length, sent);
    }
  }
}

- (int)createSocketForFlow:(NSString *)key {
  int s = socket(AF_INET, SOCK_DGRAM, 0);
  if (s < 0)
    return 0;

  _flowMap[key] = @(s);
  _reverseMap[@(s)] = key;

  // Listen for response
  dispatch_source_t source =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, s, 0, _queue);
  dispatch_source_set_event_handler(source, ^{
    uint8_t buf[4096];
    struct sockaddr_in fromAddr;
    socklen_t fromLen = sizeof(fromAddr);
    ssize_t len = recvfrom(s, buf, sizeof(buf), 0, (struct sockaddr *)&fromAddr,
                           &fromLen);

    if (len > 0) {
      [self handleResponse:buf length:len from:key];
    }
  });
  dispatch_resume(source);

  return s;
}

- (void)handleResponse:(uint8_t *)buf
                length:(ssize_t)len
                  from:(NSString *)flowKey {
  if (len < 10)
    return;
  if (buf[2] != 0x00)
    return; // No Frag

  uint8_t atyp = buf[3];
  int headerLen = 0;
  NSData *remoteSrcAddr = nil;
  // Note: buf[4] start addr

  if (atyp == 0x01) { // IPv4
    headerLen = 10;
    remoteSrcAddr = [NSData dataWithBytes:&buf[4] length:4];
  } else if (atyp == 0x04) { // IPv6
    headerLen = 22;          // 4 header + 16 addr + 2 port
    remoteSrcAddr = [NSData dataWithBytes:&buf[4] length:16];
  } else {
    return; // Ignore Domain for now
  }

  if (len <= headerLen)
    return;
  uint16_t remoteSrcPort = *(uint16_t *)&buf[headerLen - 2];
  NSData *payload = [NSData dataWithBytes:buf + headerLen
                                   length:len - headerLen];

  // Parse Key to find Local Dst
  BOOL isV6Flow = [flowKey hasPrefix:@"["];

  if (isV6Flow) {
    if (atyp != 0x04)
      return; // Mismatch? We expected v6 return for v6 flow ideally?
    // Actually, server response type matches the server address type.
    // If client sent to IPv6 dest, server replies from IPv6 src.

    // Parse Key: "[IPv6]:Port"
    NSRange endBracket = [flowKey rangeOfString:@"]"];
    if (endBracket.location == NSNotFound)
      return;
    NSString *ipStr =
        [flowKey substringWithRange:NSMakeRange(1, endBracket.location - 1)];
    NSString *portStr = [flowKey substringFromIndex:endBracket.location + 2];

    struct in6_addr localIP;
    inet_pton(AF_INET6, [ipStr UTF8String], &localIP);
    uint16_t localPort = (uint16_t)[portStr intValue];

    // Construct IPv6 Packet
    NSMutableData *ipPacket = [NSMutableData dataWithLength:40 + 8];
    uint8_t *pkt = ipPacket.mutableBytes;
    struct ip6_header *ip6h = (struct ip6_header *)pkt;
    struct udp_header *udph = (struct udp_header *)(pkt + 40);

    ip6h->ip6_vfc = 0x60; // Version 6
    ip6h->ip6_plen = htons(8 + payload.length);
    ip6h->ip6_nxt = 17; // UDP
    ip6h->ip6_hlim = 64;

    memcpy(&ip6h->ip6_src, remoteSrcAddr.bytes, 16);
    memcpy(&ip6h->ip6_dst, &localIP, 16);

    udph->src_port = remoteSrcPort;    // already network order from buf
    udph->dst_port = htons(localPort); // host order -> network
    udph->length = htons(8 + payload.length);
    udph->checksum = 0;

    [ipPacket appendData:payload];

    // Calculate IPv6 UDP Checksum (Mandatory)
    udph->checksum = [self ip6Checksum:ipPacket.bytes length:ipPacket.length];

    if (self.writeHandler)
      self.writeHandler(ipPacket);

  } else {
    // IPv4 Flow
    if (atyp != 0x01) {
      // If we requested IPv4 but got IPv6, we can't route back to an IPv4-only
      // app socket easily
      return;
    }
    NSArray *parts = [flowKey componentsSeparatedByString:@":"];
    if (parts.count != 2)
      return;
    uint32_t localIP = (uint32_t)[parts[0] longLongValue];
    uint16_t localPort = (uint16_t)[parts[1] intValue];

    NSMutableData *ipPacket = [NSMutableData dataWithLength:20 + 8];
    uint8_t *pkt = ipPacket.mutableBytes;
    struct ip_header *iph = (struct ip_header *)pkt;
    struct udp_header *udph = (struct udp_header *)(pkt + 20);

    iph->ver_ihl = 0x45;
    iph->total_length = htons(20 + 8 + payload.length);
    iph->ttl = 64;
    iph->protocol = 17;
    memcpy(&iph->src_addr, remoteSrcAddr.bytes, 4);
    iph->dst_addr = localIP;

    udph->src_port = remoteSrcPort;
    udph->dst_port =
        localPort; // Wait, parts[1] was net byte order in old code?
    // Checking old code: "srcPort = udph->src_port;" (Net order).
    // "flowKey = [NSString stringWithFormat:@"%u:%u", srcIP, srcPort];" (Raw
    // integer value) "localPort = (uint16_t)[parts[1] intValue];" -> This is
    // NET ORDER value stored as int. So no htons needed if we assign direct.
    udph->dst_port = localPort;
    udph->length = htons(8 + payload.length);

    [ipPacket appendData:payload];

    iph->checksum = [self ipChecksum:ipPacket.bytes length:20];
    if (self.writeHandler)
      self.writeHandler(ipPacket);
  }
}

- (uint16_t)ip6Checksum:(const void *)data length:(size_t)totalLen {
  // Pseudo Header for IPv6 UDP Checksum
  struct pseudo_header_v6 {
    struct in6_addr src;
    struct in6_addr dst;
    uint32_t len;
    uint32_t next_header; // 3 bytes zero + 1 byte next
  };

  if (totalLen < 40)
    return 0;
  const struct ip6_header *ip6h = data;
  const struct udp_header *udph =
      (const struct udp_header *)((uint8_t *)data + 40);

  struct pseudo_header_v6 ph;
  ph.src = ip6h->ip6_src;
  ph.dst = ip6h->ip6_dst;
  ph.len = htonl(totalLen - 40); // TCP/UDP Length
  ph.next_header = htonl(17);

  uint32_t sum = 0;
  const uint16_t *ptr = (const uint16_t *)&ph;
  for (int i = 0; i < sizeof(ph) / 2; i++) {
    sum += ptr[i];
  }

  // Payload (UDP Header + Data)
  ptr = (const uint16_t *)udph;
  size_t len = totalLen - 40;
  while (len > 1) {
    sum += *ptr++;
    len -= 2;
  }
  if (len > 0) {
    sum += *(const uint8_t *)ptr;
  }

  while (sum >> 16)
    sum = (sum & 0xFFFF) + (sum >> 16);
  return ~sum;
}

- (uint16_t)ipChecksum:(const void *)data length:(size_t)len {
  uint32_t sum = 0;
  const uint16_t *buf = data;
  while (len > 1) {
    sum += *buf++;
    len -= 2;
  }
  if (len > 0) {
    sum += *(const uint8_t *)buf;
  }
  while (sum >> 16) {
    sum = (sum & 0xFFFF) + (sum >> 16);
  }
  return ~sum;
}

@end
