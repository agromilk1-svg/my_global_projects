# ECDeviceSpoof Hook 完整清单 (v2424)

> 用于逐一排查 TikTok 闪退 (Watchdog 0x8badf00d) 的根因。
> 
> **当前崩溃诊断**：v2424 日志确认 constructor 同步部分仅耗时 ~95ms（35.819→35.914），
> 但 TikTok 自身的 scene-create 阶段消耗了 2.4s CPU (100% CPU)，超过 Watchdog 允许的 **1.35 秒**限制。
> 
> **结论**：问题不在 constructor 同步操作，而是 **`setupMethodSwizzling()` 安装的 Hook 在 TikTok 启动高频调用时产生的额外 CPU 开销**。

---

## 一、执行时机分类

### 🔴 极早期（Pre-Init，在 constructor 最前面）

| # | Hook 函数 | 功能 | 开关 | 当前状态 |
|---|----------|------|------|---------|
| 0 | `objc_setHook_getClass` | 覆盖 AAAASingularity 注册的类加载监控回调 | 无（硬编码） | ✅ 始终开启 |
| 1 | `ec_install_crash_handler` | 注册 SIGSEGV/SIGABRT 等信号处理器，记录崩溃日志 | 无（硬编码） | ✅ 始终开启 |
| 2 | `Heimdallr backgroundSession 拦截` | 拦截 `backgroundSessionConfigurationWithIdentifier:`，防止 Heimdallr XPC 风暴 | 无（硬编码） | ✅ 始终开启 |
| 3 | `sanitizeMainBinaryHeader` | 遍历 Mach-O Header 的 LC_LOAD_DYLIB，抹除可疑注入 dylib 路径 | 无（硬编码） | ✅ 始终开启 |
| 4 | `hooked_sigaction_fn` | 拦截外部代码（Heimdallr）对崩溃信号处理器的覆盖，30秒保护窗口 | 无（硬编码） | ✅ 始终开启 |

### 🟡 同步执行（Constructor 中，在 `setupMethodSwizzling()` 内）

> ⚠️ **这些 Hook 在主线程同步安装，且会被 TikTok 启动流程高频调用（每次调用都走 Hook 逻辑）。**
> **即使安装本身只需 ~50ms，但 Hook 被调用时产生的 CPU 开销会累积到 TikTok 的 scene-create 时间中。**

| # | Hook 函数 | 目标方法 | 功能 | 开关 (plist key) | 默认值 |
|---|----------|---------|------|-----------------|-------|
| 5 | `ec_systemVersion` | `UIDevice.systemVersion` | 返回伪装的 iOS 版本号 (如 15.8.6) | `enableUIDeviceHooks` | **YES** ✅ |
| 6 | `ec_model` | `UIDevice.model` | 返回伪装的设备型号 (如 iPhone) | `enableUIDeviceHooks` | **YES** ✅ |
| 7 | `ec_localizedModel` | `UIDevice.localizedModel` | 返回伪装的本地化型号 | `enableUIDeviceHooks` | **YES** ✅ |
| 8 | `ec_name` | `UIDevice.name` | 返回伪装的设备名称 | `enableUIDeviceHooks` | **YES** ✅ |
| 9 | `ec_systemName` | `UIDevice.systemName` | 返回 "iOS" | `enableUIDeviceHooks` | **YES** ✅ |
| 10 | `operatingSystemVersionString` | `NSProcessInfo.operatingSystemVersionString` | 返回伪装的 OS 版本字符串 | `enableUIDeviceHooks` | **YES** ✅ |
| 11 | `operatingSystemVersion` | `NSProcessInfo.operatingSystemVersion` | 返回伪装的 OS 版本结构体 | `enableUIDeviceHooks` | **YES** ✅ |
| 12 | `ec_identifierForVendor` | `UIDevice.identifierForVendor` | 返回伪装/生成的 IDFV (克隆隔离) | `enableIDFVHook` | **YES** ✅ |
| 13 | `ec_bounds` | `UIScreen.bounds` | 返回伪装的屏幕尺寸 | `enableUIScreenHooks` | **YES** ✅ |
| 14 | `ec_scale` | `UIScreen.scale` | 返回伪装的屏幕缩放比 | `enableUIScreenHooks` | **YES** ✅ |
| 15 | `ec_nativeBounds` | `UIScreen.nativeBounds` | 返回伪装的原生分辨率 | `enableUIScreenHooks` | **YES** ✅ |
| 16 | `ec_maximumFramesPerSecond` | `UIScreen.maximumFramesPerSecond` | 返回伪装的最大刷新率 | `enableUIScreenHooks` | **YES** ✅ |

