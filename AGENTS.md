# MergeMill Dev Team

## 安装 Skills

将所有 skills 安装到任意支持的编程 Agent 中（支持 40+ 种）：

```bash
npx skills add panzi-hub/MergeMill
```

支持 Claude Code、Cursor、Windsurf、Antigravity、Kiro CLI 等，详见 [skills.sh](https://skills.sh)。

## 可用 Skills

### MergeMill-dev
TDD 开发工作流，包含 git worktree 隔离、设计画布、测试优先开发、代码审查和 CI 验证。支持交互式和自主模式。

### MergeMill-review
PR 代码审查，包含检查清单验证、合并冲突解决、通过浏览器自动化进行 E2E 测试，以及自动合并。

### MergeMill-dispatcher
GitHub Issue 扫描器，按 cron 定时调度开发和审查 Agent。通过标签管理自主流水线生命周期。

### MergeMill-common
共享基础设施：工作流强制 hooks 和 Agent 可调用的工具脚本（标记 Issue 复选框、回复评论、批量解决讨论线索、以用户身份运行 gh）。MergeMill-dev 和 MergeMill-review 的依赖项。不可直接调用。

### create-issue
交互式 GitHub Issue 创建器，提供结构化模板、MergeMill 标签指导和工作区变更附件。支持功能请求和 Bug 报告。

## 工作流概要

1. 设计 -> 2. Worktree -> 3. 测试 -> 4. 实现 -> 5. 验证 -> 6. 审查 -> 7. PR -> 8. CI -> 9. E2E -> 10. 合并

## Hooks

工作流强制 hooks 打包在 `skills/MergeMill-common/hooks/` 中。`MergeMill-dev` 和 `MergeMill-review` 的 SKILL.md 前导元数据中的 hook 命令引用 `$CLAUDE_PROJECT_DIR/hooks/`，因此项目根目录需要有一个符号链接。

**模板用户**已自带 `hooks -> skills/MergeMill-common/hooks`。

**`npx skills add` 用户**需在安装后手动创建符号链接：

```bash
ln -sf .claude/skills/MergeMill-common/hooks hooks
ln -sf .claude/skills/MergeMill-dispatcher/scripts scripts
```

Hooks 由 Claude Code 和 Kiro CLI 支持。其他 IDE 需手动按工作流步骤操作。完整参考见 `hooks/README.md`。

## Scripts

流水线和工具脚本打包在 skill 目录内：
- 共享脚本：`skills/MergeMill-common/scripts/`
- 流水线脚本：`skills/MergeMill-dispatcher/scripts/`
- 审查脚本：`skills/MergeMill-review/scripts/`

全部可通过项目根目录的 `scripts/` 符号链接访问。
