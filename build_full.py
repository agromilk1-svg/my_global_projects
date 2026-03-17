
import os
import shutil
import subprocess
import sys
import datetime
import re

# --- Configuration ---
PROJECT_ROOT = "/Users/hh/Desktop/my"
TROLLSTORE_SOURCE = os.path.join(PROJECT_ROOT, "external_sources/TrollStore_Source")
BUILD_ROOT = os.path.join(PROJECT_ROOT, "_build_full_temp")
OUTPUT_DIR = os.path.join(PROJECT_ROOT, "web_control_center/backend/updates")
THEOS_PATH = os.path.join(PROJECT_ROOT, "external_sources/theos")

# Xcode Config
XCODE_PROJECT = os.path.join(PROJECT_ROOT, "ECMAIN/ECMAIN.xcodeproj")
SCHEME_NAME = "ECMAIN"
DERIVED_DATA_DIR = os.path.join(BUILD_ROOT, "DerivedData")

def log(msg):
    print(f"\033[1;32m[+] {msg}\033[0m")

def error(msg):
    print(f"\033[1;31m[-] Error: {msg}\033[0m")
    sys.exit(1)

def update_build_version():
    log("Updating Build Version...")
    try:
        build_num_path = os.path.join(PROJECT_ROOT, ".build_number")
        if os.path.exists(build_num_path):
            with open(build_num_path, "r") as f:
                content = f.read().strip()
                if content:
                    num = int(content)
                else:
                    num = 100
        else:
            num = 100
        
        num += 1
        
        with open(build_num_path, "w") as f:
            f.write(str(num))
            
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
        version_str = f"Build: {now} #{num} (Auto)"
        
        # Modify ViewController.m directly
        vc_path = os.path.join(PROJECT_ROOT, "ECMAIN/ViewController.m")
        if os.path.exists(vc_path):
            with open(vc_path, "r") as f:
                vc_content = f.read()
            
            # Use regex to replace version string
            new_line = f'versionLabel.text = @"{version_str}";'
            vc_content = re.sub(r'versionLabel\.text = @".*";', new_line, vc_content)
            
            with open(vc_path, "w") as f:
                f.write(vc_content)
                
            log(f"Updated ViewController.m with: {version_str}")
        else:
            error(f"ViewController.m not found at {vc_path}")
        
        # --- 自动更新支持：生成版本常量 ---
        
        # 更新 ECBuildInfo.h，写入整数版本号常量
        build_info_path = os.path.join(PROJECT_ROOT, "ECMAIN/ECBuildInfo.h")
        with open(build_info_path, "w") as f:
            f.write(f'#define EC_BUILD_INFO @"Build: {now} #{num} (Auto)"\n')
            f.write(f'#define EC_BUILD_VERSION {num}\n')
        log(f"Updated ECBuildInfo.h with EC_BUILD_VERSION={num}")
        
        # ecmain_version.json 在编译成功后才生成（见 main() 末尾）
            
    except Exception as e:
        error(f"Failed to update build version: {e}")

def run_cmd(cmd, cwd=None, env=None, ignore_error=False):
    print(f"[*] Executing: {cmd}")
    try:
        subprocess.check_call(cmd, shell=True, cwd=cwd, env=env)
    except subprocess.CalledProcessError as e:
        if ignore_error:
            print(f"[-] Ignored error: {e}")
        else:
            error(f"Command failed: {e}")

