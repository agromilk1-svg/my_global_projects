project_path = "/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj"

with open(project_path, 'r') as f:
    content = f.read()

# Fix ECLogManager.m
old_m = 'path = ECLogManager.m; sourceTree = "<group>";'
new_m = 'path = ECMAIN/Core/ECLogManager.m; sourceTree = SOURCE_ROOT;'

# Fix ECLogManager.h
old_h = 'path = ECLogManager.h; sourceTree = "<group>";'
new_h = 'path = ECMAIN/Core/ECLogManager.h; sourceTree = SOURCE_ROOT;'

if old_m in content:
    content = content.replace(old_m, new_m)
    print("Fixed ECLogManager.m path")
else:
    print("ECLogManager.m path pattern not found or already fixed")

if old_h in content:
    content = content.replace(old_h, new_h)
    print("Fixed ECLogManager.h path")
else:
    print("ECLogManager.h path pattern not found or already fixed")

with open(project_path, 'w') as f:
    f.write(content)
