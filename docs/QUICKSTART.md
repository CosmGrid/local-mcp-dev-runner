# Local MCP Dev Runner 快速开始指南

Local MCP Dev Runner 是一个运行在本地的 stdio MCP 服务。它允许 ChatGPT / Claude 等 MCP 客户端**安全地只读浏览**你本地注册的 Git 仓库，并在独立的、由 runner 管理的 **Git Worktree** 中进行受控修改。

---

## 1. 核心安全边界

- **默认只读**：主工程源码永远是 `write: false`，模型无法直接修改原仓库。
- **唯一可写面**：修改必须在独立的 `mcp/*` 分支工作区（Worktree）中进行。
- **敏感文件拦截**：`.env`、`.git`、私钥、密钥文件及父目录逃逸请求会被立即拒绝。
- **沙箱执行**：`run_script` 仅运行在 macOS Seatbelt 沙箱内（无网络、无 shell 拼接、必须在 package.json 与项目白名单内钉死 hash）。

---

## 2. 首次初始化与健康检查

在项目根目录运行初始化命令生成配置模板：

```bash
# 1. 生成初始配置文件（若已存在则会拒绝覆盖，保护现有配置）
node server.mjs --init

# 若确需重置覆盖现有配置，可追加 --force：
# node server.mjs --init --force

# 2. 检查环境就绪状态
node server.mjs --health-check
```

配置文件路径为：`~/.config/local-mcp-dev-runner/projects.json`（权限严格受控为 0600）。

---

## 3. 注册本地工程

编辑 `~/.config/local-mcp-dev-runner/projects.json`，添加你想要让 AI 访问的项目根目录：

```json
{
  "projects": {
    "my-app": {
      "root": "/path/to/my-app",
      "write": false
    }
  }
}
```

> **提示**：原仓库请务必保持 `"write": false`。

---

## 4. 日常使用工作流（搭配 ChatGPT / MCP 客户端）

与 ChatGPT 对话时的标准开发步骤：

1. **查看项目列表与目录**：
   - 对话：“请查看我注册的项目 `my-app` 的目录结构。”
   - 客户端调用：`list_projects`、`list_directory`、`read_file`。
2. **创建修改分支与隔离工作区**：
   - 对话：“我想开发新功能，请为 `my-app` 创建一个 worktree。”
   - 客户端调用：`git_worktree_create`（自动创建 `mcp/<feature>` 分支并注册为独立可写工程 `my-app-worktree`）。
3. **在工作区内修改与验证**：
   - 对话：“请在工作区内修改代码。”
   - 客户端调用：`create_file`、`replace_text`。
   - 检查变动：`git_status`、`git_diff`。
4. **提交代码**：
   - 对话：“请提交本次修改，附带提交信息。”
   - 客户端调用：`git_commit`（敏感文件自动过滤，不触发外部推送）。
5. **清理工作区**：
   - 对话：“本次任务已完成，请清理 worktree。”
   - 客户端调用：`git_worktree_remove`（保留 git 分支，安全移除临时目录）。

---

## 5. 常见错误与处理指引

| 错误信息 | 原因 | 下一步操作 |
| --- | --- | --- |
| `CONFIG_NOT_FOUND` | 配置文件不存在 | 运行 `node server.mjs --init` 生成配置模板 |
| `CONFIG_JSON_PARSE_ERROR` | `projects.json` 语法错误 | 检查 JSON 逗号/引号语法，或 `--init --force` 重新生成 |
| `Unknown project: <name>` | 项目未注册或拼写错误 | 检查 `projects.json` 配置或调用 `list_projects` |
| `Project is read-only` | 尝试直接修改只读原项目 | 调用 `git_worktree_create` 创建隔离工作区后再写入 |
| `Branch must start with mcp/` | 分支命名不符合规范 | 使用 `mcp/<feature-name>` 格式的分支名称 |
| `Sensitive path is blocked` | 访问了敏感文件（如 `.env`） | 涉及凭据的文件受到全局阻断，无法通过 MCP 读写 |
| `SANDBOX_BACKEND_UNAVAILABLE` | 沙箱执行环境不可用 | 脚本执行需 macOS 真实原生环境，嵌套沙箱环境自动保护性拒绝 |
