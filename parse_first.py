import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    if "Clone ID: 53" in line or "Clone ID: 56" in line:
        print(f"[{i}] {line.strip()}")
        
    if "7609571564602935060" in line or "7609569696664503829" in line:
        print(f"[{i}] FIRST ID MATCH: {line.strip()}")
        break