# --- Step 1: Build RootHelper (C/ObjC) ---
def build_native_helper():
    log("Starting Native Helper Build (RootHelper)...")
    
    # 1. Setup Build Dir
    helper_build_dir = os.path.join(BUILD_ROOT, "Source")
    if os.path.exists(helper_build_dir):
        shutil.rmtree(helper_build_dir)
    shutil.copytree(TROLLSTORE_SOURCE, helper_build_dir)
    
    # 1.5 IMPORTANT: Overlay ECMAIN/RootHelper files to include our fixes (LSEnvironment, etc.)
    ecmain_rh_dir = os.path.join(PROJECT_ROOT, "ECMAIN/RootHelper")
    dest_rh_dir = os.path.join(helper_build_dir, "RootHelper")
    if os.path.exists(ecmain_rh_dir):
        log("Overlaying ECMAIN/RootHelper fixes onto TrollStore source...")
        for item in os.listdir(ecmain_rh_dir):
            src_item = os.path.join(ecmain_rh_dir, item)
            dst_item = os.path.join(dest_rh_dir, item)
            if os.path.isfile(src_item):
                shutil.copy2(src_item, dst_item)
                log(f"  Copied: {item}")
    else:
        log("Warning: ECMAIN/RootHelper not found, using original TrollStore sources.")
    
    # 2. Patch RootHelper/Makefile
    log("Patching RootHelper Makefile...")
    rh_makefile = os.path.join(helper_build_dir, "RootHelper/Makefile")
    with open(rh_makefile, 'r') as f: content = f.read()
    
    # Inject Headers & Flags
    content = "ADDITIONAL_CFLAGS += -I../Shared\n" + content
    content = "ADDITIONAL_LDFLAGS += -larchive\n" + content
    
    # Fix OpenSSL & Libarchive paths
    openssl_include = os.path.join(PROJECT_ROOT, "external_sources/openssl/include")
    libarchive_include = "/opt/homebrew/opt/libarchive/include" # Default Homebrew location
    if not os.path.exists(libarchive_include):
         # Try alternate location or fallback to ../Shared if we copied headers there?
         # But unarchive.m uses <archive.h> standard include style.
         # Let's add the include flag correctly.
         libarchive_include = os.path.join(PROJECT_ROOT, "external_sources/libarchive/include") # If user has it locally
    
    # Force use of local include if header exists in Shared
    # But unarchive.m uses <archive.h>, so we should add -I/opt/homebrew...
    
    content = content.replace("$(shell pkg-config --cflags libcrypto)", f"-I{openssl_include}")
    # The original Makefiles used $(shell brew --prefix)/opt/libarchive/include
    # We replace it with hardcoded path or better determine it.
    
    # Just hardcode to the brew path that works on this machine (mac)
    content = content.replace("$(shell brew --prefix)/opt/libarchive/include", "/opt/homebrew/opt/libarchive/include")
    
    with open(rh_makefile, 'w') as f: f.write(content)
    
    # 3. Patch fastPathSign/Makefile
    log("Patching fastPathSign Makefile...")
    fps_makefile = os.path.join(helper_build_dir, "Exploits/fastPathSign/Makefile")
    if os.path.exists(fps_makefile):
        with open(fps_makefile, 'r') as f: fps_content = f.read()
        openssl_lib = os.path.join(PROJECT_ROOT, "external_sources/openssl/lib")
        fps_content = fps_content.replace("$(shell pkg-config --cflags libcrypto)", f"-I{openssl_include}")
        fps_content = fps_content.replace("$(shell pkg-config --libs libcrypto)", f"-L{openssl_lib} -Lc++ -lcrypto")
        with open(fps_makefile, 'w') as f: f.write(fps_content)

    # 4. (REMOVED: packageType variable is actually used, commenting it out caused compilation errors)
    # Old code was commenting out the packageType declaration in main.m but it's needed for the FMWK check

    # 5.1 Patch ChOma/src/MachO.c to bypass encryption check
    log("Patching ChOma to bypass encryption check...")
    macho_c = os.path.join(helper_build_dir, "ChOma/src/MachO.c")
    if os.path.exists(macho_c):
        with open(macho_c, 'r') as f: macho_content = f.read()
        # Replace macho_is_encrypted to always return false
        original_func = '''bool macho_is_encrypted(MachO *macho)
{
    __block bool isEncrypted = false;
    macho_enumerate_load_commands(macho, ^(struct load_command loadCommand, uint64_t offset, void *cmd, bool *stop) {
        if (loadCommand.cmd == LC_ENCRYPTION_INFO_64 || loadCommand.cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *encryptionInfoCommand = cmd;
            ENCRYPTION_INFO_COMMAND_APPLY_BYTE_ORDER(encryptionInfoCommand, LITTLE_TO_HOST_APPLIER);
            if (encryptionInfoCommand->cryptid == 1) {
                *stop = true;
                isEncrypted = true;
            }
        }
    });
    return isEncrypted;
}'''
        patched_func = '''bool macho_is_encrypted(MachO *macho)
{
    // ECMAIN: Bypass encryption check to allow installing encrypted IPAs
    // This allows installation of App Store apps with SC_Info authorization
    return false;
}'''
        if original_func in macho_content:
            macho_content = macho_content.replace(original_func, patched_func)
            with open(macho_c, 'w') as f: f.write(macho_content)
            log("ChOma encryption check bypassed!")
        else:
            log("Warning: Could not find macho_is_encrypted function to patch")

    # 5. Patch Root Makefile (Remove unneeded targets)
    root_makefile = os.path.join(helper_build_dir, "Makefile")
    with open(root_makefile, 'r') as f: rm_content = f.read()
    rm_content = rm_content.replace("make_trollhelper_package", "")
    with open(root_makefile, 'w') as f: f.write(rm_content)

    # 6. Copy Shared Headers
    shutil.copytree(
        os.path.join(TROLLSTORE_SOURCE, "Shared"), 
        os.path.join(helper_build_dir, "Shared"),
        dirs_exist_ok=True
    )
    
    # 7. Setup Environment
    env = os.environ.copy()
    env["THEOS"] = THEOS_PATH
    
    # 7.5 Build OpenSSL for iOS (Required for RootHelper linking)
    log("Building OpenSSL for iOS (arm64)...")
    openssl_src = os.path.join(PROJECT_ROOT, "external_sources/openssl1.1_src")
    openssl_out = os.path.join(PROJECT_ROOT, "external_sources/openssl_ios_arm64")

    # 7.6 Build OpenSSL for macOS (Required for fastPathSign tool)
    log("Building OpenSSL for macOS (Host)...")
    openssl_macos_out = os.path.join(PROJECT_ROOT, "external_sources/openssl_macos")
    
    if not os.path.exists(os.path.join(openssl_macos_out, "lib/libcrypto.a")):
        log("Compiling OpenSSL for macOS...")
        # Clean source (or copy it to temp to avoid conflict with iOS build artifacts?)
        # Best to copy source to temp dir for macOS build to process in parallel/cleanly
        openssl_macos_src = os.path.join(BUILD_ROOT, "openssl_macos_src")
        if os.path.exists(openssl_macos_src): shutil.rmtree(openssl_macos_src)
        shutil.copytree(openssl_src, openssl_macos_src)
        
        # Configure
        # Assume x86_64 based on uname -m, or detect?
        # Safe to usually target the current host
        import platform
        machine = platform.machine()
        target = "darwin64-x86_64-cc" if machine == "x86_64" else "darwin64-arm64-cc"
        
        env_mac = os.environ.copy()
        # Ensure we use host clang
        env_mac["CC"] = "clang"
        
        run_cmd("make clean", cwd=openssl_macos_src, ignore_error=True)
        run_cmd(f"./Configure {target} no-shared no-dso no-hw no-engine --prefix={openssl_macos_out}", cwd=openssl_macos_src, env=env_mac)
        run_cmd("make -j4 build_libs", cwd=openssl_macos_src, env=env_mac)
        run_cmd("make install_sw", cwd=openssl_macos_src, env=env_mac)
    else:
        log("OpenSSL for macOS already built. Skipping.")
    
    # Check if iOS already built
    # ... logic continues ...
    if os.path.exists(os.path.join(openssl_out, "lib/libcrypto.a")):
        log("OpenSSL for iOS already built. Skipping.")
    elif os.path.exists(openssl_src):
        # clean first
        run_cmd(f"make -C {openssl_src} clean", ignore_error=True)
        # ... (rest of build logic, condensed)
        # Determine SDK path
        sdk_path_ssl = os.path.join(THEOS_PATH, "sdks/iPhoneOS14.5.sdk")
        # Check if Configure has iphoneos-cross
        has_ios_config = False
        try:
            with open(os.path.join(openssl_src, "Configure"), "r") as f:
                content = f.read()
                if "iphoneos-cross" in content:
                    has_ios_config = True
        except:
            pass
        config_target = "iphoneos-cross" if has_ios_config else "BSD-generic64"
        env = os.environ.copy()
        env["CC"] = f"xcrun -sdk iphoneos clang -arch arm64 -isysroot {sdk_path_ssl} -miphoneos-version-min=14.0"
        env["CROSS_TOP"] = os.path.dirname(os.path.dirname(sdk_path_ssl)) 
        env["CROSS_SDK"] = os.path.basename(sdk_path_ssl)
        cmd_conf = f"./Configure {config_target} no-shared no-dso no-hw no-engine --prefix={openssl_out}"
        run_cmd(cmd_conf, cwd=openssl_src, env=env)
        run_cmd("make -j4", cwd=openssl_src, env=env)
        run_cmd("make install_sw", cwd=openssl_src, env=env)
        run_cmd(f"lipo -info {os.path.join(openssl_out, 'lib/libcrypto.a')}", ignore_error=True) 
        
    # 8. Build with Manual Clang (Reliable)
    log("Compiling Helper with Clang...")
    
    # Define Sources
    sources = [
        "RootHelper/main.m",
        "RootHelper/devmode.m",
        "RootHelper/jit.m",
        "RootHelper/uicache.m",
        "RootHelper/unarchive.m",
        "Shared/TSUtil.m",
    ]
    sources = [os.path.join(helper_build_dir, s) for s in sources]
    for s in sources:
        if not os.path.exists(s): error(f"Source file missing: {s}")
             
    # Output
    output_bin = os.path.join(helper_build_dir, "trollstorehelper")
    
    # RESTORE SDK PATH DEFINITION
    sdk_path = os.path.join(THEOS_PATH, "sdks/iPhoneOS14.5.sdk")
    if not os.path.exists(sdk_path):
         # Try sourcing latest sdk in Theos
         sdks_list = os.listdir(os.path.join(THEOS_PATH, "sdks"))
         sdks_list = [s for s in sdks_list if "iPhoneOS" in s]
         sdks_list.sort()
         if sdks_list:
             sdk_path = os.path.join(THEOS_PATH, "sdks", sdks_list[-1])
             log(f"Selected SDK: {sdk_path}")
         else:
             error("No SDK found in Theos.")

    # Generate version.h
    with open(os.path.join(helper_build_dir, "version.h"), "w") as f:
        f.write('#define TROLLSTORE_VERSION "2.0"')
        
    # 保留原始 unarchive.m（基于 libarchive，支持 tar/gzip/zip 所有格式）
    # 不再覆写为 ZIP-only 解压器，以支持 OTA 自动更新的 ecmain.tar 解压
    log("Using original libarchive-based unarchive.m (supports tar/gzip/zip)")

    # Add ChOma sources
    # Use patched ChOma from helper_build_dir (has macho_is_encrypted bypass)
    choma_src = os.path.join(helper_build_dir, "ChOma/src")
    if os.path.exists(choma_src):
        for f in os.listdir(choma_src):
            if f.endswith(".c"):
                sources.append(os.path.join(choma_src, f))

    # Add fastPathSign implementation (Source for linking)
    fps_src = os.path.join(TROLLSTORE_SOURCE, "Exploits/fastPathSign/src")
    if os.path.exists(fps_src):
        for f in os.listdir(fps_src):
            # Include .c files (except main.c) and codesign.m
            if f.endswith(".c") and f != "main.c": 
                sources.append(os.path.join(fps_src, f))
            elif f == "codesign.m":
                sources.append(os.path.join(fps_src, f))

    # COMPILE fastPathSign TOOL (Required for signing later)
    # This must be a HOST binary (macOS)
    log("Compiling fastPathSign tool (macOS)...")
    fps_bin_path = os.path.join(helper_build_dir, "Exploits/fastPathSign/fastPathSign")
    os.makedirs(os.path.dirname(fps_bin_path), exist_ok=True)
    fps_src_dir = os.path.join(TROLLSTORE_SOURCE, "Exploits/fastPathSign/src")
    
    # We compile it using host clang, linking only necessary ChOma files
    # Note: ChOma sources need to be included.
    fps_cmd = (
        f"clang -O3 "
        f"{os.path.join(fps_src_dir, 'main.m')} "
        f"{os.path.join(fps_src_dir, 'codesign.m')} "
        f"{os.path.join(fps_src_dir, 'coretrust_bug.c')} "
        f"-o {fps_bin_path} "
        f"-I {os.path.join(TROLLSTORE_SOURCE, 'ChOma/src')} "
        f"-I {os.path.join(TROLLSTORE_SOURCE, 'Exploits/fastPathSign/src')} " 
        # Include ChOma sources directly
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/MachO.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/Util.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/PatchFinder.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/PatchFinder_arm64.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/arm64.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/CSBlob.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/MemoryStream.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/FileStream.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/BufferedStream.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/CodeDirectory.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/FAT.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/MachOLoadCommand.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/Host.c')} "
        f"{os.path.join(TROLLSTORE_SOURCE, 'ChOma/src/Base64.c')} "
        f"-fobjc-arc -framework Foundation -framework Security "
        f"-I {os.path.join(openssl_macos_out, 'include')} "
        f"-L {os.path.join(openssl_macos_out, 'lib')} "
        f"-lcrypto"
    )
    run_cmd(fps_cmd, ignore_error=False)

    cmd = (
        f"xcrun clang -isysroot {sdk_path} -target arm64-apple-ios14.0 "
        f"-fobjc-arc -O2 -fmodules -fcxx-modules " 
        f"-DTSLog=NSLog -DkCFCoreFoundationVersionNumber_iOS_15_0=1854.0 " 
        f"-I {helper_build_dir} " 
        f"-I {os.path.join(helper_build_dir, 'Shared')} "
        f"-I {os.path.join(helper_build_dir, 'ChOma/src')} " 
        f"-I {os.path.join(helper_build_dir, 'Exploits/fastPathSign/src')} " 
        f"-I {os.path.join(THEOS_PATH, 'vendor/include')} " 
        # libarchive 头文件路径（用于 unarchive.m 的 tar/gzip 解压）
        f"-I {os.path.join(PROJECT_ROOT, 'external_sources/libarchive_ios_arm64/include')} " 
        # Point to NEW OpenSSL Include
        f"-I {os.path.join(openssl_out, 'include')} "
        # Point to NEW OpenSSL Lib
        f"-L {os.path.join(openssl_out, 'lib')} "
        f"-lcrypto " 
        # 链接 libarchive（支持 tar/gzip/zip 解压）
        f"-larchive " 
        # Private Frameworks
        f"-F {os.path.join(THEOS_PATH, 'sdks/iPhoneOS14.5.sdk/System/Library/PrivateFrameworks')} " 
        f"-framework Foundation -framework CoreFoundation -framework UIKit -framework MobileCoreServices "
        f"-framework BackBoardServices -framework FrontBoardServices -framework MobileContainerManager -framework RunningBoardServices -framework CoreTelephony "
        f"-o {output_bin} " + " ".join(sources)
    )
    
    run_cmd(cmd)
    
    # Sign it ad-hoc immediately
    ldid_bin = os.path.join(THEOS_PATH, "toolchain/linux/iphone/bin/ldid")
    if not os.path.exists(ldid_bin):
        ldid_bin = os.path.join(THEOS_PATH, "bin/ldid")  # Try alternate location
    if not os.path.exists(ldid_bin):
        ldid_bin = "ldid"  # Fallback to PATH
    run_cmd(f"'{ldid_bin}' -S {output_bin}", ignore_error=True)

    built_helper = output_bin
    
    if not os.path.exists(built_helper):
        error("Clang compilation failed.")
        
    log(f"Native Helper compiled at: {built_helper}")
    return built_helper

