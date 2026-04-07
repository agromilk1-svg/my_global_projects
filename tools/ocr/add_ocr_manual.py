#!/usr/bin/env python3
"""
Manually add OCR folder to Xcode project as folder reference.
This directly modifies project.pbxproj to add the OCR folder.
"""
import re
import uuid
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

def generate_uuid():
    """Generate a 24-character hex UUID for Xcode"""
    return uuid.uuid4().hex[:24].upper()

with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# Check if OCR already added
if 'OCR /* OCR */' in content or 'Resources/OCR' in content:
    print("✓ OCR folder already in project")
else:
    print("Adding OCR folder to project...")
    
    # Generate UUIDs for the new entries
    ocr_file_ref_uuid = generate_uuid()
    ocr_build_file_uuid = generate_uuid()
    
    # 1. Add PBXFileReference for the OCR folder
    # Find the end of PBXFileReference section
    file_ref_pattern = r'(/\* End PBXFileReference section \*/)'
    file_ref_entry = f'''		{ocr_file_ref_uuid} /* OCR */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = OCR; path = WebDriverAgentLib/Resources/OCR; sourceTree = SOURCE_ROOT; }};
		'''
    content = re.sub(file_ref_pattern, file_ref_entry + r'\1', content)
    
    # 2. Add PBXBuildFile for copy resources
    build_file_pattern = r'(/\* End PBXBuildFile section \*/)'
    build_file_entry = f'''		{ocr_build_file_uuid} /* OCR in Resources */ = {{isa = PBXBuildFile; fileRef = {ocr_file_ref_uuid} /* OCR */; }};
		'''
    content = re.sub(build_file_pattern, build_file_entry + r'\1', content)
    
    # 3. Add to WebDriverAgentLib resources build phase
    # Find the PBXResourcesBuildPhase for WebDriverAgentLib
    # We need to add our OCR to the files array
    # Look for the Resources build phase that belongs to WebDriverAgentLib
    
    # Find all resource build phases and add to the first one (which should be WebDriverAgentLib)
    resource_phase_pattern = r'(isa = PBXResourcesBuildPhase;[^}]*files = \([^)]*)'
    
    def add_ocr_to_resources(match):
        existing = match.group(1)
        # Add our OCR file reference
        return existing + f'\n				{ocr_build_file_uuid} /* OCR in Resources */,'
    
    content = re.sub(resource_phase_pattern, add_ocr_to_resources, content, count=1)
    
    print("✓ Added OCR folder reference")
    print("✓ Added OCR to build file")
    print("✓ Added OCR to resources build phase")

with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print("\n✓ Project saved! Please rebuild in Xcode.")
