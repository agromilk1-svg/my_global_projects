#!/usr/bin/env python3
"""
Fix file group placement in Xcode project
Move files from root group to Utilities group
"""
import re

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# Files to move (their reference IDs)
files_to_move = [
    '4F2D4B16A3193B9C0F2335B0', # FBTouchMonitor.h
    'DE1943A0BD348866548C2841', # FBTouchMonitor.m  
    'B2B849D5A4EE62688F1C637C', # FBOCREngine.h
    'F7674E5797F54139512CD024', # FBOCREngine.mm
]

# Also OCR folder refs that shouldn't be at root
ocr_refs = [
    '103743CB990FD53882B9E8BD', # OCR
    '8C6D4C7FA0449BF50A7DC75D', # OCR
]

# Step 1: Remove these from the root group (around line 1639-1644)
# Find the root group children and remove these entries
for ref_id in files_to_move + ocr_refs:
    # Remove lines like: \t\t\t\t{ref_id} /* ... */,
    pattern = rf'\t+{ref_id} /\* [^*]+ \*/,\n'
    content = re.sub(pattern, '', content)

# Step 2: Add the file references to Utilities group
# Find the Utilities group and add to its children array
# Pattern: EE9AB78E1CAEDF0C008C271F /* Utilities */ = {
#            isa = PBXGroup;
#            children = (

# Find position after "children = (" in Utilities group
utilities_pattern = r'(EE9AB78E1CAEDF0C008C271F /\* Utilities \*/ = \{\s+isa = PBXGroup;\s+children = \()'

# Files to add (with comments)
new_entries = '''
				4F2D4B16A3193B9C0F2335B0 /* FBTouchMonitor.h */,
				DE1943A0BD348866548C2841 /* FBTouchMonitor.m */,
				B2B849D5A4EE62688F1C637C /* FBOCREngine.h */,
				F7674E5797F54139512CD024 /* FBOCREngine.mm */,'''

def add_to_utilities(match):
    return match.group(1) + new_entries

content = re.sub(utilities_pattern, add_to_utilities, content)

with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print("Files moved to Utilities group!")
print("Please close and reopen the project in Xcode.")
