import os
import shutil
import glob
import subprocess
import sys

# Configuration
SDK = "iphoneos"
# TARGET MUST be 14.5 to avoid xpc_connection_create_mach_service availability errors
TARGET = "arm64-apple-ios14.5"
WORK_DIR = "echelper"
OUTPUT_BINARY = "echelper" # Relative to WORK_DIR

# Paths
BASE_DIR = "external_sources/TrollStore_Source"      # Source with my modifications
DEPS_DIR = "external_sources/TrollStore"             # Source with extra deps (archive.h, Frameworks)
HELPER_DIR = os.path.join(BASE_DIR, "TrollHelper")
SHARED_DIR = os.path.join(BASE_DIR, "Shared")
ROOT_HELPER_DIR = os.path.join(BASE_DIR, "RootHelper")
SIGNING_TOOL = "external_sources/TrollStore/Exploits/fastPathSign/fastPathSign"
THEOS_VENDOR_INC = "../external_sources/theos/vendor/include"
PRIVATE_SDK_DIR = "../build_antigravity/PrivateSDK"
FASTPATHSIGN_SRC = os.path.join(BASE_DIR, "Exploits/fastPathSign/src")
CHOMA_SRC = os.path.join(BASE_DIR, "ChOma/src")

# 1. Clean and Create Directory
# print(f"[*] Cleaning {WORK_DIR}...")
# if os.path.exists(WORK_DIR):
#    shutil.rmtree(WORK_DIR)
if not os.path.exists(WORK_DIR):
    os.makedirs(WORK_DIR)

# 2. Gather Sources
print("[*] Copying sources to isolated directory...")
def copy_files(src_dir, pattern, dest_dir=WORK_DIR):
    files = glob.glob(os.path.join(src_dir, pattern))
    copied = []
    for f in files:
        filename = os.path.basename(f)
        dest_path = os.path.join(dest_dir, filename)
        
        # Handle collision for main.m from RootHelper
        if filename == "main.m" and "RootHelper" in src_dir:
            dest_path = os.path.join(dest_dir, "root_main.m")
            print(f"Renaming RootHelper/main.m to root_main.m")
        
        # Skip main.m from fastPathSign (it's a standalone tool)
        if filename == "main.m" and "fastPathSign" in src_dir:
             print(f"Skipping main.m from fastPathSign")
             continue

        # Skip main.m from TrollHelper (PersistenceHelper) when building RootHelper
        if filename == "main.m" and "TrollHelper" in src_dir:
             print(f"Skipping main.m from TrollHelper (conflicts with RootHelper)")
             continue

        if not os.path.exists(dest_path):
            shutil.copy(f, dest_path)
            copied.append(dest_path)
        else:
             print(f"Skipping {filename} (exists)")
    return copied

root_srcs = copy_files(ROOT_HELPER_DIR, "*.m")
helper_srcs = copy_files(HELPER_DIR, "*.m")
shared_srcs = copy_files(SHARED_DIR, "*.m")

# Headers
copy_files(HELPER_DIR, "*.h")
copy_files(SHARED_DIR, "*.h")
copy_files(ROOT_HELPER_DIR, "*.h")
copy_files(FASTPATHSIGN_SRC, "*.h")
copy_files(CHOMA_SRC, "*.h")

# Copy MISSING headers from DEPS_DIR
DEPS_SHARED = os.path.join(DEPS_DIR, "Shared")
DEPS_HELPER = os.path.join(DEPS_DIR, "TrollHelper")
DEPS_ROOT = os.path.join(DEPS_DIR, "RootHelper")

copy_files(DEPS_SHARED, "*.h")
copy_files(DEPS_HELPER, "*.h")
copy_files(DEPS_ROOT, "*.h")

# ChOma & fastPathSign Sources
copy_files(FASTPATHSIGN_SRC, "*.c")
copy_files(FASTPATHSIGN_SRC, "*.m")
copy_files(CHOMA_SRC, "*.c")
copy_files(CHOMA_SRC, "*.m")

# Copy Templates for coretrust_bug
templates_src = os.path.join(FASTPATHSIGN_SRC, "Templates")
templates_dest = os.path.join(WORK_DIR, "Templates")
if os.path.exists(templates_src) and not os.path.exists(templates_dest):
    shutil.copytree(templates_src, templates_dest)
    print("Copied Templates directory")

# Entitlements
entitlements_dest = os.path.join(WORK_DIR, "entitlements.plist")
if not os.path.exists(entitlements_dest):
    shutil.copy(os.path.join(HELPER_DIR, "entitlements.plist"), WORK_DIR)

