#import "ECWebServer.h"
#import "../ECMAIN/Core/ECScriptParser.h"
#import "../System/ECSystemManager.h"
#import "ECNetworkManager.h"
#import "../Shared/TSUtil.h"
#import <UIKit/UIKit.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface ECWebServer ()
@property(assign, nonatomic) CFSocketRef socket;
@property(assign, nonatomic) BOOL isRunning;
@property(strong, nonatomic) NSThread *serverThread; // [v1726] 专用后台线程
@property(assign, nonatomic) CFRunLoopRef serverRunLoop; // [v1726] 后台 RunLoop
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

// [v1726] 后台线程入口：维持 RunLoop 永不退出
- (void)serverThreadMain {
    @autoreleasepool {
        NSLog(@"[ECWebServer] 🧵 后台 Server 线程已启动 (tid=%p)", [NSThread currentThread]);
        self.serverRunLoop = CFRunLoopGetCurrent();
        // 添加一个空 Source 防止 RunLoop 立即退出
        CFRunLoopSourceContext ctx = {0};
        CFRunLoopSourceRef keepAliveSource = CFRunLoopSourceCreate(NULL, 0, &ctx);
        CFRunLoopAddSource(self.serverRunLoop, keepAliveSource, kCFRunLoopDefaultMode);
        CFRelease(keepAliveSource);
        CFRunLoopRun(); // 永久运行
    }
}

// [v1726] 确保后台线程已启动
- (void)ensureServerThread {
    if (!self.serverThread || self.serverThread.isCancelled || self.serverThread.isFinished) {
        self.serverThread = [[NSThread alloc] initWithTarget:self selector:@selector(serverThreadMain) object:nil];
        self.serverThread.name = @"ECWebServer.AcceptThread";
        self.serverThread.qualityOfService = NSQualityOfServiceUserInitiated;
        [self.serverThread start];
        // 等待 RunLoop 就绪
        while (!self.serverRunLoop) {
            usleep(10000); // 10ms
        }
    }
}

