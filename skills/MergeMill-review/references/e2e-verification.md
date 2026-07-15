# E2E 验证流程

> **此节仅在已配置 E2E 验证时适用。** 审查 wrapper 脚本（`MergeMill-review.sh`）将指示是否启用了 E2E 并在 prompt 中提供必要配置。

## 前置条件

审查脚本（`MergeMill-review.sh`）提取并提供：
- **预览 URL**：从 PR 评论中提取的预览 URL 或由审查 wrapper 提供
- **测试用户邮箱**：来自 `{E2E_TEST_USER_EMAIL}` 环境变量
- **测试用户密码**：来自 `{E2E_TEST_USER_PASSWORD}` 环境变量
- **截图上传脚本**：`scripts/upload-screenshot.sh` 用于上传截图到 GitHub

## 逐步流程

### 1. 验证预览 URL
- 检查 prompt 中是否提供了预览 URL
- 如果 `NOT_FOUND`，立即判定审查失败："E2E verification failed: PR preview URL not found"

### 2. 打开浏览器并导航
```
使用 Chrome DevTools MCP 工具：
1. new_page -> 打开一个全新浏览器页面
2. navigate_page -> 转到预览 URL
3. wait_for -> 确认页面加载（等待已知元素）
4. take_screenshot -> 捕获着陆页
5. 立即上传截图：
   bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "landing-page"
```

### 3. 使用测试用户登录
```
1. 点击 sign-in / login 按钮
2. fill -> 在邮箱字段中输入邮箱
3. fill -> 在密码字段中输入密码
4. 点击 submit / sign-in 按钮
5. wait_for -> 确认重定向到已认证页面（例如 dashboard）
6. take_screenshot -> 捕获已认证状态
7. 立即上传截图：
   bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "auth-login"
```

### 4. 执行正常路径测试用例
- 基于上述选择逻辑，执行选择的正常路径用例
- **关键**：每次 `take_screenshot` 后，必须立即运行上传命令：
  ```bash
  SCREENSHOT_URL=$(bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "<TC-ID>")
  ```
  保存返回的 URL 用于 E2E 报告表格。
- 对每个用例：
  1. 遵循用例定义中的详细步骤
  2. 使用 Chrome DevTools MCP 工具（navigate_page、click、fill、wait_for、type_text 等）
  3. 在关键验证点 `take_screenshot`
  4. **立即**上传每个截图：`bash scripts/upload-screenshot.sh "<path>" "<PR>" "<TC-ID>"`
  5. 使用上传的截图 URL 作为可点击链接 `[TC-ID](url)` 记录 PASS 或 FAIL

### 5. 执行功能测试用例
- 阅读 `docs/test-cases/<feature>.md` 了解审查的功能
- 对每个测试用例：
  1. 使用 Chrome DevTools MCP 工具按测试步骤操作
  2. 通过检查可见页面内容验证预期结果
  3. 在每个关键验证点 `take_screenshot`
  4. **立即**上传：`bash scripts/upload-screenshot.sh "<path>" "<PR>" "<TC-ID>"`
  5. 使用可点击链接 `[TC-ID](url)` 记录 PASS 或 FAIL

### 6. 回归检查
- **认证**：验证登录/注销正常
- **导航**：点击主要侧边栏链接，验证页面加载
- **控制台错误**：使用 `list_console_messages` 检查 JS 错误

### 7. 发布 E2E 报告
在 **PR**（不是 Issue）上发布结构化评论，格式如下：

```markdown
## E2E Verification Report

### Summary
| Total | Passed | Failed | Skipped |
|-------|--------|--------|---------|
| N     | X      | Y      | Z       |

### Happy Path Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-HP-001 | Generate 1-week plan | PASS | [TC-HP-001](<upload-script-returned-url>) |

### Feature Test Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-XXX-001 | Description | PASS | [TC-XXX-001](<upload-script-returned-url>) |

### Regression Tests
| Test | Status |
|------|--------|
| Auth login/logout | PASS |
| Navigation | PASS |
| Console errors | PASS |
```

## 正常路径测试用例

正常路径测试用例是项目特定的。审查 Agent 基于以下因素选择用例：

1. 阅读 `docs/test-cases/` 目录了解可用的测试用例文档
2. 分析 PR diff 以确定哪些区域发生了变化
3. 选择覆盖变更功能的最相关测试用例
4. 每次审查至少执行一个正常路径测试用例

如果没有测试用例文档，执行基本冒烟测试：
- 导航到应用根 URL
- 验证页面无错误加载
- 检查浏览器控制台是否有 JavaScript 错误

## 截图发布

在使用 Chrome DevTools MCP 在 E2E 验证期间截图时，**上传到 GitHub 并在 PR 评论中链接它们**。

> **私有仓库限制**：`![img](url)` 格式的内联图片在私有仓库中不会渲染，因为 `raw.githubusercontent.com` 需要认证而 GitHub 的 markdown 渲染器不注入认证。相反，使用指向 `/blob/` URL 的**可点击链接**——GitHub 的 Web UI 原生为有仓库访问权的已认证用户渲染 PNG 文件。

### 上传工作流

每次 `take_screenshot` 后，运行上传辅助脚本获取 GitHub blob URL：

```bash
# 用法：scripts/upload-screenshot.sh <png-path> <pr-number> <test-case-id>
# 返回：仓库成员可查看的 GitHub blob URL

URL=$(scripts/upload-screenshot.sh /tmp/screenshot.png 42 TC-HP-001)
# -> https://github.com/{REPO}/blob/screenshots/pr-42/TC-HP-001.png
```

在审查会话内部从终端执行上传：

```bash
SCREENSHOT_URL=$(bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "<TC-ID>")
```

### 链接格式

在 E2E 报告表格中使用可点击链接（而非内联图片）：

```markdown
| TC-HP-001 | Generate 1-week plan | PASS | [TC-HP-001](<uploaded-url>) |
```

### 回退行为

如果上传脚本失败（例如网络问题、权限错误）：
1. 脚本输出 `UPLOAD_FAILED` 作为 URL
2. 在 E2E 报告中描述观察到的视觉状态，而非链接截图：
   ```
   | TC-HP-001 | Generate 1-week plan | PASS | Screenshot upload failed. Verified: plan shows 7 days, each with video thumbnails, title "Python Basics" |
   ```
3. 继续审查——截图上传失败不应阻塞审查本身

### CI 截图

CI 工作流在 E2E 测试中自动捕获截图并将其作为构件上传：
- `e2e-screenshots-pr-<N>` 构件（5 天保留期）
- CI 发布的 PR 评论包含完整构件的下载链接
