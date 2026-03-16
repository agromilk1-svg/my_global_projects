import sys

with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    log_lines = f.read().split('\n')

c53_reqs = []
c56_reqs = []

cur_c = None
for l in log_lines:
    if "Clone ID: 53" in l: cur_c = 53
    elif "Clone ID: 56" in l: cur_c = 56
    
    if "POST /" in l or "GET /" in l or "➤ REQUEST" in l:
        if cur_c == 53: c53_reqs.append(l.strip())
        elif cur_c == 56: c56_reqs.append(l.strip())

def clean_req(req):
    import re
    # 移除时间戳等无用信息
    req = re.sub(r'默认.*?\]\s*', '', req)
    return req

print(f"--- 53 Requests ({len(c53_reqs)}) ---")
for r in c53_reqs: print(clean_req(r))

print(f"\n--- 56 Requests ({len(c56_reqs)}) ---")
for r in c56_reqs: print(clean_req(r))

