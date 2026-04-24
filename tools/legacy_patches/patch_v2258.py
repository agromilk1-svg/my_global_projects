import re

file_path = "/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m"

with open(file_path, "r") as f:
    content = f.read()

# 替换所有 [[SCPrefLoader shared] currentCloneId] 相关的隔离判定
# 1. App Group 隔离 (ec_containerURLForSecurityApplicationGroupIdentifier)
pattern_appgroup = r'NSString \*cloneId = \[\[SCPrefLoader shared\] currentCloneId\];\s*if \(cloneId && groupIdentifier\)'
replacement_appgroup = r'NSString *cloneId = g_FastCloneId;\n    if (g_isCloneMode && cloneId && groupIdentifier)'
content = re.sub(pattern_appgroup, replacement_appgroup, content)

# 2. NSUserDefaults 隔离 (ec_initWithSuiteName:)
pattern_suite = r'NSString \*cloneId = \[\[SCPrefLoader shared\] currentCloneId\];\s*if \(cloneId && suitename && \[suitename isKindOfClass:\[NSString class\]\]\)'
replacement_suite = r'NSString *cloneId = g_FastCloneId;\n    if (g_isCloneMode && cloneId && suitename && [suitename isKindOfClass:[NSString class]])'
content = re.sub(pattern_suite, replacement_suite, content)

# 3. standardUserDefaults 隔离 (ec_standardUserDefaults)
pattern_std = r'NSString \*cloneId = \[\[SCPrefLoader shared\] currentCloneId\];\s*if \(cloneId\)'
replacement_std = r'NSString *cloneId = g_FastCloneId;\n    if (g_isCloneMode && cloneId)'
content = re.sub(pattern_std, replacement_std, content)

# 4. SecItemCopyMatchingVirtual (虚拟 Keychain) 
pattern_virtkey = r'NSString \*cloneId = \[\[SCPrefLoader shared\] currentCloneId\];\s*if \(\!originalBundleId \|\| \!cloneId\)'
replacement_virtkey = r'NSString *cloneId = g_FastCloneId;\n    if (!originalBundleId || !cloneId || !g_isCloneMode)'
content = re.sub(pattern_virtkey, replacement_virtkey, content)

# 5. setupDataIsolationHooks (最致命的开关！！！)
pattern_setup = r'NSString \*cloneId = \[\[SCPrefLoader shared\] currentCloneId\];\s*if \(!cloneId\) \{\s*ECLog\(@" 非分身模式，跳过数据隔离 Hook"\);\s*return;\s*\}'
replacement_setup = r'NSString *cloneId = g_FastCloneId;\n    if (!g_isCloneMode || !cloneId) {\n        ECLog(@" 非分身模式，跳过数据隔离 Hook");\n        return;\n    }'
content = re.sub(pattern_setup, replacement_setup, content)

with open(file_path, "w") as f:
    f.write(content)

print("v2258 Python patching completed!")
