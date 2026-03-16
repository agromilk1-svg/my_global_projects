#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys

# Configuration
PROJECT_DIR = "/Users/hh/Desktop/my"
BUILD_DIR = os.path.join(PROJECT_DIR, "build_xcode/Build/Products/Release-iphoneos")
APP_NAME = "ECWDA.app"
APP_PATH = os.path.join(BUILD_DIR, APP_NAME)
ENTITLEMENTS = os.path.join(PROJECT_DIR, "WDA_Minimal.entitlements")
OUTPUT_DIR = os.path.join(PROJECT_DIR, "build_antigravity/IPA")
IPA_NAME = "ECWDA_Standalone.ipa"
TEMP_DIR = "/tmp/ecwda_standalone_pkg"

def run_cmd(cmd, cwd=None):
    print(f"Exec: {' '.join(cmd)}")
    try:
        subprocess.check_call(cmd, cwd=cwd)
        return True
    except subprocess.CalledProcessError as e:
        print(f"Error: {e}")
        return False

def main():
    if not os.path.exists(APP_PATH):
        print(f"Error: App not found at {APP_PATH}")
        sys.exit(1)

    print(f"--- Packaging {APP_NAME} ---")

    # 1. Prepare Frameworks
    frameworks_dir = os.path.join(APP_PATH, "Frameworks")
    if not os.path.exists(frameworks_dir):
        os.makedirs(frameworks_dir)

    # Copy XCTest frameworks if missing (sanity check, they should be there from previous step)
    # But let's be sure
    xctest_base = "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/Library/Frameworks"
    needed_fws = ["XCTest.framework", "XCTestCore.framework", "XCUIAutomation.framework", "XCUnit.framework", "Testing.framework"]
    
    for fw in needed_fws:
        src = os.path.join(xctest_base, fw)
        dst = os.path.join(frameworks_dir, fw)
        if os.path.exists(src) and not os.path.exists(dst):
            print(f"Copying {fw}...")
            if os.path.isdir(src):
                shutil.copytree(src, dst)
            else:
                shutil.copy2(src, dst)

    # 2. Sign Frameworks
    print("--- Signing Frameworks ---")
    if os.path.exists(frameworks_dir):
        for item in os.listdir(frameworks_dir):
            item_path = os.path.join(frameworks_dir, item)
            
            # Find binary to sign
            binary_path = item_path
            if item.endswith(".framework"):
                binary_name = os.path.splitext(item)[0]
                binary_path = os.path.join(item_path, binary_name)
            
            if os.path.exists(binary_path) and not os.path.isdir(binary_path):
                print(f"Signing {item}...")
                run_cmd(["codesign", "-f", "-s", "-", binary_path])

    # 3. Sign Main Binary
    print("--- Signing Main Application ---")
    binary_path = os.path.join(APP_PATH, "ECWDA")
    if run_cmd(["codesign", "-f", "-s", "-", "--entitlements", ENTITLEMENTS, binary_path]):
        print("Application signed successfully.")
    else:
        print("Failed to sign application.")
        sys.exit(1)

    # 4. Create IPA
    print("--- Creating IPA ---")
    if os.path.exists(TEMP_DIR):
        shutil.rmtree(TEMP_DIR)
    
    payload_dir = os.path.join(TEMP_DIR, "Payload")
    os.makedirs(payload_dir)
    
    print(f"Copying .app to Payload...")
    shutil.copytree(APP_PATH, os.path.join(payload_dir, APP_NAME))
    
    # Zip
    output_ipa = os.path.join(OUTPUT_DIR, IPA_NAME)
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
        
    print(f"Zipping to {output_ipa}...")
    # make_archive defaults to zip
    shutil.make_archive(os.path.join(OUTPUT_DIR, "ECWDA_Standalone"), 'zip', TEMP_DIR)
    
    # Rename .zip to .ipa
    zip_path = os.path.join(OUTPUT_DIR, "ECWDA_Standalone.zip")
    if os.path.exists(output_ipa):
        os.remove(output_ipa)
    shutil.move(zip_path, output_ipa)
    
    print(f"✅ IPA Package Created: {output_ipa}")
    
    # Cleanup
    shutil.rmtree(TEMP_DIR)

if __name__ == "__main__":
    main()
