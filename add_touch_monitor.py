#!/usr/bin/env python3
"""Add FBTouchMonitor files to Xcode project"""
from pbxproj import XcodeProject

project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')

files_to_add = [
    ('WebDriverAgentLib/Utilities/FBTouchMonitor.h', 'WebDriverAgentLib'),
    ('WebDriverAgentLib/Utilities/FBTouchMonitor.m', 'WebDriverAgentLib'),
]

for file_path, target in files_to_add:
    import os
    if os.path.exists(file_path):
        basename = os.path.basename(file_path)
        existing = project.get_files_by_name(basename)
        if existing:
            print(f"  {basename} already exists, skipping...")
            continue
        project.add_file(file_path, target_name=target)
        print(f"  Added {basename}")
    else:
        print(f"  WARNING: File not found: {file_path}")

project.save()
print("Done!")