### 🟢 延迟执行（`dispatch_after(2.0s)` → `ECDeviceSpoofInitialize()`）

> 以下所有 Hook 在 App 启动完成约 2 秒后才安装。

#### A. 崩溃防护

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 17 | `installTikTokCrashGuards` | 修复 `__NSArray0` 上的 KVO addObserver/removeObserver 崩溃 | 无（硬编码） | ✅ 始终开启 |

#### B. 标识符注入

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 18 | `cleanKeychainIfNeeded` | 清除 ByteDance SDK 在 Keychain 中残留的 device_id/install_id | 无（硬编码） | ✅ 始终开启 |
| 19 | `injectSpoofedIDs` | 生成/加载 OpenUDID、IDFV 隔离值到全局缓存 | 无（硬编码） | ✅ 始终开启 |
| 20 | `setupTTInstallIDManagerHooks` | Hook `TTInstallIDManager` 的 deviceID/installID/openUDID/idfv getter | 无（硬编码） | ✅ 始终开启 |

#### C. 网络拦截

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 21 | `setupNetworkInterception` (L1) | `NSURLSession dataTaskWithRequest:completionHandler:` | 拦截 HTTP 请求，替换 URL 中的设备标识参数 | `enableNetworkInterception` | **YES** ✅ |
| 22 | `setupNetworkInterception` (L2) | `TTNetworkManager` 的 6+ 个请求方法 | Hook TTNet SDK 的所有请求入口，替换 device_type/os_version 参数 | `enableNetworkInterception` | **YES** ✅ |
| 23 | `setupNetworkInterception` (L3) | `NSURLProtocol` | 注册 `ECNetworkInterceptorProtocol` 拦截协议 | `enableNetworkInterception` | **YES** ✅ |
| 24 | `setupSSLHooks` (L4) | BoringSSL C 函数 | SSL 层 fishhook（当前为空操作） | `enableNetworkL2` | **YES** ✅ |
| 25 | `setupNetworkInterception` (L5) | QUIC 协议 | 通过 TTNet enable_quic=0 禁用 QUIC | `disableQUIC` | **YES** ✅ |

#### D. 设备伪装（Method Swizzling，延迟路径中再次调用）

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 26 | `setupMethodSwizzling` (延迟重入) | UIDevice/UIScreen/NSProcessInfo/IDFV 伪装（因 dispatch_once 不会重复安装） | `enableMethodSwizzling` | **YES** ✅ |

#### E. 区域/语言伪装

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 27 | `setupNSCFLocaleHooks` | `__NSCFLocale` 的 objectForKey/localeIdentifier/countryCode/languageCode/currencyCode | 直接替换 IMP，返回伪装的区域信息 | `enableNSCFLocaleHooks` | **YES** ✅ |
| 28 | `setupCFLocaleHooks` | `CFLocaleGetValue` / `CFLocaleCopyPreferredLanguages` / `CFLocaleCopyCurrent` | C 层 fishhook，返回伪装的 CFLocale 值 | `enableCFLocaleHooks` | **YES** ✅ |
| 29 | `setupLanguageSwizzling` | `+[NSLocale preferredLanguages]` / `+[NSLocale currentLocale]` / `+[NSLocale autoupdatingCurrentLocale]` / `+[NSLocale systemLocale]` | 类方法 Swizzle，返回伪装的语言列表 | `enableCFLocaleHooks` | **YES** ✅ |
| 30 | `setupLanguageSwizzling` | `-[NSBundle preferredLocalizations]` | 返回伪装的首选本地化 | `enableCFLocaleHooks` | **YES** ✅ |
| 31 | `setupLanguageSwizzling` | `-[NSUserDefaults objectForKey:]` | 拦截 `AppleLanguages` 读取，返回伪装语言 | `enableCFLocaleHooks` | **YES** ✅ |
| 32 | `setupLanguageSwizzling` | `-[NSUserDefaults setObject:forKey:]` | 阻止 SDK 覆写 `AppleLanguages` | `enableCFLocaleHooks` | **YES** ✅ |
| 33 | `setupLanguageSwizzling` | `-[NSUserDefaults removeObjectForKey:]` | 阻止 SDK 删除 `AppleLanguages` | `enableCFLocaleHooks` | **YES** ✅ |
| 34 | `setupLanguageSwizzling` | `-[NSBundle appStoreReceiptURL]` | DRM 绕过，返回伪造的 receipt URL | `enableCFLocaleHooks` | **YES** ✅ |

