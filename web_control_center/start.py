#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Web Control Center — 跨平台统一启动脚本
支持 Windows / macOS / CentOS (Linux)

用法：
  python3 start.py          # macOS / Linux
  python  start.py          # Windows

首次运行会自动：
  1. 创建 Python 虚拟环境并安装后端依赖
  2. 安装前端 Node.js 依赖（npm install）
"""

import os
import sys
import signal
import subprocess
import platform
import time

import hashlib

# ─── 路径常量 ───
ROOT_DIR = os.path.dirname(os.path.abspath(__file__))
BACKEND_DIR = os.path.join(ROOT_DIR, "backend")
FRONTEND_DIR = os.path.join(ROOT_DIR, "frontend")
REQUIREMENTS = os.path.join(ROOT_DIR, "requirements.txt")

IS_WINDOWS = platform.system() == "Windows"
IS_MAC = platform.system() == "Darwin"

def get_venv_dir():
    """获取虚拟环境目录，针对 ExFAT 进行特殊处理"""
    default_venv = os.path.join(ROOT_DIR, "venv")
    if IS_WINDOWS:
        return default_venv
    
    # 在 Mac 上，如果项目位于外置卷，需要测试是否支持符号链接
    if IS_MAC and "/Volumes/" in ROOT_DIR:
        test_link = os.path.join(ROOT_DIR, ".symlink_test")
        is_exfat = False
        try:
            if os.path.exists(test_link): os.remove(test_link)
            os.symlink(ROOT_DIR, test_link)
            os.remove(test_link)
        except Exception:
            is_exfat = True

        if is_exfat:
            path_hash = hashlib.md5(ROOT_DIR.encode()).hexdigest()[:8]
            local_venv_base = os.path.expanduser("~/.cache/web_control_center_venv")
            target_dir = os.path.join(local_venv_base, path_hash)
            return target_dir
    
    return default_venv

VENV_DIR = get_venv_dir()

if IS_WINDOWS:
    VENV_PYTHON = os.path.join(VENV_DIR, "Scripts", "python.exe")
    VENV_PIP = os.path.join(VENV_DIR, "Scripts", "pip.exe")
else:
    VENV_PYTHON = os.path.join(VENV_DIR, "bin", "python3")
    VENV_PIP = os.path.join(VENV_DIR, "bin", "pip3")
    if not os.path.exists(VENV_PYTHON) and os.path.exists(os.path.join(VENV_DIR, "bin", "python")):
        VENV_PYTHON = os.path.join(VENV_DIR, "bin", "python")

# 子进程句柄列表
children = []


def banner(msg):
    print(f"\n{'=' * 50}")
    print(f"  {msg}")
    print(f"  环境路径: {VENV_DIR}")
    print(f"{'=' * 50}\n")


def run_or_die(cmd, cwd=None, shell=False):
    """运行命令，失败则终止"""
    print(f"  → {cmd if isinstance(cmd, str) else ' '.join(cmd)}")
    ret = subprocess.call(cmd, cwd=cwd, shell=shell)
    if ret != 0:
        print(f"  ✗ 命令执行失败 (exit={ret})，终止。")
        sys.exit(ret)


def ensure_venv():
    """确保 Python 虚拟环境存在、可用，并已安装依赖"""
    need_rebuild = False

    if not os.path.isdir(VENV_DIR):
        need_rebuild = True
        banner("创建 Python 虚拟环境...")
    elif not os.path.exists(VENV_PYTHON):
        print(f"  ⚠️ 虚拟环境已损坏 (找不到 {VENV_PYTHON})，准备重建...")
        need_rebuild = True
    else:
        try:
            # 同时检查 Python 版本和 pip 模块是否完整
            subprocess.check_call([VENV_PYTHON, "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.check_call([VENV_PYTHON, "-m", "pip", "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            print(f"  ⚠️ 虚拟环境已损坏或 pip 不可用，准备重建...")
            need_rebuild = True

    if need_rebuild:
        if os.path.exists(VENV_DIR):
            import shutil
            shutil.rmtree(VENV_DIR, ignore_errors=True)
        
        # 确保缓存父目录存在
        os.makedirs(os.path.dirname(VENV_DIR), exist_ok=True)
        run_or_die([sys.executable, "-m", "venv", VENV_DIR])

    banner("安装 / 更新 Python 依赖...")
    run_or_die([VENV_PYTHON, "-m", "pip", "install", "-r", REQUIREMENTS])


def ensure_node_modules():
    """确保前端 node_modules 已安装"""
    node_modules = os.path.join(FRONTEND_DIR, "node_modules")
    if not os.path.isdir(node_modules):
        banner("安装前端 Node.js 依赖...")
        npm_cmd = "npm.cmd" if IS_WINDOWS else "npm"
        run_or_die([npm_cmd, "install"], cwd=FRONTEND_DIR)
    else:
        print("  ✓ 前端依赖已就绪")


def kill_port_simple(port):
    """强大的端口清理（启动前预防性清理），联合 psutil 与原生命令"""
    print(f"  🔍 正在检查端口 {port} 是否被占用...")
    
    # 1. 尝试使用 psutil (跨平台，最优雅)
    try:
        import psutil
        for proc in psutil.process_iter(['pid', 'name']):
            try:
                for conn in proc.connections(kind='inet'):
                    if conn.laddr.port == port:
                        if proc.pid != os.getpid():
                            proc.kill()
                            print(f"  ✓ [psutil] 已终结占用端口 {port} 的进程: {proc.name()} (PID={proc.pid})")
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                continue
    except Exception:
        pass

    # 2. 针对 macOS/Linux 的系统原生兜底 (lsof)
    if not IS_WINDOWS:
        try:
            # 查找 PID
            cmd = ["lsof", "-t", f"-i:{port}"]
            output = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode().strip()
            if output:
                for pid in output.split("\n"):
                    if pid.isdigit() and int(pid) != os.getpid():
                        subprocess.call(["kill", "-9", pid], stderr=subprocess.DEVNULL)
                        print(f"  ✓ [lsof] 强制清理残留进程 PID={pid}")
        except Exception:
            pass
    
    # 3. 针对 Windows 的系统原生兜底 (netstat + taskkill)
    else:
        try:
            cmd = f'netstat -ano | findstr :{port}'
            output = subprocess.getoutput(cmd)
            for line in output.splitlines():
                if 'LISTENING' in line:
                    parts = line.split()
                    if len(parts) > 4:
                        pid = parts[-1]
                        if pid.isdigit() and int(pid) != os.getpid():
                            subprocess.call(['taskkill', '/F', '/PID', pid], stderr=subprocess.DEVNULL)
                            print(f"  ✓ [netstat] 强制清理残留进程 PID={pid}")
        except Exception:
            pass


def start_backend():
    """启动 FastAPI 后端"""
    banner("启动后端服务 (FastAPI on :8088)...")
    kill_port_simple(8088)
    cmd = [VENV_PYTHON, "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8088"]
    # 仅开发模式下才启用热重载（通过 --dev 命令行参数触发）
    # 注意：--reload 会导致 DeviceManager 被双重实例化，生产环境务必禁用
    if "--dev" in sys.argv:
        cmd.append("--reload")
        print("  ⚠️ 开发模式：已启用 Uvicorn 热重载 (--reload)")
    proc = subprocess.Popen(cmd, cwd=BACKEND_DIR)
    children.append(proc)
    return proc


def start_frontend():
    """启动 Vue 前端开发服务器"""
    banner("启动前端服务 (Vite on :5173)...")
    kill_port_simple(5173)
    npm_cmd = "npm.cmd" if IS_WINDOWS else "npm"
    cmd = [npm_cmd, "run", "dev", "--", "--host"]
    proc = subprocess.Popen(cmd, cwd=FRONTEND_DIR)
    children.append(proc)
    return proc


def cleanup(*args):
    """清理所有子进程"""
    print("\n\n  正在停止所有服务...")
    for proc in children:
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
    print("  ✓ 已停止。\n")
    sys.exit(0)


def main():
    # 注册退出信号
    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)
    if IS_WINDOWS:
        # Windows 不支持 SIGTERM 的某些用法，但 SIGINT (Ctrl+C) 可以
        pass

    banner("Web Control Center — 跨平台启动器")
    print(f"  操作系统: {platform.system()} {platform.release()}")
    print(f"  Python:   {sys.version.split()[0]}")
    print(f"  项目目录: {ROOT_DIR}")

    # 0. 针对外置磁盘进行元数据清理，防止 Vite/Rust 扫描到二进制隐藏文件导致崩溃
    if IS_MAC and "/Volumes/" in ROOT_DIR:
        print("  🧹 正在清理外置磁盘元数据 (dot_clean)...")
        try:
            subprocess.call(["dot_clean", "-m", ROOT_DIR], timeout=5)
        except Exception:
            pass

    # 1. 环境准备
    ensure_venv()
    ensure_node_modules()

    # 2. 启动服务
    backend_proc = start_backend()
    time.sleep(2)  # 给后端一点启动时间
    frontend_proc = start_frontend()

    banner("所有服务已启动！")
    print("  后端:  http://127.0.0.1:8088")
    print("  前端:  http://localhost:5173")
    print("  按 Ctrl+C 停止所有服务。")
    print()

    # 3. 阻塞等待
    try:
        while True:
            # 检查子进程是否意外退出
            if backend_proc.poll() is not None:
                print("  ⚠️ 后端进程已退出，正在清理...")
                cleanup()
            if frontend_proc.poll() is not None:
                print("  ⚠️ 前端进程已退出，正在清理...")
                cleanup()
            time.sleep(1)
    except KeyboardInterrupt:
        cleanup()


if __name__ == "__main__":
    main()
