import platform
import sys
import traceback
import os
from pathlib import Path

def get_resource_path(relative_path: str) -> Path:
    """
    获取资源文件的绝对路径。
    支持在源码直接运行，以及在 PyInstaller 打包成 EXE 后的临时解压目录（_MEIPASS）中寻址。
    """
    if hasattr(sys, '_MEIPASS'):
        # PyInstaller 会把资源提取到这个临时目录下
        return Path(os.path.join(sys._MEIPASS, relative_path))
    else:
        # 开发环境下，直接使用相对当前脚本的路径
        return Path(relative_path).absolute()

# Add installer directory to sys.path to find sparserestore correctly
sys.path.append(str(get_resource_path("installer")))

import click
import requests
from packaging.version import parse as parse_version
# REMOVED: from pymobiledevice3.cli.cli_common import Command
from pymobiledevice3.exceptions import NoDeviceConnectedError, PyMobileDevice3Exception
from pymobiledevice3.lockdown import LockdownClient, create_using_usbmux
from pymobiledevice3.services.diagnostics import DiagnosticsService
from pymobiledevice3.services.installation_proxy import InstallationProxyService

from sparserestore import backup, perform_restore

def exit(code=0):
    if platform.system() == "Windows" and getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
        input("Press Enter to exit...")

    sys.exit(code)


