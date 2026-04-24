# TikTok 完整反逆向检测机制深度分析报告 V3.0

> 本报告基于对 `/Users/hh/Desktop/Payload/TikTok.app/Frameworks/TikTokCore.framework/TikTokCore`（662MB）的全量静态字符串扫描，结合 `ECMAIN/ECDeviceSpoof.m` 注入逻辑的交叉比对，列出了**所有可发现的检测手段**及对应绕过策略。

---

## 一、越狱环境检测 (Jailbreak Detection)

### 1.1 路径存在性探测
TikTok 硬编码了大量越狱环境路径，通过 `access()` / `stat()` / `fopen()` 逐一探测：

| 检测路径 | 含义 |
|---|---|
| `/Applications/Cydia.app` | Cydia 包管理器 |
| `/Library/MobileSubstrate/MobileSubstrate.dylib` | Substrate 主体 |
| `/Library/MobileSubstrate/CydiaSubstrate.dylib` | CydiaSubstrate 主体 |
| `/Library/MobileSubstrate/DynamicLibraries/LiveClock.plist` | 典型插件占位 |
| `/Library/MobileSubstrate/DynamicLibraries/Veency.plist` | VNC 插件 |
| `/etc/apt` | APT 包管理配置目录 |
| `/private/var/lib/apt` | APT 数据库 |
| `/private/var/lib/cydia` | Cydia 数据 |
| `/private/var/tmp/cydia.log` | Cydia 日志 |
| `/usr/bin/ssh` / `/usr/sbin/sshd` | SSH 服务 |
| `/usr/libexec/ssh-keysign` | SSH 签名辅助 |
| `/usr/lib/libjailbreak.dylib` | libjailbreak |
| `/usr/share/jailbreak/injectme.plist` | 通用越狱标记 |
| `/var/lib/dpkg/info/mobilesubstrate.md5sums` | dpkg 记录 |
| `/var/lib/undecimus/apt` | Unc0ver APT |
| `/var/lib/cydia` | Cydia 数据目录 |
| `/etc/apt/sources.list.d/sileo.sources` | Sileo 源 |
| `/etc/apt/sources.list.d/electra.list` | Electra 源 |
| `/etc/apt/undecimus/undecimus.list` | Unc0ver APT 源 |
| `/jb/libjailbreak.dylib` | palera1n/roothide 变体 |
| `/jb/jailbreakd.plist` | jailbreakd 配置 |
| `/bin/bash` | bash 存在（越狱标志） |

**调用的 ObjC 方法（已确认）**：
- `deviceIsJailbroken` — 封装结果的属性
- `btd_isJailBroken` — ByteDance 分类方法
- `tspk_device_info_btd_isJailBroken` — TSPK 拦截后的代理调用
- `_isJailBroken` / `isJailBroken` / `is_jailbroken` — 多个命名变体
- `_skipAdvancedJailbreakValidation` — 越狱检测跳过开关（A/B 测试）
- `binaryImagesLogStrWithMustIncludeImagesNames:includePossibleJailbreakImage:` — 在崩溃日志中标记可疑越狱映像

### 1.2 沙盒逃逸写入测试
尝试向只有 root/jailbreak 才能写入的路径执行 `fopen(.., "w")`：
- `/private/jailbreak_test_file`
- `/var/mobile/jb_write_test`

失败说明沙盒完整，成功则视为越狱设备。

### 1.3 符号链接检测
对 `/Applications`、`/Library/Ringtones`、`/Library/Wallpaper`、`/usr/arm-apple-darwin9` 等路径调用 `lstat()`，检查返回的 `st_mode` 是否为 `S_IFLNK`（符号链接），越狱环境这些目录往往是 symlink。

### 1.4 文件系统特征检测
调用 `statvfs()` 检测根分区（`/`）的挂载标志：正常 iOS 根分区为只读（`ST_RDONLY`），越狱后根分区可写则暴露身份。

