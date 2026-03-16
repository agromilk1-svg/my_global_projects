#!/usr/bin/env python3
import re
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

def clean_project_file():
    with open(PROJECT_PATH, 'r') as f:
        content = f.read()

    print(f"Original file size: {len(content)} bytes")

    # 1. REMOVE /usr/local/include
    # Use generic regex to find any line containing this path and remove it
    # We replace it with an empty string, but handle commas if needed
    
    # Regex for: "/usr/local/include" (with optional trailing comma and quotes)
    # matching: "*/usr/local/include*",
    pattern_unsafe = r'\s*"?[^"\n]*/usr/local/include"?,?'
    
    matches = re.findall(pattern_unsafe, content)
    if matches:
        print(f"Found {len(matches)} unsafe paths! Removing them...")
        for m in matches:
            print(f"  Removing: {m.strip()}")
            content = content.replace(m, '')
    else:
        print("No explicit '/usr/local/include' found in project file.")

    # 2. FORCE C++ Standard to GNU++14 (Fixes 'nullptr' warning)
    # Find CLANG_CXX_LANGUAGE_STANDARD = ...; and replace val
    pattern_std = r'CLANG_CXX_LANGUAGE_STANDARD = [^;]+;'
    content = re.sub(pattern_std, 'CLANG_CXX_LANGUAGE_STANDARD = "gnu++14";', content)
    print("Updated C++ Standard to gnu++14")
    
    # 3. FORCE ALWAYS_SEARCH_USER_PATHS = NO
    if 'ALWAYS_SEARCH_USER_PATHS = YES' in content:
        content = content.replace('ALWAYS_SEARCH_USER_PATHS = YES', 'ALWAYS_SEARCH_USER_PATHS = NO')
        print("Disabled ALWAYS_SEARCH_USER_PATHS")

    # 4. RESET HEADER_SEARCH_PATHS for all configurations
    # We want to replace existing blocks with a clean set of paths
    # This ensures we don't inherit garbage if we don't want to
    
    # Clean paths for WDA Lib/Runner
    clean_search_paths = """                                HEADER_SEARCH_PATHS = (
                                        "$(SDKROOT)/usr/include/libxml2",
                                        "$(SRCROOT)/WebDriverAgentLib/Utilities",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/ncnn.framework/Headers",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/openmp.framework/Headers",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/opencv2.framework/Headers",
                                        "$(SRCROOT)/Modules",
                                );"""
                                
    # Use a regex that captures the whole HEADER_SEARCH_PATHS = (...); block
    # Be careful not to match too much. PBXProj format is usually indented.
    # We look for the start, then match until );
    
    path_block_pattern = r'HEADER_SEARCH_PATHS = \([\s\S]*?\);'
    
    # We will replace ALL occurrences. This might affect UITestingUITests too, but that's what we want - consistency.
    # The paths provided are safe for all targets in this workspace.
    content = re.sub(path_block_pattern, clean_search_paths, content)
    print("Reset all HEADER_SEARCH_PATHS blocks to safe defaults")

    # 5. Fix LIBRARY_SEARCH_PATHS similarly
    clean_lib_paths = """                                LIBRARY_SEARCH_PATHS = (
                                        "$(inherited)",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor",
                                );"""
    lib_block_pattern = r'LIBRARY_SEARCH_PATHS = \([\s\S]*?\);'
    content = re.sub(lib_block_pattern, clean_lib_paths, content)
    print("Reset all LIBRARY_SEARCH_PATHS blocks")

    with open(PROJECT_PATH, 'w') as f:
        f.write(content)
    
    print("Project file saved.")

if __name__ == "__main__":
    clean_project_file()
