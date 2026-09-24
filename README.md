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

MergeMill 是一个全自动开发流水线，将 Issue 转化为已合并的 Pull Request——无需人工干预。

它会扫描带有 `MergeMill` 标签的 Issue，调度一个 **Dev Agent（开发 Agent）** 在隔离的 worktree 中通过 TDD（测试驱动开发）实现功能，然后移交给 **Review Agent（审查 Agent）** 进行代码审查和可选的 E2E 验证。整个循环按 cron 定时无人值守运行。

### 特性

- **全自动闭环**：Issue 创建 → 自动开发 → 自动审查 → 自动合并，零人工参与
- **多 Agent CLI 支持**：Claude Code、Codex CLI、Kiro CLI、opencode、Cursor Agent、Antigravity CLI (agy)，以及所有支持 `-p <prompt>` 非交互式标志的 CLI
- **多平台**：GitHub 和 GitLab（gitlab.com 及自托管实例），通过可插拔 provider 接口接入
- **TDD 工作流**：测试用例文档 → 单元测试 → 实现 → 验证，强制覆盖率 >80%
- **多 Agent 审查**：可配置多个独立审查 Agent 并行运行，要求一致通过才合并
- **E2E 验证**：支持浏览器自动化（Chrome DevTools MCP）或命令行模式的端到端测试
- **崩溃恢复**：僵死检测 + 会话恢复，支持从上次中断处继续

### 快速开始

**安装 skills：**

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | 描述 |
|-------|------|
| **MergeMill-dev** | TDD 工作流：git worktree 隔离、设计画布、测试优先开发、代码审查、CI 验证 |
| **MergeMill-review** | PR 代码审查：检查清单验证、合并冲突解决、E2E 测试、自动合并 |
| **MergeMill-dispatcher** | Issue 扫描器，按 cron 定时调度开发和审查 Agent |
| **MergeMill-common** | 共享的工作流强制 hooks 和 Agent 可调用的工具脚本 |
| **create-issue** | 结构化 Issue 创建器：模板、MergeMill 标签指导、工作区变更附件 |

**作为模板使用：**

```bash
gh repo create my-project --template panzi-hub/MergeMill
cd my-project
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
# 编辑 MergeMill.conf 填入项目配置
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
# 启动调度器
*/5 * * * * cd /path/to/project && bash skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh
```

### 工作原理

```
Issue（MergeMill 标签）
   │
   ▼
Dispatcher（cron tick）──▶ Dev Agent ──────────▶ Review Agent
   扫描 + 调度               worktree + TDD       查找 PR + 审查
   并发控制 + 重试           实现 + 测试           可选 E2E 验证
                            创建 PR               审批 + 合并
```

Issue 通过 Agent 自动管理的标签流转：

```
MergeMill → in-progress → pending-review → reviewing → approved（已合并）
                                                 │
                                                 └─→ pending-dev（审查失败则回到开发循环）
```

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

MergeMill is a fully automated development pipeline that turns Issues into merged Pull Requests — with zero human intervention.

It scans Issues labeled `MergeMill`, dispatches a **Dev Agent** to implement features through TDD in isolated worktrees, then hands off to a **Review Agent** for code review and optional E2E verification. The entire cycle runs unattended on a cron schedule.

### Features

- **Fully automated loop**: Issue creation → auto development → auto review → auto merge, without human involvement
- **Multi-Agent CLI support**: Claude Code, Codex CLI, Kiro CLI, opencode, Cursor Agent, Antigravity CLI (agy), and any CLI accepting `-p <prompt>`
- **Multi-platform**: GitHub and GitLab (gitlab.com and self-hosted instances) via pluggable provider seams
- **TDD workflow**: Test case docs → unit tests → implementation → verification, enforcing >80% coverage
- **Multi-Agent review**: Configurable parallel independent review agents with unanimous-PASS gating
- **E2E verification**: Browser automation (Chrome DevTools MCP) or command-mode end-to-end testing
- **Crash recovery**: Stale detection + session resume, picking up from the last checkpoint

### Quick Start

**Install as skills:**

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | Description |
|-------|-------------|
| **MergeMill-dev** | TDD workflow: git worktree isolation, design canvas, test-first development, code review, CI verification |
| **MergeMill-review** | PR code review: checklist verification, merge conflict resolution, E2E testing, auto-merge |
| **MergeMill-dispatcher** | Issue scanner that dispatches dev/review agents on a cron schedule |
| **MergeMill-common** | Shared workflow enforcement hooks and agent-callable utility scripts |
| **create-issue** | Structured issue creator: templates, MergeMill label guidance, workspace change attachment |

