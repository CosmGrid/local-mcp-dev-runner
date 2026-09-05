# Local MCP Dev Runner

一个运行在你自己机器上的 **stdio MCP server**，让 ChatGPT（经由 Secure MCP Tunnel）能够 **只读** 地查看你本地已注册的 Git 仓库，并在严格受限的 runner-managed worktree 里做有限的写入。

版本：2.1.0 · 工具数：24 · 状态：V1 baseline + 结构化输出契约（A3）+ P2 沙箱执行 + 受限 GitHub 仓库管理

---

## 1. 它是什么

一个单文件的 MCP server（`server.mjs`），通过标准输入输出与 MCP 客户端通信。它对外暴露 24 个工具，覆盖：

| 类别 | 工具 |
| --- | --- |
| 注册表 | `list_projects`、`project_info` |
| 只读浏览 | `list_directory`、`find_files`、`search_text`、`read_file`、`read_files`、`file_info` |
| 受限写入 | `create_directory`、`create_file`、`replace_text`、`delete_file` |
| 只读 Git | `git_status`、`git_diff`、`git_log`、`git_branch_list` |
| 受控分支与工作区 | `git_create_branch`、`git_worktree_create`、`git_worktree_remove` |
| 受控提交 | `git_commit` |
| 脚本（**沙箱受控 · v2.0.0**） | `project_scripts`、`run_script`（仅 npm/pnpm，hash 钉死，macOS Seatbelt 沙箱） |
| 受限 GitHub 管理 | `github_repository_info`、`github_repository_create`（白名单组织、Keychain 凭证、幂等创建、无 push、无 delete） |

> **结构化输出（v1.1.0 新增）**：每个工具现在都声明了 `outputSchema`，成功返回在原有文本 `content` 之外还携带机器可解析的 `structuredContent`，MCP 客户端（ChatGPT 等）可以稳定地按字段名取值，而不必解析自由文本。输入契约（`inputSchema`）零变更。

## 2. 为什么存在

远程模型要帮你看代码，传统做法是上传代码或开放 shell，两者都不可接受。这个 runner 的取舍是：

- **代码不出本机。** 模型只能拿到你允许它拿到的那部分文本。
- **默认只读。** 原仓库一律 `write: false`。
- **要写就写到别处。** 唯一可写的目标是 runner 自己创建并登记的 git worktree。
- **执行受沙箱约束。** `run_script` 自 v2.0.0 起在 macOS Seatbelt 沙箱内受控执行（仅 npm/pnpm、hash 钉死、无网络、无 shell 逃逸），详见第 11 节与 [docs/P2_PROCESS_SANDBOX_DESIGN.md](docs/P2_PROCESS_SANDBOX_DESIGN.md)。

## 3. 架构

```
ChatGPT
   │  (MCP over the Secure MCP Tunnel)
   ▼
Secure MCP Tunnel            ← 网络边界；由 Tunnel 侧负责身份认证与加密
   │
   ▼
stdio MCP Runner             ← 本机进程，即本仓库的 server.mjs
   │
   ▼
registered project registry  ← $HOME/.config/local-mcp-dev-runner/projects.json
   │
   ├── original repo        READ_ONLY   （源码真值，永远不可写）
   └── managed worktree     READ_WRITE  （runner 自建，仅 mcp/* 分支）
```

关键点：runner 本身 **不监听端口、不做鉴权、不持有任何 API Key**。它与 Tunnel 之间是本机 stdio，认证与传输安全由 Tunnel 侧承担。详细的分层与信任边界见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 4. 安装

前置：Node.js >= 20.11，Git。

```bash
git clone <this-repo> local-mcp-dev-runner
cd local-mcp-dev-runner
npm ci
npm run gate:all          # 语法 + 安全门禁 + 测试 + 密钥扫描
bash scripts/install-local.sh
```

`install-local.sh` 只做三件事：校验源码构建、按需创建配置目录、把构建部署到 runtime。它 **不会** 启动 Tunnel，**不会** 碰任何凭据。

