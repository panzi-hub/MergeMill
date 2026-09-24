---
name: MergeMill-common
description: >
  Use when setting up, troubleshooting, or modifying the shared hooks and
  agent-callable utility scripts that enforce the MergeMill dev/review
  workflow. Triggers on phrases like "push to main is blocked",
  "block-commit-outside-worktree hook failing", "configure hooks after
  npx skills add", "what does check-pr-review.sh do", "set up workflow
  hook symlinks", or when editing files under `skills/MergeMill-common/`.
  Provides the hooks the MergeMill-dev / MergeMill-review skills depend
  on, plus utility scripts (gh-as-user.sh, mark-issue-checkbox.sh,
  reply-to-comments.sh, resolve-threads.sh).
---

# 自主公共基础设施

`MergeMill-dev`、`MergeMill-review` 和 `MergeMill-dispatcher` 使用的共享工作流强制 hooks 和 Agent 可调用工具脚本。其他 MergeMill-* skills 引用此处的脚本和 hooks——当那些引用路径断裂时，通常应在此 skill 中查找。

## `npx skills add` 用户的设置

`npx skills add` 后，从项目根目录为你的编程 Agent 运行一次安装器：

| Agent | 安装器 | 写入目标 |
|---|---|---|
| Claude Code | `bash .claude/skills/MergeMill-common/scripts/install-claude-hooks.sh` | `.claude/settings.json` |
| Qoder | `bash .claude/skills/MergeMill-common/scripts/install-qoder-hooks.sh` | `.qoder/settings.json` |
| Antigravity | `bash .claude/skills/MergeMill-common/scripts/install-antigravity-hooks.sh` | `.antigravity/hooks.json` |
| Cursor | `bash .claude/skills/MergeMill-common/scripts/install-cursor-hooks.sh` | `.cursor/hooks.json` |
| Kiro CLI | `bash .claude/skills/MergeMill-common/scripts/install-kiro-hooks.sh [--agent <name>]` | `.kiro/agents/<name>.json`（默认：`default`） |
| Gemini CLI | `bash .claude/skills/MergeMill-common/scripts/install-gemini-hooks.sh` | `.gemini/settings.json` |
| Codex CLI | `bash .claude/skills/MergeMill-common/scripts/install-codex-hooks.sh` | `.codex/hooks.json` + `.codex/config.toml` |
| Windsurf | `bash .claude/skills/MergeMill-common/scripts/install-windsurf-hooks.sh` | `.windsurf/hooks.json` |
| Kimi CLI | `bash .claude/skills/MergeMill-common/scripts/install-kimi-hooks.sh [--project]` | `~/.kimi/config.toml`（默认；`--project` 写入 `.kimi/config.toml`）|

每个安装器在**项目范围**内接入工作流 hooks，因此它们在仓库中的每个 shell 命令上触发——不限于显式加载 MergeMill-* skill 时。否则，skill frontmatter 中声明的 hook 命令仅在 skill 在会话中活跃时运行，这正是修复 #68 的回归。

