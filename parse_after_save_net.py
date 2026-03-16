import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

start_idx = 0
for i, line in enumerate(lines):
    if "Saved deviceId" in line:
        start_idx = i
        break

print("--- Network requests after ID save ---")
for i in range(start_idx, len(lines)):
    line = lines[i]
    if "GET /" in line or "POST /" in line:
        print(line.strip())
