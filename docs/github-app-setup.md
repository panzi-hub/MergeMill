# GitHub App 设置指南

## 为什么使用 GitHub App 而不是个人访问 token？

自主流水线最多使用三个独立的 bot 身份（dev Agent、review Agent、dispatcher）。GitHub App 提供以下优势：

| 优势 | PAT | GitHub App |
|---------|-----|------------|
| 独立的 bot 身份 | 否——所有操作显示为 PAT 所有者 | 是——每个 App 有自己的 bot 账户 |
| 细粒度权限 | 仅仓库级别 | 按权限粒度控制 |
| Token 过期 | 长期有效（有风险） | 1 小时 token（自动刷新） |
| 速率限制 | 与用户共享 | 每个 App 独立 |
| 审计追踪 | 所有操作归因于一个用户 | 每个 bot 清晰可辨识 |

使用 GitHub App 后，dev Agent 的 PR 评论显示为 `my-dev-bot[bot]`，审查批准显示为 `my-review-bot[bot]`，dispatcher 操作显示为 `my-dispatcher-bot[bot]`。这使流水线的操作透明且可审计。

## 创建 GitHub App

你需要创建**三个** GitHub App——每个流水线角色一个。这确保了清晰的关注点分离和审计追踪。

### App 1：Dev Agent

1. 进入 **Settings > Developer settings > GitHub Apps > New GitHub App**
2. 填写：
   - **GitHub App name**：`<project>-dev-agent`（例如 `myproject-coding-agent`）
   - **Homepage URL**：你的仓库 URL
   - **Webhook**：取消勾选 "Active"（不需要）
3. 设置权限：

   | 权限 | 访问级别 | 用途 |
   |------------|--------|---------|
   | **Issues** | Read & Write | 读取 issue 正文、发表评论、更新标签 |
   | **Pull requests** | Read & Write | 创建 PR、发表评论、更新描述 |
   | **Contents** | Read & Write | 推送代码到功能分支 |

4. 在 "Where can this GitHub App be installed?" 下选择 **Only on this account**
5. 点击 **Create GitHub App**
6. 记下设置页显示的 **App ID**

### App 2：Review Agent

1. 创建另一个 GitHub App：`<project>-review-agent`（例如 `myproject-test-agent`）
2. 设置与 dev Agent 相同的权限，外加：

   | 权限 | 访问级别 | 用途 |
   |------------|--------|---------|
   | **Issues** | Read & Write | 读取 issue 正文、发布审查裁决、更新标签 |
   | **Pull requests** | Read & Write | 提交 PR 审查（APPROVE/REQUEST_CHANGES） |
   | **Contents** | Read & Write | 推送 rebase 后的分支、上传截图 |

3. 点击 **Create GitHub App** 并记下 **App ID**

### App 3：Dispatcher

1. 创建第三个 GitHub App：`<project>-dispatcher`（例如 `myproject-dispatcher`）
2. 设置权限：

   | 权限 | 访问级别 | 用途 |
   |------------|--------|---------|
   | **Issues** | Read & Write | 列出 issue、更新标签、发表调度评论 |
   | **Pull requests** | Read | 读取 PR 状态用于审查调度 |

3. 点击 **Create GitHub App** 并记下 **App ID**

## 在仓库上安装 App

对三个 App 分别执行：

1. 进入 App 的设置页面
2. 点击左侧栏的 **Install App**
3. 选择你的账户/组织
4. 选择 **Only select repositories** 并选择你的目标仓库
5. 点击 **Install**

## 下载私钥 PEM 文件

对每个 App：

1. 进入 App 的设置页面
2. 滚动到 **Private keys**
3. 点击 **Generate a private key**
4. 一个 `.pem` 文件将自动下载
5. 将其安全地存储在运行流水线的机器上

推荐的存储位置：
```
/path/to/project/
  .github-apps/          # 已 gitignored 的目录
    dev-agent.pem
    review-agent.pem
    dispatcher.pem
```

将 `.github-apps/` 添加到 `.gitignore`：
```bash
echo ".github-apps/" >> .gitignore
```

## 配置 MergeMill.conf

编辑 `scripts/MergeMill.conf`，填入 App ID 和 PEM 路径：

```bash
# === GitHub 认证 ===
GH_AUTH_MODE="app"

# Dev Agent
DEV_AGENT_APP_ID="123456"
DEV_AGENT_APP_PEM="/path/to/project/.github-apps/dev-agent.pem"

# Review Agent
REVIEW_AGENT_APP_ID="789012"
REVIEW_AGENT_APP_PEM="/path/to/project/.github-apps/review-agent.pem"

# Dispatcher
DISPATCHER_APP_ID="345678"
DISPATCHER_APP_PEM="/path/to/project/.github-apps/dispatcher.pem"
```

