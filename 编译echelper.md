# ECHelper 编译指南 (防崩溃修复版)

本文档详细记录了 ECHelper (PersistenceHelper) 的正确编译流程。
该版本已修复此前导致 iOS 重启 (Boot Loop) 和黑屏 (Black Screen) 的所有已知问题。

## ⚠️ 关键配置检查
在开始编译前，请务必确认源码和配置符合以下要求，否则会导致设备崩溃：

1.  **禁止链接危险库**:
    *   `Makefile` 或编译脚本中**绝对不能**链接 `RunningBoardServices` (导致 Crash)。
    *   `Makefile` 或编译脚本中**绝对不能**链接 `MobileCoreServices` (导致不稳定)。
2.  **必须包含 UI 修复**:
    *   `main.m` 必须包含 `sceneDelegateFix` 函数并在入口调用，否则 Tips 打开会黑屏。
3.  **Root 权限宏**:
    *   编译时必须定义 `EMBEDDED_ROOT_HELPER=1`。
4.  **签名工具**:
    *   必须使用 `fastPathSign` 进行 CoreTrust Bypass 签名，普通 `ldid` 或 `codesign` 无效。

---

## 方式一：自动化编译 (推荐)

使用项目根目录下的 `build_echelper.py` 脚本，它已经过更新，内置了上述所有正确配置。

### 步骤
1.  **准备环境**:
    确保 `external_sources/theos/sdks/iPhoneOS14.5.sdk` 存在。
    确保 `external_sources/TrollStore/Exploits/fastPathSign/fastPathSign` 存在。

2.  **运行脚本**:
    在终端根目录下执行：
    ```bash
    python3 build_echelper.py
    ```

3.  **产物**:
    *   编译成功后，二进制文件会自动归档到：
        `build_antigravity/IPA/echelper`
    *   脚本会自动验证签名有效性。

4.  **安装**:
    直接运行安装脚本即可（它会自动使用上述路径的文件）：
    ```bash
    python3 install_echelper.py
    ```

---

## 方式二：手动编译 (Theos/Make)

如果您是开发者或需要调试 Make 流程，请严格按照以下步骤操作。

### 1. 检查 Makefile
位置: `echelper/Makefile`
确保 `ECHelper_PRIVATE_FRAMEWORKS` 此时**不包含** `RunningBoardServices`。
确保 `ECHelper_FRAMEWORKS` 此时**不包含** `MobileCoreServices`。

### 2. 执行编译命令
进入 `echelper` 目录并执行 Clean Build：

```bash
cd echelper
make clean
make FINALPACKAGE=1 EMBEDDED_ROOT_HELPER=1 ARCHS=arm64
```
*   `FINALPACKAGE=1`: 去除调试符号，优化体积。
*   `EMBEDDED_ROOT_HELPER=1`: 激活 Root Helper 入口逻辑。
*   `ARCHS=arm64`: 仅编译 64 位。

### 3. 执行特定签名
Theos 默认签名无法满足 CoreTrust 要求，必须手动重签。

在 `echelper` 目录下执行：
```bash
../external_sources/TrollStore/Exploits/fastPathSign/fastPathSign \
    --entitlements entitlements.plist \
    .theos/obj/arm64/ECHelper.app/ECHelper
```

### 4. 验证与归档
建议运行 `otool` 检查依赖，确保没有混入危险库：
```bash
otool -L .theos/obj/arm64/ECHelper.app/ECHelper
```
(确认列表中没有 `RunningBoardServices`)

最后将文件移动到标准产物目录：
```bash
cp .theos/obj/arm64/ECHelper.app/ECHelper ../build_antigravity/IPA/echelper
```

---

## 常见问题排查

### 安装后无限重启 (Boot Loop)
*   **原因**: 很有可能是使用了硬链接且目标文件变为 0 字节，或者链接了 `RunningBoardServices`。
*   **解决**: 确保使用 `install_echelper.py` 或正确配置了 `mode=755` 的安装脚本，并检查二进制依赖。

### 打开 Tips 黑屏
*   **原因**: `main.m` 缺少 `sceneDelegateFix`，无法通过 Info.plist 的 Scene 检查。
*   **解决**: 恢复 `main.m` 中的修复代码并重新编译。

### 安装脚本报错 "command not found"
*   **原因**: `pymobiledevice3` 版本不兼容或未安装。
*   **解决**: 确保 `pymobiledevice3` 已安装，且脚本中移除了对 `Command` 类的依赖。