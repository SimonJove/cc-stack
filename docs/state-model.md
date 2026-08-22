# State model — 8 stores → 3 (campaign `feat/state-model`)

设计文档。实施计划见 `docs/state-model-plan.md`。
体例同 `docs/consolidation-map.md`（上一轮 cc-* 脚本 10 → 6 的设计文档）。

**Goal**：状态从 8 处各自为政的存储收敛到 3 处，锁只有一份实现，字段访问只有一条路径。
**Non-goal**：不改任何用户可见行为——板的列契约、`gwt-*` 的输出、hook 的零输出/永远 exit 0，全部逐字不变。
不动 `worktree.zsh` 的 zsh 形态（架构项 B 已由人工决定挂起）。

---

## 1. 为什么现在做

audit-0821 这一轮付出的实际代价，逐条指回状态层：

| 症状 | 根 |
|---|---|
| 同一套 mkdir 锁抄了 **9 份**（`worktree.zsh` 4、`cc-board.sh` 2、`cc-dispatch.sh` 2、`cc-hooks.sh` 1），全部无 stale 回收 | 每个存储自带一套并发控制 |
| "TSV 读取纪律"整段注释在 **3 个文件**各写一遍 | TAB 塌缩会把一次读错**固化到磁盘**，只能靠纪律防 |
| 板的 PARENT 列曾经与 git config 不一致，`gwt-rm --branch` 之后归档永久显示错的那个（C9） | 同一事实两处存储，没有约定所有者 |
| `$TMPDIR/cc-cmux-tabs/` 攒了 **38 个**没人清的去重标记 | 第 8 个存储，没有任何清理器 |
| 派发中途崩溃 → tab 开着、板上没行、而去重标记还挡住 120 秒内的重试（实测窗口见 §3.1） | 去重标记与任务行是同一事实的两次写，中间隔着十几秒 |
| 归档重写要专门判 `awk` rc 才敢 `mv`，否则半损坏 | 无事务，靠手写"先写 tmp 再 mv" |

字段级解析点：生产代码 **46 处**（`cc-dispatch.sh` 22、`worktree.zsh` 12、`cc-board.sh` 10、`cc-hooks.sh` 2），
test.sh **19 行**。这是本次改造的全部作用面，有界。

## 2. 三个测量结果决定了设计

在本机（macOS，python 3.14.7 / sqlite 3.53.4）实测：

```
python3 空启动                 16.0 ms
python3 + sqlite 查 40 行      16.3 ms      ← sqlite 本身只占 0.3 ms
cc-board.sh 现渲染             17.5 ms
cc-hooks.sh status 现单次      20.0 ms      ← 已经在派生 python3 + awk + mkdir 锁循环
```

三个结论：

1. **"换 sqlite 会变慢"不成立**。python 启动就是全部成本，而它已与现在的 bash/awk 板持平。
2. **hook 路径会变快**。它现在为解析 JSON 派生一次 python3、再派生 awk、再跑 mkdir 锁循环；
   合并成"一次 python3 既解析 JSON 又写库"是减法。这条路径在本机每个会话的每条 prompt / Stop /
   通知上都跑，是全栈最敏感的一处，而它恰好是收益最大的一处。
3. **不能每个字段查一次库**。16 ms 是**每次调用**的底价，所以访问层必须是**问题导向**而不是行导向：
   一次调用回答调用方真正的那个问题（见 §4）。

## 3. 模型：每个存储变成什么

### 3.1 合并进单一状态库（1 个文件，2 张表）

| 现在 | 之后 | 理由 |
|---|---|---|
| `worktree-tasks.tsv` | `tasks` 表 | 三者都以 **dir** 为键、都在描述同一个子任务 |
| `worktree-status.tsv` | `tasks.state` + `tasks.state_ts` | sidecar 只是任务行的两列 |
| `worktree-tasks-archive.tsv` | `tasks.merged_at` + `tasks.merged_into` 非空 | 归档是纯追加（单一写入点 `worktree.zsh:171`），本质是同一行的终态 |
| `$TMPDIR/cc-cmux-tabs/<sha1>` | `tasks.tab_opened_ts` | 它问的"120 秒内给这个 dir 开过 tab 吗"就是任务行能回答的问题 |
| `opened-tabs.tsv` | `tabs` 表（**同库、独立表**） | 键是 surface uuid、问的是"谁开的这个 tab"。README 说得对：两个台账回答不同问题、**永不互相去重**。独立表恰好保住这一点，同时共享一个锁域与一次迁移 |

