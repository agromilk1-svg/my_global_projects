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
                             QHBoxLayout, QPushButton, QTextEdit, QLabel, QProgressBar, QListWidget, QListWidgetItem, QSplitter, QCheckBox)
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
if len(sys.argv) >= 3 and sys.argv[1] == "-m" and sys.argv[2] == "tidevice":
    if HAS_TIDEVICE:
        # [动态修复] 针对 tidevice 无法拉起通过漏洞底层安装的无沙盒特权 App 的问题
        # 我们在这里拦截 tidevice 的运行并注入底层 Hook
        try:
            import tidevice._device as td
            # 1. 允许直接指定 bundle_id 跳过 User 类型枚举
            td.Device._fnmatch_find_bundle_id = lambda self, b: b
            
            # 2. 欺骗系统，将该底核进程所在的容器环境强制定向到公用的媒体子系统
            orig_lookup = td.Installation.lookup
            def patched_lookup(self, bundle_id):
                info = orig_lookup(self, bundle_id)
                if info and bundle_id == "com.apple.accessibility.ecwda":
                    info['Container'] = '/var/mobile/Media'
                return info
            td.Installation.lookup = patched_lookup
            
            # 3. 将其试图进行的内部文件推送强制降级为公用 AFC (直接操作媒体盘)
            orig_app_sync = td.Device.app_sync
            def patched_app_sync(self, bundle_id, command="VendDocuments"):
                if bundle_id == "com.apple.accessibility.ecwda":
                    import tidevice._sync as tdsync
                    conn = self.start_service("com.apple.afc")
                    afc = tdsync.Sync(conn)
                    try:
                        afc.listdir("/tmp")
                    except Exception:
                        afc.mkdir("/tmp")
                    return afc
                return orig_app_sync(self, bundle_id, command)
            td.Device.app_sync = patched_app_sync
        except Exception as e:
            import logging
            logging.error(f"Failed to inject ecwda patches: {e}")
            pass

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
        # 在源码环境下，我们将指令重新引回本身脚本以触发上方的 "-m tidevice" 拦截，应用补丁
        cmd = [sys.executable, os.path.abspath(__file__), "-m", "tidevice"] + list(args_list)
    
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
            from types import SimpleNamespace
            last_res = SimpleNamespace(returncode=-1, stdout="", stderr=f"[{e.__class__.__name__}] {e}")
            time.sleep(1)
            
    if wait and last_res and last_res.returncode != 0:
        err_msg = getattr(last_res, 'stderr', "Unknown Error")
        logging.error(f"tidevice 指令最终失败: {' '.join(cmd)}\n最后报错: {err_msg}")
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
        return Path(os.path.dirname(os.path.abspath(__file__))).joinpath(relative_path).absolute()
sys.path.append(str(get_resource_path("installer")))

# 导入 pymobiledevice3 检测设备
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.exceptions import NoDeviceConnectedError
from packaging.version import parse as parse_version

# 导入静默安装核心
import install_echelper

def get_best_match_image(target_version_str: str) -> Path:
    """在 device-support 目录下寻找最接近的可用 iOS 镜像版本"""
    ds_dir = get_resource_path("device-support")
    if not ds_dir.exists():
        return None
        
    try:
        tv = parse_version(target_version_str)
        best_match_dir = None
        min_diff = float('inf')
        
        for d in ds_dir.iterdir():
            if d.is_dir() and d.name.count('.') >= 1:
                try:
                    dv = parse_version(d.name)
                    # 优先匹配大版本号，再匹配最近的子版本
                    if tv.major == dv.major:
                        diff = abs(tv.minor - dv.minor)
                        if diff < min_diff:
                            min_diff = diff
                            best_match_dir = d
                except:
                    pass
        return best_match_dir
    except:
        return None

