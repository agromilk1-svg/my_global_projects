import json

text = "{"
with open('/Users/hh/Desktop/my/log.log', 'r') as f:
    lines = f.readlines()
    start_idx = -1
    for i, line in enumerate(lines):
        if '"processByPid" :' in line:
            start_idx = i
            break
    
    if start_idx != -1:
        text += "".join(lines[start_idx:])
        text = text[:text.rfind('}')+1] # truncate trailing non-json
        
        try:
            data = json.loads(text)
            pid_data = data.get("processByPid", {}).get("23474", {})
            if not pid_data:
                print("No PID 23474 found in processByPid")
            for tid, tinfo in pid_data.get("threadById", {}).items():
                if tinfo.get("dispatch_queue_label") == "com.apple.main-thread":
                    print(f"Main Thread (TID: {tid}):")
                    frames = tinfo.get("userFrames", [])
                    for f in frames:
                        print(f)
        except Exception as e:
            print("Parse error:", e)
