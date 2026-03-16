import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "Saved deviceId = 76095696" in line:
        start = max(0, i - 15)
        end = min(len(lines), i + 15)
        print("--- Context around ID save ---")
        for j in range(start, end):
            print(f"[{j}] {lines[j].strip()}")
        break