---

## 二、反调试检测 (Anti-Debug)

### 2.1 进程状态位检测
**已确认符号**：`proc_pidinfo`、`debuggerAttached`、`canFindDebuggerAttached`

底层通过 `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` 获取 `kinfo_proc` 结构体，读取 `kp_proc.p_flag` 的 `P_TRACED` 位（`0x00000800`）。若该位为 1，说明进程被调试器跟踪。

**⚠️ 关键点**：TikTok 在若干地方会直接使用汇编 `svc 0x80` 绕过 C 库封装，使 `fishhook` 对 `sysctl` 的拦截完全失效。

### 2.2 Mach 异常端口检测
**已确认符号**：`mach_exception_prefix`、`mach_exception_list`、`enable_mach_exception`

通过 `task_get_exception_ports()` 获取当前任务的异常端口。正常运行时异常端口为空；调试器附加后会注册端口，从而被检测。

### 2.3 线程分析
**已确认符号**：`task_threads`、`task_info`、`thread_get_state`、`exception_thread_info`

枚举线程，检测是否存在 Debugserver/LLDB 注入的线程，或检测线程数量异常（每个调试断点都会引入额外线程）。

### 2.4 父进程检测
**已确认字符串**：`Parent Process:      [launchd]`

通过 `getppid()` 获取父进程 PID，再用 `sysctl` 查 `KERN_PROC_PID` 验证父进程名称。正常 iOS App 的父进程应为 `launchd`（PID=1），若为 `debugserver` 或 `LLDB` 则触发警报。

### 2.5 V2 采样合规计数器（安全环境评分）
**已确认方法**：
```
calculateV2ValueWithTimestamp:uid:systemVersion:firstLaunchDate:
  AFSDKVersion:isSimulator:isDevBuild:isJailBroken:isCounterValid:isDebuggerAttached:
```
综合环境评分被编码为一个"V2值"，注入到每个风控请求头中。服务端通过对比历史值来判断设备状态是否异常。

---

## 三、注入与 Hook 检测 (Injection & Hook Detection)

### 3.1 Heimdallr 动态库映像监控
**已确认符号**：`HMDBinaryImage`、`HMDInjectedInfo`、`com.hmd.add.image`、`binaryImagesLogStrWithMustIncludeImagesNames:includePossibleJailbreakImage:`

- 注册 `_dyld_register_func_for_add_image` 回调，每次有新的 dylib 被加载，立即触发扫描回调。
- 提取 Mach-O 的 `__TEXT.__cstring` 段，做字符串内存搜索。
- 识别已知的黑名单库：`TweakInject`、`libsubstrate`、`SubstrateLoader`、`Frida`、`ECDeviceSpoof`（如果明文存在则命中）。

### 3.2 bdfishhook 内置符号表校验
**已确认符号**：`fishhookConflictFixEnable`、`bdfishhook_sys_offset_cache`、`bdfishhook_offset_cache_last_config`、`AWEFishhookInitTask`

TikTok 内置了自研版 `fishhook`，并周期性地比较 GOT（全局偏移表）和 Lazy Symbol Pointer Table 中关键系统函数（如 `open`、`stat`、`dlopen`）的当前地址与其缓存的"原始地址"。若发现地址被篡改（即我们用传统 fishhook 进行了 Hook），会触发 `fishhookConflictFixEnable` 逻辑。

### 3.3 ObjC Method IMP 地址越界检测
**已确认类**：`AWEFakeBundleIDManager`、`AWEDeviceManager`、`TTInstallIDManager`、`BDInstall`

通过 `class_getMethodImplementation()` 获取关键方法的 IMP，校验该地址是否落在 `TikTokCore.framework` 的 `__TEXT` 段内存范围内（`[TikTokCore_base, TikTokCore_base + TikTokCore_size]`）。若 IMP 指向外部（即我们的 `spoof_plugin` 地址空间），即触发告警。

