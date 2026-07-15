---
name: MergeMill-dev
description: >
  Use to develop a feature or bug fix end-to-end through a TDD git-worktree
  workflow — interactively (developer-led) or unattended (MergeMill-mode,
  driven by the dispatcher). Triggers on phrases like "implement issue #N",
  "fix this bug", "add a feature", "create a worktree", "write test cases",
  "push and open a PR", "check CI", "address review comments", "resolve
  review threads", "/q review", "/codex review", "implement this autonomously",
  or any partial step in the design → worktree → tests → implement → verify →
  review → PR → CI → E2E lifecycle. Interactive mode asks for decisions;
  MergeMill mode makes decisions per MergeMill-mode.md and posts progress
  comments to the GitHub issue.
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-push-to-main.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-commit-outside-worktree.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-design-canvas.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-code-simplifier.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-pr-review.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-unit-tests.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/warn-skip-verification.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-rebase-before-push.sh"
          timeout: 10
    - matcher: "Write"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-test-plan.sh"
          timeout: 5
    - matcher: "Edit"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-test-plan.sh"
          timeout: 5
  PostToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-action-clear.sh commit code-simplifier"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-action-clear.sh commit design-canvas"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-action-clear.sh push pr-review"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-push.sh"
          timeout: 30
  Stop:
    - hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/verify-completion.sh"
          timeout: 10
---

# TDD 开发工作流

一套完整的开发工作流，强制执行测试驱动开发、git worktree 隔离、代码审查、CI 验证和 E2E 测试。支持两种模式：交互式（默认）用于人工引导的会话，自主模式用于完全无人值守的 GitHub Issue 实现。

> **不可协商的规则 — 每个标记为 MANDATORY（强制）的步骤必须执行。** 不要跳过、延迟或询问用户是否运行这些步骤。将它们作为工作流的一部分自动执行。这包括创建 PR、等待 CI、运行 E2E 测试和处理审查者的发现。

---

## 模式检测

### 交互式模式（默认）

当有开发者参与时使用。工作流：
- 在进入实现阶段前请求用户批准设计
- 展示设计画布并等待反馈
- 在关键决策点暂停等待用户输入
- 报告最终状态并让用户决定何时合并

### 自主模式

在 `scripts/MergeMill-dev.sh` wrapper 内运行时触发。工作流：
- 自主做出所有决策（见下方"决策指南"）
- 将进度评论发布到 GitHub Issue，而不是向用户提问
- 创建设计文档但跳过交互式审批
- 验证后停止——不合并（审查 Agent 负责合并）
- 随工作推进标记 Issue 正文中的需求复选框

---

## 跨平台说明

此 skill 适用于支持 skills.sh 的 IDE。将本文档中的通用动词映射到你的 IDE 工具（Claude Code 的 Bash → Cursor 中的 terminal 等）。Claude Code 和 Kiro CLI 支持基于 hook 的强制执行；在 Cursor / Windsurf 中，手动按每个步骤操作——规范相同。

完整的 IDE 表格 + 动词到工具的映射见 [`references/cross-platform.md`](references/cross-platform.md)。

---

## 开发工作流概览

所有功能开发和 Bug 修复均按此工作流进行：

```
步骤 1:  设计画布（Pencil MCP，如可用）
步骤 2:  创建 Git Worktree（强制）
步骤 3:  编写测试用例（TDD）
步骤 4:  实现变更
步骤 5:  本地验证
步骤 6:  代码简化
步骤 7:  Commit 和创建 PR         -- 强制
步骤 8:  PR 审查 Agent            -- 强制
步骤 9:  等待所有 CI 检查完成      -- 强制
步骤 10: 处理审查 Bot 的发现       -- 强制
步骤 11: 迭代直到无新发现
步骤 12: E2E 测试 & 准备合并       -- 强制
步骤 13: 清理 Worktree
```

---

## 步骤 1：设计画布

为新的 UI 工作、面向用户的功能、架构决策和复杂数据流创建设计画布。不改变行为的琐碎修复或重构可跳过。

- 有 Pencil MCP 的 IDE：创建 `docs/designs/<feature>.pen`。
- 无 Pencil MCP 的 IDE：创建 `docs/designs/<feature>.md`。

