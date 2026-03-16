import os
import subprocess
import glob

# Configuration
SDK = "iphoneos"
TARGET = "arm64-apple-ios15.0"
OUTPUT_DIR = "../build_antigravity/ECHelper"

# Source Files
HELPER_SOURCES = [
    "ECHelper/main.m",
    "ECHelper/ECHelperAppDelegate.m",
    "ECHelper/ECHelperSceneDelegate.m",
    "ECHelper/ECHelperViewController.m"
]

# TrollStore Core Sources (Dependencies)
TS_SOURCES = [
    "TrollStoreCore/TSUtil.m",
    "TrollStoreCore/TSShim.m",
    "TrollStoreCore/libroot_dyn.c", # Include libroot source
]

# Create output dir
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Compile Command
cmd = [
    "xcrun", "-sdk", SDK, "clang",
    "-target", TARGET,
    "-fobjc-arc",
    "-framework", "UIKit",
    "-framework", "Foundation",
    "-framework", "CoreGraphics",
    "-framework", "MobileCoreServices",
    "-framework", "CoreServices",
    "-framework", "Security",
    "-framework", "CoreTelephony",
    "-Wl,-undefined,dynamic_lookup", # Allow undefined symbols (private APIs)
    "-o", f"{OUTPUT_DIR}/ECHelper",
] + HELPER_SOURCES + TS_SOURCES

print("Running compilation...")
print(" ".join(cmd))

try:
    subprocess.check_call(cmd)
    print("✅ ECHelper Compiled Successfully!")
    
    # Sign it with Fake Root Cert (installer/victim.p12) using our host ldid
    # Paths adjusted relative to script running in ECMAIN/
    ldid_path = "../installer/ldid_host"
    entitlements_path = "ECHelper.entitlements"
    cert_path = "../installer/victim.p12"
    
    if not os.path.exists(ldid_path):
        print(f"❌ Error: ldid_host not found at {ldid_path}")
        exit(1)
        
    subprocess.check_call(["chmod", "+x", ldid_path])
    
    sign_cmd = [
        ldid_path,
        f"-S{entitlements_path}",
        f"-K{cert_path}", # CRITICAL: CoreTrust Bypass
        f"{OUTPUT_DIR}/ECHelper"
    ]
    
    print(f"Signing with: {' '.join(sign_cmd)}")
    subprocess.check_call(sign_cmd)
    
    print("✅ ECHelper Signed (CoreTrust Bypass Applied)!")
    
except subprocess.CalledProcessError as e:
    print(f"❌ Build/Signing Failed: {e}")
