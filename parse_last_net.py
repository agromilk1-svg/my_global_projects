import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()

print("--- Check the API interactions ---")
for line in lines[-100:]:
    if "GET /" in line or "POST /" in line:
        print(line.strip()[:150] + "...")
