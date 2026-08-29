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

调研（survey-tsv / survey-other，2026-08-22）在这 46 处解析点里找到六个缺陷；第一轮的 gate 又实测出两个（7、8）。它们**不是本设计的目标**，
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
7. **unborn 分支上 `cc-board.sh log` 会写出一条两行的坏行**（2026-08-22 gate 实测）：
   `git rev-parse --abbrev-ref HEAD` 在没有任何提交的分支上 **exit 128 的同时把 `HEAD` 打到 stdout**，
   于是 `cc-board.sh:67` 的 `$(… || echo '?')` 捕到的是 `HEAD\n?` —— 板文件里多出一行断裂记录。
   门面自己判分支，返回干净的 `?`。这是**有意偏离"逐字节相同"**，方向是安全的。
8. **`LC_ALL=C` 下 `cut -c1-140` 是按字节切的**，会把中文摘要切在半个字符中间，往盘上写非法 UTF-8。
   hook 环境不保证 UTF-8 locale，而本项目的工作语言是中文，所以这条是活的。门面按**字符**切。
   同样是有意偏离，同样记在这里而不是悄悄改掉。
9. **`gwt-prune` 对一个被手工截断成 0 字节的任务文件，从「✔ emptied」变成「list is empty」**
   （C 期第一轮 `feat/c1-callers`，2026-08-23）。根因是 `cc-state exists` 的契约定义在**行**上
   而不是**文件**上——而这个定义是必需的：换引擎后没有 per-store 文件可 stat，
   「存储不存在」与「存储在但没匹配上」这两句话只能靠行数区分。
   附带影响：那个 0 字节文件不再被 `rm -f` 掉，会留在盘上（今天惰性无害，C 期第二轮后连文件都不存在）。
   **这个状态栈自己产生不出来**：`_write_unlocked` 清空哪个 store 就 unlink 哪个，
   只有人手动 `> worktree-tasks.tsv` 才能造出来。
   `test.sh` §36「a hand-truncated store reads as empty」同时断言消息**和**文件被保留，
   把这条偏离钉在明处而不是抹掉。

10. **`dump` 的最后一行会被补上换行符**（C 期第二轮 `feat/c2-engine`，2026-08-23）。
    换引擎前 `cmd_dump` 是**原始字节透传**（`open(p,"rb")`，注释写着 "Never reconstruct from
    parsed fields"），所以一个末尾没有换行符的手工编辑行会**原样**打回去。库里没有文件可透传，
    `dump` 只能从列重建，重建总是以 `\n` 收尾——于是「末尾无换行符」这个字节事实在**迁移那一刻**
    被规范化掉，之后再也复现不出来。
    **这条偏离的作用面比看上去小**：`read_lines` 一直把「最后一行没有换行符」当成一行
    （不是当成半行丢掉），所以**行数、字段数、字段内容全都不变**，变的只有文件末尾那一个字节。
    产生这种行的只有人手工编辑或 `cc-state load`；栈自己写出来的行永远带换行符。
    `test.sh` §32「a newline-less final row is still a row」+「the rebuild supplies the newline」
    和 §39「the newline-less legacy row gained a newline」把两半都钉住：**行还在**，
    **换行符被补上**——断言的是它发生，不是容忍它发生。

