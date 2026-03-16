#!/usr/bin/env python3
"""
Real-time iPhone Screen Mirror with Click Control
Uses high-frequency screenshot polling for compatibility (MJPEG fallback)
"""

import sys
import threading
import time
import base64
import requests
from io import BytesIO
from typing import Optional

try:
    from PyQt5.QtWidgets import (QApplication, QMainWindow, QLabel, QVBoxLayout,
                                  QHBoxLayout, QWidget, QLineEdit, QPushButton, 
                                  QSizePolicy, QMessageBox, QSlider)
    from PyQt5.QtCore import Qt, QThread, pyqtSignal, QPoint, QTimer
    from PyQt5.QtGui import QImage, QPixmap, QPainter, QMouseEvent
except ImportError:
    print("需要安装 PyQt5: pip3 install PyQt5")
    sys.exit(1)

try:
    from PIL import Image
except ImportError:
    print("需要安装 Pillow: pip3 install Pillow")
    sys.exit(1)


class ScreenshotThread(QThread):
    """高频截图线程"""
    frame_ready = pyqtSignal(QImage, int, int)  # image, width, height
    error_signal = pyqtSignal(str)
    fps_signal = pyqtSignal(float)
    
    def __init__(self, wda_url: str, session_id: str):
        super().__init__()
        self.wda_url = wda_url
        self.session_id = session_id
        self.running = False
        self.interval = 0.05  # 50ms = ~20 FPS 目标
        self._last_fps_time = time.time()
        self._frame_count = 0
    
    def set_interval(self, interval: float):
        """设置截图间隔"""
        self.interval = max(0.03, interval)  # 最小 30ms
    
    def run(self):
        self.running = True
        screenshot_url = f"{self.wda_url}/screenshot"
        
        session = requests.Session()
        
        while self.running:
            start_time = time.time()
            
            try:
                resp = session.get(screenshot_url, timeout=3)
                if resp.status_code != 200:
                    time.sleep(0.5)
                    continue
                
                data = resp.json()
                img_data = data.get("value")
                if not img_data:
                    continue
                
                # 解码 base64 图像
                img_bytes = base64.b64decode(img_data)
                img = Image.open(BytesIO(img_bytes))
                img = img.convert("RGB")
                
                # 转换为 QImage
                qimg = QImage(img.tobytes("raw", "RGB"), 
                             img.width, img.height,
                             img.width * 3, QImage.Format_RGB888)
                self.frame_ready.emit(qimg.copy(), img.width, img.height)
                
                # FPS 统计
                self._frame_count += 1
                now = time.time()
                if now - self._last_fps_time >= 1.0:
                    fps = self._frame_count / (now - self._last_fps_time)
                    self.fps_signal.emit(fps)
                    self._frame_count = 0
                    self._last_fps_time = now
                
            except Exception as e:
                if self.running:
                    self.error_signal.emit(str(e))
                time.sleep(0.5)
                continue
            
            # 控制帧率
            elapsed = time.time() - start_time
            sleep_time = self.interval - elapsed
            if sleep_time > 0:
                time.sleep(sleep_time)
    
    def stop(self):
        self.running = False


class ScreenLabel(QLabel):
    """可点击的屏幕显示控件"""
    click_signal = pyqtSignal(int, int)
    drag_signal = pyqtSignal(int, int, int, int)
    coord_signal = pyqtSignal(int, int)  # 新增：坐标变化信号
    
    def __init__(self):
        super().__init__()
        self.setAlignment(Qt.AlignCenter)
        self.setMinimumSize(200, 300)
        self.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        self.setStyleSheet("background-color: #1a1a2e; border: 1px solid #333;")
        self.setMouseTracking(True)  # 启用鼠标追踪
        
        self._image_size = None
        self._drag_start = None
        self._is_dragging = False
    
    def set_image(self, qimg: QImage, dev_width: int, dev_height: int):
        """设置显示的图像"""
        self._image_size = (dev_width, dev_height)
        scaled = qimg.scaled(self.size(), Qt.KeepAspectRatio, Qt.SmoothTransformation)
        self.setPixmap(QPixmap.fromImage(scaled))
    
    def _map_to_device(self, pos: QPoint) -> tuple:
        """将控件坐标映射到设备坐标"""
        if not self._image_size or not self.pixmap():
            return None
        
        pix = self.pixmap()
        label_w, label_h = self.width(), self.height()
        pix_w, pix_h = pix.width(), pix.height()
        
        offset_x = (label_w - pix_w) // 2
        offset_y = (label_h - pix_h) // 2
        
        rel_x = pos.x() - offset_x
        rel_y = pos.y() - offset_y
        
        if rel_x < 0 or rel_y < 0 or rel_x >= pix_w or rel_y >= pix_h:
            return None
        
        dev_x = int(rel_x * self._image_size[0] / pix_w)
        dev_y = int(rel_y * self._image_size[1] / pix_h)
        
        return (dev_x, dev_y)
    
    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton:
            self._drag_start = event.pos()
            self._is_dragging = False
    
    def mouseMoveEvent(self, event: QMouseEvent):
        # 发送坐标信号
        coord = self._map_to_device(event.pos())
        if coord:
            self.coord_signal.emit(coord[0], coord[1])
        
        if self._drag_start:
            dx = abs(event.pos().x() - self._drag_start.x())
            dy = abs(event.pos().y() - self._drag_start.y())
            if dx > 10 or dy > 10:
                self._is_dragging = True
    
    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.LeftButton and self._drag_start:
            end_pos = event.pos()
            start_coord = self._map_to_device(self._drag_start)
            end_coord = self._map_to_device(end_pos)
            
            if start_coord and end_coord:
                print(f"[DEBUG] 坐标: {start_coord} -> {end_coord}, 拖动: {self._is_dragging}")
                if self._is_dragging:
                    # 滑动
                    self.drag_signal.emit(start_coord[0], start_coord[1],
                                         end_coord[0], end_coord[1])
                else:
                    # 点击
                    self.click_signal.emit(start_coord[0], start_coord[1])
            else:
                print(f"[DEBUG] 坐标映射失败: {self._drag_start} -> {end_pos}")
            
            self._drag_start = None
            self._is_dragging = False


