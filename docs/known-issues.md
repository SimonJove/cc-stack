# Known issues

记录 cc-stack 已知但尚未修复的问题。按严重度排序。

---

## P1 · 脚本硬编码 `~/.config/cc-stack` — 非默认 `--dir` 安装会全面断裂

**严重度:** P1(真实功能性 bug;但用默认路径 `~/.config/cc-stack` 安装的用户不会触发)

**现象:**
`install.sh` 支持 `--dir <path>` / `CC_STACK_DIR` 装到任意目录(README 明确宣传:`curl ... | bash -s -- --dir ~/somewhere/cc-stack`)。`.zshrc` 里 **source 得到**(2026-08-16 起真的能:见下方"已修的相邻面"),**但被 source 的脚本内部全部硬编码 `~/.config/cc-stack`**,且没有一个脚本用 `BASH_SOURCE`/`ZSH_SOURCE` 自解析目录 → 运行时找不到自己,`gwt-*` 命令全面断裂。**本条剩下的就只有"脚本内部硬编码"这一面。**

**已修的相邻面(2026-08-16,feat/install-docs)** —— 原文把这两条并进了本条,现在分开记:
- **步骤 3 的幂等判据认错人**:旧判据 `grep -qF "cc-stack/worktree.zsh"` 只要 `.zshrc` 里**任何一行**含该子串就跳过,于是从 `~/.config/cc-stack` 改装到 `~/other/cc-stack` 时命中旧行 → **新位置永远不会被 source**。现在判据只认本次目标(两种拼法),旧行保留但**响亮列出并说明本次目标胜出**。
- **`--dir` / `--repo` 不带值会挂死**:`shift 2` 在 `$# < 2` 时返回 1 且不移位,而脚本只有 `set -u` 没有 `set -e` → `while [ $# -gt 0 ]` 死循环(实测 rc=124)。现在缺值 exit 2 并点名 flag。

**根因:**
脚本不从自身位置或 `CC_STACK_DIR` 推导 cc-stack 根目录,而是写死 `$HOME/.config/cc-stack`(或 `~/.config/cc-stack`)。

**硬编码处**(仓库内 `grep -rn config/cc-stack`,排除 `.bak`/worktrees;处数为 grep 行命中,含注释。
2026-08 cc-* 脚本合并后文件已改名,行数按合并后文件重新统计):

| 文件 | 处数 | 后果(DEST ≠ 默认时) |
|---|---|---|
| `worktree.zsh` | 23 | `gwt-new`/`gwt-rm` 调 `cc-worktree-shared.sh`、`cc-merge.sh`、`cc-trust.sh`、`cc-dispatch.sh`(workspace)全部找不到 |
| `aliases.zsh` | 3 | `claude()`、`gwt-claude`、`gwt-test` 失效 |
| `cc-dispatch.sh` | 8 | hook 路径下文件不存在 → 子任务永远开不了 tab(吸收了 `cc-cmux-surface-claude.sh`/`cc-worktree-claude.sh`/`cc-cmux-workspace.sh`) |
| `cc-hooks.sh` | 3 | 同上(吸收了 `cc-worktree-cmux-hook.sh`/`cc-status-hook.sh`) |
| `cc-board.sh` | 7 | 任务表写错位置,`gwt-status` 读空(`log` 子命令,吸收了 `cc-tasks-log.sh`;其余为渲染路径默认值) |

**修复方向:**
- **推荐 A — 脚本自解析根目录:** bash 脚本用 `${BASH_SOURCE[0]}`、zsh 用 `${(%):-%x}`(或在 source 时记录一次)推导出 cc-stack 安装根,替代硬编码。自包含,不依赖外部 state。
- **方案 B — install 写 state + 脚本读取:** `install.sh` 写 `~/.cc-stack-dir`(或把 `CC_STACK_DIR` export 进 `.zshrc`),脚本读它。简单但多一层间接。
- 两种方案都应保留 `CC_STACK_DIR` 环境变量作为 override(测试 / 特殊部署用)。

**验证:**
```bash
./install.sh --dir /tmp/ccstack-test --yes
# 在 /tmp/ccstack-test 起一个 claude,gwt-* 应全部工作、不依赖 ~/.config/cc-stack
```

**关联:** `install.sh` 的 `--dir`/`CC_STACK_DIR` 处理(约行 13、41)、README 的 install 文档(约行 40-65)。

**当前硬编码计数(2026-08-16 本轮修复后重新统计,供下一条线用)**:`worktree.zsh` 27 · `cc-dispatch.sh` 18 · `cc-board.sh` 7 · `gwt-done` 4 · `cc-hooks.sh` 3 · `aliases.zsh` 3。
注意 `worktree.zsh` 已有 `_gwt_src_dir` 自解析并用于 `cc-board.sh` / `cc-dispatch.sh` / `gwt-done` 三个入口,`gwt-done` 与 `cc-board.sh` 也已用 `$(dirname "$0")` 自解析——**方案 A 的机制已经存在,缺的只是推广到其余调用点**(`cc-merge.sh` / `cc-trust.sh` / `cc-worktree-shared.sh` 的调用仍写死)。

## hook 防双开过滤的非规范引号角落(cc-hooks.sh worktree)

**现象:** `CC_WT_PROMPT` 若不用文档规定的单引号形式(例如双引号包裹、或 `'\''` 内嵌撇号),且 payload 文本里恰好字面点名 `cc-dispatch.sh` 或两个 legacy 脚本名,该次派发会被 SKIP —— **无 tab,且无任何记录**。

> **订正(2026-08-16 实证)**:原文这里写的是"失败可见:cc-failures.log 有记录",**与实现不符**。
> 防双开这一跳走的是裸 `sys.exit(0)`,从来不写面包屑(改动前后都是)——否则每次 `gwt-claude`
> 都会刷日志。实测:双引号形式 + payload 点名 dispatcher → stdout 空、stderr 空。
> 所以这个角落的真实性质是**静默**,比原文描述的更难排查(症状只有"该开的 tab 没开")。

**界定:** 规范单引号形式完全不受影响(剥离按 `CC_WT_PROMPT='…'` span 做);该角落是剥离方式的固有边界,方向为净收紧(基线对新名字本来就是 DISPATCH),触发需要同时违反引号约定并在 payload 里点名 dispatcher,概率极低。

**处置:** 无需修复;记录在案。若将来出现真实误触,把剥离从"单引号 span"升级为"引号无关的 token 级检测"即可。

## cc-send 门卫失效(claude TUI 升级后)——排查锚点

**症状**:cc-send 不再等待正在输入的用户(恒直达),或恒走 fail-open 面包屑;开 tab 自校准报模式不命中;或反之——**无人输入却 hold 死等**(60s 通知后无限等)。

**根因**:cc-send(`cc-dispatch.sh send`)靠 read-screen 解析 claude TUI 输入行的"❯ 提示符 + 行内是否已有未提交文本"判断撞车。该形态由 TUI 渲染器(`tui: fullscreen|default`)和 claude 版本决定——**claude TUI 改版输入区后,模式列表失配,门卫失明**。已实测(2026-08-15,claude 2.1.233):两种渲染器的输入行**字节级一致**——空态 = `❯` + U+00A0 不换行空格(光标占位,不是 ASCII 空格!),输入态 = `❯` + NBSP + 草稿;transcript 会以 `❯` + ASCII 空格回显已提交消息(在活输入框**上方**,故 cc-send 自底向上取最后一条命中行)。

**根因变体——上下文建议 placeholder 中毒(2026-08-15 晚实弹)**:输入框空态下的**建议型 placeholder**(TUI 按会话上下文生成的跟进提示,如"继续,L10 三条做完就发令牌合并")会**渲染进 pane 文本缓冲**——read-screen 捕获到 `❯ + 建议文案`,cc-send 判 busy → hold。placeholder 本身就是空态、永远不会"清空",没有人工干预即**无限 hold**(现场:子任务汇报被扣 6 分钟,直到人工发消息解堵)。与草稿无法用文本区分(本质差异是颜色:placeholder 恒暗灰、输入恒正常色,而 read-screen/capture-pane 均不保留转义码)。**已应用规避:`~/.claude/settings.json` 设 `"promptSuggestionEnabled": false`**(schema 原文:When false, prompt suggestions are disabled;env 替代 `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION`)——只对新会话生效。辅助判别(editorMode=vim 时):有字但模式行无 `-- INSERT --`/`-- NORMAL --` 标记 = placeholder 态;该标记是 vim 专属,非 vim 配置无此信号。

