import sys
import re

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_content = f.read()

log_lines = log_content.split('\n')

print("=== Analyzing New log.log ===")
print(f"Total lines: {len(log_lines)}")

c53_lines = []
for line in log_lines:
    if "Clone ID: 53" in line:
        c53_lines.append(True)
print(f"Contains Clone 53 runs: {len(c53_lines)}")

# Look for empty device ID warnings
empty_count = sum(1 for line in log_lines if "deviceID is empty" in line)
print(f"Total 'deviceID is empty' warnings: {empty_count}")

# Check for Save persistent ID
saved_ids = [line for line in log_lines if "Saved deviceId" in line or "Saved installId" in line]
print(f"Saved Persistent IDs: {len(saved_ids)}")
for s in saved_ids:
    print(f"  {s.strip()}")

# Check for any app crashing / network errors
errors = []
for i, line in enumerate(log_lines):
    if "error" in line.lower() or "exception" in line.lower() or "fail" in line.lower() or "crash" in line.lower():
        if "bitmoji" not in line.lower() and "subclass" not in line.lower():
            # filter out noise
            errors.append(f"[{i}] {line.strip()}")

print(f"\nPotential errors found: {len(errors)}")
for e in errors[:20]:
    print(e)
    
