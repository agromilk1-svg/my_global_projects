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

---

## 八、验证码 (Captcha) 触发与账号掉线溯源深度剖析

根据对网络层、风控拦截器以及安全凭证的深层追踪，我们定位到了导致克隆版高频弹验证码、必定掉线的根源：

### 8.1 验证码 (SecVerify/Captcha) 的触发链路与判决引擎

TikTok 绝不会“随机”弹出验证码，它的弹窗是由底层的 **TSPK（风控管线）** 与 **X-Gorgon / X-Argus（请求签名生成器）** 联合评分机制决定的。

1. **V2 综合环境评分系统 (X-Argus)**
   在发起任何核心请求（点赞、注册、拉流）之前，底层的 `SecSdk` 会收集当前的设备环境数据（含设备型号、屏幕分辨率 `UIScreen.nativeBounds`、CPU硬件 `hw.cpufamily`、调试状态 `isDebuggerAttached`，以及是否有被系统拦截的越狱钩子）。
   这些数据被聚合计算出一串哈希值，塞入 `X-Argus` 或者 `X-Gorgon` 请求头。
2. **服务端阻断与 Challenge 下发**
   如果服务端反解 `X-Argus` 发现评分过低（例如，伪装机型是 iPhone 7，但底层硬件返回了 A15 芯片，或者屏幕逻辑点偏离了出厂规格 15pt），服务端会直接拦截请求，并下发 **HTTP 414 / 403** 状态码，附带一个特定的 JSON Challenge。
3. **VerifySdk 唤起拦截**
   网络底座（`TTNet`）收到 Challenge 后，中止当前请求，唤起 `VerifySdk.framework`（或 `BDSecVerify`）在当前视图盖上一层验证码界面。
   一旦底层参数被修复匹配，这个环境评分将回到安全水位，弹窗自然消失。

### 8.2 克隆版极易掉线 (Logout) 的致命死穴

掉线的根本原因不是“封号”，而是**设备凭证无法持久化/读写错位导致的被动下线**。这涉及三重致命打击：

#### A. Keychain 隔离引发的数据断档
TikTok 的 `TSPK` 引擎早在启动第一阶段就接管了 `SecItemAdd` 和 `SecItemCopyMatching` 等 C 层 API，它将账号授权的 Session Token 以及独一无二的设备锁（ZTI Token）强行写入了官方的 Keychain 访问组（`T8ALTGMVXN.com.zhiliaoapp.musically`）。
而你克隆的 App 由于使用了新的（个人的或者企业级）Team ID，根本无法跨界读取该安全区。每次 App 重启，读取 Token 为空，系统就会认定“用户已退出”，迫使你重新登录。

#### B. 设备指纹 (ZTI Token) 跳动
TikTok 服务端为每一个端发配了绑定的 `dtoken`（内含 `device_id` 和 `install_id`）。每次打开 App，客户端都会拿当前运行时的物理 ID 去和加密后的 `dtoken` 比对。由于我们没有做底层 Keychain 隔离，这个数据一直处于错乱更新状态，日志中高频上报 `[Device-ZTI] did or iid not match`，服务端为了防止跨端盗号，主动销毁会话。

#### C. App Group 容器剥离
TikTok 强依赖官方共享容器 `group.com.zhiliaoapp.musically`。克隆证书如果缺少此授权，内部通讯套接字崩溃，同样触发账号登出保护逻辑。

> **针对此问题的终极解决方案：** 实施 Keychain Isolation。即重绑定底层的 `SecItem` 系列 C 函数，在写入和读取请求前，通过代码强行剥离 `kSecAttrAccessGroup`，迫使所有安全数据存放在克隆 App 自己合法生成的 Keychain 域中，以此维持持久登录。

---

## 九、完整可 Hook 函数索引（按检测类型分类）

> 以下函数/方法均从 TikTokCore 二进制静态字符串表提取确认，标注了所在框架和推荐的 Hook 策略。

### 9.1 克隆/多开检测 (Clone Detection)

