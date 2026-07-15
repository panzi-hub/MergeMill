# 审查线程管理

> **GitHub 通道参考（`CODE_HOST=github`）。** 线程回复机制、GraphQL `resolveReviewThread` 变更和下方的错误做法警告是 GitHub 特定的。在 GitLab 通道（`CODE_HOST=gitlab`）上，合并请求讨论及其 `resolvable`/`resolved` 状态通过流水线的 provider 接口管理（`chp_list_inline_comments`、`chp_reply_review_comment` 以及 wrapper 的解决辅助函数）；Agent 不要手写 `glab api /projects/.../discussions/...`。GitLab 等价物见 `docs/gitlab-setup.md` 和 `skills/MergeMill-dispatcher/scripts/providers/chp-gitlab.sh` 中的叶子头文档字符串。不要逐字移植这些命令。

## 关键规则

- **直接回复每条评论线程** — 而非发一条通用的 PR 评论
- **回复后解决每个对话**
- **错误做法**：`gh pr comment {pr} --body "Fixed all issues"`（不会关闭线程）

## 回复审查评论

```bash
# 获取评论 ID
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:50]}'

# 回复特定评论
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  -X POST \
  -f body="Addressed in commit abc123 - <description of fix>" \
  -F in_reply_to=<comment_id>
```

## 解决审查线程

```bash
# 获取未解决线程 ID
gh api graphql -f query='
query { repository(owner: "{owner}", name: "{repo}") {
  pullRequest(number: {pr}) {
    reviewThreads(first: 50) {
      nodes { id isResolved comments(first: 1) { nodes { body } } }
    }
  }
}}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id'

# 解决一个线程
gh api graphql -f query='
mutation { resolveReviewThread(input: {threadId: "<thread_id>"}) { thread { isResolved } } }'
```

## 批量解决所有线程

```bash
scripts/resolve-threads.sh {owner} {repo} {pr_number}
```

## 常见响应模式

### 有效问题

```
Addressed in commit {hash} - {description of fix}
```

### 误报

```
This is by design because {explanation}. The {feature} requires {justification}.
```

### 文档关切

```
The referenced file {filename} exists in the repository at {path}. This is a reference document, not executable code.
```

## 快速参考

| 任务 | 命令 |
|------|--------|
| 创建 worktree | `git worktree add .worktrees/<branch> -b <branch>` |
| 列出 worktree | `git worktree list` |
| 移除 worktree | `git worktree remove .worktrees/<branch>` |
| 清理 worktree | `git worktree prune` |
| 创建设计 | Pencil MCP 工具（如可用） |
| 创建 PR | `gh pr create --title "..." --body "..."` |
| 观察检查 | `gh pr checks {pr} --watch` |
| 获取评论 | `gh api repos/{o}/{r}/pulls/{pr}/comments` |
| 回复评论 | `gh api ... -X POST -F in_reply_to=<id>` |
| 解决线程 | GraphQL `resolveReviewThread` 变更 |
| 触发 Q 审查 | `bash scripts/gh-as-user.sh pr comment {pr} --body "/q review"`（当 `q` ∈ `REVIEW_BOTS`） |
| 触发 Codex 审查 | `bash scripts/gh-as-user.sh pr comment {pr} --body "/codex review"`（当 `codex` ∈ `REVIEW_BOTS`） |
| 触发 Claude 审查 | `bash scripts/gh-as-user.sh pr comment {pr} --body "@claude review"`（当 `claude` ∈ `REVIEW_BOTS`） |
| 回复评论（脚本） | `scripts/reply-to-comments.sh {owner} {repo} {pr} {comment_id} "{message}"` |
| 解决所有线程（脚本） | `scripts/resolve-threads.sh {owner} {repo} {pr}` |
| 标记 hook 状态 | `hooks/state-manager.sh mark <action>` |
| 列出 hook 状态 | `hooks/state-manager.sh list` |
