#!/usr/bin/env python3
import re
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# 1. Remove /usr/local/include from HEADER_SEARCH_PATHS
# This causes the "unsafe for cross-compilation" error
# We'll use a specific regex to find and remove this line specifically within HEADER_SEARCH_PATHS blocks

# This pattern looks for "/usr/local/include" inside quotes or not, potentially with trailing comma
# It's safer to read line by line for this specific removal to avoid messing up the structure

lines = content.split('\n')
new_lines = []
in_header_paths = False
removed_count = 0

for line in lines:
    clean_line = line.strip()
    
    # Check if we are entering a HEADER_SEARCH_PATHS block
    if 'HEADER_SEARCH_PATHS = (' in clean_line:
        in_header_paths = True
        new_lines.append(line)
        continue
    
    # Check if we are exiting the block
    if in_header_paths and clean_line.startswith(');'):
        in_header_paths = False
        new_lines.append(line)
        continue
        
    # If we are inside, check for the bad path
    if in_header_paths:
        if '/usr/local/include' in clean_line:
            print(f"Removing unsafe path: {clean_line}")
            removed_count += 1
            if ',' not in clean_line and len(new_lines) > 0 and new_lines[-1].strip().endswith(','):
                # If we removed the last item, we might need to fix the comma of the previous item
                # But usually lists in pbxproj have commas on all items or it's fine.
                # Let's just skip adding this line.
                pass
            continue
            
    # Keep the line
    new_lines.append(line)

content = '\n'.join(new_lines)

# 2. Fix Double Quote Issue in Framework Search Paths if any
# Sometimes paths get messed up.
# Let's ensure our Vendor path is correct
# "$(SRCROOT)/WebDriverAgentLib/Vendor" is what we want.

if '"$(SRCROOT)/WebDriverAgentLib/Vendor"' not in content and '$(SRCROOT)/WebDriverAgentLib/Vendor' not in content:
    print("Warning: Vendor path might be missing from Framework Search Paths")

# Write back
with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print(f"Fixed project! Removed {removed_count} unsafe include paths.")
print("Starting cleanup...")
