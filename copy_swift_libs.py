#!/usr/bin/env python3
"""
Copy required Swift runtime libraries into the app bundle Frameworks directory.
This is needed because opencv2.framework uses Swift but the project doesn't compile Swift code,
so Xcode doesn't automatically embed the Swift runtime.
"""

import os
import shutil
import subprocess
import sys

# Swift runtime libraries path
SWIFT_LIBS_PATH = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-5.0/iphoneos'

# Required Swift libraries (based on otool output from WebDriverAgentRunner)
REQUIRED_LIBS = [
    'libswiftCore.dylib',
    'libswiftFoundation.dylib',
    'libswiftDarwin.dylib',
    'libswiftDispatch.dylib',
    'libswiftObjectiveC.dylib',
    'libswiftCoreFoundation.dylib',
    'libswiftos.dylib',
    'libswiftAccelerate.dylib',
    'libswiftAVFoundation.dylib',
    'libswiftCoreAudio.dylib',
    'libswiftCoreImage.dylib',
    'libswiftCoreMedia.dylib',
    'libswiftMetal.dylib',
    'libswiftQuartzCore.dylib',
    'libswiftsimd.dylib',
    'libswiftUIKit.dylib',
]

def copy_swift_libs(app_path):
    """Copy Swift runtime libraries to app bundle's Frameworks directory."""
    frameworks_dir = os.path.join(app_path, 'Frameworks')
    
    if not os.path.exists(frameworks_dir):
        os.makedirs(frameworks_dir)
        print(f"Created Frameworks directory: {frameworks_dir}")
    
    copied = 0
    for lib in REQUIRED_LIBS:
        src = os.path.join(SWIFT_LIBS_PATH, lib)
        dst = os.path.join(frameworks_dir, lib)
        
        if os.path.exists(src):
            if not os.path.exists(dst):
                shutil.copy2(src, dst)
                print(f"Copied: {lib}")
                copied += 1
            else:
                print(f"Already exists: {lib}")
        else:
            print(f"Warning: {lib} not found at {src}")
    
    print(f"\nCopied {copied} Swift runtime libraries to {frameworks_dir}")
    return copied > 0

def main():
    if len(sys.argv) < 2:
        # Default path
        app_path = 'build/Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app'
    else:
        app_path = sys.argv[1]
    
    if not os.path.exists(app_path):
        print(f"Error: App bundle not found at {app_path}")
        print("Please build the project first, then run this script.")
        sys.exit(1)
    
    print(f"Copying Swift runtime libraries to: {app_path}")
    success = copy_swift_libs(app_path)
    
    if success:
        # Also copy to xctest bundle
        xctest_path = os.path.join(app_path, 'PlugIns', 'WebDriverAgentRunner.xctest')
        if os.path.exists(xctest_path):
            print(f"\nAlso copying to xctest bundle: {xctest_path}")
            copy_swift_libs(xctest_path)
    
    print("\nDone!")

if __name__ == '__main__':
    main()
