# P3.5 Stage 0C — Host Helper Filesystem Containment Prototype

## 1. 目标
验证 macOS Seatbelt (`sandbox-exec`) 机制对 Stage 0C Host helper 形成 OS 强制的 filesystem containment（文件系统容器化隔离）：
- 允许：单一 per-run 临时 allowed 目录（`$RUN_DIR/allowed`）的读写操作；
- 拒绝：
  - 兄弟目录 (`sibling-dir`)
  - 父级目录 (`parent-denied`)
  - 伪造的用户主目录凭证 (`fake-home/.ssh/id_rsa`, `.aws/credentials`, `.config/projects.json`, `.local/share/...`)
  - 相对符号链接越狱 (`rel-link -> ../sentinels/...`)
  - 绝对符号链接越狱 (`abs-link -> $SENTINELS/...`)
  - 任意绝对系统路径 (`/etc/hosts`)
  - 未授权写入 (`denied-write`)
  - 网络外联（沙箱内完全禁用网络）
  - 子进程越权（验证子进程继承相同的沙箱隔离约束）

## 2. 关键设计原则
1. **Helper 必须位于 allowed 目录**：
   编译产物不直接在代码仓库中以沙箱启动，而是复制到 `$RUN_DIR/allowed/p35-stage0c-helper` 并赋予执行权限。
2. **Probes Manifest 位于 allowed 目录**：
   测试配置清单 `$ALLOWED/probes.json` 由 runner 在 allowed 内部生成，helper 从自身所属目录读取。
3. **安全数据完全使用 Fake 哨兵**：
   严禁读取或复制真实系统的 `~/.ssh`、`~/.aws` 或生产 `projects.json`。
4. **环回网络门禁（Loopback Network Gate）**：
   在沙箱外启动本地专属 TCP 监听器并建立控制组验证（`UNSANDBOXED_LOOPBACK_CONNECT=PASS`），同时验证沙箱内发起连接被系统安全策略明确拒绝（`SANDBOXED_NETWORK_CONNECT=DENIED`）。
5. **规范化清理门禁（Canonical Cleanup Gate）**：
   严格沿用 Stage 0B 的 8 项安全校验与精确 PID 清理，杜绝任意意外删除。

## 3. 运行与验证
- 编译 Helper：`./build.sh`
- 原生沙箱门禁：`./run-native-stage0c.sh`
