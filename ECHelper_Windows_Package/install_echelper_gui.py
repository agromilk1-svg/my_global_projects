import sys
import os
import time
import traceback
import logging
import platform
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                             QHBoxLayout, QPushButton, QTextEdit, QLabel, QProgressBar)
from PyQt5.QtCore import QThread, pyqtSignal, Qt
from PyQt5.QtGui import QFont, QTextCursor, QIcon

# 跨平台字体选择
def _get_ui_font():
    """根据操作系统返回最佳中文字体名称"""
    s = platform.system()
    if s == "Darwin":
        return "PingFang SC"
    elif s == "Windows":
        return "Microsoft YaHei"
    return "Noto Sans CJK SC"

UI_FONT = _get_ui_font()

# 配置全局日志文件
log_file = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "log.log")
logging.basicConfig(
    filename=log_file,
    level=logging.ERROR,
    format='%(asctime)s - %(levelname)s - %(message)s',
    encoding='utf-8'
)

# 拦截所有未处理异常，防止 GUI 闪退后无报错信息
def global_exception_handler(exctype, value, tb):
    err_msg = "".join(traceback.format_exception(exctype, value, tb))
    logging.error(f"【全局未捕获异常】\n{err_msg}")
    sys.__excepthook__(exctype, value, tb)
sys.excepthook = global_exception_handler

# 确保能找到内部模块
from pathlib import Path
def get_resource_path(relative_path: str) -> Path:
    if hasattr(sys, '_MEIPASS'):
        return Path(os.path.join(sys._MEIPASS, relative_path))
    else:
        return Path(relative_path).absolute()
sys.path.append(str(get_resource_path("installer")))

# 导入 pymobiledevice3 检测设备
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.exceptions import NoDeviceConnectedError
from packaging.version import parse as parse_version

# 导入静默安装核心
import install_echelper

class StreamRedirector:
    def __init__(self, signal):
        self.signal = signal

    def write(self, text):
        if isinstance(text, bytes):
            text = text.decode('utf-8', errors='replace')
        else:
            text = str(text)
            
        if text.strip() or text == '\n':
            self.signal.emit(text)

    def flush(self):
        pass

class DeviceMonitorThread(QThread):
    device_connected = pyqtSignal(str, str, str, str) # name, version, build, udid
    device_disconnected = pyqtSignal()
    log_signal = pyqtSignal(str)

    def run(self):
        os_names = {
            "iPhone": "iOS", "iPad": "iPadOS", "iPod": "iOS",
            "AppleTV": "tvOS", "Watch": "watchOS",
            "AudioAccessory": "HomePod Software", "RealityDevice": "visionOS"
        }
        last_state = False
        last_error_time = 0
        last_error_msg = ""
        while True:
            try:
                service_provider = create_using_usbmux()
                device_class = service_provider.get_value(key="DeviceClass")
                device_build = service_provider.get_value(key="BuildVersion")
                device_version = service_provider.product_version
                device_udid = service_provider.get_value(key="UniqueDeviceID")
                
                os_name = os_names.get(device_class, "Unknown OS")
                
                if not last_state:
                    self.device_connected.emit(os_name, device_version, device_build, device_udid)
                    last_state = True
            except Exception as e:
                err_str = str(e)
                # 过滤掉常见的未连接错误
                if not isinstance(e, NoDeviceConnectedError):
                    # 防刷屏处理 (如果是相同的错误，5 秒内不重复打印)
                    current_time = time.time()
                    if err_str != last_error_msg or (current_time - last_error_time > 5):
                        last_error_msg = err_str
                        last_error_time = current_time
                        
                        if "MuxException" in type(e).__name__ or "183" in err_str:
                            self.log_signal.emit("⚠️ 【连接异常】设备未就绪。请尝试：\n1. 解锁手机并在此电脑上点击“信任”\n2. 拔下数据线后重新插入电脑 USB 接口\n3. 如果还是不行，请重启电脑上的 Apple Mobile Device Service (或者 iTunes)。")
                        else:
                            self.log_signal.emit(f"[USB 监控线程异常] {type(e).__name__}: {e}")
                            logging.error(f"监控线程崩毁: {traceback.format_exc()}")
                
                if last_state:
                    self.device_disconnected.emit()
                    last_state = False
            time.sleep(1.5)

