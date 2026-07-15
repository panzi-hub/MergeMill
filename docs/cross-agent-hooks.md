# 跨 Agent Hook 支持

本文档是关于在支持 hook 式执行（在工具调用之前/之后运行 shell 命令，并可以选择阻止）的编程 Agent 中安装 MergeMill 工作流 hook 的参考指南。

## 规范的 Hook 意图（Agent 无关）

Hook 本身位于 `skills/MergeMill-common/hooks/`，是 Agent 可移植的：它们从 stdin 读取 JSON，退出 `0` 表示允许，`2` 表示阻止，并使用 `$CLAUDE_PROJECT_DIR` 查找脚本。此契约适用于下表列出的每个 Agent。

各 Agent 之间的差异在于**如何声明哪个脚本在何时运行**——即各 Agent 的配置文件路径、schema、事件名称和工具名称匹配器。

## 各 Agent 矩阵

| CLI | 配置路径 | Schema 风格 | 工具名称匹配器 | 阻止退出码 | 安装器 |
|---|---|---|---|---|---|
| **Claude Code** | `.claude/settings.json` | 参考（JSON，`PreToolUse`，…） | `Bash`、`Write`、`Edit` | `2` | `install-claude-hooks.sh`（PR-5） |
| **Qoder** | `.qoder/settings.json` | 与 Claude Code 相同 | `Bash`、`Write`、`Edit` | `2` | `install-qoder-hooks.sh`（PR-11a） |
| **Antigravity** | `.antigravity/hooks.json` | 与 Claude Code 相同（未文档化） | `Bash` | `2` | `install-antigravity-hooks.sh`（PR-11a） |
| **Cursor** | `.cursor/hooks.json` | Claude 风格，驼峰命名事件，`version: 1` 信封 | `Shell`（或 cmd 上的管道正则） | `2` | `install-cursor-hooks.sh`（PR-11b） |
| **Kiro CLI / Amazon Q** | `.kiro/agents/<name>.json` | Agent 定义；驼峰命名事件；`timeout_ms`（毫秒而非秒） | `execute_bash`、`fs_write`（Write+Edit 合并） | `2` | `install-kiro-hooks.sh`（PR-11b） |
| **Gemini CLI** ⚠️ 已退役 | `.gemini/settings.json` | `BeforeTool`/`AfterTool` 事件；提供 `$CLAUDE_PROJECT_DIR` 环境兼容别名 | `run_shell_command`、`write_file`、`replace` | `2` | `install-gemini-hooks.sh`（PR-11b）——保留用于历史安装；Gemini CLI 上游已停用，请改用 Antigravity CLI（`agy`） |
| **Codex CLI** | `.codex/hooks.json` + `config.toml` 中的 `[features]codex_hooks=true` | Claude 风格（逐字模仿） | `Bash`、`Write`、`Edit`（未文档化但推断） | `2` | `install-codex-hooks.sh`（PR-11b） |
| **Windsurf** | `.windsurf/hooks.json` | snake_case 事件，折叠匹配器信息；条目**无匹配器字段** | 事件编码种类：`pre_run_command`（Bash）/ `pre_write_code`（Write+Edit 合并）/ 等 | `2` | `install-windsurf-hooks.sh`（PR-11c） |
| **Kimi CLI** | `~/.kimi/config.toml`（或带 `--project` 的 `.kimi/config.toml`） | TOML，`[[hooks]]` 表数组 | 精确/正则（`RunShell`、`WriteFile`、`StrReplaceFile`） | `2` | `install-kimi-hooks.sh`（PR-11c） |

## 各 Agent 安装

在 `npx skills add panzi-hub/MergeMill` 之后，从项目根目录运行**以下之一**：

