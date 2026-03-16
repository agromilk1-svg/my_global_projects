#!/usr/bin/env python3
"""
Fix linker flags to properly link OpenCV and NCNN static libraries.
Replace -lopencv2 and -lncnn with direct paths to the static archives.
"""
import re

PROJECT = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

with open(PROJECT, 'r') as f:
    content = f.read()

# Replace -lopencv2 with direct path to the static archive
# The opencv2 binary inside opencv2.framework is a static library
content = content.replace(
    '"-lopencv2"',
    '"$(SRCROOT)/WebDriverAgentLib/Vendor/opencv2.framework/opencv2"'
)

# Replace -lncnn with direct path to the static archive
content = content.replace(
    '"-lncnn"',
    '"$(SRCROOT)/WebDriverAgentLib/Vendor/ncnn.framework/ncnn"'
)

print("✓ Replaced -lopencv2 with direct path to opencv2 static library")
print("✓ Replaced -lncnn with direct path to ncnn static library")

with open(PROJECT, 'w') as f:
    f.write(content)

print("\n✓ Project updated!")
