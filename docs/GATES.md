# GATES

每道门禁检查什么，以及为什么需要它（而不是被别的门禁覆盖）。

## 总览

| 命令 | 类型 | 检查内容 | 耗时 |
| --- | --- | --- | --- |
| `npm run check` | 静态 | 全量 `.mjs` 能否解析 | 快 |
| `npm run gate:security` | 静态 | 守卫字符串是否仍在源码；禁止构造是否未出现；`.gitignore` 必要条目是否仍在 | 快 |
| `npm run test:inventory` | 行为 | 22 个工具，名称集合精确匹配 | 中 |
| `npm run test:security` | 行为 | 全部安全守卫真的会拒绝 | 中 |
| `npm test` | 行为 | 以上两组 | 中 |
| `npm run gate:secret-scan` | 静态 | 待提交文件中有无密钥 / 绝对路径 / 用户名 | 快 |
| `npm run gate:input-compat` | 静态/行为 | 与基线 `8137b48` 对比每个工具的 inputSchema 与名称，零变更才 PASS | 中 |
| `npm run gate:schema` | 行为 | 运行 `tests/schema.test.mjs`：22/22 outputSchema 覆盖 + structuredContent 对照校验 | 中 |
| `npm run gate:all` | 组合 | check → gate:security → gate:inventory → test → gate:input-compat → gate:schema → gate:secret-scan | 中 |
| `npm run verify:runtime` | 只读校验 | 已部署 runtime 是否健康、是否与源码漂移 | 中 |

## 1. 语法门禁 `scripts/check-syntax.mjs`

递归找出所有 `.mjs`（跳过 `node_modules`、`.git`、`coverage`、`dist`、`build`、`out`），逐个 `node --check`。

为什么单独存在：`node --test` 只会执行测试文件，`scripts/` 与 `server.mjs` 之外的辅助脚本语法错误不会被任何测试捕获。

若一个文件都没找到，它**报错退出**，不做"零文件通过"的空转。

## 2. 安全策略门禁 `scripts/check-security-policies.mjs`

静态 tripwire。要求 13 条守卫字符串仍存在于 `server.mjs`：

```
Project is read-only
Target file already exists
SHA-256 mismatch
Path escapes registered project root
Writes through symlinked directories are blocked
Sensitive path is blocked
Branch must start with mcp/
Writes are blocked on protected branch
Only runner-managed worktrees can be removed
Managed worktree is dirty
run_script is disabled in v1.0
No safe changes to commit
Repository uses a Git filter via
```

同时要求 8 类危险构造**不出现**：`exec(`、`execSync`、`spawn(`、`spawnSync`、`shell: true`、`"push"|"pull"|"fetch"` 字面量、`rm -rf`、从环境读密钥的 `process.env.*KEY|TOKEN|SECRET|PASSWORD`。

还要求 `.gitignore` 仍包含 8 条必要排除项。

为什么需要它：行为测试只能覆盖"被测试覆盖到的路径"。如果有人删掉某条守卫，而恰好没有测试打到那条分支，行为测试仍然全绿。这层门禁保证守卫字符串本身消失会被立刻发现。

**它是 tripwire，不是测试的替代品。** 两者都要有。

## 3. 工具清单门禁 `scripts/check-inventory.mjs`

拉起 `server.mjs`，通过 MCP 协议问它有哪些工具，要求恰好 22 个且名称集合精确匹配。

支持 `--server <path>`，因此可以对 **staging 里的构建** 和 **已部署的 runtime** 各跑一次——这是部署脚本在交换前和交换后都调用它的原因。

它在一次性 HOME + 空注册表下运行，不读真实配置。

## 4. 行为测试 `tests/`

**核心机制：一次性 HOME 隔离。**

`server.mjs` 的三个运行时路径都由环境变量派生：

```js
CONFIG_FILE   = path.join(os.homedir(), ".config", "local-mcp-dev-runner", "projects.json")
WORKTREE_BASE = path.join(os.homedir(), ".local", "share", "local-mcp-dev-runner", "worktrees")
// 用户级 git attributes: $XDG_CONFIG_HOME/git/attributes 与 os.homedir()/.gitattributes
```

`os.homedir()` 在 POSIX 上遵循 `HOME` 环境变量。测试用 `mkdtemp` 建一个临时 HOME，把 `HOME`、`XDG_CONFIG_HOME`、`GIT_CONFIG_GLOBAL`、`GIT_CONFIG_SYSTEM` 全部指过去，然后拉起真实的 `server.mjs` 进程。

结果：**注册表、worktree 根目录、git 全局配置全部落在临时目录里，`server.mjs` 里没有任何测试专用代码路径。** 被测文件与部署到 RUNTIME_ROOT 的文件逐字节相同。

**覆盖清单（70 项）**

