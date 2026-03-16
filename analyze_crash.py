import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

print("=== Analyzing log.log for crashes ===")
crash_lines = []
for i, line in enumerate(lines):
    lower_line = line.lower()
    if "crash" in lower_line or "fatal" in lower_line or "unrecognized selector" in lower_line or "exc_bad_access" in lower_line or "sigabrt" in lower_line:
        crash_lines.append(i)

# Also look for 'error' and 'exception' but filter noise
error_lines = []
for i, line in enumerate(lines):
    lower_line = line.lower()
    if "exception" in lower_line or "error:" in lower_line:
        if "bitmoji" not in lower_line and "ttinstallidmanager" not in lower_line and "subclass" not in lower_line and "awepassportserviceimp" not in lower_line:
            error_lines.append(i)

print(f"Found {len(crash_lines)} critical crash keywords and {len(error_lines)} other errors.")

combined = sorted(list(set(crash_lines + error_lines)))

for idx in combined[:20]: # print first 20 matches with context
    print(f"\n--- Context around line {idx} ---")
    start = max(0, idx - 2)
    end = min(len(lines), idx + 8)
    for j in range(start, end):
        prefix = ">> " if j == idx else "   "
        print(f"{prefix}[{j}] {lines[j].strip()}")
