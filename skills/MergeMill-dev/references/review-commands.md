# 审查命令参考

> **GitHub 通道参考（`CODE_HOST=github`）。** 以下每个命令都是刻意针对 GitHub 的——此文件作为 GitHub 通道审查工作的具体 `gh` CLI + GraphQL 参考手册。在 GitLab 通道（`CODE_HOST=gitlab`）上，这些操作通过流水线的 provider 接口（`chp_*` / `itp_*` 动词）或审查 wrapper 路由；GitLab REST 等价物位于 `skills/MergeMill-dispatcher/scripts/providers/chp-gitlab.sh` 的叶子头文档字符串中。通道配置见 `docs/gitlab-setup.md`，接口契约见 `skills/MergeMill-dispatcher/scripts/providers/provider-spec.md`。不要逐字将这些命令移植到 GitLab 通道工作流中。

PR 审查工作流中使用的 GitHub CLI 和 GraphQL 命令的完整参考。

## gh CLI 命令

### 获取 PR 审查评论

列出 PR 上的所有审查评论：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:100], created_at: .created_at}'
```

按日期过滤（特定时间之后的评论）：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '[.[] | select(.created_at > "2024-01-01T00:00:00Z")] | .[] | {id: .id, body: .body[:100]}'
```

获取特定审查的评论：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews/{review_id}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:150]}'
```

### 回复审查评论

直接回复特定评论（创建线程回复）：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  -X POST \
  -f body="Addressed in commit abc123 - <description of fix>" \
  -F in_reply_to=<comment_id>
```

**重要**：使用 `-F in_reply_to=<id>` 在线程中回复。不这样做会创建新评论而非线程回复。

### 获取 PR 审查

列出 PR 上的所有审查：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '.[] | {id: .id, state: .state, user: .user.login, submitted_at: .submitted_at}'
```

获取最近的 Amazon Q Developer 审查：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '[.[] | select(.user.login == "amazon-q-developer[bot]")] | .[-1] | {id: .id, submitted_at: .submitted_at}'
```

获取最近的 Codex 审查：

```bash
gh api repos/{owner}/{repo}/pulls/{pr}/reviews \
  --jq '[.[] | select(.user.login == "codex[bot]")] | .[-1] | {id: .id, submitted_at: .submitted_at}'
```

### 触发 Bot 审查

仅对项目 `REVIEW_BOTS`（每项目 `MergeMill.conf` 设置）中列出的 bot 应用触发器。空的 `REVIEW_BOTS` 表示没有 bot 是强制性的；跳过此节。

> **重要：** 所有三个内置 bot 审查者（Amazon Q、Codex、Claude）忽略由 GitHub App bot 账户发布的触发评论。如果项目有 `scripts/gh-as-user.sh`，使用它使评论归属于真实用户。

```bash
# Amazon Q Developer（当 q ∈ REVIEW_BOTS）
bash scripts/gh-as-user.sh pr comment {pr} --body "/q review"

# Codex（当 codex ∈ REVIEW_BOTS）
bash scripts/gh-as-user.sh pr comment {pr} --body "/codex review"

# Claude（当 claude ∈ REVIEW_BOTS）
# 注意：Claude 使用 @claude review，而非 /claude review。
bash scripts/gh-as-user.sh pr comment {pr} --body "@claude review"
```

对于自定义 bot（通过 `REVIEW_BOTS_<NAME>_TRIGGER` 和 `_LOGIN` 声明），使用你设置的触发短语。

如果 `scripts/gh-as-user.sh` 不可用，直接回退到 `gh pr comment`。

### 监控 PR 检查

观察所有检查直到完成：

```bash
gh pr checks {pr} --watch --interval 30
```

快速状态检查：

```bash
gh pr checks {pr}
```

### 获取 PR 状态

```bash
gh pr view {pr} --json state,reviewDecision,statusCheckRollup \
  --jq '{state: .state, reviewDecision: .reviewDecision}'
```

## GraphQL 命令

### 获取审查线程状态

查询获取所有审查线程及其解决状态：

```bash
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        totalCount
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes {
              body
            }
          }
        }
      }
    }
  }
}'
```

### 仅获取未解决的线程

过滤仅显示未解决的线程：

```bash
gh api graphql -f query='...' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | {id: .id, comment: .comments.nodes[0].body[:80]}'
```

### 获取线程计数摘要

```bash
gh api graphql -f query='...' --jq '{
  total: .data.repository.pullRequest.reviewThreads.totalCount,
  resolved: [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == true)] | length,
  unresolved: [.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length
}'
```

### 解决审查线程

解决单个线程的变更操作：

```bash
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "<thread_id>"}) {
    thread {
      isResolved
    }
  }
}'
```

### 批量解决所有未解决线程

组合查询和变更循环：

```bash
gh api graphql -f query='...' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id' | while read thread_id; do
  echo "Resolving: $thread_id"
  gh api graphql -f query="mutation { resolveReviewThread(input: {threadId: \"$thread_id\"}) { thread { isResolved } } }" --jq '.data.resolveReviewThread.thread.isResolved'
done
```

## 常见工作流

### 完整审查响应流程

1. **获取新评论**：
```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments --jq 'sort_by(.created_at) | .[-10:] | .[] | {id: .id, body: .body[:100]}'
```

2. **回复每条评论**：
```bash
gh api repos/{owner}/{repo}/pulls/{pr}/comments -X POST -f body="Addressed in commit abc123 - Fixed the issue" -F in_reply_to=<comment_id>
```

3. **解决所有线程**：
```bash
# 使用批量解决脚本或上述循环
```

4. **为 `REVIEW_BOTS` 中的每个 bot 触发新审查**（使用 `gh-as-user.sh` 使 bot 不会忽略触发器）：
```bash
# 当 q ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr} --body "/q review"
# 当 codex ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr} --body "/codex review"
# 当 claude ∈ REVIEW_BOTS:
bash scripts/gh-as-user.sh pr comment {pr} --body "@claude review"
```

5. **等待并检查新评论**：
```bash
sleep 90
# 检查 Amazon Q
gh api repos/{owner}/{repo}/pulls/{pr}/reviews --jq '[.[] | select(.user.login == "amazon-q-developer[bot]")] | .[-1]'
# 检查 Codex
gh api repos/{owner}/{repo}/pulls/{pr}/reviews --jq '[.[] | select(.user.login == "codex[bot]")] | .[-1]'
```

6. **迭代直到无新阳性发现** - 如有新发现，从步骤 1 重复

### 检查所有线程是否已解决

```bash
unresolved=$(gh api graphql -f query='...' --jq '... | select(.isResolved == false) | .id' | wc -l)
if [ "$unresolved" -eq 0 ]; then echo "All threads resolved!"
else echo "$unresolved threads still unresolved"
fi
```

## 错误处理

### 线程未找到

如果 `resolveReviewThread` 返回 "Could not resolve to a node"：
- 确认线程 ID 正确
- 检查 PR 是否仍开放
- 确保你对仓库有写权限

### 限流

如果遇到 GitHub API 限流：
- 在请求之间添加延迟：`sleep 1`
- 对大型结果集使用分页
- 检查限流状态：`gh api rate_limit`

### 认证问题

确保 `gh` 已认证：
```bash
gh auth status
gh auth login  # 如需要
```
