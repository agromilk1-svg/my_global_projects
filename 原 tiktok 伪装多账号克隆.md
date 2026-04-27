# 原版 TikTok 伪装多账号克隆方案 (方案 C)

## 核心思路

**不修改 Bundle ID**，使用原版 TikTok 通过 TrollStore 安装并注入 dylib，在 dylib 内部实现**多 Profile 数据隔离 + 设备伪装**，达到"一个 App 多个身份"的效果。

**与方案 B（修改 Bundle ID 产生多个独立 App）的本质区别**：
- 方案 B：桌面多图标、多进程、但沙盒异常（PluginKitPlugin 容器）
- 方案 C：桌面一个图标、单进程、沙盒完全正常、**TikTok 无法区分与正版的差异**

---

## 架构设计

```
┌─────────────────────────────────────────────────┐
│              TikTok.app (原版 Bundle ID)          │
│              com.ss.iphone.ugc.Ame               │
│                                                   │
│  ┌─────────────────────────────────────────────┐  │
│  │           ECDeviceSpoof.dylib (注入)          │  │
│  │                                               │  │
│  │  ┌───────────┐  ┌───────────┐  ┌──────────┐  │  │
│  │  │ Profile   │  │ 数据隔离   │  │ 设备伪装  │  │  │
│  │  │ Manager   │  │ Engine    │  │ Engine   │  │  │
│  │  └─────┬─────┘  └─────┬─────┘  └────┬─────┘  │  │
│  │        │              │              │         │  │
│  │  ┌─────▼──────────────▼──────────────▼──────┐  │  │
│  │  │         统一 Hook 层 (fishhook)           │  │  │
│  │  │  NSHomeDirectory / Keychain / IDFV /     │  │  │
│  │  │  NSUserDefaults / CFPreferences / ...    │  │  │
│  │  └──────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────┘  │
│                                                   │
│  ┌─────────────────────────────────────────────┐  │
│  │              数据目录 (沙盒内)                 │  │
│  │                                               │  │
│  │  Documents/.ecprofiles/                       │  │
│  │  ├── active_profile        (当前 Profile ID)  │  │
│  │  ├── profiles.plist        (Profile 列表)     │  │
│  │  ├── profile_0/  (主号)                        │  │
│  │  │   ├── Home/             (虚拟 HOME)        │  │
│  │  │   │   ├── Documents/                       │  │
│  │  │   │   ├── Library/                         │  │
│  │  │   │   └── tmp/                             │  │
│  │  │   └── device.plist      (伪装配置)          │  │
│  │  ├── profile_1/  (小号 1)                      │  │
│  │  └── profile_2/  (小号 2)                      │  │
│  └─────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## 模块 1: Profile Manager (账号管理器)

### 1.1 Profile 存储结构

```
Documents/.ecprofiles/
├── profiles.plist          # Profile 元数据列表
├── active_profile          # 当前激活的 Profile ID (纯文本文件)
├── profile_0/              # 每个 Profile 独立的完整沙盒镜像
│   ├── Home/               # 该 Profile 的虚拟 HOME 目录
│   │   ├── Documents/
│   │   ├── Library/
│   │   │   ├── Preferences/
│   │   │   ├── Caches/
│   │   │   └── Application Support/
│   │   └── tmp/
│   └── device.plist        # 该 Profile 的设备伪装配置
└── profile_1/
    └── ...
```

### 1.2 profiles.plist 格式

```xml
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>profiles</key>
  <array>
    <dict>
      <key>id</key><string>0</string>
      <key>name</key><string>主号</string>
      <key>created</key><date>2026-04-26T00:00:00Z</date>
      <key>lastUsed</key><date>2026-04-26T12:00:00Z</date>
    </dict>
    <dict>
      <key>id</key><string>1</string>
      <key>name</key><string>小号 1</string>
      <key>created</key><date>2026-04-26T01:00:00Z</date>
    </dict>
  </array>
