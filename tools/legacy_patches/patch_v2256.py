import re
import sys

file_path = "/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m"

with open(file_path, "r") as f:
    content = f.read()

# 1. 在顶部插入 g_FastCloneId
if "static NSString *g_FastCloneId = nil;" not in content:
    insert_point = content.find("static NSMutableDictionary *g_VirtualKeychain = nil;")
    if insert_point == -1:
        insert_point = content.find("static NSMutableDictionary *g_VirtualKeychain")
    
    if insert_point != -1:
        fast_clone_vars = """
// v2256 极速克隆标记
static NSString *g_FastCloneId = nil;
static BOOL g_isCloneMode = NO;

"""
        content = content[:insert_point] + fast_clone_vars + content[insert_point:]

# 2. 在 constructor 的极早期注入解析逻辑
constructor_sig = r"__attribute__\(\(constructor\)\) static void ECDeviceSpoofInitialize\(void\) \{"
constructor_match = re.search(constructor_sig, content)
if constructor_match and "🚀 极速判定启动" not in content:
    idx = constructor_match.end()
    fast_detect_logic = """
    // [极速克隆标记] 在最早期拦截开始前，强制确定身份！
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
    content = content[:idx] + fast_detect_logic + content[idx:]

# 3. 替换 Keychain 的 cloneId 判定
# 将 `NSString *cloneId = [[SCPrefLoader shared] currentCloneId];` 以及 `if (cloneId) {`
# 替换为 `if (g_isCloneMode) {`
# 但我们要处理 4 个钩子
def replace_keychain(func_name):
    global content
    pattern = r'(static OSStatus hooked_' + func_name + r'.*?\{)\s*NSString \*cloneId = \[\[SCPrefLoader shared\] currentCloneId\];\s*if \(cloneId\) \{'
    replacement = r'\1\n    if (g_isCloneMode) {'
    content = re.sub(pattern, replacement, content, flags=re.DOTALL)

replace_keychain("SecItemCopyMatching")
replace_keychain("SecItemAdd")
replace_keychain("SecItemUpdate")
replace_keychain("SecItemDelete")

# 4. 增加 UIPasteboard 隔离
pasteboard_logic = """
#pragma mark - UIPasteboard Isolation
@interface UIPasteboard (ec_Isolation)
+ (UIPasteboard *)ec_pasteboardWithName:(NSString *)pasteboardName create:(BOOL)create;
+ (UIPasteboard *)ec_generalPasteboard;
@end

@implementation UIPasteboard (ec_Isolation)
+ (UIPasteboard *)ec_pasteboardWithName:(NSString *)pasteboardName create:(BOOL)create {
    if (g_isCloneMode && g_FastCloneId) {
        NSString *isolatedName = [NSString stringWithFormat:@"%@_clone_%@", pasteboardName, g_FastCloneId];
        NSLog(@"[ecwg][ECDeviceSpoof] 🛡️ 强制隔离 UIPasteboard: %@ -> %@", pasteboardName, isolatedName);
        return [self ec_pasteboardWithName:isolatedName create:create];
    }
    return [self ec_pasteboardWithName:pasteboardName create:create];
}
+ (UIPasteboard *)ec_generalPasteboard {
    if (g_isCloneMode && g_FastCloneId) {
        NSString *isolatedName = [NSString stringWithFormat:@"general_clone_%@", g_FastCloneId];
        NSLog(@"[ecwg][ECDeviceSpoof] 🛡️ 强制隔离 UIPasteboard general: -> %@", isolatedName);
        // 使用 withName 来获取一个虚假的 general
        return [self ec_pasteboardWithName:isolatedName create:YES];
    }
    return [self ec_generalPasteboard];
}
@end
"""

if "UIPasteboard (ec_Isolation)" not in content:
    # Find a good place to insert, right before setupDataIsolationHooks
    setup_data_idx = content.find("static void setupDataIsolationHooks(void) {")
    if setup_data_idx != -1:
        content = content[:setup_data_idx] + pasteboard_logic + "\n" + content[setup_data_idx:]
        
        # Then, inside setupDataIsolationHooks, inject the swizzles
        swizzle_logic = """
    // [NEW v2256] UIPasteboard Swizzle
    swizzleClassMethod([UIPasteboard class], @selector(pasteboardWithName:create:), @selector(ec_pasteboardWithName:create:));
    swizzleClassMethod([UIPasteboard class], @selector(generalPasteboard), @selector(ec_generalPasteboard));
    ECLog(@" Swizzled: +[UIPasteboard pasteboardWithName/generalPasteboard]");
"""
        # Find the line `ECLog(@" ℹ️ standardUserDefaults: 使用系统默认 (独立沙盒天然隔离)");` and insert after it
        insert_idx2 = content.find('ECLog(@" ℹ️ standardUserDefaults: 使用系统默认 (独立沙盒天然隔离)");')
        if insert_idx2 != -1:
            end_of_line = content.find("\n", insert_idx2)
            content = content[:end_of_line] + swizzle_logic + content[end_of_line:]

with open(file_path, "w") as f:
    f.write(content)

print("v2256 Python patching completed!")
