#!/usr/bin/env python3
"""
Add OCR resources folder to Xcode project Copy Bundle Resources
"""
from pbxproj import XcodeProject
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'
OCR_FOLDER = 'WebDriverAgentLib/Resources/OCR'

print("Loading Xcode project...")
project = XcodeProject.load(PROJECT_PATH)

# Check if OCR folder already exists in project
existing = project.get_files_by_name('OCR')
if existing:
    print("✓ OCR folder already in project")
else:
    print("Adding OCR folder to project...")
    try:
        # Add the OCR folder as a folder reference (not a group)
        # This will copy the entire folder to the bundle
        added = project.add_folder(
            OCR_FOLDER,
            parent=project.get_or_create_group('Resources', 'WebDriverAgentLib'),
            excludes=['\.DS_Store'],
            target_name='WebDriverAgentLib'
        )
        if added:
            print("✓ Added OCR folder to project")
        else:
            print("⚠️ Could not add OCR folder")
    except Exception as e:
        print(f"Error: {e}")
        # Try alternative method - add as file reference
        try:
            added = project.add_file(
                OCR_FOLDER,
                parent=project.get_or_create_group('Resources', 'WebDriverAgentLib'),
                force=False,
                target_name='WebDriverAgentLib',
                file_options=project.new_file_options(create_build_files=True)
            )
            if added:
                print("✓ Added OCR folder as file reference")
        except Exception as e2:
            print(f"Error with alternative method: {e2}")

project.save()
print("\n✓ Project saved!")
