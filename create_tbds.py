import os

SDK_PATH = "build_antigravity/PrivateSDK"

FRAMEWORKS = [
    {
        "name": "SpringBoardServices",
        "path": "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
        "symbols": ["_SBReloadIconForIdentifier", "_OBJC_CLASS_$_SBSHomeScreenService"]
    },
    {
        "name": "FrontBoardServices",
        "path": "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
        "symbols": ["_OBJC_CLASS_$_FBSSystemService"]
    },
    {
        "name": "BackBoardServices",
        "path": "/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices",
        "symbols": ["_BKSTerminateApplicationForReasonAndReportWithDescription"]
    },
    {
        "name": "MobileContainerManager",
        "path": "/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager",
        "symbols": ["_MCMContainerContentClassForContainerClass"] # Guessing symbol to keep it valid
    },
    {
        "name": "Preferences",
        "path": "/System/Library/PrivateFrameworks/Preferences.framework/Preferences",
        "symbols": ["_OBJC_CLASS_$_PSListController", "_OBJC_CLASS_$_PSSpecifier"]
    }
]

def create_tbd(fw):
    name = fw["name"]
    install_path = fw["path"]
    symbols = fw["symbols"]
    
    # Create framework dir
    fw_dir = os.path.join(SDK_PATH, f"{name}.framework")
    os.makedirs(fw_dir, exist_ok=True)
    
    tbd_content = f"""--- !tapi-tbd-v3
archs:           [ arm64 ]
uuids:           [ '00000000-0000-0000-0000-000000000000' ]
platform:        ios
flags:           [ not_app_extension_safe ]
install-name:    '{install_path}'
current-version: 1.0
compatibility-version: 1.0
exports:
  - archs:           [ arm64 ]
    symbols:         [ {', '.join(f"'{s}'" for s in symbols)} ]
    objc-classes:    []
...
"""
    # Note: using v3 format which is widely compatible
    tbd_path = os.path.join(fw_dir, f"{name}.tbd")
    with open(tbd_path, "w") as f:
        f.write(tbd_content)
    print(f"Created {tbd_path}")

def main():
    if not os.path.exists(SDK_PATH):
        os.makedirs(SDK_PATH)
    
    for fw in FRAMEWORKS:
        create_tbd(fw)

if __name__ == "__main__":
    main()