</dict>
</plist>
```

### 1.3 切换机制

切换 Profile 时需要**重启 App**（因为 TikTok 在启动时初始化大量单例和缓存）：

```
用户选择切换 → 写入 active_profile 文件 → exit(0) →
系统自动重启 App → dylib constructor 读取 active_profile →
激活对应 Profile 的数据目录和设备伪装配置
```

### 1.4 切换入口 UI

在 TikTok 的"我"页面注入一个**悬浮球**，点击弹出 Profile 列表：
- 使用独立 `UIWindow` 层级，不影响 TikTok 原有 UI
- 显示当前 Profile 名称 + 列表
- "新建 Profile" / "删除 Profile" / "重命名"
- 切换时弹出确认对话框

---

## 模块 2: 数据隔离引擎

### 2.1 需要 Hook 的 API 列表

| 层级 | API | 作用 |
|---|---|---|
| **文件系统** | `NSHomeDirectory()` | 重定向 HOME 到 Profile 目录 |
| | `NSSearchPathForDirectoriesInDomains()` | 重定向 Documents/Library/Caches |
| | `getenv("HOME")` | C 层面的 HOME 路径 |
| | `open()` / `stat()` / `access()` | 拦截越狱路径 + 监控数据泄漏 |
| **偏好设置** | `NSUserDefaults` (objectForKey/setObject) | 按 Profile 隔离用户偏好 |
| | `NSUserDefaults initWithSuiteName:` | 重定向 App Group |
| | `CFPreferencesCopy*` / `CFPreferencesSet*` | 底层偏好读写拦截 |
| **钥匙串** | `SecItemAdd` / `SecItemCopyMatching` | 按 Profile 隔离 Keychain |
| | `SecItemUpdate` / `SecItemDelete` | 防止跨 Profile 数据泄漏 |
| **设备标识** | `UIDevice.identifierForVendor` | 每个 Profile 独立 IDFV |
| | `ASIdentifierManager` | 每个 Profile 独立 IDFA |

### 2.2 核心重定向逻辑

```objc
// 全局变量
static NSString *g_realHome = nil;          // 真实 HOME
static NSString *g_activeProfileDir = nil;  // 当前 Profile 的虚拟 HOME
static NSString *g_profileBaseDir = nil;    // .ecprofiles 根目录

// 在 constructor 中初始化
void loadActiveProfile() {
    g_realHome = @(getenv("HOME"));
    g_profileBaseDir = [g_realHome stringByAppendingPathComponent:@"Documents/.ecprofiles"];

    NSString *activeFile = [g_profileBaseDir stringByAppendingPathComponent:@"active_profile"];
    NSString *profileId = [NSString stringWithContentsOfFile:activeFile
                                                   encoding:NSUTF8StringEncoding
                                                      error:nil];
    if (!profileId || profileId.length == 0) profileId = @"0";

    g_activeProfileDir = [g_profileBaseDir stringByAppendingFormat:@"/profile_%@/Home", profileId];

    // 确保目录结构存在
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[g_activeProfileDir stringByAppendingPathComponent:@"Documents"]
        withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[g_activeProfileDir stringByAppendingPathComponent:@"Library/Preferences"]
        withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[g_activeProfileDir stringByAppendingPathComponent:@"tmp"]
        withIntermediateDirectories:YES attributes:nil error:nil];
}

// Hook NSHomeDirectory
NSString* hooked_NSHomeDirectory(void) {
    if (g_activeProfileDir) return g_activeProfileDir;
    return original_NSHomeDirectory();
}
```

### 2.3 Keychain 隔离

每个 Profile 的 Keychain 条目通过**前缀化 Service/Account** 实现隔离：

```objc
// 修改 SecItemAdd/SecItemCopyMatching 的 query
// 在 kSecAttrService 前加上 "profile_{id}_" 前缀
// 例如: "com.bytedance.device.id" → "profile_1_com.bytedance.device.id"
```

这与当前 `clone_XX_` 前缀方案完全一致，只是前缀从 `clone_XX` 变为 `profile_XX`。

### 2.4 关键区别：不需要 Bundle ID 伪装

方案 C 中 Bundle ID 始终是 `com.ss.iphone.ugc.Ame`，因此：
- **移除** `CFBundleIdentifier` / `infoDictionary` 的 Hook
- **移除** `CFBundleGetValueForInfoDictionaryKey` 的 Hook
- **移除** `NSBundle objectForInfoDictionaryKey` 的 Hook

这直接消除了沙盒容器类型不匹配的根因。

---

## 模块 3: 设备伪装引擎

### 3.1 每 Profile 独立的伪装维度

| 维度 | API Hook 点 | 说明 |
|---|---|---|
| IDFV | `UIDevice.identifierForVendor` | 每个 Profile 生成唯一 UUID |
| IDFA | `ASIdentifierManager` | 每个 Profile 生成唯一 UUID |
| 设备型号 | `sysctl(hw.machine)` / `UIDevice.model` | 可选：不同 Profile 模拟不同机型 |
| 系统版本 | `UIDevice.systemVersion` | 可选 |
| 语言/地区 | `NSLocale` / `AppleLanguages` | 每个 Profile 独立配置 |
| 设备名称 | `UIDevice.name` | 每个 Profile 不同 |
| OpenUDID | 自定义存储 | 每个 Profile 独立 |
| Install ID | ByteDance SDK 内部 | 通过 Keychain 隔离自动实现 |

### 3.2 device.plist 配置文件

每个 Profile 创建时**自动随机生成**：

```xml
<dict>
  <key>vendorId</key>
  <string>A1B2C3D4-E5F6-7890-ABCD-EF1234567890</string>
  <key>openudid</key>
  <string>abcdef1234567890abcdef1234567890abcdef12</string>
  <key>machineModel</key>
  <string>iPhone12,1</string>
  <key>systemVersion</key>
  <string>16.6</string>
  <key>preferredLanguage</key>
  <string>en-US</string>
  <key>localeIdentifier</key>
  <string>en_US</string>
  <key>countryCode</key>
  <string>US</string>
