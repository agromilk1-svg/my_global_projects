import sys
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService

def main():
    try:
        lockdown = create_using_usbmux()
        with InstallationProxyService(lockdown) as iproxy:
            print("[*] Fetching User Apps...")
            apps = iproxy.get_apps(application_type="User")
            print("[*] Fetching System Apps...")
            sys_apps = iproxy.get_apps(application_type="System")
            apps.update(sys_apps)
            
            print(f"[*] Apps Type: {type(apps)}")
            if isinstance(apps, dict):
                print(f"[*] Found {len(apps)} Total Apps (filtering for 'Runner' or 'ecwda')...")
                found_count = 0
                for bid, info in apps.items():
                    name = info.get("CFBundleDisplayName", info.get("CFBundleName", "Unknown"))
                    path = info.get("Path", "Unknown")
                    executable = info.get("CFBundleExecutable", "Unknown")
                    
                    # Filter
                    if "Runner" in name or "Runner" in bid or "ecwda" in bid or "ecmain" in bid:
                        print(f"Name: {name}")
                        print(f"  ID: {bid}")
                        print(f"  Path: {path}")
                        print(f"  Exec: {executable}")
                        print(f"  Container: {info.get('Container', 'Unknown')}")
                        print("-" * 30)
                        found_count += 1
                print(f"[*] Matching apps found: {found_count}")
            elif isinstance(apps, list):
                print(f"[*] Found {len(apps)} User Apps (List)")
                print(apps[0] if apps else "Empty")
            else:
                print(apps)
    except Exception as e:
        print(f"[-] Error: {e}")

if __name__ == "__main__":
    main()
