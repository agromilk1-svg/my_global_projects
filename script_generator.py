#!/usr/bin/env python3
"""
ECWDA 脚本生成器
类似按键精灵的脚本录制和控制工具

功能：
1. 实时屏幕投屏
2. 鼠标点击/滑动控制
3. 获取坐标和颜色信息
4. 录制操作脚本
5. 脚本回放执行
"""

import tkinter as tk
from tkinter import ttk, scrolledtext, filedialog, messagebox
import threading
import time
import json
import base64
import io
from datetime import datetime
from typing import Optional, Dict, List, Tuple

try:
    from PIL import Image, ImageTk, ImageDraw, ImageFont
except ImportError:
    print("请安装 Pillow: pip install Pillow")
    exit(1)

from ecwda import ECWDA


class ScriptGenerator:
    """脚本生成器主界面"""
    
    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("ECWDA 脚本生成器 v1.0")
        self.root.geometry("1400x900")
        
        # ECWDA 客户端
        self.ec: Optional[ECWDA] = None
        self.connected = False
        
        # 屏幕状态
        self.current_image: Optional[Image.Image] = None
        self.display_image: Optional[ImageTk.PhotoImage] = None
        self.scale_factor = 1.0
        self.screen_width = 375
        self.screen_height = 667
        
        # 录制状态
        self.recording = False
        self.recorded_actions: List[Dict] = []
        self.last_action_time = 0
        
        # 拾取模式
        self.pick_mode = None  # None, 'color', 'position', 'multicolor'
        self.multi_color_points: List[Dict] = []
        
        # 投屏线程
        self.screen_thread: Optional[threading.Thread] = None
        self.running = False
        self.fps = 5
        
        # 创建界面
        self._create_ui()
        
    def _create_ui(self):
        """创建用户界面"""
        # 主框架
        main_frame = ttk.Frame(self.root)
        main_frame.pack(fill=tk.BOTH, expand=True, padx=5, pady=5)
        
        # 左侧：屏幕显示
        left_frame = ttk.LabelFrame(main_frame, text="屏幕", padding=5)
        left_frame.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        
        # 屏幕画布
        self.canvas = tk.Canvas(left_frame, bg='#1a1a1a', width=400, height=700)
        self.canvas.pack(fill=tk.BOTH, expand=True)
        self.canvas.bind('<Button-1>', self._on_canvas_click)
        self.canvas.bind('<B1-Motion>', self._on_canvas_drag)
        self.canvas.bind('<ButtonRelease-1>', self._on_canvas_release)
        self.canvas.bind('<Motion>', self._on_mouse_move)
        self.canvas.bind('<Button-3>', self._on_right_click)  # 右键菜单
        
        # 拖动状态
        self.drag_start = None
        
        # 右侧：控制面板
        right_frame = ttk.Frame(main_frame, width=500)
        right_frame.pack(side=tk.RIGHT, fill=tk.BOTH, padx=(5, 0))
        right_frame.pack_propagate(False)
        
        # 连接区域
        conn_frame = ttk.LabelFrame(right_frame, text="连接", padding=5)
        conn_frame.pack(fill=tk.X, pady=(0, 5))
        
        ttk.Label(conn_frame, text="WDA 地址:").pack(side=tk.LEFT)
        self.url_var = tk.StringVar(value="http://localhost:8100")
        self.url_entry = ttk.Entry(conn_frame, textvariable=self.url_var, width=30)
        self.url_entry.pack(side=tk.LEFT, padx=5)
        
        self.connect_btn = ttk.Button(conn_frame, text="连接", command=self._toggle_connection)
        self.connect_btn.pack(side=tk.LEFT, padx=5)
        
        self.status_label = ttk.Label(conn_frame, text="未连接", foreground='red')
        self.status_label.pack(side=tk.LEFT, padx=5)
        
        # 信息显示区域
        info_frame = ttk.LabelFrame(right_frame, text="信息", padding=5)
        info_frame.pack(fill=tk.X, pady=(0, 5))
        
        # 坐标显示
        coord_frame = ttk.Frame(info_frame)
        coord_frame.pack(fill=tk.X)
        
        ttk.Label(coord_frame, text="坐标:").pack(side=tk.LEFT)
        self.coord_var = tk.StringVar(value="X: 0, Y: 0")
        ttk.Label(coord_frame, textvariable=self.coord_var, font=('Consolas', 10)).pack(side=tk.LEFT, padx=10)
        
        ttk.Button(coord_frame, text="复制坐标", command=self._copy_coord).pack(side=tk.RIGHT)
        
        # 颜色显示
        color_frame = ttk.Frame(info_frame)
        color_frame.pack(fill=tk.X, pady=(5, 0))
        
        ttk.Label(color_frame, text="颜色:").pack(side=tk.LEFT)
        self.color_var = tk.StringVar(value="#000000")
        ttk.Label(color_frame, textvariable=self.color_var, font=('Consolas', 10)).pack(side=tk.LEFT, padx=10)
        
        self.color_preview = tk.Label(color_frame, width=4, bg='black', relief='sunken')
        self.color_preview.pack(side=tk.LEFT, padx=5)
        
        ttk.Button(color_frame, text="复制颜色", command=self._copy_color).pack(side=tk.RIGHT)
        
        # 工具区域
        tool_frame = ttk.LabelFrame(right_frame, text="工具", padding=5)
        tool_frame.pack(fill=tk.X, pady=(0, 5))
        
        tool_row1 = ttk.Frame(tool_frame)
        tool_row1.pack(fill=tk.X)
        
        ttk.Button(tool_row1, text="📷 截图", command=self._save_screenshot).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row1, text="🎨 拾取颜色", command=self._start_pick_color).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row1, text="📍 拾取坐标", command=self._start_pick_position).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row1, text="🌈 多点找色", command=self._start_pick_multicolor).pack(side=tk.LEFT, padx=2)
        
        tool_row2 = ttk.Frame(tool_frame)
        tool_row2.pack(fill=tk.X, pady=(5, 0))
        
        ttk.Button(tool_row2, text="🏠 主屏幕", command=self._go_home).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row2, text="↑ 上滑", command=lambda: self._swipe('up')).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row2, text="↓ 下滑", command=lambda: self._swipe('down')).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row2, text="← 左滑", command=lambda: self._swipe('left')).pack(side=tk.LEFT, padx=2)
        ttk.Button(tool_row2, text="→ 右滑", command=lambda: self._swipe('right')).pack(side=tk.LEFT, padx=2)
        
        # 录制区域
        record_frame = ttk.LabelFrame(right_frame, text="录制", padding=5)
        record_frame.pack(fill=tk.X, pady=(0, 5))
        
        record_btn_frame = ttk.Frame(record_frame)
        record_btn_frame.pack(fill=tk.X)
        
        self.record_btn = ttk.Button(record_btn_frame, text="⏺ 开始录制", command=self._toggle_recording)
        self.record_btn.pack(side=tk.LEFT, padx=2)
        
        ttk.Button(record_btn_frame, text="🗑 清空", command=self._clear_recording).pack(side=tk.LEFT, padx=2)
        ttk.Button(record_btn_frame, text="▶ 回放", command=self._playback).pack(side=tk.LEFT, padx=2)
        ttk.Button(record_btn_frame, text="💾 保存", command=self._save_script).pack(side=tk.LEFT, padx=2)
        ttk.Button(record_btn_frame, text="📂 加载", command=self._load_script).pack(side=tk.LEFT, padx=2)
        
        self.record_status = ttk.Label(record_frame, text="未录制")
        self.record_status.pack(fill=tk.X, pady=(5, 0))
        
        # 手动添加动作
        add_frame = ttk.LabelFrame(right_frame, text="添加动作", padding=5)
        add_frame.pack(fill=tk.X, pady=(0, 5))
        
        # 动作类型
        action_row1 = ttk.Frame(add_frame)
        action_row1.pack(fill=tk.X)
        
        ttk.Label(action_row1, text="类型:").pack(side=tk.LEFT)
        self.action_type = ttk.Combobox(action_row1, values=['tap', 'longPress', 'doubleTap', 'swipe', 'sleep', 'home'], width=12)
        self.action_type.set('tap')
        self.action_type.pack(side=tk.LEFT, padx=5)
        
        ttk.Label(action_row1, text="X:").pack(side=tk.LEFT)
        self.action_x = ttk.Entry(action_row1, width=6)
        self.action_x.pack(side=tk.LEFT, padx=2)
        
        ttk.Label(action_row1, text="Y:").pack(side=tk.LEFT)
        self.action_y = ttk.Entry(action_row1, width=6)
        self.action_y.pack(side=tk.LEFT, padx=2)
        
        ttk.Button(action_row1, text="添加", command=self._add_action).pack(side=tk.LEFT, padx=5)
        
        # 脚本编辑区域
        script_frame = ttk.LabelFrame(right_frame, text="脚本", padding=5)
        script_frame.pack(fill=tk.BOTH, expand=True)
        
        self.script_text = scrolledtext.ScrolledText(script_frame, height=15, font=('Consolas', 9))
        self.script_text.pack(fill=tk.BOTH, expand=True)
        
        # 底部按钮
        bottom_frame = ttk.Frame(right_frame)
        bottom_frame.pack(fill=tk.X, pady=(5, 0))
        
        ttk.Button(bottom_frame, text="生成 Python 代码", command=self._generate_python).pack(side=tk.LEFT, padx=2)
        ttk.Button(bottom_frame, text="生成 JSON 脚本", command=self._generate_json).pack(side=tk.LEFT, padx=2)
        ttk.Button(bottom_frame, text="发送到设备执行", command=self._send_to_device).pack(side=tk.RIGHT, padx=2)
        
        # 绑定关闭事件
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)
    
    def _toggle_connection(self):
        """切换连接状态"""
        if self.connected:
            self._disconnect()
        else:
            self._connect()
    
    def _connect(self):
        """连接设备"""
        url = self.url_var.get()
        self.ec = ECWDA(url)
        
        if self.ec.is_connected():
            self.connected = True
            self.connect_btn.config(text="断开")
            self.status_label.config(text="已连接", foreground='green')
            
            # 获取屏幕尺寸
            self.ec.create_session()
            self.screen_width, self.screen_height = self.ec.get_screen_size()
            
            # 启动投屏
            self._start_screen_capture()
        else:
            messagebox.showerror("连接失败", "无法连接到 WDA，请检查:\n1. WDA 是否在运行\n2. 端口转发: tidevice relay 8100 8100")
    
    def _disconnect(self):
        """断开连接"""
        self.running = False
        self.connected = False
        self.connect_btn.config(text="连接")
        self.status_label.config(text="未连接", foreground='red')
    
    def _start_screen_capture(self):
        """启动屏幕捕获"""
        self.running = True
        self.screen_thread = threading.Thread(target=self._capture_loop, daemon=True)
        self.screen_thread.start()
    
    def _capture_loop(self):
        """屏幕捕获循环"""
        while self.running:
            try:
                img_base64 = self.ec.screenshot()
                if img_base64:
                    img_data = base64.b64decode(img_base64)
                    self.current_image = Image.open(io.BytesIO(img_data))
                    
                    # 更新显示
                    self.root.after(0, self._update_display)
                
                time.sleep(1.0 / self.fps)
            except Exception as e:
                print(f"截图错误: {e}")
                time.sleep(1)
    
    def _update_display(self):
        """更新屏幕显示"""
        if not self.current_image:
            return
        
        # 计算缩放比例
        canvas_width = self.canvas.winfo_width()
        canvas_height = self.canvas.winfo_height()
        
        img_width, img_height = self.current_image.size
        
        scale_w = canvas_width / img_width
        scale_h = canvas_height / img_height
        self.scale_factor = min(scale_w, scale_h, 1.0)
        
        # 缩放图片
        new_width = int(img_width * self.scale_factor)
        new_height = int(img_height * self.scale_factor)
        
        resized = self.current_image.resize((new_width, new_height), Image.Resampling.LANCZOS)
        self.display_image = ImageTk.PhotoImage(resized)
        
        # 居中显示
        x = (canvas_width - new_width) // 2
        y = (canvas_height - new_height) // 2
        
        self.canvas.delete("all")
        self.canvas.create_image(x, y, anchor=tk.NW, image=self.display_image)
        
        # 存储偏移量
        self.display_offset = (x, y)
        self.display_size = (new_width, new_height)
    
    def _canvas_to_device(self, canvas_x: int, canvas_y: int) -> Tuple[int, int]:
        """画布坐标转设备坐标"""
        if not hasattr(self, 'display_offset'):
            return (0, 0)
        
        offset_x, offset_y = self.display_offset
        
        # 计算相对于图片的坐标
        rel_x = canvas_x - offset_x
        rel_y = canvas_y - offset_y
        
        # 转换为设备坐标
        device_x = int(rel_x / self.scale_factor)
        device_y = int(rel_y / self.scale_factor)
        
        return (device_x, device_y)
    
    def _on_mouse_move(self, event):
        """鼠标移动事件"""
        device_x, device_y = self._canvas_to_device(event.x, event.y)
        self.coord_var.set(f"X: {device_x}, Y: {device_y}")
        
        # 更新颜色
        if self.current_image:
            try:
                if 0 <= device_x < self.current_image.width and 0 <= device_y < self.current_image.height:
                    pixel = self.current_image.getpixel((device_x, device_y))
                    if len(pixel) >= 3:
                        color = f"#{pixel[0]:02X}{pixel[1]:02X}{pixel[2]:02X}"
                        self.color_var.set(color)
                        self.color_preview.config(bg=color)
            except:
                pass
        
        # 存储当前坐标
        self.current_x = device_x
        self.current_y = device_y
    
    def _on_canvas_click(self, event):
        """画布点击事件"""
        device_x, device_y = self._canvas_to_device(event.x, event.y)
        self.drag_start = (device_x, device_y)
        
        # 拾取模式
        if self.pick_mode == 'color':
            color = self.color_var.get()
            self._add_to_script(f"# 颜色: {color} 位置: ({device_x}, {device_y})")
            self.pick_mode = None
            
        elif self.pick_mode == 'position':
            self._add_to_script(f"# 坐标: ({device_x}, {device_y})")
            self.pick_mode = None
            
        elif self.pick_mode == 'multicolor':
            color = self.color_var.get()
            if len(self.multi_color_points) == 0:
                # 第一个点
                self.multi_color_points.append({
                    'x': device_x, 'y': device_y, 'color': color, 'offset': [0, 0]
                })
                messagebox.showinfo("多点找色", f"已添加第 1 个点\n颜色: {color}\n继续点击添加更多点，右键结束")
            else:
                # 偏移点
                first = self.multi_color_points[0]
                offset_x = device_x - first['x']
                offset_y = device_y - first['y']
                self.multi_color_points.append({
                    'x': device_x, 'y': device_y, 'color': color, 'offset': [offset_x, offset_y]
                })
                messagebox.showinfo("多点找色", f"已添加第 {len(self.multi_color_points)} 个点\n偏移: [{offset_x}, {offset_y}]\n颜色: {color}")
    
    def _on_canvas_drag(self, event):
        """画布拖动事件"""
        pass  # 暂不处理
    
    def _on_canvas_release(self, event):
        """画布释放事件"""
        if not self.connected or not self.ec:
            return
        
        if self.pick_mode:
            return  # 拾取模式不触发点击
        
        device_x, device_y = self._canvas_to_device(event.x, event.y)
        
        if self.drag_start:
            start_x, start_y = self.drag_start
            
            # 判断是点击还是滑动
            dx = abs(device_x - start_x)
            dy = abs(device_y - start_y)
            
            if dx < 10 and dy < 10:
                # 点击
                self.ec.click(start_x, start_y)
                if self.recording:
                    self._record_action({'action': 'tap', 'params': {'x': start_x, 'y': start_y}})
            else:
                # 滑动
                self.ec.swipe(start_x, start_y, device_x, device_y, 0.3)
                if self.recording:
                    self._record_action({
                        'action': 'swipe',
                        'params': {'fromX': start_x, 'fromY': start_y, 'toX': device_x, 'toY': device_y}
                    })
        
        self.drag_start = None
    
    def _on_right_click(self, event):
        """右键点击"""
        if self.pick_mode == 'multicolor' and len(self.multi_color_points) > 0:
            # 结束多点找色
            self._finish_multicolor()
    
    def _finish_multicolor(self):
        """完成多点找色"""
        if len(self.multi_color_points) < 2:
            messagebox.showwarning("多点找色", "至少需要 2 个点")
            return
        
        first = self.multi_color_points[0]
        offsets = []
        for i, p in enumerate(self.multi_color_points[1:], 1):
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
        """复制坐标"""
        coord = f"({self.current_x}, {self.current_y})"
        self.root.clipboard_clear()
        self.root.clipboard_append(coord)
    
    def _copy_color(self):
        """复制颜色"""
        color = self.color_var.get()
        self.root.clipboard_clear()
        self.root.clipboard_append(color)
    
    def _save_screenshot(self):
        """保存截图"""
        if self.current_image:
            filename = filedialog.asksaveasfilename(
                defaultextension=".png",
                filetypes=[("PNG", "*.png"), ("JPEG", "*.jpg")],
                initialfile=f"screenshot_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
            )
            if filename:
                self.current_image.save(filename)
                messagebox.showinfo("保存成功", f"截图已保存到:\n{filename}")
    
    def _start_pick_color(self):
        """开始拾取颜色"""
        self.pick_mode = 'color'
        messagebox.showinfo("拾取颜色", "点击屏幕上的位置获取颜色")
    
    def _start_pick_position(self):
        """开始拾取坐标"""
        self.pick_mode = 'position'
        messagebox.showinfo("拾取坐标", "点击屏幕上的位置获取坐标")
    
    def _start_pick_multicolor(self):
        """开始多点找色"""
        self.pick_mode = 'multicolor'
        self.multi_color_points = []
        messagebox.showinfo("多点找色", "点击第一个颜色点（基准点），然后点击其他偏移点。\n右键结束拾取。")
    
    def _go_home(self):
        """返回主屏幕"""
        if self.ec:
            self.ec.home()
            if self.recording:
                self._record_action({'action': 'home', 'params': {}})
    
    def _swipe(self, direction: str):
        """滑动"""
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
        """切换录制状态"""
        self.recording = not self.recording
        if self.recording:
            self.record_btn.config(text="⏹ 停止录制")
            self.record_status.config(text="🔴 正在录制...", foreground='red')
            self.last_action_time = time.time()
        else:
            self.record_btn.config(text="⏺ 开始录制")
            self.record_status.config(text=f"已录制 {len(self.recorded_actions)} 个动作", foreground='black')
    
    def _record_action(self, action: Dict):
        """录制动作"""
        # 添加延迟
        now = time.time()
        if self.last_action_time > 0:
            delay = now - self.last_action_time
            if delay > 0.1:  # 超过 100ms 才记录延迟
                self.recorded_actions.append({
                    'action': 'sleep',
                    'params': {'seconds': round(delay, 2)}
                })
        
        self.recorded_actions.append(action)
        self.last_action_time = now
        
        # 更新显示
        self._update_script_display()
    
    def _update_script_display(self):
        """更新脚本显示"""
        self.script_text.delete(1.0, tk.END)
        for i, action in enumerate(self.recorded_actions, 1):
            self.script_text.insert(tk.END, f"{i}. {json.dumps(action, ensure_ascii=False)}\n")
    
    def _clear_recording(self):
        """清空录制"""
        self.recorded_actions = []
        self.script_text.delete(1.0, tk.END)
        self.record_status.config(text="已清空", foreground='black')
    
    def _playback(self):
        """回放脚本"""
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
        """手动添加动作"""
        action_type = self.action_type.get()
        x = self.action_x.get()
        y = self.action_y.get()
        
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
        """添加文本到脚本"""
        self.script_text.insert(tk.END, text + "\n")
    
    def _save_script(self):
        """保存脚本"""
        filename = filedialog.asksaveasfilename(
            defaultextension=".json",
            filetypes=[("JSON", "*.json"), ("Python", "*.py")],
            initialfile="script.json"
        )
        if filename:
            if filename.endswith('.py'):
                with open(filename, 'w', encoding='utf-8') as f:
                    f.write(self._generate_python_code())
            else:
                with open(filename, 'w', encoding='utf-8') as f:
                    json.dump(self.recorded_actions, f, indent=2, ensure_ascii=False)
            messagebox.showinfo("保存成功", f"脚本已保存到:\n{filename}")
    
    def _load_script(self):
        """加载脚本"""
        filename = filedialog.askopenfilename(
            filetypes=[("JSON", "*.json"), ("所有文件", "*.*")]
        )
        if filename:
            with open(filename, 'r', encoding='utf-8') as f:
                self.recorded_actions = json.load(f)
            self._update_script_display()
    
    def _generate_python(self):
        """生成 Python 代码"""
        code = self._generate_python_code()
        
        # 显示在新窗口
        win = tk.Toplevel(self.root)
        win.title("Python 代码")
        win.geometry("600x500")
        
        text = scrolledtext.ScrolledText(win, font=('Consolas', 10))
        text.pack(fill=tk.BOTH, expand=True)
        text.insert(tk.END, code)
    
    def _generate_python_code(self) -> str:
        """生成 Python 代码"""
        lines = [
            '#!/usr/bin/env python3',
            '"""自动生成的脚本"""',
            '',
            'from ecwda import ECWDA',
            'import time',
            '',
            'def main():',
            '    ec = ECWDA("http://localhost:8100")',
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
        """生成 JSON 脚本"""
        json_str = json.dumps(self.recorded_actions, indent=2, ensure_ascii=False)
        
        # 显示在新窗口
        win = tk.Toplevel(self.root)
        win.title("JSON 脚本")
        win.geometry("500x400")
        
        text = scrolledtext.ScrolledText(win, font=('Consolas', 10))
        text.pack(fill=tk.BOTH, expand=True)
        text.insert(tk.END, json_str)
    
    def _send_to_device(self):
        """发送到设备执行（脱机模式）"""
        if not self.ec or not self.recorded_actions:
            return
        
        result = self.ec.execute_script(self.recorded_actions)
        messagebox.showinfo("发送成功", f"脚本已发送到设备\n{json.dumps(result, ensure_ascii=False)}")
    
    def _on_close(self):
        """关闭窗口"""
        self.running = False
        self.root.destroy()


def main():
    root = tk.Tk()
    app = ScriptGenerator(root)
    root.mainloop()


if __name__ == "__main__":
    main()
