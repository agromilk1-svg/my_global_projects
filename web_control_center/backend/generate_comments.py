import sqlite3
import random
import time

DB_PATH = "/Users/hh/Desktop/my/web_control_center/backend/ecmain_control.db"

emojis = ["😂", "🥰", "🔥", "👏", "👍", "😁", "❤️", "🙌", "✨", ""]

langs_map = {
    "zh-CN": {
        "A": ["这个视频", "简直", "哇塞", "天哪", "哈哈", "我的天", "说实话", "讲真", "真的是", "不可思议"],
        "B": ["太搞笑了", "绝了", "太棒了", "很有意思", "神仙内容", "太牛了", "好好笑", "绝绝子", "超出预期", "很特别"],
        "C": ["继续加油！", "收藏了！", "喜欢！", "点赞！", "支持一下", "爱了爱了", "看了好几遍", "笑死我了", "宝藏博主", "学到了"]
    },
    "es-MX": {
        "A": ["Este video", "Neta", "Órale", "Ay Dios", "Jaja", "No manches", "La verdad", "Te lo juro", "Está", "Increíble"],
        "B": ["es chistosísimo", "está padrísimo", "buenísimo", "muy interesante", "es una joya", "está cañón", "me da risa", "está de locos", "superó mis expectativas", "muy especial"],
        "C": ["¡sigue así!", "¡guardado!", "¡me encanta!", "¡dale like!", "te apoyo", "lo amé", "lo vi mil veces", "me muero de risa", "qué buen creador", "aprendí algo"]
    },
    "pt-BR": {
        "A": ["Esse vídeo", "Cara", "Nossa", "Meu Deus", "Haha", "Caraca", "Na moral", "Sério", "Isso é", "Inacreditável"],
        "B": ["é muito engraçado", "é top demais", "muito bom", "interessante demais", "é uma obra prima", "é foda", "muito hilário", "fantástico", "superou as expectativas", "muito especial"],
        "C": ["continua assim!", "salvei!", "amei!", "dei like!", "apoiando", "apaixonado", "assisti mil vezes", "morri de rir", "melhor criador", "aprendi muito"]
    },
    "de-DE": {
        "A": ["Dieses Video", "Einfach", "Wow", "Oh mein Gott", "Haha", "Krass", "Ganz ehrlich", "Echt jetzt", "Es ist", "Unglaublich"],
        "B": ["ist so lustig", "ist genial", "ist super", "ist sehr interessant", "ist ein Meisterwerk", "echt stark", "mega witzig", "fantastisch", "besser als erwartet", "sehr speziell"],
        "C": ["weiter so!", "gespeichert!", "liebe es!", "like gelassen!", "ich unterstütze dich", "verliebt", "habs so oft geschaut", "ich lach mich tot", "toller Creator", "was gelernt"]
    },
    "en-SG": {
        "A": ["This video", "Wah", "Walao", "Omg", "Haha", "Siao", "Honestly", "For real", "It is", "Unbelievable"],
        "B": ["so funny sia", "damn solid", "super good", "damn interesting", "a masterpiece", "damn power", "so damn funny", "fantastic", "better than expected", "very special"],
        "C": ["keep it up!", "saved!", "love it!", "liked!", "support!", "damn love", "watched so many times", "laugh die me", "treasure creator", "learnt something"]
    },
    "ja-JP": {
        "A": ["この動画", "マジで", "わあ", "やばい", "笑", "すげえ", "正直", "ガチで", "マジ", "信じられない"],
        "B": ["面白すぎ", "神すぎ", "最高", "興味深い", "傑作だね", "ヤバすぎ", "めっちゃ笑った", "凄すぎる", "期待以上", "特別だね"],
        "C": ["頑張って！", "保存した！", "好き！", "いいね！", "応援してる", "めっちゃ愛してる", "何回も見た", "笑い死にそう", "最高の投稿者", "勉強になった"]
    },
    "en-US": {
        "A": ["This video", "Literally", "Wow", "Omg", "Haha", "Crazy", "Honestly", "For real", "It's", "Unbelievable"],
        "B": ["is so funny", "is amazing", "is really good", "is so interesting", "is a masterpiece", "is crazy good", "is hilarious", "is fantastic", "exceeded expectations", "is very special"],
        "C": ["keep it up!", "saved!", "love it!", "liked!", "supporting you", "absolutely love it", "watched it so many times", "dying laughing", "hidden gem creator", "learned a lot"]
    },
    "es-ES": {
        "A": ["Este vídeo", "Literal", "Ostras", "Madre mía", "Jaja", "Hostia", "Sinceramente", "De verdad", "Es", "Increíble"],
        "B": ["es graciosísimo", "es una pasada", "buenísimo", "muy interesante", "es una obra de arte", "es la leche", "me parto", "es alucinante", "superó mis expectativas", "muy especial"],
        "C": ["¡sigue así!", "¡guardado!", "¡me encanta!", "¡le di a me gusta!", "te apoyo", "me chifla", "lo vi mil veces", "me muero de risa", "qué buen creador", "aprendí algo"]
    },
    "en-GB": {
        "A": ["This video", "Literally", "Blimey", "Oh my days", "Haha", "Mental", "Honestly", "For real", "It's", "Unbelievable"],
        "B": ["is so funny", "is absolutely brilliant", "is proper good", "is quite interesting", "is a masterpiece", "is cracking", "is hilarious", "is fantastic", "exceeded expectations", "is rather special"],
        "C": ["keep it up mate!", "saved!", "love it!", "liked!", "supporting you", "absolutely love it", "watched it a hundred times", "dying laughing", "cracking creator", "learned a bit"]
    },
    "fr-FR": {
        "A": ["Cette vidéo", "Franchement", "Ouah", "Mon Dieu", "Mdr", "Dingue", "Honnêtement", "Pour de vrai", "C'est", "Incroyable"],
        "B": ["est trop marrante", "est géniale", "est super", "est super intéressante", "est un chef-d'œuvre", "est ouf", "est hilarante", "est fantastique", "a dépassé mes attentes", "est très spéciale"],
        "C": ["continue comme ça!", "sauvegardé!", "j'adore!", "liké!", "je te soutiens", "j'kiffe", "je l'ai regardée mille fois", "mort de rire", "super créateur", "j'ai appris un truc"]
    }
}

def generate_db():
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    # Ensure table exists
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS ec_comments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            language TEXT NOT NULL,
            content TEXT NOT NULL,
            created_at REAL
        )
    ''')
    cursor.execute('DELETE FROM ec_comments')
    
    insert_data = []
    
    for lang, parts in langs_map.items():
        combinations = []
        for a in parts["A"]:
            for b in parts["B"]:
                for c in parts["C"]:
                    for e in emojis:
                        if lang in ["zh-CN", "ja-JP"]:
                            text = f"{a} {b} {c} {e}".strip()
                        else:
                            text = f"{a} {b}, {c} {e}".strip()
                        combinations.append(text)
        
        # shuffle and pick 1000
        random.shuffle(combinations)
        selected = combinations[:1000]
        
        for text in selected:
            insert_data.append((lang, text, time.time()))
            
    cursor.executemany('INSERT INTO ec_comments (language, content, created_at) VALUES (?, ?, ?)', insert_data)
    conn.commit()
    conn.close()
    
    print(f"✅ Generated {len(insert_data)} comments in DB successfully!")

if __name__ == "__main__":
    generate_db()
