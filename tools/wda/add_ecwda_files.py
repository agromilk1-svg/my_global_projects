from pbxproj import XcodeProject
import sys

try:
    print("Loading project...")
    project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')
    
    # --- 1. WebDriverAgentLib Targets (Original Logic) ---
    groups = project.get_groups_by_name('Commands')
    if groups:
        parent_group = groups[0]
        file_m = 'WebDriverAgentLib/Commands/FBECWDACommands.m'
        file_h = 'WebDriverAgentLib/Commands/FBECWDACommands.h'
        target_name = 'WebDriverAgentLib'
        print(f"Adding {file_m} to target {target_name}...")
        project.add_file(file_m, parent=parent_group, target_name=target_name, force=False)
        project.add_file(file_h, parent=parent_group, force=False)
    else:
        print("Warning: Could not find 'Commands' group under WebDriverAgentLib.")

    # --- 2. WebDriverAgentRunner Targets (Standalone Logic) ---
    runner_groups = project.get_groups_by_name('WebDriverAgentRunner')
    if runner_groups:
        runner_group = runner_groups[0]
        standalone_files = [
            'WebDriverAgentRunner/FBStandaloneAppDelegate.h',
            'WebDriverAgentRunner/FBStandaloneAppDelegate.m',
            'WebDriverAgentRunner/main.m'
        ]
        target_name = 'WebDriverAgentRunner'
        for f in standalone_files:
            print(f"Adding {f} to target {target_name}...")
            # Note: headers don't need to be in the compile sources phase
            if f.endswith('.m'):
                project.add_file(f, parent=runner_group, target_name=target_name, force=False)
            else:
                project.add_file(f, parent=runner_group, force=False)
    else:
        print("Error: Could not find 'WebDriverAgentRunner' group.")
        sys.exit(1)
    
    # 3. Save
    print("Saving project...")
    project.save()
    print("Done! All files added successfully.")

except Exception as e:
    print(f"An error occurred: {e}")
    sys.exit(1)
