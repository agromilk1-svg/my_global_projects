import threading
import collections
import time
import subprocess
import socket
import logging
import os
import sys
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.exceptions import NoDeviceConnectedError
from pymobiledevice3.lockdown import create_using_usbmux

logger = logging.getLogger("DeviceManager")
logging.basicConfig(level=logging.INFO)


class PortPool:
    """
    线程安全的端口池管理器。
    支持分配、回收、可用性探测，适配万台设备并发。
    """
    def __init__(self, start: int, end: int, label: str = ""):
        self.label = label
        self.start = start
        self.end = end
        # 双端队列：左侧弹出分配，回收时追加到右侧（FIFO 复用）
        self.available = collections.deque(range(start, end))
        self.in_use = set()
        self.lock = threading.Lock()
    
    @property
    def capacity(self):
        return self.end - self.start
    
    @property
    def used_count(self):
        with self.lock:
            return len(self.in_use)

    def allocate(self) -> int:
        """
        分配一个可用端口。
        优先从回收队列复用，自动跳过仍被系统占用的端口。
        """
        with self.lock:
            attempts = 0
            max_attempts = len(self.available)
            while self.available and attempts < max_attempts:
                port = self.available.popleft()
                if port not in self.in_use and self._is_port_free(port):
                    self.in_use.add(port)
                    logger.info(f"[PortPool:{self.label}] 分配端口 {port} (已用 {len(self.in_use)}/{self.capacity})")
                    return port
                # 端口仍被占用，放回队尾稍后重试
                self.available.append(port)
                attempts += 1
            
            raise RuntimeError(
                f"[PortPool:{self.label}] 端口池耗尽！"
                f"范围 {self.start}-{self.end}, 已用 {len(self.in_use)}, "
                f"可用队列 {len(self.available)} 个端口全部被系统占用"
            )
    
    def release(self, port: int):
        """回收端口到池尾，供后续设备复用。"""
        with self.lock:
            if port in self.in_use:
                self.in_use.discard(port)
                self.available.append(port)
                logger.info(f"[PortPool:{self.label}] 回收端口 {port} (已用 {len(self.in_use)}/{self.capacity})")
    
    @staticmethod
    def _is_port_free(port: int) -> bool:
        """通过 socket 探测端口是否真正空闲（无需 root 权限）。"""
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
                s.settimeout(0.1)
                result = s.connect_ex(('127.0.0.1', port))
                # connect_ex 返回非零 = 连接失败 = 端口空闲
                return result != 0
        except:
            return True


class DeviceState:
    def __init__(self, display_id, hardware_udid, wda_port, mjpeg_port, script_port):
        self.sync_lock = threading.Lock()  # [v1780] 线程同步锁 (健康检查与主逻辑状态一致性)
        self.udid = display_id          # 逻辑 ID (SerialNumber, 如 8ded2e7b)
        self.hardware_udid = hardware_udid  # 物理 ID (40-char UDID)
        self.wda_port = wda_port
        self.mjpeg_port = mjpeg_port
        self.script_port = script_port
        self.xctest_process = None
        self.wda_process = None
        self.mjpeg_process = None
        self.script_process = None      # ECMAIN 8089 转发进程
        self.is_wda_ready = False
        self.is_ecmain_ready = False
        self.tunnel_retry_count = 0     # 当前隧道重建次数
        self.last_health_ok = 0         # 上次健康检查通过的时间戳
    
    @property
    def wda_ready(self):
        return self.is_wda_ready
    
    def to_dict(self):
        return {
            "udid": self.udid,
            "hardware_udid": self.hardware_udid,
            "wda_port": self.wda_port,
            "mjpeg_port": self.mjpeg_port,
            "script_port": self.script_port,
            "wda_ready": self.is_wda_ready,
            "ecmain_ready": self.is_ecmain_ready,
        }


