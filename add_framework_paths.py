#!/usr/bin/env python3
"""
Add OpenCV and NCNN framework paths to the Xcode project
"""
import re

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

# Read project file
with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# Paths to add
opencv_header = '"$(SRCROOT)/WebDriverAgentLib/Vendor/opencv2.framework/Headers"'
ncnn_header = '"$(SRCROOT)/WebDriverAgentLib/Vendor/ncnn.framework/Headers"'
opencv_lib = '"$(SRCROOT)/WebDriverAgentLib/Vendor"'
ncnn_lib = '"$(SRCROOT)/WebDriverAgentLib/Vendor"'

# Check if paths already exist
if 'opencv2.framework/Headers' in content:
    print("OpenCV headers already in project")
else:
    # Find HEADER_SEARCH_PATHS and add our paths
    # Pattern: HEADER_SEARCH_PATHS = (...)
    pattern = r'(HEADER_SEARCH_PATHS = \(\s*)'
    
    def add_paths(match):
        return match.group(1) + f'\n\t\t\t\t\t\t\t{opencv_header},\n\t\t\t\t\t\t\t{ncnn_header},'
    
    new_content = re.sub(pattern, add_paths, content)
    
    if new_content != content:
        content = new_content
        print("✓ Added OpenCV and NCNN header paths")
    else:
        print("⚠️  Could not find HEADER_SEARCH_PATHS to modify")

# Check library search paths
if 'WebDriverAgentLib/Vendor' not in content:
    pattern = r'(LIBRARY_SEARCH_PATHS = \(\s*)'
    
    def add_lib_paths(match):
        return match.group(1) + f'\n\t\t\t\t\t\t\t{opencv_lib},'
    
    new_content = re.sub(pattern, add_lib_paths, content)
    
    if new_content != content:
        content = new_content
        print("✓ Added library search paths")

# Check framework search paths
if 'WebDriverAgentLib/Vendor' not in content or 'FRAMEWORK_SEARCH_PATHS' not in content:
    pattern = r'(FRAMEWORK_SEARCH_PATHS = \(\s*)'
    
    def add_fw_paths(match):
        return match.group(1) + f'\n\t\t\t\t\t\t\t{opencv_lib},'
    
    new_content = re.sub(pattern, add_fw_paths, content)
    
    if new_content != content:
        content = new_content
        print("✓ Added framework search paths")

# Also need to add OTHER_LDFLAGS for linking opencv2 and ncnn
# Find OTHER_LDFLAGS and add -lopencv2 -lncnn
if '-lopencv2' not in content:
    # Find lines with OTHER_LDFLAGS = "";  and replace with proper flags
    content = re.sub(
        r'OTHER_LDFLAGS = "";',
        'OTHER_LDFLAGS = (\n\t\t\t\t\t"-lopencv2",\n\t\t\t\t\t"-lncnn",\n\t\t\t\t\t"-lc++",\n\t\t\t\t);',
        content
    )
    print("✓ Added linker flags for opencv2 and ncnn")

# Write back
with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print("\n✓ Project updated!")
