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

print("--- Searching for response with ID ---")
for i, line in enumerate(clone56_lines):
    if "response" in line.lower() or "◀" in line:
        for j in range(i, min(len(clone56_lines), i+10)):
            if "7609569696664503829" in clone56_lines[j] or "7609571564602935060" in clone56_lines[j]:
                print(f"[{i}] {line.strip()}")
                print(f"  Found ID at: {clone56_lines[j].strip()}")

