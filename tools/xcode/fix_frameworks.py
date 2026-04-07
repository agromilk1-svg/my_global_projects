#!/usr/bin/env python3
"""
Fix ECMAIN framework embedding issue - system frameworks should not be embedded
"""
from pbxproj import XcodeProject

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

print("Loading project...")
project = XcodeProject.load(PROJECT_PATH)

# Remove the incorrectly added system frameworks
frameworks_to_remove = [
    'UIKit.framework',
    'AVFoundation.framework', 
    'NetworkExtension.framework',
    'Security.framework',
    'CoreFoundation.framework',
]

print("Removing embedded system frameworks...")
for fw in frameworks_to_remove:
    try:
        files = project.get_files_by_name(fw)
        for f in files:
            project.remove_file_by_id(f.get_id())
            print(f"  ✓ Removed {fw}")
    except Exception as e:
        print(f"  Note ({fw}): {e}")

project.save()
print("\n✓ Frameworks removed!")
print("\nSystem frameworks are automatically linked by Clang.")
print("No need to manually add UIKit, Foundation, etc.")
print("\nTry building again!")