11. **迁移只导入与库同目录的 legacy TSV**（同上，事故后加的规则）。
    四个 `CC_*_FILE` 与 `CC_STATE_DB` 是**互相独立**的 override，所以「只设库、不设四个路径」
    的调用方会让迁移去读 `~/.config/cc-stack/` 里的**真台账**，把它们导进一个用完就扔的库、
    并且**改名搬走**。这不是假想：本轮开发中一条只设了 `CC_STATE_DB` 的临时命令，
    真的把活的 `opened-tabs.tsv` 与 `worktree-tasks-archive.tsv` 搬走了（已还原）。
    危险之处在于**装机目录跑的还是换引擎前的 `cc-state`**，它改名之后会看到「四个台账都不存在」，
    板直接空掉。
    规则因此定成：**legacy 文件必须与库在同一个目录**才算这个 store set 的一员。
    这在生产里零成本（四个 TSV 和库本来就并排住在 `~/.config/cc-stack/`），
    但把这个洞在所有其它环境里堵死。`test.sh` §39「a library does not import a store from
    another directory」钉住它，并配一条反面断言证明同目录的**确实**会导入。

    **残余口子与它的处置**（gate 提出）：`README` 把 `CC_TASKS_FILE` 写成**面向用户的**旋钮
    （另外三个明确标着 "override for tests"），所以「用户合法地把任务表挪走」是支持的动作——
    而同目录规则会让那份台账**永远不被导入**，板静默变空。
    处置是**说出来**，不是把规则改软：`_orphan_legacy()` 在每次打开时检查「**被显式挪走**、
    存在、但不在库目录里」的 store，往 **stderr** 打一行点名文件与修法
    （`cc-state load <store> <path>`），不影响 rc；hook 路径本来就 `>/dev/null 2>&1`，
    天然静默（§39 用断言钉住，不靠这个巧合）。

    > **D 期的最终处置（2026-08-29）**：这条规则从**检查**变成了**路径的构造方式**。
    > 四个 `CC_*_FILE` 覆盖退役（§8 不变量 9），legacy 路径改为从库所在目录派生，于是
    > 「五个路径可以互相指到别的目录」这个**状态本身不可表示**了 —— `_migratable` /
    > `_orphan_legacy` / `_warn_orphans` 三个函数随之删除，而它们保住的那条性质（不导入
    > 邻居目录的台账）由 §39 原来那条断言继续钉着：**性质是交付物，代码不是**。
    > 留下的唯一风险是「shell 里还导着旧变量的人」，处理办法仍是说出来：`_warn_retired()`
    > 每进程一次，逐个点名被忽略的变量与修法。
    **两处非直觉**：(a) 检查必须放在「库已存在」的路径上——写进迁移分支的话，
    对受影响的机器**一次都不会触发**（库当场就从旁边那几个 store 建好了，之后再也不看 legacy 路径）；
    (b) 只报**被显式覆盖**的 store，仍在默认位置的不算「被挪走」，否则每个只设了库路径的
    调用方都会收到关于默认路径的噪音。

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
task-mark-opened <dir>                               盖上"tab 真的开成了"的时戳（原 120s 标记）
task-opened-recently <dir> <seconds>                 rc 0 = 窗口内开过
tab-add      <suuid> <owner> <dir> <session-id>
tab-list     [--all]
tab-resolve  <dir>                                   候选行按优先级全出（board 行 → tabs 台账），一行一个候选
tab-owner    <suuid>                                 最终选定的 uuid 的 owner
tab-prune    <live-map-file>                         收原始 live map（不是抽好的 uuid 表），自己认哨兵
dump         tasks|archive|tabs|status               打出今天格式的 TSV，供人 cat/grep 排查
```

**为什么 `tab-prune` 收的是原始 live map 而不是一份 uuid 清单**（2026-08-22 gate 实测后改）：
`!partial` 哨兵是 live map 里的**一行 1 字段**，而调用方抽 key 的那句
`awk 'NF>=2{print toupper($2)}'` 恰好会把它丢掉——今天 `_cctabs_prune` 之所以安全，
是因为它**先**查哨兵**再**抽 key。门面若只收抽好的清单，就永远看不见哨兵，
§8 不变量 4 会从结构性保证降级成调用方约定，而那正是本次 campaign 五个提交在守的东西。
收原始 map、自己认哨兵，这条不变量才重新变成门面自己担保的。

**为什么 `task-mark-opened` 和 `task-add` 是两个动词**（2026-08-22 gate 实测后拆开）：
`cc-dispatch.sh:711` 的注释是硬约束——*Only CHECK here; write the marker after success
(failures leave no blocking marker)*。板行要在 tab 一开就写（§3.1 那个 bug 的修复），
而去重标记只能在 tab **确实开成**之后盖：把两者塞进一个动词，就等于让一次失败的派发
留下标记、吃掉操作者 120 秒内的重试，而且是静默的（`cc-dispatch.sh:721` exit 0，无 tab 无提示）。
一个动词一件事，调用方按自己知道的成败来决定盖不盖。

`tab-resolve` 是 §2 结论 3 的样板，但它**不替调用方做选择**——这一点是 2026-08-22 实读 `close` 后修正的。

`cc-dispatch.sh close` 今天不是「板行优先、台账兜底」这么简单，而是一条**探活穿插其间**的四段级联：
板行取 `suuid`/`csuuid` → 拿 `_cctabs_livemap` 探活 → **不活**才查 opened-tabs 台账并再探一次 →
仍不活才查 cmux 自己的会话存储（`~/.cmuxterm/claude-hook-sessions.json`，按 cwd）再探一次；
owner 最后按**最终选定的那个 uuid** 反查。

选择依据是探活，而探活按 §3.2 明确留在门面之外（那是 cmux 探测，不是状态）。所以门面**不能**返回单行结论：
`tab-resolve <dir>` 按优先级输出**全部台账候选**，每行 `source \t suuid \t owner \t branch`
（`source` = `board` | `tabs`），编排——挨个探活、取第一个活的——留在 `cc-dispatch.sh`。
第三段的 cmux 会话存储**不进门面**：它不是 cc-stack 的状态，cc-stack 只读它。

收益仍在：三次文件读变一次调用、TSV 解析和规范化下沉；变的只是「谁做决定」——门面给证据，调用方做判断。
给 `tab-resolve` 加一个「顺便探活」的 flag 是错的方向：那会把 cmux 依赖拖进门面，
让门面在没有 cmux 的环境里（测试、CI、远程 SSH）从可用变成不可用。

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
- **C · 换引擎**。门面后端换成 sqlite + WAL + 自迁移。~~测试不动（它们已经走门面）。~~
  **这句是错的，2026-08-23 实测更正**：B 期只把大多数节的**读**改走门面，
  **造夹具的写从来没改过**——`test.sh` 里直接引用四个 TSV 环境变量的点有 **117 处**
  （52 处 printf 造夹具 + 46 处原始读），局部别名夹具路径另有 49 处；
  而且「raw file IS the object under test」的豁免注释出现**三次**（§32、§20、§36），
  不止 §32。换引擎后这些点全部失去意义，**没有「测试不动」的路径**。
  C 期必须同时给出一个夹具机制（见 `cc-state load`，第 20 个动词）。
  *交付：锁消失、事务、单文件。*
- **D · 收敛模型**（已交付 2026-08-29，走 D-min，见 `docs/state-model-d-plan.md`）。
  tasks/status/archive/marker 合成 §3.1 的表结构；`$TMPDIR` 去重标记与 `worktree-status.tsv`
  退役；`merged_into` 落库；四个 legacy 环境覆盖退役（§8 不变量 9）。
  *交付：8 → 3。* 未交付（列为 D2）：`dir` 主键与动词层按名取字段 —— 收益是内部整洁而非行为，
  代价是 `dump` 从字节透传变成按列重建，单独一期、单独 gate。

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
9. **测试永不写真实状态**：沙箱变量收敛为 `CC_STATE_DB`（A 期起两套并存，D 期退役旧变量
   —— **已完成 2026-08-29**：四个 `CC_*_FILE` 不再被读取，legacy 路径从库目录派生，
   于是「只设一半覆盖」这个曾经把活台账迁走的状态不可表示）。

## 9. 风险

| 风险 | 处置 |
|---|---|
| hook 路径回归会打到本机**每个**会话 | A 期就把 hook 的写路径切到门面并单独 gate；契约 1 写成断言 |
| 换引擎后不能 `cat` 排查 | `cc-state dump` 逐字节同格式；README 排障补一行 |
| 迁移把现存的板搞丢 | 旧文件改名保留、不删；迁移失败即回退到旧路径 |
| 46 处解析点改漏一处 | A 期结束时 `grep -nE 'awk -F|IFS=\$.\\t'` 在四个文件里应为 0 命中（除门面自身） |
| 与架构项 B（zsh/bash）纠缠 | 不纠缠：`worktree.zsh` 只把 12 处解析改成调门面，形态不动 |