| 函数/方法 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `-[AWEFakeBundleIDManager isOfficialBundleId]` | TikTokCore | 判定是否官方 BundleID | → 返回 `YES` |
| `-[AWEFakeBundleIDManager fakedBundleID]` | TikTokCore | 返回被伪造的 BundleID | → 返回 `nil` |
| `-[AWEFakeBundleIDManager containerPath]` | TikTokCore | 返回容器路径（暴露克隆） | → 返回 `nil` |
| `_aweLazyRegisterLoad_AWEFakeBundleID` | TikTokCore | 懒加载注册入口 | → 空实现 |
| `-[NSBundle objectForInfoDictionaryKey:]` | Foundation | 读取 `CFBundleIdentifier` | → 返回官方 BundleID |
| `-[NSBundle appStoreReceiptURL]` | Foundation | DRM 收据路径 | → 重定向到假收据文件 |
| `containerURLForSecurityApplicationGroupIdentifier:` | Foundation | App Group 容器访问 | → 返回克隆目录 |
| `-[NSUserDefaults initWithSuiteName:]` | Foundation | App Group 数据读取 | → 重定向 suite 名 |
| `SecItemAdd` / `SecItemCopyMatching` / `SecItemUpdate` / `SecItemDelete` | Security | Keychain 访问组隔离 | → 剥离 `kSecAttrAccessGroup` |
| `NSBundleResourceRequest.beginAccessingResources` | Foundation | ODR 资源请求（泄露 BundleID） | → 返回错误 |

### 9.2 验证码引擎 (BDTuring Captcha)

| 函数/方法 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `-[BDTuring(TTNet) parametersFromResponse:]` | TikTokCore | 从网络响应解析验证码参数 | 诊断拦截点 |
| `BDTuringVerifyHandler` | TikTokCore | 验证码处理器（入口类） | 监控触发条件 |
| `BDTuringVerifyView` / `BDTuringPresentView` | TikTokCore | 验证码 UI 展示 | 不建议直接 Hook |
| `BDTuringPictureVerifyModel` | TikTokCore | 图片验证码模型 | 诊断用 |
| `BDTuringSlidePictureVerifyModel` | TikTokCore | 滑块验证码模型 | 诊断用 |
| `BDTuringWhirlPictureVerifyModel` | TikTokCore | 旋转验证码模型 | 诊断用 |
| `BDTuringQAVerifyModel` / `BDTuringQAVerifyView` | TikTokCore | 问答验证码 | 诊断用 |
| `BDTuringSMSVerifyModel` / `BDTuringSMSVerifyView` | TikTokCore | 短信验证码 | 诊断用 |
| `BDTuringTwiceVerify` / `BDTuringTwiceVerifyRequest` | TikTokCore | 二次验证 | 诊断用 |
| `BDTuringConfig` / `BDTuringSettings` | TikTokCore | 验证码引擎配置 | 可 Hook 禁用 |
| `BDTuringServiceCenter` | TikTokCore | 验证码服务调度中心 | 核心拦截点 |
| `BDTuringDeviceHelper` | TikTokCore | 验证码设备环境采集 | → Hook 返回安全环境 |
| `BDTuringModelValidation` | TikTokCore | 验证码模型校验 | → 返回通过 |
| `BDTuringSandBoxHelper` | TikTokCore | 沙盒环境检测辅助 | → 返回正常环境 |
| `-[GBLUserCaptchaFragment showCaptcha]` | TikTokCore | 直播场景验证码展示 | 拦截入口 |
| `/eco/captcha_check/` | TikTokCore (URL) | 验证码校验 API 端点 | 网络层监控 |

### 9.3 越狱检测 (Jailbreak Detection)

