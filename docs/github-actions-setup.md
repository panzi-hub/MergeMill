# GitHub Actions CI 设置指南

本文档提供完整的 GitHub Actions CI 工作流配置。

## 为什么需要手动设置？

GitHub 要求 token 具有 `workflow` 范围才能通过 API 创建或修改工作流文件。这是一项安全措施，防止未经授权的工作流修改。

## 添加 CI 工作流

### 步骤

1. 在仓库中创建目录：`.github/workflows/`
2. 创建文件：`.github/workflows/ci.yml`
3. 将以下内容复制到文件中

### CI 工作流配置

```yaml
name: CI

on:
  push:
    branches: [main, master]
  pull_request:
    branches: [main, master]

# 取消同一分支正在进行的运行
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  lint:
    name: Lint & Type Check
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run linter
        run: npm run lint

      - name: Run type check
        run: npm run typecheck

  test:
    name: Unit Tests
    runs-on: ubuntu-latest
    needs: lint
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Run tests
        run: npm test -- --coverage

      - name: Upload coverage report
        uses: codecov/codecov-action@v4
        if: always()
        with:
          token: ${{ secrets.CODECOV_TOKEN }}
          files: ./coverage/lcov.info
          fail_ci_if_error: false

  build:
    name: Build
    runs-on: ubuntu-latest
    needs: [lint, test]
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Build
        run: npm run build

      - name: Upload build artifacts
        uses: actions/upload-artifact@v4
        with:
          name: build
          path: dist/
          retention-days: 7
```

## E2E 测试配置（可选）

如果需要 E2E 测试，在以上配置中添加以下 job：

```yaml
  e2e:
    name: E2E Tests
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'

      - name: Install dependencies
        run: npm ci

      - name: Install Playwright browsers
        run: npx playwright install --with-deps

      - name: Download build artifacts
        uses: actions/download-artifact@v4
        with:
          name: build
          path: dist/

      - name: Run E2E tests
        run: npm run test:e2e

      - name: Upload test results
        uses: actions/upload-artifact@v4
        if: always()
        with:
          name: playwright-report
          path: playwright-report/
          retention-days: 7
```

## 自定义

根据项目需求，你可能需要调整：

1. **Node.js 版本**：修改 `node-version` 参数
2. **包管理器**：如果使用 yarn 或 pnpm，相应修改安装命令
3. **测试命令**：根据 `package.json` 调整测试命令
4. **构建输出目录**：将 `dist/` 改为实际的输出目录
5. **分支名称**：如果主分支不是 `main` 或 `master`，相应调整

## 必需的 Secrets

要使用 CI 工作流，需要配置以下 GitHub secrets：

### CODECOV_TOKEN（可选但推荐）

用于安全的覆盖率报告上传：

1. 在 [codecov.io](https://codecov.io) 注册并连接你的仓库
2. 从 Codecov 获取仓库上传 token
3. 将其添加为 GitHub secret：
   - 进入仓库 → Settings → Secrets and variables → Actions
   - 点击 "New repository secret"
   - Name：`CODECOV_TOKEN`
   - Value：你的 Codecov 上传 token

> **注意**：没有 token，覆盖率上传可能失败或存在安全问题。
