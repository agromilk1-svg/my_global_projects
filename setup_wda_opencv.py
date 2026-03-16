#!/usr/bin/env python3
"""
配置 Xcode 项目以支持 OpenCV
"""
import os
import shutil
from pbxproj import XcodeProject

PROJECT_PATH = 'WebDriverAgent.xcodeproj/project.pbxproj'

project = XcodeProject.load(PROJECT_PATH)

# 配置 Search Paths
configs_gen = project.objects.get_configurations_on_targets(target_name='WebDriverAgentLib')

framework_search_path = "$(SRCROOT)/WebDriverAgentLib/Vendor"

for config in configs_gen:
    config_name = config.name
    
    # FRAMEWORK_SEARCH_PATHS
    fsp = config.buildSettings.get('FRAMEWORK_SEARCH_PATHS', [])
    if isinstance(fsp, str): fsp = [fsp]
    
    modified = False
    if framework_search_path not in fsp:
        fsp.append(framework_search_path)
        modified = True
        
    if modified:
        config.buildSettings['FRAMEWORK_SEARCH_PATHS'] = fsp
        print(f"Updated FRAMEWORK_SEARCH_PATHS for {config_name}")
        
    # OTHER_LDFLAGS
    ldflags = config.buildSettings.get('OTHER_LDFLAGS', [])
    if isinstance(ldflags, str): ldflags = [ldflags]
    
    flags_to_add = ['-framework', 'opencv2']
    flag_modified = False
    for flag in flags_to_add:
        if flag not in ldflags:
            ldflags.append(flag)
            flag_modified = True
            
    if flag_modified:
        config.buildSettings['OTHER_LDFLAGS'] = ldflags
        print(f"Updated OTHER_LDFLAGS for {config_name}")

project.save()
print("OpenCV setup complete!")
