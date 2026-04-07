
path_to_replace = 'path = ECMAIN/TrollStoreCore/'
new_path = 'path = TrollStoreCore/'
project_path = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

with open(project_path, 'r') as f:
    content = f.read()

new_content = content.replace(path_to_replace, new_path)

if new_content != content:
    with open(project_path, 'w') as f:
        f.write(new_content)
    print("Fixed TrollStoreCore paths.")
else:
    print("No paths to fix found (or already fixed).")
