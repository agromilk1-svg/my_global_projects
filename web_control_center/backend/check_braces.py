import sys

with open('/Users/hh/Desktop/my/web_control_center/frontend/src/App.vue', 'r') as f:
    lines = f.readlines()

balance = 0
max_bal = 0
max_bal_line = 0
for i, line in enumerate(lines):
    line_num = i + 1
    clean_line = ""
    in_quote = False
    for j, char in enumerate(line):
        if char == '"' or char == "'":
            if j > 0 and line[j-1] != '\\':
                in_quote = not in_quote
        if not in_quote:
            clean_line += char
            
    opens = clean_line.count('{')
    closes = clean_line.count('}')
    balance += opens
    balance -= closes
    
    if balance > max_bal:
        max_bal = balance
        max_bal_line = line_num
        
    # Print lines where balance grows very fast
    if opens > 5:
        print(f"Line {line_num:4d} | Balance: {balance:3d} | OPENS: {opens} | Line: {line.strip()}")

print(f"Max Balance: {max_bal} at Line {max_bal_line}")
