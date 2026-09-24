# Findings -> Decision Gate — 强制步骤

> **Provider 通道范围。** 本文档中的每个 `gh pr …` / `gh issue …` 命令是 GitHub 通道的具体形式。门控的规则——Agent 发布裁决评论、wrapper 提交 `--approve` / `--request-changes` / merge、wrapper 强制执行可合并门控（[INV-44](../../../docs/pipeline/invariants.md)）——都是 provider 无关的，同样适用于 GitLab 通道（`CODE_HOST=gitlab`），通过 `chp_approve` / `chp_merge` / `chp_mergeable` provider 接口。在 GitLab 通道上，将 `gh` 示例视为这些接口的占位符；wrapper 以相同方式驱动它们。不要手写 `glab` 等价物。

> **此门控不可协商。在提交任何 PR 审查（APPROVE 或 REQUEST_CHANGES）之前和在 Issue 上发布裁决评论之前，必须执行此自检。如果跳过此门控，审查无效。**

完成步骤 1-11 后，所有检查清单类别中的发现将被收集。在做出 PASS/FAIL 决策之前，执行以下自检：

## 门控流程

1. **列举所有发现** — 列出步骤 3-11 中发现的每个问题，不论多小。包括：
   - 流程合规性差距（缺失文档、缺失测试、未勾选的 PR 项）
   - 代码质量问题
   - CI 检查失败或待处理中的检查
   - E2E 测试失败
   - 无法验证的验收标准
   - **需求漂移**（Issue 评论显示需求变化但未在 PR 代码中反映）

2. **将每个发现分类** 为 BLOCKING（阻塞性）或 NON-BLOCKING（非阻塞性）：
   | 类别 | 阻塞性？| 示例 |
   |----------|-----------|--------|
   | 缺失设计文档 | BLOCKING | 无 `docs/plans/` 或 `docs/designs/` 文件 |
   | 缺失测试用例文档 | BLOCKING | 无 `docs/test-cases/` 文件 |
   | 新代码缺失单元测试 | BLOCKING | 新 hook/组件有 0 个测试 |
   | CI 检查未通过（包括待处理）| BLOCKING | Deploy Preview 仍 pending |
   | E2E 测试失败 | BLOCKING | 任何正常路径或功能测试失败 |
   | 验收标准未验证 | BLOCKING | 任何 AC 复选框未勾选 |
   | 安全漏洞 | BLOCKING | 凭据、注入等 |
   | 与基础分支的合并冲突 | BLOCKING | PR `mergeable` 为 `CONFLICTING` — wrapper 也强制执行（[INV-44](../../../docs/pipeline/invariants.md)）|
   | PR 检查清单项未勾选 | BLOCKING | 必选项未标记 |
   | 需求漂移 | BLOCKING | Issue 评论显示需求变化（如范围缩小、功能移除、新约束）未在 PR 代码中反映 |
   | 次要风格建议 | NON-BLOCKING | 命名偏好、可选重构 |
   | Bot 审查缺失（超时后）| NON-BLOCKING | 尽力而为，按现行策略 |

