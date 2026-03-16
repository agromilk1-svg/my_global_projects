# ECDeviceSpoof Hook 详细信息

> 最后更新: 2026-02-27 Build #889
> 所有开关通过 `spoofBoolForKey:defaultValue:` 从 plist 读取

---

## 一、设备伪装 (MethodSwizzling 组)

### 1. `enableMethodSwizzling` — ObjC 方法交换总开关
- **默认**: ✅ YES
- **作用**: 控制 UIDevice/UIScreen/IDFV 等 ObjC 方法交换的总开关。关闭时以下子开关全部失效。

### 2. `enableUIDeviceHooks` — UIDevice 伪装
- **默认**: ✅ YES
- **Hook 目标**: `UIDevice` 的 5 个属性
  - `systemVersion` → 伪装 iOS 版本号 (如 16.7.10)
  - `model` → 伪装设备类型 (如 iPhone)
  - `localizedModel` → 伪装本地化设备名
  - `name` → 伪装用户设备名
  - `systemName` → 伪装系统名称
- **额外**: Hook `NSProcessInfo.operatingSystemVersion` 使系统版本号一致

### 3. `enableIDFVHook` — IDFV 隔离
- **默认**: ✅ YES
- **Hook 目标**: `UIDevice.identifierForVendor`
- **作用**: 为每个克隆实例生成独立的 IDFV，并持久化到 `.com.apple.uikit.idfv.cache`，确保多克隆之间设备标识隔离

### 4. `enableUIScreenHooks` — 屏幕尺寸伪装
- **默认**: ✅ YES
- **Hook 目标**: `UIScreen` 的 4 个属性
  - `bounds` → 伪装屏幕尺寸
  - `scale` → 伪装缩放比例
  - `nativeBounds` → 伪装原生分辨率
  - `maximumFramesPerSecond` → 伪装刷新率
- **作用**: 使目标设备型号与屏幕参数一致

### 5. `enableCarrierHooks` — 运营商伪装 (CTCarrier)
- **默认**: ❌ NO（但当配置了 `carrierName` 时自动启用）
- **Hook 目标**: `CTCarrier` 的 4 个属性
  - `carrierName` → 运营商名称 (如 NTT docomo)
  - `mobileCountryCode` → MCC (如 440)
  - `mobileNetworkCode` → MNC (如 10)
  - `isoCountryCode` → 国家代码 (如 JP)
- **注意**: 默认关闭是为了避免多出 carrier_region 参数暴露伪装，选择运营商后自动启用

### 6. `enableDiskBatteryHooks` — 磁盘/电池伪装
- **默认**: ✅ YES
- **Hook 目标**: `NSFileManager` 和 `UIDevice`
  - 磁盘可用空间/总空间
  - 电池电量/充电状态
- **作用**: 使磁盘/电池信息与目标设备型号匹配

---

## 二、系统调用伪装 (Sysctl 组)

### 7. `enableSysctlHooks` — Sysctl 总开关
- **默认**: ✅ YES
- **作用**: 控制 `sysctlbyname` 和 `uname` 的 Hook 总开关。由「全链路联动」强制启用。

### 8. `enableSysctlMachine` — 机型伪装
- **默认**: ✅ YES
- **Hook 目标**:
  - `sysctlbyname("hw.machine")` → 伪装机型标识 (如 iPhone10,1)
  - `uname()` → 伪装 utsname.machine
- **作用**: C 层面的设备型号伪装，与 UIDevice Hook 配合形成完整伪装链

### 9. `enableSysctlKern` — 内核版本伪装
- **默认**: ✅ YES
- **Hook 目标**:
  - `sysctlbyname("kern.osversion")` → 伪装系统构建版本号
  - `sysctlbyname("kern.version")` → 伪装 Darwin 内核版本
- **作用**: 使操作系统底层版本信息与目标 iOS 版本一致

### 10. `enableSysctlHardware` — 硬件参数伪装
- **默认**: ✅ YES
- **Hook 目标**:
  - `sysctlbyname("hw.ncpu")` / `hw.physicalcpu` / `hw.logicalcpu` → CPU 核心数
  - `sysctlbyname("hw.memsize")` / `hw.physmem` → 物理内存大小
- **作用**: 使硬件规格与目标设备型号匹配

### 11. `enableSysctlBoottime` — 启动时间伪装
- **默认**: ✅ YES
- **Hook 目标**: `sysctlbyname("kern.boottime")`
- **作用**: 随机化设备启动时间，防止通过 boottime 追踪设备身份

---

## 三、区域/语言伪装

### 12. `enableCFLocaleHooks` — CFLocale 伪装 (C 层)
- **默认**: ✅ YES
- **Hook 目标**: `CFLocaleCopyPreferredLanguages` (通过 fishhook rebind)
- **作用**: C 函数层面的语言/区域伪装，注册到全局 rebind 合并机制