# --- Step 1.5: Build Device Spoof Dylib ---
def build_device_spoof_dylib():
    """编译设备信息伪装 dylib"""
    log("Building libswiftCompatibilityPacks.dylib...")
    
    dylib_src = os.path.join(PROJECT_ROOT, "ECMAIN/Dylib")
    dylib_output = os.path.join(dylib_src, "libswiftCompatibilityPacks.dylib")
    
    if not os.path.exists(dylib_src):
        log("Dylib source not found, skipping...")
        return None
    
    # 使用 Makefile 编译 (需要设置 DEVELOPER_DIR)
    env = os.environ.copy()
    env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
    # Remove ignore_error=True to see failure
    run_cmd("make clean && make", cwd=dylib_src, env=env)
    
    if os.path.exists(dylib_output):
        log(f"Device Spoof Dylib compiled at: {dylib_output}")
    else:
        log("Device Spoof Dylib build failed (non-critical, continuing...)")
        return None
    
    # 2.6 Build Dump Dylib
    log(f"Building Dump Dylib...")
    dump_src = os.path.join(PROJECT_ROOT, "ECMAIN/Dylib/dump.c")
    dump_dylib = os.path.join(PROJECT_ROOT, "ECMAIN/Dylib/dump.dylib")
    # 简单 clang 编译 (需要 DEVELOPER_DIR)
    # Suppress deprecation warnings for cleaner output
    run_cmd(f"xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -Wno-deprecated-declarations -o {dump_dylib} {dump_src}", env=env)
    log(f"Dump Dylib compiled at: {dump_dylib}")

    # Sign Dump Dylib (Critical: Unsigned dylib won't load!)
    # Use codesign with entitlements for library validation bypass
    dump_entitlements = os.path.join(PROJECT_ROOT, "ECMAIN/Dylib/dump.entitlements")
    log(f"Signing dump.dylib with codesign and entitlements...")
    if os.path.exists(dump_entitlements):
        run_cmd(f"codesign -f -s - --entitlements '{dump_entitlements}' '{dump_dylib}'", ignore_error=True)
    else:
        run_cmd(f"codesign -f -s - '{dump_dylib}'", ignore_error=True)
    
    # Apply CT bypass using fastPathSign if available
    fastpathsign = os.path.join(BUILD_ROOT, "Source/Exploits/fastPathSign/fastPathSign")
    if os.path.exists(fastpathsign):
        log(f"Applying CT bypass to dump.dylib...")
        run_cmd(f"'{fastpathsign}' '{dump_dylib}'", ignore_error=True)
    else:
        log("Warning: fastPathSign not available, dump.dylib may not load on device")

    # 2.7 Generate ECDumpBinary.h
    log("Generating ECDumpBinary.h...")
    import base64
    if os.path.exists(dump_dylib):
        with open(dump_dylib, "rb") as f:
            b64 = base64.b64encode(f.read()).decode('utf-8')
        
        header_path = os.path.join(PROJECT_ROOT, "ECMAIN/ECMAIN/UI/ECDumpBinary.h")
        with open(header_path, "w") as f:
            f.write(f'#define DUMP_DYLIB_BASE64 @"{b64}"\n')
        log(f"Generated {header_path}")
    else:
        log("Error: dump.dylib not found, cannot generate header.")
    
    # FIX: Update Dylib ID to match expected load path
    log(f"Fixing dylib ID for {dylib_output}...")
    run_cmd(f"install_name_tool -id @executable_path/Frameworks/libswiftCompatibilityPacks.dylib '{dylib_output}'", ignore_error=True)

    return dylib_output # 返回 dylib 路径

