# MergeMill — 自主开发流水线

## 项目概览

MergeMill 是一个完全自动化的开发流水线，将 GitHub Issue 转化为已合并的 Pull Request。Dispatcher 按 cron 定时扫描带 `MergeMill` 标签的 Issue，调度 Dev Agent 在隔离 worktree 中通过 TDD 实现功能，再移交 Review Agent 进行代码审查和自动合并——全程无人干预。

---

## 技术栈

| 组件 | 选择 | 理由 |
|-----------|--------|----------|
| 核心语言 | Bash | 调度器和 wrapper 脚本 |
| Agent CLI | Claude Code / Codex / Kiro / opencode / agy | AI 编程 Agent，可插拔 |
| 版本控制 | Git + GitHub | Issue 跟踪、PR、CI/CD |
| 测试框架 | Shell 单元测试 (自定义) | 针对 bash 脚本的 grep 断言测试 |
| CI/CD | GitHub Actions | Hermetic + Live Smoke 双层 CI |

---

## 开发工作流（TDD + Agent 辅助）

此项目通过 Agent hooks 强制执行严格的 TDD 开发工作流。该工作流适用于所有支持的编程 Agent（Claude Code、Kiro CLI、Cursor、Windsurf、Antigravity 等）。

### 强制规则（Hooks 执行）

1. **所有代码变更必须在 Git Worktree 中开发** — `.worktrees/` 外的 commit 会被自动阻止
2. **所有变更必须通过 Pull Request** — 直接 push 到 `main` 会被自动阻止
3. **push 前必须 rebase** — 落后于 `origin/main` 的分支 push 会被阻止
4. **commit 前必须进行代码审查** — commit 前必须运行 code-simplifier（仅 Claude Code）
5. **push 前必须进行 PR 审查** — push 前必须运行 pr-review agent（仅 Claude Code）

> Claude Code 和 Kiro CLI 支持 Hooks。对于不支持 hook 的 Agent（Cursor、Windsurf 等），需手动按每个步骤操作——规范相同。

> ⚠️ **此仓库是自托管的——绝不要在主工作目录中编辑文件；始终使用 worktree。** 此 `panzi-hub/MergeMill` 的 checkout 被运行在同一台机器上的自主 dispatcher 消费：其 `scripts/` 符号链接解析到此仓库自身的 `skills/MergeMill-dispatcher/scripts/` 树中，因此 dispatcher 通过 `scripts/MergeMill-{dev,review}.sh` 执行的就是这些文件。**主工作目录中的任何未提交变更都会对每次被调度的 dev/review wrapper 生效。** 一个未完成的编辑可能中途崩溃 wrapper——例如不完整的 per-side `AGENT_REVIEW_CMD` 重新绑定会导致 review wrapper 以 `AGENT_REVIEW_CMD: unbound variable` 中止，使 Issue 卡在 `reviewing` 状态且无裁决、无法重新调度。
>
> 因此：
> - **所有工作必须在 git worktree 中进行** — `git worktree add .worktrees/<branch> -b <branch>`，在那里编辑，从那里提 PR。
> - **绝不在主工作目录中修改、暂存或留下任何被跟踪文件的脏状态。** 对主工作目录唯一允许的直接写入是已提交状态的同步（`git pull` / `git reset --hard origin/main`）。
> - 这比通用的"在 worktree 中开发"规则（上述 #1）更严格：此处它保护的是**运行中的 dispatcher**，而不仅仅是 commit 规范。

### 流水线文档权威性

`docs/pipeline/*.md`（`state-machine.md`、`invariants.md`、`dispatcher-flow.md`、`dev-agent-flow.md`、`review-agent-flow.md`、`handoffs.md`）是 dispatcher / dev wrapper / review wrapper 子系统的**规范**。对这些 wrapper 的任何代码变更必须在**同一 PR 中**更新相应的流水线文档。

当代码与文档不一致时，**文档是权威的**——偏离已记录不变量的代码是一个 Bug，而非文档过时。新的不变量在 `invariants.md` 中获得新的 `INV-NN` 条目；新的标签转换更新 `state-machine.md` 的 mermaid 图和"无效组合"部分。PR 审查者会拒绝触及流水线但未附带匹配文档更新的 PR。

此规则范围限定在 dispatcher/wrapper 子系统；仓库其余部分遵循普通的文档保持更新规范。

### 工作流概要

```
设计 → Worktree → 测试 → 实现 → 验证 → 审查 → PR → CI → E2E → 合并
```

完整的逐步工作流定义在 **MergeMill-dev** skill 中。使用方式：

```bash
# 将 skills 安装到你的 Agent 中
npx skills add panzi-hub/MergeMill
```

或直接阅读：`skills/MergeMill-dev/SKILL.md`

### 工作流步骤（速查参考）

