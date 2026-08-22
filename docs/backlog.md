# Backlog — 待办队列

`docs/known-issues.md` 记的是**有什么毛病**(每条含现象/根因/实测证据)。
本文件记的是**下一步做什么、什么顺序、怎么切分成子任务线**。
每条都指回 known-issues 的对应条目,不重复描述缺陷本身。

已落地两轮:`feature/audit-0816`(7 条子任务线,测试 469 → 703,`git log a58e38c..8f12ed3`)、
`feature/audit-0821`(2026-08-21,4 条子任务线 merge-target / dispatch-fixes / wtz-guards /
rules-docs;各线修掉的条目在 known-issues 标「修于 2026-08-21(feature/audit-0821,<线名>)」)。

---

## 切分原则(两轮验证有效,照抄即可)

- **按文件所有权切,不按严重度切。** 两条线碰同一个文件就是一条线;只是"感觉相关"不算。
- **`test.sh` 是唯一的共享文件**:给每条线分配一个**独立的新节号 + 独立锚点**
  (锚点之间隔 ≥150 行),就地改写既有断言只允许改自己那条线负责的。
- **每条线的简报必须区分"我验证过的事实"和"这是我的假设,请你自己判断"** ——
  两轮最有价值的产出都来自后者(子任务推翻/改进了父会话给的方案)。
- **gate 在 rebase 后的 base 上重跑**,不是在子任务自己的 base 上。
  上一轮两次打回全部来自这一步。

---

## 队列

### 1. mkdir 锁收敛(audit-0821 的「第二波」,单独一轮)

**known-issues**:「mkdir 锁 10 处副本、无 stale 恢复」(2026-08-21 新增)

单一实现(pid + 年龄回收),cc-hooks.sh / cc-board.sh / cc-dispatch.sh / worktree.zsh 全部改用。
**碰全部文件 → 必须在所有并行线落地之后独占一轮做**(audit-0821 就是这么排的:第二波)。

### 2. F12 · 硬编码路径推广自解析 — P1,横跨全部文件

**known-issues**:「P1 · 脚本硬编码 `~/.config/cc-stack`」

机制已经存在(`worktree.zsh` 的 `_gwt_src_dir`、`gwt-done` / `cc-board.sh` 的
`$(dirname "$0")`),缺的只是推广到 `cc-merge.sh` / `cc-trust.sh` / `cc-worktree-shared.sh`
的调用点。当前计数:`worktree.zsh` 27 · `cc-dispatch.sh` 18 · `cc-board.sh` 7 ·
`gwt-done` 4 · `cc-hooks.sh` 3 · `aliases.zsh` 3。
它和任何其它线都冲突——要么第一个做,要么最后一个做,建议独占一轮。
验收:`./install.sh --dir /tmp/ccstack-test --yes` 之后在该目录起 claude,`gwt-*` 全部可用。
2026-08-21 23:00 事故的长期归宿也在这一条:worktree 经硬编码路径被动读到主 checkout(兼安装
目录)的状态,无法真正自测(见 known-issues「子任务线把草稿写进主 checkout」)。

### 3. 给 9 个动词补任意 shell 入口(形态决定与架构项 B 合并考虑)

**known-issues**:「gwt-* 里 9 个动词没有任意 shell 入口」

`gwt-rm` 最急(实际踩到过)。**不要逐个补 wrapper**:先决定形态——实现下沉到 `cc-*.sh`
子命令,还是统一 `gwt <verb>` bash 入口。这个决定就是架构项 B 的决定,合并考虑。
碰 `worktree.zsh` + 多个 `cc-*.sh`,与 #1/#2 冲突,排在其后。

### 4. cc-send "never dropped" × 调用方 120s 超时(短期纪律,根治归架构 C)

**known-issues**:「cc-send 的"never dropped"承诺与调用方 Bash 工具超时互相矛盾」(2026-08-21 新增)

短期:关键回传一律 `run_in_background` / 调大 `CC_SEND_TIMEOUT`(README 已写);
根治在架构项 C,不单独立线。

### 5. `CC_WT_COPY` 默认清单收敛单一事实源