**这一条不只是合并，它修三个 bug——但换键不是免费的，两个窗口都要堵。**

调研实测（survey-other，2026-08-22）：标记写在 `cc-dispatch.sh:797`（`new-surface` 成功后立刻），
板行写在 `:983`——中间隔着 RDY shell 探测（最多 10 s）、launch 发送、trust/TUI 循环
（最多 24×0.25 s，每命中一次对话框另加 1 s，最坏 ~30 s）、cc-send 校准。于是：

- **窗口 A（标记有、板行无）**：797→983 之间，常态 3–16 s、最坏 30–40 s。这段时间 tab 已开、板上零行。
  进程若死在这里（audit-0821 实测撞到过：休眠打断回合）就是**永久**的"标记有、板行无"。
  单纯把去重键换成板行时间戳，这个窗口里的重试会开出**重复 tab**——而这恰恰是最容易重试的时段
  （hook 同步阻塞主会话，人会手动重来）。
- **窗口 B（板行有、标记无）**：resume 路径。`_ccres_setref` 原地刷新第 3 字段和 suuid，
  **不动第 1 字段的时间戳**，所以刚被 resume 重开的 tab 板行时间戳可能是几天前的；
  换成板行时间戳后紧接着的同目录派发**不会**被去重——又是重复 tab。
  （今天 resume 干脆不写标记，所以这个洞今天也在，只是没人踩到。）

**所以合并的写法必须是两条一起做**：
1. `task-add` 提前到**今天写标记的位置**（`:797`，tab 一开就落占位行），末尾用 `task-set-launch`
   补齐 `launch_args`/`caller_ref` —— 窗口 A 消失，崩溃留下的是一条"信息不全但可见"的板行，
   而不是一个隐形孤儿 tab。
2. `tab_opened_ts` 是**独立于 `created_at` 的列**，resume 重开 tab 时也要更新它 —— 窗口 B 消失。
   （`task-opened-recently` 只看 `tab_opened_ts`，永不看 `created_at`。）

**顺带消失的第三个 bug**：标记路径是 `<dir>/$(shasum … | cut -f1)`，`shasum` 不可用时哈希为空
→ `marker="$marker_dir/"` 指向**目录本身**，`[ -e ]` 恒真、且每次 `: >` 失败被 `|| true` 吞掉而目录
mtime 仍被更新 → **任意一次派发后 120 秒内、所有目录的派发都被静默吞掉**。概率低，但失败模式是
静默且全局的。变成一个整数列之后这条路径不存在了。

**注意不在覆盖范围**：`gwt-new` 走 `cc-dispatch.sh workspace` 而不是 `surface`，既不写标记也不写板行，
它有自己独立的 workspace 去重（`cc-dispatch.sh:1660`）。本设计不动它。

`tasks` 表列（与今天的 TSV 字段一一对应，不新增语义）：

```
dir TEXT PRIMARY KEY   -- 规范化路径（cd + pwd -P），今天的第 4 字段
created_at TEXT        -- 今天的第 1 字段
branch TEXT            -- 第 2
surface_ref TEXT       -- 第 3（短号，是地址不是身份）
caller_ref TEXT        -- 第 5
task TEXT              -- 第 6，已折行截断
parent TEXT            -- 第 7，见 §3.3
launch_args TEXT       -- 第 8
state TEXT             -- working|idle|blocked|NULL（原 sidecar）
state_ts INTEGER       -- 原 sidecar 的时间戳
tab_opened_ts INTEGER  -- 原去重标记
merged_at INTEGER      -- 非空 = 已归档
merged_into TEXT       -- 落地时真正合进了哪里
```

