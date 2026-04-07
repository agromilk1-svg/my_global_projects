#!/usr/bin/env python3
"""
Create a minimal clean Xcode project for ECMAIN
"""
import os
import uuid

def generate_uuid():
    return uuid.uuid4().hex[:24].upper()

PROJECT_DIR = '/Users/hh/Desktop/my/ECMAIN'
XCODEPROJ_DIR = os.path.join(PROJECT_DIR, 'ECMAIN.xcodeproj')
PBXPROJ_PATH = os.path.join(XCODEPROJ_DIR, 'project.pbxproj')

# Collect source files
source_files = []
for root, dirs, files in os.walk(PROJECT_DIR):
    if 'ECMAIN.xcodeproj' in root:
        continue
    for f in files:
        if f.endswith(('.h', '.m', '.c', '.mm', '.cpp')):
            rel_path = os.path.relpath(os.path.join(root, f), PROJECT_DIR)
            source_files.append(rel_path)

# Generate UUIDs
project_uuid = generate_uuid()
main_group_uuid = generate_uuid()
source_group_uuid = generate_uuid()
target_uuid = generate_uuid()
build_config_list_project_uuid = generate_uuid()
build_config_list_target_uuid = generate_uuid()
debug_config_uuid = generate_uuid()
release_config_uuid = generate_uuid()
debug_target_config_uuid = generate_uuid()
release_target_config_uuid = generate_uuid()
sources_phase_uuid = generate_uuid()
frameworks_phase_uuid = generate_uuid()
resources_phase_uuid = generate_uuid()
product_ref_uuid = generate_uuid()
products_group_uuid = generate_uuid()

file_refs = {}
build_files = {}
for f in source_files:
    file_refs[f] = generate_uuid()
    if f.endswith(('.m', '.mm', '.c', '.cpp')):
        build_files[f] = generate_uuid()

# Start building pbxproj content
pbx = """// !$*UTF8*$!
{
    archiveVersion = 1;
    classes = {
    };
    objectVersion = 56;
    objects = {
"""

# PBXBuildFile section
pbx += "\n/* Begin PBXBuildFile section */\n"
for f, bf_uuid in build_files.items():
    pbx += f'\t\t{bf_uuid} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[f]} /* {os.path.basename(f)} */; }};\n'
pbx += "/* End PBXBuildFile section */\n"

# PBXFileReference section
pbx += "\n/* Begin PBXFileReference section */\n"
for f, fr_uuid in file_refs.items():
    name = os.path.basename(f)
    ftype = "sourcecode.c.objc"
    if f.endswith('.h'):
        ftype = "sourcecode.c.h"
    elif f.endswith('.mm'):
        ftype = "sourcecode.cpp.objcpp"
    elif f.endswith('.cpp'):
        ftype = "sourcecode.cpp.cpp"
    pbx += f'\t\t{fr_uuid} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {ftype}; path = "{f}"; sourceTree = "<group>"; }};\n'
# Product reference
pbx += f'\t\t{product_ref_uuid} /* ECMAIN.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ECMAIN.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
pbx += "/* End PBXFileReference section */\n"

# PBXFrameworksBuildPhase
pbx += "\n/* Begin PBXFrameworksBuildPhase section */\n"
pbx += f'\t\t{frameworks_phase_uuid} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n'
pbx += "/* End PBXFrameworksBuildPhase section */\n"

# PBXGroup section
pbx += "\n/* Begin PBXGroup section */\n"
# Main group
pbx += f'\t\t{main_group_uuid} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{source_group_uuid} /* Sources */,\n\t\t\t\t{products_group_uuid} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};\n'
# Sources group
pbx += f'\t\t{source_group_uuid} /* Sources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n'
for f, fr_uuid in file_refs.items():
    pbx += f'\t\t\t\t{fr_uuid} /* {os.path.basename(f)} */,\n'
pbx += f'\t\t\t);\n\t\t\tpath = .;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n'
# Products group
pbx += f'\t\t{products_group_uuid} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{product_ref_uuid} /* ECMAIN.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};\n'
pbx += "/* End PBXGroup section */\n"

# PBXNativeTarget
pbx += "\n/* Begin PBXNativeTarget section */\n"
pbx += f'\t\t{target_uuid} /* ECMAIN */ = {{\n'
pbx += f'\t\t\tisa = PBXNativeTarget;\n'
pbx += f'\t\t\tbuildConfigurationList = {build_config_list_target_uuid} /* Build configuration list for PBXNativeTarget "ECMAIN" */;\n'
pbx += f'\t\t\tbuildPhases = (\n'
pbx += f'\t\t\t\t{sources_phase_uuid} /* Sources */,\n'
pbx += f'\t\t\t\t{frameworks_phase_uuid} /* Frameworks */,\n'
pbx += f'\t\t\t\t{resources_phase_uuid} /* Resources */,\n'
pbx += f'\t\t\t);\n'
pbx += f'\t\t\tbuildRules = (\n\t\t\t);\n'
pbx += f'\t\t\tdependencies = (\n\t\t\t);\n'
pbx += f'\t\t\tname = ECMAIN;\n'
pbx += f'\t\t\tproductName = ECMAIN;\n'
pbx += f'\t\t\tproductReference = {product_ref_uuid} /* ECMAIN.app */;\n'
pbx += f'\t\t\tproductType = "com.apple.product-type.application";\n'
pbx += f'\t\t}};\n'
pbx += "/* End PBXNativeTarget section */\n"

