import sys
import os
import time
import traceback
import logging
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                             QHBoxLayout, QPushButton, QTextEdit, QLabel, QProgressBar)
from PyQt5.QtCore import QThread, pyqtSignal, Qt
from PyQt5.QtGui import QFont, QTextCursor, QIcon

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
        if text.strip() or text == '\n':
            self.signal.emit(text)

    def flush(self):
        pass

class DeviceMonitorThread(QThread):
    device_connected = pyqtSignal(str, str, str, str) # name, version, build, udid
    device_disconnected = pyqtSignal()
    
    def run(self):
        os_names = {
            "iPhone": "iOS", "iPad": "iPadOS", "iPod": "iOS",
            "AppleTV": "tvOS", "Watch": "watchOS",
            "AudioAccessory": "HomePod Software", "RealityDevice": "visionOS"
        }
        last_state = False
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
            except Exception:
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

    def run(self):
        self.log_signal.emit("🚀 正在组织环境准备启动 ECWDA 底核...")
        import platform
        import shutil
        import subprocess
        
        t_path = shutil.which("tidevice")
        if not t_path:
            self.log_signal.emit("❌ 未在系统 PATH 中找到 tidevice 命令行工具，请确保已安装潮汐通道！(pip install tidevice)")
            return
            
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
        cmd_wda = [t_path, "-u", self.udid, "wdaproxy", "-B", "com.facebook.WebDriverAgentRunner.ecwda", "--port", "0"]
        
        creationflags = 0
        if hasattr(subprocess, 'CREATE_NO_WINDOW'):
            creationflags = subprocess.CREATE_NO_WINDOW
            
        try:
            wda_proc = subprocess.Popen(
                cmd_wda, 
                creationflags=creationflags,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
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
        title_label.setFont(QFont("Microsoft YaHei", 18, QFont.Bold))
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
        self.status_label.setFont(QFont("Microsoft YaHei", 12))
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
        self.launch_btn.setFont(QFont("Microsoft YaHei", 14, QFont.Bold))
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

        self.install_btn = QPushButton("一键安装 ECHelper")
        self.install_btn.setFont(QFont("Microsoft YaHei", 14, QFont.Bold))
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
        self.append_log("🚀 开始准备安装过程...\n")

        self.installer_thread = InstallerThread()
        self.installer_thread.log_signal.connect(self.append_log)
        self.installer_thread.finished_signal.connect(self.on_installation_finished)
        self.installer_thread.start()

    def on_installation_finished(self, success):
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(100)
        
        if success:
            self.install_btn.setText("🎉 安装完成 (设备正在重启)")
            self.install_btn.setStyleSheet("""
                QPushButton {
                    background-color: #2ed573;
                    color: white;
                    border-radius: 8px;
                }
            """)
        else:
            self.install_btn.setText("❌ 安装过程中发生错误")
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