</dict>
```

---

## 与现有代码的复用关系

方案 C **复用现有 ECDeviceSpoof.m 中 90% 的代码**：

| 现有逻辑 | 方案 C 改动 |
|---|---|
| Bundle ID 后缀判断克隆 (Ame90) | 改为 `active_profile` 文件判断 Profile |
| `g_FastCloneId` / `g_isCloneMode` | 改为 `g_activeProfileId` / `g_isProfileMode` |
| `cloneDataDirectory` 返回 `.ecdata/session_XX` | 返回 `.ecprofiles/profile_XX/Home` |
| 从外部 plist 读取伪装配置 | 从 Profile 目录内 `device.plist` 读取 |
| 需要 Bundle ID 伪装 Hook | **移除**——原版 Bundle ID 无需伪装 |
| 需要处理 PluginKitPlugin 容器 | **不需要**——原版容器天然正确 |
| cfprefsd/IOKit 权限修复 | **不需要**——原版沙盒权限完整 |

---

## 优势对比

| 维度 | 方案 B（改 Bundle ID） | 方案 C（原版注入） |
|---|---|---|
| 沙盒类型 | ❌ PluginKitPlugin | ✅ Application |
| cfprefsd 权限 | ❌ 1116 次 deny | ✅ 0 次 deny |
| IOKit 权限 | ❌ 342 次 deny | ✅ 正常访问 |
| AppleLanguages | ❌ 框架内部泄漏 | ✅ 无泄漏 |
| 风控检测风险 | 🔴 高 | 🟢 极低 |
| 桌面图标 | 多个独立图标 | 一个图标 |
| 同时运行 | ✅ 可以 | ❌ 需切换重启 |
| 代码复杂度 | 高 | 低（复用现有逻辑） |

---

## 实施步骤

### 第一阶段：Profile Manager 基础

1. **新建 `ECProfileManager.h/m`**
   - Profile CRUD（创建/读取/更新/删除）
   - `active_profile` 文件读写
   - 首次启动时自动创建 `profile_0`
   - `device.plist` 自动生成（随机指纹）

2. **修改 `SCPrefLoader.m`**
   - `detectCloneId` 改为 `detectActiveProfile`
   - `cloneDataDirectory` 改为 `profileDataDirectory`
   - 从 `profile_XX/device.plist` 加载配置

### 第二阶段：数据隔离适配

3. **修改 `ECDeviceSpoof.m` constructor**
   - 移除 Bundle ID 后缀解析逻辑
   - 改为读取 `active_profile` 文件
   - 移除 `CFBundleIdentifier` Hook

4. **修改数据隔离 Hook**
   - `hooked_NSHomeDirectory` 指向 `profile_XX/Home`
   - Keychain 前缀从 `clone_XX_` 改为 `profile_XX_`
   - `NSUserDefaults initWithSuiteName:` 适配 Profile 模式

### 第三阶段：切换 UI

5. **新建 `ECProfileSwitcherView.h/m`**
   - 悬浮球 UI
   - Profile 列表（名称 + 最后使用时间）
   - "新建 Profile" / "删除" / "重命名"
   - 切换确认 → 写入 `active_profile` → `exit(0)`

6. **注入 UI 到 TikTok**
   - Swizzle `AppDelegate.didFinishLaunching`
   - 在主 Window 上添加悬浮球

### 第四阶段：安装流程

7. **修改 ECMAIN 安装逻辑**
   - 安装原版 TikTok IPA（不修改 Bundle ID）
   - 仅注入 dylib 到 Frameworks 目录
   - 保留原版签名

### 第五阶段：清洗与验证

8. **Profile 切换时的数据清洗**
   - 切换时清空 `NSUserDefaults` 内存缓存
   - 通过 exit + restart 重置所有单例

---

## 风险与限制

| 风险 | 缓解措施 |
|---|---|
| 切换需要重启 App | UI 上提示"切换账号需要重新打开" |
| 不能同时在线两个号 | 架构限制，无法规避 |
| TikTok 更新可能改变类名 | 使用运行时动态查找 |
| 原版 TikTok 更新会覆盖注入 | 锁定版本或禁用自动更新 |

---

## 文件清单

```
ECMAIN/Dylib/
├── ECDeviceSpoof.m          # [修改] 移除 Bundle ID 伪装，适配 Profile 模式
├── SCPrefLoader.m           # [修改] Profile 目录读取
├── ECProfileManager.h       # [新增] Profile 生命周期管理
├── ECProfileManager.m       # [新增]
├── ECProfileSwitcherView.h  # [新增] 切换 UI
└── ECProfileSwitcherView.m  # [新增]
```



五个实施阶段
Profile Manager — 管理多 Profile 的 CRUD 和 device.plist 自动生成
数据隔离适配 — 将现有 cloneDataDirectory 机制改为 profileDataDirectory
切换 UI — 悬浮球 + Profile 列表 + exit(0) 重启切换
安装流程 — 原版 IPA + dylib 注入（不改 Bundle ID）
清洗验证 — 切换时通过 exit/restart 彻底重置单例



----------------------------------------------------------------------------------------
# 方案 C 实施计划：原版 TikTok 多 Profile 注入

## 目标

在不修改 Bundle ID 的前提下，向原版 TikTok 注入 dylib，实现多账号 Profile 切换和设备伪装。全部使用**新建文件**，不修改现有方案 B 代码。

---

## 文件结构

```
ECMAIN/Dylib/
├── ECDeviceSpoof.m              # [保留] 方案 B 代码
├── SCPrefLoader.m               # [保留] 方案 B 代码
├── fishhook.c / fishhook.h      # [共用] fishhook 库
├── Makefile                     # [保留] 方案 B 编译
│
├── ECProfileSpoof.m             # [新增] 方案 C 核心 - Profile 数据隔离 + 设备伪装
├── ECProfileSpoof.h             # [新增] 方案 C 头文件
├── ECProfileManager.m           # [新增] Profile 管理器 - CRUD/切换
├── ECProfileManager.h           # [新增] Profile 管理器头文件
├── ECProfileSwitcherUI.m        # [新增] 悬浮球切换 UI
├── ECProfileSwitcherUI.h        # [新增] 切换 UI 头文件
├── Makefile.profilec            # [新增] 方案 C 单独编译脚本
│
└── libECProfileSpoof.dylib      # [产物] 方案 C 编译产物

