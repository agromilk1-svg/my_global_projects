#!/usr/bin/env python3
import os
import subprocess
import argparse
import shutil
import sys

# Configuration
PROJECT_DIR = os.getcwd() # Assuming running from project root
# User requested "build_antigravity" for permanent storage
BUILD_ROOT = os.path.join(PROJECT_DIR, "build_antigravity")

DERIVED_DATA_DIR = os.path.join(BUILD_ROOT, "DerivedData")
PRODUCTS_DIR = os.path.join(BUILD_ROOT, "Products")
IPA_DIR = os.path.join(BUILD_ROOT, "IPA")
if not os.path.exists(IPA_DIR):
    os.makedirs(IPA_DIR)

def is_macho_binary(filepath):
    try:
        with open(filepath, 'rb') as f:
            magic = f.read(4)
            return magic in [
                b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe',
                b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe',
                b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
            ]
    except:
        return False

def is_signed(filepath):
    try:
        result = subprocess.run(['codesign', '-dvvv', filepath], capture_output=True, text=True)
        return 'not signed' not in result.stderr
    except:
        return True

def sign_unsigned_binaries(app_path):
    print(f"[*] Scanning {app_path} for unsigned binaries...")
    signed_count = 0
    for root, dirs, files in os.walk(app_path):
        for filename in files:
            filepath = os.path.join(root, filename)
            if not is_macho_binary(filepath): continue
            if is_signed(filepath): continue
            print(f"[+] Signing: {os.path.relpath(filepath, app_path)}")
            try:
                subprocess.check_call(['codesign', '-f', '-s', '-', filepath])
                signed_count += 1
            except subprocess.CalledProcessError as e:
                print(f"[-] Failed to sign {filename}: {e}")
    print(f"[+] Signed {signed_count} unsigned binaries")

def run_cmd(cmd, cwd=PROJECT_DIR, ignore_error=False):
    print(f"Executing: {cmd}")
    try:
        subprocess.check_call(cmd, shell=True, cwd=cwd)
        return True
    except subprocess.CalledProcessError as e:
        if not ignore_error:
            print(f"Error: {e}")
        return False

def clean_old_dirs():
    print("--- Cleaning old build directories ---")
    dirs_to_remove = ["build_ipa", "build_wda", "ECWDA_Build", "Build_IPA", "build", "build_xcode"]
    for d in dirs_to_remove:
        path = os.path.join(PROJECT_DIR, d)
        if os.path.exists(path):
            print(f"Removing {d}...")
            shutil.rmtree(path)
            
    # Also clean current build dir if requested (handled by xcodebuild clean usually)
    # But for a full clean:
    # if os.path.exists(BUILD_ROOT):
    #    shutil.rmtree(BUILD_ROOT)

def prepare_dirs():
    for d in [BUILD_ROOT, DERIVED_DATA_DIR, PRODUCTS_DIR, IPA_DIR]:
        if not os.path.exists(d):
            os.makedirs(d)

