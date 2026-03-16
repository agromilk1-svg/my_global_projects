import sys
import re

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

clone53_lines = []
clone56_lines = []
current_clone = None
for line in log_content.split('\n'):
    if "Clone ID: 53" in line: current_clone = 53
    elif "Clone ID: 56" in line: current_clone = 56
    
    if current_clone == 53: clone53_lines.append(line)
    elif current_clone == 56: clone56_lines.append(line)

def get_url(lines):
    for line in lines:
        match = re.search(r'(GET|POST) ([^\s]+)', line)
        if match and "/aweme/v1/anchor/list" in match.group(2):
            return match.group(2)
    return ""

url53 = get_url(clone53_lines)
url56 = get_url(clone56_lines)

print("--- Clone 53 ---")
if "?" in url53:
    for p in url53.split("?")[1].split("&"): print(p)

print("\n--- Clone 56 ---")
if "?" in url56:
    for p in url56.split("?")[1].split("&"): print(p)

