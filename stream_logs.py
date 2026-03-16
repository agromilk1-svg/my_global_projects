import sys
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.os_trace import OsTraceService
from pymobiledevice3.services.syslog import SyslogService

def main():
    print("[*] connecting to syslog...")
    try:
        lockdown = create_using_usbmux()
        # Use SyslogService for older iOS or OsTrace for newer
        # iOS 15+ usually requires OsTrace (log stream)
        # But pymobiledevice3 might abstract it.
        # Let's try OsTraceService first as it is richer.
        
        with OsTraceService(lockdown) as syslog:
             print("[*] Streaming logs... (Press Ctrl+C to stop)")
             for line in syslog.syslog():
                 # Filter usually happens on device side but we can filter here
                 msg = str(line.message) if hasattr(line, 'message') else str(line)
                 label = str(line.label) if hasattr(line, 'label') else ""
                 
                 # Look for Tips or our bundle ID or dyld errors
                 keywords = ["Tips", "ECMAIN", "dyld", "amfid", "SpringBoard", "Ecrunner", "Runner", "wda", "testmanagerd", "kernel", "CTLoop"]
                 if any(k in msg for k in keywords) or "com.apple.tips" in label:
                     print(f"[{label}] {msg}")
                     
    except Exception as e:
        print(f"[-] Error: {e}")

if __name__ == "__main__":
    main()
