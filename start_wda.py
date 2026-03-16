#!/usr/bin/env python3
"""
WDA XCTest Runner Launcher
使用 tidevice 启动 WebDriverAgent，建立 XCTest session 以获得截屏权限。

Usage:
    python3 start_wda.py
    python3 start_wda.py --bundle-id com.custom.runner.xctrunner
"""

import subprocess
import sys
import time
import argparse
import threading

# Configuration
TIDEVICE_PATH = "/Users/hh/Library/Python/3.9/bin/tidevice"
DEFAULT_BUNDLE_ID = "com.ecwda.myRunner.xctrunner"  # XCTest runner bundle ID
WDA_PORT = 10088
MJPEG_PORT = 10089


def run_tidevice_xctest(bundle_id: str) -> subprocess.Popen:
    """Start WDA using tidevice xctest."""
    cmd = [
        TIDEVICE_PATH,
        "xctest",
        "-B", bundle_id
    ]
    print(f"🚀 Starting WDA via tidevice...")
    print(f"   Command: {' '.join(cmd)}")
    
    proc = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True
    )
    return proc


def setup_port_forward():
    """Setup port forwarding for WDA and MJPEG."""
    # Forward WDA port
    wda_forward = subprocess.Popen(
        [TIDEVICE_PATH, "relay", str(WDA_PORT), str(WDA_PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    
    # Forward MJPEG port
    mjpeg_forward = subprocess.Popen(
        [TIDEVICE_PATH, "relay", str(MJPEG_PORT), str(MJPEG_PORT)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL
    )
    
    print(f"📡 Port forwarding established:")
    print(f"   WDA:   localhost:{WDA_PORT} -> device:{WDA_PORT}")
    print(f"   MJPEG: localhost:{MJPEG_PORT} -> device:{MJPEG_PORT}")
    
    return wda_forward, mjpeg_forward


def monitor_output(proc: subprocess.Popen):
    """Monitor and print tidevice output."""
    for line in proc.stdout:
        line = line.strip()
        if line:
            # Highlight important messages
            if "ServerURL" in line or "http://" in line:
                print(f"✅ {line}")
            elif "Error" in line or "error" in line:
                print(f"❌ {line}")
            else:
                print(f"   {line}")


def main():
    parser = argparse.ArgumentParser(description="Launch WDA via tidevice xctest")
    parser.add_argument(
        "--bundle-id", "-B",
        default=DEFAULT_BUNDLE_ID,
        help=f"XCTest runner bundle ID (default: {DEFAULT_BUNDLE_ID})"
    )
    parser.add_argument(
        "--no-forward",
        action="store_true",
        help="Don't setup port forwarding"
    )
    args = parser.parse_args()
    
    print("=" * 50)
    print("WDA XCTest Runner Launcher")
    print("=" * 50)
    
    # Setup port forwarding first
    if not args.no_forward:
        wda_fwd, mjpeg_fwd = setup_port_forward()
    
    # Start WDA
    proc = run_tidevice_xctest(args.bundle_id)
    
    # Monitor output
    try:
        monitor_output(proc)
    except KeyboardInterrupt:
        print("\n⏹ Stopping WDA...")
        proc.terminate()
        if not args.no_forward:
            wda_fwd.terminate()
            mjpeg_fwd.terminate()
    
    proc.wait()
    print("WDA stopped.")


if __name__ == "__main__":
    main()
