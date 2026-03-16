#!/usr/bin/env python3
"""
ECWDA 脚本生成器 (PyQt5 版本)
类似按键精灵的脚本录制和控制工具

功能：
1. 实时屏幕投屏
2. 鼠标点击/滑动控制
3. 获取坐标和颜色信息
4. 录制操作脚本
5. 脚本回放执行
"""

import sys
import threading
import time
import json
import base64
import io
from datetime import datetime
from typing import Optional, Dict, List, Tuple

from PyQt5.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QPushButton, QLineEdit, QTextEdit, QComboBox, QGroupBox,
    QFileDialog, QMessageBox, QSplitter, QFrame, QScrollArea
)
from PyQt5.QtCore import Qt, QTimer, pyqtSignal, QObject, QPoint
from PyQt5.QtGui import QPixmap, QImage, QPainter, QColor, QCursor, QKeySequence
from PyQt5.QtWidgets import QShortcut

try:
    from PIL import Image
except ImportError:
    print("请安装 Pillow: pip install Pillow")
    sys.exit(1)

from ecwda import ECWDA


class SignalEmitter(QObject):
    """用于线程间通信的信号发射器"""
    update_screen = pyqtSignal(bytes)
    

class ScreenLabel(QLabel):
    """可交互的屏幕显示标签"""
    
    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMinimumSize(300, 500)
        self.setAlignment(Qt.AlignCenter)
        self.setStyleSheet("background-color: #1a1a1a; border: 1px solid #333;")
        
        self.current_image: Optional[Image.Image] = None
        self.scale_factor = 1.0
        self.offset = (0, 0)
        self.drag_start = None
        
        # 长轨迹录制
        self.trajectory_mode = False
        self.trajectory_points: List[Tuple[int, int]] = []
        
        # 回调函数
        self.on_click = None
        self.on_drag = None
        self.on_move = None
        self.on_right_click = None
        self.on_trajectory = None  # 长轨迹滑动回调
        
        self.setMouseTracking(True)
    
    def set_image(self, img_data: bytes):
        """设置显示的图像"""
        self.current_image = Image.open(io.BytesIO(img_data))
        self._update_display()
    
    def _update_display(self):
        """更新显示"""
        if not self.current_image:
            return
        
        # 计算缩放
        widget_w = self.width()
        widget_h = self.height()
        img_w, img_h = self.current_image.size
        
        scale_w = widget_w / img_w
        scale_h = widget_h / img_h
        self.scale_factor = min(scale_w, scale_h, 1.0)
        
        new_w = int(img_w * self.scale_factor)
        new_h = int(img_h * self.scale_factor)
        
        # 转换为 QPixmap
        resized = self.current_image.resize((new_w, new_h), Image.Resampling.LANCZOS)
        
        if resized.mode == 'RGBA':
            data = resized.tobytes('raw', 'RGBA')
            qimg = QImage(data, new_w, new_h, QImage.Format_RGBA8888)
        else:
            resized = resized.convert('RGB')
            data = resized.tobytes('raw', 'RGB')
            qimg = QImage(data, new_w, new_h, QImage.Format_RGB888)
        
        pixmap = QPixmap.fromImage(qimg)
        self.setPixmap(pixmap)
        
        # 计算偏移
        self.offset = ((widget_w - new_w) // 2, (widget_h - new_h) // 2)
    
    def _to_device_coords(self, x: int, y: int) -> Tuple[int, int]:
        """转换为设备坐标"""
        if not self.current_image:
            return (0, 0)
        
        rel_x = x - self.offset[0]
        rel_y = y - self.offset[1]
        
        device_x = int(rel_x / self.scale_factor)
        device_y = int(rel_y / self.scale_factor)
        
        return (device_x, device_y)
    
    def get_color_at(self, device_x: int, device_y: int) -> str:
        """获取指定位置的颜色"""
        if not self.current_image:
            return "#000000"
        
        try:
            if 0 <= device_x < self.current_image.width and 0 <= device_y < self.current_image.height:
                pixel = self.current_image.getpixel((device_x, device_y))
                if len(pixel) >= 3:
                    return f"#{pixel[0]:02X}{pixel[1]:02X}{pixel[2]:02X}"
        except:
            pass
        return "#000000"
    
    def mousePressEvent(self, event):
        if event.button() == Qt.LeftButton:
            device_x, device_y = self._to_device_coords(event.x(), event.y())
            self.drag_start = (device_x, device_y)
        elif event.button() == Qt.RightButton:
            if self.on_right_click:
                self.on_right_click()
    
    def mouseReleaseEvent(self, event):
        if event.button() == Qt.LeftButton and self.drag_start:
            device_x, device_y = self._to_device_coords(event.x(), event.y())
            start_x, start_y = self.drag_start
            
            dx = abs(device_x - start_x)
            dy = abs(device_y - start_y)
            
            if dx < 10 and dy < 10:
                # 点击
                if self.on_click:
                    self.on_click(start_x, start_y)
            else:
                # 滑动
                if self.trajectory_mode and len(self.trajectory_points) > 1:
                    # 长轨迹模式
                    if self.on_trajectory:
                        self.on_trajectory(self.trajectory_points.copy())
                    self.trajectory_points = []
                elif self.on_drag:
                    self.on_drag(start_x, start_y, device_x, device_y)
            
            self.drag_start = None
    
    def mouseMoveEvent(self, event):
        device_x, device_y = self._to_device_coords(event.x(), event.y())
        color = self.get_color_at(device_x, device_y)
        if self.on_move:
            self.on_move(device_x, device_y, color)
        
        # 长轨迹录制模式：记录移动轨迹
        if self.trajectory_mode and self.drag_start:
            if len(self.trajectory_points) == 0 or \
               (abs(device_x - self.trajectory_points[-1][0]) > 5 or 
                abs(device_y - self.trajectory_points[-1][1]) > 5):
                self.trajectory_points.append((device_x, device_y))
    
    def resizeEvent(self, event):
        super().resizeEvent(event)
        if self.current_image:
            self._update_display()


class ScriptGeneratorQt(QMainWindow):
    """脚本生成器主界面 (PyQt5 版本)"""
    
    def __init__(self):
        super().__init__()
        self.setWindowTitle("ECWDA 脚本生成器 v1.0 (Qt)")
        self.setGeometry(100, 100, 1400, 900)
        
        # ECWDA 客户端
        self.ec: Optional[ECWDA] = None
        self.connected = False
        
        # 屏幕状态
        self.screen_width = 375
        self.screen_height = 667
        
        # 录制状态
        self.recording = False
        self.recorded_actions: List[Dict] = []
        self.last_action_time = 0
        
        # 拾取模式
        self.pick_mode = None
        self.multi_color_points: List[Dict] = []
        
        # 投屏
        self.running = False
        self.fps = 5
        
        # 信号
        self.signals = SignalEmitter()
        self.signals.update_screen.connect(self._on_screen_update)
        
        # 当前坐标
        self.current_x = 0
        self.current_y = 0
        
        # 空格键状态
        self.space_pressed = False
        
        self._create_ui()
        self._setup_shortcuts()
    
    def _create_ui(self):
        """创建用户界面"""
        central = QWidget()
        self.setCentralWidget(central)
        
        main_layout = QHBoxLayout(central)
        
        # 左侧：屏幕显示
        left_group = QGroupBox("屏幕")
        left_layout = QVBoxLayout(left_group)
        
        self.screen_label = ScreenLabel()
        self.screen_label.on_click = self._on_screen_click
        self.screen_label.on_drag = self._on_screen_drag
        self.screen_label.on_move = self._on_mouse_move
        self.screen_label.on_right_click = self._on_right_click
        self.screen_label.on_trajectory = self._on_trajectory
        left_layout.addWidget(self.screen_label)
        
        main_layout.addWidget(left_group, stretch=2)
        
        # 右侧：控制面板
        right_widget = QWidget()
        right_widget.setMaximumWidth(500)
        right_layout = QVBoxLayout(right_widget)
        
        # 连接区域
        conn_group = QGroupBox("连接")
        conn_layout = QHBoxLayout(conn_group)
        
        conn_layout.addWidget(QLabel("WDA 地址:"))
        self.url_input = QLineEdit("http://localhost:10088")
        conn_layout.addWidget(self.url_input)
        
        self.connect_btn = QPushButton("连接")
        self.connect_btn.clicked.connect(self._toggle_connection)
        conn_layout.addWidget(self.connect_btn)
        
        self.status_label = QLabel("未连接")
        self.status_label.setStyleSheet("color: red;")
        conn_layout.addWidget(self.status_label)
        
        right_layout.addWidget(conn_group)
        
        # 信息显示区域
        info_group = QGroupBox("信息")
        info_layout = QVBoxLayout(info_group)
        
        # 坐标
        coord_row = QHBoxLayout()
        coord_row.addWidget(QLabel("坐标:"))
        self.coord_label = QLabel("X: 0, Y: 0")
        self.coord_label.setStyleSheet("font-family: Consolas;")
        coord_row.addWidget(self.coord_label)
        coord_row.addStretch()
        
        copy_coord_btn = QPushButton("复制坐标")
        copy_coord_btn.clicked.connect(self._copy_coord)
        coord_row.addWidget(copy_coord_btn)
        info_layout.addLayout(coord_row)
        
        # 颜色
        color_row = QHBoxLayout()
        color_row.addWidget(QLabel("颜色:"))
        self.color_label = QLabel("#000000")
        self.color_label.setStyleSheet("font-family: Consolas;")
        color_row.addWidget(self.color_label)
        
        self.color_preview = QLabel()
        self.color_preview.setFixedSize(30, 20)
        self.color_preview.setStyleSheet("background-color: black; border: 1px solid gray;")
        color_row.addWidget(self.color_preview)
        color_row.addStretch()
        
        copy_color_btn = QPushButton("复制颜色")
        copy_color_btn.clicked.connect(self._copy_color)
        color_row.addWidget(copy_color_btn)
        info_layout.addLayout(color_row)
        
        right_layout.addWidget(info_group)
        
        # 工具区域
        tool_group = QGroupBox("工具")
        tool_layout = QVBoxLayout(tool_group)
        
        tool_row1 = QHBoxLayout()
        
        btn = QPushButton("📷 截图")
        btn.clicked.connect(self._save_screenshot)
        tool_row1.addWidget(btn)
        
        btn = QPushButton("🎨 拾取颜色")
        btn.clicked.connect(self._start_pick_color)
        tool_row1.addWidget(btn)
        
        btn = QPushButton("📍 拾取坐标")
        btn.clicked.connect(self._start_pick_position)
        tool_row1.addWidget(btn)
        
        btn = QPushButton("🌈 多点找色")
        btn.clicked.connect(self._start_pick_multicolor)
        tool_row1.addWidget(btn)
        
        tool_layout.addLayout(tool_row1)
        
        tool_row2 = QHBoxLayout()
        
        btn = QPushButton("🏠 主屏幕")
        btn.clicked.connect(self._go_home)
        tool_row2.addWidget(btn)
        
        btn = QPushButton("↑ 上滑")
        btn.clicked.connect(lambda: self._swipe('up'))
        tool_row2.addWidget(btn)
        
        btn = QPushButton("↓ 下滑")
        btn.clicked.connect(lambda: self._swipe('down'))
        tool_row2.addWidget(btn)
        
        btn = QPushButton("← 左滑")
        btn.clicked.connect(lambda: self._swipe('left'))
        tool_row2.addWidget(btn)
        
        btn = QPushButton("→ 右滑")
        btn.clicked.connect(lambda: self._swipe('right'))
        tool_row2.addWidget(btn)
        
        tool_layout.addLayout(tool_row2)
        right_layout.addWidget(tool_group)
        
        # 录制区域
        record_group = QGroupBox("录制")
        record_layout = QVBoxLayout(record_group)
        
        record_btn_row = QHBoxLayout()
        
        self.record_btn = QPushButton("⏺ 开始录制")
        self.record_btn.clicked.connect(self._toggle_recording)
        record_btn_row.addWidget(self.record_btn)
        
        btn = QPushButton("🗑 清空")
        btn.clicked.connect(self._clear_recording)
        record_btn_row.addWidget(btn)
        
        btn = QPushButton("▶ 回放")
        btn.clicked.connect(self._playback)
        record_btn_row.addWidget(btn)
        
        btn = QPushButton("💾 保存")
        btn.clicked.connect(self._save_script)
        record_btn_row.addWidget(btn)
        
        btn = QPushButton("📂 加载")
        btn.clicked.connect(self._load_script)
        record_btn_row.addWidget(btn)
        
        record_layout.addLayout(record_btn_row)
        
        self.record_status = QLabel("未录制")
        record_layout.addWidget(self.record_status)
        
        # 快捷键提示
        shortcut_label = QLabel("快捷键: Ctrl+S=开始录制, Ctrl+T=停止录制, 按住空格+拖动=长轨迹")
        shortcut_label.setStyleSheet("color: gray; font-size: 9pt;")
        record_layout.addWidget(shortcut_label)
        
        right_layout.addWidget(record_group)
        
        # 手动添加动作
        add_group = QGroupBox("添加动作")
        add_layout = QHBoxLayout(add_group)
        
        add_layout.addWidget(QLabel("类型:"))
        self.action_type = QComboBox()
        self.action_type.addItems(['tap', 'longPress', 'doubleTap', 'swipe', 'sleep', 'home'])
        add_layout.addWidget(self.action_type)
        
        add_layout.addWidget(QLabel("X:"))
        self.action_x = QLineEdit()
        self.action_x.setMaximumWidth(60)
        add_layout.addWidget(self.action_x)
        
        add_layout.addWidget(QLabel("Y:"))
        self.action_y = QLineEdit()
        self.action_y.setMaximumWidth(60)
        add_layout.addWidget(self.action_y)
        
        btn = QPushButton("添加")
        btn.clicked.connect(self._add_action)
        add_layout.addWidget(btn)
        
        right_layout.addWidget(add_group)
        
        # 脚本编辑区域
        script_group = QGroupBox("脚本 (可直接编辑JSON格式脚本)")
        script_layout = QVBoxLayout(script_group)
        
        # 脚本格式说明
        script_hint = QLabel('格式: [{"action": "tap", "params": {"x": 100, "y": 200}}, ...]')
        script_hint.setStyleSheet("color: gray; font-size: 9pt;")
        script_layout.addWidget(script_hint)
        
        self.script_text = QTextEdit()
        self.script_text.setStyleSheet("font-family: Consolas; font-size: 10pt;")
        self.script_text.setPlaceholderText(
            '输入 JSON 脚本，例如:\n'
            '[\n'
            '  {"action": "tap", "params": {"x": 100, "y": 200}},\n'
            '  {"action": "sleep", "params": {"seconds": 1}},\n'
            '  {"action": "swipe", "params": {"fromX": 100, "fromY": 500, "toX": 100, "toY": 200}}\n'
            ']'
        )
        script_layout.addWidget(self.script_text)
        
        right_layout.addWidget(script_group, stretch=1)
        
        # 底部按钮
        bottom_row = QHBoxLayout()
        
        btn = QPushButton("生成 Python 代码")
        btn.clicked.connect(self._generate_python)
        bottom_row.addWidget(btn)
        
        btn = QPushButton("生成 JSON 脚本")
        btn.clicked.connect(self._generate_json)
        bottom_row.addWidget(btn)
        
        btn = QPushButton("▶ 发送到设备执行")
        btn.clicked.connect(self._send_to_device)
        bottom_row.addWidget(btn)
        
        right_layout.addLayout(bottom_row)
        
        main_layout.addWidget(right_widget)
    
    def _setup_shortcuts(self):
        """设置快捷键"""
        # Ctrl+S 键 - 开始录制
        shortcut_start = QShortcut(QKeySequence('Ctrl+S'), self)
        shortcut_start.activated.connect(self._start_recording)
        
        # Ctrl+T 键 - 停止录制
        shortcut_stop = QShortcut(QKeySequence('Ctrl+T'), self)
        shortcut_stop.activated.connect(self._stop_recording)
    
    def keyPressEvent(self, event):
        """按键按下事件"""
        if event.key() == Qt.Key_Space and not event.isAutoRepeat():
            self.space_pressed = True
            self.screen_label.trajectory_mode = True
            self.record_status.setText("🔵 长轨迹模式 (按住空格拖动)")
            self.record_status.setStyleSheet("color: blue;")
        super().keyPressEvent(event)
    
    def keyReleaseEvent(self, event):
        """按键释放事件"""
        if event.key() == Qt.Key_Space and not event.isAutoRepeat():
            self.space_pressed = False
            self.screen_label.trajectory_mode = False
            if self.recording:
                self.record_status.setText("🔴 正在录制...")
                self.record_status.setStyleSheet("color: red;")
            else:
                self.record_status.setText("未录制")
                self.record_status.setStyleSheet("color: black;")
        super().keyReleaseEvent(event)
    
    def _start_recording(self):
        """开始录制 (快捷键 S)"""
        if not self.recording:
            self._toggle_recording()
    
    def _stop_recording(self):
        """停止录制 (快捷键 T)"""
        if self.recording:
            self._toggle_recording()
    
    def _toggle_connection(self):
        if self.connected:
            self._disconnect()
        else:
            self._connect()
    
    def _connect(self):
        url = self.url_input.text()
        self.ec = ECWDA(url)
        
        if self.ec.is_connected():
            self.connected = True
            self.connect_btn.setText("断开")
            self.status_label.setText("已连接")
            self.status_label.setStyleSheet("color: green;")
            
            self.ec.create_session()
            self.screen_width, self.screen_height = self.ec.get_screen_size()
            
            self._start_screen_capture()
        else:
            QMessageBox.critical(self, "连接失败", 
                "无法连接到 WDA，请检查:\n1. WDA 是否在运行\n2. 端口转发: tidevice relay 10088 10088")
    
    def _disconnect(self):
        self.running = False
        self.connected = False
        self.connect_btn.setText("连接")
        self.status_label.setText("未连接")
        self.status_label.setStyleSheet("color: red;")
    
    def _start_screen_capture(self):
        self.running = True
        thread = threading.Thread(target=self._capture_loop, daemon=True)
        thread.start()
    
    def _capture_loop(self):
        while self.running:
            try:
                img_base64 = self.ec.screenshot()
                if img_base64:
                    img_data = base64.b64decode(img_base64)
                    self.signals.update_screen.emit(img_data)
                
                time.sleep(1.0 / self.fps)
            except Exception as e:
                print(f"截图错误: {e}")
                time.sleep(1)
    
    def _on_screen_update(self, img_data: bytes):
        self.screen_label.set_image(img_data)
    
    def _on_screen_click(self, x: int, y: int):
        if self.pick_mode == 'color':
            color = self.color_label.text()
            self._add_to_script(f"# 颜色: {color} 位置: ({x}, {y})")
            self.pick_mode = None
            return
        
        if self.pick_mode == 'position':
            self._add_to_script(f"# 坐标: ({x}, {y})")
            self.pick_mode = None
            return
        
        if self.pick_mode == 'multicolor':
            color = self.color_label.text()
            if len(self.multi_color_points) == 0:
                self.multi_color_points.append({
                    'x': x, 'y': y, 'color': color, 'offset': [0, 0]
                })
                QMessageBox.information(self, "多点找色", 
                    f"已添加第 1 个点\n颜色: {color}\n继续点击添加更多点，右键结束")
            else:
                first = self.multi_color_points[0]
                offset_x = x - first['x']
                offset_y = y - first['y']
                self.multi_color_points.append({
                    'x': x, 'y': y, 'color': color, 'offset': [offset_x, offset_y]
                })
                QMessageBox.information(self, "多点找色", 
                    f"已添加第 {len(self.multi_color_points)} 个点\n偏移: [{offset_x}, {offset_y}]\n颜色: {color}")
            return
        
        if self.connected and self.ec:
            self.ec.click(x, y)
            if self.recording:
                self._record_action({'action': 'tap', 'params': {'x': x, 'y': y}})
    
    def _on_screen_drag(self, from_x: int, from_y: int, to_x: int, to_y: int):
        if self.pick_mode:
            return
        
        if self.connected and self.ec:
            self.ec.swipe(from_x, from_y, to_x, to_y, 0.3)
            if self.recording:
                self._record_action({
                    'action': 'swipe',
                    'params': {'fromX': from_x, 'fromY': from_y, 'toX': to_x, 'toY': to_y}
                })
    
    def _on_trajectory(self, points: List[Tuple[int, int]]):
        """处理长轨迹滑动"""
        if not self.connected or not self.ec or len(points) < 2:
            return
        
        # 执行长轨迹滑动
        # 将轨迹分解为多个短滑动
        for i in range(len(points) - 1):
            from_x, from_y = points[i]
            to_x, to_y = points[i + 1]
            self.ec.swipe(from_x, from_y, to_x, to_y, 0.05)
            time.sleep(0.02)
        
        # 录制长轨迹
        if self.recording:
            self._record_action({
                'action': 'trajectory',
                'params': {'points': points}
            })
    
    def _on_mouse_move(self, x: int, y: int, color: str):
        self.current_x = x
        self.current_y = y
        self.coord_label.setText(f"X: {x}, Y: {y}")
        self.color_label.setText(color)
        self.color_preview.setStyleSheet(f"background-color: {color}; border: 1px solid gray;")
    
    def _on_right_click(self):
        if self.pick_mode == 'multicolor' and len(self.multi_color_points) > 0:
            self._finish_multicolor()
    
    def _finish_multicolor(self):
        if len(self.multi_color_points) < 2:
            QMessageBox.warning(self, "多点找色", "至少需要 2 个点")
            return
        
        first = self.multi_color_points[0]
        offsets = []
        for p in self.multi_color_points[1:]:
            offsets.append({'offset': p['offset'], 'color': p['color']})
        
        code = f'''# 多点找色
pos = ec.find_multi_color(
    first_color="{first['color']}",
    offset_colors={json.dumps(offsets, indent=8)}
)
if pos:
    ec.click(pos['x'], pos['y'])
'''
        self._add_to_script(code)
        
        self.multi_color_points = []
        self.pick_mode = None
    
    def _copy_coord(self):
        QApplication.clipboard().setText(f"({self.current_x}, {self.current_y})")
    
    def _copy_color(self):
        QApplication.clipboard().setText(self.color_label.text())
    
    def _save_screenshot(self):
        if self.screen_label.current_image:
            filename, _ = QFileDialog.getSaveFileName(
                self, "保存截图", 
                f"screenshot_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png",
                "PNG (*.png);;JPEG (*.jpg)"
            )
            if filename:
                self.screen_label.current_image.save(filename)
                QMessageBox.information(self, "保存成功", f"截图已保存到:\n{filename}")
    
    def _start_pick_color(self):
        self.pick_mode = 'color'
        QMessageBox.information(self, "拾取颜色", "点击屏幕上的位置获取颜色")
    
    def _start_pick_position(self):
        self.pick_mode = 'position'
        QMessageBox.information(self, "拾取坐标", "点击屏幕上的位置获取坐标")
    
    def _start_pick_multicolor(self):
        self.pick_mode = 'multicolor'
        self.multi_color_points = []
        QMessageBox.information(self, "多点找色", 
            "点击第一个颜色点（基准点），然后点击其他偏移点。\n右键结束拾取。")
    
    def _go_home(self):
        if self.ec:
            self.ec.home()
            if self.recording:
                self._record_action({'action': 'home', 'params': {}})
    
    def _swipe(self, direction: str):
        if not self.ec:
            return
        
        if direction == 'up':
            self.ec.swipe_up()
        elif direction == 'down':
            self.ec.swipe_down()
        elif direction == 'left':
            self.ec.swipe_left()
        elif direction == 'right':
            self.ec.swipe_right()
        
        if self.recording:
            self._record_action({'action': f'swipe_{direction}', 'params': {}})
    
    def _toggle_recording(self):
        self.recording = not self.recording
        if self.recording:
            self.record_btn.setText("⏹ 停止录制")
            self.record_status.setText("🔴 正在录制...")
            self.record_status.setStyleSheet("color: red;")
            self.last_action_time = time.time()
        else:
            self.record_btn.setText("⏺ 开始录制")
            self.record_status.setText(f"已录制 {len(self.recorded_actions)} 个动作")
            self.record_status.setStyleSheet("color: black;")
    
    def _record_action(self, action: Dict):
        now = time.time()
        if self.last_action_time > 0:
            delay = now - self.last_action_time
            if delay > 0.1:
                self.recorded_actions.append({
                    'action': 'sleep',
                    'params': {'seconds': round(delay, 2)}
                })
        
        self.recorded_actions.append(action)
        self.last_action_time = now
        self._update_script_display()
    
    def _update_script_display(self):
        self.script_text.clear()
        for i, action in enumerate(self.recorded_actions, 1):
            self.script_text.append(f"{i}. {json.dumps(action, ensure_ascii=False)}")
    
    def _clear_recording(self):
        self.recorded_actions = []
        self.script_text.clear()
        self.record_status.setText("已清空")
        self.record_status.setStyleSheet("color: black;")
    
    def _playback(self):
        if not self.ec or not self.recorded_actions:
            return
        
        def run_playback():
            for action in self.recorded_actions:
                if action['action'] == 'tap':
                    self.ec.click(action['params']['x'], action['params']['y'])
                elif action['action'] == 'longPress':
                    self.ec.long_click(action['params']['x'], action['params']['y'], action['params'].get('duration', 1))
                elif action['action'] == 'doubleTap':
                    self.ec.double_click(action['params']['x'], action['params']['y'])
                elif action['action'] == 'swipe':
                    p = action['params']
                    self.ec.swipe(p['fromX'], p['fromY'], p['toX'], p['toY'])
                elif action['action'] == 'sleep':
                    time.sleep(action['params']['seconds'])
                elif action['action'] == 'home':
                    self.ec.home()
                elif action['action'] == 'swipe_up':
                    self.ec.swipe_up()
                elif action['action'] == 'swipe_down':
                    self.ec.swipe_down()
        
        threading.Thread(target=run_playback, daemon=True).start()
    
    def _add_action(self):
        action_type = self.action_type.currentText()
        x = self.action_x.text()
        y = self.action_y.text()
        
        action = {'action': action_type, 'params': {}}
        
        if action_type in ['tap', 'longPress', 'doubleTap']:
            if x and y:
                action['params'] = {'x': int(x), 'y': int(y)}
        elif action_type == 'swipe':
            action['params'] = {'fromX': int(x) if x else 200, 'fromY': 600, 'toX': int(x) if x else 200, 'toY': 200}
        elif action_type == 'sleep':
            action['params'] = {'seconds': float(x) if x else 1.0}
        
        self.recorded_actions.append(action)
        self._update_script_display()
    
    def _add_to_script(self, text: str):
        self.script_text.append(text)
    
    def _save_script(self):
        filename, _ = QFileDialog.getSaveFileName(
            self, "保存脚本", "script.json",
            "JSON (*.json);;Python (*.py)"
        )
        if filename:
            if filename.endswith('.py'):
                with open(filename, 'w', encoding='utf-8') as f:
                    f.write(self._generate_python_code())
            else:
                with open(filename, 'w', encoding='utf-8') as f:
                    json.dump(self.recorded_actions, f, indent=2, ensure_ascii=False)
            QMessageBox.information(self, "保存成功", f"脚本已保存到:\n{filename}")
    
    def _load_script(self):
        filename, _ = QFileDialog.getOpenFileName(
            self, "加载脚本", "",
            "JSON (*.json);;所有文件 (*.*)"
        )
        if filename:
            with open(filename, 'r', encoding='utf-8') as f:
                self.recorded_actions = json.load(f)
            self._update_script_display()
    
    def _generate_python(self):
        code = self._generate_python_code()
        
        dialog = QMessageBox(self)
        dialog.setWindowTitle("Python 代码")
        dialog.setText("代码已生成，请查看详情")
        dialog.setDetailedText(code)
        dialog.exec_()
    
    def _generate_python_code(self) -> str:
        lines = [
            '#!/usr/bin/env python3',
            '"""自动生成的脚本"""',
            '',
            'from ecwda import ECWDA',
            'import time',
            '',
            'def main():',
            '    ec = ECWDA("http://localhost:10088")',
            '    if not ec.is_connected():',
            '        print("连接失败")',
            '        return',
            '    ',
            '    ec.create_session()',
            '    '
        ]
        
        for action in self.recorded_actions:
            if action['action'] == 'tap':
                p = action['params']
                lines.append(f'    ec.click({p["x"]}, {p["y"]})')
            elif action['action'] == 'longPress':
                p = action['params']
                lines.append(f'    ec.long_click({p["x"]}, {p["y"]}, {p.get("duration", 1)})')
            elif action['action'] == 'doubleTap':
                p = action['params']
                lines.append(f'    ec.double_click({p["x"]}, {p["y"]})')
            elif action['action'] == 'swipe':
                p = action['params']
                lines.append(f'    ec.swipe({p["fromX"]}, {p["fromY"]}, {p["toX"]}, {p["toY"]})')
            elif action['action'] == 'sleep':
                lines.append(f'    time.sleep({action["params"]["seconds"]})')
            elif action['action'] == 'home':
                lines.append('    ec.home()')
            elif action['action'] == 'swipe_up':
                lines.append('    ec.swipe_up()')
            elif action['action'] == 'swipe_down':
                lines.append('    ec.swipe_down()')
        
        lines.extend([
            '    ',
            '    print("脚本执行完成")',
            '',
            'if __name__ == "__main__":',
            '    main()'
        ])
        
        return '\n'.join(lines)
    
    def _generate_json(self):
        json_str = json.dumps(self.recorded_actions, indent=2, ensure_ascii=False)
        
        dialog = QMessageBox(self)
        dialog.setWindowTitle("JSON 脚本")
        dialog.setText("脚本已生成，请查看详情")
        dialog.setDetailedText(json_str)
        dialog.exec_()
    
    def _send_to_device(self):
        """发送脚本到设备执行 (需要 WDA 支持 /wda/script/execute 端点)"""
        if not self.ec:
            QMessageBox.warning(self, "未连接", "请先连接设备")
            return
        
        # 优先使用文本框中的脚本
        script_content = self.script_text.toPlainText().strip()
        
        if script_content:
            try:
                # 尝试解析 JSON 脚本
                actions = json.loads(script_content)
                if isinstance(actions, list):
                    result = self.ec.execute_script(actions)
                    QMessageBox.information(self, "发送成功", 
                        f"脚本已发送到设备执行\n共 {len(actions)} 个动作\n{json.dumps(result, ensure_ascii=False)}")
                    return
            except json.JSONDecodeError:
                # 不是有效的 JSON，尝试解析为编号格式
                pass
        
        # 使用录制的动作
        if self.recorded_actions:
            result = self.ec.execute_script(self.recorded_actions)
            QMessageBox.information(self, "发送成功", 
                f"脚本已发送到设备\n{json.dumps(result, ensure_ascii=False)}")
        else:
            QMessageBox.warning(self, "无脚本", 
                "请录制脚本或在文本框中输入 JSON 格式的脚本")
    
    def _execute_script_locally(self):
        """在本地执行脚本 (通过 Python 逐条执行)"""
        if not self.ec:
            QMessageBox.warning(self, "未连接", "请先连接设备")
            return
        
        # 获取要执行的脚本
        actions = []
        script_content = self.script_text.toPlainText().strip()
        
        if script_content:
            try:
                actions = json.loads(script_content)
                if not isinstance(actions, list):
                    actions = []
            except json.JSONDecodeError:
                pass
        
        if not actions and self.recorded_actions:
            actions = self.recorded_actions
        
        if not actions:
            QMessageBox.warning(self, "无脚本", 
                "请录制脚本或在文本框中输入 JSON 格式的脚本")
            return
        
        # 在后台线程执行
        def run_script():
            for i, action in enumerate(actions):
                try:
                    act_type = action.get('action', '')
                    params = action.get('params', {})
                    
                    if act_type == 'tap':
                        self.ec.click(params.get('x', 0), params.get('y', 0))
                    elif act_type == 'longPress':
                        self.ec.long_click(params.get('x', 0), params.get('y', 0), params.get('duration', 1))
                    elif act_type == 'doubleTap':
                        self.ec.double_click(params.get('x', 0), params.get('y', 0))
                    elif act_type == 'swipe':
                        self.ec.swipe(
                            params.get('fromX', 0), params.get('fromY', 0),
                            params.get('toX', 0), params.get('toY', 0),
                            params.get('duration', 0.3)
                        )
                    elif act_type == 'sleep':
                        time.sleep(params.get('seconds', 1))
                    elif act_type == 'home':
                        self.ec.home()
                    elif act_type == 'swipe_up':
                        self.ec.swipe_up()
                    elif act_type == 'swipe_down':
                        self.ec.swipe_down()
                    elif act_type == 'swipe_left':
                        self.ec.swipe_left()
                    elif act_type == 'swipe_right':
                        self.ec.swipe_right()
                    elif act_type == 'trajectory':
                        # 长轨迹滑动
                        points = params.get('points', [])
                        for j in range(len(points) - 1):
                            from_x, from_y = points[j]
                            to_x, to_y = points[j + 1]
                            self.ec.swipe(from_x, from_y, to_x, to_y, 0.05)
                            time.sleep(0.02)
                except Exception as e:
                    print(f"执行动作 {i+1} 失败: {e}")
        
        threading.Thread(target=run_script, daemon=True).start()
        QMessageBox.information(self, "开始执行", f"脚本开始在本地执行\n共 {len(actions)} 个动作")
    
    def closeEvent(self, event):
        self.running = False
        event.accept()


def main():
    app = QApplication(sys.argv)
    window = ScriptGeneratorQt()
    window.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
