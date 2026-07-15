# MergeMill Dev Team 流水线

> **权威状态机、dispatcher / dev / review 流程、交接不变量和完整的 INV-NN 目录，见 [`docs/pipeline/`](pipeline/README.md)。** 本文档是入门指南；该目录是规范。流水线 Bug 修复必须更新 `docs/pipeline/`（根据 [`CONTRIBUTING.md`](../CONTRIBUTING.md) 规则 1）。

## 概述

MergeMill Dev Team 流水线自动化了 GitHub issue 的完整软件开发生命周期。当 issue 被打上 `MergeMill` 标签后，流水线会自动：

1. **调度**一个开发 Agent 来实现需求
2. **审查**生成的 PR（使用独立的审查 Agent）
3. **合并** PR（如果所有检查通过）或**退回**修复（如果未通过）

流水线无需人工干预即可运行，使用 AI 编程 Agent（Claude Code、Codex、Kiro）来编写代码、测试和文档。通过 GitHub issue 跟踪、PR 审查以及 `no-auto-close` 标签的人工批准门控来保持人工监督。

## 架构

```
                    ┌──────────────────────────────┐
                    │      GitHub Issues            │
                    │   (MergeMill 标签)           │
                    └──────────────┬───────────────┘
                                   │
                          ┌────────▼────────┐
                          │    OpenClaw      │
                          │   Dispatcher     │
                          │  (cron 5min)     │
                          └──┬─────────┬────┘
                             │         │
                   ┌─────────▼──┐  ┌───▼──────────┐
                   │  Dev Agent  │  │ Review Agent  │
                   │  (Opus)     │  │ (Sonnet)      │
                   │             │  │               │
                   │ - 设计      │  │ - 代码审查    │
                   │ - 实现      │  │ - CI 验证     │
                   │ - 测试      │  │ - E2E 测试    │
                   │ - 创建 PR   │  │ - 批准/失败   │
                   └──────┬──────┘  └───────┬──────┘
                          │                 │
                          ▼                 ▼
                    ┌──────────────────────────────┐
                    │      GitHub PRs               │
                    │   (自动合并或手动)            │
                    └──────────────────────────────┘
```

### 组件职责

| 组件 | 运行时 | 职责 |
|-----------|---------|----------------|
| OpenClaw Dispatcher | Cron（每 5 分钟） | 扫描 issue、管理标签、调度 dev/review Agent |
| Dev Agent | 编程 Agent 会话 | 实现需求、编写测试、创建 PR |
| Review Agent | 编程 Agent 会话 | 审查 PR、运行 E2E 测试、批准或请求变更 |

> **注意：** 脚本打包在 skill 目录中以便移植。项目根目录的 `scripts/` 是指向 `skills/MergeMill-dispatcher/scripts/` 的符号链接。共享脚本从 `skills/MergeMill-common/scripts/` 符号链接而来。

## 前置条件

- **OpenClaw** — Agent 编排平台（或使用 `dispatch-local.sh` 进行本地调度）
- **编程 Agent CLI** — 以下之一：`claude`（Claude Code）、`codex`、`gemini`、`kiro` 或 `opencode`
- **GitHub CLI**（`gh`）— 使用适当权限认证
- **jq** — JSON 处理器，用于解析 GitHub API 响应
- **Git** — 支持 worktree

## 快速开始

### 1. 克隆仓库

```bash
git clone https://github.com/<owner>/<repo>.git
cd <repo>
```

### 2. 复制配置模板

```bash
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
```

### 3. 填写配置

编辑 `scripts/MergeMill.conf`，填入你的项目值：

```bash
# 必需
PROJECT_ID="my-project"
REPO="owner/repo-name"
REPO_OWNER="owner"
REPO_NAME="repo-name"
PROJECT_DIR="/path/to/project"

# 认证（选择一种模式）
GH_AUTH_MODE="token"  # 或 "app" 用于 GitHub App token

# 可选：E2E 验证
E2E_ENABLED="false"
```