`dir` 做主键就吃掉了今天 bash 侧手写的 newest-per-dir 去重（`tail -r | awk '!seen[$4]++'`）。
**归档行例外**：同一个 dir 可以被反复派发、反复归档，所以归档不能挤掉主键。
取舍：`tasks` 主键为 `dir`，归档行在写入时**移出**到 `archive` 表（第三张表，纯追加，无主键）。
即：**2 张活表 + 1 张归档表**，仍是一个文件、一次迁移。

### 3.2 留在外面的两个（有意的）

- **`cc-failures.log`** —— 保持纯追加的文本日志。它的读者是人，生命周期与状态无关（跨 campaign 留存），
  而且 hook 在任何失败下都要能写它。**要改两件事**：(a) 写入者收敛到一个函数（今天 `_ccsend_crumb` /
  `_fail` / `cc-hooks.sh:282` / `cc-merge.sh:338` 四处各写各的，默认路径串在 5 处各自硬编码）；
  (b) **把 `CC_SEND_FAILLOG` 纳入测试沙箱**——`cc_sandbox_ledgers()` 只覆盖四个 TSV 和 trust store，
  §24 的活文件尾断言也只列那四个，所以它是唯一一个"靠每个调用点自觉"的可写存储，
  正是 known-issues 里记过两次事故的那个模式。它没有轮转、没有截断，7 天 20 行，
  且 board 的读侧（24 h 窗口 + 折叠）**目前零测试覆盖**。
- **`~/.cmuxterm/claude-hook-sessions.json`** —— cmux 自己的，我们只读，不碰。

### 3.3 git config 是分支作用域事实的**所有者**

`branch.<b>.ccMergeInto` / `branch.<b>.ccDone` **不搬进库**。理由：

- 它跟着**分支**走，而库跟着 **dir** 走。`gwt-rm` 删掉 worktree 之后分支还在、还要能合并，
  `gwt-tree` 正是靠遍历这些 config 才看得见"没有 worktree 的分支"（merge-target 线刚修的 F7）。
- 搬进库意味着库必须在分支被删时同步清理——引入耦合，不是消除耦合。
- git 自己在 `branch -D` 时会连带删 `branch.<n>.*`，这是免费的生命周期管理。

**`tasks.parent` 与 config 的关系（写清楚，避免 C9 重演）**：
`parent` 是**派发时刻裁决结果的快照**，不是第二个事实来源。规矩是一句话——
**只有 `cc-merge.sh capture`（单一裁决点，merge-target 线已落地）可以决定 target，
它的返回值同时写进 config 和 `tasks.parent`；其它任何代码都不得写 parent。**
保留这个快照是因为 config 会随分支消失，而归档要长期可读。这是**有意的反规范化**，不是重复。

### 3.4 结果

```
8 处  →  1 个状态库（tasks / archive / tabs 三表）
         + git config（分支作用域：merge target、ready）
         + cc-failures.log（追加日志）
         + 外部只读：cmux session 库
```

## 3.5 门面顺带修掉的既有缺陷

调研（survey-tsv / survey-other，2026-08-22）在这 46 处解析点里找到六个缺陷。它们**不是本设计的目标**，
但只要访问收敛到一份实现就自动消失——所以每一条都要在对应任务里写一条断言钉住：

1. **`_ccres_dropstatus`（`cc-dispatch.sh:1524`）的 awk 漏了 `-F'\t'`**，按空白切分 → 路径含空格的 dir
   删不掉（漏删，不会误删）。同函数的 `_ccres_keys` 是对的，所以是纯粹的手滑。
2. **`_gwt_archive_branch`（`worktree.zsh:170`）只按分支名匹配、无仓库过滤** → 两个仓库有同名分支时，
   在一个仓库 `gwt-merge` 会把**另一个仓库**的板行一起归档掉。`gwt-prune` 的全局去重、
   `gwt-tree` 的 `_gt_ref[branch]` 同样跨仓库。
3. **sidecar 的 join 键两套口径**：`cc-hooks.sh:363` 拿板行 `$4` 做**原样字符串**匹配，
   而 `cc-board.sh:347` 渲染时会把 `$4` **再规范化一次**才去 join。对 `surface` 写的行两者一致，
   对手写/遗留的 logical-path 行（macOS 的 `/var` vs `/private/var`），hook 永远匹配不上 →
   那一行永远没有状态。根因是**规范化发生在读侧而不是写侧**。