#### F. 运营商伪装

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 35 | `setupCarrierHooks` | Hook `CTCarrier` 的 carrierName/mcc/mnc/isoCountryCode | `enableCarrierHooks` + 配置了 carrierName | **NO** ❌ (未配置) |

#### G. TikTok 专用 Hook

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 36 | `setupTikTokHooks` | `UIDevice btd_isJailBroken` | 返回 NO (越狱检测绕过) | `enableTikTokHooks` | **YES** ✅ |
| 37 | `setupTikTokHooks` | `NSUserDefaults awe_installID` | 返回伪装的 install ID | `enableTikTokHooks` | **YES** ✅ |
| 38 | `setupTikTokHooks` | `AWELanguageManager currentLanguage` | 返回伪装的当前语言 | `enableTikTokHooks` | **YES** ✅ |
| 39 | `setupTikTokHooks` | `AAWEBootChecker shouldCheckPlusLoad/shouldCheckTargetPath` | 绕过启动检查 | `enableTikTokHooks` | **YES** ✅ |
| 40 | `setupTikTokHooks` | `AAWEBootStub` 的 environment/run/execute | 禁用启动桩代码 | `enableTikTokHooks` | **YES** ✅ |
| 41 | `setupTikTokHooks` | `AAAASingularity` 10个实例方法 + stop/guardService/onThreadExecEntryBlock | 全面无效化安全框架 | `enableTikTokHooks` | **YES** ✅ |
| 42 | `setupTikTokHooks` | `NSBundle bundleWithIdentifier:` | 隐藏 XCTest Bundle | `enableTikTokHooks` | **YES** ✅ |
| 43 | `setupTikTokHooks` | `TTKSingularityEPAHelper` 及更多安全类 | 越狱检测方法返回 NO/nil | `enableTikTokHooks` | **YES** ✅ |
| 44 | `setupTikTokHooks` | `AWEIsOfficialBundleId` / `resetedVendorID` / `fakedBundleID` / `btd_bundleIdentifier` / `btd_currentLanguage` | 各种 ByteDance 内部 API 伪装 | `enableTikTokHooks` | **YES** ✅ |
| 45 | `setupTikTokHooks` | `storeRegion` / `priorityRegion` / `currentRegion` / `containerPath` | 区域和容器路径伪装 | `enableTikTokHooks` | **YES** ✅ |

#### H. 底层系统 Hook

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 46 | `setupSysctlHook` | `sysctlbyname("hw.machine")` / `uname()` | C 层 fishhook，返回伪装的机型 | `enableSysctlHooks` | **YES** ✅ |
| 47 | `setupMobileGestaltHook` | `MGCopyAnswer` / `MGGetBoolAnswer` | 返回伪装的硬件指纹 (productType/boardId 等) | `enableMobileGestaltHooks` | **YES** ✅ |
| 48 | `setupCFBundleFishhook` | `CFBundleGetValueForInfoDictionaryKey` | C 层 fishhook，返回伪装的 Bundle ID | `enableCFBundleFishhook` | **YES** ✅ |
| 49 | `setupISASwizzling` | NSObject ISA 指针 | ISA 层级的类伪装 | `enableISASwizzling` | **YES** ✅ |

#### I. 磁盘/电池伪装

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 50 | `setupDiskAndBatteryHooks` | `NSFileManager attributesOfFileSystemForPath:error:` | 返回伪装的磁盘空间 | `enableDiskBatteryHooks` | **YES** ✅ |
| 51 | `setupDiskAndBatteryHooks` | `UIDevice batteryLevel` / `batteryState` | 返回伪装的电池电量/充电状态 | `enableDiskBatteryHooks` | **YES** ✅ |