先演练再实装：

```bash
DRY_RUN=1 bash scripts/install-local.sh
```

## 5. 配置

真实配置 **不在本仓库里**，它在：

```
$HOME/.config/local-mcp-dev-runner/projects.json
```

这是 **runtime state**，不是源码。仓库里只有结构示例 `config/projects.example.json`，里面全是 `<PLACEHOLDER>`，没有用户名、绝对路径或密钥。

首次安装时，若 `projects.json` 不存在，安装脚本会用示例文件播种一份（权限 600）。**若已存在，脚本绝不覆盖。** 之后你需要手工替换其中的占位符：

```jsonc
{
  "projects": {
    "my-api": {
      "root": "<ABSOLUTE_PATH_TO_PROJECT_ROOT>",
      "write": false            // 原仓库：保持 false
    },
    "my-api-work": {
      "root": "<ABSOLUTE_PATH_TO_WRITABLE_ROOT>",
      "write": true,
      "runScripts": false,
      "allowedScripts": []
    }
  }
}
```

字段含义见 `config/projects.example.json` 内的 `_fieldReference`。

### 5.1 Trusted Workspace 自动发现

不想逐个登记项目时，可以声明一个你信任的开发 Workspace，Runner 会自动发现其中的 Git 仓库：

```jsonc
{
  "trustedWorkspaces": {
    "cosm": {
      "root": "/Users/me/Desktop/开发/CosmGrid",
      "maxDepth": 3,          // 可选，1-5，默认 3
      "enabled": true         // 可选，默认 true
    }
  }
}
```

发现行为：

- Workspace 内、扫描深度内的 Git 仓库会被自动发现，并作为 **READ_ONLY** 项目暴露，`runScripts=false`。
- `list_projects` 会合并「显式 `projects`」与「自动发现项目」，去重且按名称排序。
- `project_info` 对两者一视同仁，realpath / policy / 敏感路径 / 权限 / worktree 检查全部照旧。
- 命名：目录名全局唯一时用短名（如 `api`）；重名时用稳定 ID（如 `cosm/services/api`）。两种形式都可解析；用短名命中多个仓库时返回明确 ambiguity，绝不猜测。
- 优先级：**显式 `projects` 永远优先**。已手工登记的仓库不会重复暴露为自动发现项目。

安全边界：

- 自动发现 **永远不会** 授予 write / runScripts，任何试图从配置里抬升这些默认值的字段都会被忽略。
- 扫描不跨越 Workspace 的 realpath：不跟随符号链接、不进入 `node_modules` 等依赖目录、深度与目录数都有上限。
- 声明 `/`、`/Users`、`/System`、`/tmp` 这类过宽的根会被直接拒绝；Workspace 根不存在或不可读是硬错误（fail-closed），不会静默当成「空 Workspace」。

要写代码时流程不变：对自动发现的项目执行 `git_worktree_create`，得到 runner-managed 的 **READ_WRITE** worktree；原仓库本身仍是 READ_ONLY。

不配置 `trustedWorkspaces` 时，行为与本次改动前完全一致。

## 6. 启动

Runner 自己不常驻、不监听端口，由 MCP 客户端（Tunnel）拉起：

```bash
node server.mjs
```

日常不需要手工执行这条命令。修改源码后需要重新部署并重启 runner 进程：

```bash
bash scripts/update-runtime.sh
bash scripts/verify-runtime.sh
```

## 7. 开发

**只在 SOURCE_ROOT 改代码，永远不要直接编辑 RUNTIME_ROOT。**

```
SOURCE_ROOT  本仓库（唯一可编辑的地方）
RUNTIME_ROOT $HOME/.local/share/local-mcp-dev-runner   ← 部署目标，勿手改
```

流程：编辑 `server.mjs` → `npm run gate:all` → `bash scripts/update-runtime.sh` → 重启 runner 进程。

