import re

file_path = "/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m"

with open(file_path, "r") as f:
    lines = f.readlines()

new_lines = []
globals_to_insert = [
    "// 极速克隆标记 (v2258)\n",
    "static NSString *g_FastCloneId = nil;\n",
    "static BOOL g_isCloneMode = NO;\n"
]

found_globals = False
for line in lines:
    if "static NSString *g_FastCloneId = nil;" in line:
        continue
    if "static BOOL g_isCloneMode = NO;" in line:
        continue
    new_lines.append(line)

# 在 @implementation ECDeviceSpoof 之前插入，或者在包含 #import 的后面插入
# 我们找到第一个 @interface
insert_idx = 0
for i, line in enumerate(new_lines):
    if "@interface" in line or "static NSMutableDictionary *g_VirtualKeychain" in line:
        insert_idx = i
        break

new_lines = new_lines[:insert_idx] + globals_to_insert + new_lines[insert_idx:]

with open(file_path, "w") as f:
    f.writelines(new_lines)

print("Fix applied v2!")
