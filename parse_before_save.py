import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "Saved deviceId = 76095696" in line:
        start = max(0, i - 150)
        end = min(len(lines), i)
        print("--- Requests before ID save ---")
        for j in range(start, end):
            if "POST" in lines[j] or "GET" in lines[j] or "➤ api-boot" in lines[j] or "◀ api-boot" in lines[j]:
                print(f"[{j}] {lines[j].strip()}")
        break
