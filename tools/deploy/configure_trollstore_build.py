#!/usr/bin/env python3
"""
Configure ECMAIN for TrollStore build (no code signing)
Uses direct file manipulation since pbxproj API varies
"""
import re

PROJECT_PATH = '/Users/hh/Desktop/my/ECMAIN/ECMAIN.xcodeproj/project.pbxproj'

print("Loading project...")
with open(PROJECT_PATH, 'r') as f:
    content = f.read()

print("Disabling code signing...")

# Add/update build settings for no signing
replacements = [
    # Remove any existing CODE_SIGN settings and add our own
    (r'CODE_SIGN_IDENTITY = "[^"]*";', 'CODE_SIGN_IDENTITY = "";'),
    (r'CODE_SIGN_STYLE = [^;]+;', 'CODE_SIGN_STYLE = Manual;'),
    (r'"CODE_SIGN_IDENTITY\[sdk=iphoneos\*\]" = "[^"]*";', '"CODE_SIGN_IDENTITY[sdk=iphoneos*]" = "";'),
]

for pattern, replacement in replacements:
    content = re.sub(pattern, replacement, content)

# Add CODE_SIGNING_REQUIRED = NO to all buildSettings blocks
# Find all buildSettings = { and add our settings
def add_no_signing(match):
    settings = match.group(0)
    if 'CODE_SIGNING_REQUIRED' not in settings:
        # Insert after the opening brace
        settings = settings.replace('buildSettings = {', 
            'buildSettings = {\n\t\t\t\tCODE_SIGNING_REQUIRED = NO;\n\t\t\t\tCODE_SIGNING_ALLOWED = NO;')
    return settings

content = re.sub(r'buildSettings = \{[^}]+\}', add_no_signing, content, flags=re.DOTALL)

print("Saving project...")
with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print("\n✓ Project configured for TrollStore build!")
print("\nXcode Build Settings updated:")
print("  - CODE_SIGNING_REQUIRED = NO")
print("  - CODE_SIGNING_ALLOWED = NO")
print("  - CODE_SIGN_IDENTITY = (empty)")
print("\nNext steps:")
print("1. Close and reopen ECMAIN.xcodeproj")
print("2. Remove all Capabilities from Signing & Capabilities tab")
print("3. Build (⌘B)")
print("4. Use ldid to sign with entitlements for TrollStore")
