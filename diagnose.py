
import sys
import pymobiledevice3
print(f"pymobiledevice3 file: {pymobiledevice3.__file__}")
print(f"pymobiledevice3 version: {getattr(pymobiledevice3, '__version__', 'unknown')}")

try:
    from pymobiledevice3.usbmux import list_devices
    print("Successfully imported list_devices")
except ImportError as e:
    print(f"Failed to import list_devices: {e}")
    sys.exit(1)

try:
    devices = list_devices()
    print(f"list_devices() returned type: {type(devices)}")
    print(f"Device count: {len(devices)}")
    for d in devices:
        print(f" - Serial: {d.serial}")
        print(f" - ConnectionType: {d.connection_type}")
        print(f" - Struct: {d}")
except Exception as e:
    print(f"Error calling list_devices: {e}")

try:
    from pymobiledevice3.lockdown import create_using_usbmux
    if devices:
        serial = devices[0].serial
        ld = create_using_usbmux(serial=serial)
    try:
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        print("Testing InstallationProxy...")
        ip = InstallationProxyService(ld)
        apps = ip.get_apps(application_type="User", calculate_sizes=False)
        print(f"User Apps count: {len(apps)}")
        if apps:
            first_id = list(apps.keys())[0]
            print(f"First App: {first_id}")
    except Exception as e:
        print(f"InstallationProxy error: {e}")

except Exception as e:
    print(f"Lockdown error: {e}")
