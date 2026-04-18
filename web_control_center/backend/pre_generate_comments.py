import sys
import os
import random
import time

# 将后端目录加入路径以导入 database
sys.path.append('/Users/hh/Desktop/my/web_control_center/backend')
import database

def run_pre_generate():
    emojis = ["😂", "🥰", "🔥", "👏", "👍", "😁", "❤️", "🙌", "✨", ""]
    
    langs_config = {
        "th-TH": {
            "A": ["วิดีโอนี้", "ว้าว", "โอ้มายก๊อด", "ฮ่าๆ", "บ้าไปแล้ว", "เอาจริงนะ", "จริงๆ นะ", "มัน", "ไม่น่าเชื่อ", "สุดยอด"],
            "B": ["ตลกมาก", "เจ๋งสุดๆ", "ดีมากจริงๆ", "น่าสนใจมาก", "เป็นผลงานที่ยอดเยี่ยม", "เท่มาก", "ขำกลิ้งเลย", "น่าทึ่งมาก", "ดีกว่าที่คิดไว้เยอะ", "พิเศษจริงๆ"],
            "C": ["สู้ๆ นะ!", "บันทึกไว้ดูอีก!", "ชอบมาก!", "กดไลก์รัวๆ!", "เป็นกำลังใจให้!", "หลงรักเลย", "ดูวนไปหลายรอบ", "ขำหนักมาก", "ช่องโปรดเลย", "ขอบคุณสำหรับเนื้อหาดีๆ"]
        },
        "ms-MY": {
            "A": ["Video ini", "Weyh", "Wah", "Ya ampun", "Haha", "Gila lah", "Sejujurnya", "Sumpah", "Memang", "Tak percaya"],
            "B": ["kelakar gila", "mantap gila", "memang padu", "sangat menarik", "memang masterpiece", "power lah", "lawak betul", "fantastik", "luar jangkaan", "memang istimewa"],
            "C": ["teruskan usaha!", "dah save!", "suka sangat!", "dah like!", "support korang", "sayang sangat", "tengok banyak kali", "gelak pecah perut", "creator terbaik", "dapat ilmu baru"]
        }
    }
    
    all_comments = []
    
    for lang, parts in langs_config.items():
        combinations = []
        for a in parts["A"]:
            for b in parts["B"]:
                for c in parts["C"]:
                    for e in emojis:
                        if lang == "th-TH":
                            text = f"{a} {b} {c} {e}".strip()
                        else:
                            text = f"{a} {b}, {c} {e}".strip()
                        combinations.append(text)
        
        random.shuffle(combinations)
        selected = combinations[:1000]
        
        now = time.time()
        for content in selected:
            all_comments.append((lang, content, now))
    
    inserted = database.batch_add_comments(all_comments)
    print(f"Successfully pre-generated {inserted} comments.")

if __name__ == "__main__":
    run_pre_generate()
