# Changelog

本文件记录 Local MCP Dev Runner 的版本变更。

格式参考 Keep a Changelog，版本遵循 Semantic Versioning。

---

## [2.1.0] - 2026-09-06 — GitHub Repository Management + Workspace-first Auto Discovery

自 2.0.0 起合入 main 的 feature 级能力汇总与版本对齐。

### 新增
- **受限 GitHub 仓库管理**（2026-09-05，`05197b3` / `7434a9b`）：新增 `github_repository_info`、`github_repository_create` 两个工具（白名单组织、Keychain 凭证、幂等创建、无 push、无 delete），工具数 22 → 24；`scripts/check-inventory.mjs` 与部署脚本门禁同步更新至 24 工具
- **Workspace-first Auto Discovery**（2026-09-06，`73bf6f5` / `bf2d436`）：`projects.json` 新增 `trustedWorkspaces` 配置，server 按配置的 `root` / `maxDepth` 自动发现 Git 仓库并注册为 READ_ONLY、`source=workspace` 的只读项目（`write=false`、`runScripts=false`）；显式 `projects` 条目始终优先；新增 `scripts/workspace-discovery.mjs` 与 `tests/workspace/` 测试组
- **易用性打磨**（2026-09-04，`2951ecb`）：`--init` 引导、health check、错误信息优化与 [QUICKSTART](docs/QUICKSTART.md) 指南

### 运行时
- 2026-09-06：SOURCE_ROOT 与 RUNTIME_ROOT 的 `server.mjs` / `scripts/workspace-discovery.mjs` SHA-256 逐字节一致，本地 runtime 已运行本版本构建。

### 版本对齐
- README / package.json / package-lock.json / server.mjs / CHANGELOG 的版本号统一为 2.1.0
- [docs/SOURCE_VS_RUNTIME.md](docs/SOURCE_VS_RUNTIME.md) 按当前 `update-runtime.sh` / `verify-runtime.sh` 真实行为重写（`scripts/` 随部署进入 runtime、24 工具门禁、verify 职责与漂移检测）

---

## [2.0.0] - 2026-09-01 — Sandboxed run_script execution (P2 PROCESS SANDBOX)

