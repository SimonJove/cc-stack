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

**症状**:cc-send 不再等待正在输入的用户(恒直达),或恒走 fail-open 面包屑;开 tab 自校准报模式不命中。

**根因**:cc-send(`cc-dispatch.sh send`)靠 read-screen 解析 claude TUI 输入行的"❯ 提示符 + 行内是否已有未提交文本"判断撞车。该形态由 TUI 渲染器(`tui: fullscreen|default`)和 claude 版本决定——**claude TUI 改版输入区后,模式列表失配,门卫失明**。已实测(2026-08-15,claude 2.1.233):两种渲染器的输入行**字节级一致**——空态 = `❯` + U+00A0 不换行空格(光标占位,不是 ASCII 空格!),输入态 = `❯` + NBSP + 草稿;transcript 会以 `❯` + ASCII 空格回显已提交消息(在活输入框**上方**,故 cc-send 自底向上取最后一条命中行)。

**实现参照**(模式列表 + 兜底都在 `cc-dispatch.sh` 顶部的 cc-send 块):
- 默认模式列表 `^❯:^>`(冒号分隔 ERE,自动锚定行首);`CC_SEND_INPUT_PATTERNS` **整体替换**默认列表;
- 空白判定把 NBSP(UTF-8 字节 c2 a0)视为空白——若新版光标占位换成别的字符,空态会被误判 busy(超时→通知→死等),同样是本条目的排查对象;
- 面包屑写 cc-failures.log(`CC_SEND_FAILLOG` 可覆盖):fail-open 与校准失配各写一行,gwt-status 可见。

**排查三步**:
1. 任意 idle claude tab 跑 `cmux read-screen --surface <ref> --lines 8`,看输入行现在的形态(空态),必要时 hexdump(`| od -An -tx1`)确认 ❯ 后面的字节;
2. 跑 `~/.config/cc-stack/cc-dispatch.sh calibrate <ref>`(对已知空输入框复检模式命中;miss 会写面包屑并 exit 1),对照模式列表是否匹配新形态;
3. 不匹配 → `CC_SEND_INPUT_PATTERNS` 一行改配置先恢复,或跟进新版式;更新后用"注入文本不按 Enter + read-screen"复检(设计验证手法,2026-08-15 已用此法实证过)。

**兜底语义**:模式失配时 fail-open 退回裸 send——行为=本功能出现之前,不会丢消息、不会扣死,只是失去防撞保护。开 tab 自校准(cc-dispatch.sh surface 在 TUI 起来后跑一次)的面包屑是第一报警线。

## cmux send 到 idle pane 会静默停在输入框不执行(与 cc-send 的交互)

上游缺陷记录在主 checkout 的 `docs/issues/cc-stack-issues.md` Defect 2(cmux 侧问题,cc-stack 不修执行验证本身)。交互语义:
- cc-send 的出口固定是 `cmux send` + `send-key Enter` **成对**——Enter 是该缺陷的 flush 手段,但**成对不等于必达**(见下方现场数据);
- 若输入框里已有**历史残留的 parked 消息**(旧裸 send / busy 队列留下),❯ 行非空 → cc-send 判 busy,持有 + 桌面通知而非追加堆叠(安全的失败方向);清掉残留后正常投递;
- 同文档观察 #1(首字符在传输中被吞)对 cc-send 同样成立——报告消息开头几个字符可能丢失,关键路径用文件传递。
- **现场数据(2026-08-15,父→子长指令)**:`cmux send` + `send-key Enter` 双双返回 OK,长文本被 TUI 折叠为 `[Pasted text #1]` 后**紧随的 Enter 被吞**,消息在输入框停了 ~15 分钟、claude 全程不知情,手动再补一个 Enter 才送达。教训:发长指令后用 read-screen 复核输入行已清,非空则补按一次 Enter;给 cc-send 加"发送后确认 + 补按"属后续增强(现设计只检查发送前)。