### 3.4 TSPK 拦截器双向检测
**已确认类**：`TSPKInterceptorCheckerImpl`、`TSPKSparkSecurityPipeline`、`TSPKDfCheckSubscriber`

TSPK 不仅自己 Hook 系统 API（比我们更早），还会校验这些 API 的 Hook 链是否合法。对于 `UIDevice`、`NSLocale`、`sysctlbyname` 等接口，TSPK 在 Hook 时记录了自己的代理 IMP 地址；若发现调用链中间还有额外的跳转（我们的 swizzle），立即标记为"非法拦截"。

---

## 四、克隆与多开检测 (Clone Detection)

### 4.1 AWEFakeBundleIDManager 管道
**已确认符号**：`AWEFakeBundleIDManager`、`fakedBundleID`、`isOfficialBundleId`、`_aweLazyRegisterLoad_AWEFakeBundleID`

TikTok 内部维护了一个"伪 Bundle ID"检测器，逻辑如下：
1. 读取 `[[NSBundle mainBundle] bundleIdentifier]`。
2. 对比白名单：`com.zhiliaoapp.musically`（国际版）、`com.ss.iphone.ugc.Aweme`（中国版）、`snssdk1128`、`snssdk1233` 等。
3. 若不在白名单，设置 `fakedBundleID` 并把 `isOfficialBundleId` 标记为 `NO`，后续功能受限。
4. 底层还会物理读取 `Info.plist` 文件进行校验，不仅依赖 `NSBundle` API。

### 4.2 App Group 共享容器权限校验
**已确认符号**：`extensionAppGroupIdentifier`、`containerURLForSecurityApplicationGroupIdentifier:`、`appGroupsIdentifier`

尝试访问 `group.com.zhiliaoapp.musically.*` App Group 共享容器。克隆 App 的签名 Team ID 不是官方的，无权访问该 Group，返回 `nil` 即可判定为克隆实例。

### 4.3 Keychain 访问组校验
**已确认符号**：`keychainAccessGroupWithName:`、`kSecAttrAccessGroup`、`setSharedKeyChain`、`saveToSharedKeychain`

尝试读取 `kSecAttrAccessGroup = "T8ALTGMVXN.com.zhiliaoapp.musically"` 中的 Keychain 条目（Team ID 为官方 `T8ALTGMVXN`）。克隆 App 使用不同的 Team ID，无法读取官方 Keychain，触发"共享登录"异常流程。

### 4.4 ZTI Token (Device Token Index) 比对
**已确认日志**：`[Device-ZTI] local_did=%@, dtoken_did=%@, local_iid=%@, dtoken_iid=%@`、`[Device-ZTI] did or iid not match`

TikTok 维护了一个 `dtoken`（Device Token），其中嵌入了 `device_id` 和 `install_id`。启动时对比本地缓存的 DID/IID 与 dtoken 中解密出来的值，若不一致说明设备或安装信息被篡改，触发重新注册流程，同时上报风控事件。

---

## 五、硬件指纹与设备 ID 采集 (Device Fingerprinting)

### 5.1 TSPK 设备信息采集管线
**已确认管线列表**：
- `TSPKDeviceInfoOfUIDevicePipeline` — `UIDevice.model`、`systemVersion`、`name`
- `TSPKDeviceInfoOfUIScreenPipeline` — `UIScreen.bounds`、`nativeScale`、`nativeBounds`
- `TSPKDeviceInfoOfSysctlByNamePipeline` — `hw.machine`、`hw.model`、`kern.version`
- `TSPKDeviceInfoOfNSProcessInfoPipeline` — `NSProcessInfo.physicalMemory`
- `TSPKDeviceInfoOfNSFileManagerPipeline` — 磁盘容量 `statvfs`
- `TSPKIDFVOfUIDevicePipeline` — IDFV（厂商标识符）
- `TSPKMotionOfUIDevicePipeline` — 设备方向、运动传感器
- `TSPKDeviceInfoOfTaskThreadsPipeline` — 线程数检测

