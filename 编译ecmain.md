# ECMAIN 编译指南

## 项目概述

ECMAIN 是基于 TrollStore 的 iOS 应用安装器，支持在 iOS 设备上安装 IPA 文件。

## 环境要求

- macOS 系统
- Xcode（包含 iOS SDK）
- Theos 工具链（位于 `/opt/theos`）
- Python 3
- Ruby（用于 Xcode 项目操作）

## 项目结构

```
/Users/hh/Desktop/my/
├── build_full.py              # 主编译脚本
├── ECMAIN/                    # 主应用项目
│   ├── ECMAIN.xcodeproj      # Xcode 项目
│   ├── TrollStoreCore/       # 核心功能模块
│   │   ├── ZipReader.h       # ZIP 读取器（替代 libarchive）
│   │   ├── ZipReader.m
│   │   └── TSAppInfo.m       # IPA 信息读取
│   └── ECMAIN.entitlements   # 应用权限配置
├── external_sources/          # 外部依赖源码
│   ├── TrollStore_Source/    # TrollStore 原始代码
│   │   ├── RootHelper/       # 根权限助手
│   │   └── Exploits/fastPathSign/  # CoreTrust Bypass 工具
│   └── openssl_macos/        # macOS 版 OpenSSL（用于编译 fastPathSign）
├── ldid                       # iOS 签名工具
└── build_antigravity/IPA/    # 输出目录
    └── ecmain.tar            # 最终打包文件
```

## 编译步骤

### 1. 一键编译

```bash
cd /Users/hh/Desktop/my
# ⚠️ 请务必使用 build_full.py 进行编译，不要使用旧的 build_ecmain.py
python3 build_full.py
```

编译成功后，输出文件位于：`build_antigravity/IPA/ecmain.tar`

### 2. 编译流程详解

`build_full.py` 执行以下步骤：

1. **编译 OpenSSL for macOS**
   - 用于 fastPathSign 工具的编译
   - 输出：`external_sources/openssl_macos/`

2. **编译 trollstorehelper**
   - 使用 Theos 编译 iOS arm64 二进制
   - 重写 `unarchive.m` 使用 zlib 实现 ZIP 解压
   - 输出：`_build_full_temp/Source/trollstorehelper`

3. **编译 fastPathSign**
   - macOS 工具，用于应用 CoreTrust Bypass
   - 链接 Security 框架和 OpenSSL
   - 输出：`_build_full_temp/Source/Exploits/fastPathSign/fastPathSign`

4. **编译 ECMAIN.app**
   - 使用 xcodebuild 编译主应用
   - 链接 zlib（`-lz`）
   - 输出：`_build_full_temp/DerivedData/Build/Products/Release-iphoneos/ECMAIN.app`

5. **打包签名**
   - 注入 trollstorehelper 到 ECMAIN.app
   - 注入 ldid 工具
   - 签名顺序：
     1. `codesign` 应用 entitlements
     2. `fastPathSign` 应用 CoreTrust Bypass
   - 打包为 tar 文件

### 3. 自动版本号管理

每次执行 `build_full.py` 时，会自动更新版本信息：
1.  **计数器**: 读取并递增项目根目录下的 `.build_number` 文件。
2.  **UI 更新**: 脚本使用正则表达式直接修改 `ViewController.m` 中的版本字符串。
    - 格式: `Build: YYYY-MM-DD HH:MM #<BuildNum> (Auto)`

## 关键修改点

### 1. IPA 解压功能（核心修复）

**问题：** 原版 TrollStore 使用 libarchive 读取 IPA 文件，但 libarchive 在当前环境无法编译。

**解决方案：** 创建纯 zlib 实现的 ZIP 读取器

#### trollstorehelper 的 unarchive.m

位置：`external_sources/TrollStore_Source/RootHelper/unarchive.m`

在 `build_full.py` 中被重写为：

