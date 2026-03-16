import sys
import re

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

start_idx = 0
for i, line in enumerate(lines):
    if "Saved deviceId" in line:
        start_idx = i
        break

print("--- After Save: TTInstall Empty Warnings ---")
count = 0
for i in range(start_idx, len(lines)):
    line = lines[i]
    if "deviceID is empty" in line:
        count += 1

print(f"Empty warnings after Save: {count}")

