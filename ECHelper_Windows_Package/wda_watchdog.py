#!/usr/bin/env python3
"""
WDA 常驻看护服务 (wda_watchdog.py)
===================================
持续监控所有通过 USB 连接的 iOS 设备，自动拉起 WDA 并维护端口映射。

用法:
    python wda_watchdog.py              # 看护所有已连接设备
    python wda_watchdog.py -u UDID      # 只看护指定设备

依赖: tidevice, pymobiledevice3 (已在 requirements.txt 中声明)
"""

import sys
import os
import time
import socket
import logging
import threading
import signal
import argparse
from pathlib import Path

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%H:%M:%S'
)
log = logging.getLogger("wda-watchdog")

# 尝试导入 tidevice
try:
    from tidevice.__main__ import main as tidevice_cli_main
    HAS_TIDEVICE = True
except ImportError:
    HAS_TIDEVICE = False
    log.warning("tidevice 未安装，将尝试使用命令行方式调用")

# 尝试导入 pymobiledevice3
try:
    from pymobiledevice3.usbmux import list_devices
    from pymobiledevice3.lockdown import create_using_usbmux
    HAS_PMD3 = True
except ImportError:
    HAS_PMD3 = False
    log.warning("pymobiledevice3 未安装，设备发现功能受限")


# ==================== 核心工具函数 ====================

import subprocess

def tidevice_invoke(args_list, wait=True):
    """通过子进程安全调用 tidevice，支持并发且不干扰全局 sys.argv"""
    if not HAS_TIDEVICE:
        log.error("代码中缺失 tidevice 库，请检查安装")
        return None

    # 使用当前 Python 解释器运行 tidevice 模块
    cmd = [sys.executable, "-m", "tidevice"] + list(args_list)
    
    try:
        if not wait:
            # 开启后台常驻进程 (用于 relay)
            return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        else:
            # 阻塞等待执行结果 (用于 launch 等)
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            if result.returncode != 0:
                log.error(f"tidevice 指令失败: {' '.join(cmd)}\n报错: {result.stderr}")
            return result
    except Exception as e:
        log.error(f"tidevice_exec 异常: {e}")
        return None


