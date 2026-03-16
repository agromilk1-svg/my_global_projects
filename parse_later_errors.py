import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

start_idx = 0
for i, line in enumerate(lines):
    if "Saved deviceId" in line:
        start_idx = i
        break

print("--- Searching for specific HTTP related errors or TTNet messages after Save ---")
for i in range(start_idx, len(lines)):
    line = lines[i]
    if "error" in line.lower() or "exception" in line.lower() or "fail" in line.lower() or "status code" in line.lower() or "denied" in line.lower() or "invalid" in line.lower():
        if "bitmoji" not in line.lower() and "subclass" not in line.lower() and "ttinstallidmanager" not in line.lower():
            print(f"[{i}] {line.strip()}")