# --- Step 1.6: Build Persistence Helper (ECHelper) ---
def build_persistence_helper():
    log("Building Persistence Helper (ECHelper) from 'echelper' directory...")
    
    src_dir = os.path.join(PROJECT_ROOT, "echelper")
    if not os.path.exists(src_dir):
        # Fallback: Check if user meant the binary provided directly? 
        # But assuming source build is preferred.
        error(f"Persistence Helper source directory not found: {src_dir}")

    # Use make to build it
    # ensure THEOS is set
    env = os.environ.copy()
    env['THEOS'] = THEOS_PATH
    
    # Clean and Make
    run_cmd("make clean", cwd=src_dir, env=env, ignore_error=True)
    run_cmd("make", cwd=src_dir, env=env)
    
    # Find output binary
    # Theos usually puts it in .theos/obj/debug/ECHelper.app/ECHelper
    # specific path depends on valid architecture and debug/release
    # We can check likely locations
    
    possible_paths = [
        os.path.join(src_dir, ".theos/obj/debug/ECHelper.app/ECHelper"),
        os.path.join(src_dir, ".theos/obj/debug/arm64/ECHelper.app/ECHelper"),
        os.path.join(src_dir, ".theos/obj/debug/ECHelper"), # sometimes just binary
    ]
    
    built_bin = None
    for p in possible_paths:
        if os.path.exists(p):
            built_bin = p
            break
            
    if not built_bin:
        # try find command
        for root, dirs, files in os.walk(os.path.join(src_dir, ".theos")):
            if "ECHelper" in files:
                found = os.path.join(root, "ECHelper")
                # check if executable
                if os.access(found, os.X_OK):
                    built_bin = found
                    break
    
    if not built_bin:
        error("Could not find compiled ECHelper binary after make.")

    # Copy to build root as PersistenceHelper
    output_bin = os.path.join(BUILD_ROOT, "PersistenceHelper")
    shutil.copy(built_bin, output_bin)
    
    # Sign with Entitlements + CT Bypass
    log("Signing Persistence Helper...")
    entitlements_path = os.path.join(src_dir, "entitlements.plist")
    if os.path.exists(entitlements_path):
        run_cmd(f"codesign -f -s - --entitlements '{entitlements_path}' '{output_bin}'", ignore_error=True)
    else:
        log("Warning: echelper/entitlements.plist not found, using ad-hoc signature.")
        run_cmd(f"codesign -f -s - '{output_bin}'", ignore_error=True)
        
    # Apply CT Bypass
    fastpathsign = os.path.join(BUILD_ROOT, "Source/Exploits/fastPathSign/fastPathSign")
    if os.path.exists(fastpathsign):
        run_cmd(f"'{fastpathsign}' '{output_bin}'", ignore_error=True)
    else:
        log("Warning: fastPathSign not found for Persistence Helper.")
        
    log(f"Persistence Helper compiled at: {output_bin}")
    return output_bin

