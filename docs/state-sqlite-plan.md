# C 期 · 换引擎实施计划（四个 TSV → 一个 sqlite 库 / WAL）

> **面向执行者**：本文是 `docs/state-model.md` §5 / §6 / §7·C 的落地计划。
> 规格与计划一起读：规格说"为什么"，本文说"改哪一行、怎么证明它对"。

**目标**：`cc-state` 的后端从四个 TSV 文件换成一个 sqlite 库（WAL），门面对外的 18 个动词、
rc 约定、`dump` 的字节输出全部不变；锁消失、写入变成事务。

**架构**：门面内部已经有一层干净的存储接口——`read_lines(store) → [str]` /
`_write_unlocked(p, lines)` / `write_lines` / `rewrite(store, fn)` / `append_line(store, line)`，
上面 760 行、18 个动词全部只跟**整行字符串**打交道。C 期把这 5 个函数的**实现**换掉，
动词逻辑一行不动。行 ↔ 列的转换发生在这一层边界上。

**技术栈**：python3 标准库 `sqlite3`（无需安装，编译在解释器里）、WAL、`busy_timeout=3000`。

**规格**：`docs/state-model.md`（§3.1 表结构 / §5 引擎 / §6 迁移 / §7 分期 / §8 不变量 / §9 风险）

**campaign 分支**：`feature/state-sqlite`，基于 `main@4a77c70`（A 期已 fast-forward 进 main）。
每条子任务线以它为 `--base`，也以它为 merge target。

**范围裁定（2026-08-23，人工）**：**只换引擎**。§3.1 的模型收敛（sidecar/marker 变成列、
tasks+archive+tabs 三表、顺带修掉窗口 A/B 与 shasum 空哈希）留在 D 期。理由：
`dump` 保持逐字节等价，现有 1187 条断言原样成立；一旦回归，能归因到"引擎"而不是"引擎或模型"。
代价是 D 期要做第二次迁移，但那是库内 schema 迁移，比 TSV 导入便宜得多。

---

## 全局约束（每条都写进每份简报）

1. **python 3.9 下限**。`cc-state` 的 shebang 是 `#!/usr/bin/env python3`；交互式 PATH 解析到
   homebrew 3.14.7，但 hook 在精简 PATH 下会落到 `/usr/bin/python3` = **3.9.6**（实测）。
   于是：**不得使用 `sqlite3.connect(autocommit=...)`（3.12+）**，只能用
   `isolation_level=None` + 显式 `BEGIN IMMEDIATE`；不得使用 `match` 语句、
   不得使用运行时求值的 `X | Y` 注解。两个解释器实测都能开 WAL（sqlite 3.53.4 / 3.51.0）。
2. **bash 3.2** 适用于全部 shell 侧代码（无关联数组、无 `${var,,}`、无 `mapfile`）。
3. **hook 契约**：`cc-hooks.sh status` **零 stdout**（UserPromptSubmit 的 stdout 会注入模型上下文）、
   **永远 exit 0**、任何失败（无 python3、库损坏、磁盘满）降级为静默 no-op。
4. **板的输出契约逐字不变**：列头 `TAB|BRANCH|PARENT|STATUS|DIR|TASK`、STATUS 单元格
   `working(23m)` / `idle(2h)` / `blocked(5m)` / `-`、TAB 的四个取值与 partial 语义。
5. **`dump` 逐字节等价**，两条已记录的有意偏离（§3.5 的 7、8）之外不得有第三条。
   C 期新增的偏离**必须写进 `docs/state-model.md` §3.5**，不得静默发生。
6. **没有 ready 状态**：readiness 只由 `gwt-done` + 干净树决定，sidecar 永不写 ready。
7. **证据不完整就不剪枝**：`tab-prune` 的 `!partial` 不变量原样保留。
8. **两个台账永不互相去重**：`tasks` 回答"这是谁的子任务"，`tabs` 回答"谁开的这个 tab"。
9. **resume 用记录的 dir 字符串原样启动**：claude 以路径字符串为项目身份，
   `/Users/...` 与 `/private/...` 是两个项目。
10. **测试永不写真实状态**。`test.sh` 顶部 `cc_sandbox_ledgers()` 是唯一的沙箱入口；
    §24 的活文件泄漏 oracle（`CC_LIVE_LEDGERS` / `_cc_live_files`）是它的看门狗。
11. **worktree 自测**：`bash test.sh` 跑的是它所在的那份副本，不是主 checkout。
    绝对路径写死 `~/.config/cc-stack` 会让子任务读到/写到**安装目录**（2026-08-21 有过事故）。