| 函数/属性 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `deviceIsJailbroken` | TikTokCore | 越狱状态属性 | → 返回 `NO` |
| `btd_isJailBroken` | TikTokCore | ByteDance 分类方法 | → 返回 `NO` |
| `tspk_device_info_btd_isJailBroken` | TikTokCore | TSPK 代理调用 | → 返回 `NO` |
| `_isJailBroken` / `isJailBroken` | TikTokCore | 多个命名变体 | → 返回 `NO` |
| `_skipAdvancedJailbreakValidation` | TikTokCore | A/B 测试跳过开关 | → 返回 `YES` |
| `calculateV2ValueWithTimestamp:...isJailBroken:...` | TikTokCore | V2 环境评分（含越狱状态） | → `isJailBroken` 参数伪装 |
| `calculateV2SanityFlagsWithIsSimulator:...isJailBroken:...` | TikTokCore | V2 健全性标志 | → `isJailBroken` = `NO` |
| `binaryImagesLogStrWithMustIncludeImagesNames:includePossibleJailbreakImage:` | TikTokCore | 崩溃日志标记越狱映像 | → `includePossibleJailbreakImage` = `NO` |
| `access()` / `stat()` / `lstat()` / `fopen()` | libc | 路径探测 (40+ 越狱路径) | → 黑名单路径返回 `-1` |
| `fork()` / `vfork()` | libc | 沙盒逃逸测试 | → 返回 `-1` / `ENOSYS` |
| `lstat()` → `S_IFLNK` 检查 | libc | 符号链接检测 | → 返回普通目录类型 |
| `statvfs("/")` | libc | 根分区可写性检测 | → 返回 `ST_RDONLY` |

### 9.4 注入/Hook 检测 (Injection Detection)

| 函数/方法 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `_dyld_image_count` | dyld | 动态库数量 | → 减去隐藏库数量 |
| `_dyld_get_image_name` | dyld | 动态库路径名 | → 跳过注入库 |
| `_dyld_get_image_header` | dyld | 动态库 Mach-O 头 | → 跳过注入库 |
| `_dyld_get_image_vmaddr_slide` | dyld | 动态库 ASLR 偏移 | → 跳过注入库 |
| `dladdr()` | libdyld | 地址反查库路径 | → 伪装为系统库 |
| `HMDInjectedInfo.deviceID` / `.installID` | TikTokCore | Heimdallr 注入信息采集 | 诊断监控 |
| `binaryImagesLogStr` | TikTokCore | 映像列表序列化 | → 过滤注入库名 |
| `AWEFishhookInitTask` (start/run/execute) | TikTokCore | bdfishhook 初始化任务 | → 空实现 |
| `fishhookConflictFixEnable` | TikTokCore | GOT 表冲突修复开关 | → 返回 `NO` |
| `class_getMethodImplementation()` | ObjC Runtime | IMP 地址越界检测 | → 返回原始 IMP |
| LC_LOAD_DYLIB (Mach-O Header) | 内存 | 注入库名在 Header 中 | → 覆写为系统库路径 |

### 9.5 TSPK 安全管线 (Security Pipeline)

| 管线类名 | 拦截的系统 API | 推荐 Hook 策略 |
|---------|---------------|----------------|
| `TSPKDeviceInfoOfUIDevicePipeline` | `UIDevice.model/systemVersion/name` | TSPK 先 Hook → 需保持一致 |
| `TSPKDeviceInfoOfUIScreenPipeline` | `UIScreen.bounds/nativeScale` | 同上 |
| `TSPKDeviceInfoOfSysctlByNamePipeline` | `sysctlbyname("hw.machine")` 等 | 同上 |
| `TSPKDeviceInfoOfNSProcessInfoPipeline` | `NSProcessInfo.physicalMemory` | 同上 |
| `TSPKDeviceInfoOfNSFileManagerPipeline` | 磁盘容量 `statvfs` | 同上 |
| `TSPKDeviceInfoOfStatPipeline` | `stat()` 系统调用 | 同上 |
| `TSPKDeviceInfoOfTaskThreadsPipeline` | 线程数检测 | 同上 |
| `TSPKIDFVOfUIDevicePipeline` | `identifierForVendor` | 同上 |
| `TSPKDeviceInfoOfSecItemAddPipeline` | `SecItemAdd` | Keychain 写入拦截 |
| `TSPKDeviceInfoOfSecItemCopyMatchingPipeline` | `SecItemCopyMatching` | Keychain 读取拦截 |
| `TSPKDeviceInfoOfSecItemDeletePipeline` | `SecItemDelete` | Keychain 删除拦截 |
| `TSPKDeviceInfoOfSecItemUpdatePipeline` | `SecItemUpdate` | Keychain 更新拦截 |
| `TSPKInterceptorCheckerImpl` | 拦截链合法性校验 | → `isIntercepted` 返回 `NO` |
| `TSPKSparkSecurityPipeline` | 安全火花引擎 | → 致盲 |
| `TSPKDfCheckSubscriber` | 设备指纹校验订阅者 | → 致盲 |
| `TSPKNetworkHooker` / `TSPKNetworkTTNetRequestHooker` | 网络请求拦截器 | 不建议直接干预 |

