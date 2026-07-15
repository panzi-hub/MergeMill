---
name: create-issue
description: >
  Use when the user asks to create a GitHub issue, file a bug, request a feature,
  open a tracking issue, or break a feature into multiple sub-issues. Guides
  interactive issue drafting with structured templates, workspace-change
  attachment, dependency linking, and the optional `MergeMill` label for the
  automated dev pipeline.
---

# 创建 GitHub Issue

通过交互式澄清，根据用户描述创建结构良好的 GitHub Issue。

## 仓库检测

使用平台 CLI 从当前 git remote 检测仓库。示例：

```bash
# GitHub 通道 (CODE_HOST=github):
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')

# GitLab 通道 (CODE_HOST=gitlab):
REPO=$(glab repo view -F json | jq -r '.path_with_namespace')
```

两者均拆分为 `OWNER` 和 `REPO_NAME`（或在 GitLab 上为 `NAMESPACE` 和 `PROJECT`）。如检测失败，向用户询问目标仓库。

## 流程

### 步骤 1：理解请求

当用户描述功能或 Bug 时，通过澄清问题收集上下文。不要立即创建 Issue。

**对于功能，澄清：**
- 面向用户的目标是什么？（非实现细节）
- 验收标准是什么？（如何验证它是否正常工作）
- **对于每个验收标准，它是否可合并前验证？** 其证据能否在 PR 合并前从自主 dev/review Agent 可触及的表面获得——CI 作业、PR 预览 URL、staging 命令、本地复现？优先选择可合并前验证的 AC，并让作者**指明表面 + 预期证据**。如果某个标准*不可*合并前验证（需要部署/生产、真实用户、时间浸泡、外部审批、生产遥测或 bot 缺少的凭据），首先检查现有的 PR 预览/staging 路径是否已用相同输入覆盖了相同代码路径；如果确实无法合并前验证，则将其拆分为单独的**非阻塞、非 `MergeMill` 后续 Issue**（参见 **`references/ac-verification.md`**）。一个流水线无法在合并前满足的阻塞性 AC 是已知的无法终止的 dev↔review 循环的驱动因素。
- 是否有 UI/UX 影响？
- 与哪些现有功能相关？
- 优先级和范围约束

**对于 Bug，澄清：**
- 复现步骤
- 预期行为 vs 实际行为
- 环境（prod、staging、PR 预览）
- 严重性（阻塞、降级、外观）
- 任何错误消息或日志
- **对于修复的每个验收标准，它是否可合并前验证？** Bug 修复通常有多个 AC——分类**每一个**，而不仅仅是标题"回归测试在修复前失败、修复后通过"（这条默认是可合并前验证的——指明表面：CI `unit`/E2E 作业）。警惕将任何标准描述为*合并后/生产重放*（"通过部署流水线重放失败的批次来验证"）：如果现有 PR 预览/staging 路径已用相同输入锻炼了相同代码路径，将该标准指向该表面。若某标准确实只能在部署后确认，将其拆分为单独的**非阻塞、非 `MergeMill` 后续 Issue**（参见 **`references/ac-verification.md`**）。此按标准分类对 Bug 修复同样适用，与功能需求一样——无论 Issue 类型如何，流水线无法在合并前满足的阻塞性 AC 是已知的无法终止的 dev↔review 循环的驱动因素。（注意：Bug 的 `## Environment` 字段可合法地为 `prod`——那是*复现*环境，而非验收标准。）

每轮提出 2-3 个聚焦的问题。在有足够信息编写清晰的 Issue 后停止。

> 上述按 AC 的**可合并前验证**分类适用于**两种** Issue 类型——功能和 Bug 均适用。不要像对待功能一样，收集一个带有阻塞性仅生产环境验收标准的 Bug 报告。

### 步骤 2：起草 Issue

根据 Issue 类型使用适当的模板。完整模板内容见 **`references/issue-templates.md`**。

两种模板都包含以下必需部分：
- **Summary** / **Motivation**（功能）或 **Steps to Reproduce**（Bug）
- 带复选框的 **Requirements**（功能）或 **Expected/Actual Behavior**（Bug）
- **Testing Requirements**（强制 TDD 部分：测试用例文档、单元测试、E2E 测试）
- 带复选框的 **Acceptance Criteria**
- **Dependencies** 部分（Issue 排序）

