import time
import sys
import subprocess
from pymobiledevice3.exceptions import NoDeviceConnectedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.crash_reports import CrashReportsManager

def wait_for_device(timeout=60):
    start = time.time()
    print(f"[*] Waiting for device connection ({timeout}s)...")
    while time.time() - start < timeout:
        try:
            lockdown = create_using_usbmux()
            print("[+] Device Connected!")
            return lockdown
        except NoDeviceConnectedError:
            time.sleep(1)
        except Exception as e:
            # Maybe just waiting for trust dialog?
            pass
    return None

def main():
    lockdown = wait_for_device()
    if not lockdown:
        print("[-] Timeout: No device detected.")
        return

    try:
        crash_service = CrashReportsManager(lockdown)
        files = crash_service.ls("./")
        
        # Sort by name (which usually starts with timestamp? No, usually Name-Date.ips)
        # We can't easily sort by date without stat.
        # But let's just print ALL filenames to see what's there.
        print(f"[*] Found {len(files)} crash reports. listing last 20:")
        for fname in files[-20:]:
            print(fname)
            
    except Exception as e:
        print(f"[-] Error fetching crashes: {e}")

        
    except Exception as e:
        print(f"[-] Error fetching crashes: {e}")

if __name__ == "__main__":
    main()
