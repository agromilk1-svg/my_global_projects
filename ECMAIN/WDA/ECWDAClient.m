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
  NSLog(@"[ECWDAClient] ====== EXECUTE SCRIPT ======");
  NSLog(@"[ECWDAClient] Script: %@", script);

  // WDA 运行在 localhost
  NSString *urlString = @"http://127.0.0.1:10088/wda/script/run";
  NSURL *url = [NSURL URLWithString:urlString];
  NSLog(@"[ECWDAClient] Target URL: %@", urlString);

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

  NSLog(@"[ECWDAClient] Request body: %@", body);
  NSLog(@"[ECWDAClient] Sending request...");

  [[NSURLSession.sharedSession
      dataTaskWithRequest:request
        completionHandler:^(NSData *_Nullable data,
                            NSURLResponse *_Nullable response,
                            NSError *_Nullable error) {
          NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
          NSLog(@"[ECWDAClient] <<< Response received");
          NSLog(@"[ECWDAClient] Status code: %ld", (long)httpResp.statusCode);

          if (error) {
            NSLog(@"[ECWDAClient] !!! ERROR: %@", error.localizedDescription);
            NSLog(@"[ECWDAClient] Error code: %ld", (long)error.code);
            if (completion)
              completion(NO, nil);
            return;
          }

          if (data) {
            NSString *responseStr =
                [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];
            NSLog(@"[ECWDAClient] Response body: %@", responseStr);

            NSDictionary *res = [NSJSONSerialization JSONObjectWithData:data
                                                                options:0
                                                                  error:nil];
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] ========= 接收到 WDA 执行结果 "
                  @"=========");
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] 原始报文: %@", responseStr);
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] 解析结果: %@", res);
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] "
                  @"=======================================");
            if (completion)
              completion(YES, res);
          } else {
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] ========= 接收到 WDA 执行结果 "
                  @"=========");
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] !!! No data in response "
                  @"(没有数据返回)");
            NSLog(@"[EC_CMD_LOG] [ECWDAClient] "
                  @"=======================================");
            if (completion)
              completion(NO, nil);
          }

          NSLog(@"[ECWDAClient] ====== SCRIPT DONE ======");
        }] resume];
}

- (void)statusWithCompletion:(void (^)(BOOL success,
                                       NSDictionary *status))completion {
  NSString *urlString = @"http://127.0.0.1:10088/status";
  // TODO: 实现 HTTP GET 请求
  NSLog(@"[ECWDAClient] Checking status...");
}

@end