## 双 token 拆分 — 限定范围的 Agent token（[INV-79]）

在 **app 模式**下，流水线每次运行从**同一** App 凭据生成**两个**安装 token：

| Token | 持有者 | contents | issues | pull_requests | 用途 |
|-------|--------|----------|--------|---------------|----------|
| **完整写入**（现有） | 仅 **wrapper** shell | write | write | **write** | 标签翻转、PR approve/merge、裁决发布、代理的 `gh pr create`、代理的 E2E 报告 |
| **限定范围**（新增） | 仅 **Agent** 子进程 | write | write | **read** | 推送分支、进度评论、复选框打勾、E2E 报告（写入代理文件） |

Wrapper 在启动 Agent 前从其环境中剥离完整写入凭据：Agent 进程获得的 `GH_TOKEN_FILE` 指向**限定范围**的 token 文件（由限定范围的守护进程保持刷新——因此 Agent 的 `gh` 在 1 小时 App token TTL 后仍然有效），`GH_TOKEN` = 作为快照回退的限定范围 token，`GITHUB_PERSONAL_ACCESS_TOKEN` 未设置（wrapper 的完整写入 token 文件位于不同路径且从未暴露）。`GH_USER_PAT` 也被**清除**——保留该宿主用户 PAT 的限定范围 Agent 可以 `export GH_TOKEN="$GH_USER_PAT"` 重新获得 approve/merge 权限。Agent 仍然触发内置的审查 bot，但通过**代理**：它将触发短语（`/q review` 等）写入文件，wrapper 通过 `gh-as-user.sh` 发布它们（bot 拒绝 App-bot 账户），将 `GH_USER_PAT` 仅保留在 wrapper shell 中。`PATH` 被重写：wrapper 的每次运行 shim 目录被剥离，Agent 自己的每次运行 shim 目录被前置，使 Agent 环境不携带 wrapper 的 `gh` shim，而 Agent 的裸 `gh` 仍然可解析（Agent 自己的 `gh-with-token-refresh.sh` shim——在 `REAL_GH`/非交互式 PATH 主机上唯一可解析的 `gh`）；该 shim 读取限定范围的 `GH_TOKEN_FILE` 并以新鲜的限定范围 token 执行真实的 `gh`，因此 Agent 的 `gh` 可正常工作、保持刷新且范围受限。限定范围 token 由自己的后台守护进程刷新（与完整写入 token 相同的 45 分钟周期）。

### 精确的权限范围

限定范围的 Agent token 精确请求：

```json
{ "contents": "write", "issues": "write", "pull_requests": "read" }
```

（可通过 `MergeMill.conf` 中的 `AGENT_TOKEN_PERMISSIONS` 被操作者覆盖）。

- `contents: write`——**必需**：dev Agent 必须推送功能分支；只读 token 在事实上不可能用于开发。
- `issues: write`——进度评论、复选框打勾和 E2E 报告回退发布。
- `pull_requests: read`——隔离杠杆：`gh pr review --approve` 和 `gh pr merge` 都需要 `pull_requests:write`，因此 Agent 的 token 在任一操作上都会收到确定性的 **403**。`gh pr create` 同样需要 `pull_requests:write`，因此 dev Agent 不直接运行它——而是将 PR 标题+正文写入代理文件，由 wrapper 打开 PR（见 `docs/pipeline/invariants.md` 中的 [INV-79]）。

> App **安装**必须仍然授予 `pull_requests: write`（wrapper 的完整写入 token 需要它）。*限定范围*的 token 仅请求子集；GitHub 会拒绝超出安装授权的限定请求（HTTP 422）。

### 攻击面说明（纵深防御，而非隔离）

Agent 和 wrapper 以**相同的操作系统用户**运行，因此一个有决心的 Agent 可以从磁盘读取 wrapper 的 token 文件。此拆分是**纵深防御，而非沙箱**。它保证的是：Agent 的 `gh` *实际使用*的 token 不能 approve 或 merge PR——将"Agent 可以合并"（自合并事件类型，即 Agent 运行了 `gh pr review --approve` + merge，绕过了 wrapper 门控）转变为"Agent 的 token 无法合并"，独立于 PreToolUse hook 层（该层会遗漏 `gh api` 且对非 claude CLI 没有覆盖）。**明确超出范围**：Agent 的操作系统用户/容器隔离。

### PAT 模式退化