完整的 Pencil MCP 调用序列、markdown 画布模板和每种模式（交互式 vs 自主）的审批门控见 [`references/design-canvas.md`](references/design-canvas.md)。

---

## 步骤 2：创建 Git Worktree（强制）

**每次变更都必须在隔离的 git worktree 中开发。绝不要直接在主工作区上开发。**

> 由 `block-commit-outside-worktree.sh` hook 强制执行（如已安装 hooks）。worktree 外的 commit 会被自动阻止。直接 push 到 main 被 `block-push-to-main.sh` 阻止。

### 为什么需要 Worktree？

- **隔离**：每个功能/修复拥有独立目录，防止交叉污染
- **并行工作**：多个功能可同时进行
- **干净的主工作区**：主 checkout 保持在 `main`，随时可用于快速检查
- **安全回滚**：丢弃 worktree 而不影响主工作区

### Worktree 创建流程

在终端中执行：

```bash
# 1. 根据变更类型确定分支名
#    feat/<name>, fix/<name>, refactor/<name> 等
BRANCH_NAME="feat/my-feature"

# 2. 从 main 创建带有新分支的 worktree
git worktree add .worktrees/$BRANCH_NAME -b $BRANCH_NAME

# 3. 进入 worktree
cd .worktrees/$BRANCH_NAME

# 4. 安装依赖（使用你项目的包管理器）
npm install  # 或: bun install, yarn install, pnpm install

# 5. 验证干净的基准
npm run build && npm test
```

### 目录约定

| 项目 | 值 |
|------|-------|
| Worktree 根目录 | `.worktrees/`（项目本地，已 gitignore） |
| 路径模式 | `.worktrees/<branch-name>` |
| 示例 | `.worktrees/feat/user-authentication` |

### 安全检查

创建任何 worktree 前，确认 `.worktrees/` 在 `.gitignore` 中：

```bash
git check-ignore -q .worktrees 2>/dev/null || echo "WARNING: .worktrees not in .gitignore!"
```

### 后续所有步骤在 Worktree 内执行

创建 worktree 后，**所有开发命令**（test、lint、build、commit、push）均在 worktree 目录内执行。在清理之前不触碰主工作区。

---

## 步骤 3：编写测试用例（TDD）

在编写任何实现代码之前：

1. 阅读设计画布和需求
2. 识别所有用户场景、边界情况和错误处理路径
3. 创建或编辑测试用例文档：`docs/test-cases/<feature>.md`
   - 列出所有测试场景（正常路径、边界情况、错误处理）
   - 分配测试 ID（例如 `TC-AUTH-001`）
   - 定义预期结果和验收标准
4. 创建单元测试骨架
5. 创建 E2E 测试用例（如适用）

---

## 步骤 4：实现变更

- 按照测试用例编写代码（在 worktree 内）
- 为新功能编写新的单元测试
- 如行为有变化则更新已有测试
- 确保实现覆盖所有测试场景

---

## 步骤 5：本地验证

在终端中执行：

```bash
timeout 1800 bash -lc 'npm run build && npm run test' > /tmp/verify.log 2>&1; rc=$?; [ $rc -ne 0 ] && tail -100 /tmp/verify.log; exit $rc
```

修复任何失败再继续。如适用，在本地部署并验证。

### 如何运行耗时较长的验证

将项目的构建/测试套件作为一个**带充裕超时的同步命令**运行——绝不要将其后台运行并在多个轮次中轮询：

1. **带显式充裕超时同步运行顶层套件命令。** 一次阻塞调用（或几次连续的阻塞调用，例如先构建后测试），在当前轮次内返回完整结果。捕获输出并仅在失败时回放尾部：
   ```bash
   timeout 1800 bash -lc '<your project'\''s build & test command>' > /tmp/verify.log 2>&1; rc=$?; [ $rc -ne 0 ] && tail -100 /tmp/verify.log; exit $rc
   ```
2. **绝不要将顶层套件后台运行**（不使用 `&`，不使用后台任务模式——无论宿主 CLI 怎么称呼，例如 `run_in_background`）然后在各 Agent 轮次中轮询其日志。每次轮询是一次完整的模型往返；累计的轮询成本可能超过套件自身运行时长的数量级。
3. 如果工具的最大超时确实无法覆盖套件，按目录/前缀拆分为几个连续的同步调用——仍不要轮询。
4. 如项目提供了并行运行器，优先使用该类工具。

