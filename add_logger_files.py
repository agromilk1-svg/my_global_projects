from pbxproj import XcodeProject
import sys
import os

def add_file_to_project(project, file_path, target_name='WebDriverAgentLib'):
    # file_path: e.g. 'WebDriverAgentLib/Utilities/FBFileLogger.m'
    
    dir_name = os.path.basename(os.path.dirname(file_path)) # Utilities
    group_name = dir_name 
    
    print(f"Processing {file_path} (Target Group: {group_name})...")
    
    # Find the Utilities group
    groups = project.get_groups_by_name(group_name)
    if not groups:
        print(f"  Error: Group '{group_name}' not found. Please ensure it exists.")
        return False
        
    parent_group = groups[0]
    
    try:
        # Check if file is already in project to avoid duplicates (pbxproj handles this but good to be safe)
        # Using add_file is usually idempotent enough for this library
        
        # Add to target only if it's a source file
        if file_path.endswith('.m') or file_path.endswith('.mm') or file_path.endswith('.c'):
             # force=False prevents duplication if already exists
            project.add_file(file_path, parent=parent_group, target_name=target_name, force=False)
        else:
            project.add_file(file_path, parent=parent_group, force=False)
            
        print(f"  Successfully added/verified {file_path}")
        return True
    except Exception as e:
        print(f"  Error adding {file_path}: {e}")
        return False

def main():
    files_to_add = [
        'WebDriverAgentLib/Utilities/FBFileLogger.h',
        'WebDriverAgentLib/Utilities/FBFileLogger.m'
    ]
    
    project_path = 'WebDriverAgent.xcodeproj/project.pbxproj'
    
    try:
        print(f"Loading project {project_path} ...")
        project = XcodeProject.load(project_path)
        
        count = 0
        for f in files_to_add:
            if add_file_to_project(project, f):
                count += 1
        
        if count > 0:
            print("Saving project...")
            project.save()
            print("Done. Project updated.")
        else:
            print("No changes needed.")
            
    except Exception as e:
        print(f"An error occurred: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main()
