#!/usr/bin/env python3
import sys

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

with open(PROJECT_PATH, 'r') as f:
    lines = f.readlines()

print(f"Checking {len(lines)} lines...")

found_header = False
found_cpp = False
unsafe_count = 0

for i, line in enumerate(lines):
    if 'HEADER_SEARCH_PATHS' in line:
        print(f"Line {i}: {line.strip()}")
        found_header = True
        # Print next few lines to see the value
        for j in range(1, 6):
            if i+j < len(lines):
                print(f"  +{j}: {lines[i+j].strip()}")
                
    if 'CLANG_CXX_LANGUAGE_STANDARD' in line:
        print(f"Line {i}: {line.strip()}")
        found_cpp = True

    if '/usr/local/include' in line:
        print(f"!!! FOUND UNSAFE PATH at Line {i}: {line.strip()}")
        unsafe_count += 1

if not found_header:
    print("WARNING: No HEADER_SEARCH_PATHS found!")

if not found_cpp:
    print("WARNING: No CLANG_CXX_LANGUAGE_STANDARD found!")
    
if unsafe_count == 0:
    print("No explicit /usr/local/include found.")
