import re
import uuid

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

# Files to add
TS_FILES_M = [
    'TSShim.m',
    'libroot_dyn.c',
    'TrollStoreIncludes.m',
    'TSAppInfo.m',
    'TSApplicationsManager.m',
    'TSInstallationController.m',
    'TSPresentationDelegate.m',
    'TSUtil.m'
]

TS_FILES_H = [
    'archive_entry.h',
    'archive.h',
    'libroot.h',
    'TSAppInfo.h',
    'TSApplicationsManager.h',
    'TSCommonTCCServiceNames.h',
    'TSCoreServices.h',
    'TSInstallationController.h',
    'TSPresentationDelegate.h',
    'TSUtil.h'
]

EC_FILES = [
    ('ECAppListViewController.m', 'UI') 
]

# Mapping
file_ref_ids = {}
build_file_ids = {}

def generate_id():
    return uuid.uuid4().hex[:24].upper()

def read_project():
    with open(PROJECT_PATH, 'r') as f:
        return f.read()

def write_project(content):
    with open(PROJECT_PATH, 'w') as f:
        f.write(content)

content = read_project()

# 1. Create IDs
for f in TS_FILES_M + TS_FILES_H:
    file_ref_ids[f] = generate_id()
    if f.endswith('.m') or f.endswith('.c'):
        build_file_ids[f] = generate_id()

for f, group in EC_FILES:
    file_ref_ids[f] = generate_id()
    build_file_ids[f] = generate_id()

# 2. Insert PBXBuildFile
# 		53DB547C32CC4D2DBC73AB37 /* ECLogManager.m in Sources */ = {isa = PBXBuildFile; fileRef = 12BC1EAB08844D69A05C7179 /* ECLogManager.m */; };

build_file_section_start = content.find('/* Begin PBXBuildFile section */')
insert_pos = content.find('\n', build_file_section_start) + 1

lines_to_insert = []
for f in TS_FILES_M:
    lines_to_insert.append(f'\t\t{build_file_ids[f]} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_ids[f]} /* {f} */; }};')
for f, group in EC_FILES:
    lines_to_insert.append(f'\t\t{build_file_ids[f]} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_ids[f]} /* {f} */; }};')

content = content[:insert_pos] + '\n'.join(lines_to_insert) + '\n' + content[insert_pos:]

# 3. Insert PBXFileReference
# 		12BC1EAB08844D69A05C7179 /* ECLogManager.m */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.c.objc; path = ECMAIN/Core/ECLogManager.m; sourceTree = SOURCE_ROOT; };

file_ref_section_start = content.find('/* Begin PBXFileReference section */')
insert_pos = content.find('\n', file_ref_section_start) + 1

lines_to_insert = []
for f in TS_FILES_M + TS_FILES_H:
    ftype = 'sourcecode.c.objc' if f.endswith('.m') else ('sourcecode.c.c' if f.endswith('.c') else 'sourcecode.c.h')
    lines_to_insert.append(f'\t\t{file_ref_ids[f]} /* {f} */ = {{isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = {ftype}; name = {f}; path = ECMAIN/TrollStoreCore/{f}; sourceTree = SOURCE_ROOT; }};')

for f, group in EC_FILES:
    lines_to_insert.append(f'\t\t{file_ref_ids[f]} /* {f} */ = {{isa = PBXFileReference; includeInIndex = 1; lastKnownFileType = sourcecode.c.objc; name = {f}; path = ECMAIN/{group}/{f}; sourceTree = SOURCE_ROOT; }};')

content = content[:insert_pos] + '\n'.join(lines_to_insert) + '\n' + content[insert_pos:]

# 4. Create TrollStoreCore PBXGroup and Add to Main Group
# We need to find the main group children list.
# 0D1301BDC2AB4773A730DED1 = { ... children = ( ... ); ... };

main_group_id = '0D1301BDC2AB4773A730DED1'
ts_group_id = generate_id()

# Create TS Group definition
group_section_start = content.find('/* Begin PBXGroup section */')
insert_pos = content.find('\n', group_section_start) + 1

ts_children = [f'\t\t\t\t{file_ref_ids[f]} /* {f} */,' for f in TS_FILES_M + TS_FILES_H]
ts_group_def = f'''\t\t{ts_group_id} /* TrollStoreCore */ = {{
\t\t\tisa = PBXGroup;
\t\t\tchildren = (
{chr(10).join(ts_children)}
\t\t\t);
\t\t\tname = TrollStoreCore;
\t\t\tsourceTree = "<group>";
\t\t}};'''

content = content[:insert_pos] + ts_group_def + '\n' + content[insert_pos:]

# Add TS Group to Main Group
# Find main group definition
main_group_pat = re.compile(r'0D1301BDC2AB4773A730DED1 = \{.*?children = \((.*?)\);', re.DOTALL)
match = main_group_pat.search(content)
if match:
    children_block = match.group(1)
    new_children_block = children_block + f'\n\t\t\t\t{ts_group_id} /* TrollStoreCore */,'
    content = content.replace(children_block, new_children_block)

# 5. Add ECAppListViewController to UI Group
# UI Group ID: B7FBAA1D7A610887CFEB5A35
ui_group_pat = re.compile(r'B7FBAA1D7A610887CFEB5A35 /\* UI \*/ = \{.*?children = \((.*?)\);', re.DOTALL)
match = ui_group_pat.search(content)
if match:
    children_block = match.group(1)
    new_files = [f'\t\t\t\t{file_ref_ids[f[0]]} /* {f[0]} */,' for f in EC_FILES]
    new_children_block = children_block + '\n' + '\n'.join(new_files)
    content = content.replace(children_block, new_children_block)

# 6. Add to PBXSourcesBuildPhase
# ECMAIN Sources Build Phase ID need to be found. 
# Target ECMAIN: C6E6615753BB47E1824B1C32 -> buildPhases -> 9501187F79604FD4B4D684F1 /* Sources */
# Find 9501187F79604FD4B4D684F1 /* Sources */ = { ... files = ( ... ) ... }

sources_pat = re.compile(r'9501187F79604FD4B4D684F1 /\* Sources \*/ = \{.*?files = \((.*?)\);', re.DOTALL)
match = sources_pat.search(content)
if match:
    files_block = match.group(1)
    new_files = []
    for f in TS_FILES_M:
         new_files.append(f'\t\t\t\t{build_file_ids[f]} /* {f} in Sources */,')
    for f, group in EC_FILES:
         new_files.append(f'\t\t\t\t{build_file_ids[f]} /* {f} in Sources */,')
    
    new_files_block = files_block + '\n' + '\n'.join(new_files)
    content = content.replace(files_block, new_files_block)

write_project(content)
print("Project updated.")
