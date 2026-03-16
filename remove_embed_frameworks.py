#!/usr/bin/env python3
"""
Remove all embedded frameworks and the Embed Frameworks phase
"""
import re

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

print("Loading project...")
with open(PROJECT_PATH, 'r') as f:
    content = f.read()

print("Removing framework embed references...")

# Remove all "in Embed Frameworks" build file entries
content = re.sub(r'\s*[A-F0-9]+ /\* [^*]+ in Embed Frameworks \*/ = \{[^}]+\};\n', '', content)

# Remove framework references from Embed Frameworks section files list
content = re.sub(r'\s*[A-F0-9]+ /\* [^*]+\.framework in Embed Frameworks \*/,?\n', '', content)

# Remove Embed Frameworks phase section if empty or problematic
# Find and remove the entire Embed Frameworks phase
embed_phase_pattern = r'/\* Embed Frameworks \*/ = \{\s*isa = PBXCopyFilesBuildPhase;[^}]+buildActionMask[^}]+files = \([^)]*\);[^}]+\};'
content = re.sub(embed_phase_pattern, '', content, flags=re.DOTALL)

# Remove framework file references
frameworks = ['UIKit.framework', 'AVFoundation.framework', 'NetworkExtension.framework', 
              'Security.framework', 'CoreFoundation.framework']
for fw in frameworks:
    # Remove PBXFileReference
    pattern = rf'\s*[A-F0-9]+ /\* {re.escape(fw)} \*/ = \{{[^}}]+\}};\n'
    content = re.sub(pattern, '', content)
    # Remove from children lists
    pattern = rf'\s*[A-F0-9]+ /\* {re.escape(fw)} \*/,?\n'
    content = re.sub(pattern, '', content)

print("Saving project...")
with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print("\n✓ Framework embedding removed!")
print("Building again...")
