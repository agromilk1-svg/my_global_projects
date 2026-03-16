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

def print_params(lines, text):
    print(f"--- Params in {text} ---")
    for line in lines:
        if "idfv" in line or "os_version" in line or "device_type" in line:
            # try to extract some parameters from the URL
            match = re.search(r'(GET|POST) ([^\s]+)', line)
            if match:
                url = match.group(2)
                if "?" in url:
                    params = url.split("?")[1].split("&")
                    important = [p for p in params if any(k in p for k in ["idfv", "os_version", "device_type", "sys_region"])]
                    if important:
                        print(f"[{text}] {', '.join(important)}")
                        return

print_params(clone53_lines, "Clone 53")
print_params(clone56_lines, "Clone 56")

