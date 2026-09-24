# Issue 模板

## 功能模板

```markdown
## Summary
<1-2 sentence description of the feature>

## Motivation
<Why this feature is needed, what problem it solves>

## Requirements
- [ ] <Requirement 1>
- [ ] <Requirement 2>
- [ ] <Requirement 3>

## Testing Requirements

> **强制**：Dev Agent 必须遵循项目的 TDD 工作流。
> 此节指定预期的测试产出物。所有列出的项目都是 PR 批准的要求。

### Test Cases Document
- [ ] 创建包含所有测试场景的测试用例文档（ID 格式：`TC-<FEATURE>-NNN`）
- <列出文档必须覆盖的 2-4 个关键测试场景>

### Unit Tests
- [ ] 为新功能创建单元测试
- [ ] 覆盖率目标：>80%
- <列出需要测试的具体单元：API 处理器、工具函数、数据转换等>

### E2E Tests
- [ ] 创建覆盖关键用户流程的 E2E 测试
- <列出 E2E 测试必须覆盖的 2-4 个关键用户流程，例如：>
- [ ] <正常路径：用户执行 X 并看到 Y>
- [ ] <边界情况：空状态 / 错误状态 / 未授权访问>

## Acceptance Criteria

> **分类每个标准：是否可合并前验证？** 可合并前验证 =
> 证据可在合并前获得 — **指明验证表面**（CI 作业、PR 预览 URL、
> staging 命令或本地复现）**+ 预期证据**。不可合并前
> 验证 = 需要部署/生产、真实用户、时间浸泡、外部审批、生产
> 遥测或 bot 缺少的凭据。优先选择可合并前验证的标准。确实
> 不可合并前验证的标准应放入单独的**非阻塞、
> 非 `MergeMill` 后续 Issue**（在 `## Out of Scope` 下引用，**绝不**
> 在 `## Dependencies` 下）— 自主流水线无法在合并前满足的阻塞性 AC 是
> 已知的无法终止的 dev↔review 循环的驱动因素。见 `references/ac-verification.md`。

- [ ] <标准 1 — 可合并前验证；指明表面 + 预期证据>
- [ ] <标准 2>

## Dependencies
<!--
  重要：仅列出在此 Issue 开始前必须先关闭/合并的 Issue。
  不要列出：
    - 此 Issue 解锁的 Issue（即依赖于此 Issue 的 Issue）
    - 引为上下文的父 epic 或元跟踪器
    - 正文其他部分提到的 Issue

  自主 dispatcher 按字面解析此部分 — 任何仍处于开放状态的列表项引用
  会导致此 Issue 被静默跳过，直到该引用关闭/合并。解析有两个阶段：
    1. 仅扫描列表项行（以 `-`、`*` 或 `1.` 开头的行）。
       `## Dependencies` 和下一个 `## ` 之间的正文、引用块（`> ...`）
       和标题被忽略 — 它们不会阻塞调度。
    2. 在每个列表项上，dispatcher 识别两种引用形式：
         - `#N`             — 同仓库 Issue/PR（本仓库）
         - `owner/repo#N`   — 跨仓库 Issue/PR（相对于 owner/repo 解析）
       任一形式的开放引用均阻塞此 Issue。

  从下方两种形式中选择一个（删除另一个）：
    - 如果没有阻塞性前置条件，精确写：None
    - 否则，每个阻塞项一行：
        - #N（必须先合并，因为 <具体原因>）
        - owner/repo#N（跨仓库阻塞项，因为 <具体原因>）
-->
- None

## Design Considerations
<架构说明、API 变更、数据模型影响 — 如适用>

## Out of Scope
<明确列出此 Issue 不覆盖的内容>
```

## Bug 模板

```markdown
## Summary
<1-sentence description of the bug>

## Steps to Reproduce
1. <Step 1>
2. <Step 2>
3. <Step 3>

## Expected Behavior
<What should happen>

## Actual Behavior
<What actually happens>

## Environment
- Stage: <prod / staging / PR preview>
- Browser: <if applicable>
- Relevant logs: <error messages, log links>

## Severity
<Blocking / Degraded / Cosmetic>

## Possible Cause
<If known, suggest root cause or area of code>

## Testing Requirements

> **强制**：Dev Agent 必须创建防止此 Bug 回归的测试。

### Unit Tests
- [ ] 添加在修复前失败、修复后通过的回归测试
- [ ] 测试必须覆盖精确的复现场景

### E2E Tests（如果与 UI 相关）
- [ ] 添加或更新 E2E 测试以覆盖修复后的行为
- [ ] 端到端测试上述精确的复现步骤

## Acceptance Criteria

> **分类每个标准：是否可合并前验证？** 可合并前验证 =
> 证据可在合并前获得 — **指明验证表面**（CI 作业、PR 预览 URL、
> staging 命令或本地复现）**+ 预期证据**。不可合并前
> 验证 = 需要部署/生产、真实用户、时间浸泡、外部审批、生产
> 遥测或 bot 缺少的凭据。优先选择可合并前验证的标准。确实
> 不可合并前验证的标准应放入单独的**非阻塞、
> 非 `MergeMill` 后续 Issue**（在 `## Out of Scope` 下引用，**绝不**
> 在 `## Dependencies` 下）— 自主流水线无法在合并前满足的阻塞性 AC 是
> 已知的无法终止的 dev↔review 循环的驱动因素。见 `references/ac-verification.md`。
>
> 注意：上方的 Bug `## Environment` 字段可合法地为 `prod` — 那是
> 复现环境，而非验收标准；分类适用于下方的 AC 复选框行。

- [ ] <标准 1 — 可合并前验证；例如回归测试在修复前失败、
      修复后通过，在 CI `unit` 作业中绿色（指明表面）>
- [ ] <标准 2>

## Dependencies
<!--
  仅列出在此 Bug 修复开始前必须先关闭/合并的 Issue。
  自主 dispatcher 按字面解析此部分 — 任何开放状态的列表项引用
  （`#N` 同仓库或 `owner/repo#N` 跨仓库）静默阻塞调度，直到它
  关闭/合并。正文和引用块被忽略。如果没有阻塞项，精确写：None。
-->
- None

## Out of Scope
<!-- `## Acceptance Criteria` 注释指示你拆分出的任何确实的合并后/
     仅生产环境验证的非阻塞归宿。在此处（正文）引用后续 Issue —
     绝不在 `## Dependencies` 下（那会硬阻塞修复）。
     也列出此 Bug 修复故意不覆盖的任何内容。 -->
<Explicitly list what this fix does NOT cover, incl. any post-deploy follow-up issue (non-blocking)>
```
