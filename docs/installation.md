# 安装指南（Agent 驱动）

本指南是为 AI 编程 Agent（Claude Code、Cursor、Codex CLI、Kiro 等）编写的，Agent 将在用户机器上代为执行安装。每个命令都可以直接复制粘贴；每个步骤都有可验证的结果。如果你是人类读者，请自行按照以下步骤操作，或将底部的提示粘贴到你的 Agent 中。

## 第 1 步 — 安装 skills

使用 `skills` CLI（注意末尾有 `s`——不带 `s` 的 `skill` 是另一个工具，目标目录为 `.codebuddy/skills/`）。

```bash
# 将所有 skills 安装到当前项目，仅针对 Claude Code。
# -a claude-code：将安装范围限定为 Claude Code（省略该参数则 CLI 会为
#                 它知道的所有其他 Agent 创建空的占位目录，污染工作区）。
# -y           ：跳过交互式确认。
npx skills add panzi-hub/MergeMill -a claude-code -y
```

如果只需要 skill 包中的单个 skill（极少见——大多数用户需要全部）：

```bash
npx skills add panzi-hub/MergeMill --skill MergeMill-dev -a claude-code -y
```

**验证安装：**

```bash
ls .claude/skills
# 预期输出：MergeMill-common  MergeMill-dev  MergeMill-dispatcher  MergeMill-review  create-issue
```

## 第 2 步 — 连接符号链接（仅 Claude Code / Kiro CLI）

Hook 脚本和 Agent 可调用脚本位于已安装的 skill 目录中，但从项目根目录引用。创建符号链接以使路径正确解析：

```bash
ln -sf .claude/skills/MergeMill-common/hooks   hooks
ln -sf .claude/skills/MergeMill-dispatcher/scripts scripts
```

**验证符号链接：**

```bash
test -x hooks/state-manager.sh && echo "hooks OK"
test -f scripts/MergeMill.conf.example && echo "scripts OK"
```

> **为什么需要符号链接？** `npx skills add` 将每个 skill 目录复制到 `.claude/skills/`，但 hook 命令使用 `$CLAUDE_PROJECT_DIR/hooks/`（项目根目录）。符号链接弥补了这一差距。`scripts/` 符号链接使 skills 引用的 Agent 可调用工具脚本（例如 `scripts/gh-as-user.sh`）可用。

如果你的 IDE 不支持 hook（Cursor、Windsurf），跳过此步骤——skills 仍然可用；只需手动执行工作流。

## 第 3 步 — 启用必需的 Claude Code 插件

编辑 `.claude/settings.json` 并在 `enabledPlugins` 中添加以下内容：

```json
{
  "enabledPlugins": {
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  }
}
```

Hook 引用了这些插件的子 Agent（`code-simplifier:code-simplifier`、`pr-review-toolkit:code-reviewer`）。没有它们，`check-code-simplifier.sh` 和 `check-pr-review.sh` 门控将阻止 commit/push。

## 第 4 步 — 创建每个项目的 `MergeMill.conf`

```bash
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
```

该文件是一个 bash 脚本，在每次 dispatcher tick 和 wrapper 调用时被 `source`。填写以下必需的值：

