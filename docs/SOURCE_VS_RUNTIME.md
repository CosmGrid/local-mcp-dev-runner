# SOURCE_ROOT 与 RUNTIME_ROOT

## 定义

| | SOURCE_ROOT | RUNTIME_ROOT |
| --- | --- | --- |
| 路径 | 本仓库的检出位置 | `$HOME/.local/share/local-mcp-dev-runner` |
| 性质 | 源码 | 部署产物 |
| 版本控制 | 是（Git） | 否 |
| 谁写它 | 你 | 只有部署脚本 |
| 有 `.git` | 有 | 没有 |

还有第三处，不属于上面任何一个：

| | CONFIG |
| --- | --- |
| 路径 | `$HOME/.config/local-mcp-dev-runner/projects.json` |
| 性质 | runtime state（机器相关的绝对路径 + 访问策略 + trustedWorkspaces 自动发现配置） |
| 版本控制 | **否，且永不应被提交** |
| 谁写它 | 你手工编辑；部署脚本从不写它（部署前后各取一次 SHA-256 比对，变化即报错退出） |

## 判定规则

**"我该改哪里？"**

- 改代码、改测试、改脚本、改文档 → SOURCE_ROOT
- 加一个新项目、改某个项目的 `write` 标志、增删 `trustedWorkspaces` → CONFIG
- 其他一切 → 都不要动

**"RUNTIME_ROOT 里出现了我想要的改动？"**

不可能。它不是编辑目标。任何手工改动会在下次 `update-runtime.sh` 时消失。

**"改了源码之后要做什么？"**

- 改了 `server.mjs`、`package.json`、`package-lock.json` 或 `scripts/` 下任何会被 runtime 加载的模块 → 跑 `bash scripts/update-runtime.sh` 重新部署，然后重启 MCP runner 进程（server 不会热加载代码）。
- 只改了 CONFIG → 什么都不用做，`server.mjs` 每次调用都重新读注册表，改完即生效。
- 只改了 `docs/`、`tests/` 等不进部署产物的内容 → 不需要部署。

**绝不要手动 `cp` 覆盖 RUNTIME_ROOT 里的任何文件。** 部署脚本的 staging、校验、回滚逻辑就是为了让坏构建进不了 runtime；手动绕过它等于放弃全部保护。

## 部署时到底复制了什么

`update-runtime.sh` 复制的是：

```
server.mjs
package.json
package-lock.json
scripts/          整棵目录树
```

`scripts/` 会进入部署产物——`server.mjs` 启动时从 `./scripts` 加载运行时模块（工具实现、门禁、workspace 发现等），缺少它 v2.x 构建无法启动。P2 沙箱脚本（`scripts/sandbox-*.mjs` 等）同样属于 `scripts/`，**随部署一并进入 runtime**。

**不会**被复制：`node_modules`（在 staging 里用 `npm ci` 重装，失败则回退复用现有 runtime 的 `node_modules`）、`.git`、`tests/`、`docs/`、`config/`、`*.bak-*`、任何 `.npmrc` 或凭据文件。

## 部署时保留了什么

下列目录属于 runtime state，会在替换时从旧 runtime 原样搬到新树（全新安装时创建为空目录）：

```
sandbox/     可能已被注册表引用为一个 READ_WRITE 项目
worktrees/   已创建的 managed worktree
logs/
```

如果部署不搬这些，注册表里指向 `sandbox/` 的项目会在部署后凭空消失。因此这一步是部署正确性的组成部分，不是可选优化。

CONFIG（`projects.json`）永远原样不动，部署前后哈希必须一致。

## 部署流程

```
1. 预检查：源码语法 + 24 工具清单门禁必须全过，否则非零退出、不碰 runtime
2. 记录 CONFIG 的 SHA-256
3. 在 RUNTIME_ROOT 的同级目录建 staging（同文件系统，保证 rename 原子）
4. 复制 server.mjs / package.json / package-lock.json + scripts/ 整树，比对 server.mjs 哈希
5. npm ci 安装依赖（失败则回退复用现有 node_modules）
6. 校验 staging 构建（语法 + 24 工具清单），创建空的 sandbox/ / worktrees/ / logs/
7. 旧 RUNTIME_ROOT → .bak-<时间戳>；runtime state 目录搬入 staging；staging → RUNTIME_ROOT（一次 rename）
8. 再次比对 CONFIG 哈希，变化即报错退出
9. 对已部署构建跑工具清单门禁；轮转旧备份（默认保留 3 份，KEEP_BACKUPS 可调）
```

任何一步失败都非零退出：staging 被清掉，若已移走旧 runtime 则自动回滚，不会留下半成品。支持 `DRY_RUN=1` 影子演练（只验证 staging，不替换）与 `SKIP_DEPS=1`（跳过依赖安装）。

## 校验已部署的 runtime（verify-runtime.sh）

`verify-runtime.sh` 是**只读**校验，不修改 RUNTIME_ROOT、CONFIG 或 tunnel。职责：

- RUNTIME_ROOT 布局完整（`server.mjs` / `package.json` / `package-lock.json` 存在）
- `server.mjs` 可通过 `node --check`
- 依赖已安装（`node_modules/@modelcontextprotocol`）
- 已部署构建暴露恰好 24 个工具（在一次性 HOME 下启动真实 MCP 协议探测，真实 CONFIG 永不被读取）
- CONFIG 存在且为合法 JSON（内容从不打印；权限过宽只告警）
- runtime state 目录（`sandbox/` `worktrees/` `logs/`）存在
- **漂移检测**：比对 SOURCE_ROOT 与 RUNTIME_ROOT 的 `server.mjs` SHA-256，不一致报 WARN 提示重新部署；`STRICT=1` 时 WARN 升级为 FAIL

## 为什么 staging 必须和 RUNTIME_ROOT 同文件系统

`mv` 跨文件系统会退化成"复制 + 删除"，期间 RUNTIME_ROOT 处于半完成状态。放在同一文件系统下，`mv` 是一次原子 rename，任何时刻 RUNTIME_ROOT 要么完全是旧的，要么完全是新的。

代价是 staging 目录会短暂出现在 `$HOME/.local/share/` 下（隐藏目录，`.lmdr-staging-XXXXXXXX`），正常退出时被清理。
