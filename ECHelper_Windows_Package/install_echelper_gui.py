import sys
import os
import time
import traceback
import logging
import platform
import shutil
import threading
import subprocess
from PyQt5.QtWidgets import (QApplication, QMainWindow, QWidget, QVBoxLayout,
                             QHBoxLayout, QPushButton, QTextEdit, QLabel, QProgressBar, QListWidget, QListWidgetItem, QSplitter)
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

# 尝试导入 tidevice CLI 入口，实现全量封装
try:
    from tidevice.__main__ import main as tidevice_cli_main
    HAS_TIDEVICE = True
except ImportError:
    HAS_TIDEVICE = False

# [关键修复] 针对 PyInstaller 打包环境的多进程拦截
# 当使用 subprocess 调用 sys.executable 且附带 "-m tidevice" 时，实际上是再次运行了当前程序的 .exe
# 为防止其继续往下执行触发 GUI 单例锁(socket bind 报错退出)，必须在这里直接拦截并转发给 tidevice 处理
if getattr(sys, 'frozen', False) and len(sys.argv) >= 3 and sys.argv[1] == "-m" and sys.argv[2] == "tidevice":
    if HAS_TIDEVICE:
        # 重写 sys.argv 欺骗 click/argparse，让其认为我们直接在命令行调用了 tidevice
        sys.argv = ["tidevice"] + sys.argv[3:]
        sys.exit(tidevice_cli_main())
    else:
        sys.exit(1)

# 模拟 CLI 调用 tidevice
def tidevice_exec(args_list, wait=False, background=True, tries=2):
    """通过子进程安全调用 tidevice，支持并发且不干扰全局 sys.argv"""
    if not HAS_TIDEVICE:
        logging.error("代码中缺失 tidevice 库，请检查安装")
        return None

    # [关键修复] PyInstaller 打包环境下 sys.executable 不是原生的 python，不能用 -m
    # 优先检测是否为打包后的独立运行环境 (Frozen)
    env = os.environ.copy()
    if getattr(sys, 'frozen', False):
        # 在 PyInstaller 下，所有 Python 包都在 sys._MEIPASS 或包目录下
        # 我们使用当前可执行文件作为 python 引导
        if hasattr(sys, '_MEIPASS'):
            env['PYTHONPATH'] = sys._MEIPASS + os.pathsep + env.get('PYTHONPATH', '')
        cmd = [sys.executable, "-m", "tidevice"] + list(args_list)
    else:
        cmd = [sys.executable, "-m", "tidevice"] + list(args_list)
    
    last_res = None
    for i in range(tries):
        try:
            if not wait:
                # 开启后台常驻进程 (用于 relay)
                kwargs = {"env": env, "stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
                if platform.system() == "Windows":
                    # Windows 下隐藏控制台窗口
                    kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
                return subprocess.Popen(cmd, **kwargs)
            else:
                # 阻塞等待执行结果 (用于 launch 等)
                result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env)
                if result.returncode == 0:
                    return result
                
                last_res = result
                # 如果是 SSL 握手超时或服务无效，尝试重试
                err_lower = result.stderr.lower()
                if "timeout" in err_lower or "handshake" in err_lower or "invalidservice" in err_lower:
                    logging.warning(f"tidevice 指令 ({' '.join(args_list)}) 遇到超时/异常，正在尝试第 {i+2} 次重试...")
                    time.sleep(1)
                    continue
                else:
                    break # 其它错误不重试
        except Exception as e:
            logging.error(f"tidevice_exec 异常 (第 {i+1} 次): {e}")
            time.sleep(1)
            
    if wait and last_res and last_res.returncode != 0:
        logging.error(f"tidevice 指令最终失败: {' '.join(cmd)}\n最后报错: {last_res.stderr}")
    return last_res