| 步骤 | 操作 | 由谁强制执行 |
|------|--------|-------------|
| 1 | 设计画布（Pencil MCP 或 markdown） | `check-design-canvas.sh` |
| 2 | 创建 Git Worktree | `block-commit-outside-worktree.sh` |
| 3 | 编写测试用例（TDD） | `check-test-plan.sh` |
| 4 | 实现变更 | — |
| 5 | 本地验证（构建 + 测试） | `check-unit-tests.sh` |
| 6 | 代码简化审查 | `check-code-simplifier.sh` |
| 7 | Commit 并创建 PR | — |
| 8 | PR 审查 Agent | `check-pr-review.sh` |
| 9 | Rebase 并 Push | `check-rebase-before-push.sh` |
| 10 | 等待 CI 检查完成 | `verify-completion.sh` |
| 11 | 处理审查 Bot 的发现 | — |
| 12 | E2E 测试 | `verify-completion.sh` |
| 13 | 清理 Worktree | — |

---

## 验收检查清单

合并任何 PR 前，确认：

- [ ] 设计画布已创建/更新（`docs/designs/<feature>.pen` 或 `.md`）
- [ ] 已为开发创建 git worktree
- [ ] 测试用例文档已创建（`docs/test-cases/<feature>.md`）
- [ ] 功能代码已完成并在本地验证
- [ ] 单元测试覆盖率 >80%
- [ ] 所有单元测试通过
- [ ] code-simplifier Agent 审查已通过
- [ ] pr-review Agent 审查已通过
- [ ] **所有 GitHub PR Checks 通过**
- [ ] E2E 测试通过
- [ ] 同行审查完成
- [ ] 合并后清理 worktree
- [ ] 如果 PR 触及 dispatcher / dev / review wrapper，对应的 `docs/pipeline/*.md`（state-machine、invariants、*-flow、handoffs）已在同一 PR 中更新——见 [流水线文档权威性](#流水线文档权威性)

---

## 常用命令

```bash
# Worktree 管理
git worktree add .worktrees/<branch> -b <branch>   # 创建 worktree
git worktree list                                   # 列出 worktrees
git worktree remove .worktrees/<branch>             # 移除 worktree
git worktree prune                                  # 清理过期引用

# 开发
npm run dev                    # 启动本地开发服务器
npm run build                  # 构建项目

# 测试
npm test                       # 运行所有测试
npm run test:coverage          # 运行测试并生成覆盖率报告
npm run test:e2e               # 运行 E2E 测试

# 代码质量
npm run lint                   # 运行 Linter
npm run lint:fix               # 运行 Linter 并自动修复
npm run typecheck              # TypeScript 类型检查

# Hook 状态管理
hooks/state-manager.sh list        # 查看当前状态
hooks/state-manager.sh mark <action>   # 将操作标记为完成
hooks/state-manager.sh clear <action>  # 清除状态
```

---

## 项目结构

```
project-root/
├── CLAUDE.md                     # 项目配置和工作流（此文件）
├── AGENTS.md                    # 跨平台 skill 发现
├── .claude/
│   ├── settings.json            # Claude Code hooks 配置
│   └── skills -> ../skills      # Claude Code 发现用的符号链接
├── .kiro/
│   ├── agents/
│   │   └── default.json         # Kiro CLI agent 配置（hooks + 工具）
│   └── skills -> ../skills      # Kiro CLI 发现用的符号链接
├── hooks -> skills/MergeMill-common/hooks   # 向后兼容的符号链接
├── scripts -> skills/MergeMill-dispatcher/scripts  # 向后兼容的符号链接
├── skills/                      # 跨平台 skills（skills.sh 兼容）
│   ├── MergeMill-common/       # 共享 hooks + Agent 可调用脚本
│   │   ├── SKILL.md
│   │   ├── hooks/               # 工作流强制 hooks
│   │   │   ├── README.md
│   │   │   ├── lib.sh
│   │   │   ├── state-manager.sh
│   │   │   ├── block-push-to-main.sh
│   │   │   ├── block-commit-outside-worktree.sh
│   │   │   ├── check-design-canvas.sh
│   │   │   ├── check-code-simplifier.sh
│   │   │   ├── check-pr-review.sh
│   │   │   ├── check-test-plan.sh
│   │   │   ├── check-unit-tests.sh
│   │   │   ├── check-rebase-before-push.sh
│   │   │   ├── warn-skip-verification.sh
│   │   │   ├── post-git-action-clear.sh
│   │   │   ├── post-git-push.sh
│   │   │   └── verify-completion.sh
│   │   └── scripts/             # 共享的 Agent 可调用脚本
│   │       ├── mark-issue-checkbox.sh
│   │       ├── gh-as-user.sh
│   │       ├── reply-to-comments.sh
│   │       └── resolve-threads.sh
│   ├── MergeMill-dev/          # TDD 开发工作流
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── commit-conventions.md
│   │       ├── review-commands.md
│   │       ├── review-threads.md
│   │       └── MergeMill-mode.md
│   ├── MergeMill-review/       # PR 审查工作流
│   │   ├── SKILL.md
│   │   ├── scripts/
│   │   │   └── upload-screenshot.sh
│   │   └── references/
│   │       ├── merge-conflict-resolution.md
│   │       ├── e2e-verification.md
│   │       └── decision-gate.md
│   ├── MergeMill-dispatcher/   # Issue 调度器 + 流水线脚本
│   │   ├── SKILL.md
│   │   └── scripts/
│   │       ├── MergeMill-dev.sh
│   │       ├── MergeMill-review.sh
│   │       ├── MergeMill.conf.example
│   │       ├── dispatch-local.sh
│   │       ├── lib-agent.sh
│   │       ├── lib-auth.sh
│   │       ├── gh-app-token.sh
│   │       ├── gh-token-refresh-daemon.sh
│   │       ├── gh-with-token-refresh.sh
│   │       └── setup-labels.sh
│   └── create-issue/            # GitHub Issue 创建器
│       ├── SKILL.md
│       └── references/
│           ├── issue-templates.md
│           └── workspace-changes.md
├── .worktrees/                  # Git worktrees（已 gitignore）
├── docs/
│   ├── designs/                 # 设计画布文档
│   ├── test-cases/              # 测试用例文档
│   ├── MergeMill-pipeline.md
│   └── templates/
├── src/                         # 源代码
├── tests/                       # 测试代码
│   ├── unit/
│   └── e2e/
└── .github/
    └── workflows/               # GitHub Actions CI 配置
```

---

## Skills 参考

此项目提供五个可移植 skills，可安装到 40+ 种编程 Agent 中：

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | 位置 | 描述 |
|-------|----------|-------------|
| **MergeMill-dev** | `skills/MergeMill-dev/SKILL.md` | TDD 工作流：worktree 隔离、设计画布、测试优先开发、代码审查、CI 验证 |
| **MergeMill-review** | `skills/MergeMill-review/SKILL.md` | PR 代码审查：检查清单、合并冲突解决、E2E 测试、自动合并 |
| **MergeMill-dispatcher** | `skills/MergeMill-dispatcher/SKILL.md` | GitHub Issue 扫描器，按 cron 定时调度 dev/review Agent |
| **create-issue** | `skills/create-issue/SKILL.md` | 结构化 GitHub Issue 创建器：模板和 MergeMill 标签指导 |
| **MergeMill-common** | `skills/MergeMill-common/SKILL.md` | 共享的工作流强制 hooks 和 Agent 可调用工具脚本，由其他 MergeMill-* skills 使用 |

---

## 自主流水线

一个完全自动化的流水线：GitHub Issue → Dev Agent → Review Agent → 已合并 PR。通过 cron 周期上的 dispatcher 无人值守运行。支持多种编程 Agent CLI（Claude Code、Codex、Kiro），具有可插拔抽象层。

完整的流水线设计、标签状态机和并发模型见 `docs/MergeMill-pipeline.md`。

### 配置

```bash
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
```

关键设置：`REPO`、`PROJECT_DIR`、`AGENT_CMD`（claude/codex/kiro）、`GH_AUTH_MODE`（token/app）、`MAX_CONCURRENT`、`MAX_RETRIES`、E2E 选项。详见示例文件中的注释。

### 关键脚本

> 注意：脚本现在打包在 skill 目录内，可通过项目根目录的 `scripts/` 符号链接访问。

| 脚本 | 用途 |
|--------|---------|
| `scripts/MergeMill-dev.sh` | Dev Agent wrapper |
| `scripts/MergeMill-review.sh` | Review Agent wrapper |
| `scripts/dispatch-local.sh` | 本地调度脚本 |
| `scripts/lib-agent.sh` | Agent CLI 抽象层（`run_agent`、`resume_agent`） |
| `scripts/lib-auth.sh` | GitHub 认证抽象层（PAT 或 GitHub App 模式） |
| `scripts/setup-labels.sh` | 创建流水线所需的 GitHub 标签 |
| `scripts/mark-issue-checkbox.sh` | 将 Issue 正文中的复选框标记为完成 |
| `scripts/reply-to-comments.sh` | 回复 PR 审查评论 |
| `scripts/resolve-threads.sh` | 批量解决审查讨论线程 |

### GitHub App 设置

对于需要独立 bot 身份的多 Agent 认证，见 `docs/github-app-setup.md`。

---

## 实现日志

### YYYY-MM-DD：项目初始化
- 创建项目结构
- 配置 Agent hooks
- 配置 CI/CD 流水线

---

## 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|--------|------------|
| - | - | - |

---

## 安全最佳实践

- **GH_TOKEN** 使用 GitHub classic PAT（`repo` scope），通过 `MergeMill.conf` 注入，不提交到仓库
- `MergeMill.conf` 已在 `.gitignore` 中排除
- Pipeline 将 Issue 内容作为 Agent 指令执行——仅在私有仓库和可信环境中使用
- 公开仓库中 Issue 是 prompt 注入攻击面，详见 `docs/security.md`
- 研发流程强制 git worktree 隔离，防止主工作目录脏状态影响运行中的 dispatcher
