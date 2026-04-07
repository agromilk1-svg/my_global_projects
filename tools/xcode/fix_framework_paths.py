#!/usr/bin/env python3
"""
Fix OpenCV and NCNN framework paths for proper header resolution.

For #import <opencv2/imgcodecs/ios.h> to work:
1. FRAMEWORK_SEARCH_PATHS must include $(SRCROOT)/WebDriverAgentLib/Vendor
2. Frameworks need to be linked properly

This script modifies the project.pbxproj to add the correct paths.
"""
import re

PROJECT = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

with open(PROJECT, 'r') as f:
    content = f.read()

# We need to add Vendor to FRAMEWORK_SEARCH_PATHS for each build config
# Pattern to find buildSettings blocks for WebDriverAgentLib
framework_path = '"$(SRCROOT)/WebDriverAgentLib/Vendor"'

changes_made = 0

# Strategy: Find all FRAMEWORK_SEARCH_PATHS and add our path if not present
if framework_path not in content:
    # Add to existing FRAMEWORK_SEARCH_PATHS
    pattern = r'(FRAMEWORK_SEARCH_PATHS = \(\s*"\$\(inherited\)")'
    replacement = r'\1,\n\t\t\t\t\t\t\t"$(SRCROOT)/WebDriverAgentLib/Vendor"'
    new_content = re.sub(pattern, replacement, content)
    if new_content != content:
        content = new_content
        changes_made += 1
        print("✓ Added Vendor to FRAMEWORK_SEARCH_PATHS (inherited)")

    # Also handle case where FRAMEWORK_SEARCH_PATHS has explicit paths
    pattern = r'(FRAMEWORK_SEARCH_PATHS = \(\s*\n\s*)("\$\(inherited\)",)'
    replacement = r'\1\2\n\t\t\t\t\t\t\t"$(SRCROOT)/WebDriverAgentLib/Vendor",'
    new_content = re.sub(pattern, replacement, content)
    if new_content != content:
        content = new_content
        changes_made += 1
        print("✓ Added Vendor to FRAMEWORK_SEARCH_PATHS (multiline)")

# Also check HEADER_SEARCH_PATHS - we need the Headers directories
# For #import <opencv2/...>, we need the path where 'opencv2' folder exists
# Since opencv2.framework/Headers contains the headers, and we import as <opencv2/...>
# We need to create a symlink or add the right path

# The framework structure is:
# opencv2.framework/Headers/imgcodecs/ios.h
# For #import <opencv2/imgcodecs/ios.h> to work, clang needs to know:
# -F path/to/Vendor (for framework lookup)
# or
# -I path/that/contains/opencv2 (for header lookup)

# Since opencv2.framework is a framework, the standard way is to use -F
# But since we're importing with angle brackets, we can also use header search paths

# Let's create a proper include structure by adding a symlink
import os
import subprocess

vendor_path = '/Users/hh/Desktop/my/WebDriverAgentLib/Vendor'
opencv2_header_link = os.path.join(vendor_path, 'opencv2')
opencv2_headers = os.path.join(vendor_path, 'opencv2.framework', 'Headers')

if not os.path.exists(opencv2_header_link):
    try:
        os.symlink(opencv2_headers, opencv2_header_link)
        print(f"✓ Created symlink: opencv2 -> opencv2.framework/Headers")
        changes_made += 1
    except Exception as e:
        print(f"⚠️ Could not create symlink: {e}")
else:
    print("✓ opencv2 symlink already exists")

# Same for ncnn
ncnn_header_link = os.path.join(vendor_path, 'ncnn')
ncnn_headers = os.path.join(vendor_path, 'ncnn.framework', 'Headers')

if not os.path.exists(ncnn_header_link):
    try:
        os.symlink(ncnn_headers, ncnn_header_link)
        print(f"✓ Created symlink: ncnn -> ncnn.framework/Headers")
        changes_made += 1
    except Exception as e:
        print(f"⚠️ Could not create symlink: {e}")
else:
    print("✓ ncnn symlink already exists")

# Now add Vendor to HEADER_SEARCH_PATHS
header_path = '"$(SRCROOT)/WebDriverAgentLib/Vendor"'
if header_path not in content:
    # Add to HEADER_SEARCH_PATHS after $(inherited)
    pattern = r'(HEADER_SEARCH_PATHS = \(\s*"\$\(inherited\)")'
    replacement = r'\1,\n\t\t\t\t\t\t\t"$(SRCROOT)/WebDriverAgentLib/Vendor"'
    new_content = re.sub(pattern, replacement, content)
    if new_content != content:
        content = new_content
        changes_made += 1
        print("✓ Added Vendor to HEADER_SEARCH_PATHS")

# Write back
with open(PROJECT, 'w') as f:
    f.write(content)

print(f"\n✓ Done! Made {changes_made} changes.")