**实现参照**(模式列表 + 兜底都在 `cc-dispatch.sh` 顶部的 cc-send 块):
- 默认模式列表 `^❯:^>`(冒号分隔 ERE,自动锚定行首);`CC_SEND_INPUT_PATTERNS` **整体替换**默认列表;
- 空白判定把 NBSP(UTF-8 字节 c2 a0)视为空白——若新版光标占位换成别的字符,空态会被误判 busy(超时→通知→死等),同样是本条目的排查对象;
- 持有通知非一次性:`CC_SEND_TIMEOUT`(默认 60s)首发,此后每 `CC_SEND_HEARTBEAT_SEC`(默认 300s,0=只发一次)重发,正文带 blocked-by 预览(`CC_SEND_PREVIEW_CHARS`,默认 40,0=关)——placeholder 类无限 hold 至少持续可见;
- busy 快路径:捕获里出现工作指示行(旋转 glyph + 时长括号,实测 6 帧 `· ✢ ✳ ✶ ✻ ✽`,形如 `✻ Befuddling… (10m 12s · ↓ 34.0k tokens)`;`CC_SEND_BUSY_PATTERNS` 整体替换)即**跳过等待直接发送**——cmux 对工作 pane 的 send 会入队并被消费,输入框里的队列文本不值得等。pattern 失配只是退化回等待,方向安全;
- 面包屑写 cc-failures.log(`CC_SEND_FAILLOG` 可覆盖):fail-open、校准失配、发送后 park 各写一行,gwt-status 可见。

**排查三步**:
1. 任意 idle claude tab 跑 `cmux read-screen --surface <ref> --lines 8`,看输入行现在的形态(空态),必要时 hexdump(`| od -An -tx1`)确认 ❯ 后面的字节;
2. 跑 `~/.config/cc-stack/cc-dispatch.sh calibrate <ref>`(对已知空输入框复检模式命中;miss 会写面包屑并 exit 1),对照模式列表是否匹配新形态;
3. 不匹配 → `CC_SEND_INPUT_PATTERNS` 一行改配置先恢复,或跟进新版式;更新后用"注入文本不按 Enter + read-screen"复检(设计验证手法,2026-08-15 已用此法实证过)。

**hold 类症状的排查前缀**:先确认非空行是不是 placeholder(肉眼看灰字,或 vim 配置看无编辑标记)——是则先查 `promptSuggestionEnabled` 是否被版本改版重新默认开启,而不是调模式列表。

**兜底语义**:模式失配时 fail-open 退回裸 send——行为=本功能出现之前,不会丢消息、不会扣死,只是失去防撞保护。开 tab 自校准(cc-dispatch.sh surface 在 TUI 起来后跑一次)的面包屑是第一报警线。

## cmux send 到 idle pane 会静默停在输入框不执行(与 cc-send 的交互)

上游缺陷记录在主 checkout 的 `docs/issues/cc-stack-issues.md` Defect 2(cmux 侧问题,cc-stack 不修执行验证本身)。交互语义:
- cc-send 的出口固定是 `cmux send` + `send-key Enter` **成对**——Enter 是该缺陷的 flush 手段,但**成对不等于必达**(见下方现场数据);
- 若输入框里已有**历史残留的 parked 消息**(旧裸 send / busy 队列留下),❯ 行非空 → cc-send 判 busy,持有 + 桌面通知而非追加堆叠(安全的失败方向);清掉残留后正常投递;
- 同文档观察 #1(首字符在传输中被吞)对 cc-send 同样成立——报告消息开头几个字符可能丢失,关键路径用文件传递。
- **现场数据(2026-08-15,父→子长指令)**:`cmux send` + `send-key Enter` 双双返回 OK,长文本被 TUI 折叠为 `[Pasted text #1]` 后**紧随的 Enter 被吞**,消息在输入框停了 ~15 分钟、claude 全程不知情,手动再补一个 Enter 才送达。教训:发长指令后用 read-screen 复核输入行已清,非空则补按一次 Enter;"发送后确认 + 补按"已实现(2026-08-15,feat/ccsend-delivery-impl):cc-send 空态投递后复读输入行,非空即补按**一次** Enter,再非空则响亮失败(stderr + 面包屑 + rc≠0),绝不假装成功;busy 快路径投递跳过复核(队列文本留在输入框是合法终态)。

## macOS BSD sed:BRE 里字面括号 + `.*` 跨过文本 `)` 再锚 `$` 会静默失配

**症状**(2026-08-16,8c 测试首跑 8 败连锁):`sed -n 's/^ *staged merge PRESERVED in: \(.*\) (branch .*)$/\1/p'` 对含 `(branch feat/camp)` 的行**静默不匹配**——无报错、无输出,下游全部断言级联失败。GNU sed 语义下同式正确。

**根因**:`/usr/bin/sed`(BSD,darwin 25)的 BRE 匹配怪癖,~20 组探针定界:模式含**字面 `(`**、其后的 `.*` 需要**跨过主体文本中的 `)`**、再锚 `$` 时失配;去掉任一条件(`(` 或 `$` 或跨 `)`)即恢复正常。`\(…\)` 分组、无括号 `.*$`、`).*$` 均正常。LC_ALL=C 无济于事。

**规则**:在本仓库(darwin + bash 3.2)里,**解析含括号的行一律不用 sed 模式混排字面括号与通配**——用 bash 参数展开(`${v#*prefix}` / `${v%% (suffix*}`)或 awk。先例:test.sh 8c 的 `kept` 提取(注释里有指向本条)。

## 测试污染真实状态(同一类问题已三次;2026-08-16 上机制修)+ 删除动词备忘

**这条原名「测试泄漏真实 cmux workspace」,现按第三次复发后的教训一般化。**

**规矩(升级后)**:测试**不许留下任何真实副作用**——不只是 surface / workspace,还包括四个 TSV
(`worktree-tasks` / `worktree-status` / `worktree-tasks-archive` / `opened-tabs`)、`~/.claude.json`、
`~/.claude/settings.json`。

**机制(不再靠"逐处加 override")**:`test.sh` 顶部统一 export 一组 sandbox 路径(四个 ledger +
`CC_TRUST_CFG_OVERRIDE`);**裸 `unset` 是这类泄漏的根源**,凡是要"归还"的地方一律调 `cc_sandbox_ledgers`
回落到 sandbox,而不是回落到 live 默认路径;末尾一节做 7 条**可归因**的收尾断言
(账本不许消失 / 已有行一条不许少 / trust 条目不许少 / fixture 路径不许出现在真实账本 /
settings.json 的 hooks 注册不许变 / 不许留 `.lock` / 五个 override 收尾时仍在 sandbox)。

**取证教训(反直觉,值得记住)**:**sha 不足以证明没被污染。**
`_gwt_tasks_rewrite` 做的是 read→`mv` 全量重写,恰好没有行匹配时**字节不变、只有 mtime 变**。
第一次抓到泄漏靠的是 **mtime**,不是 sha。反过来,mtime/sha 也**不能当硬断言**:
`cc-board.sh` 每次读板都 prune-on-read 重写 tasks.tsv,任何活着的 agent 的 status hook 都会写
status.tsv——拿它们当断言会假阳性,而假阳性的门卫最后都会被删掉。所以收尾断言用的是上面那 7 条
可归因判据,sha/mtime 只降级成诊断输出。

**跨线交互的实例(2026-08-16,gate 时抓到)**:一条并行线在自己的小节结尾写了裸
`unset CC_TASKS_FILE …`,rebase 后与另一条线新建的 sandbox 层相遇——
`_cc_overrides_escaped` 在 `set -u` 下遍历已 unset 的变量,函数直接死掉、命令替换吐空,断言
`expected[0] got[]`。断言变红只是可见的一半;不可见的一半是该节之后所有小节都回落到了真实默认路径。

**第一次复发的原始记录(cmux workspace)**:`test.sh` 第 12 节的 `gwt-adopt` 走真 cmux——`gwt-adopt <branch>` 会给被收编的 worktree 开一个 cmux **workspace**(worktree.zsh → `cc-dispatch.sh workspace`),测试没做 PATH shim,**每跑一次套件就在用户界面上留一个 `feature-orphan-y` 空 workspace**(2026-08-16 一次清出 5 个:workspace:147-151)。已修:该节的 `gwt-adopt` 调用全部经一个 no-op 假 cmux(`azsh`),套件跑完 workspace/surface 计数不变(已实测 7/7、8/8)。

**第二次复发(2026-08-16 gate 时抓到)**:`test.sh` 第 19b 节的 `gwt-rm wtguard --branch` 没带
`CC_TASKS_FILE` / `CC_STATUS_FILE` override,直接对真实账本做 read→`mv` 重写,并对真实
`~/.claude.json` 调 `cc-trust.sh --remove`;另有三处小节用裸 `unset` 归还变量,等于把后续小节交回真实默认路径。

## 删除动词备忘

