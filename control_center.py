#!/usr/bin/env python3
"""
ECWDA 控制中心 - 统一工具
集成屏幕镜像、脚本生成器、触摸轨迹可视化和操作日志

功能：
1. 实时屏幕镜像（低延迟）
2. 鼠标点击/滑动控制
3. 真机触摸事件监听与轨迹显示
4. 脚本录制与回放
5. 操作日志窗口
6. USB 自动检测与优先连接
"""

import sys
import os
import shutil
import platform
import threading
import time
import base64
import json
import requests
import subprocess
from io import BytesIO
from typing import Optional, List, Tuple, Dict
from datetime import datetime
from collections import deque

try:
    from PyQt5.QtWidgets import (
        QApplication, QMainWindow, QWidget, QLabel, QVBoxLayout, QHBoxLayout,
        QPushButton, QLineEdit, QTextEdit, QSlider, QSizePolicy, QSplitter,
        QGroupBox, QMessageBox, QScrollArea, QFrame, QTabWidget, QShortcut,
        QComboBox, QSpinBox, QCheckBox, QFileDialog, QInputDialog, QFormLayout,
        QRadioButton, QButtonGroup, QStackedLayout
    )
    from PyQt5.QtCore import (
        Qt, QThread, pyqtSignal, QPoint, QTimer, QRect, QSize, pyqtSlot,
        QMutex, QMutexLocker, QUrl, QEvent, QProcess
    )
    from PyQt5.QtGui import (
        QImage, QPixmap, QPainter, QMouseEvent, QPen, QColor, QBrush,
        QPalette, QKeySequence, QFont, QSurfaceFormat
    )
    from PyQt5.QtWebEngineWidgets import QWebEngineView, QWebEngineSettings
    from PyQt5.QtNetwork import QNetworkProxy
except ImportError:
    print("需要安装 PyQt5 和 PyQtWebEngine: pip3 install PyQt5 PyQtWebEngine")
    sys.exit(1)

try:
    from PIL import Image
except ImportError:
    print("需要安装 Pillow: pip3 install Pillow")
    sys.exit(1)


try:
    from PyQt5.QtWebEngineWidgets import QWebEngineView
except ImportError:
    print("PyQtWebEngine not found. Please install via: pip install PyQtWebEngine")
    QWebEngineView = None

    QWebEngineView = None

# ========== USB 设备管理 ==========

# 尝试自动查找 tidevice，如果找不到则使用默认值 (Windows 下需确保在 PATH 中)
# 尝试自动查找 tidevice
# 优先查找 PATH，其次查找常见的 Python bin 目录
user_bin = os.path.expanduser("~/Library/Python/3.9/bin/tidevice")
TIDEVICE_PATH = shutil.which("tidevice")
if not TIDEVICE_PATH and os.path.exists(user_bin):
    TIDEVICE_PATH = user_bin
if not TIDEVICE_PATH:
    TIDEVICE_PATH = "tidevice" # Default fallback

