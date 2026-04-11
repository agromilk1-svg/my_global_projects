# -*- coding: utf-8 -*-
"""
WiFi WDA 启动器 (v1930)
完全绕过 tidevice 的 house_arrest 限制，直接通过 instruments 协议启动 TrollStore 系统级 WDA。

核心思路：
  tidevice 在启动 xctest 时需要通过 VendContainer 将配置文件推送到应用沙盒，
  但对于 TrollStore 注册的系统级应用，WiFi 模式下 house_arrest 会拒绝访问。
  本脚本通过直接访问 instruments 远程服务，跳过文件推送步骤，
  利用 ECMAIN 已存在的 HTTP 接口在设备端写入配置文件。
"""

import logging
import sys
import os
import uuid
import time
import threading
import struct

logger = logging.getLogger("WiFiWDALauncher")
logging.basicConfig(level=logging.INFO, format='[%(levelname)s] %(message)s')

# 添加 tidevice 的模块路径
VENV_SITE = os.path.join(os.path.dirname(__file__), '..', 'venv', 'lib')
# 查找 python 版本目录
for d in os.listdir(VENV_SITE) if os.path.isdir(VENV_SITE) else []:
    sp = os.path.join(VENV_SITE, d, 'site-packages')
    if os.path.isdir(sp) and sp not in sys.path:
        sys.path.insert(0, sp)


