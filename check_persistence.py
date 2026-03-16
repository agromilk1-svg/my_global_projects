import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

for line in lines:
    if "76095" in line and ("load" in line.lower() or "read" in line.lower() or "cache" in line.lower() or "found" in line.lower() or "setDeviceID" in line or "setInstallID" in line):
        print(line.strip())

