# GitLab 设置指南

面向操作者的指南，用于接入 issue 跟踪器 AND/OR 代码托管为 GitLab（`ISSUE_PROVIDER=gitlab` / `CODE_HOST=gitlab`）的项目。两个接缝是独立的——项目可以 issues 使用 GitLab、代码使用 GitHub，或反之，或两者都用。

自主流水线通过冻结的 P3-1 传输契约（`skills/MergeMill-dispatcher/scripts/providers/lib-gitlab-transport.sh`）访问 GitLab。每个叶子动词（`itp_gitlab_*` 和 `chp_gitlab_*`）通过该 lib 的 `_gl_api` 公共函数路由 HTTP——一个阻塞点、一个分页遍历器、一个 429/`Retry-After` 退避循环、一个 fail-CLOSED 策略。

## 为什么是 GitLab token 而非 GitHub App

GitLab **没有等效的 GitHub App**。流水线的三个 GitHub bot 身份（dev、review、dispatcher——见 `docs/github-app-setup.md`）在 GitLab 上的映射如下：

| 属性 | GitHub App 模式 | GitLab token 模式 |
|----------|-----------------|-------------------|
| 独立的 bot 身份 | 三个独立 App，三个 bot 账户 | 一个 token = 一个身份（token 所有者或项目/组） |
| Token 过期 | 1 小时安装 token（自动刷新） | 长期有效的 PAT / 项目访问 token / 组访问 token（由操作者管理轮换） |
| 细粒度权限 | 按权限粒度控制 | 基于范围（`api` 覆盖接缝的需求） |
| 限定范围的 Agent token 隔离（[INV-79]） | **强制执行**——wrapper 为 Agent 子进程生成单独的 `pull_requests: read` token，因此 `gh pr review --approve` / `gh pr merge` 从 Agent 端返回 403 | **退化为约定**——没有更低权限的 token 可生成；同一 PAT 在所有地方使用。Wrapper 的 approve/merge 门控（[INV-44] / [INV-52]）和 `_AGENT_GITLAB_TOKEN_PAT_WARNED` 锁存器（`skills/MergeMill-dispatcher/scripts/lib-auth.sh`）是唯一的隔离手段（见 `docs/pipeline/provider-spec.md` §5.1）。 |
| 审计追踪 | 每个 bot 在时间线中清晰可辨识 | 操作归因于 token 所有者 |

如果你的组织需要在 GitLab 通道上为 dev/review/dispatcher 使用不同的 bot 身份，请配置三个独立的 GitLab 用户（或项目上的三个项目访问 token），并将每个 token 放入对应的按角色拆分配置键中。

## 创建 Token

GitLab 支持三种可互换的 token 类别供此流水线使用。三者都使用 P3-1 传输发送的 `PRIVATE-TOKEN` HTTP 头，且三者消耗相同的 `api` 范围。选择与你部署形态匹配的类别：

| 类别 | 创建位置 | 何时使用 |
|-------|---------------------|-------------|
| **个人访问 token（PAT）** | User Settings → Access tokens | 单操作者项目，流水线以一个人身份运行。最简单——匹配 GitHub 侧的 `GH_AUTH_MODE=token` 形态。 |
| **项目访问 token** | Project Settings → Access tokens | 流水线归项目所有，而非个人。Token 随项目消亡；轮换是项目管理员操作。推荐作为组织项目的默认方式。 |
| **组访问 token** | Group Settings → Access tokens | 流水线跨同一组中的兄弟项目工作（例如通过 `## Dependencies` 引用跨项目依赖）。 |

### 所需范围

`api`——该单一范围覆盖流水线调用的每个动词（issue 读/写、MR 读/写、notes、discussions、approvals、labels、用于 `chp_gitlab_commit_file` 的文件/分支）。没有更窄的范围能满足写入叶子节点的需求。

### 可选的更严格范围

对于**只读**部署（dispatcher 侧的存活检查、证据收集），`read_api` 足够。Dev/review wrapper 需要 `api`。

## 自托管主机配置

