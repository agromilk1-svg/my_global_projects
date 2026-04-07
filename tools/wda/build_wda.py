#!/usr/bin/env python3
"""
复刻 build_ipa.py 的成功逻辑
适配当前环境配置。
"""
import os
import subprocess
import shutil
import glob
import plistlib
import sys
import json
from datetime import datetime

# 配置
PROJECT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../"))
XCODE_PROJECT = os.path.join(PROJECT_DIR, "WebDriverAgent.xcodeproj")
SCHEME_NAME = "WebDriverAgentRunner"
BUILD_DIR = os.path.join(PROJECT_DIR, "build_ref_output")
IPA_OUTPUT_DIR = os.path.join(PROJECT_DIR, "web_control_center/backend/updates")
ECWDA_VERSION_FILE = os.path.join(IPA_OUTPUT_DIR, "ecwda_version.json")

# 固定 Bundle ID（需与 ECMAIN 代码中的 kECWDABundleID 保持一致）
FIXED_BUNDLE_ID = "com.apple.accessibility.ecwda"

# 伪装进程名（替换原始的 WebDriverAgentRunner-Runner，消除 WDA 指纹）
DISGUISED_RUNNER_NAME = "ECService-Runner"
DISGUISED_TEST_NAME = "ECService"

def run_cmd(cmd, cwd=PROJECT_DIR, ignore_error=False, env=None):
    print(f"执行命令: {cmd}")
    try:
        if env:
            subprocess.check_call(cmd, shell=True, cwd=cwd, env=env)
        else:
            subprocess.check_call(cmd, shell=True, cwd=cwd)
        return True
    except subprocess.CalledProcessError as e:
        if not ignore_error:
            print(f"错误: {e}")
        return False

def build_project():
    print("--- 构建未签名 .app (参考逻辑) ---")
    
    if os.path.exists(BUILD_DIR):
        shutil.rmtree(BUILD_DIR)
    os.makedirs(BUILD_DIR)

    # 0. 清理环境
    env = os.environ.copy()
    for k in ['C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH', 'LIBRARY_PATH', 'CPATH']:
        if k in env: del env[k]

    # --- 构建前修改 (参考逻辑) ---
    print(f"--- 使用固定 Bundle ID: {FIXED_BUNDLE_ID} ---")
    
    # 注意: 我们不再修改磁盘上的 project.pbxproj
    # 以避免递归添加后缀 (例如 .ecwda.ecwda)。
    # 相反，我们将 PRODUCT_BUNDLE_IDENTIFIER 传递给 xcodebuild。
    
    # 1. DerivedData
    derived_data = os.path.join(BUILD_DIR, "DerivedData")

    # 使用强制设置构建 wrapper app
    build_cmd = (
        f"DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build "
        f"-project WebDriverAgent.xcodeproj "
        f"-target {SCHEME_NAME} "
        f"-configuration Release "
        f"-sdk iphoneos "
        f"SYMROOT={BUILD_DIR} "
        f"CODE_SIGN_IDENTITY=\"\" CODE_SIGNING_REQUIRED=NO "
        f"CODE_SIGNING_ALLOWED=NO "
        f"GCC_TREAT_WARNINGS_AS_ERRORS=NO "
        f"WARNING_CFLAGS=\"-Wno-missing-include-dirs\" "
        f"STRIP_INSTALLED_PRODUCT=YES "
        f"COPY_PHASE_STRIP=YES "
        f"DEBUG_INFORMATION_FORMAT=dwarf-with-dsym "
        f"PRODUCT_BUNDLE_IDENTIFIER=\"{FIXED_BUNDLE_ID}\" "
        f"USE_PORT=10088 "
        f"MJPEG_SERVER_PORT=10089 "
        f"RUN_CLANG_STATIC_ANALYZER=NO "
    )
    
    print(f"正在执行构建...")
    if not run_cmd(build_cmd, env=env):
        print("❌ 构建失败")
        return None

    products_dir = os.path.join(BUILD_DIR, "Release-iphoneos")
    if not os.path.exists(products_dir):
        print(f"SYMROOT 中未找到，检查 build/Release-iphoneos...")
        products_dir = os.path.join(PROJECT_DIR, "build/Release-iphoneos")
    
    app_path = None
    # 优先使用 Ecrunner-Runner.app (从项目设置检测到)
    possible_names = ["ECWDAStandalone.app", "Ecrunner-Runner.app", "WebDriverAgentRunner-Runner.app", "WebDriverAgentRunner.app"]
    
    app_path = None
    for name in possible_names:
        path = os.path.join(products_dir, name)
        if os.path.exists(path):
            app_path = path
            break
            
    if not app_path:
        # 回退到任意 app
        apps = glob.glob(os.path.join(products_dir, "*.app"))
        if apps:
            app_path = apps[0]
            
    if not app_path:
        print(f"❌ 无法在 {products_dir} 中找到 app")
        return None
        
    print(f"找到 app 于: {app_path}")
    return app_path