```objective-c
// 使用 zlib 直接解析 ZIP 格式
#import <zlib.h>

int extract(NSString* fileToExtract, NSString* extractionPath) {
    // 1. 打开 ZIP 文件
    FILE *zipFile = fopen([fileToExtract fileSystemRepresentation], "rb");
    
    // 2. 遍历 ZIP 本地文件头
    while (!feof(zipFile)) {
        ZipLocalFileHeader header;
        fread(&header, sizeof(header), 1, zipFile);
        
        if (header.signature == ZIP_LOCAL_FILE_SIG) {
            // 读取文件名和数据
            // 使用 inflate() 解压 deflate 压缩的数据
        }
    }
}
```

#### ECMAIN 的 ZipReader

位置：`ECMAIN/TrollStoreCore/ZipReader.h` 和 `ZipReader.m`

提供与 libarchive 兼容的 API：

```objective-c
// ZipReader.h - 兼容 libarchive API
struct archive *archive_read_new(void);
int archive_read_support_format_all(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buffer, size_t len);
```

**修改文件：**
- `ECMAIN/TrollStoreCore/TSAppInfo.h` - 将 `#import "archive.h"` 改为 `#import "ZipReader.h"`

### 2. 签名顺序修复

**问题：** 原始实现先运行 fastPathSign，后运行 codesign，导致 CoreTrust Bypass 被覆盖。

**解决方案：** 在 `build_full.py` 的 `sign_binary()` 函数中确保正确顺序：

```python
def sign_binary(binary_path, entitlements=None):
    # 1. 先用 codesign 应用 entitlements
    if entitlements:
        run_cmd(f"codesign -f -s - --entitlements '{entitlements}' '{binary_path}'")
    else:
        run_cmd(f"codesign -f -s - '{binary_path}'")
    
    # 2. 后用 fastPathSign 应用 CoreTrust Bypass
    if os.path.exists(fastPathSign_bin):
        run_cmd(f"'{fastPathSign_bin}' '{binary_path}'")
```

### 3. trollstorehelper 权限配置

**问题：** trollstorehelper 缺少安装 IPA 所需的权限。

**解决方案：** 在 `build_full.py` 中指定 RootHelper entitlements：

```python
# package_all() 函数中
helper_entitlements = os.path.join(TROLLSTORE_SOURCE, "RootHelper/entitlements.plist")
sign_binary(dest_helper, helper_entitlements)
```

关键权限包括：
- `com.apple.private.mobileinstall.allowedSPI`
- `platform-application`
- `com.apple.private.security.no-sandbox`

### 4. fastPathSign 编译修复

**问题：** 缺少 Security 框架链接，导致链接错误。

**解决方案：** 在编译命令中添加 `-framework Security`：

```python
fps_cmd = (
    f"clang -O3 {main_m} {codesign_m} {coretrust_bug_c} "
    f"-o {fps_bin_path} "
    f"-fobjc-arc -framework Foundation -framework Security "
    f"-I {openssl_macos_out}/include "
    f"-L {openssl_macos_out}/lib "
    f"-lcrypto"
)
```

### 5. OpenSSL 编译修复

**问题：** 复用 iOS 版 OpenSSL 源码导致 fat file 错误。

**解决方案：** 在配置前执行 `make clean`：

```python
run_cmd("make clean", cwd=openssl_macos_src, ignore_error=True)
run_cmd(f"./Configure darwin64-x86_64-cc no-shared ...", cwd=openssl_macos_src)
```

### 6. 加密应用安装支持 (FairPlay DRM)

**问题：** 无法安装从 App Store 导出的加密 IPA，因为常规流程会重签名二进制文件或修改 `Info.plist`，导致 FairPlay 校验失败（应用闪退）。

**解决方案：** 

1.  **跳过重签名 (`skipSigning`)**:
    *   在 `trollstorehelper` 中增加 `--skip-signing` 参数。
    *   当启用此参数时，完全跳过 `ldid` 签名步骤。

2.  **强制使用 `installd`**:
    *   加密应用必须通过系统服务 `installd` (`LSApplicationWorkspace`) 安装，因为它能处理 DRM 解密。
    *   不能使用 TrollStore 自定义的 `MCMAppContainer` 方法（不支持 DRM）。

3.  **PackageType 设置**:
    *   调用 `LSApplicationWorkspace` 时，将 `PackageType` 从 `"Placeholder"` 改为 `"Customer"`。
    *   这告诉系统这是一个正常的消费者应用，需要进行 FairPlay 检查。

