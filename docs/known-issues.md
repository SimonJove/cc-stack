# Known issues

记录 cc-stack 已知但尚未修复的问题。按严重度排序。

---

## P1 · 脚本硬编码 `~/.config/cc-stack` — 非默认 `--dir` 安装会全面断裂

**严重度:** P1(真实功能性 bug;但用默认路径 `~/.config/cc-stack` 安装的用户不会触发)

**现象:**
`install.sh` 支持 `--dir <path>` / `CC_STACK_DIR` 装到任意目录(README 明确宣传:`curl ... | bash -s -- --dir ~/somewhere/cc-stack`)。安装时 `.zshrc` 写入的是正确路径(`$CCT/worktree.zsh`),所以 source 能成功。**但被 source 的脚本内部全部硬编码 `~/.config/cc-stack`**,且没有一个脚本用 `BASH_SOURCE`/`ZSH_SOURCE` 自解析目录 → 运行时找不到脚本,`gwt-*` 命令全面断裂。

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

**关联:** `install.sh` 的 `--dir`/`CC_STACK_DIR` 处理(约行 13、34)、README 的 install 文档(约行 40-65)。

## hook 防双开过滤的非规范引号角落(cc-hooks.sh worktree)

**现象:** `CC_WT_PROMPT` 若不用文档规定的单引号形式(例如双引号包裹、或 `'\''` 内嵌撇号),且 payload 文本里恰好字面点名 `cc-dispatch.sh` 或两个 legacy 脚本名,该次派发会被 SKIP(无 tab,但失败可见:cc-failures.log 有记录)。

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

## 测试泄漏真实 cmux workspace(2026-08-16 修)+ 删除动词备忘

**现象**:`test.sh` 第 12 节的 `gwt-adopt` 走真 cmux——`gwt-adopt <branch>` 会给被收编的 worktree 开一个 cmux **workspace**(worktree.zsh → `cc-dispatch.sh workspace`),测试没做 PATH shim,**每跑一次套件就在用户界面上留一个 `feature-orphan-y` 空 workspace**(2026-08-16 一次清出 5 个:workspace:147-151)。已修:该节的 `gwt-adopt` 调用全部经一个 no-op 假 cmux(`azsh`),套件跑完 workspace/surface 计数不变(已实测 7/7、8/8)。

**规矩**:测试(和实弹探测)开的任何 surface / workspace,报告前必须自己关掉,并在报告里列出清单。

**删除动词(实测定界,2026-08-16)**:
- **关不掉最后一个 surface**:`cmux close-surface` 关 workspace 里仅剩的那个 surface 会报 `invalid_state: Cannot close the last surface`——所以"把 surface 关光,空 workspace 自己消失"这条路**不存在**;
- workspace 必须显式删:`cmux workspace close --workspace <ref|uuid>`(旧名 `cmux close-workspace` 仍可用,但会打一行 alias 提示,`CMUX_QUIET=1` 可静音);
- **UUID 目标跨 workspace 需要上下文**:`cmux close-surface --surface <UUID>` 只在目标位于调用者**当前 workspace** 时直接命中;目标在别的 workspace 里会报 `Error: Surface not found: <UUID>`,要补 `--workspace <ref>`。对 `cc-dispatch.sh close` 的影响:子任务 tab 是在派发方 workspace 里开的,常态命中;若有人把 tab 拖到别的 workspace,关闭会**响亮失败**(`✗ cmux close-surface failed for uuid …`),不会误关别的东西——留作已知残留,未加自动补 `--workspace` 的重试。

## cc-board 读循环对空 caller 字段的 TAB 塌缩(存量,未修)

**现象**:任务 TSV 第 5 字段(caller surface)为空时,bash/zsh 的 `read` 连续 TAB 塌缩导致后续字段左移一位——render 显示错列、prune 可能误删。live 数据 0 行受影响(实际派发都会写 caller)。
**根因**:`read a b c` 语义对空字段不保位;写侧未做防塌缩(test.sh 的字段数断言因此恒非空)。
**处置**:后续 sweep——写侧对空 caller 写占位符(如 `-`)或读侧换 `IFS=$'\t' read -r` 数组式解析(注意 bash 3.2 无 `read -a` 于 zsh 差异)。关联:8 字段 launch-args 落地时已确认新字段写侧有 tab 消毒,不会加重本条。

## ~~block-worktree-commit.sh 未入库(运行态孤儿文件)~~ 已收编(2026-08-16,feat/safe-close-impl)

原风险:`~/.claude/hooks/block-worktree-commit.sh`(v2,命令有效目录判定)是 commit 门卫的唯一实现,不在仓库——机器迁移即丢、无测试覆盖。
**处置**:原样收编为 `hooks/block-worktree-commit.sh`(v2 语义未改:命令有效目录 `cd X`/`-C X` 优先,解析失败回退会话 cwd;哨兵一次一 commit),install.sh 注册到 PreToolUse,并把旧的 `~/.claude/hooks/…` 注册当陈旧项剥离(按 `.claude/hooks/` 路径子串匹配,不会误伤新注册)。**残留清理靠人**:重跑 install.sh 后 `~/.claude/hooks/block-worktree-commit.sh` 文件本身还在(已不再被注册),可手工删。(当初与它一起注册的 `hooks/block-unsafe-close.sh` 已于 2026-08-16 退役,见下文"关 tab 事故"条。)

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
