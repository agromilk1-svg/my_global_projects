import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

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

print("--- Checking for early errors in Clone 53 ---")
for i, line in enumerate(clone53_lines):
    if "error" in line.lower() or "fail" in line.lower() or "exception" in line.lower():
        print(f"[{i}] {line.strip()}")
        
print("\n--- Checking for early errors in Clone 56 ---")
for i, line in enumerate(clone56_lines):
    if "error" in line.lower() or "fail" in line.lower() or "exception" in line.lower():
        print(f"[{i}] {line.strip()}")