4.  **禁止修改 Info.plist**:
    *   在加密安装模式下，严禁调用 `applyPatchesToInfoDictionary`。
    *   修改 Info.plist（即使是微小改动）也会导致签名 Hash 不匹配。

## 踩过的坑

### 1. posix_spawn error 1 (EPERM)

**现象：** trollstorehelper 调用 `spawnRoot` 失败

**原因：** `spawnRoot` 内部使用 `posix_spawnattr_set_persona_np` 切换用户身份，但 helper 进程没有此权限

**解决：** 改用直接的 `posix_spawn`，不进行 persona 切换

### 2. posix_spawn error 2 (ENOENT)

**现象：** 尝试调用 `/usr/bin/tar` 或 `/usr/bin/unzip` 失败

**原因：** iOS 设备上不存在这些命令行工具

**解决：** 使用纯 zlib 实现 ZIP 解压，不依赖外部命令

### 3. libarchive 链接失败

**现象：** xcodebuild 报错 `undefined symbols: _archive_read_support_*`

**原因：** 
- ECMAIN 项目使用 libarchive API 读取 IPA
- libarchive 在当前环境无法编译（无 cmake，autoconf 失败）

**解决：** 创建 `ZipReader.h/m` 提供兼容 API，内部使用 zlib

### 4. CoreTrust Bypass 被覆盖

**现象：** 应用安装后立即崩溃

**原因：** 签名顺序错误，fastPathSign 的修改被 codesign 覆盖

**解决：** 确保 codesign 在前，fastPathSign 在后

### 5. xcodebuild 编译器路径错误

**现象：** `unable to spawn process 'xcrun -sdk iphoneos clang...'`

**原因：** 环境变量中的 CC/CXX 设置干扰 xcodebuild

**解决：** 在调用 xcodebuild 前清除相关环境变量：

```python
env = os.environ.copy()
for k in ['CC', 'CXX', 'CFLAGS', 'CXXFLAGS', 'LDFLAGS']:
    if k in env: del env[k]
```

## 依赖文件清单

### 必需文件

1. **TrollStore 源码**
   - 位置：`external_sources/TrollStore_Source/`
   - 来源：https://github.com/opa334/TrollStore
   - 用途：RootHelper、fastPathSign 源码

2. **Theos 工具链**
   - 位置：`/opt/theos`
   - 来源：https://theos.dev
   - 用途：编译 iOS 二进制

3. **ldid**
   - 位置：`/Users/hh/Desktop/my/ldid`
   - 来源：https://github.com/ProcursusTeam/ldid
   - 用途：iOS 伪签名工具（注入到 app 中）

4. **ECMAIN 项目文件**
   - `ECMAIN/ECMAIN.xcodeproj`
   - `ECMAIN/TrollStoreCore/` - 核心功能
   - `ECMAIN/ECMAIN.entitlements` - 应用权限

5. **自定义文件**
   - `ECMAIN/TrollStoreCore/ZipReader.h`
   - `ECMAIN/TrollStoreCore/ZipReader.m`
   - 这两个文件是自己创建的，用于替代 libarchive

### 生成的中间文件

- `external_sources/openssl_macos/` - macOS 版 OpenSSL
- `_build_full_temp/` - 编译临时目录
- `build_antigravity/IPA/ecmain.tar` - 最终输出

## 验证编译结果

### 检查签名

```bash
# 解压 tar
tar -xf build_antigravity/IPA/ecmain.tar

# 检查主应用签名
codesign -d --entitlements :- ECMAIN.app

# 检查 helper 签名
codesign -d --entitlements :- ECMAIN.app/trollstorehelper

# 验证文件存在
ls -la ECMAIN.app/trollstorehelper
ls -la ECMAIN.app/ldid
```

### 预期输出

- `ECMAIN.app` 应包含 entitlements
- `trollstorehelper` 应包含 RootHelper entitlements（包括 mobileinstall 权限）
- 两者都应被 fastPathSign 处理过

## 安装测试

1. 将 `ecmain.tar` 传输到 iOS 设备
2. 解压并安装 ECMAIN.app
3. 打开应用，尝试安装一个测试 IPA
4. 检查日志确认解压和安装流程正常

