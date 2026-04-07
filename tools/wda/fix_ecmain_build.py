#!/usr/bin/env python3
"""
Fix ECMAIN build errors - remove Info.plist and entitlements from Copy Bundle Resources
"""
from pbxproj import XcodeProject

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

print("Loading project...")
project = XcodeProject.load(PROJECT_PATH)

# Find and remove Info.plist and entitlements from build phases
files_to_remove = ['Info.plist', 'ECMAIN.entitlements']

print("Removing problematic files from build phases...")
for file_name in files_to_remove:
    try:
        # Get files by name
        files = project.get_files_by_name(file_name)
        for f in files:
            # Remove from all targets' build phases
            project.remove_file_by_id(f.get_id())
            print(f"  ✓ Removed {file_name} from project")
    except Exception as e:
        print(f"  Note ({file_name}): {e}")

project.save()
print("\n✓ Project fixed!")
print("\nNow rebuild in Xcode (⌘B)")