def check_usb_device() -> Optional[Dict]:
    """检查是否有 USB 连接的 iOS 设备"""
    try:
        result = subprocess.run(
            [TIDEVICE_PATH, "list", "--json"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            devices = json.loads(result.stdout)
            for dev in devices:
                # tidevice 使用小写字段名
                if dev.get("conn_type") == "usb":
                    return {
                        "udid": dev.get("udid"),
                        "name": dev.get("name"),
                        "model": dev.get("market_name"),
                        "ios": dev.get("product_version")
                    }
    except Exception as e:
        print(f"[USB] 检测失败: {e}")
    return None


class USBRelayManager:
    """USB 转发管理器 - 带自动重连"""
    def __init__(self, wda_port: int = 10088, mjpeg_port: int = 10089):
        self.wda_port = wda_port
        self.mjpeg_port = mjpeg_port
        self.processes: List[subprocess.Popen] = []
        self.is_running = False
        self._udid: Optional[str] = None
        self._monitor_thread: Optional[threading.Thread] = None
        self._should_monitor = False
    
    def _kill_port_occupants(self, port: int):
        """杀掉占用指定端口的进程 (Mac 兼容)"""
        import socket
        # 快速检查端口是否被占用
        in_use = False
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            if s.connect_ex(('127.0.0.1', port)) == 0:
                in_use = True
                
        if not in_use:
            return

        print(f"[USB] 检测到端口 {port} 被占用，准备主动删除占用进程...")
        try:
            cmd = f"lsof -i :{port} -t"
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            if result.stdout:
                pids = result.stdout.strip().split('\n')
                for pid in pids:
                    if pid:
                        print(f"[USB] 成功强制杀掉占用端口 {port} 的残留进程 PID: {pid}")
                        subprocess.run(f"kill -9 {pid}", shell=True, stderr=subprocess.DEVNULL)
        except Exception as e:
            print(f"[USB] 清理端口占用失败: {e}")

    def _start_relay(self, port: int) -> subprocess.Popen:
        """启动单个端口转发进程"""
        cmd = [TIDEVICE_PATH, "relay", str(port), str(port)]
        if self._udid:
            cmd = [TIDEVICE_PATH, "-u", self._udid, "relay", str(port), str(port)]
        # 使用 DEVNULL 避免管道缓冲区满导致进程阻塞
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return p

    def start(self, udid: Optional[str] = None) -> bool:
        """启动 USB 转发 (WDA + MJPEG)"""
        if self.is_running:
            return True
        
        self._udid = udid
        
        # 启动前主动检查并清理可能的残留占用
        self._kill_port_occupants(self.wda_port)
        self._kill_port_occupants(self.mjpeg_port)
        
        try:
            # 1. Forward WDA Port
            print(f"[USB] Starting WDA relay on {self.wda_port} -> {self.wda_port}...")
            p_wda = self._start_relay(self.wda_port)
            self.processes.append(p_wda)
            
            # 2. Forward MJPEG Port
            print(f"[USB] Starting MJPEG relay on {self.mjpeg_port} -> {self.mjpeg_port}...")
            p_mjpeg = self._start_relay(self.mjpeg_port)
            self.processes.append(p_mjpeg)
            
            time.sleep(1)
            
            # Check if alive
            if p_wda.poll() is None:
                self.is_running = True
                print(f"[USB] 转发已启动: localhost:{self.wda_port}/{self.mjpeg_port} -> device")
                # 启动守护线程监控进程存活
                self._should_monitor = True
                self._monitor_thread = threading.Thread(target=self._monitor_loop, daemon=True)
                self._monitor_thread.start()
                return True
            else:
                print(f"[USB] 转发启动失败")
                self.stop()
                return False
                
        except Exception as e:
            print(f"[USB] 转发异常: {e}")
            self.stop()
            return False
    
    def _monitor_loop(self):
        """后台守护线程：监控 relay 进程存活，退出时自动重启"""
        while self._should_monitor and self.is_running:
            time.sleep(3)  # 每 3 秒检查一次
            if not self._should_monitor:
                break
            
            for i, p in enumerate(self.processes):
                if p and p.poll() is not None:
                    # 进程已退出，尝试重启
                    port = self.wda_port if i == 0 else self.mjpeg_port
                    name = "WDA" if i == 0 else "MJPEG"
                    print(f"[USB] {name} relay 进程退出 (code={p.returncode})，正在自动重启...")
                    try:
                        new_p = self._start_relay(port)
                        self.processes[i] = new_p
                        time.sleep(0.5)
                        if new_p.poll() is None:
                            print(f"[USB] {name} relay 重启成功")
                        else:
                            print(f"[USB] {name} relay 重启失败")
                    except Exception as e:
                        print(f"[USB] {name} relay 重启异常: {e}")
    
    def stop(self):
        """停止 USB 转发"""
        self._should_monitor = False
        for p in self.processes:
            if p:
                p.terminate()
                try:
                    p.wait(timeout=1)
                except:
                    p.kill()
        self.processes = []
        self.is_running = False
        print("[USB] 转发已停止")


class XCTestLauncher:
    """XCTest 会话启动器 - 使用 tidevice xctest 启动 WDA 以获得截屏权限"""
    
    DEFAULT_BUNDLE_ID = "com.ecwda.myRunner.xctrunner"
    
    def __init__(self, bundle_id: str = None):
        self.bundle_id = bundle_id or self.DEFAULT_BUNDLE_ID
        self.process: Optional[subprocess.Popen] = None
        self.is_running = False
        self.output_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self.log_callback: Optional[callable] = None
    
    def start(self, udid: Optional[str] = None, log_callback: callable = None) -> bool:
        """启动 WDA XCTest 会话
        
        Args:
            udid: 设备 UDID (可选，默认使用第一个设备)
            log_callback: 日志回调函数 (可选)
        
        Returns:
            是否启动成功
        """
        if self.is_running:
            return True
        
        self.log_callback = log_callback
        self._stop_event.clear()
        
        try:
            cmd = [TIDEVICE_PATH, "xctest", "-B", self.bundle_id]
            if udid:
                cmd = [TIDEVICE_PATH, "-u", udid, "xctest", "-B", self.bundle_id]
            
            self._log(f"[XCTest] 启动命令: {' '.join(cmd)}")
            
            self.process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1
            )
            
            # 启动输出监控线程
            self.output_thread = threading.Thread(target=self._monitor_output, daemon=True)
            self.output_thread.start()
            
            # 等待一下看是否立即失败
            time.sleep(2)
            
            if self.process.poll() is None:
                self.is_running = True
                self._log("[XCTest] WDA XCTest 会话启动成功!")
                return True
            else:
                self._log("[XCTest] WDA 启动失败，请检查 bundle ID 和设备连接")
                return False
                
        except Exception as e:
            self._log(f"[XCTest] 启动异常: {e}")
            return False
    
    def stop(self):
        """停止 XCTest 会话"""
        self._stop_event.set()
        
        if self.process:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
            self.process = None
        
        self.is_running = False
        self._log("[XCTest] WDA 会话已停止")
    
    def _monitor_output(self):
        """监控 tidevice 输出"""
        try:
            for line in self.process.stdout:
                if self._stop_event.is_set():
                    break
                line = line.strip()
                if line:
                    # 检测重要信息
                    if "ServerURL" in line or "http://" in line:
                        # 替换端口显示，避免混淆
                        if ":8100" in line:
                             line = line.replace(":8100", ":10088")
                        self._log(f"[XCTest] ✅ {line}")
                    elif "Error" in line.lower() or "error" in line.lower():
                        self._log(f"[XCTest] ❌ {line}")
                    else:
                        self._log(f"[XCTest] {line}")
        except Exception as e:
            if not self._stop_event.is_set():
                self._log(f"[XCTest] 输出监控异常: {e}")
    
    def _log(self, message: str):
        """输出日志"""
        print(message)
        if self.log_callback:
            try:
                self.log_callback(message)
            except:
                pass


class TouchTrail:
    """触摸轨迹数据"""
    def __init__(self, start_x: int, start_y: int, is_device: bool = False):
        self.points = [(start_x, start_y)]
        self.is_device = is_device  # 是否为设备触摸（vs 控制端操作）
        self.timestamp = time.time()
        self.finished = False
    
    def add_point(self, x: int, y: int):
        self.points.append((x, y))
    
    def finish(self):
        self.finished = True


class ScreenshotThread(QThread):
    """高频截图线程 - 极速优化版"""
    frame_ready = pyqtSignal(QImage, int, int)
    error_signal = pyqtSignal(str)
    fps_signal = pyqtSignal(float)
    latency_signal = pyqtSignal(int)
    
    def __init__(self, stream_url: str):
        super().__init__()
        self.stream_url = stream_url
        self.running = False
        
        # 生产者-消费者模型变量
        self._lock = QMutex()
        self._latest_bytes = None
        self._frame_counter = 0
        self.interval = 0.033

    def set_interval(self, interval: float):
        self.interval = max(0.016, interval)
    
    def run(self):
        self.running = True
        self._run_mjpeg_optimized()

    def get_latest_frame(self):
        """线程安全地获取最新帧数据 (由 UI 线程调用)"""
        if not self.running:
            return None
        with QMutexLocker(self._lock):
            return self._latest_bytes

    def _run_mjpeg_optimized(self):
        """MJPEG 流模式 - 生产者 (只负责收数据)"""
        # 直接使用传入的流地址，不做魔改
        mjpeg_url = self.stream_url
        
        # 60/50: 平衡画质与性能
        if "?" not in mjpeg_url:
            mjpeg_url += "?compressionQuality=60&scaleFactor=50"
        else:
            mjpeg_url += "&compressionQuality=60&scaleFactor=50"
        
        print(f"[Stream] Connecting to {mjpeg_url} ...")
        
        try:
            # 关键优化：绕过系统代理，防止 localhost/IP 被抓包工具拦截导致卡死
            s = requests.Session()
            s.trust_env = False 
            headers = {
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Connection": "keep-alive"
            }
            
            print(f"[Stream] Sending GET request to {mjpeg_url}")
            stream = s.get(mjpeg_url, stream=True, timeout=10, headers=headers)
            print(f"[Stream] Response Status: {stream.status_code}")
            
            if stream.status_code != 200:
                self.error_signal.emit(f"MJPEG connection failed: {stream.status_code}")
                return

            bytes_data = bytearray()
            
            # 使用大 buffer 全速读取
            frame_count = 0
            for chunk in stream.iter_content(chunk_size=1024*64): 
                if not self.running:
                    print("[Stream] Thread stopping...")
                    break
                
                # print(f"[Stream] Received chunk: {len(chunk)} bytes")
                bytes_data.extend(chunk)
                
                bytes_data.extend(chunk)
                
                # Low Latency Optimization:
                # Instead of parsing every frame sequentially (which causes lag if we fall behind),
                # we always jump to the LAST "Start of Image" marker in the buffer.
                # This explicitly drops older frames to keep the stream live.
                
                last_soi = bytes_data.rfind(b'\xff\xd8')
                
                if last_soi != -1:
                    # Found a start marker. Discard everything before it (old data).
                    # But we must check if we have a complete frame (SOI ... EOI)
                    
                    # Optimization: slice to the potential latest frame
                    current_pending = bytes_data[last_soi:]
                    
                    eoi_idx = current_pending.find(b'\xff\xd9')
                    
                    if eoi_idx != -1:
                        # We have a complete latest frame!
                        jpg_data = current_pending[:eoi_idx + 2]
                        
                        # Process it
                        with QMutexLocker(self._lock):
                            self._latest_bytes = jpg_data
                            self._frame_counter += 1
                        self._process_frame(jpg_data)
                        
                        # Keep only what's after this frame
                        bytes_data = current_pending[eoi_idx + 2:]
                    else:
                        # We have the start of a new frame, but not the end yet.
                        # Discard all old data (before last_soi) to save memory and ensure we track live.
                        bytes_data = current_pending
                
                else:
                    # No start marker found yet. 
                    # If buffer gets too huge without any marker (garbage), clear it.
                    if len(bytes_data) > 6000000: # ~6MB
                         print("[Stream] Buffer too large/corrupt, clearing")
                         bytes_data = bytearray()
                        
        except Exception as e:
            print(f"[Stream] Exception: {e}")
            import traceback
            traceback.print_exc()
            self.error_signal.emit(f"MJPEG Error: {e}")
            
    def _process_frame(self, jpg_data):
        """处理单帧 JPEG 数据"""
        try:
            # 性能优化：直接使用 Qt 加载 JPEG 数据
            qimg = QImage.fromData(jpg_data)
            if not qimg.isNull():
                width, height = qimg.width(), qimg.height()
                self.frame_ready.emit(qimg, width, height)
                
                # 简易计算延迟 (无法精确，因 MJPEG 不带发送时间戳)
                # 这里只能计算帧间隔
                now = time.time()
                self._frame_count += 1
                
                if now - self._last_fps_time >= 1.0:
                    fps = self._frame_count / (now - self._last_fps_time)
                    self.fps_signal.emit(fps)
                    self.latency_signal.emit(int(1000/fps) if fps > 0 else 0) # 估算显示延迟
                    self._frame_count = 0
                    self._last_fps_time = now
        except Exception as e:
            pass

    def stop(self):
        self.running = False


class LatencyThread(QThread):
    """后台线程监测 WDA 延迟 (Ping)，连续失败时发出断线信号"""
    latency_signal = pyqtSignal(int)
    connection_lost = pyqtSignal()  # 连续多次 WDA 不可达时触发
    
    # 连续失败阈值：超过此次数判定为断线 (设较高以避免 WDA 重操作期间误报)
    FAIL_THRESHOLD = 10
    
    def __init__(self, check_url):
        super().__init__()
        self.check_url = check_url
        self.running = True
        self.session = requests.Session()
        self.session.trust_env = False  # 绕过系统代理
        self._consecutive_fails = 0
        self._already_notified = False  # 避免重复发出 connection_lost
        self._paused = False   # 暂停标志（/source 请求期间暂停心跳）
        
    def pause(self):
        """暂停心跳检测 (在获取 UI 树等重操作期间调用)"""
        self._paused = True
    
    def resume(self):
        """恢复心跳检测并重置失败计数"""
        self._paused = False
        self._consecutive_fails = 0
        self._already_notified = False
        
    def run(self):
        while self.running:
            # 暂停期间跳过检测 (在 /source 等重操作期间 WDA 会阻塞)
            if self._paused:
                time.sleep(1)
                continue
            try:
                start_time = time.time()
                # 请求 status 端点，数据量极小
                resp = self.session.get(self.check_url, timeout=3)
                end_time = time.time()
                
                if resp.status_code == 200:
                    latency = int((end_time - start_time) * 1000)
                    self.latency_signal.emit(latency)
                    # 恢复正常，重置计数
                    if self._consecutive_fails > 0:
                        print(f"[Heartbeat] WDA 恢复正常 (之前连续失败 {self._consecutive_fails} 次)")
                    self._consecutive_fails = 0
                    self._already_notified = False
                else:
                    self._on_fail(f"HTTP {resp.status_code}")
            except Exception as e:
                self._on_fail(str(e))
                
            # Sleep 1s (分段 sleep 以便快速响应 stop)
            for _ in range(10):
                if not self.running: break
                time.sleep(0.1)

    def _on_fail(self, reason: str):
        """处理一次 WDA 不可达"""
        self._consecutive_fails += 1
        self.latency_signal.emit(-1)
        print(f"[Heartbeat] WDA 不可达 (连续第 {self._consecutive_fails} 次): {reason}")
        
        if self._consecutive_fails >= self.FAIL_THRESHOLD and not self._already_notified:
            self._already_notified = True
            print(f"[Heartbeat] 🔴 连续 {self.FAIL_THRESHOLD} 次失败，触发 connection_lost 信号")
            self.connection_lost.emit()

    def stop(self):
        self.running = False


class ScreenCanvas(QWidget):
    """
    透明触摸层: 覆盖在 WebEngineView 上，仅处理触摸事件和绘制 UI 辅助元素
    """
    click_signal = pyqtSignal(int, int) # x, y
    double_tap_signal = pyqtSignal(int, int)
    long_press_signal = pyqtSignal(int, int, float) # x, y, duration
    swipe_signal = pyqtSignal(int, int, int, int, float) # x1, y1, x2, y2, duration
    coord_signal = pyqtSignal(int, int)
    right_click_signal = pyqtSignal(int, int)
    selection_complete = pyqtSignal(int, int, int, int)
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        # 透明背景，让底下的 WebEngineView 可见
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setStyleSheet("background: transparent;")
        self.setMouseTracking(True)
        # 禁止系统上下文菜单，确保右键事件能正常传递
        self.setContextMenuPolicy(Qt.NoContextMenu)
        
        self._image_size = None
        self._current_frame = None
        self._drag_start = None
        self._is_dragging = False
        self._press_start_time = 0
        
        # Double tap detection
        self._last_click_time = 0
        self._last_click_pos = None
        
        # 触摸轨迹
        self._trails: List[TouchTrail] = []
        self._max_trails = 10
        self._current_trail: Optional[TouchTrail] = None
        
        # 设备触摸点
        self._device_touches: List[Tuple[int, int, float, str]] = []
        
        # 点击波纹动画 [(x, y, radius, alpha)]
        self._ripples = []
        
        # 性能优化
        self._last_size = None
        self._skip_trails = True  # 跳过轨迹绘制以提升性能
        
        # 选区模式 (用于截取模板图片)
        self._selection_mode = False

        # 初始化设备尺寸
        self._dev_width = 375
        self._dev_height = 667
        self._image_size = (375, 667)
        
        self._selection_start = None
        self._selection_end = None
        self._selection_rect = None
        
        # UI 元素审查高亮矩形 (设备逻辑坐标: x, y, w, h)
        self._highlight_rect = None
        self._highlight_label = ""

    def set_dev_size(self, w, h):
        """设置设备原始分辨率，用于坐标映射"""
        self._dev_width = w
        self._dev_height = h
        self._image_size = (w, h)
        self.update()
        self._selection_start = None  # QPoint - 控件坐标
        self._selection_end = None    # QPoint - 控件坐标
        self._last_selection_rect = None  # (x, y, w, h) 像素坐标 - 找图用
        self._selection_rect = None   # 当前选区矩形 (设备坐标)
    
    def set_highlight_rect(self, x: float, y: float, w: float, h: float, label: str = ""):
        """设置 UI 审查高亮矩形 (WDA 逻辑点坐标)"""
        self._highlight_rect = (x, y, w, h)
        self._highlight_label = label
        self.update()
    
    def clear_highlight(self):
        """清除高亮矩形"""
        self._highlight_rect = None
        self._highlight_label = ""
        self.update()
    
    def set_selection_mode(self, enabled: bool):
        """设置选区模式"""
        self._selection_mode = enabled
        self._selection_start = None
        self._selection_end = None
        self._selection_rect = None
        if enabled:
            self.setCursor(Qt.CrossCursor)
        else:
            self.setCursor(Qt.ArrowCursor)
        self.update()
    
    def set_image(self, qimg: QImage, dev_width: int, dev_height: int):
        self._image_size = (dev_width, dev_height)
        self._current_frame = qimg
        # 触发重绘，由 paintEvent 处理缩放和绘制，避免在 Python 层做大量计算
        self.update()
    
    def add_device_touch(self, x: int, y: int, touch_type: str):
        """添加设备触摸点"""
        now = time.time()
        self._device_touches.append((x, y, now, touch_type))
        if len(self._device_touches) > 20:
            self._device_touches = self._device_touches[-20:]
        self.update()

    def paintEvent(self, event):
        """高性能绘制：直接绘制 Image 避免 Pixmap 转换和 CPU 缩放"""
        painter = QPainter(self)
        
        # 1. 计算目标区域
        # 即使没有 current_frame (WebEngine 模式)，也需要计算 video_rect 以便绘制 overlay
        target_rect = self.rect()
        
        if self._current_frame:
            img_w, img_h = self._current_frame.width(), self._current_frame.height()
        else:
            img_w, img_h = self._dev_width, self._dev_height
            
        if img_w == 0 or img_h == 0:
            return

        # 计算保持长宽比的目标区域
        scale = min(target_rect.width() / img_w, target_rect.height() / img_h)
        draw_w = int(img_w * scale)
        draw_h = int(img_h * scale)
        draw_x = (target_rect.width() - draw_w) // 2
        draw_y = (target_rect.height() - draw_h) // 2
        
        draw_rect = QRect(draw_x, draw_y, draw_w, draw_h)
        
        # 2. 如果有 Native 帧，绘制它
        if self._current_frame:
            # 使用 SmoothTransformation 在绘制时可能会稍微费一点 GPU，但比 CPU 快
            painter.setRenderHint(QPainter.SmoothPixmapTransform, False)
            painter.drawImage(draw_rect, self._current_frame)
        
        # 3. 绘制覆盖层 (触摸轨迹、高亮矩形等)
        if self._trails or self._device_touches or self._selection_mode or self._drag_start or self._highlight_rect:
            self._draw_overlays(painter, draw_rect)

    def step_animations(self):
        """更新动画状态 (由主定时器调用)"""
        if not self._ripples:
            return
            
        new_ripples = []
        needs_update = False
        
        for x, y, r, alpha in self._ripples:
            if alpha > 5:
                # 扩散并淡出
                new_ripples.append((x, y, r + 2, alpha - 10))
                needs_update = True
        
        if needs_update:
            self._ripples = new_ripples
            self.update()

    def add_ripple(self, x, y):
        """添加点击波纹"""
        self._ripples.append((x, y, 5, 255)) # x, y, radius, alpha
        self.update()

    def _draw_overlays(self, painter: QPainter, video_rect: QRect):
        """绘制覆盖层 (轨迹、触摸点、选区、波纹)"""
        # 坐标转换辅助函数：设备坐标 -> 实际绘制区域坐标
        def dev_to_view(dx, dy):
             if not self._image_size: return None
             dv_w, dv_h = self._image_size
             vx = int(video_rect.x() + dx * video_rect.width() / dv_w)
             vy = int(video_rect.y() + dy * video_rect.height() / dv_h)
             return (vx, vy)

        painter.setRenderHint(QPainter.Antialiasing, True)
        
        # 1. 绘制波纹 (Ripple)
        for x, y, r, alpha in self._ripples:
            painter.setPen(QPen(QColor(0, 255, 255, alpha), 2))
            painter.setBrush(Qt.NoBrush)
            painter.drawEllipse(x - r, y - r, r * 2, r * 2)

        # 绘制控制端轨迹
        for trail in self._trails[-5:]:
             if len(trail.points) < 2: continue
             pen = QPen(QColor(0, 150, 255, 150))
             pen.setWidth(2)
             painter.setPen(pen)
             points = trail.points[-20:]
             for i in range(1, len(points)):
                 p1 = dev_to_view(*points[i-1])
                 p2 = dev_to_view(*points[i])
                 if p1 and p2:
                     painter.drawLine(p1[0], p1[1], p2[0], p2[1])

        # 绘制设备触摸点
        if self._device_touches:
             latest = self._device_touches[-1]
             # 只显示最近 0.5 秒内的
             if time.time() - latest[2] < 0.5:
                 pos = dev_to_view(latest[0], latest[1])
                 if pos:
                     painter.setBrush(QBrush(QColor(0, 255, 0, 200)))
                     painter.setPen(Qt.NoPen)
                     painter.drawEllipse(pos[0]-10, pos[1]-10, 20, 20)
                     
        # 绘制选区
        if self._selection_mode and self._selection_start and self._selection_end:
             # 这里 _selection_start 是控件坐标，直接画即可
             # 但需要限制在 video_rect 内吗？这里简化处理直接画
             rect = QRect(self._selection_start, self._selection_end).normalized()
             painter.setPen(QPen(QColor(255, 0, 0), 2))
             painter.setBrush(QBrush(QColor(255, 0, 0, 50)))
             painter.drawRect(rect)
        
        # 5. 绘制 UI 审查高亮矩形
        if self._highlight_rect:
            hx, hy, hw, hh = self._highlight_rect
            # 将设备像素坐标转换为 view 坐标
            p1 = dev_to_view(hx, hy)
            p2 = dev_to_view(hx + hw, hy + hh)
            if p1 and p2:
                # 绿色高亮边框
                painter.setPen(QPen(QColor(0, 255, 100), 2))
                painter.setBrush(QBrush(QColor(0, 255, 100, 30)))
                painter.drawRect(p1[0], p1[1], p2[0] - p1[0], p2[1] - p1[1])
                # 显示元素类型标签
                if self._highlight_label:
                    painter.setPen(QPen(QColor(255, 255, 255)))
                    font = painter.font()
                    font.setPointSize(9)
                    painter.setFont(font)
                    # 标签背景
                    label_rect = painter.fontMetrics().boundingRect(self._highlight_label)
                    bg_rect = QRect(p1[0], p1[1] - label_rect.height() - 4,
                                    label_rect.width() + 8, label_rect.height() + 4)
                    painter.setBrush(QBrush(QColor(0, 0, 0, 180)))
                    painter.setPen(Qt.NoPen)
                    painter.drawRect(bg_rect)
                    # 标签文字
                    painter.setPen(QPen(QColor(0, 255, 100)))
                    painter.drawText(p1[0] + 4, p1[1] - 4, self._highlight_label)
    
    # 移除旧的 _update_display_fast 和 _update_display
    # 更新 _widget_to_device 以使用动态计算的 rect (需要修改 logic)
    # 因为 paintEvent 实时计算 rect，我们在 handle input 时也需要计算
    
    def _get_video_rect(self):
        """计算视频在控件中的显示区域"""
        target_rect = self.rect()
        
        if self._current_frame:
            img_w, img_h = self._current_frame.width(), self._current_frame.height()
        else:
             img_w, img_h = self._dev_width, self._dev_height
             
        if img_w == 0 or img_h == 0: return QRect()
        
        scale = min(target_rect.width() / img_w, target_rect.height() / img_h)
        draw_w = int(img_w * scale)
        draw_h = int(img_h * scale)
        draw_x = (target_rect.width() - draw_w) // 2
        draw_y = (target_rect.height() - draw_h) // 2
        return QRect(draw_x, draw_y, draw_w, draw_h)

    def _widget_to_device(self, pos: QPoint) -> Optional[Tuple[int, int]]:
        """widget 坐标转换为设备坐标"""
        # 移除对 _current_frame 的依赖检查
        
        v_rect = self._get_video_rect()
        if v_rect.isEmpty():
            return None
            
        # 在 video_rect 内部的相对坐标，增加防越界智能贴合截取
        rel_x = max(0, min(pos.x() - v_rect.x(), v_rect.width() - 1))
        rel_y = max(0, min(pos.y() - v_rect.y(), v_rect.height() - 1))
        
        # 使用 self._dev_width 代替 self._image_size[0] 以确保一致性
        dev_w = self._dev_width
        dev_h = self._dev_height
            
        # dev_width/height are now set to actual pixel resolution by _update_screen_size
        # so we don't need * 2.0 anymore
        dev_x = int(rel_x * dev_w / v_rect.width())
        dev_y = int(rel_y * dev_h / v_rect.height())
        
        return (dev_x, dev_y)

    def _device_to_widget(self, dev_x: int, dev_y: int, pix_size: QSize=None) -> Optional[Tuple[int, int]]:
         # pix_size 参数为了兼容旧接口保留，但不再使用
         v_rect = self._get_video_rect()
         if v_rect.isEmpty(): return None

         vx = int(v_rect.x() + dev_x * v_rect.width() / self._dev_width)
         vy = int(v_rect.y() + dev_y * v_rect.height() / self._dev_height)
         return (vx, vy)
    
    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            coord = self._widget_to_device(event.pos())
            if coord:
                print(f"[TOUCH] Press: ({coord[0]}, {coord[1]})")
                self._drag_start = event.pos()
                self._press_start_time = time.time()
                self._is_dragging = False
                
                if self._selection_mode:
                    # 选区模式：记录起点
                    self._selection_start = event.pos()
                    self._selection_end = event.pos()
                else:
                    # 普通模式：绘制轨迹
                    self._current_trail = TouchTrail(coord[0], coord[1], is_device=False)
                    self._trails.append(self._current_trail)
        elif event.button() == Qt.RightButton:
            coord = self._widget_to_device(event.pos())
            if coord:
                print(f"[RIGHT-CLICK] 审查坐标: ({coord[0]}, {coord[1]})")
                self.right_click_signal.emit(coord[0], coord[1])
            else:
                print(f"[RIGHT-CLICK] 坐标转换失败 (pos={event.pos()})")
    
    def mouseMoveEvent(self, event: QMouseEvent):
        coord = self._widget_to_device(event.pos())
        if coord:
            # print(f"[TOUCH] Move: ({coord[0]}, {coord[1]})")
            self.coord_signal.emit(coord[0], coord[1])
        
        if self._drag_start:
            dx = abs(event.pos().x() - self._drag_start.x())
            dy = abs(event.pos().y() - self._drag_start.y())
            if dx > 10 or dy > 10:
                self._is_dragging = True
            
            if self._selection_mode:
                # 选区模式：更新终点并重绘
                self._selection_end = event.pos()
                self.update()  # 触发 paintEvent
            elif self._current_trail and coord:
                self._current_trail.add_point(coord[0], coord[1])
                self.update()
    
    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton and self._drag_start:
            end_pos = event.pos()
            start_coord = self._widget_to_device(self._drag_start)
            end_coord = self._widget_to_device(end_pos)
            
            duration = time.time() - self._press_start_time
            
            if self._selection_mode:
                # 选区模式 logic (kept same)
                if start_coord and end_coord and self._is_dragging:
                    x1, y1 = min(start_coord[0], end_coord[0]), min(start_coord[1], end_coord[1])
                    x2, y2 = max(start_coord[0], end_coord[0]), max(start_coord[1], end_coord[1])
                    width, height = x2 - x1, y2 - y1
                    if width > 10 and height > 10:
                        self._selection_rect = (x1, y1, width, height)
                        # 保存像素坐标的选区供找图功能使用
                        self._last_selection_rect = (x1, y1, width, height)
                        self.selection_complete.emit(x1, y1, width, height)
                self._selection_start = None
                self._selection_end = None
                self._drag_start = None
                self._is_dragging = False
                self.update()
            else:
                # Gesture Logic
                if self._current_trail:
                    self._current_trail.finish()
                
                if start_coord and end_coord:
                    if self._is_dragging:
                        # Swipe
                        # Enforce min duration for safety
                        if duration < 0.1: duration = 0.1
                        self.swipe_signal.emit(start_coord[0], start_coord[1],
                                             end_coord[0], end_coord[1], duration)
                    else:
                        # Click / Long Press / Double Tap
                        x, y = start_coord
                        
                        if duration > 0.8:
                            # Long Press
                            self.long_press_signal.emit(x, y, duration)
                        else:
                            # Check Double Tap
                            is_double = False
                            now = time.time()
                            if self._last_click_pos:
                                lx, ly = self._last_click_pos
                                # Distance check (30px) and Time check (300ms)
                                dist = ((x - lx)**2 + (y - ly)**2)**0.5
                                if now - self._last_click_time < 0.3 and dist < 30:
                                    is_double = True
                            
                            if is_double:
                                self.double_tap_signal.emit(x, y)
                                self._last_click_time = 0
                                self._last_click_pos = None
                            else:
                                self.click_signal.emit(x, y)
                                self._last_click_time = now
                                self._last_click_pos = (x, y)
                
                self._drag_start = None
                self._is_dragging = False
                self._current_trail = None
    
    def paintEvent(self, event):
        """绘制选区矩形"""
        super().paintEvent(event)
        
        # 绘制正在选择的矩形
        if self._selection_mode and self._selection_start and self._selection_end:
            painter = QPainter(self)
            painter.setRenderHint(QPainter.Antialiasing)
            
            # 绿色虚线边框
            pen = QPen(QColor(0, 255, 0), 2, Qt.DashLine)
            painter.setPen(pen)
            
            # 半透明填充
            brush = QBrush(QColor(0, 255, 0, 30))
            painter.setBrush(brush)
            
            # 绘制矩形
            rect = QRect(self._selection_start, self._selection_end).normalized()
            painter.drawRect(rect)
            
            # 显示尺寸
            if rect.width() > 50 and rect.height() > 20:
                painter.setPen(QPen(Qt.white))
                coord1 = self._widget_to_device(self._selection_start)
                coord2 = self._widget_to_device(self._selection_end)
                if coord1 and coord2:
                    w = abs(coord2[0] - coord1[0])
                    h = abs(coord2[1] - coord1[1])
                    painter.drawText(rect.center(), f"{w}x{h}")
            
            painter.end()
        
        # 绘制已完成的选区（绿色实线）
        elif self._selection_rect:
            painter = QPainter(self)
            pen = QPen(QColor(0, 255, 0), 2)
            painter.setPen(pen)
            
            # 转换设备坐标到控件坐标，修正黑边偏移
            video_rect = self._get_video_rect()
            if self._image_size and not video_rect.isEmpty():
                scale_x = video_rect.width() / self._image_size[0]
                scale_y = video_rect.height() / self._image_size[1]
                x = video_rect.x() + int(self._selection_rect[0] * scale_x)
                y = video_rect.y() + int(self._selection_rect[1] * scale_y)
                w = int(self._selection_rect[2] * scale_x)
                h = int(self._selection_rect[3] * scale_y)
                painter.drawRect(x, y, w, h)
            
            painter.end()


class OperationLog:
    """操作日志条目"""
    def __init__(self, op_type: str, details: str, source: str = "control"):
        self.timestamp = datetime.now()
        self.op_type = op_type
        self.details = details
        self.source = source  # "control" 或 "device"
    
    def to_string(self) -> str:
        time_str = self.timestamp.strftime("%H:%M:%S.%f")[:-3]
        icon = "🖱️" if self.source == "control" else "👆"
        return f"[{time_str}] {icon} {self.op_type}: {self.details}"


WDA_PORT = 10088  # WDA监听端口 (原生WDA)
ECMAIN_PORT = 8089 # ECMAIN监听端口 (我们的控制App)


class UIInspectorWidget(QWidget):
    """UI 元素审查标签页 — 查看 / 搜索 / 点击 UI 元素"""
    
    # 信号：请求点击某个坐标 (由 ControlCenter 连接到 tap 逻辑)
    tap_request = pyqtSignal(int, int)
    # 内部信号：线程安全的 UI 更新 (action: str, data: str)
    _ui_update = pyqtSignal(str, str)
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self._session = None    # requests.Session (由 ControlCenter 注入)
        self._wda_url = ""      # WDA base URL
        self._screen_scale = 2.0  # 像素/逻辑点缩放比
        self._ui_tree = None    # 缓存的 UI 树
        self._canvas = None     # ScreenCanvas 引用 (用于高亮)
        self._setup_ui()
        # 连接 UI 更新信号到主线程处理方法
        self._ui_update.connect(self._handle_ui_update)
    
    def set_connection(self, session, wda_url: str, screen_scale: float,
                       canvas=None, device_ip: str = "", latency_thread=None):
        """连接后注入网络会话和 URL"""
        self._session = session
        self._wda_url = wda_url
        self._screen_scale = screen_scale
        self._canvas = canvas
        self._latency_thread = latency_thread  # 用于暂停/恢复心跳
        # 优先用 WiFi 直连获取 UI 树（避免大数据量阻塞 USB relay）
        self._device_ip = device_ip
        if device_ip:
            self._source_url = f"http://{device_ip}:{WDA_PORT}/source?format=json"
        else:
            self._source_url = f"{wda_url}/source?format=json"
    
    def _setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        
        # === 1. 工具栏 ===
        toolbar = QHBoxLayout()
        
        self.refresh_btn = QPushButton("🔄 刷新 UI 树")
        self.refresh_btn.setStyleSheet("font-weight: bold; background-color: #4CAF50; color: white;")
        self.refresh_btn.clicked.connect(self._refresh_tree)
        toolbar.addWidget(self.refresh_btn)
        
        self.status_label = QLabel("未加载")
        self.status_label.setStyleSheet("color: #888; font-size: 11px;")
        toolbar.addWidget(self.status_label)
        toolbar.addStretch()
        
        layout.addLayout(toolbar)
        
        # === 2. 搜索区域 ===
        search_group = QGroupBox("🔍 搜索元素")
        search_layout = QVBoxLayout(search_group)
        
        # 搜索输入
        search_row = QHBoxLayout()
        search_row.addWidget(QLabel("关键词:"))
        self.search_input = QLineEdit()
        self.search_input.setPlaceholderText("输入 label / text / identifier ...")
        self.search_input.returnPressed.connect(self._search_elements)
        search_row.addWidget(self.search_input)
        
        self.search_btn = QPushButton("搜索")
        self.search_btn.clicked.connect(self._search_elements)
        search_row.addWidget(self.search_btn)
        
        self.exists_btn = QPushButton("判断存在")
        self.exists_btn.setToolTip("检查包含此文字的元素是否存在")
        self.exists_btn.clicked.connect(self._check_element_exists)
        search_row.addWidget(self.exists_btn)
        
        search_layout.addLayout(search_row)
        
        # 类型过滤 + 操作按钮
        filter_row = QHBoxLayout()
        filter_row.addWidget(QLabel("按类型:"))
        self.type_combo = QComboBox()
        self.type_combo.addItems([
            "全部", "Button", "StaticText", "TextField", "SecureTextField",
            "Image", "Cell", "Switch", "Slider", "ScrollView",
            "Table", "NavigationBar", "TabBar", "Alert", "Sheet"
        ])
        self.type_combo.setMaximumWidth(140)
        filter_row.addWidget(self.type_combo)
        
        self.filter_btn = QPushButton("按类型筛选")
        self.filter_btn.clicked.connect(self._filter_by_type)
        filter_row.addWidget(self.filter_btn)
        
        filter_row.addStretch()
        
        self.tap_element_btn = QPushButton("👆 点击选中元素")
        self.tap_element_btn.setToolTip("点击结果列表中选中元素的中心点")
        self.tap_element_btn.clicked.connect(self._tap_selected_element)
        filter_row.addWidget(self.tap_element_btn)
        
        search_layout.addLayout(filter_row)
        layout.addWidget(search_group)
        
        # === 3. 右键审查结果 (由 ControlCenter 写入) ===
        inspect_group = QGroupBox("🎯 右键审查结果")
        inspect_layout = QVBoxLayout(inspect_group)
        self.inspect_text = QTextEdit()
        self.inspect_text.setReadOnly(True)
        self.inspect_text.setMaximumHeight(120)
        self.inspect_text.setStyleSheet("font-family: monospace; font-size: 12px; background-color: #1e1e2e; color: #e0e0e0;")
        self.inspect_text.setPlaceholderText("右键点击屏幕上的元素，审查结果将显示在这里...")
        inspect_layout.addWidget(self.inspect_text)
        layout.addWidget(inspect_group)
        
        # === 4. 搜索结果列表 ===
        result_group = QGroupBox("📋 搜索结果")
        result_layout = QVBoxLayout(result_group)
        self.result_text = QTextEdit()
        self.result_text.setReadOnly(True)
        self.result_text.setStyleSheet("font-family: monospace; font-size: 11px; background-color: #f5f5f5; color: #333;")
        self.result_text.setPlaceholderText("搜索结果将显示在这里...")
        result_layout.addWidget(self.result_text)
        result_group.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        layout.addWidget(result_group)
    
    def show_inspect_result(self, info: str):
        """外部调用：显示右键审查结果 (线程安全)"""
        self._ui_update.emit("inspect", info)
    
    def _handle_ui_update(self, action: str, data: str):
        """主线程中处理 UI 更新 (由 _ui_update 信号触发)"""
        if action == "inspect":
            self.inspect_text.setPlainText(data)
        elif action == "status":
            self.status_label.setText(data)
        elif action == "result":
            self.result_text.setPlainText(data)
        elif action == "refresh_btn":
            self.refresh_btn.setEnabled(data == "1")
        elif action == "exists_btn":
            self.exists_btn.setEnabled(data == "1")
    
    def _refresh_tree(self):
        """刷新 UI 树"""
        if not self._session or not self._wda_url:
            self.status_label.setText("❌ 未连接 WDA")
            return
        
        self._ui_update.emit("refresh_btn", "0")
        self._ui_update.emit("status", "⏳ 正在获取 UI 树...")
        
        def fetch():
            try:
                # 暂停心跳 (因为 /source 会阻塞 WDA)
                if self._latency_thread:
                    self._latency_thread.pause()
                resp = self._session.get(self._source_url, timeout=15)
                if resp.status_code == 200:
                    data = resp.json()
                    self._ui_tree = data.get("value", data)
                    count = self._count_elements(self._ui_tree)
                    self._ui_update.emit("status", f"✅ 已加载 ({count} 个元素)")
                    self._ui_update.emit("result", f"UI 树已加载，共 {count} 个元素。\n\n请使用搜索功能查找元素，或右键点击屏幕审查。")
                else:
                    self._ui_update.emit("status", f"❌ HTTP {resp.status_code}")
            except Exception as e:
                self._ui_update.emit("status", f"❌ {str(e)[:30]}")
            finally:
                if self._latency_thread:
                    self._latency_thread.resume()
            self._ui_update.emit("refresh_btn", "1")
        
        threading.Thread(target=fetch, daemon=True).start()
    
    def _count_elements(self, node: dict) -> int:
        """递归统计元素数量"""
        count = 1
        for child in node.get("children", []):
            count += self._count_elements(child)
        return count
    
    def _search_elements(self):
        """按关键词搜索 UI 元素 (搜索 label, value, identifier)"""
        keyword = self.search_input.text().strip()
        if not keyword:
            self.result_text.setPlainText("请输入搜索关键词")
            return
        
        # 如果没有缓存的 UI 树，先刷新
        if not self._ui_tree:
            self._ui_update.emit("result", "⏳ 正在加载 UI 树...")
            
            def fetch_and_search():
                try:
                    if not self._session or not self._wda_url:
                        self._ui_update.emit("result", "❌ 未连接 WDA")
                        return
                    resp = self._session.get(self._source_url, timeout=15)
                    if resp.status_code == 200:
                        data = resp.json()
                        self._ui_tree = data.get("value", data)
                        self._do_search(keyword)
                    else:
                        self._ui_update.emit("result", f"❌ 获取 UI 树失败: HTTP {resp.status_code}")
                except Exception as e:
                    self._ui_update.emit("result", f"❌ {e}")
            
            threading.Thread(target=fetch_and_search, daemon=True).start()
        else:
            self._do_search(keyword)
    
    def _do_search(self, keyword: str):
        """在已缓存的 UI 树中搜索"""
        results = []
        self._search_recursive(self._ui_tree, keyword, results, depth=0)
        
        if results:
            lines = [f"找到 {len(results)} 个匹配元素:\n"]
            for i, (elem, depth) in enumerate(results, 1):
                lines.append(self._format_search_result(i, elem, depth))
            self._ui_update.emit("result", "\n".join(lines))
        else:
            self._ui_update.emit("result", f'未找到包含 "{keyword}" 的元素')
    
    def _search_recursive(self, node: dict, keyword: str, results: list, depth: int):
        """递归搜索元素"""
        # 搜索 label, value, rawIdentifier, name
        label = str(node.get("label", "") or "")
        value = str(node.get("value", "") or "")
        identifier = str(node.get("rawIdentifier", "") or node.get("name", "") or "")
        
        if (keyword.lower() in label.lower() or
            keyword.lower() in value.lower() or
            keyword.lower() in identifier.lower()):
            results.append((node, depth))
        
        for child in node.get("children", []):
            self._search_recursive(child, keyword, results, depth + 1)
    
    def _filter_by_type(self):
        """按类型筛选元素"""
        type_filter = self.type_combo.currentText()
        if type_filter == "全部":
            self._ui_update.emit("result", "请选择具体类型后点击筛选")
            return
        
        target_type = f"XCUIElementType{type_filter}"
        
        if not self._ui_tree:
            self._ui_update.emit("result", '⏳ 请先点击"刷新 UI 树"')
            return
        
        results = []
        self._filter_recursive(self._ui_tree, target_type, results, depth=0)
        
        if results:
            lines = [f"找到 {len(results)} 个 {type_filter} 元素:\n"]
            for i, (elem, depth) in enumerate(results, 1):
                if i > 50:
                    lines.append(f"\n... 还有 {len(results) - 50} 个元素未显示")
                    break
                lines.append(self._format_search_result(i, elem, depth))
            self._ui_update.emit("result", "\n".join(lines))
        else:
            self._ui_update.emit("result", f"未找到类型为 {type_filter} 的元素")
    
    def _filter_recursive(self, node: dict, target_type: str, results: list, depth: int):
        """递归筛选指定类型的元素"""
        if node.get("type") == target_type:
            results.append((node, depth))
        for child in node.get("children", []):
            self._filter_recursive(child, target_type, results, depth + 1)
    
    def _check_element_exists(self):
        """判断包含指定文字的元素是否存在 (实时查询，不用缓存)"""
        keyword = self.search_input.text().strip()
        if not keyword:
            self._ui_update.emit("inspect", "请输入关键词")
            return
        
        if not self._session or not self._wda_url:
            self._ui_update.emit("inspect", "❌ 未连接 WDA")
            return
        
        self._ui_update.emit("exists_btn", "0")
        self._ui_update.emit("inspect", f'⏳ 正在检查 "{keyword}" 是否存在...')
        
        def check():
            try:
                if self._latency_thread:
                    self._latency_thread.pause()
                import time as _time
                start = _time.time()
                resp = self._session.get(self._source_url, timeout=15)
                elapsed = int((_time.time() - start) * 1000)
                
                if resp.status_code == 200:
                    data = resp.json()
                    tree = data.get("value", data)
                    # 更新缓存
                    self._ui_tree = tree
                    
                    results = []
                    self._search_recursive(tree, keyword, results, depth=0)
                    
                    if results:
                        elem = results[0][0]
                        frame = elem.get("rect") or elem.get("frame", {})
                        el_type = elem.get("type", "").replace("XCUIElementType", "")
                        label = elem.get("label", "") or ""
                        self._ui_update.emit("inspect",
                            f"✅ 元素存在! (耗时 {elapsed}ms, 共找到 {len(results)} 个)\n\n"
                            f"  类型: {el_type}\n"
                            f"  label: \"{label}\"\n"
                            f"  位置: ({frame.get('x',0)}, {frame.get('y',0)}, "
                            f"{frame.get('width',0)}x{frame.get('height',0)})"
                        )
                        # 高亮第一个结果 (在主线程中执行)
                        if self._canvas:
                            from PyQt5.QtCore import QTimer
                            QTimer.singleShot(0, lambda: self._canvas.set_highlight_rect(
                                frame.get("x", 0) * self._screen_scale,
                                frame.get("y", 0) * self._screen_scale,
                                frame.get("width", 0) * self._screen_scale,
                                frame.get("height", 0) * self._screen_scale,
                                el_type
                            ))
                    else:
                        self._ui_update.emit("inspect",
                            f"❌ 元素不存在 (耗时 {elapsed}ms)\n\n"
                            f'  未找到包含 "{keyword}" 的元素'
                        )
                        if self._canvas:
                            from PyQt5.QtCore import QTimer
                            QTimer.singleShot(0, lambda: self._canvas.clear_highlight())
                else:
                    self._ui_update.emit("inspect", f"❌ HTTP {resp.status_code}")
            except Exception as e:
                self._ui_update.emit("inspect", f"❌ {e}")
            finally:
                if self._latency_thread:
                    self._latency_thread.resume()
            self._ui_update.emit("exists_btn", "1")
        
        threading.Thread(target=check, daemon=True).start()
    
    def _tap_selected_element(self):
        """点击搜索结果中的第一个元素的中心点"""
        if not self._ui_tree:
            self._ui_update.emit("inspect", "请先搜索或刷新 UI 树")
            return
        
        keyword = self.search_input.text().strip()
        if not keyword:
            self._ui_update.emit("inspect", "请输入要点击的元素关键词")
            return
        
        results = []
        self._search_recursive(self._ui_tree, keyword, results, depth=0)
        
        if results:
            elem = results[0][0]
            frame = elem.get("rect") or elem.get("frame", {})
            cx = frame.get("x", 0) + frame.get("width", 0) / 2
            cy = frame.get("y", 0) + frame.get("height", 0) / 2
            
            el_type = elem.get("type", "").replace("XCUIElementType", "")
            label = elem.get("label", "") or ""
            
            self._ui_update.emit("inspect",
                f'👆 点击元素: [{el_type}] "{label}"\n'
                f'  中心坐标: ({cx:.0f}, {cy:.0f})'
            )
            
            self.tap_request.emit(int(cx), int(cy))
        else:
            self._ui_update.emit("inspect", f'未找到包含 "{keyword}" 的元素')
    
    def _format_search_result(self, index: int, elem: dict, depth: int) -> str:
        """格式化搜索结果的单个元素"""
        el_type = elem.get("type", "Unknown").replace("XCUIElementType", "")
        label = elem.get("label", "") or ""
        value = elem.get("value", "") or ""
        identifier = elem.get("rawIdentifier", "") or ""
        frame = elem.get("rect") or elem.get("frame", {})
        fx = frame.get("x", 0)
        fy = frame.get("y", 0)
        fw = frame.get("width", 0)
        fh = frame.get("height", 0)
        visible = elem.get("isVisible", True)
        
        # 简洁单行格式
        parts = [f"  {index}. [{el_type}]"]
        if label:
            parts.append(f'"{label}"')
        if value and value != label:
            parts.append(f'value="{value}"')
        if identifier:
            parts.append(f'id="{identifier}"')
        parts.append(f"({fx},{fy} {fw}x{fh})")
        if not visible:
            parts.append("⚠️hidden")
        
        return " ".join(parts)


class ECMainTestWidget(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.device_ip = "192.168.1.5" # Default
        self.setup_ui()
        
    def setup_ui(self):
        layout = QVBoxLayout(self)
        
        # IP Input
        ip_layout = QHBoxLayout()
        ip_layout.addWidget(QLabel("Device IP:"))
        self.ip_input = QLineEdit(self.device_ip)
        self.ip_input.textChanged.connect(self.update_ip)
        ip_layout.addWidget(self.ip_input)
        layout.addLayout(ip_layout)
        
        # 1. Script Test
        script_group = QGroupBox("Script Test")
        script_layout = QVBoxLayout()
        self.script_input = QTextEdit()
        self.script_input.setPlaceholderText("Enter JS script here...")
        self.script_input.setMaximumHeight(80)
        script_layout.addWidget(self.script_input)
        
        btn_send_script = QPushButton("Send Script (Push to ECMAIN)")
        btn_send_script.clicked.connect(self.send_script)
        script_layout.addWidget(btn_send_script)
        script_group.setLayout(script_layout)
        layout.addWidget(script_group)
        
        # 2. VPN Test
        vpn_group = QGroupBox("VPN Test")
        vpn_layout = QFormLayout()
        self.vpn_server = QLineEdit()
        self.vpn_account = QLineEdit()
        self.vpn_password = QLineEdit()
        self.vpn_secret = QLineEdit()
        vpn_layout.addRow("Server:", self.vpn_server)
        vpn_layout.addRow("Account:", self.vpn_account)
        vpn_layout.addRow("Password:", self.vpn_password)
        vpn_layout.addRow("Secret:", self.vpn_secret)
        
        btn_vpn_connect = QPushButton("Connect VPN")
        btn_vpn_connect.clicked.connect(self.connect_vpn)
        btn_vpn_disconnect = QPushButton("Stop VPN")
        btn_vpn_disconnect.clicked.connect(self.stop_vpn)
        
        vpn_btn_layout = QHBoxLayout()
        vpn_btn_layout.addWidget(btn_vpn_connect)
        vpn_btn_layout.addWidget(btn_vpn_disconnect)
        vpn_layout.addRow(vpn_btn_layout)
        
        vpn_group.setLayout(vpn_layout)
        layout.addWidget(vpn_group)
        
        # 3. System Test
        sys_group = QGroupBox("System Ops")
        sys_layout = QVBoxLayout()
        
        # Install IPA
        install_layout = QHBoxLayout()
        self.ipa_path = QLineEdit("/var/mobile/Documents/test.ipa")
        install_layout.addWidget(QLabel("IPA Path:"))
        install_layout.addWidget(self.ipa_path)
        btn_install = QPushButton("Install IPA")
        btn_install.clicked.connect(self.install_app)
        install_layout.addWidget(btn_install)
        sys_layout.addLayout(install_layout)
        
        # Set Device Info
        info_layout = QHBoxLayout()
        self.info_model = QLineEdit("iPhone15,2")
        self.info_ver = QLineEdit("16.5")
        info_layout.addWidget(QLabel("Model:"))
        info_layout.addWidget(self.info_model)
        info_layout.addWidget(QLabel("OS:"))
        info_layout.addWidget(self.info_ver)
        btn_set_info = QPushButton("Spoof Info")
        btn_set_info.clicked.connect(self.set_info)
        info_layout.addWidget(btn_set_info)
        sys_layout.addLayout(info_layout)
        
        sys_group.setLayout(sys_layout)
        layout.addWidget(sys_group)

        layout.addWidget(sys_group)
        
        layout.addStretch()
        
    def update_ip(self, text):
        self.device_ip = text
        
    def _send_task(self, task_type, payload):
        url = f"http://{self.device_ip}:{ECMAIN_PORT}/task"
        data = {
            "type": task_type,
            "payload": payload
        }
        self.log(f"Sending {task_type} to {url}...")
        try:
            resp = self.session.post(url, json=data, timeout=5)
            self.log(f"Response: {resp.status_code} {resp.text}")
        except Exception as e:
            self.log(f"Error: {e}")

    def send_script(self):
        script = self.script_input.toPlainText()
        if not script:
            script = "mobile: scroll" # Default test
        self._send_task("SCRIPT", script)
        
    def connect_vpn(self):
        payload = {
            "server": self.vpn_server.text(),
            "account": self.vpn_account.text(),
            "password": self.vpn_password.text(),
            "secret": self.vpn_secret.text()
        }
        self._send_task("VPN", payload)

    def stop_vpn(self):
        self._send_task("STOP_VPN", {})

    def install_app(self):
        path = self.ipa_path.text()
        self._send_task("INSTALL", path)
        
    def set_info(self):
        payload = {
            "model": self.info_model.text(),
            "version": self.info_ver.text()
        }
        self._send_task("SET_INFO", payload)
        
    def log(self, msg):
        print(f"[ECTest] {msg}")
        # Ideally find the LogWidget and append, but print is fine for now


class ControlCenter(QMainWindow):
    """控制中心主窗口"""
    
    def __init__(self):
        super().__init__()
        self.setWindowTitle("ECWDA 控制中心")
        self.setGeometry(100, 100, 1400, 900)
        
        self.wda_url = ""
        self.session_id = None
        self.stream_thread = None
        self.is_connected = False
        self.is_recording = False
        self.is_touch_monitoring = False
        
        # 屏幕缩放因子 (截图像素 / WDA 点)
        self.screen_scale = 2.0  # 默认 @2x，会在连接时自动检测
        self.wda_width = 375
        self.wda_height = 667
        
        self.control_url = "" 
        self.stream_url = "" 
        self.wda_url = "" # Compat
        
        # USB 管理
        self.usb_relay = USBRelayManager()
        self.using_usb = False
        self._prev_usb_online = None  # 上次 USB 设备在线状态 (用于断线检测)
        
        # 网络请求优化 (绕过系统代理)
        self.session = requests.Session()
        self.session.trust_env = False # 关键: 不读取环境变量代理
        self.session.headers.update({
             "Connection": "keep-alive",
             "User-Agent": "ECWDA-Control/1.0"
        })
        
        # 操作日志
        self.operation_logs: List[OperationLog] = []
        self.max_logs = 500
        
        # 录制的脚本
        self.recorded_actions = []
        
        # API 测试状态
        self.pick_mode = None  # "coord" 或 "color"
        self.template_image_data = None  # Base64 模板图片
        self.selection_mode_type = None  # "template" 或 "region"
        
        self.main_splitter = None
        self._first_frame_resized = False
        
        self._setup_ui()
        self._setup_timers()
        
        # WDA Process
        self.wda_process = None
    
    def _setup_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QHBoxLayout(central)
        main_layout.setSpacing(0)
        main_layout.setContentsMargins(0, 0, 0, 0)
        
        # === 左侧：屏幕区域 ===
        left_panel = QVBoxLayout()
        left_panel.setContentsMargins(0, 0, 0, 0)
        
        # 连接设置区域
        conn_group = QGroupBox("连接设置")
        conn_layout = QHBoxLayout()
        
        self.url_label = QLabel("设备 IP:")
        conn_layout.addWidget(self.url_label)
        
        self.url_input = QLineEdit()
        self.url_input.setPlaceholderText("192.168.x.x") # 只输入 IP
        self.url_input.setText("192.168.110.253")
        conn_layout.addWidget(self.url_input)
        
        self.connect_btn = QPushButton("🔗 连接")
        self.connect_btn.setStyleSheet("font-weight: bold; font-size: 13px;")
        self.connect_btn.clicked.connect(self._toggle_connection)
        conn_layout.addWidget(self.connect_btn)
        
        # USB Checkbox
        self.usb_check = QCheckBox("USB")
        self.usb_check.setToolTip("使用 USB 连接 (低延迟)")
        # 如果检测到 USB 设备，自动勾选 (在 _check_usb_status 中处理)
        conn_layout.addWidget(self.usb_check)
        
        # USB Status
        conn_group_layout = QVBoxLayout()
        self.usb_info_label = QLabel("正在检测 USB...")
        self.usb_info_label.setStyleSheet("color: #888;")
        conn_group_layout.addWidget(self.usb_info_label)
        conn_group_layout.addLayout(conn_layout)

        # Launch WDA Button (Moved here)
        btn_launch_wda = QPushButton("启动 ECWDA")
        btn_launch_wda.setStyleSheet("background-color: #4CAF50; color: white; font-weight: bold;")
        btn_launch_wda.clicked.connect(self.launch_ecwda)
        conn_group_layout.addWidget(btn_launch_wda)
        
        conn_group.setLayout(conn_group_layout)
        left_panel.addWidget(conn_group)
        
        # ECMAIN 连接区域
        ecmain_layout = QHBoxLayout()
        ecmain_layout.addWidget(QLabel("ECMAIN:"))
        self.ecmain_url_input = QLineEdit()
        self.ecmain_url_input.setPlaceholderText("ECMAIN 地址")
        # 默认跟 WDA 联动
        self.ecmain_url_input.setText("http://192.168.110.253:8089") 
        ecmain_layout.addWidget(self.ecmain_url_input)
        
        self.ecmain_test_btn = QPushButton("🔗 测试")
        self.ecmain_test_btn.clicked.connect(self._test_ecmain_connection)
        ecmain_layout.addWidget(self.ecmain_test_btn)
        
        self.ecmain_status_label = QLabel("未连接")
        self.ecmain_status_label.setStyleSheet("color: #888;")
        ecmain_layout.addWidget(self.ecmain_status_label)
        left_panel.addLayout(ecmain_layout)
        
        # 状态栏
        status_layout = QHBoxLayout()
        self.status_label = QLabel("未连接")
        self.status_label.setStyleSheet("color: #888;")
        self.status_label.setFixedWidth(200)
        status_layout.addWidget(self.status_label)
        
        status_layout.addStretch()
        
        self.fps_label = QLabel("FPS: --")
        self.fps_label.setStyleSheet("color: #888; font-size: 11px;")
        status_layout.addWidget(self.fps_label)
        
        status_layout.addSpacing(10)
        
        self.latency_label = QLabel("延迟: --")
        self.latency_label.setStyleSheet("color: #888; font-size: 11px;")
        status_layout.addWidget(self.latency_label)
        
        status_layout.addSpacing(5)
        left_panel.addLayout(status_layout)
        
        # === 左侧: 屏幕显示区域 (Canvas) ===
        # 容器 - 使用 StackedLayout 叠加 WebEngine 和 Transparent Canvas
        self.video_container = QWidget()
        self.video_container.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.video_container.setStyleSheet("background-color: #000;")
        
        # 布局
        self.stack_layout = QStackedLayout(self.video_container)
        self.stack_layout.setStackingMode(QStackedLayout.StackAll) # 叠加模式
        
        # 1. 底层: WebEngineView
        self.web_view = QWebEngineView()
        self.web_view.setStyleSheet("background: black;")
        self.web_view.settings().setAttribute(QWebEngineSettings.ShowScrollBars, False)
        # 禁用 WebEngineView 的右键上下文菜单，避免拦截 ScreenCanvas 的右键事件
        self.web_view.setContextMenuPolicy(Qt.NoContextMenu)
        self.stack_layout.addWidget(self.web_view)
        
        # 2. 顶层: 透明触摸层
        self.screen_canvas = ScreenCanvas()
        
        # Connect Signals
        self.screen_canvas.click_signal.connect(self._on_canvas_tap)
        self.screen_canvas.double_tap_signal.connect(self._on_canvas_double_tap)
        self.screen_canvas.long_press_signal.connect(self._on_canvas_long_press)
        self.screen_canvas.swipe_signal.connect(self._on_canvas_swipe)
        self.screen_canvas.coord_signal.connect(self._update_coord_label)
        self.screen_canvas.right_click_signal.connect(self._on_right_click)
        self.screen_canvas.selection_complete.connect(self._on_selection_complete)
        
        self.stack_layout.addWidget(self.screen_canvas)
        
        # 强制将透明触摸层置于顶层
        self.stack_layout.setCurrentWidget(self.screen_canvas)
        self.screen_canvas.raise_()
            
        left_panel.addWidget(self.video_container, 1)
        
        # 坐标显示
        coord_layout = QHBoxLayout()
        self.coord_label = QLabel("坐标: (-, -)")
        self.coord_label.setStyleSheet("color: #FFD700; font-size: 14px; font-weight: bold;")
        coord_layout.addWidget(self.coord_label)
        
        self.device_touch_label = QLabel("设备触摸: --")
        self.device_touch_label.setStyleSheet("color: #00BFFF; font-size: 12px;")
        coord_layout.addWidget(self.device_touch_label)
        coord_layout.addStretch()
        left_panel.addLayout(coord_layout)
        
        # 快捷按钮
        btn_layout = QHBoxLayout()
        
        self.record_btn = QPushButton("⏺ 录制")
        self.record_btn.clicked.connect(self._toggle_recording)
        btn_layout.addWidget(self.record_btn)
        
        self.touch_monitor_btn = QPushButton("👆 监听触摸")
        self.touch_monitor_btn.clicked.connect(self._toggle_touch_monitor)
        btn_layout.addWidget(self.touch_monitor_btn)
        
        home_btn = QPushButton("🏠 Home")
        home_btn.clicked.connect(self._press_home)
        btn_layout.addWidget(home_btn)
        
        screenshot_btn = QPushButton("📷 截图")
        screenshot_btn.clicked.connect(self._save_screenshot)
        btn_layout.addWidget(screenshot_btn)
        
        left_panel.addLayout(btn_layout)
        
        # 左侧面板容器
        left_widget = QWidget()
        left_widget.setLayout(left_panel)
        
        # === 右侧：脚本和日志 ===
        right_panel = QVBoxLayout()
        
        # 标签页
        self.tabs = QTabWidget()
        
        # 脚本面板
        script_tab = QWidget()
        script_tab_layout = QVBoxLayout(script_tab)
        self.script_edit = QTextEdit()
        self.script_edit.setPlaceholderText("在此输入 JS 脚本，点击发送将透过 ECMAIN 下发到设备执行...")
        self.script_edit.setStyleSheet("font-family: monospace; font-size: 12px;")
        script_tab_layout.addWidget(self.script_edit)
        script_send_btn = QPushButton("▶ 发送脚本到设备")
        script_send_btn.clicked.connect(self._send_script_to_device)
        script_tab_layout.addWidget(script_send_btn)
        self.tabs.addTab(script_tab, "📝 脚本")
        
        # 日志标签页
        log_tab = QWidget()
        log_layout = QVBoxLayout(log_tab)
        
        self.log_text = QTextEdit()
        self.log_text.setReadOnly(True)
        self.log_text.setStyleSheet("font-family: monospace; font-size: 11px; background-color: #1e1e2e;")
        log_layout.addWidget(self.log_text)
        
        log_btn_layout = QHBoxLayout()
        clear_log_btn = QPushButton("清空日志")
        clear_log_btn.clicked.connect(self._clear_logs)
        log_btn_layout.addWidget(clear_log_btn)
        log_btn_layout.addStretch()
        log_layout.addLayout(log_btn_layout)
        
        self.tabs.addTab(log_tab, "📋 操作日志")
        
        # === ECWDA 接口文档标签页 ===
        # === ECWDA 接口文档标签页 (完整版) ===
        ecwda_tab = QWidget()
        ecwda_layout = QVBoxLayout(ecwda_tab)
        
        ecwda_info = QTextEdit()
        ecwda_info.setReadOnly(True)
        ecwda_info.setStyleSheet("font-family: monospace; font-size: 11px; background-color: #f0f0f5; color: #333;")
        ecwda_info.setHtml("""
        <h3>🚀 ECWDA 接口能力概览</h3>
        
        <p><b>1. 基础控制</b></p>
        <ul>
            <li><code>/status</code> - 获取设备状态、SessionId、由于 IP</li>
            <li><code>/session</code> - 创建/删除会话 (POST/DELETE)</li>
            <li><code>/wda/homescreen</code> - 模拟 Home 键</li>
            <li><code>/wda/lock</code> - 锁定屏幕</li>
            <li><code>/wda/unlock</code> - 解锁屏幕</li>
            <li><code>/wda/screen</code> - 获取屏幕逻辑尺寸/缩放比</li>
        </ul>

        <p><b>2. 屏幕与交互</b></p>
        <ul>
            <li><code>/screenshot</code> - 获取屏幕截图 (PNG base64)</li>
            <li><code>/wda/tap/0</code> - 点击指定坐标 (x, y)</li>
            <li><code>/wda/doubleTap</code> - 双击指定坐标</li>
            <li><code>/wda/touchAndHold</code> - 长按 (duration)</li>
            <li><code>/wda/dragfromtoforduration</code> - 滑动/拖拽</li>
            <li><code>/wda/touch/perform</code> - 执行复杂多指手势链</li>
            <li><code>/wda/keys</code> - 模拟键盘输入文本</li>
            <li><code>/wda/keyboard/dismiss</code> - 隐藏软键盘</li>
        </ul>

        <p><b>3. 应用管理</b></p>
        <ul>
            <li><code>/wda/apps/launch</code> - 启动应用 (bundleId)</li>
            <li><code>/wda/apps/terminate</code> - 关闭应用</li>
            <li><code>/wda/apps/state</code> - 查询应用运行状态 (前台/后台/未运行)</li>
            <li><code>/wda/activeAppInfo</code> - 获取当前前台应用的信息</li>
            <li><code>/wda/deactivateApp</code> - 将当前应用切换到后台 (duration)</li>
        </ul>
        
        <p><b>4. 元素与 UI 树</b></p>
        <ul>
            <li><code>/source</code> - 获取当前页面的 UI 树 (XML/JSON)</li>
            <li><code>/elements</code> - 查找元素 (By ID, Class, XPath等)</li>
            <li><code>/element/{uuid}/click</code> - 点击指定元素</li>
            <li><code>/element/{uuid}/text</code> - 获取元素文本</li>
            <li><code>/element/{uuid}/value</code> - 输入内容到元素</li>
            <li><code>/wda/accessibleSource</code> - 获取无障碍节点信息</li>
        </ul>

        <p><b>5. 系统能力</b></p>
        <ul>
            <li><code>/wda/batteryInfo</code> - 获取电池电量与状态</li>
            <li><code>/wda/volume</code> - 获取/设置音量 (0.0 - 1.0)</li>
            <li><code>/orientation</code> - 获取/设置屏幕方向 (PORTRAIT/LANDSCAPE)</li>
            <li><code>/wda/clipboard</code> - 剪贴板操作 (Get/Set)</li>
            <li><code>/wda/alert/accept</code> - 接受系统弹窗</li>
            <li><code>/wda/alert/dismiss</code> - 关闭系统弹窗</li>
        </ul>

        <p><b>6. 文件系统</b></p>
        <ul>
            <li><code>/wda/files</code> - 列出沙盒文件 (GET)</li>
            <li><code>/wda/files</code> - 上传文件 (POST) / 下载文件 (GET?path=...)</li>
        </ul>
        """)
        ecwda_layout.addWidget(ecwda_info)
        self.tabs.addTab(ecwda_tab, "📚 ECWDA接口")
        
        # === API 测试标签页 (增强版) ===
        api_tab = QWidget()
        api_main_layout = QVBoxLayout(api_tab)
        
        # 使用滚动区域
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll_content = QWidget()
        api_layout = QVBoxLayout(scroll_content)
        
        # ========== 1. 设备函数 ==========
        device_group = QGroupBox("📱 设备函数")
        device_layout = QVBoxLayout(device_group)
        
        row1 = QHBoxLayout()
        btn = QPushButton("设备信息")
        btn.clicked.connect(self._test_device_info)
        row1.addWidget(btn)
        
        btn = QPushButton("屏幕尺寸")
        btn.clicked.connect(self._test_screen_size)
        row1.addWidget(btn)
        
        btn = QPushButton("电池信息")
        btn.clicked.connect(self._test_battery)
        row1.addWidget(btn)
        
        btn = QPushButton("当前应用")
        btn.clicked.connect(self._test_app_info)
        row1.addWidget(btn)
        
        btn = QPushButton("屏幕锁定状态")
        btn.clicked.connect(self._test_lock_status)
        row1.addWidget(btn)
        
        device_layout.addLayout(row1)
        api_layout.addWidget(device_group)
        
        # ========== 2. 点击/操作函数 ==========
        action_group = QGroupBox("👆 点击/操作函数")
        action_layout = QVBoxLayout(action_group)
        
        # 坐标输入行
        coord_row = QHBoxLayout()
        coord_row.addWidget(QLabel("X:"))
        self.api_x_input = QSpinBox()
        self.api_x_input.setRange(0, 9999)
        self.api_x_input.setValue(100)
        coord_row.addWidget(self.api_x_input)
        
        coord_row.addWidget(QLabel("Y:"))
        self.api_y_input = QSpinBox()
        self.api_y_input.setRange(0, 9999)
        self.api_y_input.setValue(100)
        coord_row.addWidget(self.api_y_input)
        
        pick_btn = QPushButton("🎯 从屏幕取点")
        pick_btn.setToolTip("点击后在屏幕上点击获取坐标")
        pick_btn.clicked.connect(self._pick_coordinate)
        coord_row.addWidget(pick_btn)
        coord_row.addStretch()
        action_layout.addLayout(coord_row)
        
        # 操作按钮行
        action_btn_row = QHBoxLayout()
        btn = QPushButton("点击")
        btn.clicked.connect(self._test_click)
        action_btn_row.addWidget(btn)
        
        btn = QPushButton("双击")
        btn.clicked.connect(self._test_double_click)
        action_btn_row.addWidget(btn)
        
        btn = QPushButton("长按")
        btn.clicked.connect(self._test_long_click)
        action_btn_row.addWidget(btn)
        
        btn = QPushButton("输入文本")
        btn.clicked.connect(self._test_input_text)
        action_btn_row.addWidget(btn)
        
        action_layout.addLayout(action_btn_row)
        api_layout.addWidget(action_group)
        
        # ========== 2.5 随机区域操作 ==========
        random_group = QGroupBox("🎲 随机区域操作 (模拟人手)")
        random_layout = QVBoxLayout(random_group)
        
        # 区域输入行
        region_row1 = QHBoxLayout()
        region_row1.addWidget(QLabel("左上角:"))
        region_row1.addWidget(QLabel("X1:"))
        self.region_x1 = QSpinBox()
        self.region_x1.setRange(0, 9999)
        self.region_x1.setValue(150)
        region_row1.addWidget(self.region_x1)
        region_row1.addWidget(QLabel("Y1:"))
        self.region_y1 = QSpinBox()
        self.region_y1.setRange(0, 9999)
        self.region_y1.setValue(250)
        region_row1.addWidget(self.region_y1)
        region_row1.addStretch()
        random_layout.addLayout(region_row1)
        
        region_row2 = QHBoxLayout()
        region_row2.addWidget(QLabel("右下角:"))
        region_row2.addWidget(QLabel("X2:"))
        self.region_x2 = QSpinBox()
        self.region_x2.setRange(0, 9999)
        self.region_x2.setValue(180)
        region_row2.addWidget(self.region_x2)
        region_row2.addWidget(QLabel("Y2:"))
        self.region_y2 = QSpinBox()
        self.region_y2.setRange(0, 9999)
        self.region_y2.setValue(500)
        region_row2.addWidget(self.region_y2)
        
        self.select_region_btn = QPushButton("🖼️ 框选区域")
        self.select_region_btn.setCheckable(True)
        self.select_region_btn.clicked.connect(self._toggle_region_selection_mode)
        region_row2.addWidget(self.select_region_btn)
        region_row2.addStretch()
        random_layout.addLayout(region_row2)
        
        # 滑动方向选择行
        swipe_row = QHBoxLayout()
        swipe_row.addWidget(QLabel("滑动方向:"))
        self.swipe_direction = QComboBox()
        self.swipe_direction.addItems(["↑ 向上", "↓ 向下", "← 向左", "→ 向右"])
        self.swipe_direction.setMaximumWidth(100)
        swipe_row.addWidget(self.swipe_direction)
        swipe_row.addStretch()
        random_layout.addLayout(swipe_row)
        
        # 随机操作按钮行
        random_btn_row = QHBoxLayout()
        btn = QPushButton("🎲 随机点击")
        btn.clicked.connect(self._test_random_tap)
        random_btn_row.addWidget(btn)
        
        btn = QPushButton("🎲 随机双击")
        btn.clicked.connect(self._test_random_double_tap)
        random_btn_row.addWidget(btn)
        
        btn = QPushButton("🎲 随机长按")
        btn.clicked.connect(self._test_random_long_press)
        random_btn_row.addWidget(btn)
        
        btn = QPushButton("🎲 随机滑动")
        btn.clicked.connect(self._test_random_swipe)
        random_btn_row.addWidget(btn)
        
        random_layout.addLayout(random_btn_row)
        api_layout.addWidget(random_group)
        
        # ========== 3. 图色函数 ==========
        image_group = QGroupBox("🎨 图色函数")
        image_layout = QVBoxLayout(image_group)
        
        # 颜色输入行
        color_row = QHBoxLayout()
        color_row.addWidget(QLabel("颜色:"))
        self.api_color_input = QLineEdit()
        self.api_color_input.setPlaceholderText("#FFFFFF")
        self.api_color_input.setText("#FFFFFF")
        self.api_color_input.setMaximumWidth(100)
        self.api_color_input.textChanged.connect(self._update_color_preview)
        self._update_color_preview("#FFFFFF")
        color_row.addWidget(self.api_color_input)
        
        color_row.addWidget(QLabel("容差:"))
        self.api_tolerance_input = QSpinBox()
        self.api_tolerance_input.setRange(0, 255)
        self.api_tolerance_input.setValue(10)
        color_row.addWidget(self.api_tolerance_input)
        
        pick_color_btn = QPushButton("🎨 从屏幕取色")
        pick_color_btn.clicked.connect(self._pick_color)
        color_row.addWidget(pick_color_btn)
        color_row.addStretch()
        image_layout.addLayout(color_row)
        
        # 多点找色偏移颜色输入
        offset_row = QHBoxLayout()
        offset_row.addWidget(QLabel("偏移:"))
        self.api_offset_input = QLineEdit()
        self.api_offset_input.setPlaceholderText("dx,dy,#颜色  例: 10,0,#FF0000|20,5,#00FF00")
        self.api_offset_input.setToolTip("多点找色的偏移颜色列表，格式: dx,dy,#RRGGBB 用 | 分隔多个")
        self.api_offset_input.textChanged.connect(self._on_offset_input_changed)
        offset_row.addWidget(self.api_offset_input)
        
        self.add_offset_btn = QPushButton("+ 追加右键取色")
        self.add_offset_btn.setToolTip("右键取色后点此按钮，自动追加为偏移点（相对于上次取色坐标）")
        self.add_offset_btn.clicked.connect(self._add_offset_color)
        offset_row.addWidget(self.add_offset_btn)
        image_layout.addLayout(offset_row)
        
        # 图色按钮行
        image_btn_row = QHBoxLayout()
        btn = QPushButton("截图")
        btn.clicked.connect(self._test_screenshot)
        image_btn_row.addWidget(btn)
        
        btn = QPushButton("取该点颜色")
        btn.clicked.connect(self._test_get_pixel)
        image_btn_row.addWidget(btn)
        
        btn = QPushButton("单点找色")
        btn.clicked.connect(self._test_find_color)
        image_btn_row.addWidget(btn)
        
        btn = QPushButton("多点找色")
        btn.setToolTip("使用上面的颜色和偏移列表进行多点特征匹配")
        btn.clicked.connect(self._test_find_multi_color)
        image_btn_row.addWidget(btn)
        
        btn = QPushButton("比色")
        btn.clicked.connect(self._test_cmp_color)
        image_btn_row.addWidget(btn)
        
        image_layout.addLayout(image_btn_row)
        
        # 找图按钮行
        image_btn_row2 = QHBoxLayout()
        btn = QPushButton("🖼 找图 (选区模板)")
        btn.setToolTip("先用截图选区功能截取按钮图片，然后点此按钮在屏幕上查找")
        btn.clicked.connect(self._test_find_image_from_selection)
        image_btn_row2.addWidget(btn)
        
        btn = QPushButton("🎯 找色并点击")
        btn.setToolTip("找到指定颜色后自动点击该位置")
        btn.clicked.connect(self._test_find_color_and_tap)
        image_btn_row2.addWidget(btn)
        
        image_btn_row2.addStretch()
        image_layout.addLayout(image_btn_row2)
        
        api_layout.addWidget(image_group)
        
        # ========== 4. 找图功能 ==========
        find_img_group = QGroupBox("🔍 找图功能 (ECWDA)")
        find_img_layout = QVBoxLayout(find_img_group)
        
        # 模板操作行
        template_row = QHBoxLayout()
        self.select_template_btn = QPushButton("🖼️ 框选模板")
        self.select_template_btn.setToolTip("在屏幕预览上框选一个区域作为查找模板")
        self.select_template_btn.setCheckable(True)
        self.select_template_btn.clicked.connect(self._toggle_selection_mode)
        template_row.addWidget(self.select_template_btn)
        
        self.template_label = QLabel("未选择模板")
        self.template_label.setStyleSheet("color: #888;")
        template_row.addWidget(self.template_label)
        
        btn = QPushButton("🔍 执行找图")
        btn.clicked.connect(self._test_find_image_ecwda)
        template_row.addWidget(btn)
        
        btn = QPushButton("📍 找图并点击")
        btn.clicked.connect(self._test_find_image_and_click)
        template_row.addWidget(btn)
        
        template_row.addStretch()
        find_img_layout.addLayout(template_row)
        
        # 阈值设置行
        threshold_row = QHBoxLayout()
        threshold_row.addWidget(QLabel("匹配阈值:"))
        self.find_img_threshold = QSpinBox()
        self.find_img_threshold.setRange(50, 100)
        self.find_img_threshold.setValue(80)
        self.find_img_threshold.setSuffix("%")
        threshold_row.addWidget(self.find_img_threshold)
        threshold_row.addStretch()
        find_img_layout.addLayout(threshold_row)
        
        api_layout.addWidget(find_img_group)
        
        # ========== 5. OCR 识别 ==========
        ocr_group = QGroupBox("📖 OCR识别 (需要WDA支持)")
        ocr_layout = QVBoxLayout(ocr_group)
        
        ocr_input_row = QHBoxLayout()
        ocr_input_row.addWidget(QLabel("查找文字:"))
        self.api_text_input = QLineEdit()
        self.api_text_input.setPlaceholderText("要查找的文字")
        self.api_text_input.setText("设置")
        ocr_input_row.addWidget(self.api_text_input)
        ocr_layout.addLayout(ocr_input_row)
        
        ocr_btn_row = QHBoxLayout()
        btn = QPushButton("OCR全屏识别")
        btn.clicked.connect(self._test_ocr)
        ocr_btn_row.addWidget(btn)
        
        btn = QPushButton("查找文字位置")
        btn.clicked.connect(self._test_find_text)
        ocr_btn_row.addWidget(btn)
        
        btn = QPushButton("扫描二维码")
        btn.clicked.connect(self._test_qrcode)
        ocr_btn_row.addWidget(btn)
        
        ocr_layout.addLayout(ocr_btn_row)
        api_layout.addWidget(ocr_group)
        
        # ========== 6. 应用操作 ==========
        app_group = QGroupBox("📲 应用操作")
        app_layout = QVBoxLayout(app_group)
        
        app_input_row = QHBoxLayout()
        app_input_row.addWidget(QLabel("Bundle ID:"))
        self.api_bundle_input = QLineEdit()
        self.api_bundle_input.setPlaceholderText("com.apple.Preferences")
        self.api_bundle_input.setText("com.apple.Preferences")
        app_input_row.addWidget(self.api_bundle_input)
        app_layout.addLayout(app_input_row)
        
        app_btn_row = QHBoxLayout()
        btn = QPushButton("启动应用")
        btn.clicked.connect(self._test_launch_app)
        app_btn_row.addWidget(btn)
        
        btn = QPushButton("关闭应用")
        btn.clicked.connect(self._test_terminate_app)
        app_btn_row.addWidget(btn)
        
        btn = QPushButton("返回桌面")
        btn.clicked.connect(self._press_home)
        app_btn_row.addWidget(btn)
        
        app_layout.addLayout(app_btn_row)
        api_layout.addWidget(app_group)
        
        # ========== 7. 工具函数 ==========
        utils_group = QGroupBox("🔧 工具函数")
        utils_layout = QHBoxLayout(utils_group)
        
        btn = QPushButton("剪贴板")
        btn.clicked.connect(self._test_clipboard)
        utils_layout.addWidget(btn)
        
        btn = QPushButton("震动")
        btn.clicked.connect(self._test_vibrate)
        utils_layout.addWidget(btn)
        
        btn = QPushButton("随机数")
        btn.clicked.connect(self._test_random)
        utils_layout.addWidget(btn)
        
        btn = QPushButton("MD5")
        btn.clicked.connect(self._test_md5)
        utils_layout.addWidget(btn)
        
        api_layout.addWidget(utils_group)
        
        # ========== 8. ECWDA 脚本引擎 ==========
        script_group = QGroupBox("📜 脚本引擎 (ECWDA)")
        script_layout = QVBoxLayout(script_group)
        
        # 脚本输入
        script_input_row = QHBoxLayout()
        script_input_row.addWidget(QLabel("脚本:"))
        self.api_script_input = QLineEdit()
        self.api_script_input.setPlaceholderText('wda.tap(100, 200); wda.sleep(1);')
        self.api_script_input.setText('wda.log("Hello ECWDA!");')
        script_input_row.addWidget(self.api_script_input)
        script_layout.addLayout(script_input_row)
        
        # 脚本按钮行
        script_btn_row = QHBoxLayout()
        btn = QPushButton("执行脚本")
        btn.clicked.connect(self._test_script_run)
        script_btn_row.addWidget(btn)
        
        btn = QPushButton("脚本状态")
        btn.clicked.connect(self._test_script_status)
        script_btn_row.addWidget(btn)
        
        btn = QPushButton("停止脚本")
        btn.clicked.connect(self._test_script_stop)
        script_btn_row.addWidget(btn)
        
        script_layout.addLayout(script_btn_row)
        api_layout.addWidget(script_group)
        
        # ========== 9. 节点操作 (ECWDA) ==========
        node_group = QGroupBox("🌳 节点操作 (ECWDA)")
        node_layout = QVBoxLayout(node_group)
        
        # 节点查找输入
        node_input_row = QHBoxLayout()
        node_input_row.addWidget(QLabel("文本/类型:"))
        self.api_node_input = QLineEdit()
        self.api_node_input.setPlaceholderText("Button 或 要查找的文本")
        self.api_node_input.setText("Button")
        self.api_node_input.setMaximumWidth(150)
        node_input_row.addWidget(self.api_node_input)
        node_input_row.addStretch()
        node_layout.addLayout(node_input_row)
        
        # 节点按钮行
        node_btn_row = QHBoxLayout()
        btn = QPushButton("按类型查找")
        btn.clicked.connect(self._test_node_find_by_type)
        node_btn_row.addWidget(btn)
        
        btn = QPushButton("按文本查找")
        btn.clicked.connect(self._test_node_find_by_text)
        node_btn_row.addWidget(btn)
        
        btn = QPushButton("获取所有节点")
        btn.clicked.connect(self._test_node_get_all)
        node_btn_row.addWidget(btn)
        
        node_layout.addLayout(node_btn_row)
        api_layout.addWidget(node_group)
        

        # ========== 10. ECWDA 扩展 ==========
        ecwda_group = QGroupBox("⚡ ECWDA扩展")
        ecwda_layout = QVBoxLayout(ecwda_group)
        
        # URL/文本输入
        ecwda_input_row = QHBoxLayout()
        ecwda_input_row.addWidget(QLabel("URL/文本:"))
        self.api_ecwda_input = QLineEdit()
        self.api_ecwda_input.setPlaceholderText("https://example.com 或 要编码的文本")
        self.api_ecwda_input.setText("Hello ECWDA!")
        ecwda_input_row.addWidget(self.api_ecwda_input)
        ecwda_layout.addLayout(ecwda_input_row)
        
        # ECWDA 按钮行1
        ecwda_btn_row1 = QHBoxLayout()
        btn = QPushButton("ECWDA信息")
        btn.clicked.connect(self._test_ecwda_info)
        ecwda_btn_row1.addWidget(btn)
        
        btn = QPushButton("打开URL")
        btn.clicked.connect(self._test_open_url)
        ecwda_btn_row1.addWidget(btn)
        
        btn = QPushButton("Base64编码")
        btn.clicked.connect(self._test_base64_encode)
        ecwda_btn_row1.addWidget(btn)
        
        btn = QPushButton("Base64解码")
        btn.clicked.connect(self._test_base64_decode)
        ecwda_btn_row1.addWidget(btn)
        
        ecwda_layout.addLayout(ecwda_btn_row1)
        
        # ECWDA 按钮行2
        ecwda_btn_row2 = QHBoxLayout()
        btn = QPushButton("二维码识别")
        btn.clicked.connect(self._test_qrcode_scan)
        ecwda_btn_row2.addWidget(btn)
        

        btn = QPushButton("点击文字")
        btn.clicked.connect(self._test_click_text)
        ecwda_btn_row2.addWidget(btn)
        
        ecwda_layout.addLayout(ecwda_btn_row2)
        api_layout.addWidget(ecwda_group)
        
        # 添加弹性空间
        api_layout.addStretch()
        
        scroll_content.setLayout(api_layout)
        scroll.setWidget(scroll_content)
        api_main_layout.addWidget(scroll)
        
        # 结果显示区域
        result_group = QGroupBox("📋 测试结果")
        result_layout = QVBoxLayout(result_group)
        self.api_result_text = QTextEdit()
        self.api_result_text.setReadOnly(True)
        self.api_result_text.setPlaceholderText("点击上方按钮测试 API，结果将显示在这里...")
        self.api_result_text.setStyleSheet("font-family: monospace; font-size: 11px;")
        self.api_result_text.setMaximumHeight(200)
        result_layout.addWidget(self.api_result_text)
        result_group.setLayout(result_layout)
        api_main_layout.addWidget(result_group)
        
        self.tabs.addTab(api_tab, "🧪 API测试")
        
        # ECMAIN 功能测试标签页
        self.ecmain_test = ECMainTestWidget()
        self.tabs.addTab(self.ecmain_test, "📱 ECMAIN测试")
        
        # UI 元素审查标签页
        self.ui_inspector = UIInspectorWidget()
        self.ui_inspector.tap_request.connect(self._do_click)
        self.tabs.addTab(self.ui_inspector, "🔍 UI审查")
        
        right_panel.addWidget(self.tabs)
        
        # 右侧面板容器
        right_widget = QWidget()
        right_widget.setLayout(right_panel)
        
        # 主分割器 - 可拖拽调整左右面板宽度
        self.main_splitter = QSplitter(Qt.Horizontal)
        self.main_splitter.setHandleWidth(6)
        self.main_splitter.setStyleSheet("""
            QSplitter::handle {
                background-color: #555;
            }
            QSplitter::handle:hover {
                background-color: #4CAF50;
            }
        """)
        self.main_splitter.addWidget(left_widget)
        self.main_splitter.addWidget(right_widget)
        self.main_splitter.setSizes([400, 600])  # 初始比例
        self.main_splitter.setChildrenCollapsible(False)
        
        main_layout.addWidget(self.main_splitter)
    
    def _setup_timers(self):
        # 触摸事件轮询定时器
        self.touch_poll_timer = QTimer()
        self.touch_poll_timer.timeout.connect(self._poll_touch_events)
        
        # 屏幕刷新定时器 (30-60 FPS)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.update_screen)
        self.timer.start(30) # ~33ms
        
        # USB 检测定时器 (3s)
        self.usb_timer = QTimer(self)
        self.usb_timer.timeout.connect(self._check_usb_status)
        self.usb_timer.start(3000)
        # 日志刷新定时器
        self.log_refresh_timer = QTimer()
        self.log_refresh_timer.timeout.connect(self._refresh_log_display)
        self.log_refresh_timer.start(500)
        
    def update_screen(self):
        """Timer callback for screen animations"""
        self.screen_canvas.step_animations()

    
    def _add_log(self, op_type: str, details: str, source: str = "control"):
        log = OperationLog(op_type, details, source)
        self.operation_logs.append(log)
        if len(self.operation_logs) > self.max_logs:
            self.operation_logs = self.operation_logs[-self.max_logs:]
    
    def _refresh_log_display(self):
        if self.tabs.currentIndex() == 1:  # 日志标签页
            text = "\n".join(log.to_string() for log in self.operation_logs[-100:])
            self.log_text.setPlainText(text)
            self.log_text.verticalScrollBar().setValue(
                self.log_text.verticalScrollBar().maximum()
            )
    


    def _check_usb_status(self):
        """定期检查USB连接状态，检测断线时自动触发断开"""
        device = check_usb_device()
        usb_online = device is not None
        
        if device:
            udid = device.get('udid', 'Unknown')
            short_udid = udid[:8] + "..." if len(udid) > 8 else udid
            self.usb_info_label.setText(f"✅ 已连接 USB (UDID: {short_udid})")
            self.usb_info_label.setStyleSheet("color: #4CAF50; font-weight: bold;")
        else:
            self.usb_info_label.setText("❌ 未检测到 USB 设备")
            self.usb_info_label.setStyleSheet("color: #F44336;")
        
        # 检测 USB 从 "有设备" → "无设备" 的状态变化
        if self._prev_usb_online is True and not usb_online:
            print("[USB] ⚠️ 检测到 USB 设备断开!")
            self._add_log("USB", "⚠️ USB 设备断开!")
            if self.is_connected and self.using_usb:
                self._add_log("USB", "自动断开 WDA 连接 (USB 设备已拔出)")
                self._on_connection_lost()
        
        self._prev_usb_online = usb_online

    def launch_ecwda(self):
        """通过 tidevice xctest 启动手机上的 ECWDA"""
        try:
            # 检查设备连接
            device = check_usb_device()
            if not device:
                QMessageBox.warning(self, "错误", "未检测到 USB 设备，请先连接 iPhone！")
                return
            
            udid = device["udid"]
            # ECWDA 的 XCTest Bundle ID (固定值，和 Xcode 工程一致)
            bundle_id = "com.facebook.WebDriverAgentRunner.ecwda"
            
            # 切换到日志标签，方便查看进度
            # 日志 tab 是 index=1
            self.tabs.setCurrentIndex(1)
            self.log_text.clear()
            self.log_text.append(f"🚀 正在启动 ECWDA...")
            self.log_text.append(f"   设备 UDID: {udid}")
            self.log_text.append(f"   Bundle ID: {bundle_id}")
            self.log_text.append(f"   命令: tidevice -u {udid} launch {bundle_id}")
            self.log_text.append("⏳ 请等待...")
            self.log_text.append("")
            
            # 停止已有的 WDA 进程
            if self.wda_process and self.wda_process.state() != QProcess.NotRunning:
                self.log_text.append("⏹️ 先停止旧的 ECWDA 进程...")
                self.wda_process.terminate()
                self.wda_process.waitForFinished(2000)
            
            # 用 QProcess 异步运行 tidevice launch，不阻塞 UI
            self.wda_process = QProcess()
            self.wda_process.setProgram(TIDEVICE_PATH)
            # launch <bundle_id>：直接唤醒 TrollStore 部署的独立 App
            self.wda_process.setArguments(["-u", udid, "launch", bundle_id])
            
            self.wda_process.readyReadStandardOutput.connect(self._on_wda_output)
            self.wda_process.readyReadStandardError.connect(self._on_wda_error)
            self.wda_process.finished.connect(self._on_wda_process_finished)
            self.wda_process.start()
            
            # 非阻塞：等 100ms 确认进程确实启动了
            if not self.wda_process.waitForStarted(3000):
                self.log_text.append("❌ tidevice 启动失败！请确认 tidevice 已安装且 TIDEVICE_PATH 正确。")
                self.log_text.append(f"   当前 TIDEVICE_PATH: {TIDEVICE_PATH}")
                return
            
            self.log_text.append("✅ tidevice 进程已启动，正在等待 ECWDA 输出...")
            
        except Exception as e:
            import traceback
            QMessageBox.critical(self, "启动失败", f"启动 ECWDA 时发生异常:\n{e}\n\n{traceback.format_exc()}")


    def _on_wda_output(self):
        data = self.wda_process.readAllStandardOutput()
        text = bytes(data).decode("utf-8", errors="ignore")
        self.log_text.append(text)
        # Check for success message
        if "WebDriverAgent start successfully" in text:
             self.log_text.append("\n✅ WDA 启动成功! 现在可以点击连接了。")

    def _on_wda_error(self):
        data = self.wda_process.readAllStandardError()
        text = bytes(data).decode("utf-8", errors="ignore")
        self.log_text.append(f"<span style='color:#FF6B6B'>{text}</span>")

    def _on_wda_process_finished(self, exit_code: int, exit_status):
        """tidevice xctest 进程退出回调"""
        if exit_code == 0:
            self.log_text.append("⏹️ ECWDA 已正常退出")
        else:
            self.log_text.append(f"❌ ECWDA 进程退出，退出码: {exit_code}")
            self.log_text.append("💡 常见原因: Bundle ID 不正确 / 设备未信任 / WDA 未安装到设备")


    def _toggle_connection(self):
        if self.is_connected:
            self._disconnect()
        else:
            self._connect()
    
    def _connect(self):
        raw_url = self.ip_input.text().strip() if hasattr(self, 'ip_input') else self.url_input.text().strip()
        
        # 2. 检查连接模式 (尊重用户的 USB 勾选状态)
        if self.usb_check.isChecked():
            # USB 模式
            if not self.usb_relay.start():
                QMessageBox.warning(self, "错误", "USB 转发启动失败，将退回备用线路...")
                # 回退策略：如果转发启动失败，取消勾选并尝试 Wifi
                self.usb_check.setChecked(False)
                self.connect_btn.setEnabled(True)
                return
            
            # 使用本地转发端口
            self.control_url = f"http://127.0.0.1:{WDA_PORT}"
            self.stream_url = f"http://127.0.0.1:10089"
            self.using_usb = True
            conn_type = "USB"
            self._add_log("连接", f"启动 USB 转发: {WDA_PORT} -> Device")
            
        else:
            # WiFi 模式
            # 如果用户输入了 localhost，自动处理
            if not raw_url:
                QMessageBox.warning(self, "错误", "请输入设备 IP 地址")
                self.connect_btn.setEnabled(True)
                return
                
            target_host = raw_url
            if "://" in raw_url:
                target_host = raw_url.split("://")[1]
            if ":" in target_host:
                target_host = target_host.split(":")[0]
                
            self.control_url = f"http://{target_host}:{WDA_PORT}"
            self.stream_url = f"http://{target_host}:10089"
            
            self.using_usb = False
            conn_type = "WiFi"
            self._add_log("连接", f"连接到: {target_host} (Browser Kernel)")
            
        
        # 4. 建立 WDA Session (Control URL)
        
        
        # 4. 建立 WDA Session (Control URL)
        self.status_label.setText("正在建立 Session...")
        self.connect_btn.setEnabled(False)
        QApplication.processEvents()
        
        try:
            # 尝试连接 Create Session
            resp = self.session.post(f"{self.control_url}/session",
                               json={"capabilities": {}}, timeout=5)
            
            if resp.status_code == 200:
                data = resp.json()
                self.session_id = data.get("sessionId") or data.get("value", {}).get("sessionId")
                self._add_log("连接", f"Session ID: {self.session_id}")
            else:
                 raise Exception(f"HTTP {resp.status_code}")
            
            if not self.session_id:
                raise Exception("无法获取 session ID")
            
            # 4.1 获取屏幕尺寸
            try:
                size_resp = self.session.get(f"{self.control_url}/session/{self.session_id}/window/size", timeout=5)
                if size_resp.status_code == 200:
                    size_val = size_resp.json().get("value", {})
                    self.wda_width = size_val.get("width", 375)
                    self.wda_height = size_val.get("height", 667)
                    self._add_log("连接", f"屏幕尺寸: {self.wda_width}x{self.wda_height}")
            except Exception as e:
                print(f"[Connect] Get size error: {e}")
                self.wda_width = 375
                self.wda_height = 667

        except Exception as e:
            self.status_label.setText(f"连接失败")
            self._add_log("连接", f"连接失败: {e}")
            QMessageBox.warning(self, "连接失败", f"无法连接到 WDA:\n{e}\n\n请确认 WDA 已启动且端口正确({WDA_PORT})")
            
            self.status_label.setStyleSheet("color: #f44336;")
            self.connect_btn.setEnabled(True)
            return
        
        # 兼容旧代码
        self.wda_url = self.control_url
        
        # 启动 MJPEG 视频流 (WebEngine)
        # 停止 WebEngine
        self.web_view.stop()
        self.web_view.setUrl(QUrl("about:blank"))
        
        if hasattr(self, 'stream_thread') and self.stream_thread:
            self.stream_thread.stop()
            self.stream_thread.wait()
            
        # 使用 10089 端口 (WDA MJPEG)
        mjpeg_url = self.stream_url 
        if "?" not in mjpeg_url:
            mjpeg_url += "?compressionQuality=60&scaleFactor=50"
        
        # 使用自定义 HTML 加载视频流，强制去除边距并居中显示
        # 这样可以保证与 ScreenCanvas 的坐标计算逻辑 (保持比例居中) 完美匹配
        html = f"""
        <html>
        <body style="margin:0; padding:0; background-color:black; 
                     display:flex; justify-content:center; align-items:center; 
                     height:100vh; overflow:hidden;">
            <img src="{mjpeg_url}" style="max-width:100%; max-height:100%; object-fit:contain;">
        </body>
        </html>
        """
        self.web_view.setHtml(html)
        self._add_log("视频流", f"WebEngine 加载: {mjpeg_url}")
        
        # 设置 Canvas 的设备尺寸 (默认，会在连接后根据 device info 更新)
        if self.wda_width > 0:
            self.screen_canvas.set_dev_size(self.wda_width, self.wda_height)
        
        # 启动延迟监测
        if hasattr(self, 'latency_thread') and self.latency_thread:
            self.latency_thread.stop()
            self.latency_thread.wait()
            
        self.latency_thread = LatencyThread(f"{self.control_url}/status")
        self.latency_thread.latency_signal.connect(self._on_latency_update)
        self.latency_thread.connection_lost.connect(self._on_connection_lost)
        self.latency_thread.start()
        
        self.is_connected = True
        self.status_label.setText(f"已连接 ({conn_type}) (Browser Kernel)")
        self.status_label.setStyleSheet("color: #4CAF50;")
        self.connect_btn.setText("⏏ 断开")
        self.connect_btn.setEnabled(True)
        
        # 注入连接信息到 UI 审查面板
        device_ip = self.ip_input.text().strip() if hasattr(self, 'ip_input') else ""
        self.ui_inspector.set_connection(
            self.session, self.control_url, self.screen_scale,
            self.screen_canvas, device_ip, self.latency_thread
        )
        
        # 获取屏幕尺寸并计算缩放因子

        
        # 获取屏幕尺寸并计算缩放因子
        # 获取屏幕尺寸并计算缩放因子
        try:
            resp = self.session.get(f"{self.control_url}/session/{self.session_id}/window/size", timeout=5)
            if resp.status_code == 200:
                data = resp.json().get("value", {})
                self.wda_width = data.get("width", 375)
                self.wda_height = data.get("height", 667)
                print(f"[INFO] WDA 窗口尺寸: {self.wda_width}x{self.wda_height}")
        except:
            pass
        
        self._add_log("连接", f"已连接到 {self.wda_url} ({conn_type})")
        
        # 自动获取屏幕尺寸
        threading.Thread(target=self._update_screen_size, daemon=True).start()

    def _update_screen_size(self):
        """获取设备实际屏幕尺寸 (Pixels vs Points)"""
        try:
            # 1. 获取 WDA 状态 (Points)
            resp = self.session.get(f"{self.wda_url}/status", timeout=5)
            if resp.status_code != 200:
                self._add_log("屏幕", f"获取状态失败: {resp.status_code}")
                return
            
            # 2. 获取截图 (Pixels)
            # 使用 /screenshot 端点获取一张图来确定真实分辨率
            import base64
            resp_img = self.session.get(f"{self.wda_url}/screenshot", timeout=10)
            if resp_img.status_code != 200:
                self._add_log("屏幕", "获取截图失败，无法确定分辨率")
                return
                
            data = resp_img.json().get("value")
            if not data:
                return
                
            img_data = base64.b64decode(data)
            from PIL import Image
            import io
            img = Image.open(io.BytesIO(img_data))
            real_w, real_h = img.size
            
            # 更新 canvas
            print(f"[SCREEN] Real Resolution: {real_w}x{real_h}")
            self._add_log("屏幕", f"检测到分辨率: {real_w}x{real_h}")
            
            # WDA 通常使用逻辑点，但如果用户需要像素坐标，我们直接设置 dev_size 为像素
            # 之前的逻辑是 points * 2.0，现在直接用 real_w/real_h，并在 _widget_to_device 里去掉 * 2.0
            # 还是保持 _dev_width 为 points? 
            # 用户反馈"被除以2了"，说明他想要 pixels。
            # 所以我们将 _dev_width 设置为 real_w (Pixels)
            
            self.screen_canvas.set_dev_size(real_w, real_h)
            
            # 由于 canvas 现在使用真实像素尺寸，我们需要更新缩放因子
            # Screen coordinates (Pixels) -> WDA coordinates (Points)
            if self.wda_width > 0:
                self.screen_scale = real_w / self.wda_width
            else:
                self.screen_scale = 1.0
                
            self._add_log("屏幕", f"缩放因子设置为: {self.screen_scale:.2f} (Pixels/Points)")
            
        except Exception as e:
            print(f"[SCREEN] Update size failed: {e}")
            self._add_log("屏幕", f"获取尺寸错误: {e}")
    
    def _on_connection_lost(self):
        """WDA 连续超时或 USB 设备消失时的自动断线处理"""
        if not self.is_connected:
            return
        
        print("[Connection] 🔴 连接丢失，自动断开...")
        self._add_log("连接", "🔴 检测到连接丢失，自动断开")
        
        # 先断开
        self._disconnect()
        
        # 更新 UI 提示
        self.status_label.setText("⚠️ 连接丢失 (自动断开)")
        self.status_label.setStyleSheet("color: #FF9800; font-weight: bold;")
    
    def _disconnect(self):
        if self.stream_thread:
            self.stream_thread.stop()
            self.stream_thread.wait(2000)
            self.stream_thread = None
        
        if self.is_touch_monitoring:
            self._toggle_touch_monitor()
        
        # 停止 USB 转发
        # 停止 USB 转发
        if self.using_usb:
            self.usb_relay.stop()
            self.using_usb = False
            self._add_log("断开", "停止 USB 转发")
            
        if hasattr(self, 'decode_timer') and self.decode_timer.isActive():
            self.decode_timer.stop()
        if hasattr(self, 'stats_timer') and self.stats_timer.isActive():
            self.stats_timer.stop()
        
        self.session_id = None
        self.is_connected = False
        self.status_label.setText("已断开")
        self.status_label.setStyleSheet("color: #888;")
        self.fps_label.setText("FPS: --")
        self.latency_label.setText("延迟: --")
        self.connect_btn.setText("🔗 连接")
        
        self._add_log("断开", "已断开连接")
    
    # _on_frame removed for WebEngine mode

    
    def _on_fps(self, fps: float):
        self.fps_label.setText(f"FPS: {fps:.1f}")
        
    def _on_latency_update(self, ms: int):
        if ms >= 0:
            color = "#4CAF50" if ms < 100 else "#FF9800" if ms < 300 else "#f44336"
            self.latency_label.setText(f"延迟: <span style='color:{color}'>{ms}ms</span>")
        else:
            self.latency_label.setText("延迟: <span style='color:red'>超时</span>")
    
    def _on_latency(self, ms: int):
        # 根据延迟设置颜色
        if ms < 200:
            color = "#4CAF50"  # 绿色 - 流畅
        elif ms < 400:
            color = "#FF9800"  # 橙色 - 一般
        else:
            color = "#f44336"  # 红色 - 慢
        self.latency_label.setText(f"延迟: {ms}ms")
        self.latency_label.setStyleSheet(f"color: {color}; font-weight: bold;")
    
    def _on_coord(self, x: int, y: int):
        # x, y 是像素坐标，转换为 WDA 点坐标
        wda_x = int(x / self.screen_scale)
        wda_y = int(y / self.screen_scale)
        self.coord_label.setText(f"坐标: ({wda_x}, {wda_y})")
    
    def _on_click(self, x: int, y: int):
        # 检查是否在取点/取色模式
        if self.pick_mode:
            self._on_screen_click_for_api(x, y)
            return
        
        if not self.session_id:
            return
        
        # 转换为 WDA 点坐标
        wda_x = int(x / self.screen_scale)
        wda_y = int(y / self.screen_scale)
        
        self._add_log("点击", f"({x},{y}) -> WDA({wda_x},{wda_y})")
        
        if self.is_recording:
            self.script_edit.append(f"wda.tap({wda_x}, {wda_y});")
            self._add_log("录制", f"记录点击: ({wda_x}, {wda_y})")
        
        threading.Thread(target=self._do_click, args=(wda_x, wda_y), daemon=True).start()
    
    def _do_click(self, x: int, y: int):
        try:
            # 使用 ECWDA 的 withoutSession 路由，避免触发 activeApplication 的 UI 树遍历
            self.session.post(
                f"{self.control_url}/wda/tap",
                json={"x": x, "y": y},
                timeout=2
            )
        except Exception as e:
            print(f"[Tap Error] {e}")
    
    def _on_drag(self, from_x: int, from_y: int, to_x: int, to_y: int):
        if not self.session_id:
            return
        
        # 转换为 WDA 点坐标
        wda_from_x = int(from_x / self.screen_scale)
        wda_from_y = int(from_y / self.screen_scale)
        wda_to_x = int(to_x / self.screen_scale)
        wda_to_y = int(to_y / self.screen_scale)
        
        self._add_log("滑动", f"({wda_from_x},{wda_from_y}) -> ({wda_to_x},{wda_to_y})")
        
        if self.is_recording:
            self.script_edit.append(f"wda.swipe({wda_from_x}, {wda_from_y}, {wda_to_x}, {wda_to_y});")
            self._add_log("录制", f"记录滑动: ({wda_from_x},{wda_from_y}) -> ({wda_to_x},{wda_to_y})")
        
        threading.Thread(target=self._do_drag,
                        args=(wda_from_x, wda_from_y, wda_to_x, wda_to_y), daemon=True).start()
    
    def _do_drag(self, from_x: int, from_y: int, to_x: int, to_y: int):
        try:
            # 使用 ECWDA 的 withoutSession 路由，避免触发 activeApplication 的 UI 树遍历
            self.session.post(
                f"{self.control_url}/wda/swipe",
                json={
                    "fromX": from_x,
                    "fromY": from_y,
                    "toX": to_x,
                    "toY": to_y,
                    "duration": 0.1
                },
                timeout=5
            )
        except Exception as e:
            print(f"[Drag Error] {e}")
    
    def _on_right_click(self, x: int, y: int):
        """右键点击：即时取色（从当前显示画面获取）"""
        # x, y 是 ScreenCanvas 返回的设备像素坐标
        wda_x = int(x / self.screen_scale) if self.screen_scale > 0 else x
        wda_y = int(y / self.screen_scale) if self.screen_scale > 0 else y
        
        color = None
        
        # 方法1: 从 _current_frame 获取 (如果可用)
        frame = self.screen_canvas._current_frame
        if frame and 0 <= int(x) < frame.width() and 0 <= int(y) < frame.height():
            color = frame.pixelColor(int(x), int(y))
        
        # 方法2: 从 WebEngineView 截取当前画面
        if color is None and hasattr(self, 'web_view'):
            # 将设备像素坐标转回控件坐标
            widget_pos = self.screen_canvas._device_to_widget(x, y)
            if widget_pos:
                pixmap = self.web_view.grab()
                if not pixmap.isNull():
                    img = pixmap.toImage()
                    # Retina 显示器下 grab() 返回的图像是 devicePixelRatio 倍大小
                    dpr = pixmap.devicePixelRatio()
                    px = int(widget_pos[0] * dpr)
                    py = int(widget_pos[1] * dpr)
                    if 0 <= px < img.width() and 0 <= py < img.height():
                        color = img.pixelColor(px, py)
        
        if color is None:
            self._add_log("取色", f"无法获取颜色 (坐标: {x},{y})")
            return
        
        hex_color = f"#{color.red():02X}{color.green():02X}{color.blue():02X}"
        
        # 填入颜色输入框
        if hasattr(self, 'api_color_input'):
            self.api_color_input.setText(hex_color)
        
        # 存储取色坐标和颜色，用于多点找色偏移计算
        self._last_pick_wda = (wda_x, wda_y)
        self._last_pick_color = hex_color
        
        info = (f"🎨 颜色: {hex_color}  RGB({color.red()}, {color.green()}, {color.blue()})\n"
                f"   WDA坐标: ({wda_x}, {wda_y})")
        self._add_log("取色", info)
        self.ui_inspector._ui_update.emit("inspect", info)
    
    def _hit_test_element(self, node: dict, x: float, y: float) -> Optional[dict]:
        """递归 hit-test：找到包含 (x, y) 的最深层可见 UI 元素"""
        frame = node.get("rect") or node.get("frame", {})
        fx = frame.get("x", 0)
        fy = frame.get("y", 0)
        fw = frame.get("width", 0)
        fh = frame.get("height", 0)
        
        # 检查坐标是否在当前节点 frame 内
        if not (fx <= x <= fx + fw and fy <= y <= fy + fh):
            return None
        
        # 当前节点匹配，尝试在子节点中找更深的匹配
        best = node
        children = node.get("children", [])
        for child in children:
            if not child.get("isVisible", True):
                continue
            result = self._hit_test_element(child, x, y)
            if result:
                best = result  # 更深层的子元素优先
        
        return best
    
    def _format_element_info(self, element: dict) -> str:
        """格式化 UI 元素信息用于日志显示"""
        el_type = element.get("type", "Unknown").replace("XCUIElementType", "")
        label = element.get("label", "") or ""
        value = element.get("value", "") or ""
        identifier = element.get("rawIdentifier", "") or element.get("name", "") or ""
        enabled = element.get("isEnabled", True)
        visible = element.get("isVisible", True)
        
        frame = element.get("rect") or element.get("frame", {})
        fx = frame.get("x", 0)
        fy = frame.get("y", 0)
        fw = frame.get("width", 0)
        fh = frame.get("height", 0)
        
        lines = [f"✅ [{el_type}]"]
        if label:
            lines.append(f"  label: \"{label}\"")
        if value:
            lines.append(f"  value: \"{value}\"")
        if identifier:
            lines.append(f"  id: \"{identifier}\"")
        lines.append(f"  frame: ({fx}, {fy}, {fw}x{fh})")
        if not enabled:
            lines.append(f"  ⚠️ disabled")
        if not visible:
            lines.append(f"  ⚠️ invisible")
        
        return "\n".join(lines)
    
    def _toggle_recording(self):
        if self.is_recording:
            self.is_recording = False
            self.record_btn.setText("⏺ 录制")
            self.record_btn.setStyleSheet("")
            self._add_log("录制", "停止录制")
        else:
            self.is_recording = True
            self.record_btn.setText("⏹ 停止")
            self.record_btn.setStyleSheet("background-color: #f44336;")
            self._add_log("录制", "开始录制")
    

    
    def _toggle_touch_monitor(self):
        if not self.control_url:
            return
        
        if self.is_touch_monitoring:
            threading.Thread(target=lambda: self.session.post(
                f"{self.control_url}/wda/touch/stop", timeout=5
            ), daemon=True).start()
            self.touch_poll_timer.stop()
            self.is_touch_monitoring = False
            self.touch_monitor_btn.setText("👆 监听触摸")
            self.device_touch_label.setText("设备触摸: 已停止")
            self._add_log("监听", "停止设备触摸监听")
        else:
            try:
                resp = self.session.post(f"{self.control_url}/wda/touch/start", timeout=5)
                if resp.status_code == 200:
                    data = resp.json().get("value", {})
                    if data.get("success"):
                        self.touch_poll_timer.start(50)
                        self.is_touch_monitoring = True
                        self.touch_monitor_btn.setText("⏹ 停止监听")
                        self.device_touch_label.setText("设备触摸: 监听中...")
                        self._add_log("监听", "开始设备触摸监听")
                    else:
                        msg = data.get("message", "启动失败")
                        self.device_touch_label.setText(f"设备触摸: {msg}")
                        self._add_log("监听", f"启动失败: {msg}")
            except Exception as e:
                self.device_touch_label.setText(f"设备触摸: 错误")
                self._add_log("监听", f"错误: {str(e)}")
    
    def _poll_touch_events(self):
        if not self.control_url:
            return
        
        try:
            resp = self.session.get(f"{self.control_url}/wda/touch/events", timeout=1)
            if resp.status_code == 200:
                data = resp.json().get("value", {})
                events = data.get("events", [])
                for event in events:
                    x = int(event.get("x", 0))
                    y = int(event.get("y", 0))
                    event_type = event.get("type", "?")
                    
                    self.device_touch_label.setText(f"设备触摸: {event_type} ({x}, {y})")
                    self.device_touch_label.setStyleSheet("color: #00FF00; font-size: 12px;")
                    
                    # 在画布上显示
                    self.screen_canvas.add_device_touch(x, y, event_type)
                    
                    # 添加日志
                    self._add_log(f"设备{event_type}", f"({x}, {y})", source="device")
        except:
            pass
    

    # ========== 控制指令 ==========
    
    def _tap(self, x: int, y: int):
        """发送点击指令 (W3C Actions)"""
        if not self.session_id:
            return
            
        def _do_tap():
            try:
                actions = {
                    "actions": [
                        {
                            "type": "pointer",
                            "id": "finger1",
                            "parameters": {"pointerType": "touch"},
                            "actions": [
                                {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                                {"type": "pointerDown", "button": 0},
                                {"type": "pause", "duration": 50},
                                {"type": "pointerUp", "button": 0}
                            ]
                        }
                    ]
                }
                resp = self.session.post(
                    f"{self.control_url}/session/{self.session_id}/actions",
                    json=actions,
                    timeout=2
                )
            except Exception as e:
                print(f"[Tap Error] {e}")
        
        threading.Thread(target=_do_tap, daemon=True).start()
        
    def _swipe(self, x1, y1, x2, y2, duration=500):
        """发送滑动指令 (W3C Actions)"""
        if not self.session_id:
            return
            
        def _do_swipe():
            try:
                actions = {
                    "actions": [
                        {
                            "type": "pointer",
                            "id": "finger1",
                            "parameters": {"pointerType": "touch"},
                            "actions": [
                                {"type": "pointerMove", "duration": 0, "x": x1, "y": y1},
                                {"type": "pointerDown", "button": 0},
                                {"type": "pointerMove", "duration": int(duration * 1000), "x": x2, "y": y2},
                                {"type": "pointerUp", "button": 0}
                            ]
                        }
                    ]
                }
                resp = self.session.post(
                    f"{self.control_url}/session/{self.session_id}/actions",
                    json=actions,
                    timeout=5
                )
            except Exception as e:
                print(f"[Swipe Error] {e}")
        
        threading.Thread(target=_do_swipe, daemon=True).start()

    def _toggle_touch_monitor(self):
        """切换触摸监听状态"""
        if not self.is_connected:
            QMessageBox.warning(self, "错误", "请先连接设备")
            return
            
        if self.is_touch_monitoring:
            # 停止监听
            self.touch_poll_timer.stop()
            self.is_touch_monitoring = False
            self.touch_monitor_btn.setText("👆 监听触摸")
            self.device_touch_label.setText("设备触摸: 已停止")
            
            # 发送停止指令
            threading.Thread(target=lambda: self.session.post(
                f"{self.control_url}/wda/touch/stop", timeout=2
            ), daemon=True).start()
            
        else:
            # 开始监听
            self.is_touch_monitoring = True
            self.touch_monitor_btn.setText("🛑 停止监听")
            self.device_touch_label.setText("设备触摸: 启动中...")
            
            # 发送开始指令
            def _start_monitor():
                try:
                    self.session.post(f"{self.control_url}/wda/touch/start", timeout=5)
                    # 启动轮询定时器
                    QTimer.singleShot(0, lambda: self.touch_poll_timer.start(50)) # 50ms 轮询一次
                except Exception as e:
                    print(f"[Monitor Error] {e}")
                    self.is_touch_monitoring = False
                    
            threading.Thread(target=_start_monitor, daemon=True).start()
            
    def _poll_touch_events(self):
        """轮询设备触摸事件"""
        if not self.is_touch_monitoring:
            return
            
        def _poll():
            try:
                resp = self.session.get(f"{self.control_url}/wda/touch/events", timeout=1)
                if resp.status_code == 200:
                    events = resp.json().get("value", [])
                    if events:
                        # 只取最新的一个事件显示
                        last_event = events[-1]
                        x = last_event.get("x", 0)
                        y = last_event.get("y", 0)
                        action = last_event.get("type", "")
                        # 在主线程更新 UI
                        QTimer.singleShot(0, lambda: self.device_touch_label.setText(f"设备触摸: {action} ({x}, {y})"))
            except:
                pass
        
        threading.Thread(target=_poll, daemon=True).start()

    # === Native Canvas Handlers ===
    
    def _update_coord_label(self, x, y):
        # x, y 是像素坐标，转换为 WDA 点坐标
        wda_x = int(x / self.screen_scale)
        wda_y = int(y / self.screen_scale)
        self.coord_label.setText(f"坐标: ({wda_x}, {wda_y})")

    def _on_canvas_tap(self, x, y):
        # 视觉反馈
        self.screen_canvas.add_ripple(x, y)
        
        # 转换为逻辑坐标 (Points)
        wda_x = int(x / self.screen_scale)
        wda_y = int(y / self.screen_scale)
        print(f"[Touch] Tap at ({x}, {y}) -> WDA ({wda_x}, {wda_y})")
        
        self._tap(wda_x, wda_y)
        if hasattr(self, 'device_touch_label'):
            self.device_touch_label.setText(f"点击: ({wda_x}, {wda_y})")

    def _on_canvas_double_tap(self, x, y):
        self.screen_canvas.add_ripple(x, y)
        self.screen_canvas.add_ripple(x, y) # Double ripple
        
        # 转换为逻辑坐标 (Points)
        wda_x = int(x / self.screen_scale)
        wda_y = int(y / self.screen_scale)
        print(f"[Touch] Double Tap at ({x}, {y}) -> WDA ({wda_x}, {wda_y})")
        self._double_tap(wda_x, wda_y)
        if hasattr(self, 'device_touch_label'):
            self.device_touch_label.setText(f"双击: ({wda_x}, {wda_y})")

    def _on_canvas_long_press(self, x, y, duration):
        self.screen_canvas.add_ripple(x, y)
        
        # 转换为逻辑坐标 (Points)
        wda_x = int(x / self.screen_scale)
        wda_y = int(y / self.screen_scale)
        print(f"[Touch] Long Press at ({x}, {y}) -> WDA ({wda_x}, {wda_y})")
        self._long_press(wda_x, wda_y, duration)
        if hasattr(self, 'device_touch_label'):
            self.device_touch_label.setText(f"长按: ({wda_x}, {wda_y})")

    def _on_canvas_swipe(self, x1, y1, x2, y2, duration):
        # 转换为逻辑坐标 (Points)
        wda_x1 = int(x1 / self.screen_scale)
        wda_y1 = int(y1 / self.screen_scale)
        wda_x2 = int(x2 / self.screen_scale)
        wda_y2 = int(y2 / self.screen_scale)
        
        print(f"[Touch] Swipe ({x1},{y1}) -> WDA ({wda_x1},{wda_y1}) to ({wda_x2},{wda_y2})")
        self._swipe(wda_x1, wda_y1, wda_x2, wda_y2, duration)
        if hasattr(self, 'device_touch_label'):
            self.device_touch_label.setText(f"滑动: ({wda_x1},{wda_y1}) -> ({wda_x2},{wda_y2})")

    # Removed: eventFilter
    # Removed: _handle_touch_event (Replaced by above)
    
    def _double_tap(self, x, y):
        """执行双击 (W3C Actions)"""
        def _target():
            try:
                actions = {
                    "actions": [
                        {
                            "type": "pointer",
                            "id": "finger1",
                            "parameters": {"pointerType": "touch"},
                            "actions": [
                                {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                                {"type": "pointerDown", "button": 0},
                                {"type": "pause", "duration": 50},
                                {"type": "pointerUp", "button": 0},
                                {"type": "pause", "duration": 100},
                                # Second Tap
                                {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                                {"type": "pointerDown", "button": 0},
                                {"type": "pause", "duration": 50},
                                {"type": "pointerUp", "button": 0}
                            ]
                        }
                    ]
                }
                self.session.post(
                    f"{self.control_url}/session/{self.session_id}/actions",
                     json=actions, timeout=5)
            except Exception as e:
                print(f"[DoubleTap] Error: {e}")
        threading.Thread(target=_target, daemon=True).start()

    def _long_press(self, x, y, duration=1000):
        """执行长按 (W3C Actions)"""
        def _target():
            try:
                actions = {
                    "actions": [
                        {
                            "type": "pointer",
                            "id": "finger1",
                            "parameters": {"pointerType": "touch"},
                            "actions": [
                                {"type": "pointerMove", "duration": 0, "x": x, "y": y},
                                {"type": "pointerDown", "button": 0},
                                {"type": "pause", "duration": int(duration * 1000)},
                                {"type": "pointerUp", "button": 0}
                            ]
                        }
                    ]
                }
                self.session.post(
                    f"{self.control_url}/session/{self.session_id}/actions", 
                    json=actions, timeout=5)
            except Exception as e:
                print(f"[LongPress] Error: {e}")
        threading.Thread(target=_target, daemon=True).start()

    def _press_home(self):
        if not self.wda_url:
            return
        self._add_log("Home", "按下 Home 键")
        threading.Thread(target=lambda: self.session.post(
            f"{self.wda_url}/wda/homescreen", timeout=5
        ), daemon=True).start()
    
    def _save_screenshot(self):
        try:
            pixmap = self.web_view.grab()
            if not pixmap.isNull():
                path = f"screenshot_{int(time.time())}.png"
                pixmap.save(path)
                self.status_label.setText(f"已保存: {path}")
                self._add_log("截图", f"保存到 {path}")
        except Exception as e:
            self._add_log("截图失败", str(e))
    
    def _run_generated_script(self, js_code: str):
        """执行生成的 JavaScript 脚本 - 通过 ECMAIN 转发到 WDA"""
        ecmain_url = self.ecmain_url_input.text().strip()
        if not ecmain_url:
            QMessageBox.warning(self, "错误", "请先配置 ECMAIN 地址")
            return
        
        # 详细日志记录
        self._add_log("发送", f"目标: {ecmain_url}/task")
        self._add_log("发送", f"脚本内容: {js_code[:100]}{'...' if len(js_code) > 100 else ''}")
        
        def _target():
            try:
                payload = {"type": "SCRIPT", "payload": js_code}
                self._add_log("HTTP", f"POST {ecmain_url}/task")
                self._add_log("HTTP", f"Body: {payload}")
                
                resp = self.session.post(
                    f"{ecmain_url}/task", 
                    json=payload,
                    timeout=60
                )
                
                self._add_log("HTTP", f"响应状态: {resp.status_code}")
                self._add_log("HTTP", f"响应内容: {resp.text[:200] if resp.text else '(空)'}")
                
                if resp.status_code == 200:
                    self._add_log("结果", "✅ 脚本已成功发送到 ECMAIN")
                else:
                    self._add_log("错误", f"❌ ECMAIN 返回错误: {resp.status_code}")
            except requests.exceptions.ConnectionError as e:
                self._add_log("错误", f"❌ 无法连接到 ECMAIN: {ecmain_url}")
            except requests.exceptions.Timeout:
                self._add_log("错误", f"❌ 请求超时: {ecmain_url}")
            except Exception as e:
                self._add_log("错误", f"❌ 异常: {type(e).__name__}: {str(e)}")
                
        threading.Thread(target=_target, daemon=True).start()

    def _send_script_to_device(self):
        """脚本面板"发送"按钮: 读取脚本内容，通过 ECMAIN 下发到设备执行"""
        js_code = self.script_edit.toPlainText().strip()
        if not js_code:
            QMessageBox.warning(self, "错误", "脚本内容为空，请先输入脚本")
            return
        self._run_generated_script(js_code)

    def _clear_logs(self):
        self.operation_logs = []
        self.log_text.clear()
    
    def _test_ecmain_connection(self):
        """测试 ECMAIN 连接"""
        ecmain_url = self.ecmain_url_input.text().strip()
        if not ecmain_url:
            self.ecmain_status_label.setText("❌ 请输入地址")
            self.ecmain_status_label.setStyleSheet("color: #FF5252;")
            return
        
        self._add_log("ECMAIN", f"测试连接: {ecmain_url}")
        self.ecmain_status_label.setText("⏳ 测试中...")
        self.ecmain_status_label.setStyleSheet("color: #FFA726;")
        
        def _test():
            try:
                # 发送一个简单的测试请求
                resp = self.session.post(
                    f"{ecmain_url}/task",
                    json={"type": "PING", "payload": "test"},
                    timeout=5
                )
                if resp.status_code == 200:
                    self.ecmain_status_label.setText("✅ 已连接")
                    self.ecmain_status_label.setStyleSheet("color: #4CAF50;")
                    self._add_log("ECMAIN", f"连接成功: {ecmain_url}")
                else:
                    self.ecmain_status_label.setText(f"❌ {resp.status_code}")
                    self.ecmain_status_label.setStyleSheet("color: #FF5252;")
                    self._add_log("ECMAIN", f"连接失败: {resp.status_code}")
            except requests.exceptions.ConnectionError as e:
                self.ecmain_status_label.setText("❌ 无法连接")
                self.ecmain_status_label.setStyleSheet("color: #FF5252;")
                self._add_log("ECMAIN", f"连接失败: 无法连接到 {ecmain_url}")
            except requests.exceptions.Timeout:
                self.ecmain_status_label.setText("❌ 超时")
                self.ecmain_status_label.setStyleSheet("color: #FF5252;")
                self._add_log("ECMAIN", f"连接超时: {ecmain_url}")
            except Exception as e:
                self.ecmain_status_label.setText("❌ 错误")
                self.ecmain_status_label.setStyleSheet("color: #FF5252;")
                self._add_log("ECMAIN", f"连接异常: {str(e)}")
        
        threading.Thread(target=_test, daemon=True).start()
    
    def closeEvent(self, event):
        if self.is_touch_monitoring:
            self.touch_poll_timer.stop()
            try:
                self.session.post(f"{self.wda_url}/wda/touch/stop", timeout=2)
            except:
                pass
        self._disconnect()
        event.accept()
    
    # ========== API 测试方法 ==========
    
    def _show_api_result(self, title: str, result):
        """显示 API 测试结果"""
        text = f"=== {title} ===\n"
        if isinstance(result, dict):
            text += json.dumps(result, indent=2, ensure_ascii=False)
        elif isinstance(result, list):
            text += json.dumps(result, indent=2, ensure_ascii=False)
        else:
            text += str(result)
        text += f"\n\n[{datetime.now().strftime('%H:%M:%S')}]"
        self.api_result_text.setText(text)
        self._add_log("API测试", title)
    
    def _test_device_info(self):
        """测试设备信息"""
        if not self.wda_url:
            return
        try:
            resp = self.session.get(f"{self.wda_url}/status", timeout=5)
            data = resp.json().get("value", {})
            info = {
                "名称": data.get("name", "未知"),
                "iOS版本": data.get("os", {}).get("version", "未知"),
                "设备型号": data.get("model", "未知"),
                "UUID": data.get("uuid", "未知"),
                "SDK版本": data.get("sdkVersion", "未知"),
            }
            self._show_api_result("设备信息", info)
        except Exception as e:
            self._show_api_result("设备信息", f"错误: {e}")
    
    def _test_screen_size(self):
        """测试屏幕尺寸"""
        if not self.session_id:
            return
        try:
            resp = self.session.get(f"{self.wda_url}/session/{self.session_id}/window/size", timeout=5)
            data = resp.json().get("value", {})
            data["scale"] = self.screen_scale
            data["screenshot_size"] = f"{int(data.get('width', 0) * self.screen_scale)}x{int(data.get('height', 0) * self.screen_scale)}"
            self._show_api_result("屏幕尺寸", data)
        except Exception as e:
            self._show_api_result("屏幕尺寸", f"错误: {e}")
    
    def _test_battery(self):
        """测试电池信息"""
        if not self.session_id:
            return
        try:
            resp = self.session.get(f"{self.wda_url}/session/{self.session_id}/wda/batteryInfo", timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("电池信息", data)
        except Exception as e:
            self._show_api_result("电池信息", f"错误: {e}")
    
    def _test_app_info(self):
        """测试应用信息"""
        if not self.session_id:
            return
        try:
            resp = self.session.get(f"{self.wda_url}/session/{self.session_id}/wda/activeAppInfo", timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("当前应用", data)
        except Exception as e:
            self._show_api_result("当前应用", f"错误: {e}")
    
    def _test_screenshot(self):
        """测试截图"""
        if not self.wda_url:
            return
        try:
            start = time.time()
            resp = self.session.get(f"{self.wda_url}/screenshot", timeout=5)
            elapsed = time.time() - start
            data = resp.json()
            img_data = data.get("value", "")
            result = {
                "耗时": f"{elapsed*1000:.0f}ms",
                "图片大小": f"{len(img_data) // 1024}KB (base64)",
                "状态": "成功" if img_data else "失败"
            }
            self._show_api_result("截图", result)
        except Exception as e:
            self._show_api_result("截图", f"错误: {e}")
    
    def _test_get_pixel(self):
        """测试获取像素颜色 (从本地截图帧获取，WDA 不支持 /wda/pixel)"""
        x = self.api_x_input.value() if hasattr(self, 'api_x_input') else 100
        y = self.api_y_input.value() if hasattr(self, 'api_y_input') else 100
        if self.screen_canvas._current_frame:
            frame = self.screen_canvas._current_frame
            px = int(x * self.screen_scale)
            py = int(y * self.screen_scale)
            if 0 <= px < frame.width() and 0 <= py < frame.height():
                color = frame.pixelColor(px, py)
                hex_color = f"#{color.red():02X}{color.green():02X}{color.blue():02X}"
                self._show_api_result(f"像素颜色 ({x},{y})", {
                    "颜色": hex_color,
                    "RGB": f"({color.red()}, {color.green()}, {color.blue()})",
                    "坐标 (WDA 点)": f"({x}, {y})",
                    "坐标 (像素)": f"({px}, {py})"
                })
                # 自动填入颜色输入框
                self.api_color_input.setText(hex_color)
            else:
                self._show_api_result("像素颜色", f"坐标 ({px},{py}) 超出屏幕范围")
        else:
            self._show_api_result("像素颜色", "无屏幕截图，请先连接设备")
    
    def _test_find_color(self):
        """测试找色 (使用用户输入的颜色和容差)"""
        color = self.api_color_input.text().strip() or "#FFFFFF"
        tolerance = self.api_tolerance_input.value()
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/findColor",
                json={"color": color, "tolerance": tolerance},
                timeout=10
            )
            data = resp.json().get("value", {})
            if data.get("found"):
                wda_x = int(data.get('x', 0) / (self.screen_scale or 1))
                wda_y = int(data.get('y', 0) / (self.screen_scale or 1))
                self._show_api_result(f"找色 {color} (tolerance={tolerance})", {
                    "结果": "✅ 找到",
                    "坐标": f"({wda_x}, {wda_y})",
                    "原生像素": f"({data.get('x', 0)}, {data.get('y', 0)})",
                    "原始数据": data
                })
            else:
                self._show_api_result(f"找色 {color}", "❌ 未找到该颜色")
        except Exception as e:
            self._show_api_result("找色", f"错误: {e}")
    
    def _test_find_color_and_tap(self):
        """找色并点击"""
        color = self.api_color_input.text().strip() or "#FFFFFF"
        tolerance = self.api_tolerance_input.value()
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/findColor",
                json={"color": color, "tolerance": tolerance},
                timeout=10
            )
            data = resp.json().get("value", {})
            if data.get("found"):
                wda_x = int(data.get("x", 0) / (self.screen_scale or 1))
                wda_y = int(data.get("y", 0) / (self.screen_scale or 1))
                self._show_api_result(f"找色并点击 {color}", {
                    "结果": "✅ 找到并点击",
                    "坐标": f"({wda_x}, {wda_y})",
                    "原生像素": f"({data.get('x', 0)}, {data.get('y', 0)})"
                })
                # 发送点击
                self._do_click(wda_x, wda_y)
            else:
                self._show_api_result(f"找色并点击 {color}", "❌ 未找到该颜色，无法点击")
        except Exception as e:
            self._show_api_result("找色并点击", f"错误: {e}")
    
    def _test_find_image_from_selection(self):
        """找图：用截图选区作为模板，调用 /wda/findImage 在屏幕上查找"""
        if not self.screen_canvas._current_frame:
            self._show_api_result("找图", "无屏幕截图，请先连接设备")
            return
        
        # 检查是否有选区
        if not hasattr(self.screen_canvas, '_last_selection_rect') or not self.screen_canvas._last_selection_rect:
            self._show_api_result("找图", "请先使用“截图”功能选取一个屏幕区域作为模板\n\n"
                                  "步骤：\n"
                                  "1. 点击“📷 截图”进入选区模式\n"
                                  "2. 在屏幕上拖拽框选按钮区域\n"
                                  "3. 再点击此按钮进行找图")
            return
        
        # 从当前帧截取选区
        frame = self.screen_canvas._current_frame
        sel = self.screen_canvas._last_selection_rect  # (x, y, w, h) 像素坐标
        cropped = frame.copy(sel[0], sel[1], sel[2], sel[3])
        
        if cropped.isNull():
            self._show_api_result("找图", "选区截取失败")
            return
        
        # 转为 base64 PNG
        import io
        from PyQt5.QtCore import QBuffer, QIODevice
        buffer = QBuffer()
        buffer.open(QIODevice.WriteOnly)
        cropped.save(buffer, "PNG")
        template_bytes = bytes(buffer.data())
        buffer.close()
        
        import base64
        template_b64 = base64.b64encode(template_bytes).decode('utf-8')
        
        self._show_api_result("找图", f"⏳ 正在匹配 (模板大小: {sel[2]}x{sel[3]}px, {len(template_b64)//1024}KB)...")
        
        def find():
            try:
                resp = self.session.post(
                    f"{self.wda_url}/wda/findImage",
                    json={"template": template_b64},
                    timeout=15
                )
                data = resp.json().get("value", {})
                if data.get("found"):
                    wda_x = int(data.get("x", 0) / (self.screen_scale or 1))
                    wda_y = int(data.get("y", 0) / (self.screen_scale or 1))
                    self._show_api_result(f"找图结果", {
                        "结果": "✅ 找到",
                        "坐标": f"({wda_x}, {wda_y})",
                        "原生像素": f"({data.get('x', 0)}, {data.get('y', 0)})",
                        "相似度": data.get("similarity", "N/A"),
                        "原始数据": data
                    })
                else:
                    self._show_api_result("找图结果", {
                        "结果": "❌ 未找到匹配",
                        "原始数据": data
                    })
            except Exception as e:
                self._show_api_result("找图", f"错误: {e}")
        
        threading.Thread(target=find, daemon=True).start()
    
    def _test_multi_color(self):
        """测试多点找色"""
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/findMultiColor",
                json={
                    "firstColor": "#FFFFFF",
                    "offsetColors": [{"offset": [10, 0], "color": "#000000"}],
                    "tolerance": 15
                },
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result("多点找色", data)
        except Exception as e:
            self._show_api_result("多点找色", f"错误: {e}")
    
    def _test_ocr(self):
        """测试 OCR"""
        try:
            resp = self.session.post(f"{self.wda_url}/wda/ocr", json={}, timeout=15)
            data = resp.json().get("value", {})
            self._show_api_result("OCR识别", data)
        except Exception as e:
            self._show_api_result("OCR识别", f"错误: {e}")
    
    def _test_find_text(self):
        """测试查找文字"""
        text = self.api_text_input.text().strip()
        if not text:
            self._show_api_result("查找文字", "请输入要查找的文字")
            return
            
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/findText",
                json={"text": text},
                timeout=15,
            )
            data = resp.json().get("value", {})
            self._show_api_result(f"查找文字 '{text}'", data)
        except Exception as e:
            self._show_api_result("查找文字", f"错误: {e}")
    
    def _test_qrcode(self):
        """测试二维码扫描"""
        try:
            resp = self.session.post(f"{self.wda_url}/wda/scanQrcode", json={}, timeout=10)
            data = resp.json().get("value", {})
            self._show_api_result("二维码扫描", data)
        except Exception as e:
            self._show_api_result("二维码扫描", f"错误: {e}")
    
    def _test_sandbox(self):
        """测试沙盒路径"""
        try:
            resp = self.session.get(f"{self.wda_url}/wda/sandbox", timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("沙盒路径", data)
        except Exception as e:
            self._show_api_result("沙盒路径", f"错误: {e}")
    
    def _test_clipboard(self):
        """测试剪贴板"""
        # 即使没有 sessionId 也应该能用我们的自定义接口
        # if not self.session_id:
        #    return
        try:
            # 使用我们自定义的增强接口
            resp = self.session.get(f"{self.wda_url}/wda/clipboard/get", timeout=5)
            
            if resp.status_code == 200:
                data = resp.json().get("value", {})
                # 显示完整调试信息
                self._show_api_result("剪贴板内容 (调试)", data)
            else:
                self._show_api_result("剪贴板", f"失败: {resp.status_code} - {resp.text}")
        except Exception as e:
            self._show_api_result("剪贴板", f"错误: {e}")
    
    def _test_list_files(self):
        """测试列出文件"""
        try:
            resp = self.session.get(f"{self.wda_url}/wda/files?path=/", timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("文件列表", data)
        except Exception as e:
            self._show_api_result("文件列表", f"错误: {e}")
    
    def _test_vibrate(self):
        """测试震动"""
        try:
            resp = self.session.post(f"{self.wda_url}/wda/vibrate", json={}, timeout=5)
            result = "成功" if resp.status_code == 200 else "失败"
            self._show_api_result("震动", {"结果": result})
        except Exception as e:
            self._show_api_result("震动", f"错误: {e}")
    
    def _test_random(self):
        """测试随机数"""
        import random
        nums = [random.randint(1, 100) for _ in range(10)]
        self._show_api_result("随机数 (本地)", {"numbers": nums})
    
    def _test_md5(self):
        """测试 MD5"""
        import hashlib
        text = "Hello ECWDA"
        md5 = hashlib.md5(text.encode()).hexdigest()
        self._show_api_result("MD5 (本地)", {"input": text, "md5": md5})
    
    # ========== ECWDA 脚本引擎 API ==========
    
    def _test_script_run(self):
        """执行 ECWDA 脚本"""
        script = self.api_script_input.text().strip()
        if not script:
            self._show_api_result("脚本执行", "错误: 请输入脚本内容")
            return
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/script/run",
                json={"script": script},
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result("脚本执行", data)
        except Exception as e:
            self._show_api_result("脚本执行", f"错误: {e}")
    
    def _test_script_status(self):
        """获取脚本执行状态"""
        try:
            resp = self.session.get(f"{self.wda_url}/wda/script/status", timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("脚本状态", data)
        except Exception as e:
            self._show_api_result("脚本状态", f"错误: {e}")
    
    def _test_script_stop(self):
        """停止脚本执行"""
        try:
            resp = self.session.post(f"{self.wda_url}/wda/script/stop", json={}, timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("停止脚本", data)
        except Exception as e:
            self._show_api_result("停止脚本", f"错误: {e}")
    
    # ========== ECWDA 节点操作 API ==========
    
    def _test_node_find_by_type(self):
        """按类型查找节点"""
        node_type = self.api_node_input.text().strip() or "Button"
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/node/findByType",
                json={"type": node_type},
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result(f"节点查找(类型={node_type})", data)
        except Exception as e:
            self._show_api_result("节点查找", f"错误: {e}")
    
    def _test_node_find_by_text(self):
        """按文本查找节点"""
        text = self.api_node_input.text().strip() or "设置"
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/node/findByText",
                json={"text": text},
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result(f"节点查找(文本={text})", data)
        except Exception as e:
            self._show_api_result("节点查找", f"错误: {e}")
    
    def _test_node_get_all(self):
        """获取所有节点"""
        try:
            resp = self.session.get(f"{self.wda_url}/wda/node/all", timeout=15)
            data = resp.json().get("value", {})
            # 限制返回的节点数量以避免UI卡顿
            if isinstance(data, dict) and "elements" in data:
                count = data.get("count", 0)
                elements = data.get("elements", [])[:10]
                data = {"count": count, "elements (前10个)": elements}
            self._show_api_result("所有节点", data)
        except Exception as e:
            self._show_api_result("所有节点", f"错误: {e}")
    
    # ========== ECWDA 扩展 API ==========
    
    def _test_ecwda_info(self):
        """获取 ECWDA 信息"""
        try:
            resp = self.session.get(f"{self.wda_url}/wda/ecwda/info", timeout=5)
            data = resp.json().get("value", {})
            self._show_api_result("ECWDA 信息", data)
        except Exception as e:
            self._show_api_result("ECWDA 信息", f"错误: {e}")
    
    def _test_open_url(self):
        """打开 URL"""
        url = self.api_ecwda_input.text().strip()
        if not url.startswith("http"):
            url = "https://" + url
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/openUrl",
                json={"url": url},
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result(f"打开URL: {url}", data)
        except Exception as e:
            self._show_api_result("打开URL", f"错误: {e}")
    
    def _test_base64_encode(self):
        """Base64 编码 (通过 ECWDA)"""
        text = self.api_ecwda_input.text().strip() or "Hello ECWDA!"
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/utils/base64/encode",
                json={"text": text},
                timeout=5
            )
            data = resp.json().get("value", {})
            self._show_api_result("Base64编码", {"input": text, **data})
        except Exception as e:
            self._show_api_result("Base64编码", f"错误: {e}")
    
    def _test_base64_decode(self):
        """Base64 解码 (通过 ECWDA)"""
        text = self.api_ecwda_input.text().strip() or "SGVsbG8gRUNXREEh"
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/utils/base64/decode",
                json={"text": text},
                timeout=5
            )
            data = resp.json().get("value", {})
            self._show_api_result("Base64解码", {"input": text, **data})
        except Exception as e:
            self._show_api_result("Base64解码", f"错误: {e}")
    
    def _test_qrcode_scan(self):
        """二维码识别"""
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/qrcode/scan",
                json={},
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result("二维码识别", data)
        except Exception as e:
            self._show_api_result("二维码识别", f"错误: {e}")
    
    def _test_find_multi_color(self):
        """多点找色 (使用用户输入的主颜色和偏移颜色列表)"""
        color = self.api_color_input.text().strip() or "#FFFFFF"
        tolerance = self.api_tolerance_input.value()
        similarity = max(0.0, 1.0 - tolerance / 255.0)
        
        # 解析偏移颜色 (格式: dx,dy,#RRGGBB|dx,dy,#RRGGBB)
        offset_text = self.api_offset_input.text().strip()
        offset_colors = []
        if offset_text:
            for item in offset_text.split("|"):
                parts = item.strip().split(",")
                if len(parts) >= 3:
                    try:
                        dx = int(parts[0].strip())
                        dy = int(parts[1].strip())
                        c = parts[2].strip()
                        if not c.startswith("#"):
                            c = "#" + c
                        offset_colors.append({"offsetX": dx, "offsetY": dy, "color": c})
                    except ValueError:
                        pass
        
        if not offset_colors:
            self._show_api_result("多点找色", "请输入偏移颜色\n\n"
                                  "格式: dx,dy,#RRGGBB 用 | 分隔多个\n"
                                  "例如: 10,0,#FF0000|20,5,#00FF00\n\n"
                                  "或使用右键取色 + \"+ 追加右键取色\" 按钮自动生成")
            return
        
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/findMultiColor",
                json={
                    "firstColor": color,
                    "offsetColors": offset_colors,
                    "similarity": similarity
                },
                timeout=10
            )
            data = resp.json().get("value", {})
            if data.get("found"):
                wda_x = int(data.get("x", 0) / (self.screen_scale or 1))
                wda_y = int(data.get("y", 0) / (self.screen_scale or 1))
                self._show_api_result(f"多点找色 ({color})", {
                    "结果": "✅ 找到",
                    "坐标": f"({wda_x}, {wda_y})",
                    "原生像素": f"({data.get('x', 0)}, {data.get('y', 0)})",
                    "主颜色": color,
                    "偏移点数": len(offset_colors),
                    "传给API的偏移": offset_colors,
                    "原始数据": data
                })
            else:
                self._show_api_result(f"多点找色 ({color})", {
                    "结果": "❌ 未找到",
                    "主颜色": color,
                    "偏移点": offset_colors,
                    "相似度": similarity
                })
        except Exception as e:
            self._show_api_result("多点找色", f"错误: {e}")
    
    def _test_click_text(self):
        """点击文字"""
        text = self.api_node_input.text().strip() or "设置"
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/clickText",
                json={"text": text},
                timeout=10
            )
            data = resp.json().get("value", {})
            self._show_api_result(f"点击文字({text})", data)
        except Exception as e:
            self._show_api_result("点击文字", f"错误: {e}")
    
    # ========== 新增 API 测试方法 ==========
    
    def _on_offset_input_changed(self, text):
        """当清空偏移输入框时，重置取色的基准点"""
        if not text.strip():
            self._offset_base_wda = None
            self._offset_base_color = None
            
    def _update_color_preview(self, hex_color: str):
        """更新颜色输入框的背景色作为调色板预览"""
        import re
        if re.match(r'^#[0-9a-fA-F]{6}$', hex_color):
            # 根据背景明暗自动调整文字颜色
            r = int(hex_color[1:3], 16)
            g = int(hex_color[3:5], 16)
            b = int(hex_color[5:7], 16)
            # 计算亮度 (YIQ formula)
            yiq = ((r * 299) + (g * 587) + (b * 114)) / 1000
            text_color = "#000000" if yiq >= 128 else "#FFFFFF"
            
            self.api_color_input.setStyleSheet(f"""
                QLineEdit {{
                    background-color: {hex_color};
                    color: {text_color};
                    font-weight: bold;
                    border: 1px solid #555;
                    border-radius: 4px;
                }}
            """)
            
    def _add_offset_color(self):
        """追加右键取色结果为偏移点"""
        if not hasattr(self, '_last_pick_wda') or not self._last_pick_wda:
            self._show_api_result("偏移取色", "请先右键取一个基准色（第一个取的颜色作为主颜色）\n然后右键取偏移点颜色，再点此按钮追加")
            return
        
        # 如果没有基准坐标，用当前作为基准
        if not hasattr(self, '_offset_base_wda') or not self._offset_base_wda:
            self._offset_base_wda = self._last_pick_wda
            self._offset_base_color = self._last_pick_color
            self._show_api_result("偏移取色", f"✅ 已设置主基准点: ({self._offset_base_wda[0]}, {self._offset_base_wda[1]})\n"
                                  f"主颜色: {self._last_pick_color}\n\n"
                                  f"现在请在屏幕上右键取其他偏移点的颜色，然后再按此按钮追加。")
            return
        
        # 计算偏移
        dx = self._last_pick_wda[0] - self._offset_base_wda[0]
        dy = self._last_pick_wda[1] - self._offset_base_wda[1]
        
        current = self.api_offset_input.text().strip()
        new_entry = f"{dx},{dy},{self._last_pick_color}"
        if current:
            self.api_offset_input.setText(f"{current}|{new_entry}")
        else:
            self.api_offset_input.setText(new_entry)
            
        # 恢复主颜色到输入框 (因为取偏移点时被覆盖了)
        if self._offset_base_color:
            self.api_color_input.setText(self._offset_base_color)
        
        self._show_api_result("偏移取色", f"✅ 已追加偏移点:\n偏移({dx},{dy}) 颜色 {self._last_pick_color}")
    
    def _pick_coordinate(self):
        """从屏幕取点"""
        self.pick_mode = "coord"
        self.status_label.setText("🎯 请在屏幕上点击获取坐标...")
        self.status_label.setStyleSheet("color: #FFD700;")
        self._show_api_result("取点模式", "请在左侧屏幕上点击，坐标将自动填入")
    
    def _pick_color(self):
        """从屏幕取色"""
        self.pick_mode = "color"
        self.status_label.setText("🎨 请在屏幕上点击获取颜色...")
        self.status_label.setStyleSheet("color: #FFD700;")
        self._show_api_result("取色模式", "请在左侧屏幕上点击，颜色将自动填入")
    
    def _on_screen_click_for_api(self, x: int, y: int):
        """处理用于 API 测试的屏幕点击"""
        if self.pick_mode == "coord":
            # 转换为 WDA 点坐标
            wda_x = int(x / self.screen_scale)
            wda_y = int(y / self.screen_scale)
            self.api_x_input.setValue(wda_x)
            self.api_y_input.setValue(wda_y)
            self._show_api_result("坐标已获取", {"x": wda_x, "y": wda_y, "像素坐标": {"x": x, "y": y}})
            self.pick_mode = None
            self._restore_status()
        elif self.pick_mode == "color":
            # 获取颜色
            wda_x = int(x / self.screen_scale)
            wda_y = int(y / self.screen_scale)
            self._get_and_fill_color(wda_x, wda_y)
            self.pick_mode = None
            self._restore_status()
    
    def _restore_status(self):
        """恢复状态栏"""
        if self.is_connected:
            conn_type = "USB" if self.using_usb else "WiFi"
            self.status_label.setText(f"已连接 ({conn_type})")
            self.status_label.setStyleSheet("color: #4CAF50;")
        else:
            self.status_label.setText("未连接")
            self.status_label.setStyleSheet("color: #888;")
    
    def _get_and_fill_color(self, x: int, y: int):
        """获取颜色并填入输入框"""
        try:
            # 从当前帧获取颜色
            if self.screen_canvas._current_frame:
                frame = self.screen_canvas._current_frame
                px = int(x * self.screen_scale)
                py = int(y * self.screen_scale)
                if 0 <= px < frame.width() and 0 <= py < frame.height():
                    color = frame.pixelColor(px, py)
                    hex_color = f"#{color.red():02X}{color.green():02X}{color.blue():02X}"
                    self.api_color_input.setText(hex_color)
                    self._show_api_result("颜色已获取", {
                        "颜色": hex_color,
                        "RGB": f"({color.red()}, {color.green()}, {color.blue()})",
                        "坐标": {"x": x, "y": y}
                    })
                    return
            self._show_api_result("取色失败", "无法获取颜色")
        except Exception as e:
            self._show_api_result("取色失败", f"错误: {e}")
    
    def _test_click(self):
        """测试点击"""
        x = self.api_x_input.value()
        y = self.api_y_input.value()
        try:
            # 使用 ECWDA 的 withoutSession 路由，避免触发 UI 树遍历
            resp = self.session.post(
                f"{self.wda_url}/wda/tap",
                json={"x": x, "y": y}, timeout=5
            )
            result = "成功" if resp.status_code == 200 else f"失败 ({resp.status_code})"
            self._show_api_result(f"点击 ({x}, {y})", {"结果": result})
        except Exception as e:
            self._show_api_result("点击", f"错误: {e}")
    
    def _test_double_click(self):
        """测试双击"""
        x = self.api_x_input.value()
        y = self.api_y_input.value()
        try:
            # 使用 ECWDA 的 withoutSession 路由
            resp = self.session.post(
                f"{self.wda_url}/wda/doubleTap",
                json={"x": x, "y": y}, timeout=5
            )
            result = "成功" if resp.status_code == 200 else f"失败 ({resp.status_code})"
            self._show_api_result(f"双击 ({x}, {y})", {"结果": result})
        except Exception as e:
            self._show_api_result("双击", f"错误: {e}")
    
    def _test_long_click(self):
        """测试长按"""
        x = self.api_x_input.value()
        y = self.api_y_input.value()
        try:
            # 使用 ECWDA 的 withoutSession 路由
            resp = self.session.post(
                f"{self.wda_url}/wda/longPress",
                json={"x": x, "y": y, "duration": 1000}, timeout=5
            )
            result = "成功" if resp.status_code == 200 else f"失败 ({resp.status_code})"
            self._show_api_result(f"长按 ({x}, {y})", {"结果": result})
        except Exception as e:
            self._show_api_result("长按", f"错误: {e}")
    
    def _test_input_text(self):
        """测试输入文本"""
        text, ok = QInputDialog.getText(self, "输入文本", "请输入要发送的文本:")
        if ok and text:
            try:
                # 使用 ECWDA 的 withoutSession 路由
                resp = self.session.post(
                    f"{self.wda_url}/wda/inputText",
                    json={"text": text}, timeout=5
                )
                result = "成功" if resp.status_code == 200 else f"失败 ({resp.status_code})"
                self._show_api_result(f"输入文本", {"文本": text, "结果": result})
            except Exception as e:
                self._show_api_result("输入文本", f"错误: {e}")
    
    def _test_cmp_color(self):
        """测试比色"""
        x = self.api_x_input.value()
        y = self.api_y_input.value()
        target_color = self.api_color_input.text().strip()
        tolerance = self.api_tolerance_input.value()
        
        # 从当前帧获取颜色比较
        if self.screen_canvas._current_frame:
            frame = self.screen_canvas._current_frame
            px = int(x * self.screen_scale)
            py = int(y * self.screen_scale)
            if 0 <= px < frame.width() and 0 <= py < frame.height():
                color = frame.pixelColor(px, py)
                actual_hex = f"#{color.red():02X}{color.green():02X}{color.blue():02X}"
                
                # 比较颜色
                try:
                    target = target_color.lstrip('#')
                    tr, tg, tb = int(target[0:2], 16), int(target[2:4], 16), int(target[4:6], 16)
                    match = (abs(color.red() - tr) <= tolerance and
                            abs(color.green() - tg) <= tolerance and
                            abs(color.blue() - tb) <= tolerance)
                    self._show_api_result("比色结果", {
                        "坐标": f"({x}, {y})",
                        "目标颜色": target_color,
                        "实际颜色": actual_hex,
                        "容差": tolerance,
                        "匹配": "✅ 匹配" if match else "❌ 不匹配"
                    })
                except Exception as e:
                    self._show_api_result("比色", f"颜色解析错误: {e}")
        else:
            self._show_api_result("比色", "无法获取屏幕颜色")
    
    def _test_lock_status(self):
        """测试屏幕锁定状态"""
        if not self.session_id:
            return
        try:
            resp = self.session.get(f"{self.wda_url}/session/{self.session_id}/wda/locked", timeout=5)
            data = resp.json().get("value", False)
            self._show_api_result("屏幕锁定状态", {"锁定": "是" if data else "否"})
        except Exception as e:
            self._show_api_result("屏幕锁定状态", f"错误: {e}")
    
    def _test_launch_app(self):
        """测试启动应用"""
        if not self.session_id:
            return
        bundle_id = self.api_bundle_input.text().strip()
        if not bundle_id:
            self._show_api_result("启动应用", "请输入 Bundle ID")
            return
        try:
            resp = self.session.post(
                f"{self.wda_url}/session/{self.session_id}/wda/apps/launch",
                json={"bundleId": bundle_id}, timeout=10
            )
            result = "成功" if resp.status_code == 200 else f"失败 ({resp.status_code})"
            self._show_api_result(f"启动应用 {bundle_id}", {"结果": result})
        except Exception as e:
            self._show_api_result("启动应用", f"错误: {e}")
    
    def _test_terminate_app(self):
        """测试关闭应用"""
        if not self.session_id:
            return
        bundle_id = self.api_bundle_input.text().strip()
        if not bundle_id:
            self._show_api_result("关闭应用", "请输入 Bundle ID")
            return
        try:
            resp = self.session.post(
                f"{self.wda_url}/session/{self.session_id}/wda/apps/terminate",
                json={"bundleId": bundle_id}, timeout=5
            )
            result = "成功" if resp.status_code == 200 else f"失败 ({resp.status_code})"
            self._show_api_result(f"关闭应用 {bundle_id}", {"结果": result})
        except Exception as e:
            self._show_api_result("关闭应用", f"错误: {e}")
    
    def _toggle_selection_mode(self, checked: bool):
        """切换框选模板模式"""
        self.selection_mode_type = "template" if checked else None
        self.screen_canvas.set_selection_mode(checked)
        if checked:
            self.select_template_btn.setText("🖼️ 取消框选")
            self.select_template_btn.setStyleSheet("background-color: #FF5722;")
            self._show_api_result("框选模式", "请在左侧屏幕预览上拖动鼠标框选模板区域")
        else:
            self.select_template_btn.setText("🖼️ 框选模板")
            self.select_template_btn.setStyleSheet("")
            self.screen_canvas._selection_rect = None
            self.screen_canvas.update()
    
    def _on_selection_complete(self, x: int, y: int, width: int, height: int):
        """选区完成回调 - 支持模板和区域两种模式"""
        
        # 区域选择模式
        if self.selection_mode_type == "region":
            # 更新区域输入框
            self.region_x1.setValue(x)
            self.region_y1.setValue(y)
            self.region_x2.setValue(x + width)
            self.region_y2.setValue(y + height)
            
            # 退出选区模式
            self.select_region_btn.setChecked(False)
            self._toggle_region_selection_mode(False)
            
            self._show_api_result("区域已选取", {
                "左上角": f"({x}, {y})",
                "右下角": f"({x + width}, {y + height})",
                "尺寸": f"{width}x{height}"
            })
            return
        
        # 模板选择模式
        try:
            frame = getattr(self.screen_canvas, '_current_frame', None)
            
            # 如果没有当前帧(WebEngine 模式)，需要从设备实时请求最新一帧截图
            if not frame:
                try:
                    resp = self.session.get(f"{self.wda_url}/screenshot", timeout=5)
                    data = resp.json().get("value")
                    if data:
                        img_bytes = base64.b64decode(data)
                        frame = QImage.fromData(img_bytes)
                except Exception as e:
                    self._show_api_result("框选模板", f"无法拉取设备截图: {e}")
                    return

            if not frame or frame.isNull():
                self._show_api_result("框选模板", "底图依然为空，无法完成截取")
                return
            
            # 坐标已经是设备坐标，直接使用
            cropped = frame.copy(x, y, width, height)
            
            if cropped.isNull():
                self._show_api_result("框选模板", "截取失败，请重试")
                return
            
            # 转为 base64
            buffer = BytesIO()
            # 转换 QImage 为 PIL Image
            img_data = cropped.bits()
            img_data.setsize(cropped.byteCount())
            
            # 根据 QImage 格式处理
            if cropped.format() == QImage.Format_RGBA8888:
                mode = "RGBA"
            elif cropped.format() == QImage.Format_RGB888:
                mode = "RGB"
            else:
                # 转换为 RGB888
                cropped = cropped.convertToFormat(QImage.Format_RGB888)
                img_data = cropped.bits()
                img_data.setsize(cropped.byteCount())
                mode = "RGB"
            
            # 注意 QImage 的行是按4字节对齐的
            bytes_per_line = cropped.bytesPerLine()
            img = Image.frombuffer(mode, (cropped.width(), cropped.height()),
                                   bytes(img_data), 'raw', mode, bytes_per_line, 1)
            img.save(buffer, format="PNG")
            self.template_image_data = base64.b64encode(buffer.getvalue()).decode()
            
            # 自动复制长代码到剪贴板，方便跨组件粘贴（如脚本生成器中）
            from PyQt5.QtWidgets import QApplication
            QApplication.clipboard().setText(self.template_image_data)
            
            # 更新 UI
            self.template_label.setText(f"模板: {width}x{height}")
            self.template_label.setStyleSheet("color: #4CAF50; font-weight: bold;")
            
            # 退出选区模式
            self.select_template_btn.setChecked(False)
            self._toggle_selection_mode(False)
            
            self._show_api_result("模板已选取", {
                "区域": f"({x}, {y})",
                "尺寸": f"{width}x{height}",
                "Base64长度": len(self.template_image_data),
                "剪贴板": "✅ 已自动复制图片代码，可直接去左边粘贴"
            })
        except Exception as e:
            self._show_api_result("框选模板失败", f"错误: {e}")
    
    def _test_find_image_ecwda(self):
        """通过 ECWDA 找图"""
        if not hasattr(self, 'template_image_data') or not self.template_image_data:
            self._show_api_result("找图", "请先框选模板图片")
            return
        
        threshold = self.find_img_threshold.value() / 100.0
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/findImage",
                json={
                    "template": self.template_image_data,
                    "threshold": threshold
                },
                timeout=30
            )
            data = resp.json().get("value", {})
            if isinstance(data, dict) and "value" in data:
                data = data["value"]
            
            # 显示完整 Base64
            base64_full = self.template_image_data
            
            if data.get("found"):
                img_x = data.get("x", 0)
                img_y = data.get("y", 0)
                wda_x = int(img_x / (self.screen_scale or 1))
                wda_y = int(img_y / (self.screen_scale or 1))
                self._show_api_result("找图成功", {
                    "逻辑坐标": f"({wda_x}, {wda_y})",
                    "原生像素": f"({img_x}, {img_y})",
                    "尺寸": f"{data.get('width')}x{data.get('height')}",
                    "置信度": f"{data.get('confidence', 0):.1%}",
                    "模板Base64": base64_full,
                    "Base64长度": len(self.template_image_data)
                })
            else:
                self._show_api_result("找图", {
                    "结果": "未找到匹配",
                    "最高置信度": f"{data.get('confidence', 0):.1%}",
                    "模板Base64": base64_full,
                    "建议": "降低匹配阈值或更换模板"
                })
        except Exception as e:
            self._show_api_result("找图", f"错误: {e}")
    
    def _test_find_image_and_click(self):
        """找图并点击 - 随机点击图片区域内的位置（模拟人手）"""
        import random
        
        if not hasattr(self, 'template_image_data') or not self.template_image_data:
            self._show_api_result("找图并点击", "请先框选模板图片")
            return
        
        threshold = self.find_img_threshold.value() / 100.0
        try:
            # 先找图
            resp = self.session.post(
                f"{self.wda_url}/wda/findImage",
                json={
                    "template": self.template_image_data,
                    "threshold": threshold
                },
                timeout=30
            )
            data = resp.json().get("value", {})
            if isinstance(data, dict) and "value" in data:
                data = data["value"]
            
            if data.get("found"):
                # 获取图片位置和尺寸
                img_x = data.get("x", 0)
                img_y = data.get("y", 0)
                img_w = data.get("width", 0)
                img_h = data.get("height", 0)
                
                # 计算随机点击位置（在图片区域内的 20%-80% 范围内，模拟人手）
                random_offset_x = random.uniform(0.2, 0.8)
                random_offset_y = random.uniform(0.2, 0.8)
                
                # 最终点击坐标（逻辑坐标，除以 screen_scale）
                scale = self.screen_scale or 1
                click_x = int((img_x + img_w * random_offset_x) / scale)
                click_y = int((img_y + img_h * random_offset_y) / scale)
                
                # 使用 ECWDA 的 withoutSession 路由执行点击
                click_resp = self.session.post(
                    f"{self.wda_url}/wda/tap",
                    json={"x": click_x, "y": click_y},
                    timeout=10
                )
                
                self._show_api_result("找图并点击", {
                    "图片位置": f"({img_x}, {img_y})",
                    "图片尺寸": f"{img_w}x{img_h}",
                    "随机偏移": f"({random_offset_x:.0%}, {random_offset_y:.0%})",
                    "点击位置": f"({click_x}, {click_y})",
                    "置信度": f"{data.get('confidence', 0):.1%}",
                    "点击结果": "成功" if click_resp.status_code == 200 else f"失败({click_resp.status_code})"
                })
            else:
                self._show_api_result("找图并点击", {
                    "结果": "未找到匹配，无法点击",
                    "最高置信度": f"{data.get('confidence', 0):.1%}"
                })
        except Exception as e:
            self._show_api_result("找图并点击", f"错误: {e}")
    
    # ========== 随机区域操作 ==========
    def _toggle_region_selection_mode(self, checked: bool):
        """切换区域框选模式"""
        self.selection_mode_type = "region" if checked else None
        self.screen_canvas.set_selection_mode(checked)
        if checked:
            self.select_region_btn.setText("🖼️ 取消框选")
            self.select_region_btn.setStyleSheet("background-color: #2196F3;")
            self._show_api_result("区域框选", "请在左侧屏幕预览上拖动鼠标框选操作区域")
        else:
            self.select_region_btn.setText("🖼️ 框选区域")
            self.select_region_btn.setStyleSheet("")
            self.screen_canvas._selection_rect = None
            self.screen_canvas.update()
    
    def _test_random_tap(self):
        """随机点击区域内任意位置"""
        import random
        x1, y1 = self.region_x1.value(), self.region_y1.value()
        x2, y2 = self.region_x2.value(), self.region_y2.value()
        
        # 生成随机坐标
        x = random.randint(min(x1, x2), max(x1, x2))
        y = random.randint(min(y1, y2), max(y1, y2))
        
        try:
            # 使用 ECWDA 的 withoutSession 路由
            resp = self.session.post(
                f"{self.wda_url}/wda/tap",
                json={"x": x, "y": y},
                timeout=10
            )
            self._show_api_result("随机点击", {
                "区域": f"({x1},{y1}) - ({x2},{y2})",
                "随机坐标": f"({x}, {y})",
                "结果": "成功" if resp.status_code == 200 else f"失败({resp.status_code})"
            })
        except Exception as e:
            self._show_api_result("随机点击", f"错误: {e}")
    
    def _test_random_double_tap(self):
        """随机双击区域内任意位置"""
        import random
        x1, y1 = self.region_x1.value(), self.region_y1.value()
        x2, y2 = self.region_x2.value(), self.region_y2.value()
        
        x = random.randint(min(x1, x2), max(x1, x2))
        y = random.randint(min(y1, y2), max(y1, y2))
        
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/doubleTap",
                json={"x": x, "y": y},
                timeout=10
            )
            self._show_api_result("随机双击", {
                "区域": f"({x1},{y1}) - ({x2},{y2})",
                "随机坐标": f"({x}, {y})",
                "结果": "成功" if resp.status_code == 200 else f"失败({resp.status_code})"
            })
        except Exception as e:
            self._show_api_result("随机双击", f"错误: {e}")
    
    def _test_random_long_press(self):
        """随机长按区域内任意位置"""
        import random
        x1, y1 = self.region_x1.value(), self.region_y1.value()
        x2, y2 = self.region_x2.value(), self.region_y2.value()
        
        x = random.randint(min(x1, x2), max(x1, x2))
        y = random.randint(min(y1, y2), max(y1, y2))
        
        try:
            resp = self.session.post(
                f"{self.wda_url}/wda/touchAndHold",
                json={"x": x, "y": y, "duration": 1000},
                timeout=10
            )
            self._show_api_result("随机长按", {
                "区域": f"({x1},{y1}) - ({x2},{y2})",
                "随机坐标": f"({x}, {y})",
                "时长": "1.0秒",
                "结果": "成功" if resp.status_code == 200 else f"失败({resp.status_code})"
            })
        except Exception as e:
            self._show_api_result("随机长按", f"错误: {e}")
    
    def _test_random_swipe(self):
        """随机滑动 - 根据区域和方向计算起点终点"""
        import random
        x1, y1 = self.region_x1.value(), self.region_y1.value()
        x2, y2 = self.region_x2.value(), self.region_y2.value()
        
        # 获取方向
        direction_text = self.swipe_direction.currentText()
        direction_map = {"↑ 向上": "up", "↓ 向下": "down", "← 向左": "left", "→ 向右": "right"}
        direction = direction_map.get(direction_text, "up")
        
        # 确保坐标正确
        min_x, max_x = min(x1, x2), max(x1, x2)
        min_y, max_y = min(y1, y2), max(y1, y2)
        mid_x = (min_x + max_x) // 2
        mid_y = (min_y + max_y) // 2
        
        # 根据方向计算起点和终点
        if direction == "up":
            # 从下往上滑
            sx = random.randint(min_x, max_x)
            sy = random.randint(mid_y, max_y)  # 起点在下半部分
            ex = random.randint(min_x, max_x)
            ey = random.randint(min_y, mid_y)  # 终点在上半部分
        elif direction == "down":
            # 从上往下滑
            sx = random.randint(min_x, max_x)
            sy = random.randint(min_y, mid_y)  # 起点在上半部分
            ex = random.randint(min_x, max_x)
            ey = random.randint(mid_y, max_y)  # 终点在下半部分
        elif direction == "left":
            # 从右往左滑
            sx = random.randint(mid_x, max_x)  # 起点在右半部分
            sy = random.randint(min_y, max_y)
            ex = random.randint(min_x, mid_x)  # 终点在左半部分
            ey = random.randint(min_y, max_y)
        elif direction == "right":
            # 从左往右滑
            sx = random.randint(min_x, mid_x)  # 起点在左半部分
            sy = random.randint(min_y, max_y)
            ex = random.randint(mid_x, max_x)  # 终点在右半部分
            ey = random.randint(min_y, max_y)
        else:
            sx, sy = random.randint(min_x, max_x), random.randint(mid_y, max_y)
            ex, ey = random.randint(min_x, max_x), random.randint(min_y, mid_y)
        
        # duration 使用毫秒级随机值，模拟真人手指速度
        duration_ms = random.randint(130, 350)
        
        try:
            # 使用 ECWDA 的 withoutSession 路由，避免触发 UI 树遍历
            resp = self.session.post(
                f"{self.control_url}/wda/swipe",
                json={
                    "fromX": sx, "fromY": sy,
                    "toX": ex, "toY": ey,
                    "duration": duration_ms / 1000.0
                },
                timeout=10
            )
            self._show_api_result("随机滑动", {
                "区域": f"({min_x},{min_y}) - ({max_x},{max_y})",
                "方向": direction_text,
                "起点": f"({sx}, {sy})",
                "终点": f"({ex}, {ey})",
                "时长": f"{duration_ms}ms",
                "结果": "成功" if resp.status_code == 200 else f"失败({resp.status_code})"
            })
        except Exception as e:
            self._show_api_result("随机滑动", f"错误: {e}")



    def _poll_latest_frame(self):
        """UI 主线程从后台线程拉取最新帧"""
        if self.stream_thread:
            jpg_data = self.stream_thread.get_latest_frame()
            if jpg_data:
                # 在主线程解码，利用多核 (Qt 内部优化) 但不阻塞网络线程
                qimg = QImage.fromData(jpg_data)
                if not qimg.isNull():
                    self.screen_canvas.set_image(qimg, qimg.width(), qimg.height())

    def _update_stream_stats(self):
        """更新 FPS 和延迟统计"""
        if self.stream_thread:
            current_count = self.stream_thread._frame_counter
            fps = current_count - self.last_frame_count
            self.last_frame_count = current_count
            
            self._on_fps_change(30) # 更新 UI 显示 
            if fps > 0:
                 self.fps_label.setText(f"FPS: {fps}")
                 self.latency_label.setText(f"延迟: {int(1000/fps)}ms")
            else:
                 self.fps_label.setText(f"FPS: 0")

    def _on_stream_error(self, error_msg: str):
        """流媒体线程报错处理"""
        print(f"[Stream Error] {error_msg}")
        self._add_log("视频流", f"错误: {error_msg}")

def main():
    print("[DEBUG] Starting main...")
    # === 关键修复: 彻底禁用系统代理 ===
    # 1. 清除环境变量代理设置 (防止 requests/Qt 读取)
    for k in ["http_proxy", "https_proxy", "all_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY"]:
        if k in os.environ:
            del os.environ[k]
            
    # 2. 设置 Qt 应用程序不使用代理
    print("[DEBUG] Setting NoProxy...")
    QNetworkProxy.setApplicationProxy(QNetworkProxy(QNetworkProxy.NoProxy))
    
    # === 关键修复: 开启 OpenGL 硬件加速 (仅 macOS 需要强制) ===
    # macOS 上 PyQtWebEngine 需要明确请求 OpenGL 3.2 Core Profile 才能开启 GPU 加速
    # Windows 上通常不需要，且强制 Desktop OpenGL 可能会导致兼容性问题 (Qt 会自动选 ANGLE/D3D)
    if sys.platform == 'darwin':
        print("[DEBUG] macOS detected, creating OpenGL 3.2 context...")
        format = QSurfaceFormat()
        format.setDepthBufferSize(24)
        format.setStencilBufferSize(8)
        format.setVersion(3, 2)
        format.setProfile(QSurfaceFormat.CoreProfile)
        QSurfaceFormat.setDefaultFormat(format)
        
        # 解决 Chromium 软件渲染问题 (Lag fix)
        QApplication.setAttribute(Qt.AA_UseDesktopOpenGL)
        QApplication.setAttribute(Qt.AA_ShareOpenGLContexts)
    else:
        print(f"[DEBUG] Platform: {sys.platform}, using default graphics backend.")
        # Windows/Linux 下通常自动选择即可，或者可以显式尝试
        # QApplication.setAttribute(Qt.AA_UseOpenGLES) # 某些 Windows 可能需要这个
        pass
    
    # 3. 启动参数强制 Chromium 内核禁用代理 + 强制 GPU 加速
    # --no-proxy-server: 禁用代理
    # --ignore-certificate-errors: 忽略自签名证书错误
    # --enable-gpu-rasterization: 强制 GPU 光栅化
    # --ignore-gpu-blocklist: 忽略 GPU 黑名单
    args = sys.argv + [
        "--no-proxy-server", 
        "--ignore-certificate-errors",
        "--enable-gpu-rasterization",
        "--ignore-gpu-blocklist",
        "--enable-zero-copy"
    ]
    
    print("[DEBUG] Creating QApplication...")
    app = QApplication(args)
    app.setStyle('Fusion')
    
    # 深色主题
    palette = QPalette()
    # ... (colors)
    palette.setColor(QPalette.Window, QColor(30, 30, 46))
    palette.setColor(QPalette.WindowText, Qt.white)
    palette.setColor(QPalette.Base, QColor(25, 25, 40))
    palette.setColor(QPalette.Text, Qt.white)
    palette.setColor(QPalette.Button, QColor(45, 45, 65))
    palette.setColor(QPalette.ButtonText, Qt.white)
    palette.setColor(QPalette.Highlight, QColor(100, 100, 200))
    palette.setColor(QPalette.HighlightedText, Qt.white)
    app.setPalette(palette)
    
    print("[DEBUG] Initializing ControlCenter...")
    window = ControlCenter()
    window.show()
    
    print("[DEBUG] Starting Event Loop...")
    sys.exit(app.exec_())



        
if __name__ == "__main__":
    main()
