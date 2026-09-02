# Stage 0B — VirtioFS 工作树隔离原型 (P3.5 设计验证)

> 实验分支 `mcp/p35-stage0b-virtiofs-isolation`。本目录是 **原型**，仅验证 Apple
> Virtualization.framework 的 VirtioFS 目录共享能否安全地用于「只暴露一个宿主临时
> 目录」的工作树隔离设计。**不**对接 Local MCP Dev Runner / `server.mjs` / `run_script`，
> **不**触碰 `projects.json`、已部署 runtime、真实 worktree，`P3_5_PRODUCTION_IMPLEMENTATION=NO`。

## 目标

验证以下安全断言在本机（Intel Mac, macOS 15.7, Virtualization.framework）成立：

1. 可以把 **单个** VirtioFS 共享（`tag=lmdr-stage0b`，宿主临时目录）挂进 Linux 客户机。
2. 客户机 **能** 双向读写该共享（IO 门）。
3. 客户机 **不能** 通过 `..` / 相对符号链接 / 绝对符号链接 逃出共享根，读到宿主
   `denied-sentinel/` 里的假标记（路径逃逸门）。
4. 客户机 **不能** 通过绝对路径直接触及宿主文件系统（绝对路径门）。
5. 没有任何 HOME 挂载、没有任何网络设备（`networkDevices=[]`，仅 loopback）。
6. VM 生命周期全部在绑定的 dispatch 队列上执行（继承 Stage 0A 队列亲和修复，无 SIGILL）。

## 文件

| 文件 | 作用 |
|------|------|
| `Sources/main.swift` | Swift 助手：`validate` / `run` 子命令，构建含 VirtioFS 设备的 VM 配置（正确 API 形式），队列亲和自检。 |
| `guest/stage0b-init` | 客户机 early-userspace init（PID 1，经 `rdinit=/stage0b-init`）。挂载 virtiofs、跑 IO/逃逸/网络/HOME 门，结果写回共享目录。**不覆盖** Alpine 原 `/init`。 |
| `build-initramfs.sh` | 解包 Stage 0A initramfs、保留 `/init`、加入 `/stage0b-init`、重新打包。前置检查 `cpio`/`gzip`（缺失则 `INITRAMFS_BUILD_GATE=BLOCKED`，不安装工具）。 |
| `run-native-stage0b.sh` | **原生门禁入口**（仅在本地 Terminal 跑，会启动真实 VM）。建临时宿主树、建 initramfs、编译、校验配置、跑 VM、收集客户机结果、算 IO/逃逸/安全门、清理、输出固定报告。 |
| `build.sh` | 编译 + ad-hoc codesign（仅 `com.apple.security.virtualization`）。 |
| `virtualization.entitlements` | 仅 virtualization  entitlement，无 app-sandbox、无 hypervisor。 |
| `assets.lock.json` | 复用 Stage 0A 已校验的 Alpine virt x86_64 内核/initramfs。 |

## VirtioFS API（正确形式，禁止用 `VZSingleDirectoryShare(directory:readOnly:)` 便捷初始化器）

```swift
let sharedDirectory = VZSharedDirectory(url: allowedDirURL, readOnly: false)
let share = VZSingleDirectoryShare(directory: sharedDirectory)
let fs = VZVirtioFileSystemDeviceConfiguration(tag: "lmdr-stage0b")
fs.share = share
config.directorySharingDevices = [fs]
```

- `VIRTIOFS_TAG=lmdr-stage0b`，`VIRTIOFS_TAG_POLICY=FIXED_LITERAL`。

## 客户机 init 机制

- 不解包覆盖 Alpine 原 `/init`；解包 Stage 0A initramfs 后 **新增** `/stage0b-init`。
- 内核 cmdline 用 `rdinit=/stage0b-init` 选取新增的 early-userspace init。
- `INITRAMFS_ORIGINAL_INIT_PRESERVED=YES`。