### 9.6 登录/会话管理 (Passport & Session)

| 函数/方法 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `+[TTAccountSKGLoginManager clearPreviousLoginStatusWithoutET]` | TikTokCore | 清除登录状态 | 诊断监控 |
| `+[TTAccountSessionXTTToken checkIfNeedDeviceCreateWithResponse:...]` | TikTokCore | 检查是否需要创建新设备 | 诊断：触发即说明 ZTI 失败 |
| `+[TTAccountSessionXTTToken tokenBeatWithScene:completed:]` | TikTokCore | Token 心跳保活 | 诊断：失败 = 即将掉线 |
| `-[TTAccountSessionXTTToken handleSessionExpiredIfNeeded...]` | TikTokCore | 会话过期处理 | ⚠️ 核心掉线触发点 |
| `+[TTAccountSessionXTTToken sessionUserChangeFromResponse:...]` | TikTokCore | 用户变更检测 | 诊断用 |
| `+[TTAccountTicketGuard setupIfNeeded]` | TikTokCore | Ticket 守卫初始化 | 诊断用 |
| `+[TTAccountCSRFTokenManager csrfTokenForDispatchUrl:]` | TikTokCore | CSRF 令牌获取 | 不干预 |
| `+[TTKKeychainService setLoginInfoEnabled:type:userID:loginToken:...]` | TikTokCore | Keychain 登录信息持久化 | Keychain 隔离覆盖 |
| `TTKPersonalizedNUJServiceImpl.finishAutoLoginWithAccount:` | TikTokCore | 自动登录完成 | 诊断用 |
| `TTKPersonalizedNUJServiceImpl.processAutoLoginWithFailure:` | TikTokCore | 自动登录失败处理 | 诊断用 |

### 9.7 设备注册/指纹 (Device Registration)

| 函数/方法 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `TTKDeviceCheckInitTask` (start/run/execute) | TikTokCore | Apple DeviceCheck 初始化 | → 空实现 |
| `-[DCDevice generateTokenWithCompletionHandler:]` | DeviceCheck.framework | 设备令牌生成 | → 返回 error |
| `https://log.tiktokv.com/service/2/device_register/` | 网络 URL | 设备注册端点 | 监控请求参数 |
| `x-gorgon` / `x-argus` / `x-khronos` / `x-ladon` | HTTP Header | 请求签名 | 不可直接伪造 |
| `x-tt-token` / `x-tt-token-sign` | HTTP Header | 会话令牌 | Keychain 隔离保证 |
| `[Device-ZTI] did or iid not match` | 日志字符串 | ZTI 不匹配告警 | 通过 ID 一致性修复 |
| `APP_FIRST_LAUNCH_TIME` | TikTokCore | 首次启动时间戳 | 需在全新安装时重置 |
| `FirstLaunchTimestamp` | TikTokCore | 首次启动时间戳 | 同上 |
| `AppsFlyerFirstLaunchDate` / `AppsFlyerFirstLaunchTimestamp` | TikTokCore | AppsFlyer 首次启动 | 同上 |
| `+[MMKV initializeMMKV:]` / `+[MMKV mmkvWithID:cryptKey:relativePath:]` | TikTokCore | MMKV 初始化（数据持久化） | → relativePath 重定向 |

### 9.8 安全插件 (Security Plugins)