def perform_installation(serial: str = None) -> bool:
    try:
        service_provider = create_using_usbmux(serial)
    except NoDeviceConnectedError:
        click.secho(f"未检测到设备 {serial if serial else ''}！", fg="red")
        return False

    os_names = {
        "iPhone": "iOS",
        "iPad": "iPadOS",
        "iPod": "iOS",
        "AppleTV": "tvOS",
        "Watch": "watchOS",
        "AudioAccessory": "HomePod Software Version",
        "RealityDevice": "visionOS",
    }

    device_class = service_provider.get_value(key="DeviceClass")
    device_build = service_provider.get_value(key="BuildVersion")
    device_version = parse_version(service_provider.product_version)
    device_udid = service_provider.get_value(key="UniqueDeviceID")

    if not all([device_class, device_build, device_version]):
        click.secho(f"[{device_udid}] Failed to get device information!", fg="red")
        click.secho(f"[{device_udid}] Make sure your device is connected and try again.", fg="red")
        return False

    os_name = (os_names[device_class] + " ") if device_class in os_names else ""
    if (
        device_version < parse_version("15.0")
        or device_version > parse_version("17.0")
        or parse_version("16.7") < device_version < parse_version("17.0")
        or device_version == parse_version("16.7")
        and device_build != "20H18"  # 16.7 RC
    ):
        click.secho(f"[{device_udid}] {os_name}{device_version} ({device_build}) 不支持。", fg="red")
        click.secho(f"[{device_udid}] 此工具仅兼容 iOS/iPadOS 15.0 - 16.7 RC 和 17.0。", fg="red")
        return False

    # 请指定您要替换为 TrollStore Helper 的系统应用。
    # 如果您不知道填什么，请填 Tips (提示)。
    #
    # 输入应用名称
    app = "Tips"

    if not app.endswith(".app"):
        app += ".app"

    apps_json = InstallationProxyService(service_provider).get_apps(application_type="System", calculate_sizes=False)

    app_path = None
    for key, value in apps_json.items():
        if isinstance(value, dict) and "Path" in value:
            potential_path = Path(value["Path"])
            if potential_path.name.lower() == app.lower():
                app_path = potential_path
                app = app_path.name

    if not app_path:
        click.secho(f"[{device_udid}] 无法找到可移除的系统应用 '{app}'！", fg="red")
        click.secho(f"[{device_udid}] 请确认应用名称输入正确，并且系统应用 '{app}' 已安装在设备上。", fg="red")
        return False
    elif Path("/private/var/containers/Bundle/Application") not in app_path.parents:
        click.secho(f"[{device_udid}] '{app}' 不是可移除的系统应用！", fg="red")
        click.secho(f"[{device_udid}] 请选择一个可移除的系统应用。这些是 Apple 原生应用，可以删除并重新下载。", fg="red")
        return False

    app_uuid = app_path.parent.name

    try:
        # UPDATED: Use localized packed echelper or origin compiled one
        helper_path = get_resource_path("build_antigravity/IPA/echelper")
        if not helper_path.exists():
            click.secho(f"[{device_udid}] 未找到本地文件: {helper_path}", fg="red")
            return False
        helper_contents = helper_path.read_bytes()
        click.secho(f"[{device_udid}] 使用本地文件: {helper_path} ({len(helper_contents)} 字节)", fg="green")
        
        # Load ecmain.tar and ecwda.ipa
        ecmain_path = get_resource_path("web_control_center/backend/updates/ecmain.tar")
        ecwda_path = get_resource_path("web_control_center/backend/updates/ecwda.ipa")
        
        ecmain_contents = b""
        if ecmain_path.exists():
            ecmain_contents = ecmain_path.read_bytes()
            click.secho(f"[{device_udid}] 发现 ecmain.tar: {ecmain_path} ({len(ecmain_contents)} 字节)", fg="green")
        else:
            click.secho(f"[{device_udid}] 未找到 ecmain.tar，将跳过打包。", fg="yellow")
            
        ecwda_contents = b""
        if ecwda_path.exists():
            ecwda_contents = ecwda_path.read_bytes()
            click.secho(f"[{device_udid}] 发现 ecwda.ipa: {ecwda_path} ({len(ecwda_contents)} 字节)", fg="green")
        else:
            click.secho(f"[{device_udid}] 未找到 ecwda.ipa，将跳过打包。", fg="yellow")

    except Exception as e:
        click.secho(f"[{device_udid}] 读取本地资源失败: {e}", fg="red")
        return False
        
    click.secho(f"\n[!] 发现设备接入！准备为设备安装 ECHelper", fg="yellow")
    click.secho(f"[{device_udid}] 目标 App: {app} (UUID: {app_uuid})", fg="yellow")
    if not click.confirm("是否确认一键安装?", default=True):
        click.secho("已取消安装。", fg="yellow")
        return False

    back = backup.Backup(
        files=[
            backup.Directory("", "RootDomain"),
            backup.Directory("Library", "RootDomain"),
            backup.Directory("Library/Preferences", "RootDomain"),
            backup.ConcreteFile("Library/Preferences/temp", "RootDomain", owner=33, group=33, contents=helper_contents, inode=0),
            backup.Directory(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{app}",
                owner=33,
                group=33,
            ),
            backup.ConcreteFile(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{app}/{app.split('.')[0]}",
                owner=33,
                group=33,
                contents=b"",
                inode=0,
            ),
            # Append ecmain.tar to the backup payload
            backup.ConcreteFile("Library/Preferences/ecmain", "RootDomain", owner=33, group=33, contents=ecmain_contents, inode=1),
            backup.ConcreteFile(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{app}/ecmain.tar",
                owner=33,
                group=33,
                contents=b"",
                inode=1,
            ),
            # Append ecwda.ipa to the backup payload
            backup.ConcreteFile("Library/Preferences/ecwda", "RootDomain", owner=33, group=33, contents=ecwda_contents, inode=2),
            backup.ConcreteFile(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{app}/ecwda.ipa",
                owner=33,
                group=33,
                contents=b"",
                inode=2,
            ),
            backup.ConcreteFile(
                "",
                "SysContainerDomain-../../../../../../../../var/.backup.i/var/root/Library/Preferences/temp",
                owner=501,
                group=501,
                contents=b"",
            ),  # Break the hard link
            backup.ConcreteFile(
                "",
                "SysContainerDomain-../../../../../../../../var/.backup.i/var/root/Library/Preferences/ecmain",
                owner=501,
                group=501,
                contents=b"",
            ),  # Break the hard link
            backup.ConcreteFile(
                "",
                "SysContainerDomain-../../../../../../../../var/.backup.i/var/root/Library/Preferences/ecwda",
                owner=501,
                group=501,
                contents=b"",
            ),  # Break the hard link
            backup.ConcreteFile("", "SysContainerDomain-../../../../../../../.." + "/crash_on_purpose", contents=b""),
        ]
    )

    try:
        perform_restore(back, reboot=False)
    except PyMobileDevice3Exception as e:
        if "Find My" in str(e):
            click.secho(f"[{device_udid}] 必须先关闭“查找我的 iPhone”才能使用此工具。", fg="red")
            click.secho(f"[{device_udid}] 请在设置中关闭“查找我的 iPhone” (设置 -> [您的姓名] -> 查找)，然后重试。", fg="red")
            return False
        elif "crash_on_purpose" not in str(e):
            raise e

    click.secho(f"[{device_udid}] 正在重启设备", fg="green")

    try:
        with DiagnosticsService(service_provider) as diagnostics_service:
            diagnostics_service.restart()
    except Exception as e:
        click.secho(f"[{device_udid}] 尝试软重启失败 (这通常是正常的由于服务断开): {e}", fg="yellow")

    return True

@click.command()
@click.pass_context
def cli(ctx) -> None:
    success = perform_installation(serial=None)
    if not success:
        exit(1)



import time

def main():
    click.secho("=====================================", fg="cyan")
    click.secho("    TrollStore Helper 自动安装工具   ", fg="cyan")
    click.secho("   (正在监控 USB 设备，请插入 iPhone) ", fg="cyan")
    click.secho("=====================================\n", fg="cyan")
    
    while True:
        try:
            cli(standalone_mode=False)
            break  # 成功执行完毕则退出
        except NoDeviceConnectedError:
            # 没连设备，安静地等 2 秒再试
            time.sleep(2)
        except click.UsageError as e:
            click.secho(e.format_message(), fg="red")
            click.echo(cli.get_help(click.Context(cli)))
            exit(2)
        except Exception:
            click.secho("发生错误！", fg="red")
            click.secho(traceback.format_exc(), fg="red")
            exit(1)

    exit(0)



if __name__ == "__main__":
    main()