class ScreenMirrorWindow(QMainWindow):
    """主窗口"""
    
    def __init__(self):
        super().__init__()
        self.setWindowTitle("iPhone 实时镜像 - ECWDA")
        self.setMinimumSize(400, 700)
        self.resize(400, 850)
        
        self.wda_url = ""
        self.session_id = None
        self.stream_thread = None
        
        self._setup_ui()
    
    def _setup_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setSpacing(8)
        layout.setContentsMargins(10, 10, 10, 10)
        
        # 连接区域
        conn_layout = QHBoxLayout()
        self.url_input = QLineEdit()
        self.url_input.setPlaceholderText("WDA 地址，如 http://192.168.1.100:8100")
        self.url_input.setText("http://192.168.110.171:8100")
        conn_layout.addWidget(self.url_input)
        
        self.connect_btn = QPushButton("连接")
        self.connect_btn.clicked.connect(self._toggle_connection)
        self.connect_btn.setStyleSheet("padding: 5px 15px;")
        conn_layout.addWidget(self.connect_btn)
        layout.addLayout(conn_layout)
        
        # 状态栏
        status_layout = QHBoxLayout()
        self.status_label = QLabel("未连接")
        self.status_label.setStyleSheet("color: #888;")
        status_layout.addWidget(self.status_label)
        
        self.fps_label = QLabel("FPS: --")
        self.fps_label.setStyleSheet("color: #4CAF50; font-weight: bold;")
        status_layout.addWidget(self.fps_label)
        status_layout.addStretch()
        
        # 帧率调节
        fps_ctrl = QHBoxLayout()
        fps_ctrl.addWidget(QLabel("帧率:"))
        self.fps_slider = QSlider(Qt.Horizontal)
        self.fps_slider.setRange(5, 30)  # 5-30 FPS
        self.fps_slider.setValue(15)
        self.fps_slider.setFixedWidth(100)
        self.fps_slider.valueChanged.connect(self._on_fps_change)
        fps_ctrl.addWidget(self.fps_slider)
        self.fps_target_label = QLabel("15")
        fps_ctrl.addWidget(self.fps_target_label)
        status_layout.addLayout(fps_ctrl)
        
        layout.addLayout(status_layout)
        
        # 屏幕显示区域
        self.screen_label = ScreenLabel()
        self.screen_label.click_signal.connect(self._on_click)
        self.screen_label.drag_signal.connect(self._on_drag)
        self.screen_label.coord_signal.connect(self._on_coord)  # 坐标更新
        layout.addWidget(self.screen_label, 1)
        
        # 坐标显示
        self.coord_label = QLabel("坐标: (-, -)")
        self.coord_label.setStyleSheet("color: #FFD700; font-size: 14px; font-weight: bold;")
        self.coord_label.setAlignment(Qt.AlignCenter)
        layout.addWidget(self.coord_label)
        
        # 设备触摸显示（从真机获取）
        self.device_touch_label = QLabel("设备触摸: 未监听")
        self.device_touch_label.setStyleSheet("color: #00BFFF; font-size: 12px;")
        self.device_touch_label.setAlignment(Qt.AlignCenter)
        layout.addWidget(self.device_touch_label)
        
        # 快捷按钮
        btn_layout = QHBoxLayout()
        
        home_btn = QPushButton("🏠 Home")
        home_btn.clicked.connect(self._press_home)
        btn_layout.addWidget(home_btn)
        
        lock_btn = QPushButton("🔒 锁屏")
        lock_btn.clicked.connect(self._press_lock)
        btn_layout.addWidget(lock_btn)
        
        screenshot_btn = QPushButton("📷 截图")
        screenshot_btn.clicked.connect(self._save_screenshot)
        btn_layout.addWidget(screenshot_btn)
        
        # 触摸监听按钮
        self.touch_monitor_btn = QPushButton("👆 监听触摸")
        self.touch_monitor_btn.clicked.connect(self._toggle_touch_monitor)
        btn_layout.addWidget(self.touch_monitor_btn)
        
        layout.addLayout(btn_layout)
        
        # 触摸监听定时器
        self.touch_poll_timer = QTimer()
        self.touch_poll_timer.timeout.connect(self._poll_touch_events)
        self.is_touch_monitoring = False
        
        # 提示
        hint = QLabel("💡 点击控制 | 拖动滑动 | 👆监听真机触摸")
        hint.setStyleSheet("color: #666; font-size: 11px;")
        hint.setAlignment(Qt.AlignCenter)
        layout.addWidget(hint)
    
    def _on_fps_change(self, value: int):
        self.fps_target_label.setText(str(value))
        if self.stream_thread:
            self.stream_thread.set_interval(1.0 / value)
    
    def _toggle_connection(self):
        if self.stream_thread and self.stream_thread.running:
            self._disconnect()
        else:
            self._connect()
    
    def _connect(self):
        self.wda_url = self.url_input.text().strip().rstrip('/')
        if not self.wda_url:
            QMessageBox.warning(self, "错误", "请输入 WDA 地址")
            return
        
        self.status_label.setText("正在连接...")
        self.connect_btn.setEnabled(False)
        QApplication.processEvents()
        
        # 创建 session
        try:
            resp = requests.post(f"{self.wda_url}/session", 
                               json={"capabilities": {}}, timeout=10)
            if resp.status_code == 200:
                data = resp.json()
                self.session_id = data.get("sessionId") or data.get("value", {}).get("sessionId")
            
            if not self.session_id:
                raise Exception("无法获取 session ID")
            
        except Exception as e:
            self.status_label.setText(f"连接失败: {e}")
            self.status_label.setStyleSheet("color: #f44336;")
            self.connect_btn.setEnabled(True)
            return
        
        # 启动截图线程
        target_fps = self.fps_slider.value()
        self.stream_thread = ScreenshotThread(self.wda_url, self.session_id)
        self.stream_thread.set_interval(1.0 / target_fps)
        self.stream_thread.frame_ready.connect(self._on_frame)
        self.stream_thread.error_signal.connect(self._on_error)
        self.stream_thread.fps_signal.connect(self._on_fps)
        self.stream_thread.start()
        
        self.status_label.setText("已连接 (截图模式)")
        self.status_label.setStyleSheet("color: #4CAF50;")
        self.connect_btn.setText("断开")
        self.connect_btn.setEnabled(True)
    
    def _disconnect(self):
        if self.stream_thread:
            self.stream_thread.stop()
            self.stream_thread.wait(2000)
            self.stream_thread = None
        
        self.session_id = None
        self.status_label.setText("已断开")
        self.status_label.setStyleSheet("color: #888;")
        self.fps_label.setText("FPS: --")
        self.connect_btn.setText("连接")
    
    def _on_frame(self, qimg: QImage, dev_w: int, dev_h: int):
        self.screen_label.set_image(qimg, dev_w, dev_h)
    
    def _on_fps(self, fps: float):
        self.fps_label.setText(f"FPS: {fps:.1f}")
    
    def _on_error(self, msg: str):
        # 只显示非连接错误
        if "timeout" not in msg.lower():
            self.status_label.setText(f"警告: {msg[:30]}")
    
    def _on_coord(self, x: int, y: int):
        """更新坐标显示"""
        self.coord_label.setText(f"坐标: ({x}, {y})")
    
    def _on_click(self, x: int, y: int):
        """处理点击事件"""
        if not self.session_id:
            return
        
        threading.Thread(target=self._do_click, args=(x, y), daemon=True).start()
    
    def _do_click(self, x: int, y: int):
        try:
            print(f"[DEBUG] 发送点击: ({x}, {y}) session={self.session_id}")
            # 使用 W3C Touch Actions 进行点击
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
            resp = requests.post(
                f"{self.wda_url}/session/{self.session_id}/actions",
                json=actions,
                timeout=5
            )
            print(f"[DEBUG] 点击响应: {resp.status_code}")
        except Exception as e:
            print(f"[ERROR] 点击失败: {e}")
    
    def _on_drag(self, from_x: int, from_y: int, to_x: int, to_y: int):
        """处理滑动事件"""
        if not self.session_id:
            return
        
        threading.Thread(target=self._do_drag, 
                        args=(from_x, from_y, to_x, to_y), daemon=True).start()
    
    def _do_drag(self, from_x: int, from_y: int, to_x: int, to_y: int):
        try:
            print(f"[DEBUG] 发送滑动: ({from_x},{from_y}) -> ({to_x},{to_y})")
            # 使用 W3C Touch Actions 进行滑动
            actions = {
                "actions": [
                    {
                        "type": "pointer",
                        "id": "finger1",
                        "parameters": {"pointerType": "touch"},
                        "actions": [
                            {"type": "pointerMove", "duration": 0, "x": from_x, "y": from_y},
                            {"type": "pointerDown", "button": 0},
                            {"type": "pause", "duration": 10},
                            {"type": "pointerMove", "duration": 250, "x": to_x, "y": to_y},
                            {"type": "pointerUp", "button": 0}
                        ]
                    }
                ]
            }
            resp = requests.post(
                f"{self.wda_url}/session/{self.session_id}/actions",
                json=actions,
                timeout=10
            )
            print(f"[DEBUG] 滑动响应: {resp.status_code}")
        except Exception as e:
            print(f"[ERROR] 滑动失败: {e}")
    
    def _press_home(self):
        if not self.wda_url:
            return
        threading.Thread(target=lambda: requests.post(
            f"{self.wda_url}/wda/homescreen", timeout=5
        ), daemon=True).start()
    
    def _press_lock(self):
        if not self.session_id:
            return
        threading.Thread(target=lambda: requests.post(
            f"{self.wda_url}/session/{self.session_id}/wda/lock", timeout=5
        ), daemon=True).start()
    
    def _save_screenshot(self):
        if self.screen_label.pixmap():
            path = f"screenshot_{int(time.time())}.png"
            self.screen_label.pixmap().save(path)
            self.status_label.setText(f"已保存: {path}")
    
    def _toggle_touch_monitor(self):
        """切换触摸监听状态"""
        if not self.wda_url:
            return
        
        if self.is_touch_monitoring:
            # 停止监听
            threading.Thread(target=lambda: requests.post(
                f"{self.wda_url}/wda/touch/stop", timeout=5
            ), daemon=True).start()
            self.touch_poll_timer.stop()
            self.is_touch_monitoring = False
            self.touch_monitor_btn.setText("👆 监听触摸")
            self.device_touch_label.setText("设备触摸: 已停止")
        else:
            # 开始监听
            try:
                resp = requests.post(f"{self.wda_url}/wda/touch/start", timeout=5)
                if resp.status_code == 200:
                    data = resp.json().get("value", {})
                    if data.get("success"):
                        self.touch_poll_timer.start(50)  # 50ms 轮询
                        self.is_touch_monitoring = True
                        self.touch_monitor_btn.setText("⏹ 停止监听")
                        self.device_touch_label.setText("设备触摸: 监听中...")
                    else:
                        self.device_touch_label.setText(f"设备触摸: {data.get('message', '启动失败')}")
            except Exception as e:
                self.device_touch_label.setText(f"设备触摸: 错误 - {str(e)[:20]}")
    
    def _poll_touch_events(self):
        """轮询触摸事件"""
        if not self.wda_url:
            return
        
        try:
            resp = requests.get(f"{self.wda_url}/wda/touch/events", timeout=1)
            if resp.status_code == 200:
                data = resp.json().get("value", {})
                events = data.get("events", [])
                if events:
                    # 显示最新的触摸事件
                    latest = events[-1]
                    x = int(latest.get("x", 0))
                    y = int(latest.get("y", 0))
                    event_type = latest.get("type", "?")
                    self.device_touch_label.setText(f"设备触摸: {event_type} ({x}, {y})")
                    self.device_touch_label.setStyleSheet("color: #00FF00; font-size: 12px;")
        except:
            pass
    
    def closeEvent(self, event):
        if self.is_touch_monitoring:
            self.touch_poll_timer.stop()
            try:
                requests.post(f"{self.wda_url}/wda/touch/stop", timeout=2)
            except:
                pass
        self._disconnect()
        event.accept()


def main():
    app = QApplication(sys.argv)
    app.setStyle('Fusion')
    
    # 深色主题
    from PyQt5.QtGui import QPalette, QColor
    palette = QPalette()
    palette.setColor(QPalette.Window, QColor(30, 30, 46))
    palette.setColor(QPalette.WindowText, Qt.white)
    palette.setColor(QPalette.Base, QColor(25, 25, 40))
    palette.setColor(QPalette.Text, Qt.white)
    palette.setColor(QPalette.Button, QColor(40, 40, 60))
    palette.setColor(QPalette.ButtonText, Qt.white)
    app.setPalette(palette)
    
    window = ScreenMirrorWindow()
    window.show()
    
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