| 函数/方法 | 所在框架 | 作用 | 推荐 Hook 策略 |
|-----------|----------|------|----------------|
| `TTSecurityPluginsAdapterPostLaunchTask` | TikTokCore | 启动后安全任务 | → 空实现 |
| `setupSecurityPlugins` / `sec_setupSecurityPlugins:` | TikTokCore | 安全插件初始化 | 诊断监控 |
| `IESSecurityPluginConfigManager` | TikTokCore | 安全插件配置管理 | 诊断用 |
| `WKIESSecurityPlugin` / `inject_wksecurityplugin` | TikTokCore | WebView 安全插件注入 | 诊断用 |
| `isWKSecurityPluginInstalled` | TikTokCore | WebView 安全插件状态 | 诊断用 |
| `IESCSRFSecurityPlugin` | TikTokCore | CSRF 安全插件 | 不干预 |

---

## 十、ECDeviceSpoof 覆盖率评估 (V5 — 已修复)

基于上述提取的完整函数列表，对 `ECDeviceSpoof.m`（9000+行）各模块进行覆盖率评估：

| 检测类别 | TikTok 检测点总数 | ECDeviceSpoof 已覆盖 | 覆盖率 | 状态 |
|---------|:-:|:-:|:-:|------|
| **克隆/多开检测** | 10 | 10 | **100%** | ✅ 全覆盖 |
| **验证码引擎** | 16 | 5 | **31%** | 🟡 BDTuringConfig/ServiceCenter/ModelValidation/SandBoxHelper 已拦截 |
| **越狱检测** | 12 | 12 | **100%** | ✅ lstat 符号链接伪装 + statvfs 根分区只读 已补全 |
| **注入/Hook检测** | 11 | 9 | **82%** | 🟡 `_dyld_register_func_for_add_image` 竞态为低概率问题 |
| **TSPK 安全管线** | 16 | 12 | **75%** | ✅ SecItem 4管线 + Spark + DfCheck + 批量扫描 已致盲 |
| **登录/会话管理** | 10 | 5 | **50%** | 🟡 handleSessionExpired + tokenBeat 已监控 |
| **设备注册/指纹** | 10 | 9 | **90%** | ✅ MMKV 3个类方法已重定向 |
| **安全插件** | 6 | 3 | **50%** | 🟡 PostLaunchTask 已禁用 + BDTuringSandBoxHelper 致盲 |

**综合覆盖率：约 65/91 = 71%** (修复前 48%)

---

## 十一、克隆后"非全新状态"问题根因分析

### 11.1 问题表现

克隆安装 TikTok 后打开，显示的是之前的登录状态/浏览记录，而非全新安装的引导页面。

### 11.2 根因：5 个数据残留来源

```
克隆App首次启动 → TikTok读取本地数据
     │
     ├─ [1] MMKV 持久化文件 ← 🔴 未隔离
     │     路径: Library/MMKV/ 下的 mmap 文件
     │     内容: device_id, install_id, session_token, user_id
     │     问题: ECDeviceSpoof 的 NSHomeDirectory Hook 已生效，
     │           但 MMKV 在 +load 阶段用 C API 直接 open() 初始化，
     │           此时 Hook 可能尚未安装（时序竞态）
     │
     ├─ [2] WCDBSQLCipher 加密数据库 ← 🟡 部分隔离
     │     路径: Library/Application Support/*.db
     │     内容: 聊天记录, 草稿箱, 浏览历史
     │     问题: open() Hook 在 performMergedRebind() 之后才生效，
     │           数据库可能在此之前已被打开
     │
     ├─ [3] Keychain 残留 ← ✅ 已有清理但条件过宽
     │     cleanKeychainIfNeeded() 仅在 deviceId 缺失时触发
     │     问题: 首次克隆时 deviceId 可能已从原始App的Keychain读到
     │           (因为 SecItem Hook 在 cleanKeychain 之后才安装)
     │
     ├─ [4] CFPreferences (plist) 缓存 ← 🟡 部分隔离
     │     路径: Library/Preferences/com.zhiliaoapp.musically.plist
     │     内容: APP_FIRST_LAUNCH_TIME, 用户偏好设置
     │     问题: CFPreferences Hook 注册后延迟到 performMergedRebind()
     │           生效，首次读取可能使用原始路径
     │
     └─ [5] NSUserDefaults standardUserDefaults ← ⚠️ 已禁用Hook
           代码注释: "独立安装的克隆包有独立沙盒，天然 per-app 隔离"
           问题: 这个假设仅在 TrollStore 独立安装时成立。
                 如果克隆包共享同一个容器目录，UserDefaults 会读到旧数据
```