```bash
# Claude Code
bash .claude/skills/MergeMill-common/scripts/install-claude-hooks.sh

# Qoder
bash .claude/skills/MergeMill-common/scripts/install-qoder-hooks.sh

# Antigravity（未文档化的契约——见下方注意事项）
bash .claude/skills/MergeMill-common/scripts/install-antigravity-hooks.sh

# Cursor
bash .claude/skills/MergeMill-common/scripts/install-cursor-hooks.sh

# Kiro CLI / Amazon Q（默认 Agent 名称为 "default"；用 --agent <name> 覆盖）
bash .claude/skills/MergeMill-common/scripts/install-kiro-hooks.sh

# Gemini CLI（上游已退役——见上方矩阵说明；请改用 Antigravity）
bash .claude/skills/MergeMill-common/scripts/install-gemini-hooks.sh

# Codex CLI（同时启用 .codex/config.toml 中的 [features] codex_hooks = true）
bash .claude/skills/MergeMill-common/scripts/install-codex-hooks.sh

# Windsurf（将 Bash/Write/Edit 匹配器折叠为 pre_run_command / pre_write_code 事件）
bash .claude/skills/MergeMill-common/scripts/install-windsurf-hooks.sh

# Kimi CLI（默认：~/.kimi/config.toml；--project 用于 .kimi/config.toml）
bash .claude/skills/MergeMill-common/scripts/install-kimi-hooks.sh
```

每个安装器是幂等的，并保留 Agent 配置文件中已有的任何其他顶级键。它们还安装每个 worktree 的 git pre-push hook（关闭 #65）；传递 `--no-git-hook` 可跳过。

## 注意事项

- **Antigravity**：Google 未文档化 hook 支持。社区证据表明 Claude Code schema 在实践中可用，但可能不经通知就变更。视为尽力而为的支持。
- **Codex CLI**（PR-11b）：hook 支持在实验性功能标志之后（`~/.codex/config.toml` 中的 `codex_hooks = true`）。`Bash`、`Write` 等工具名称匹配器模仿 Claude Code 但未正式文档化。
- **Windsurf**：没有按工具的匹配器字段——`pre_run_command` 对每个 shell 命令触发，`pre_write_code` 对每个文件写入/编辑触发。Hook 必须在脚本内部自行过滤（例如 `block-push-to-main.sh` 已检查命令）。安装器将 Claude 的 `(event, matcher)` 对折叠为 Windsurf 的工具特定事件。
- **Kimi CLI**：TOML 配置，上游 beta 功能。工具名称不同（`WriteFile`/`StrReplaceFile`/`RunShell` 而非 Claude 的 `Write`/`Edit`/`Bash`）。默认安装目标是用户级别（`~/.kimi/config.toml`）；`--project` 写入 `.kimi/config.toml`（实验性——Kimi 可能仅读取用户级别）。

## Hook 脚本可移植性

`skills/MergeMill-common/hooks/` 下的脚本使用规范契约：

```
stdin: {"hook_event_name": "...", "tool_name": "...", "tool_input": {...}, "cwd": "...", ...}
exit 0: 允许（stdout 添加到 Agent 上下文）
exit 2: 阻止（stderr 作为原因反馈给 LLM）
env:   $CLAUDE_PROJECT_DIR 指向仓库根目录
```

这适用于矩阵中的每个 Agent。**Gemini CLI 显式提供 `$CLAUDE_PROJECT_DIR`** 作为 Claude Code 兼容性别名。其他 Agent 要么提供等效变量（例如 `CURSOR_PROJECT_DIR`），要么以 `cwd = project root` 运行 hook，因此 `tool_input.cwd` 中的相对路径可以正常工作。

## 添加新的 Agent

如果要支持矩阵中尚未覆盖的 Agent：

1. 验证 Agent 是否确实支持 hook（检查官方文档）。
2. 在本文档的矩阵中记录其 schema。
3. 在 `skills/MergeMill-common/scripts/` 下添加 `install-<agent>-hooks.sh`。使用 `lib-installer.sh` 辅助函数（`require_jq`、`merge_hooks_settings`、`write_hooks_only_settings`、`install_per_worktree_pre_push`）。
4. 更新 `skills/MergeMill-common/SKILL.md` 的 Setup 部分。
5. 在 `tests/unit/` 下添加单元测试。

位于 `skills/MergeMill-common/scripts/claude-settings.template.json` 的规范模板是单一事实来源——你的安装器在安装时将其转换为 Agent 的风格。