# PBXProject
pbx += "\n/* Begin PBXProject section */\n"
pbx += f'\t\t{project_uuid} /* Project object */ = {{\n'
pbx += f'\t\t\tisa = PBXProject;\n'
pbx += f'\t\t\tattributes = {{\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastUpgradeCheck = 1500;\n\t\t\t}};\n'
pbx += f'\t\t\tbuildConfigurationList = {build_config_list_project_uuid} /* Build configuration list for PBXProject "ECMAIN" */;\n'
pbx += f'\t\t\tcompatibilityVersion = "Xcode 14.0";\n'
pbx += f'\t\t\tdevelopmentRegion = en;\n'
pbx += f'\t\t\thasScannedForEncodings = 0;\n'
pbx += f'\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n'
pbx += f'\t\t\tmainGroup = {main_group_uuid};\n'
pbx += f'\t\t\tproductRefGroup = {products_group_uuid} /* Products */;\n'
pbx += f'\t\t\tprojectDirPath = "";\n'
pbx += f'\t\t\tprojectRoot = "";\n'
pbx += f'\t\t\ttargets = (\n\t\t\t\t{target_uuid} /* ECMAIN */,\n\t\t\t);\n'
pbx += f'\t\t}};\n'
pbx += "/* End PBXProject section */\n"

# PBXResourcesBuildPhase
pbx += "\n/* Begin PBXResourcesBuildPhase section */\n"
pbx += f'\t\t{resources_phase_uuid} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n'
pbx += "/* End PBXResourcesBuildPhase section */\n"

# PBXSourcesBuildPhase
pbx += "\n/* Begin PBXSourcesBuildPhase section */\n"
pbx += f'\t\t{sources_phase_uuid} /* Sources */ = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n'
for f, bf_uuid in build_files.items():
    pbx += f'\t\t\t\t{bf_uuid} /* {os.path.basename(f)} in Sources */,\n'
pbx += f'\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n'
pbx += "/* End PBXSourcesBuildPhase section */\n"

# XCBuildConfiguration
build_settings_common = """
\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.0;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tMARKETING_VERSION = 1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.ecmain.app;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";
"""

pbx += "\n/* Begin XCBuildConfiguration section */\n"
# Project Debug
pbx += f'\t\t{debug_config_uuid} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{build_settings_common}\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n'
# Project Release
pbx += f'\t\t{release_config_uuid} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{{build_settings_common}\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";\n\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n'
# Target Debug
pbx += f'\t\t{debug_target_config_uuid} /* Debug */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tINFOPLIST_FILE = Info.plist;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.ecmain.app;\n\t\t\t\tPRODUCT_NAME = ECMAIN;\n\t\t\t}};\n\t\t\tname = Debug;\n\t\t}};\n'
# Target Release
pbx += f'\t\t{release_target_config_uuid} /* Release */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n\t\t\t\tINFOPLIST_FILE = Info.plist;\n\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.ecmain.app;\n\t\t\t\tPRODUCT_NAME = ECMAIN;\n\t\t\t}};\n\t\t\tname = Release;\n\t\t}};\n'
pbx += "/* End XCBuildConfiguration section */\n"

# XCConfigurationList
pbx += "\n/* Begin XCConfigurationList section */\n"
pbx += f'\t\t{build_config_list_project_uuid} /* Build configuration list for PBXProject "ECMAIN" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{debug_config_uuid} /* Debug */,\n\t\t\t\t{release_config_uuid} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n'
pbx += f'\t\t{build_config_list_target_uuid} /* Build configuration list for PBXNativeTarget "ECMAIN" */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{debug_target_config_uuid} /* Debug */,\n\t\t\t\t{release_target_config_uuid} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n'
pbx += "/* End XCConfigurationList section */\n"

# Close
pbx += """
    };
    rootObject = """ + project_uuid + """ /* Project object */;
}
"""

# Write file
os.makedirs(XCODEPROJ_DIR, exist_ok=True)
with open(PBXPROJ_PATH, 'w') as f:
    f.write(pbx)

print(f"Created clean project at {XCODEPROJ_DIR}")
print(f"Added {len(source_files)} source files")
