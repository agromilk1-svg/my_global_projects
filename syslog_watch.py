import sys
sys.path.append("installer")
try:
    from pymobiledevice3.usbmux import list_devices
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.syslog import SyslogService
except ImportError:
    print("Error: pymobiledevice3 not installed. Please run: pip3 install pymobiledevice3")
    sys.exit(1)

import signal
import time

# Handle Ctrl+C gracefully
def signal_handler(sig, frame):
    print("\nStopping syslog monitoring...")
    sys.exit(0)

signal.signal(signal.SIGINT, signal_handler)

def main():
    devices = list_devices()
    serial_to_use = None
    
    if not devices:
        print("list_devices() found nothing. Trying fallback serial...")
        serial_to_use = "b18d48b7905e124e519f95ee91241dcc816f7c0a"
    else:
        serial_to_use = devices[0].serial

    print(f"Connecting to device: {serial_to_use}")
    
    try:
        lockdown = create_using_usbmux(serial=serial_to_use)
        syslog = SyslogService(lockdown)
        
        keywords = ["Ecrunner-Runner", "ECMAIN", "amfid", "SpringBoard", "task_for_pid", "AMFI", "trust_cache"]
        print(f"Watching syslog for keywords: {', '.join(keywords)}")
        print("Please launch 'Ecrunner-Runner' on your device now...")
        print("Press Ctrl+C to stop.")
        
        for line in syslog.watch():
            # Check if any keyword matches
            if any(k in line for k in keywords):
                print(line)
                sys.stdout.flush() # Ensure output is flushed immediately
                
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    main()
