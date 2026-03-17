import sys
import os
import time
import traceback
import logging
import platform
import shutil
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                             QHBoxLayout, QPushButton, QTextEdit, QLabel, QProgressBar, QListWidget, QListWidgetItem)
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

# --- 增强 PATH 环境以支持打包后的 macOS .app 寻找 tidevice ---
def fix_env_path():
    common_paths = [
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        os.path.expanduser("~/Library/Python/3.9/bin"),
        os.path.expanduser("~/Library/Python/3.8/bin"),
        os.path.expanduser("/Library/Frameworks/Python.framework/Versions/3.9/bin"),
        "/opt/homebrew/bin"
    ]
    current_path = os.environ.get("PATH", "")
    for p in common_paths:
        if os.path.exists(p) and p not in current_path:
            current_path = p + os.pathsep + current_path
    os.environ["PATH"] = current_path

fix_env_path()

def get_tidevice_path():
    p = shutil.which("tidevice")
    if not p and platform.system() == "Darwin":
        # 最后的兜底尝试
        user_bin = os.path.expanduser("~/Library/Python/3.9/bin/tidevice")
        if os.path.exists(user_bin):
            return user_bin
    return p

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
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.exceptions import NoDeviceConnectedError
from packaging.version import parse as parse_version

# 导入静默安装核心
import install_echelper

class StreamRedirector:
    def __init__(self, signal):
        self.signal = signal

    def write(self, text):
        # click.secho 在某些环境下可能输出 bytes，需要先解码
        if isinstance(text, bytes):
            text = text.decode('utf-8', errors='replace')
        if isinstance(text, str) and (text.strip() or text == '\n'):
            self.signal.emit(text)

    def flush(self):
        pass

class DeviceMonitorThread(QThread):
    devices_updated = pyqtSignal(list) # list of dicts: {'udid': udid, 'name': 'OS Name', 'version': '15.0', 'build': 'abc'}
    
    def run(self):
        os_names = {
            "iPhone": "iOS", "iPad": "iPadOS", "iPod": "iOS",
            "AppleTV": "tvOS", "Watch": "watchOS",
            "AudioAccessory": "HomePod Software", "RealityDevice": "visionOS"
        }
        last_udids = set()
        while True:
            try:
                current_devices = []
                current_udids = set()
                
                devices = list_devices()
                for dev in devices:
                    try:
                        service_provider = create_using_usbmux(serial=dev.serial)
                        device_class = service_provider.get_value(key="DeviceClass")
                        device_build = service_provider.get_value(key="BuildVersion")
                        device_version = service_provider.product_version
                        device_udid = dev.serial
                        
                        os_name = os_names.get(device_class, "Unknown OS")
                        current_devices.append({
                            'udid': device_udid,
                            'name': os_name,
                            'version': device_version,
                            'build': device_build
                        })
                        current_udids.add(device_udid)
                    except Exception:
                        pass
                        
                if current_udids != last_udids:
                    self.devices_updated.emit(current_devices)
                    last_udids = current_udids
            except Exception:
                if last_udids:
                    self.devices_updated.emit([])
                    last_udids = set()
            time.sleep(2)

