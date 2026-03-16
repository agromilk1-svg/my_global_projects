# -*- mode: python ; coding: utf-8 -*-


a = Analysis(
    ['install_echelper_gui.py'],
    pathex=[],
    binaries=[],
    datas=[('build_antigravity/IPA/echelper', 'build_antigravity/IPA'), ('web_control_center/backend/updates', 'web_control_center/backend/updates'), ('installer', 'installer'), ('device-support', 'device-support')],
    hiddenimports=['pymobiledevice3.services.mobilebackup2', 'pymobiledevice3.services.installation_proxy', 'pymobiledevice3.services.diagnostics', 'pymobiledevice3.services.afc', 'pymobiledevice3.services.syslog', 'pymobiledevice3.services.os_trace', 'PyQt5', 'PyQt5.QtCore', 'PyQt5.QtGui', 'PyQt5.QtWidgets'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='Install_ECHelper_GUI',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='Install_ECHelper_GUI',
)
app = BUNDLE(
    coll,
    name='Install_ECHelper_GUI.app',
    icon=None,
    bundle_identifier=None,
)