在 **token 模式**下（`GH_AUTH_MODE=token`），PAT 在生成时无法降级权限，因此**没有**第二个 token。Agent 保留共享的 PAT；wrapper 记录一次性 WARN：

```
WARN: [INV-79] GH_AUTH_MODE=token — a PAT cannot be down-scoped, so agent
credential enforcement degraded to convention in PAT mode ...
```

在 PAT 模式下，approve/merge 隔离依赖 wrapper 的 INV-44/52 门控加上 PreToolUse hook 层——凭据边界不可用。

## Token 刷新守护进程

GitHub App 安装 token 在 1 小时后过期。流水线包含一个后台 token 刷新守护进程，在过期前自动生成新 token。

### 工作原理

1. 当 `GH_AUTH_MODE=app` 时，`lib-auth.sh` 在后台启动 `gh-token-refresh-daemon.sh`
2. 守护进程将当前 token 写入文件：`/tmp/cc-${PROJECT_ID}-gh-token-<pid>.txt`
3. `gh-with-token-refresh.sh` wrapper 在每次 `gh` 命令前从此文件读取最新 token
4. 守护进程每 45 分钟刷新一次 token（在 60 分钟过期之前）
5. 清理时（脚本退出），守护进程被终止，token 文件被删除

### Token 流向

```
┌──────────────┐     写入 token      ┌─────────────────┐
│ Token 刷新    │ ──────────────────► │  Token 文件      │
│ 守护进程      │  （每 45 分钟）     │  /tmp/cc-*.txt   │
└──────────────┘                      └────────┬────────┘
                                               │ 读取
                                      ┌────────▼────────┐
                                      │  gh wrapper      │
                                      │  (gh-with-       │
                                      │   token-refresh) │
                                      └────────┬────────┘
                                               │ 调用
                                      ┌────────▼────────┐
                                      │  GitHub API      │
                                      └─────────────────┘
```

### 手动生成 Token

用于调试或一次性操作：

```bash
source scripts/gh-app-token.sh
GH_TOKEN=$(get_gh_app_token "$APP_ID" "$APP_PEM" "$REPO_OWNER" "$REPO_NAME")
export GH_TOKEN
gh issue list --repo owner/repo
```

## 故障排除

### "FATAL: Failed to generate GitHub App token"

**原因**：JWT 生成或安装 token 交换失败。

**检查**：
1. 验证 PEM 文件存在且可读：
   ```bash
   ls -la /path/to/.github-apps/dev-agent.pem
   ```
2. 验证 App ID 正确（检查 GitHub App 设置页面）
3. 验证 App 已安装在目标仓库上
4. 确保 `openssl` 可用（用于 JWT 签名）：
   ```bash
   which openssl
   ```

### "Token daemon failed to write initial token"

**原因**：后台守护进程已启动但无法生成第一个 token。

**检查**：
1. 检查 `/tmp/` 是否可写
2. 检查守护进程日志中的错误
3. 验证 GitHub API 的网络连接
4. 尝试手动 token 生成（见上文）

### "gh: command requires authentication"

**原因**：`gh` wrapper 未正确读取 token 文件。

**检查**：
1. 验证 `GH_TOKEN_FILE` 是否已设置：`echo $GH_TOKEN_FILE`
2. 验证 token 文件存在且非空：`cat $GH_TOKEN_FILE`
3. 验证 `gh-with-token-refresh.sh` 符号链接设置正确：
   ```bash
   ls -la scripts/gh  # 应指向 gh-with-token-refresh.sh
   ```

### 操作显示为错误的用户

**原因**：使用了错误的 App token 或回退到了个人 token。

**检查**：
1. 在 `MergeMill.conf` 中验证 `GH_AUTH_MODE=app`
2. 验证每个角色使用了正确的 App ID/PEM 对
3. 检查 `GH_TOKEN` 未设置为 PAT（会覆盖 App token）

### App 安装 token 权限不正确

**原因**：App 权限在安装后发生了变更。

**修复**：进入 App 的安装设置，验证权限与上述列表匹配。如果更改了 App 权限，可能需要在安装页面重新接受新权限。

## 使用 Token 模式（更简单的替代方案）

如果不需要独立的 bot 身份，可以使用单个个人访问 token：

```bash
# 在 MergeMill.conf 中
GH_AUTH_MODE="token"

# 然后在运行流水线前设置 GH_TOKEN
export GH_TOKEN="ghp_xxxxxxxxxxxx"
```

所需的 PAT 范围：`repo`（完整仓库访问）。

这种方式设置更简单，但所有流水线操作都将显示为你的个人账户。
