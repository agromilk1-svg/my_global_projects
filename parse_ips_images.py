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
        text = text[:text.rfind('}')+1]
        try:
            data = json.loads(text)
            images = data.get("usedImages", [])
            for i, img in enumerate(images):
                print(f"Image {i}: {img.get('path', img.get('name', 'Unknown'))}")
        except Exception as e:
            print("Error:", e)
