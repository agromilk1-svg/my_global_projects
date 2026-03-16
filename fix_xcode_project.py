#!/usr/bin/env python3
import re

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

def fix_project():
    with open(PROJECT_PATH, 'r') as f:
        content = f.read()

    # 1. Deduplicate files in Build Phases (Sources, Headers, etc.)
    # We look for sections like /* Begin PBXBuildFile section */ ... /* End PBXBuildFile section */
    # and inside PBXSourcesBuildPhase, PBXHeadersBuildPhase.
    # A simpler heuristic for project.pbxproj is to just look at the 'files = (...)' lists in build phases.
    
    # We will parse the file line by line to handle the nested structure safely-ish without full plist parsing
    lines = content.split('\n')
    new_lines = []
    
    in_build_phase = False
    seen_files_in_phase = set()
    
    for line in lines:
        # Detect start of a build phase files block
        if 'isa = PBXSourcesBuildPhase;' in line or 'isa = PBXHeadersBuildPhase;' in line or 'isa = PBXCopyFilesBuildPhase;' in line:
            in_build_phase = True
            seen_files_in_phase = set()
            new_lines.append(line)
            continue
            
        if in_build_phase:
            if 'files = (' in line:
                new_lines.append(line)
                continue
            if ');' in line:
                new_lines.append(line)
                in_build_phase = False # End of files block (mostly)
                # Actually build phases end with }; but the files block ends with );
                # We reset seen_files for safety, though technically we need to wait for the next phase start
                continue
            
            # This is a file reference line, e.g. "A48D... /* Foo.m in Sources */,"
            match = re.search(r'^\s*([A-Fa-f0-9]{24})\s*/\*', line)
            if match:
                file_id = match.group(1)
                # We also need to check the comment to see what file it is, 
                # because the same file ref might be added multiple times with different build file IDs?
                # Actually in PBXBuildFile section, each entry maps a file ref to a build file id.
                # In the BuildPhase 'files' list, it lists the BuildFile IDs.
                # If we have duplicate BuildFile IDs for the same underlying file, we need to remove them.
                # BUT, usually the duplicate warning comes from the SAME file reference being included multiple times in the list.
                
                # Let's extract the file name/comment to identify "duplicates"
                # A better approach is to track the content of the line itself if it's identical
                cleaned_line = line.strip()
                if cleaned_line in seen_files_in_phase:
                    print(f"Removing duplicate line: {cleaned_line}")
                    continue
                seen_files_in_phase.add(cleaned_line)
                new_lines.append(line)
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)

    content = '\n'.join(new_lines)
    
    # 2. Fix Missing Include Dirs Error
    # Xcode treats missing include dirs as errors if specific warnings are enabled.
    # We will perform a regex replace to add "WARNING_CFLAGS = ("-Wno-missing-include-dirs");" 
    # if it's not present, or append it to existing WARNING_CFLAGS.
    
    # Strategy: Find buildSettings blocks and ensure -Wno-missing-include-dirs is in WARNING_CFLAGS
    
    # Helper to insert into buildSettings
    def add_warning_flag(match):
        block = match.group(0)
        if 'WARNING_CFLAGS' in block:
            if '-Wno-missing-include-dirs' not in block:
                # Add it to existing list or string
                block = block.replace('WARNING_CFLAGS = "', 'WARNING_CFLAGS = "-Wno-missing-include-dirs ')
                block = block.replace('WARNING_CFLAGS = (', 'WARNING_CFLAGS = (\n\t\t\t\t\t"-Wno-missing-include-dirs",')
        else:
            # Add new entry. Try to put it after PRODUCT_NAME for consistency
            block = block.replace('};', '\t\t\t\tWARNING_CFLAGS = "-Wno-missing-include-dirs";\n\t\t\t};')
        return block

    # We apply this to all buildSettings blocks
    content = re.sub(r'buildSettings\s*=\s*\{[^}]+\};', add_warning_flag, content)

    # 3. Explicitly remove the specific bad paths if found
    # clang: error: no such include directory: '/Users/hh/Desktop/my/build/Build/Products/Debug-iphoneos/include'
    
    # We can try to remove these specific paths from HEADER_SEARCH_PATHS if they are hardcoded
    # But usually they are generated variables. 
    # The error "no such include directory" is suppressed by the flag above.
    
    with open(PROJECT_PATH, 'w') as f:
        f.write(content)
    print("Project cleaned up.")
    
    # 3. Add FRAMEWORK_SEARCH_PATHS
    # We need to ensure $(SRCROOT)/WebDriverAgentLib/Vendor is in FRAMEWORK_SEARCH_PATHS
    # for WebDriverAgentRunner target.
    # We will do a second pass text replace to keep it simple.
    
    with open(PROJECT_PATH, 'r') as f:
        content = f.read()
        
    def add_vendor_framework_path(match):
        block = match.group(0)
        if 'FRAMEWORK_SEARCH_PATHS' in block:
            if 'WebDriverAgentLib/Vendor' not in block:
                # Add it
                block = block.replace('FRAMEWORK_SEARCH_PATHS = (', 'FRAMEWORK_SEARCH_PATHS = (\n\t\t\t\t\t"$(SRCROOT)/WebDriverAgentLib/Vendor",')
                block = block.replace('FRAMEWORK_SEARCH_PATHS = "$(inherited)";', 'FRAMEWORK_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t"$(SRCROOT)/WebDriverAgentLib/Vendor",\n\t\t\t\t);')
        return block

    # We apply this to blocks that are likely for WebDriverAgentRunner.
    # A bit naive to apply to all, but safest for this "Vendor" deps.
    # Better to refine regex to target buildSettings that don't have it.
    
    content = re.sub(r'buildSettings\s*=\s*\{[^}]+\};', add_vendor_framework_path, content)
    
    # 4. Fix C++ Standard (Force C++17 and libc++)
    # OpenCV requires modern C++. Some targets are set to gnu++0x which is too old.
    
    def update_cpp_standard(match):
        block = match.group(0)
        # Update Language Standard
        if 'CLANG_CXX_LANGUAGE_STANDARD' in block:
            block = re.sub(r'CLANG_CXX_LANGUAGE_STANDARD = "[^"]+";', 'CLANG_CXX_LANGUAGE_STANDARD = "gnu++17";', block)
        else:
            block = block.replace('};', '\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++17";\n\t\t\t};')
            
        # Update Library
        if 'CLANG_CXX_LIBRARY' in block:
             block = re.sub(r'CLANG_CXX_LIBRARY = "[^"]+";', 'CLANG_CXX_LIBRARY = "libc++";', block)
        else:
             block = block.replace('};', '\t\t\t\tCLANG_CXX_LIBRARY = "libc++";\n\t\t\t};')
             
        return block

    content = re.sub(r'buildSettings\s*=\s*\{[^}]+\};', update_cpp_standard, content)

    with open(PROJECT_PATH, 'w') as f:
        f.write(content)
    print("C++ Standard updated to gnu++17.")

if __name__ == '__main__':
    fix_project()