## 临时宿主树（仅 `/tmp`，无真实数据）

`run-native-stage0b.sh` 用 `mktemp -d /tmp/lmdr-p35-stage0b-XXXXXX` 建树：

```
<root>/allowed/            # VirtioFS 共享根（挂到客户机 /worktree）
  host-read.txt            # 随机 HOST_READ_MARKER（主机→客户机读）
  probe-spec.sh            # 假 secret + 逃逸目标路径（客户机 source）
  escape-link  -> ../denied-sentinel          # 相对符号链接
  escape-link-abs -> <root>/denied-sentinel   # 绝对符号链接
<root>/denied-sentinel/    # 客户机禁止触达
  LMDR_STAGE0B_DENIED_<rand>  # 假 secret 内容
```

所有随机标记都是 **假** 字符串（不含任何真实密钥）。

## 跑法

```bash
# 1) 构建 initramfs（WorkBuddy 可做，不涉及 VM）
bash experiments/p35-stage0b/build-initramfs.sh

# 2) 编译 Swift 助手（WorkBuddy 可做）
bash experiments/p35-stage0b/build.sh

# 3) 原生门禁（本地 Terminal，启动真实 VM）—— 用户执行
bash experiments/p35-stage0b/run-native-stage0b.sh
```

WorkBuddy 只做「构建 / 语法 / 静态 / 无 VM」检查；最终 VM 证据由用户在原生 Terminal 跑
`run-native-stage0b.sh` 产出，脚本以 `==== STAGE 0B NATIVE GATE REPORT ====` 输出全部固定字段。

## 固定报告关键字段

`HOST_TEST_ROOT=TEMP_ONLY`、`INITRAMFS_ORIGINAL_INIT_PRESERVED`、`INITRAMFS_BUILD_GATE`、
`VIRTIOFS_DEVICE/TAG/SHARE_MODE`、`VIRTIOFS_GUEST_SUPPORT/MOUNT`、`VM_QUEUE_POLICY`、
`VM_START/RUNNING/STOP/FINAL_STATE`、`VIRTIOFS_HOST_TO_GUEST_READ`、`VIRTIOFS_GUEST_TO_HOST_WRITE`、
`GATE_A_IO`、`DOTDOT_ESCAPE`、`SYMLINK_ESCAPE_REL/ABS`、`SYMLINK_ESCAPE`、`ABSOLUTE_PATH_ESCAPE`、
`VIRTIOFS_PATH_ESCAPE_GATE`、`HOST_HOME_EXPOSED_TO_GUEST`、`NETWORK_DEVICE_COUNT`、
`GUEST_HAS_VIRTIO_NET`、`GATE_B_SECURITY`、`STAGE0B_SECURITY_GATE`、`TEMP_FILES_CLEANED`、
`ORPHAN_PROCESS_COUNT`、`PROJECTS_JSON_MODIFIED=NO`、`RUNTIME_MODIFIED=NO`、`REAL_WORKTREE_TOUCHED=NO`、
`STAGE0B_RESULT`、`P3_5_PRODUCTION_IMPLEMENTATION=NO`。

## 结果语义

- 客户机内核无 VirtioFS 支持（`VIRTIOFS_MOUNT=FAIL`）→ `STAGE0B_RESULT=BLOCKED`，
  `BLOCK_REASON=VIRTIOFS_GUEST_UNSUPPORTED`。
- 任一逃逸门 `FAIL`（符号链接真的逃出）→ `SYMLINK_ESCAPE=FAIL`、`STAGE0B_SECURITY_GATE=FAIL`、
  `P3_5_STATUS=DESIGN_REPAIR_REQUIRED`（本轮不做 sanitizer/chroot/policy 实现）。
- 全部门 `PASS` 且 `VM_QUEUE_POLICY=PASS` → `STAGE0B_RESULT=PASS`（设计可行的证据，非生产实现）。
