# P3.5 Stage 0D — Host Helper Filesystem Containment + VirtioFS Isolation Prototype

## 1. 目标
在严格受 macOS Seatbelt (`sandbox-exec`) 限制的 Host Helper 进程中启动 `Virtualization.framework` 虚拟机，同时验证：
- **Host Containment**：OS 级别强制约束 Host Helper 只能读写 `$RUN_DIR/allowed`；
- **VirtioFS Guest Isolation**：Guest 内部挂载 `allowed/share`，严格阻断相对路径、绝对路径、`..` 符号链接及主机私有目录逃逸；
- **Delta Gate**：验证 VM 运行前（Phase 1）与 VM 停止后（Phase 3）Host Containment 的状态完全等价与不退化；
- **Network Gate**：双向断网（Host 受 Seatbelt 阻断外联，Guest 无虚拟网卡设备）；
- **Minimal Capability Delta**：初次实现严格保持 `STAGE0D_CAPABILITY_DELTA=NONE`（完全对齐 Stage 0C Profile Baseline），若因 Seatbelt denial 导致 VM 无法启动，则严格判定为 `STAGE0D_RESULT=BLOCKED` 并输出最小 denial 证据。

## 2. 目录布局
```
/private/tmp/lmdr-p35-stage0d-<RUN_ID>/
├── allowed/
│   ├── helper/
│   │   └── stage0d-vz-tool
│   ├── assets/
│   │   ├── vmlinuz-virt
│   │   └── initramfs-stage0d
│   ├── share/
│   │   ├── host-read.txt
│   │   ├── guest-write.txt
│   │   ├── probe-spec.sh
│   │   └── write-target/
│   ├── can-read.txt
│   ├── write-target/
│   ├── rel-link
│   ├── abs-link
│   └── probes.json
├── sentinels/
│   ├── fake-home/
│   ├── sibling-dir/
│   └── parent-denied/
├── profile.sb
├── .stage0d-runner.json
└── .stage0d-active
```

## 3. 执行与验证
- 编译 Helper：`./build.sh`
- 构建 Initramfs：`./build-initramfs.sh`
- 本地自动化 Fixture 测试：`./test-fixtures.sh`
- 原生沙箱门禁：`./run-native-stage0d.sh`
