import sys
import re

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

log_lines = log_content.split('\n')

print("=== Analyzing log.log ===")
print(f"Total lines: {len(log_lines)}")

clone53_lines = []
clone56_lines = []

current_clone = None
for line in log_lines:
    if "Clone ID: 53" in line:
        current_clone = 53
    elif "Clone ID: 56" in line:
        current_clone = 56
    
    if current_clone == 53:
        clone53_lines.append(line)
    elif current_clone == 56:
        clone56_lines.append(line)

print(f"Clone 53 lines: {len(clone53_lines)}")
print(f"Clone 56 lines: {len(clone56_lines)}")

def find_key_events(lines, clone_id):
    print(f"\n--- Key events for Clone {clone_id} ---")
    need_reg_calls = [l for l in lines if "_needRegsiter:" in l]
    print(f"_needRegsiter calls: {len(need_reg_calls)}")
    if need_reg_calls:
        print(f"  First: {need_reg_calls[0]}")
    
    device_reg_reqs = [l for l in lines if "/device_register/" in l or "device_register" in l]
    print(f"/device_register/ requests: {len(device_reg_reqs)}")
    if device_reg_reqs:
        for req in device_reg_reqs[:3]:
            print(f"  {req}")

    ttinstall_empty = [l for l in lines if "deviceID is empty and no persistent ID found" in l]
    print(f"TTInstallIDManager empty warnings: {len(ttinstall_empty)}")

find_key_events(clone53_lines, 53)
find_key_events(clone56_lines, 56)

