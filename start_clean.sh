#!/bin/bash

# Define the target IP
TARGET_IP="user.ecmain.site"

echo "=== ECWDA Clean Start ==="
echo "Cleaning proxy environment variables..."

# 1. Unset all common proxy variables
unset http_proxy
unset https_proxy
unset all_proxy
unset HTTP_PROXY
unset HTTPS_PROXY
unset ALL_PROXY

# 2. Explicitly set no_proxy to bypass VPN for local IPs
export no_proxy="localhost,127.0.0.1,::1,${TARGET_IP}"
export NO_PROXY="localhost,127.0.0.1,::1,${TARGET_IP}"

# 3. Print current proxy state for verification
echo "Current Proxy Env:"
env | grep -i proxy
echo "----------------------"

echo "Starting Control Center..."
# Run the python script
python3 /Users/hh/Desktop/my/control_center.py
