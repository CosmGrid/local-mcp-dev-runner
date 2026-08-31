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
| 性质 | runtime state（机器相关的绝对路径 + 访问策略） |
| 版本控制 | **否，且永不应被提交** |
| 谁写它 | 你手工编辑；部署脚本只在文件缺失时播种一份示例 |

## 判定规则

**"我该改哪里？"**

- 改代码、改测试、改脚本、改文档 → SOURCE_ROOT
- 加一个新项目、改某个项目的 `write` 标志 → CONFIG
- 其他一切 → 都不要动

**"RUNTIME_ROOT 里出现了我想要的改动？"**

不可能。它不是编辑目标。任何手工改动会在下次 `update-runtime.sh` 时消失。

## 部署时到底复制了什么

`update-runtime.sh` 只复制三个文件：

```
server.mjs
package.json
package-lock.json
```

**不会**被复制：`node_modules`（在 staging 里用 `npm ci` 重装）、`.git`、`tests/`、`scripts/`、`docs/`、`config/`、`*.bak-*`、任何 `.npmrc` 或凭据文件。

## 部署时保留了什么

下列目录属于 runtime state，会被原样搬到新树上：

```
sandbox/     可能已被注册表引用为一个 READ_WRITE 项目
worktrees/   已创建的 managed worktree
logs/
```

如果部署不搬这些，注册表里指向 `sandbox/` 的项目会在部署后凭空消失。因此这一步是部署正确性的组成部分，不是可选优化。

## 部署流程

```
1. 校验源码构建（语法 + 22 工具清单）
2. 记录 CONFIG 的 SHA-256
3. 在 RUNTIME_ROOT 的同级目录建 staging（同文件系统，保证 rename 原子）
4. 复制三个文件，比对哈希
5. npm ci 安装依赖（失败则回退复制现有 node_modules）
6. 校验 staging 构建（语法 + 22 工具清单）
7. 迁移 runtime state 到 staging
8. 旧 RUNTIME_ROOT → .bak-<时间戳>；staging → RUNTIME_ROOT（一次 rename）
9. 再次比对 CONFIG 哈希，变化即报错退出
10. 校验已部署构建；轮转旧备份（默认保留 3 份）
```

任何一步失败都非零退出，且不会留下半成品：staging 会被清掉，若已移走旧 runtime 则会回滚。

## 为什么 staging 必须和 RUNTIME_ROOT 同文件系统

`mv` 跨文件系统会退化成"复制 + 删除"，期间 RUNTIME_ROOT 处于半完成状态。放在同一文件系统下，`mv` 是一次原子 rename，任何时刻 RUNTIME_ROOT 要么完全是旧的，要么完全是新的。

代价是 staging 目录会短暂出现在 `$HOME/.local/share/` 下（隐藏目录，`.lmdr-staging-XXXXXXXX`），正常退出时被清理。
