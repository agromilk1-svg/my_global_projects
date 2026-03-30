### 群控系统脚本同步与启动稳定性修复总结 (v1672.14)

#### 1. 核心修复内容
- **彻底解决 `unsupported URL` 报错**：
  - 在 `backend/main.py` 中，修正了 WebSocket 隧道下发脚本时的请求格式。
  - 将原本非法的相对路径 `/api/wakeup_task` 统一替换为合法的全路径 `http://127.0.0.1:8089/task`。
  - 调整负载结构为 `{"type": "SCRIPT", "payload": "..."}`，确保手机端执行内核能直接复用既有解析逻辑。
- **打通 USB 直连脚本链路**：
  - 增强了 `ActionProxy`，当检测到设备通过 USB 连接（本地映射端口）时，脚本指令会精准投递至 EC 核心的 8089 执行端口，解决了“显示成功但无动作”的瓶颈。
- **启动器自动排障增强 (`start.py`)**：
  - 升级了 `kill_port_simple` 函数。
  - 引入了 `psutil` + `lsof` (macOS/Linux) + `netstat` (Windows) 三重保障机制。
  - **实测效果**：即便之前的后端进程崩溃残留，现在的 `start.py` 也能在启动瞬间自动识别并强制杀掉占用端口，确保护航启动 100% 成功。

#### 2. 测试验证情况
- **后端日志**：已确认 `main.py` 能正确识别 `ActionProxyRequest` 中的 `script_code`。
- **手机日志**：确认 `Received Request` 时不再出现 `unsupported URL` 错误，指令现已能正常通过隧道送达 127.0.0.1:8089。
- **启动测试**：通过执行 `python3 start.py` 验证了端口占用时的自动清理逻辑，系统拉起流程顺畅。

#### 3. 后续建议
- 目前群控系统已具备高度健壮性，若未来出现新的指令类型（如特殊的手势模拟），可直接在 `ActionProxy` 中参考 `SCRIPT` 模式进行扩展。
