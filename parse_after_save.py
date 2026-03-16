import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

print("--- Looking for errors or failures after deviceId gets saved ---")
start_idx = 0
for i, line in enumerate(lines):
    if "Saved deviceId" in line:
        start_idx = i
        break

for j in range(start_idx, len(lines)):
    line = lines[j]
    if "error" in line.lower() or "fail" in line.lower() or "exception" in line.lower() or "invalid" in line.lower() or "denied" in line.lower():
        if "bitmoji" not in line.lower() and "subclass" not in line.lower() and "ttinstallidmanager" not in line.lower():
            print(f"[{j}] {line.strip()}")

