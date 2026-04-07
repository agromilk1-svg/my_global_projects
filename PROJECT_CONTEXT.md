# Project Context: My Web Control Center (iOS Automation)

## 项目定位
- 核心业务：基于 Web 的 iOS 设备中央控制系统。
- 技术闭环：FastAPI (Backend) + Vue 3 (Frontend) + `pymobiledevice3` (Core Lib)。

## 技术栈细节
- **前端 (frontend)**: 
  - Framework: Vue 3, Vite, TypeScript
  - Styling: Tailwind CSS
- **后端 (backend)**:
  - Framework: FastAPI, Uvicorn
  - Storage: SQLite (`ecmain_control.db`)
  - iOS Logic: `pymobiledevice3`, `tidevice`, `pyimg4`
- **基础设施**: 移动端脚本自动生成 (`script_generator.py`)，WDA 自动部署与监控

## 当前进驻团队 🦞
- **Producer**: 龙虾 (Project Manager)
- **Engine**: Claude Code (Senior Engineer)
- **Roles**: PM, Architect, QA, DevOps (Standby)

## 待办事项 (TODOS)
1. [ ] **代码审计**: 审查 `backend/main.py` 的路由结构与异常处理。
2. [ ] **依赖校验**: 确认 `requirements.txt` 与 `venv` 中的实际库是否同步。
3. [ ] **前端联调**: 确认 Vue 3 前端是否能正确连接 FastAPI 后端接口。
4. [ ] **WDA 稳定性**: 审查 `wda_run.log` 系统日志，定位频繁重启的原因。

## 关键记忆记录
- [2026-04-07]: 龙虾正式接手该项目，建立上下文档案。
- [2026-04-07]: 确认项目具备 iOS 固件分析及应用签名能力（超然签板块）。