每个 Agent 的 schema 映射参考见 [`docs/cross-agent-hooks.md`](https://github.com/panzi-hub/MergeMill/blob/main/docs/cross-agent-hooks.md)。

### 项目侧 `scripts/` 和 `hooks/` 符号链接

上述 IDE 安装器仅写入 IDE 配置文件（如 `.claude/settings.json`）。项目侧的 `<project>/scripts/` 符号链接（使 `dispatcher-tick.sh` 找到 `MergeMill-dev.sh`、`lib-agent.sh` 等）和 `<project>/hooks` 目录符号链接由独立的、与 IDE 无关的引导脚本管理——**这是 `scripts/` 目录中已包含项目本地文件的项目的规范模式**：

```bash
# 从项目根目录，`npx skills add` 之后：
bash .agents/skills/MergeMill-common/scripts/install-project-hooks.sh
```

它的功能：

- 将已安装的 `MergeMill-dispatcher/scripts/` 中的每个 `*.sh` 创建符号链接到 `<project>/scripts/`，**不覆盖**真实的（非符号链接的）项目本地文件，如 `MergeMill.conf` 或每项目部署辅助脚本。
- 如果上游移除文件，清理悬空的符号链接。
- 创建符号链接 `<project>/hooks` → `MergeMill-common/hooks`（拒绝遮蔽已有的真实目录）。
- 安装每个 worktree 的 git `pre-push` hook（#65）。使用 `--no-git-hook` 跳过。

幂等——每次 `npx skills update` 后重新运行，以便新添加的上游文件（例如此 skill 集合添加新的 `lib-*.sh` 时）被自动拾取。修复了 #153 背后的静默漂移模式。

### 遗留目录级回退（已弃用）

较早的文档建议用单一符号链接替换项目的 `scripts/` 目录：

```bash
ln -sf .claude/skills/MergeMill-dispatcher/scripts scripts   # 已弃用
```

这会丢失 `scripts/` 中的任何项目本地文件。改用 `install-project-hooks.sh`——它能正确处理已有项目本地内容的目录，且重新运行可拾取上游变更。

### 必需的 Claude Code 插件

仅 Claude Code。安装器会提示；如手动安装，添加到 `.claude/settings.json` 的 `enabledPlugins` 下：

```json
{
  "enabledPlugins": {
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  }
}
```

> 不支持 hook 的 IDE（Cursor、Windsurf）跳过安装器和符号链接——skills 无需 hooks 也可工作，但须手动执行工作流步骤。

## 此目录中的内容

- **`hooks/`** — 工作流强制 hooks（block-push-to-main、block-commit-outside-worktree、check-pr-review、check-shellcheck、verify-completion 等）。规范列表和每个 hook 的语义见 `hooks/README.md`。
- **`scripts/`** — dev/review skills 使用的 Agent 可调用工具：
  - `install-project-hooks.sh` — 与 IDE 无关的项目侧引导：将 dispatcher `*.sh` 创建符号链接到 `<project>/scripts/`（不覆盖项目本地文件），创建符号链接 `<project>/hooks`，清理悬空链接，安装 git pre-push hook。每次 `npx skills update` 后重新运行（修复 #153）
  - `lib-installer.sh` — 每个 Agent 安装器使用的共享合并/写入辅助函数
  - `lib-installer-translate.sh` — 近克隆 Agent 的 schema 翻译辅助函数（事件名映射、工具名映射、超时单位转换）
  - `install-claude-hooks.sh` — Claude Code 安装器（写入 `.claude/settings.json`）
  - `install-qoder-hooks.sh` — Qoder 安装器（写入 `.qoder/settings.json` — 与 Claude Code 相同 schema）
  - `install-antigravity-hooks.sh` — Antigravity 安装器（写入 `.antigravity/hooks.json`）
  - `install-cursor-hooks.sh` — Cursor 安装器（写入 `.cursor/hooks.json`）
  - `install-kiro-hooks.sh` — Kiro CLI / Amazon Q 安装器（写入 `.kiro/agents/<name>.json`）
  - `install-gemini-hooks.sh` — Gemini CLI 安装器（写入 `.gemini/settings.json`）
  - `install-codex-hooks.sh` — Codex CLI 安装器（写入 `.codex/hooks.json` + `.codex/config.toml`）
  - `install-windsurf-hooks.sh` — Windsurf 安装器（写入 `.windsurf/hooks.json`）
  - `install-kimi-hooks.sh` — Kimi CLI 安装器（写入 `~/.kimi/config.toml` 或 `.kimi/config.toml`）
  - `claude-settings.template.json` — 所有 Agent 安装器应用的规范 hook 列表
  - `gh-as-user.sh` — 以真实用户身份运行 `gh`（重新触发 bot 审查如 `/q review` 时需要）
  - `mark-issue-checkbox.sh` — Agent 切换 GitHub Issue 正文中的复选框
  - `reply-to-comments.sh` — 回复 PR 审查评论
  - `resolve-threads.sh` — 批量解决 PR 上的审查线程

> hooks 和 scripts 在其各自的 README/源文件中有详细文档。此 SKILL.md 仅编录可用的内容，以便你找到正确的文件进行编辑。
