#!/usr/bin/env python3
import os
import sys
from pbxproj import XcodeProject
from pbxproj.pbxextensions.ProjectFiles import FileOptions

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'
SOURCE_ROOT = '/Users/hh/Desktop/my/ECMAIN'

def main():
    print(f"Loading project: {PROJECT_PATH}")
    try:
        project = XcodeProject.load(PROJECT_PATH)
    except Exception as e:
        print(f"Error loading project: {e}")
        return

    # 1. Create main ECMAIN Group
    print("Creating ECMAIN group...")
    main_group = project.get_or_create_group('ECMAIN')

    # 2. Walk and add files
    target_name = 'WebDriverAgentRunner' # Add to the existing runner target for now
    
    files_to_add = []
    for root, dirs, files in os.walk(SOURCE_ROOT):
        # Skip the xcodeproj directory itself
        if 'ECMAIN.xcodeproj' in root:
            continue
            
        for file in files:
            if file.endswith(('.h', '.m', '.c', '.cpp', '.mm')):
                full_path = os.path.join(root, file)
                # Make path relative to where project file expects (usually project root)
                # Since project is in ECMAIN/ECMAIN.xcodeproj, and sources are in ECMAIN/
                # We need to be careful.
                # Actually, simply adding absolute paths is safer for this hack, 
                # or relative to the project folder.
                # The project is at /Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj
                # The files are at /Users/hh/Desktop/my/ECMAIN/...
                # So relative path is "../filename"
                
                rel_path = os.path.relpath(full_path, os.path.dirname(PROJECT_PATH))
                files_to_add.append(rel_path)

    print(f"Found {len(files_to_add)} source files.")

    for path in files_to_add:
        try:
            # Add to the ECMAIN group
            # We use the 'Runner' target because that's the App target in WDA
            project.add_file(
                path, 
                parent=main_group, 
                target_name=target_name,
                force=False
            )
            print(f"Added: {os.path.basename(path)}")
        except Exception as e:
            print(f"Failed to add {path}: {e}")

    # 3. Rename Target (Best Effort)
    # Finding the target by name
    targets = project.objects.get_targets(target_name)
    if targets:
        t = targets[0]
        t.name = "ECMAIN"
        print(f"Renamed target {target_name} to ECMAIN")
        
        # Also try to update PRODUCT_NAME in build configurations
        build_config_list = project.objects[t.buildConfigurationList]
        if build_config_list:
            for config_id in build_config_list.buildConfigurations:
                config = project.objects[config_id]
                config.buildSettings['PRODUCT_NAME'] = "ECMAIN"
                config.buildSettings['INFOPLIST_FILE'] = "ECMAIN/Info.plist" # Point to new plist if we have one (WE DON'T YET, creating dummy)

            # Ensure appropriate frameworks are linked
            # (NetworkExtension etc need to be added manually or via capability usually)

    project.save()
    print("Project saved.")

if __name__ == "__main__":
    main()
