# 合并冲突解决 — 审查前置步骤

> **Provider 通道范围。** 下方的 `gh pr view … --json mergeable` 和 `gh pr checks --watch` 命令是 GitHub 通道的具体形式；rebase 并强制推送流程本身是 git 原生的、provider 无关的。在 GitLab 通道（`CODE_HOST=gitlab`）上，wrapper 通过 `chp_mergeable` provider 接口读取可合并性，通过 `chp_ci_status` 读取 CI 状态——审查 Agent 在其 prompt 中获得已解析的状态（或调用接口），而非原始的 `glab mr view`。在 `CODE_HOST=gitlab` 下运行时，将 `gh pr …` 调用视为占位符。

开始审查前，检查 PR 分支是否与 main 有合并冲突。如有，rebase 该分支使 PR 可合并。

> **此审查前 rebase 是尽力而为的 prompt 指导——wrapper 机械地执行同一规则。** 即使你跳过此步骤，审查 wrapper 在汇总裁决并批准前会重新检查 `mergeable`：`CONFLICTING` 的 PR 永远无法达到 `approved`（[INV-44](../../../docs/pipeline/invariants.md)）。主动执行此步骤仍有帮助——一次干净的 rebase 使 PR 在本轮合并，而非弹回给 dev——但遗漏的步骤不再能让冲突的 PR 滑过。

## 流程

1. **检查可合并状态**：
   ```bash
   MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
   ```

2. **如果 MERGEABLE 为 "MERGEABLE"** — 跳到审查流程。

3. **如果 MERGEABLE 为 "CONFLICTING"** — 将 PR 分支 rebase 到 main 上：
   ```bash
   # Fetch 最新的 main 和 PR 分支
   git fetch origin main <PR_BRANCH>

   # [INV-100] (#355): 幂等预清理 — 崩溃的前一次 lane（同项目、同 Agent、同 PR）
   # 可能留下此精确目录；在 `git worktree add` 之前移除它，
   # 使重试永远不会因过期的 worktree 而卡住。
   git worktree remove --force /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER> 2>/dev/null || rm -rf /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER>

   # 为 rebase 创建临时 worktree — 键包含 PROJECT_ID + 此
   # Agent 的名称 + PR 编号，因此跨项目冲突和
   # 多 Agent 并行展开冲突（AGENT_REVIEW_AGENTS 针对同一 PR 运行
   # N 个 Agent，每个独立执行步骤 0）均被排除。
   git worktree add /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER> <PR_BRANCH>
   cd /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER>

   # Rebase 到 main
   git rebase origin/main
   ```

4. **如果 rebase 成功**（无冲突）：
   ```bash
   # 强制推送 rebase 后的分支
   git push --force-with-lease origin <PR_BRANCH>

   # 清理临时 worktree
   cd -
   git worktree remove /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER>

   # 等待 CI 在新 HEAD 上重新启动（强制推送后检查重置）
   # 轮询直到检查出现并完成
   sleep 10
   gh pr checks <PR_NUMBER> --watch --interval 30
   ```
   然后继续审查流程。

5. **如果 rebase 失败**（无法自动解决的合并冲突）：
   ```bash
   # 在 abort 之前捕获冲突文件
   CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "unknown")

   # Abort rebase
   git rebase --abort

   # 清理临时 worktree
   cd -
   git worktree remove /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER> --force
   ```
   **立即将审查判定为 FAIL**，附带：
   ```
   Review findings:

   Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

   1. **[BLOCKING] Merge conflict with main** - PR 分支 `<PR_BRANCH>` 与
      `main` 存在审查 Agent 无法自动解决的冲突。
      - 冲突文件：<来自 CONFLICT_FILES 的列表>
      - Dev Agent 在重新审查前必须解决这些冲突：
        1. `git fetch origin main`
        2. `git rebase origin/main`
        3. 解决列出文件中的冲突
        4. `git rebase --continue`
        5. `git push --force-with-lease origin <PR_BRANCH>`
   ```
   将此发布到 Issue 上并退出。Wrapper 脚本会将 Issue 转换为 `pending-dev`。

6. **如果 MERGEABLE 为 "UNKNOWN"** — GitHub 可能仍在计算。等待并重试：
   ```bash
   sleep 10
   MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
   ```
   如果 3 次重试后仍为 UNKNOWN，**不要将其视为 MERGEABLE 并继续批准。** GitHub 尚未解决的 UNKNOWN 可能隐藏着真实的冲突；将其视为可合并正是 [INV-44](../../../docs/pipeline/invariants.md) 所关闭的过期 `UNKNOWN` 直通路径。相反，将审查保持未最终定稿——发布一条简短说明表示可合并性仍在计算中，让下一个审查 tick 重新检查。（Wrapper 执行同一规则：持续 UNKNOWN 的 PR 被路由为非实质性重新排队，绝不自动批准。）

## 重要说明

- 强制推送到功能分支是安全的——只有流水线 Agent 触及这些分支。
- 使用 `--force-with-lease`（而非 `--force`）以避免覆盖意外变更。
- 强制推送后，所有 CI 检查会自动重启。在继续审查之前等待它们通过。