# Copy Frameworks from TrollHelper (Check DEPS first as they are likely there)
frameworks_to_copy = [
    "Preferences.framework",
    "SpringBoardServices.framework",
    "FrontBoardServices.framework",
    "BackBoardServices.framework",
    "MobileContainerManager.framework"
]
for fw in frameworks_to_copy:
    # Check Source first
    fw_path = os.path.join(HELPER_DIR, fw)
    if not os.path.exists(fw_path):
        # Check Deps
        fw_path = os.path.join(DEPS_HELPER, fw)
    
    if os.path.exists(fw_path):
        dest_fw = os.path.join(WORK_DIR, fw)
        if os.path.exists(dest_fw):
            shutil.rmtree(dest_fw)
        shutil.copytree(fw_path, dest_fw)
        print(f"Copied {fw} from {fw_path}")
    else:
        print(f"⚠️ Warning: {fw} not found in Helper or Deps dir")

# Create dummy version.h
with open(os.path.join(WORK_DIR, "version.h"), "w") as f:
    f.write("#define TROLLSTORE_VERSION \"2.0\"\n")
print("Created dummy version.h")

# OVERWRITE coretrust_bug.c with stub
if os.path.exists("stub_coretrust_bug.c"):
    shutil.copy("stub_coretrust_bug.c", os.path.join(WORK_DIR, "coretrust_bug.c"))
    print("⚠️ Overwrote coretrust_bug.c with stub (OpenSSL bypass)")

print(f"[*] Copied sources.")

# 3. Compile
all_sources = glob.glob(os.path.join(WORK_DIR, "*.m")) + glob.glob(os.path.join(WORK_DIR, "*.c"))
# Convert to basenames for compilation inside CWD
source_basenames = [os.path.basename(s) for s in all_sources]

entitlements_path = "entitlements.plist" # Relative to WORK_DIR

# Use explicit SDK path from Theos to allow using old APIs
SDK_PATH = "../external_sources/theos/sdks/iPhoneOS14.5.sdk"

cmd = [
    "xcrun", "clang",
    "-isysroot", SDK_PATH,
    "-target", TARGET,
    "-fobjc-arc",
    
    # Standard Frameworks
    "-framework", "UIKit",
    "-framework", "Foundation",
    "-framework", "CoreGraphics",
    "-framework", "MobileCoreServices",
    "-framework", "CoreServices",
    "-framework", "Security",
    "-framework", "CoreTelephony",
    
    # Private Frameworks
    "-F", ".",
    "-F", PRIVATE_SDK_DIR,
    "-framework", "SpringBoardServices",
    "-framework", "FrontBoardServices",
    "-framework", "BackBoardServices",
    "-framework", "MobileContainerManager", 
    "-framework", "Preferences",
    
    "-fmodules", 
    "-Wl,-undefined,dynamic_lookup",
    "-larchive", 
    "-lc++",
    
    # Includes
    "-I", ".", 
    "-I", "/opt/homebrew/opt/libarchive/include",
    "-I", THEOS_VENDOR_INC, # Important for private headers
    
    # Flags & Defines
    "-Wno-error=availability",
    "-Wno-availability",
    # "-DEMBEDDED_ROOT_HELPER=1", # CRITICAL FIX: Do NOT define this for RootHelper!
    "-DkCFCoreFoundationVersionNumber_iOS_15_0=1854.0",
    
    "-o", OUTPUT_BINARY, # Output filename (relative to CWD)
] + source_basenames

print(f"[*] Compiling {OUTPUT_BINARY}...")
print(" ".join(cmd))

try:
    # Run in WORK_DIR
    subprocess.check_call(cmd, cwd=WORK_DIR)
    print("✅ Compilation Successful!")
    
    # 4. Sign
    print("[*] Signing...")
    abs_sign_tool = os.path.abspath(SIGNING_TOOL)
    
    sign_cmd = [
        abs_sign_tool,
        "--entitlements", entitlements_path,
        OUTPUT_BINARY
    ]
    subprocess.check_call(sign_cmd, cwd=WORK_DIR)
    print("✅ Signed with CoreTrust Bypass!")
    
    # Verify
    subprocess.check_call(["codesign", "-dvvv", OUTPUT_BINARY], cwd=WORK_DIR)
    
except subprocess.CalledProcessError as e:
    print(f"❌ Failed: {e}")
except Exception as e:
    print(f"❌ Error: {e}")