12. **落地授权**：commit / rebase / merge / push / 删 worktree / 删分支**一律要人**。
    子任务做完就停下报告，然后跑 `~/.config/cc-stack/gwt-done`（绝对路径）。

---

## 0. 落地前实测的四组事实

派发前在主 checkout 实测。**其中三组推翻或补充了设计文档**——简报里要作为"已验证事实"给出。

### 0.1 成本全在 python 启动，与引擎无关

```
python3 -c 'pass'            15 ms     ← 全部成本
python3 -c 'import sqlite3'  15 ms     ← import 本身 ≈ 0.7 ms，免费
sqlite 开库 + 单行事务       0.34 ms   ← 200 行表，中位数；max 0.61 ms
[ -f ] 一次                  0.019 ms
```

**推论**：hook 那个「无板 4.6 ms / 有板 46.2 ms」的差距全部是两次 python 启动。
所以 **`cc-hooks.sh` 的存在性预检必须留在 shell 侧**，不能换成门面调用——那会给
本机每个会话的每条 prompt 加 15 ms。这是一条**有意的例外**：hook 是全栈唯一的快路径，
允许它认识一个文件名。要写成注释，并用断言钉住"无库时 0 次 python 派生"。

### 0.2 `cc-board.sh` 的两处预检在**取数之后**

`cc-board.sh:145-158`：先 `"$STATE" task-list ...` 拿 `rows_src`，**空了才**去看
`[ -f "$arch" ]` / `[ -f "$tasks" ]`，用来区分两条消息：

| 情况 | 今天打印 |
|---|---|
| 存储文件不存在 | `no registered worktree tasks` / `no archived tasks` |
| 文件在但没有行匹配（例如全是别的仓库的行） | `no records` |

即它是**冷路径**，换成门面调用零常规成本。而且因为 `_write_unlocked` 在行集为空时**删除文件**，
"文件在但零行"今天根本不会出现——所以把语义定义成「**该 store 至少有一行**」与今天行为等价，
且换引擎后依然成立。**这就是 Task 1 能先于引擎独立落地的原因。**

### 0.3 行 ↔ 列的往返是无损的（有前提）

`_sanitize_field()` 把每个写入字段里的 TAB 和换行都折叠成空格，`_sanitize()` 同理。
所以门面写出去的行里**不可能有字段内 TAB**，按列存、再按 TAB 拼回来是**无损的**。
**但有两个前提要在 Task 2 里堵住**：

- **字段数**。今天 tasks 有 7 字段遗留行和 8 字段活行，archive 有 8/9 两种。
  从固定列 schema 渲染会把 7 字段行**补成 8 字段**——`dump` 的字节就变了。
  → schema 里存一列 `nf INTEGER`（该行原本的字段数），渲染时按 `nf` 截断。
- **行序**。TSV 是插入序，sqlite 没有隐含顺序。→ 每张表带一个单调 `seq INTEGER`（rowid 即可），
  所有读取 `ORDER BY seq`。`task-prune --compact` 的 newest-per-dir 语义依赖行序，
  这一条不是可选项。

### 0.4 `dump` 今天是**原始字节透传**，不是重建

`cmd_dump` 直接 `open(p,"rb").read()` 打到 stdout，注释明写 "Never reconstruct from parsed fields"。
换引擎后没有文件可 `cat`，**`dump` 只能重建**。于是：

- 逐字节等价从"透传保证"降级成"重建保证"，靠 0.3 的 `nf` + `seq` 兑现；
- **一条新的有意偏离**：今天一个末尾**没有换行符**的手工编辑行，`dump` 会原样透传；
  迁移之后统一补上换行。这必须作为第 9 条写进 `docs/state-model.md` §3.5，不得静默发生。
- `dump` 现有的 BrokenPipe / EPIPE 处理（`sys.stdout.flush()` 在 try 内，B13）**原样保留**。
- **§32 的冻结 oracle 正是这一步的守门人**：`F32OR1` / `F32OR2` 是 A 期在
  `3edabd1` 记录下来的字面量，独立于被测门面。它必须在换引擎后**不改一个字节**地继续绿。
  改这两行不是"修测试"。

---

## 1. 为什么 C 期是两轮串行，不是一轮并行

A 期第二轮能开四条并行线，是因为四个调用方彼此独立。C 期不行：