class DeviceManager:
    """
    负责监控 USB 设备插拔，并为其打通 WDA(10088)、MJPEG(10089) 和 ECMAIN(8089) 的代理隧道。
    重构版本：弹性端口池 + 自动重试 + 端口回收，支持万台设备。
    """
    
    # 端口池范围定义（每类 10000 个端口，总计 30000 个）
    WDA_PORT_START    = 20000
    WDA_PORT_END      = 30000
    MJPEG_PORT_START  = 30000
    MJPEG_PORT_END    = 40000
    SCRIPT_PORT_START = 40000
    SCRIPT_PORT_END   = 50000
    
    # 隧道重建最大重试次数
    MAX_TUNNEL_RETRIES = 3
    # 隧道健康检查间隔（秒）
    HEALTH_CHECK_INTERVAL = 30
    # 隧道不健康超时阈值（秒）：超过此时间无成功心跳则触发重建
    HEALTH_TIMEOUT = 90
    
    def __init__(self):
        self.devices = {}                   # 逻辑 udid (SerialNumber) -> DeviceState
        self.hardware_to_logical = {}       # hardware_udid -> logical_udid
        
        # 三类独立端口池
        self.wda_pool = PortPool(self.WDA_PORT_START, self.WDA_PORT_END, "WDA")
        self.mjpeg_pool = PortPool(self.MJPEG_PORT_START, self.MJPEG_PORT_END, "MJPEG")
        self.script_pool = PortPool(self.SCRIPT_PORT_START, self.SCRIPT_PORT_END, "Script")
        
        # 重建锁：防止同一设备并发重建
        self._rebuild_locks = {}
        self._rebuild_lock_guard = threading.Lock()
        
        # 物理断开防抖计数器
        self.disconnect_counters = {}
        
        self.running = True
        self.monitor_thread = threading.Thread(target=self._monitor_loop, daemon=True)
        self.monitor_thread.start()
    
    def _get_rebuild_lock(self, logical_id: str) -> threading.Lock:
        """获取指定设备的重建互斥锁（懒创建）。"""
        with self._rebuild_lock_guard:
            if logical_id not in self._rebuild_locks:
                self._rebuild_locks[logical_id] = threading.Lock()
            return self._rebuild_locks[logical_id]
    
    def _monitor_loop(self):
        """设备插拔监控主循环。"""
        while self.running:
            try:
                current_devices = list_devices()
                online_hardware_udids = set(d.serial for d in current_devices)
                
                # 1. 发现新物理插入的设备
                for hw_udid in online_hardware_udids:
                    if hw_udid not in self.hardware_to_logical:
                        logger.info(f"检测到新设备物理接入: {hw_udid}")
                        
                        # 通过 Lockdown 协议尝试获取 SerialNumber (即 ECMAIN 上报的逻辑 ID)
                        logical_id = hw_udid  # 默认回退
                        try:
                            with create_using_usbmux(hw_udid) as client:
                                serial = client.get_value(key="SerialNumber")
                                if serial:
                                    logical_id = serial
                                    logger.info(f"  设备映射完成 {hw_udid} -> SN:{logical_id}")
                        except Exception as e:
                            logger.warning(f"  无法获取 SerialNumber ({hw_udid}), 使用原始 UDID: {e}")

                        # 如果逻辑 ID 已经在管理中（说明是重连），则先清理旧的
                        if logical_id in self.devices:
                            logger.info(f"  设备 {logical_id} 重连，清理旧隧道...")
                            self._teardown_device(logical_id)
                        
                        # 从端口池分配
                        try:
                            wda = self.wda_pool.allocate()
                            mjpeg = self.mjpeg_pool.allocate()
                            script = self.script_pool.allocate()
                        except RuntimeError as e:
                            logger.error(f"  端口池分配失败: {e}")
                            continue
                        
                        state = DeviceState(logical_id, hw_udid, wda, mjpeg, script)
                        self.devices[logical_id] = state
                        self.hardware_to_logical[hw_udid] = logical_id
                        self._start_tunnels(logical_id)
                
                # 2. 移除物理断开的设备
                current_managed_hw_udids = list(self.hardware_to_logical.keys())
                for hw_udid in current_managed_hw_udids:
                    if hw_udid not in online_hardware_udids:
                        self.disconnect_counters[hw_udid] = self.disconnect_counters.get(hw_udid, 0) + 1
                        if self.disconnect_counters[hw_udid] >= 3:
                            logical_id = self.hardware_to_logical[hw_udid]
                            logger.info(f"设备物理断开确认: {hw_udid} (SN:{logical_id})")
                            self._teardown_device(logical_id)
                            del self.hardware_to_logical[hw_udid]
                            del self.disconnect_counters[hw_udid]
                        else:
                            logger.warning(f"设备 {hw_udid} 疑似物理闪断 (防抖计数: {self.disconnect_counters[hw_udid]}/3)")
                    else:
                        if hw_udid in self.disconnect_counters:
                            logger.info(f"设备 {hw_udid} 物理连接已恢复，取消防抖断开")
                            del self.disconnect_counters[hw_udid]

            except Exception as e:
                logger.error(f"设备监控循环异常: {e}")
            
            time.sleep(3)
    
    def _teardown_device(self, logical_id: str):
        """完全清理设备：终止隧道进程 + 回收端口。"""
        state = self.devices.get(logical_id)
        if not state:
            return
        
        self._stop_tunnels(logical_id)
        
        # 回收端口到池
        self.wda_pool.release(state.wda_port)
        self.mjpeg_pool.release(state.mjpeg_port)
        self.script_pool.release(state.script_port)
        
        # 清理设备记录
        if logical_id in self.devices:
            del self.devices[logical_id]
        
        # 清理重建锁
        with self._rebuild_lock_guard:
            self._rebuild_locks.pop(logical_id, None)
        
        logger.info(f"设备 {logical_id} 已完全清理（端口已回收）")

    def _start_tunnels(self, logical_id: str):
        """为设备建立所有隧道（WDA/MJPEG/Script）。"""
        state = self.devices.get(logical_id)
        if not state:
            return
        
        hw_udid = state.hardware_udid
        logger.info(
            f"正在建立隧道 {logical_id} "
            f"(Hardware:{hw_udid}, WDA:{state.wda_port}, MJPEG:{state.mjpeg_port}, Script:{state.script_port})..."
        )
        
        # 清理旧端口占用（使用增强版清理）
        import platform_utils
        platform_utils.kill_port(state.wda_port)
        platform_utils.kill_port(state.mjpeg_port)
        platform_utils.kill_port(state.script_port)
        
        # 激活设备端的 WDA 服务 (必须使用硬件 UDID)
        state.xctest_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", hw_udid, "xctest", "-B", "com.apple.accessibility.ecwda"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        time.sleep(2)  # 给予远端起振时间
        
        # WDA Tunnel (10088)
        state.wda_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", hw_udid, "relay", str(state.wda_port), "10088"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        # MJPEG Tunnel (10089)
        state.mjpeg_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", hw_udid, "relay", str(state.mjpeg_port), "10089"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        # ECMAIN Script Tunnel (8089) -> 映射到动态 script_port
        state.script_process = subprocess.Popen(
            [sys.executable, "-m", "tidevice", "-u", hw_udid, "relay", str(state.script_port), "8089"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        
        state.last_health_ok = time.time()
        state.tunnel_retry_count = 0
        
        # 启动健康检查守护线程
        threading.Thread(target=self._health_check_loop, args=(logical_id,), daemon=True).start()

    def _health_check_loop(self, logical_id: str):
        """
        持续后台健康检查：
        - 初始阶段（前30秒）：每3秒检查一次，快速标记就绪状态
        - 常态阶段：每 HEALTH_CHECK_INTERVAL 秒检查一次
        - 如果连续 HEALTH_TIMEOUT 秒检查失败，自动触发隧道重建
        """
        import requests as req_lib
        
        # 初始快速探测阶段（10 轮 × 3 秒 = 30 秒）
        state = self.devices.get(logical_id)
        if not state:
            return
        
        for _ in range(10):
            state = self.devices.get(logical_id)
            if not state:
                return
            time.sleep(3)
            
            try:
                if req_lib.get(f"http://127.0.0.1:{state.wda_port}/status", timeout=2).status_code == 200:
                    with state.sync_lock:
                        state.is_wda_ready = True
            except:
                pass
            try:
                test_payload = {"type": "SCRIPT", "payload": "// Probe"}
                if req_lib.post(f"http://127.0.0.1:{state.script_port}/task", json=test_payload, timeout=2.5).status_code == 200:
                    with state.sync_lock:
                        state.is_ecmain_ready = True
            except:
                pass

            with state.sync_lock:
                if state.is_wda_ready and state.is_ecmain_ready:
                    state.last_health_ok = time.time()
                    logger.info(f"设备 {logical_id} 隧道全部就绪 (WDA:{state.wda_port})")
                    break
        
        # 常态巡检阶段
        while self.running:
            state = self.devices.get(logical_id)
            if not state:
                return  # 设备已移除，退出巡检
            
            time.sleep(self.HEALTH_CHECK_INTERVAL)
            
            state = self.devices.get(logical_id)
            if not state:
                return
            
            wda_ok = False
            try:
                if req_lib.get(f"http://127.0.0.1:{state.wda_port}/status", timeout=2).status_code == 200:
                    wda_ok = True
            except:
                pass
            
            # 检测 relay 子进程是否崩溃
            relay_alive = (
                state.wda_process and state.wda_process.poll() is None
            )
            
            if wda_ok and relay_alive:
                with state.sync_lock:
                    state.is_wda_ready = True
                    state.last_health_ok = time.time()
            else:
                with state.sync_lock:
                    state.is_wda_ready = False
                elapsed = time.time() - state.last_health_ok
                
                if elapsed > self.HEALTH_TIMEOUT:
                    logger.warning(
                        f"设备 {logical_id} 隧道 {state.wda_port} 持续 {int(elapsed)}s 无响应，"
                        f"触发自动重建 (第 {state.tunnel_retry_count + 1} 次)"
                    )
                    self.rebuild_device_tunnels(logical_id)
                    return  # 重建后会启动新的 health_check 线程，当前线程退出

    def rebuild_device_tunnels(self, logical_id: str):
        """
        公开方法：销毁旧隧道 → 释放端口 → 分配新端口 → 重建隧道。
        线程安全，同一设备不会并发重建。
        """
        lock = self._get_rebuild_lock(logical_id)
        if not lock.acquire(blocking=False):
            logger.info(f"设备 {logical_id} 正在重建中，跳过重复请求")
            return False
        
        try:
            state = self.devices.get(logical_id)
            if not state:
                logger.warning(f"设备 {logical_id} 不在管理列表中，无法重建")
                return False
            
            if state.tunnel_retry_count >= self.MAX_TUNNEL_RETRIES:
                logger.error(
                    f"设备 {logical_id} 已达最大重试次数 ({self.MAX_TUNNEL_RETRIES})，"
                    f"放弃自动重建。请手动介入。"
                )
                return False
            
            hw_udid = state.hardware_udid
            old_wda = state.wda_port
            old_mjpeg = state.mjpeg_port
            old_script = state.script_port
            retry_count = state.tunnel_retry_count
            
            # 1. 停止旧隧道
            self._stop_tunnels(logical_id)
            
            # 2. 回收旧端口
            self.wda_pool.release(old_wda)
            self.mjpeg_pool.release(old_mjpeg)
            self.script_pool.release(old_script)
            
            # 3. 分配新端口
            try:
                new_wda = self.wda_pool.allocate()
                new_mjpeg = self.mjpeg_pool.allocate()
                new_script = self.script_pool.allocate()
            except RuntimeError as e:
                logger.error(f"重建时端口池分配失败: {e}")
                return False
            
            # 4. 更新设备状态
            state.wda_port = new_wda
            state.mjpeg_port = new_mjpeg
            state.script_port = new_script
            state.is_wda_ready = False
            state.is_ecmain_ready = False
            state.tunnel_retry_count = retry_count + 1
            
            logger.info(
                f"设备 {logical_id} 隧道重建: "
                f"WDA {old_wda} → {new_wda}, "
                f"MJPEG {old_mjpeg} → {new_mjpeg}, "
                f"Script {old_script} → {new_script} "
                f"(第 {state.tunnel_retry_count} 次重试)"
            )
            
            # 5. 启动新隧道
            self._start_tunnels(logical_id)
            return True
            
        finally:
            lock.release()

    def _stop_tunnels(self, logical_id: str):
        """终止设备的所有隧道子进程。"""
        state = self.devices.get(logical_id)
        if state:
            for p in [state.xctest_process, state.wda_process, state.mjpeg_process, state.script_process]:
                if p:
                    try:
                        p.terminate()
                        p.wait(timeout=3)
                    except:
                        try:
                            p.kill()
                        except:
                            pass
            state.xctest_process = None
            state.wda_process = None
            state.mjpeg_process = None
            state.script_process = None

    def get_all_devices(self):
        return [state.to_dict() for state in self.devices.values()]
    
    def get_pool_stats(self):
        """返回端口池使用情况统计（供监控 API 使用）。"""
        return {
            "wda": {"used": self.wda_pool.used_count, "capacity": self.wda_pool.capacity},
            "mjpeg": {"used": self.mjpeg_pool.used_count, "capacity": self.mjpeg_pool.capacity},
            "script": {"used": self.script_pool.used_count, "capacity": self.script_pool.capacity},
            "total_devices": len(self.devices),
        }


device_manager = DeviceManager()
