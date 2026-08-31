# Local MCP Dev Runner

一个运行在你自己机器上的 **stdio MCP server**，让 ChatGPT（经由 Secure MCP Tunnel）能够 **只读** 地查看你本地已注册的 Git 仓库，并在严格受限的 runner-managed worktree 里做有限的写入。

版本：1.0.0 · 工具数：22 · 状态：V1 baseline（已通过 Final Gate 与真实工作流 Gate）

---

## 1. 它是什么

一个单文件的 MCP server（`server.mjs`），通过标准输入输出与 MCP 客户端通信。它对外暴露 22 个工具，覆盖：

| 类别 | 工具 |
| --- | --- |
| 注册表 | `list_projects`、`project_info` |
| 只读浏览 | `list_directory`、`find_files`、`search_text`、`read_file`、`read_files`、`file_info` |
| 受限写入 | `create_directory`、`create_file`、`replace_text`、`delete_file` |
| 只读 Git | `git_status`、`git_diff`、`git_log`、`git_branch_list` |
| 受控分支与工作区 | `git_create_branch`、`git_worktree_create`、`git_worktree_remove` |
| 受控提交 | `git_commit` |
| 脚本（**永久关闭**） | `project_scripts`、`run_script` |

## 2. 为什么存在

远程模型要帮你看代码，传统做法是上传代码或开放 shell，两者都不可接受。这个 runner 的取舍是：

- **代码不出本机。** 模型只能拿到你允许它拿到的那部分文本。
- **默认只读。** 原仓库一律 `write: false`。
- **要写就写到别处。** 唯一可写的目标是 runner 自己创建并登记的 git worktree。
- **不给 shell。** `run_script` 在 v1.0 里被硬编码关闭，见下。

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
npm test                # 全部测试（当前 64 项）
npm run test:security   # 仅安全套件
npm run test:inventory  # 仅工具清单
npm run gate:security   # 静态安全策略门禁（守卫是否仍存在于源码）
npm run gate:secret-scan
npm run gate:all        # 以上全部
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

## 11. 为什么 `run_script` 默认关闭

`run_script` 存在的意义是保留接口契约，让人能从 `project_scripts` 看到项目有哪些脚本。但它的实现体第一行就是无条件抛错：

```js
async ({ project }) => {
  await resolveProject(project);
  throw new Error("run_script is disabled in v1.0 security profile until an OS/process sandbox is added");
}
```

理由很直接：**这个 runner 没有任何进程级沙箱。** 它跑在你的用户身份下，能读你所有的 SSH key、浏览器 cookie 和云凭据。一旦开放"按项目 package.json 里的名字执行脚本"，攻击者只需要往仓库里塞一个 `postinstall` 或改一行 `scripts.test`，就能把"执行测试"变成"执行任意命令"。allowlist 也挡不住这种攻击，因为脚本内容是仓库的一部分，而仓库内容正是被操纵的对象。

所以 v1.0 的选择是：宁可没有这个能力，也不给一条绕过路径。将来要开放，前置条件是引入真正的 OS 级隔离（容器 / seccomp / 独立低权限用户），再按脚本内容哈希做 allowlist。在此之前，这个开关不应被打开。

## 12. 许可与状态

私有项目，未对外发布。本仓库只建立本地 Git 仓库，不做 push。
