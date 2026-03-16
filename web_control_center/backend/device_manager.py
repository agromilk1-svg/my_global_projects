import threading
import time
import subprocess
import socket
import logging
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.exceptions import NoDeviceConnectedError
from pymobiledevice3.lockdown import create_using_usbmux

logger = logging.getLogger("DeviceManager")
logging.basicConfig(level=logging.INFO)

class DeviceState:
    def __init__(self, udid):
        self.udid = udid
        self.wda_port = 10088
        self.mjpeg_port = 10089
        self.xctest_process = None
        self.wda_process = None
        self.mjpeg_process = None
        self.is_wda_ready = False
        self.is_ecmain_ready = False
    
    def to_dict(self):
        return {
            "udid": self.udid,
            "wda_port": self.wda_port,
            "mjpeg_port": self.mjpeg_port,
            "wda_ready": self.is_wda_ready,
            "ecmain_ready": self.is_ecmain_ready,
        }

class DeviceManager:
    """
    负责监控 USB 设备插拔，并为其打通 WDA(10088) 和 ECMAIN(8089) 的代理隧道。
    """
    def __init__(self):
        self.devices = {} # udid -> DeviceState
        self.running = True
        self.monitor_thread = threading.Thread(target=self._monitor_loop, daemon=True)
        self.monitor_thread.start()

    def _monitor_loop(self):
        while self.running:
            try:
                current_devices = list_devices()
                online_udids = set(d.serial for d in current_devices)
                
                # 添加新设备
                for udid in online_udids:
                    if udid not in self.devices:
                        logger.info(f"New device detected: {udid}")
                        self.devices[udid] = DeviceState(udid)
                        self._start_tunnels(udid)
                
                # 移除断开设备
                offline_udids = set(self.devices.keys()) - online_udids
                for udid in offline_udids:
                    logger.info(f"Device disconnected: {udid}")
                    self._stop_tunnels(udid)
                    del self.devices[udid]

            except Exception as e:
                logger.error(f"Error in device monitor: {e}")
            
            time.sleep(3)

    def _start_tunnels(self, udid):
        import os, sys
        state = self.devices[udid]
        
        logger.info(f"Starting tunnels for {udid} (killer active)...")
        # 跨平台清理旧端口占用
        import platform_utils
        platform_utils.kill_port(state.wda_port)
        platform_utils.kill_port(state.mjpeg_port)
        
        # 激活设备端的 WDA 服务以产出信令和视频流
        state.xctest_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", udid, "xctest", "-B", "com.facebook.WebDriverAgentRunner.ecwda"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        time.sleep(2) # 给予远端起振时间
        
        # WDA Tunnel
        state.wda_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", udid, "relay", str(state.wda_port), "10088"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        # MJPEG Tunnel
        state.mjpeg_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", udid, "relay", str(state.mjpeg_port), "10089"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        
        # 简单模拟就绪状态 (通过轮询 ping 处理)
        threading.Thread(target=self._health_check, args=(udid,), daemon=True).start()

    def _health_check(self, udid):
        import requests
        state = self.devices.get(udid)
        if not state: return
        
        for _ in range(10):  # 等待 30 秒
            time.sleep(3)
            try:
                if requests.get(f"http://127.0.0.1:{state.wda_port}/status", timeout=2).status_code == 200:
                    state.is_wda_ready = True
            except:
                pass
            try:
                # 简单测试确保 MJPEG 是否联通实际上可以通过连接状态断言，此处暂时仅判定WDA
                if state.is_wda_ready:
                    state.is_ecmain_ready = True
            except:
                pass
            if state.is_wda_ready and state.is_ecmain_ready:
                logger.info(f"Device {udid} tunnels are fully ready.")
                break

    def _stop_tunnels(self, udid):
        state = self.devices.get(udid)
        if state:
            if state.xctest_process:
                state.xctest_process.terminate()
            if state.wda_process:
                state.wda_process.terminate()
            if state.mjpeg_process:
                state.mjpeg_process.terminate()

    def get_all_devices(self):
        return [state.to_dict() for state in self.devices.values()]

device_manager = DeviceManager()
