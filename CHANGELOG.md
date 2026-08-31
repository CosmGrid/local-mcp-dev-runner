# Changelog

本文件记录 Local MCP Dev Runner 的版本变更。

格式参考 Keep a Changelog，版本遵循 Semantic Versioning。

---

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