## 故障排查

### 应用崩溃

1. 检查签名顺序是否正确（codesign → fastPathSign）
2. 检查 trollstorehelper 是否有正确的 entitlements
3. 查看设备日志：`idevicesyslog | grep ECMAIN`

### IPA 安装失败

1. 检查 trollstorehelper 的 entitlements 是否包含 `com.apple.private.mobileinstall.allowedSPI`
2. 检查 `unarchive.m` 是否正确使用 zlib 解压
3. 查看 trollstorehelper 日志

### 编译失败

1. 确认 Theos 已正确安装：`ls /opt/theos`
2. 确认 Xcode 命令行工具已安装：`xcode-select -p`
3. 检查 Python 3 可用：`python3 --version`
4. 查看详细错误日志

## 注意事项

1. **不要修改签名顺序** - codesign 必须在 fastPathSign 之前
2. **不要删除 ZipReader 文件** - 这是替代 libarchive 的关键组件
3. **保留 OpenSSL 编译产物** - fastPathSign 需要链接它
4. **确保 trollstorehelper 有正确权限** - 否则无法安装 IPA
5. **编译前清理** - 如遇到奇怪问题，删除 `_build_full_temp` 重新编译

## 更新日志

- 2026-01-25 17:17: 
  - ✅ **编译成功**
  - **新增设备信息伪装功能**：
    - 新增第四个 Tab "设备信息"
    - 可查看/编辑以下设备参数：
      - 系统版本（iOS版本、构建号、系统名称）
      - 设备型号（机型、设备名、类型）
      - 屏幕信息（宽高、缩放、原生分辨率、帧率）
      - 区域/语言（国家、语言、时区、货币）
      - 硬件信息（CPU核心、内存、架构）
      - 唯一标识（IDFV、设备名）
    - 支持保存修改到配置文件
    - 支持一键还原默认值
  - 新增文件：
    - `ECMAIN/Core/ECDeviceInfoManager.h/m`
    - `ECMAIN/UI/ECDeviceInfoViewController.h/m`
  - 修改文件：`MainTabBarController.m`

- 2026-01-25 17:41:
  - ✅ **编译成功**
  - **实现设备信息 Hook 注入功能**：
    - 新增 `ECDeviceSpoof.dylib` - 设备伪装动态库
      - Hook UIDevice (systemVersion, model, name 等)
      - Hook UIScreen (bounds, scale, nativeBounds 等)
      - Hook NSLocale (countryCode, languageCode 等)
      - Hook sysctl (hw.machine, kern.osversion 等)  
      - Hook CTCarrier (运营商信息)
      - Hook ASIdentifierManager (IDFA/IDFV)
    - 新增 `ECDylibInjector.h/m` - Mach-O 注入工具
    - 更新 `build_full.py` 集成 dylib 编译和打包
    - 更新配置保存路径为全局路径 `/var/mobile/Documents/`
  - 新增文件：
    - `ECMAIN/Dylib/ECDeviceSpoof.h/m`
    - `ECMAIN/Dylib/ECDeviceSpoofConfig.h/m`
    - `ECMAIN/Dylib/fishhook.h/c`
    - `ECMAIN/Dylib/Makefile`
    - `ECMAIN/ECMAIN/Core/ECDylibInjector.h/m`

- 2026-01-25 17:22:
  - ✅ **编译成功**
  - **完善设备信息伪装功能**：
    - 添加完整参数列表（8 个分类共约 35 项）：
      - 一、系统版本：iOS版本、构建版本、内核版本、系统名称
      - 二、设备型号：型号标识、设备名称、本地化型号、设备名、产品类型、产品名称
      - 三、屏幕信息：宽度、高度、缩放比例、原生分辨率、刷新率
      - 四、区域/语言：国家代码、语言代码、区域标识符、时区、货币代码、运营商国家
      - 五、网络/运营商：运营商名称、MNC、MCC、网络类型
      - 六、唯一标识符：IDFV、IDFA、序列号、UDID、IMEI
      - 七、硬件参数：CPU核心数、物理内存、电池容量、存储容量、CPU架构
      - 八、其他可伪造：是否越狱、是否模拟器、开机时间、磁盘可用空间
    - **修改后的值显示红色**
    - **使用导航栏 Toolbar 显示保存/还原按钮**（确保始终可见）
    - 添加点击弹窗编辑功能

