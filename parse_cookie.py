import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    # Only search string roughly matching the install_id since length is 19 digits
    if "7609571564602935060" in line:
        print(f"Match found at line {i}: {line.strip()}")