4. **归档文件没有任何锁**：写入借板锁串行化，`--archive` 读取完全无锁。
5. **`_gwt_archive_branch` 非原子**：同一趟 awk 里既 `>> arch` 又写 tmp；awk 中途失败时板文件保持不动，
   但归档可能已经多了几行（代码自己打印"归档可能已产生重复行"）。
6. **`_ccres_setref` 是全仓库唯一会改变行字段数的重写路径**：它用 `$3=r` 赋值触发 awk 以 `OFS` 重建 `$0`，
   于是把 7 字段遗留行**扩成 8 字段**。因为有 `-F'\t'` 所以空字段不会塌缩（安全），但这是既有纪律
   （"按行号选行 + `print $0` 逐字重发"）的唯一破例，门面里不应该保留这个例外。

另外两条**边界**，写进约束而不是改掉：

- **`branch.<b>.ccDone` 是全栈唯一没有副本的关键事实**（四个 TSV 都不存 ready）。这是 `cc-hooks.sh:311`
  明确写下的设计决定，合并状态层时**保留这条边界**。
- **`cc-merge.sh` 与 `gwt-done` 完全不碰这四个 TSV**（只操作 git config），本设计不需要动它们。
  `install.sh` 也只是在拷贝安装时排除这些文件，无迁移逻辑。

## 4. 访问层：问题导向，不是行导向

`cc-state`（python3，随仓库分发，`CC_SELF` 自解析定位）。每个子命令**一次调用回答一个调用方问题**，
join 发生在库里，不在 shell 里。返回值一律 TSV（无表头），保持 shell 侧 `awk -F'\t'` 的既有手感。

```
task-add     <dir> <branch> <ref> <task> <parent>        tab 一开就调（占位行，见 §3.1）
task-set-launch <dir> <caller-ref> <launch-args>        派发末尾补齐
task-list    [--all] [--repo <root>] [--archive]     newest-per-dir + 仓库过滤 + 死目录剪枝，一次出全
task-get     <dir>                                   一行
task-set-state <dir> <state>                         hook 的写；dir 不在表里就静默 no-op（今天的板成员资格判据）
task-set-ref <dir> <ref> [<suuid>]                   resume 的刷新（含 launch_args 里的 suuid 替换）
task-drop    <dir>                                   gwt-rm
task-prune                                           目录已消失的行
task-archive <branch> <merged-into>                  移进 archive 表，返回被移动的 dir
task-opened-recently <dir> <seconds>                 rc 0 = 窗口内开过（原 120s 标记）
tab-add      <suuid> <owner> <dir> <session-id>
tab-list     [--all]
tab-resolve  <dir>                                   suuid + owner + branch，close 的三问一次答完
tab-prune    <live-uuid-list>                        证据完整才剪（今天的 !partial 不变量）
dump         tasks|archive|tabs                      打出今天格式的 TSV，供人 cat/grep 排查
```

`tab-resolve` 是 §2 结论 3 的样板：`cc-dispatch.sh close` 今天要查板行、查台账、查 owner 三次，
合成一次调用。

## 5. 存储引擎与并发

**sqlite3（python3 stdlib），WAL 模式。**

- **锁全部消失**。WAL 下多读者 + 单写者由引擎保证，9 份 mkdir 锁连同"崩溃后无限降级为无锁写入"
  一起删掉。
- **事务**取代"写 tmp 再 mv"，半损坏那一类不存在了。
- 写者规模：本机每个 claude 会话的每条生命周期事件都写一次，量级是个位数并发、每次几毫秒，
  WAL 足够。`busy_timeout` 设 3000 ms 兜底。
- **可读性的代价与补偿**：不能再 `cat`/`grep` 看了，而这个项目（包括 audit-0821 全程排查）
  大量依赖直接读文件。`cc-state dump` 打出与今天**逐字节同格式**的 TSV 作为兜底，
  并在 README 排障一节写明。

## 6. 迁移