- 2026-01-25 16:55: 
  - ✅ **编译成功**
  - **修复 ldid 首次安装问题**：
    - 在用户点击"应用"tab 时自动检查 ldid 是否已安装到 Documents 目录
    - 如果 Documents/ldid 不存在，自动从 APP 包内复制并设置可执行权限
    - 确保第一次安装 IPA 时 ldid 已就绪
  - 修改文件：`ECAppListViewController.m`
    - 新增 `ensureLdidInstalled` 方法
    - 在 `viewWillAppear:` 中调用

- 2026-01-25 16:48: 
  - ✅ **编译成功**
  - **修复两个关键问题：**
    1. **ldid 签名组件错误修复**：
       - `isLdidInstalled()` 现在检查当前 APP 包内的 ldid（而不是 TrollStore 路径）
       - RootHelper 的 `isLdidInstalled()` 也检查当前 APP 包路径
    2. **分身安装完整实现**：
       - RootHelper 支持 `--custom-bundle-id=xxx` 参数
       - RootHelper 支持 `--custom-display-name=xxx` 参数  
       - RootHelper 支持 `--registration-type=System/User` 参数
       - 在 IPA 解压后修改 Info.plist 应用自定义包名和显示名称
       - ECMAIN UI 传递正确的参数给 RootHelper

- 2026-01-25 16:21: 
  - ✅ **编译成功**
  - 添加三个新功能：
    1. 已安装应用列表显示权限标志 [S]=System / [U]=User
    2. 分身安装支持两个输入框（包名 + 桌面显示名称），自动显示默认值
    3. 安装时自动检测并修复 ldid 组件
  - 支持 customDisplayName 参数传递给 trollstorehelper
  - 输出：`/Users/hh/Desktop/my/build_antigravity/IPA/ecmain.tar`
  - 编译脚本：`python3 build_full.py`

## 编译命令

```bash
cd /Users/hh/Desktop/my
python3 build_full.py
```

## 本次编译修复

添加了 `ZipWriter.m` 到 Xcode 项目的编译源文件中（之前缺失导致链接错误）。

---

## ⚠️ 重要注意事项（2026-01-26 更新）

### 1. VPN Tunnel 扩展签名

**问题：** Tunnel.appex (VPN 扩展) 未被签名，导致 VPN 无法启动（错误 `NEVPNErrorDomain Code=1`）

**解决方案：** 在 `build_full.py` 的 `package_all()` 函数中添加：

```python
# 4.5 Sign Tunnel Extension (VPN)
tunnel_appex = os.path.join(final_app, "PlugIns/Tunnel.appex")
if os.path.exists(tunnel_appex):
    tunnel_binary = os.path.join(tunnel_appex, "Tunnel")
    run_cmd(f"codesign -f -s - --entitlements 'ECMAIN/Tunnel/Tunnel.entitlements' '{tunnel_binary}'")
    run_cmd(f"'{fastpathsign}' '{tunnel_binary}'")  # CoreTrust bypass
```

### 2. Mihomo.framework 嵌入

**问题：** Mihomo.framework（代理内核）未被嵌入到应用包中，导致 Tunnel 扩展启动失败

**解决方案：** 在 `build_full.py` 的 `package_all()` 函数中添加：

```python
# 1.5 Embed Mihomo.framework
mihomo_src = os.path.join(DERIVED_DATA_DIR, "Build/Products/Release-iphoneos/Mihomo.framework")
if os.path.exists(mihomo_src):
    frameworks_dir = os.path.join(final_app, "Frameworks")
    os.makedirs(frameworks_dir, exist_ok=True)
    shutil.copytree(mihomo_src, os.path.join(frameworks_dir, "Mihomo.framework"))
```

### 3. 签名 Mihomo.framework

**问题：** 嵌入的 Mihomo.framework 需要签名才能加载

**解决方案：**

