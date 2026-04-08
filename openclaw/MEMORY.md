# MEMORY.md - AI 软件公司当前记忆核 🧠

## 核心技术栈
- **Frontend**: React / Next.js / Tailwind CSS / TypeScript
- **Backend**: Python (FastAPI) / Node.js (Koa) / Go (Gin)
- **Database**: PostgreSQL / Redis / Vector DB (Qdrant)
- **Infra**: Docker / Kubernetes / Terraform / GitHub Actions
*(特殊项目若带有 `PROJECT_CONTEXT.md`，以此为最高技术栈原则)*

## 脱坑纪要 (Vitals)
- **沙盒路径**: 调用 `sessions_spawn` 时必须继承主 Workspace (`inherit sandbox`)。
- **Git 并流**: 新功能强制切 `feature/xxx` 分支，由 Producer 审计 QA 后推入主线。

*备注：历史里程碑及技术决策书(ADR) 已冷藏备份于 `memory/archive.md`。*