| 变量 | 是否必需 | 设置内容 | 备注 |
|---|---|---|---|
| `PROJECT_ID` | 是 | 简短标识符（例如 `acme-api`） | 用于 PID/日志文件名。每个项目必须唯一。 |
| `REPO` | 是 | `owner/repo-name` | 流水线监控的仓库。 |
| `REPO_OWNER`、`REPO_NAME` | 是 | `REPO` 的分拆形式 | 用于 App token 范围限定（GitHub）。 |
| `PROJECT_DIR` | 是 | dispatcher 机器上项目根目录的绝对路径 | Agent 运行的位置。 |
| `ISSUE_PROVIDER`、`CODE_HOST` | 否（默认 `github`） | `github` 或 `gitlab` | 两个 provider 接缝（issue 跟踪器 / 代码托管）。GitLab 通道见 [gitlab-setup.md](gitlab-setup.md)。 |
| `AGENT_CMD` | 否（默认 `claude`） | `claude`、`codex`、`kiro`、`agy` 或 `opencode` | 用于启动 dev/review Agent 的 CLI。各 CLI 的说明和 resume 语义见 [agent-clis.md](agent-clis.md)。 |
| `AGENT_DEV_MODEL`、`AGENT_REVIEW_MODEL` | 否（默认空 / `sonnet`） | 传递给 Agent CLI 的模型名称 | 空 = 让 CLI 自行选择。审查模型默认为 `sonnet` 以保持审查成本可预测。 |
| `AGENT_REVIEW_AGENTS` | 否（默认空） | 空格分隔的 CLI 列表（例如 `agy kiro`） | 运行**多个**独立的审查 Agent，并要求一致同意才能合并。见 [agent-clis.md](agent-clis.md#multiple-review-agents)。 |
| `AGENT_PERMISSION_MODE` | 否（默认 `auto`） | `auto`、`plan` 或 `bypassPermissions` | `bypassPermissions` 授予 Agent 不受限制的 shell 访问权限——仅在受信任的沙箱中使用。 |
| `AGENT_TIMEOUT` | 否（默认 `4h`） | coreutils `timeout` 单位（例如 `30m`、`2h`、`1d`） | 每次 Agent 调用的挂钟时间上限。 |
| `GH_AUTH_MODE` | 否（默认 `token`） | `token` 或 `app` | 仅 GitHub 通道。`app` 使用 GitHub App 私钥（见 [github-app-setup.md](github-app-setup.md)）。 |
| `GITLAB_HOST`、`GITLAB_TOKEN`、`GITLAB_PROJECT` | GitLab 通道 | 见 [gitlab-setup.md](gitlab-setup.md) | 当任一接缝为 `gitlab` 时必需。 |
| `MAX_CONCURRENT` | 否（默认 `5`） | 数字 | 并行 Agent 进程的上限。 |
| `MAX_RETRIES` | 否（默认 `3`） | 数字 | Dev Agent 的重试预算，超出后 issue 标记为 `stalled`。 |
| `REVIEW_BOTS` | 否（默认 `q`） | 空格分隔的短名称 | 批准前必须在每个 PR 上运行的外部 bot 审查者（GitHub 通道；内置：`q` / `codex` / `claude`）。空字符串禁用 bot 强制执行。 |
| `E2E_ENABLED` | 否（默认 `false`） | `true` / `false` | 在审查步骤中启用 Chrome DevTools MCP E2E 验证。 |
| `REAL_GH` | 否（默认空） | 真实 `gh` 二进制文件的绝对路径 | 当 `gh` 不在最小 POSIX PATH 中且 dispatcher 从非交互式 shell（cron、systemd、SSM、nohup）运行时设置。 |

**验证配置：**

```bash
bash -n scripts/MergeMill.conf            # 语法检查
( source scripts/MergeMill.conf && \
  echo "REPO=$REPO PROJECT_DIR=$PROJECT_DIR AGENT_CMD=${AGENT_CMD:-claude} REVIEW_BOTS='${REVIEW_BOTS:-q}'" )
```

## 第 5 步 — 创建流水线标签

```bash
# 先 source 配置以确保 $REPO 被解析；子 shell 防止变量泄漏。
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
```

创建 `MergeMill`、`pending-dev`、`in-progress`、`pending-review`、`reviewing`、`done`、`stalled`、`no-auto-close` 等标签。幂等操作——可安全地重复运行。在 GitLab 通道上，标签供应通过 provider 接缝自动路由。

## 第 6 步 — 冒烟测试 wrapper（不实际启动 Agent）

```bash
bash -n scripts/MergeMill-dev.sh        # 由 dispatcher 按 issue 启动（dev 路径）
bash -n scripts/MergeMill-review.sh     # 由 dispatcher 按 issue 启动（review 路径）
bash -n scripts/dispatcher-tick.sh       # 每次 tick 的入口点
```

三个命令都不应有输出（语法干净）。运行时，如果 `dispatcher-tick.sh` 报告 `REVIEW_BOTS validation failed`，请修正 `MergeMill.conf` 中的拼写错误并重新运行——预检在任何 API 调用之前中止整个 tick，因此重试计数器不会递增。

## 供 AI Agent 直接复制粘贴的提示

将以下内容粘贴到 Claude Code、Cursor、Codex CLI 或任何能运行 shell 命令的 Agent 中。Agent 将端到端执行上述步骤。

````markdown
将 MergeMill skills 安装到此项目中。仓库是 GitHub 上的 `panzi-hub/MergeMill`。

按顺序执行以下步骤。每步完成后验证结果再继续下一步。

1. 运行 `npx skills add panzi-hub/MergeMill -a claude-code -y`，确认 `.claude/skills/MergeMill-{common,dev,dispatcher,review}` 和 `.claude/skills/create-issue` 存在。

2. 创建两个项目根目录符号链接：
   `ln -sf .claude/skills/MergeMill-common/hooks hooks`
   `ln -sf .claude/skills/MergeMill-dispatcher/scripts scripts`
   验证 `hooks/state-manager.sh` 和 `scripts/MergeMill.conf.example` 可访问。

3. 将 `code-simplifier@claude-plugins-official` 和 `pr-review-toolkit@claude-plugins-official` 添加到 `.claude/settings.json` 的 `enabledPlugins` 中（如果文件不存在则创建）。

4. 复制 `scripts/MergeMill.conf.example` 为 `scripts/MergeMill.conf`。然后**向我询问**以下值：`PROJECT_ID`、`REPO`、`PROJECT_DIR`、`AGENT_CMD`（默认 `claude`）、`ISSUE_PROVIDER`/`CODE_HOST`（默认 `github`；`gitlab` 需要 GITLAB_* 键——见 docs/gitlab-setup.md）、`REVIEW_BOTS`（默认 `q`）、`GH_AUTH_MODE`（默认 `token`）。原地编辑文件；不要提交机密信息。编辑完成后，运行 `bash -n scripts/MergeMill.conf` 并 source 它确认值正确回显。

5. Source 配置并运行 `bash scripts/setup-labels.sh "$REPO"` 创建流水线标签。（不先 source，`$REPO` 将为空，`setup-labels.sh` 会针对错误的仓库或失败。）
   ```bash
   ( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
   ```

6. 冒烟测试语法：`bash -n scripts/MergeMill-dev.sh scripts/MergeMill-review.sh scripts/dispatcher-tick.sh`。报告任何错误。

7. **到此为止。** 不要设置 dispatcher cron——这是由用户根据他们使用的编排主机（OpenClaw、普通 cron + Agent CLI、GitHub Actions schedule 等）单独决定的。告诉用户 README 的"运行完整流水线"部分列出了哪些选项，让他们自行选择。
````
