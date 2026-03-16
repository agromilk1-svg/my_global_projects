from pbxproj import XcodeProject
import sys

try:
    print("Loading project...")
    project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')
    
    # 1. Find the 'Commands' group
    # We expect it to be under WebDriverAgentLib, but searching by name is usually sufficient if unique.
    groups = project.get_groups_by_name('Commands')
    if not groups:
        print("Error: Could not find 'Commands' group.")
        sys.exit(1)
    
    parent_group = groups[0]
    print(f"Found 'Commands' group: {parent_group.name} ({parent_group.get_id()})")

    # 2. Add files
    # Note: filenames are relative to the project root (where .xcodeproj is)
    file_m = 'WebDriverAgentLib/Commands/FBECWDACommands.m'
    file_h = 'WebDriverAgentLib/Commands/FBECWDACommands.h'
    
    target_name = 'WebDriverAgentLib'
    
    print(f"Adding {file_m} to target {target_name}...")
    project.add_file(file_m, parent=parent_group, target_name=target_name)
    
    print(f"Adding {file_h} to group...")
    project.add_file(file_h, parent=parent_group)
    
    # 3. Save
    print("Saving project...")
    project.save()
    print("Done! Files added successfully.")

except Exception as e:
    print(f"An error occurred: {e}")
    sys.exit(1)