### 13. `enableNSCFLocaleHooks` — NSLocale 伪装 (ObjC 层)
- **默认**: ✅ YES
- **Hook 目标**: `__NSCFLocale` 的 5 个方法
  - `objectForKey:` → 拦截 NSLocaleCountryCode/NSLocaleLanguageCode 等
  - `localeIdentifier` → 伪装区域标识符 (如 ja_JP)
  - `countryCode` → 伪装国家代码
  - `languageCode` → 伪装语言代码
  - `currencyCode` → 伪装货币代码
- **额外 Hook**:
  - `+[NSLocale preferredLanguages]` → 伪装首选语言列表
  - `+[NSLocale currentLocale]` / `autoupdatingCurrentLocale` / `systemLocale`
  - `-[NSBundle preferredLocalizations]` → 伪装应用本地化
  - `-[NSUserDefaults objectForKey:]` → 拦截 AppleLanguages 查询
  - `+[NSTimeZone localTimeZone]` / `systemTimeZone` → 伪装时区

---

## 四、网络拦截

### 14. `enableNetworkInterception` — 网络拦截总开关
- **默认**: ✅ YES
- **作用**: 控制以下 L1-L4 层和 QUIC 禁用的总开关

### 15. `enableNetworkL1` — NSURLSession Hook
- **默认**: ✅ YES
- **Hook 目标**: `NSURLSession -dataTaskWithRequest:completionHandler:`
- **作用**: 拦截并记录通过 NSURLSession 发出的第三方 SDK 流量

### 16. `enableNetworkL2` — TTNet/SSL Hook
- **默认**: ✅ YES
- **Hook 目标**:
  - `TTNetworkManager` 类方法 (ByteDance 自有网络库)
  - `TTHttpTaskChromium.resume` → **MSSDK 风控拦截在此层**
  - Passport/Login 相关请求记录也在此层
  - SSL 加解密 Hook (明文数据拦截)
- **关键作用**: 登录流程的 Passport Hook (7 处) 依赖此开关

### 17. `enableNetworkL3` — NSURLProtocol 全局注册
- **默认**: ✅ YES
- **Hook 目标**: 注册 `ECNetworkInterceptorProtocol` 为全局 NSURLProtocol
- **作用**: 记录所有通过 NSURLSession 的 TikTok/ByteDance 域名请求（仅日志，不拦截）

### 18. `disableQUIC` — 禁用 QUIC/UDP
- **默认**: ✅ YES (即默认禁用 QUIC)
- **Hook 目标**: `TTNetworkManager -enableQuic` 返回 NO
- **作用**: 强制 TikTok 使用 TCP/TLS 而非 QUIC，使网络流量可被代理/拦截

### 19. `enableNetworkHooks` — 网络信息伪装
- **默认**: ✅ YES
- **Hook 目标**: `CNCopyCurrentNetworkInfo` (通过 fishhook rebind)
- **作用**: 伪装 Wi-Fi SSID/BSSID 信息

---

## 五、反检测/反越狱

### 20. `enableAntiDetectionHooks` — 反检测总开关
- **默认**: ✅ YES
- **作用**: 控制以下 fork/BundleID/canOpenURL/Keychain 子开关

### 21. `enableForkHooks` — 沙盒完整性 (fork/vfork)
- **默认**: ✅ YES
- **Hook 目标**: `fork()` / `vfork()` (通过 fishhook rebind)
- **作用**: 让 fork/vfork 返回 -1 (ENOSYS)，模拟正常沙盒环境。越狱环境中 fork 会成功，被 TikTok 用于检测越狱。

### 22. `enableBundleIDHook` — Bundle ID 查询伪装
- **默认**: ✅ YES
- **Hook 目标**: `NSBundle` 的 3 个方法
  - `infoDictionary` → 替换 CFBundleIdentifier
  - `objectForInfoDictionaryKey:` → 拦截 BundleID 查询
  - `pathForResource:ofType:` → 拦截资源路径查询
- **作用**: 使克隆版 Bundle ID 看起来与正版一致 (com.zhiliaoapp.musically)

### 23. `enableCanOpenURLHook` — URL Scheme 隐藏
- **默认**: ✅ YES
- **Hook 目标**: `UIApplication -canOpenURL:`
- **作用**: 对 ECMAIN 相关 URL Scheme 返回 NO，隐藏管理工具的存在

### 24. `enableKeychainIsolation` — Keychain 隔离
- **默认**: ✅ YES
- **Hook 目标**: Security.framework 的 4 个 C 函数 (通过 fishhook rebind)
  - `SecItemAdd` → 修改 kSecAttrAccessGroup，隔离写入
  - `SecItemCopyMatching` → 修改查询条件，隔离读取
  - `SecItemUpdate` → 修改更新条件，隔离修改
  - `SecItemDelete` → 修改删除条件，隔离删除