**删除动词(实测定界,2026-08-16)**:
- **关不掉最后一个 surface**:`cmux close-surface` 关 workspace 里仅剩的那个 surface 会报 `invalid_state: Cannot close the last surface`——所以"把 surface 关光,空 workspace 自己消失"这条路**不存在**;
- workspace 必须显式删:`cmux workspace close --workspace <ref|uuid>`(旧名 `cmux close-workspace` 仍可用,但会打一行 alias 提示,`CMUX_QUIET=1` 可静音);
- **UUID 目标跨 workspace 需要上下文**:`cmux close-surface --surface <UUID>` 只在目标位于调用者**当前 workspace** 时直接命中;目标在别的 workspace 里会报 `Error: Surface not found: <UUID>`,要补 `--workspace <ref>`。对 `cc-dispatch.sh close` 的影响:子任务 tab 是在派发方 workspace 里开的,常态命中;若有人把 tab 拖到别的 workspace,关闭会**响亮失败**(`✗ cmux close-surface failed for uuid …`),不会误关别的东西——留作已知残留,未加自动补 `--workspace` 的重试。

## ~~cc-board 读循环对空 caller 字段的 TAB 塌缩(存量,未修)~~ 已修(2026-08-16,feat/wtz-board)

**严重度修正:这条曾被记成"显示错列 / live 数据 0 行受影响",两条都是错的。它是 P0 落盘损坏。**

**现象**:任务 TSV 任一中间字段为空时,`IFS=$'\t' read` 的连续 TAB 塌缩使后续字段左移一位。
致命的一步在 **`cc-board.sh` 的 prune-on-read**:它读 7 个变量再 `printf` 7 个字段,
于是把读错的结果**写回文件**——一次读错固化成永久损坏。同型写点还有 `worktree.zsh` 的
`_gwt_tasks_rewrite` / `_gwt_archive_branch` / `gwt-prune` 去重循环。

实测(2026-08-16,8 字段行跑一次 `cc-board.sh --all`):

| 空字段 | 结果 |
|---|---|
| 第 7 字段 parent | 8 字段永久变 7 字段,`launch-args` 整串挪进 **PARENT 列** |
| 第 5 字段 caller | caller/task/parent 全部左移,**第 8 字段直接消失** |

**为什么"live 0 行"是错的**:(a) 第 8 字段 launch-args 落地后写侧几乎恒非空;
(b) 第 7 字段 parent 在 detached HEAD 下恒空(`cc-dispatch.sh` 取 `symbolic-ref --short HEAD` 返回空)。

**后果链**:第 8 字段错位 → `gwt-resume` 取不到 `uuid=` 把行降级成 idle tab;
`cc-dispatch.sh close` 取不到 `csuuid`/`suuid` → fail-closed 拒绝关 tab。
**下面「文本门卫退役」条里"三个 tab 只能人工去 UI 关"的现场,除了"先跑 gwt-rm 再 close",本条是另一个可能成因。**

**处置**:走**读侧 awk** ——所有字段访问改 `awk -F'\t'`,所有 rewrite 改成"按行号选行、原样 re-emit 整行",
不再逐字段 re-printf,因此 7/8/9 字段行逐字节 round-trip、**无存量行迁移问题**(没有选 `-` 占位的写侧方案)。
awk→shell 的交接用 **US (0x1f)** 而非 TAB:TAB 是 IFS whitespace,`read` 必塌缩;US 不是,空字段能原样读回。
顺带补了两处数据安全:archive / gwt-prune 的 awk 或管道失败时不再把半成品 `mv` 覆盖任务表(原来会)。

