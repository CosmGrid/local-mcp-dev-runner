# Security Model

本文记录 Local MCP Dev Runner v1.0 的安全边界、每项控制的失效后果，以及对应的验证方式。

威胁模型：**对面说话的可能不是你。** 通过 Tunnel 连进来的模型可能被提示词注入、可能被越狱、也可能因为上下文混淆而发出破坏性请求。因此本 runner 的立场是——不信任任何来自上游的调用参数，每一个工具调用都当作一次独立的攻击尝试来处理。

---

## 1. 控制清单

| # | 控制项 | 机制 | 绕过后的后果 |
| --- | --- | --- | --- |
| 1 | 注册项目 allowlist | 只有 `projects.json` 里登记过的名字可用，其余一律 `Unknown project` | 任意路径读写 |
| 2 | READ_ONLY / READ_WRITE 分层 | 原仓库 `write:false`；写入前强制校验 `project.write === true` | 源码真值被改写 |
| 3 | runner-managed worktree | 唯一可写目标是 runner 自己 `git worktree add` 出来并登记的项目，带 `managedWorktree:true` 标记 | 任意目录可写 |
| 4 | 敏感路径拦截 | `.env*` / `.git` / `.ssh` / `.aws` / `credentials` / `*.key` / `*.pem` / `service-account*.json` 等 20 条模式，在读、写、列目录、搜索、暂存各环节过滤 | 密钥外泄 |
| 5 | realpath 逃逸防御 | 词法检查（`..`、绝对路径、NUL 字节）之后再做 `realpath` 解析，最终结果必须落在项目根之内 | `../` 穿越到仓库外 |
| 6 | 符号链接防御 | 写入时比较父目录的 `realpath` 与词法路径，不一致即拒绝；读取时解析后的真实路径必须仍在项目内 | 通过软链接读写仓库外文件 |
| 7 | SHA-256 并发保护 | `replace_text` / `delete_file` 要求调用方提供当前内容哈希，不匹配即拒绝 | 覆盖掉他人（或上游并发）的改动 |
| 8 | 已存在文件保护 | `create_file` 遇到已存在目标直接拒绝，不提供静默覆盖 | 静默覆盖 |
| 9 | Git 分支限制 | 只能创建 `mcp/*` 分支；`main` / `master`（及自定义保护分支）拒绝写入 | 直接污染主干 |
| 10 | 无任意 shell | 全部子进程调用走 `execFile` 传数组参数，无 `exec` / `spawn` / `shell:true` | 任意命令执行 |
| 11 | 无 push / pull / fetch | 工具集中不存在这些子命令 | 代码外传、远端被污染 |
| 12 | Git filter 守卫 | checkout 前检查 attributes 是否真的启用了 filter/clean/smudge 驱动 | 检出过程触发任意程序执行 |
| 13 | 提交内容过滤 | 敏感路径永不进入 index；没有安全变更时拒绝提交 | 密钥进版本历史 |
| 14 | 输出上限 | 读取 200 KB、写入 500 KB、搜索 512 KB、目录 500 条、结果 200 条、diff 100 文件 | 上下文耗尽、信息批量外泄 |
| 15 | 凭据隔离 | git 子进程强制 `-c credential.helper=`、`commit.gpgSign=false`、`-c core.fsmonitor=` | 触发钩子或凭据助手 |
| 16 | 无生产部署 | 仓库内没有任何部署、发布、CI 触发路径 | 生产事故 |

## 2. 关于 run_script

`run_script` 在 v1.0 中是 **永久关闭** 的：工具被注册（契约可见），但处理体第一行就无条件抛错。

这不是"暂时没做完"，而是一个明确的安全取舍。runner 运行在你的用户身份下，没有进程沙箱。开放"执行项目脚本"意味着仓库内容可以决定执行什么命令——而仓库内容恰恰是不可信输入的一部分。在这个前提下，任何 allowlist 都可以被改一行 `package.json` 绕开。

