#import "utun_nat.h"
#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/ioctl.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <net/if.h>
#import <unistd.h>
#import <pthread.h>
#import <ifaddrs.h>

#ifndef RTM_VERSION
#define RTM_VERSION 5
#endif
#ifndef RTM_ADD
#define RTM_ADD 0x1
#endif
#ifndef RTF_UP
#define RTF_UP 0x1
#endif
#ifndef RTF_GATEWAY
#define RTF_GATEWAY 0x2
#endif
#ifndef RTF_HOST
#define RTF_HOST 0x4
#endif
#ifndef RTF_STATIC
#define RTF_STATIC 0x800
#endif
#ifndef RTA_DST
#define RTA_DST 0x1
#endif
#ifndef RTA_GATEWAY
#define RTA_GATEWAY 0x2
#endif

struct rt_metrics_compat {
    uint32_t rmx_locks;
    uint32_t rmx_mtu;
    uint32_t rmx_hopcount;
    int32_t  rmx_expire;
    uint32_t rmx_recvpipe;
    uint32_t rmx_sendpipe;
    uint32_t rmx_ssthresh;
    uint32_t rmx_rtt;
    uint32_t rmx_rttvar;
    uint32_t rmx_pksent;
    uint32_t rmx_state;
    uint32_t rmx_filler[3];
};

struct rt_msghdr_compat {
    uint16_t rtm_msglen;
    uint8_t  rtm_version;
    uint8_t  rtm_type;
    uint16_t rtm_index;
    int      rtm_flags;
    int      rtm_addrs;
    pid_t    rtm_pid;
    int      rtm_seq;
    int      rtm_errno;
    int      rtm_use;
    uint32_t rtm_inits;
    struct   rt_metrics_compat rtm_rmx;
};

#ifndef AF_LINK
#define AF_LINK 18
#endif

struct sockaddr_dl_compat {
    uint8_t  sdl_len;
    uint8_t  sdl_family;
    uint16_t sdl_index;
    uint8_t  sdl_type;
    uint8_t  sdl_nlen;
    uint8_t  sdl_alen;
    uint8_t  sdl_slen;
    char     sdl_data[12];
};

#ifndef UTUN_OPT_IFNAME
#define UTUN_OPT_IFNAME 2
#endif

// 补充被 iOS SDK 隐藏的 macOS/BSD 系统内核控制结构体
struct ctl_info {
    uint32_t ctl_id;
    char ctl_name[96];
};
#define CTLIOCGINFO 0xc0644e03UL // _IOWR('N', 3, struct ctl_info)

struct sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};
#ifndef AF_SYSTEM
#define AF_SYSTEM 32
#endif
#ifndef AF_SYS_CONTROL
#define AF_SYS_CONTROL 2
#endif
#ifndef SYSPROTO_CONTROL
#define SYSPROTO_CONTROL 2
#endif

char g_utun_ifname[20] = {0};
static int g_utun_fd = -1;
static BOOL g_utun_running = NO;
static pthread_t g_utun_thread;

// 校验和计算
static uint16_t calculate_checksum(uint16_t *buf, int len) {
    uint32_t sum = 0;
    while (len > 1) {
        sum += *buf++;
        len -= 2;
    }
    if (len == 1) {
        sum += *(uint8_t*)buf;
    }
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return ~sum;
}

// TCP 伪头部
struct pseudo_header {
    uint32_t src_addr;
    uint32_t dst_addr;
    uint8_t zero;
    uint8_t proto;
    uint16_t tcp_len;
} __attribute__((packed));

static uint16_t tcp_checksum(uint8_t *ip_hdr, uint8_t *tcp_hdr, int tcp_len) {
    struct pseudo_header ph;
    ph.src_addr = *(uint32_t *)(ip_hdr + 12);
    ph.dst_addr = *(uint32_t *)(ip_hdr + 16);
    ph.zero = 0;
    ph.proto = IPPROTO_TCP;
    ph.tcp_len = htons(tcp_len);
    
    uint32_t sum = 0;
    uint16_t *ptr = (uint16_t *)&ph;
    for (int i = 0; i < sizeof(ph)/2; i++) {
        sum += ptr[i];
    }
    
    ptr = (uint16_t *)tcp_hdr;
    int len = tcp_len;
    while (len > 1) {
        sum += *ptr++;
        len -= 2;
    }
    if (len == 1) {
        // 由于是网络字节序，大端序，未满16位时放到高字节
        uint16_t last_byte = 0;
        *(uint8_t *)&last_byte = *(uint8_t *)ptr;
        sum += last_byte;
    }
    
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    return ~sum;
}

// 获取真机 Wi-Fi IP
static NSString *get_wifi_ip(void) {
    NSString *address = @"127.0.0.1"; // 默认 fallback
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *temp_addr = interfaces; temp_addr != NULL; temp_addr = temp_addr->ifa_next) {
            if (temp_addr->ifa_addr->sa_family == AF_INET) {
                NSString *name = [NSString stringWithUTF8String:temp_addr->ifa_name];
                if ([name isEqualToString:@"en0"]) {
                    address = [NSString stringWithUTF8String:inet_ntoa(((struct sockaddr_in *)temp_addr->ifa_addr)->sin_addr)];
                    break;
                }
            }
        }
        freeifaddrs(interfaces);
    }
    return address;
}

