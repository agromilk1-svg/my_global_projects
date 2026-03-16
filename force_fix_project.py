#!/usr/bin/env python3
import re
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

safe_header_paths = """                                HEADER_SEARCH_PATHS = (
                                        "$(inherited)",
                                        "$(SRCROOT)/WebDriverAgentLib/Utilities",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/ncnn.framework/Headers",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/openmp.framework/Headers",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/opencv2.framework/Headers",
                                );"""

with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# Strategy: Find existing HEADER_SEARCH_PATHS blocks and replace them with our safe version
# We use regex to match the multi-line block

# This regex matches HEADER_SEARCH_PATHS = (...);
# It handles whitespace and newlines
pattern = r'HEADER_SEARCH_PATHS = \([^;]+\);'

# Replace all occurrences
new_content = re.sub(pattern, safe_header_paths, content, flags=re.MULTILINE|re.DOTALL)

# Also check for Library Search Paths just in case
safe_lib_paths = """                                LIBRARY_SEARCH_PATHS = (
                                        "$(inherited)",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/ncnn.framework",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/openmp.framework",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor/opencv2.framework",
                                );"""

lib_pattern = r'LIBRARY_SEARCH_PATHS = \([^;]+\);'
new_content = re.sub(lib_pattern, safe_lib_paths, new_content, flags=re.MULTILINE|re.DOTALL)

# Also fix Framework Search Paths
safe_framework_paths = """                                FRAMEWORK_SEARCH_PATHS = (
                                        "$(inherited)",
                                        "$(SRCROOT)/WebDriverAgentLib/Vendor",
                                );"""

fw_pattern = r'FRAMEWORK_SEARCH_PATHS = \([^;]+\);'
new_content = re.sub(fw_pattern, safe_framework_paths, new_content, flags=re.MULTILINE|re.DOTALL)

with open(PROJECT_PATH, 'w') as f:
    f.write(new_content)

print("Forced reset of Search Paths in project file.")
