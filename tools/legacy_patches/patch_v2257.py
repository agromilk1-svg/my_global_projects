import re

file_path = "/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m"

with open(file_path, "r") as f:
    content = f.read()

# 检查是否已经注入
if "🚀 极速判定启动" not in content:
    # 寻找 constructor 入口
    # __attribute__((constructor)) static void constructor(void) {
    #     @autoreleasepool {
    #       // 0. [CRITICAL] 立即抹除注入痕迹
    #       sanitizeMainBinaryHeader();
    search_str = "sanitizeMainBinaryHeader();"
    idx = content.find(search_str)
    
    if idx != -1:
        insert_idx = idx + len(search_str)
        fast_detect_logic = """

      // [极速克隆标记 v2257] 在最早期拦截开始前，强制确定身份！
      NSString *__fastBid = [[NSBundle mainBundle] bundleIdentifier];
      if (!__fastBid) {
          NSString *__infoPath = [[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Info.plist"];
          NSDictionary *__infoDict = [NSDictionary dictionaryWithContentsOfFile:__infoPath];
          __fastBid = __infoDict[@"CFBundleIdentifier"];
      }
      if (__fastBid) {
          NSRegularExpression *__regex = [NSRegularExpression regularExpressionWithPattern:@"\\\\.([a-zA-Z]{3,})(\\\\d+)$" options:0 error:nil];
          NSTextCheckingResult *__match = [__regex firstMatchInString:__fastBid options:0 range:NSMakeRange(0, __fastBid.length)];
          if (__match && __match.numberOfRanges > 2) {
              g_FastCloneId = [__fastBid substringWithRange:[__match rangeAtIndex:2]];
              g_isCloneMode = YES;
              NSLog(@"[ecwg][ECDeviceSpoof] 🚀 极速判定启动：当前是克隆环境 CloneID: %@", g_FastCloneId);
          } else {
              // Try .cloneX format
              __regex = [NSRegularExpression regularExpressionWithPattern:@"\\\\.clone(\\\\d+)$" options:0 error:nil];
              __match = [__regex firstMatchInString:__fastBid options:0 range:NSMakeRange(0, __fastBid.length)];
              if (__match && __match.numberOfRanges > 1) {
                  g_FastCloneId = [__fastBid substringWithRange:[__match rangeAtIndex:1]];
                  g_isCloneMode = YES;
                  NSLog(@"[ecwg][ECDeviceSpoof] 🚀 极速判定启动：当前是克隆环境 CloneID: %@", g_FastCloneId);
              }
          }
      }
"""
        content = content[:insert_idx] + fast_detect_logic + content[insert_idx:]
        
        with open(file_path, "w") as f:
            f.write(content)
        print("v2257 Python patching completed!")
    else:
        print("Failed to find sanitizeMainBinaryHeader();")
else:
    print("Already patched!")