`GITLAB_HOST` 默认为 `gitlab.com`。任何 API 通过标准 PAT 认证与 `/api/v4` 通信的自托管 CE/EE 实例都是一等目标——将 `GITLAB_HOST` 设置为裸主机名（无 scheme、无路径）。P3-1 传输将每个请求 URL 构造为 `https://${GITLAB_HOST}/api/v4/<path>`。

**自定义 CA / mTLS / 自签名证书。** 流水线将网络通道视为操作者拥有的；它不暴露树内 `GITLAB_CA_BUNDLE` 配置项。如果你的 `curl` 需要自定义证书包、自定义 CA、mTLS 客户端证书、cookie jar 或代理配置，通过操作者拥有的**传输 hook**（见下文）进行设置，该 hook 用你部署所需的任何 curl 参数重定义了 `_gl_http`。传输 hook 是接缝的唯一扩展点（#414 pillar 3）；它将你的自定义配置置于与默认传输相同的 fail-loud 预检（[INV-116]）之后。

## 配置 MergeMill.conf

取消注释并填充 `scripts/MergeMill.conf` 底部附近的 GitLab 块（示例文件默认全部注释掉，使仅 github 的配置文件与 #420 之前字节级相同）：

```bash
# === GitLab provider（ISSUE_PROVIDER=gitlab / CODE_HOST=gitlab）===

ISSUE_PROVIDER="gitlab"      # 如果仅 CODE_HOST 是 gitlab 则不设置
CODE_HOST="gitlab"           # 如果仅 ISSUE_PROVIDER 是 gitlab 则不设置

GITLAB_HOST="gitlab.com"                     # 或你的自托管主机
GITLAB_TOKEN="glpat-xxxxxxxxxxxxxxxxxxxx"    # PAT / 项目 / 组 token
GITLAB_PROJECT="group%2Fsubgroup%2Fproject"  # URL 编码的路径

# 可选；不设置则使用默认 curl 传输。
# GITLAB_TRANSPORT_HOOK="/path/to/operator-owned/hook.sh"
```

键——与 `skills/MergeMill-dispatcher/scripts/MergeMill.conf.example` 中的块匹配：

| 键 | 含义 | 备注 |
|-----|---------|-------|
| `ISSUE_PROVIDER` | 路由到哪个 ITP 接缝。 | `github`（默认）/ `gitlab` / `asana`（预留）。 |
| `CODE_HOST` | 路由到哪个 CHP 接缝。 | `github`（默认）/ `gitlab`。 |
| `GITLAB_HOST` | API 主机（无 scheme）。 | 默认为 `gitlab.com`。 |
| `GITLAB_TOKEN` | PAT / 项目 / 组访问 token。 | 范围：`api`。在每个请求中作为 `PRIVATE-TOKEN` 发送。 |
| `GITLAB_PROJECT` | 项目的 URL 编码 `namespace/name`（或 `group/subgroup/name`）。 | 以**已编码**形式存储（spec §3.4）。由叶子节点**逐字**使用——绝不重新编码。示例：`group%2Fsubgroup%2Fproject`。动态路径段（标签名、文件路径）单独通过 `_gl_urlencode` 处理。 |
| `GITLAB_TRANSPORT_HOOK` | 指向自定义传输 hook 的可选路径。 | 见下一节。 |

将 `GITLAB_TOKEN` 存储在版本控制之外。标准形式（与 github 侧匹配）是项目根目录中的 `.env.gitlab` 文件，已 gitignored，由 `MergeMill.conf` source：

```bash
# scripts/MergeMill.conf
if [[ -r .env.gitlab ]]; then
  # shellcheck disable=SC1091
  source .env.gitlab
fi
```

## 传输 Hook（自定义网关部署）