```python
# 在签名主应用前先签名框架
mihomo_framework = os.path.join(final_app, "Frameworks/Mihomo.framework")
if os.path.exists(mihomo_framework):
    mihomo_binary = os.path.join(mihomo_framework, "Mihomo")
    run_cmd(f"codesign -f -s - '{mihomo_binary}'")
    run_cmd(f"'{fastpathsign}' '{mihomo_binary}'")  # CoreTrust bypass
```

### 4. 签名顺序总结

正确的签名顺序：
1. **Mihomo.framework** - 框架必须先签名
2. **主应用 ECMAIN.app** - 使用 ECMAIN.entitlements
3. **trollstorehelper** - 使用 RootHelper entitlements
4. **Tunnel.appex** - 使用 Tunnel.entitlements + CoreTrust bypass

---

## 更新日志 (2026-01-26)

- ✅ **加密应用安装支持**：
  - **核心突破**：利用 iOS 原生 `installd` 服务安装加密 IPA，完美保留 FairPlay DRM。
  - **实现逻辑**：
    - 新增 `🔐 加密安装 (User)` 选项。
    - 后端实现 `--skip-signing` 参数，彻底跳过重签名。
    - 强制使用系统安装 API，并设置 `PackageType="Customer"`。
    - 修复了此前因修改 `Info.plist` 导致签名失效的问题。
  - **限制**：加密应用不支持“分身”功能（因为分身需要修改 Bundle ID，这会破坏签名）。

- ✅ **VPN 功能修复**：
  - 添加 Tunnel.appex 签名步骤
  - 应用 CoreTrust bypass 到 Tunnel 二进制
  - 嵌入 Mihomo.framework 到 Frameworks 目录
  - 签名 Mihomo.framework

- ✅ **分阶段脱壳方案**：
  - 新增扩展进程扫描函数 `findRunningExtensionProcesses()`
  - 新增扩展脱壳函数 `decryptExtensionProcess()`
  - 实现分阶段用户交互流程：主程序脱壳 → 提示切换应用 → 扫描扩展 → 打包

- ✅ **Watch App 脱壳支持**：
  - 添加 Watch/ 目录处理
  - 支持 Watch App 内的 Frameworks 脱壳

- **修改的文件**：
  - `build_full.py` - 添加 VPN 相关签名和嵌入步骤
  - `MemoryUtilities.h/m` - 添加扩展进程扫描和脱壳函数
  - `ECAppListViewController.m` - 添加分阶段脱壳 UI 流程

### 7. Team ID 获取修复

**问题：** 之前通过解析 `mobileprovision` 或 `Info.plist` 获取 Team ID 的方法不可靠，经常返回 `(null)`，导致签名失败。

**解决方案：** 实现 Native 方法直接从二进制文件读取 Code Directory。

1.  **原理：**
    - 解析 Mach-O 文件的 Load Commands。
    - 找到 `LC_CODE_SIGNATURE`。
    - 读取 Code Directory Blob。
    - 提取 Entitlements 字段。
    - 从 `com.apple.developer.team-identifier` 中读取 Team ID。

2.  **实现位置：** `ECAppInjector.m` -> `nativeDumpEntitlements:`

