from pbxproj import XcodeProject
import sys

try:
    print("Loading project...")
    project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')
    
    # 1. Add the new .m file to Categories group
    file_m = 'WebDriverAgentLib/Categories/XCUIApplication+FBFocused.m'
    
    groups = project.get_groups_by_name('Categories')
    if groups:
        parent_group = groups[0]
        print(f"Adding {file_m} to target WebDriverAgentLib...")
        project.add_file(file_m, parent=parent_group, target_name='WebDriverAgentLib')
    else:
        print("Warning: Could not find 'Categories' group")
    
    # 2. Fix path references for previously added files
    files_to_fix = [
        'FBECWDACommands.m',
        'FBECWDACommands.h',
        'FBWebServerParams.h',
        'FBWebServerParams.m',
        'XCUIApplication+FBFocused.h',
        'XCUIApplication+FBFocused.m',
    ]
    
    for filename in files_to_fix:
        files = project.get_files_by_name(filename)
        for file_ref in files:
            if hasattr(file_ref, 'sourceTree') and file_ref.sourceTree == 'SOURCE_ROOT':
                print(f"Fixing path for {filename}...")
                file_ref.sourceTree = '<group>'
                file_ref.path = filename
    
    print("Saving project...")
    project.save()
    print("Done!")
    
except Exception as e:
    print(f"Error: {e}")
    sys.exit(1)