# --- Step 2: Build UI App (Xcode) ---
def build_ui_app():
    log("Building UI App (ECMAIN)...")

    # Clean Env - remove variables that might interfere with xcodebuild
    env = os.environ.copy()
    for k in ['C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH', 'LIBRARY_PATH', 'CPATH', 'CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS']:
        if k in env: del env[k]

    # Set DEVELOPER_DIR to use full Xcode instead of CommandLineTools
    env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'

    cmd = (
        f"DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build "
        f"-project {XCODE_PROJECT} "
        f"-target {SCHEME_NAME} "
        f"-configuration Release "
        f"-sdk iphoneos "
        f"SYMROOT={BUILD_ROOT}/build "
        f"ASSETCATALOG_COMPILER_APPICON_NAME=\"\" "
        f"CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO "
        f"GCC_TREAT_WARNINGS_AS_ERRORS=NO "
        f"SUPPORTED_PLATFORMS=iphoneos "
        f"ONLY_ACTIVE_ARCH=NO "
        f"ENABLE_ONLY_ACTIVE_RESOURCES=YES "
        f"ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS=NO "
        f"OTHER_LDFLAGS=\"-lz\" "
    )
    run_cmd(cmd, cwd=PROJECT_ROOT, env=env)
    
    # Manual Asset Compilation (Bypass broken thinning in xcodebuild)
    log("Compiling Assets Manually...")
    
    # We compile to a standalone output dir and then copy to App
    assets_out_dir = os.path.join(BUILD_ROOT, "assets_out")
    if os.path.exists(assets_out_dir): shutil.rmtree(assets_out_dir)
    os.makedirs(assets_out_dir)
    
    app_path = os.path.join(BUILD_ROOT, "build/Release-iphoneos/ECMAIN.app")
    assets_path = os.path.join(PROJECT_ROOT, "ECMAIN/Assets.xcassets")
    if os.path.exists(assets_path):
        import subprocess
        log("Running actool to generate Assets.car...")
        cmd_actool = (
            f"DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun actool "
            f"'{assets_path}' "
            f"--compile '{assets_out_dir}' "
            f"--platform iphoneos "
            f"--minimum-deployment-target 15.0 "
            f"--app-icon AppIcon "
            f"--output-partial-info-plist '{BUILD_ROOT}/partial.plist' "
        )
        run_cmd(cmd_actool, env=env, ignore_error=True)
    # Find .app
    app_path = os.path.join(BUILD_ROOT, "build/Release-iphoneos/ECMAIN.app")
    if not os.path.exists(app_path):
        # Check other common locations
        alt_paths = [
            os.path.join(PROJECT_ROOT, "build_xcode/Build/Products/Release-iphoneos/ECMAIN.app"),
            os.path.join(PROJECT_ROOT, "build/Build/Products/Release-iphoneos/ECMAIN.app"),
        ]
        for alt in alt_paths:
            if os.path.exists(alt):
                app_path = alt
                break
    if not os.path.exists(app_path):
        # Fallback search in DerivedData
        for root, dirs, files in os.walk(DERIVED_DATA_DIR):
            if "ECMAIN.app" in dirs:
                app_path = os.path.join(root, "ECMAIN.app")
                break
    if not os.path.exists(app_path):
        # Final fallback: search project root
        for root, dirs, files in os.walk(PROJECT_ROOT):
            if "ECMAIN.app" in dirs and "Release-iphoneos" in root:
                app_path = os.path.join(root, "ECMAIN.app")
                break
                
    if app_path and os.path.exists(app_path):
        # Now copy compiled assets (Assets.car & icons) into the found app_path
        if os.path.exists(assets_out_dir):
            log("Copying manually compiled assets to App Bundle...")
            for f in os.listdir(assets_out_dir):
                shutil.copy(os.path.join(assets_out_dir, f), os.path.join(app_path, f))
    
    # Merge partial.plist into Info.plist to restore AppIcon keys
    partial_plist_path = os.path.join(BUILD_ROOT, "partial.plist")
    if os.path.exists(app_path) and os.path.exists(partial_plist_path):
        import plistlib
        log("Merging AppIcon keys from partial.plist...")
        info_plist_path = os.path.join(app_path, "Info.plist")
        
        # Convert Info.plist to XML first in case it's binary
        run_cmd(f"plutil -convert xml1 '{info_plist_path}'")
        
        try:
            with open(partial_plist_path, 'rb') as f:
                partial_data = plistlib.load(f)
            with open(info_plist_path, 'rb') as f:
                info_data = plistlib.load(f)
                
            for k, v in partial_data.items():
                info_data[k] = v
                
            with open(info_plist_path, 'wb') as f:
                plistlib.dump(info_data, f)
        except Exception as e:
            log(f"Failed to merge partial.plist: {e}")
                
    if not os.path.exists(app_path):
        error("ECMAIN.app build failed.")
        
    log(f"UI App compiled at: {app_path}")
    
    # --- POST-BUILD PATCHING ---
    log("Patching Info.plist with TrollStore keys...")
    info_plist = os.path.join(app_path, "Info.plist")
    
    # Use plutil to convert to xml first
    run_cmd(f"plutil -convert xml1 {info_plist}")
    
    with open(info_plist, "r") as f:
        plist_content = f.read()
        
    # 1. Fix Bundle Identifier (Ensure it is com.ecmain.app)
    # The Xcode project likely sets this, but we validate specific keys.
        
    # 2. Add Keys (TSRootHelperPath, URL Schemes) matching OUR ID
    if "TSRootHelperPath" not in plist_content:
        plist_content = plist_content.replace("</dict>", """
    <key>TSRootHelperPath</key>
    <string>trollstorehelper</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.ecmain.app</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>trollstore</string>
                <string>apple-magnifier</string>
            </array>
        </dict>
    </array>
    <key>TSAppGroup</key>
    <string>group.com.ecmain.shared</string>
    <key>UIBackgroundModes</key>
    <array>
        <string>audio</string>
        <string>location</string>
        <string>voip</string>
        <string>fetch</string>
        <string>remote-notification</string>
        <string>processing</string>
    </array>
</dict>""")

    with open(info_plist, "w") as f:
        f.write(plist_content)
        
    # Convert back to binary (optional but good practice)
    # run_cmd(f"plutil -convert binary1 {info_plist}")

    return app_path

