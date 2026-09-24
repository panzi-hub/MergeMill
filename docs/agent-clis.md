# 支持的 Agent CLI

流水线通过可插拔的抽象层（`scripts/lib-agent.sh` + `adapters/<cli>.sh`）启动 dev/review Agent。通过 `scripts/MergeMill.conf` 中的 `AGENT_CMD` 配置。

## 支持矩阵

| Agent CLI | 命令 | 新会话 | 恢复（Resume） | 状态 |
|-----------|---------|-------------|--------|--------|
| Claude Code | `claude` | `--session-id <UUID>` | `--resume <id>` | 完全支持 |
| Codex CLI | `codex` | `exec --json "<prompt>"` | `exec resume <thread-id>`（从 JSON 流中捕获） | 完全支持 |
| Kiro CLI | `kiro-cli` | `chat --no-interactive [--agent <name>]` | （回退到新建） | 基本支持 |
| Cursor Agent | `agent` | `-p "<prompt>"` | `--resume=<chat-id>` | 通用回退（未测试的显式分支） |
| Antigravity CLI | `agy` | `-p "<prompt>" --log-file <path>`（从日志中 grep 出对话 UUID） | `--conversation <UUID>` | 完全支持 |
| opencode | `opencode` | `run --format json [PROMPT]` | `run --session <sessionID>`（从 JSON 流中捕获） | 完全支持 † |

`claude`、`codex`、`agy`、`kiro` 和 `opencode` 行有显式适配器；其他 CLI 通过通用的 `<cli> -p <prompt>` 回退运行。任何未列出的 CLI 如果接受 `-p <prompt>` 非交互式标志，也应该能工作——抽象层是故意宽容的。

> **Gemini CLI 上游已退役**，此处不再有适配器行。Antigravity CLI（`agy`）是 Gemini 系列模型的替代品——它自带对话 UUID 会话模型（从 `--log-file` grep 获取，而非 Gemini CLI 使用的 `--session-id`/`--resume` 对），以及通过 `agy models` 进行 `--model` 验证（见下方 EXTRA_ARGS 表）。

## 各 CLI 必需的 EXTRA_ARGS（#102 / #140 之后）

#102 多 CLI 测试端到端地测试了每个受支持的 CLI。#140 随后将各 CLI 的安全标志从 `lib-agent.sh` 中提取到操作者配置中，通过 `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`。各 CLI 的最小配置片段：

| AGENT_CMD | E2E 验证（#102） | 必需的 EXTRA_ARGS | 原因 |
|-----------|---------------------|---------------------|-----|
| `claude` | R1 | （无——`--permission-mode` 是结构性的） | claude 的工具信任配置项是现有的结构性标志 |
| `codex` | R3 | （无） | `exec --json` 是结构性的；无操作者可调信任默认值 |
| `agy` | — | （无——`--dangerously-skip-permissions --print-timeout "$AGENT_TIMEOUT"` 是结构性的，硬编码在适配器中） | 没有 `--dangerously-skip-permissions`，headless 模式会在每次工具使用提示时阻塞（agy 的对应 kiro 的 `--trust-all-tools`）；`--print-timeout` 覆盖 agy 内部默认的 5 分钟上限 |
| `kiro` | R5 / R5' | `--trust-all-tools` | 标准 kiro 安装在 `--no-interactive` 模式下拒绝每个编程工具（静默编造失败模式） |
| `opencode` | R4 | （无） | `run --format json` 是结构性的；provider/model 选择器通过 `AGENT_DEV_MODEL` 处理 |

`EXTRA_ARGS` 机制是操作者可调的（可用于添加 `--debug`、替代输出格式等）。以上值是各 CLI 在自主模式中正常运作的经验性最低要求。完整各 CLI 配置块见 `scripts/MergeMill.conf.example`。

## † opencode 前置条件

与 Claude Code（Anthropic 绑定）或 Codex CLI（OpenAI 绑定）不同，opencode 是 provider 无关的——它没有默认模型，也没有内置凭据。在设置 `AGENT_CMD=opencode` 之前：