- **作用**: 每个克隆实例的 Keychain 数据完全隔离，防止登录信息交叉污染

---

## 六、C 函数 Hook (fishhook rebind)

### 25. `enableCFBundleFishhook` — CFBundle C 函数伪装
- **默认**: ✅ YES
- **Hook 目标**: Core Foundation 的 3 个 C 函数
  - `CFBundleGetIdentifier` → 伪装 C 层 Bundle ID
  - `CFBundleGetValueForInfoDictionaryKey` → 伪装 Info.plist 查询
  - `CFBundleCopyBundleURL` → 伪装 Bundle URL
- **作用**: 覆盖 C 层面的 BundleID 查询，与 ObjC 层 NSBundle Hook 形成完整链

### 26. `enableMobileGestaltHooks` — 硬件指纹伪装
- **默认**: ✅ YES
- **Hook 目标**: `MGCopyAnswer` (通过 fishhook rebind)
- **作用**: 拦截 MobileGestalt 框架的硬件信息查询，伪装设备硬件标识

### 27. `enableISASwizzling` — ISA 指针交换
- **默认**: ✅ YES
- **Hook 目标**: `object_setClass` / `object_getClass` (通过 fishhook rebind)
- **作用**: 防止运行时 class 检查暴露 Hook 的存在

---

## 七、TikTok 专用

### 28. `enableTikTokHooks` — TikTok 专用 Hook
- **默认**: ✅ YES
- **Hook 目标**:
  - `NSUserDefaults -awe_installID` → 伪装安装 ID
  - `AWELanguageManager -currentLanguage` → 伪装 TikTok 内部语言
  - `IESForestKVStorage` / `BDAutoTrack` → 拦截设备追踪
  - `BTDAppRegionConfig` / `AWERemoteConfig` → 伪装区域配置
  - `TTNetworkManager -appRegion` / `-priorityRegion` → 伪装网络区域
- **作用**: 针对 TikTok/ByteDance 自有 SDK 的深度伪装

---

## 八、全链路联动机制

**不是独立开关，而是自动检测逻辑**：

当以下任一开关启用时，系统自动强制启用所有设备伪装相关 Hook（UIDevice/Sysctl/MobileGestalt/UIScreen），确保设备信息在所有层面一致：

```
anyDeviceHookEnabled = enableMethodSwizzling || enableUIDeviceHooks || 
  enableSysctlHooks || enableMobileGestaltHooks || enableDiskBatteryHooks || 
  enableUIScreenHooks || enableSysctlMachine || enableSysctlKern || 
  enableSysctlHardware || enableSysctlBoottime
```

联动触发的操作：
1. 强制启用 `setupNetworkInterception()` (网络拦截)
2. 强制启用 `setupSafeHooks()` (sysctl/uname/rebind)
3. 强制启用 `setupAntiDetectionHooks()` (反越狱检测)

---

## 总结

| 开关 | 默认 | 类型 |
|---|---|---|
| enableMethodSwizzling | ✅ YES | 总开关 |
| enableUIDeviceHooks | ✅ YES | 子开关 |
| enableIDFVHook | ✅ YES | 子开关 |
| enableUIScreenHooks | ✅ YES | 子开关 |
| enableCarrierHooks | ❌ NO (自动检测) | 子开关 |
| enableDiskBatteryHooks | ✅ YES | 子开关 |
| enableSysctlHooks | ✅ YES | 总开关 |
| enableSysctlMachine | ✅ YES | 子开关 |
| enableSysctlKern | ✅ YES | 子开关 |
| enableSysctlHardware | ✅ YES | 子开关 |
| enableSysctlBoottime | ✅ YES | 子开关 |
| enableCFLocaleHooks | ✅ YES | 独立 |
| enableNSCFLocaleHooks | ✅ YES | 独立 |
| enableNetworkInterception | ✅ YES | 总开关 |
| enableNetworkL1 | ✅ YES | 子开关 |
| enableNetworkL2 | ✅ YES | 子开关 |
| enableNetworkL3 | ✅ YES | 子开关 |
| disableQUIC | ✅ YES | 独立 |
| enableNetworkHooks | ✅ YES | 独立 |
| enableAntiDetectionHooks | ✅ YES | 总开关 |
| enableForkHooks | ✅ YES | 子开关 |
| enableBundleIDHook | ✅ YES | 子开关 |
| enableCanOpenURLHook | ✅ YES | 子开关 |
| enableKeychainIsolation | ✅ YES | 子开关 |
| enableCFBundleFishhook | ✅ YES | 独立 |
| enableMobileGestaltHooks | ✅ YES | 独立 |
| enableISASwizzling | ✅ YES | 独立 |
| enableTikTokHooks | ✅ YES | 独立 |