#### J. 反检测模块

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 52 | `setupAntiDetectionHooks` | `stat/lstat/access/faccessat` | 拦截 TrollStore 路径检测 | `enableAntiDetectionHooks` | **YES** ✅ |
| 53 | `setupAntiDetectionHooks` | `dyld_image_count/dyld_get_image_name/dyld_get_image_header` | 隐藏注入的 dylib | `enableAntiDetectionHooks` | **YES** ✅ |
| 54 | `setupAntiDetectionHooks` | `NSBundleResourceRequest beginAccessingResources/conditionallyBeginAccessingResources` | 拦截 ODR 资源请求 | `enableAntiDetectionHooks` | **YES** ✅ |
| 55 | `setupAntiDetectionHooks` | `fork/vfork` | 禁止 fork 检测 | `enableAntiDetectionHooks` | **YES** ✅ |
| 56 | `setupAntiDetectionHooks` | `abort/exit/raise/kill/pthread_kill` | 拦截自杀行为 (30秒保护窗口) | `enableAntiDetectionHooks` | **YES** ✅ |
| 57 | `setupAntiDetectionHooks` | `statvfs` | 根分区只读伪装 | `enableAntiDetectionHooks` | **YES** ✅ |
| 58 | `setupAntiDetectionHooks` | `NSBundle objectForInfoDictionaryKey:` | Info.plist 键值伪装 | `enableAntiDetectionHooks` | **YES** ✅ |
| 59 | `setupAntiDetectionHooks` | `UIApplication canOpenURL:` | 阻止越狱检测 URL scheme | `enableAntiDetectionHooks` | **YES** ✅ |

#### K. Per-Image 安全 Hook

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 60 | `setupSafeHooks` (performMergedRebind) | 对每个 app image 单独执行 fishhook rebind (sysctl/MG/IOKit/SecItem等) | 无（硬编码） | ✅ 始终开启 |

#### L. 脱壳/克隆检测绕过

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 61 | `setupCloneDetectionBypass` | cryptid 伪造 (加密状态伪装) + Receipt 占位文件 + appStoreReceiptURL Hook | 无（硬编码） | ✅ 始终开启 |

#### M. 深度防护

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 62 | `setupIMPSpoofing` | IMP 越界扫描防护 | 无（硬编码） | ✅ 始终开启 |
| 63 | `setupBDFishhookBypass` | 禁用 `AWEFishhookInitTask execute` (GOT 表完整性校验) | 无（硬编码） | ✅ 始终开启 |
| 64 | `setupTSPKBypass` | TSPK 拦截链校验绕过 | 无（硬编码） | ✅ 始终开启 |
| 65 | `setupDeviceCheckBypass` | DeviceCheck / AppAttest 绕过 (返回错误) | 无（硬编码） | ✅ 始终开启 |
| 66 | `setupMMKVPathRedirection` | MMKV 存储路径重定向 (克隆数据隔离) | 无（硬编码） | ✅ 始终开启 |
| 67 | `setupSecurityPluginDisable` | 安全插件禁用 + 会话过期监控 + HMDCrashTracker 拦截 | 无（硬编码） | ✅ 始终开启 |

#### N. Keychain 隔离

| # | Hook 函数 | 目标 | 功能 | 开关 | 默认值 |
|---|----------|------|------|------|-------|
| 68 | `setupKeychainIsolationHooks` | `SecItemCopyMatching/SecItemAdd/SecItemUpdate/SecItemDelete` | fishhook，为 Keychain 操作注入 accessGroup 实现克隆隔离 | `enableKeychainIsolation` | **YES** ✅ |

#### O. 数据隔离

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 69 | `setupDataIsolationHooks` | NSHomeDirectory/NSSearchPath/NSFileManager/NSUserDefaults 路径重定向 | 无（硬编码，仅克隆模式生效） | ✅ 仅克隆模式 |

#### P. Passport/登录诊断

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 70 | `setupPassportHooks` | Hook AWEPassportNetworkManager/AWEPassportServiceImp 的登录请求，记录日志 | 无（硬编码） | ✅ 始终开启 |
| 71 | `setupLoginDiagnosticHooks` | Hook TTHttpTaskChromium resume，记录网络请求诊断信息 | 无（硬编码） | ✅ 始终开启 |

#### Q. 其他

| # | Hook 函数 | 功能 | 开关 | 默认值 |
|---|----------|------|------|-------|
| 72 | `ec_install_cellular_data_hook` | 强制 CTCellularData 回调返回 NotRestricted | 无（硬编码） | ✅ 始终开启 |
| 73 | `ec_trigger_network_permission_once` | 发起探针请求辅助 CommCenter 完成 App 注册 | 无（硬编码） | ✅ 始终开启 |

---

