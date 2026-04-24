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
#import <sys/stat.h>
#import <fcntl.h>
@interface ECWebServer ()
@property(assign, nonatomic) CFSocketRef socket;
@property(assign, nonatomic) BOOL isRunning;
@property(strong, nonatomic) NSThread *serverThread; // [v1726] 专用后台线程
@property(assign, nonatomic) CFRunLoopRef serverRunLoop; // [v1726] 后台 RunLoop
@end

static NSString *formatFileSize(long long size) {
    if (size < 1024) return [NSString stringWithFormat:@"%lld B", size];
    if (size < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", size / 1024.0];
    if (size < 1024 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", size / (1024.0 * 1024.0)];
    return [NSString stringWithFormat:@"%.1f GB", size / (1024.0 * 1024.0 * 1024.0)];
}

static NSString *formatFileDate(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    return [formatter stringFromDate:date];
}

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

  // 解析出基础 Header 来拦截特定流式路由
  NSString *tempHeader = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
  if (!tempHeader) tempHeader = [[NSString alloc] initWithData:requestData encoding:NSASCIIStringEncoding];
  if (!tempHeader) { close(socket); return; }
  
  NSArray *tempLines = [tempHeader componentsSeparatedByString:@"\r\n"];
  NSString *tempFirstLine = tempLines.count > 0 ? tempLines[0] : @"";

  // 【大文件流式上传拦截，彻底消灭 OOM】
  if ([tempFirstLine hasPrefix:@"POST /upload-stream"]) {
      NSString *targetDir = @"/";
      NSString *fileName = @"upload.bin";
      for (NSString *line in tempLines) {
          if ([line hasPrefix:@"X-Target-Dir: "]) {
              targetDir = [[line substringFromIndex:14] stringByRemovingPercentEncoding];
          } else if ([line hasPrefix:@"X-File-Name: "]) {
              fileName = [[line substringFromIndex:13] stringByRemovingPercentEncoding];
          }
      }
      if (![targetDir hasPrefix:@"/"]) targetDir = [@"/" stringByAppendingString:targetDir];
      NSString *fullPath = [targetDir stringByAppendingPathComponent:fileName];
      NSLog(@"[ECWebServer] 🌊 流式写入大文件至: %@", fullPath);
      
      int fd = open([fullPath UTF8String], O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (fd >= 0) {
          // 写入被 header 读取带出来的 body 部分
          NSRange hlRange = [tempHeader rangeOfString:@"\r\n\r\n"];
          if (hlRange.location != NSNotFound) {
              NSUInteger headerLen = hlRange.location + 4;
              if (requestData.length > headerLen) {
                  write(fd, [requestData bytes] + headerLen, requestData.length - headerLen);
              }
          }
          // 循环流式写入剩下的 body
          while (currentBodyLength < contentLength) {
              ssize_t len = recv(socket, buffer, sizeof(buffer), 0);
              if (len <= 0) break;
              write(fd, buffer, len);
              currentBodyLength += len;
          }
          close(fd);
          const char *resp200 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
          send(socket, resp200, strlen(resp200), 0);
      } else {
          NSLog(@"[ECWebServer] ❌ 无法打开文件进行写入: %@", fullPath);
          while (currentBodyLength < contentLength) {
              ssize_t len = recv(socket, buffer, sizeof(buffer), 0);
              if (len <= 0) break;
              currentBodyLength += len;
          }
          const char *resp500 = "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
          send(socket, resp500, strlen(resp500), 0);
      }
      close(socket);
      return;
  }

  // 常规缓存整个 Body (由于拦截了大文件上传，剩下的请求都很小)
  while (headersComplete && contentLength > 0 &&
         currentBodyLength < contentLength) {
    ssize_t len = recv(socket, buffer, sizeof(buffer), 0);
    if (len <= 0)
      break;
    [requestData appendBytes:buffer length:len];
    currentBodyLength += len;
  }

  // Separate Header and Body.
  NSData *crlf2 = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange bStart = [requestData rangeOfData:crlf2 options:0 range:NSMakeRange(0, requestData.length)];
  if (bStart.location == NSNotFound) {
      close(socket);
      return;
  }
  
  NSData *headerData = [requestData subdataWithRange:NSMakeRange(0, bStart.location + 4)];
  NSData *bodyData = [requestData subdataWithRange:NSMakeRange(bStart.location + 4, requestData.length - (bStart.location + 4))];
  
  NSString *headerStr = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
  if (!headerStr) headerStr = [[NSString alloc] initWithData:headerData encoding:NSASCIIStringEncoding];
  if (!headerStr) { close(socket); return; }

  NSString *request = headerStr; // Compatibility
  NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
  NSString *firstLine = lines.count > 0 ? lines[0] : @"";
  
  NSLog(@"[ECWebServer] ====== HTTP REQUEST ======");
  NSLog(@"[ECWebServer] Request Line: %@", firstLine);
  NSLog(@"[ECWebServer] Body length: %lu bytes", (unsigned long)bodyData.length);

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
                  
                  NSMutableString *html = [NSMutableString stringWithString:@"<html><head><meta charset='utf-8'><title>Root FS Explorer</title><meta name='viewport' content='width=device-width, initial-scale=1.0'><style>body{font-family:-apple-system,system-ui,sans-serif;margin:0;padding:0;background:#f0f2f5;color:#1c1e21}.container{max-width:1000px;margin:20px auto;background:#fff;border-radius:12px;box-shadow:0 4px 12px rgba(0,0,0,0.1);overflow:hidden;position:relative}header{padding:20px;background:#007aff;color:#fff;display:flex;justify-content:space-between;align-items:center}header h2{margin:0;font-size:20px;word-break:break-all;flex:1}.shortcuts{padding:10px 20px;background:#fff;border-bottom:1px solid #eee;display:flex;gap:10px;flex-wrap:wrap}.shortcut-btn{text-decoration:none;background:#f0f2f5;color:#007aff;padding:6px 12px;border-radius:20px;font-size:13px;font-weight:500;transition:all 0.2s}.shortcut-btn:hover{background:#007aff;color:#fff}.upload-zone{padding:20px;background:#f8f9fa;border-bottom:1px solid #eee;display:flex;flex-direction:column;gap:10px}.batch-actions{padding:10px 20px;background:#fff;border-bottom:1px solid #eee;display:none;align-items:center;gap:15px;position:sticky;top:0;z-index:10;box-shadow:0 2px 8px rgba(0,0,0,0.05)}#progress-container{width:100%;background:#e0e0e0;border-radius:10px;height:20px;overflow:hidden;display:none;margin-top:10px}#progress-bar{height:100%;background:linear-gradient(90deg, #007aff, #5856d6);width:0%;transition:width 0.1s ease;display:flex;align-items:center;justify-content:center;color:#fff;font-size:12px}table{width:100%;border-collapse:collapse}th{text-align:left;background:#f8f9fa;padding:12px 15px;font-size:13px;color:#65676b;text-transform:uppercase;border-bottom:1px solid #eee}td{padding:12px 15px;border-bottom:1px solid #f0f2f5;vertical-align:middle}tr:hover{background:#f1f8ff}.name{display:flex;align-items:center;gap:10px;text-decoration:none;color:#007aff;font-weight:500}.size,.time{font-size:13px;color:#65676b}.actions{text-align:right}.btn{border:none;border-radius:6px;padding:8px 16px;cursor:pointer;font-size:14px;transition:all 0.2s}.btn-refresh{background:rgba(255,255,255,0.2);color:#fff;border:1px solid rgba(255,255,255,0.3)}.btn-refresh:hover{background:rgba(255,255,255,0.3)}.btn-upload{background:#007aff;color:#fff}.btn-upload:hover{background:#0056b3}.btn-del{background:#ff3b30;color:#fff;padding:4px 8px;font-size:12px}.btn-del:hover{background:#d32f2f}.btn-batch-del{background:#ff3b30;color:#fff;font-weight:bold}input[type='file']{font-size:14px;color:#65676b}input[type='checkbox']{width:18px;height:18px;cursor:pointer}</style></head><body>"];
                  
                  [html appendFormat:@"<div class='container'><header><h2>📁 %@</h2><button class='btn btn-refresh' onclick='location.reload()'>🔄 刷新</button></header>", absPath];
                  
                  // Shortcuts
                  NSString *bundlePath = [[NSBundle mainBundle] bundlePath];
                  NSString *dataPath = NSHomeDirectory();
                  NSString *sharedPath = [[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:@"group.com.ecmain.shared"].path;
                  NSString *mediaPath = @"/var/mobile/Media/DCIM";
                  if (![[NSFileManager defaultManager] fileExistsAtPath:mediaPath]) mediaPath = @"/var/mobile/Media";

                  NSString* (^encode)(NSString*) = ^NSString*(NSString *p) {
                      return [p stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                  };

                  [html appendString:@"<div class='shortcuts'>"];
                  [html appendFormat:@"<a href='/files%@' class='shortcut-btn'>🖼️ 相册</a>", encode(mediaPath)];
                  [html appendFormat:@"<a href='/files%@' class='shortcut-btn'>📂 Data 目录</a>", encode(dataPath)];
                  [html appendFormat:@"<a href='/files%@' class='shortcut-btn'>📦 Bundle 目录</a>", encode(bundlePath)];
                  if (sharedPath) {
                      [html appendFormat:@"<a href='/files%@' class='shortcut-btn'>🤝 共享容器</a>", encode(sharedPath)];
                  }
                  [html appendString:@"</div>"];
                  
                  // Batch Actions Bar
                  [html appendString:@"<div class='batch-actions' id='batchBar'><input type='checkbox' id='selectAll' onclick='toggleAll(this)'> <span id='selectedCount' style='flex:1;font-size:14px;color:#1c1e21'>已选择 0 项</span> <button class='btn btn-batch-del' onclick='batchDelete()'>🗑️ 批量强力删除</button></div>"];

                  // Upload form with Progress
                  [html appendString:@"<div class='upload-zone'><div style='display:flex;gap:10px;align-items:center'><input type='file' id='fileInput' name='file'><button type='button' class='btn btn-upload' onclick='handleUpload()'>🚀 开始上传</button></div><div id='progress-container'><div id='progress-bar'>0%%</div></div></div>"];
                  
                  [html appendString:@"<table><thead><tr><th style='width:40px'></th><th>名称</th><th>大小</th><th>修改时间</th><th class='actions'>操作</th></tr></thead><tbody id='fileList'>"];
                  
                  if (![absPath isEqualToString:@"/"]) {
                      NSString *parentPath = [absPath stringByDeletingLastPathComponent];
                      if (parentPath.length == 0) parentPath = @"/";
                      NSString *parentEncoded = [parentPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                      NSString *hrefUrl = [parentEncoded isEqualToString:@"/"] ? @"/files" : [NSString stringWithFormat:@"/files%@", parentEncoded];
                      [html appendFormat:@"<tr><td></td><td><a href='%@' class='name'>📁 ../ (返回上级目录)</a></td><td>-</td><td>-</td><td></td></tr>", hrefUrl];
                  }
                  
                  for (NSString *f in files) {
                      NSString *fullChildPath = [absPath isEqualToString:@"/"] ? [@"/" stringByAppendingString:f] : [absPath stringByAppendingPathComponent:f];
                      NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:fullChildPath error:nil];
                      BOOL childIsDir = [[attrs fileType] isEqualToString:NSFileTypeDirectory];
                      
                      NSString *icon = childIsDir ? @"📁" : @"📄";
                      NSString *sizeStr = childIsDir ? @"-" : formatFileSize([attrs fileSize]);
                      NSString *timeStr = formatFileDate([attrs fileModificationDate]);
                      
                      NSString *encodedPath = [fullChildPath stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
                      
                      [html appendFormat:@"<tr><td><input type='checkbox' class='file-check' data-path='%@' onclick='updateBatchBar()'></td><td><a href='/files%@' class='name'>%@ %@</a></td><td class='size'>%@</td><td class='time'>%@</td><td class='actions'><button class='btn btn-del' data-file='%@' onclick=\"if(confirm('警告: 确定删除 %@ 吗？不可恢复！')) { fetch('/files'+this.dataset.file, {method:'DELETE'}).then(()=>location.reload()); }\">删除</button></td></tr>", encodedPath, encodedPath, icon, f, sizeStr, timeStr, encodedPath, f];
                  }
                  
                  if (files.count == 0) [html appendString:@"<tr><td colspan='5' style='text-align:center;color:#888;padding:20px'>( 空目录 )</td></tr>"];
                  
                  // Add Scripts
                  [html appendString:@"</tbody></table></div>"];
                  [html appendString:@"<script> \
                    function toggleAll(el) { \
                        document.querySelectorAll('.file-check').forEach(c => c.checked = el.checked); \
                        updateBatchBar(); \
                    } \
                    function updateBatchBar() { \
                        const checks = document.querySelectorAll('.file-check:checked'); \
                        const bar = document.getElementById('batchBar'); \
                        const count = document.getElementById('selectedCount'); \
                        if (checks.length > 0) { \
                            bar.style.display = 'flex'; \
                            count.innerText = '已选择 ' + checks.length + ' 项'; \
                        } else { \
                            bar.style.display = 'none'; \
                        } \
                    } \
                    function batchDelete() { \
                        const checks = document.querySelectorAll('.file-check:checked'); \
                        if (!confirm('确定批量删除这 ' + checks.length + ' 项吗？删除后不可恢复！')) return; \
                        const paths = Array.from(checks).map(c => c.dataset.path); \
                        let completed = 0; \
                        paths.forEach(p => { \
                            fetch('/files' + p, {method:'DELETE'}).then(() => { \
                                completed++; \
                                if (completed === paths.length) location.reload(); \
                            }); \
                        }); \
                    } \
                    function handleUpload() { \
                        const input = document.getElementById('fileInput'); \
                        if (input.files.length === 0) return; \
                        const file = input.files[0]; \
                        const xhr = new XMLHttpRequest(); \
                        const pContainer = document.getElementById('progress-container'); \
                        const pBar = document.getElementById('progress-bar'); \
                        pContainer.style.display = 'block'; \
                        xhr.upload.onprogress = (e) => { \
                            if (e.lengthComputable) { \
                                const percent = Math.round((e.loaded / e.total) * 100); \
                                pBar.style.width = percent + '%'; \
                                pBar.innerText = percent + '%'; \
                            } \
                        }; \
                        xhr.onreadystatechange = () => { \
                            if (xhr.readyState === 4) location.reload(); \
                        }; \
                        xhr.open('POST', '/upload-stream', true); \
                        let currentDir = window.location.pathname.substring(6); \
                        if (currentDir === '') currentDir = '/'; \
                        xhr.setRequestHeader('X-Target-Dir', encodeURIComponent(currentDir)); \
                        xhr.setRequestHeader('X-File-Name', encodeURIComponent(file.name)); \
                        xhr.setRequestHeader('Content-Type', 'application/octet-stream'); \
                        xhr.send(file); \
                    } \
                  </script></body></html>"];
                  
                  NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n", (unsigned long)[html lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
                  send(socket, [header UTF8String], header.length, 0);
                  send(socket, [html UTF8String], [html lengthOfBytesUsingEncoding:NSUTF8StringEncoding], 0);
              } else {
                  // ==== Serve specific file (Stream) ====
                  int fd = open([absPath UTF8String], O_RDONLY);
                  if (fd >= 0) {
                      struct stat st;
                      fstat(fd, &st);
                      long long fileSize = st.st_size;
                      
                      NSString *ext = [absPath pathExtension].lowercaseString;
                      NSString *contentType = @"application/octet-stream";
                      
                      NSArray *textExts = @[@"txt", @"log", @"json", @"js", @"md", @"csv", @"conf", @"ini", @"m", @"h", @"plist"];
                      NSArray *imageExts = @[@"jpg", @"jpeg", @"png", @"gif", @"webp", @"bmp", @"ico"];
                      NSArray *videoExts = @[@"mp4", @"mov", @"avi", @"mkv"];
                      
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
                      
                      NSString *header = [NSString stringWithFormat:@"HTTP/1.1 200 OK\r\nContent-Type: %@\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n", contentType, fileSize];
                      send(socket, [header UTF8String], header.length, 0);
                      
                      char readBuf[32768];
                      ssize_t r;
                      while((r = read(fd, readBuf, sizeof(readBuf))) > 0) {
                          ssize_t totalSent = 0;
                          while (totalSent < r) {
                              ssize_t s = send(socket, readBuf + totalSent, r - totalSent, 0);
                              if (s <= 0) break;
                              totalSent += s;
                          }
                          if (totalSent < r) break;
                      }
                      close(fd);
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

  // Check for POST /files (文件上传)
  if ([request hasPrefix:@"POST /files"]) {
      NSLog(@"[ECWebServer] Matched: POST /files (Upload)");
      NSString *targetDir = @"/";
      NSArray *routeParts = [firstLine componentsSeparatedByString:@" "];
      if (routeParts.count >= 2) {
          NSString *routePath = routeParts[1];
          if (routePath.length > 6) {
              targetDir = [[routePath substringFromIndex:6] stringByRemovingPercentEncoding];
              if (![targetDir hasPrefix:@"/"]) targetDir = [@"/" stringByAppendingString:targetDir];
          }
      }
      
      // Get boundary from headerStr
      NSString *boundary = nil;
      NSRange ctRange = [headerStr rangeOfString:@"Content-Type: multipart/form-data; boundary=" options:NSCaseInsensitiveSearch];
      if (ctRange.location == NSNotFound) {
          // Alternative check for Header
          for (NSString *line in lines) {
              if ([line rangeOfString:@"boundary=" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                  boundary = [[line componentsSeparatedByString:@"boundary="] lastObject];
                  break;
              }
          }
      } else {
          NSString *afterBoundary = [headerStr substringFromIndex:ctRange.location + ctRange.length];
          boundary = [[afterBoundary componentsSeparatedByString:@"\r\n"] firstObject];
      }
      
      if (boundary) {
          NSString *boundaryStr = [NSString stringWithFormat:@"--%@", boundary];
          NSData *boundaryData = [boundaryStr dataUsingEncoding:NSUTF8StringEncoding];
          
          // Find first boundary in bodyData
          NSRange firstBoundaryPos = [bodyData rangeOfData:boundaryData options:0 range:NSMakeRange(0, bodyData.length)];
          if (firstBoundaryPos.location != NSNotFound) {
              // Extract part header (after boundary, before \r\n\r\n)
              NSData *crlfcrlfData = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
              NSUInteger partSearchStart = firstBoundaryPos.location + firstBoundaryPos.length;
              NSRange partHeaderEnd = [bodyData rangeOfData:crlfcrlfData options:0 range:NSMakeRange(partSearchStart, bodyData.length - partSearchStart)];
              
              if (partHeaderEnd.location != NSNotFound) {
                  NSData *partHeaderData = [bodyData subdataWithRange:NSMakeRange(partSearchStart, partHeaderEnd.location - partSearchStart)];
                  NSString *partHeaderStr = [[NSString alloc] initWithData:partHeaderData encoding:NSUTF8StringEncoding];
                  if (!partHeaderStr) partHeaderStr = [[NSString alloc] initWithData:partHeaderData encoding:NSASCIIStringEncoding];
                  
                  NSRange fnRange = [partHeaderStr rangeOfString:@"filename=\""];
                  if (fnRange.location != NSNotFound) {
                      NSString *afterFn = [partHeaderStr substringFromIndex:fnRange.location + 10];
                      NSString *filename = [[afterFn componentsSeparatedByString:@"\""] firstObject];
                      
                      if (filename.length > 0) {
                          NSUInteger fileContentStart = partHeaderEnd.location + 4;
                          NSRange nextBoundaryRange = [bodyData rangeOfData:boundaryData options:0 range:NSMakeRange(fileContentStart, bodyData.length - fileContentStart)];
                          
                          if (nextBoundaryRange.location != NSNotFound) {
                              // Data ends before next boundary (-2 for \r\n)
                              NSData *finalFileData = [bodyData subdataWithRange:NSMakeRange(fileContentStart, nextBoundaryRange.location - fileContentStart - 2)];
                              
                              NSString *finalPath = [targetDir stringByAppendingPathComponent:filename];
                              NSLog(@"[ECWebServer] Saving Binary Upload: %@ (Size: %lu bytes)", finalPath, (unsigned long)finalFileData.length);
                              
                              BOOL saved = [finalFileData writeToFile:finalPath atomically:YES];
                              if (saved) {
                                  // For AJAX, return 200 OK
                                  const char *resp200 = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
                                  send(socket, resp200, strlen(resp200), 0);
                              } else {
                                  NSLog(@"[ECWebServer] ERROR: Permission denied or Path invalid for %@", finalPath);
                                  const char *resp500 = "HTTP/1.1 500 Internal Server Error (Write Failed)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                                  send(socket, resp500, strlen(resp500), 0);
                              }
                              close(socket);
                              return;
                          }
                      }
                  }
              }
          }
      }
      
      const char *resp400 = "HTTP/1.1 400 Bad Request (Multipart Parse Error)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      send(socket, resp400, strlen(resp400), 0);
      close(socket);
      return;
  }

  // [v2142] Check for POST /write-file (用于 bypass house_arrest 直接写入 Base64 配置文件)
  if ([request hasPrefix:@"POST /write-file"]) {
      NSLog(@"[ECWebServer] Matched: POST /write-file");
      NSRange bodyRange = [request rangeOfString:@"\r\n\r\n"];
      if (bodyRange.location != NSNotFound) {
          NSString *body = [request substringFromIndex:bodyRange.location + 4];
          NSData *bodyData = [body dataUsingEncoding:NSUTF8StringEncoding];
          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:nil];
          if (json && json[@"path"] && json[@"content_b64"]) {
              NSString *path = json[@"path"];
              NSString *b64 = json[@"content_b64"];
              NSData *fileData = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
              if (fileData) {
                  NSError *err = nil;
                  BOOL saved = [fileData writeToFile:path options:NSDataWritingAtomic error:&err];
                  if (saved) {
                      const char *resp200 = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                      send(socket, resp200, strlen(resp200), 0);
                      NSLog(@"[ECWebServer] ✅ 成功写入文件至: %@", path);
                      close(socket);
                      return;
                  } else {
                      NSLog(@"[ECWebServer] ❌ 写入文件失败: %@", err);
                  }
              }
          }
      }
      const char *resp500 = "HTTP/1.1 500 Internal Server Error (Write Failed)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
      send(socket, resp500, strlen(resp500), 0);
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

    // Find body (after double newline) — 使用正确的二进制 bodyData，而非字符串截割
    // 旧写法 [request substringFromIndex:...] 在含 Unicode 字符时会截断字节导致 JSON 解析失败
    NSLog(@"[ECWebServer] Request body: %@", [[NSString alloc] initWithData:bodyData encoding:NSUTF8StringEncoding] ?: @"<binary/non-utf8>");

    if (bodyData.length > 0) {
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
      NSLog(@"[ECWebServer] !!! Empty body in request (bodyData.length == 0)");
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
