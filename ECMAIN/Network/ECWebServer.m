#import "ECWebServer.h"
#import "../ECMAIN/Core/ECScriptParser.h"
#import "../System/ECSystemManager.h"
#import "ECNetworkManager.h"
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <sys/socket.h>

@interface ECWebServer ()
@property(assign, nonatomic) CFSocketRef socket;
@end

@implementation ECWebServer

+ (instancetype)sharedServer {
  static ECWebServer *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ECWebServer alloc] init];
  });
  return sharedInstance;
}

- (void)startServerWithPort:(uint16_t)port {
  if (self.socket)
    return;

  CFSocketContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
  self.socket =
      CFSocketCreate(kCFAllocatorDefault, PF_INET, SOCK_STREAM, IPPROTO_TCP,
                     kCFSocketAcceptCallBack, handleConnect, &ctx);

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_len = sizeof(addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);

  // 必须加复用：防止 iOS 上的 TIME_WAIT 引发下一次重连时默默失联
  int yes = 1;
  setsockopt(CFSocketGetNative(self.socket), SOL_SOCKET, SO_REUSEADDR,
             (void *)&yes, sizeof(yes));

  NSData *addressData = [NSData dataWithBytes:&addr length:sizeof(addr)];
  if (CFSocketSetAddress(self.socket, (__bridge CFDataRef)addressData) !=
      kCFSocketSuccess) {
    NSLog(@"[ECWebServer] Failed to bind port %d", port);
    return;
  }

  CFRunLoopSourceRef source =
      CFSocketCreateRunLoopSource(kCFAllocatorDefault, self.socket, 0);
  CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
  CFRelease(source);

  NSLog(@"[ECWebServer] Started on port %d", port);
}

- (void)stopServer {
  if (self.socket) {
    CFSocketInvalidate(self.socket);
    CFRelease(self.socket);
    self.socket = NULL;
  }
}

void handleConnect(CFSocketRef s, CFSocketCallBackType type, CFDataRef address,
                   const void *data, void *info) {
  if (type != kCFSocketAcceptCallBack)
    return;

  CFSocketNativeHandle nativeSocketHandle = *(CFSocketNativeHandle *)data;

  // Simple handling in background
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0),
                 ^{
                   handleRequest(nativeSocketHandle);
                 });
}