3. **应用硬性规则**：
   - **如果任何发现是 BLOCKING -> 裁决必须是 FAIL**。不要发布 "Review PASSED"。发布 "Review findings:" 并列出所有问题。（Wrapper 随后提交 `--request-changes` — 你不做。）
   - **如果零个发现是 BLOCKING -> 裁决是 PASS**。发布 "Review PASSED"。（Wrapper 随后提交 `--approve` 并在其门控后合并 — 你不做。）
   - **没有中间地带。** 发布带有阻塞项的 "Review findings:" 评论和发布 "Review PASSED" 互斥。
   - **你仅发布裁决评论 — 绝不发布 GitHub PR 审查或合并。** Wrapper 负责 GitHub 原生操作（`--approve` / `--request-changes` / `gh pr merge`）— 见下方的 [谁负责提交 GitHub 原生 PR 操作](#谁负责提交-github-原生-pr-操作inv-52)。

4. **自检问题** — 在继续之前逐一回答：
   - "我是否在上方列出了任何缺失的文档、测试或 CI 失败？" -> 如果是 YES -> FAIL
   - "所有 CI 检查是否处于 'pass' 状态（不是 'pending'，不是 'fail'）？" -> 如果是 NO -> FAIL
   - "PR 是否 `mergeable`？（`gh pr view <PR> --json mergeable -q .mergeable`）" -> 如果 `CONFLICTING` -> 那是一个阻塞性发现 -> FAIL（且 wrapper 独立强制执行 — INV-44 — 因此无论如何都不可能批准 CONFLICTING 的 PR）
   - "我是否成功标记了所有验收标准复选框？" -> 如果是 NO -> FAIL
   - "我的发现中是否写了 'must be resolved before this PR can be approved' 或类似语句？" -> 如果是 YES -> 意味着我发现了阻塞性问题 -> FAIL
   - "我是否在 Issue 评论中发现了任何未反映在 PR 代码中的需求变化？" -> 如果是 YES -> FAIL

## 此门控为何存在

在之前的一次审查中，审查 Agent 发布了多个阻塞性发现（缺失设计文档、缺失测试用例、缺失单元测试、CI 待处理、PR 检查清单未勾选），然后立即批准了 PR。E2E 通过"感觉"足够，但 skill 明确要求所有检查清单项必须满足。此门控通过强制 Agent 在执行操作前将发现与裁决对齐来防止这种脱节。

在另一次事件中，仓库所有者在 PR 已经实现后发布了一条需求变更（"移除 PDF 支持"）作为 Issue 评论。审查 Agent 在没有阅读该评论的情况下批准了 PR，因为它只检查了 Issue 正文和 PR diff——而非评论线程。"需求漂移"类别正是为了捕获这类 Bug 而添加的。

## 多 Agent 审查（INV-40）

当项目针对同一 PR 运行多个达成裁决的审查 Agent 时（`AGENT_REVIEW_AGENTS` 列出 ≥2 个 CLI），**每个 Agent 独立运行此门控**并发布自己的裁决评论。你从自己的发现中得出自己的 PASS/FAIL——你无法看到其他 Agent 的裁决，且不得试图协调。Wrapper 随后以**一致通过**规则汇总所有 Agent 的裁决：仅当每个可用 Agent 都通过时，wrapper 才批准+合并；任一 FAIL 会使 wrapper 提交 `--request-changes` 并退回给 dev。通过 `bash scripts/post-verdict.sh` 发布你的裁决（[INV-56](../../../docs/pipeline/invariants.md)）；该助手根据你传递的参数附加 `Review Session: \`<id>\`` 尾部标记和 `Review Agent: <name>` 标识行（不要手写它们）——标识行是 wrapper 在以相同身份发布的 N 个 Agent 中归属你的裁决的方式。使用可选的第 6 个 `<model>` 参数，助手将你的模型折叠到该行中为 `Review Agent: <name> (model: <model>)`，使运维者能分辨每个并行审查者使用的模型（[INV-60](../../../docs/pipeline/invariants.md)）。一致通过规则是此门控自身"任何阻塞性发现 → FAIL"理念在各 Agent 间的横向表达。

## 谁负责提交 GitHub 原生 PR 操作（INV-52）

> **审查 WRAPPER — 而非 Agent — 负责 GitHub 原生 PR 审查/合并操作。** Agent 的唯一输出是 Issue 上的裁决**评论**（通过 `post-verdict.sh` 发布，[INV-56](../../../docs/pipeline/invariants.md)）。Wrapper 读取它并执行操作：
>
> | Agent 发布的内容（Issue 评论）| Wrapper 提交的内容（GitHub 原生，在其门控之后）|
> |---|---|
> | `Review PASSED` | `gh pr review --approve` 然后 `gh pr merge`（除非 `no-auto-close`），在 [INV-44](../../../docs/pipeline/invariants.md) 可合并门控之后 |
> | `Review findings:`（阻塞性）| `gh pr review --request-changes` → `reviewDecision = CHANGES_REQUESTED` |
>
> **Agent 绝不能运行 `gh pr review --approve`、`gh pr review --request-changes`、`gh pr merge` 或 MCP merge 工具。** 自发批准/合并的 Agent 会与 wrapper 的可合并硬门控和 `no-auto-close` 跳过合并竞争——它可能在门控运行之前合并一个 `UNKNOWN` 可合并性的 PR 或一个 `no-auto-close` 的 PR（正是促使 [INV-52](../../../docs/pipeline/invariants.md) 的 PR #191 事件）。Agent 发出任何 GitHub PR 审查或合并都是一个**缺陷**。

## 决策标准

### PASS（发布 "Review PASSED" — WRAPPER 随后提交 APPROVE 审查 + 合并）

**以下所有项必须为真** — 即使一项为假，裁决即为 FAIL：

- 所有审查检查清单项（第 1-5 节）均满足
- 至少一个正常路径测试用例通过（来自文档或冒烟测试）
- 代码质量可接受
- 无安全顾虑
- **所有 CI 检查处于 "pass" 状态**（不是 "pending"，不是 "queued"，不是 "fail"）
- **PR 是 `mergeable`**（不是 `CONFLICTING`；wrapper 也强制 — INV-44）
- E2E 验证通过（如已配置）
- **所有验收标准复选框在 Issue 正文中标记为已勾选**
- **未检测到需求漂移**（Issue 评论不包含未处理的需求变化）
- **Findings->Decision Gate 产生零个阻塞性发现**

### FAIL（发布 "Review findings:" — WRAPPER 随后提交 REQUEST_CHANGES）

**如果以下任一项为真**，裁决为 FAIL — 发布 "Review findings:" 且不要发布 "Review PASSED"（且绝不自己提交任何 GitHub PR 审查）：

- 任何检查清单项未满足
- 发现安全漏洞
- 重大代码质量问题
- **任何 CI 检查未处于 "pass" 状态**（pending 算作未通过）
- **PR 为 `CONFLICTING`**（与基础分支的合并冲突 — wrapper 的可合并门控即使你遗漏也会在此处强制 FAIL，INV-44）
- **任何 E2E 测试用例失败**（如已配置 E2E）
- **任何正常路径测试用例失败**（如已配置 E2E）
- **预览 URL 不可用**（如已配置 E2E）
- **任何验收标准复选框保持未勾选**
- **检测到需求漂移**（Issue 评论包含未反映在 PR 中的需求变化）
- **Findings->Decision Gate 产生一个或多个阻塞性发现**

当判定为失败时，提供具体且可操作的反馈：
- 引用有问题的代码
- 解释为什么它是一个问题
- 建议修复方法
- 包含 E2E 失败截图作为证据（如可用）
- **对于需求漂移：引用改变需求的 Issue 评论并列出需要更新的具体文件/代码**

## 输出格式

> **Findings->Decision Gate 必须在发布任何输出之前执行。如果尚未运行，立即停止并运行它。**

将审查结果作为 Issue（不是 PR）的评论发布，**仅**通过确定性助手 — 绝不用裸的 `gh issue comment` 发布裁决（[INV-56](../../../docs/pipeline/invariants.md)）。**该评论是你的唯一输出** — wrapper 执行 GitHub 原生 PR 操作（见 [谁负责提交 GitHub 原生 PR 操作](#谁负责提交-github-原生-pr-操作inv-52)）。

```bash
# 将你的裁决正文写入文件（文件避免了带反引号/引号的多行
# 正文的 shell 引用破损），然后发布。助手在前后附加标准的
# "Review PASSED" / "Review findings:" 首行和
# `Review Session:` / `Review Agent:` 尾部标记（ids + model 在
# 你的 prompt 中）。可选的第 6 个 <model> 参数被折叠到 agent 行中为
# `Review Agent: <name> (model: <model>)`，使裁决记录产生它的模型
#（[INV-60](../../../docs/pipeline/invariants.md)）：
bash scripts/post-verdict.sh <issue-number> <pass|fail> <body-file> <agent-name> <session-id> [<model>]
```

**操作配对 — 这两者必须匹配：**
| 裁决 | 你的操作（Agent，通过 `post-verdict.sh`）| Wrapper 的操作（GitHub 原生，在其门控之后）|
|---------|--------------|------------------|
| PASS | `post-verdict.sh … pass …` 在 Issue 上 | 提交 `--approve` + `gh pr merge`（除非 `no-auto-close`）|
| FAIL | `post-verdict.sh … fail …` 在 Issue 上 | 提交 `--request-changes` → `reviewDecision = CHANGES_REQUESTED` |

**禁止**生成了带有阻塞项的 "Review findings:" 裁决却将其视为 PASS。这两者互斥。也**禁止** Agent 提交任何 GitHub PR 审查（`gh pr review --approve` / `--request-changes`）或 `gh pr merge` — 那是 wrapper 的工作（[INV-52](../../../docs/pipeline/invariants.md)）。

你写入文件的正文（助手保证在其周围加上首行 + 尾部标记）：

PASS 格式：
```
All checklist items verified, code quality good. E2E verification completed.

Findings->Decision Gate: 0 blocking findings.

Summary:
- Design: docs/plans/xxx.md
- Tests: X unit tests, Y E2E tests
- CI: All checks passing
- Code: Clean, follows project conventions
- E2E: All N test cases passed (including M happy path), K regression checks passed
- Happy path: TC-HP-XXX executed, plan generation verified
- Requirement drift: None detected
```

FAIL 格式：
```
Findings->Decision Gate: N blocking finding(s) — FAIL.

1. **[BLOCKING] E2E test failure** - TC-HP-001 failed
   - Expected: Plan with 7 days of Python videos
   - Actual: Plan generated with only 3 days
   - Evidence: [inline screenshot in PR E2E report comment]
   - Action: Fix plan generation to respect duration requirements

2. **[BLOCKING] Requirement drift** - PDF support removal not implemented
   - Issue comment by @owner (2026-03-18): "移除 PDF 支持，转换效果不好"
   - PR still contains PDF upload, conversion, and test code
   - Action: Remove .pdf from frontend accept, backend API, Lambda handler, and tests

3. **[BLOCKING] CI check pending** - Deploy Preview not yet passed
   - Action: Wait for deployment to complete before requesting review
```
