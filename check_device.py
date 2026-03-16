import sys
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.lockdown import create_using_usbmux

def main():
    print("Checking for connected devices...")
    try:
        devices = list_devices()
        print(f"Found {len(devices)} devices via USBMUX:")
        for dev in devices:
            print(f"  - Serial: {dev.serial}, Type: {dev.connection_type}")
            try:
                lockdown = create_using_usbmux(serial=dev.serial)
                name = lockdown.get_value("DeviceName")
                version = lockdown.get_value("ProductVersion")
                print(f"    -> Connected! Name: {name}, iOS Version: {version}")
            except Exception as e:
                print(f"    -> Connection failed: {e} (Unlock device and Trust Computer?)")
    except Exception as e:
        print(f"Error listing devices: {e}")

if __name__ == "__main__":
    main()
