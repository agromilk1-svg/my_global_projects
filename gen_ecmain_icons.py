import os
import shutil
from PIL import Image

LOGO_PATH = "/Users/hh/.gemini/antigravity/brain/6ad67ef7-42be-40d9-8d93-a65fa6756589/emain_logo_1769592415560.png"
DEST_DIR = "/Users/hh/Desktop/my/ECMain/Assets.xcassets"
APPICON_SET = os.path.join(DEST_DIR, "AppIcon.appiconset")

def generate_icons():
    if not os.path.exists(LOGO_PATH):
        print(f"Logo not found: {LOGO_PATH}")
        return

    if os.path.exists(DEST_DIR):
        shutil.rmtree(DEST_DIR)
    os.makedirs(APPICON_SET)
    
    img = Image.open(LOGO_PATH)
    
    # Standard iOS App Icon sizes
    sizes = [
        (20, 1), (20, 2), (20, 3),
        (29, 1), (29, 2), (29, 3),
        (40, 1), (40, 2), (40, 3),
        (60, 2), (60, 3),
        (76, 1), (76, 2),
        (83.5, 2),
        (1024, 1)
    ]
    
    images_json = []

    for size_pt, scale in sizes:
        size_px = int(size_pt * scale)
        filename = f"Icon-{size_pt}x{size_pt}@{scale}x.png"
        if scale == 1:
            filename = f"Icon-{size_pt}x{size_pt}.png"
            
        full_path = os.path.join(APPICON_SET, filename)
        resized = img.resize((size_px, size_px), Image.Resampling.LANCZOS)
        resized.save(full_path)
        
        entry = {
            "size": f"{size_pt}x{size_pt}",
            "idiom": "iphone",
            "filename": filename,
            "scale": f"{scale}x"
        }
        if size_pt == 76 or size_pt == 83.5 or size_pt == 1024:
             entry["idiom"] = "ipad" # Just in case, broadly compatible
        if size_pt == 1024:
             entry["idiom"] = "ios-marketing"
             
        # Add duplicate entries for universal if needed or just minimal set
        # For simplicity, just adding them as universal-ish
        images_json.append(entry)

    # Write Contents.json
    contents = {
        "images": images_json,
        "info": {
            "version": 1,
            "author": "xcode"
        }
    }
    
    import json
    with open(os.path.join(APPICON_SET, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=4)

    print(f"Generated icons in {APPICON_SET}")

if __name__ == "__main__":
    generate_icons()
