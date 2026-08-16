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

## cc-board 读循环对空 caller 字段的 TAB 塌缩(存量,未修)

**现象**:任务 TSV 第 5 字段(caller surface)为空时,bash/zsh 的 `read` 连续 TAB 塌缩导致后续字段左移一位——render 显示错列、prune 可能误删。live 数据 0 行受影响(实际派发都会写 caller)。
**根因**:`read a b c` 语义对空字段不保位;写侧未做防塌缩(test.sh 的字段数断言因此恒非空)。
**处置**:后续 sweep——写侧对空 caller 写占位符(如 `-`)或读侧换 `IFS=$'\t' read -r` 数组式解析(注意 bash 3.2 无 `read -a` 于 zsh 差异)。关联:8 字段 launch-args 落地时已确认新字段写侧有 tab 消毒,不会加重本条。

## block-worktree-commit.sh 未入库(运行态孤儿文件)

**风险**:`~/.claude/hooks/block-worktree-commit.sh`(v2,命令有效目录判定)是 commit 门卫的唯一实现,**不在 cc-stack 仓库**——机器迁移/重装即丢,且无测试覆盖(8 项手测 2026-08-16 全过后未固化)。
**处置建议**:收编进仓库(hooks/ 目录)+ install.sh 分发 + test.sh 加合成 stdin 断言。v2 语义:命令有效目录(commit 前最后一个 `cd X`/`-C X`)优先,解析失败回退会话 cwd;哨兵一次一 commit 原样。
