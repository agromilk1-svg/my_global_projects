#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>

int main() {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un un;
    memset(&un, 0, sizeof(un));
    un.sun_family = AF_UNIX;
    strcpy(un.sun_path, "/var/run/lockdown.sock");
    if (connect(fd, (struct sockaddr *)&un, sizeof(un)) < 0) {
        perror("connect"); return 1;
    }
    
    // Create StartService Plist
    CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(dict, CFSTR("Request"), CFSTR("StartService"));
    CFDictionarySetValue(dict, CFSTR("Service"), CFSTR("com.apple.mobile.mobile_image_mounter"));
    // CFDictionarySetValue(dict, CFSTR("ClientVersionString"), CFSTR("libimobiledevice 1.3.0"));
    
    CFErrorRef error = NULL;
    CFDataRef xml = CFPropertyListCreateData(NULL, dict, kCFPropertyListXMLFormat_v1_0, 0, &error);
    
    uint32_t len = htonl(CFDataGetLength(xml));
    write(fd, &len, 4);
    write(fd, CFDataGetBytePtr(xml), CFDataGetLength(xml));
    
    uint32_t resp_len = 0;
    if (read(fd, &resp_len, 4) != 4) { perror("read len"); return 1; }
    resp_len = ntohl(resp_len);
    char *buf = malloc(resp_len + 1);
    read(fd, buf, resp_len);
    buf[resp_len] = 0;
    printf("Response: %s\n", buf);
    return 0;
}