**Use as a template:**

```bash
gh repo create my-project --template panzi-hub/MergeMill
cd my-project
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
# Edit MergeMill.conf with your project settings
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
# Start the dispatcher
*/5 * * * * cd /path/to/project && bash skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh
```

### How It Works

```
Issue (MergeMill label)
   │
   ▼
Dispatcher (cron tick)──▶ Dev Agent ──────────▶ Review Agent
   scan + dispatch          worktree + TDD       find PR + review
   concurrency + retry      implement + test     optional E2E verify
                            create PR            approve + merge
```

Issues flow through labels managed automatically by agents:

```
MergeMill → in-progress → pending-review → reviewing → approved (merged)
                                                 │
                                                 └─→ pending-dev (back to dev on review failure)
```

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

MergeMill（マージミル）は、Issue をマージ済みの Pull Request に変換する完全自動開発パイプラインです——人の介入は一切不要です。

`MergeMill` ラベルが付いた Issue をスキャンし、**Dev Agent（開発エージェント）** を隔離された worktree にディスパッチして TDD（テスト駆動開発）で機能を実装、その後 **Review Agent（レビューエージェント）** に引き継いでコードレビューとオプションの E2E 検証を行います。全サイクルは cron スケジュールで無人実行されます。

### 主な機能

- **完全自律ループ**：Issue 作成 → 自動開発 → 自動レビュー → 自動マージ、人の関与ゼロ
- **マルチ Agent CLI 対応**：Claude Code、Codex CLI、Kiro CLI、opencode、Cursor Agent、Antigravity CLI (agy)、および `-p <prompt>` 非対話フラグを受け付ける任意の CLI
- **マルチプラットフォーム**：GitHub および GitLab（gitlab.com とセルフホストインスタンス）をプラグ可能なプロバイダーインターフェースでサポート
- **TDD ワークフロー**：テストケース文書 → 単体テスト → 実装 → 検証、80% 以上のカバレッジを強制
- **マルチ Agent レビュー**：複数の独立したレビューエージェントを並列実行し、全会一致の PASS のみマージ
- **E2E 検証**：ブラウザ自動化（Chrome DevTools MCP）またはコマンドモードのエンドツーエンドテスト
- **クラッシュリカバリ**： stale 検出 + セッション復旧、中断点からの再開

### クイックスタート

**Skills としてインストール：**

```bash
npx skills add panzi-hub/MergeMill
```

| Skill | 説明 |
|-------|------|
| **MergeMill-dev** | TDD ワークフロー：git worktree 隔離、デザインキャンバス、テストファースト開発、コードレビュー、CI 検証 |
| **MergeMill-review** | PR コードレビュー：チェックリスト検証、マージコンフリクト解決、E2E テスト、自動マージ |
| **MergeMill-dispatcher** | Issue スキャナー、cron で開発・レビューエージェントを定期的にディスパッチ |
| **MergeMill-common** | 共有ワークフロー強制フックとエージェント呼び出し可能なユーティリティスクリプト |
| **create-issue** | 構造化 Issue 作成：テンプレート、MergeMill ラベルガイダンス、ワークスペース変更添付 |

**テンプレートとして使用：**

```bash
gh repo create my-project --template panzi-hub/MergeMill
cd my-project
cp scripts/MergeMill.conf.example scripts/MergeMill.conf
# MergeMill.conf をプロジェクト設定で編集
( source scripts/MergeMill.conf && bash scripts/setup-labels.sh "$REPO" )
# ディスパッチャーを起動
*/5 * * * * cd /path/to/project && bash skills/MergeMill-dispatcher/scripts/dispatcher-tick.sh
```

### 仕組み

```
Issue（MergeMill ラベル）
   │
   ▼
Dispatcher（cron tick）──▶ Dev Agent ──────────▶ Review Agent
   スキャン + ディスパッチ   worktree + TDD       PR 検出 + レビュー
   並列制御 + リトライ       実装 + テスト         オプション E2E 検証
                             PR 作成               承認 + マージ
```

Issue はエージェントが自動管理するラベルで状態遷移：

```
MergeMill → in-progress → pending-review → reviewing → approved（マージ済み）
                                                 │
                                                 └─→ pending-dev（レビュー失敗で開発ループに戻る）
```

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