def package_ipa(app_path):
    print("--- 正在打包 IPA ---")
    
    temp_dir = os.path.join(BUILD_DIR, "temp_package")
    if os.path.exists(temp_dir): shutil.rmtree(temp_dir)
    payload_dir = os.path.join(temp_dir, "Payload")
    os.makedirs(payload_dir)
    
    # 复制 App
    dest_app = os.path.join(payload_dir, "ECWDA.app") # 按要求重命名为 ECWDA
    shutil.copytree(app_path, dest_app)
    
    # ====== Standalone 改造结束 =======
    
    # 手动嵌入框架 (参考逻辑)
    print("--- 正在嵌入第三方框架 ---")
    frameworks_dir = os.path.join(dest_app, "Frameworks")
    if not os.path.exists(frameworks_dir):
        os.makedirs(frameworks_dir)
        
    vendor_dir = os.path.join(PROJECT_DIR, "WebDriverAgentLib/Vendor")
    # frameworks_to_copy = ["ncnn.framework", "opencv2.framework", "openmp.framework"]
    frameworks_to_copy = []
    
    for fw in frameworks_to_copy:
        src = os.path.join(vendor_dir, fw)
        dst = os.path.join(frameworks_dir, fw)
        if os.path.exists(src):
            if os.path.exists(dst): shutil.rmtree(dst)
            shutil.copytree(src, dst)
            print(f"已嵌入 {fw}")
        else:
            print(f"⚠️ 警告: 无法在 {src} 找到框架 {fw}")

    print(f"--- 使用固定 Bundle ID: {FIXED_BUNDLE_ID} ---")

    # 计算下一个版本号 (当前值+1)，写入 IPA 但不更新 JSON 文件
    # JSON 文件只有在 IPA 完全打包落盘后才更新，防止设备下载到旧包
    ecwda_version = 1
    if os.path.exists(ECWDA_VERSION_FILE):
        try:
            with open(ECWDA_VERSION_FILE, 'r') as f:
                ver_data = json.load(f)
                ecwda_version = ver_data.get('version', 0) + 1
        except Exception:
            pass
    print(f"--- ECWDA 版本号 (即将写入 IPA): {ecwda_version} ---")

    # === 进程名伪装：重命名主可执行文件（消除 WebDriverAgentRunner-Runner 指纹）===
    print(f"--- 进程名伪装: WebDriverAgentRunner-Runner → {DISGUISED_RUNNER_NAME} ---")
    old_runner = os.path.join(dest_app, "WebDriverAgentRunner-Runner")
    new_runner = os.path.join(dest_app, DISGUISED_RUNNER_NAME)
    if os.path.exists(old_runner):
        os.rename(old_runner, new_runner)
        print(f"  ✅ 主二进制已重命名")
    
    # === 进程名伪装：重命名 xctest 插件内的可执行文件 ===
    xctest_dir = os.path.join(dest_app, "PlugIns", "WebDriverAgentRunner.xctest")
    if os.path.exists(xctest_dir):
        # 重命名 xctest 内部的二进制
        old_test_bin = os.path.join(xctest_dir, "WebDriverAgentRunner")
        new_test_bin = os.path.join(xctest_dir, DISGUISED_TEST_NAME)
        if os.path.exists(old_test_bin):
            os.rename(old_test_bin, new_test_bin)
            print(f"  ✅ XCTest 二进制已重命名")
        
        # 修改 xctest 的 Info.plist
        xctest_plist_path = os.path.join(xctest_dir, "Info.plist")
        if os.path.exists(xctest_plist_path):
            with open(xctest_plist_path, 'rb') as f:
                xctest_plist = plistlib.load(f)
            xctest_plist['CFBundleExecutable'] = DISGUISED_TEST_NAME
            xctest_plist['CFBundleIdentifier'] = FIXED_BUNDLE_ID
            with open(xctest_plist_path, 'wb') as f:
                plistlib.dump(xctest_plist, f)
            print(f"  ✅ XCTest Info.plist 已更新")
        
        # 重命名 xctest 目录本身
        new_xctest_dir = os.path.join(dest_app, "PlugIns", f"{DISGUISED_TEST_NAME}.xctest")
        os.rename(xctest_dir, new_xctest_dir)
        print(f"  ✅ XCTest 目录已重命名")
        
        # 清理 dSYM（调试符号也含指纹）
        dsym_dir = os.path.join(dest_app, "PlugIns", "WebDriverAgentRunner.xctest.dSYM")
        if os.path.exists(dsym_dir):
            shutil.rmtree(dsym_dir)
            print(f"  ✅ 调试符号 (dSYM) 已清除")

    # 修复 Info.plist（图标/名称/BundleID/版本号/进程名）
    print("--- 正在修复 Info.plist ---")
    info_plist = os.path.join(dest_app, "Info.plist")
    if os.path.exists(info_plist):
        with open(info_plist, 'rb') as f:
            plist = plistlib.load(f)
        
        plist['CFBundleDisplayName'] = 'ECWDA'
        plist['CFBundleName'] = 'ECWDA'
        plist['CFBundleIconName'] = 'AppIcon'
        plist['CFBundleIdentifier'] = FIXED_BUNDLE_ID
        plist['CFBundleExecutable'] = DISGUISED_RUNNER_NAME  # 关键：修改进程名
        plist['CFBundleVersion'] = str(ecwda_version)
        plist['UIBackgroundModes'] = ['audio', 'location', 'fetch']
        plist['NSMicrophoneUsageDescription'] = '需在后台使用微量的系统麦克风资源以防进程被系统休眠挂起'
        
        with open(info_plist, 'wb') as f:
            plistlib.dump(plist, f)
            
    # 编译图标资源 (图标显示的关键)
    assets_path = os.path.join(PROJECT_DIR, "WebDriverAgentRunner/Assets.xcassets")
    if os.path.exists(assets_path):
        print(f"正在编译资源...")
        run_cmd(
            f"DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun actool '{assets_path}' "
            f"--compile '{dest_app}' "
            f"--platform iphoneos "
            f"--minimum-deployment-target 15.0 "
            f"--app-icon AppIcon "
            f"--output-partial-info-plist '{temp_dir}/partial.plist' ",
            ignore_error=True
        )
        
        # 将 partial.plist 合并到主 Info.plist (图标关键)
        partial_plist_path = os.path.join(temp_dir, "partial.plist")
        if os.path.exists(partial_plist_path):
            print("--- 合并 partial.plist (图标资源) ---")
            with open(partial_plist_path, 'rb') as f:
                partial_plist = plistlib.load(f)
            
            with open(info_plist, 'rb') as f:
                main_plist = plistlib.load(f)
                
            # 合并键值
            for key, value in partial_plist.items():
                print(f"合并资源中的 {key}")
                main_plist[key] = value
                
            with open(info_plist, 'wb') as f:
                plistlib.dump(main_plist, f)


    

    # 手动签名阶段 (修复 TrollStore 错误码 185)
    print("--- 应用 Ad-Hoc 签名 (修复错误码 185) ---")
    for root, dirs, files in os.walk(dest_app):
        for f in files:
            if f.endswith(".dylib"):
                run_cmd(f"codesign -f -s - '{os.path.join(root, f)}'", ignore_error=True)
        for d in dirs:
            if d.endswith(".framework"):
                run_cmd(f"codesign -f -s - '{os.path.join(root, d)}'", ignore_error=True)
                
    # 使用包含后台高优先级的防丢权限进行打包签名
    entitlements_path = os.path.join(PROJECT_DIR, "WDA_Minimal.entitlements")
    if os.path.exists(entitlements_path):
        run_cmd(f"codesign -f -s - --entitlements '{entitlements_path}' '{dest_app}'")
    else:
        print("⚠️ 警告：未找到 WDA_Minimal.entitlements，防后台休眠可能失效！")
        run_cmd(f"codesign -f -s - '{dest_app}'")

    # 5. Zip
    ipa_path = os.path.join(IPA_OUTPUT_DIR, "ecwda.ipa")
    if os.path.exists(ipa_path):
        os.remove(ipa_path)
        
    # 手动使用 zip 命令确保结构严格
    run_cmd(f"cd {temp_dir} && zip -qr {ipa_path} Payload")
    
    print("--- 清除扩展属性 ---")
    run_cmd(f"xattr -c {ipa_path}")

    print(f"\n✅ 成功！参考逻辑 IPA 生成于:")
    print(ipa_path)
    run_cmd(f"open {IPA_OUTPUT_DIR}")

def update_build_version():
    """在编译开始前立刻增加和持久化保存版本号，防止中途失败未写入"""
    ecwda_version = 1
    if os.path.exists(ECWDA_VERSION_FILE):
        try:
            with open(ECWDA_VERSION_FILE, 'r') as f:
                ver_data = json.load(f)
                ecwda_version = ver_data.get('version', 0) + 1
        except Exception:
            pass
    
    os.makedirs(os.path.dirname(ECWDA_VERSION_FILE), exist_ok=True)
    with open(ECWDA_VERSION_FILE, 'w') as f:
        json.dump({
            'version': ecwda_version,
            'build_date': datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        }, f, indent=2)
    print(f"[+] ✅ 已提前递增 ECWDA 版本文件: {ECWDA_VERSION_FILE} 现为 (v{ecwda_version})")

if __name__ == "__main__":
    app = build_project()
    if app:
        package_ipa(app)
        # 关键：IPA 文件已经完整写入磁盘后，才更新版本号 JSON
        # 这样设备发现新版本时，下载到的一定是已经包含新版本号的 IPA
        update_build_version()
