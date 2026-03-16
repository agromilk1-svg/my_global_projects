#!/usr/bin/env python3
"""
Add all OCR resource files to Xcode project.
This adds the OCR folder as a folder reference so all files get copied.
"""
import re
import uuid

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

def gen_uuid():
    return uuid.uuid4().hex[:24].upper()

with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# List of all OCR files that need to be in the bundle
ocr_files = [
    'ncnn_PP_OCRv5_mobile_det.ncnn.bin',
    'ncnn_PP_OCRv5_mobile_det.ncnn.param',
    'ncnn_PP_OCRv5_mobile_rec.ncnn.bin',
    'ncnn_PP_OCRv5_mobile_rec.ncnn.param',
    'ch_PP-OCRv5_mobile_det.onnx',
    'ch_PP-OCRv5_rec_mobile_infer.onnx',
    'ch_ppocr_mobile_v2.0_cls_infer.onnx',
    'ppocrv5_mobile_labels.txt',
    'agent_port.txt',
]

# Find WebDriverAgentLib's Resources build phase
# We identified it as EE158A971CBD452B00A3E3F0 from previous grep

resources_phase_id = 'EE158A971CBD452B00A3E3F0'

added_count = 0

for filename in ocr_files:
    # Check if file already in project
    if filename in content:
        print(f"✓ {filename} already in project")
        continue
    
    file_uuid = gen_uuid()
    build_uuid = gen_uuid()
    
    # Determine file type
    if filename.endswith('.bin'):
        file_type = 'archive.macbinary'
    elif filename.endswith('.param'):
        file_type = 'text'
    elif filename.endswith('.onnx'):
        file_type = 'file'
    elif filename.endswith('.txt'):
        file_type = 'text'
    else:
        file_type = 'file'
    
    # 1. Add PBXFileReference
    file_ref_pattern = r'(/\* End PBXFileReference section \*/)'
    file_ref_entry = f'''		{file_uuid} /* {filename} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; name = {filename}; path = WebDriverAgentLib/Resources/OCR/{filename}; sourceTree = "<group>"; }};
'''
    content = re.sub(file_ref_pattern, file_ref_entry + r'\1', content)
    
    # 2. Add PBXBuildFile
    build_file_pattern = r'(/\* End PBXBuildFile section \*/)'
    build_file_entry = f'''		{build_uuid} /* {filename} in Resources */ = {{isa = PBXBuildFile; fileRef = {file_uuid} /* {filename} */; }};
'''
    content = re.sub(build_file_pattern, build_file_entry + r'\1', content)
    
    # 3. Add to Resources build phase
    # Find the specific resources phase and add to its files array
    phase_pattern = rf'({resources_phase_id} /\* Resources \*/ = \{{\s*isa = PBXResourcesBuildPhase;[^}}]*files = \([^)]*)'
    
    def add_to_phase(match):
        return match.group(1) + f'\n				{build_uuid} /* {filename} in Resources */,'
    
    content = re.sub(phase_pattern, add_to_phase, content)
    
    # 4. Add to OCR group (if it exists)
    group_pattern = r'(9AB3494F9501D0CB4F4E4AD2 /\* OCR \*/ = \{[^}]*children = \([^)]*)'
    def add_to_group(match):
        return match.group(1) + f'\n				{file_uuid} /* {filename} */,'
    content = re.sub(group_pattern, add_to_group, content)
    
    print(f"✓ Added {filename}")
    added_count += 1

with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print(f"\n✓ Added {added_count} files to project. Please rebuild in Xcode.")
