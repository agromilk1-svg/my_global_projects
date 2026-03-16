import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

print("--- Looking for UIScreen / UIDevice hooks executed ---")
for line in lines:
    if "UIScreen" in line or "UIDevice" in line or "UIApplication" in line or "bounds" in line or "frame" in line:
        if "ClassSearch" not in line and "ECDeviceSpoof" in line:
            print(line.strip()[:150])

print("--- Done ---")
