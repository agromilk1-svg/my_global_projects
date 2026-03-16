# ECWDA & ECMAIN Build Configuration

This document records the valid build configuration required to generate installable IPAs for this project.

## 1. Output Directory
All build artifacts (DerivedData, Products, IPAs) are stored in:
`[ProjectRoot]/build_antigravity/`

The main build script `unified_build.py` handles this automatically.

## 2. WebDriverAgent (ECWDA) Configuration
**Status**: Signed (Development Certificate)
**Reason**: Installable on iOS devices.

*   **Signing**:
    *   **MUST** use the User's Development Certificate `Apple Development: mickyhhong@icloud.com`.
    *   **Do NOT** use `CODE_SIGNING_ALLOWED=NO`. The script allows Xcode to pick up the project's signing identity.
*   **Frameworks**:
    *   **Do NOT** manually embed `opencv2.framework`, `ncnn.framework`, `openmp.framework`.
    *   These are linked (statically or via Xcode) by `WebDriverAgentLib`. Manual embedding causes duplicate bloat (600MB+) and signing errors.
*   **Packaging**:
    *   Use `cp -a` to preserve file attributes.
    *   Use `zip -r -y` to preserve symbolic links.
    *   The resulting IPA `build_antigravity/IPA/ECWDA.ipa` is ~55MB and installable.

## 3. ECMAIN Configuration
**Status**: Ad-Hoc Signed
**Reason**: No Team ID configured in project.

*   **Signing**:
    *   **MUST** use `CODE_SIGNING_ALLOWED=NO` in `xcodebuild`.
    *   Since the `ECMAIN.xcodeproj` does not have a valid Team ID, automatic signing fails. Ad-Hoc signing enables compilation.
*   **Packaging**:
    *   Same robust packaging (`cp -a`, `zip -y`).

## 4. Build Script (`unified_build.py`)
The script has been updated to reflect these rules.

**Usage**:
```bash
# Build Everything
python3 unified_build.py --target all

# Build Only WDA
python3 unified_build.py --target wda

# Build Only ECMAIN
python3 unified_build.py --target ecmain
```

**Key Code Logic**:
*   **WDA Build**: Standard `xcodebuild` (allows signing).
*   **ECMAIN Build**: `xcodebuild ... CODE_SIGNING_ALLOWED=NO`.
*   **Path Forcing**: Uses `CONFIGURATION_BUILD_DIR` and `SYMROOT` to force all outputs to `build_antigravity`.
