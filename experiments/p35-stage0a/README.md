# P3.5 Stage 0A — Virtualization.framework Native Prototype

## 目的

这是 **实验性 prototype**，不是 P3.5 正式实现。它的唯一目标是验证
**Virtualization.framework 在当前 Intel x86_64 Mac 上作为未来 backend 的最底层前置条件**：

- Swift CLI 能否编译并带 `com.apple.security.virtualization=true` entitlement；
- ad-hoc codesign 后 entitlement 是否可被读回确认；
- `VZVirtualMachine.isSupported` 在当前系统是否 `true`；
- 一个 **x86_64 Linux guest**（Alpine "virt"）能否在 `NETWORK_DEVICE_COUNT=0` 下
  真实启动、运行、停止。

所有 MCP / server / runtime / projects.json 集成均**不在本阶段范围**。本 prototype
严格隔离在 `experiments/p35-stage0a/`，不触碰运行时与任何已部署配置。

## 目录结构

```
experiments/p35-stage0a/
├── .gitignore                       # 忽略 build 产物 + 所有 Linux 资产
├── README.md                        # 本文档
├── assets.lock.json                 # 官方上游资产 spec（钉版本 + SHA-256）
├── virtualization.entitlements      # com.apple.security.virtualization=true（无 app-sandbox）
├── build.sh                         # swiftc 编译 + ad-hoc codesign（不启动 VM）
├── run-native-stage0a.sh            # 单一入口：preflight→build→codesign→asset→VM
└── Sources/
    └── main.swift                   # VZLinuxBootLoader + 无网络设备配置 + validate/run
```

## 如何在原生 Terminal 运行（推荐）

```bash
# 必须在原生 Terminal（非嵌套自动化沙箱）执行，VM 才能真实启动
cd /path/to/local-mcp-dev-runner
bash experiments/p35-stage0a/run-native-stage0a.sh
```

脚本会自动完成：

1. **preflight** — 检查 HOST_ARCH / MACOS_VERSION / SWIFTC / CODESIGN /
   Virtualization.framework 是否存在；
2. **build** — `swiftc` 编译并 ad-hoc codesign；
3. **entitlement inspection** — `codesign -d --entitlements :-` 读回确认
   `com.apple.security.virtualization=true` 且 `com.apple.security.app-sandbox` 缺失；
4. **VZ support** — `VZVirtualMachine.isSupported` 必须为 `true`；
5. **asset gate** — 读取 `assets.lock.json`，下载 Alpine ISO 并对齐官方 published SHA-256；
6. **extract** — 从 ISO 抽取 `boot/vmlinuz-virt` + `boot/initramfs-virt`；
7. **validate** — 配置校验（CPU/memory/networkDeviceCount=0）；
8. **run** — 真实启动 VM、轮询 running、停留若干秒、优雅停止、读取 final state；
9. **cleanup + report** — 输出固定的 `KEY=VALUE` Native Gate 报告。

## Gate 字段含义（节选）

| 字段 | 含义 |
|------|------|
| `ADHOC_VIRTUALIZATION_ENTITLEMENT` | ad-hoc 签名后能否读回 virtualization=true |
| `VZ_IS_SUPPORTED` | `VZVirtualMachine.isSupported` 是否为 `true` |
| `ASSET_GATE` | 官方资产 SHA-256 是否对齐（不符则 `BLOCKED`） |
| `NETWORK_DEVICE_COUNT` | 必须为 `0`（禁 NAT/桥接/socket/virtio-net） |
| `VM_START / VM_RUNNING / VM_STOP` | VM 生命周期三态 |
| `COLD_START_MS` | 从 `start()` 到 `running` 的冷启动耗时 |
| `PROJECTS_JSON_MODIFIED` | 必须为 `NO`（不得改 projects.json） |
| `RUNTIME_MODIFIED` | 必须为 `NO`（runtime 2.0.0 完全不变） |
| `REAL_WORKTREE_TOUCHED` | 必须为 `NO`（不碰真实 worktree） |
| `STAGE0A_RESULT` | `PASS` / `REPAIR` / `BLOCKED` |

## 环境限制说明

在 WorkBuddy 等嵌套自动化沙箱中，Virtualization.framework 的 VM 启动可能被
系统拒绝（与 P2 native gate 同样的 fail-closed 逻辑）。这属于**环境限制**，
**不判 Intel Mac 不支持**。本 prototype 对 VM 启动被拒时只**记录真实错误**、
不绕过签名检查、不产生误判。真实 VM 启动请在原生 Terminal 复跑。

资产下载（63MB Alpine ISO）在受限网络下可能被节流；脚本已将其推迟到原生
Terminal 执行，且 `assets.lock.json` 钉死官方上游版本与 SHA-256，任何校验失败
一律 `BLOCKED`、不降低标准。