class InstallerThread(QThread):
    log_signal = pyqtSignal(str)
    finished_signal = pyqtSignal(bool) # True if success
    
    def __init__(self, udids):
        super().__init__()
        self.udids = udids
        
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
        
        all_success = True
        try:
            for i, udid in enumerate(self.udids):
                self.log_signal.emit(f"\\n==========================================")
                self.log_signal.emit(f"⏳ 开始安装设备 [{i+1}/{len(self.udids)}]: {udid}")
                self.log_signal.emit(f"==========================================\\n")
                
                success = install_echelper.perform_installation(serial=udid)
                if not success:
                    all_success = False
                    self.log_signal.emit(f"\\n❌ 设备 {udid[:8]} 安装失败！")
                else:
                    self.log_signal.emit(f"\\n✅ 设备 {udid[:8]} 安装成功！")
                    
                    # 自动唤起 ECMAIN 以触发内部静默安装 ECWDA 的逻辑
                    self.log_signal.emit(f"🚀 正在自动拉起 ECHelper 触发底核部署...")
                    try:
                        import subprocess
                        t_path = get_tidevice_path()
                        if t_path:
                            subprocess.run([t_path, "-u", udid, "launch", "com.apple.Tips"], capture_output=True, timeout=10)
                            self.log_signal.emit("   ✅ 成功拉起！ECWDA 将在几秒内静默安装完毕")
                        else:
                            self.log_signal.emit("   ⚠️ 无法找到 tidevice 工具，请手动在手机上打开 [提示] App")
                    except Exception as e:
                        self.log_signal.emit(f"   ⚠️ 自动拉起出错，请手动在手机上打开 [提示] App: {e}")
        except Exception as e:
            err_msg = traceback.format_exc()
            logging.error(f"一键安装 ECHelper 崩溃:\\n{err_msg}")
            self.log_signal.emit(f"安装过程发生异常: {str(e)}")
            self.log_signal.emit(err_msg)
            all_success = False
        finally:
            sys.stdout = old_stdout
            sys.stderr = old_stderr
            click.confirm = original_confirm
            self.finished_signal.emit(all_success)