**同类残留(修于 2026-08-21,feature/audit-0821,dispatch-fixes 线;backlog 原 #4 结项)**:
`cc-dispatch.sh` resume 段用 awk 抽 5 字段之后,又用 `IFS=$'\t' read` 读回去
——`$2`/`$3` 为空时同样错位,把 `r_task`/`r_largs` 挪位。dir 排第一所以不会错仓库,影响面是
resume 误读 uuid;两个字段写侧都有 `?` 兜底,概率低。`cc-hooks.sh` 已全程 awk,无此问题。

## ~~block-worktree-commit.sh 未入库(运行态孤儿文件)~~ 已收编(2026-08-16,feat/safe-close-impl)

原风险:`~/.claude/hooks/block-worktree-commit.sh`(v2,命令有效目录判定)是 commit 门卫的唯一实现,不在仓库——机器迁移即丢、无测试覆盖。
**处置**:原样收编为 `hooks/block-worktree-commit.sh`(v2 语义未改:命令有效目录 `cd X`/`-C X` 优先,解析失败回退会话 cwd;哨兵一次一 commit),install.sh 注册到 PreToolUse,并把旧的 `~/.claude/hooks/…` 注册当陈旧项剥离(按 `.claude/hooks/` 路径子串匹配,不会误伤新注册)。**残留清理靠人**:重跑 install.sh 后 `~/.claude/hooks/block-worktree-commit.sh` 文件本身还在(已不再被注册),可手工删。(当初与它一起注册的 `hooks/block-unsafe-close.sh` 已于 2026-08-16 退役,见下文"关 tab 事故"条。)

> **后续(2026-08-16 晚,feat/commit-gate-git):这个 PreToolUse 实现已整体退役。**
> 门卫改为 `hooks/git-pre-commit.sh` —— **git 自己的 pre-commit**,按仓库挂一次到 `.git/hooks/`
> (`cc-dispatch.sh commit-gate mount|unmount`;`surface`/`workspace` 开 worktree tab 时自动挂,
> install.sh 步骤 4b 给安装目录挂)。install.sh 的 PreToolUse **不再注册任何东西**,旧注册按
> **裸文件名** `block-worktree-commit.sh` 剥离(同时扫掉 `~/.claude/hooks/` 与仓库路径两种写法),
> 安装目录里的旧文件由 install.sh 删除。**仍需人手删的只剩 `~/.claude/hooks/block-worktree-commit.sh` 这一个文件。**
> 理由见下文「文本门卫退役」条末尾的"commit 门卫为什么结论不同"。

## 关 tab 事故(2026-08-16 02:19):父会话用漂移的短号自杀

**严重度:** P1(已修 — 本条记录机理;当初的文本门卫已于当天退役,见本条末尾)

**时间线**:email-goal-4C campaign 的父会话(cloudoverture)完成已授权的合并后清理,准备关掉"自己的三个子 tab"。
1. 先用裸数字 `cmux close-surface --surface 283`(等价形式)→ 3 次全失败:`Surface index not found`;
2. 改写成 `for s in 283 284 285; do cmux close-surface surface:$s; done` → 其中一次回执 `OK surface:286 workspace:137`——**关掉的是它自己所在的 pane**,父会话当场死在这一句上(transcript 停在该 tool_result);
3. 事后发现"幸存的那个子 tab"其实是主 checkout 里一个旧的 continued 会话——**父会话脑子里的 tab 账本早就和现实脱节了**。

**机理(2026-08-16 实弹复现,两个临时 tab,已清理)**:
- **短号会漂**:`cmux new-surface` 开出来报 `surface:291`,同一个 tab 关闭时回执却是 `OK surface:292`;再开一对是 293/294,关 293 回执报 295。短 ref 是**会话内动态分配的地址,不是身份**;
- **裸数字是 index 语义**:`--surface 283` 按索引解释,pane 开关一次就整体重排 → "Surface index not found"或指向别的 tab;
- **位置参数被静默忽略**:`cmux close-surface surface:99999`(没有 `--surface` 旗标)**不报错、不关那个 surface**,而是回落到 `--surface` 的默认值 `$CMUX_SURFACE_ID`——**关掉调用者自己**。这才是父会话自杀的直接原因(不是"短号刚好漂到自己头上")。CLI help 里 `--surface` 标着 `(default: $CMUX_SURFACE_ID)`,这个默认值加上被忽略的位置参数,构成一个静默的自杀陷阱;
- 稳定身份只有 **surface UUID**:`cmux close-surface --surface <UUID>` 实测精确、跨漂移可靠(`--id-format both` 可同时拿到短 ref 与 UUID)。

**为什么 UI 路径豁免**(第一轮的推理,结论仍成立):人在 cmux 界面上点关闭根本不经过 Claude Code 的任何 hook——那是人的操作,人对自己开的 tab 有完全处置权。所以"父/主 checkout tab 只有人能关"落到实现上就等于:**拦掉所有自动化(Bash)发起的、目标不是自己孩子的关闭**。

**第一轮修复(feat/safe-close-impl,2026-08-16 上午)**:
1. **账本带稳定身份**:派发时 `cc-dispatch.sh surface` 把两个 surface UUID 写进板子 launch-args 字段 —— `csuuid=<派发方(父)surface uuid>`、`suuid=<子 tab 自己的 surface uuid>`(model 仍恒排末位;旧行无这两项 = 无登记 owner);gwt-resume 恢复 tab 时同步刷新 `suuid`(surface UUID 随 tab 重建而变)。
2. **PreToolUse 门卫** `hooks/block-unsafe-close.sh`:文本解析每一条 Bash 命令,拦截命令位置上的关闭动词,按 a→f 判定。**已于当天退役,见下条。**
3. **合法出口** `cc-dispatch.sh close <dir>` / `gwt-rm <name> --close`:按目录查账本 → 取 `suuid` → 打印解析结果(短 ref + UUID + cwd)→ 策略校验 → **按 UUID 关**。
4. 规则一行进 claude-rules.md 托管块(install.sh 带进 `~/.claude/CLAUDE.md`)。

## 文本门卫退役(2026-08-16 晚,feat/tab-ledger)——为什么不再要拦截层

**结论**:`hooks/block-unsafe-close.sh` 连同它的 install 注册、test.sh 第 18 节的对抗性文本测试**整体删除**。关 tab 策略从此只有三条腿:**账本(数据面)+ 合法出口(执行面)+ CLAUDE.md 规则(约束面)**,没有任何机械拦截层。

**退役理由(两个方向的残留同时到达不可修的地步)**:
- **过松方向不可闭合**:命令文本里看不见的形态门卫永远看不到——事先定义的 alias / shell 函数(定义好别名后只跑 `k --surface X`)、把关闭动作写进脚本文件再 `bash script.sh`、跨空格的 splice(动词被参数展开劈开且跨过空格)。要堵只能在 cmux 侧鉴权,不在本仓库范围;
- **过紧方向反复咬到真实工作**:门卫必须猜"哪个词是命令",而**派发简报的正文里天然引用关闭命令的写法**。2026-08-16 当天两次实弹误拦:
  1. `cmux --json diff --title '…stuff'`——全局旗标状态机把真动词 `diff` 当成 `--json` 的取值吞掉,`--title` 的取值文本被判成动词 → rule c;同族还有"旗标取值恰好长得像动词、真动词无害"的写法;
  2. **(收尾时的那一次)父会话派发本项目这份简报本身被 rule c 拦掉**:简报正文举例引用了关闭命令的写法,而参数里 heredoc(`"$(cat <<'EOF' … EOF)"`)的正文中,一行以引用文本开头的例子——前面恰好有 `(` / `<` / `>` 这类被 tokenizer 当作语句分隔符的字符——被判成"命令位置上的 cmux"。**门卫在阻止一次派发,而不是在阻止一次关闭。**(同一现象在本次实现期间第三次出现:改这份文档的 Bash 写入命令,因为正文引用了关闭动词而被运行态门卫拦下。)

  这两类都能靠加白名单/加惰性命令集缓解,但方向是明确的:**一个必须判断"引号里的散文是不是命令"的解析器,在一个天天互相发命令文本的多 agent 系统里,误拦率只会继续涨**;而它换来的那点保护,本来就绕得过去。

**替代它的是什么(本次落地)**:
1. **第二本账本 `opened-tabs.tsv`**(`CC_TABS_FILE`;字段 `surface-uuid | owner-surface-uuid | dir | session-uuid | ts`,mkdir 锁追加,空字段写 `-` 防 TAB 塌缩):`cc-dispatch.sh surface` / `workspace` **每开一个 tab 就记一行**,owner = 开这个 tab 的 `$CMUX_SURFACE_ID`。它回答"**谁开了这个 tab**",板子回答"**这是谁的子任务**"——两本账**互不去重**,读时按 live surface 惰性剪枝(cmux 不可达时**不剪**:探测不到不等于 tab 死了)。`cc-dispatch.sh tabs` / `gwt-tabs` 是它的清单视图;
2. **合法出口按两本账解析**:`close <dir>` 先板子 `suuid`,**再 opened-tabs 按目录**(板子行会被 `gwt-rm` 删掉,opened-tabs 不会——现场教训:先跑 `gwt-rm` 再 `close`,得到"no live tab resolves",三个 tab 只能人工去 UI 关),最后 cmux 会话库;
3. **策略在出口处执行**(自动化调用方按进程祖先判定,见下条):不许关自己;非 worktree 目录只有"**本会话就是这个 tab 的 opener**"(opened-tabs owner)时放行——这正是"leader 关自己开的 runner tab"这个此前无解的场景;子任务 tab 由**派发它的父**关,**或**在 `gwt-done` 标记 ready 之后由任意自动化调用方回收(完成的子任务是可回收的;**未完成的子任务只有它自己的父(或人)能终止**——这条是保护不变量,四格真值表在 test.sh 第 18 节逐格断言);
4. **规则面**:claude-rules.md 的关 tab 条目保留全部实操约束(只走合法出口;绝不硬编码短 ref / 裸数字 / 位置参数——cmux 会静默忽略位置参数并关掉调用者自己),只删掉"有 PreToolUse hook 拦着"这半句。

**已知测试缺口/理论边角(验收轮备案,非阻塞)**:resume 回放开 tab 的记账写入(第 4 字段取回放命令里的 `--resume` 会话 uuid)目前**只有 gatekeeper 直探验证、无套件内覆盖**(fake cmux 不吐 uuid 回执;补法 = 让 fixture 的 new-surface 回执带 uuid);`_cc_repo_of` 的最后回退(非标准布局 + 目录已删)会落到调用方 repo——分支重名的理论性错读,标准 `.claude/worktrees/` / `.worktrees/` 布局按模式解析不受影响。

**明确的新残留(有意接受)**:手写的关闭命令现在**没有任何机械阻拦**,只有规则约束。判断:2026-08-16 事故的三条直接成因(位置参数静默自杀、裸数字 index 语义、短 ref 漂移)都已在**规则文本 + 合法出口的响亮解析输出**里覆盖,而门卫在事故之后的实际战果是——拦下的多是自己人的简报。

**已知边界(有意为之,沿用)**:
- **fail-closed 仍在合法出口里**:解析不出目标身份、两本账都没有 owner、分支也没 ready —— 一律拒绝,宁可让人去 UI 点一下;
- **cmux 会话库覆盖不到我们的子任务**:`~/.cmuxterm/claude-hook-sessions.json` 只记录 `claude` 启动器的会话,`ccteam`(= `cmux claude-teams`)起的子任务**根本不在里面**(2026-08-16 实测)。所以身份解析以**账本为主**,会话库只作 cwd 兜底;
- **整 window / 整 workspace 的关闭**:同样是人的操作,只靠规则约束。

- **"自动化 vs 人"不用环境变量判定,用进程祖先(2026-08-16 验收轮)**:`cc-dispatch.sh close` 的所有权强制原先看 `$CLAUDECODE`——验收方实弹验证 `env -u CLAUDECODE cc-dispatch.sh close <别人的子任务目录>` 会把强制降级成"只打印"并**真的关掉了那个 tab**。环境变量是被审查的那条命令行自己就能改的,不能当判据。现改为**沿 PPID 链上溯**(`ps -o ppid=`/`-o comm=`,深度上限 12):链上出现 claude 可执行文件 = 自动化调用方,强制所有权;走到 init/登录 shell 都没有 = 人,只打印不强制。`$CLAUDECODE` 只保留为快路径提示(**置位 ⇒ 一定是自动化;未置位不作任何结论**)。测试用 PATH shim 里的假 `ps` 驱动两条链,不给产品代码开 env 后门。

### commit 门卫为什么结论不同(2026-08-16 晚,feat/commit-gate-git)

同一天,同族的**最后一个**文本解析器——commit 门卫 `block-worktree-commit.sh`——也退役了。
但**结论和关 tab 不一样,这个区别必须写清楚,否则后人会把"退役解析器"读成"放弃机械约束"**:

- **关 tab 没有可靠的执行点**。cmux 不给我们任何"真的要关一个 tab 了"的钩子,唯一能插手的地方
  就是"猜某条命令文本是不是关闭动作"。所以那里的结论是:**不要拦截层**,改成账本 + 合法出口 + 规则。
- **commit 有一个天然的执行点:git 自己**。所以门卫没有消失,只是从"猜命令文本"搬到了
  "**git 真的要提交的那一刻**"——`hooks/git-pre-commit.sh`,零文本解析,cwd 由 git 设成正在提交的
  那个工作树,无论命令是 `cd X && git commit`、`git -C "$VAR" commit`、shell 函数还是脚本文件。

**当天该解析器的实战战绩(两个方向都中,这是迁移的直接证据)**:

| 方向 | 现场 |
|---|---|
| 误拦 ×2 | ① 子任务写一个 heredoc 文件,正文**引用**了 `git … commit` 的写法 → 被拦;② 父会话一条探针命令,所有 `git commit` 都在 `/tmp` 临时仓库里,walker 把 `&&` 当成 `cd` 的目标 → 落回 session cwd → 被拦。**两次都是在阻止一次写文件,不是阻止一次 commit。** |
| **误放 ×1** | 父会话用 `git -C "$W" commit` 提交子任务成果——hook 看到的是字面三个字符 `$W`(hook 不做变量展开)→ 不是目录 → 落回 session cwd = 主 checkout → **豁免放行,哨兵从头到尾没被读过**。 |

迁移前给旧解析器打的三个补丁(`set -f`、成对引号剥离、`top` 显式初始化)里,
**有两个原本是 fail-open**——即真的放行了 worktree 里的 commit。加固是净收紧,
但修不掉误拦:弱点在那条 trigger grep(对散文和真命令一视同仁),不在 walker。

**为什么是 `.git/hooks/` 而不是 `core.hooksPath`(实测定界,git 2.55.0/darwin)**:
`core.hooksPath` 会**静默替换下游项目的整套钩子**——一个靠自己的 `commit-msg` 强制
Conventional Commits 的仓库会无声失去它(本仓库 `docs/issues/cc-stack-issues.md` 记录的下游仓库正是这种)。
`.git/hooks/` 则**天然被该仓库的所有 linked worktree 共享**,所以挂载是**每仓库一次**,不是每 worktree 一次。
已存在的 `pre-commit` 存为 `pre-commit.cc-stack-orig`,门卫放行后 `exec` 它,项目自己的钩子照跑;
目标仓库如果已经在用 `core.hooksPath`,**响亮拒绝挂载**,不半吊子服务。

**有意接受的残留**:`git commit --no-verify` 完全绕过(实测:静默提交成功)。这是**故意**的——
退役的 PreToolUse 版本同样能绕(shell 函数、脚本文件、变量指路,父会话当天就无意绕过去一次),
是同一档。**这道门是防手滑、防 skill 自作主张,不是安全边界,不要当成安全边界来卖。**

**已知的行为收紧(未处理,留待决定)**:`cc-merge.sh do-merge` 的 squash 提交发生在
"目标分支所在的那个工作树"里。目标在主 checkout(campaign 的常规情形)不受影响;
但**嵌套子任务**(A1 并回 A,而 A 被 checkout 在受管 worktree 里)那次 merge 提交会被门卫拦下。
降级是干净的(报 `commit-rejected`、保留已暂存的 merge、原样打出门卫那句 `touch`),
父会话 touch 一下哨兵再跑一次即可;摩擦点在 `gwt-collect`——一次收多个孩子要一个哨兵一次。
旧的文本门卫在这里从不触发(命令文本里没有 `git commit`),所以这是相对旧行为的**收紧**。

## install.sh 从 linked worktree 安装会把 `.git` 指针文件复制进安装目录(2026-08-16 修)

**现象**:安装时的 `find` 只排除了 `./.git/*`,但 **linked worktree 的 `.git` 是一个文件**(内含
`gitdir:` 指针),不是目录,所以它被复制进了安装目录——**安装目录从此在 git 眼里是源仓库的一个工作树**。

**为什么要紧**:影响远不止某一个功能。任何"按目录解析仓库"的逻辑(`gwt-*` 全家、
commit 门卫的挂载、`_cc_gitroot`)从安装目录出发都会**静默指向源仓库**。
它就是 feat/commit-gate-git 期间"install 步骤 4b 真的往主仓库 `.git/hooks/` 写了一个 pre-commit"的机制。

**处置**:`find` 加 `! -name '.git'`;挂载侧另加一道守卫——目标目录解析出的 git dir 若不把它
列为该仓库的 worktree(散落/被复制的 `.git` 指针),**拒绝挂载**。

## hook 派发闸门:两条静默跳过 + 一条面包屑(2026-08-16,feat/hook-notab)

PostToolUse 的 worktree hook 现在**只在"意图明确 + 目标无歧义"时才派发**。三种终局:

| 情形 | 行为 |
|---|---|
| 无 `CC_WT_PROMPT` | **不开 tab,静默**(常态,不是故障,不写记录) |
| 路径 pin 不出该仓库的 linked worktree | **不开 tab**,写一行 `cc-failures.log`(板子会显示),点名 add target 并提示改用 `gwt-claude` |
| 意图明确 + 路径精确 | 正常派发 |

**为什么删掉 mtime 兜底**:旧实现解析不出路径时会挑"该仓库 mtime 最新的 linked worktree"顶替。
两个实测后果:(a) bisect 辅助 / 手工建 worktree / 测试 fixture 各白得一个什么都不做的 idle tab
(其中一个的目录当时已经不存在);(b) **更严重**——一个正在跑测试套件的子任务(fixture 里满是
变量指路的 `git worktree add`),被兜底挑中了**它自己的 worktree**,于是在一个已经有 claude 在
工作的目录里又起了一个 claude。

**最隐蔽的一面:mtime 兜底会污染 merge target。** 兜底选中目录后,`cc-dispatch.sh surface` 的
capture 分支跟着跑,`CC_CALLER_CWD` 是子任务自己的 cwd,于是把
`branch.<b>.ccMergeInto` 写成了**分支自己**。后果链全程静默:`gwt-merge` 读到"目标=自己" →
`do-merge` 返回 `skipped: already merged` **rc 0** → `gwt-merge` 当作成功、把板行归档 ——
**这条线从板子上消失,却一行代码都没落地**。2026-08-16 实际发生过一次,靠人工核对 campaign
的 tip 才发现。(后果那一半 2026-08-17 已堵:`capture` 不再写自己、preflight 有
`check: target-not-self`、`do-merge` 提前拒绝 —— 见下文"merge target 被记成兄弟分支"。)

**已知残留(未修)**:目标已 pin 但 mtime > 120s(add 失败 / 目录早已存在)仍是静默跳过、无面包屑;
面包屑只在 cmux 可达时才可能写(hook 在 `cmux ping` 之后才解析),远程 SSH 下整个 hook 是 no-op、
不留任何记录。

## commit 门卫在 `core.hooksPath` 仓库上完全不生效(能力边界,非缺陷)

`hooks/git-pre-commit.sh` 挂进 `.git/hooks/`。但仓库若设了 `core.hooksPath`,git **完全忽略**
`.git/hooks/`,门卫无处可挂,`cc-dispatch.sh commit-gate mount` 会**响亮拒绝**。

**为什么不能强挂**(2026-08-16 对一个真实下游仓库实测,`core.hooksPath = .githooks`):
1. 那个目录是**被版本控制的项目内容**(`commit-msg` / `pre-commit` / `pre-push` / `lib/*.sh` 全部 tracked)
   —— 往里写等于改项目源码,会出现在 diff 里、可能被提交进去;
2. **相对 `core.hooksPath` 按每个工作树各自解析**(实测:在 worktree 自己的 `.githooks/` 放不同钩子,
   提交时跑的是 worktree 那份)—— 所以就算写进主 checkout 也**根本管不到 worktree**。

**后果(要正视)**:**越是有自己钩子纪律的项目,越拿不到 commit 门卫。** 那里的
`.commit-authorized` 令牌机制没有任何机械强制,只剩规则约束。
唯一止损是在派发简报里明说"没有文件挡着不代表可以提交"。

理论上的出路:`git config --worktree core.hooksPath`(需先开 `extensions.worktreeConfig`)
能按 worktree 挂而不动项目配置 —— 会改下游仓库的 git 配置,**未采纳**,记录备查。

## gwt-* 里 9 个动词没有任意 shell 入口(存量)

`gwt-*` 是 zsh 函数,子任务的非交互 shell 里不存在。已有任意 shell 入口的只有 5 个,
而且**每一个都是事故之后补的**:

| 有入口 | 无入口(zsh only) |
|---|---|
| `gwt-status` / `gwt-log` → `cc-board.sh` | `gwt-merge` `gwt-collect` `gwt-tree` |
| `gwt-resume` / `gwt-tabs` → `cc-dispatch.sh` | **`gwt-rm`** `gwt-new` `gwt-adopt` |
| `gwt-done` → 独立脚本(2026-08-16 事故后补) | `gwt-prune` `gwt-clean` `gwt-provider` |

**整个"清理 + 合并"家族都在无入口那一列。** 2026-08-16 现场:一个 agent 跑 `gwt-rm` 得到
`_gwt_wt_path: command not found`(部分加载的 shell),改用 `cc-dispatch.sh close <dir>` 才走通。

**注意 `close` 不是 `gwt-rm` 的替代品**:它只关 tab;`gwt-rm` 还要删 worktree、清板行、
清 sidecar、清 pre-trust、可选删分支。用 close 顶替会漏掉后面几步。

**排查提示**:纯 bash `source worktree.zsh` 会在第 20 行 `${${(%):-%x}:A:h}` 直接 bad substitution
退出,**一个函数都不定义**(所以症状是 `gwt-rm: command not found`);
"`gwt-rm` 在但 `_gwt_wt_path` 不在"是另一种部分加载态。

## merge target 被记成**兄弟分支**:ff 之后尖端相同,cwd 不再能区分 campaign 和兄弟(2026-08-17 修)

**现场**:一条 campaign 下三条并行线。线 A 先 ff 合进 campaign 分支 —— 此后
`campaign` 与 `feat/A` **是同一个 commit、同一份工作树**。随后派出的线 B 的 merge target 被记成了
`feat/A`;`gwt-merge B` 一路四项全绿、打印 `merged: feat/B -> feat/A`,而 **campaign 分支原地不动**。
差一个 `y` 就把一条线折进了兄弟里。人工用 `set-parent` 钉死后两条线才躲开。

**根因**:merge target 由 `cc-merge.sh capture` 记录,取的是**发起方 cwd 所在分支**
(`git -C <cwd> symbolic-ref --short HEAD`)。这个信号在 ff 之后**失去分辨力**:campaign 和刚合进去的
兄弟指向同一个 commit,`git status`、工作树内容、`rev-parse` 全都一样,站错一个目录看不出来。

**为什么闸门抓不住**:拓扑里也没有这个信息。B 从 campaign 拉出来,ff 后 `merge-base(B, A)` 与
`merge-base(B, campaign)` 是同一个 commit,`merge-tree` 自然不冲突 —— preflight 的四项检查
(clean / done / target-exists / conflict)**每一项都该绿**。**能区分二者的只有"派发时的意图"**。

**修法(两层)**:
1. **根因**:显式 base 就是记录的 merge target。`capture` 增加第 4 个参数
   `<base>`,base 若命名了一个分支就直接写成 `ccMergeInto`,cwd 只在没有显式 base(或 base 是
   `HEAD`/tag/sha,不构成意图)时兜底。三条派发路径都接上了:`gwt-claude --base`、`gwt-new` 的
   base 位参、以及 **hook 路径** —— `cc-hooks.sh` 现在把 `git worktree add <path> <base>` 的第二个
   位置参数解析出来,经 `CC_WT_BASE` 交给 `cc-dispatch.sh surface`(emit 协议随之变成
   `path \t mode \t base \t prompt`,prompt 仍在最后)。技能文档一直写着"`--base` 记录 merge
   target",现在代码才真的对上。
2. **纵深(可见性)**:preflight 多打两行 —— `target-parent: <目标自己的目标>`,以及目标本身
   是一条已登记的子任务线时的 `note: ... 落这儿不会推进 <camp>`;`gwt-merge` 的授权行也从
   `into feat/A` 变成 `into feat/A → camp`。**这不是检查**(嵌套树本来就往子任务线上合),而是把
   "尖端相同时人眼看不见的那一格"打印出来,让 y/N 之前能分辨。

**顺带补的两条守卫**(同一个洞的另一面,原"gwt-merge 不拒绝目标 == 自身"那条):
`capture` **不再把分支自己写成自己的 merge target**(不写配置 → `get-parent` 回落 trunk:可能不对,
但绝不会伪装成一次成功);`preflight` 新增 `check: target-not-self`,`do-merge` 在任何 git 动作之前
拒绝并返回 rc 2,`gwt-merge` 连 `--force` 也不放行 —— 此前它会四项全绿、把分支合进自己、拿
`skipped: already merged` **rc 0** 当作落地并**归档板行**,一次空操作被完整包装成一次成功。

**仍未覆盖 → 修于 2026-08-21(feature/audit-0821,merge-target 线)**:发起方站错目录 **且** 没给
显式 base 时,记的仍是 cwd 的分支(ff 之后依旧无从分辨)。该线把 capture 契约定死:显式本地分支
base = merge target;其余情况(省略 / `HEAD` / tag / sha)按回落链记录,但**记了什么必须回显给派发方**
—— gwt-claude / hook 两条路径的具体回显形态由该线实现,文档只钉住这个契约(核对回显,别赌回落);
板行 PARENT 列即记录到的 target,复用已有分支时非显式 base 不再覆盖已记录的 target。
同线还在处理(以 gate 后形态为准):非本地 base / detached-HEAD 回落 trunk 的记录、gwt-tree 节点来源、
hook 性能。规则文档(claude-rules.md)随之改为"记了什么会告诉你——核对它"。
止损纪律不变:派发永远带显式 `--base`。

## ~~gwt-tree 的 tab 存活标记仍是单 workspace(跨 workspace 问题的第五面,未修)~~ 已修(2026-08-21,feature/audit-0821,wtz-guards 线)

`worktree.zsh` 的 `gwt-tree` 自己调 `cmux list-pane-surfaces` 判 `✔live`/`⌫closed`,
**没有走** 2026-08-16 修好的跨 workspace 并集(`_cctabs_livemap`)。
所以别的 workspace 里活着的子任务,在 `gwt-tree` 上仍会显示成 `⌫closed`。
`cc-board.sh` / `cc-dispatch.sh`(prune / close / resume)四面都已修,只剩这一面。

**修法(2026-08-21,wtz-guards 线,5e69955 落地)**:存活探测改走跨全部 workspace 并集(逐
`--workspace` 枚举),别 workspace 里活着的子任务不再误显 `⌫closed`;匹配前剥掉选中行的前导 `*`
再按字段精确匹配——子串匹配会把已关的 tab 显示成 live,不剥 `*` 则当前选中的那个反显示成
closed(与 cc-dispatch.sh:334 同一 sed);workspace 枚举不完整时渲染 `?` 并打脚注,不猜。

---

## 2026-08-21 追记:audit-0821 campaign 转写

以下条目来自 `docs/plans/audit-0821.md`(gitignored,只在主 checkout)的审计结论,由 rules-docs
线转写入库(2026-08-21)。行号/证据按 audit 时点;标「修于」的是本轮各子任务线的计划落地,
⚠ 一律以该线 gate 后的实际形态为准。

## gwt-rm 对脏 worktree 无条件 `--force` 强删

**现象**:`gwt-rm <name>` 在 worktree 有未提交改动时直接丢弃,无确认、无提示。
**根因**:`worktree.zsh` 的 gwt-rm 实现:`git worktree remove … || git worktree remove --force …`
—— 第一次失败(脏树)就无条件回退到 `--force`,把"删不动"当成"那就硬删"。
**修法/修于**:修于 2026-08-21(feature/audit-0821,wtz-guards 线,5e69955 落地):拒绝判据不靠
事后反推——预检在 shared-corpus collect **之前**拦两类:**脏树**(`git status --short` 非空,打印
头 20 行 + `--force` 提示)与 **locked**(`worktree list --porcelain` 检出——locked 的树是干净的,
会绕过脏检查,必须单拦),拒绝时 rc 1、主仓零改动;探测本身失败也按拒绝处理(fail-closed)。
submodule 有意不探(git 2.55 对未填充 gitlink 的干净树本来就会删,自判反而更严、误拦常规 rm)。
其余情形交给 git 本身:`git worktree remove` 失败原样打印 stderr,无 `--force` 一律 rc 1、什么都
不清。`--branch` 判已合并:target 取 `cc-merge.sh get-parent`,merged = `git merge-base
--is-ancestor` 或 target log 里有 do-merge squash 写的 Child-Tip trailer;target 分支已删则回落
trunk 再判一次;分支本就不存在时顺手清 `branch.<b>.*` config section 并说明——已合并直接删并打
`merged into <target>`,未合并保留 + 提示。`--force` 是唯一破坏性开关,同时管工作树和分支
(`--branch --force` 才 `-D`)。

## `CC_WT_COPY` 复制语义漂移:gwt-claude 无条件覆盖,hook 路径跳过已存在文件

**现象**:同一个 `$CC_WT_COPY` 清单,两条派发路径的复制语义相反——worktree 里已存在的文件
(比如子任务已改过的 `.env`),gwt-claude 路径会直接覆盖掉本地改动,hook 路径则跳过;行为取决于
谁派发,覆盖那半边会静默吃掉子任务的修改。
**根因**:`worktree.zsh:76` `cp -p "$root/$f" "$wtpath/$f"` 无条件覆盖;`cc-dispatch.sh:689`
`[ -e "$abspath/$f" ] && continue`(注释直言 don't overwrite if it already exists)跳过已存在。
两处各写各的语义,互不知情。
**修法/修于**:修于 2026-08-21(feature/audit-0821,wtz-guards 线 F3,5e69955 落地):
`_gwt_bootstrap_wt` 不再覆盖 worktree 里已有的文件(存在即 `kept worktree's own`,与
cc-dispatch.sh surface 路径一致);seeding 全程 best-effort、rc 不外漏,`CC_WT_SHARE` 为空或
seed 失败都不再让 bootstrap 失败(旧写法 `[[ ]] &&` 在导出空值时 rc=1,gwt-new/gwt-adopt 会在
worktree 建好之后整个 bail)。(默认清单写在三处的结构性问题另记 backlog 队列 #5,本轮无人认领。)

## surface prompt 临时文件按超时删,held/failed 投递可能读到空

**现象**:launch 行经 cc-send 投递;若 cc-send 因目标输入框有字而 hold,或投递失败重试,
读到的 `$pf` 临时文件可能已被删——launch 收到空 prompt,子任务起在空简报上。
**根因**:`cc-dispatch.sh` surface 路径:`pf="${TMPDIR:-/tmp}/cc-wt-prompt.$$.txt"`(:846),
launch 用 `ccteam "$(cat '$pf')"` 投递;`rm -f "$pf"` 在 ≤6s 的 trust-scan 循环之后**按时间
无条件执行**——删除只由循环超时推动,不证明 launch 行已被 shell 消费(held/failed 恰是没消费)。
**修法/修于**:修于 2026-08-21(feature/audit-0821,dispatch-fixes 线):临时文件生命周期改为
跟随投递确认,不再按超时删。⚠ 以该线 gate 后形态为准。

## cc-send parked 面包屑无失败证据(audit 实测 16/16)

**现象**:audit-0821 实测 16 个 parked 面包屑,无一个对应真实失败的 send——报警本身可能是误报。
**根因**:`cc-dispatch.sh:188-189` 写面包屑的动作与 TUI 消费队列文本的时机竞争:crumb 在 send
结果未定时就落盘,排查时把"写了 crumb"当"send 失败"。
**修法/修于**:修于 2026-08-21(feature/audit-0821,dispatch-fixes 线):面包屑只在确认失败后写。
⚠ 以该线 gate 后形态为准。

## 任务板仓库过滤在 linked worktree 下滤掉同仓全部兄弟行

**现象**:从 worktree 里跑 `cc-board.sh`,本仓库其它子任务的行一行都不显示。
**根因**:`cc-board.sh:143-149` 调用方仓库根用 PWD 起 `git rev-parse --show-toplevel`——在
linked worktree 里它返回 **worktree 自己的根**,不是主 checkout 根;:328-331
`case "$cdir" in "$root"|"$root"/*)` 于是把所有兄弟行滤掉。
**修法/修于**:修于 2026-08-21(feature/audit-0821,dispatch-fixes 线):过滤键改用主 checkout
根(`--git-common-dir` 一类),同仓 worktree 行全部可见。⚠ 以该线 gate 后形态为准。

## mkdir 锁 10 处副本、无 stale 恢复(OPEN)

**现象**:并发写 TSV/状态文件的互斥靠 `mkdir` 自旋锁;锁目录残留(进程被杀)后,后续写入全部
等满超时再 fail-open 写——竞态窗口被拉长,且无提示。
**根因**:10 处副本各自实现:`cc-dispatch.sh:278/1398/1427`、`cc-hooks.sh:333`、`cc-board.sh:76/137`、
`worktree.zsh:118/154/192/349`。均为「60 × 0.05s 自旋 + 超时 fail-open 写」,无 pid/年龄记录、
无 stale 回收(`cc-hooks.sh:330` 注释直言 "if the lock never frees we still write")。
**计划**:单一实现(pid + 年龄回收)全部改用;碰所有文件 → 所有并行线落地后独占一轮做
(backlog 队列 #1,audit-0821 的「第二波」)。

## cc-send 的 "never dropped" 承诺与调用方 Bash 工具超时互相矛盾(OPEN)

**现象**:cc-send 语义是「永不丢消息」(目标忙就等),但子任务经 Claude 的 Bash 工具调用它,
默认 120s 被工具超时杀掉——等待中的 send 连同消息一起死,承诺落空。
**根因**:承诺在进程内,超时在进程外(调用方工具层),两者之间无协议;`cc-dispatch.sh:226-227`
的 notify 文案宣称 never dropped,但没有对应的超时预算。
**计划**:短期纪律——关键回传一律 `run_in_background` / 调大 `CC_SEND_TIMEOUT`;根治归架构项 C
(文件邮箱 + hook 注入,屏幕抓取只作 fallback),不单独立线(backlog 队列 #4)。

## 2026-08-21 23:00 事故:三条子任务线把草稿写进主 checkout,污染活安装目录

**现象**:2026-08-21 23:00–23:52,三条子任务线先后通过绝对路径 `~/.config/cc-stack/` 把草稿写进
父会话的主 checkout(按恢复后的文件 mtime 定线,内容现已全部等于 HEAD):`worktree.zsh`
23:16:21(wtz-guards 线);`cc-dispatch.sh` / `cc-board.sh` / `test.sh` 同为 23:20:10——一次
`git checkout --` 恢复的痕迹(dispatch-fixes 线);`cc-hooks.sh` / `cc-merge.sh` 直到 23:52 才由
父会话恢复(merge-target 线)。主 checkout 同时是**活的安装目录**,本机所有会话的
dispatcher/hook 运行态当时跑的是半成品——rules-docs 线在窗口期调用活的 `cc-dispatch.sh send`
撞到的 :885 语法错误,就是 dispatch-fixes 线改到一半的主 checkout 副本;兄弟线(worktree)的
测试经硬编码路径读到脏副本,树渲染相关 8 项断言失败,污染源恢复到 HEAD 后消失。
**根因(两层)**:
1. 简报和文档里到处是 `~/.config/cc-stack/` 绝对路径,而主 checkout 兼任安装目录——子任务照抄
   绝对路径编辑,写的就是运行态本身;
2. `worktree.zsh` / `cc-hooks.sh` 内部硬编码该路径,worktree 无法真正自测,只能被动读到主
   checkout 的状态(与 known P1「硬编码路径」同根)。
**止损**:① 派发简报必须写明「只在 cwd(自己的 worktree)里编辑,绝不写 `~/.config/cc-stack/` 下的
文件」;② surface 注入子任务的 working agreement 新增第 (6) 条「只在 worktree 内编辑,主
checkout / 安装目录只读」(dispatch-fixes 线在加)。长期根治归 backlog 队列 #2
(P1 · 硬编码路径推广自解析)。

## 子任务被 API 错误/休眠打断后静默停摆,板上与"正在干活"完全同形(OPEN)

**现象**(2026-08-22 实测,campaign `feature/audit-0821`):`feat/dispatch-fixes` 那条线在回复中途
撞上 `API Error: Your computer went to sleep mid-response`,claude 停在空输入框、todo 还开着,
**再也不会自己继续**。板上那一行显示 `working(2h)`——与"确实在跑一个长任务"一模一样。
父会话是靠"这条线两个多小时没回报"起疑,再 `cmux read-screen` 才看到那行 API Error 的。

**根因**:STATUS 列的语义是"最后一次生命周期事件是什么",不是"现在还活着吗"。
`cc-hooks.sh status` 在 UserPromptSubmit 写 `working`、Stop 写 `idle`;一次中途夭折的回复
**两个事件都不会再来**,于是 `working` 连同它那个旧时间戳一直挂着。sidecar 里的 ts 是唯一线索,
而板把它渲染成 `working(2h)` 这种读起来像"忙了两小时"的形式,不是"两小时没动静"。

**为什么不能靠 tab 存活判**:tab 是活的(TUI 在、进程在、`S+` 0% CPU),`✔live` 完全正确。
死的是那一轮对话,不是进程。

**修复方向**(未做):
- 板侧最省事:给 `working` 加一个陈旧阈值(比如 >30m)渲染成 `working?(2h)` 或 `stalled?(2h)`——
  纯显示层,不需要新数据。长任务确实会误报,但"可能卡住了,去看一眼"正是这时候该做的事。
- 更准:`Stop` 之外再挂一个 `SubagentStop`/错误类事件(若 Claude Code 暴露),或让 hook 记录
  `working` 时的 PID,板侧核对进程是否还在推进(CPU 时间是否增长)。
- 无论哪种,**恢复手段已经有了且实测可用**:`cc-dispatch.sh send <ref> "继续"` 就能把它推回去
  (本次即如此);真卡死到键盘不响应时走 `close` + `resume`(见下一条)。

## busy 判定对每个 turn 的头 ~1 秒是瞎的(2026-08-23,feat/ccsend-queued 采样实测,OPEN)

```
CCSEND_BUSY_PATTERNS_DEFAULT='^(·|✢|✳|✶|✻|✽) .*[(][0-9]+[smh]'

  MISS  <✽ Zesting… >                        ← turn 刚开始的形态,没有时长括号
  HIT   <✽ Zesting… (3s · ↓ 1.2k tokens)>    ← ~1s 之后才渲染出括号
```

45 帧/秒的实况采样里,一个 turn 开头连续 **60 帧(≈1.3 s)** 全是无括号形态,`_ccsend_busyhit` 全 MISS。

**为什么没顺手放宽 pattern**(ccsend-queued 线的判断,父会话复核认可):
① `_ccsend_busyhit` 匹配的是**整屏任意一行**,不是自底向上取最后一个 ——
放宽成 `<glyph> <word>…` 会被 transcript 里的正文命中;
② busyhit 一命中就**整个跳过 post-send verify** —— 拿它换这 1 秒窗口,
代价是别处所有真 parked 都不再被兜住。这个改动要单独设计,不该顺手做。

**影响面不止 cc-send**:任何"这个 tab 在忙吗"的判断都吃这套 pattern。

## cc-send parked 假阳性的根因找到了:"Press up to edit queued messages"(2026-08-22 晚,面包屑抓到)

audit-0821 的 dispatch-fixes 线让报警带上**匹配行原文**,这次直接把根因交出来了:

```
[2026-08-22 23:16:21] surface:34 — cc-send parked after send: input line still non-empty
  after one Enter retry (matched line: "Press up to edit queued messages") — see docs/known-issues.md
```

骗到"输入行还有字"判定的**不是** `❯` 提示符回显(那是先前的假设,现在可以降级),
是 Claude Code 在**目标忙碌、消息被排队**时渲染的那行提示。这解释了整个模式:
假阳性总出现在接收方正在干活的时候,因为那正是这行提示出现的时候。

**为什么本该不走到这一步**:cc-dispatch.sh 的 busy fast-path 就是为这种情况设计的
(:212-214 — 忙碌时直接发、不做 post-send verify,因为"排队的文字留在框里是合法终态")。
这次是 **busy 判定没命中**,于是落到 verify 那条路,再被这行提示咬中。

**修法(未做,超出当轮作用面)**:把 `Press up to edit queued messages` 当成**排队信号**
而不是"残留输入"——它出现时应当走 busy fast-path 的终态,报 `delivered (queued)`,不报 parked。

**在修好之前**:收到 parked 报警**先看屏再决定**,不要直接重发。
判据是**底部那个框里的 `❯` 后面有没有字**,不是屏幕上有没有 `❯`——
transcript 里的历史消息也以 `❯ <text>` 渲染。重发假阳性会造成重复消息。
真阳性长什么样见下一条(长多行消息打死 TUI,进程 0.7% CPU 且 Enter/Escape/Ctrl-C 全被吞)。

## cc-send 的 parked 报警有真阳性:长多行消息把 TUI 打到键盘无响应(2026-08-22 实测)

**现象**:父会话用 `cc-dispatch.sh send` 往一个 **接近 auto-compact**(76% 会话)的子任务 tab
发一条约 1100 字、多行的打回清单。输入框里**只出现了第一行、约一屏宽的字**,其余全丢;
随后 `send-key Enter` ×3、`Escape`、`Ctrl-C` **全部无响应**,进程 `S+` 0% CPU 并非在忙。
`cc-send` 的 post-send verify 正确判定为 parked 并写了面包屑——**这次是真阳性**
(与「cc-send parked 面包屑无失败证据」那条记的 16/16 假阳性并存,所以证据字段是必要的)。

**恢复路径**(实测一次通过,值得记住):
```
cc-dispatch.sh close <worktree-dir>      # 按记录的 stable uuid 关掉,不碰键盘
cc-dispatch.sh resume                    # 按板行记录的 --resume <uuid> 重开,上下文完整
```
重开后是新 surface(本次 surface:4 → surface:20),板行的 ref 由 resume 自动刷新;
随后把同一份内容**写成文件、只发一个指针**(`读 <abs-path> 并按其中的清单执行`)即刻送达。

**教训**:给运行中的 tab 发长指令一律走文件指针。技能文档对"简报"已经这么要求,
但**打回清单、追加说明这类中途消息**同样适用,而且正是最容易图省事直接内联的地方。

## python 管道写者的 BrokenPipe 噪音有**尺寸窗口**:采样一档就下结论会得到相反答案(2026-08-22,cc-state 门面)

`cc-state dump archive | head -2` 这类"大输出接一个提前退出的消费方",漏不漏 85 字节的
`Exception ignored while flushing sys.stdout: BrokenPipeError` 到 stderr,**取决于库的字节数**:

```
库大小        dump stderr(5 次)   task-list stderr(5 次)
 90893B            425                425      ← 窗口内,每次必漏
113890B            425                425
136890B              0                  0
182893B              0                  0
228893B              0                  0
552894B              0                  0
```

窗口约 **90 KB – 136 KB**,窗口内 100% 复现。机理:`head` 读完两行就退出、写者填满 64 KB 管道缓冲,
两者的先后是竞态。EPIPE 在 `main()` 内部冒出来时,`except BrokenPipeError` 接得住;
在解释器退出时的最后一次 flush 里冒出来时,try/except 早已退出,handler 命中次数为 **0**——
代码看着有 handler,实际没执行。

**这条记在这里不是因为那 85 字节,是因为它让两个独立审查者得出了相反的结论。**
gate 只在 ~114 KB 上量、只探了 `dump` 一条路径,判定"handler 是死代码、没修";
父会话只在 228 KB 上量、探了两条路径,判定"两条都干净、结案"。两边的观测都是真的,
两边的推广都不成立。定案靠的是**二分**,不是重申。

**修法**(唯一确定性的):把 EPIPE 逼进 try 内部,别指望它自己冒到那里——

```python
try:
    _rc = main(sys.argv[1:])
    sys.stdout.flush()          # ← 没有这一行,窗口内 handler 永远不可达
    sys.exit(_rc)
except BrokenPipeError:
    os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    sys.exit(0)
```

**注意**:`except OSError: pass` 会顺手吃掉 `BrokenPipeError`(它是 OSError 子类)。
`cc-state` 的 `cmd_dump` 曾因此在一条路径上"看起来修好了",实际是被局部吞掉的——
同时也吞掉了真正的读错误(部分输出 + rc 0)。要吃就只吃 `BrokenPipeError`。

**给后来者**:测这一类问题时,断言要钉在**已知会漏的尺寸**上(`cc-state` 的 §32 钉在 90–110 KB)。
钉在干净档位的断言恒绿,而且看不出来它恒绿。可达性也别当合成场景:
`worktree-tasks-archive.tsv` 只增不剪,会单调穿过这个窗口(约 470–720 条归档行)。

## 已合并的分支继续开工时，板行已被归档（2026-08-23，执行形状副作用）

**现象**：一条子任务线拆成两段、中间落地一次（`gwt-merge` 之后让同一个 worktree 接着做
下半段）时，`_gwt_archive_branch` 已经把该分支的板行搬进归档，于是 `cc-board.sh` /
`gwt-tree` 看不到这个仍然活着的 tab，STATUS 列也随之消失。tab 本身工作正常。

**根因**：归档的触发点是「merge 成功」，它假设 merge 意味着这条线结束。这个假设对
一次性交付的线成立，对「落地一次、继续开工」的线不成立。

**处置**：暂不改。这是父会话主动选择的执行形状（拆两段但不新开 tab），发生频率低，
代价只是可见性而不是正确性；真要改的话，正确的形状是让 `gwt-merge` 接一个
`--keep-row` 之类的显式意图，而不是猜。记在这里，免得下次当成 bug 追。

## 行外的列会被基于整行的重写静默抹掉（2026-08-29，D 期 Task 1 落地时抓到）

**现象**：`task-set-ref <dir> s:9` 之后，板上**每个** worktree 的 STATUS 都变成 `-`。
没有报错，没有 rc，看不出发生过什么。`task-prune`、`task-set-launch`、`task-drop`、
板的 prune-on-read —— 任何一条走重写的路径都一样。

**根因**：C 期确立的分层是「20 个动词只跟整行字符串打交道，行↔列的转换收在存储层」，
而存储层的重写实现是 `DELETE FROM tasks` + 按 `f1..f8` 重插。D 期第一次把状态放到**行外的
列**上（`state` / `state_ts` / `tab_opened_ts` / `merged_at` / `merged_into`），于是那道原本
干净的分层变成陷阱：重写只知道行，不知道列，列就跟着 DELETE 一起没了。

**处置（已修）**：`_carry` / `_restore` —— 重写前按 dir 快照全部 carried 列，重写后按
`dir_match` 贴回去。被重写**丢掉**的 dir 自然贴不回来，这正是想要的语义（剪掉任务行就连
状态一起带走）。

**给后来者**：
- 再往 `tasks` 加任何**不出现在 TSV 行里**的列，必须同时加进 `CARRIED`，否则它会以完全
  相同的方式静默消失。这是本仓库里少数「加一列 = 改两处」的地方，值得记住。
- 抓到它的是 13 条形如「无关的那一行还在吗」的断言。它们看起来啰嗦，实际是这一类缺陷
  **唯一**的探测器 —— 直接断言「我关心的那行还在」是抓不到的，因为它确实还在。
- 同一次落地还抓到一条相邻的：**降级可以损失可见性，绝不能损失数据**。旧代码开 v2 库会
  重建空 `status` 表并把版本戳回 1，若升级路径无条件折叠这张空表，就会清掉仍在列里的状态
  （新→旧→新丢数据）。空 sidecar 必须直接 DROP，不折叠。§39 有回归断言 + 变异确认。
