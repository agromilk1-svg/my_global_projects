from pbxproj import XcodeProject
import os
import sys

def get_disk_files(root_dirs):
    disk_files = set()
    for root_dir in root_dirs:
        for root, dirs, files in os.walk(root_dir):
            if 'Pods' in root: continue
            for file in files:
                if file.endswith(('.h', '.m', '.c', '.swift')):
                    # Store relative path
                    rel_path = os.path.join(root, file)
                    disk_files.add(rel_path)
    return disk_files

def get_project_files(project_path):
    try:
        project = XcodeProject.load(project_path)
        # Getting all file references is tricky with pbxproj sometimes, 
        # but we can iterate over all file objects.
        project_files = set()
        for file in project.objects.get_objects_in_section('PBXFileReference'):
            # path can be None or relative
            path = file.get('path')
            if path and (path.endswith('.h') or path.endswith('.m') or path.endswith('.c') or path.endswith('.swift')):
                # This is a simplification. The path in PBXFileReference might be relative to a group, 
                # but often for source files it's close enough or we can try to match by filename if distinct.
                # However, for a robust check, let's just collect filenames.
                # For a more accurate check, we'd need to resolve paths from groups, which is complex.
                # Let's start by just checking if the file *name* is known.
                project_files.add(os.path.basename(path))
        return project_files
    except Exception as e:
        print(f"Error loading project: {e}")
        return set()

def main():
    root_dirs = ['WebDriverAgentLib', 'WebDriverAgentRunner']
    disk_files = get_disk_files(root_dirs)
    
    project_path = 'WebDriverAgent.xcodeproj/project.pbxproj'
    project = XcodeProject.load(project_path)
    
    # Let's try a different approach: verify if file paths on disk are present in the project
    # Pbxproj's `get_files_by_path` might be useful
    
    missing_files = []
    
    for file_path in disk_files:
        # Check if this exact path is in the project
        # Note: Project might store it as "Commands/FBECWDACommands.m" if it's in a group "Commands"
        # We need to be careful.
        
        # Simple heuristic: Check if the filename exists in the project.
        # This assumes no duplicate filenames across folders (which is generally good practice in ObjC)
        filename = os.path.basename(file_path)
        found = False
        
        # We search for any file reference with this name
        files = project.get_files_by_name(filename)
        if files:
            found = True
        
        if not found:
            missing_files.append(file_path)

    if missing_files:
        print("MISSING_FILES_START")
        for f in missing_files:
            print(f)
        print("MISSING_FILES_END")
    else:
        print("No missing files found.")

if __name__ == "__main__":
    main()
