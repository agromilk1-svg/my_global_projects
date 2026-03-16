#!/usr/bin/env python3
"""
Repair Xcode project by:
1. Restoring from original WDA project.pbxproj
2. Cleanly adding custom ECWDA files
"""
from pbxproj import XcodeProject
import os
import shutil

def main():
    print("=" * 60)
    print("XCODE PROJECT REPAIR SCRIPT")
    print("=" * 60)
    
    # Backup current project
    print("\n1. Backing up current project.pbxproj...")
    shutil.copy(
        'WebDriverAgent.xcodeproj/project.pbxproj',
        'WebDriverAgent.xcodeproj/project.pbxproj.corrupted'
    )
    print("   Backup saved to project.pbxproj.corrupted")
    
    # Restore from original
    print("\n2. Restoring from original WDA project.pbxproj...")
    shutil.copy(
        '/tmp/original_project.pbxproj',
        'WebDriverAgent.xcodeproj/project.pbxproj'
    )
    print("   Restored original project file")
    
    # Load project
    print("\n3. Loading project and adding custom files...")
    project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')
    
    # Custom files to add
    custom_files = [
        # (path, group_name, target_name)
        ('WebDriverAgentLib/Commands/FBECWDACommands.h', 'Commands', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Commands/FBECWDACommands.m', 'Commands', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Utilities/FBWebServerParams.h', 'Utilities', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Utilities/FBWebServerParams.m', 'Utilities', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Categories/XCUIApplication+FBFocused.h', 'Categories', 'WebDriverAgentLib'),
        ('WebDriverAgentLib/Categories/XCUIApplication+FBFocused.m', 'Categories', 'WebDriverAgentLib'),
    ]
    
    for file_path, group_name, target_name in custom_files:
        if os.path.exists(file_path):
            # Check if already exists
            basename = os.path.basename(file_path)
            existing = project.get_files_by_name(basename)
            if existing:
                print(f"   {basename} already exists, skipping...")
                continue
            
            # Find group
            groups = project.get_groups_by_name(group_name)
            if groups:
                # Use the one with the right path
                target_group = None
                for g in groups:
                    group_path = getattr(g, 'path', '')
                    if 'WebDriverAgentLib' in str(group_path) or group_name in ['Commands', 'Categories', 'Utilities', 'Routing']:
                        target_group = g
                        break
                if target_group is None:
                    target_group = groups[0]
                
                project.add_file(file_path, parent=target_group, target_name=target_name)
                print(f"   Added {basename} to {group_name}")
            else:
                print(f"   WARNING: Group '{group_name}' not found for {basename}")
        else:
            print(f"   WARNING: File not found: {file_path}")
    
    # Save project
    print("\n4. Saving project...")
    project.save()
    print("   Project saved successfully!")
    
    # Validate
    print("\n5. Validating project file...")
    import subprocess
    result = subprocess.run(['plutil', '-lint', 'WebDriverAgent.xcodeproj/project.pbxproj'], 
                          capture_output=True, text=True)
    print(f"   {result.stdout.strip()}")
    
    print("\n" + "=" * 60)
    print("REPAIR COMPLETE!")
    print("Please reopen the project in Xcode.")
    print("=" * 60)

if __name__ == "__main__":
    main()
