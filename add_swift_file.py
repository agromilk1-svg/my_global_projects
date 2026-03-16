#!/usr/bin/env python3
"""
Add SwiftBridge.swift to the Xcode project to force Swift runtime embedding.
"""

import uuid

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

def generate_id():
    """Generate a 24-character hex ID like Xcode uses"""
    return uuid.uuid4().hex[:24].upper()

def add_swift_file():
    with open(PROJECT_PATH, 'r') as f:
        content = f.read()
    
    # Check if SwiftBridge.swift is already in the project
    if 'SwiftBridge.swift' in content:
        print("SwiftBridge.swift is already in the project.")
        return
    
    # Generate unique IDs
    file_ref_id = generate_id()
    build_file_id_lib = generate_id()
    build_file_id_runner = generate_id()
    
    # 1. Add PBXFileReference
    file_ref_entry = f'\t\t{file_ref_id} /* SwiftBridge.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SwiftBridge.swift; sourceTree = "<group>"; }};\n'
    
    # Find PBXFileReference section and add our entry
    marker = '/* Begin PBXFileReference section */\n'
    pos = content.find(marker)
    if pos >= 0:
        insert_pos = pos + len(marker)
        content = content[:insert_pos] + file_ref_entry + content[insert_pos:]
    
    # 2. Add PBXBuildFile for both targets
    build_file_lib = f'\t\t{build_file_id_lib} /* SwiftBridge.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* SwiftBridge.swift */; }};\n'
    build_file_runner = f'\t\t{build_file_id_runner} /* SwiftBridge.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_id} /* SwiftBridge.swift */; }};\n'
    
    marker = '/* Begin PBXBuildFile section */\n'
    pos = content.find(marker)
    if pos >= 0:
        insert_pos = pos + len(marker)
        content = content[:insert_pos] + build_file_lib + build_file_runner + content[insert_pos:]
    
    # 3. Add file to Utilities group
    # Find a line with FBOCREngine.h in a children list and add after it
    search_str = '/* FBOCREngine.h */,'
    pos = content.find(search_str)
    if pos >= 0:
        insert_pos = pos + len(search_str)
        content = content[:insert_pos] + f'\n\t\t\t\t{file_ref_id} /* SwiftBridge.swift */,' + content[insert_pos:]
    
    # 4. Add to Sources build phases
    # Find lines with FBOCREngine.mm in Sources and add after them
    search_str = '/* FBOCREngine.mm in Sources */,'
    count = 0
    start = 0
    while count < 2:
        pos = content.find(search_str, start)
        if pos < 0:
            break
        insert_pos = pos + len(search_str)
        if count == 0:
            new_entry = f'\n\t\t\t\t{build_file_id_lib} /* SwiftBridge.swift in Sources */,'
        else:
            new_entry = f'\n\t\t\t\t{build_file_id_runner} /* SwiftBridge.swift in Sources */,'
        content = content[:insert_pos] + new_entry + content[insert_pos:]
        start = insert_pos + len(new_entry)
        count += 1
    
    with open(PROJECT_PATH, 'w') as f:
        f.write(content)
    
    print(f"Added SwiftBridge.swift to project with file ref ID: {file_ref_id}")
    print("Swift runtime libraries will now be embedded when building.")

if __name__ == '__main__':
    add_swift_file()

