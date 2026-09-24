# 工作区变更附加

起草 Issue 后，检查工作区中可能为自主 dev Agent 提供有用上下文的本地变更（未暂存、已暂存或未跟踪文件）。Dev Agent 在从 `main` 创建的隔离 git worktree 中工作，看不到用户的本地工作区，因此将这些变更附加到 Issue 可以弥合这一差距。

**如果没有本地变更，静默跳过此步骤。**

## 检测变更

运行这些命令检查工作区修改：

```bash
# 检查任何变更（已修改、已暂存、未跟踪）
git status --short

# 统计已暂存 + 未暂存变更的 diff 行数
STAGED_LINES=$(git diff --cached | wc -l)
UNSTAGED_LINES=$(git diff | wc -l)

# 列出未跟踪文件（null 分隔以确保安全处理）
UNTRACKED=$(git ls-files --others --exclude-standard)

# 统计未跟踪文件内容行数（处理文件名中的空格）
UNTRACKED_LINES=0
if [ -n "$UNTRACKED" ]; then
  UNTRACKED_LINES=$(git ls-files --others --exclude-standard -z | xargs -0 cat 2>/dev/null | wc -l)
fi

TOTAL_DIFF_LINES=$((STAGED_LINES + UNSTAGED_LINES + UNTRACKED_LINES))
```

如果 `git status --short` 无输出，完全跳过工作区变更附加。

## 汇总并确认

向用户展示摘要：
- 变更文件数量（已修改 + 已暂存 + 未跟踪）
- 大约新增/删除的行数
- 受影响的文件路径列表

然后询问：
> "这些本地变更似乎与此 Issue 相关。我是否应将它们附加到 Issue 以便 dev Agent 使用？（Y/n）"

如果用户拒绝，跳到 Issue 创建。

## 选择附加策略

| 总 Diff 行数 | 策略 | 详情 |
|------------------|----------|--------|
| < 500 行 | **内联 diff** | 将合并 diff 作为可折叠代码块嵌入 Issue 正文 |
| >= 500 行 | **分支推送** | Commit 到 `issue-context/<issue-number>` 分支，在 Issue 正文中引用 |
| 推送失败 | **文件列表回退** | 列出变更的文件路径并附简短描述 |

## 生成合并 Diff（用于内联策略）

将已暂存、未暂存和未跟踪文件内容合并为单一 diff：

```bash
{
  # 已暂存变更
  git diff --cached
  # 未暂存变更
  git diff
  # 未跟踪文件作为新文件 diff
  git ls-files --others --exclude-standard | while IFS= read -r f; do
    [ -f "$f" ] || continue
    LINES=$(wc -l < "$f")
    echo "diff --git a/$f b/$f"
    echo "new file mode 100644"
    echo "--- /dev/null"
    echo "+++ b/$f"
    echo "@@ -0,0 +1,$LINES @@"
    sed 's/^/+/' "$f"
  done
}
```

## 向 Issue 正文添加 Pre-existing Changes 部分

**对于内联 diff（< 500 行）**，附加到 Issue 正文：

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
Dev agent should apply these changes first before starting implementation.

<details>
<summary>Click to expand diff (N files changed, +X/-Y lines)</summary>

\`\`\`diff
<combined diff output>
\`\`\`
</details>
```

**对于分支推送（>= 500 行）**，分支在 Issue 创建后创建（需要 Issue 编号）：

1. 暂存所有变更（包括未跟踪文件）
2. 创建 commit：`context: workspace changes for issue #<number>`
3. 推送到 `issue-context/<issue-number>` 分支
4. 恢复工作区到原始状态

```bash
# 保存当前索引状态
git stash --keep-index --quiet 2>/dev/null || true

# 暂存所有内容，包括未跟踪文件
git add -A

# 创建临时 commit
git commit -m "context: workspace changes for issue #<number>"

# 推送到上下文分支
git push origin HEAD:refs/heads/issue-context/<number>

# 撤销 commit 但在工作树中保留变更
git reset HEAD~1

# 恢复原始索引状态
git stash pop --quiet 2>/dev/null || true
```

然后更新 Issue 正文以包含：

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
Dev agent should apply these changes first before starting implementation.

**Branch**: `issue-context/<issue-number>`

To apply in your worktree:
\`\`\`bash
git cherry-pick issue-context/<issue-number>
# or
git diff main...issue-context/<issue-number> | git apply
\`\`\`

### Files Changed
- `path/to/file1.ts` -- <brief description>
- `path/to/file2.test.ts` -- <brief description>
```

**文件列表回退**（如果分支推送失败）：

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
These changes could not be automatically attached. The dev agent should recreate them based on the descriptions below.

### Files Changed
- `path/to/file1.ts` -- <brief description of changes>
- `path/to/file2.test.ts` -- <brief description of changes>

### Summary of Changes
<Prose description of what the changes do and why>
```

## 附加后清理（可选）

成功附加变更后，询问用户：
> "工作区变更已附加到 Issue。你要清理（丢弃）这些本地变更吗？（y/N）"

如果用户同意，仅清理附加 diff 中的文件 — 不要移除不相关的未跟踪文件：

```bash
# 还原被跟踪文件的修改（已暂存和未暂存）
git checkout -- <list of modified tracked files from the diff>

# 仅移除 diff 中包含的未跟踪文件
rm <list of untracked files from the diff>
```

**重要**：不要使用 `git clean -fd`，因为它会移除所有未跟踪文件，包括与该 Issue 无关的文件。仅移除在附加 diff 中明确包含的文件。

默认是保留变更（用户必须明确选择清理）。
