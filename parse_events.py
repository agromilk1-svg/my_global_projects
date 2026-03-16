import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

print("--- Looking for TTInstallIDManager deviceID empty calls around Save ---")
for i, line in enumerate(lines):
    if "Saved deviceId" in line:
        start = max(0, i-5)
        end = min(len(lines), i+15)
        for j in range(start, end):
            print(f"[{j}] {lines[j].strip()}")
        break