部署、回滚与运行手册见 [docs/OPERATIONS.md](docs/OPERATIONS.md)，两个根目录的职责划分见 [docs/SOURCE_VS_RUNTIME.md](docs/SOURCE_VS_RUNTIME.md)。

## 8. 测试

```bash
npm run check           # 语法门禁：全量 .mjs 解析
npm test                # 全部测试（tests/ + tests/security/ + tests/p2/；P2 真实沙箱用例在 tests/native/，须原生 Terminal 跑）
npm run test:security   # 仅安全套件
npm run test:inventory  # 仅工具清单
npm run gate:security   # 静态安全策略门禁（守卫是否仍存在于源码）
npm run gate:input-compat  # 输入契约 vs 基线 b2f907d（v2.0.0 run_script 沙箱化；其余 21 工具零变更）
npm run gate:schema        # 22/22 outputSchema 覆盖 + structuredContent 校验
npm run gate:secret-scan
npm run gate:p2-unit     # P2 单元/镜像/静态门禁（tests/p2，WorkBuddy 嵌套沙箱内可跑）
npm run gate:sandbox-real # 真实 macOS Seatbelt 沙箱门禁（须在原生 Terminal 跑，嵌套沙箱必 exit 71）
npm run gate:p2-full     # gate:p2-unit && gate:sandbox-real
npm run gate:all        # 以上静态/行为门禁（含 gate:p2-unit，不含 gate:sandbox-real）
npm run verify:runtime  # 校验已部署的 runtime（只读）
```

测试通过 **真实 MCP 协议** 驱动真实的 `server.mjs` 进程，而不是调用内部函数。每个用例都在一次性 HOME 下运行，注册表、worktree 根目录、git 全局配置全部重定向到临时目录，因此 **永远不会读写你真实的注册表和业务仓库**。机制说明见 [docs/GATES.md](docs/GATES.md)。

## 9. 安全边界

- 只有注册表里登记过的项目可访问，未登记一律 `Unknown project`。
- 原仓库恒为只读；写入只发生在 runner 自建的 worktree。
- 所有路径先做词法检查，再 `realpath` 解析，越界即拒绝；符号链接穿越被拦截。
- `.env`、`.git`、`*.key`、`credentials` 等敏感路径在读、写、列目录、搜索、提交各环节都被过滤。
- 写操作需要调用方提供当前文件的 SHA-256，防止覆盖并发改动。
- 只能创建 `mcp/*` 分支；`main` / `master` 等保护分支拒绝写入。
- 不提供 `push` / `pull` / `fetch`，不提供任意 shell。

完整清单与每项的失效后果见 [SECURITY.md](SECURITY.md)。

## 10. 当前限制

- **单文件实现。** v1.0 保留 1303 行的 `server.mjs` 作为已验证基线，未做模块化拆分，以降低改动风险。
- **无推送能力。** 分支必须在本机手工合并。
- **不执行任何脚本。** 不能跑测试、不能构建。
- **输出有上限。** 单文件读取 200 KB、写入 500 KB、搜索文件 512 KB、目录条目 500 条、搜索结果 200 条、diff 文件 100 个、输出统一裁剪 200 KB，超出会被截断或拒绝。
- **提交不做签名。** 强制 `commit.gpgSign=false`。
- **无并发协调。** SHA 校验是乐观锁，不是事务。

## 11. `run_script` 现在是沙箱受控执行（v2.0.0）

`run_script` 在 v1.0 / v1.1.0 里是永久关闭的：接口契约可见，但处理体第一行无条件抛错。v2.0.0 把它改造成在 **macOS Seatbelt（`sandbox-exec`）进程沙箱**内受控执行 npm / pnpm 脚本，而不是简单地打开开关。

开放的前提条件已被满足，但被严格约束：

