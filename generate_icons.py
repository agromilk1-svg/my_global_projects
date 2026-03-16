import os
import json
from PIL import Image

# Configuration
LOGOS = {
    "emain": {
        "source": "/Users/hh/.gemini/antigravity/brain/6ad67ef7-42be-40d9-8d93-a65fa6756589/emain_logo_1769592415560.png",
        "dest": "/Users/hh/Desktop/my/ECInstall/TrollInstallerX/Assets.xcassets/AppIcon.appiconset"
    },
    "ecwda": {
        "source": "/Users/hh/.gemini/antigravity/brain/6ad67ef7-42be-40d9-8d93-a65fa6756589/ecwda_logo_final_1769594120510.png",
        "dest": "/Users/hh/Desktop/my/WebDriverAgentRunner/Assets.xcassets/AppIcon.appiconset"
    },
    "deviceinfo": {
        "source": "/Users/hh/.gemini/antigravity/brain/6ad67ef7-42be-40d9-8d93-a65fa6756589/deviceinfo_logo_final_1769594313064.png",
        "dest": "/Users/hh/Desktop/my/deviceinfo/Resources/Assets.xcassets/AppIcon.appiconset"
    }
}

SIZES = [
    {"size": "20x20", "idiom": "iphone", "filename": "Icon-App-20x20@2x.png", "scale": "2x"},
    {"size": "20x20", "idiom": "iphone", "filename": "Icon-App-20x20@3x.png", "scale": "3x"},
    {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@2x.png", "scale": "2x"},
    {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@3x.png", "scale": "3x"},
    {"size": "40x40", "idiom": "iphone", "filename": "Icon-App-40x40@2x.png", "scale": "2x"},
    {"size": "40x40", "idiom": "iphone", "filename": "Icon-App-40x40@3x.png", "scale": "3x"},
    {"size": "60x60", "idiom": "iphone", "filename": "Icon-App-60x60@2x.png", "scale": "2x"},
    {"size": "60x60", "idiom": "iphone", "filename": "Icon-App-60x60@3x.png", "scale": "3x"},
    {"size": "20x20", "idiom": "ipad", "filename": "Icon-App-20x20@1x.png", "scale": "1x"},
    {"size": "20x20", "idiom": "ipad", "filename": "Icon-App-20x20@2x.png", "scale": "2x"},
    {"size": "29x29", "idiom": "ipad", "filename": "Icon-App-29x29@1x.png", "scale": "1x"},
    {"size": "29x29", "idiom": "ipad", "filename": "Icon-App-29x29@2x.png", "scale": "2x"},
    {"size": "40x40", "idiom": "ipad", "filename": "Icon-App-40x40@1x.png", "scale": "1x"},
    {"size": "40x40", "idiom": "ipad", "filename": "Icon-App-40x40@2x.png", "scale": "2x"},
    {"size": "76x76", "idiom": "ipad", "filename": "Icon-App-76x76@1x.png", "scale": "1x"},
    {"size": "76x76", "idiom": "ipad", "filename": "Icon-App-76x76@2x.png", "scale": "2x"},
    {"size": "83.5x83.5", "idiom": "ipad", "filename": "Icon-App-83.5x83.5@2x.png", "scale": "2x"},
    {"size": "1024x1024", "idiom": "ios-marketing", "filename": "Icon-App-1024x1024@1x.png", "scale": "1x"}
]

def generate_icons(project_name, config):
    src = config["source"]
    dest = config["dest"]
    
    if "FOUND_WDA_PATH" in dest:
        print(f"Skipping {project_name} due to unresolved path: {dest}")
        return

    if not os.path.exists(dest):
        os.makedirs(dest, exist_ok=True)
        
    try:
        img = Image.open(src)
        
        # Contents.json structure
        contents = {
            "images": [],
            "info": {
                "version": 1,
                "author": "xcode"
            }
        }
        
        for size_info in SIZES:
            size_str = size_info["size"]
            scale_str = size_info["scale"]
            filename = size_info["filename"]
            
            # Calculate pixel size
            base_size = float(size_str.split('x')[0])
            scale = int(scale_str.replace('x', ''))
            pixel_size = int(base_size * scale)
            
            # Resize
            resized_img = img.resize((pixel_size, pixel_size), Image.Resampling.LANCZOS)
            resized_img.save(os.path.join(dest, filename))
            
            # Add to contents
            contents["images"].append({
                "size": size_str,
                "idiom": size_info["idiom"],
                "filename": filename,
                "scale": scale_str
            })
            
        # Write Contents.json
        with open(os.path.join(dest, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
            
        print(f"Successfully generated icons for {project_name} at {dest}")
        
    except Exception as e:
        print(f"Error generating icons for {project_name}: {e}")

if __name__ == "__main__":
    # Dynamically find WDA path if needed
    # (Checking if WDA is in current dir or known location)
    wda_candidates = [
        "/Users/hh/Desktop/my/WebDriverAgent",
        "/Users/hh/Desktop/my/WDA" # Hypothetical
    ]
    
    # Check if we can resolve WDA path
    # For now, let's just try to generate for emain and deviceinfo first
    # logic is handled in generate_icons
    
    for project, config in LOGOS.items():
        generate_icons(project, config)