| 文件 | 覆盖 |
| --- | --- |
| `tests/inventory.test.mjs` | 22 工具、服务器身份、每个工具都有描述与 input schema |
| `tests/security/filesystem.test.mjs` | READ_ONLY 拒绝写；READ_WRITE 可写；已存在文件不可覆盖；SHA 陈旧拒绝；SHA 正确才删除；绝对路径 / `..` / NUL 拒绝；符号链接读取、目录写入、文件替换拒绝；`.env` / `.git` / `*.key` 拒绝；列目录与搜索过滤敏感项；未登记项目拒绝；写入体积上限 |
| `tests/security/git.test.mjs` | 非 `mcp/*` 分支拒绝；保护分支拒绝写；非托管 worktree 不可移除；managed worktree 全生命周期（创建 → 写入 → 提交 → 脏拒绝移除 → 清理后移除 → 分支保留）；提交不含 `.env`；仅剩敏感变更时拒绝提交 |
| `tests/security/run-script.test.mjs` | `run_script` 六种调用方式全部拒绝；`project_scripts` 报告执行已关闭 |
| `tests/security/git-filter.test.mjs` | 全局装 LFS 但无 filter 规则 → 不阻断（3 个误报场景）；注释中的 filter → 不阻断；无害 attributes → 不阻断；仓库 `.gitattributes` / `core.attributesFile` / XDG attributes 含 filter → 阻断（3 个正向对照） |
| `tests/schema.test.mjs` | 22/22 工具均声明 outputSchema（名称集合与基线精确一致、inputSchema 仍齐全）；真实调用文件写入链 / 只读路径 / git / worktree 链 / run_script DENY，将 `structuredContent` 对照其 `outputSchema` 做 JSON Schema 校验 |

**测试不会做的事**：读写 `$HOME/.config/local-mcp-dev-runner/projects.json`；触碰任何真实业务仓库；启动 Tunnel；联网。

## 5. 密钥扫描 `scripts/secret-scan.sh`

扫描 `git ls-files`（即真正会被提交的内容），两类规则：

**路径规则**——这些文件被跟踪即失败：`.env`、`.env.*`、`projects.json`、`.npmrc`、`.netrc`、`credentials*`、`*service-account*.json`、`*secrets*.json`、`id_rsa*`、`id_ed25519*`、`*.pem`、`*.key`、`*.p12`、`*.pfx`、`*.jks`、`*.keystore`。

**内容规则**——OpenAI / GitHub / AWS / Slack 令牌形态、私钥块、npm `_authToken`、通用凭据赋值、`/Users/<real-user>/` 绝对路径、当前 OS 用户名、tunnel API key 赋值。

跳过二进制文件。命中即非零退出。

关于最后两条规则的说明：把"当前 OS 用户名"和"绝对 home 路径"判为风险，是因为仓库的价值之一是**可移植**。一旦提交，这些值会泄漏到每一个克隆里，也让机器身份信息进入版本历史。文档因此统一使用 `$HOME` 与 `<PLACEHOLDER>`。

## 6. 输入兼容性门禁 `scripts/check-input-compat.mjs`

与基线 commit `8137b48` 对比每个工具的 **输入契约**，确保本工作包（只动输出侧）没有悄悄改变任何工具的调用面：

1. 从 `8137b48` 提取当时的 `server.mjs`，与当前工作树 `server.mjs` 各拉起一次真实进程（基线副本提取到临时目录，并通过符号链接复用真实 `node_modules`，因此能像正式 server 一样启动）；
2. 各自 `tools/list`，取每个工具的 `inputSchema`；
3. 名称集合必须完全一致（无新增 / 无删除 / 无改名）；
4. 每个同名工具的 `inputSchema` 必须深度相等。

任一不一致即打印差异并 `INPUT_SCHEMA_COMPATIBILITY=FAIL` 退出 1；全部一致才输出 `INPUT_SCHEMA_COMPATIBILITY=PASS` 退出 0。

## 7. 输出 schema 门禁 `tests/schema.test.mjs`

`npm run gate:schema` 即运行该文件。它做两件事：

1. **工具发现覆盖（OUTPUT_SCHEMA_COVERAGE = 22/22）**：`tools/list` 必须返回恰好 22 个工具，名称集合与 `tests/inventory.test.mjs` 固定的基线精确一致，每个工具都声明了 `outputSchema` 且根类型为 `object`、`additionalProperties: false`、`inputSchema` 仍齐全。
2. **结构化结果校验**：对能在 fixture 中安全成功执行的工具（文件写入链、只读路径、git、worktree 链）做真实调用，取出 SDK 抽出的 `structuredContent`，用该工具自己声明的 `outputSchema` 跑 JSON Schema 校验；`run_script` 仍验证为 DENY 且不携带 `structuredContent`。

这层门禁保证声明的 `outputSchema` 不是装饰——它真的匹配 handler 的实际返回。

## 8. 部署门禁 `scripts/verify-runtime.sh`

只读校验已部署 runtime，不修改任何东西：

1. RUNTIME_ROOT 存在，三个文件齐全
2. `server.mjs` 能解析
3. 依赖已安装
4. 已部署构建暴露 22 个工具（一次性 HOME 下运行，不读真实配置）
5. 注册表存在、是合法 JSON、权限为 600/700（**内容永不打印**）
6. `sandbox/` `worktrees/` `logs/` 存在
7. 与 SOURCE_ROOT 的哈希漂移（WARN；`STRICT=1` 时视为 FAIL）

## 9. 提交前顺序

```bash
npm run gate:all
bash scripts/verify-runtime.sh
```

`gate:all` 保证源码健康，`verify-runtime.sh` 保证线上健康。两者都绿才可以提交。
