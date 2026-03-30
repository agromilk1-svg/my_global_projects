# -*- coding: utf-8 -*-
"""
跨平台工具模块 (Windows / macOS / CentOS)
封装所有依赖操作系统特性的操作，消除 lsof/pkill 等硬编码。
"""

import os
import sys
import platform
import shutil
import logging
import signal

import psutil

logger = logging.getLogger("PlatformUtils")

# ─── 操作系统标识 ───
IS_WINDOWS = platform.system() == "Windows"
IS_MAC = platform.system() == "Darwin"
IS_LINUX = platform.system() == "Linux"


def _kill_port_native(port: int):
    """
    使用操作系统原生命令清理端口占用（无需 root 权限的 lsof/netstat 兜底）。
    """
    import subprocess
    if not IS_WINDOWS:
        # macOS / Linux: lsof -ti :PORT 可以在非 root 下找到当前用户的进程
        try:
            output = subprocess.check_output(
                ["lsof", "-ti", f":{port}"],
                stderr=subprocess.DEVNULL
            ).decode().strip()
            if output:
                for pid_str in output.split("\n"):
                    pid_str = pid_str.strip()
                    if pid_str.isdigit() and int(pid_str) != os.getpid():
                        subprocess.call(["kill", "-9", pid_str], stderr=subprocess.DEVNULL)
                        logger.info(f"[lsof 兜底] 已杀掉占用端口 {port} 的进程 PID={pid_str}")
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass
    else:
        # Windows: netstat + taskkill
        try:
            output = subprocess.getoutput(f"netstat -ano | findstr :{port}")
            for line in output.splitlines():
                if "LISTENING" in line:
                    parts = line.split()
                    if len(parts) > 4:
                        pid_str = parts[-1]
                        if pid_str.isdigit() and int(pid_str) != os.getpid():
                            subprocess.call(["taskkill", "/F", "/PID", pid_str], stderr=subprocess.DEVNULL)
                            logger.info(f"[netstat 兜底] 已杀掉占用端口 {port} 的进程 PID={pid_str}")
        except Exception:
            pass


def kill_port(port: int):
    """
    杀掉占用指定端口的所有进程（跨平台）。
    优先使用 psutil，权限不足时降级为系统原生命令。
    """
    killed = set()
    try:
        for conn in psutil.net_connections(kind="inet"):
            if conn.laddr and conn.laddr.port == port and conn.pid:
                if conn.pid not in killed and conn.pid != os.getpid():
                    try:
                        proc = psutil.Process(conn.pid)
                        proc.kill()
                        killed.add(conn.pid)
                        logger.info(f"已杀掉占用端口 {port} 的进程 PID={conn.pid} ({proc.name()})")
                    except (psutil.NoSuchProcess, psutil.AccessDenied):
                        pass
    except psutil.AccessDenied:
        # psutil 无权限，降级为系统原生命令兜底
        logger.info(f"psutil 无权限枚举端口 {port}，启用原生命令兜底...")
        _kill_port_native(port)


def kill_process_by_keyword(keyword: str):
    """
    按命令行关键字杀掉匹配的进程（跨平台）。
    替代 `pkill -9 -f 'keyword'`。
    """
    for proc in psutil.process_iter(["pid", "cmdline"]):
        try:
            cmdline = proc.info.get("cmdline")
            if cmdline and keyword in " ".join(cmdline):
                if proc.pid != os.getpid():
                    proc.kill()
                    logger.info(f"已杀掉匹配 '{keyword}' 的进程 PID={proc.pid}")
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass


def find_tidevice() -> str:
    """
    跨平台查找 tidevice 可执行文件路径。
    优先顺序：
      1. 当前 Python 环境中的 tidevice（同 venv）
      2. shutil.which 在 PATH 中搜索
      3. 各系统常见安装位置
      4. 兜底返回 "tidevice"（由 subprocess 在 PATH 中查找）
    """
    # 1. 当前 Python 环境自带的 Scripts/bin 目录
    if IS_WINDOWS:
        venv_candidate = os.path.join(os.path.dirname(sys.executable), "Scripts", "tidevice.exe")
    else:
        venv_candidate = os.path.join(os.path.dirname(sys.executable), "tidevice")
    if os.path.isfile(venv_candidate):
        return venv_candidate

    # 2. shutil.which
    found = shutil.which("tidevice")
    if found:
        return found

    # 3. 平台特定的常见路径
    if IS_MAC:
        candidates = [
            os.path.expanduser("~/Library/Python/3.9/bin/tidevice"),
            "/usr/local/bin/tidevice",
            "/opt/homebrew/bin/tidevice",
        ]
    elif IS_LINUX:
        candidates = [
            "/usr/local/bin/tidevice",
            os.path.expanduser("~/.local/bin/tidevice"),
        ]
    else:  # Windows
        candidates = [
            os.path.join(os.environ.get("APPDATA", ""), "Python", "Scripts", "tidevice.exe"),
        ]

    for c in candidates:
        if os.path.isfile(c):
            return c

    # 4. 兜底
    return "tidevice"


def get_env_with_path() -> dict:
    """
    返回包含正确 PATH 的环境变量字典（跨平台）。
    macOS: 追加 /usr/local/bin, /opt/homebrew/bin
    Linux: 追加 /usr/local/bin, ~/.local/bin
    Windows: 不做额外处理
    """
    env = os.environ.copy()
    current_path = env.get("PATH", "")

    if IS_MAC:
        extra = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        env["PATH"] = f"{extra}:{current_path}"
    elif IS_LINUX:
        extra = f"/usr/local/bin:{os.path.expanduser('~/.local/bin')}:/usr/bin:/bin"
        env["PATH"] = f"{extra}:{current_path}"
    # Windows 不需要特殊处理

    return env
