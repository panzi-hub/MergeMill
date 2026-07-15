---
name: MergeMill-review
description: >
  Use to perform an end-to-end PR review and reach an approve/request-changes
  verdict — including verifying acceptance criteria, running E2E tests via
  browser automation, resolving merge conflicts, and (when verdict passes)
  merging the PR. Triggers on phrases like "review this PR", "decide whether
  to approve and merge", "run E2E verification", "resolve merge conflicts on
  PR #N", or when the dispatcher hands off a PR labeled `pending-review` /
  `reviewing` for MergeMill review. Distinct from in-flight dev-side
  self-review (that lives in MergeMill-dev's pr-review step).
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-push-to-main.sh"
          timeout: 5
  Stop:
    - hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/verify-completion.sh"
          timeout: 10
---

# 自主审查模式

> **Provider 通道范围。** 以下正文以 GitHub 术语书写——`gh pr review`、`gh pr merge`、`gh pr checks`、`gh pr view`、`gh issue view`——因为它们是 GitHub 通道的具体形式。每个 INV-52 / INV-44 规则（Agent 发布裁决评论；wrapper 负责 approve/request-changes/merge；wrapper 强制执行可合并硬门控）都是 provider 无关的，同样适用于 GitLab 通道（`CODE_HOST=gitlab`）：wrapper 通过 `chp_approve` / `chp_merge` / `chp_mergeable` provider 接口驱动，而非 `gh pr *` 动词。当你的 prompt 在 `CODE_HOST=gitlab` 下运行时，将每一个 `gh pr …` / `gh issue …` 示例视为 wrapper 提供的接口占位符——不要手写 `glab` 调用来替换它们。

彻底客观地审查由自主开发会话创建的 PR，然后**发布裁决评论**（`Review PASSED` 或 `Review findings:`）。审查 **wrapper** 负责 GitHub 原生操作：它在 PASS 后提交 `--approve` 并合并（通过其可合并 + `no-auto-close` 门控），在阻塞性 FAIL 时提交 `--request-changes`。你绝不要自己运行 `gh pr review` 或 `gh pr merge`——见 [谁负责提交 GitHub 原生 PR 操作（INV-52）](#谁负责提交-github-原生-pr-操作inv-52)。

## 何时使用

| 使用此 skill | 使用其他 skill |
|---|---|
| 已完成 PR 的最终裁决（发布裁决评论；wrapper 批准+合并或请求变更） | 实现过程中开发侧的自行审查 → 使用 `MergeMill-dev` 步骤 8（pr-review） |
| Dispatcher 移交了标记为 `pending-review` 或 `reviewing` 的 PR | 草稿 PR 的手动部分审查 → 直接使用 `pr-review-toolkit` Agent |
| 运行 E2E 验证 + 检查验收标准 + 解决合并冲突 | 仅检查 CI 状态 → 直接使用 `gh pr checks` |

## 跨平台说明

此 skill 适用于任何支持 skills 的 IDE/CLI。浏览器自动化步骤使用 Chrome DevTools MCP——确保你的 IDE 已为此 MCP 服务器配置好了 E2E 验证。

### Hooks（可选）
如果你的 IDE 支持 hooks（Claude Code、Kiro CLI），`hooks/` 中的工作流强制执行 hooks 会提供自动门控检查。没有 hooks 的情况下，手动按每个步骤操作。

## 审查检查清单

验证以下所有项：

### 1. 流程合规性
- [ ] 设计画布存在于 `docs/designs/` 或 `docs/plans/`
- [ ] 分支遵循命名约定（`feat/`、`fix/`、`refactor/` 等）
- [ ] 测试用例记录在 `docs/test-cases/`
- [ ] PR 描述遵循模板（Summary、Design、Test Plan、Checklist 部分）
- [ ] PR 引用了 Issue（`Closes #N` 或 `Fixes #N`）

### 2. 代码质量
- [ ] 无安全问题（无凭据、无注入漏洞）
- [ ] TypeScript 类型正确（无 `any` 滥用）
- [ ] 错误处理恰当
- [ ] 代码遵循代码库中的现有模式
- [ ] 无明显性能退化

### 3. 测试
- [ ] 新功能有单元测试
- [ ] 新代码的单元测试覆盖率合理
- [ ] 如有 UI 变更，E2E 测试已更新
- [ ] 所有 CI 检查通过

### 4. 基础设施（如适用）
- [ ] 基础设施即代码变更是安全的
- [ ] 无意外资源删除
- [ ] IAM 权限遵循最小权限

### 5. 可选：Bot 审查者验证
- [ ] 如已配置的 bot 审查者发布了审查，验证其发现已被处理
- [ ] 所有 bot 审查线程已解决
- [ ] 如 bot 审查缺失且已配置，使用 `scripts/gh-as-user.sh` 触发它（见下方"触发 Bot 审查者"）

#### 触发 Bot 审查者

强制性 bot 集合由项目 `MergeMill.conf` 中的 `REVIEW_BOTS` 决定。空的 `REVIEW_BOTS` 完全跳过此节；否则触发每个已配置的 bot。

**必须使用 `scripts/gh-as-user.sh`。** 所有内置 bot（Amazon Q、Codex、Claude）拒绝由 GitHub App bot 账户发布的触发评论；wrapper 以真实用户身份发布。

内置 bot 触发器：

```bash
# 当 q ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr_number} --body "/q review"

# 当 codex ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr_number} --body "/codex review"

# 当 claude ∈ REVIEW_BOTS（注意：@claude，不是 /claude）:
bash scripts/gh-as-user.sh pr comment {pr_number} --body "@claude review"
```

对于通过 `REVIEW_BOTS_<NAME>_TRIGGER` 声明的自定义 bot，使用配置的触发器。

不要使用默认的 `gh pr comment` 来触发 bot 审查——它以 bot 身份认证。如果项目中 `scripts/gh-as-user.sh` 不可用，回退到 `gh pr comment` 并接受某些 bot 可能忽略触发器。

### 6. E2E 验证

> **如果已配置 E2E 验证，此节为强制步骤。** Wrapper 根据 `E2E_MODE` 注入两种流程之一。如果 prompt 中两者都没有出现，跳过此节。

**Browser 模式**（`E2E_MODE=browser`，用于 SaaS Web 应用）：
- [ ] 从 PR 评论中提取预览 URL
- [ ] 通过 Chrome DevTools MCP 成功导航到预览 URL
- [ ] 在预览环境中验证了测试用户登录
- [ ] 选择并执行了正常路径测试用例（见下方章节）
- [ ] 针对实时预览执行了功能测试用例
- [ ] 执行了回归测试（认证、导航、控制台错误）
- [ ] 截图已捕获、上传并作为证据链接
- [ ] E2E 验证报告以 PR 评论形式发布，附截图链接

**Command 模式**（`E2E_MODE=command`，用于后端流水线 / CLI / 库）：
- [ ] 预 hooks 已执行（如已配置）— 退出码 0
- [ ] 验证命令在超时内执行 — 退出码 0（或可恢复超时）
- [ ] 证据解析器生成了一个以 `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` 结尾的 markdown 块
- [ ] 证据块以 PR 评论形式发布
- [ ] Issue 正文中每个命名了可验证构件的验收标准都被证据块覆盖

## 合并冲突解决 — 强制的前置审查步骤

开始审查前，检查 PR 分支是否与 main 有合并冲突。如有，rebase 该分支使 PR 可合并。完整的 rebase 流程、冲突处理和失败协议请参考 **`references/merge-conflict-resolution.md`**。

快速检查：
```bash
MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
```
- **MERGEABLE** — 继续审查流程
- **CONFLICTING** — 按照参考文档中的 rebase 流程操作；这是一个**阻塞性发现**（FAIL）
- **UNKNOWN** — 等待并重试（最多 3 次）；如仍为 UNKNOWN，不要当作 MERGEABLE——将审查保持未最终定稿，留待下一 tick

> 此步骤是尽力而为的 prompt 指导；审查 **wrapper 在收集裁决后机械地执行同一规则**（可合并硬门控，INV-44）。即使你跳过此步骤，`CONFLICTING` 的 PR 也永远无法被批准，持续 `UNKNOWN` 的 PR 会被重新排队而非自动批准。

## 审查流程

1. **阅读 Issue** 以理解需求
2. **阅读所有 Issue 评论** 以检测需求变化（见下方"需求漂移检测"）
3. **彻底阅读 PR diff**（`gh pr diff <number>`）
4. **检查 CI 状态**（`gh pr checks <number>`）
5. **阅读文件** 以确认设计文档、测试用例等存在
6. **评估代码质量** 对照上述检查清单
7. **验证 bot 审查者发现**（如已配置——见检查清单第 5 节）
8. **选择正常路径测试用例** 基于 PR diff 分析（见下方）
9. **执行 E2E 验证**（如已配置——见下方流程）
10. **标记验收标准** — 对于每个已验证的标准，在 Issue 正文中标记其复选框（见"标记验收标准"）
11. **强制自检门控** — 在提交任何审查裁决之前执行 Findings->Decision Gate（见下方）

## 需求漂移检测 — 强制步骤

> **此步骤必须在阅读 PR diff 之前执行。需求可能在实现后通过仓库所有者或维护者的 Issue 评论发生变化。**

阅读 Issue 上的所有评论（不仅是正文），寻找：
- 范围变更（"remove"、"no longer"、"drop"、"don't support"、"instead of"）
- 原始 Issue 创建后新增的需求
- 仓库所有者的修正或澄清
- 对 dev agent 的明确指示，可能尚未反映在 PR 代码中

```bash
# 阅读所有 Issue 评论以检查需求变化
gh issue view <ISSUE_NUMBER> --repo <REPO> --json comments \
  -q '.comments[] | "\(.author.login) [\(.createdAt)]: \(.body[0:500])"'
```

如果发现 PR 代码 **未** 反映的任何需求变化：
- 这是一个 **[BLOCKING] 需求漂移** 发现
- PR 必须被退回给 dev，并附上关于变化内容的具体说明
- 引用改变需求的评论
- 列出需要更新的具体文件/代码

## 正常路径测试用例

正常路径测试用例是项目特定的。审查 Agent 基于以下因素选择用例：

1. 阅读 `docs/test-cases/` 目录以了解可用的测试用例文档
2. 分析 PR diff 以确定哪些区域发生了变化
3. 选择覆盖变更功能的最相关测试用例
4. 每次审查至少执行一个正常路径测试用例

如果没有测试用例文档，执行基本冒烟测试：
- 导航到应用根 URL
- 验证页面无错误加载
- 检查浏览器控制台是否有 JavaScript 错误

## E2E 验证流程

> **此节仅在已配置 E2E 验证时适用。** 审查 wrapper 脚本（`MergeMill-review.sh`）将根据项目 `MergeMill.conf` 中的 `E2E_MODE` 设置，在你的 prompt 中注入两种 E2E 流程之一：
>
> - **`E2E_MODE=browser`** — Chrome DevTools MCP UI 冒烟测试（登录、导航、截图）。适用于有每 PR 预览 URL 的 SaaS Web 应用。
> - **`E2E_MODE=command`** — 调用项目提供的验证命令，验证其证据输出。适用于后端流水线、CLI 工具、库、基础设施即代码或 ML 流水线。

如果 prompt 中两个块都没有出现，则项目已禁用 E2E（`E2E_MODE=none` 或未设置）。跳过此节。

### Browser 模式

完整的逐步 browser 模式流程（浏览器自动化、截图上传、测试执行、报告格式）请参考 **`references/e2e-verification.md`**。

关键步骤：
1. 验证预览 URL 可用
2. 打开浏览器并通过 Chrome DevTools MCP 导航
3. 使用测试用户凭据登录
4. 执行正常路径和功能测试用例
5. 运行回归检查（认证、导航、控制台错误）
6. 在 PR 上发布结构化 E2E 报告，附截图证据

### Command 模式

完整契约（项目侧脚本要求、证据块格式、退出码语义、上手示例）请参考 **`references/e2e-command-mode.md`**。

关键步骤：
1. 如配置则运行预 hooks（例如向每 PR stage 中写入测试数据）
2. 带超时运行验证命令
3. 检查退出码（0 = 通过；124 = 超时；其他 = 失败）
4. 运行证据解析器以提取结构化 markdown 块
5. 验证该块以 SHA 绑定的标记 `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` 结尾（SHA 是必需的，防止先前提交的过期证据复用评论）
6. 将证据块发布为 PR 评论
7. 基于退出码 + 证据-vs-AC 覆盖范围决定 PASS/FAIL

## 标记验收标准

在 E2E 验证过程中，每验证一个验收标准就在 Issue 正文中标记其复选框。

### 流程

1. 阅读 Issue 正文并识别 `## Acceptance Criteria` 部分
2. 对于每个标准：
   a. 通过 Chrome DevTools MCP、代码检查或 CI 检查结果验证它
   b. 如果**通过**，标记复选框：
      ```bash
      bash scripts/mark-issue-checkbox.sh <ISSUE_NUMBER> "<criterion text>"
      ```
   c. 如果**失败**，停止标记——记录失败并进入"审查发现"
3. 脚本使用 `gh`（通过 `GH_TOKEN_FILE` 获取活跃的 App token），因此编辑显示为配置的审查 bot

### 重要规则

- 仅在验证后标记标准——不要提前标记
- 如果任何标准失败，不要标记它——发布 "Review findings:" 代替
- 不要标记 Requirements（需求）复选框——那些是 dev agent 的
- 在批准 PR 之前，所有验收标准必须是已勾选状态（`- [x]`）

## Findings -> Decision Gate — 强制步骤

> **此门控不可协商。在提交任何 PR 审查（APPROVE 或 REQUEST_CHANGES）之前和在 Issue 上发布裁决评论之前，必须执行此自检。**

完整的门控流程（发现分类、阻塞 vs 非阻塞规则、自检问题、决策标准和输出格式）请参考 **`references/decision-gate.md`**。

硬性规则摘要：
- **任何阻塞性发现 -> 裁决必须是 FAIL** — 发布 `Review findings:`（wrapper 随后提交 `--request-changes`）。
- **零阻塞性发现 -> 裁决是 PASS** — 发布 `Review PASSED`（wrapper 随后提交 `--approve` 并在其门控后合并）。
- **没有中间地带** — 带有阻塞项的 `Review findings:` 评论和 `Review PASSED` 评论互斥。

将审查结果作为 Issue（而非 PR）的评论发布，**仅**通过确定性助手 `bash scripts/post-verdict.sh <issue> <pass|fail> <body-file> <agent-name> <session-id> [<model>]` — 不要为裁决使用裸的 `gh issue comment`（[INV-56](../../docs/pipeline/invariants.md)）。该助手保证标准的 "Review PASSED" / "Review findings:" 首行（wrapper 轮询此首行），并自行附加 `Review Session: \`<id>\`` + `Review Agent: <name>` 尾部标记，因此你不必手写。当提供可选的第 6 个 `<model>` 参数时，助手将其折叠到 agent 行中为 `Review Agent: <name> (model: <model>)`，使裁决评论记录产生该裁决的模型（[INV-60](../../docs/pipeline/invariants.md)）。请传递正文**文件**（而非 argv 字符串），以便带反引号/引号的多行 findings 正文不会被破坏；wrapper 在你的 prompt 中提供 `<id>`、`<name>` 和 `<model>`——直接传递它们。**你的唯一输出是裁决评论**——wrapper 执行 GitHub 原生 PR 操作（见下方）。

### 谁负责提交 GitHub 原生 PR 操作（INV-52）

> **审查 WRAPPER — 不是你 — 负责 GitHub 原生 PR 审查/合并操作。** 你发布裁决**评论**（通过 `post-verdict.sh`）；wrapper 读取它并执行操作。

- 在 **PASS** 时，wrapper 提交 `gh pr review --approve` 然后（除非 Issue 有 `no-auto-close`）提交 `gh pr merge`，**在**其机械的可合并硬门控（[INV-44](../../docs/pipeline/invariants.md)）和 `no-auto-close` 跳过合并检查**之后**。
- 在阻塞性 **FAIL** 时，wrapper 提交 `gh pr review --request-changes`，使 PR 的 `reviewDecision` 变为 `CHANGES_REQUESTED` — 对人类、分支保护和 dev-resume Agent 都是权威的（[INV-52](../../docs/pipeline/invariants.md)）。
- **你绝不能自己运行 `gh pr review --approve`、`gh pr review --request-changes`、`gh pr merge` 或 MCP merge 工具。** 这样做会与 wrapper 的门控竞争：自发批准+合并可能会合并可合并性仍为 `UNKNOWN`（[INV-44](../../docs/pipeline/invariants.md)）的 PR 或带有 `no-auto-close` 的 PR — 这正是促使 INV-52 的 PR #191 事件。Agent 发出任何 GitHub PR 审查或合并都是一个**缺陷**，而非捷径。

### 多 Agent 审查（当已配置时）

当项目将 `AGENT_REVIEW_AGENTS` 设为多于一个 CLI 时，多个审查 Agent **并行**运行，各自针对**同一 PR**，每个都是完全独立的审查者。如果你是其中之一：

- **独立**运行 Findings -> Decision Gate — 基于你自己的发现得出自己的 PASS/FAIL。不要试图与其他 Agent 协调或服从它们；你无法看到它们的裁决。
- 通过 `bash scripts/post-verdict.sh` 发布你自己的裁决，使用你分配的 agent 名称 + session id（两者都在你的 prompt 中）— 绝不要用裸的 `gh issue comment`（[INV-56](../../docs/pipeline/invariants.md)）。该助手根据你传递的参数写入你的 `Review Agent: <name>` 标识行，因此它始终正确；该行是 wrapper 在并行审查者中归属你的裁决的方式（[INV-40](../../docs/pipeline/invariants.md)）。
- Wrapper 以**一致通过**规则汇总所有 Agent 的裁决：仅当**每个**可用的 Agent 都通过时，wrapper 才批准+合并；任一 FAIL 都会使 wrapper 提交 `--request-changes` 并将 PR 退回给 dev。这反映了门控自身的"任何阻塞性发现 → FAIL"理念，应用于各 Agent 之间。如上所述，**任何 Agent 都不提交 GitHub 原生操作**——wrapper 在汇总后执行一次。

---

## 参考文档

详细流程请参考：
- **`references/merge-conflict-resolution.md`** -- 完整的 rebase 流程、冲突处理和失败协议
- **`references/e2e-verification.md`** -- 浏览器自动化步骤、截图上传、测试执行、E2E 报告格式（`E2E_MODE=browser`）
- **`references/e2e-command-mode.md`** -- 项目提供的验证命令契约、证据块格式、上手示例（`E2E_MODE=command`）
- **`references/decision-gate.md`** -- 发现分类、阻塞规则、决策标准和输出格式