- **只跑 npm / pnpm。** yarn / bun / npx 一律拒绝；`install` / `ci` / `add` 等安装类子命令永久 DENY——沙箱无网络，安装毫无意义，且会从远端拉取不可信代码。
- **hash 钉死。** 包内容（`packageSha256`）与脚本内容（`scriptSha256`）双重校验，执行前重读 `package.json` 防 TOCTOU；caller 还可额外传 `expectedPackageSha256` 做第三层校验。改一行 `package.json` 即 hash 失效、拒绝执行——这正是 v1.0 担心的「改一行绕开 allowlist」被结构性堵死。
- **OS 级隔离。** 沙箱 deny-by-default：无网络、只写 per-run HOME/TMP、只可读 runner 管理的 `mcp/*` worktree；真实 HOME / 系统目录 / 敏感文件全 seal。环境变量只透传显式 allowlist，绝不整体继承父进程环境；凭据形变量（如 `MY_API_TOKEN`、`AWS_SECRET_ACCESS_KEY`）不进沙箱。
- **无逃逸。** 无 shell、argv 结构化、stdio 全 pipe；`spawn` 调用点固定枚举为 2（主子进程 + `pgrep` 后代发现）；超时即 SIGTERM→SIGKILL 整进程组回收；kill switch 双通道（文件 + 环境变量）。

**真实的隔离验证必须在原生 Terminal 跑**：WorkBuddy 本身已是嵌套沙箱，`sandbox-exec` 会返回 `Operation not permitted`（exit 71），这是预期行为，门禁会 fail-closed 而非假 PASS。请在本机 Terminal.app 执行：

```bash
cd /path/to/local-mcp-dev-runner && bash scripts/run-native-sandbox-gate.sh
```

设计权威与全部冻结约束见 [docs/P2_PROCESS_SANDBOX_DESIGN.md](docs/P2_PROCESS_SANDBOX_DESIGN.md)。

## 12. 受限 GitHub 仓库管理（v2.1.0）

v2.1.0 引入受限的 GitHub 仓库管理工具集（`github_repository_info` 与 `github_repository_create`），用于在明确授权的组织下查询与自动创建空仓库：

- **核心边界声明：GitHub 仓库创建 != Git push！**
  - Runner **仅**通过 GitHub 官方 HTTPS REST API 建立或查询空仓库，**绝对不包含 `git push`、`git pull`、`git fetch` 等操作**。
  - 现有的 `NO_GIT_PUSH=YES` 安全边界与所有本地 Git 约束 100% 保持不变。
- **组织白名单（Organization Allowlist）：**
  - 必须在 `projects.json` 中明确配置 `github.allowedOrganizations`（例如 `["CosmGrid"]`）。
  - 任何未在白名单中的组织请求一律 **FAIL-CLOSED** 拒绝执行。
- **macOS Keychain 凭证管理：**
  - GitHub Token 绝对禁止写入代码、配置文件、环境变量、日志或返回给客户端。
  - 凭证存储于系统 macOS Keychain（服务名：`local-mcp-dev-runner-github-api-token`）。
  - 配置命令：
    ```bash
    security add-generic-password -s "local-mcp-dev-runner-github-api-token" -a "github" -w "<YOUR_GITHUB_TOKEN>"
    ```
  - Runner 仅在 API 请求瞬间在内存读取，用后即脱敏，凭证缺失时立即 FAIL-CLOSED。
- **严格幂等性与安全限制：**
  - 仓库已存在且可见性一致时，幂等返回 `ALREADY_EXISTS`，不重复创建。
  - 仓库已存在但可见性冲突时，返回 `GITHUB_VISIBILITY_CONFLICT`，拒绝自动更改。
  - 严禁包含删除仓库（`delete_repository`）、重命名、归档、修改可见性、变更权限等危险能力。
  - 固定 Host 为 `https://api.github.com`，防 SSRF 与任意 URL 注入。
  - 所有操作均记入 `$RUNTIME_ROOT/logs/github-audit.log` 审计日志，敏感字段全脱敏。

## 13. 许可与状态

私有项目，未对外发布。本仓库只建立本地 Git 仓库，不做 push。
