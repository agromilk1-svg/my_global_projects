import re

file_path = "/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m"

with open(file_path, "r") as f:
    content = f.read()

# 移除原来的声明
decl = "// v2256 极速克隆标记\nstatic NSString *g_FastCloneId = nil;\nstatic BOOL g_isCloneMode = NO;\n"
content = content.replace(decl, "")

# 放到更靠前的地方
insert_point = content.find("static NSMutableDictionary *g_VirtualKeychain")
if insert_point != -1:
    content = content[:insert_point] + decl + "\n" + content[insert_point:]

with open(file_path, "w") as f:
    f.write(content)

print("Fix applied!")