### 步骤 3：检测并附加工作区变更

起草 Issue 后，检查工作区的本地变更，这些变更可能为自主 dev Agent 提供有用上下文。完整的检测、附加和清理流程见 **`references/workspace-changes.md`**。

摘要：
1. 运行 `git status --short` — 无变更则跳过
2. 汇总变更并请求用户确认
3. 根据 diff 大小选择策略：内联（< 500 行）、分支推送（>= 500 行）或文件列表回退
4. 向 Issue 正文添加 `## Pre-existing Changes` 部分
5. 附加后可选择清理本地变更

### 步骤 4：与用户确认

向用户展示 Issue 草稿：
1. 建议标题（简洁、具描述性）
2. 完整 Issue 正文（如适用，包含 Pre-existing Changes 部分）
3. 建议的标签
4. 是否添加 `MergeMill` 标签

使用 AskUserQuestion 确认：
- "此 Issue 看起来正确吗？是否创建？"
- 询问 MergeMill 标签：AI 是否应自动处理此 Issue

**建议性可合并前验证自检**（你是 linter——无运行时脚本）：对草稿的 **AC 复选框行**（`## Acceptance Criteria` 下的 `- [ ]` 行，而非其他字段——这避免了 Bug 模板的 `## Environment` 字段的误报，其 `Stage:` 值可合法地为 `prod`）进行自检，寻找表示不可合并前验证 AC 的措辞：
`post-merge`、`after merge`、`in production`、**以及长尾**——`live users`、`soak`、`rollout`、`approver`、`prod telemetry`、`manual smoke`。如果**阻塞性** AC 匹配且没有配对的后续 Issue 拆分，**警告作者（建议性，非阻塞）** 并按 **`references/ac-verification.md`** §3 提供拆分（创建非阻塞、非 `MergeMill` 的后续 Issue；在 `## Out of Scope` 下引用，绝对不在 `## Dependencies` 下）。不要在匹配时硬性拒绝草稿。

### 步骤 5：创建 Issue

使用 GitHub MCP 工具或 `gh` CLI 创建 Issue：
- `title`：确认的标题
- `body`：确认的正文
- `labels`：适当的标签（见下方标签指南）

向用户报告创建的 Issue URL。

**如果分支推送被推迟（大 diff 策略）：**

Issue 创建且 Issue 编号已知后：
1. 使用实际 Issue 编号执行步骤 3 的分支推送命令
2. 更新 Issue 正文以包含分支引用部分

## 标签指南

| 标签 | 何时使用 |
|-------|-------------|
| `bug` | Bug 报告 |
| `enhancement` | 功能请求 |
| `MergeMill` | 用户确认 AI 应自动处理 dev/test/review/merge |
| `no-auto-close` | 与 `MergeMill` 搭配——AI 处理 dev/test/review 但在合并前停止，需手动批准 |
| `documentation` | 纯文档变更 |
| `good first issue` | 简单、范围明确的任务 |

## MergeMill 标签决策

起草 Issue 后，明确询问用户是否添加 `MergeMill` 标签。

提供何时适合使用 `MergeMill` 的指导：
- **适合**：范围明确、验收标准清晰、遵循现有模式、无不明确的设计决策
- **不适合**：需要重大架构决策、开发过程中需要用户输入、涉及敏感基础设施变更、探索性/研究性任务

将问题表述为：
> "此 Issue 是否应由自主开发流水线处理？AI 将自动开发、测试、审查和合并变更。对于定义明确、验收标准清晰的任务最有效。"

**如果用户选择 `MergeMill`，也询问 `no-auto-close`：**

> "此 Issue 是否也应带有 `no-auto-close` 标签？有了此标签，AI 将处理开发、测试和审查，但会**在合并前停止**——你将收到通知以做出最终合并决策。推荐用于敏感基础设施变更、需要产品签收的功能或实验性工作。"

**标签交互摘要：**
- 仅 `MergeMill` = AI 处理 dev/test/review **并**在通过后自动合并
- `MergeMill` + `no-auto-close` = AI 处理 dev/test/review 但**在合并前停止**，通知所有者手动批准

