import sys
import uuid

def generate_id():
    return uuid.uuid4().hex[:24].upper()

project_path = "/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj"

with open(project_path, 'r') as f:
    content = f.read()

if "ECLogManager.m" in content:
    print("ECLogManager already in project")
    sys.exit(0)

# IDs
id_h_ref = generate_id()
id_m_ref = generate_id()
id_m_build = generate_id()

# Templates based on ECScriptParser
# 1. PBXBuildFile
# 959294DFEF78403ABD9A21F7 /* ECScriptParser.m in Sources */ = {isa = PBXBuildFile; fileRef = 9DD1B2E1B3D342D4970FCEB2 /* ECScriptParser.m */; };
# We need to find the section and insert.
build_file_section_marker = "/* Begin PBXBuildFile section */"
build_file_entry = f'\t\t{id_m_build} /* ECLogManager.m in Sources */ = {{isa = PBXBuildFile; fileRef = {id_m_ref} /* ECLogManager.m */; }};'

# 2. PBXFileReference
# 06D47D49E5D7471F855FF11E /* ECScriptParser.h */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = ECLogManager.h; sourceTree = "<group>"; };
# 9DD1B2E1B3D342D4970FCEB2 /* ECScriptParser.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = ECLogManager.m; sourceTree = "<group>"; };
file_ref_section_marker = "/* Begin PBXFileReference section */"
file_ref_h = f'\t\t{id_h_ref} /* ECLogManager.h */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; path = ECLogManager.h; sourceTree = "<group>"; }};'
file_ref_m = f'\t\t{id_m_ref} /* ECLogManager.m */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = ECLogManager.m; sourceTree = "<group>"; }};'

# 3. PBXGroup (children)
# Find group containing ECScriptParser.m
# 9DD1B2E1B3D342D4970FCEB2 /* ECScriptParser.m */,
# Depending on how the file is formatted, regex or exact match.
# The grep showed standard formatting with tabs/spaces.
# We'll rely on the comment suffix.

# 4. PBXSourcesBuildPhase
# 959294DFEF78403ABD9A21F7 /* ECScriptParser.m in Sources */,

source_entry = f'\t\t\t\t{id_m_build} /* ECLogManager.m in Sources */,'
group_entry_h = f'\t\t\t\t{id_h_ref} /* ECLogManager.h */,'
group_entry_m = f'\t\t\t\t{id_m_ref} /* ECLogManager.m */,'


# Injection logic
new_content = content

# Inject BuildFile
if build_file_section_marker in new_content:
    new_content = new_content.replace(build_file_section_marker, build_file_section_marker + '\n' + build_file_entry)
else:
    print("Could not find PBXBuildFile section")
    sys.exit(1)

# Inject FileRef
if file_ref_section_marker in new_content:
    new_content = new_content.replace(file_ref_section_marker, file_ref_section_marker + '\n' + file_ref_h + '\n' + file_ref_m)
else:
    print("Could not find PBXFileReference section")
    sys.exit(1)

# Inject into Group
# We look for ECScriptParser.m in children list
# The line in file looks like: \t\t\t\tUUID /* ECScriptParser.m */,
# We search for " /* ECScriptParser.m */,"
if "/* ECScriptParser.m */," in new_content:
    new_content = new_content.replace("/* ECScriptParser.m */,", "/* ECScriptParser.m */,\n" + group_entry_h + '\n' + group_entry_m)
else:
    print("Could not find ECScriptParser.m in group")
    sys.exit(1)

# Inject into Sources
if "/* ECScriptParser.m in Sources */," in new_content:
    new_content = new_content.replace("/* ECScriptParser.m in Sources */,", "/* ECScriptParser.m in Sources */,\n" + source_entry)
else:
    print("Could not find ECScriptParser.m in Sources")
    sys.exit(1)

with open(project_path, 'w') as f:
    f.write(new_content)

print("Modified project.pbxproj successfully")