1. **认证 provider。** 在 dispatcher 机器上（如果 `EXECUTION_BACKEND=remote-aws-ssm` 则为每台运行 wrapper 的机器）运行一次 `opencode providers login`。没有这一步，Agent 会进入会话但不产生输出，流水线静默地无进展。
2. **设置显式模型。** opencode 的 `--model` 参数需要 `provider/model` 形式（例如 `anthropic/claude-sonnet-4-6`、`openai/gpt-5.4`）。Wrapper 从 `MergeMill.conf` 转发 `AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL`；将它们留空会导致 opencode 报错或等待交互式选择（在 headless 模式下永远不会到来）。推荐：
   ```bash
   AGENT_DEV_MODEL="anthropic/claude-sonnet-4-6"
   AGENT_REVIEW_MODEL="anthropic/claude-haiku-4-5"
   ```
3. **`AGENT_PERMISSION_MODE=bypassPermissions` 尚未接入** opencode 的 `--dangerously-skip-permissions` 标志（与 codex 分支相同的差距——标记为后续跟进）。目前，在缺少权限标志可接受的沙箱环境中运行 opencode。

## 多个审查 Agent

默认情况下，wrapper 运行一个达成裁决的审查 Agent（`AGENT_REVIEW_CMD`，默认 `claude`）。设置 `AGENT_REVIEW_AGENTS` 为空格分隔的 CLI 列表，以针对同一 PR 并行运行**多个独立**的审查 Agent，并要求一致同意才能合并：

```bash
AGENT_REVIEW_AGENTS="agy kiro"   # 两者都必须 PASS 才能自动合并
```

单一审查 wrapper 在内部扇出——每个 Agent 一个并行子 shell，各自拥有独立的会话 ID 和日志，各自以 `Review Agent: <name>` 鉴别行结束其裁决评论，wrapper 使用该行进行裁决归属。聚合规则（[INV-40](pipeline/invariants.md)）：

- **一致 PASS**——仅当**每个可用 Agent** 通过时，PR 才被批准/合并；任何一个 FAIL 会将 issue 退回 `pending-dev`。
- **部分不可用时警告**——在轮询窗口内未产生裁决评论的 Agent（因为其 CLI 启动失败，或已启动但静默）被从投票中移除并发出 WARN；它**确实**发布了 FAIL 仍然算数。决策在剩余 Agent 上做出。
- **全部不可用 → 旧版回退**——如果没有任何 Agent 产生裁决，wrapper 回退到单 Agent FAIL 路径（`−reviewing +pending-dev`），保留旧版崩溃与干净但静默的区分。

扇出是 wrapper 内部的：dispatcher、`review-<N>.pid` 文件以及 `reviewing` 标签不变，因此流水线的其余部分看到每个 issue 恰好一次审查，与之前完全相同。

### 各 Agent 的模型 / extra-args 覆盖

默认情况下，每个扇出的 Agent 共享 `AGENT_REVIEW_MODEL` / `AGENT_REVIEW_EXTRA_ARGS`（[INV-41](pipeline/invariants.md)）。当列出的 CLI 使用**不兼容的模型命名空间**时（例如 kiro 需要 `claude-sonnet-4.6` 而 claude 系列 Agent 需要 `sonnet[1m]`——每个 CLI 会拒绝另一个的 id），通过各 Agent 键为特定 Agent 设置自己的值：Agent 名称大写，每个非字母数字字符映射到 `_`（`agy`→`AGY`，`kiro`→`KIRO`，`claude-code`→`CLAUDE_CODE`）：

```bash
AGENT_REVIEW_AGENTS="kiro agy"
AGENT_REVIEW_MODEL="sonnet[1m]"               # 共享默认值（agy 保留此项）
AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"   # kiro 获取自己的 id
AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"   # kiro 独有标志
```

优先级是各 Agent 键 → 共享值 → 库默认值。未设置各 Agent 键时，行为与共享值默认值逐字节相同。工作示例见 `scripts/MergeMill.conf.example`。

> **与 `REVIEW_BOTS` 的区别。** `REVIEW_BOTS` 触发*外部*审查 bot（`/q review`、`/codex review`、`@claude review`——GitHub 通道），其评论被裁决 Agent 作为**输入**读取。`AGENT_REVIEW_AGENTS` 运行 N 个**独立的达成裁决**的 Agent，每个都做出自己的 approve/pushback 决定。两者是正交的，可以组合使用。