**换引擎会让门面之外 9 处「存储感知」同时静默失效**，而它们分散在四个文件里。
如果先换引擎再修调用方，campaign 分支在两轮之间是**坏的**（板恒打 "no registered worktree tasks"、
hook 静默不写状态），每条并行线的 gate 都在一个半坏的栈上跑，`re-verify on the new base` 失去意义。
如果引擎和调用方同一轮做，那就是一条线碰五个文件——并行度为 1。

**所以顺序反过来**：先把存储感知从调用方收进门面（后端仍是 TSV，全绿、字节不变、可独立 gate），
**再**换引擎（此时门面之外没有任何代码知道状态存在哪里，套件自然保持绿）。

这 9 处全部是 **fail-silent-empty**——换引擎后不报错，只是安静地走"空"分支。
而"空存储 → 空输出"的断言对它们**恒绿**，正是本 campaign 抓了 6 次的那个陷阱，
只是这次落在文件存在性这一层。**每一条都要用变异测试证明断言会红。**

---

## 2. 文件所有权

| 文件 | Task 1 | Task 2 |
|---|---|---|
| `cc-state` | 新增 `exists` 动词 | 存储层换实现 |
| `cc-board.sh` | 2 处 | — |
| `cc-dispatch.sh` | 3 处 | — |
| `worktree.zsh` | 2 处预检 + 1 处 awk 直读 | — |
| `cc-hooks.sh` | — | 1 处预检改认库文件 |
| `install.sh` | — | 拷贝排除清单 + 输出提示 |
| `test.sh` | 新节（自己确认空闲节号） | 新节 + 沙箱 + §24 泄漏 oracle |
| `docs/state-model.md` | — | §3.5 第 9 条偏离 |
| `README.md` | — | 排障一节：不能再 `cat`，用 `cc-state dump` |

两条线**串行**，Task 2 以 Task 1 落地后的 campaign tip 为 base。

**`test.sh` 是唯一共享文件**：每条线拿一个**独立新节号 + 锚点间隔 ≥150 行**，
就地改写既有断言只允许改自己那条线负责的。当前 `test.sh` 4694 行，
出现过的节号：`1 2b 3 4 9 11 12 16 17 18 19b 20 21 23 24 25 26 27 28 32 33`。
**派发时不要照抄节号，让子任务自己 grep 确认空闲**——它落地时文件已经变了。

---

## Task 1 · 把存储感知从调用方收进门面（后端仍是 TSV）

**线名**：`c1-callers` **base**：`feature/state-sqlite`

**交付**：门面之外没有任何代码知道状态存在哪个文件里（`cc-hooks.sh` 的快路径预检是唯一
有意保留的例外，Task 2 处理）。后端不动，行为逐字节不变，套件全绿。

### 新动词

```
cc-state exists <store>        # store ∈ tasks|status|archive|tabs
                               # rc 0 = 该 store 至少有一行；rc 1 = 没有；rc 2 = 用法错
                               # 零输出（stdout/stderr 都不写，除了 rc 2 的 usage）
```

契约定义成**「至少有一行」而不是「文件存在」**，理由见 §0.2：两者今天等价（空行集会删文件），
但只有前者在换引擎后仍然成立。**这个动词的契约在 Task 2 里一个字都不变，只换实现。**

### 要改的 8 处

```
cc-board.sh:153     [ -f "$arch"  ] || { echo "no archived tasks"; exit 0; }
cc-board.sh:156     [ -f "$tasks" ] || { echo "no registered worktree tasks"; exit 0; }
cc-dispatch.sh:444  _tl_f="$(_cctabs_file)"; [ -f "$_tl_f" ] || return 0
cc-dispatch.sh:1350 [ -f "$tabs_f" ] || { echo "  (no tabs recorded)"; exit 0; }
cc-dispatch.sh:1489 [ -f "$tasks" ] || { echo "no registered worktree tasks (nothing to resume)"; exit 0; }
worktree.zsh:277    local had=0; [[ -f "$f" ]] && had=1      # gwt-prune 的 "list is empty"
worktree.zsh:369    if [[ -f "$f" ]]; then                    # gwt-tree 的 ref 映射
worktree.zsh:373    while IFS=$'\t' read -r br rf; do _gt_ref[$br]="$rf"; done \
                      < <(awk -F'\t' '$2 != "" {print $2 "\t" $3}' "$f")
```

最后一条是**第 47 处字段级解析**——A 期的验收 grep 只在生产文件里数"字段级解析 = 0"，
这行藏在 `[[ -f "$f" ]]` 里逃掉了。改成读门面的 TSV 输出，
照抄 `cc-board.sh:199` 已经确立的形态：

