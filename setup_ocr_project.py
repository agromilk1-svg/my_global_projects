#!/usr/bin/env python3
"""
配置 Xcode 项目以支持 NCNN + PaddleOCR
"""
import os
import shutil
from pbxproj import XcodeProject, PBXBuildFile, PBXFileReference

PROJECT_PATH = 'WebDriverAgent.xcodeproj/project.pbxproj'
BACKUP_PATH = 'WebDriverAgent.xcodeproj/project.pbxproj.bak'

# 备份项目文件
if not os.path.exists(BACKUP_PATH):
    shutil.copy(PROJECT_PATH, BACKUP_PATH)
    print(f"Created backup at {BACKUP_PATH}")

project = XcodeProject.load(PROJECT_PATH)

# 1. 添加源文件
files_to_add = [
    'WebDriverAgentLib/Utilities/FBOCREngine.h',
    'WebDriverAgentLib/Utilities/FBOCREngine.mm',
]

for file_path in files_to_add:
    if os.path.exists(file_path):
        # 检查是否已存在
        name = os.path.basename(file_path)
        if hasattr(project, 'get_files_by_name') and project.get_files_by_name(name):
            print(f"File {name} already exists in project")
        else:
            project.add_file(file_path, target_name='WebDriverAgentLib')
            print(f"Added {name}")

# 2. 设置 Search Paths
# 获取 build configurations
configs_gen = project.objects.get_configurations_on_targets(target_name='WebDriverAgentLib')

ncnn_header_path = "$(SRCROOT)/WebDriverAgentLib/Vendor/ncnn.framework/Headers"
openmp_header_path = "$(SRCROOT)/WebDriverAgentLib/Vendor/openmp.framework/Headers"
framework_search_path = "$(SRCROOT)/WebDriverAgentLib/Vendor"

for config in configs_gen:
    config_name = config.name
    
    # HEADER_SEARCH_PATHS
    hsp = config.buildSettings.get('HEADER_SEARCH_PATHS', [])
    if isinstance(hsp, str): hsp = [hsp]
    
    modified = False
    if ncnn_header_path not in hsp:
        hsp.append(ncnn_header_path)
        modified = True
    if openmp_header_path not in hsp:
        hsp.append(openmp_header_path)
        modified = True
        
    if modified:
        config.buildSettings['HEADER_SEARCH_PATHS'] = hsp
        print(f"Updated HEADER_SEARCH_PATHS for {config_name}")

    # FRAMEWORK_SEARCH_PATHS
    fsp = config.buildSettings.get('FRAMEWORK_SEARCH_PATHS', [])
    if isinstance(fsp, str): fsp = [fsp]
    
    if framework_search_path not in fsp:
        fsp.append(framework_search_path)
        config.buildSettings['FRAMEWORK_SEARCH_PATHS'] = fsp
        print(f"Updated FRAMEWORK_SEARCH_PATHS for {config_name}")
        
    # OTHER_LDFLAGS
    ldflags = config.buildSettings.get('OTHER_LDFLAGS', [])
    if isinstance(ldflags, str): ldflags = [ldflags]
    
    flags_to_add = ['-framework', 'ncnn', '-framework', 'openmp', '-lc++']
    flag_modified = False
    for flag in flags_to_add:
        if flag not in ldflags:
            ldflags.append(flag)
            flag_modified = True
            
    if flag_modified:
        config.buildSettings['OTHER_LDFLAGS'] = ldflags
        print(f"Updated OTHER_LDFLAGS for {config_name}")

    # Enable Objective-C++
    # config.buildSettings['CLANG_CXX_LANGUAGE_STANDARD'] = 'gnu++14'
    # config.buildSettings['CLANG_CXX_LIBRARY'] = 'libc++'

# 3. 添加 Frameworks (这一步比较 tricky，pbxproj add_file 可能无法正确处理 framework 引用到 Build Phases)
# 我们已经在 Search Paths 和 Link Flags 中处理了，这通常足够。
# 如果需要明确添加文件引用：
# project.add_file('WebDriverAgentLib/Vendor/ncnn/ncnn.framework', target_name='WebDriverAgentLib', tree='SOURCE_ROOT')
# project.add_file('WebDriverAgentLib/Vendor/ncnn/openmp.framework', target_name='WebDriverAgentLib', tree='SOURCE_ROOT')

# 4. 添加资源文件 (OCR 模型)
# 我们需要把 Resources/OCR 文件夹作为 Folder Reference 添加到 WebDriverAgentRunner (不是 Lib，因为资源通常在 Bundle 中)
# 或者添加到 Lib 的 Resources 阶段
ocr_folder = 'WebDriverAgentLib/Resources/OCR'
if os.path.exists(ocr_folder):
    # 作为 Folder Reference 添加 (蓝色文件夹)
    # project.add_file(ocr_folder, target_name='WebDriverAgentRunner', tree='SOURCE_ROOT', force=False)
    # 尝试添加到 Lib
    project.add_file(ocr_folder, target_name='WebDriverAgentLib', tree='SOURCE_ROOT')
    print("Added OCR resources")

project.save()
print("Project setup complete!")
