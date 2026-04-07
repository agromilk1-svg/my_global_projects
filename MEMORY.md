# MEMORY.md - iOS 群控系统项目记忆 🧠
> 本文件由龙虾 🦞 维护，记录项目关键信息、决策与踩坑经验。

---

## 一、项目概览

- **项目性质**: iOS 设备批量自动化控制系统（群控）
- **主要用途**: TikTok 等 App 的批量账号操作、自动化脚本执行
- **根目录**: `/Users/hh/Desktop/my/`
- **开发机**: Mac mini (192.168.1.250)

---

## 二、四大核心组件

| 组件 | 路径 | 职责 | 编译产物 |
|------|------|------|----------|
| **ECMAIN** | `/Users/hh/Desktop/my/ECMAIN/` | 手机端控制中转 App（ObjC），解析执行 JS 脚本、桥接 WDA、管理 VPN/网络 | `ecmain.tar` |
| **ECWDA** | `/Users/hh/Desktop/my/WebDriverAgent.xcodeproj` | 定制版 WebDriverAgent，提供 HTTP/WS 控制接口、MJPEG 推流 | `ecwda.ipa` |
| **ECHelper** | `/Users/hh/Desktop/my/echelper/` | TrollStore 辅助工具（C语言），用于在越狱设备上安装 ECMAIN | `echelper` 二进制 |
| **Web控制后台** | `/Users/hh/Desktop/my/web_control_center/` | 网页管理后台，管理设备状态、下发脚本、查看截图推流 | 运行服务 |

---

## 三、编译脚本（关键）

```bash
# 编译 ECMAIN（手机端 App）
python3 /Users/hh/Desktop/my/tools/deploy/build_full.py
# → 产物: web_control_center/backend/updates/ecmain.tar

# 编译 ECWDA（定制 WDA）
python3 /Users/hh/Desktop/my/tools/wda/build_wda.py
# → 产物: web_control_center/backend/updates/ecwda.ipa

# 编译 ECHelper（TrollStore 辅助）
python3 /Users/hh/Desktop/my/tools/deploy/build_echelper.py
# → 产物: echelper/echelper
```

---

## 四、Web 控制后台技术栈

- **后端**: FastAPI + SQLite (WAL模式) + pymobiledevice3 + tidevice
- **前端**: Vue 3（单文件 App.vue，无 Router/Store，⚠️ 待拆分重构）
- **认证**: 自定义 HMAC-SHA256 Token（7天有效期）
- **数据库**: `ecmain_control.db`，主表 `ec_devices`，含内存心跳缓存
- **启动**: `python3 start.py` 或 `bash start_web.sh`
- **端口**: 后端 `:8088`，前端开发 `:5173`
- **静态服务**: FastAPI 直接 serve 构建后的 `backend/static/index.html`

---

## 五、通信架构

```
[Web控制后台 :8088]
        ↕ WebSocket隧道 / HTTP
[Mac ECMAIN管控服务 (pymobiledevice3/tidevice)]
        ↕ USB端口转发
[手机 ECMAIN :8089]  ←→  [手机 ECWDA :10088 (HTTP) / :10089 (MJPEG)]
```

**三种连接模式**:
- `ws` — WebSocket 隧道（USB数据线，穿透NAT）
- `lan` — 局域网直连（需手机与Mac同网段）
- `auto` — 自动选择

**MJPEG 推流**: 端口池从 11100 起，每个设备独立分配

---

## 六、关键技术细节

- **ECMAIN**: ObjC 原生 iOS App，内嵌 JSBridge 执行自动化脚本，支持 VPN（Hysteria协议）、静态IP配置
- **ECWDA**: 基于 Appium WebDriverAgent 深度定制，增加 MJPEG 原生推流（:10089）和二进制帧推送
- **ECHelper**: C 语言，使用 iOS 14.5 SDK，通过 TrollStore 的 `fastPathSign` 签名
- **签名方案**: TrollStore 越狱免签 或 开发者证书
- **设备识别陷阱**: ECMAIN 心跳上报的 UDID（`identifierForVendor`）≠ USB 硬件 UDID，两者格式不同，匹配需模糊处理

---

## 七、已知问题 & 风险

| 问题 | 严重级 | 说明 |
|------|--------|------|
| `TOKEN_SECRET` 硬编码 fallback | 🔴 高 | env var 缺失时用固定字符串，存在安全隐患 |
| App.vue 2000+ 行单文件 | 🟡 中 | 可维护性差，建议拆分为多组件 |
| WDA 重启稳定性 | 🟡 中 | WDA 偶发崩溃，有 watchdog 机制但未完全覆盖 |
| USB UDID 与心跳 UDID 不一致 | 🟡 中 | 设备匹配需要模糊处理，逻辑复杂 |
| `--reload` 导致 DeviceManager 双实例 | 🟢 低 | 生产环境已禁用，仅开发模式启用 |

---

## 八、重要目录索引

```
/Users/hh/Desktop/my/
├── ECMAIN/                    # 手机端 App 源码 (ObjC)
├── WebDriverAgent.xcodeproj   # ECWDA 项目文件
├── echelper/                  # ECHelper 源码 (C)
├── web_control_center/        # Web 控制后台
│   ├── backend/               # FastAPI 后端
│   │   ├── main.py            # 核心入口 (2228行)
│   │   ├── database.py        # SQLite 数据层 (1284行)
│   │   ├── device_manager.py  # USB设备管理 (483行)
│   │   ├── updates/           # 编译产物存放 (ecmain.tar, ecwda.ipa)
│   │   └── shared_files/      # 共享文件管理
│   └── frontend/
│       └── src/App.vue        # 前端入口 (单文件，待重构)
├── tools/
│   ├── deploy/
│   │   ├── build_full.py      # 编译 ECMAIN
│   │   └── build_echelper.py  # 编译 ECHelper
│   └── wda/
│       └── build_wda.py       # 编译 ECWDA
└── MEMORY.md                  # 本文件
```

---

## 九、文件变更记录（每次修改必填）

> 规则：龙虾 🦞 及所有子 Agent 每次修改文件后，必须在此追加记录。格式如下。

| 日期时间 | 修改文件 | 改动内容 | 操作人 |
|----------|----------|----------|--------|
| 2026-04-07 | `/Users/hh/Desktop/my/MEMORY.md` | 新建项目记忆文件 | 龙虾 🦞 |
| 2026-04-07 | `web_control_center/backend/main.py` | OTA任务保护补丁：给 `/api/ecmain/version` 和 `/api/ecwda/version` 两个 GET 接口添加 `udid` 可选参数，阻止主动拉取更新导致的打断 | 龙虾 🦞 |
