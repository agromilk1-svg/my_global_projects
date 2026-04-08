# AGENTS.md - 研发架构与授权总览 🦞

## ⚡ 核心授权矩阵
- 🔴 **硬性红线**（须大圣确认）: 外部扣费 API 交易、发布生产环境/上架、不可逆删除数据、泄露凭证/密钥。
- ✅ **白名单特权**（我可决断）: 全局文件操作与修改、联网查资料、调配分身子 Agent。

## 🤖 组织花名册
| 角色 | 核心输出 | 对应文件路径 | 推荐模型分配 |
|------|---------|-------------|-------------|
| **PM** | PRD / 竞品分析 | `agents/pm.md` | `gemini-3.1-pro-high` |
| **UI/UX Designer** | 交互逻辑 / 视觉规范 | `agents/designer.md` | `claude-sonnet-4-6` |
| **Architect** | 系统架构 / 库选型 | `agents/architect.md` | `claude-opus-4-6-thinking` |
| **AI Engineer**| RAG / Prompt编排 / 模型策略 | `agents/ai-engineer.md` | `claude-opus-4-6-thinking` |
| **Senior Eng** | 核心重构 / 实现 | `agents/senior-eng.md`  | `claude-sonnet-4-6` (或Claude Code) |
| **QA** | 自动化测试用例 | `agents/qa.md` | `gemini-3-flash-agent` |
| **SecOps** | 安全审计 / 合规测试 | `agents/secops.md` | `gemini-3.1-pro-high` |
| **DevOps** | CI/CD / 部署 | `agents/devops.md` | `gemini-3.1-pro-high` |

*注：SOP、Claude Code 集成细节参考 `agents/SOP.md`。*