重新开放的前置条件：真正的 OS 级隔离（容器 / seccomp / 独立低权限用户），加上按脚本内容哈希而非脚本名的 allowlist。详见 [README 第 11 节](README.md#11-为什么-run_script-默认关闭)。

## 3. Git filter 的风险模型

Git 的 `filter` / `clean` / `smudge` 属性可以在检出或暂存文件时调用外部程序。也就是说，**一个恶意的 `.gitattributes` 等价于远程代码执行**。这是本 runner 最需要防的一类攻击。

难点在于区分真假。`git lfs install` 会把 `[filter "lfs"]` 驱动写进**用户全局** `.gitconfig`：

```ini
[filter "lfs"]
	clean = git-lfs clean -- %f
	smudge = git-lfs smudge -- %f
	process = git-lfs filter-process
	required = true
```

这是**全局状态，不是仓库状态**。驱动本身什么都不做——只有当某条 **attributes 规则** 把它指派给某个路径时，它才会在 checkout 时真正执行。

早期实现检查了 git config，一看到机器上装了 Git LFS 就拒绝所有 checkout。这就是**误报**：用户全局装了 LFS、但仓库根本没启用 filter，却被阻断。

v1.0 的判定只检查 **attributes**，不检查 config。判定顺序：

1. 仓库内所有 `.gitattributes`（已跟踪 + 未跟踪）
2. `.git/info/attributes`
3. `core.attributesFile` 指向的文件
4. `$XDG_CONFIG_HOME/git/attributes`
5. `$HOME/.gitattributes`

规则解析会跳过注释行和空的 `filter=`（后者是 Git 中"取消 filter"的写法），只有真正激活的 `filter=<driver>` / `-filter` / `!filter` 才触发阻断。

| 场景 | 是否阻断 | 说明 |
| --- | --- | --- |
| 全局装了 Git LFS，仓库无 filter 规则 | 否 | 误报已修复，这是回归测试的核心用例 |
| `.gitattributes` 里 filter 只在注释中 | 否 | 注释不生效 |
| `.gitattributes` 里 `*.bin filter=lfs diff=lfs merge=lfs -text` | **是** | 真正会执行 |
| `core.attributesFile` 指向含 filter 的文件 | **是** | 用户级全局指派 |
| `$XDG_CONFIG_HOME/git/attributes` 含 filter | **是** | 用户级全局指派 |

## 4. runtime secrets 不得进入仓库

以下数据属于 runtime state，**永不被提交**：

- `$HOME/.config/local-mcp-dev-runner/projects.json`（含机器相关的绝对路径与访问策略）
- RUNTIME_ROOT 下的 `worktrees/`、`sandbox/`、`logs/`
- `node_modules/`、`.bak-*` 备份、临时目录
- API Key、Tunnel Runtime API Key、shell 环境变量中的密钥
- 用户真实 `.env`、私钥、证书、Git credentials

仓库内只有 `config/projects.example.json`，全部为 `<PLACEHOLDER>`。

防线有三层：

1. `.gitignore` 按模式排除（含 `*.key`、`*.pem`、`.env`、`*.bak-*`、`projects.json`）。
2. `scripts/secret-scan.sh` 扫描 `git ls-files` 的内容，命中即非零退出。覆盖 OpenAI/GitHub/AWS/Slack 令牌形态、私钥块、npm authToken、凭据赋值、`/Users/<real-user>/` 绝对路径、当前 OS 用户名。
3. `scripts/check-security-policies.mjs` 校验 `.gitignore` 的必要条目仍在。

**如果密钥不慎进入历史**：不要把文件删掉就当作解决——重写历史（`git filter-repo`），轮换密钥，然后检查仓库是否已被推送过。

## 5. 验证方式

安全策略不能只写在文档里。本仓库用三道独立的门保证它成立：

- **行为测试**（`tests/security/`）：通过真实 MCP 协议调用真实 `server.mjs`，断言每条守卫真的会拒绝。共 64 项。
- **静态策略门禁**（`npm run gate:security`）：断言守卫字符串仍存在于源码，且禁止构造（exec / spawn / shell:true / push / `rm -rf`）不存在。防止有人删掉守卫而测试恰好没覆盖到。
- **密钥扫描**（`npm run gate:secret-scan`）：见上。

测试隔离机制：所有用例在一次性 `HOME` 下运行，注册表、worktree 根目录、git 全局配置全部重定向到临时目录。**测试不会读写你真实的注册表，也不会触碰任何业务仓库。** 详见 [docs/GATES.md](docs/GATES.md)。

## 6. 已知不覆盖的范围

诚实说明 v1.0 防不住什么：

- **已授权范围内的读取。** 模型可以读走它有权读的任何非敏感文件，并按 200 KB 上限分批外传。控制手段是注册范围，不是流量限制。
- **已授权 worktree 内的破坏。** 在 `mcp/*` 分支的 managed worktree 里，删除文件是允许的。恢复手段是 git，不是 runner。
- **拒绝服务。** 大量并发调用可以拖慢机器。没有速率限制。
- **Tunnel 侧。** 身份认证与传输安全由 Tunnel 承担，不在本仓库范围内。
- **本机其他进程。** 如果机器上已有恶意软件，runner 不提供额外保护。
