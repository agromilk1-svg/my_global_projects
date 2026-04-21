import os
import sys
import subprocess
import shutil
import time
import platform

IS_MAC = platform.system() == "Darwin"
IS_WIN = platform.system() == "Windows"

# 强制将工作目录切换到脚本所在目录，确保 dist 和 build 不会生成在用户的当前执行路径
script_dir = os.path.dirname(os.path.abspath(__file__))
os.chdir(script_dir)

print("=========================================")
print("  TrollStore ECHelper - 跨平台自动打包工具")
print(f"  当前平台: {platform.system()} ({platform.machine()})")
print("=========================================")

# 1. 检查必要环境
try:
    import PyInstaller
except ImportError:
    print("[-] 未安装 PyInstaller，正在安装...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "pyinstaller"])

# 2. 清理旧产物（忽略被占用的目录，让打包继续运行）
for folder in ["build", "dist"]:
    if os.path.exists(folder):
        try:
            shutil.rmtree(folder, ignore_errors=True)
        except Exception as e:
            print(f"[!] 警告: 无法清理 {folder}，可能有文件被占用，继续执行打包...")

exe_name = f"Install_ECHelper_GUI"

# 3. 核心资源路径
add_data_args = []

# 加入 ECHelper 二进制文件包
echelper_path = "build_antigravity/IPA/echelper"
if not os.path.exists(echelper_path):
    print(f"[-] 严重警告: 找不到 '{echelper_path}'！打包出来的产物将无法正确安装 Helper。")
    print("    请确保在 Mac 上编译好 ECHelper 再进行打包，或者路径正确。")
    sys.exit(1)

# PyInstaller 语法: src;dest (Windows) 或者 src:dest (Linux/Mac)
separator = ";" if IS_WIN else ":"
add_data_args.extend(["--add-data", f"{echelper_path}{separator}build_antigravity/IPA"])

# 加入 ecmain.tar 和 ecwda.ipa
updates_dir = "web_control_center/backend/updates"
add_data_args.extend(["--add-data", f"{updates_dir}{separator}{updates_dir}"])

# 加入 installer 中的依赖模块
add_data_args.extend(["--add-data", f"installer{separator}installer"])

# 加入 tidevice 所需的 iOS DeviceSupport 镜像文件（内嵌后无需联网下载）
device_support_dir = "device-support"
if os.path.exists(device_support_dir):
    add_data_args.extend(["--add-data", f"{device_support_dir}{separator}{device_support_dir}"])
    print(f"[+] 已加入内嵌 DeviceSupport 资源: {device_support_dir}")
else:
    print(f"[!] 警告: 未找到 '{device_support_dir}' 目录，tidevice 启动 WDA 时可能需要联网下载镜像。")

# IPA 预置包已移除，不再打包到安装器中

# 4. 执行 PyInstaller 打包
cmd = [
    sys.executable, "-m", "PyInstaller",
    "--onedir" if IS_MAC else "--onefile", # macOS 请使用 onedir 以符合 App Bundle 规范，Windows 保留 onefile
    "--windowed",                # 跨平台参数：Windows 隐藏 CMD 黑框，macOS 标记为 GUI 应用
    f"--name={exe_name}",        # 生成名称
    "--collect-all", "tidevice",
    "--collect-all", "pymobiledevice3",
    "--collect-all", "zeroconf",
    "--collect-all", "apple_compress",
    "--collect-all", "pyimg4",
    "--hidden-import", "pymobiledevice3.services.mobilebackup2",
    "--hidden-import", "pymobiledevice3.services.installation_proxy",
    "--hidden-import", "pymobiledevice3.services.diagnostics",
    "--hidden-import", "pymobiledevice3.services.afc",
    "--hidden-import", "pymobiledevice3.services.syslog",
    "--hidden-import", "pymobiledevice3.services.os_trace",
    "--hidden-import", "PyQt5",
    "--hidden-import", "PyQt5.QtCore",
    "--hidden-import", "PyQt5.QtGui",
    "--hidden-import", "PyQt5.QtWidgets",
] + add_data_args + ["install_echelper_gui.py"]

print("[+] 开始打包：")
print(" ".join(cmd))
subprocess.check_call(cmd)

print("\n=========================================")
print("[+] 打包成功！")
if IS_MAC:
    print(f"    请在当前目录的 'dist' 文件夹下找到 [{exe_name}.app]")
    print('    将它拖入「应用程序」文件夹，双击运行，插入手机即可自动安装！')
elif IS_WIN:
    print(f"    请在当前目录的 'dist' 文件夹下找到 [{exe_name}.exe]")
    print("    将它发给任何 Windows 电脑，双击运行，插入手机即可自动安装！")
else:
    print(f"    请在当前目录的 'dist' 文件夹下找到 [{exe_name}]")
    print("    赋予执行权限后运行，插入手机即可自动安装！")
print("=========================================")