def launch_wda_wifi(hw_udid: str, bundle_id: str = "com.apple.accessibility.ecwda", device_ip: str = None):
    """
    通过 WiFi 网络启动设备上的 WDA XCTest 服务。
    
    参数:
        hw_udid: 设备的40位物理硬件 UDID
        bundle_id: WDA 的 Bundle ID
        device_ip: 设备的 WiFi IP 地址 (用于通过 ECMAIN HTTP 写入配置文件)
    
    返回:
        bool: 是否成功启动
    """
    from tidevice._device import BaseDevice
    from tidevice._usbmux import Usbmux
    
    logger.info(f"🚀 WiFi WDA 启动器 v1930 - 目标: {hw_udid}")
    
    # 1. 连接设备
    um = Usbmux()
    device = None
    for dev in um.device_list():
        if dev.udid == hw_udid:
            device = dev
            break
    
    if not device:
        logger.error(f"❌ 在 usbmuxd 中未找到设备 {hw_udid}")
        return False
    
    logger.info(f"✅ 找到设备: {device.udid} (conn_type={device.conn_type})")
    
    d = BaseDevice(hw_udid, um)
    
    # 2. 查找应用信息
    logger.info(f"🔍 查找应用 {bundle_id}...")
    app_info = d.installation.lookup(bundle_id)
    if not app_info:
        logger.error(f"❌ 未找到应用 {bundle_id}")
        return False
    
    app_path = app_info['Path']
    app_container = app_info.get('Container', '')
    exec_name = app_info['CFBundleExecutable']
    logger.info(f"  Path: {app_path}")
    logger.info(f"  Container: {app_container}")
    logger.info(f"  Executable: {exec_name}")
    
    assert exec_name.endswith("-Runner"), f"非法 CFBundleExecutable: {exec_name}"
    target_name = exec_name[:-len("-Runner")]
    
    # 3. 生成 xctest 配置
    session_identifier = uuid.uuid4()
    xctest_path = f"/tmp/{target_name}-{str(session_identifier).upper()}.xctestconfiguration"
    
    from tidevice import bplist
    xctest_configuration = bplist.XCTestConfiguration({
        "testBundleURL": bplist.NSURL(None, f"file://{app_path}/PlugIns/{target_name}.xctest"),
        "sessionIdentifier": session_identifier,
        "targetApplicationBundleID": None,
        "targetApplicationArguments": [],
        "targetApplicationEnvironment": {},
        "testsToRun": set(),
        "testsMustRunOnMainThread": True,
        "reportResultsToIDE": True,
        "reportActivities": True,
        "automationFrameworkPath": "/Developer/Library/PrivateFrameworks/XCTAutomationSupport.framework",
    })
    xctest_content = bplist.objc_encode(xctest_configuration)
    
    # 4. 通过 ECMAIN HTTP 在设备上写入配置文件 (绕过 house_arrest!)
    xctestconfiguration_path = app_container + xctest_path
    
    if device_ip:
        logger.info(f"📡 通过 ECMAIN HTTP 写入配置文件到设备...")
        import requests
        import base64
        try:
            resp = requests.post(
                f"http://{device_ip}:8089/write-file",
                json={
                    "path": xctestconfiguration_path,
                    "content_b64": base64.b64encode(xctest_content).decode(),
                },
                timeout=5
            )
            if resp.status_code == 200:
                logger.info(f"  ✅ 配置文件已写入设备: {xctestconfiguration_path}")
            else:
                logger.warning(f"  ⚠️ HTTP 写入返回 {resp.status_code}, 尝试继续...")
        except Exception as e:
            logger.warning(f"  ⚠️ HTTP 写入失败: {e}, 尝试继续...")
    
    # 5. 尝试通过 VendContainer 写入 (可能在 USB 下成功)
    if not device_ip:
        try:
            fsync = d.app_sync(bundle_id, command="VendContainer")
            for fname in fsync.listdir("/tmp"):
                if fname.endswith(".xctestconfiguration"):
                    fsync.remove("/tmp/" + fname)
            fsync.push_content(xctest_path, xctest_content)
            logger.info("✅ VendContainer 写入成功")
        except Exception as e:
            logger.warning(f"⚠️ VendContainer 失败: {e}, 跳过文件推送")
    
    # 6. 通过 instruments 启动应用
    logger.info("🔧 连接 instruments 服务...")
    
    XCODE_VERSION = 29
    quit_event = threading.Event()
    
    # IDE 1st connection
    x1 = d._connect_testmanagerd_lockdown()
    x1_daemon_chan = x1.make_channel(
        'dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface'
    )
    
    from tidevice._instruments import AUXMessageBuffer
    if d.major_version() >= 11:
        aux = AUXMessageBuffer()
        aux.append_obj(XCODE_VERSION)
        x1.call_message(x1_daemon_chan, '_IDE_initiateControlSessionWithProtocolVersion:', aux)
    x1.register_callback("cycled", lambda _: quit_event.set())
    
    # IDE 2nd connection
    x2 = d._connect_testmanagerd_lockdown()
    x2_daemon_chan = x2.make_channel(
        'dtxproxy:XCTestManager_IDEInterface:XCTestManager_DaemonConnectionInterface'
    )
    x2.register_callback("cycled", lambda _: quit_event.set())
    
    _start_flag = threading.Event()
    
    def _start_executing(m=None):
        if _start_flag.is_set():
            return
        _start_flag.set()
        logger.info("▶️ 开始执行测试计划...")
        x2.call_message(0xFFFFFFFF, '_IDE_startExecutingTestPlanWithProtocolVersion:', 
                       [XCODE_VERSION], expects_reply=False)
    
    def _show_log_message(m):
        if m and m.result and len(m.result) > 1:
            msg = ''.join(str(x) for x in m.result[1]) if isinstance(m.result[1], (list, tuple)) else str(m.result[1])
            if 'Received test runner ready reply' in msg:
                logger.info("✅ Test runner ready!")
                _start_executing()
            if 'ServerURLHere' in msg:
                logger.info(f"🎉 WDA 启动成功! {msg.strip()}")
    
    from tidevice._instruments import DTXPayload, DTXMessage, Event, AUXMessageBuffer
    
    def _ready_with_caps_callback(m):
        x2.send_dtx_message(m.channel_id,
                           payload=DTXPayload.build_other(0x03, xctest_configuration),
                           message_id=m.message_id)
    
    x2.register_callback('_XCT_testBundleReadyWithProtocolVersion:minimumVersion:', _start_executing)
    x2.register_callback('_XCT_logDebugMessage:', _show_log_message)
    x2.register_callback('_XCT_testRunnerReadyWithCapabilities:', _ready_with_caps_callback)
    
    # 发起 IDE session
    aux = AUXMessageBuffer()
    aux.append_obj(session_identifier)
    aux.append_obj(str(session_identifier) + '-6722-000247F15966B083')
    aux.append_obj('/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild')
    aux.append_obj(XCODE_VERSION)
    result = x2.call_message(x2_daemon_chan, 
                             '_IDE_initiateSessionWithIdentifier:forClient:atPath:protocolVersion:', 
                             aux)
    if "NSError" in str(result):
        logger.error(f"❌ IDE Session 初始化失败: {result}")
        return False
    
    # 7. 启动 WDA 应用进程
    logger.info("🚀 正在启动 WDA 进程...")
    
    from tidevice._instruments import InstrumentsService, ServiceInstruments
    conn = d.connect_instruments()
    channel = conn.make_channel(InstrumentsService.ProcessControl)
    
    conn.call_message(channel, "processIdentifierForBundleIdentifier:", [bundle_id])
    
    app_env = {
        'CA_ASSERT_MAIN_THREAD_TRANSACTIONS': '0',
        'CA_DEBUG_TRANSACTIONS': '0',
        'DYLD_FRAMEWORK_PATH': app_path + '/Frameworks:',
        'DYLD_LIBRARY_PATH': app_path + '/Frameworks',
        'MTC_CRASH_ON_REPORT': '1',
        'NSUnbufferedIO': 'YES',
        'SQLITE_ENABLE_THREAD_ASSERTIONS': '1',
        'WDA_PRODUCT_BUNDLE_IDENTIFIER': '',
        'XCTestBundlePath': f"{app_path}/PlugIns/{target_name}.xctest",
        'XCTestConfigurationFilePath': xctestconfiguration_path,
        'XCODE_DBG_XPC_EXCLUSIONS': 'com.apple.dt.xctestSymbolicator',
        'MJPEG_SERVER_PORT': '',
        'USE_PORT': '',
        'LLVM_PROFILE_FILE': app_container + "/tmp/%p.profraw",
    }
    
    if d.major_version() >= 11:
        app_env['DYLD_INSERT_LIBRARIES'] = '/Developer/usr/lib/libMainThreadChecker.dylib'
        app_env['OS_ACTIVITY_DT_MODE'] = 'YES'
    
    app_args = ['-NSTreatUnknownArgumentsAsOpen', 'NO', '-ApplePersistenceIgnoreState', 'YES']
    app_options = {'StartSuspendedKey': False}
    if d.major_version() >= 12:
        app_options['ActivateSuspended'] = True
    
    pid = conn.call_message(
        channel,
        "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:",
        [app_path, bundle_id, app_env, app_args, app_options]
    )
    
    if not isinstance(pid, int):
        logger.error(f"❌ 进程启动失败: {pid}")
        return False
    
    logger.info(f"✅ WDA 进程已启动! PID: {pid}")
    
    # 授权测试会话
    aux = AUXMessageBuffer()
    aux.append_obj(pid)
    if d.major_version() >= 12:
        result = x1.call_message(x1_daemon_chan, '_IDE_authorizeTestSessionWithProcessID:', aux)
    elif d.major_version() <= 9:
        result = x1.call_message(x1_daemon_chan, '_IDE_initiateControlSessionForTestProcessID:', aux)
    else:
        aux.append_obj(XCODE_VERSION)
        result = x1.call_message(x1_daemon_chan, '_IDE_initiateControlSessionForTestProcessID:protocolVersion:', aux)
    
    if "NSError" in str(result):
        logger.error(f"❌ 授权失败: {result}")
        return False
    
    logger.info("✅ 测试会话已授权，WDA 正在初始化...")
    
    # 8. 等待 WDA 完全启动 (最多30秒)
    started = quit_event.wait(timeout=30)
    if not started:
        logger.info("⏳ WDA 仍在运行中 (30秒内未退出，这是正常的)")
    
    return True


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"用法: {sys.argv[0]} <hw_udid> [device_ip]")
        sys.exit(1)
    
    hw_udid = sys.argv[1]
    device_ip = sys.argv[2] if len(sys.argv) > 2 else None
    
    success = launch_wda_wifi(hw_udid, device_ip=device_ip)
    sys.exit(0 if success else 1)
