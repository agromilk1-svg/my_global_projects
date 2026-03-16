import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

clone53_lines = []
current_clone = None
for line in log_content.split('\n'):
    if "Clone ID: 53" in line: current_clone = 53
    elif "Clone ID: 56" in line: current_clone = 56
    
    if current_clone == 53: clone53_lines.append(line)

print("--- Looking for TTInstallIDManager in 53 ---")
count = 0
for i, line in enumerate(clone53_lines):
    if "deviceID is empty" in line:
        count += 1
        if count <= 5:
            # print a few lines before it
            for j in range(max(0, i-5), i+1):
                if "GET" in clone53_lines[j] or "POST" in clone53_lines[j] or "TTInstall" in clone53_lines[j]:
                    print(f"[{j}] {clone53_lines[j].strip()}")
            print("---")

print(f"Total empty warnings in 53: {count}")