ECMAIN/ECMAIN/
├── Core/ECAppInjector.m         # [修改] 增加方案 C 注入选项
├── UI/ECAppListViewController.m # [修改] 注入按钮增加选择弹窗
```

---

## 模块分解

### 模块 1: ECProfileManager（Profile 生命周期管理）

**职责**：管理多 Profile 的创建/切换/删除/配置。

**关键方法**：
```objc
@interface ECProfileManager : NSObject
+ (instancetype)shared;
- (NSString *)activeProfileId;              // 获取当前激活的 Profile ID
- (NSString *)profileHomeDirectory;          // 当前 Profile 的虚拟 HOME
- (void)switchToProfile:(NSString *)profileId; // 切换（写文件 + exit）
- (NSString *)createNewProfile;              // 创建新 Profile（随机指纹）
- (void)deleteProfile:(NSString *)profileId; // 删除
- (NSArray *)allProfiles;                    // 所有 Profile 列表
- (NSDictionary *)deviceConfigForProfile:(NSString *)profileId; // 设备伪装配置
@end
```

**数据存储**：
```
{真实HOME}/Documents/.ecprofiles/
├── active_profile          # 纯文本，当前 Profile ID
├── profiles.plist          # Profile 元数据列表
├── profile_0/Home/         # 虚拟 HOME
└── profile_0/device.plist  # 设备伪装配置
```

### 模块 2: ECProfileSpoof（核心 Hook 引擎）

**职责**：数据隔离 + 设备伪装。从 ECDeviceSpoof.m 中**精简提取**必要的 Hook，去掉所有 Bundle ID 相关的伪装。

**需要的 Hook**：
| Hook 类别 | 函数 | 用途 |
|---|---|---|
| 文件系统 | `NSHomeDirectory` | 重定向到 Profile 目录 |
| | `NSSearchPathForDirectoriesInDomains` | 重定向标准路径 |
| | `getenv("HOME"/"TMPDIR")` | C 层路径重定向 |
| | `open/stat/access` | 越狱路径拦截 + 环境探针拦截 |
| 偏好设置 | `NSUserDefaults` | 按 Profile 隔离 |
| | `CFPreferencesSetValue` | 覆写 AppleLanguages |
| 钥匙串 | `SecItemAdd/CopyMatching/Update/Delete` | Keychain 隔离 |
| 设备标识 | `UIDevice.identifierForVendor` | 每 Profile 独立 IDFV |
| | `ASIdentifierManager` | 每 Profile 独立 IDFA |
| | `sysctl/sysctlbyname` | 硬件伪装 |
| | `UIDevice properties` | 设备名称/型号/版本 |
| 安全 | `sanitizeMainBinaryHeader` | 抹除 dylib 注入痕迹 |
| | `is_jailbreak_path` | 越狱路径伪装 |
| | `/hmd_tmp_file` 拦截 | 环境探针 |
| | `kern.proc.all` 拦截 | 进程枚举保护 |

**不需要的 Hook**（方案 B 特有，方案 C 移除）：
- ❌ `CFBundleIdentifier` / `infoDictionary` 伪装
- ❌ `CFBundleGetValueForInfoDictionaryKey` 伪装
- ❌ `CFBundleDisplayName` / `CFBundleName` 去克隆号
- ❌ `container-required` entitlement 修补
- ❌ AppGroup / Suite Name 伪装

### 模块 3: ECProfileSwitcherUI（切换界面）

**职责**：在 TikTok 内提供 Profile 切换入口。

**实现方式**：
- 独立 `UIWindow`（keyWindow 之上），避免影响 TikTok 原生 UI
- 悬浮球（可拖动），点击展开 Profile 列表
- 三指长按手势作为备用触发方式
- 切换时：写入 `active_profile` → 弹出提示 → `exit(0)`

---

## 构建系统

### [NEW] Makefile.profilec

新建独立编译脚本，产物为 `libECProfileSpoof.dylib`：

```makefile
SOURCES = ECProfileSpoof.m ECProfileManager.m ECProfileSwitcherUI.m fishhook.c
DYLIB_NAME = libECProfileSpoof.dylib
```

### 注入逻辑修改

修改 `ECAppInjector.m`，增加方案 C 的 dylib 路径：

```objc
// 方案 B
static NSString *const kSpoofDylibName = @"libswiftCompatibilityPacks.dylib";
// 方案 C
static NSString *const kProfileDylibName = @"libECProfileSpoof.dylib";
```

修改 `ECAppListViewController.m` 的注入按钮，弹出选择框：
- "💉 注入伪装 dylib (方案 B - 克隆多实例)"
- "💉 注入伪装 dylib (方案 C - 原版多 Profile)"

---

## 实施步骤

### 第一步：创建 ECProfileManager.h/m
- Profile 元数据 CRUD
- active_profile 读写
- device.plist 自动生成（随机 IDFV/IDFA/OpenUDID）
- 目录结构自动创建

### 第二步：创建 ECProfileSpoof.m
- 从 ECDeviceSpoof.m 中提取必要的 Hook 逻辑
- constructor 中初始化 ProfileManager → 确定 Profile → 设置 Hook
- 所有文件路径 Hook 指向 Profile 的虚拟 HOME
- Keychain 隔离使用 `profile_{id}_` 前缀
- 设备伪装从 device.plist 读取

### 第三步：创建 ECProfileSwitcherUI.m
- 悬浮球 UIWindow
- Profile 列表 (UITableView in UIViewController)
- 新建/删除/切换操作

### 第四步：创建 Makefile.profilec
- 编译方案 C 的 dylib

### 第五步：修改注入入口
- ECAppInjector.m 增加方案 C 注入方法
- ECAppListViewController.m 注入按钮增加选择

## 验证计划

1. 编译 `libECProfileSpoof.dylib`
2. 在 ECMAIN 中选择原版 TikTok → 注入伪装 dylib (方案 C)
3. 启动 TikTok → 检查悬浮球出现
4. 使用 Profile 0 登录账号 A
5. 切换到 Profile 1 → 重启后登录账号 B
6. 切回 Profile 0 → 确认账号 A 数据完整
7. 对比日志：cfprefsd/IOKit deny 数量应为 0