**known-issues**:「`CC_WT_COPY` 复制语义漂移」(2026-08-21,wtz-guards F3 修的是语义)之外的
结构性残留:默认清单写在三处(`cc-dispatch.sh` 的 `${CC_WT_COPY:-…}`、`worktree.zsh` 的
`: ${CC_WT_COPY:=…}`、README 表格),当前恰好一致,任何一处改动即静默漂移。本轮无人认领,记此排队。

### 已结项(详见 known-issues 的修于标记)

- ~~gwt-tree 第五面(跨 workspace)~~ 修于 2026-08-21(wtz-guards)
- ~~gwt-merge 目标==自身守卫~~ 修于 2026-08-17(f6bc115:preflight target-not-self + do-merge rc 2)
- ~~cc-dispatch.sh resume 段 TAB 塌缩~~ 修于 2026-08-21(dispatch-fixes)
- ~~文档~~ 修于 2026-08-21(rules-docs:README :78 示例 + 排障表、claude-rules.md 六条审查结论、
  known-issues/backlog 对齐本轮 campaign、roadmap 归档标注)

---

## 架构项(另起 campaign,不塞进修复轮)

audit-0821 定界,每项单独立项:

- **A 状态散落 8 处 → 单一 `cc-state` 模块**(python3 已是硬依赖)
- **B zsh/bash 双实现 → `gwt <verb>` 单一 bash 入口**,worktree.zsh 只留 cd 与补全
  (吞掉队列 #3 的形态决定)。**2026-08-22 人工决定:暂不实施,只记录。**
  痛点是真的(本轮父会话全程用 `zsh -c 'source worktree.zsh; gwt-merge …'` 驱动落地),
  但代价是重写 832 行 zsh + 全部调用点,收益是"任意 shell 可用",不值得现在做。
  队列 #3 若单独补 wrapper 也要先回到这个形态决定,所以两者一起挂起。
- **C cc-send 屏幕抓取当协议**。先澄清一个常见误解:**抓取本身零 token**
  (`_ccsend` 全是 cmux/awk/sleep/date,没有任何模型参与),它换来的代价是可靠性不是成本。
  改文件邮箱 + hook 注入的 token 增量也≈0(消息内容无论哪条路径都要进子任务上下文;
  没有新消息时 hook 注入空)。**但本轮实测给出了一个便宜得多的中间解**:
  真阳性 parked 只在"长多行消息 + 接近 auto-compact 的 tab"发生,而父会话手工改发
  **文件指针**后 100% 送达。所以先把这条固化进 `cc-send`:超过 N 字自动落盘 + 只发一行
  `读 <abs-path>`,几十行代码,不动协议。整套邮箱重写留到它仍不够用时再说。
  (吞掉队列 #4 与 known-issues「cmux send 停在输入框」一族的根治)
- **D `cc-dispatch.sh` 1724 行单文件拆 lib** —— 注意这是**省** token 的投资:
  现在改其中一个函数往往要读进大半个文件,拆开后每次只读相关的一个。
- **E `test.sh` 单体拆 `tests/NN-<topic>.sh` + runner** —— 同上,且本轮四条线并行改 test.sh
  是靠"每条线分配独立节号 + 锚点间隔 ≥150 行"的人为约定避冲突的,这是用流程补架构。
- (F 硬编码自解析推广 = 队列 #2,不重复立项)

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

## 操作性提醒

- **改动 `hooks/` 或 `claude-rules.md` 之后必须人工重跑 `install.sh`**。运行态
  (`~/.claude/settings.json` 的注册、`~/.claude/CLAUDE.md` 的托管块)只在 install.sh 执行时迁移。
  上一轮踩过:合并删掉了 `hooks/block-worktree-commit.sh`,而 settings.json 的 PreToolUse
  注册还指着它——**这台机器上每条 Bash 调用都报错**,直到重跑 install.sh。
  注意时机:**主 checkout 就是安装目录**,合进 campaign 的那一刻运行态就变了,不是等合进 main。
- `~/.claude/hooks/block-worktree-commit.sh` 这个文件仍需人手删(已不再被注册)。
- **campaign 总览 `docs/plans/audit-0821.md` 是 gitignored(只在主 checkout)**:其结论已由
  rules-docs 线转写进本文件与 known-issues(2026-08-21);该文件本身不进仓库。
