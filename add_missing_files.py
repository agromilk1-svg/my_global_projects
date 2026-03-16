from pbxproj import XcodeProject
import sys
import os

def add_file_to_project(project, file_path, target_name='WebDriverAgentLib'):
    # file_path e.g., 'WebDriverAgentLib/Utilities/FBWebServerParams.h'
    
    # Determine group name from directory structure
    # Valid groups in this project seem to flatly map to directory names under WebDriverAgentLib usually.
    # e.g. WebDriverAgentLib/Commands -> Group 'Commands'
    # WebDriverAgentLib/Utilities -> Group 'Utilities'
    # WebDriverAgentLib/Categories -> Group 'Categories'
    
    dir_name = os.path.basename(os.path.dirname(file_path))
    group_name = dir_name
    
    print(f"Processing {file_path} (Group: {group_name})...")
    
    groups = project.get_groups_by_name(group_name)
    if not groups:
        print(f"  Warning: Group '{group_name}' not found. Attempting to find parent group...")
        # Fallback: try to add to main group or create? For now let's just abort for this file or put in root.
        # But actually, 'Utilities' and 'Categories' should likely exist.
        # Let's list groups if fail.
        print(f"  Available groups: {[g.name for g in project.objects.get_objects_in_section('PBXGroup')]}")
        return False

    parent_group = groups[0]
    
    # Check if already added to avoid duplicates (though pbxproj handles some of this, let's be safe)
    # This check is basic; pbxproj's add_file usually handles it.
    
    try:
        if file_path.endswith('.m') or file_path.endswith('.c'):
            project.add_file(file_path, parent=parent_group, target_name=target_name)
        else:
            project.add_file(file_path, parent=parent_group) # Headers don't go into compile sources target usually, just the group
        print(f"  Successfully added {file_path}")
        return True
    except Exception as e:
        print(f"  Error adding {file_path}: {e}")
        return False

def main():
    files_to_add = [
        'WebDriverAgentLib/Utilities/FBWebServerParams.h',
        'WebDriverAgentLib/Utilities/FBWebServerParams.m',
        'WebDriverAgentLib/Categories/XCUIApplication+FBFocused.h'
    ]
    
    try:
        print("Loading project...")
        project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')
        
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