```objective-c
// 伪代码示例
- (NSDictionary *)nativeDumpEntitlements:(NSString *)binaryPath {
    // 1. 打开文件
    // 2. 找到 CS_SuperBlob
    // 3. 找到 CSSLOT_ENTITLEMENTS
    // 4. 解析 plist 数据
### 8. WDA 闪退修复 (签名冲突解决)
2026-02-06

**问题：** 安装未签名的 `ecwda_ref.ipa` 后，应用启动立即闪退（Crash by invalid signature）。

**原因：**
1.  **CodeResources 缺失**：原包安装时，`signAdhoc` (使用 `fastPathSign`) 仅对二进制文件签名，不支持目录签名，导致 `.xctest` 和 `.framework` Bundle 目录缺少有效的 `_CodeSignature/CodeResources` 文件。
2.  **双重签名冲突**：虽然我们在修复中引入了 `ldid` 来对目录签名（生成 `CodeResources`），但随后的代码逻辑又调用了 `signAdhoc` 对同一二进制重新签名。`fastPathSign` 的签名覆盖了 `ldid` 的签名，导致二进制签名与 `CodeResources` 不匹配，验证失败。

**解决方案：**
在 `RootHelper/main.m` 的 `signApp` 函数中引入冲突检测逻辑：
1.  先检测是否为 `.xctest` 或 `.framework` 目录。
2.  如果是，显式调用 `ldid -S<entitlements> <path>` 对整个 **目录** 进行签名。这会生成正确的 `CodeResources` 且包含 entitlements。
3.  **关键点**：设置标志位 `signedWithLdid = YES`。
4.  在后续逻辑中，如果检测到 `signedWithLdid` 为真，则 **跳过** `signAdhoc` 调用，防止签名被 `fastPathSign` 覆盖。

```objective-c
// 伪代码逻辑
if (isBundleDirectory) {
    runLdid(@["-S", bundlePath], ...); // 生成 CodeResources
    signedWithLdid = YES;
}
// ... 
if (!signedWithLdid) {
    signAdhoc(binaryPath, ...); // 仅在未被 ldid 签过时运行
}
```

---

## 更新日志

- 2026-02-06 15:10:
  - ✅ **WDA 闪退修复 (Build #577)**
  - **核心修复**：解决安装未签名 IPA (如 WDA) 时的签名冲突问题。
    - 修复原理：`ldid` (用于目录签名) 与 `fastPathSign` (用于二进制签名) 互斥。
    - 实施：对 Bundle 目录优先使用 `ldid` 签名并跳过后续 `fastPathSign`。
  - **结果**：`ecwda_ref.ipa` 可通过“原包安装”成功运行，不再闪退。
  - **编译命令**：`python3 build_full.py` (自动包含此修复)

- 2026-02-01:
  - ✅ **tun2proxy 集成 (Build #387)**
  - **功能**:
    - 集成 `tun2proxy` Rust 库，替代 `ECHevTunnel` + `ECUDPBridge`。
    - 提供原生 SOCKS5 UDP 支持，解决 UDP 流量（如 TikTok 视频）超时问题。
    - 使用 `socketpair` 桥接 `NEPacketTunnelFlow` 与 `tun2proxy`，无需原生 TUN fd。
    - **强制 DNS over TCP**: 防止 `socketpair` 环境下 UDP DNS 响应丢失导致的超时。
  - **新增依赖**:
    - **Rust Toolchain**: 1.93.0
    - **Rust Targets**: `aarch64-apple-ios`, `x86_64-apple-ios`, `aarch64-apple-ios-sim`, `x86_64-apple-darwin`
    - **cbindgen**: 用于生成 C 头文件
  - **新增文件**:
    - `ECMAIN/Tunnel/tun2proxy.xcframework`
    - `ECMAIN/Tunnel/tun2proxy.h`
    - `ECMAIN/Tunnel/ECTun2Proxy.h/m`
  - **构建流程更新**:
    - `build_full.py` 尚未自动集成 Rust 编译（目前手动编译 xcframework 放入项目）。
    - 需确保 `tun2proxy.xcframework` 存在于 `ECMAIN/Tunnel/` 目录。

## VPN 参数与架构 (Tun2proxy)

### 架构图

```mermaid
graph LR
    App[Target App] -->|IP Packets| NEPacketTunnelFlow
    NEPacketTunnelFlow -->|readPackets| ECTun2Proxy
    ECTun2Proxy -->|socketpair| tun2proxy[tun2proxy (Rust)]
    tun2proxy -->|SOCKS5 TCP| Mihomo[Mihomo Core :7890]
    Mihomo -->|VLESS/Trojan| RemoteProxy
```

### 关键配置

1.  **TUN 设置**:
    - IP: `198.18.0.1/16`
    - DNS: `198.18.0.2` (Fake IP, 路由到 TUN)
    - MTU: `1500`
    - Default Route: `0.0.0.0/0` (全流量捕获)

2.  **DNS 策略**:
    - `Tun2proxyDns_OverTcp`: 强制 DNS 查询封装在 TCP 中发送给 SOCKS5 代理。
    - 原因: 在 `socketpair` 模式下，Standard UDP response path 可能有问题，导致 `timed out`。

3.  **防环路**:
    - Exclude Route: `Proxy Server IP` (动态解析)
    - Exclude Route: `127.0.0.1/32` (防止死循环)
