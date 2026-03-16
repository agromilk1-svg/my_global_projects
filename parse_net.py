import sys
import re

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

clone56_lines = []
in_clone56 = False
for line in log_content.split('\n'):
    if "Clone ID: 56" in line:
        in_clone56 = True
    elif "Clone ID: 53" in line:
        in_clone56 = False
    
    if in_clone56 and "➤ REQUEST:" in line or "➤ api-boot" in line or "POST /tiktok" in line or "GET /tiktok" in line or "GET /tfe/api" in line or "POST /vc/setting" in line or "GET /common" in line:
        clone56_lines.append(line)

print("--- Clone 56 Network Requests ---")
for r in clone56_lines:
    if "POST " in r or "GET " in r or "REQUEST:" in r:
        print(r)