# --- Step 3: Sign & Package ---
def sign_binary(path, entitlements_path=None):
    log(f"Signing {os.path.basename(path)}...")
    
    # 1. Codesign (Apply Entitlements & Ad-Hoc Signature)
    # This creates the signature blob that fastPathSign will later patch.
    cmd = f"codesign -f -s - --preserve-metadata=identifier,entitlements '{path}'"
    if entitlements_path:
        cmd = f"codesign -f -s - --entitlements '{entitlements_path}' '{path}'"
        
    try:
        run_cmd(cmd)
    except:
        log("Strict signing failed, falling back to ad-hoc...")
        run_cmd(f"codesign -f -s - '{path}'")

    # 2. CT Bypass (Patch the signature)
    # MUST RUN AFTER CODESIGN!
    fastpathsign = os.path.join(BUILD_ROOT, "Source/Exploits/fastPathSign/fastPathSign")
    if os.path.exists(fastpathsign):
        # If directory (bundle), find binary
        target_bin = path
        if os.path.isdir(path):
            name = os.path.splitext(os.path.basename(path))[0]
            target_bin = os.path.join(path, name)
            
        run_cmd(f"'{fastpathsign}' '{target_bin}'")
    else:
        print("[-] Warning: fastPathSign not found (skipped CT bypass).")