### 5.2 风控 SDK 设备注册
**已确认 URL**：
- `https://log.tiktokv.com/service/2/device_register/`
- `https://api.tiktokv.com/service/2/device_register/`

启动时将采集到的完整设备指纹（包含 `device_id`、`install_id`、`idfv`、`openudid`、`system_version`、`device_model` 等）上报到字节跳动风控服务端，服务端颁发 `device_token`，后续所有请求必须携带此 token。

### 5.3 Apple DeviceCheck 与 AppAttest
**已确认符号**：`TTKDeviceCheckService`、`TTKDeviceCheckInitTask`、`generateTokenWithCompletionHandler:`、`generateAssertion:clientDataHash:completionHandler:`、`attestationObject`

- **DeviceCheck**：调用苹果官方 `DCDevice.generateToken()` 生成设备令牌，提交给 TikTok 服务端由 Apple 验证设备合法性。
- **AppAttest**：更强的硬件安全验证，`generateAssertion` 需要 Secure Enclave 参与，无法伪造。

### 5.4 网络请求签名体系
每个 HTTPS 请求必须携带以下动态签名头（无法静态复现）：
- `X-Gorgon` — 请求签名（基于请求体 + 设备指纹）
- `X-Khronos` — 时间戳（与服务端的时间误差超过阈值即拒绝）
- `X-Argus` — 辅助签名（环境安全评分）
- `X-Ladon` — 设备风险令牌
- `x-tt-token` — 用户会话令牌
- `device_token` — 设备注册令牌（来自 DeviceCheck）
- `csrf_token` — 跨站请求伪造防护令牌

---

## 六、ECMAIN 注入指纹总结（已暴露的特征）

当前 `ECDeviceSpoof.dylib`（即 `spoof_plugin.dat`）存在以下明文特征，会被 Heimdallr 内存扫描直接命中：

| 暴露特征 | 类型 | 被检测方式 |
|---|---|---|
| `ECDeviceSpoof` | 明文字符串 | HMD 字符串扫描 |
| `ECBatterySpoof` | 明文字符串 | HMD 字符串扫描 |
| `/var/mobile/Documents/ECSpoof` | 路径字符串 | HMD + 文件监控 |
| `/usr/lib/TweakInject.dylib` | 依赖路径 | HMD 黑名单匹配 |
| `/usr/lib/libsubstrate.dylib` | 依赖路径 | HMD 黑名单匹配 |
| `/usr/lib/libsubstitute.dylib` | 依赖路径 | HMD 黑名单匹配 |
| `DYLD_INSERT_LIBRARIES` | 环境变量字符串 | TSPK 环境检测 |
| `method_exchangeImplementations` | ObjC Runtime Hook | IMP 地址越界检测 |
| `rebind_symbols` (fishhook) | GOT Hook | bdfishhook 冲突检测 |
| `[ecwg][ECDeviceSpoof]` 日志前缀 | NSLog 输出 | 日志采样上报 |
| `Swizzle failed: method not found` | 调试日志 | 日志采样上报 |
| `Setting up TikTok-specific hooks` | 调试日志 | 日志采样上报 |

---

## 七、绕过策略（学术研究级）

### 7.1 【最高优先级】Dylib 映像断链（Heimdallr 致盲）

**目标**：让 `_dyld_image_count`、`_dyld_get_image_name` 遍历不到我们的 dylib。

**实现**（在 `__attribute__((constructor, visibility("hidden")))` 中执行）：

```c
// 获取 dyld_all_image_infos 结构体（位于 __DATA 段，地址存在 task_info 里）
// arm64 中可从 dyld_get_all_image_infos() 获取（仅限越狱）
#include <mach-o/dyld_images.h>

static void unlink_self_from_dyld(void) {
    const struct dyld_all_image_infos *infos = _dyld_get_all_image_infos();
    // 查找自己（通过 Mach-O header 地址匹配）
    // 将自身条目从 infoArray 中移除（内存移位 + 修改 infoArrayCount）
    // 之后 _dyld_image_count 减少 1，HMD 完全看不到我们
}
```

