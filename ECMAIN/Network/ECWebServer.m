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

  // Check for GET /files (全系统文件浏览与下载)
  if ([request hasPrefix:@"GET /files"]) {
      NSLog(@"[ECWebServer] Matched: GET /files");
      NSArray *parts = [firstLine componentsSeparatedByString:@" "];
      if (parts.count >= 2) {
          NSString *requestPath = parts[1];
          NSString *absPath = @"/";
          if (requestPath.length > 6) {
              absPath = [[requestPath substringFromIndex:6] stringByRemovingPercentEncoding];
              if (![absPath hasPrefix:@"/"]) absPath = [@"/" stringByAppendingString:absPath];
          }
          
          BOOL isDir = NO;
          if ([[NSFileManager defaultManager] fileExistsAtPath:absPath isDirectory:&isDir]) {
              if (isDir) {
                  // ==== Serve HTML directory listing ====
                  NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:absPath error:nil];
                  files = [files sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
                  
                  NSMutableString *html = [NSMutableString stringWithString:@"<html><head><meta charset='utf-8'><title>Root FS Explorer</title><meta name='viewport' content='width=device-width, initial-scale=1.0'><style>body{font-family:-apple-system,sans-serif;padding:20px;background:#f5f5f7}li{margin:8px 0;display:flex;align-items:center;padding:8px;background:#fff;border-radius:6px;box-shadow:0 1px 3px rgba(0,0,0,0.1)}a{flex:1;color:#007aff;text-decoration:none;word-break:break-all}a:hover{text-decoration:underline}.del-btn{background:#ff3b30;color:#fff;border:none;border-radius:4px;padding:4px 8px;margin-left:10px;cursor:pointer}.del-btn:active{background:#d32f2f}.head-bar{display:flex;justify-content:space-between;align-items:center;margin-bottom:20px;font-size:14px;word-break:break-all;gap:10px}.refresh-btn{background:#007aff;color:#fff;border:none;border-radius:6px;padding:8px 16px;cursor:pointer;font-size:14px;white-space:nowrap}</style></head><body>"];
                  
                  [html appendFormat:@"<div class='head-bar'><h2>📁 %@</h2><button class='refresh-btn' onclick='location.reload()'>🔄 刷新</button></div><ul style='list-style:none;padding:0'>", absPath];
                  
                  if (![absPath isEqualToString:@"/"]) {
                      NSString *parentPath = [absPath stringByDeletingLastPathComponent];
                      if (parentPath.length == 0) parentPath = @"/";
                      NSString *parentEncoded = [parentPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                      NSString *hrefUrl = [parentEncoded isEqualToString:@"/"] ? @"/files" : [NSString stringWithFormat:@"/files%@", parentEncoded];
                      [html appendFormat:@"<li style='background:#e5e5ea'><a href='%@'>📁 ../ (返回上级目录)</a></li>", hrefUrl];
                  }
                  
                  for (NSString *f in files) {
                      NSString *fullChildPath = [absPath isEqualToString:@"/"] ? [@"/" stringByAppendingString:f] : [absPath stringByAppendingPathComponent:f];
                      BOOL childIsDir = NO;
                      [[NSFileManager defaultManager] fileExistsAtPath:fullChildPath isDirectory:&childIsDir];
                      NSString *icon = childIsDir ? @"📁" : @"📄";
                      
                      NSString *encodedPath = [fullChildPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                      
                      [html appendFormat:@"<li><a href='/files%@'>%@ %@</a><button class='del-btn' data-file='%@' onclick=\"if(confirm('强暴删除警告: 确定删除 %@ 吗？不可恢复！')) { fetch('/files'+this.dataset.file, {method:'DELETE'}).then(()=>location.reload()); }\">直接删除</button></li>", encodedPath, icon, f, encodedPath, f];
                  }
                  
                  if (files.count == 0) [html appendString:@"<li style='color:#888;justify-content:center'>( Empty Directory )</li>"];
                  [html appendString:@"</ul></body></html>"];
                  
                  NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)[html lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                  send(socket, [header UTF8String], header.length, 0);
                  send(socket, [html UTF8String], [html lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 0);
              } else {
                  // ==== Serve specific file ====
                  NSData *fileData = [NSData dataWithContentsOfFile:absPath];
                  if (fileData) {
                      NSString *ext = [absPath pathExtension].lowercaseString;
                      NSString *contentType = @"application/octet-stream";
                      
                      NSArray *textExts = @[@"txt", @"log", @"json", @"js", @"md", @"csv", @"conf", @"ini", @"m", @"h", @"plist"];
                      NSArray *imageExts = @[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"bmp", @"ico"];
                      NSArray *videoExts = @[@"mp4", @"mov", @"avi", @"mkv"];
                      
                      // 模糊匹配包含 log 的文件或者常见后缀
                      if ([textExts containsObject:ext] || [[absPath lowercaseString] containsString:@".log"]) {
                          contentType = @"text/plain; charset=utf-8";
                      } else if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"]) {
                          contentType = @"text/html; charset=utf-8";
                      } else if ([imageExts containsObject:ext]) {
                          if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) contentType = @"image/jpeg";
                          else contentType = [NSString stringWithFormat:@"image/%@", ext];
                      } else if ([videoExts containsObject:ext]) {
                          if ([ext isEqualToString:@"mov"]) contentType = @"video/quicktime";
                          else contentType = [NSString stringWithFormat:@"video/%@", ext];
                      }
                      
                      NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", contentType, (unsigned long)fileData.length];
                      send(socket, [header UTF8String], header.length, 0);
                      send(socket, [fileData bytes], fileData.length, 0);
                  } else {
                      const char *resp500 = "HTTP/1.1 500 Internal Server Error (Permission Denied)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                      send(socket, resp500, strlen(resp500), 0);
                  }
              }
          } else {
              const char *resp404 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
              send(socket, resp404, strlen(resp404), 0);
          }
      }
      close(socket);
      return;
  }
  
  // Check for DELETE /files (全系统文件删除)
  if ([request hasPrefix:@"DELETE /files"]) {
      NSLog(@"[ECWebServer] Matched: DELETE /files");
      NSArray *parts = [firstLine componentsSeparatedByString:@" "];
      if (parts.count >= 2) {
          NSString *requestPath = parts[1];
          NSString *absPath = @"/";
          if (requestPath.length > 6) {
              absPath = [[requestPath substringFromIndex:6] stringByRemovingPercentEncoding];
              if (![absPath hasPrefix:@"/"]) absPath = [@"/" stringByAppendingString:absPath];
          }
          
          NSError *err = nil;
          if ([[NSFileManager defaultManager] fileExistsAtPath:absPath]) {
              [[NSFileManager defaultManager] removeItemAtPath:absPath error:&err];
              if (!err) {
                  const char *resp200 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                  send(socket, resp200, strlen(resp200), 0);
              } else {
                  NSLog(@"[ECWebServer] 删除文件失败: %@", err);
                  const char *resp500 = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                  send(socket, resp500, strlen(resp500), 0);
              }
          } else {
              const char *resp404 = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
              send(socket, resp404, strlen(resp404), 0);
          }
      }
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

  // [v1930] WDA 反向代理端点：后端在 WS 隧道不可用时通过此端点代理 WDA 请求
  // ECMAIN 本机可以访问 127.0.0.1:10088 (WDA)，但外部无法直接访问（WDA 绑定 localhost）
  if ([request hasPrefix:@"POST /wda_proxy"]) {
    NSLog(@"[ECWebServer] Matched: POST /wda_proxy");
    NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
    if (bodyRange.location != NSNotFound) {
      NSString *body = [request substringFromIndex:bodyRange.location + 4];
      NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary *proxyReq = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
      
      if (proxyReq) {
        NSString *method = proxyReq[@"method"] ?: @"GET";
        NSString *path = proxyReq[@"path"] ?: @"/status";
        NSDictionary *reqBody = proxyReq[@"body"];
        NSNumber *timeoutMs = proxyReq[@"timeout"] ?: @(15000);
        
        // 构造到本机 WDA 的请求
        NSString *wdaUrl = [NSString stringWithFormat:@"http://127.0.0.1:10088%@", path];
        NSURL *targetURL = [NSURL URLWithString:wdaUrl];
        
        if (targetURL) {
          NSMutableURLRequest *wdaReq = [NSMutableURLRequest requestWithURL:targetURL];
          wdaReq.HTTPMethod = method;
          wdaReq.timeoutInterval = [timeoutMs doubleValue] / 1000.0;
          [wdaReq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
          
          if (reqBody && ![method isEqualToString:@"GET"]) {
            wdaReq.HTTPBody = [NSJSONSerialization dataWithJSONObject:reqBody options:0 error:nil];
          }
          
          // 同步等待 WDA 响应
          dispatch_semaphore_t sem = dispatch_semaphore_create(0);
          __block NSData *wdaRespData = nil;
          __block NSHTTPURLResponse *wdaHttpResp = nil;
          __block NSError *wdaError = nil;
          
          NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:wdaReq
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              wdaRespData = data;
              wdaHttpResp = (NSHTTPURLResponse *)response;
              wdaError = error;
              dispatch_semaphore_signal(sem);
            }];
          [task resume];
          dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(([timeoutMs doubleValue] + 2000) * NSEC_PER_MSEC)));
          
          if (wdaRespData && !wdaError) {
            // 成功：包装 WDA 响应返回给后端
            NSDictionary *wdaJson = [NSJSONSerialization JSONObjectWithData:wdaRespData options:0 error:nil];
            NSDictionary *proxyResp = @{
              @"status": @((int)wdaHttpResp.statusCode),
              @"body": wdaJson ?: @{}
            };
            NSData *respData = [NSJSONSerialization dataWithJSONObject:proxyResp options:0 error:nil];
            NSString *respBody = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
            NSString *httpResp = [NSString stringWithFormat:
              @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
              (unsigned long)respBody.length, respBody];
            send(socket, [httpResp UTF8String], httpResp.length, 0);
          } else {
            // 失败：返回错误信息
            NSDictionary *errResp = @{
              @"status": @(502),
              @"body": @{@"error": wdaError ? wdaError.localizedDescription : @"WDA timeout"}
            };
            NSData *respData = [NSJSONSerialization dataWithJSONObject:errResp options:0 error:nil];
            NSString *respBody = [[NSString alloc] initWithData:respData encoding:NSUTF8StringEncoding];
            NSString *httpResp = [NSString stringWithFormat:
              @"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n%@",
              (unsigned long)respBody.length, respBody];
            send(socket, [httpResp UTF8String], httpResp.length, 0);
          }
        }
      }
    }
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