def build_wda():
    print("\n=== Building ECWDA (WebDriverAgent) ===")
    
    # Clean
    run_cmd(f"xcodebuild clean -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner -configuration Debug")
    
    # Build
    cmd = (
        f"xcodebuild -project WebDriverAgent.xcodeproj "
        f"-scheme WebDriverAgentRunner "
        f"-sdk iphoneos "
        f"-configuration Debug "
        f"-derivedDataPath {DERIVED_DATA_DIR} "
        f"CONFIGURATION_BUILD_DIR='{os.path.join(DERIVED_DATA_DIR, 'Build/Products/Debug-iphoneos')}' "
        f"SYMROOT='{os.path.join(DERIVED_DATA_DIR, 'Build/Products')}' "
        f"CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO "
        f"CODE_SIGNING_ALLOWED=NO"
    )
    
    if not run_cmd(cmd):
        print("❌ WDA Build Failed")
        return False
        
    print("✅ WDA Build Succeeded")
    
    # Package IPA
    print("--- Packaging ECWDA.ipa ---")
    
    # Find .app
    # It usually ends up in DerivedData/Build/Products/Debug-iphoneos/
    app_path = os.path.join(DERIVED_DATA_DIR, "Build/Products/Debug-iphoneos/Ecrunner-Runner.app")
    
    # Fallback search if scheme renamed product
    if not os.path.exists(app_path):
        # Try WebDriverAgentRunner-Runner.app
        app_path = os.path.join(DERIVED_DATA_DIR, "Build/Products/Debug-iphoneos/WebDriverAgentRunner-Runner.app")
        
    # Explicit check for build_antigravity structure (redundant if using derived path but safe)
    antigrav_build_path = os.path.join(BUILD_ROOT, "Build/Products/Debug-iphoneos/Ecrunner-Runner.app")
    if not os.path.exists(app_path) and os.path.exists(antigrav_build_path):
        app_path = antigrav_build_path
        
    if not os.path.exists(app_path):
        # Scan entire build root - Prioritize iphoneos
        print(f"DEBUG: Scanning {BUILD_ROOT} for WDA app...")
        candidate = None
        for root, dirs, files in os.walk(BUILD_ROOT, followlinks=True):
             # print(f"DEBUG: Visiting {root}") 
             for d in dirs:
                if d.endswith(".app"):
                    full_path = os.path.join(root, d)
                    
                    # Logic: Must be a Runner app, preferably in iphoneos path
                    is_runner = "Runner" in d
                    is_ios = "iphoneos" in root or "iphoneos" in d
                    is_tvos = "tvOS" in d or "appletv" in root
                    
                    if is_runner and is_ios and not is_tvos:
                        print(f"DEBUG: Found iOS MATCH -> {full_path}")
                        app_path = full_path
                        break
                    elif is_runner and not is_tvos and not candidate:
                        print(f"DEBUG: Found backup candidate -> {full_path}")
                        candidate = full_path
            
             if app_path: break
        
        if not app_path and candidate:
             print(f"DEBUG: Using backup candidate -> {candidate}")
             app_path = candidate
             
    if not os.path.exists(app_path):
        print("❌ Could not find WDA .app product")
        run_cmd(f"find '{BUILD_ROOT}' -name '*.app'", ignore_error=True)
        return False
        
    print(f"Found App: {app_path}")
    
    # Frameworks embedding removed to avoid bloat (OpenCV ~550MB).
    # Relying on Xcode's native linking and derived data structure.


    # Create Payload
    payload_path = os.path.join(BUILD_ROOT, "Payload_WDA")
    if os.path.exists(payload_path):
        shutil.rmtree(payload_path)
    os.makedirs(os.path.join(payload_path, "Payload"))
    
    dest_app = os.path.join(payload_path, "Payload", os.path.basename(app_path))
    run_cmd(f"cp -a '{app_path}' '{dest_app}'")
    
    # Sign unsigned binaries (fix for Error 185)
    # Also resign the main binary with proper entitlements to fix crash (remove get-task-allow)
    entitlements_path = os.path.join(PROJECT_DIR, "WDA_Minimal.entitlements")
    if os.path.exists(entitlements_path):
        print(f"[*] Resigning main binary with minimal entitlements: {entitlements_path}")
        # Recurse sign logic in sign_unsigned_binaries needs to handle main binary specifically for entitlements?
        # sign_unsigned_binaries only does ad-hoc (-). We need to enhance it or call codesign manually for main app.
        
        # 1. Sign Frameworks/Plugins first (handled by sign_unsigned_binaries)
        sign_unsigned_binaries(dest_app)
        
        # 2. Resign Main Binary with Entitlements
        main_binary = os.path.join(dest_app, "Ecrunner-Runner")
        if not os.path.exists(main_binary):
             main_binary = os.path.join(dest_app, "WebDriverAgentRunner-Runner")
             
        if os.path.exists(main_binary):
            try:
                subprocess.check_call(['codesign', '-f', '-s', '-', '--entitlements', entitlements_path, main_binary])
                print(f"[+] Resigned {os.path.basename(main_binary)} with WDA_Minimal.entitlements")
            except Exception as e:
                print(f"[-] Failed to resign main binary: {e}")
    else:
        sign_unsigned_binaries(dest_app)
    
    ipa_output = os.path.join(IPA_DIR, "ECWDA.ipa")
    if os.path.exists(ipa_output):
        os.remove(ipa_output)
        
    run_cmd(f"cd '{payload_path}' && zip -r -y '{ipa_output}' Payload -q")
    
    print(f"✅ Created {ipa_output}")
    return True

