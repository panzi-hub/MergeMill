# Commit 和分支约定

分支命名、commit 消息和 PR 管理标准。

## 分支命名约定

| 类型 | 模式 | 示例 | 用例 |
|------|---------|---------|----------|
| 功能 | `feat/<name>` | `feat/user-config-api` | 新功能 |
| Bug 修复 | `fix/<name>` | `fix/websocket-connection` | Bug 修复 |
| 重构 | `refactor/<name>` | `refactor/openresty-container` | 代码重构 |
| 文档 | `docs/<name>` | `docs/runtime-routing` | 文档更新 |
| 测试 | `test/<name>` | `test/e2e-isolation` | 测试添加 |
| 杂务 | `chore/<name>` | `chore/update-deps` | 维护任务 |

### 分支命名指南

- 使用小写和连字符
- 保持名称简洁但有描述性
- 避免特殊字符
- 如适用，包含工单/Issue 编号：`feat/GH-123-user-auth`

## Commit 消息格式

```
type(scope): description

[可选正文]

[可选页脚]
```

### 类型

| 类型 | 描述 | 示例 |
|------|-------------|---------|
| `feat` | 新功能 | `feat(auth): add Cognito user pool` |
| `fix` | Bug 修复 | `fix(runtime): correct URL rewriting` |
| `docs` | 文档 | `docs(readme): update deployment steps` |
| `refactor` | 代码重构 | `refactor(edge): extract Lambda handler` |
| `test` | 测试 | `test(e2e): add user isolation tests` |
| `chore` | 维护 | `chore(deps): update CDK to v2.100` |
| `perf` | 性能 | `perf(query): optimize database queries` |
| `style` | 格式 | `style(lint): fix eslint warnings` |
| `ci` | CI/CD 变更 | `ci(workflow): add security scan` |

### 范围

根据项目结构定义范围。常见示例：

| 范围 | 区域 |
|-------|------|
| `auth` | 认证 |
| `api` | API 端点 |
| `ui` | 用户界面 |
| `db` | 数据库 |
| `security` | 安全配置 |
| `test` | 测试基础设施 |
| `e2e` | 端到端测试 |
| `design` | 设计画布/Pencil 文件 |

### 消息指南

- 使用祈使语气："add" 而非 "added" 或 "adds"
- 首行不超过 72 字符
- 不以句号结尾
- 类型/范围后首字母大写

**好的示例**：
```
feat(auth): add user-scoped settings storage
fix(runtime): correct localhost URL rewriting
docs(readme): update deployment prerequisites
test(e2e): add TC-019 secrets isolation test
design(ui): create login page mockup in Pencil
```

**坏的示例**：
```
Added new feature.              # 过去式，模糊，有句号
fix stuff                       # 无范围，过于模糊
FEAT(AUTH): ADD USER AUTH       # 全大写
feat(auth): added user auth.    # 过去式，有句号
```

## PR 检查参考

### CI 检查

| 检查 | 描述 | 常见失败原因 |
|-------|-------------|-----------------|
| `build-and-test` | TypeScript 构建 + Jest + pytest | 编译错误、测试失败 |
| `security-checks` | npm audit、密钥扫描 | 有漏洞的依赖 |
| `infrastructure-scan` | Checkov、cfn-lint | IaC 最佳实践 |
| `dependency-check` | OWASP 依赖检查 | 已知漏洞 |

### 审查 Bot

| Bot | 用途 | 响应策略 |
|-----|---------|-------------------|
| Amazon Q Developer | 安全和代码审查 | 修复问题或说明设计决策 |
| Codex | AI 代码审查 | 修复问题或说明设计决策 |
| Dependabot | 依赖更新 | 审查并在安全时合并 |

### 检查状态值

| 状态 | 含义 | 操作 |
|--------|---------|--------|
| `SUCCESS` | 检查通过 | 继续 |
| `FAILURE` | 检查失败 | 修复问题 |
| `PENDING` | 仍在运行 | 等待 |
| `SKIPPED` | 不适用 | 忽略 |

## PR 标题约定

遵循与 commit 消息相同的格式：

```
type(scope): brief description
```

控制在 72 字符以内。

**示例**：
```
feat(user-config): add user configuration API
fix(security): implement user-scoped settings stores
docs(e2e): add TC-019 and TC-020 test cases
design(dashboard): create analytics dashboard mockup
```

## PR 描述模板

```markdown
## Summary
<1-3 bullet points describing the change>

## Design
- [ ] Design canvas created (`docs/designs/<feature>.pen`)
- [ ] Design approved by user

## Changes
- List of specific changes made

## Test Plan
- [ ] Unit tests pass (`npm run test`)
- [ ] E2E tests verified
- [ ] Manual verification completed

## Related Issues
Closes #<issue_number>
```

## 合并策略

1. **Squash and merge** - 功能分支默认策略
2. **Rebase and merge** - 用于保持干净历史
3. **Merge commit** - 极少使用，保留完整历史

合并前：
- 所有 CI 检查必须通过
- 所有审查线程必须解决
- 至少一个批准（如需要）
- 设计画布已批准（如适用）