## 编写指南

- **标题**：以动词开头，保持具体。"Add pagination to plans list page" 而非 "Plans page improvement"
- **正文**：为能访问完整代码库但无此对话口头上下文的 AI 开发者编写
- **验收标准**：必须可客观验证，不可主观
- **AC 验证表面**：对于每个验收标准，将其分类为**可合并前验证**（证据可在合并前获得——**指明表面**：CI 作业、PR 预览 URL、staging 命令或本地复现——加上预期证据）vs **不可合并前验证**（需要部署/生产、真实用户、时间浸泡、外部审批、生产遥测或 bot 缺少的凭据）。优先前者，始终**指明表面 + 预期证据**而非仅断言结果。确实不可合并前验证的标准应放入单独的**非阻塞、非 `MergeMill` 后续 Issue**（在 `## Out of Scope` 下引用，绝不在 `## Dependencies` 下）——将其保留为阻塞性 AC 是已知的无法终止的 dev↔review 循环的驱动因素。完整标准、复用现有预览指导、拆分流程和实际示例：**`references/ac-verification.md`**。
- **范围**：优先小范围、聚焦的 Issue，而非大型多部分 Issue
- **引用**：适当时链接到相关 Issue、PRD 部分或代码路径
- **依赖项**：`## Dependencies` 部分必须**仅**包含在此 Issue 开始前必须先关闭/合并的 Issue。不要包括：引为上下文的父 epic、此 Issue 解锁的 Issue 或正文其他部分提到的 `#NNN` 引用。自主 dispatcher 按字面解析此部分——任何开放状态的列表项引用会导致此 Issue 被静默跳过，直到该引用关闭/合并。解析范围：**仅列表项行**（以 `-`、`*` 或 `1.` 开头的行）；`## Dependencies` 和下一个 `## ` 之间的正文和引用块被忽略。在列表项上，`#N`（同仓库）和 `owner/repo#N`（跨仓库）两种引用形式均被识别。如果没有阻塞项，精确写作 `None`。按依赖顺序创建 Issue，使编写后置 Issue 时前置 Issue 编号已知。
- **测试需求**：始终包含"Testing Requirements"部分。Dev Agent 遵循项目的 TDD 工作流，但据观察，当 Issue 未明确要求时，它会跳过 E2E 测试或测试用例文档。明确说明：
  - 每种测试类型必须覆盖的关键场景（2-4 个要点）
  - 对于 Bug：回归测试必须在修复前失败、修复后通过

## 多 Issue 创建

将大型功能拆分为多个 Issue 时：

1. **按依赖顺序创建 Issue** — 先创建无依赖的 Issue，然后是依赖它们的 Issue。这确保编写依赖引用时 Issue 编号已知。
2. **在每个 Issue 正文中填充 `## Dependencies` 部分**，使用 `#N`（同仓库）或 `owner/repo#N`（跨仓库）列表项链接，仅链接**直接阻塞**该 Issue 的 Issue。不要引用父 epic、上下文 Issue 或此 Issue 解锁的 Issue——dispatcher 将该部分中的每个列表项引用视为硬阻塞。正文或引用块中的引用被忽略。
3. **使用一致的命名方案** — 标题前缀项目/功能名以便过滤（如 "MyProject: Add DynamoDB infrastructure"）。
4. **交叉引用计划** — 如存在实现计划，将每个 Issue 链接到相关的计划任务/块。
5. **Dispatcher 跳过被阻塞的 Issue** — `## Dependencies` 部分中有开放依赖项的 Issue 会被自主 dispatcher 忽略，直到所有依赖项解决（已关闭/合并）。

---

## 参考文档

详细内容请参考：
- **`references/issue-templates.md`** -- 完整的功能和 Bug Issue 模板，包含所有必需部分
- **`references/ac-verification.md`** -- 可合并前验证 vs 不可合并前验证 AC 分类标准、复用现有预览指导、拆分到非阻塞后续 Issue 的流程、`no-auto-close` 说明和两个实例（防止循环）
- **`references/workspace-changes.md`** -- 工作区变更检测、附加策略和清理流程的完整说明