class LaunchEcwdaThread(QThread):
    log_signal = pyqtSignal(str)
    finished_signal = pyqtSignal()

    def __init__(self, udids):
        super().__init__()
        self.udids = udids

    def run(self):
        self.log_signal.emit(f"🚀 准备为 {len(self.udids)} 台设备启动 ECWDA 底核...")
        import subprocess
        
        t_path = get_tidevice_path()
        if not t_path:
            self.log_signal.emit("❌ 未在系统 PATH 中找到 tidevice 命令行工具，请确保已安装！(pip install tidevice)")
            self.finished_signal.emit(False)
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
        
        creationflags = 0
        kwargs = {}
        if hasattr(subprocess, 'CREATE_NO_WINDOW'):
            creationflags = subprocess.CREATE_NO_WINDOW
        
        if platform.system() == "Windows":
            if hasattr(subprocess, 'CREATE_NEW_PROCESS_GROUP'):
                creationflags |= subprocess.CREATE_NEW_PROCESS_GROUP
        else:
            kwargs['start_new_session'] = True
            
        # 缓存起来防止 GC 时调用 __del__ 杀掉子进程
        self.running_processes = getattr(self, 'running_processes', [])
            
        try:
            for i, udid in enumerate(self.udids):
                self.log_signal.emit(f"🚀 发送穿透启动指令 (UDID: {udid[:8]})...")
                # ECWDA 是独立应用，直接 launch 即可，后台进程会退出，不阻塞
                cmd_wda = [t_path, "-u", udid, "launch", "com.facebook.WebDriverAgentRunner.ecwda"]
                
                subprocess.run(
                    cmd_wda, 
                    creationflags=creationflags,
                    capture_output=True,
                    **kwargs
                )
                self.log_signal.emit(f"   ✅ [{udid[:8]}] 主核进程已唤醒潜渡")
                
                # 为每台设备分配递增的 PC 端口映射以防止冲突 (i*10)
                current_pc_10088 = 10088 + i * 10
                current_pc_10089 = 10089 + i * 10
                current_pc_8089 = 8089 + i * 10
                
                for local_p, remote_p in [(current_pc_10088, 10088), (current_pc_10089, 10089), (current_pc_8089, 8089)]:
                    cmd_relay = [t_path, "-u", udid, "relay", str(local_p), str(remote_p)]
                    r_proc = subprocess.Popen(
                        cmd_relay, 
                        creationflags=creationflags,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        **kwargs
                    )
                    self.running_processes.append(r_proc)
                    self.log_signal.emit(f"   ✅ [{udid[:8]}] 映射 PC:{local_p} -> 手机:{remote_p} (PID: {r_proc.pid})")
                
            self.log_signal.emit(f"🎉 {len(self.udids)} 台设备的 ECWDA 全链舰队（主核+中继）已成功独立驻留后台！")
        except Exception as e:
            err_msg = traceback.format_exc()
            logging.error(f"启动 ECWDA 崩溃:\\n{err_msg}")
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

        # 多设备监控列表
        self.device_list = QListWidget()
        self.device_list.setStyleSheet("""
            QListWidget {
                background-color: #ffffff;
                border: 1px solid #dcdde1;
                border-radius: 8px;
                padding: 5px;
                font-family: "Microsoft YaHei";
                font-size: 14px;
                color: #2f3542;
            }
            QListWidget::item {
                padding: 10px;
                border-bottom: 1px solid #f5f6fa;
            }
        """)
        self.device_list.setFixedHeight(120)
        self.known_udids = set()
        layout.addWidget(self.device_list)

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
        self.monitor_thread.devices_updated.connect(self.on_devices_updated)
        self.monitor_thread.start()

    def get_selected_udids(self):
        udids = []
        for i in range(self.device_list.count()):
            item = self.device_list.item(i)
            if item.checkState() == Qt.Checked:
                udids.append(item.data(Qt.UserRole))
        return udids

    def on_devices_updated(self, current_devices):
        checked_udids = set(self.get_selected_udids())
        self.device_list.clear()
        
        if not current_devices:
            item = QListWidgetItem("⏳ 正在监控 USB 设备，请插入您的 iPhone...")
            item.setFlags(Qt.NoItemFlags)
            self.device_list.addItem(item)
            self.set_buttons_enabled(False)
            return

        for dev in current_devices:
            text = f"📱 {dev['name']} {dev['version']} ({dev['build']})  [{dev['udid'][:8]}]"
            item = QListWidgetItem(text)
            item.setData(Qt.UserRole, dev['udid'])
            item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
            
            # 如果是新发现的设备，默认勾选；否则保持之前的勾选状态
            if dev['udid'] not in self.known_udids:
                item.setCheckState(Qt.Checked)
                self.known_udids.add(dev['udid'])
            else:
                item.setCheckState(Qt.Checked if dev['udid'] in checked_udids else Qt.Unchecked)
                
            self.device_list.addItem(item)
            
        self.set_buttons_enabled(True)

    def set_buttons_enabled(self, enabled):
        self.install_btn.setEnabled(enabled)
        self.launch_btn.setEnabled(enabled)
        if enabled:
            self.install_btn.setStyleSheet(""""
                QPushButton { background-color: #2ed573; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #26de81; }
            """)
            self.launch_btn.setStyleSheet("""
                QPushButton { background-color: #3742fa; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #5352ed; }
            """)
        else:
            disabled_style = "QPushButton:disabled { background-color: #dfe4ea; color: #a4b0be; border-radius: 8px; }"
            self.install_btn.setStyleSheet(disabled_style)
            self.launch_btn.setStyleSheet(disabled_style)

    def start_launch_ecwda(self):
        selected_udids = self.get_selected_udids()
        if not selected_udids:
            self.append_log("⚠️ 未勾选任何设备！\\n")
            return
            
        self.set_buttons_enabled(False)
        self.launch_btn.setText("底核运转中...")
        self.progress_bar.setRange(0, 0)
        self.progress_bar.show()
        
        self.log_text.clear()
        self.append_log(f"⚡️ 开始下发潮汐穿透指令... 目标: {len(selected_udids)} 台\\n")
        
        self.launch_thread = LaunchEcwdaThread(selected_udids)
        self.launch_thread.log_signal.connect(self.append_log)
        self.launch_thread.finished_signal.connect(self.on_launch_finished)
        self.launch_thread.start()

    def on_launch_finished(self):
        """ECWDA 启动线程结束回调 -- 一定在主线程被执行"""
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(100)
        self.launch_btn.setEnabled(True)
        self.launch_btn.setText("🚀 启动 ECWDA")

    def start_installation(self):
        selected_udids = self.get_selected_udids()
        if not selected_udids:
            self.append_log("⚠️ 未勾选任何设备！\\n")
            return
            
        self.set_buttons_enabled(False)
        self.install_btn.setText("正在执行批量安装...")
        self.progress_bar.setRange(0, 0) # 忙碌动画
        self.progress_bar.show()
        
        self.log_text.clear()
        self.append_log(f"🚀 开始准备批量安装过程... 目标: {len(selected_udids)} 台\\n")

        self.installer_thread = InstallerThread(selected_udids)
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