`_gl_http` 原语（P3-1 W-A，`providers/lib-gitlab-transport.sh`）是 GitLab 接缝的**唯一**公开覆盖点。将 `GITLAB_TRANSPORT_HOOK` 指向一个操作者拥有的 shell 文件，该文件按照 `docs/pipeline/provider-spec.md` §transport（[§3.5.1](pipeline/provider-spec.md#351-gitlab-transport-contract-transport--the-two-layer-choke-point)）中的冻结契约重定义 `_gl_http`，之后每个叶子节点继承你的自定义——代理、mTLS、自定义认证头等部署所需的任何内容。`_gl_api`（分页遍历器、`429`/`Retry-After` 退避、fail-CLOSED 策略）保持库拥有，因此变体传输无法静默退化这些保证。

**信任模型。** Hook 是**操作者拥有的本地代码**，由传输库在库初始化时、任何叶子节点运行之前 source。它具有与 `MergeMill.conf` 本身相同的权限——明确不是一个沙箱（#414 pillar 3）。不要将 `GITLAB_TRANSPORT_HOOK` 指向你不拥有的文件；传输库每个进程读取一次并执行其中发现的任何内容。

**预检。** 库以 fail-loud 方式拒绝配置错误的 hook（[INV-116]）：设置了 `GITLAB_TRANSPORT_HOOK` 但指向不可读路径，或 hook 未重定义 `_gl_http`，或 hook 的 `_gl_http` 体与默认值字节级相同（伪装为自定义传输的无操作 hook），都将在首次 `_gl_api` 调用时 fail-loud。

## Git 远程认证由操作者拥有

传输 hook 覆盖 **API** 通道（issues、merge requests、approvals、discussions、file API——ITP/CHP 叶子节点调用的所有内容）。它**不**覆盖 **git** 通道——dev Agent 对代码托管 git 远程执行的 `git push` / `git fetch`。该通道按设计在接缝之外（#414 pillar 3 的第二个扩展点）。

通过标准、操作者拥有的机制配置 git 远程认证：

- **SSH 远程**——将流水线用户的 SSH 密钥添加到拥有上述 token 的 GitLab 用户/项目/组，让 git 通过你的 SSH 配置解析 `git@${GITLAB_HOST}:group/subgroup/project.git`。
- **HTTPS 远程**——配置 git **凭据助手**（`git config --global credential.helper …`），为 `${GITLAB_HOST}` 返回 `GITLAB_TOKEN`。流水线本身不会写入你的 `.git-credentials` 文件。

Dev Agent 的 `git push` 使用你配置的远程；流水线不拦截、包装或覆盖它。

## 验证设置

1. 按上述在 `scripts/MergeMill.conf` 中填充 GitLab 键。
2. 确认配置文件仍能干净地 source：
   ```bash
   env -u PROJECT_DIR bash -c 'source scripts/MergeMill.conf && \
     printf "provider=%s host=%s project=%s\n" \
       "$ISSUE_PROVIDER" "$GITLAB_HOST" "$GITLAB_PROJECT"'
   ```
3. 针对 gitlab 轴端到端运行一致性套件（密封，无实时网络 I/O——夹具传输 hook 提供预设负载）：
   ```bash
   env -u PROJECT_DIR bash tests/provider-conformance/run-provider-conformance.sh \
     --itp gitlab --chp gitlab \
     --transport-hook tests/provider-conformance/fixtures/gitlab-hook/gitlab-transport-hook.sh
   ```
   在完全落地 P3-1..P3-4 树上预期 `CONFORMANCE-SUMMARY total=34 pass=32 fail=0 skip=2 pending=0`。两个 SKIP 是 `chp_request_changes`（`rest_request_changes=0`——GitLab 没有请求变更的 REST 动词）和 `chp_trigger_bot`（`review_bots=0`——gitlab 通道的初始审查 bot 姿态）。
4. 实时 GitLab 冒烟测试——操作者配置的标准 GitLab 项目，一个 `MergeMill` issue，一个 dev/review 周期——是父 #414 AC5 的合并后门控。

## 另见

- `docs/pipeline/provider-spec.md` §3.4（配置命名空间）、§3.5.1（传输契约）、§5.1（GitLab 按后端可行性）。
- `docs/pipeline/invariants.md` [INV-79]（Agent token 隔离）、[INV-116]（GitLab 传输预检）。
- `docs/github-app-setup.md`——本指南的 GitHub 侧对等文档；对照阅读以了解共享词汇（wrapper vs Agent、双 token 姿态、裁决 actor 检测）。
