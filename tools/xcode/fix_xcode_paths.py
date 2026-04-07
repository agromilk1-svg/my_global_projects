from pbxproj import XcodeProject
import sys

# Load the project
project = XcodeProject.load('WebDriverAgent.xcodeproj/project.pbxproj')

# Identify the files we want to fix
files_to_fix = ['FBECWDACommands.m', 'FBECWDACommands.h']

for filename in files_to_fix:
    # Get files by name
    files = project.get_files_by_name(filename)
    for file_ref in files:
        print(f"Fixing {filename}...")
        
        # Change sourceTree to "<group>"
        file_ref.sourceTree = '<group>'
        
        # Change path to just the filename (since the group 'Commands' already points to the dir)
        file_ref.path = filename
        
        print(f"  Updated to path={file_ref.path}, sourceTree={file_ref.sourceTree}")

project.save()
print("Project saved with fixed file references.")
