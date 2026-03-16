import sys
import re

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

clone56_lines = []
in_clone56 = False
for line in log_content.split('\n'):
    if "Clone ID: 56" in line:
        in_clone56 = True
    elif "Clone ID: 53" in line:
        in_clone56 = False
    
    if in_clone56:
        clone56_lines.append(line)

print("--- Searching for ID generation in Clone 56 ---")
for i, line in enumerate(clone56_lines):
    if "7609569696664503829" in line:  # This is the device_id seen in the diff
        print(f"[{i}] {line}")
        # Print a few lines before to see context
        start = max(0, i - 10)
        for j in range(start, i):
            if "POST" in clone56_lines[j] or "GET" in clone56_lines[j] or "Response" in clone56_lines[j] or "BDInstall" in clone56_lines[j]:
                print(f"  Context: {clone56_lines[j].strip()}")