static void *utun_loop(void *arg) {
    uint8_t buffer[4096];
    
    NSString *wifi_ip_str = get_wifi_ip();
    NSLog(@"[utun-nat] 设备底层 Wi-Fi IP: %@", wifi_ip_str);
    
    uint32_t ip_wifi = inet_addr(wifi_ip_str.UTF8String);
    uint32_t ip_fake_src = inet_addr("10.8.0.2");
    uint32_t ip_fake_dst = inet_addr("10.8.0.3");

    while (g_utun_running) {
        ssize_t n = read(g_utun_fd, buffer, sizeof(buffer));
        if (n <= 0) continue;
        
        NSLog(@"[utun-nat] -------- READ PACKET: size=%zd --------", n);
        if (n < 24) {
            NSLog(@"[utun-nat] 包太小: %zd", n);
            continue;
        }
        
        // UTUN 前面有 4 字节的 AF_INET
        uint32_t family = *(uint32_t *)buffer;
        NSLog(@"[utun-nat] Family=0x%08x", family);
        if (family != AF_INET && family != htonl(AF_INET)) {
            NSLog(@"[utun-nat] 忽略非 AF_INET (2) 的包!");
            continue;
        }
        
        uint8_t *ip_hdr = buffer + 4;
        
        // 必须是 IPv4
        if ((ip_hdr[0] >> 4) != 4) {
            NSLog(@"[utun-nat] 忽略非 IPv4!");
            continue;
        }
        
        // 获取头部长度
        int ihl = (ip_hdr[0] & 0x0F) * 4;
        
        // 源地址、目标地址
        uint32_t src_ip = *(uint32_t *)(ip_hdr + 12);
        uint32_t dst_ip = *(uint32_t *)(ip_hdr + 16);
        
        BOOL modified = NO;
        
        // Outbound: go-ios -> 10.8.0.3，我们拦截它，伪装成发往 lockdownd
        if (src_ip == ip_fake_src && dst_ip == ip_fake_dst) {
            *(uint32_t *)(ip_hdr + 12) = ip_fake_dst; // 伪装成是从 10.8.0.3 来的
            *(uint32_t *)(ip_hdr + 16) = ip_wifi;     // 目的地发给真实的内核 lockdownd
            modified = YES;
            NSLog(@"[utun-nat] 拦截 OUTBOUND: 10.8.0.2 -> 10.8.0.3 变更为 10.8.0.3 -> Wi-Fi");
        } 
        // Inbound: lockdownd -> 伪装端，发回给 go-ios
        else if (src_ip == ip_wifi && dst_ip == ip_fake_dst) {
            *(uint32_t *)(ip_hdr + 12) = ip_fake_dst; // 伪装成是 10.8.0.3 发回来的
            *(uint32_t *)(ip_hdr + 16) = ip_fake_src; // 路由目标交还给 go-ios
            modified = YES;
            NSLog(@"[utun-nat] 拦截 INBOUND: Wi-Fi -> 10.8.0.3 变更为 10.8.0.3 -> 10.8.0.2");
        } else {
            struct in_addr src_addr, dst_addr;
            src_addr.s_addr = src_ip;
            dst_addr.s_addr = dst_ip;
            NSLog(@"[utun-nat] 忽略未知包: %s -> %s", inet_ntoa(src_addr), inet_ntoa(dst_addr));
        }
        
        if (modified) {
            // 重算 IP Checksum
            ip_hdr[10] = 0;
            ip_hdr[11] = 0;
            uint16_t new_ip_csum = calculate_checksum((uint16_t *)ip_hdr, ihl);
            *(uint16_t *)(ip_hdr + 10) = new_ip_csum;
            
            // 重算 TCP/UDP Checksum (Protocol is at offset 9)
            if (ip_hdr[9] == IPPROTO_TCP) {
                uint8_t *tcp_hdr = ip_hdr + ihl;
                int tcp_len = (int)n - 4 - ihl;
                // clear old checksum (offset 16)
                *(uint16_t *)(tcp_hdr + 16) = 0;
                uint16_t new_tcp_csum = tcp_checksum(ip_hdr, tcp_hdr, tcp_len);
                *(uint16_t *)(tcp_hdr + 16) = new_tcp_csum;
            }
            
            // 写回内核！由于这个网卡就是 iOS 真实路由层，内核会按修改后的目标地址分发！
            write(g_utun_fd, buffer, n);
            // NSLog(@"[utun-nat] 拦截并重写了一个包，成功欺骗系统物理层!");
        }
    }
    return NULL;
}

