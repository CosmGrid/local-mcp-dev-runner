# Operations — 安装 / 更新 / 回滚 / 日常运维

本文档描述 `local-mcp-dev-runner` 的部署与运维流程。核心原则：**源码项目（SOURCE_ROOT）与运行态（RUNTIME_ROOT）严格分离**，任何脚本都不得修改真实业务仓库、不得触碰 Tunnel/OpenAI 凭据、不得自动启动 Tunnel。

---

## 1. 两个目录

| 名称 | 默认值 | 含义 |
| --- | --- | --- |
| `SOURCE_ROOT` | 本仓库根目录（本机为 `$HOME/Desktop/开发/CosmGrid/local-mcp-dev-runner`） | 后续开发只改这里。 |
| `RUNTIME_ROOT` | `~/.local/share/local-mcp-dev-runner` | 部署目标。`server.mjs` 与 `package.json`/`package-lock.json` 在此运行。 |
| `CONFIG_DIR` | `~/.config/local-mcp-dev-runner` | 运行配置文件目录。 |
| `CONFIG_FILE` | `$CONFIG_DIR/projects.json` | 注册项目清单（runtime state，不入库）。 |

所有脚本均支持通过环境变量覆盖上述路径，便于在一次性目录里安全演练（见第 6 节）。

---

## 2. 首次安装（install-local.sh）

```bash
# 在 SOURCE_ROOT 下
bash scripts/install-local.sh
# 或显式覆盖目标
RUNTIME_ROOT=/custom/runtime CONFIG_DIR=/custom/config \
  CONFIG_FILE=/custom/config/projects.json bash scripts/install-local.sh
```

脚本行为：

1. 预检查：`node` 可用、SOURCE_ROOT 存在 `server.mjs` + `package-lock.json`、目标目录无 `.git`（避免误装进别的仓库）。
2. 仅复制源码文件：`server.mjs`、`package.json`、`package-lock.json`、`README.md`、`SECURITY.md`、`ARCHITECTURE.md`、`CHANGELOG.md`、`.gitignore`、`config/`、`docs/`、`scripts/`。
3. **不复制** `node_modules`、`tests`、`worktrees`、`logs`、`sandbox`、`/tmp`、`.bak-*`、任何 secrets。
4. **不覆盖** `$CONFIG_FILE`（projects.json）。若目标已存在同名配置则跳过并提示。
5. 自动 `npm ci --omit=dev`（或回退 `npm install --omit=dev`）安装运行时依赖。
6. 不自动启动 Tunnel，不修改任何 API Key。

`DRY_RUN=1 bash scripts/install-local.sh` 只打印将要执行的操作，不写任何文件（已实测无残留）。

---

## 3. 更新已部署的 runtime（update-runtime.sh）

```bash
bash scripts/update-runtime.sh
# 或指定源码与运行时
SOURCE_ROOT=/path/to/source RUNTIME_ROOT=/path/to/runtime \
  bash scripts/update-runtime.sh
```

策略：**原子替换 + 旧版本备份**，避免半安装状态。

1. 预检查：语法门禁（对所有复制的 `.mjs` 跑 `node --check`）、inventory 门禁、security 门禁必须全过，否则直接非零退出、不碰 runtime。
2. 把当前 `RUNTIME_ROOT` 重命名为 `RUNTIME_ROOT.bak-<时间戳>`（备份）。
3. 用临时 staging 目录构建新 runtime，校验通过后再 `mv` 到 `RUNTIME_ROOT`。
4. **迁移 runtime state**：保留 `sandbox/`、`worktrees/`、`logs/`、以及 `$CONFIG_FILE`，不会因替换而丢失已注册项目指向的数据。
5. 备份轮转：默认保留最近 3 个 `.bak-*`，更早的自动清理（`KEEP_BACKUPS` 可调）。
6. 任何一步失败：若已 rename 旧目录，则尝试回滚；始终以非零退出码终止。

坏源码（语法错误 / 门禁不过）会被拦截在预检查阶段，**RUNTIME_ROOT 完全不动**——已实测验证。

---

## 4. 校验运行时（verify-runtime.sh）

```bash
bash scripts/verify-runtime.sh
# 或
RUNTIME_ROOT=/path/to/runtime CONFIG_FILE=/path/to/projects.json \
  bash scripts/verify-runtime.sh
```

校验项：

- `RUNTIME_ROOT/server.mjs` 存在且 `node --check` 通过。
- `package.json` / `package-lock.json` 存在，`npm ci --omit=dev --dry-run` 不报错（依赖可解析）。
- 注册表文件存在且为合法 JSON，每个注册项目的 `root` 目录存在。
- 不修改任何文件，仅报告 PASS/FAIL。

---

## 5. 回滚

```bash
# 假设最近一次备份为 ~/.local/share/local-mcp-dev-runner.bak-20260831-141500
RUNTIME_ROOT=~/.local/share/local-mcp-dev-runner \
  bash -c 'mv "$RUNTIME_ROOT" "$RUNTIME_ROOT.failed-$(date +%Y%m%d-%H%M%S)" && \
           mv "$RUNTIME_ROOT.bak-<时间戳>" "$RUNTIME_ROOT"'
```

由于每次更新都保留完整旧目录备份，回滚即「把备份改回原名」。脚本不自动回滚，以免掩盖真实的部署失败——运维人员应确认失败原因后再操作。

---

## 6. 安全演练（不污染真实 runtime）

所有脚本都通过环境变量接受覆盖，因此可以完全在一次性目录里验证行为：

```bash
export RUNTIME_ROOT=/tmp/lmdr-drill CONFIG_DIR=/tmp/lmdr-drill-config \
       CONFIG_FILE=/tmp/lmdr-drill-config/projects.json
DRY_RUN=1 bash scripts/install-local.sh     # 影子演练
bash scripts/install-local.sh               # 真实演练（一次性目录）
bash scripts/verify-runtime.sh              # 校验演练结果
rm -rf /tmp/lmdr-drill /tmp/lmdr-drill-config  # 清理
```

本仓库的 CI / 门禁本身使用 `tests/` 下的 HOME 隔离集成测试，不依赖真实 runtime，因此可在任意干净机器上跑。

---

## 7. 日常开发循环

```bash
cd SOURCE_ROOT
npm ci                       # 安装开发依赖（含 MCP SDK，用于测试）
npm run check                # 语法门禁
npm run gate:security        # 安全策略字符串门禁
npm run gate:inventory       # 24-tool inventory 门禁
npm test                     # HOME 隔离集成测试
npm run gate:secret-scan     # 密钥扫描
npm run gate:all             # 一键跑全部门禁
```

修改 `server.mjs` 后，先在 SOURCE_ROOT 跑全套门禁，再 `bash scripts/update-runtime.sh` 部署到真实 runtime。绝不手动 `cp` 覆盖 `~/.local/share/local-mcp-dev-runner/server.mjs`。

---

## 8. 禁止项（运维红线）

- 不得修改真实业务仓库（如「有个搭子」六仓）的任何文件。
- 不得修改 Tunnel ID / OpenAI API Key。
- 不得删除当前 runtime。
- 不得开启 `run_script`（v1.0 默认 DENY，且 `update-runtime.sh` 不改动此策略）。
- 不得增加 arbitrary shell / `push` / `pull` / `fetch` / 生产部署。
- 不得把 runtime state（projects.json、sandbox、worktrees）提交进源码仓库。
