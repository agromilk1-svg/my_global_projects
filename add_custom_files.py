#!/usr/bin/env python3
"""
Add custom files to Xcode project using parent group ID to avoid wrong group selection.
"""
from pbxproj import XcodeProject
import os

def main():
    print("Loading project...")
    project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')
    
    # Get the specific groups by their IDs
    # EE9AB73E1CAEDF0C008C271F = WebDriverAgentLib/Categories
    # EE9AB74F1CAEDF0C008C271F = WebDriverAgentLib/Commands
    # EE9AB78E1CAEDF0C008C271F = WebDriverAgentLib/Utilities
    
    files_to_add = [
        ('WebDriverAgentLib/Commands/FBECWDACommands.h', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Commands/FBECWDACommands.m', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Utilities/FBWebServerParams.h', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Utilities/FBWebServerParams.m', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Categories/XCUIApplication+FBFocused.h', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Categories/XCUIApplication+FBFocused.m', 'WebDriverAgentLib'),
    ]
    
    for file_path, target_name in files_to_add:
        if os.path.exists(file_path):
            basename = os.path.basename(file_path)
            existing = project.get_files_by_name(basename)
            if existing:
                print(f"  {basename} already exists, skipping...")
                continue
            
            # Add to target directly, pbxproj will place in appropriate group
            project.add_file(file_path, target_name=target_name)
            print(f"  Added {basename}")
        else:
            print(f"  WARNING: File not found: {file_path}")
    
    print("Saving project...")
    project.save()
    print("Done!")

if __name__ == "__main__":
    main()