```zsh
< <("$(_gwt_state)" dump tasks | awk -F'\t' '$2 != "" {print $2 "\t" $3}')
```

> **落地更正（2026-08-23，`feat/c1-callers` 实测）**：本文最初写的是 `task-list --all`，
> **那是错的**，而且我自己引用的 `cc-board.sh:199` 写的就是 `dump`——指令和引用打架。
> `cmd_task_list` 的非归档路径是 `for line in reversed(read_lines("tasks"))` +
> `os.path.isdir` 跳过 + `seen` 去重，即它 (a) 跳过 dir 已消失的行、(b) newest-per-dir 去重、
> (c) **倒序**输出。而 `gwt-tree` 是 `_gt_ref[$br]="$rf"` 的 last-write-wins 循环：
> 倒序喂进去，一个分支记过两个 dir 时赢的变成**最旧**那条 ref；被跳过的死目录行恰恰是
> 「worktree 被手删、tab 还开着」那种，`⌫closed` 会静默渲染成 `-`。
> `dump tasks` 是原始行流，与今天 awk 直读文件逐字节等价。
> `test.sh` §37 两条断言钉住，变异 M3 复跑确认会红（父会话已独立复现）。

**站点数更正**：本节最初列了 8 处，实际是 **9 处**——漏掉了 `worktree.zsh` 里紧邻 `had` 的
`[[ -s "$f" ]] || { rm -f "$f"; ... }`（`gwt-prune` 的后置判断）。它也已收进 `exists`，
并因此产生了一条有意偏离，见 `docs/state-model.md` §3.5 第 9 条。

### 待你自己判断的两件事（我没有验证）

1. **`cc-dispatch.sh:1348` 把文件路径打进了表头**：`echo "── opened tabs ($tabs_f) ──"`。
   Task 1 不要求改它（后端还是那个文件，打印是准确的），但请**在报告里说明**
   还有几处这样"把存储路径打给人看"的地方——Task 2 要一并处理，我需要知道全集。
   请用 grep 做一次普查，不要凭印象。
2. **`worktree.zsh:277` 的 `had` 变量**：它决定 `gwt-prune` 在空表时打 `list is empty`
   还是别的。请读完整段再改——我只看了 10 行上下文，不确定 `had` 是否还有第二个用途。

### 步骤

- [ ] **1** 读 `cc-state` 的存储层（第 77–230 行）与 `VERBS` 表；读上面 8 处的完整上下文。
- [ ] **2** 先写失败的断言（新节）：8 处行为各一条，**每条都必须先证明它会红**。
      形态参考：把该处的存储文件删掉/清空，断言输出是"存储不存在"那条消息而不是"没匹配上"那条。
      注意这正是恒绿陷阱最爱的形状——空存储对两条分支都"看起来对"。
      **必须用变异测试证明**：把 `exists` 改成恒返回 0（或恒 1），跑一遍，
      记录每条断言的红/绿，把 tally 写进报告。变异完**务必还原**。
- [ ] **3** 跑测试，确认新断言红。记录 tally。
- [ ] **4** 实现 `cc-state exists`，改 8 处调用点。
- [ ] **5** `./test.sh`，全绿，记录 `result: N passed, 0 failed`。
- [ ] **6** 变异测试：按步骤 2 的清单逐条破坏 → 记录红 → 还原。tally 写进报告。
- [ ] **7** 性能回归检查：`cc-board.sh` 的 python 派生次数**不得增加**
      （今天活板渲染 3 次）。`exists` 只在已经为空的冷路径上调用，
      写一条断言钉住"非空板渲染时 `exists` 零调用"。
- [ ] **8** 停下报告：改了什么、tally、分支名。然后 `~/.config/cc-stack/gwt-done`。
      **不要 commit / merge**——commit gate 需要人给 `.commit-authorized`。

---

## Task 2 · 换引擎（sqlite + WAL + 自迁移）

**线名**：`c2-engine` **base**：Task 1 落地后的 `feature/state-sqlite` tip

**交付**：锁消失、写入是事务、四个文件变成一个库；`dump` 逐字节等价（除已记录的偏离）；
`cc-state` 对外的 18+1 个动词、rc 约定、输出一字不变。

### schema（1:1 映射今天的四个 store，**不做模型收敛**——那是 D 期）

