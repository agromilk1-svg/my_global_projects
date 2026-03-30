#!/usr/bin/env python3
"""
ECHelper 编译脚本（修复版）

输出：echelper/echelper
用于：install_trollstore_cn.py 安装到设备
"""

import os
import subprocess
import shutil
import glob

# 配置
SDK_PATH = "external_sources/theos/sdks/iPhoneOS14.5.sdk"
TARGET = "arm64-apple-ios14.5"
WORK_DIR = "echelper"
OUTPUT_BINARY = "echelper"
SIGNING_TOOL = "external_sources/TrollStore/Exploits/fastPathSign/fastPathSign"

def run_cmd(cmd, cwd=None):
    print(f"[*] 执行: {' '.join(cmd[:10])}...")
    subprocess.check_call(cmd, cwd=cwd)

def main():
    print("=" * 50)
    print("   ECHelper 编译脚本（修复版）")
    print("=" * 50)

    # 检查 SDK
    if not os.path.exists(SDK_PATH):
        print(f"[-] 找不到 iOS 14.5 SDK: {SDK_PATH}")
        print("    请下载并放入 external_sources/theos/sdks/")
        return 1

    # 检查工作目录
    if not os.path.exists(WORK_DIR):
        print(f"[-] 找不到 echelper 目录: {WORK_DIR}")
        return 1
        
    # 清理旧文件
    output_path = os.path.join(WORK_DIR, OUTPUT_BINARY)
    if os.path.exists(output_path):
        print(f"[*] 清理旧文件: {output_path}")
        os.remove(output_path)

    # 收集源文件
    all_m_files = glob.glob(os.path.join(WORK_DIR, "*.m"))
    all_c_files = glob.glob(os.path.join(WORK_DIR, "*.c"))
    
    # 关键修复：排除 root_main.m（它定义的函数会在 main.m 中通过 EMBEDDED_ROOT_HELPER 宏引用）
    # 不，实际上 root_main.m 定义的是 rootHelperMain，需要包含它
    # 问题是：如果不定义 EMBEDDED_ROOT_HELPER，root_main.m 会定义 main() 而不是 rootHelperMain()
    # 所以必须定义 -DEMBEDDED_ROOT_HELPER=1
    
    source_files = all_m_files + all_c_files
    source_basenames = [os.path.basename(f) for f in source_files]
    
    print(f"[*] 找到 {len(all_m_files)} 个 .m 文件, {len(all_c_files)} 个 .c 文件")

    # 编译命令
    cmd = [
        "xcrun", "clang",
        "-isysroot", f"../{SDK_PATH}",
        "-target", TARGET,
        "-fobjc-arc",
        "-O2",
        "-fmodules",
        
        # 标准框架
        "-framework", "UIKit",
        "-framework", "Foundation",
        "-framework", "CoreGraphics",
        # REMOVED: "-framework", "MobileCoreServices", (Fix for crash)
        "-framework", "CoreServices",
        "-framework", "Security",
        "-framework", "CoreTelephony",
        
        # 私有框架（从 echelper 目录加载 TBD）
        "-F", ".",
        "-F", "../build_antigravity/PrivateSDK",
        "-framework", "SpringBoardServices",
        "-framework", "FrontBoardServices",
        "-framework", "BackBoardServices",
        "-framework", "MobileContainerManager",
        "-framework", "Preferences",
        
        # 链接选项
        "-Wl,-undefined,dynamic_lookup",
        "-larchive",
        "-lc++",
        
        # 头文件路径
        "-I", ".",
        "-I", "/opt/homebrew/opt/libarchive/include",
        "-I", "../external_sources/theos/vendor/include",
        
        # 关键宏定义
        "-DEMBEDDED_ROOT_HELPER=1",  # 必须启用，否则 root_main.m 会定义 main() 导致冲突
        "-DFINALPACKAGE=1",
        "-DkCFCoreFoundationVersionNumber_iOS_15_0=1854.0",
        
        # 抑制警告
        "-Wno-error=availability",
        "-Wno-availability",
        "-Wno-deprecated-declarations",
        
        "-o", OUTPUT_BINARY,
    ] + source_basenames

    print("\n[*] 开始编译...")
    try:
        run_cmd(cmd, cwd=WORK_DIR)
        print("✅ 编译成功!")
    except subprocess.CalledProcessError as e:
        print(f"❌ 编译失败: {e}")
        return 1

    # 签名
    output_path = os.path.join(WORK_DIR, OUTPUT_BINARY)
    entitlements_path = os.path.join(WORK_DIR, "entitlements.plist")
    
    if os.path.exists(SIGNING_TOOL):
        print("\n[*] 使用 fastPathSign 签名...")
        try:
            run_cmd([
                os.path.abspath(SIGNING_TOOL),
                "--entitlements", "entitlements.plist",
                OUTPUT_BINARY
            ], cwd=WORK_DIR)
            print("✅ CoreTrust 签名成功!")
        except subprocess.CalledProcessError:
            print("[-] fastPathSign 失败，尝试 codesign...")
            run_cmd(["codesign", "-f", "-s", "-", output_path])
    else:
        print("\n[*] 使用 codesign 签名...")
        run_cmd(["codesign", "-f", "-s", "-", output_path])

    # 验证
    print("\n[*] 验证签名...")
    subprocess.run(["codesign", "-dvvv", output_path], capture_output=False)
    
    # 归档到项目根目录
    final_output_dir = "build_antigravity/IPA"
    if not os.path.exists(final_output_dir):
        os.makedirs(final_output_dir)
    final_bin_path = os.path.join(final_output_dir, "echelper")
    shutil.copy2(output_path, final_bin_path)
    print(f"\n[*] 已归档到: {final_bin_path}")

    # 自动同步到 Windows 安装包目录（install_echelper.py 从这里读取）
    win_pkg_dir = "ECHelper_Windows_Package/build_antigravity/IPA"
    if not os.path.exists(win_pkg_dir):
        os.makedirs(win_pkg_dir)
    win_bin_path = os.path.join(win_pkg_dir, "echelper")
    shutil.copy2(output_path, win_bin_path)
    print(f"[*] 已同步到: {win_bin_path}")

    print("\n" + "=" * 50)
    print(f"   ✅ 编译完成")
    print("=" * 50)
    print(f"   大小: {os.path.getsize(final_bin_path) / 1024 / 1024:.2f} MB")
    print(f"   下一步: python3 install_echelper.py")
    print("=" * 50)
    
    return 0

if __name__ == "__main__":
    exit(main())