def check_wda_alive(port=10088, host="127.0.0.1", timeout=3):
    """检测 WDA 是否在指定端口响应"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect((host, port))
        # 尝试发一个 HTTP 请求
        s.sendall(b"GET /status HTTP/1.0\r\n\r\n")
        data = s.recv(1024)
        s.close()
        return b"200" in data or b"sessionId" in data or len(data) > 0
    except (socket.timeout, ConnectionRefusedError, OSError):
        return False


def discover_devices(target_udid=None):
    """发现设备并返回 (UDID, ConnectionType) 列表"""
    if not HAS_PMD3:
        if target_udid:
            return [(target_udid, "Unknown")]
        return []

    try:
        devices = list_devices()
        results = []
        for dev in devices:
            # 尝试获取连接类型 (Network/USB)
            conn_type = getattr(dev, "connection_type", "Unknown")
            if target_udid:
                if dev.serial == target_udid:
                    results.append((dev.serial, conn_type))
            else:
                results.append((dev.serial, conn_type))
        return results
    except Exception as e:
        log.error(f"设备发现失败: {e}")
        return []


# ==================== 看护核心 ====================

class WDAWatchdog:
    """单设备 WDA 看护器"""

    def __init__(self, udid, pc_port_base=10088, conn_type="Unknown"):
        self.udid = udid
        self.short_id = udid[:8]
        self.conn_type = conn_type
        self.pc_port = pc_port_base
        self.relay_threads = []
        self.relay_running = False
        self.consecutive_failures = 0
        self.max_failures = 5
        self.wda_bundle = "com.facebook.WebDriverAgentRunner.ecwda"

    def start_relay(self):
        """建立端口映射 (后台子进程)"""
        if self.relay_running:
            return

        self.relay_running = True
        port_mappings = [
            (self.pc_port, 10088),
            (self.pc_port + 1, 10089),
            (self.pc_port - 1999, 8089),  # 8089 映射
        ]

        for local_p, remote_p in port_mappings:
            # 使用子进程，非阻塞
            tidevice_invoke(["-u", self.udid, "relay", str(local_p), str(remote_p)], wait=False)
            log.info(f"  [{self.short_id}] 端口映射已建立: PC:{local_p} -> 手机:{remote_p}")

    def launch_wda(self):
        """通过 tidevice 拉起 WDA"""
        log.info(f"  [{self.short_id}] 🚀 正在拉起 WDA...")

        # 阻塞执行 launch，直到命令返回
        tidevice_invoke(["-u", self.udid, "launch", self.wda_bundle], wait=True)

        # 建立端口映射
        self.start_relay()

    def check_and_recover(self):
        """检查 WDA 状态，必要时恢复"""
        alive = check_wda_alive(port=self.pc_port)

        if alive:
            if self.consecutive_failures > 0:
                log.info(f"  [{self.short_id}] ✅ WDA 已恢复响应 (端口 {self.pc_port})")
            self.consecutive_failures = 0
            return True
        else:
            self.consecutive_failures += 1
            if self.consecutive_failures >= self.max_failures:
                log.warning(f"  [{self.short_id}] ❌ WDA 连续 {self.consecutive_failures} 次无响应，触发重启")
                self.relay_running = False  # 允许重建端口映射
                self.launch_wda()
                self.consecutive_failures = 0
                return False
            else:
                log.debug(f"  [{self.short_id}] ⏳ WDA 未响应 ({self.consecutive_failures}/{self.max_failures})")
                return False


# ==================== 主循环 ====================

def main():
    parser = argparse.ArgumentParser(description="WDA 常驻看护服务")
    parser.add_argument("-u", "--udid", help="指定设备 UDID (不指定则看护所有设备)")
    parser.add_argument("-p", "--port", type=int, default=10088, help="PC 端 WDA 端口 (默认 10088)")
    parser.add_argument("-i", "--interval", type=int, default=5, help="检查间隔 (秒，默认 5)")
    args = parser.parse_args()

    log.info("=" * 50)
    log.info("  WDA 常驻看护服务 (支持 Wi-Fi)")
    log.info("=" * 50)

    # 优雅退出
    running = True
    def signal_handler(sig, frame):
        nonlocal running
        log.info("\n⏹️  收到退出信号，正在停止...")
        running = False
    signal.signal(signal.SIGINT, signal_handler)

    watchdogs = {}  # udid -> WDAWatchdog
    check_interval = args.interval

    while running:
        # 1. 发现设备 (UDID, ConnectionType)
        device_infos = discover_devices(target_udid=args.udid)

        if not device_infos:
            log.info("⏳ 等待设备连接 (USB 或 Wi-Fi)...")
            time.sleep(check_interval)
            continue

        current_udids = [info[0] for info in device_infos]

        # 2. 为新设备创建看护器
        for i, (udid, conn_type) in enumerate(device_infos):
            if udid not in watchdogs:
                port_base = args.port + i * 10
                watchdogs[udid] = WDAWatchdog(udid, pc_port_base=port_base, conn_type=conn_type)
                log.info(f"📱 发现新设备: {udid[:8]}... (类型: {conn_type}, 端口: {port_base})")
                # 首次发现，立即尝试拉起
                watchdogs[udid].launch_wda()

        # 3. 清理已断开的设备
        disconnected = [u for u in watchdogs if u not in current_udids]
        for u in disconnected:
            log.info(f"📴 设备已断开: {u[:8]}...")
            del watchdogs[u]

        # 4. 检查所有设备的 WDA 状态
        for udid, wd in watchdogs.items():
            wd.check_and_recover()

        time.sleep(check_interval)

    log.info("✅ 看护服务已停止")


if __name__ == "__main__":
    main()
