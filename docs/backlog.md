# Backlog — 2026-08-16 审计 campaign 之后的待办队列

`docs/known-issues.md` 记的是**有什么毛病**(每条含现象/根因/实测证据)。
本文件记的是**下一步做什么、什么顺序、怎么切分成子任务线**。
每条都指回 known-issues 的对应条目,不重复描述缺陷本身。

上一轮(`feature/audit-0816`,7 条子任务线,测试 469 → 703)已落地的不在此列,
见 `git log a58e38c..8f12ed3`。

---

## 切分原则(上一轮验证有效,照抄即可)

- **按文件所有权切,不按严重度切。** 两条线碰同一个文件就是一条线;只是"感觉相关"不算。
- **`test.sh` 是唯一的共享文件**:给每条线分配一个**独立的新节号 + 独立锚点**
  (锚点之间隔 ≥150 行),就地改写既有断言只允许改自己那条线负责的。
- **每条线的简报必须区分"我验证过的事实"和"这是我的假设,请你自己判断"** ——
  上一轮两次最有价值的产出都来自后者(子任务推翻/改进了父会话给的方案)。
- **gate 在 rebase 后的 base 上重跑**,不是在子任务自己的 base 上。
  上一轮两次打回全部来自这一步。

---

## 队列

### 1. F12 · 硬编码路径推广自解析 — P1,最大的一条

**known-issues**:「P1 · 脚本硬编码 `~/.config/cc-stack`」

机制已经存在(`worktree.zsh` 的 `_gwt_src_dir`、`gwt-done` / `cc-board.sh` 的
`$(dirname "$0")`),缺的只是推广到 `cc-merge.sh` / `cc-trust.sh` / `cc-worktree-shared.sh`
的调用点。当前计数:`worktree.zsh` 27 · `cc-dispatch.sh` 18 · `cc-board.sh` 7 ·
`gwt-done` 4 · `cc-hooks.sh` 3 · `aliases.zsh` 3。

**为什么排第一**:它横跨全部文件,和任何其它线都冲突 —— 要么第一个做,要么最后一个做,
不能并行。建议**单独一条线、独占一轮**。
验收:`./install.sh --dir /tmp/ccstack-test --yes` 之后在该目录起 claude,`gwt-*` 全部可用。

### 2. 跨 workspace 的第五面 · `gwt-tree`

**known-issues**:「gwt-tree 的 tab 存活标记仍是单 workspace」

`cc-board.sh` / `cc-dispatch.sh`(prune / close / resume)四面已修,只剩 `worktree.zsh`
里 `gwt-tree` 自己那次 `cmux list-pane-surfaces`。改法是复用已有的跨 workspace 并集。

**注意**:`gwt-tree` 在 `worktree.zsh`,与第 1 条冲突 —— 二选一并线,或排在第 1 条之后。

### 3. `gwt-merge` 目标==自身守卫

**known-issues**:「gwt-merge 不拒绝"目标 == 自身"」

一行前置守卫。**但它是上一轮唯一一次"看起来成功其实什么都没做"的失败形态**,
优先级高于它的代码量。碰 `worktree.zsh` / `cc-merge.sh`。

### 4. `cc-dispatch.sh` resume 段同类 TAB 塌缩

**known-issues**:「cc-board 读循环…TAB 塌缩」条末尾的"仍未修的同类残留"

awk 抽 5 字段之后又用 `IFS=$'\t' read` 读回去,`$2`/`$3` 为空时错位。
dir 排第一所以不会错仓库,影响面是 resume 误读 uuid;两个字段写侧有 `?` 兜底,概率低。
碰 `cc-dispatch.sh`,可与第 2/3 条并行。

### 5. 给 9 个动词补任意 shell 入口

**known-issues**:「gwt-* 里 9 个动词没有任意 shell 入口」

`gwt-rm` 最急(实际踩到过),`gwt-merge` / `gwt-collect` / `gwt-tree` 次之。
建议**不要逐个补 wrapper**,而是先决定形态:是把实现下沉到 `cc-*.sh` 子命令
(像 `gwt-status`→`cc-board.sh`、`gwt-resume`→`cc-dispatch.sh` 那样),
还是提供一个统一的 `gwt <verb>` bash 入口。**这是设计决策,先定形态再动手。**

碰 `worktree.zsh` + 多个 `cc-*.sh` —— 与第 1 条严重冲突,**排在第 1 条之后**。

### 6. 文档

- README 排障表补一条:"该开的 tab 没开" 的新常见原因是**没写 `CC_WT_PROMPT`**
  (hook-notab 指出,不在它授权范围内故未改)
- `docs/roadmap.md` 停在 2026-08-15,与本文件职责重叠,考虑合并或标注归档

---

## 不打算做的(记录决定,免得反复讨论)

- **`core.hooksPath` 仓库的 commit 门卫**:没有安全挂载点,拒绝是诚实的能力边界。
  `git config --worktree core.hooksPath` 能绕开但要改下游仓库配置,不值得。
  见 known-issues 同名条目。止损靠在简报里明说。
- **重建被误剪的 opened-tabs owner 行**:2026-08-16 的跨 workspace 误剪造成 10 个活 surface
  失去 owner 记录(已修,不再新增)。为一次性历史损坏造一个"按 cwd 从 cmux 会话库反查
  重建"的工具,维护面不划算 —— 那批 tab 人工在 UI 关掉即可。
- **`--no-verify` 绕过 commit 门卫**:有意接受。这道门防手滑、防 skill 自作主张,
  不是安全边界,不要为堵它引入新机制。

---

## 上一轮留下的操作性提醒

- **改动 `hooks/` 或 `claude-rules.md` 之后必须人工重跑 `install.sh`**。
  上一轮踩过:合并删掉了 `hooks/block-worktree-commit.sh`,而 `~/.claude/settings.json`
  的 PreToolUse 注册还指着它 —— **这台机器上每条 Bash 调用都报错**,直到重跑 install.sh。
  注意时机:**主 checkout 就是安装目录**,所以合进 campaign 的那一刻运行态就变了,
  不是等合进 main 才变。
- `~/.claude/hooks/block-worktree-commit.sh` 这个文件仍需人手删(已不再被注册)。
