from pbxproj import XcodeProject
import sys
import os

def add_file_to_project(project, file_path, target_name='ECMAIN'):
    # file_path relative: e.g. 'ECMAIN/Core/ECBackgroundManager.m'
    
    dir_name = os.path.basename(os.path.dirname(file_path)) # Core
    group_name = dir_name 
    
    print(f"Processing {file_path} (Group: {group_name})...")
    
    groups = project.get_groups_by_name(group_name)
    parent_group = groups[0] if groups else None
    
    if not parent_group:
        print(f"  Warning: Group '{group_name}' not found. Creating it...")
        # Get main group to add new group to
        main_group = project.get_or_create_group('ECMAIN')
        parent_group = project.get_or_create_group(group_name, parent=main_group)

    try:
        if file_path.endswith('.m') or file_path.endswith('.mm') or file_path.endswith('.c'):
            project.add_file(file_path, parent=parent_group, target_name=target_name)
        else:
            project.add_file(file_path, parent=parent_group) 
        print(f"  Successfully added {file_path}")
        return True
    except Exception as e:
        print(f"  Error adding {file_path}: {e}")
        return False

def main():
    files_to_add = [
        'ECMAIN/Core/ECBackgroundManager.h',
        'ECMAIN/Core/ECBackgroundManager.m',
        'ECMAIN/silent.wav'
    ]
    
    try:
        print("Loading project...")
        project = XcodeProject.load('ECMAIN/ECMAIN.xcodeproj/project.pbxproj')
        
        count = 0
        for f in files_to_add:
            if add_file_to_project(project, f):
                count += 1
        
        if count > 0:
            print("Saving project...")
            project.save()
            print("Done.")
        else:
            print("No changes made.")
            
    except Exception as e:
        print(f"An error occurred: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
