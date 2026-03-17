#import "ECWDAClient.h"

@implementation ECWDAClient

+ (instancetype)sharedClient {
  static ECWDAClient *sharedInstance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    sharedInstance = [[ECWDAClient alloc] init];
  });
  return sharedInstance;
}

- (void)executeScript:(NSString *)script
           completion:(void (^)(BOOL success, NSDictionary *result))completion {
  NSLog(@"[脚本动作] ====== 发送脚本到 WDA 执行 ======");
  NSLog(@"[脚本动作] 脚本内容: %@", script);

  // WDA 运行在 localhost
  NSString *urlString = @"http://127.0.0.1:10088/wda/script/run";
  NSURL *url = [NSURL URLWithString:urlString];

  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  // 彻底取消执行脚本的超时上限。
  // 为了确保哪怕是长达 24 小时或不限时的 `while(true)`
  // 养号脚本可以无视系统阻断地持续运行。
  request.timeoutInterval = 0;

  NSDictionary *body = @{@"script" : script ? script : @""};
  NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body
                                                     options:0
                                                       error:nil];
  request.HTTPBody = bodyData;

  NSLog(@"[脚本动作] 正在发送请求到 WDA...");

  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
          NSLog(@"[脚本动作] <<< 收到 WDA 响应 (HTTP %ld)", (long)httpResp.statusCode);

          if (error) {
            NSLog(@"[脚本动作] ❌ WDA 执行出错: %@", error.localizedDescription);
            if (completion)
              completion(NO, nil);
            return;
          }

          if (data) {
            NSString *responseStr =
                [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];

            NSDictionary *res = [NSJSONSerialization JSONObjectWithData:data
                                                                options:0
                                                                  error:nil];
            NSLog(@"[脚本动作] ========= WDA 执行结果 =========");
            NSLog(@"[脚本动作] 原始报文: %@", responseStr);
            NSLog(@"[脚本动作] 解析结果: %@", res);
            NSLog(@"[脚本动作] ===================================");
            if (completion)
              completion(YES, res);
          } else {
            NSLog(@"[脚本动作] ⚠️ WDA 未返回数据");
            if (completion)
              completion(NO, nil);
          }

          NSLog(@"[脚本动作] ====== WDA 脚本执行完毕 ======");
        }] resume];
}

- (void)statusWithCompletion:(void (^)(BOOL success,
                                       NSDictionary *status))completion {
  NSString *urlString = @"http://127.0.0.1:10088/status";
  // TODO: 实现 HTTP GET 请求
  NSLog(@"[ECWDAClient] Checking status...");
}

@end
