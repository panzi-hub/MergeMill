# 贡献指南

感谢你对 `MergeMill` 的支持。此项目的变更遵循两条规则。

## 规则 1：流程优先，代码其次

这个项目的工作是协调三个自主 Agent（dispatcher、dev、review），通过共享的
GitHub Issue 标签状态机运行。这类系统中的 Bug 来自组件间的衔接缝，而非某个
组件的内部问题。我们在 dispatcher / wrapper 中修复的每一个 Bug 都追溯到一个
状态机边界情况——它在代码中是隐式的，但在文档中未被记录。

为了打破这种模式：**任何对流水线行为的变更必须在代码变更之前（或在同一 PR 中）
更新 [`docs/pipeline/`](docs/pipeline/)。**

### 什么是"流水线行为"变更

一个变更是流水线行为变更，如果它触及以下任一目录：

- `skills/MergeMill-dispatcher/scripts/**/*.sh`（递归——任意深度）
- `skills/MergeMill-dev/scripts/**/*.sh`（递归）
- `skills/MergeMill-review/scripts/**/*.sh`（递归）
- `skills/MergeMill-common/hooks/**/*.sh`（递归）
- `skills/MergeMill-common/scripts/**/*.sh`（递归）
- `skills/MergeMill-{dispatcher,dev,review,common}/SKILL.md`

（`**` glob 标记为便于人类阅读——CI 门控使用等价的 ERE 正则及 `.*` 匹配跨目录分隔符，
因此 `scripts/` 和 `hooks/` 的子目录均正确覆盖。）

如果你的 PR diff 触及上述任何路径，则必须同时也触及 `docs/pipeline/` 下的一个
或多个文件。CI 强制执行此规则——见
[`.github/workflows/pipeline-docs-gate.yml`](.github/workflows/pipeline-docs-gate.yml)。

### 在 `docs/pipeline/` 中写什么

选择正确的文件：

| 如果你的变更关于… | 更新… |
|---|---|
| 标签转换或新状态 | `state-machine.md` |
| dispatcher cron-tick 步骤 | `dispatcher-flow.md` |
| dev wrapper 生命周期、prompt 或 trap | `dev-agent-flow.md` |
| review wrapper 生命周期、决策门或尾部 | `review-agent-flow.md` |
| 两个角色间的交接（如 dev → review） | `handoffs.md` |
| 调试过程中发现的新跨横切规则 | `invariants.md`（新增 `INV-NN`）|

如果你的变更跨越上述多项，则逐项更新。

### 发现了新的不变量？写下来。

大多数流水线 Bug 暴露出一个先前隐式的不变量。修复 Bug 后，将规则添加到
[`docs/pipeline/invariants.md`](docs/pipeline/invariants.md)，分配一个新的
`INV-NN` ID，并包含：

- 一句话规则
- 引发此规则的 Bug（链接到 Issue / PR）
- 生产者（哪个角色必须维护）和消费者（哪个角色依赖它）
- 在何处测试（或 "TODO: add test"）

### 编辑或新增 mermaid 图表

`docs/pipeline/` 使用 mermaid 绘制状态机、时序图和流程图。**一个解析失败的
mermaid 块会在 github.com 上渲染为巨大的红色错误框——这比完全没有图表更糟糕。**
GitHub 通过 mermaid 10.x 客户端渲染；唯一可靠的验证方式是将代码推送到分支并
在 github.com 上查看渲染后的文件。`bash -n`、围栏代码块配对计数和文字审阅都无法
发现损坏的图表。

#### 需要避免的三个语法陷阱

