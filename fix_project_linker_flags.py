#!/usr/bin/env python3
import re
import os

PROJECT_PATH = '/Users/hh/Desktop/my/WebDriverAgent.xcodeproj/project.pbxproj'

FRAMEWORKS = [
    'Vision', 'ncnn', 'opencv2', 'CoreGraphics', 'CoreMedia', 
    'CoreVideo', 'QuartzCore', 'AVFoundation', 'Accelerate', 
    'CoreImage', 'Metal', 'OpenGLES', 'Security', 'xml2', 'openmp',
    'swiftCompatibility50', 'swiftCompatibility51', 'swiftCompatibilityDynamicReplacements'
]

VENDOR_PATH = '"$(SRCROOT)/WebDriverAgentLib/Vendor"'
SWIFT_LIB_PATH = '"$(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)"'
OCR_PATH = '"$(SRCROOT)/WebDriverAgentLib/Resources/OCR"'

def fix_project():
    with open(PROJECT_PATH, 'r') as f:
        content = f.read()

    # Pattern for buildSettings block
    pattern = re.compile(r'(buildSettings\s*=\s*\{)(.*?)(\};)', re.DOTALL)
    
    def update_settings(match):
        prefix = match.group(1)
        body = match.group(2)
        suffix = match.group(3)
        
        # 1. Update FRAMEWORK_SEARCH_PATHS
        if 'FRAMEWORK_SEARCH_PATHS' not in body:
             body += f'\n\t\t\t\tFRAMEWORK_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t{VENDOR_PATH},\n\t\t\t\t);'
        elif VENDOR_PATH not in body:
             if 'FRAMEWORK_SEARCH_PATHS = (' in body:
                 body = body.replace('FRAMEWORK_SEARCH_PATHS = (', f'FRAMEWORK_SEARCH_PATHS = (\n\t\t\t\t\t{VENDOR_PATH},')
        
        # 2. Update LIBRARY_SEARCH_PATHS
        # We want to ensure Swift path is there.
        if 'LIBRARY_SEARCH_PATHS' not in body:
             body += f'\n\t\t\t\tLIBRARY_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t{SWIFT_LIB_PATH},\n\t\t\t\t\t{VENDOR_PATH},\n\t\t\t\t);'
        elif SWIFT_LIB_PATH not in body:
             if 'LIBRARY_SEARCH_PATHS = (' in body:
                 body = body.replace('LIBRARY_SEARCH_PATHS = (', f'LIBRARY_SEARCH_PATHS = (\n\t\t\t\t\t{SWIFT_LIB_PATH},')
             else:
                 # Single line assignment, e.g. LIBRARY_SEARCH_PATHS = "foo";
                 # Replace with list including new paths and keeping existing one if possible, or just standard set
                 # Since we saw it was set to OCR path, let's include that.
                 def repl_lib_single(m):
                     # keep existing value in theory?
                     # simple approach: replace with our full list including OCR path and VENDOR path
                     return f'LIBRARY_SEARCH_PATHS = (\n\t\t\t\t\t"$(inherited)",\n\t\t\t\t\t{SWIFT_LIB_PATH},\n\t\t\t\t\t{VENDOR_PATH},\n\t\t\t\t\t{OCR_PATH},\n\t\t\t\t);'
                 
                 body = re.sub(r'LIBRARY_SEARCH_PATHS\s*=\s*.*?;', repl_lib_single, body, count=1)
                 
        # 3. Update OTHER_LDFLAGS
        # Construct valid list of flags
        flags_entries = ''
        for fw in FRAMEWORKS:
            if fw == 'xml2':
                flag = '-lxml2'
            elif fw.startswith('swiftCompatibility'):
                flag = f'-l{fw}'
            else:
                flag = f'-framework {fw}'
            flags_entries += f'\t\t\t\t\t"{flag}",\n'

        if 'OTHER_LDFLAGS' not in body:
             body += f'\n\t\t\t\tOTHER_LDFLAGS = (\n\t\t\t\t\t"$(inherited)",\n{flags_entries}\t\t\t\t);'
        else:
            # Check if swift libs are missing
            if 'swiftCompatibility50' not in body:
                if 'OTHER_LDFLAGS = (' in body:
                    # List format - replace start
                    body = body.replace('OTHER_LDFLAGS = (', f'OTHER_LDFLAGS = (\n{flags_entries}')
                else:
                    # Single line assignment replace
                    def repl_single_line(m):
                         return f'OTHER_LDFLAGS = (\n\t\t\t\t\t"$(inherited)",\n{flags_entries}\t\t\t\t);'
                    body = re.sub(r'OTHER_LDFLAGS\s*=\s*.*?;', repl_single_line, body, count=1)

        return prefix + body + suffix

    new_content = pattern.sub(update_settings, content)
    
    if new_content != content:
        with open(PROJECT_PATH, 'w') as f:
            f.write(new_content)
        print("Updated project build settings.")
    else:
        print("Project already up to date.")

if __name__ == '__main__':
    fix_project()