**范围**：禁止的是将顶层验证命令后台运行。内部创建子进程或本地服务器的测试/脚本不受影响，真正的事件驱动等待也不受影响（步骤 9 的 CI 检查、步骤 10-11 的 bot 审查）。

---

## 步骤 6：代码简化

1. 如 IDE 支持 subagent，使用 subagent（例如 `code-simplifier:code-simplifier`），否则手动审查代码中的不必要复杂性。
2. 处理简化建议。
3. 标记完成（如已安装 hooks）：
   ```bash
   hooks/state-manager.sh mark code-simplifier
   ```

---

## 步骤 7：Commit 和创建 PR（强制）

### Commit

在终端中执行：

```bash
git add <files>
git commit -m "type(scope): description"
git push -u origin <branch-name>
```

### 创建 PR

> **GitHub 通道（`CODE_HOST=github`）** — 以下示例使用 GitHub CLI。在 GitLab 通道上，wrapper 通过 `chp_create_pr` provider 接口打开合并请求；Agent 不要手写平台 API 调用。如果必须直接调用 CLI，替换为 `glab mr create --title … --description …`。

```bash
gh pr create --title "type(scope): description" --body "$(cat <<'EOF'
## Summary
<1-3 bullet points describing the change>

## Design
- [ ] Design canvas created (`docs/designs/<feature>.pen`)
- [ ] Design approved

## Test Plan
- [ ] Test cases documented (`docs/test-cases/<feature>.md`)
- [ ] Build passes (`npm run build`)
- [ ] Unit tests pass (`npm run test`)
- [ ] CI checks pass
- [ ] Code simplification review passed
- [ ] PR review agent review passed
- [ ] Reviewer bot findings addressed (no new findings)
- [ ] E2E tests pass

## Checklist
- [ ] New unit tests written for new functionality
- [ ] E2E test cases updated if needed
- [ ] Documentation updated if needed
EOF
)"
```

### 更新 PR 检查清单

完成每个步骤后，更新 PR/MR 描述。获取当前正文，将项目标记为 `[x]`，然后写回。

```bash
# GitHub 通道 (CODE_HOST=github):
gh pr view {pr_number} --json body --jq '.body' > /tmp/pr_body.md
# 编辑检查清单（标记项目为 [x]）
gh pr edit {pr_number} --body "$(cat /tmp/pr_body.md)"

# GitLab 通道 (CODE_HOST=gitlab):
glab mr view {mr_number} -F json | jq -r .description > /tmp/pr_body.md
# 编辑检查清单（标记项目为 [x]）
glab mr update {mr_number} --description "$(cat /tmp/pr_body.md)"
```

---

## 步骤 8：PR 审查 Agent（强制）

1. 如 IDE 支持 subagent，使用 subagent（例如 `/pr-review-toolkit:review-pr`），否则根据 PR diff 自行审查。
2. 按严重性处理发现：
   - Critical/Severe（严重）：必须修复
   - High（高）：必须修复
   - Medium（中）：应当修复
   - Low（低）：可选
3. 标记完成（如已安装 hooks）：
   ```bash
   hooks/state-manager.sh mark pr-review
   ```

---

## 步骤 9：等待所有 CI 检查完成（强制 -- 不可跳过）

在终端中执行。GitHub 通道使用 GitHub CLI；GitLab 通道使用 `glab`（或流水线的 `chp_ci_status` 接口，它将两个平台统一为 `green`/`pending`/`failed`/`none`）。

```bash
# GitHub 通道 (CODE_HOST=github):
gh pr checks {pr_number} --watch --interval 30

# GitLab 通道 (CODE_HOST=gitlab):
glab ci status {mr_number}   # 较新版本的 glab 可加 `--live` 持续更新
```

所有检查都必须通过：Lint、单元测试、构建、部署预览、E2E 测试。

如果任何检查失败：分析日志、修复、推送、重新观察。在所有检查都显示"pass"之前不要继续。

### 需要监控的检查