def auto_mount_developer_image(udid, log_func=None):
    """自动判断设备的 Developer 镜像状态，缺失则自动注入"""
    try:
        from pymobiledevice3.services.mobile_image_mounter import MobileImageMounterService
        service_provider = create_using_usbmux(serial=udid)
        ver = service_provider.product_version
        
        with MobileImageMounterService(lockdown=service_provider) as mounter:
            if mounter.is_image_mounted("Developer"):
                return True
                
            if log_func:
                log_func(f"   💡 [{udid[:8]}] 侦测到该设备未启蒙 (缺失 Developer 镜像)！准备静默重塑核心池...")
                
            img_dir = get_best_match_image(ver)
            if not img_dir:
                if log_func:
                    log_func(f"   ⚠️ [{udid[:8]}] 本工程的 'device-support' 文件夹内缺少针对 iOS {ver} 的关联镜像，可能遭遇启蒙挫败！")
                return False
                
            dmg_path = img_dir / "DeveloperDiskImage.dmg"
            sig_path = img_dir / "DeveloperDiskImage.dmg.signature"
            
            if not dmg_path.exists() or not sig_path.exists():
                return False
                
            if log_func:
                log_func(f"   ⏳ [{udid[:8]}] 正在向设备骨干注入 {img_dir.name} 版本开发者映像，耗时约 5 秒...")
            
            with open(sig_path, 'rb') as f:
                sig_data = f.read()
            with open(dmg_path, 'rb') as f:
                dmg_data = f.read()
                
            mounter.upload_image("Developer", dmg_data, sig_data)
            mounter.mount_image("Developer", sig_data)
            
            if log_func:
                log_func(f"   ✅ [{udid[:8]}] 开发者镜像固化完毕！设备现已支持底层调试及无线越狱！")
            return True
            
    except Exception as e:
        if log_func:
            log_func(f"   ❌ [{udid[:8]}] 核心镜像写入异常: [{e.__class__.__name__}] {e}")
        return False

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
                    # [修改] 之前过滤了 WiFi 虚拟连接 (network)，现在为了无线调试开启，放宽至全部显示！
                    conn_type_str = str(getattr(dev, "connection_type", "")).lower()
                    # 不再执行 continue 阻断
                        
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
                            'connection': connection_type,
                            'trusted': True
                        })
                        current_udids.add(device_udid)
                    except Exception:
                        # 设备未解锁或未信任电脑会抛出异常，此时仍需要显示在列表供用户排查
                        device_udid = dev.serial
                        connection_type = getattr(dev, "connection_type", "Unknown")
                        current_devices.append({
                            'udid': device_udid,
                            'name': "未解锁或未信任",
                            'version': "???",
                            'build': "请在手机上点击信任",
                            'connection': connection_type,
                            'trusted': False
                        })
                        current_udids.add(device_udid)
                        
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
                
                # IPA 预传输已移除，直接进入安装阶段
                
                # ==========================================================
                # 第二阶段：执行正式的 ECHelper 底层漏洞安装 (此时会引发重启)
                # ==========================================================
                success = install_echelper.perform_installation(serial=udid)
                if not success:
                    all_success = False
                    self.log_signal.emit(f"\\n❌ 设备 {udid[:8]} 安装失败！")
                else:
                    self.log_signal.emit(f"\\n✅ 设备 {udid[:8]} 安装成功！(注意: 设备重启中)")

                    # 使用内部模拟调用，不再依赖 PATH
                    self.log_signal.emit(f"🚀 正在通过内置组件拉起 ECHelper 触发底核部署...")
                    try:
                        if HAS_TIDEVICE:
                            # 启动后 ECMAIN 会常驻，这里加个超时或者后台跑
                            t_thread = threading.Thread(target=tidevice_invoke, args=(["-u", udid, "launch", "com.apple.Tips"],))
                            t_thread.start()
                            self.log_signal.emit("   ✅ 指令已下发！如果设备未自动拉起请开机后手动打开 [提示] App")
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
    finished_signal = pyqtSignal(bool)

    BUNDLE_ID = "com.apple.accessibility.ecwda"

    def __init__(self, udids):
        super().__init__()
        self.udids = udids

    def run(self):
        self.log_signal.emit(f"🚀 准备为 {len(self.udids)} 台设备启动 ECWDA...")

        if not HAS_TIDEVICE:
            self.log_signal.emit("❌ 运行环境中缺失内置驱动库，请检查安装！")
            self.finished_signal.emit(False)
            return

        # ── 清理旧的 tidevice 残留进程 ────────────────────────────────────────
        try:
            p_kill_cmd = (["taskkill", "/F", "/IM", "tidevice.exe"]
                         if platform.system() == "Windows" else ["pkill", "-f", "tidevice"])
            subprocess.run(p_kill_cmd, capture_output=True)
            self.log_signal.emit("✅ 旧残留守护进程已清场")
        except Exception:
            pass

        time.sleep(1)

        all_ok = True
        try:
            for i, udid in enumerate(self.udids):
                short = udid[:8]
                self.log_signal.emit(f"\n🔧 [{short}] 设备 {i+1}/{len(self.udids)} 开始处理")

                wda_port  = 10088 + i * 10
                wda_port2 = 10089 + i * 10

                # ── 第 1 步：挂载 Developer 镜像（必须成功，否则 testmanagerd 无法命令 xctest）──
                self.log_signal.emit(f"   💿 [{short}] 正在检查并挂载 Developer 镜像...")
                img_ok = auto_mount_developer_image(udid, self.log_signal.emit)
                if not img_ok:
                    self.log_signal.emit(
                        f"   ❌ [{short}] Developer 镜像挂载失败！"
                        f"无法启动 WDA，跳过此设备。\n"
                        f"      请确认 device-support 目录下是否存在匹配 iOS 版本的"
                        f" DeveloperDiskImage.dmg 及签名文件。"
                    )
                    all_ok = False
                    continue  # 跳过该设备，不要尝试搭建 relay

                # ── 第 2 步：建立 USB 端口转发通道（relay）──────────────────
                self.log_signal.emit(
                    f"   🔗 [{short}] 建立 USB 端口转发: "
                    f"PC {wda_port} → 手机 10088 / PC {wda_port2} → 手机 10089"
                )
                for local_p, remote_p in [(wda_port, 10088), (wda_port2, 10089)]:
                    tidevice_exec(["-u", udid, "relay", str(local_p), str(remote_p)], wait=False)
                time.sleep(1)  # 等待 relay 进程就绪

                # ── 第 3 步：通过 xctest 启动 WDA（WDA 必须以 XCTest runner 方式运行）──
                self.log_signal.emit(
                    f"   ▶️  [{short}] 通过 tidevice xctest 启动 WDA "
                    f"(bundle: {self.BUNDLE_ID})..."
                )
                tidevice_exec(
                    ["-u", udid, "xctest", "-B", self.BUNDLE_ID],
                    wait=False
                )
                self.log_signal.emit(
                    f"   ✅ [{short}] xctest 指令已发出，WDA 进程通常需要 5～15 秒内在手机端就绪。"
                    f"\n      手机端可在屏幕上看到 ecwda 应用首页启动。"
                    f"\n      PC 可通过 http://127.0.0.1:{wda_port}/status 确认 WDA 状态。"
                )

            result_str = "🎉 所有设备 ECWDA 启动指令已发出！" if all_ok else \
                         "⚠️  部分设备 Developer 镜像挂载失败，已跳过。"
            self.log_signal.emit(f"\n{result_str}")
            self.finished_signal.emit(all_ok)

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
        self.wda_bundle = "com.apple.accessibility.ecwda"

    def stop(self):
        self._running = False

    def _check_wda(self, port, timeout=3):
        """通过 HTTP 探测 WDA 是否在线。不使用 TCP connect，防止 relay 进程造成假阳性。"""
        import urllib.request, json
        try:
            resp = urllib.request.urlopen(f"http://127.0.0.1:{port}/status", timeout=timeout)
            if resp.status != 200:
                return False
            data = json.loads(resp.read().decode("utf-8", errors="ignore"))
            return isinstance(data, dict) and any(k in data for k in ("sessionId", "status", "value"))
        except Exception:
            return False

    def _launch_and_relay(self, udid, port_base):
        """
        看护者重新拉起 WDA。
        正确顺序： Developer 镜像挂载 → relay 复活 → xctest
        """
        short = udid[:8]
        self.log_signal.emit(f"   🔁 [{short}] 看护者：重新拉起 WDA...")

        # 挂载 Developer 镜像（看护场景不阻塞，失败也继续尝试 xctest）
        auto_mount_developer_image(udid, self.log_signal.emit)

        # 复活 relay 端口转发
        for local_p, remote_p in [(port_base, 10088), (port_base + 1, 10089)]:
            tidevice_exec(["-u", udid, "relay", str(local_p), str(remote_p)], wait=False)
        time.sleep(0.5)

        # 重新通过 xctest 启动 WDA
        tidevice_exec(["-u", udid, "xctest", "-B", self.wda_bundle], wait=False)
        self.log_signal.emit(f"   ✅ [{short}] xctest 启动指令已重新派发。")

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
        # [重要] 延迟到 Qt 事件循环启动后再开始监控，防止 pymobiledevice3 与 Qt
        # C 扩展在初始化阶段并发操作同一内存对象造成 double free 崩溃
        from PyQt5.QtCore import QTimer
        QTimer.singleShot(600, self.start_monitoring)

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
        
        # 列表与全选框容器
        list_container = QWidget()
        list_layout = QVBoxLayout(list_container)
        list_layout.setContentsMargins(0, 0, 0, 0)
        list_layout.setSpacing(5)

        # 顶部工具栏（全选 + 扫描按钮）
        top_bar_layout = QHBoxLayout()
        
        self.select_all_cb = QCheckBox("全选 / 取消全选")
        self.select_all_cb.setFont(QFont("Microsoft YaHei", 12))
        self.select_all_cb.setStyleSheet("color: #2f3542; margin-left: 5px;")
        self.select_all_cb.stateChanged.connect(self.toggle_select_all)
        top_bar_layout.addWidget(self.select_all_cb)

        top_bar_layout.addStretch()

        self.refresh_btn = QPushButton("🔄 扫描设备")
        self.refresh_btn.setFont(QFont("Microsoft YaHei", 11))
        self.refresh_btn.setCursor(Qt.PointingHandCursor)
        self.refresh_btn.setStyleSheet("""
            QPushButton {
                background-color: #f1f2f6;
                color: #2f3542;
                border: 1px solid #ced6e0;
                border-radius: 4px;
                padding: 4px 12px;
            }
            QPushButton:hover {
                background-color: #dfe4ea;
            }
        """)
        self.refresh_btn.clicked.connect(self.force_refresh_devices)
        top_bar_layout.addWidget(self.refresh_btn)

        list_layout.addLayout(top_bar_layout)

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
        list_layout.addWidget(self.device_list)
        
        self.splitter.addWidget(list_container)

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

    def force_refresh_devices(self):
        """强制打断并重启设备监控线程，实现手动触发重搜"""
        self.append_log("🔄 正在强制重新扫描设备列表...\n")
        self.refresh_btn.setEnabled(False)
        
        if hasattr(self, 'monitor_thread') and self.monitor_thread.isRunning():
            self.monitor_thread.terminate()  # 简单粗暴中断以切断可能挂起的底层连接
            self.monitor_thread.wait(1000)
            
        self.start_monitoring()
        
        # 1.5 秒后恢复按钮可点击状态，防止狂点
        import threading
        threading.Timer(1.5, lambda: self.refresh_btn.setEnabled(True)).start()

    def toggle_select_all(self, state):
        check_state = Qt.Checked if state == Qt.Checked else Qt.Unchecked
        for i in range(self.device_list.count()):
            item = self.device_list.item(i)
            if item.flags() & Qt.ItemIsUserCheckable:
                item.setCheckState(check_state)

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

        from PyQt5.QtGui import QColor
        for dev in current_devices:
            conn_tag = " [USB]" if dev['connection'] == "USB" else " [网络]"
            is_trusted = dev.get('trusted', True)
            
            if is_trusted:
                text = f"📱 {dev['name']} {dev['version']} ({dev['build']}){conn_tag}  [{dev['udid'][:8]}]"
            else:
                text = f"🔒 {dev['name']} ({dev['build']}){conn_tag}  [{dev['udid'][:8]}]"
                
            item = QListWidgetItem(text)
            item.setData(Qt.UserRole, dev['udid'])
            
            if is_trusted:
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
            else:
                # 不允许操作未信任的设备
                item.setFlags(item.flags() & ~Qt.ItemIsUserCheckable)
                item.setForeground(QColor("#e84118"))  # 使用红色突出提示
            
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

    def on_launch_finished(self, success):
        """ECWDA 启动线程结束回调 -- 一定在主线程被执行"""
        self.progress_bar.setRange(0, 100)
        self.progress_bar.setValue(100)
        self.launch_btn.setEnabled(True)
        if success:
            self.launch_btn.setText("✅ ECWDA 已就位")
            self.launch_btn.setStyleSheet("""
                QPushButton { background-color: #2ed573; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #26de81; }
            """)
        else:
            self.launch_btn.setText("❌ 启动失败，点击重试")
            self.launch_btn.setStyleSheet("""
                QPushButton { background-color: #ff4757; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #ff6b81; }
            """)
        # 3 秒后恢复默认按钮文字和样式，允许重试
        import threading
        def _reset():
            time.sleep(3)
            self.launch_btn.setText("🚀 启动 ECWDA")
            self.launch_btn.setStyleSheet("""
                QPushButton { background-color: #3742fa; color: white; border-radius: 8px; }
                QPushButton:hover { background-color: #5352ed; }
            """)
        threading.Thread(target=_reset, daemon=True).start()

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
                self.append_log(f"   [{udid[:8]}] 正在注入网络重塑指令...")
                # 在向设备下达无线指令前，它必须具备开发者身份镜像
                auto_mount_developer_image(udid, self.append_log)
                
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