# 为了兼容旧代码，保留 tidevice_invoke 别名并重定向
def tidevice_invoke(args_list):
    # 默认使用等待模式，因为旧代码中很多是直接调用的
    return tidevice_exec(args_list, wait=True)

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
                        connection_type = getattr(dev, "connection_type", "Unknown")
                        
                        current_devices.append({
                            'udid': device_udid,
                            'name': os_name,
                            'version': device_version,
                            'build': device_build,
                            'connection': connection_type
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
                    
                    # 使用内部模拟调用，不再依赖 PATH
                    self.log_signal.emit(f"🚀 正在通过内置组件拉起 ECHelper 触发底核部署...")
                    try:
                        if HAS_TIDEVICE:
                            # 启动后 ECMAIN 会常驻，这里加个超时或者后台跑
                            t_thread = threading.Thread(target=tidevice_invoke, args=(["-u", udid, "launch", "com.apple.Tips"],))
                            t_thread.start()
                            self.log_signal.emit("   ✅ 指令已下发！ECWDA 将在几秒内静默安装完毕")
                        else:
                            self.log_signal.emit("   ⚠️ 缺少内置驱动组件，请手动在手机上打开 [提示] App")
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
    finished_signal = pyqtSignal(bool) # Changed to bool to indicate success/failure

    def __init__(self, udids):
        super().__init__()
        self.udids = udids

    def run(self):
        self.log_signal.emit(f"🚀 准备为 {len(self.udids)} 台设备启动 ECWDA 底核...")
        
        if not HAS_TIDEVICE:
            self.log_signal.emit("❌ 运行环境中缺失内置驱动库，请检查安装！")
            self.finished_signal.emit(False)
            return

        try:
            # 清理旧残留不需要 tidevice
            p_kill_cmd = ["taskkill", "/F", "/IM", "tidevice.exe"] if platform.system() == "Windows" else ["pkill", "-f", "tidevice"]
            import subprocess
            subprocess.run(p_kill_cmd, capture_output=True)
            self.log_signal.emit("✅ 旧残留守护进程已清场")
        except Exception:
            pass
            
        time.sleep(1)
        
        try:
            for i, udid in enumerate(self.udids):
                self.log_signal.emit(f"🚀 发送穿透启动指令 (UDID: {udid[:8]})...")
                
                # 为每台设备分配递增的 PC 端口映射
                current_pc_10088 = 10088 + i * 10
                current_pc_10089 = 10089 + i * 10
                current_pc_8089 = 8089 + i * 10
                
                # 第 1 步：先建立端口转发（relay 不需要代码签名校验，纯 USB 通道）
                self.log_signal.emit(f"   🔗 [{udid[:8]}] 正在建立 USB 端口转发隧道...")
                for local_p, remote_p in [(current_pc_10088, 10088), (current_pc_10089, 10089), (current_pc_8089, 8089)]:
                    tidevice_exec(["-u", udid, "relay", str(local_p), str(remote_p)], wait=False)
                
                self.log_signal.emit(f"   ✅ [{udid[:8]}] 转发链已就位: PC:{current_pc_8089} -> 手机:8089")
                
                # 等待端口转发生效
                time.sleep(2)
                
                # 第 2 步：通过 ECMAIN 的 HTTP API 触发 WDA 启动
                # ECMAIN 监听在手机的 8089 端口，我们通过已建立的 USB relay 通道访问
                self.log_signal.emit(f"   📡 [{udid[:8]}] 通过 ECMAIN 内部通道触发 WDA 启动 (绕过签名校验)...")
                
                import urllib.request
                import json
                
                wda_started = False
                for attempt in range(3):
                    try:
                        # 先探测 ECMAIN 是否在线
                        ping_url = f"http://127.0.0.1:{current_pc_8089}/ping"
                        req = urllib.request.Request(ping_url, method="GET")
                        req.add_header("Connection", "close")
                        resp = urllib.request.urlopen(req, timeout=5)
                        ping_result = resp.read().decode("utf-8", errors="replace")
                        
                        if "pong" in ping_result:
                            self.log_signal.emit(f"   ✅ [{udid[:8]}] ECMAIN 主控已在线 (端口 {current_pc_8089})")
                            
                            # 调用 /start-wda 端点,让 ECMAIN 用 root 权限启动 WDA
                            wda_url = f"http://127.0.0.1:{current_pc_8089}/start-wda"
                            wda_req = urllib.request.Request(wda_url, method="GET")
                            wda_req.add_header("Connection", "close")
                            wda_resp = urllib.request.urlopen(wda_req, timeout=30)
                            wda_body = wda_resp.read().decode("utf-8", errors="replace")
                            
                            try:
                                wda_json = json.loads(wda_body)
                                if wda_json.get("status") == "ok":
                                    self.log_signal.emit(f"   ✅ [{udid[:8]}] WDA 底核已通过内部提权成功启动！")
                                    wda_started = True
                                    break
                                else:
                                    self.log_signal.emit(f"   ⚠️ [{udid[:8]}] WDA 启动返回异常: {wda_json.get('message', '未知')}")
                            except json.JSONDecodeError:
                                self.log_signal.emit(f"   ⚠️ [{udid[:8]}] WDA 启动响应解析失败: {wda_body[:100]}")
                            break  # 不再重试
                        else:
                            self.log_signal.emit(f"   ⚠️ [{udid[:8]}] ECMAIN 响应异常 (第 {attempt+1} 次)，等待重试...")
                            time.sleep(2)
                    except Exception as e:
                        err_str = str(e)
                        if attempt < 2:
                            self.log_signal.emit(f"   ⏳ [{udid[:8]}] ECMAIN 探测中 (第 {attempt+1}/3 次): {err_str[:80]}")
                            time.sleep(3)
                        else:
                            self.log_signal.emit(f"   ❌ [{udid[:8]}] ECMAIN 不可达: {err_str[:120]}")
                            self.log_signal.emit(f"       💡 请确保手机上 ECMAIN 已在前台运行过至少一次！")
                
                if not wda_started:
                    # 兜底方案：尝试 tidevice launch（仅对非 TrollStore 安装的 WDA 有效）
                    self.log_signal.emit(f"   🔄 [{udid[:8]}] 尝试回退至 tidevice 直接拉起模式...")
                    res = tidevice_exec(["-u", udid, "launch", "com.facebook.WebDriverAgentRunner.ecwda"], wait=True)
                    if res and res.returncode == 0:
                        self.log_signal.emit(f"   ✅ [{udid[:8]}] 通过 tidevice 直接拉起成功")
                    else:
                        err = res.stderr if res else "未知错误"
                        self.log_signal.emit(f"   ❌ [{udid[:8]}] 所有启动方式均失败: {err.strip().split(chr(10))[-1][:100]}")
                        self.log_signal.emit(f"       💡 解决方案: 在手机上打开 ECMAIN App，点击 [🚀 启动 WDA] 按钮")
            
            self.log_signal.emit("\n🎉 所有设备驱动已就位！")
            self.finished_signal.emit(True)
        except Exception as e:
            err_msg = traceback.format_exc()
            logging.error(f"启动 ECWDA 崩溃:\n{err_msg}")
            self.log_signal.emit(f"❌ 启动受挫故障: {e}")
            self.finished_signal.emit(False)


class WatchdogThread(QThread):
    """WDA 常驻看护线程：持续监控并自动恢复 WDA"""
    log_signal = pyqtSignal(str)

    def __init__(self, udids, port_base=10088, interval=5):
        super().__init__()
        self.udids = udids
        self.port_base = port_base
        self.interval = interval
        self._running = True
        self.wda_bundle = "com.facebook.WebDriverAgentRunner.ecwda"

    def stop(self):
        self._running = False

    def _check_wda(self, port, timeout=3):
        """检测 WDA 是否在指定端口响应"""
        import socket as sock_mod
        try:
            s = sock_mod.socket(sock_mod.AF_INET, sock_mod.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(("127.0.0.1", port))
            s.sendall(b"GET /status HTTP/1.0\r\n\r\n")
            data = s.recv(1024)
            s.close()
            return len(data) > 0
        except Exception:
            return False

    def _launch_and_relay(self, udid, port_base):
        """通过 ECMAIN 内部通道拉起 WDA 并建立端口映射"""
        import urllib.request
        import json
        
        # 确保 8089 relay 存在（ECMAIN 的 HTTP API）
        ecmain_port = port_base + 1  # 8089 系列（与 port_base 偏移对应）
        # 动态计算: 如果 port_base 是 10088, 则对应的 8089 端口偏移
        device_index = (port_base - self.port_base) // 10
        local_8089 = 8089 + device_index * 10
        
        tidevice_exec(["-u", udid, "relay", str(local_8089), "8089"], wait=False)
        time.sleep(1)
        
        # 通过 ECMAIN HTTP API 启动 WDA
        try:
            wda_url = f"http://127.0.0.1:{local_8089}/start-wda"
            req = urllib.request.Request(wda_url, method="GET")
            req.add_header("Connection", "close")
            resp = urllib.request.urlopen(req, timeout=30)
            body = resp.read().decode("utf-8", errors="replace")
            result = json.loads(body)
            if result.get("status") == "ok":
                self.log_signal.emit(f"   ✅ [{udid[:8]}] 看护已通过内部通道重启 WDA")
            else:
                self.log_signal.emit(f"   ⚠️ [{udid[:8]}] WDA 重启返回异常: {result.get('message', '未知')}")
        except Exception as e:
            self.log_signal.emit(f"   ⚠️ [{udid[:8]}] 内部通道重启失败({e})，尝试 tidevice 直接拉起...")
            res = tidevice_exec(["-u", udid, "launch", self.wda_bundle], wait=True)
            if res and res.returncode != 0:
                self.log_signal.emit(f"   ❌ [{udid[:8]}] 看护重启 WDA 失败: {res.stderr.strip()[:100]}")
                return

        # relay 异步执行（WDA 端口）
        for local_p, remote_p in [(port_base, 10088), (port_base + 1, 10089)]:
            tidevice_exec(["-u", udid, "relay", str(local_p), str(remote_p)], wait=False)

    def run(self):
        self.log_signal.emit("🛡️ WDA 常驻看护已启动！")
        self.log_signal.emit(f"   监控 {len(self.udids)} 台设备，每 {self.interval} 秒检查一次\n")

        if not HAS_TIDEVICE:
            self.log_signal.emit("❌ 缺失 tidevice 驱动库，看护无法运行！")
            return

        # 初始化：设备 -> {port, failures, relayed}
        devices = {}
        for i, udid in enumerate(self.udids):
            port = self.port_base + i * 10
            devices[udid] = {"port": port, "failures": 0, "relayed": False}
            self.log_signal.emit(f"📱 [{udid[:8]}] 分配端口 PC:{port}")

        # 首次全部拉起
        for udid, info in devices.items():
            self.log_signal.emit(f"🚀 [{udid[:8]}] 首次拉起 WDA...")
            self._launch_and_relay(udid, info["port"])
            info["relayed"] = True
            self.log_signal.emit(f"   ✅ [{udid[:8]}] WDA 已启动，等待就绪...")

        while self._running:
            time.sleep(self.interval)
            for udid, info in devices.items():
                alive = self._check_wda(info["port"])
                if alive:
                    if info["failures"] > 0:
                        self.log_signal.emit(f"✅ [{udid[:8]}] WDA 已恢复 (端口 {info['port']})")
                    info["failures"] = 0
                else:
                    info["failures"] += 1
                    if info["failures"] >= 5:
                        self.log_signal.emit(f"⚠️ [{udid[:8]}] WDA 连续 {info['failures']} 次无响应，重启中...")
                        info["relayed"] = False
                        self._launch_and_relay(udid, info["port"])
                        info["relayed"] = True
                        info["failures"] = 0

        self.log_signal.emit("⏹️ WDA 常驻看护已停止。")

class ECHelperGUI(QMainWindow):
    def __init__(self):
        super().__init__()
        self.current_udid = None
        self.watchdog_thread = None
        self.setWindowTitle("ECHelper - 一键安装控制台")
        self.resize(800, 800)
        self.init_ui()
        self.start_monitoring()

    def init_ui(self):
        main_widget = QWidget()
        self.setCentralWidget(main_widget)
        layout = QVBoxLayout(main_widget)
        layout.setContentsMargins(20, 20, 20, 20)
        layout.setSpacing(15)

        # 头部标题
        title_label = QLabel("ECHelper - 一键安装控制台")
        title_label.setFont(QFont("Microsoft YaHei", 18, QFont.Bold))
        title_label.setAlignment(Qt.AlignCenter)
        title_label.setStyleSheet("color: #2f3542; margin-bottom: 5px;")
        layout.addWidget(title_label)

        # 使用 QSplitter 允许用户调整列表和日志的高度比例
        self.splitter = QSplitter(Qt.Vertical)
        
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
        self.known_udids = set()
        self.splitter.addWidget(self.device_list)

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
        self.splitter.addWidget(self.log_text)
        
        # 设置初始权重，给列表多一点空间（例如 [1, 2]）
        self.splitter.setStretchFactor(0, 1)
        self.splitter.setStretchFactor(1, 2)
        
        layout.addWidget(self.splitter)

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

        self.wifi_btn = QPushButton("📡 开启无线调试")
        self.wifi_btn.setFont(QFont("Microsoft YaHei", 12))
        self.wifi_btn.setFixedHeight(50)
        self.wifi_btn.setCursor(Qt.PointingHandCursor)
        self.wifi_btn.setStyleSheet("""
            QPushButton {
                background-color: #70a1ff;
                color: #ffffff;
                border-radius: 8px;
            }
            QPushButton:hover {
                background-color: #1e90ff;
            }
            QPushButton:disabled {
                background-color: #dfe4ea;
                color: #a4b0be;
            }
        """)
        self.wifi_btn.setEnabled(False)
        self.wifi_btn.clicked.connect(self.enable_wifi_debugging)
        btn_layout.addWidget(self.wifi_btn)

        self.watchdog_btn = QPushButton("🛡️ 常驻看护")
        self.watchdog_btn.setFont(QFont("Microsoft YaHei", 14, QFont.Bold))
        self.watchdog_btn.setFixedHeight(50)
        self.watchdog_btn.setCursor(Qt.PointingHandCursor)
        self.watchdog_btn.setStyleSheet("""
            QPushButton {
                background-color: #ffa502;
                color: #ffffff;
                border-radius: 8px;
            }
            QPushButton:hover {
                background-color: #ff9f43;
            }
            QPushButton:disabled {
                background-color: #dfe4ea;
                color: #a4b0be;
            }
        """)
        self.watchdog_btn.setEnabled(False)
        self.watchdog_btn.clicked.connect(self.toggle_watchdog)
        btn_layout.addWidget(self.watchdog_btn)

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
            conn_tag = " [USB]" if dev['connection'] == "USB" else " [网络]"
            text = f"📱 {dev['name']} {dev['version']} ({dev['build']}){conn_tag}  [{dev['udid'][:8]}]"
            item = QListWidgetItem(text)
            item.setData(Qt.UserRole, dev['udid'])
            item.setFlags(item.flags() | Qt.ItemIsUserCheckable)
            
            # 如果是新发现的设备：如果是 USB 则默认勾选，否则默认不勾选
            if dev['udid'] not in self.known_udids:
                if dev['connection'] == "USB":
                    item.setCheckState(Qt.Checked)
                else:
                    item.setCheckState(Qt.Unchecked)
                self.known_udids.add(dev['udid'])
            else:
                item.setCheckState(Qt.Checked if dev['udid'] in checked_udids else Qt.Unchecked)
                
            self.device_list.addItem(item)
            
        self.set_buttons_enabled(True)

    def set_buttons_enabled(self, enabled):
        self.install_btn.setEnabled(enabled)
        self.launch_btn.setEnabled(enabled)
        # 只有当看护未运行时，才根据设备状态控制看护按钮和无线按钮
        if self.watchdog_thread is None or not self.watchdog_thread.isRunning():
            self.watchdog_btn.setEnabled(enabled)
            self.wifi_btn.setEnabled(enabled)
        if enabled:
            self.install_btn.setStyleSheet("""
                QPushButton { background-color: #2ed573; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #26de81; }
            """)
            self.launch_btn.setStyleSheet("""
                QPushButton { background-color: #3742fa; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #5352ed; }
            """)
            self.wifi_btn.setStyleSheet("""
                QPushButton { background-color: #70a1ff; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #1e90ff; }
            """)
        else:
            disabled_style = "QPushButton:disabled { background-color: #dfe4ea; color: #a4b0be; border-radius: 8px; }"
            self.install_btn.setStyleSheet(disabled_style)
            self.launch_btn.setStyleSheet(disabled_style)
            self.wifi_btn.setStyleSheet(disabled_style)

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

    def toggle_watchdog(self):
        """切换常驻看护状态"""
        if self.watchdog_thread and self.watchdog_thread.isRunning():
            # 停止看护
            self.watchdog_thread.stop()
            self.watchdog_thread.wait(3000)
            self.watchdog_thread = None
            self.watchdog_btn.setText("🛡️ 常驻看护")
            self.watchdog_btn.setStyleSheet("""
                QPushButton { background-color: #ffa502; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #ff9f43; }
            """)
            self.append_log("\n⏹️ 看护已手动停止。\n")
        else:
            # 启动看护
            selected_udids = self.get_selected_udids()
            if not selected_udids:
                self.append_log("⚠️ 未勾选任何设备！\n")
                return

            self.log_text.clear()
            self.watchdog_thread = WatchdogThread(selected_udids)
            self.watchdog_thread.log_signal.connect(self.append_log)
            self.watchdog_thread.start()

            self.watchdog_btn.setText("⏹️ 停止看护")
            self.watchdog_btn.setStyleSheet("""
                QPushButton { background-color: #ff4757; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #ff6b81; }
            """)

    def enable_wifi_debugging(self):
        """为所有选中的设备开启网络调试 (需插线)"""
        selected_udids = self.get_selected_udids()
        if not selected_udids:
            self.append_log("⚠️ 未勾选任何设备！\n")
            return
        
        self.append_log(f"📡 正在为 {len(selected_udids)} 台设备尝试开启无线同步...\n")
        for udid in selected_udids:
            try:
                self.append_log(f"   [{udid[:8]}] 正在注入开启指令...")
                service_provider = create_using_usbmux(serial=udid)
                # 在此版本 pymobiledevice3 中，这是 LockdownClient 的一个属性
                service_provider.enable_wifi_connections = True
                self.append_log(f"   ✅ [{udid[:8]}] 已开启！现在拔掉数据线也能识别了 (需在同一网络)\n")
            except Exception as e:
                self.append_log(f"   ❌ [{udid[:8]}] 失败: {e}\n")

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
    import socket
    # 简单的单例运行保护：尝试绑定一个特定端口，如果失败则说明程序已在运行
    try:
        lock_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        lock_socket.bind(('127.0.0.1', 47231)) # 使用一个不常用的端口作为锁
    except socket.error:
        # 如果端口被占用，说明已有实例运行，直接退出
        sys.exit(0)

    # 适配高分屏 (必须在 QApplication 实例化之前设置)
    QApplication.setAttribute(Qt.AA_EnableHighDpiScaling, True)
    QApplication.setAttribute(Qt.AA_UseHighDpiPixmaps, True)

    app = QApplication(sys.argv)
    
    gui = ECHelperGUI()
    gui.show()
    sys.exit(app.exec_())
