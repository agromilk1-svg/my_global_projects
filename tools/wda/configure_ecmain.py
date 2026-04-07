#!/usr/bin/env python3
"""
Configure ECMAIN Xcode project with frameworks and entitlements
"""
from pbxproj import XcodeProject
import os

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

print("Loading project...")
project = XcodeProject.load(PROJECT_PATH)

# 1. Add entitlements file to project
print("Adding entitlements file...")
try:
    project.add_file('ECMAIN.entitlements', force=False)
    print("  ✓ Added ECMAIN.entitlements")
except Exception as e:
    print(f"  Note: {e}")

# 2. Add Info.plist to project
print("Adding Info.plist...")
try:
    project.add_file('Info.plist', force=False)
    print("  ✓ Added Info.plist")
except Exception as e:
    print(f"  Note: {e}")

# 3. Add system frameworks
frameworks = [
    'UIKit.framework',
    'AVFoundation.framework',
    'NetworkExtension.framework',
    'Security.framework',
    'CoreFoundation.framework',
]

print("Adding frameworks...")
for fw in frameworks:
    try:
        project.add_file(
            f'System/Library/Frameworks/{fw}',
            tree='SDKROOT',
            target_name='ECMAIN',
            force=False
        )
        print(f"  ✓ Added {fw}")
    except Exception as e:
        print(f"  Note ({fw}): {e}")

# 4. Update build settings
print("Updating build settings...")
for config in project.objects.get_configurations_on_targets(['ECMAIN']):
    config.buildSettings['CODE_SIGN_ENTITLEMENTS'] = 'ECMAIN.entitlements'
    config.buildSettings['INFOPLIST_FILE'] = 'Info.plist'
    config.buildSettings['ENABLE_HARDENED_RUNTIME'] = 'NO'
    config.buildSettings['CODE_SIGN_INJECT_BASE_ENTITLEMENTS'] = 'NO'
    print(f"  ✓ Updated {config.get('name', 'config')}")

project.save()
print("\n✓ Project saved successfully!")
print("\nNow open ECMAIN.xcodeproj in Xcode, select your Team, and Build.")
