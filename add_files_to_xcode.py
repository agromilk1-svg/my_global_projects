#!/usr/bin/env python3
"""
Add files to Xcode project properly (both compile sources AND group references)
"""
from pbxproj import XcodeProject
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

# Files to add - relative to project root
files_to_add = [
    # OCR Engine
    {'path': 'WebDriverAgentLib/Utilities/FBOCREngine.h', 'group': 'Utilities'},
    {'path': 'WebDriverAgentLib/Utilities/FBOCREngine.mm', 'group': 'Utilities'},
    # Touch Monitor
    {'path': 'WebDriverAgentLib/Utilities/FBTouchMonitor.h', 'group': 'Utilities'},
    {'path': 'WebDriverAgentLib/Utilities/FBTouchMonitor.m', 'group': 'Utilities'},
    # ECWDA Commands
    {'path': 'WebDriverAgentLib/Commands/FBECWDACommands.h', 'group': 'Commands'},
    {'path': 'WebDriverAgentLib/Commands/FBECWDACommands.m', 'group': 'Commands'},
]

print("Loading Xcode project...")
project = XcodeProject.load(PROJECT_PATH)

for file_info in files_to_add:
    file_path = file_info['path']
    group_name = file_info['group']
    file_name = os.path.basename(file_path)
    
    # Check if file exists on disk
    full_path = os.path.join('/Users/hh/Desktop/my', file_path)
    if not os.path.exists(full_path):
        print(f"⚠️  File {file_name} does not exist on disk, skipping...")
        continue
    
    # Check if file already in project
    existing = project.get_files_by_name(file_name)
    if existing:
        print(f"✓ File {file_name} already in project")
        continue
    
    # Add file to project with proper group
    try:
        parent_group = project.get_or_create_group(group_name, 'WebDriverAgentLib')
        added = project.add_file(
            file_path,
            parent=parent_group,
            force=False,
            target_name='WebDriverAgentLib'
        )
        if added:
            print(f"✓ Added {file_name} to project")
        else:
            print(f"⚠️  Could not add {file_name}")
    except Exception as e:
        print(f"✗ Error adding {file_name}: {e}")

project.save()
print("\n✓ Project saved!")