## 二、按排查优先级建议的禁用顺序

> **核心思路**：当前 v2424 的 constructor 同步部分只有 `setupMethodSwizzling`（#5~#16），
> 延迟部分 2 秒后执行。但 TikTok 仍然在 scene-create 阶段超时。
> 
> 这意味着 **#5~#16 的 Hook 在被 TikTok 启动期间高频调用时的 CPU 开销** 是最大嫌疑。
> 如果禁用全部同步 Hook 仍然崩溃，则说明是 TikTok 自身太重（与 Hook 无关）。

### 第 1 轮：排除同步 Hook

在 plist 配置中逐个设置以下键为 `NO`：

1. **`enableUIScreenHooks` = NO** → 禁用 #13~#16（UIScreen 伪装，启动时被高频调用）
2. **`enableUIDeviceHooks` = NO** → 禁用 #5~#11（UIDevice + NSProcessInfo 伪装）
3. **`enableIDFVHook` = NO** → 禁用 #12（IDFV 伪装）

### 第 2 轮：如果第 1 轮不能解决，排除延迟 Hook

在 plist 配置中逐个设置以下键为 `NO`：

4. **`enableNetworkInterception` = NO** → 禁用 #21~#25
5. **`enableTikTokHooks` = NO** → 禁用 #36~#45
6. **`enableAntiDetectionHooks` = NO** → 禁用 #52~#59 + #68
7. **`enableSysctlHooks` = NO** → 禁用 #46
8. **`enableMobileGestaltHooks` = NO** → 禁用 #47
9. **`enableNSCFLocaleHooks` = NO** → 禁用 #27
10. **`enableCFLocaleHooks` = NO** → 禁用 #28~#34
11. **`enableDiskBatteryHooks` = NO** → 禁用 #50~#51
12. **`enableCFBundleFishhook` = NO** → 禁用 #48
13. **`enableISASwizzling` = NO** → 禁用 #49

### 第 3 轮：终极排查（需要改代码）

