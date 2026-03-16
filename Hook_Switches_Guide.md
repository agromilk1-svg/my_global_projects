# Hook 开关详解文档

这份文档详细说明了 `device.plist` 中各个 `enable...` 开关的作用、控制的具体 Hook 函数以及它们的技术实现原理。

## 📜 目录

1. [基础 Hook (Base)](#1-基础-hook-base)
2. [网络 Hook (Network)](#2-网络-hook-network)
3. [系统层 Hook (System)](#3-系统层-hook-system)
4. [语言与区域 Hook (Locale)](#4-语言与区域-hook-locale)
5. [特定 App Hook (App Specific)](#5-特定-app-hook-app-specific)
6. [数据隔离 (Data Isolation)](#6-数据隔离-data-isolation)
7. [标识符隔离 (ID Isolation)](#7-标识符隔离-id-isolation)
8. [始终启用的 Hook (Always On)](#8-始终启用的-hook-always-on)

---

## 1. 基础 Hook (Base)

### `enableMethodSwizzling`
*   **UI 名称**: 🔧 ObjC 方法交换 (enableMethodSwizzling)
*   **说明**: Objective-C 运行时方法交换 (Method Swizzling)，用于拦截高层 API。
*   **控制函数**:
    *   **UIDevice**:
        *   `name` (设备名称)
        *   `systemName` (系统名称)
        *   `systemVersion` (系统版本)
        *   `model` (设备型号)
        *   `localizedModel` (本地化型号)
        *   `batteryLevel` (电池电量)
        *   `batteryState` (电池状态)
        *   `userInterfaceIdiom` (设备形态)
        *   `identifierForVendor` (IDFV — 同 vendor 的克隆共享此值，必须隔离)
    *   **UIScreen**:
        *   `bounds` (屏幕尺寸)
        *   `nativeBounds` (物理分辨率)
        *   `scale` (缩放因子)
        *   `maximumFramesPerSecond` (刷新率)
    *   **NSProcessInfo**:
        *   `physicalMemory` (物理内存大小)
        *   `processorCount` (核心数)
        *   `activeProcessorCount` (活跃核心数)
    *   **磁盘空间**:
        *   `NSFileManager -attributesOfFileSystemForPath:` (磁盘空间伪装)
    *   **CTCarrier (运营商)**:
        *   `carrierName`, `mobileNetworkCode`, `mobileCountryCode`, `isoCountryCode`
*   **作用**: 伪装所有通过 ObjC 方法获取的设备硬件、屏幕、内存及运营商信息。

### `enableCFBundleFishhook`
*   **UI 名称**: 📦 Bundle ID 伪装 (enableCFBundleFishhook)
*   **说明**: CFBundle C 函数 Hook，用于伪装 Bundle ID。
*   **控制函数**:
    *   `CFBundleGetValueForInfoDictionaryKey` (C API)
*   **作用**: 拦截 C 层对 `Info.plist` 的读取，返回伪装的 Bundle ID。

### `enableISASwizzling`
*   **UI 名称**: 🔗 ISA 指针交换 (enableISASwizzling)
*   **说明**: NSBundle Method Swizzling，伪装 Bundle ID 和 Info.plist。
*   **控制函数**:
    *   `NSBundle -bundleIdentifier` → 返回伪装的 Bundle ID（使用独立 IMP 替换）
*   **作用**: 通过 `method_setImplementation` 替换 `bundleIdentifier` 的实现，对 mainBundle 返回伪装 ID。

### `enableAntiDetectionHooks`（总开关）
*   **UI 名称**: 🛡️ 反检测/反越狱 (总开关)
*   **说明**: 控制所有反检测相关子功能的**总开关**。关闭后下方 7 个子开关全部失效。
*   **下属子开关**: `enableFileSystemHooks` / `enableGetenvHook` / `enableAntiDebugHooks` / `enableForkHooks` / `enableBundleIDHook` / `enableCanOpenURLHook` / `enableKeychainIsolation`

#### `enableFileSystemHooks` [已废弃]
*   **UI 名称**: 📁 文件系统反检测 (access/stat/fopen)
*   **状态**: ❌ **已移除** (出于防风控安全原因，容易被 AAAASingularity 等特征扫描检测到 GOT 表被篡改)。

#### `enableGetenvHook` [已废弃]
*   **UI 名称**: 🔒 环境变量隐藏 (getenv)
*   **状态**: ❌ **已移除** (同上，已移除底层 fishhook)。

#### `enableAntiDebugHooks` [已整合/废弃]
*   **UI 名称**: 🛡️ 反调试保护 (ptrace/sysctl)
*   **状态**: ❌ **ptrace 已移除**。sysctl 和 uname 的机器特征伪装现已归入 `enableSysctlHooks` 采用更安全的 Per-Image Rebind 方式处理。

#### `enableForkHooks`
*   **UI 名称**: 🔐 沙盒完整性 (fork/vfork)
*   **控制函数**: `fork`, `vfork` (fishhook rebind)
*   **作用**: 阻止 App 通过 fork 检测越狱环境（正常 App 沙盒内 fork 会失败）。

#### `enableBundleIDHook`
*   **UI 名称**: 📦 BundleID 查询伪装
*   **控制函数**: `NSBundle -objectForInfoDictionaryKey:` (Method Swizzling)
*   **作用**: 对 `CFBundleIdentifier` 查询返回伪装的 Bundle ID，避免克隆 App 被识别。

#### `enableCanOpenURLHook`
*   **UI 名称**: 🔗 URL Scheme 隐藏 (canOpenURL)
*   **控制函数**: `UIApplication -canOpenURL:` (Method Swizzling)
*   **作用**: 隐藏 TrollStore/Cydia/Sileo 等越狱工具的 URL Scheme，隐藏 TikTok 主号检测。

#### `enableKeychainIsolation`
*   **UI 名称**: 🔑 Keychain 隔离 (SecItem*)
*   **控制函数**: `SecItemCopyMatching` / `SecItemAdd` / `SecItemUpdate` / `SecItemDelete` (fishhook rebind)
*   **说明**: 仅克隆模式生效。克隆的 Service/Account 加 `clone_ID_` 前缀。
*   **隔离的 Service 白名单**:
    *   `kTikTokKeychainService` — TikTok 登录 session token
    *   `account.historyLogin.data` — 登录历史记录
    *   `KeychainShareLogin` — 跨 App 登录共享（防串号）
    *   `TTAExtensionToken` — Extension 访问令牌
    *   `TTKKeychainService` — TikTok 通用 Keychain
    *   `TTKOclKeyChainService` — OCL 认证 Keychain
    *   `TTKUserKeyChainService` — 用户相关 Keychain
    *   `OCLKeyChainService` — 认证 Keychain
    *   `com.tiktok.keychainItem.*` — TikTok UI 状态和偏好（前缀匹配）
    *   `com.linecorp.linesdk.*` — Line SDK 登录 token（前缀匹配）
*   **作用**: 克隆模式下隔离 Keychain 数据，防止多账号串号。

---

## 2. 网络 Hook (Network)

### `enableNetworkHooks`
*   **UI 名称**: 📡 网络信息伪装 (enableNetworkHooks)
*   **说明**: 基础网络信息 Hook (per-image Rebind)。
*   **控制函数**:
    *   `CNCopyCurrentNetworkInfo` (SystemConfiguration)
*   **作用**: 伪装 Wi-Fi SSID 和 BSSID，防止通过 Wi-Fi 指纹识别设备。

### `enableNetworkInterception`
*   **UI 名称**: 🛡️ 网络拦截总开关 (enableNetworkInterception)
*   **说明**: 网络流量拦截的总控开关。
*   **作用**: 控制 L3 层 `NSURLProtocol` 注册。如果关闭，不注册自定义 Protocol。

### `enableNetworkL1` (Layer 1)
*   **UI 名称**: L1: NSURLSession (enableNetworkL1)
*   **说明**: `NSURLSession` 高层请求拦截。
*   **控制函数**:
    *   `NSURLSession -dataTaskWithRequest:completionHandler:`
*   **作用**: 拦截标准 ObjC 网络请求，覆盖第三方 SDK 残留流量。

### `enableNetworkL2` (Layer 2)
*   **UI 名称**: L2: TTNet/SSL (enableNetworkL2)
*   **说明**: **核心层** - 拦截 TikTok 专属网络栈 (TTNet / Cronet) 及 SSL 流量。
*   **控制函数** (per-image Rebind):
    *   `SSL_write` (发送前拦截明文)
    *   `SSL_read` (接收后拦截明文)
*   **作用**: 记录 TikTok 加密请求明文日志，理论上可修改请求参数。

### `enableNetworkL3` (Layer 3)
*   **UI 名称**: L3: NSURLProtocol (enableNetworkL3)
*   **说明**: `NSURLProtocol` 协议层拦截。
*   **控制函数**:
    *   `[NSURLProtocol registerClass:]`
*   **作用**: Cocoa 网络栈最底层应用可见部分，对非 HTTP/Socket 流量无效。

### `disableQUIC`
*   **UI 名称**: 🚫 禁用 QUIC (disableQUIC)
*   **说明**: 阻止 QUIC/UDP 连接 (per-image Rebind)。
*   **控制函数**:
    *   `connect` — 拦截 UDP 443 端口的连接
*   **作用**: 强制 TikTok 回退到 TCP HTTPS，使 SSL Hook 能拦截所有流量。

---

## 3. 系统层 Hook (System)

### `enableSysctlHooks`
*   **UI 名称**: ⚙️ 系统调用伪装 (enableSysctlHooks)
*   **说明**: 系统调用级信息伪装 (更安全的 per-image Rebind)。
*   **控制函数**:
    *   `sysctl`
    *   `sysctlbyname`
    *   `uname`
*   **作用**: 伪装 `hw.machine`(型号)、`kern.osversion`(Build 号)、`kern.boottime`(启动时间)，拦截进程列表检查，以及通过 `uname` 掩盖真实硬件名称。

### `enableMobileGestaltHooks`
*   **UI 名称**: 🔑 硬件指纹伪装 (enableMobileGestaltHooks)
*   **说明**: iOS 底层硬件指纹 Hook (per-image Rebind)。
*   **控制函数**:
    *   `MGCopyAnswer` (libMobileGestalt.dylib)
    *   `IORegistryEntryCreateCFProperty` (IOKit)
*   **作用**: 伪装 UDID、SerialNumber、WifiAddress、BluetoothAddress、DiskUsage。**最底层的硬件信息获取方式**，绝大多数反欺诈 SDK 都会调用。

---

## 4. 语言与区域 Hook (Locale)

### `enableCFLocaleHooks`
*   **UI 名称**: 🌍 CF 区域设置 (enableCFLocaleHooks)
*   **说明**: CoreFoundation (C 语言) 区域设置 Hook。
*   **控制函数**:
    *   `CFLocaleCopyPreferredLanguages`
    *   `CFLocaleCopyCurrent`
    *   `CFLocaleGetValue`
*   **作用**: 确保 C API 返回伪装的语言和区域（如 `ja-JP`）。

### `enableNSCFLocaleHooks`
*   **UI 名称**: 🌐 NS 区域设置 (enableNSCFLocaleHooks)
*   **说明**: 包含 `__NSCFLocale` 实例方法直接 IMP 替换 和 `NSLocale` 类方法交换。
*   **控制函数**:
    *   `__NSCFLocale -objectForKey:` / `-localeIdentifier` / `-languageCode` / `-currencyCode`
    *   `NSLocale +preferredLanguages` / `+currentLocale` / `+systemLocale`
    *   `NSBundle -preferredLocalizations`
*   **作用**: 防止 ObjC 层的 `[NSLocale currentLocale]` 及内部私有子类绕过 C Hook 返回真实数据。强制 App 全局采用伪装的语言和区域代码。

---

## 5. 特定 App Hook (App Specific)

### `enableTikTokHooks`
*   **UI 名称**: 📱 TikTok 专用 (enableTikTokHooks)
*   **说明**: 针对 ByteDance/TikTok SDK 的特定业务 Hook 及安全框架拦截。
*   **控制函数**:
    *   **AWELanguageManager**: `currentLanguageCode` / `systemLanguage`
    *   **AWEUser / AWEUserContext**: `cleanUserCache` (启动时清理用户缓存)
    *   **BDInstall / TTInstallIDManager**: `setDeviceID:` / `setInstallID:` / `deviceIDDidChange:`
    *   **UIDevice (BTD)**: `btd_isJailBroken` → 返回 NO
    *   **安全防线绕过 (Anti-Security)**:
        *   `AAWEBootChecker` 禁用 `+load` / 环境 / 路径检查
        *   `AAWEBootStub`, `TTSecurityPluginsAdapterPostLaunchTask` (绕过启动时/后安全存根)
        *   `TTKSingularityEPAHelper` (禁用 EPA 检测)
        *   `AWERiskControlService` (屏蔽内部风控标记命中提示)
*   **作用**: 覆盖 TikTok 内部语言管理器，拦截 SDK 初始化流程，强行撕开内置的 AAAASingularity 等合规与风控探测外衣。

---

## 6. 数据隔离 (Data Isolation)

> 以下功能**无开关控制**，仅在检测到克隆 ID 时自动启用。

### Keychain 隔离
*   **触发条件**: `originalBundleId` 和 `currentCloneId` 均存在时启用
*   **作用**: 白名单中的 `SecItem*` API 的 Service/Account 加 `clone_ID_` 前缀，共享 AccessGroup 移除
*   **白名单**: 8 个精确匹配 service + 2 个前缀匹配（见 `enableAntiDetectionHooks` 章节）
*   **效果**: 每个克隆有独立 Keychain 空间，登录数据不串号

### NSUserDefaults 隔离
*   **触发条件**: `currentCloneId` 存在时启用
*   **作用**: `initWithSuiteName:` 中 `group.*` 前缀的 suite name 重定向到克隆专用 suite
*   **注意**: `standardUserDefaults` 已不再 Hook（独立沙盒天然隔离）
*   **效果**: App Group 级别的偏好设置在克隆间隔离

### App Group 隔离
*   **触发条件**: `currentCloneId` 存在时启用
*   **作用**: `containerURLForSecurityApplicationGroupIdentifier:` 重定向到克隆专用目录
*   **效果**: 防止克隆与主号共享 App Group 容器中的数据

---

## 7. 标识符隔离 (ID Isolation)

> 以下功能**无开关控制**，在 dylib 初始化阶段自动启用。

### OpenUDID — 无需 Hook（已移除）
*   **状态**: ❌ **已移除所有 Hook**（2026-02-24）
*   **原因**: 实测发现 OpenUDID 依赖 `UIPasteboard`（`org.OpenUDID`）或 `NSUserDefaults` 存储。在克隆沙盒隔离机制下，每个克隆包的存储空间互不相通且初始为空，原生 OpenUDID 库会自动重新生成不同的值。因此无需主动 Hook 和伪造。
*   **已删除的代码**:
    *   `hooked_OpenUDID_value` / `hooked_OpenUDID_valueWithError` — OpenUDID 类方法 Hook
    *   `hooked_pb_valueForPasteboardType` / `hooked_pb_dataForPasteboardType` / `hooked_pb_items` — UIPasteboard 拦截
    *   `hooked_TTInstallIDManager_openUDID` — TTInstallIDManager openUDID getter Hook
    *   `setupOpenUDIDHooks()` / `setupUIPasteboardHooks()` — 注册入口
    *   `ecGenerateOpenUDID()` — 40 位 hex 随机生成器
    *   `g_cachedOpenUDID` — 全局缓存变量

### IDFV 隔离（必须 Hook）
*   **Hook 函数**:
    *   `[UIDevice identifierForVendor]` — Method Swizzling（`ec_identifierForVendor`）
    *   `TTInstallIDManager -idfv` — IMP 替换
*   **数据来源**: Config(`idfv`) → 持久化文件 → 自动生成（UUID 格式）
*   **为什么必须 Hook**: IDFV 由 iOS 系统根据签名证书 TeamID 计算，同一签名下所有 App（包括克隆包）返回完全相同的值。实测 clone_61 与 clone_62 均返回 `0560CA5B-4DCC-4527-A030-492D9A7478D0`，若不替换将直接暴露多开关联。
*   **效果**: 每个克隆使用独立的随机 IDFV

### CDID — 无需 Hook（已移除）
*   **状态**: ❌ **已移除所有 Hook**（2026-02-24）
*   **原因**: CDID 存储在 Keychain 中，克隆模式下 Keychain Service 已加 `clone_ID_` 前缀隔离，原生逻辑找不到旧数据会自行生成新值。
*   **已删除的代码**:
    *   `hooked_TTInstallIDManager_clientDID` — clientDID getter Hook
    *   `g_cachedCDID` — 全局缓存变量

### device_id / install_id
*   **Hook 函数**:
    *   `TTInstallIDManager -deviceID` / `-installID` — IMP 替换（getter）
*   **数据来源**: Config → 持久化文件 → fallback 到原始实现（由 BDInstall 服务端注册获取）
*   **注意**: 不再本地生成假 ID，让 BDInstall 自然注册获取独立的 device_id/install_id
*   **效果**: 每个克隆通过服务端注册获得独立 ID

---

## 8. 始终启用的 Hook (Always On)

> 以下功能**不受任何主 UI 开关控制**，只要 dylib 加载且配置就绪即自动触发。

### Mach-O Header Sanitize
*   **作用**: 在内存中将注入的 `LC_LOAD_DYLIB` 路径替换为 `/usr/lib/libSystem.B.dylib`
*   **执行时机**: `__attribute__((constructor))` 最早期。
*   **效果**: 防止 App 通过读取自身内存中的 Mach-O Header (`_dyld_get_image_header`) 发现被 TrollStore 或动态库注入痕迹。

### InfoDictionary 静态内存补丁
*   **作用**: `NSMutableDictionary` 直接覆写，将内置的 `CFBundleIdentifier` 修改为伪造的 Bundle ID。
*   **执行时机**: dylib 初始化早期 (在 `ECDeviceSpoofInitialize` 末尾)。
*   **效果**: 直接在内存态修改主 Bundle 的字典对象，一劳永逸地解决深度查询并避免多线程 Hook 属性造成的死锁 (Watchdog 0x8badf00d) 问题。

### 核心 ID 独立层
*   **说明**: `setupTTInstallIDManagerHooks()`
*   **作用**: 针对 TTInstallIDManager 的 IDFV / deviceID / installID getter 强制拦截，确保持久化的 IDFV、InstallID 读取无论如何都在沙盒内进行数据重定向，为业务层隔离保底。
*   **注意**: OpenUDID 和 CDID 的 Hook 已于 2026-02-24 移除，因为克隆沙盒天然隔离使它们无需额外干预。

> 💡 **注**: 早期不受控的 `CTCarrier` (运营商) 和 `Language Swizzling` (语言) Hook 如今均已得到规范化重构，现在分别严格受 `enableMethodSwizzling` 和 `enableNSCFLocaleHooks` 开关控制，不再处于 Always-On 清单中。
