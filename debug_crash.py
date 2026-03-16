import sys
import os
sys.path.append("installer")
from pymobiledevice3.usbmux import list_devices
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.crash_reports import CrashReportsManager

def main():
    print("[*] Scanning for devices...")
    devices = list_devices()
    if not devices:
        print("[-] No devices found via usbmux.")
        return

    dev = devices[0]
    print(f"[+] Found device: {dev.serial}")

    try:
        lockdown = create_using_usbmux(serial=dev.serial)
        print(f"[+] Connected to {lockdown.get_value('DeviceName')}")
        
        crash_service = CrashReportsManager(lockdown)
        print("[*] Accessing Crash Reports...")
        
        # Pull all entries
        files = []
        for file in crash_service.ls("/"):
            if "Tips" in file:
                files.append(file)
        
        if not files:
            print("[-] No specific 'Tips' crash reports found. Listing recent logs:")
            all_files = crash_service.ls("/")
            # simple filter for recent or relevant
            for f in all_files:
                if "Tips" in f or "troll" in f.lower() or "Helper" in f:
                    print(f" - {f}")
            
            # Print top 5 unsorted to check format
            print("Sample files:", all_files[:5])
        else:
            print(f"[+] Found {len(files)} Tips-related crash logs.")
            # Get the latest one
            files.sort()
            latest = files[-1]
            print(f"[*] Reading latest log: {latest}")
            
            # Read content (streaming)
            out = crash_service.get_file_contents(latest)
            print("-" * 50)
            print(out[:2000].decode('utf-8', errors='ignore')) # Print first 2000 chars
            print("-" * 50)

    except Exception as e:
        print(f"[-] Error: {e}")

if __name__ == "__main__":
    main()