- (void)startServerWithPort:(uint16_t)port {
  if (self.socket)
    return;

  // ========== 手动创建 native socket ==========
  int nativeFd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (nativeFd < 0) {
    NSLog(@"[ECWebServer] socket() 创建失败: %s", strerror(errno));
    return;
  }
  
  int flags = fcntl(nativeFd, F_GETFD, 0);
  if (flags >= 0) {
      fcntl(nativeFd, F_SETFD, flags | FD_CLOEXEC);
  }

  int yes = 1;
  setsockopt(nativeFd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
  setsockopt(nativeFd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_len = sizeof(addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_ANY);

  if (bind(nativeFd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    int bindErr = errno;
    NSLog(@"[ECWebServer] ❌ bind() 端口 %d 失败: %s (errno: %d)", port, strerror(bindErr), bindErr);
    close(nativeFd);
    return;
  }

  if (listen(nativeFd, 16) != 0) {
    NSLog(@"[ECWebServer] listen() 端口 %d 失败: %s", port, strerror(errno));
    close(nativeFd);
    return;
  }

  // ========== 用已绑定的 fd 创建 CFSocket ==========
  CFSocketContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
  self.socket = CFSocketCreateWithNative(kCFAllocatorDefault, nativeFd,
                                          kCFSocketAcceptCallBack, handleConnect, &ctx);
  if (!self.socket) {
    NSLog(@"[ECWebServer] CFSocketCreateWithNative 失败");
    close(nativeFd);
    return;
  }

  CFSocketSetSocketFlags(self.socket,
    CFSocketGetSocketFlags(self.socket) | kCFSocketCloseOnInvalidate);

  // [v1726] 关键修复：将 RunLoop Source 添加到独立后台线程，而非主线程
  // 这样即使主线程被截图渲染阻塞，8089 的 accept 回调仍能正常工作
  [self ensureServerThread];
  CFRunLoopSourceRef source =
      CFSocketCreateRunLoopSource(kCFAllocatorDefault, self.socket, 0);
  CFRunLoopAddSource(self.serverRunLoop, source, kCFRunLoopDefaultMode);
  CFRunLoopWakeUp(self.serverRunLoop); // 唤醒后台 RunLoop 使其立即生效
  CFRelease(source);

  self.isRunning = YES;
  NSLog(@"[ECWebServer] ✅ Started on port %d (fd=%d, thread=%@)", port, nativeFd, self.serverThread.name);
}

- (BOOL)isPortActive {
    return (self.socket != NULL && self.isRunning);
}

- (void)stopServer {
  if (self.socket) {
    CFSocketInvalidate(self.socket);
    CFRelease(self.socket);
    self.socket = NULL;
    self.isRunning = NO;
    NSLog(@"[ECWebServer] 已停止服务并释放端口");
  }
}


// [v1726] 重构：不再依赖主线程，直接在后台线程执行关停与重启
- (void)restartOnPort:(uint16_t)port {
    NSLog(@"[ECWebServer] ⚡️ 正在重启 Web Server (端口 %d)...", port);
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        [self stopServer];
        // 延迟 1s 后尝试绑定
        usleep(1000000); // 1 秒
        [self startServerWithPort:port];
        if (self.socket) {
            NSLog(@"[ECWebServer] ✅ Web Server 重启成功 (端口 %d)", port);
        } else {
            NSLog(@"[ECWebServer] ⚠️ 端口 %d 绑定失败，尝试 root kill...", port);
            [self killProcessOnPort:port];
            usleep(2000000); // 2 秒
            [self startServerWithPort:port];
            NSLog(@"[ECWebServer] %@ root kill 后重试完成 (端口 %d)", self.socket ? @"✅" : @"❌", port);
        }
    });
}

// 通过 root 权限查找并杀死占用指定端口的进程
- (void)killProcessOnPort:(uint16_t)port {
    NSString *stdOut = nil;
    NSString *stdErr = nil;
    // 使用 trollstorehelper 执行 lsof (iOS 无 /bin/sh)
    NSString *helper = rootHelperPath();
    int ret = spawnRoot(helper, @[@"lsof-port", [NSString stringWithFormat:@"%d", port]], &stdOut, &stdErr);
    NSLog(@"[ECWebServer] 🔍 RootHelper (lsof-port %d) 执行完毕: ret=%d", port, ret);
    if (stdOut.length > 0) NSLog(@"[ECWebServer] RootHelper STDOUT: %@", stdOut);
    if (stdErr.length > 0) NSLog(@"[ECWebServer] RootHelper STDERR: %@", stdErr);
    // 如果 helper 不支持 lsof-port，尝试直接用 fuser
    if (ret != 0) {
        ret = spawnRoot(@"/usr/bin/fuser", @[[NSString stringWithFormat:@"%d/tcp", port]], &stdOut, &stdErr);
        NSLog(@"[ECWebServer] fuser %d/tcp: ret=%d, out=%@, err=%@", port, ret, stdOut, stdErr);
    }
    if (stdOut.length > 0) {
        NSArray *pids = [stdOut componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSInteger myPID = [[NSProcessInfo processInfo] processIdentifier];
        for (NSString *pidStr in pids) {
            NSInteger pid = [pidStr integerValue];
            if (pid > 0 && pid != myPID) {
                NSLog(@"[ECWebServer] 🔪 Killing PID %ld occupying port %d", (long)pid, port);
                spawnRoot(@"/usr/bin/kill", @[@"-9", [NSString stringWithFormat:@"%ld", (long)pid]], nil, nil);
            }
        }
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

  // 解析第一行以获取 Method 和 Path
  NSString *firstLine = [[request componentsSeparatedByString:@"\r\n"] firstObject];
  NSLog(@"[ECWebServer] Request Line: %@", firstLine);

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

  // Check for GET /start-wda — 远程触发 WDA 启动（通过 RootHelper 绕过代码签名校验）
  if ([request hasPrefix:@"GET /start-wda"]) {
    NSLog(@"[ECWebServer] Matched: GET /start-wda — 远程触发 WDA 底核启动");
    
    __block int wdaResult = -1;
    NSString *helperPath = rootHelperPath();
    if (helperPath && [[NSFileManager defaultManager] fileExistsAtPath:helperPath]) {
      NSString *stdOut = nil;
      NSString *stdErr = nil;
      wdaResult = spawnRoot(helperPath, @[@"start-wda"], &stdOut, &stdErr);
      NSLog(@"[ECWebServer] start-wda result=%d, stdout=%@, stderr=%@", wdaResult, stdOut, stdErr);
    } else {
      NSLog(@"[ECWebServer] ❌ RootHelper not found, cannot start WDA");
    }
    
    NSDictionary *resp = @{
      @"status": wdaResult == 0 ? @"ok" : @"error",
      @"message": wdaResult == 0 ? @"WDA started successfully" : @"Failed to start WDA"
    };
    NSData *respData = [NSJSONSerialization dataWithJSONObject:resp options:0 error:nil];
    NSString *respBody = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
    NSString *httpResp = [NSString stringWithFormat:
        @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
        (unsigned long)respBody.length, respBody];
    send(socket, [httpResp UTF8String], httpResp.length, 0);
    close(socket);
    return;
  }

  // Check for GET /
  if ([request hasPrefix:@"GET / HTTP/1.1"]) {
    const char *response =
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
    send(socket, response, strlen(response), 0);
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
        
        // [v1736] 稳健性增强：微延时确保数据包完全送入内核发送队列再关闭
        // 避免隧道模式下 NSURLSession 偶发性接收不全
        usleep(50000); 
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
