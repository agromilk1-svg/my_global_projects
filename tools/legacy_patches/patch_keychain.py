import re

with open("/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m", "r") as f:
    content = f.read()

# 1. 开启 ECLog
content = re.sub(r'#define EC_DEBUG_LOG_ENABLED 0', '#define EC_DEBUG_LOG_ENABLED 1', content)

# 2. 替换 hooked_SecItemCopyMatching
copy_matching_old = r'''// Hook: SecItemCopyMatching
static OSStatus hooked_SecItemCopyMatching\(CFDictionaryRef query,
                                           CFTypeRef \*result\) \{
    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone\(query\);
    OSStatus status = original_SecItemCopyMatching\(modifiedQuery, result\);

    if \(status == errSecMissingEntitlement \|\| status == errSecItemNotFound\) \{
        ec_init_virtual_keychain\(\);
        NSDictionary \*q = \(__bridge NSDictionary \*\)query;
        NSString \*key = ec_keychain_key\(q\);
        NSDictionary \*savedItem = g_VirtualKeychain\[key\];
        
        if \(savedItem\) \{
            status = errSecSuccess;
            if \(result != NULL\) \{
                if \(\[q\[\(__bridge id\)kSecReturnData\] boolValue\]\) \{
                    NSData \*data = savedItem\[\(__bridge id\)kSecValueData\];
                    if \(data\) \*result = CFRetain\(\(__bridge CFTypeRef\)data\);
                \} else if \(\[q\[\(__bridge id\)kSecReturnAttributes\] boolValue\]\) \{
                    NSMutableDictionary \*attrs = \[savedItem mutableCopy\];
                    \[attrs removeObjectForKey:\(__bridge id\)kSecValueData\];
                    \*result = CFRetain\(\(__bridge CFTypeRef\)attrs\);
                \} else \{
                    \*result = CFRetain\(\(__bridge CFTypeRef\)savedItem\);
                \}
            \}
            NSLog\(@"\[ECFix\] 🛡️ SecItemCopyMatching 从虚拟 Keychain 返回数据: %@", key\);
        \} else \{
            NSLog\(@"\[ECFix\] 🛡️ SecItemCopyMatching 虚拟未找到: %@", key\);
            status = errSecItemNotFound;
        \}
    \}

    if \(modifiedQuery != query\) \{
      CFRelease\(modifiedQuery\);
    \}
    return status;
\}'''

copy_matching_new = '''// Hook: SecItemCopyMatching
static OSStatus hooked_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSString *cloneId = [[SCPrefLoader shared] currentCloneId];
    if (cloneId) {
        // [v2255 致命拦截] 只要是分身模式，绝对禁止系统级 Keychain 读写！
        ec_init_virtual_keychain();
        NSDictionary *q = (__bridge NSDictionary *)query;
        NSString *key = ec_keychain_key(q);
        NSDictionary *savedItem = g_VirtualKeychain[key];
        
        if (savedItem) {
            if (result != NULL) {
                if ([q[(__bridge id)kSecReturnData] boolValue]) {
                    NSData *data = savedItem[(__bridge id)kSecValueData];
                    if (data) *result = CFRetain((__bridge CFTypeRef)data);
                } else if ([q[(__bridge id)kSecReturnAttributes] boolValue]) {
                    NSMutableDictionary *attrs = [savedItem mutableCopy];
                    [attrs removeObjectForKey:(__bridge id)kSecValueData];
                    *result = CFRetain((__bridge CFTypeRef)attrs);
                } else {
                    *result = CFRetain((__bridge CFTypeRef)savedItem);
                }
            }
            NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemCopyMatching (虚拟匹配): %@", key);
            return errSecSuccess;
        } else {
            NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemCopyMatching (虚拟未找到): %@", key);
            return errSecItemNotFound;
        }
    }

    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone(query);
    OSStatus status = original_SecItemCopyMatching(modifiedQuery, result);
    if (modifiedQuery != query) { CFRelease(modifiedQuery); }
    return status;
}'''

# 3. 替换 hooked_SecItemAdd
add_old = r'''// Hook: SecItemAdd
static OSStatus hooked_SecItemAdd\(CFDictionaryRef attributes,
                                  CFTypeRef \*result\) \{
    CFDictionaryRef modifiedAttrs = rewriteKeychainQueryForClone\(attributes\);
    OSStatus status = original_SecItemAdd\(modifiedAttrs, result\);

    if \(status == errSecMissingEntitlement\) \{
        ec_init_virtual_keychain\(\);
        NSDictionary \*attrs = \(__bridge NSDictionary \*\)attributes;
        NSString \*key = ec_keychain_key\(attrs\);
        
        NSMutableDictionary \*item = \[NSMutableDictionary dictionaryWithDictionary:attrs\];
        g_VirtualKeychain\[key\] = item;
        ec_save_virtual_keychain\(\);
        
        NSLog\(@"\[ECFix\] 🛡️ SecItemAdd -34018 -> 存入虚拟 Keychain \[%@\]", key\);
        status = errSecSuccess;
    \}

    if \(modifiedAttrs != attributes\) \{
      CFRelease\(modifiedAttrs\);
    \}
    return status;
\}'''

