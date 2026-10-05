<div align="center">

# MergeMill

**Issue → Dev Agent → Review Agent → 已合并的 PR**

*Issue → Dev Agent → Review Agent → Merged PR*

*Issue → Dev Agent → Review Agent → マージ済み PR*

<br>

**[🇨🇳 中文](#-中文)** &nbsp;|&nbsp; **[🇺🇸 English](#-english)** &nbsp;|&nbsp; **[🇯🇵 日本語](#-日本語)**

</div>

---

## 🇨🇳 中文

MergeMill 是一个自动化开发流水线，将 Issue 转化为 Pull Request，并按仓库策略完成审查与合并。合并审批受平台权限约束：例如 GitHub 不允许 PR 作者批准自己的 PR，因此需要其他有权限的 reviewer 或配置允许的合并流程。

它会扫描带有 `MergeMill` 标签的 Issue，调度一个 **Dev Agent（开发 Agent）** 在隔离的 worktree 中通过 TDD（测试驱动开发）实现功能，然后移交给 **Review Agent（审查 Agent）** 进行代码审查和可选的 E2E 验证。整个循环由 macOS launchd 每 300 秒无人值守调用。

### 特性

- **自动化开发闭环**：Issue 扫描、Agent 开发与审查、按仓库规则处理合并；可能需要人工审批
- **多 Agent CLI 支持**：Claude Code、Codex CLI、Kiro CLI、opencode、Cursor Agent、Antigravity CLI (agy)，以及所有支持 `-p <prompt>` 非交互式标志的 CLI
- **多平台**：GitHub 和 GitLab（gitlab.com 及自托管实例），通过可插拔 provider 接口接入
- **TDD 工作流**：测试用例文档 → 单元测试 → 实现 → 验证，强制覆盖率 >80%
- **多 Agent 审查**：可配置多个独立审查 Agent 并行运行，要求一致通过才合并
- **E2E 验证**：支持浏览器自动化（Chrome DevTools MCP）或命令行模式的端到端测试
- **可观测运行状态**：每次运行保存 run ID、attempt、日志和 Agent 结果；状态迁移写入 JSONL 事件，`status.sh` 可查看最近结果与下一次调度动作（`status.sh --all` 汇总所有相关 Issue，`--issue <n>` 选择单个，`--json` 输出稳定机器可读结构）
- **安全恢复**：`recover.sh` 默认只读；目前仅允许在开发 wrapper 的 PID/heartbeat 已失效且存在关联 PR 时，将 `in-progress` 转为 `pending-review`，其他情况拒绝自动修改

### 快速开始

**安装 skills：**

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | 描述 |
|-------|------|
| **MergeMill-dev** | TDD 工作流：git worktree 隔离、设计画布、测试优先开发、代码审查、CI 验证 |
| **MergeMill-review** | PR 代码审查：检查清单验证、合并冲突解决、E2E 测试、自动合并 |
| **MergeMill-dispatcher** | Issue 扫描器，由 macOS launchd 每 300 秒调度开发和审查 Agent |
| **MergeMill-common** | 共享的工作流强制 hooks 和 Agent 可调用的工具脚本 |
| **create-issue** | 结构化 Issue 创建器：模板、MergeMill 标签指导、工作区变更附件 |

**作为模板使用：**

```bash
gh repo create my-project --template panzi-hub/MergeMill
cd my-project
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
# 编辑 MergeMill.conf 填入项目配置
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
# 安装唯一的调度时钟（macOS launchd，每 300 秒）
bash scripts/install-dispatcher-timer.sh
```

### 工作原理

```
Issue（MergeMill 标签）
   │
   ▼
Dispatcher（launchd tick）──▶ Dev Agent ──────────▶ Review Agent
   扫描 + 调度               worktree + TDD       查找 PR + 审查
   并发控制 + 重试           实现 + 测试           可选 E2E 验证
                            创建 PR               审批 + 合并
```

Issue 通过 dispatcher 和 Agent 协作管理标签流转。Dispatcher 由 launchd 每 300 秒调用一次；标签是兼容状态投影，运行记录和迁移事件用于诊断。Agent 完成结果统一写入 `agent-result.json`，包含退出码和失败分类：

```
MergeMill → in-progress → pending-review → reviewing → approved（审查/合并完成）
      │              │                                  │
      │              └─ dead dev wrapper + linked PR → recover.sh 可安全转交
      │                                                 └─→ pending-dev（审查失败）
```

失败分类：transient / agent / code / policy / configuration。分类写入运行结果，供状态排查；dispatcher 仍保留现有 PID、heartbeat 与 dispatch marker 控制。Webhook 驱动和独立 lease 服务尚未实现。

### 安全性

**设计用于私有仓库和可信环境。** 流水线将 Issue 内容作为 Agent 指令执行——在公开仓库中这是一个 prompt 注入面。请阅读 **[docs/security.md](docs/security.md)** 了解风险模型和缓解措施。

### 文档索引

| 主题 | 位置 |
|---|---|
| 安装与配置 | [docs/installation.md](docs/installation.md) |
| Agent CLI 支持矩阵 | [docs/agent-clis.md](docs/agent-clis.md) |
| GitHub App 认证设置 | [docs/github-app-setup.md](docs/github-app-setup.md) |
| GitLab 设置 | [docs/gitlab-setup.md](docs/gitlab-setup.md) |
| 安全模型 | [docs/security.md](docs/security.md) |
| 流水线架构 | [docs/MergeMill-pipeline.md](docs/MergeMill-pipeline.md) |
| 跨 Agent Hook 支持 | [docs/cross-agent-hooks.md](docs/cross-agent-hooks.md) |
| CI 工作流设置 | [docs/github-actions-setup.md](docs/github-actions-setup.md) |
| 流水线规范 | [docs/pipeline/](docs/pipeline/) |

---

## 🇺🇸 English

MergeMill is an automated development pipeline that turns Issues into Pull Requests and completes review/merge according to repository policy. Platform permissions still apply: for example, GitHub does not allow a PR author to approve their own PR, so another authorized reviewer or an allowed merge path may be required.

It scans Issues labeled `MergeMill`, dispatches a **Dev Agent** to implement features through TDD in isolated worktrees, then hands off to a **Review Agent** for code review and optional E2E verification. The entire cycle is invoked unattended by a macOS launchd agent every 300 seconds.

### Features

- **Automated development loop**: issue scanning, agent implementation and review, with merge behavior governed by repository policy; human approval may be required
- **Multi-Agent CLI support**: Claude Code, Codex CLI, Kiro CLI, opencode, Cursor Agent, Antigravity CLI (agy), and any CLI accepting `-p <prompt>`
- **Multi-platform**: GitHub and GitLab (gitlab.com and self-hosted instances) via pluggable provider seams
- **TDD workflow**: Test case docs → unit tests → implementation → verification, enforcing >80% coverage
- **Multi-Agent review**: Configurable parallel independent review agents with unanimous-PASS gating
- **E2E verification**: Browser automation (Chrome DevTools MCP) or command-mode end-to-end testing
- **Run observability**: Each run records a run ID, attempt, logs, and normalized Agent result; state transitions are appended as JSONL events and surfaced by `status.sh` (`--all` for every relevant issue, `--issue <n>` for one, `--json` for a stable machine-readable object)
- **Guarded recovery**: `recover.sh` is read-only by default. Its current apply path only hands off `in-progress` to `pending-review` when the dev wrapper PID/heartbeat is stale and a linked PR exists; it refuses other cases

### Quick Start

**Install as skills:**

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | Description |
|-------|-------------|
| **MergeMill-dev** | TDD workflow: git worktree isolation, design canvas, test-first development, code review, CI verification |
| **MergeMill-review** | PR code review: checklist verification, merge conflict resolution, E2E testing, auto-merge |
| **MergeMill-dispatcher** | Issue scanner dispatched by a macOS launchd agent every 300 seconds |
| **MergeMill-common** | Shared workflow enforcement hooks and agent-callable utility scripts |
| **create-issue** | Structured issue creator: templates, MergeMill label guidance, workspace change attachment |

**Use as a template:**

```bash
gh repo create my-project --template panzi-hub/MergeMill
cd my-project
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
# Edit MergeMill.conf with your project settings
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
# Install the only dispatcher clock (macOS launchd, every 300s)
bash scripts/install-dispatcher-timer.sh
```

### How It Works

```
Issue (MergeMill label)
   │
   ▼
Dispatcher (launchd tick)──▶ Dev Agent ──────────▶ Review Agent
   scan + dispatch          worktree + TDD       find PR + review
   concurrency + retry      implement + test     optional E2E verify
                            create PR            approve + merge
```

The dispatcher and agents coordinate issue labels. The dispatcher is invoked by launchd every 300 seconds; labels are the backward-compatible state projection, while run records and transition events provide diagnostics. Agent completion is normalized in `agent-result.json` with an exit code and failure class:

```
MergeMill → in-progress → pending-review → reviewing → approved (review/merge complete)
      │              │                                  │
      │              └─ dead dev wrapper + linked PR → safe handoff via recover.sh
      │                                                 └─→ pending-dev (review failure)
```

Failure classes: transient / agent / code / policy / configuration. They are recorded for diagnosis; dispatch still relies on the existing PID, heartbeat, and dispatch-marker controls. Webhook-driven dispatch and a standalone lease service are not implemented yet.

### Security

**Designed for private repos and trusted environments.** The pipeline executes issue content as agent instructions — a prompt injection surface in public repos. Read **[docs/security.md](docs/security.md)** for the risk model and mitigations.

### Documentation Index

| Topic | Location |
|---|---|
| Installation & Configuration | [docs/installation.md](docs/installation.md) |
| Agent CLI Support Matrix | [docs/agent-clis.md](docs/agent-clis.md) |
| GitHub App Auth Setup | [docs/github-app-setup.md](docs/github-app-setup.md) |
| GitLab Setup | [docs/gitlab-setup.md](docs/gitlab-setup.md) |
| Security Model | [docs/security.md](docs/security.md) |
| Pipeline Architecture | [docs/MergeMill-pipeline.md](docs/MergeMill-pipeline.md) |
| Cross-Agent Hook Support | [docs/cross-agent-hooks.md](docs/cross-agent-hooks.md) |
| CI Workflow Setup | [docs/github-actions-setup.md](docs/github-actions-setup.md) |
| Pipeline Specification | [docs/pipeline/](docs/pipeline/) |

---

## 🇯🇵 日本語

MergeMill（マージミル）は、Issue から Pull Request までの開発を自動化し、リポジトリのポリシーに従ってレビューとマージを進めるパイプラインです。プラットフォームの権限規則は適用されます。たとえば GitHub では PR 作成者自身は承認できないため、別の権限を持つ reviewer、または許可されたマージ手順が必要な場合があります。

`MergeMill` ラベルが付いた Issue をスキャンし、**Dev Agent（開発エージェント）** を隔離された worktree にディスパッチして TDD（テスト駆動開発）で機能を実装、その後 **Review Agent（レビューエージェント）** に引き継いでコードレビューとオプションの E2E 検証を行います。全サイクルは macOS launchd が 300 秒ごとに無人実行します。

### 主な機能

- **開発の自動化**：Issue のスキャン、Agent による実装とレビューを行い、マージはリポジトリのポリシーに従います。人の承認が必要な場合があります
- **マルチ Agent CLI 対応**：Claude Code、Codex CLI、Kiro CLI、opencode、Cursor Agent、Antigravity CLI (agy)、および `-p <prompt>` 非対話フラグを受け付ける任意の CLI
- **マルチプラットフォーム**：GitHub および GitLab（gitlab.com とセルフホストインスタンス）をプラグ可能なプロバイダーインターフェースでサポート
- **TDD ワークフロー**：テストケース文書 → 単体テスト → 実装 → 検証、80% 以上のカバレッジを強制
- **マルチ Agent レビュー**：複数の独立したレビューエージェントを並列実行し、全会一致の PASS のみマージ
- **E2E 検証**：ブラウザ自動化（Chrome DevTools MCP）またはコマンドモードのエンドツーエンドテスト
- **実行状態の可視化**：run ID、attempt、ログ、正規化された Agent 結果を保存し、状態遷移を JSONL イベントに記録。`status.sh` で確認できます（`--all` で全対象 Issue、`--issue <n>` で単一、`--json` で安定した機械可読出力）
- **安全な復旧**：`recover.sh` はデフォルトで読み取り専用です。現在 `--apply` で許可されるのは、dev wrapper の PID/heartbeat が失効し、関連 PR がある場合の `in-progress` → `pending-review` のみです。それ以外は拒否します

### クイックスタート

**Skills としてインストール：**

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | 説明 |
|-------|------|
| **MergeMill-dev** | TDD ワークフロー：git worktree 隔離、デザインキャンバス、テストファースト開発、コードレビュー、CI 検証 |
| **MergeMill-review** | PR コードレビュー：チェックリスト検証、マージコンフリクト解決、E2E テスト、自動マージ |
| **MergeMill-dispatcher** | Issue スキャナー。macOS launchd が 300 秒ごとに開発・レビューエージェントをディスパッチ |
| **MergeMill-common** | 共有ワークフロー強制フックとエージェント呼び出し可能なユーティリティスクリプト |
| **create-issue** | 構造化 Issue 作成：テンプレート、MergeMill ラベルガイダンス、ワークスペース変更添付 |

**テンプレートとして使用：**

```bash
gh repo create my-project --template panzi-hub/MergeMill
cd my-project
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
# MergeMill.conf をプロジェクト設定で編集
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
# 唯一のディスパッチャークロックをインストール（macOS launchd、300 秒ごと）
bash scripts/install-dispatcher-timer.sh
```

### 仕組み

```
Issue（MergeMill ラベル）
   │
   ▼
Dispatcher（launchd tick）──▶ Dev Agent ──────────▶ Review Agent
   スキャン + ディスパッチ   worktree + TDD       PR 検出 + レビュー
   並列制御 + リトライ       実装 + テスト         オプション E2E 検証
                             PR 作成               承認 + マージ
```

Issue のラベル遷移は dispatcher と Agent が協調して管理します。dispatcher は launchd が 300 秒ごとに呼び出し、ラベルを後方互換の状態投影として使用します。実行記録と遷移イベントは診断用です。Agent の完了結果は終了コードと失敗分類を含む `agent-result.json` に統一されます：

```
MergeMill → in-progress → pending-review → reviewing → approved（レビュー/マージ完了）
      │              │                                  │
      │              └─ dev wrapper の PID/heartbeat が失効 + 関連 PR → recover.sh で安全に引き継ぎ
      │                                                 └─→ pending-dev（レビュー失敗）
```

失敗分類：transient / agent / code / policy / configuration。診断のため実行結果に記録します。dispatcher は引き続き PID、heartbeat、dispatch marker を使用します。Webhook 駆動と独立 lease サービスはまだ実装されていません。

### セキュリティ

**プライベートリポジトリと信頼できる環境向けに設計。** パイプラインは Issue の内容をエージェントの指示として実行します——公開リポジトリではプロンプトインジェクションの攻撃面となります。リスクモデルと緩和策については **[docs/security.md](docs/security.md)** をお読みください。

### ドキュメント索引

| トピック | 場所 |
|---|---|
| インストールと設定 | [docs/installation.md](docs/installation.md) |
| Agent CLI サポートマトリックス | [docs/agent-clis.md](docs/agent-clis.md) |
| GitHub App 認証設定 | [docs/github-app-setup.md](docs/github-app-setup.md) |
| GitLab 設定 | [docs/gitlab-setup.md](docs/gitlab-setup.md) |
| セキュリティモデル | [docs/security.md](docs/security.md) |
| パイプラインアーキテクチャ | [docs/MergeMill-pipeline.md](docs/MergeMill-pipeline.md) |
| クロス Agent フックサポート | [docs/cross-agent-hooks.md](docs/cross-agent-hooks.md) |
| CI ワークフロー設定 | [docs/github-actions-setup.md](docs/github-actions-setup.md) |
| パイプライン仕様 | [docs/pipeline/](docs/pipeline/) |

---

<div align="center">

**参考项目 &nbsp;|&nbsp; Based on &nbsp;|&nbsp; ベースプロジェクト**

[panzi-hub/MergeMill](https://github.com/panzi-hub/MergeMill)

**许可证 &nbsp;|&nbsp; License &nbsp;|&nbsp; ライセンス**

MIT License

</div>
