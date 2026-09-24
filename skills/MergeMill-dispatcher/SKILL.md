---
name: MergeMill-dispatcher
description: >
  Use when running, configuring, or troubleshooting the MergeMill
  dispatcher cron. Triggers on phrases like "run the dispatcher", "scan for
  pending issues", "dispatch MergeMill tasks", "set up the dispatch cron",
  "configure dispatcher.conf", "set up multi-project dispatcher", "dispatch
  to a remote dev box via SSM", "EXECUTION_BACKEND=remote-aws-ssm",
  "stale agent detection", or working on dispatcher-tick.sh /
  dispatcher-multi-tick.sh / dispatch-local.sh / dispatch-remote-aws-ssm.sh.
  Covers per-project tick (5 steps: concurrency, scan-new, scan-pending-review,
  scan-pending-dev, stale detection), the multi-project outer loop, and
  pluggable local-vs-remote-AWS-SSM execution backends.
---

# 自主开发团队 Dispatcher

扫描 GitHub Issue 并调度 dev/review 任务。一次 cron tick 是 `dispatcher-tick.sh`（单项目）或 `dispatcher-multi-tick.sh`（多项目）的一次调用。完整的状态机、每步语义和不变量见[源码仓库的 `docs/pipeline/`](https://github.com/panzi-hub/MergeMill/tree/main/docs/pipeline)——那是规范；本文件是 Agent 的调用契约。

## 前置条件

- `gh` 和 `jq` 在 `PATH` 中。
- 本地后端：`$PROJECT_DIR` 已设置，指向项目根目录。每个项目有 `MergeMill.conf`（见 `scripts/MergeMill.conf.example`）。
- 多项目 / 远程后端：`dispatcher.conf` 声明了 `PROJECTS=()`（见 `scripts/dispatcher.conf.example`）。
- `MergeMill-dev.sh` 和 `MergeMill-review.sh` 需要有执行位（mode `100755`）——在上游已恢复，并在每次 tick 中由 `dispatcher-tick.sh` 自愈（#97）。

> **安全说明**：此 Dispatcher 处理 GitHub Issue 内容作为输入。在公开仓库中，Issue 内容不可信——任何人都可创建 Issue。确保 `MergeMill` 标签只能由可信维护者打上（使用 GitHub 分支规则集或组织策略）。Dispatcher 仅通过 GitHub API 读取标签/评论，并通过已配置的后端（`dispatch-local.sh` 或 `dispatch-remote-aws-ssm.sh`）生成本地进程——它不修改源代码或推送到分支。

## 做什么

当 cron 触发时（默认：每 5 分钟），运行**以下之一**：

**单项目部署**（每个 Dispatcher 一个仓库）：

```bash
bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"
```

**多项目部署**（一个 cron 任务，多个仓库——关闭 #62）：

```bash
DISPATCHER_CONF="$HOME/.MergeMill/dispatcher.conf" \
  bash "$PROJECT_DIR/scripts/dispatcher-multi-tick.sh"
```

多项目 tick wrapper 遍历 `dispatcher.conf` 中的 `PROJECTS=()` 并为每个项目运行一次 `dispatcher-tick.sh`。每个项目的失败记录到 stderr 但不阻塞其他项目。结构说明见 `scripts/dispatcher.conf.example`。

每个 `PROJECTS[]` 条目是以下两种形式之一：

- **本地项目**（文件路径）：指向此 dispatcher 机器上某项目 `MergeMill.conf` 的路径。Dispatcher 和项目源码位于同一台机器上。Wrapper 通过 `MERGEMILL_CONF` 优先级 1 路径 source 配置（PR-4 / [INV-14]）。
- **远程项目**（内联元数据块）：当项目源码位于通过 AWS SSM 访问的远程开发机上时使用。Dispatcher 机器上没有项目的 `MergeMill.conf` — dispatcher 扫描 Issue + 调度所需的全部内容都在 `dispatcher.conf` 中以内联方式声明。`EXECUTION_BACKEND=remote-aws-ssm` 和 `SSM_INSTANCE_ID` 通过 `aws ssm send-command` 将实际的 `dispatch-local.sh` 调用路由到远程机器。(#62)

两种形式运行相同的 5 步 tick：

1. **并发门控** — 如果 `count(in-progress + reviewing) >= MAX_CONCURRENT` 则中止。
2. **scan-new** — 查找仅带 `MergeMill` 标签的 Issue，检查依赖项，调度 dev-new。
3. **scan-pending-review** — 查找 `pending-review` Issue，调度 review。
4. **scan-pending-dev** — 查找 `pending-dev` Issue，重试计数器检查，调度 dev-resume（或如耗尽则标记为 stalled）。
5. **僵死检测** — 对 `in-progress` / `reviewing` Issue，探测 wrapper PID，根据 alive/dead 以及 PR/CI/idle 门控分支。

逻辑在 [`scripts/dispatcher-tick.sh`](scripts/dispatcher-tick.sh) 中，辅助函数在 [`scripts/lib-dispatch.sh`](scripts/lib-dispatch.sh) 中。每个步骤实现的规范见[源码仓库的 `docs/pipeline/dispatcher-flow.md`](https://github.com/panzi-hub/MergeMill/blob/main/docs/pipeline/dispatcher-flow.md)。

## GitHub 认证 — App token，非用户 token

Dispatcher 内部的所有 `gh` 调用使用 GitHub App token，而非默认用户 token。Wrapper（`MergeMill-dev.sh`、`MergeMill-review.sh`）通过 `lib-auth.sh` 处理自身的认证；dispatcher tick 处理自身的认证。

当 `GH_AUTH_MODE=app` 时，`dispatcher-tick.sh` 在前置验证后自动调用 `gh-app-token.sh::get_gh_app_token` 并在任何 `gh` 调用前导出 `GH_TOKEN`（#91）。项目的 MergeMill.conf 或内联元数据块中必需变量：

```
GH_AUTH_MODE=app
DISPATCHER_APP_ID=<numeric app id>
DISPATCHER_APP_PEM=<absolute path to PEM>
```

如果上述任一缺失，或 token 生成失败，tick 以 `FATAL` 消息退出 1——没有静默回退到用户认证。

Token 有效期为 1 小时且仅限目标仓库范围。`dispatcher-tick.sh` 通常在远不到一分钟内完成，因此单个 token 覆盖整个 tick。当 `GH_AUTH_MODE=token`（默认）或未设置时，dispatcher 使用调用者通过代码托管平台标准渠道提供的任何 token——在 GitHub 上，`GH_TOKEN` 或 `gh auth login` 会话；在 GitLab 上（`CODE_HOST=gitlab`），`GITLAB_TOKEN` 或 `glab auth login` 会话。`chp_*`/`itp_*` provider 接口根据存在的内容路由。

## 调度辅助函数

`dispatcher-tick.sh` 为每种任务类型调用 `dispatch()` 辅助函数，后者路由到已配置的执行后端。**不要以任何其他方式生成 Agent 进程。** 每个后端处理 `nohup`、输入验证、日志文件 mode 0600 和僵死 wrapper 杀除（[INV-09](https://github.com/panzi-hub/MergeMill/blob/main/docs/pipeline/invariants.md#inv-09-just_dispatched-skip-rule)）。

当前后端：

| `EXECUTION_BACKEND` | 驱动 | 何时使用 |
|---|---|---|
| `local`（默认，未设置时也是） | `scripts/dispatch-local.sh` | Wrapper 与 dispatcher 在同一台机器上运行。 |
| `remote-aws-ssm` | `scripts/dispatch-remote-aws-ssm.sh` | Wrapper 在通过 AWS Systems Manager 访问的远程开发 EC2 上运行。Dispatcher 发送 `aws ssm send-command` 在远程机器上调用 `dispatch-local.sh`。 |

每种任务命令形式（两个后端传递方式相同）：

| 类型 | 命令 |
|---|---|
| 新 dev 任务 | `dispatch dev-new ISSUE_NUM` |
| Review 任务 | `dispatch review ISSUE_NUM` |
| 恢复 dev 任务 | `dispatch dev-resume ISSUE_NUM SESSION_ID` |

## Dispatcher 绝不能做的事

Dispatcher 是一个标签和进程生成的协调者，不是代码变更者：

- 绝不能 commit 或 push 到目标仓库。
- 绝不能修改 `$PROJECT_DIR` 中的源文件。
- 只能通过 GitHub API 读取 Issue 标签/评论，通过 GitHub API 更新标签，并通过已配置的后端（`dispatch-local.sh` 或 `dispatch-remote-aws-ssm.sh`）调度 wrapper 进程。

任何代码变更都通过 wrapper 生成的 dev / review Agent 进行。

## 环境变量

从 `scripts/MergeMill.conf` 加载（由 `dispatcher-tick.sh` 在 `lib-dispatch.sh` 之前 source）：

- `REPO`：`owner/repo` 格式的 GitHub 仓库（如 `myorg/myproject`）
- `REPO_OWNER`、`REPO_NAME`：REPO 的拆分形式（用于 App token 范围限定）
- `PROJECT_ID`：日志/PID 文件的项目标识符（默认：`project`）
- `PROJECT_DIR`：本地机器上项目根目录的绝对路径
- `MAX_CONCURRENT`：最大并行任务数（默认：`5`）
- `MAX_RETRIES`：标记 Issue 为 `stalled` 前的最大 dev 重试次数（默认：`3`）
- `DISPATCHER_APP_ID`：dispatcher bot 的 GitHub App ID
- `DISPATCHER_APP_PEM`：GitHub App 私钥 PEM 文件路径

## Cron 配置（OpenClaw）

```bash
openclaw cron add \
  --name "MergeMill Dispatcher" \
  --cron "*/5 * * * *" \
  --session isolated \
  --message "Run the MergeMill-dispatcher skill. Check GitHub issues and dispatch tasks." \
  --announce
```

## 标签定义

| 标签 | 颜色 | 描述 |
|-------|-------|-------------|
| `MergeMill` | `#0E8A16` | Issue 应由自主流水线处理 |
| `in-progress` | `#FBCA04` | Agent 正在活跃开发中 |
| `pending-review` | `#1D76DB` | 开发完成，等待审查 |
| `reviewing` | `#5319E7` | Agent 正在活跃审查中 |
| `pending-dev` | `#E99695` | 审查失败，需要更多开发 |
| `approved` | `#0E8A16` | 审查通过。PR 已合并（或如果存在 `no-auto-close` 则等待手动合并） |
| `no-auto-close` | `#d4c5f9` | 与 `MergeMill` 搭配使用 — 审查通过后跳过自动合并，需手动批准 |
| `stalled` | `#B60205` | Issue 超出最大重试次数；需人工调查 |

完整状态机见[源码仓库的 `docs/pipeline/state-machine.md`](https://github.com/panzi-hub/MergeMill/blob/main/docs/pipeline/state-machine.md)。

## 模型策略

| 任务 | 模型 | 理由 |
|------|-------|-----------|
| 开发（`MergeMill-dev.sh`） | Opus（默认） | 复杂编码、架构决策 |
| 审查（`MergeMill-review.sh`） | Sonnet（`--model sonnet`） | 检查清单验证，避免 Opus 配额竞争 |
