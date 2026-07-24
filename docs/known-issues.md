# Known issues

记录 cc-stack 已知但尚未修复的问题。按严重度排序。

---

## P1 · 脚本硬编码 `~/.config/cc-stack` — 非默认 `--dir` 安装会全面断裂

**严重度:** P1(真实功能性 bug;但用默认路径 `~/.config/cc-stack` 安装的用户不会触发)

**现象:**
`install.sh` 支持 `--dir <path>` / `CC_STACK_DIR` 装到任意目录(README 明确宣传:`curl ... | bash -s -- --dir ~/somewhere/cc-stack`)。安装时 `.zshrc` 写入的是正确路径(`$CCT/worktree.zsh`),所以 source 能成功。**但被 source 的脚本内部全部硬编码 `~/.config/cc-stack`**,且没有一个脚本用 `BASH_SOURCE`/`ZSH_SOURCE` 自解析目录 → 运行时找不到脚本,`gwt-*` 命令全面断裂。

**根因:**
脚本不从自身位置或 `CC_STACK_DIR` 推导 cc-stack 根目录,而是写死 `$HOME/.config/cc-stack`(或 `~/.config/cc-stack`)。

**硬编码处**(仓库内 `grep -rn config/cc-stack`,排除 `.bak`/worktrees):

| 文件 | 处数 | 后果(DEST ≠ 默认时) |
|---|---|---|
| `worktree.zsh` | 21 | `gwt-new`/`gwt-rm` 调 `cc-worktree-shared.sh`、`cc-merge.sh`、`cc-trust.sh`、`cc-cmux-workspace.sh` 全部找不到 |
| `aliases.zsh` | 3 | `claude()`、`gwt-claude`、`gwt-test` 失效 |
| `cc-cmux-surface-claude.sh` | 5 | hook 路径下文件不存在 → 子任务永远开不了 tab |
| `cc-worktree-claude.sh` | 2 | 同上 |
| `cc-worktree-cmux-hook.sh` | 1 | 同上 |
| `cc-tasks-log.sh` | `CC_TASKS_FILE` 默认值 | 任务表写错位置,`gwt-status` 读空 |

**修复方向:**
- **推荐 A — 脚本自解析根目录:** bash 脚本用 `${BASH_SOURCE[0]}`、zsh 用 `${(%):-%x}`(或在 source 时记录一次)推导出 cc-stack 安装根,替代硬编码。自包含,不依赖外部 state。
- **方案 B — install 写 state + 脚本读取:** `install.sh` 写 `~/.cc-stack-dir`(或把 `CC_STACK_DIR` export 进 `.zshrc`),脚本读它。简单但多一层间接。
- 两种方案都应保留 `CC_STACK_DIR` 环境变量作为 override(测试 / 特殊部署用)。

**验证:**
```bash
./install.sh --dir /tmp/ccstack-test --yes
# 在 /tmp/ccstack-test 起一个 claude,gwt-* 应全部工作、不依赖 ~/.config/cc-stack
```

**关联:** `install.sh` 的 `--dir`/`CC_STACK_DIR` 处理(约行 13、34)、README 的 install 文档(约行 40-65)。