static void add_route(const char *dest_ip, const char *ifname) {
    int rts = socket(PF_ROUTE, SOCK_RAW, AF_INET);
    if (rts < 0) {
        NSLog(@"[utun-nat] ❌ 无法打开 PF_ROUTE Socket: %s", strerror(errno));
        return;
    }
    
    struct {
        struct rt_msghdr_compat hdr;
        struct sockaddr_in dst;
        struct sockaddr_dl_compat gw;
    } msg;
    memset(&msg, 0, sizeof(msg));
    
    msg.hdr.rtm_msglen = sizeof(msg);
    msg.hdr.rtm_version = RTM_VERSION;
    msg.hdr.rtm_type = RTM_ADD;
    msg.hdr.rtm_flags = RTF_UP | RTF_HOST | RTF_STATIC;
    msg.hdr.rtm_addrs = RTA_DST | RTA_GATEWAY;
    msg.hdr.rtm_pid = getpid();
    msg.hdr.rtm_seq = 1;
    
    msg.dst.sin_len = sizeof(struct sockaddr_in);
    msg.dst.sin_family = AF_INET;
    msg.dst.sin_addr.s_addr = inet_addr(dest_ip);
    
    msg.gw.sdl_len = sizeof(struct sockaddr_dl_compat);
    msg.gw.sdl_family = AF_LINK;
    msg.gw.sdl_index = if_nametoindex(ifname);
    
    if (write(rts, &msg, sizeof(msg)) < 0) {
        NSLog(@"[utun-nat] ❌ Route Injection Failed: %s -> %s: %s", dest_ip, ifname, strerror(errno));
    } else {
        NSLog(@"[utun-nat] 💀 神级指令生效：成功接管 Darwin 路由表，注入 %s -> %s !", dest_ip, ifname);
    }
    close(rts);
}

void start_utun_nat(void) {
    if (g_utun_running) return;
    
    NSLog(@"[utun-nat] 正在申请内核底层的虚拟网卡接口...");
    
    g_utun_fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (g_utun_fd < 0) {
        NSLog(@"[utun-nat] ❌ PF_SYSTEM socket 建立失败: %s", strerror(errno));
        return;
    }
    
    struct ctl_info cti;
    memset(&cti, 0, sizeof(cti));
    strlcpy(cti.ctl_name, "com.apple.net.utun_control", sizeof(cti.ctl_name));
    if (ioctl(g_utun_fd, CTLIOCGINFO, &cti) < 0) {
        NSLog(@"[utun-nat] ❌ CTLIOCGINFO 失败: %s", strerror(errno));
        close(g_utun_fd);
        g_utun_fd = -1;
        return;
    }
    
    struct sockaddr_ctl sc;
    memset(&sc, 0, sizeof(sc));
    sc.sc_id = cti.ctl_id;
    sc.sc_len = sizeof(sc);
    sc.sc_family = AF_SYSTEM;
    sc.ss_sysaddr = AF_SYS_CONTROL;
    sc.sc_unit = 0; // 自动分配单元
    
    if (connect(g_utun_fd, (struct sockaddr *)&sc, sizeof(sc)) < 0) {
        NSLog(@"[utun-nat] ❌ 连接 com.apple.net.utun_control 失败: %s", strerror(errno));
        close(g_utun_fd);
        g_utun_fd = -1;
        return;
    }
    
    socklen_t name_len = sizeof(g_utun_ifname);
    if (getsockopt(g_utun_fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, g_utun_ifname, &name_len) < 0) {
        NSLog(@"[utun-nat] ❌ 无法获取网卡名称!");
        return;
    }
    NSLog(@"[utun-nat] ✅ 成功向系统申请到隐藏网卡: %s", g_utun_ifname);
    
    // 给网卡配置 IP
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strlcpy(ifr.ifr_name, g_utun_ifname, IFNAMSIZ);
    
    struct sockaddr_in *addr = (struct sockaddr_in *)&ifr.ifr_addr;
    addr->sin_family = AF_INET;
    addr->sin_len = sizeof(struct sockaddr_in);
    
    addr->sin_addr.s_addr = inet_addr("10.8.0.2");
    if (ioctl(s, SIOCSIFADDR, &ifr) < 0) {
        NSLog(@"[utun-nat] ❌ SIOCSIFADDR failed: %s", strerror(errno));
    }
    
    addr->sin_addr.s_addr = inet_addr("10.8.0.3");
    if (ioctl(s, SIOCSIFDSTADDR, &ifr) < 0) {
        NSLog(@"[utun-nat] ❌ SIOCSIFDSTADDR failed: %s", strerror(errno));
    }
    
    if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0) {
        ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
        ioctl(s, SIOCSIFFLAGS, &ifr);
        NSLog(@"[utun-nat] ✅ 网卡已点亮！");
    }
    close(s);
    
    // 最底层指令：强行纂改内核路由！
    add_route("10.8.0.3", g_utun_ifname);
    
    g_utun_running = YES;
    pthread_create(&g_utun_thread, NULL, utun_loop, NULL);
}

void stop_utun_nat(void) {
    g_utun_running = NO;
    if (g_utun_fd >= 0) {
        close(g_utun_fd);
        g_utun_fd = -1;
    }
}
