import re

with open("/Users/hh/Desktop/my/ECMAIN/Dylib/SCPrefLoader.m", "r") as f:
    content = f.read()

pattern = re.compile(r'- \(nullable NSString \*\)cloneDataDirectory \{.*?return cachedDataDir;\n\}', re.DOTALL)

replacement = """- (nullable NSString *)cloneDataDirectory {
  static NSString *cachedDataDir = nil;
  static dispatch_once_t onceToken;

  if (!self.currentCloneId) {
    return nil; // 主应用使用默认目录
  }

  dispatch_once(&onceToken, ^{
    // [v2255 致命漏洞修复] 绝对禁止依赖 getenv("HOME")！
    // 强制统一使用设备的全局公共目录 (TrollStore app 具有访问权限)。
    NSString *globalPath = @"/var/mobile/Documents/.com.apple.UIKit.pboard";
    cachedDataDir = [NSString stringWithFormat:@"%@/session_%@", globalPath, self.currentCloneId];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:cachedDataDir]) {
      [fm createDirectoryAtPath:cachedDataDir withIntermediateDirectories:YES attributes:nil error:nil];
      ECConfigLog(@" ✅ 创建分身数据目录: %@", cachedDataDir);
    }
  });
  return cachedDataDir;
}"""

content = pattern.sub(replacement, content)

with open("/Users/hh/Desktop/my/ECMAIN/Dylib/SCPrefLoader.m", "w") as f:
    f.write(content)
print("Fixed SCPrefLoader.m cloneDataDirectory.")