以下问题导致 PR-2 ([#66](https://github.com/panzi-hub/MergeMill/pull/66))
首次提交中 7 个 mermaid 块中的 5 个失败：

1. **`stateDiagram-v2` 边标签或 `sequenceDiagram` 消息文本中不要使用 `;`。**
   Mermaid 将 `;` 视为语句分隔符，因此 `agent runs; eventually exits` 被解析
   为两条消息，第二条没有箭头。改用 `,` 或 `-` 或换个表述。

2. **在 `stateDiagram-v2` 的边标签中，字面量 `\n` 是两个字符 `\n`，不是换行符。**
   它不会渲染为换行。要么使用 `<br/>`（在 flowchart 中有效但在 stateDiagram 中
   实践效果不稳定），要么去掉换行写单行标签。`flowchart` 块对 `<br/>` 容忍度
   较好，优先选择它。

3. **flowchart `[]` 节点标签中不要使用双引号 `"..."`。** 内部的 `"` 会让解析器
   困惑。改用单引号 `'...'`，或换个表述完全避免引号。例如：
   `[comment "exited 0 but no PR"]` → `[comment 'exited 0 but no PR']`。

4. **避免在 `sequenceDiagram` 消息文本中使用 `<br/>`，并尽量减少 flowchart `[]`
   节点标签中的 `<br/>` 数量。** 这是一个*运行时布局错误*而非解析错误：
   d3-curve 标签定位遍历抛出 *"Could not find a suitable point for the given
   distance"* 并且图表在 github.com 上渲染为空框。失败在 feature 分支与 main
   分支间是非确定性的（GitHub 的 mermaid 渲染器不同缓存/版本），因此可能在 PR
   审查时所有块都显示正常，合并后却损坏——正是这种回归带来了此规则
   （[PR #66](https://github.com/panzi-hub/MergeMill/pull/66) 合并后）。
   优先使用单行消息和节点标签；如果标签感觉太长，将细节写在图表后面的文字描述中。

附注：`≥`、`≠`、`⇒`（Unicode 比较/箭头字符）渲染正常。标签中的括号也正常
（`[Step 1<br/>concurrency cap?]`）。节点标签中的 Unicode 减号 `−` 正常，但
`+` 和 `=` 紧邻标识符可能让解析器困惑——不确定时写成文字 `add`/`remove`。

#### 验证步骤（所有新增或编辑 mermaid 块的 PR 必须执行）

1. 将你的分支推送到 GitHub。
2. 计算 HEAD SHA：`gh pr view <N> --json headRefOid -q .headRefOid`（如果 PR
   尚未创建，则使用 commit SHA）。
3. 对于你修改的每个包含 mermaid 块的 `*.md` 文件，在浏览器中打开
   `https://github.com/<owner>/<repo>/blob/<sha>/<path>.md`。
4. 确认每个 mermaid 块渲染为图表（不是红色的"Parse error on line N"错误框）。
   渲染成功的块下方有"Open dialog"和"Copy mermaid code"按钮。
5. 如果使用安装了 chrome-devtools MCP 的 Claude Code，可通过
   `mcp__chrome-devtools__new_page` + `wait_for(["Parse error", "<图表后面的标题>"])`
   自动化验证——详见 [PR #66](https://github.com/panzi-hub/MergeMill/pull/66)
   的讨论。

如果某个块失败，本地修复，再次推送，重新验证。不要合并一个在 github.com 上
显示为损坏 mermaid 块的 PR。

**合并后，在 `main` 上再次验证。** GitHub 的 mermaid 渲染器
（`viewscreen.githubusercontent.com`）按 ref 缓存，feature 分支和 main 的缓存
可能命中不同的 mermaid 版本。在 PR head 上渲染正常的块可能在 main 上损坏
（上述规则 4 正是由此暴露的症状）。合并完成后打开
`https://github.com/<owner>/<repo>/blob/main/<path>.md`。

### 豁免通道：`pipeline-docs:none` 标签

有些 PR 确实没有改变流水线行为，即使它们触及了被监控的路径：

- 注释中的拼写/格式修复
- 依赖升级
- 恰好位于被监控路径下的 CI 工作流调整
- 纯粹的重构且无可观察的行为变化（罕见——通常仍会在 `state-machine.md` 中
  有所体现）

对于此类情况，向 PR 打上 `pipeline-docs:none` 标签。CI 门控将跳过文档必须检查。
该标签在 PR 列表视图中可审计，审查者可以追问"你确定吗？"。

如果仓库中尚未创建 `pipeline-docs:none`，维护者可执行：

```bash
gh label create pipeline-docs:none \
  --description "Explicitly attests this PR has no pipeline behavior change" \
  --color d4c5f9
```

### 实操示例

修复"MERGED PR 被当作开放依赖处理"的 Bug（#61）：

1. **首先**：编辑 [`docs/pipeline/dispatcher-flow.md`](docs/pipeline/dispatcher-flow.md)
   第 2 步，明确依赖检查接受 `CLOSED` 和 `MERGED` 两种状态。
2. 在 [`docs/pipeline/invariants.md`](docs/pipeline/invariants.md) 中新增不变
   量 `INV-11: Dependency state includes MERGED`。
3. **然后**：修改脚本以匹配文档化的行为。
4. 创建 PR。CI 门控检测到 diff 中同时包含 `skills/.../scripts/*.sh` 和
   `docs/pipeline/*.md` → 通过。

如果你先修改脚本再改文档，同样可以——只要它们在同一个 PR 中。CI 检查的是 PR
的整体 diff，而非逐 commit 的顺序。

## 规则 2：对自己使用 `MergeMill-dev` 工作流

本仓库的 TDD + worktree + 审查 bot 规范在 [`CLAUDE.md`](CLAUDE.md) 和
[`MergeMill-dev`](skills/MergeMill-dev/SKILL.md) skill 中已文档化。在此仓库
做贡献时请使用它们。`.claude/settings.json` 中的 hooks 将阻止：

- 在 `.worktrees/` 之外的 commit
- 直接推送到 `main`
- 落后于 `origin/main` 时的推送

不要用 `--no-verify` 绕过。如果 hook 触发，修复根本问题。

## CI 对 PR 的运行内容

CI 分为两层（[`ci.yml`](.github/workflows/ci.yml)，
[INV-77](docs/pipeline/invariants.md#inv-77-ci-is-two-tiers--hermetic-always-on--credential-free-live-agent-smoke-is-self-hosted-label-gated-and-advisory)）：

### 第 1 层 — hermetic（始终运行，无需凭据）

每个 PR 和 push 都在 GitHub 托管的 `ubuntu-latest` 上以**零凭据**运行
`hermetic-*` 任务：

- `hermetic-unit` — 所有 `tests/unit/*.sh`、适配器
  [一致性测试套件](tests/conformance/README.md)，以及 smoke / metrics /
  error-envelope 框架的 stub 模式自测。
- `hermetic-shellcheck` — 对 dispatcher 脚本的 ShellCheck 检查 + 对工作流的
  `actionlint` 检查。

由于 hermetic 层不需要密钥，**fork PR 或外部贡献者可获得完全绿色、完全有意义
的 CI**——你不需要任何 Agent CLI 认证即可通过 CI。这些检查是合并的门控条件
（分支保护必选项）。

### 第 2 层 — live agent-smoke（自托管、维护者门控、参考性）

`live-smoke` 任务在自托管 runner 上运行针对**真实** CLI 的
[#222 live agent-CLI smoke 矩阵测试](docs/pipeline/agent-smoke.md)。
它**仅在以下情况**运行：

- **维护者对 PR 打上 `run-live-smoke` 标签**（打标签需要写权限——这就是授权），
  **或者**
- 变更被推送到 `main`。

fork PR 自身无法触发 live 层（无标签 = 不调度），因为自托管 runner 绝不能
无条件执行不受信任的 PR 代码。live 层**仅作参考（非必须）**——配额受限的 CLI
返回 `UNAVAILABLE` 而不会导致任务失败，live 结果也不会阻止合并。其 SMOKE
证据会发布到运行的任务摘要中。

**作为外部贡献者，你永远不需要为 live 层做任何事**——如果需要进行 live 运行，
维护者会给你的 PR 打上标签。

> **维护者一次性设置：** live 矩阵配置必须存放在仓库 checkout **之外**
>（因为 `actions/checkout` 运行 `git clean -ffdx` 会删除 checkout 内的
> `tests/e2e/e2e.conf`）。
>
> > ⚠️ **仅从可信模板初始化——绝对不要从此 PR 的 checkout 初始化。** 对于已打
> > 标签的 fork PR，checkout 中的 `tests/e2e/e2e.conf.example` 是攻击者控制的
> > 内容，而 `run-agent-smoke.sh` 在自托管 runner 上 `eval` 每个条目的
> > `env-setup`——因此复制 checkout 副本会在 runner 上持久化任意 shell 代码。
> > 始终从 `main`（`?ref=main`）或本地可信克隆获取模板，**审查它**，然后初始化。
>
> 通过以下方式之一提供（按优先级）：
>
> 1. **`SMOKE_MATRIX` 仓库变量（推荐）**——将其设置为矩阵*内容*；`live-smoke`
>    任务在运行时将其物化到临时文件，因此在**自动扩缩容的自托管池**中可用
>    （每台机器的文件在池变化时会丢失）。仅维护者可操作；不得包含密钥
>    （Bedrock 条目使用 runner 实例角色）。从 `main` 上的模板初始化，审查，设置：
>    ```bash
>    gh api repos/<owner>/<repo>/contents/tests/e2e/e2e.conf.example?ref=main \
>      --jq '.content' | base64 -d > /tmp/smoke-matrix.tmpl   # 审查 + 编辑，然后：
>    gh variable set SMOKE_MATRIX --repo <owner>/<repo> --body-file /tmp/smoke-matrix.tmpl
>    ```
> 2. **`RUNNER_SMOKE_CONF` 仓库变量**——指向 runner 本地矩阵文件的路径 PATH。
> 3. **每台机器文件**，用于固定且长期存在的 runner，从 `main` 初始化（而非
>    checkout）：`gh api repos/<owner>/<repo>/contents/tests/e2e/e2e.conf.example?ref=main --jq '.content' | base64 -d > "$HOME/.config/MergeMill/e2e.conf"` 然后审查 + 编辑。
>
> `live-smoke` 任务在运行前检查这些，如果都未解析则失败并给出配置提示
>（列出全部三种来源）。一个**始终运行的 `live-smoke-status` 任务**也在每个 PR
> 上输出非失败的摘要，使未打标签的 PR 清楚地显示 live 层正等待维护者标签而有意跳过。

## PR 检查清单

创建 PR 前，确认：

- [ ] Worktree 在 `.worktrees/<branch>/` 下（而非主 checkout）
- [ ] 设计画布在 `docs/designs/<feature>.md`（对于非琐碎变更）
- [ ] 流水线文档已同步（规则 1）或已打上 `pipeline-docs:none` 标签
- [ ] 本地测试通过（至少对变更的 shell 脚本做 `bash -n`；如已安装则运行 shellcheck）
- [ ] 如果 PR 新增或编辑了任何 mermaid 块，每个块都已通过 github.com 上的目视验证（见上方"编辑或新增 mermaid 图表"）
- [ ] PR 正文中包含 `Closes #N`（如果修复了某个开放 Issue）
- [ ] 约定式 commit 风格的 PR 标题（`fix(dispatcher): ...`、`docs(pipeline): ...` 等）

审查者将首先检查规则 1。请省去往复修改的麻烦。
