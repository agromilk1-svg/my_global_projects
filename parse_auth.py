import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "Clone ID: 56" in line and i > 2500: # Fast forward to clone 56
        pass
    
    if "api-boot.tiktokv.com" in line and ("POST" in line or "GET" in line):
        print(f"Match found: {line.strip()}")