```sql
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=3000;
PRAGMA user_version=1;          -- schema 版本，D 期靠它做库内迁移

CREATE TABLE tasks   (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL,
                      f1 TEXT, f2 TEXT, f3 TEXT, f4 TEXT, f5 TEXT, f6 TEXT, f7 TEXT, f8 TEXT);
CREATE TABLE status  (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL, f1 TEXT, f2 TEXT, f3 TEXT);
CREATE TABLE archive (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL,
                      f1 TEXT, ..., f9 TEXT);
CREATE TABLE tabs    (seq INTEGER PRIMARY KEY, nf INTEGER NOT NULL,
                      f1 TEXT, ..., f5 TEXT);
```

**为什么是 `f1..fN` 而不是有名字的列**：C 期只换引擎。给列起名（`dir`/`branch`/`state`…）
意味着动词逻辑要从"按位置取字段"改成"按名字取字段"——那是 §3.1 的模型收敛，是 D 期。
现在起名会让 C 期的 diff 覆盖 D 期的 diff，回归时无法归因。`nf` 与 `seq` 的理由见 §0.3。

**为什么 `tasks` 的主键不是 `dir`**：同上——`dir` 做主键会**改变去重语义**
（今天 newest-per-dir 是 `task-prune --compact` 显式做的，不是存储保证的）。D 期再换。

### 存储层的新实现（5 个函数，动词逻辑一行不动）

```
read_lines(store)        SELECT ... ORDER BY seq → 按 nf 截断 → TAB 拼接 → [str]
_write_unlocked(p,lines) BEGIN IMMEDIATE; DELETE FROM t; INSERT 全量; COMMIT
write_lines / rewrite    去掉 lock()，改为一个事务；rewrite 的读+写在同一事务内
append_line(store,line)  BEGIN IMMEDIATE; INSERT 一行; COMMIT（失败静默，保 hook 契约）
lock()                   删除（连同 CC_STATE_LOCK_STALE 与 stale 回收）
```

`rewrite` 的语义不变：读 → 变换 → 写在**一次**事务里，`fn` 收到的是拷贝，
`out != rows` 才写（round-3 gate C1 的教训，注释保留）。

### 自迁移（§6）

首次打开：库不存在 **且** 旧 TSV 存在 → **一个事务**里导入四个 TSV → 旧文件改名为
`<name>.migrated.<ts>`（**不删**）。幂等；两个进程同时触发也安全。
**迁移失败 → 不建库、不改名、按今天的路径继续跑**（hook 的降级契约，全局约束 3）。

### 门面之外要跟着改的

```
cc-hooks.sh:338-339   预检改成:  [ -f "$db" ] || [ -f "$tasks_tsv" ] || exit 0
```

**两条腿都要**：只认库，则"有旧 TSV、还没迁移"的机器上 hook 永不触发迁移、状态静默丢失；
只认旧 TSV，则迁移之后 hook 永久熄火。**必须留在 shell 侧**（§0.1，15 ms × 每条 prompt）。
配一条断言：**无库无 TSV 时 0 次 python3 派生**（今天的 4.6 ms 快路径），
以及**有库时状态写得进去**。

```
install.sh:106-107    拷贝排除清单加上库文件名 + '<db>-wal' + '<db>-shm'
install.sh 输出       加一句"状态库首次使用时自动迁移，旧 TSV 保留为 .migrated.*"
```

WAL 的 `-wal` / `-shm` 实测**在连接期间出现、干净关闭时消失**，但进程被杀会留下。
所以它们既要进排除清单，也要进 §24 的泄漏 oracle。

```
test.sh  cc_sandbox_ledgers()   导出 CC_STATE_DB，并继续导出四个旧变量（迁移路径要测）
test.sh  CC_LIVE_LEDGERS         加入库文件 + -wal + -shm
test.sh  _cc_live_files          同上；存在性是断言，sha/mtime 只是诊断
```

**沙箱是第一位的**。测试写到真实库上一次，就等于污染本机每个会话的板。
先改沙箱、跑一遍确认活文件 sha 不变，再动引擎。

