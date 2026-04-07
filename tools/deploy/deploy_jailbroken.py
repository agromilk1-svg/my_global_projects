#!/usr/bin/env python3
"""
越狱设备 ECMAIN 部署脚本
Deploy ecmain.tar to jailbroken iOS device via SSH

用法:
    python3 deploy_jailbroken.py [设备IP]

默认设备IP: 192.168.110.188 (USB over WiFi) 或通过 iproxy 转发 localhost:2222
"""

import os
import sys
import subprocess
import tempfile
import shutil

# 配置
TAR_PATH = "/Users/hh/Desktop/my/build_antigravity/IPA/ecmain.tar"
APP_NAME = "ECMAIN.app"
INSTALL_PATH = "/Applications"
SSH_USER = "root"
SSH_PASSWORD = "alpine"  # 默认越狱密码，根据实际修改
DEFAULT_IP = "localhost"
DEFAULT_PORT = "2222"  # iproxy 默认端口

def run_ssh_command(host, port, command, password=SSH_PASSWORD):
    """通过 sshpass 执行 SSH 命令"""
    ssh_cmd = [
        "sshpass", "-p", password,
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-p", port,
        f"{SSH_USER}@{host}",
        command
    ]
    print(f"[*] 执行: {command}")
    result = subprocess.run(ssh_cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"[-] 错误: {result.stderr}")
    return result.returncode, result.stdout, result.stderr

def scp_file(host, port, local_path, remote_path, password=SSH_PASSWORD):
    """通过 sshpass 上传文件"""
    scp_cmd = [
        "sshpass", "-p", password,
        "scp", "-o", "StrictHostKeyChecking=no",
        "-P", port,
        local_path,
        f"{SSH_USER}@{host}:{remote_path}"
    ]
    print(f"[*] 上传: {local_path} -> {remote_path}")
    result = subprocess.run(scp_cmd, capture_output=True, text=True)
    return result.returncode == 0

def check_sshpass():
    """检查 sshpass 是否安装"""
    result = subprocess.run(["which", "sshpass"], capture_output=True)
    if result.returncode != 0:
        print("[-] 未安装 sshpass!")
        print("    请运行: brew install hudochenkov/sshpass/sshpass")
        return False
    return True

def main():
    print("=" * 50)
    print("   ECMAIN 越狱设备部署工具")
    print("=" * 50)

    # 解析参数
    if len(sys.argv) >= 2:
        host = sys.argv[1]
        port = sys.argv[2] if len(sys.argv) >= 3 else "22"
    else:
        host = DEFAULT_IP
        port = DEFAULT_PORT
        print(f"[*] 使用默认连接: {host}:{port}")
        print("[*] 提示: 可通过 'iproxy 2222 22' 转发 USB SSH")

    # 1. 检查依赖
    if not check_sshpass():
        # 尝试无密码方式
        print("[*] 尝试使用 SSH 密钥认证...")
    
    # 2. 检查 tar 文件
    if not os.path.exists(TAR_PATH):
        print(f"[-] 找不到 tar 文件: {TAR_PATH}")
        sys.exit(1)
    print(f"[+] 找到 tar 文件: {TAR_PATH}")
    print(f"    大小: {os.path.getsize(TAR_PATH) / 1024 / 1024:.2f} MB")

    # 3. 测试 SSH 连接
    print("\n[*] 测试 SSH 连接...")
    ret, out, err = run_ssh_command(host, port, "uname -a")
    if ret != 0:
        print("[-] SSH 连接失败!")
        print("    请确保:")
        print("    1. 设备已越狱并运行 OpenSSH")
        print("    2. 已运行 'iproxy 2222 22' (USB 连接)")
        print("    3. 或设备 IP 正确 (WiFi 连接)")
        sys.exit(1)
    print(f"[+] 连接成功: {out.strip()}")

    # 4. 上传 tar 文件
    print("\n[*] 上传 ecmain.tar 到设备...")
    remote_tar = "/var/mobile/ecmain.tar"
    if not scp_file(host, port, TAR_PATH, remote_tar):
        print("[-] 上传失败!")
        sys.exit(1)
    print("[+] 上传成功!")

    # 5. 解压并安装
    print("\n[*] 解压并安装到 /Applications...")
    commands = [
        f"rm -rf {INSTALL_PATH}/{APP_NAME}",  # 删除旧版本
        f"cd {INSTALL_PATH} && tar -xvf {remote_tar}",  # 解压
        f"chmod -R 755 {INSTALL_PATH}/{APP_NAME}",  # 设置权限
        f"chown -R root:wheel {INSTALL_PATH}/{APP_NAME}",  # 设置所有者
        f"rm -f {remote_tar}",  # 清理 tar
    ]
    
    for cmd in commands:
        ret, out, err = run_ssh_command(host, port, cmd)
        if ret != 0 and "rm" not in cmd:
            print(f"[-] 命令失败: {cmd}")

    # 6. 刷新图标缓存
    print("\n[*] 刷新图标缓存 (uicache)...")
    ret, out, err = run_ssh_command(host, port, f"uicache -p {INSTALL_PATH}/{APP_NAME}")
    if ret != 0:
        # 尝试其他方式
        run_ssh_command(host, port, "uicache -a")
    
    print("\n" + "=" * 50)
    print("   ✅ 安装完成!")
    print("=" * 50)
    print(f"   应用路径: {INSTALL_PATH}/{APP_NAME}")
    print("   请在主屏幕查找 ECMAIN 图标")
    print("=" * 50)

if __name__ == "__main__":
    main()