| 检查 | 描述 | 失败时的操作 |
|-------|-------------|------------------|
| CI / build-and-test | 构建 + 单元测试 | 修复代码或更新快照 |
| Security Scan | SAST、npm audit | 修复安全问题 |
| 已配置的 `REVIEW_BOTS` | 每项目的 bot 审查者（`q`、`codex`、`claude`、自定义） | 处理发现，通过 `gh-as-user.sh` 重新触发 |
| 其他审查 bot | 各种检查 | 处理发现，按各 bot 文档重新触发 |

---

## 步骤 10：处理审查 Bot 的发现（`REVIEW_BOTS` 非空时强制）

如果项目的 `MergeMill.conf` 声明了 `REVIEW_BOTS`（以空格分隔的简称，如 `q codex claude`），每个已配置 bot 的发现都是强制性的：要么修复代码，要么回复说明设计决策（误报）。然后回复讨论线程、解决它，并重新触发 bot。

如果 `REVIEW_BOTS=""`（或变量未设置），此步骤**完全跳过**——项目不强制执行任何外部 bot 审查。

内置 bot 触发器：

| 简称 | 触发短语 | Bot 登录名（过滤 `user.login`） |
|---|---|---|
| `q` | `/q review` | `amazon-q-developer[bot]` |
| `codex` | `/codex review` | `codex[bot]` |
| `claude` | `@claude review` | `claude[bot]` |

> **使用 `scripts/gh-as-user.sh` 重新触发 bot 审查。** 所有三个内置 bot 拒绝由 GitHub App bot 账户发布的触发评论；wrapper 以真实用户身份发布。

完整的重新触发命令、回复模式和线程解决语义见 [`references/review-threads.md`](references/review-threads.md)。

---

## 步骤 11：迭代直到无新发现

**重复执行直到审查 bot 不再发现问题：**

1. 处理发现（修复代码或说明设计）
2. 回复每条评论线程
3. 解决所有线程
4. 触发审查命令（`/q review`、`/codex review` 等）
5. 等待 60-90 秒
6. 检查是否有新发现
7. **如有新发现：从步骤 1 重复**
8. **仅在没有新的阳性发现时才继续**

---

## 步骤 12：E2E 测试 & 准备合并（强制 -- 不可跳过）

1. 针对已部署的预览环境运行 E2E 测试（所有测试必须通过；跳过的 Agent 依赖测试可接受）
2. 标记完成（如已安装 hooks）：
   ```bash
   hooks/state-manager.sh mark e2e-tests
   ```
3. 更新 PR 检查清单显示所有项目已完成
4. **到此为止**：向用户报告状态（交互式模式）或在 Issue 上发布摘要评论（自主模式）。在自主模式下，通过项目自带的 wrapper 发布评论，以便评论归属于配置的身份（app 模式下为 bot，token 模式下为宿主用户）：
   ```bash
   # GitHub 通道 (CODE_HOST=github):
   bash scripts/gh issue comment <ISSUE_NUMBER> --body "<summary>"
   ```
   不要直接调用裸的 `gh issue comment`——Agent 的 Bash 工具无法可靠地通过 wrapper 注入的 PATH 解析 `gh`，因此裸调用会落到系统 `gh` 并以宿主操作者的身份发布。完整规则见 [`references/MergeMill-mode.md`](references/MergeMill-mode.md#posting-issuepr-comments)。

   > **GitLab 通道（`CODE_HOST=gitlab`）** — 同样原则：wrapper/`itp_post_comment` provider 接口以配置的身份发布评论。Agent 不要手写 `glab issue note` 或 REST API；接口负责认证和身份。
5. 用户或审查 Agent 决定何时合并

---

## 步骤 13：清理 Worktree

PR 合并或关闭后，在终端中执行：

```bash
# 返回主工作区
cd $(git rev-parse --show-toplevel)

# 移除 worktree
git worktree remove .worktrees/<branch-name>

# 清理过期的 worktree 引用
git worktree prune
```

---

## 参考文档

详细的命令和约定请参考：
- **`references/commit-conventions.md`** -- 分支命名和 commit 消息约定
- **`references/review-commands.md`** -- 完整的 `gh` CLI 和 GraphQL 命令参考
- **`references/review-threads.md`** -- 审查线程管理、响应模式和快速参考命令
- **`references/MergeMill-mode.md`** -- 决策制定、恢复感知、需求跟踪、已有变更、bot 审查集成和错误恢复（仅自主模式）