### 7.2 全量字符串加密（消除 HMD 内存扫描特征）

**目标**：二进制和内存中不出现任何明文黑名单词。

**实现**：编写编译期 XOR 字符串加密宏：

```objc
// 编译期 XOR 加密（每个字符 ^ KEY）
#define EC_OBFSTR(s) ({                          \
    static const char _enc[] = { EC_ENCODE(s) }; \
    ec_decode(_enc, sizeof(_enc));               \
})
// 用法：NSString *dylib = EC_OBFSTR("ECDeviceSpoof");
// 内存中只存在加密字节，调用时才解密，使用后立即清零
```

同时彻底移除所有 `NSLog` 调试输出，避免日志采样。

### 7.3 升级为 Inline Hook（绕过 IMP 越界检测）

**目标**：保持方法 IMP 地址在 TikTokCore 地址空间内，规避地址校验。

**实现**：使用 Dobby 框架对 TikTokCore 内部函数直接打 Inline Patch：

```c
// 不替换 IMP，而是在目标函数体开头写入跳转指令
// 需要先 mprotect 使内存可写
DobbyHook((void *)target_function_address, (void *)my_hook, (void **)&original);
// IMP 依然指向 target_function_address，只是执行时会跳到我们的 hook
```

### 7.4 底层文件 IO 重定向（绕过物理 Info.plist 读取）

**目标**：让底层 `open()`/`read()` 读到的 `Info.plist` 永远是官方原版。

**实现**：对 `open` 和 `openat` 进行 Inline Hook：

```c
static int hooked_open(const char *path, int flags, ...) {
    if (path && strstr(path, "Info.plist")) {
        // 返回伪造的 Info.plist fd
        return open("/path/to/official_info.plist", O_RDONLY);
    }
    return original_open(path, flags);
}
```

### 7.5 应对 DeviceCheck / AppAttest

- **DeviceCheck** 可通过拦截 `DCDevice.generateToken()` 方法，缓存并复用一个真实设备的 token。
- **AppAttest** 需要 Secure Enclave 私钥，**无法伪造**。只能通过不触发 AppAttest 流程（禁用相关 A/B 开关 `visualSearchScreenshotOptDeviceCheckEnabled`）来规避。

### 7.6 修复 ZTI Token 不一致问题

当克隆环境更换了 device_id，需要同步修改所有缓存存储点：
- `NSUserDefaults`：`kTTInstallIDKeyDeviceID`、`kTTInstallIDKeyInstallID`
- `Keychain`：官方 access group 下的 device_id 条目（需 hook `kSecAttrAccessGroup`）
- 内存缓存：`TTInstallIDManager.deviceID`、`BDInstall.currentDeviceID`

必须确保这三处返回完全一致的值，否则 ZTI 比对时必然触发风控。

---

## 结论

TikTok 的安全防护体系是**多层纵深防御**：
1. **启动早期**：Heimdallr 注册动态库监控，TSPK 抢占关键系统 API
2. **运行时**：bdfishhook 定期校验符号表，TSPK 双向校验拦截链合法性
3. **网络层**：Gorgon/Argus/Ladon 多签名体系，服务端验证设备令牌
4. **硬件层**：Apple DeviceCheck/AppAttest 防最终伪造

**当前 ECDeviceSpoof 最致命的问题**是明文字符串特征（被 HMD 内存扫描）+ 传统 Method Swizzle（被 IMP 地址校验）+ Keychain 访问组不匹配（无法读取官方 token）。按优先级：先做**字符串全加密** → 再做 **Dylib 断链隐藏** → 最后做 **Inline Hook 升级**，可以大幅提升注入的隐蔽性。