add_new = '''// Hook: SecItemAdd
static OSStatus hooked_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSString *cloneId = [[SCPrefLoader shared] currentCloneId];
    if (cloneId) {
        ec_init_virtual_keychain();
        NSDictionary *attrs = (__bridge NSDictionary *)attributes;
        NSString *key = ec_keychain_key(attrs);
        
        NSMutableDictionary *item = [NSMutableDictionary dictionaryWithDictionary:attrs];
        g_VirtualKeychain[key] = item;
        ec_save_virtual_keychain();
        
        NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemAdd -> 存入虚拟 Keychain [%@]", key);
        return errSecSuccess;
    }

    CFDictionaryRef modifiedAttrs = rewriteKeychainQueryForClone(attributes);
    OSStatus status = original_SecItemAdd(modifiedAttrs, result);
    if (modifiedAttrs != attributes) { CFRelease(modifiedAttrs); }
    return status;
}'''

# 4. 替换 hooked_SecItemUpdate
update_old = r'''// Hook: SecItemUpdate
static OSStatus hooked_SecItemUpdate\(CFDictionaryRef query,
                                     CFDictionaryRef attributesToUpdate\) \{
    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone\(query\);
    OSStatus status = original_SecItemUpdate\(modifiedQuery, attributesToUpdate\);

    if \(status == errSecMissingEntitlement\) \{
        ec_init_virtual_keychain\(\);
        NSString \*key = ec_keychain_key\(\(__bridge NSDictionary \*\)query\);
        NSDictionary \*savedItemImmutable = g_VirtualKeychain\[key\];
        if \(savedItemImmutable\) \{
            NSMutableDictionary \*savedItem = \[savedItemImmutable mutableCopy\];
            NSDictionary \*update = \(__bridge NSDictionary \*\)attributesToUpdate;
            \[savedItem addEntriesFromDictionary:update\];
            g_VirtualKeychain\[key\] = savedItem; // 写回更新后的字典
            ec_save_virtual_keychain\(\);
            status = errSecSuccess;
        \} else \{
            status = errSecItemNotFound;
        \}
    \}

    if \(modifiedQuery != query\) \{
      CFRelease\(modifiedQuery\);
    \}
    return status;
\}'''

update_new = '''// Hook: SecItemUpdate
static OSStatus hooked_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSString *cloneId = [[SCPrefLoader shared] currentCloneId];
    if (cloneId) {
        ec_init_virtual_keychain();
        NSString *key = ec_keychain_key((__bridge NSDictionary *)query);
        NSDictionary *savedItemImmutable = g_VirtualKeychain[key];
        
        if (savedItemImmutable) {
            NSMutableDictionary *savedItem = [savedItemImmutable mutableCopy];
            NSDictionary *update = (__bridge NSDictionary *)attributesToUpdate;
            [savedItem addEntriesFromDictionary:update];
            g_VirtualKeychain[key] = savedItem;
            ec_save_virtual_keychain();
            NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemUpdate -> 更新虚拟 Keychain [%@]", key);
            return errSecSuccess;
        }
        return errSecItemNotFound;
    }

    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone(query);
    OSStatus status = original_SecItemUpdate(modifiedQuery, attributesToUpdate);
    if (modifiedQuery != query) { CFRelease(modifiedQuery); }
    return status;
}'''

# 5. 替换 hooked_SecItemDelete
delete_old = r'''// Hook: SecItemDelete
static OSStatus hooked_SecItemDelete\(CFDictionaryRef query\) \{
    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone\(query\);
    OSStatus status = original_SecItemDelete\(modifiedQuery\);

    if \(status == errSecMissingEntitlement\) \{
        ec_init_virtual_keychain\(\);
        NSString \*key = ec_keychain_key\(\(__bridge NSDictionary \*\)query\);
        \[g_VirtualKeychain removeObjectForKey:key\];
        ec_save_virtual_keychain\(\);
        NSLog\(@"\[ECFix\] 🛡️ SecItemDelete 从虚拟 Keychain 移除 \[%@\]", key\);
        status = errSecSuccess;
    \}

    if \(modifiedQuery != query\) \{
      CFRelease\(modifiedQuery\);
    \}
    return status;
\}'''

delete_new = '''// Hook: SecItemDelete
static OSStatus hooked_SecItemDelete(CFDictionaryRef query) {
    NSString *cloneId = [[SCPrefLoader shared] currentCloneId];
    if (cloneId) {
        ec_init_virtual_keychain();
        NSString *key = ec_keychain_key((__bridge NSDictionary *)query);
        [g_VirtualKeychain removeObjectForKey:key];
        ec_save_virtual_keychain();
        NSLog(@"[ECFix] 🛡️ 强制拦截 SecItemDelete -> 从虚拟 Keychain 移除 [%@]", key);
        return errSecSuccess;
    }

    CFDictionaryRef modifiedQuery = rewriteKeychainQueryForClone(query);
    OSStatus status = original_SecItemDelete(modifiedQuery);
    if (modifiedQuery != query) { CFRelease(modifiedQuery); }
    return status;
}'''


content = re.sub(copy_matching_old, copy_matching_new, content)
content = re.sub(add_old, add_new, content)
content = re.sub(update_old, update_new, content)
content = re.sub(delete_old, delete_new, content)

with open("/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m", "w") as f:
    f.write(content)
print("Patched ECDeviceSpoof.m successfully.")