def build_ecmain():
    print("\n=== Building ECMAIN ===")
    
    # Verify nested structure fix (from previous task)
    # If ECMAIN/ECMAIN doesn't exist, created it? 
    # Actually, we should try to fix the project file properly eventually, but for now 
    # we assume the 'nested hack' is in place or not needed if we fixed the project.
    # The user manual hack in previous turn: mkdir -p ECMAIN/ECMAIN && cp ...
    # We leave that as is for now.
    
    # Clean
    run_cmd(f"xcodebuild clean -project ECMAIN/ECMAIN.xcodeproj -scheme ECMAIN -configuration Debug")
    
    # Build
    cmd = (
        f"xcodebuild -project ECMAIN/ECMAIN.xcodeproj "
        f"-scheme ECMAIN "
        f"-sdk iphoneos "
        f"-configuration Debug "
        f"CODE_SIGNING_ALLOWED=NO "
        f"-derivedDataPath {DERIVED_DATA_DIR} "
        f"CONFIGURATION_BUILD_DIR='{os.path.join(DERIVED_DATA_DIR, 'Build/Products/Debug-iphoneos')}' "
        f"SYMROOT='{os.path.join(DERIVED_DATA_DIR, 'Build/Products')}' "
        f"OTHER_LDFLAGS='$(inherited) -larchive'"
    )
    
    if not run_cmd(cmd):
        print("❌ ECMAIN Build Failed")
        return False
        
    print("✅ ECMAIN Build Succeeded")
    
    # Package IPA
    print("--- Packaging ECMAIN.ipa ---")
    
    # Try multiple common locations
    possible_paths = [
        os.path.join(DERIVED_DATA_DIR, "Build/Products/Debug-iphoneos/ECMAIN.app"),
        os.path.join(DERIVED_DATA_DIR, "Build/Products/Debug-iphoneos/ECMAIN/ECMAIN.app"), # Nested sometimes
    ]
    
    app_path = None
    for p in possible_paths:
        if os.path.exists(p):
            app_path = p
            break
            
    if not app_path:
        # Scan entire build root
        for root, dirs, files in os.walk(BUILD_ROOT):
            if "ECMAIN.app" in dirs:
                app_path = os.path.join(root, "ECMAIN.app")
                break
                
    if not app_path:
        print("❌ Could not find ECMAIN.app product")
        return False
        
    print(f"Found ECMAIN App: {app_path}")

    # --- INJECT TROLLSTORE HELPER ---
    print("--- Injecting trollstorehelper ---")
    # Check Theos build locations
    helper_src_candidates = [
        os.path.join(PROJECT_DIR, "external_sources/TrollStore/RootHelper/.theos/obj/debug/trollstorehelper"),
        os.path.join(PROJECT_DIR, "external_sources/TrollStore/RootHelper/.theos/obj/trollstorehelper"),
        os.path.join(PROJECT_DIR, "external_sources/TrollStore/.theos/obj/debug/trollstorehelper"), # Maybe built from root Makefile
    ]
    
    helper_found = False
    for candidate in helper_src_candidates:
        if os.path.exists(candidate):
            shutil.copy(candidate, os.path.join(app_path, "trollstorehelper"))
            run_cmd(f"chmod +x '{os.path.join(app_path, 'trollstorehelper')}'")
            print(f"✅ Injected trollstorehelper from {candidate}")
            helper_found = True
            break
            
    if not helper_found:
        print("⚠️ Warning: trollstorehelper binary not found. You may need to compile it inside external_sources/TrollStore/RootHelper.")

    # --- INJECT SIGNING TOOLS ---
    print("--- Injecting ldid and victim.p12 ---")
    installer_dir = os.path.join(PROJECT_DIR, "installer")
    ldid_src = os.path.join(installer_dir, "ldid")
    cert_src = os.path.join(installer_dir, "victim.p12")
    
    if os.path.exists(ldid_src) and os.path.exists(cert_src):
        shutil.copy(ldid_src, os.path.join(app_path, "ldid"))
        shutil.copy(cert_src, os.path.join(app_path, "victim.p12"))
        print("✅ Injected signing tools into App Bundle")
    else:
        print("⚠️ Warning: custom signing tools (ldid/victim.p12) not found in installer/, skipping injection")

    # --- MANUAL SIGNING WITH ENTITLEMENTS ---
    print("--- Manually Signing with Entitlements ---")

    # --- MANUAL SIGNING WITH ENTITLEMENTS ---
    print("--- Manually Signing with Entitlements ---")

    def perform_sign(path, entitlements=None):
        if not os.path.exists(path):
            return
            
        # Check for our custom ldid (Host version for build time)
        installer_ldid = os.path.join(PROJECT_DIR, "installer/ldid_host")
        
        if not os.path.exists(installer_ldid):
             # Fallback to codesign if ldid execution is impossible is unsafe for TrollStore
             # But better than crashing? No, TrollStore needs ldid pseudo-sign.
             print("⚠️ Error: ldid_host not found. Signing will likely fail validation.")
             return

        # Ensure ldid is executable
        run_cmd(f"chmod +x '{installer_ldid}'")

        # 1. Sign all nested frameworks/dylibs first (deepest first)
        frameworks_dir = os.path.join(path, "Frameworks")
        if os.path.exists(frameworks_dir):
            for item in os.listdir(frameworks_dir):
                item_path = os.path.join(frameworks_dir, item)
                if item.endswith(".framework") or item.endswith(".dylib"):
                    print(f"Signing inner library: {item} using ldid...")
                    
                    # Sign framework binary
                    sig_target = item_path
                    if item_path.endswith(".framework"):
                        # Find binary inside framework
                        bin_name = os.path.splitext(item)[0]
                        bin_path = os.path.join(item_path, bin_name)
                        if os.path.exists(bin_path):
                            # Check if it is a static library (ar archive) which ldid cannot sign
                            # and shouldn't be signed as it is linked into main binary usually.
                            # We can check using 'file' command or just try/catch?
                            # 'file' is safer.
                            try:
                                file_out = subprocess.check_output(f"file '{bin_path}'", shell=True).decode()
                                if "ar archive" in file_out:
                                    print(f"Skipping static library: {bin_name}")
                                    continue
                            except:
                                pass
                                
                            sig_target = bin_path
                            
                    run_cmd(f"'{installer_ldid}' -S '{sig_target}'")

        # 2. Sign the bundle itself
        print(f"Signing {os.path.basename(path)} using ldid...")
        
        cmd = f"'{installer_ldid}'"
        if entitlements:
             cmd += f" -S'{entitlements}'"
        else:
             cmd += " -S"
             
        # CoreTrust Bypass: Use the TrollStore extracted p12 (victim.p12)
        # This is CRITICAL. Without -K, ldid just does ad-hoc signing, which might not trick CoreTrust.
        installer_p12 = os.path.join(PROJECT_DIR, "installer/victim.p12")
        if os.path.exists(installer_p12):
             cmd += f" -K'{installer_p12}'"
        else:
             print("⚠️ Warning: victim.p12 not found. Signing might not bypass CoreTrust!")
        if os.path.isdir(path):
             binary_name = os.path.splitext(os.path.basename(path))[0]
             binary_path = os.path.join(path, binary_name)
             cmd += f" '{binary_path}'"
        else:
             cmd += f" '{path}'"
             
        run_cmd(cmd)

    # 1. Sign Tunnel Extension
    tunnel_path = os.path.join(app_path, "PlugIns/Tunnel.appex")
    tunnel_entitlements = os.path.join(PROJECT_DIR, "ECMAIN/Tunnel/Tunnel.entitlements")
    
    if os.path.exists(tunnel_path):
        perform_sign(tunnel_path, tunnel_entitlements if os.path.exists(tunnel_entitlements) else None)
    else:
        print(f"⚠️ Warning: Tunnel.appex not found: {tunnel_path}")
        
    # 2. Sign Main App
    app_entitlements = os.path.join(PROJECT_DIR, "ECMAIN/ECMAIN.entitlements")
    perform_sign(app_path, app_entitlements if os.path.exists(app_entitlements) else None)

    # ----------------------------------------
        
    payload_path = os.path.join(BUILD_ROOT, "Payload_ECMAIN")
    if os.path.exists(payload_path):
        shutil.rmtree(payload_path)
    os.makedirs(os.path.join(payload_path, "Payload"))
    
    run_cmd(f"cp -a '{app_path}' '{os.path.join(payload_path, 'Payload')}'/")
    
    ipa_output = os.path.join(IPA_DIR, "ECMAIN.ipa")
    if os.path.exists(ipa_output):
        os.remove(ipa_output)
        
    run_cmd(f"cd '{payload_path}' && zip -r -y '{ipa_output}' Payload -q")
    
    print(f"✅ Created {ipa_output}")
    return True

def main():
    parser = argparse.ArgumentParser(description="Unified Build Script for ECWDA and ECMAIN")
    parser.add_argument("--clean", action="store_true", help="Clean old build directories")
    parser.add_argument("--target", choices=["wda", "ecmain", "all"], default="all", help="Target to build")
    
    args = parser.parse_args()
    
    if args.clean:
        clean_old_dirs()
        
    prepare_dirs()
    
    success = True
    
    if args.target in ["wda", "all"]:
        if not build_wda():
            success = False
            
    if args.target in ["ecmain", "all"]:
        if not build_ecmain():
            success = False
            
    if success:
        print("\n✨ All Builds Completed Successfully! ✨")
        print(f"IPAs are located in: {IPA_DIR}")
    else:
        print("\n⚠️ Some builds failed.")
        sys.exit(1)

if __name__ == "__main__":
    main()
