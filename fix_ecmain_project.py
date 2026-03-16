#!/usr/bin/env python3
"""
Fix ECMAIN Xcode project by adding missing files
"""
from pbxproj import XcodeProject
import os

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

# Files to add - relative to project root
files_to_add = [
    {'path': 'ECMAIN/ECMAIN/UI/ECAppDetailsViewController.h', 'group': 'UI'},
    {'path': 'ECMAIN/ECMAIN/UI/ECAppDetailsViewController.m', 'group': 'UI'},
    {'path': 'ECMAIN/ECMAIN/Core/ECDeviceInfoManager.h', 'group': 'Core'},
    {'path': 'ECMAIN/ECMAIN/Core/ECDeviceInfoManager.m', 'group': 'Core'},
    {'path': 'ECMAIN/ECMAIN/UI/ECDeviceInfoViewController.h', 'group': 'UI'},
    {'path': 'ECMAIN/ECMAIN/UI/ECDeviceInfoViewController.m', 'group': 'UI'},
]

print("Loading ECMAIN project...")
project = XcodeProject.load(PROJECT_PATH)

for file_info in files_to_add:
    file_path = file_info['path']
    # Calculate correct path relative to Xcode Project Root
    # Input path: ECMAIN/ECMAIN/UI/...
    # Expected Xcode path: ECMAIN/UI/... (relative to ECMAIN/)
    # But wait, input path relative to CWD is ECMAIN/ECMAIN/UI...
    
    # Let's clean this up.
    # Logic:
    # 1. full_path = os.path.join(CWD, file_path)
    # 2. xcode_path = file_path.replace('ECMAIN/ECMAIN/', 'ECMAIN/') # Crude but works for this structure
    
    # Actually, better:
    # The file path in the list IS the one relative to CWD: ECMAIN/ECMAIN/UI/...
    
    group_name = file_info['group']
    file_name = os.path.basename(file_path)
    
    # Check if file exists on disk
    full_path = os.path.join('/Users/hh/Desktop/my', file_path)
    if not os.path.exists(full_path):
        print(f"⚠️  File {file_name} does not exist on disk (at {full_path}), skipping...")
        continue
        
    # Correct path for Xcode (relative to project root which is .../ECMAIN)
    # So we want 'ECMAIN/UI/...'
    xcode_rel_path = file_path.replace('ECMAIN/ECMAIN/', 'ECMAIN/')
    
    # Check if file already in project
    existing = project.get_files_by_name(file_name)
    if existing:
        print(f"✓ File {file_name} already in project")
        # Removing just in case it was added with wrong path before?
        # project.remove_file_by_id(existing[0].get_id())
        # Let's not complicate. If it's there, assume correct? 
        # But my previous run added it with WRONG path. So I MUST remove it if path is wrong.
        # Simple fix: Let's assume user manually fixes or we overwrite? pbxproj library doesn't easily update path.
        # Let's try to add it again, maybe it adds a duplicate or updates?
        # Actually, let's remove existing references first to be safe.
        for e in existing:
             project.remove_file_by_id(e.get_id())
        print(f"  (Removed existing reference to re-add correctly)")

    # Add file to project with proper group
    try:
        parent_group = project.get_or_create_group(group_name, 'ECMAIN') 
        
        added = project.add_file(
            xcode_rel_path,
            parent=parent_group,
            force=False,
            target_name='ECMAIN' 
        )
        if added:
            print(f"✓ Added {file_name} to project")
        else:
            print(f"⚠️  Could not add {file_name}")
    except Exception as e:
        print(f"✗ Error adding {file_name}: {e}")

project.save()
print("\n✓ Project saved!")