def package_all(app_path, helper_path, dylib_path=None, persistence_helper_path=None):
    log("Assembling Package...")
    
    staging_dir = os.path.join(BUILD_ROOT, "Staging")
    if os.path.exists(staging_dir): shutil.rmtree(staging_dir)
    os.makedirs(staging_dir)
    
    # 1. Copy App
    final_app = os.path.join(staging_dir, "ECMAIN.app")
    shutil.copytree(app_path, final_app)
    
    # 1.5 Embed Mihomo.framework (Required for VPN Tunnel)
    mihomo_src = os.path.join(DERIVED_DATA_DIR, "Build/Products/Release-iphoneos/Mihomo.framework")
    if not os.path.exists(mihomo_src):
        # Try alternate location
        mihomo_src = os.path.join(PROJECT_ROOT, "ECMAIN/Frameworks/Mihomo.xcframework/ios-arm64/Mihomo.framework")
    
    if os.path.exists(mihomo_src):
        log(f"Embedding Mihomo.framework from {mihomo_src}...")
        frameworks_dir = os.path.join(final_app, "Frameworks")
        os.makedirs(frameworks_dir, exist_ok=True)
        dest_mihomo = os.path.join(frameworks_dir, "Mihomo.framework")
        if os.path.exists(dest_mihomo): shutil.rmtree(dest_mihomo)
        shutil.copytree(mihomo_src, dest_mihomo)
        log("Mihomo.framework embedded successfully")
    else:
        log("WARNING: Mihomo.framework not found! VPN may not work.")
    
    # 2. Inject Helper (The critical step!)
    dest_helper = os.path.join(final_app, "trollstorehelper")
    shutil.copy(helper_path, dest_helper)
    os.chmod(dest_helper, 0o755)
    log(f"Injected new helper from {helper_path}")
    
    # 2.5. Inject Device Spoof Dylib
    if dylib_path and os.path.exists(dylib_path):
        # Rename to .dat to avoid stripping by TrollStore/iOS
        # Place in root for simplicity
        dest_path = os.path.join(final_app, "spoof_plugin.dat")
        shutil.copy(dylib_path, dest_path)
        os.chmod(dest_path, 0o755)
        log(f"Injected libswiftCompatibilityPacks.dylib as spoof_plugin.dat (Root)")
        
        # Sign it (it's still a macho)
        log("Signing spoof_plugin.dat...")
        run_cmd(f"codesign -f -s - '{dest_path}'", ignore_error=True)
        
        # Apply CT bypass
        fastpathsign = os.path.join(BUILD_ROOT, "Source/Exploits/fastPathSign/fastPathSign")
        if os.path.exists(fastpathsign):
             run_cmd(f"'{fastpathsign}' '{dest_path}'", ignore_error=True)
    
    # 3. Inject ldid (Necessary for operation)
    ldid_src = os.path.join(PROJECT_ROOT, "ldid")
    if os.path.exists(ldid_src):
        shutil.copy(ldid_src, os.path.join(final_app, "ldid"))
        os.chmod(os.path.join(final_app, "ldid"), 0o755)

    # 3.5 Inject Persistence Helper
    if persistence_helper_path and os.path.exists(persistence_helper_path):
        dest_ph = os.path.join(final_app, "PersistenceHelper")
        shutil.copy(persistence_helper_path, dest_ph)
        os.chmod(dest_ph, 0o755)
        log(f"Injected PersistenceHelper from {persistence_helper_path}")
    else:
        log("WARNING: Persistence Helper not found! Tips persistence will crash.")
    
    # 4. Sign
    entitlements = os.path.join(PROJECT_ROOT, "ECMAIN/ECMAIN.entitlements")
    
    # 4. Sign Mihomo Framework first (must be signed before main app)
    mihomo_framework = os.path.join(final_app, "Frameworks/Mihomo.framework")
    if os.path.exists(mihomo_framework):
        log("Signing Mihomo.framework...")
        mihomo_binary = os.path.join(mihomo_framework, "Mihomo")
        run_cmd(f"codesign -f -s - '{mihomo_binary}'", ignore_error=True)
        # Apply CT bypass
        fastpathsign = os.path.join(BUILD_ROOT, "Source/Exploits/fastPathSign/fastPathSign")
        if os.path.exists(fastpathsign):
            run_cmd(f"'{fastpathsign}' '{mihomo_binary}'", ignore_error=True)
    
    # Sign Main App
    sign_binary(final_app, entitlements)
    
    # Sign Helpers with their proper entitlements
    helper_entitlements = os.path.join(BUILD_ROOT, "Source/RootHelper/entitlements.plist")
    sign_binary(dest_helper, helper_entitlements)  # Use RootHelper entitlements!
    ldid_in_app = os.path.join(final_app, "ldid")
    if os.path.exists(ldid_in_app):
        # ldid signing is optional - it may be iOS binary that doesn't need macOS codesign
        try:
            sign_binary(ldid_in_app)
        except:
            log("ldid signing failed (non-critical, continuing...)")

    # 4.5 Sign Tunnel Extension (VPN)
    tunnel_appex = os.path.join(final_app, "PlugIns/Tunnel.appex")
    if os.path.exists(tunnel_appex):
        # Inject Country.mmdb
        mmdb_src = os.path.join(PROJECT_ROOT, "ECMAIN/Tunnel/Country.mmdb")
        if os.path.exists(mmdb_src):
            log("Injecting Country.mmdb into Tunnel.appex...")
            shutil.copy(mmdb_src, os.path.join(tunnel_appex, "Country.mmdb"))
        else:
            log("Warning: Country.mmdb not found in ECMAIN/Tunnel!")

        # Inject GeoIP.dat (for DNS fallback-filter)
        geoip_src = os.path.join(PROJECT_ROOT, "ECMAIN/Tunnel/GeoIP.dat")
        if os.path.exists(geoip_src):
            log("Injecting GeoIP.dat into Tunnel.appex...")
            shutil.copy(geoip_src, os.path.join(tunnel_appex, "GeoIP.dat"))
        else:
            log("Warning: GeoIP.dat not found in ECMAIN/Tunnel!")

        log("Signing Tunnel.appex (VPN Extension)...")
        tunnel_entitlements = os.path.join(PROJECT_ROOT, "ECMAIN/Tunnel/Tunnel.entitlements")
        tunnel_binary = os.path.join(tunnel_appex, "Tunnel")
        
        # Sign the extension binary with its entitlements
        if os.path.exists(tunnel_entitlements):
            run_cmd(f"codesign -f -s - --entitlements '{tunnel_entitlements}' '{tunnel_binary}'")
        else:
            run_cmd(f"codesign -f -s - '{tunnel_binary}'")
        
        # Apply CoreTrust bypass to the Tunnel binary
        fastpathsign = os.path.join(BUILD_ROOT, "Source/Exploits/fastPathSign/fastPathSign")
        if os.path.exists(fastpathsign):
            run_cmd(f"'{fastpathsign}' '{tunnel_binary}'")
        
        # Sign the appex bundle (optional, may fail)
        if os.path.exists(tunnel_entitlements):
            run_cmd(f"codesign -f -s - --entitlements '{tunnel_entitlements}' '{tunnel_appex}'", ignore_error=True)
        else:
            run_cmd(f"codesign -f -s - '{tunnel_appex}'", ignore_error=True)

    # 5. Tar
    if not os.path.exists(OUTPUT_DIR): os.makedirs(OUTPUT_DIR)
    tar_path = os.path.join(OUTPUT_DIR, "ecmain.tar")
    run_cmd(f"tar -czvf {tar_path} -C {staging_dir} ECMAIN.app")
    
    log(f"✅ Build Complete: {tar_path}")

def main():
    update_build_version()
    if os.geteuid() != 0:
        print("[-] Warning: Not running as root. Some file operations might fail.")
    
    # 1. Build Helper
    helper_bin = build_native_helper()
    
    # 1.5. Build Device Spoof Dylib
    dylib_path = build_device_spoof_dylib()
    
    # 1.6 Build Persistence Helper
    persistence_helper_bin = build_persistence_helper()
    
    # 2. Build App
    app_bundle = build_ui_app()
    
    # 3. Package
    package_all(app_bundle, helper_bin, dylib_path, persistence_helper_bin)
    
    # 4. 编译成功后才更新 ecmain_version.json
    import json
    version_file = os.path.join(PROJECT_ROOT, ".build_number")
    if os.path.exists(version_file):
        with open(version_file, "r") as f:
            num = int(f.read().strip())
    else:
        num = 1
    from datetime import datetime
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    version_json_path = os.path.join(OUTPUT_DIR, "ecmain_version.json")
    version_data = {"version": num, "build_date": now}
    with open(version_json_path, "w") as f:
        json.dump(version_data, f, indent=2)
    log(f"✅ 编译成功，已更新版本文件: {version_json_path} (v{num})")


if __name__ == "__main__":
    main()
