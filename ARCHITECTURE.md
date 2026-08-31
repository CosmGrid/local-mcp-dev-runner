# Architecture

## 1. 调用链

```
┌─────────────┐
│  ChatGPT    │  远程模型。发出的每个 tool call 都视为不可信输入。
└──────┬──────┘
       │  MCP over the Secure MCP Tunnel
       │  （身份认证、加密、Tunnel ID 均在这一层，不在本仓库职责内）
┌──────▼────────────────┐
│  Secure MCP Tunnel    │  把远程 MCP 请求转成对本机 stdio 进程的调用
└──────┬────────────────┘
       │  stdin / stdout（本机管道，无端口、无监听）
┌──────▼──────────────────────────────────────────────────┐
│  stdio MCP Runner  (server.mjs)                         │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ registered project registry                        │  │
│  │ $HOME/.config/local-mcp-dev-runner/projects.json   │  │
│  │ name -> { root, write, managedWorktree, branch }   │  │
│  └───────┬──────────────────────────────┬─────────────┘  │
│          │                              │                │
│  ┌───────▼──────────┐        ┌──────────▼─────────────┐  │
│  │ original repo    │        │ managed worktree       │  │
│  │ READ_ONLY        │        │ READ_WRITE             │  │
│  │ 源码真值         │◀──────▶│ 仅 mcp/* 分支          │  │
│  │ 永不写入         │  worktree│ runner 自建并登记    │  │
│  └──────────────────┘        └────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**信任边界只有一条：runner 与外部之间。** runner 与 git、与文件系统之间不存在边界——它就在你的用户身份下运行。所以所有防护都集中在"参数进来之后、动作发生之前"。

## 2. 两个根目录

v1.0 最重要的一条架构约束，是源码与运行时分离：

| | SOURCE_ROOT | RUNTIME_ROOT |
| --- | --- | --- |
| 路径 | 本仓库（检出位置由你决定） | `$HOME/.local/share/local-mcp-dev-runner` |
| 性质 | 版本控制的源码 | 部署产物 |
| 可否编辑 | **唯一可以改代码的地方** | 禁止手改，只能由脚本覆盖 |
| 内容 | server.mjs、package.json、测试、脚本、文档 | server.mjs、package.json、package-lock.json、node_modules、`sandbox/`、`worktrees/`、`logs/` |
| 有 `.git` 吗 | 有 | 没有 |
| 配置在哪 | 只有 `config/projects.example.json`（占位符） | 真实 `projects.json` 在 `$HOME/.config/...`，是第三处，两者都不是 |

三条铁律：

1. **开发只改 SOURCE_ROOT。** 直接编辑 RUNTIME_ROOT 的改动会在下次部署时静默消失。
2. **部署只走脚本。** `install-local.sh` / `update-runtime.sh` 保证原子替换与可回滚。
3. **配置不属于任何一侧。** 真实注册表是 runtime state，不进 Git，也不由部署脚本写入。

## 3. 一次写入请求的完整路径

以 `create_file` 为例，说明守卫的层叠顺序——每一层都可能提前终止：

```
1. resolveProject(name)              未登记 → "Unknown project"
2. assertProjectWriteAllowed()       write:false        → "Project is read-only"
                                     保护分支            → "Writes are blocked on protected branch"
                                     非 managed worktree 的 git 仓库且分支不是 mcp/* → 拒绝
3. assertSafeRelativeLexical()       绝对路径 / ".." / NUL 字节 → 拒绝
4. assertNotSensitive()              .env / .git / *.key / credentials → "Sensitive path is blocked"
5. resolveNewFileTarget()            realpath(parent) 越界   → "Parent path escapes registered project root"
                                     realpath(parent) != 词法 parent → "Writes through symlinked directories are blocked"
6. 大小上限校验                       超过 500 KB → 拒绝
7. 目标已存在校验                     已存在 → "Target file already exists"（需先 delete_file）
8. 写入 + 计算 SHA-256
```

读取路径（`read_file`）省略第 2、7 步，但保留 3–6 的全部检查，并在第 5 步改用"解析后仍须在项目内"的判定。

## 4. Git 写入路径

```
git_worktree_create(project, branch)
  ├─ project 必须是 READ_ONLY 的原仓库
  ├─ branch 必须以 mcp/ 开头          → 否则 "Branch must start with mcp/"
  ├─ assertSafeCheckoutConfig()        → 任何会真正执行的 filter 驱动 → 拒绝
  ├─ git worktree add -b <branch> <RUNTIME_ROOT>/worktrees/<name>
  └─ 注册表新增条目 { root, write:true, managedWorktree:true,
                      sourceProject, branch }

git_worktree_remove(project)
  ├─ 必须 managedWorktree:true        → 否则 "Only runner-managed worktrees can be removed"
  ├─ 先跑 --dry-run：脏则拒绝         → "Managed worktree is dirty; refusing removal"
  ├─ git worktree remove --force
  └─ 注册表移除该条目（分支保留，交由人决定是否合并）
```

分支命名空间 `mcp/*` 的意义：让"机器产生的改动"和"人的改动"在 `git branch` 里一眼可分，也让保护分支规则有稳定的判定依据。

## 5. 单文件实现的取舍

v1.0 保留了 1303 行的单文件 `server.mjs`，没有拆成模块。

理由：这个文件已经通过了 Final Gate 与真实工作流 Gate。在工作包目标是"把已验证实现固化成可版本控制的项目"的前提下，重构带来的收益小于它引入的风险——每拆一个文件，就要重新证明一遍那条路径上的守卫没被搬丢。

代价是文件较长、职责集中。若将来要拆分，正确顺序是：先确保每条守卫都有对应的行为测试（本仓库已具备 64 项），再拆，拆完立即跑全部门禁。

## 6. 测试如何做到不碰真实数据

`server.mjs` 的三个运行时路径都由环境变量派生：

```
CONFIG_FILE    = $HOME/.config/local-mcp-dev-runner/projects.json
WORKTREE_BASE  = $HOME/.local/share/local-mcp-dev-runner/worktrees
用户级 git attributes = $XDG_CONFIG_HOME/git/attributes  与  $HOME/.gitattributes
```

`os.homedir()` 在 POSIX 上遵循 `HOME` 环境变量。因此测试只要用**一次性 HOME** 拉起真实的 `server.mjs` 进程，注册表、worktree 根目录、git 全局配置就全部落到临时目录里。

**这意味着 `server.mjs` 里没有任何测试专用代码路径。** 部署到 RUNTIME_ROOT 的文件，与被测的文件，逐字节相同。

## 7. 结构化输出契约（v1.1.0 新增）

每个工具现在除了 `inputSchema` 之外，还声明一个 `outputSchema`（Zod 对象 → JSON Schema），并且成功返回除了文本 `content` 外，还携带机器可解析的 `structuredContent`。

- `structuredContent` 的字段与 `outputSchema` 严格对应，且 `additionalProperties: false`，所以客户端可以稳定地按字段名取值，而不必解析自由文本。
- 错误处理路径（`isError: true` 或抛出异常）不携带 `structuredContent`，沿用原有的文本错误消息，符合 MCP 协议语义。
- `run_script` 在 v1.0 / v1.1.0 中仍是无条件拒绝，其 `outputSchema` 仅为契约占位，运行时不可达。
- 输入契约（`inputSchema`）零变更：本工作包只新增输出侧契约，未触碰任何工具参数。输入兼容性由 `npm run gate:input-compat` 守护（与基线 commit `8137b48` 逐字段对比）。

相关测试见 `tests/schema.test.mjs`：既验证 22/22 工具都声明了 `outputSchema`，也用真实工具调用把 `structuredContent` 对照其声明的 `outputSchema` 做 JSON Schema 校验。

## 8. 相关文档

- [docs/SOURCE_VS_RUNTIME.md](docs/SOURCE_VS_RUNTIME.md) — 两个根目录的详细职责与判定规则
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — 部署、回滚、运行手册
- [docs/GATES.md](docs/GATES.md) — 每道门禁检查什么、为什么
- [SECURITY.md](SECURITY.md) — 安全模型