如果以上全部禁用仍崩溃，问题出在硬编码的模块：
- 注释掉 `setupDeepProtection()` (#62~#67)
- 注释掉 `setupCloneDetectionBypass()` (#61)
- 注释掉 `installTikTokCrashGuards()` (#17)
- 注释掉 `setupSafeHooks()` / `performMergedRebind()` (#60)

---

## 三、配置文件位置

plist 路径（App 内）:
```
/TikTok.app/Frameworks/com.apple.preferences.display.plist
```

在此 plist 中添加对应的 Bool 键值即可控制开关，例如：
```xml
<key>enableUIScreenHooks</key>
<false/>
```

---

## 四、当前 Hook 开启状态总结 (v2425)

> 以下清单反映了 **v2425** 版本的默认开启状态。

### 🔴 极早期初始化 (Pre-Init)
*   `objc_setHook_getClass` (拦截 AAAASingularity) : ✅
*   `ec_install_crash_handler` (崩溃日志捕获) : ✅
*   `backgroundSession 拦截` (防 Heimdallr XPC 崩溃) : ✅
*   `sanitizeMainBinaryHeader` (隐藏越狱/注入痕迹) : ✅
*   `hooked_sigaction_fn` (保护崩溃拦截器) : ✅

### 🟡 同步执行 (高频设备信息，已加静态缓存)
*   `UIDevice systemVersion` (OS版本) : ✅
*   `UIDevice model` (机型) : ✅
*   `UIDevice localizedModel` (本地化机型) : ✅
*   `UIDevice name` (设备名) : ✅
*   `UIDevice systemName` (系统名) : ✅
*   `NSProcessInfo operatingSystemVersionString` (OS版本字符串) : ✅
*   `NSProcessInfo operatingSystemVersion` (OS版本结构体) : ✅
*   `UIDevice identifierForVendor` (IDFV) : ✅
*   `UIScreen bounds` (屏幕尺寸) : ✅
*   `UIScreen scale` (屏幕缩放比) : ✅
*   `UIScreen nativeBounds` (原生分辨率) : ✅
*   `UIScreen maximumFramesPerSecond` (最大刷新率) : ✅

### 🟢 延迟执行 (网络、反检测、深度防护等)
**崩溃防护与标识符**
*   `installTikTokCrashGuards` (防 NSArray KVO 崩溃) : ✅
*   `cleanKeychainIfNeeded` (清除旧设备残留 ID) : ✅
*   `setupTTInstallIDManagerHooks` (TikTok ID 获取) : ✅

**网络拦截模块**
*   `NSURLSession dataTaskWithRequest` (L1 请求替换) : ✅
*   `TTNetworkManager` (L2 请求替换) : ✅
*   `NSURLProtocol` (L3 协议拦截) : ✅
*   `BoringSSL` (L4 SSL拦截，预留) : ✅
*   `QUIC 禁用` (L5 降级为 TCP) : ✅

**区域与语言伪装**
*   `__NSCFLocale` (C层区域替换) : ✅
*   `CFLocaleGetValue / CFLocaleCopy` (底层 CF 语言读取) : ✅
*   `NSLocale preferredLanguages / currentLocale` : ✅
*   `NSBundle preferredLocalizations` : ✅
*   `NSUserDefaults AppleLanguages` (读写/删除拦截) : ✅
*   `NSBundle appStoreReceiptURL` (DRM 绕过) : ✅

**运营商伪装**
*   `CTCarrier` (MNC/MCC/CountryCode) : ❌ **(默认关闭，配置了运营商名称才会开启)**

**TikTok 专用安全与风控绕过**
*   `UIDevice btd_isJailBroken` (越狱检测) : ✅
*   `NSUserDefaults awe_installID` (TikTok 内部 ID 读取) : ✅
*   `AWELanguageManager currentLanguage` (语言检测) : ✅
*   `AAWEBootChecker` (启动校验绕过) : ✅
*   `AAWEBootStub` (禁用启动桩代码) : ✅
*   `AAAASingularity` (全面无效化安全框架) : ✅
*   `NSBundle bundleWithIdentifier` (隐藏 XCTest) : ✅
*   `TTKSingularityEPAHelper` (越狱检测方法无效化) : ✅
*   `AWEIsOfficialBundleId / fakedBundleID` (内部 API 伪装) : ✅
*   `storeRegion / currentRegion` (商店与区域伪装) : ✅

**底层系统伪装**
*   `sysctlbyname / uname` (底层硬件机型伪造) : ✅
*   `MGCopyAnswer / MGGetBoolAnswer` (底层硬件指纹伪造) : ✅
*   `CFBundleGetValueForInfoDictionaryKey` (底层 Bundle ID 伪造) : ✅
*   `NSObject ISA Swizzling` (类名保护) : ✅

**磁盘/电池伪装**
*   `NSFileManager attributesOfFileSystemForPath` (磁盘空间伪造) : ✅
*   `UIDevice batteryLevel / batteryState` (电池状态伪造) : ✅

**反检测模块**
*   `stat / lstat / access / faccessat` (拦截文件与越狱检测) : ✅
*   `dyld_image_count / dyld_get_image_name` (隐藏注入动态库) : ✅
*   `NSBundleResourceRequest` (资源加载拦截) : ✅
*   `fork / vfork` (禁止 fork 检测) : ✅
*   `abort / exit / kill` (拦截 App 自杀) : ✅
*   `statvfs` (绕过根分区只读检测) : ✅
*   `UIApplication canOpenURL` (阻止通过 URL Scheme 检测越狱工具) : ✅

**安全与脱壳检测绕过**
*   `_dyld_register_func_for_add_image` (安全 Per-Image rebind) : ✅
*   `cryptid 伪造` (伪装为已加密状态) : ✅

**深度安全防护**
*   `IMP 越界扫描防护` (保护自定义 IMP) : ✅
*   `bdfishhook 禁用` (防止 GOT 表校验) : ✅
*   `TSPK 拦截链校验绕过` : ✅
*   `DeviceCheck / AppAttest 绕过` (返回模拟失败) : ✅
*   `MMKVPathRedirection` (MMKV 缓存隔离) : ✅
*   `SecurityPluginDisable` (关闭内建安全插件) : ✅

**沙盒隔离**
*   `SecItemCopyMatching / SecItemAdd` (Keychain 操作隔离) : ✅
*   `NSHomeDirectory / NSFileManager` (克隆分身的数据目录重定向) : ✅

**诊断与辅助**
*   `setupPassportHooks` (登录请求监控) : ✅
*   `setupLoginDiagnosticHooks` (网络请求监控) : ✅
*   `ec_install_cellular_data_hook` (网络弹窗权限强制绕过) : ✅
*   `ec_trigger_network_permission_once` (启动触发网络注册) : ✅

