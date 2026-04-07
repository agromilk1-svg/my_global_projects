import os
import subprocess
import glob

# Configuration
SDK = "iphoneos"
# TARGET MUST be 14.5 to avoid xpc_connection_create_mach_service availability errors
TARGET = "arm64-apple-ios14.5"
OUTPUT_DIR = "build_antigravity/ECHelper"

# Paths
BASE_DIR = "external_sources/TrollStore"
HELPER_DIR = os.path.join(BASE_DIR, "TrollHelper")
SHARED_DIR = os.path.join(BASE_DIR, "Shared")
SIGNING_TOOL = "external_sources/TrollStore/Exploits/fastPathSign/fastPathSign"
ENTITLEMENTS = os.path.join(HELPER_DIR, "entitlements.plist")

# Sources
# Official Makefile compiles: $(wildcard *.m) $(wildcard ../Shared/*.m)
HELPER_SOURCES = glob.glob(os.path.join(HELPER_DIR, "*.m"))
COMBINED_SOURCES = HELPER_SOURCES + glob.glob(os.path.join(SHARED_DIR, "*.m"))

print(f"Found {len(HELPER_SOURCES)} helper sources and {len(glob.glob(os.path.join(SHARED_DIR, '*.m')))} shared sources.")

# Build Command
cmd = [
    "xcrun", "-sdk", SDK, "clang",
    "-target", TARGET,
    "-fobjc-arc",
    
    # Frameworks
    "-framework", "UIKit",
    "-framework", "Foundation",
    "-framework", "CoreGraphics",
    "-framework", "MobileCoreServices",
    "-framework", "CoreServices",
    "-framework", "Security",
    "-framework", "CoreTelephony",
    
    # Private Frameworks (Linked via TBDs or SDK)
    # Note: official Makefile has -F. and links Preferences, MobileContainerManager
    "-F", HELPER_DIR, 
    "-framework", "Preferences",
    "-framework", "MobileContainerManager",
    
    # Flags
    "-fmodules", 
    "-Wl,-undefined,dynamic_lookup", # Crucial for libroot symbols
    "-larchive", 
    "-lc++", # Makefile has -lc++
    
    # Includes
    "-I", HELPER_DIR,
    "-I", SHARED_DIR,
    "-I", "/opt/homebrew/opt/libarchive/include", # Attempt to find libarchive headers if needed, similar to Makefile
    # Note: Makefile uses $(shell brew --prefix)/opt/libarchive/include. 
    # If this fails, we might need to adjust or assume headers are in SDK/standard paths.
    
    "-o", f"{OUTPUT_DIR}/ECHelper",
] + COMBINED_SOURCES

print(f"Compiling... {' '.join(cmd)}")

try:
    if not os.path.exists(OUTPUT_DIR):
        os.makedirs(OUTPUT_DIR)
        
    subprocess.check_call(cmd)
    print("✅ RealHelper Compiled Successfully!")
    
    # Signing
    # Command: fastPathSign --entitlements ents.plist binary
    print("Signing with fastPathSign...")
    sign_cmd = [
        SIGNING_TOOL,
        "--entitlements", ENTITLEMENTS,
        f"{OUTPUT_DIR}/ECHelper"
    ]
    
    subprocess.check_call(sign_cmd)
    print("✅ RealHelper Signed with CoreTrust Bypass!")
    
except subprocess.CalledProcessError as e:
    print(f"❌ Build/Sign Failed: {e}")
except Exception as e:
    print(f"❌ An error occurred: {e}")