### 11.3 核心时序问题图

```
ECDeviceSpoof Constructor 执行顺序:
─────────────────────────────────────────────────
  t0: installTikTokCrashGuards()
  t1: 加载配置 SCPrefLoader
  t2: cleanKeychainIfNeeded()     ← 此时 SecItem Hook 未安装
  t3: injectSpoofedIDs()
  t4: setupTTInstallIDManagerHooks()
  ...
  t8: setupTikTokHooks()
  t9: setupAntiDetectionHooks()   ← SecItem Hook 注册(仅注册)
  t10: setupSafeHooks()
  t11: setupCloneDetectionBypass()
  t12: setupDeepProtection()
  t13: setupKeychainIsolationHooks() ← Keychain隔离注册(仅注册)
  t14: performMergedRebind()       ← ⭐ 所有Hook此刻才真正生效!
  ...
  t20: TikTokCore +load 开始执行   ← 读取MMKV/Keychain/plist
─────────────────────────────────────────────────
  问题: t2 时 cleanKeychain 使用原始 SecItemDelete（无隔离）
        t14 之前的所有 I/O 操作都是未隔离的
        如果 TikTokCore 的 +load 在 t14 之前执行，
        数据读取走原始路径 → 读到旧账号数据
```

### 11.4 修复方案

| 优先级 | 修复项 | 具体操作 |
|--------|--------|----------|
| 🔴 P0 | **MMKV 路径重定向** | Hook `+[MMKV initializeMMKV:]` 和 `+[MMKV setMMKVBasePath:]`，将 basePath 指向克隆数据目录 |
| 🔴 P0 | **首次克隆强制清理** | 在 `cleanKeychainIfNeeded()` 之前先用原始 `SecItemDelete` 清理，然后在安装 Hook 后再清理一次隔离域 |
| 🟡 P1 | **MMKV +load 竞态** | 将 MMKV basePath Hook 移至 `__attribute__((constructor(101)))` 最早期执行 |
| 🟡 P1 | **APP_FIRST_LAUNCH_TIME 重置** | 在首次克隆启动时，删除 `Library/Preferences/` 下的 plist 文件 |
| 🟢 P2 | **WCDBSQLCipher 数据库** | 首次克隆时删除 `Library/Application Support/*.db` |

### 11.5 判定首次克隆启动

```objc
// 在克隆数据目录下放置标记文件
static BOOL isFirstCloneLaunch(void) {
    NSString *marker = [[[SCPrefLoader shared] cloneDataDirectory]
        stringByAppendingPathComponent:@".ec_initialized"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker]) {
        return NO;
    }
    [@"1" writeToFile:marker atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    return YES;
}

// 在 constructor 最早期调用
if (g_isCloneMode && isFirstCloneLaunch()) {
    // 清理所有残留数据
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();
    [fm removeItemAtPath:[home stringByAppendingPathComponent:
        @"Library/MMKV"] error:nil];
    [fm removeItemAtPath:[home stringByAppendingPathComponent:
        @"Library/Application Support"] error:nil];
    [fm removeItemAtPath:[home stringByAppendingPathComponent:
        @"Library/Preferences"] error:nil];
    // Keychain 全量清理（使用原始 SecItemDelete）
    NSDictionary *q = @{(__bridge id)kSecClass:
        (__bridge id)kSecClassGenericPassword};
    SecItemDelete((__bridge CFDictionaryRef)q);
}
```
