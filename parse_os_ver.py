import sys

with open('/Users/hh/Desktop/my/ECMAIN/Dylib/ECDeviceSpoof.m', 'r') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "operatingSystemVersion" in line:
        print(f"Match found at {i+1}: {line.strip()}")
