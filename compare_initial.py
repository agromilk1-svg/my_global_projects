import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

def get_initial_requests(lines):
    reqs = []
    capture_next = False
    for line in lines:
        if "➤ REQUEST:" in line or "➤ " in line:
            reqs.append(line.strip())
            capture_next = True
        elif capture_next and (line.strip().startswith("POST") or line.strip().startswith("GET") or "Host:" in line):
            reqs.append(line.strip())
        elif capture_next and not line.strip():
            capture_next = False
    return reqs[:30] # first few requests

clone53_lines = []
clone56_lines = []

current_clone = None
for line in log_content.split('\n'):
    if "Clone ID: 53" in line:
        current_clone = 53
    elif "Clone ID: 56" in line:
        current_clone = 56
    
    if current_clone == 53:
        clone53_lines.append(line)
    elif current_clone == 56:
        clone56_lines.append(line)

print("--- Initial Network Requests in 53 ---")
for r in get_initial_requests(clone53_lines): print(r)

print("\n--- Initial Network Requests in 56 ---")
for r in get_initial_requests(clone56_lines): print(r)