> **状态：已合入 main，并随 2026-09-06 的部署同步进入本地 Runtime（与 [2.1.0](#210-2026-09-06--github-repository-management--workspace-first-auto-discovery) 同一构建）。原生 Seatbelt 隔离门禁（`scripts/run-native-sandbox-gate.sh`）须在 macOS 原生环境执行确认。**

将 `run_script` 从「永久 DENY」改造为在 macOS Seatbelt 进程沙箱内受控执行 npm / pnpm 脚本。

### 新增
- `scripts/sandbox-backend.mjs`、`scripts/sandbox-backend-sandbox-exec.mjs`、`scripts/sandbox-process-runner.mjs`、`scripts/script-policy.mjs`、`scripts/obvious-deny.mjs`、`scripts/output-handling.mjs`、`scripts/audit-log.mjs`、`scripts/sandbox-env.mjs`、`scripts/sandbox-runtime-paths.mjs`、`scripts/sensitive-worktree.mjs`、`scripts/sandbox-backend-mock.mjs`：沙箱执行全链路（后端抽象 / Seatbelt profile 生成 / 进程组生命周期 / 脚本策略 / 显式拒绝 / 审计日志 / 环境隔离 / 路径判定 / 敏感文件扫描 / 测试用 Mock 后端）
- `scripts/run-native-sandbox-gate.sh`：真实 macOS Seatbelt 隔离的一键门禁（fail-closed；嵌套沙箱必 exit 71，不假 PASS）
- `tests/p2/*.test.mjs`：P2 单元 / 镜像 / 静态门禁（66 项，WorkBuddy 嵌套沙箱内可跑）
- `tests/native/*.test.mjs`：真实沙箱隔离断言（须原生 Terminal 跑）
- `docs/P2_PROCESS_SANDBOX_DESIGN.md`：P2 冻结设计文档（design_version 1.1，含 C1 / C2 冲突裁定）

### 约束（冻结，不可变）
- 工具数仍 22；网络仅 none；仅 npm/pnpm；install DENY；无任意命令 API；仅 `mcp/*` worktree 可读写；脚本 allowlist + hash 钉死；TOCTOU A+B+C；不继承父环境；沙箱内无 git；无危险二进制；无 unsandboxed fallback；kill switch；无 hard RLIMIT；redaction 非安全边界。

### 文档同步
- README / SECURITY / ARCHITECTURE / GATES：`run_script` 由「永久关闭」改为「沙箱受控」

---

## [1.1.0] - 2026-08-31 — Structured output schemas (A3 OUTPUT-SCHEMA)

为全部 22 个 MCP 工具补充正式的、可验证的 `outputSchema` / 结构化输出契约（structured output contract），让 ChatGPT 等 MCP 客户端能可靠地以机器可解析的方式取得工具结果（成功字段、类型、数组元素结构、git / worktree / file 结果），而不必解析自由文本。

**范围严格限定在输出侧**：仅新增工具的输出 schema + 结构化内容适配器（`structured()` 辅助函数，保留原有文本 `content` 并附加 `structuredContent`）+ 相关测试 + 相关文档。未新增 / 删除 / 重命名任何工具，未改变任何工具输入参数与语义，未放松任何安全边界，`run_script` 仍为 DENY，未修改 runtime。

**新增**
- 22/22 工具声明 `outputSchema`（Zod 对象 → JSON Schema，`additionalProperties: false`，严格契约）
- `server.mjs` 增加 `structured()` 辅助函数：`text(value)` 的 JSON 载荷作为 `structuredContent`，文本 `content` 100% 兼容保留
- `list_projects` 顶层数组包装为 `{ projects }` 对象根，文本表示仍为数组
- 测试 `tests/schema.test.mjs`（6 项）：工具发现覆盖（22/22 均声明 outputSchema、名称集合与基线精确一致、inputSchema 仍齐全）+ 结构化结果校验（真实调用文件写入链 / 只读路径 / git / worktree 链 / run_script DENY，取 `structuredContent` 对照其 `outputSchema` 做 JSON Schema 校验）
- 输入兼容性门禁 `scripts/check-input-compat.mjs`：将基线 commit `8137b48` 与当前 `server.mjs` 的工具定义（inputSchema + 名称）做逐字段对比

**门禁**
- `npm run gate:input-compat` → `INPUT_SCHEMA_COMPATIBILITY=PASS`
- `npm run gate:schema` → 运行 `tests/schema.test.mjs`
- 两者已并入 `npm run gate:all`

**验证状态**
- 原有 64 项行为测试仍全绿（SDK 在调用时即按 `outputSchema` 校验 `structuredContent`，64/64 通过本身即证明每个工具的成功返回都满足其声明 schema）
- `INPUT_SCHEMA_COMPATIBILITY=PASS`（22 工具，相对 `8137b48` 输入契约零变更）
- `OUTPUT_SCHEMA_COVERAGE=22/22`
- 密钥扫描 0 findings；源码与运行时 `server.mjs` 逐字节一致

**已知限制**
- 本工作包由 A3 实施并自报 `OUTPUT_SCHEMA_IMPLEMENTATION=PASS`，但须由 A1 独立执行 Final Gate 后方可 CLOSED；A3 不自行宣布 CLOSED。

## [1.0.0] - 2026-08-31 — Baseline

首个正式版本。本版本 **不引入新功能或行为变更**，其唯一目的是把此前已在 runtime 上手工验证通过的 v1 实现，固化为一个可版本控制、可测试、可安装、可回滚的源码项目。

`server.mjs` 与运行中的 runtime 版本逐字节一致（SHA-256 `2038ebd46667b87fb098dee5780506dc1cd5046a432b5ed53d6cc1f32f4599d2`）。

### 基线能力

**工具清单（22 个）**

`list_projects`、`project_info`、`list_directory`、`find_files`、`search_text`、`read_file`、`read_files`、`file_info`、`create_directory`、`create_file`、`replace_text`、`delete_file`、`git_status`、`git_diff`、`git_log`、`git_branch_list`、`git_create_branch`、`git_worktree_create`、`git_worktree_remove`、`git_commit`、`project_scripts`、`run_script`

工具数量与名称集合被固定在 `tests/inventory.test.mjs` 与 `scripts/check-inventory.mjs` 中，任何增减都会导致门禁失败。

**安全文件操作**

- 注册项目 allowlist，未登记项目一律拒绝
- READ_ONLY 原仓库拒绝任何写入
- READ_WRITE 沙箱可创建文件与目录
- 已存在文件不可被 `create_file` 覆盖
- `replace_text` / `delete_file` 需要当前内容的 SHA-256，陈旧哈希一律拒绝
- 绝对路径、`..` 逃逸、NUL 字节在进入文件系统前被拦截
- 符号链接穿越：读取时解析后须仍在项目内；写入时父目录 realpath 必须与词法路径一致
- 敏感路径（`.env*`、`.git`、`.ssh`、`.aws`、`credentials`、`*.key`、`*.pem`、`service-account*.json` 等）在读、写、列目录、搜索、提交各环节被过滤（沙箱默认 `allowDot: false`，因此点文件默认不可写）

**只读 Git 工具**

`git_status`、`git_diff`、`git_log`、`git_branch_list`。所有 git 子进程强制 `-c credential.helper=`、`commit.gpgSign=false`、`-c core.fsmonitor=`，输出统一裁剪到 200 KB。

**Managed worktree**

- 只能创建 `mcp/*` 分支的 worktree
- 只有 runner 自建的 worktree（`managedWorktree:true`）可写、可被 `git_worktree_remove` 移除
- 移除前做 dry-run，脏工作区拒绝移除
- 移除时保留分支，交由人决定是否合并

**提交保护**

- 敏感路径永远不会进入 index
- 没有安全变更时拒绝空提交
- 单次提交文件数上限 500

**Git filter 误报修复**

checkout 前的 filter 守卫改为**只检查 attributes，不检查 git config**。详见 [SECURITY.md 第 3 节](SECURITY.md#3-git-filter-的风险模型)。已固化为回归测试：全局安装 Git LFS 但仓库未启用 filter 时不得阻断。

**已通过的 Gate**

- `V1_FINAL_GATE = PASS`
- `V1_REAL_WORKFLOW_GATE = PASS`

### 本次工程化新增

- 独立 Git 仓库，默认分支 `main`，仅本地，未 push
- `SOURCE_ROOT` 与 `RUNTIME_ROOT` 分离模型
- 部署脚本：`install-local.sh`、`update-runtime.sh`、`verify-runtime.sh`（原子替换、保留 runtime state、不覆盖注册表、失败回滚、非零退出）
- 安全示例配置 `config/projects.example.json`（纯占位符，无用户名 / 绝对路径 / 密钥）
- 测试套件 64 项，经真实 MCP 协议驱动真实 `server.mjs`，一次性 HOME 隔离
- 门禁脚本：`check-syntax.mjs`、`check-inventory.mjs`、`check-security-policies.mjs`、`secret-scan.sh`
- 文档：`README.md`、`SECURITY.md`、`ARCHITECTURE.md`、`CHANGELOG.md`、`docs/`

### 已知限制

见 [README 第 10 节](README.md#10-当前限制)。其中最需要记住的两条：`run_script` 永久关闭；不提供 push / pull / fetch。
