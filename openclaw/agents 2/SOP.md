# 深海工作室标准操作流程 (SOP) & 执行准则 🦞
> 归档自上古 AGENTS.md。按需查阅。

## 自动化协作 SOP
1. **产品孵化**: 大圣提出想法 → **PM** 出需求文档 (PRD) → 大圣审批方案。
2. **架构先行**: 方案后 → **Architect** 出技术选型与系统图谱。
3. **Claude Code 核心执行 (Senior Engineer)**: 
   - 唤起 Claude Code (通过 `claude-delegate` 技能，使用 `--permission-mode bypassPermissions`)。
   - 注入 `./agents/senior-eng.md` 指令，Claude Code 在独立 sandbox 中直接执行修改。
4. **测试门禁**:
   - 调度 **QA Agent** 或亲自执行测试（`npm test`/`pytest`等）。
5. **成果交付**: 所有测试通过后，直接向大圣展示“产品结果”，而非中间代码。

## Claude Code 执行准则
- **原子化生效**: 一旦通过基础解析，直接应用到当前工作目录。
- **上下文透明**: 执行前必须加载 `MEMORY.md`。
- **自动归位**: 修改后输出简洁的 `changelog.md` 供 Producer 审计。
- **限制**: 修改限定在当前项目内，禁止越界访问 `~/.openclaw/workspace/` 核心配置文件。

## 角色唤起机制 (Role Spawning)
- 使用 `sessions_spawn` 挂载 `./agents/[role].md`。
- **混合模式**: 允许两名 Agent 并行协作。

## 记忆管理
- **短期**: 记录在 `memory/YYYY-MM-DD.md`。
- **维护**: session 结束前将决策追加进主 `MEMORY.md`。