class InstallerThread(QThread):
    log_signal = pyqtSignal(str)
    finished_signal = pyqtSignal(bool) # True if success
    
    def run(self):
        # 劫持系统输出
        old_stdout = sys.stdout
        old_stderr = sys.stderr
        sys.stdout = StreamRedirector(self.log_signal)
        sys.stderr = StreamRedirector(self.log_signal)
        
        # 劫持 click confirm，默认同意
        import click
        original_confirm = click.confirm
        click.confirm = lambda text, default=False: True
        
        success = False
        try:
            # 建立一个虚拟的 Click 环境上下文，避免在独立线程中报错 No active click context
            ctx = install_echelper.cli.make_context("install_echelper", [])
            with ctx:
                install_echelper.cli.invoke(ctx)
            success = True
        except SystemExit as e:
            if e.code == 0:
                success = True
            else:
                logging.error(f"安装过程退出状态异常 (code: {e.code})")
        except Exception as e:
            err_msg = traceback.format_exc()
            logging.error(f"一键安装 ECHelper 崩溃:\n{err_msg}")
            self.log_signal.emit(f"安装过程发生异常: {str(e)}")
            self.log_signal.emit(err_msg)
        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr
            click.confirm = original_confirm
            self.finished_signal.emit(success)

class LaunchEcwdaThread(QThread):
    log_signal = pyqtSignal(str)
    finished_signal = pyqtSignal()

    def __init__(self, udid):
        super().__init__()
        self.udid = udid

    def _find_tidevice(self):
        """在系统 PATH 和常见 Python 安装目录中搜索 tidevice 可执行文件"""
        import shutil
        import glob
        
        # 第一优先级：直接从系统 PATH 查找
        t_path = shutil.which("tidevice")
        if t_path:
            return t_path
        
        # 第二优先级：macOS / Linux 常见的 Python 用户 Bin 目录
        home = os.path.expanduser("~")
        candidate_patterns = [
            os.path.join(home, "Library", "Python", "*", "bin", "tidevice"),  # macOS pip --user
            os.path.join(home, ".local", "bin", "tidevice"),                  # Linux pip --user
            "/usr/local/bin/tidevice",                                        # Homebrew / 系统级 pip
            "/opt/homebrew/bin/tidevice",                                     # Apple Silicon Homebrew
        ]
        for pattern in candidate_patterns:
            matches = glob.glob(pattern)
            for match in matches:
                if os.path.isfile(match) and os.access(match, os.X_OK):
                    return match
        
        return None

    def run(self):
        self.log_signal.emit("🚀 正在组织环境准备启动 ECWDA 底核...")
        import platform
        import shutil
        import subprocess
        
        t_path = self._find_tidevice()
        if not t_path:
            self.log_signal.emit("❌ 未在系统 PATH 中找到 tidevice 命令行工具，请确保已安装潮汐通道！(pip install tidevice)")
            return
        self.log_signal.emit(f"✅ 已定位 tidevice 工具: {t_path}")

        # --- 自动释放内嵌 DeviceSupport 资源 ---
        try:
            target_ds_dir = os.path.expanduser("~/.tidevice/device-support")
            os.makedirs(target_ds_dir, exist_ok=True)
            
            src_ds_dir = get_resource_path("device-support")
            if src_ds_dir.exists():
                import shutil
                # 遍历内嵌目录，若目标目录缺失则复制
                has_deployed = False
                for item in os.listdir(str(src_ds_dir)):
                    s_item = src_ds_dir / item
                    d_item = os.path.join(target_ds_dir, item)
                    if not os.path.exists(d_item):
                        if s_item.is_dir():
                            shutil.copytree(str(s_item), d_item)
                        else:
                            shutil.copy2(str(s_item), d_item)
                        has_deployed = True
                if has_deployed:
                    self.log_signal.emit("📦 已从内嵌资源库释放最新 DeviceSupport 镜像文件")
            else:
                self.log_signal.emit("⚠️ 未发现内嵌 DeviceSupport 资源，将尝试联网同步...")
        except Exception as e:
            self.log_signal.emit(f"⚠️ 预部署内嵌资源时发生异常: {e}")
        # --------------------------------------
            
        try:
            if platform.system() == "Windows":
                subprocess.run(["taskkill", "/F", "/IM", "tidevice.exe"], capture_output=True)
            else:
                subprocess.run(["pkill", "-f", "tidevice"], capture_output=True)
            self.log_signal.emit("✅ 旧残留守护进程已清场")
        except Exception:
            pass
            
        time.sleep(1)
        self.log_signal.emit(f"🚀 发送穿透启动指令 (UDID: {self.udid[:8]})...")
        cmd_wda = [t_path, "-u", self.udid, "launch", "com.facebook.WebDriverAgentRunner.ecwda"]
        
        creationflags = 0
        if hasattr(subprocess, 'CREATE_NO_WINDOW'):
            creationflags = subprocess.CREATE_NO_WINDOW
            
        try:
            wda_proc = subprocess.Popen(
                cmd_wda, 
                creationflags=creationflags,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT
            )
            
            # 启动一个线程专门读取 wda_proc 的输出并打印到日志中
            import threading
            def read_wda_output(proc):
                try:
                    for line in iter(proc.stdout.readline, b''):
                        try:
                            # 尝试解码，忽略错误
                            text = line.decode('utf-8', errors='ignore').strip()
                            if text:
                                self.log_signal.emit(f"[WDA] {text}")
                        except Exception:
                            pass
                except Exception:
                    pass
            
            threading.Thread(target=read_wda_output, args=(wda_proc,), daemon=True).start()
            
            self.log_signal.emit(f"✅ 主核进程已唤醒潜渡 (PID: {wda_proc.pid})")
            
            for port in ["10088", "10089", "8089"]:
                cmd_relay = [t_path, "-u", self.udid, "relay", port, port]
                r_proc = subprocess.Popen(
                    cmd_relay, 
                    creationflags=creationflags,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL
                )
                self.log_signal.emit(f"✅ 端口全双工映射 {port}:{port} 已挂载 (PID: {r_proc.pid})")
                
            self.log_signal.emit("🎉 ECWDA 全链舰队（主核+双重中继）已成功发射并幽灵部署于后台！")
        except Exception as e:
            err_msg = traceback.format_exc()
            logging.error(f"启动 ECWDA 崩溃:\n{err_msg}")
            self.log_signal.emit(f"❌ 启动受挫故障: {e}")
        finally:
            self.finished_signal.emit()

class ECHelperGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.current_udid = None
        self.init_ui()
        self.start_monitoring()

    def init_ui(self):
        self.setWindowTitle("ECHelper 界面安装器")
        self.resize(700, 500)
        self.setStyleSheet("QMainWindow {background-color: #f5f6fa;}")

        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        layout = QVBoxLayout(main_widget)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(15)

        # 头部标题
        title_label = QLabel("ECHelper - 一键安装控制台")
        title_label.setFont(QFont(UI_FONT, 18, QFont.Bold))
        title_label.setAlignment(Qt.AlignCenter)
        title_label.setStyleSheet("color: #2f3542;")
        layout.addWidget(title_label)

        # 设备状态面板
        status_panel = QWidget()
        status_panel.setStyleSheet("""
            QWidget {
                background-color: #ffffff;
                border: 1px solid #dcdde1;
                border-radius: 8px;
            }
        """)
        status_layout = QHBoxLayout(status_panel)
        self.status_label = QLabel("状态: 正在监控 USB 设备，请插入您的 iPhone...")
        self.status_label.setFont(QFont(UI_FONT, 12))
        self.status_label.setStyleSheet("color: #747d8c; border: none;")
        status_layout.addWidget(self.status_label)
        layout.addWidget(status_panel)

        # 日志输出框
        self.log_text = QTextEdit()
        self.log_text.setReadOnly(True)
        self.log_text.setFont(QFont("Consolas", 10))
        self.log_text.setStyleSheet("""
            QTextEdit {
                background-color: #1e272e;
                color: #d2dae2;
                border-radius: 8px;
                padding: 10px;
            }
        """)
        layout.addWidget(self.log_text)

        # 进度条 (Busy Indicator)
        self.progress_bar = QProgressBar()
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(0)
        self.progress_bar.setTextVisible(False)
        self.progress_bar.setFixedHeight(8)
        self.progress_bar.setStyleSheet("""
            QProgressBar {
                border: none;
                background-color: #dfe4ea;
                border-radius: 4px;
            }
            QProgressBar::chunk {
                background-color: #3742fa;
                border-radius: 4px;
            }
        """)
        self.progress_bar.hide()
        layout.addWidget(self.progress_bar)

        # 底部按钮区
        btn_layout = QHBoxLayout()

        self.launch_btn = QPushButton("🚀 启动 ECWDA")
        self.launch_btn.setFont(QFont(UI_FONT, 14, QFont.Bold))
        self.launch_btn.setFixedHeight(50)
        self.launch_btn.setCursor(Qt.PointingHandCursor)
        self.launch_btn.setStyleSheet("""
            QPushButton {
                background-color: #3742fa;
                color: #ffffff;
                border-radius: 8px;
            }
            QPushButton:hover {
                background-color: #5352ed;
            }
            QPushButton:disabled {
                background-color: #dfe4ea;
                color: #a4b0be;
            }
        """)
        self.launch_btn.setEnabled(False)
        self.launch_btn.clicked.connect(self.start_launch_ecwda)
        btn_layout.addWidget(self.launch_btn)

        self.install_btn = QPushButton("一键推送 ECHelper（含 ECMAIN 和 ECWDA）")
        self.install_btn.setFont(QFont(UI_FONT, 14, QFont.Bold))
        self.install_btn.setFixedHeight(50)
        self.install_btn.setCursor(Qt.PointingHandCursor)
        self.install_btn.setStyleSheet("""
            QPushButton {
                background-color: #7bed9f;
                color: #ffffff;
                border-radius: 8px;
            }
            QPushButton:hover {
                background-color: #2ed573;
            }
            QPushButton:disabled {
                background-color: #dfe4ea;
                color: #a4b0be;
            }
        """)
        self.install_btn.setEnabled(False)
        self.install_btn.clicked.connect(self.start_installation)
        btn_layout.addWidget(self.install_btn)

        layout.addLayout(btn_layout)

    def append_log(self, text):
        self.log_text.moveCursor(QTextCursor.End)
        self.log_text.insertPlainText(text)
        self.log_text.moveCursor(QTextCursor.End)

    def start_monitoring(self):
        self.monitor_thread = DeviceMonitorThread()
        self.monitor_thread.device_connected.connect(self.on_device_connected)
        self.monitor_thread.device_disconnected.connect(self.on_device_disconnected)
        self.monitor_thread.log_signal.connect(self.append_log)
        self.monitor_thread.start()

    def on_device_connected(self, os_name, version, build, udid):
        self.current_udid = udid
        self.status_label.setText(f"✅ 已连接设备: {os_name} {version} ({build})")
        self.status_label.setStyleSheet("color: #2ed573; font-weight: bold; border: none;")
        self.install_btn.setEnabled(True)
        self.launch_btn.setEnabled(True)
        self.install_btn.setStyleSheet("""
            QPushButton {
                background-color: #2ed573;
                color: white;
                border-radius: 8px;
            }
            QPushButton:hover { background-color: #26de81; }
        """)
        self.launch_btn.setStyleSheet("""
            QPushButton {
                background-color: #3742fa;
                color: white;
                border-radius: 8px;
            }
            QPushButton:hover { background-color: #5352ed; }
        """)

    def on_device_disconnected(self):
        self.current_udid = None
        self.status_label.setText("❌ 设备已断开，请重新插入...")
        self.status_label.setStyleSheet("color: #ff4757; font-weight: bold; border: none;")
        self.install_btn.setEnabled(False)
        self.launch_btn.setEnabled(False)
        self.install_btn.setStyleSheet("""
            QPushButton:disabled {
                background-color: #dfe4ea;
                color: #a4b0be;
                border-radius: 8px;
            }
        """)
        self.launch_btn.setStyleSheet("""
            QPushButton:disabled {
                background-color: #dfe4ea;
                color: #a4b0be;
                border-radius: 8px;
            }
        """)

    def start_launch_ecwda(self):
        if not self.current_udid:
            return
            
        self.launch_btn.setEnabled(False)
        self.launch_btn.setText("底核运转中...")
        self.progress_bar.setRange(0, 0)
        self.progress_bar.show()
        
        self.log_text.clear()
        self.append_log(f"⚡️ 开始下发潮汐穿透指令... {self.current_udid}\n")
        
        self.launch_thread = LaunchEcwdaThread(self.current_udid)
        self.launch_thread.log_signal.connect(self.append_log)
        # 利用 Qt 自身的信号机制在主线程安全地恢复按钮状态，避免跳过 Qt 安全检查导致和 0xc0000005 崩溃
        self.launch_thread.finished_signal.connect(self.on_launch_finished)
        self.launch_thread.start()

    def on_launch_finished(self):
        """ECWDA 启动线程结束回调 -- 一定在主线程被执行"""
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(100)
        self.launch_btn.setEnabled(True)
        self.launch_btn.setText("🚀 启动 ECWDA")

    def start_installation(self):
        self.install_btn.setEnabled(False)
        self.install_btn.setText("正在执行核心安装...")
        self.progress_bar.setRange(0, 0) # 忙碌动画
        self.progress_bar.show()
        
        self.log_text.clear()
        self.append_log("🚀 开始准备推送到 ECHelper 极速通道...\n")

        self.installer_thread = InstallerThread()
        self.installer_thread.log_signal.connect(self.append_log)
        self.installer_thread.finished_signal.connect(self.on_installation_finished)
        self.installer_thread.start()

    def on_installation_finished(self, success):
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(100)
        
        if success:
            self.install_btn.setText("🎉 ECHelper 推送完成 (设备将稍后重启)")
            self.install_btn.setStyleSheet("""
                QPushButton {
                    background-color: #2ed573;
                    color: white;
                    border-radius: 8px;
                }
            """)
        else:
            self.install_btn.setText("❌ 推送 ECHelper 发生错误")
            self.install_btn.setStyleSheet("""
                QPushButton {
                    background-color: #ff4757;
                    color: white;
                    border-radius: 8px;
                }
            """)
            self.install_btn.setEnabled(True) # 允许重试

if __name__ == "__main__":
    app = QApplication(sys.argv)
    
    # 适配高分屏
    app.setAttribute(Qt.AA_EnableHighDpiScaling, True)
    app.setAttribute(Qt.AA_UseHighDpiPixmaps, True)
    
    gui = ECHelperGUI()
    gui.show()
    sys.exit(app.exec_())