**库自迁移，不靠 install.sh。** 首次打开时：库不存在且旧 TSV 存在 → 在一个事务里导入四个 TSV，
然后把旧文件改名为 `<name>.migrated.<ts>`（**不删**）。整个过程幂等，两个进程同时触发也安全（事务）。

- 旧的 7 字段行、8 字段行、归档 9 字段行按今天的容忍规则导入（缺字段填空）。
- 迁移失败 → 不创建库、不改名旧文件、按今天的路径继续跑（hook 的降级契约）。
- `install.sh` 只需在输出里提一句"状态库首次使用时自动迁移，旧 TSV 会保留为 .migrated.*"。

## 7. 分期（每期独立可上线、独立可 gate）

顺序刻意让测试只 churn 一次：

- **A · 门面，零格式变更**。引入 `cc-state`，但后端仍是今天的四个 TSV。
  生产代码 46 处字段级解析全部改走它；9 份锁收敛成门面内部的一份（含 stale 回收）。
  测试仍读 TSV 文件，断言逐字不变。
  *交付：一份锁、一条访问路径。行为零变化。*
- **B · 测试脱离存储格式**。test.sh 里 19 行字段级解析改成问 `cc-state`（其余 178 处只是设置
  沙箱变量，机械替换）。生产代码不动。
  *交付：测试不再依赖文件格式，为换引擎铺路。*
- **C · 换引擎**。门面后端换成 sqlite + WAL + 自迁移。测试不动（它们已经走门面）。
  *交付：锁消失、事务、单文件。*
- **D · 收敛模型**。tasks/status/archive/marker 合成 §3.1 的表结构；
  `$TMPDIR` 去重标记与 `worktree-status.tsv` 退役。
  *交付：8 → 3。*

**建议**：A + B 先做一轮（这两期解决了 audit-0821 实际付出代价的**全部**问题：锁、塌缩、残留标记的归属），
C + D 看 A/B 的实际手感再决定。有了门面，C 是一个被隔离的改动，不必现在赌。

## 8. 必须守住的不变量

逐条写进每份简报：

1. **hook 契约**：`cc-hooks.sh status` 零输出（UserPromptSubmit 的 stdout 会注入模型上下文）、
   **永远 exit 0**、任何失败（无 python3、库损坏、磁盘满）降级为静默 no-op。
2. **板的输出契约**：列头 `TAB|BRANCH|PARENT|STATUS|DIR|TASK`、STATUS 单元格
   `working(23m)`/`idle(2h)`/`blocked(5m)`/`-`、TAB 的四个取值与 partial 语义，逐字不变。
3. **"没有 ready 状态"**：readiness 只由 `gwt-done` + 干净树决定，sidecar 永远不写 ready。
4. **证据不完整就不剪枝**：`tab-prune` 的 `!partial` 不变量原样保留（删一行是不可逆的，
   留一行陈旧只是噪音）。
5. **两个台账永不互相去重**：`tasks` 回答"这是谁的子任务"，`tabs` 回答"谁开的这个 tab"。
6. **resume 用**记录的 dir 字符串原样**启动**：claude 以路径字符串为项目身份，`/Users` 与 `/private` 是两个项目。
7. **bash 3.2** 适用于所有 shell 侧代码；python3 已是硬依赖（hook / trust / install 都在用）。
8. **worktree 自测**：`bash test.sh` 跑它所在的那份副本。
9. **测试永不写真实状态**：沙箱变量收敛为 `CC_STATE_DB`（A 期起两套并存，D 期退役旧变量）。

## 9. 风险

| 风险 | 处置 |
|---|---|
| hook 路径回归会打到本机**每个**会话 | A 期就把 hook 的写路径切到门面并单独 gate；契约 1 写成断言 |
| 换引擎后不能 `cat` 排查 | `cc-state dump` 逐字节同格式；README 排障补一行 |
| 迁移把现存的板搞丢 | 旧文件改名保留、不删；迁移失败即回退到旧路径 |
| 46 处解析点改漏一处 | A 期结束时 `grep -nE 'awk -F|IFS=\$.\\t'` 在四个文件里应为 0 命中（除门面自身） |
| 与架构项 B（zsh/bash）纠缠 | 不纠缠：`worktree.zsh` 只把 12 处解析改成调门面，形态不动 |