void handleRequest(int socket) {
  NSMutableData *requestData = [[NSMutableData alloc] init];
  uint8_t buffer[4096];
  BOOL headersComplete = NO;
  NSInteger contentLength = 0;
  NSInteger currentBodyLength = 0;

  while (!headersComplete) {
    ssize_t len = recv(socket, buffer, sizeof(buffer), 0);
    if (len <= 0)
      break;
    [requestData appendBytes:buffer length:len];

    NSString *currentStr = [[NSString alloc] initWithData:requestData
                                                 encoding:NSUTF8StringEncoding];
    if (!currentStr && requestData.length > 0) {
      currentStr = [[NSString alloc] initWithData:requestData
                                         encoding:NSASCIIStringEncoding];
    }

    if (currentStr && [currentStr containsString:@"\r\n\r\n"]) {
      headersComplete = YES;
      NSRange clRange = [currentStr rangeOfString:@"Content-Length: "
                                          options:NSCaseInsensitiveSearch];
      if (clRange.location != NSNotFound) {
        NSString *afterCL =
            [currentStr substringFromIndex:clRange.location + clRange.length];
        NSRange rlRange = [afterCL rangeOfString:@"\r\n"];
        if (rlRange.location != NSNotFound) {
          contentLength =
              [[afterCL substringToIndex:rlRange.location] integerValue];
        }
      }
      NSRange hlRange = [currentStr rangeOfString:@"\r\n\r\n"];
      currentBodyLength = requestData.length - (hlRange.location + 4);
    }
  }

  while (headersComplete && contentLength > 0 &&
         currentBodyLength < contentLength) {
    ssize_t len = recv(socket, buffer, sizeof(buffer), 0);
    if (len <= 0)
      break;
    [requestData appendBytes:buffer length:len];
    currentBodyLength += len;
  }

  NSString *request = [[NSString alloc] initWithData:requestData
                                            encoding:NSUTF8StringEncoding];
  if (!request) {
    close(socket);
    return;
  }

  NSLog(@"[ECWebServer] ====== HTTP REQUEST ======");
  NSLog(@"[ECWebServer] Raw request length: %lu bytes",
        (unsigned long)requestData.length);

  // Check for GET /ping
  if ([request hasPrefix:@"GET /ping"]) {
    const char *response =
        "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\npong";
    send(socket, response, strlen(response), 0);
    close(socket);
    return;
  }

  // Check for GET /logs
  if ([request hasPrefix:@"GET /logs"]) {
    NSArray *logs = [ECScriptParser popGlobalLogs];
    NSDictionary *resp = @{@"status" : @"ok", @"logs" : logs};
    NSData *respData = [NSJSONSerialization dataWithJSONObject:resp
                                                       options:0
                                                         error:nil];
    NSString *respBody = [[NSString alloc] initWithData:respData
                                               encoding:NSUTF8StringEncoding];
    NSString *httpResp =
        [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: "
                                   @"application/json\r\nContent-Length: "
                                   @"%lu\r\nConnection: close\r\n\r\n%@",
                                   (unsigned long)respBody.length, respBody];
    send(socket, [httpResp UTF8String], httpResp.length, 0);
    close(socket);
    return;
  }

  // Very primitive parser
  // Check for POST /task
  if ([request hasPrefix:@"GET /screenshot"]) {
    NSLog(@"[ECWebServer] Matched: GET /screenshot");
    NSString *tmpPath = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"screenshot.jpg"];

    // Delete old
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    BOOL success = [[ECSystemManager sharedManager] takeScreenshot:tmpPath];

    if (success && [[NSFileManager defaultManager] fileExistsAtPath:tmpPath]) {
      NSData *imgData = [NSData dataWithContentsOfFile:tmpPath];
      NSString *header = [NSString
          stringWithFormat:
              @"HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: "
              @"%lu\r\nConnection: close\r\n\r\n",
              (unsigned long)imgData.length];
      send(socket, [header UTF8String], header.length, 0);
      send(socket, [imgData bytes], imgData.length, 0);
      NSLog(@"[ECWebServer] Sent screenshot (%lu bytes)",
            (unsigned long)imgData.length);
    } else {
      const char *response =
          "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n";
      send(socket, response, strlen(response), 0);
      NSLog(@"[ECWebServer] Screenshot failed");
    }
    close(socket);
    return;
  }

  if ([request hasPrefix:@"POST /task"] ||
      [request hasPrefix:@"POST /run_script"]) {
    NSLog(@"[ECWebServer] Matched: POST /task or /run_script");

    // Find body (after double newline)
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location != NSNotFound) {
      NSString *body = [request substringFromIndex:bodyRange.location + 4];
      NSLog(@"[ECWebServer] Request body: %@", body);

      NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
      NSError *jsonError = nil;
      NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bodyData
                                                           options:0
                                                             error:&jsonError];
      if (jsonError) {
        NSLog(@"[ECWebServer] !!! JSON parse error: %@",
              jsonError.localizedDescription);
        // Return error response
        NSDictionary *errResp =
            @{@"status" : @"error", @"message" : @"JSON parse error"};
        NSData *respData = [NSJSONSerialization dataWithJSONObject:errResp
                                                           options:0
                                                             error:nil];
        NSString *respBody =
            [[NSString alloc] initWithData:respData
                                  encoding:NSUTF8StringEncoding];
        NSString *httpResp =
            [NSString stringWithFormat:
                          @"HTTP/1.1 400 Bad Request\r\nContent-Type: "
                          @"application/json\r\nContent-Length: %lu\r\n\r\n%@",
                          (unsigned long)respBody.length, respBody];
        send(socket, [httpResp UTF8String], httpResp.length, 0);
        close(socket);
        return;
      }

      if (json) {
        NSLog(@"[ECWebServer] Parsed JSON: %@", json);
        NSString *taskType = json[@"type"] ?: @"UNKNOWN";
        NSLog(@"[ECWebServer] Task type: %@", taskType);
        NSLog(@"[ECWebServer] Payload: %@", json[@"payload"] ?: @"(none)");

        // 统一格式处理
        NSMutableDictionary *task = [json mutableCopy];
        if (!task[@"type"] && task[@"script"]) {
          task[@"type"] = @"SCRIPT";
          task[@"payload"] = task[@"script"];
          taskType = @"SCRIPT";
          NSLog(@"[ECWebServer] Converted old format to new format");
        }

        // 生成任务 ID 用于追踪
        NSString *taskId = [[NSUUID UUID] UUIDString];

        // 即收即答逻辑已废弃，改作同步单程透传
        NSLog(@"[ECMAIN] 收到 Web 脚本指令 (taskId=%@)，即将进行最长达 60s "
              @"的同构阻塞执行引擎挂起...",
              taskId);

        // 使用同步方法堵截网络连接
        NSDictionary *scriptResult =
            [[ECScriptParser sharedParser] executeScriptSync:task[@"payload"]];

        NSLog(@"[ECMAIN] 引擎执行完毕 (taskId=%@)，封装返回闭环...", taskId);

        NSMutableDictionary *ackResp = [scriptResult mutableCopy];
        ackResp[@"task_id"] = taskId;
        ackResp[@"task_type"] = taskType;

        NSData *ackData = [NSJSONSerialization dataWithJSONObject:ackResp
                                                          options:0
                                                            error:nil];
        NSString *ackHeader =
            [NSString stringWithFormat:
                          @"HTTP/1.1 200 OK\r\nContent-Type: application/json; "
                          @"charset=utf-8\r\nContent-Length: "
                          @"%lu\r\nConnection: close\r\n\r\n",
                          (unsigned long)ackData.length];
        send(socket, [ackHeader UTF8String], strlen([ackHeader UTF8String]), 0);
        send(socket, [ackData bytes], ackData.length, 0);
        close(socket);

        return;
      } else {
        NSLog(@"[ECWebServer] !!! Failed to parse JSON");
      }
    } else {
      NSLog(@"[ECWebServer] !!! No body found in request");
    }
  } else {
    NSLog(@"[ECWebServer] !!! Unknown path, returning 404");
    const char *response =
        "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n";
    send(socket, response, strlen(response), 0);
  }

  // 这里去掉了通用 close(socket); 只要进入 handleTask 就会自己
  // return，没有进入的话在这里 close。
  close(socket);
  NSLog(@"[ECWebServer] ====== REQUEST DONE ======");
}

@end