> **范围更正（2026-08-23，`feat/c2-engine` 报回 + 父会话独立复核）**：
> 上面这三行**严重低估了 `test.sh` 的作用面**。派发前我只查了生产代码的解析点，
> 没查 test.sh 的**写**侧。实际：直接引用四个 TSV 环境变量的点 **117 处**
> （52 处 printf 造夹具 + 46 处原始读），局部别名夹具路径另有 49 处；
> 「raw file IS the object under test」的豁免注释出现**三次**（§32、§20、§36），不止 §32。
> `docs/state-model.md` §7 那句「C 期测试不动」同样是错的，已一并更正。
>
> 因此 C 期必须交付一个**夹具机制**：`cc-state load <store> <file>`（`dump` 的逆运算，
> 整表替换，`-` 读 stdin）。裁定与契约见 `docs/plans/briefs/c2-load-ruling.md`：
> `dump | load` 逐字节往返要有断言 + 变异；整表替换语义写进 `--help` 与 README；
> 专门测字节级文件怪癖（如末尾无换行符）的那几个夹具**继续写 legacy TSV 走迁移**，
> 因为 `load` 表达不了它们；**迁移必须有自己的专门测试**，不靠夹具顺带覆盖。
>
> 这个动词还补回一个真实能力：换引擎后人不能再手改 TSV 了，
> `dump > /tmp/x && $EDITOR /tmp/x && load < /tmp/x` 把它还回来。

### 必须钉住的断言（每条都要变异测试）

1. **§32 冻结 oracle 一字不改地绿**。`F32OR1` / `F32OR2` 是 A 期在 `3edabd1` 记录的字面量，
   独立于被测门面。**改它们不是修测试**——那意味着盘上的行格式变了。
2. **7 字段遗留行往返后仍是 7 字段**（`nf`）。构造一个 7 字段行 → 迁移 → `dump` → 逐字节比对。
3. **行序保持插入序**（`seq`）。构造 ≥3 行、乱序更新其中一行 → `dump` 的顺序不变。
4. **迁移幂等**：跑两次，库内容与旧文件改名结果一致；旧文件**没有被删**。
5. **迁移失败即回退**：制造一个不可写的库路径 → 库不存在、旧文件名字没变、命令按旧路径继续。
6. **hook 契约**：零 stdout、exit 0、无库时 0 次 python 派生。
7. **锁真的没了**：`grep -c 'mkdir' cc-state` 与 `.lock` 相关的路径应为 0
   （**这条断言容易恒绿**——请先在换引擎前跑一遍确认它是红的，再实现）。
8. **并发**：N 个进程同时 `task-set-state` 不同 dir，全部落盘、无丢失。
   A 期的 round-2 gate B1 实测过：无事务时 41 条派发丢了 18 条。这条要真的并发跑。

### 步骤

- [ ] **1** 读 `docs/state-model.md` §5/§6，读 `cc-state` 全文，读 §32 oracle 的上下文。
- [ ] **2** 先改 `test.sh` 的沙箱与泄漏 oracle，跑一遍确认活文件不受影响。commit 边界到此。
- [ ] **3** 写上面 8 条断言，**先证明它们会红**（第 7 条尤其——它在旧代码上就该是红的）。
- [ ] **4** 实现 schema + 迁移 + 5 个存储函数。
- [ ] **5** `./test.sh` 全绿，记录 tally。**跑两遍**（第二遍验证迁移幂等 + 库复用路径）。
- [ ] **6** 变异测试全套，tally 写进报告，变异**务必还原**。
- [ ] **7** 性能实测并写进报告：hook 无库 / 有库两条路径的 ms 与 python 派生次数、
      板渲染耗时。**不要引用本文的数字，自己测**——你的 base 已经不是我测的那个。
- [ ] **8** `docs/state-model.md` §3.5 加第 9 条偏离（末尾无换行符会被补上）。
- [ ] **9** `README.md` 排障一节：不能再 `cat` 状态文件，用 `cc-state dump <store>`。
- [ ] **10** 停下报告，然后 `~/.config/cc-stack/gwt-done`。**不要 commit / merge。**

---

## 派发顺序

```
feature/state-sqlite (main@4a77c70)
      │
      ├── c1-callers      ← 先派这条，独立 gate，落地
      │
      └── c2-engine       ← 以 c1 落地后的 tip 为 base
```

两条线之间**不能并行**：Task 2 的前提是"门面之外没人知道状态在哪个文件里"，
而那正是 Task 1 的交付物。

## gate 的固定动作（父会话，不可跳）

1. `git -C <worktree> status --short` / `log --oneline <base>..HEAD` / `diff <base> --stat`
   ——有没有未授权的 commit、有没有碰到不属于这条线的文件。
2. **自己重跑套件**，读自己产出的 tally，不接受形容词。
3. **自己重跑变异测试的抽样**，不接受"我做过了"。
4. rebase 到最新 base → **在新 base 上重新验证** → `gwt-merge` → `gwt-done`。
   第 3 步是最容易被跳过的一步：rebase 之前的绿不是 rebase 之后的绿。