所有可用选项见[配置参考](#配置参考)部分。

### 4. 设置调度

**选项 A：OpenClaw cron（推荐）**

```bash
openclaw cron add \
  --name "MergeMill Dispatcher" \
  --cron "*/5 * * * *" \
  --session isolated \
  --message "Run the MergeMill-dispatcher skill. Check GitHub issues and dispatch tasks." \
  --announce
```

**选项 B：本地调度脚本**

```bash
# 手动运行 dispatcher
bash scripts/dispatch-local.sh
```

### 5. 创建带 `MergeMill` 标签的 issue

创建一个带有 `MergeMill` 标签的 GitHub issue。Issue 正文应包含：

```markdown
## Requirements
- [ ] 需求 1
- [ ] 需求 2

## Acceptance Criteria
- [ ] 标准 1
- [ ] 标准 2
```

流水线将在 5 分钟内获取它。

## 配置参考

所有配置存储在 `scripts/MergeMill.conf` 中。值也可以通过环境变量设置。

| 变量 | 描述 | 默认值 | 是否必需 |
|----------|-------------|---------|----------|
| `PROJECT_ID` | 唯一项目标识符（用于日志/PID 文件名） | — | 是 |
| `REPO` | GitHub 仓库，`owner/repo` 格式 | — | 是 |
| `REPO_OWNER` | 仓库所有者（组织或用户） | — | 是 |
| `REPO_NAME` | 仓库名称 | — | 是 |
| `PROJECT_DIR` | 项目根目录的绝对路径 | — | 是 |
| `AGENT_CMD` | 编程 Agent CLI 命令 | `claude` | 否 |
| `AGENT_DEV_MODEL` | 开发任务模型 | _(Agent 默认)_ | 否 |
| `AGENT_REVIEW_MODEL` | 审查任务模型 | `sonnet` | 否 |
| `AGENT_PERMISSION_MODE` | Agent 权限模式 | `bypassPermissions` | 否 |
| `GH_AUTH_MODE` | GitHub 认证模式：`token` 或 `app` | `token` | 否 |
| `DEV_AGENT_APP_ID` | Dev Agent 的 GitHub App ID（仅 app 模式） | — | 如为 app 模式 |
| `DEV_AGENT_APP_PEM` | Dev Agent App 私钥 PEM 路径 | — | 如为 app 模式 |
| `REVIEW_AGENT_APP_ID` | Review Agent 的 GitHub App ID（仅 app 模式） | — | 如为 app 模式 |
| `REVIEW_AGENT_APP_PEM` | Review Agent App 私钥 PEM 路径 | — | 如为 app 模式 |
| `DISPATCHER_APP_ID` | Dispatcher 的 GitHub App ID（仅 app 模式） | — | 如为 app 模式 |
| `DISPATCHER_APP_PEM` | Dispatcher App 私钥 PEM 路径 | — | 如为 app 模式 |
| `MAX_CONCURRENT` | 最大并发 Agent 任务数 | `5` | 否 |
| `DEV_SKILL_CMD` | Dev Agent 提示的 skill 命令 | `/MergeMill-dev` | 否 |
| `E2E_ENABLED` | 在审查中启用 E2E 验证 | `false` | 否 |
| `E2E_PREVIEW_URL_PATTERN` | 预览 URL 模板（`{N}` = PR 编号） | — | 如 E2E 启用 |
| `E2E_TEST_USER_EMAIL` | E2E 登录的测试用户邮箱 | — | 如 E2E 启用 |
| `E2E_TEST_USER_PASSWORD` | E2E 登录的测试用户密码 | — | 如 E2E 启用 |
| `E2E_SCREENSHOT_UPLOAD` | 启用到 GitHub 的截图上传 | `false` | 否 |

## 状态机

Issue 通过一组已定义的状态流转，由 GitHub 标签跟踪：

```
                                    ┌──────────────────┐
                                    │   MergeMill     │
  Issue 创建 ──────────────────────►│   (无状态标签)   │
  带标签                            └────────┬─────────┘
                                             │
                                    Dispatcher 获取
                                             │
                                    ┌────────▼─────────┐
                              ┌────►│  in-progress      │◄────┐
                              │     └────────┬─────────┘     │
                              │              │               │
                              │     Dev Agent 完成           │
                              │              │               │
                              │     ┌────────▼─────────┐     │
                              │     │  pending-review   │     │
                              │     └────────┬─────────┘     │
                              │              │               │
                              │     Dispatcher 获取          │
                              │              │               │
                              │     ┌────────▼─────────┐     │
                              │     │  reviewing        │     │
                              │     └───┬──────────┬───┘     │
                              │         │          │         │
                              │    PASS │          │ FAIL    │
                              │         │          │         │
                              │         ▼          ▼         │
                              │   ┌──────────┐ ┌──────────┐ │
                              │   │ approved  │ │pending-dev│─┘
                              │   └──────────┘ └──────────┘
                              │         │
                              └─────────┘
                              （崩溃恢复）
```

### 标签定义

| 标签 | 颜色 | 描述 |
|-------|-------|-------------|
| `MergeMill` | `#0E8A16` | Issue 应由自主流水线处理 |
| `in-progress` | `#FBCA04` | Dev Agent 正在积极工作 |
| `pending-review` | `#1D76DB` | 开发完成，等待审查调度 |
| `reviewing` | `#5319E7` | Review Agent 正在积极审查 |
| `pending-dev` | `#E99695` | 审查失败，需要更多开发 |
| `approved` | `#0E8A16` | 审查通过，PR 已合并（或等待手动合并） |
| `no-auto-close` | `#d4c5f9` | 审查通过后跳过自动合并；需要手动批准 |

## Agent 模型策略

| 任务 | 模型 | 理由 |
|------|-------|-----------|
| 开发 | Opus（默认） | 复杂编码、架构决策、多文件变更 |
| 审查 | Sonnet | 检查清单验证、diff 分析；避免与 Opus 竞争配额 |

Dev Agent 使用默认模型（通常是 Opus）以获得最大编码能力。Review Agent 使用 Sonnet 以避免竞争 Opus 配额，同时仍然提供全面的审查分析。

通过 `MergeMill.conf` 中的 `AGENT_DEV_MODEL` 和 `AGENT_REVIEW_MODEL` 配置。

## 并发控制

- **MAX_CONCURRENT**（默认：5）限制总活动任务数（dev + review 合计）
- 每个 issue 获得一个独立的 git worktree 和 Agent 会话
- Dispatcher 在调度新任务前检查并发数
- `/tmp/cc-${PROJECT_ID}-{issue|review}-<number>.pid` 的 PID 文件跟踪活动进程

## 崩溃恢复

流水线设计为自动从 Agent 崩溃中恢复：

| 场景 | 检测 | 恢复 |
|----------|-----------|----------|
| Dev Agent 崩溃 | PID 文件存在但进程已死 | Dispatcher 将 issue 移入 `pending-review` 进行评估 |
| Review Agent 崩溃 | PID 文件存在但进程已死 | Dispatcher 将 issue 移入 `pending-dev` 进行重试 |
| Dev Agent 超时 | 长时间无活动 | 与崩溃相同——dispatcher 中的过期检测 |
| 崩溃后恢复 | Issue 有 `pending-dev` 标签 + 评论中有会话 ID | Dispatcher 使用之前的会话 ID 调度 `dev-resume` |
| 部分实现 | 需求复选框部分已选中 | Dev Agent 在恢复时读取 issue 正文，跳过已完成项 |

### 过期检测

Dispatcher 通过以下方式检查过期进程：
1. 读取 PID 文件：`/tmp/cc-${PROJECT_ID}-issue-<N>.pid`
2. 发送 `kill -0 <pid>` 检查进程是否存活
3. 如果已死，将 issue 转换到适当的恢复状态

## 日志文件位置

| 日志文件 | 内容 |
|----------|---------|
| `/tmp/cc-${PROJECT_ID}-issue-<N>.log` | Dev Agent 会话输出 |
| `/tmp/cc-${PROJECT_ID}-review-<N>.log` | Review Agent 会话输出 |

PID 文件遵循相同的模式，扩展名为 `.pid`。

## 受支持的 Agent

| Agent | 命令 | Dev 支持 | Review 支持 | Resume 支持 |
|-------|---------|-------------|----------------|----------------|
| Claude Code | `claude` | 完整 | 完整 | 是（通过 `--session-id` / `--resume` 进行 UUID 往返） |
| Codex | `codex` | 基本 | 基本 | 是（CLI 生成的 thread_id 捕获到 sidecar） |
| Gemini | `gemini` | 基本 | 基本 | 是（UUID 往返——与 claude 模型相同，无 sidecar）。操作者必须设置 `AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json"`（关键配置——见 #140 / #134）。 |
| Kiro | `kiro` | 基本 | 基本 | 否（恢复时新建会话）。操作者必须在标准 kiro 安装上设置 `AGENT_DEV_EXTRA_ARGS="--trust-all-tools"`（关键配置——见 #140 / #136）。 |
| Opencode | `opencode` | 基本 | 基本 | 是（CLI 生成的 sessionID 捕获到 sidecar） |

在 `MergeMill.conf` 中设置 `AGENT_CMD` 以切换 Agent。推荐使用 Claude Code 以获得完整的流水线支持，包括会话恢复。

### Agent 冒烟测试——CLI 实际是否能启动、认证并响应？（INV-63）

单元测试 stub 了 CLI，因此启动 → 认证 → 模型链条从未在合并前被测试。**Agent 冒烟测试**弥补了这一差距。`lib-agent-smoke.sh::smoke_agent <agent-cmd> <model>` 通过**生产环境 `run_agent`** 运行一个单 token 往返，并将结果分为三种状态：**PASS**（模型回显了 nonce）、**UNAVAILABLE**（配额/容量/临时后端——环境性，非阻塞），或 **FAIL**（启动/认证/配置损坏，包括区域漂移——门控级别）。矩阵工具 `tests/e2e/run-agent-smoke.sh` 并行运行操作者配置的矩阵，汇总为 `SMOKE-SUMMARY pass=N fail=N unavailable=N skip=N`（任何 FAIL → rc 1）。完整契约、矩阵配置（`tests/e2e/e2e.conf.example`）和 `SMOKE_STUB=1` CI 自测试见 [`docs/pipeline/agent-smoke.md`](pipeline/agent-smoke.md)。

### 操作者可调的各 CLI 标志（关闭 #140）

两个 `MergeMill.conf` 变量逐字追加标志到每次 CLI 调用：

| 变量 | 使用者 | 追加到 argv |
|---|---|---|
| `AGENT_DEV_EXTRA_ARGS` | `run_agent`（dev wrapper，新建会话路径） | 在结构性参数之后、prompt positional 之前 |
| `AGENT_REVIEW_EXTRA_ARGS` | `resume_agent`（review wrapper，恢复路径） | 在结构性参数之后、prompt positional 之前 |

两者默认为空。分词使用 `eval`，因此带引号的多词值能正常工作（`AGENT_DEV_EXTRA_ARGS='--policy "/path with spaces/policy.json"'`）。信任级别与 `AGENT_LAUNCHER` 匹配——值来自操作者控制的 `MergeMill.conf`。

**在以下场景使用此机制**：
- 向现有 CLI 添加新标志（例如 `--debug` 用于详细日志记录）
- 在不修改 `lib-agent.sh` 的情况下接入未文档化的各 CLI 安全标志
- 接入新 CLI：设置 `AGENT_CMD=<cli>` 以通过通用的 `<cli> -p <prompt>` 分支，并通过 EXTRA_ARGS 提供信任/输出标志

**常见陷阱**：
- **引号**：`eval` 将字符串解析为 shell argv。单 token 标志如 `--debug` 很简单；含嵌入空格的多 token 值需要在 conf 中使用 shell 风格的引号，例如 `AGENT_DEV_EXTRA_ARGS='--policy "/etc/foo bar/policy"'`。
- **Dev 与 review 的分歧**：`AGENT_DEV_EXTRA_ARGS` 不会被 `resume_agent` 继承——当两条路径都需要相同标志时，同时设置两个变量。例外：kiro，其 `resume_agent` 回退到 `run_agent` 并读取 `AGENT_DEV_EXTRA_ARGS`。
- **从 #140 之前迁移**：在未更新配置的情况下拉取此版本的 gemini 和 kiro 部署将静默退化到 #102 R2 / R5 编造失败模式（conf.example 头部标注是此情况的关键操作者面向工件）。

需获取各 CLI 正式值，请参见 `scripts/MergeMill.conf.example` 底部的各 CLI 配置块。

> **规范化的适配器契约**——每个 CLI 的适配器在 `dev-new` / `dev-resume` / `review` / `e2e-browser` 模式中必须返回的内容（四轴 `AdapterResult`、裁决工件 / 夹具清单 / 错误信封 JSON Schema，以及各 CLI 映射附录）——见 [`docs/pipeline/adapter-spec.md`](pipeline/adapter-spec.md)（`spec_version: 1`，[INV-66](pipeline/invariants.md#inv-66-adapter-conformance-is-spec-defined)）。当前 `lib-agent.sh` + `lib-review-*.sh` 行为映射到其中所述；后续适配器工作将实现它。

## 关键文件

| 文件 | 描述 |
|------|-------------|
| `scripts/MergeMill-dev.sh` | Dev Agent wrapper（处理标签转换） |
| `scripts/MergeMill-review.sh` | Review Agent wrapper（处理 approve/merge/fail） |
| `scripts/MergeMill.conf.example` | 配置模板 |
| `scripts/lib-agent.sh` | Agent CLI 抽象（claude/codex/gemini/kiro/opencode） |
| `scripts/lib-agent-smoke.sh` | 三状态 Agent CLI 冒烟测试（`smoke_agent`）——通过生产环境 `run_agent` 进行 PASS/UNAVAILABLE/FAIL 启动-认证-模型探测。见 [`docs/pipeline/agent-smoke.md`](pipeline/agent-smoke.md)（INV-63）。 |
| `tests/e2e/run-agent-smoke.sh` | Agent 冒烟测试矩阵工具——并行三状态运行 + `SMOKE-SUMMARY`；`SMOKE_STUB=1` 用于 CI stub 自测试。 |
| `scripts/lib-auth.sh` | GitHub 认证抽象（token/app） |
| `scripts/gh-app-token.sh` | GitHub App JWT token 生成器 |
| `scripts/gh-token-refresh-daemon.sh` | 长时间运行会话的后台 token 刷新 |
| `scripts/gh-with-token-refresh.sh` | 读取已刷新 token 的 `gh` wrapper |
| `scripts/gh-as-user.sh` | 以真实用户身份运行 `gh` 命令（用于 bot 变通方案） |
| `scripts/mark-issue-checkbox.sh` | 标记 issue 复选框（两个 Agent 都使用） |
| `scripts/upload-screenshot.sh` | 上传 E2E 截图到 GitHub |
| `skills/MergeMill-dev/SKILL.md` | Dev Agent skill 定义 |
| `skills/MergeMill-review/SKILL.md` | Review Agent skill 定义 |
| `skills/MergeMill-dispatcher/SKILL.md` | Dispatcher skill 定义 |
| `scripts/dispatch-local.sh` | 本地调度助手 |
