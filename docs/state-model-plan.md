# State model — Phase A + B Implementation Plan

> **For agentic workers:** 本仓库用 worktree 子任务 + 两级门执行（全局 `worktree-subtask` 技能）。
> 每个 Task 是一条独立的 worktree 线。步骤用 `- [ ]` 勾选。

**Goal**：引入 `cc-state` 门面，把 46 处字段级 TSV 解析和 9 份 mkdir 锁收敛成一条路径、一份锁；
再让 test.sh 不再依赖存储格式。**存储格式零变更，用户可见行为零变更。**

**Architecture**：`cc-state`（python3）是唯一读写状态文件的代码。后端仍是今天的四个 TSV，
所以 A 期不涉及迁移。所有 shell 调用方改成问它，一次调用回答一个问题。
B 期把测试的字段级断言也切到门面，为将来换引擎（C 期）铺路。

**Tech Stack**：python3（已是硬依赖：hook/trust/install 都在用）、bash 3.2、zsh（仅 worktree.zsh）。

**Spec**：`docs/state-model.md` —— 每条任务的验收都回指那里的 §8 不变量。

## Global Constraints

逐条抄进每份简报（值取自 spec §8）：

- `cc-hooks.sh status` **零输出**、**永远 exit 0**、任何失败静默 no-op。
- 板输出契约逐字不变：`TAB|BRANCH|PARENT|STATUS|DIR|TASK`；STATUS 为 `working(23m)`/`idle(2h)`/`blocked(5m)`/`-`；TAB 四值与 partial 语义不变。
- sidecar **永远不写 `ready`**（readiness 只由 `gwt-done` + 干净树决定）。
- 证据不完整**不剪枝**（`tab-prune` 的 `!partial` 不变量）。
- 两个台账**永不互相去重**。
- resume 用**记录的 dir 字符串原样**启动。
- bash 3.2 安全（无关联数组、无 `${var,,}`、无 `mapfile`）；zsh 只在 `worktree.zsh`。
- `cc-hooks.sh` 的 `<<'PY'` heredoc 必须**保持是文件里唯一的 heredoc**，且**体内无字面撇号**。
- 测试永不写真实状态：沿用 `CC_TASKS_FILE`/`CC_STATUS_FILE`/`CC_ARCHIVE_FILE`/`CC_TABS_FILE`/`CC_TRUST_CFG_OVERRIDE`/`CC_SEND_FAILLOG` 覆盖。
- 子任务**只在自己的 worktree 内编辑**；主 checkout（同时是活安装目录）只读。
- 任何会走到 `cc-dispatch.sh workspace|surface` 的测试**必须 PATH 前置假 cmux**；跑套件前后各记一次 `cmux list-workspaces` 数量。
- test.sh 不用固定 `/tmp/<name>` 临时文件，一律 `mktemp`。

**定位用 grep 锚点，不用行号**：四条线并行会互相移动行号。每个任务给的是唯一可 grep 的字符串。

---

## File Structure

| 文件 | 职责 | 谁拥有 |
|---|---|---|
| `cc-state`（新，可执行 python3） | 唯一读写状态文件的代码；子命令即 spec §4 的动词 | Task 1–3 |
| `cc-hooks.sh` | 只保留 hook 语义，状态读写全部委托 | Task 4 |
| `cc-board.sh` | 只保留渲染与仓库过滤，join 全部下沉到门面 | Task 5 |
| `cc-dispatch.sh` | 只保留派发/关 tab/恢复的编排 | Task 6 |
| `worktree.zsh` | 只保留 zsh 交互层，重写/剪枝全部委托 | Task 7 |
| `test.sh` | 每条线一个**独立新节号**，锚点相隔 ≥150 行 | 各任务分配见下 |

**test.sh 节号与锚点分配**（并行线之间必须 ≥150 行；下表的行号是本计划写成时的实测值，
执行时用 `grep -n '^echo "== '` 复核）：

| 任务 | 新节号 | 插入锚点（grep 字符串） | 当时行号 |
|---|---|---|---|
| Task 4 `cc-hooks.sh` | §33 | `== 2b. cc-hooks.sh status` | 168 |
| Task 5 `cc-board.sh` | §34 | `== 20. TSV empty-field integrity` | 355 |
| Task 1–3 `cc-state` | §32 | `== 21. dispatch path resolution` | 1923 |
| Task 6 `cc-dispatch.sh` | §35 | `== 25. commit gate` | 2786 |
| Task 7 `worktree.zsh` | §36 | `== 19b. fail-closed path guards` | 3368 |

相邻间距 187 / 1568 / 863 / 582 行，全部 ≥150。Task 8 改造既有 19 行，不新增节。

---

## Task 1: `cc-state` 骨架 + 单一锁 + `dump`

**Files**
- Create: `cc-state`
- Test: `test.sh` §32（锚点：插在 `echo "== 21. dispatch path resolution` 之前；Task 2/3 接在其后）

**Interfaces**
- Produces：`cc-state dump tasks|archive|tabs` → 打出对应 TSV 原文（无表头）；`cc-state --help` 列全部动词。
  内部 `_lock(path)` 上下文管理器：`mkdir` 原子锁 + **stale 回收**（锁目录 mtime 超过 `CC_STATE_LOCK_STALE`，默认 60 s，则夺锁并继续）。
- 路径解析：`CC_TASKS_FILE`/`CC_STATUS_FILE`/`CC_ARCHIVE_FILE`/`CC_TABS_FILE` 覆盖，默认 `$HOME/.config/cc-stack/<name>`。

- [ ] **Step 1: 写会红的测试**

在 test.sh §32 加：

```bash
echo ""
echo "== 32. cc-state facade (Phase A) =="
S32=$(mktemp -d); export CC_TASKS_FILE="$S32/t.tsv" CC_STATUS_FILE="$S32/s.tsv" \
  CC_ARCHIVE_FILE="$S32/a.tsv" CC_TABS_FILE="$S32/b.tsv"
printf '2026-01-01 00:00:00\tfeat/x\tsurface:1\t/d/x\tsurface:9\tdo x\tcamp\tuuid=u1\n' > "$CC_TASKS_FILE"
eq "32 dump tasks is byte-identical" "$("$CC/cc-state" dump tasks)" "$(cat "$CC_TASKS_FILE")"
eq "32 dump of a missing file is empty" "$("$CC/cc-state" dump tabs)" ""
# stale lock is reclaimed rather than waited out
mkdir -p "$CC_TASKS_FILE.lock"; touch -t 202601010000 "$CC_TASKS_FILE.lock"
t0=$(date +%s); "$CC/cc-state" dump tasks >/dev/null 2>&1; t1=$(date +%s)
eq "32 stale lock reclaimed fast" "$(( t1 - t0 < 3 ? 1 : 0 ))" "1"
eq "32 stale lock dir removed" "$([ -d "$CC_TASKS_FILE.lock" ] && echo yes || echo no)" "no"
```

- [ ] **Step 2: 跑它，确认失败**

`bash test.sh 2>&1 | grep '✗ 32'` → 应看到 `cc-state: No such file or directory` 一类。

- [ ] **Step 3: 写最小实现**

```python
#!/usr/bin/env python3
"""cc-stack · the single reader/writer of stack state (Phase A: TSV backend)."""
import os, sys, time, errno, contextlib

def _p(env, name):
    return os.environ.get(env) or os.path.join(
        os.path.expanduser("~"), ".config", "cc-stack", name)

PATHS = {
    "tasks":   lambda: _p("CC_TASKS_FILE",   "worktree-tasks.tsv"),
    "status":  lambda: _p("CC_STATUS_FILE",  "worktree-status.tsv"),
    "archive": lambda: _p("CC_ARCHIVE_FILE", "worktree-tasks-archive.tsv"),
    "tabs":    lambda: _p("CC_TABS_FILE",    "opened-tabs.tsv"),
}
STALE = float(os.environ.get("CC_STATE_LOCK_STALE") or 60)

@contextlib.contextmanager
def lock(path):
    """Atomic mkdir lock with stale reclaim. Never blocks forever, never writes unlocked."""
    d, held = path + ".lock", False
    deadline = time.time() + 3.0
    while True:
        try:
            os.mkdir(d); held = True; break
        except OSError as e:
            if e.errno != errno.EEXIST: break
            try:
                if time.time() - os.stat(d).st_mtime > STALE:
                    os.rmdir(d); continue          # reclaim: the holder died
            except OSError:
                continue
            if time.time() > deadline: break        # give up waiting, proceed (matches today)
            time.sleep(0.05)
    try:
        yield
    finally:
        if held:
            try: os.rmdir(d)
            except OSError: pass

def read(store):
    try:
        with open(PATHS[store](), encoding="utf-8") as f:
            return [l.rstrip("\n").split("\t") for l in f if l.strip("\n")]
    except OSError:
        return []

def write(store, rows):
    """Whole-file rewrite under the lock; an empty result removes the file (today's behaviour)."""
    p = PATHS[store]()
    with lock(p):
        if not rows:
            try: os.unlink(p)
            except OSError: pass
            return
        tmp = "%s.tmp.%d" % (p, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            for r in rows: f.write("\t".join(r) + "\n")
        os.replace(tmp, p)

def append(store, row):
    p = PATHS[store]()
    with lock(p):
        with open(p, "a", encoding="utf-8") as f:
            f.write("\t".join(row) + "\n")

def cmd_dump(args):
    for r in read(args[0]): print("\t".join(r))
    return 0

VERBS = {"dump": cmd_dump}

def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print("usage: cc-state {%s} ..." % "|".join(sorted(VERBS)), file=sys.stderr); return 2
    v = argv[0]
    if v not in VERBS:
        print("cc-state: unknown verb: " + v, file=sys.stderr); return 2
    return VERBS[v](argv[1:])

if __name__ == "__main__":
    try: sys.exit(main(sys.argv[1:]))
    except BrokenPipeError: sys.exit(0)
```

`chmod +x cc-state`。

- [ ] **Step 4: 跑测试，确认变绿**

`bash test.sh 2>&1 | tail -2` → `0 failed`。

- [ ] **Step 5: 报告并等待**

停下，报告改了什么 + tally 原文行 + 新增断言数，然后 `~/.config/cc-stack/gwt-done`。不 commit。

---

## Task 2: tasks 存储的动词

**Files**
- Modify: `cc-state`（加动词，不动 Task 1 的骨架）
- Test: `test.sh` §32（接在 Task 1 的断言之后）

**Interfaces**
- Consumes：Task 1 的 `read/write/append/lock`。
- Produces（全部输出 TSV、无表头；rc 0 = 成功）：
  - `task-add <dir> <branch> <ref> <task> <parent>` — 追加占位行，`tab_opened_ts` = now
  - `task-set-launch <dir> <caller-ref> <launch-args>` — 补齐派发末尾的两个字段
  - `task-get <dir>` — 一行；无则空、rc 1
  - `task-list [--all] [--repo <root>] [--archive]` — newest-per-dir、仓库过滤、死目录剪枝，一次出全
  - `task-set-state <dir> <state>` — dir 不在 tasks 里则**静默 no-op、rc 0**
  - `task-set-ref <dir> <ref> [<suuid>]`
  - `task-drop <dir>` / `task-prune` / `task-archive <branch> <merged-into>`
  - `task-mark-opened <dir>` — 盖"tab 真的开成了"的时戳。**`task-add` 不得顺手盖**：
    失败的派发必须不留阻塞标记（`cc-dispatch.sh:711`）。见 spec §4 的拆分说明。
  - `task-opened-recently <dir> <seconds>` — rc 0 = 窗口内开过

> **A 期的映射约定**（因为后端还是今天的文件）：`state`/`state_ts` 落在 `worktree-status.tsv`；
> `tab_opened_ts` 暂时仍落 `$TMPDIR` 标记（**D 期才退役**），由 `task-add` / `task-opened-recently`
> 封装，调用方不再直接碰。归档仍是独立文件。**门面的 API 已经是目标形状，后端是过渡形态。**

- [ ] **Step 1: 写会红的测试**

```bash
"$CC/cc-state" task-add /d/y feat/y surface:2 'do y' camp
eq "32 task-add appends" "$("$CC/cc-state" task-get /d/y | cut -f2)" "feat/y"
"$CC/cc-state" task-set-launch /d/y surface:9 'uuid=u2:pm=auto'
eq "32 set-launch fills field 8" "$("$CC/cc-state" task-get /d/y | cut -f8)" "uuid=u2:pm=auto"
# the hook's membership rule: an unregistered dir is a silent no-op
"$CC/cc-state" task-set-state /d/nope working; rc=$?
eq "32 set-state unknown dir rc0" "$rc" "0"
eq "32 set-state unknown dir writes nothing" "$([ -s "$CC_STATUS_FILE" ] && echo yes || echo no)" "no"
"$CC/cc-state" task-set-state /d/y working
eq "32 set-state registered dir" "$(cut -f2 "$CC_STATUS_FILE")" "working"
# empty middle fields must survive a round-trip (the TAB-collapse class)
printf '2026-01-01 00:00:00\tfeat/z\tsurface:3\t/d/z\t\tdo z\t\tuuid=u3\n' >> "$CC_TASKS_FILE"
"$CC/cc-state" task-set-ref /d/z surface:33
eq "32 empty fields survive rewrite" "$("$CC/cc-state" task-get /d/z | cut -f8)" "uuid=u3"
eq "32 rewrite keeps field count" "$("$CC/cc-state" task-get /d/z | awk -F'\t' '{print NF}')" "8"
```

- [ ] **Step 2: 跑它，确认失败** —— `unknown verb: task-add`。

- [ ] **Step 3: 实现**

要点（写进代码注释）：
- 所有重写走 `write()`，**整行原样重发**，绝不按变量重新拼字段——这是 TAB 塌缩固化到磁盘的那一类。
- `task-list` 的 newest-per-dir 用"从后往前扫、首见即最新"，与今天 `tail -r | awk '!seen[$4]++'` 同义。
- 死目录剪枝只在 `--archive` 未指定时做（归档的目录本来就该消失）。
- `task-set-state` 先查 tasks 是否有该 dir，没有就直接 return 0，一个字节都不写。

- [ ] **Step 4: 跑测试，确认变绿**（`0 failed`）

- [ ] **Step 5: 报告并等待**（同 Task 1 Step 5）

---

## Task 3: tabs 存储的动词

**Files**
- Modify: `cc-state`
- Test: `test.sh` §32

**Interfaces**
- Produces：
  - `tab-add <suuid> <owner> <dir> <session-id>` — 空 owner/session 写 `-`（今天的约定，防 TAB 塌缩）
  - `tab-list [--all]`（`--all` 关闭"只列本会话开的"过滤，会话身份由 `CC_CALLER_SURFACE_UUID`/`CMUX_SURFACE_ID` 决定）
  - `tab-resolve <dir>` — **每个台账候选一行**，按优先级 `board` → `tabs`，每行 `source \t suuid \t owner \t branch`。
    门面只给证据，**不做选择**：`close` 的选择依据是探活，探活按 spec §3.2 留在门面之外。详见 spec §4 修正段（2026-08-22）。
    没有任何候选 → 零行输出、rc 1。
  - `tab-owner <suuid>`
  - `tab-prune <live-uuid-file>` — 只在证据完整时剪；传入文件为空 → **一行不剪**

- [ ] **Step 1: 写会红的测试**

```bash
"$CC/cc-state" tab-add AAAA-1 BBBB-2 /d/y sid-1
eq "32 tab-add writes - for empty" "$("$CC/cc-state" tab-add CCCC-3 '' /d/z '' && cut -f2,4 "$CC_TABS_FILE" | tail -1)" "$(printf -- '-\t-')"
eq "32 tab-resolve lists board first" "$("$CC/cc-state" tab-resolve /d/y | head -1 | cut -f1,2)" "$(printf 'board\tAAAA-1')"
eq "32 tab-resolve emits every candidate, never picks" "$("$CC/cc-state" tab-resolve /d/y | cut -f1 | tr '\n' ',')" "board,tabs,"
eq "32 tab-resolve with no candidate is empty + rc1" "$("$CC/cc-state" tab-resolve /d/none; echo rc=$?)" "rc=1"
# the invariant that must never weaken: no evidence => no pruning
: > "$S32/live.empty"
"$CC/cc-state" tab-prune "$S32/live.empty"
eq "32 empty evidence prunes nothing" "$(wc -l < "$CC_TABS_FILE" | tr -d ' ')" "2"
printf 'AAAA-1\n' > "$S32/live.one"
"$CC/cc-state" tab-prune "$S32/live.one"
eq "32 complete evidence prunes the dead" "$(wc -l < "$CC_TABS_FILE" | tr -d ' ')" "1"
```

- [ ] **Step 2: 跑它，确认失败**
- [ ] **Step 3: 实现**（`tab-prune` 传空文件必须 return 0 且零改动——见 Global Constraints）
- [ ] **Step 4: 跑测试，确认变绿**
- [ ] **Step 5: 报告并等待**

---

## Task 4: `cc-hooks.sh` 切到门面（最敏感，独立 gate）

**Files**
- Modify: `cc-hooks.sh`（grep 锚点：`awk -F'\t' -v d="$canon"` 与 `tasks="${CC_TASKS_FILE:-`）
- Test: `test.sh` §33（锚点：插在 `echo "== 2b. cc-hooks.sh status` 之前）

**Interfaces**
- Consumes：`cc-state task-set-state <dir> <state>`
- 删除：`status` 分支里的板成员资格 awk、sidecar 的 mkdir 锁循环、read-modify-write 的 awk/tmp/mv 三步。

- [ ] **Step 1: 写会红的测试**（证明 hook 契约不破）

```bash
echo ""
echo "== 33. cc-hooks.sh status via cc-state =="
S33=$(mktemp -d); ...
# 契约 1：零输出
out="$(printf '%s' "$PAY_WORKING" | bash "$CC/cc-hooks.sh" status 2>&1)"
eq "33 hook writes nothing to stdout/stderr" "$out" ""
# 契约 1：python3 不可用也 exit 0 且不写
PATH="$S33/nopython:$PATH" printf '%s' "$PAY_WORKING" | bash "$CC/cc-hooks.sh" status; rc=$?
eq "33 no python3 degrades to exit 0" "$rc" "0"
# 契约 3：Notification 只在提到 permission 时才写 blocked，且永不写 ready
eq "33 never writes ready" "$(grep -c ready "$CC_STATUS_FILE" 2>/dev/null || echo 0)" "0"
# 锁不再由 hook 自己实现
eq "33 hook has no mkdir lock left" "$(grep -c 'mkdir "\$lock"' "$CC/cc-hooks.sh")" "0"
```

- [ ] **Step 2: 跑它，确认失败**（最后一条断言应为 1）
- [ ] **Step 3: 实现**：`status` 分支保留"解析事件 → 判定 state → 规范化 cwd"，然后一行
  `"$CC_SELF/cc-state" task-set-state "$canon" "$state" >/dev/null 2>&1 || true`；其余删掉。
  **`worktree` 分支的 python heredoc 一个字节都不动**（Global Constraints 里的 heredoc 约束）。
- [ ] **Step 4: 跑测试，确认变绿**；另外单独确认 heredoc 仍唯一且体内无撇号：
  `awk '/<<.PY./,/^PY$/' cc-hooks.sh | grep -c "'"` 应为 1（就是定界行本身）。
- [ ] **Step 5: 报告并等待**

---

## Task 5: `cc-board.sh` 切到门面

**Files**
- Modify: `cc-board.sh`（锚点：`ccb_dead_lines`、`ccb_drop_lines`、`ccb_lock`、`prune-on-read`、`rows="$(`）
- Test: `test.sh` §34（锚点：插在 `echo "== 20. TSV empty-field integrity` 之前）

**Interfaces**
- Consumes：`cc-state task-list [--all] [--repo <root>]`、`cc-state dump archive`
- 保留在 cc-board.sh 里的只有：渲染、`column -t`、TAB 列的 cmux 存活探测、失败日志尾部折叠。
- 删除：`ccb_dead_lines`/`ccb_drop_lines`/`ccb_lock`、两处 prune-on-read、newest-per-dir 的 `tail -r`、
  三张批量 join 表里**属于状态的那两张**（CMAP/SMAP 下沉到门面；PMAP/PWT 是 git 的，留下）。

- [ ] **Step 1: 写会红的测试**（渲染契约逐字不变）

```bash
echo ""
echo "== 34. cc-board renders through cc-state =="
# 表头逐字
eq "34 header contract" "$(bash "$CC/cc-board.sh" --all 2>/dev/null | head -1)" "TAB    BRANCH  PARENT  STATUS  DIR  TASK"
# STATUS 单元格形态
eq "34 status cell shape" "$(bash "$CC/cc-board.sh" --all 2>/dev/null | awk 'NR==2{print $4}')" "working(0m)"
# 锁与剪枝已不在 board 里
eq "34 board has no lock impl" "$(grep -c 'ccb_lock' "$CC/cc-board.sh")" "0"
eq "34 board has no dead-line pruner" "$(grep -c 'ccb_dead_lines' "$CC/cc-board.sh")" "0"
```

> 表头那条断言的期望值**执行时用当前 `cc-board.sh --all` 的真实输出填**（`column -t` 的空格数取决于内容宽度）；
> 要点是：改造前后这一行必须**逐字节相同**，所以先跑旧代码把它抄下来当期望值。

- [ ] **Step 2: 跑它，确认失败**
- [ ] **Step 3: 实现**
- [ ] **Step 4: 跑测试，确认变绿**；另跑 `bash cc-board.sh` 与改造前输出做 `diff`，必须为空
- [ ] **Step 5: 报告并等待**

---

## Task 6: `cc-dispatch.sh` 切到门面（22 处，最大一条）

**Files**
- Modify: `cc-dispatch.sh`（锚点：`_cctabs_log`、`_cctabs_prune`、`_cctabs_owner`、`_cctabs_by_dir`、
  `_cctabs_lock`、`marker=`、`cc-board.sh" log`、`_ccres_setref`、`_ccres_dropstatus`、`_ccres_keys`、`task_rows=`）
- Test: `test.sh` §35（锚点：插在 `echo "== 25. commit gate` 之前）

**Interfaces**
- Consumes：`task-add` / `task-set-launch` / `task-set-ref` / `task-list` / `task-opened-recently` /
  `task-mark-opened` / `tab-add` / `tab-resolve` / `tab-owner` / `tab-list` / `tab-prune`
- **`close` 的四段级联编排不下沉**（2026-08-22 实读修正）：`tab-resolve` 一次把台账候选全给出来，
  但「挨个探活、取第一个活的、最后按选定 uuid 反查 owner」仍写在 `cc-dispatch.sh` 里；
  第三段的 cmux 会话存储回退一个字节都不动。省掉的是三次文件读和三处 TSV 解析，不是那个判断。
- 删除：`_cctabs_*` 整族的文件读写与锁、`$TMPDIR` 标记的直接读写、resume 的 `_ccres_setref`/`_ccres_dropstatus`/`_ccres_keys`。
- **保留**：`_cctabs_livemap` / `_cctabs_partial` / `_cctabs_where`（那是 cmux 探测，不是状态）。

- [ ] **Step 1: 写会红的测试**

```bash
echo ""
echo "== 35. dispatch state goes through cc-state =="
# close 的三问合成一次
eq "35 close resolves via tab-resolve" "$(grep -c 'cc-state" tab-resolve' "$CC/cc-dispatch.sh")" "1"
# the facade gives evidence, close still decides: the liveness probe stays in the shell.
# present/absent, never a count — these helpers legitimately appear many times and a count drifts.
_in_close(){ sed -n '/^close)/,/^;;/p' "$CC/cc-dispatch.sh" | grep -c "$1" \
  | awk '{print ($1>0)?"yes":"no"}'; }
eq "35 close still probes liveness itself"      "$(_in_close '_cctabs_livemap')"  "yes"
eq "35 cmux session-store fallback untouched"   "$(_in_close 'CC_CMUX_SESSIONS')" "yes"
# and the facade must never SHELL OUT to cmux. (It may NAME cmux: $TMPDIR/cc-cmux-tabs is
# Phase A's tab_opened_ts backend and CMUX_SURFACE_ID is tab-list's session identity —
# both are spec'd. The line is forking a probe, not mentioning the word.)
eq "35 git is the only command cc-state runs" \
  "$(grep -oE 'subprocess\.run\(\["[a-z-]+"' "$CC/cc-state" | sort -u | tr '\n' ',')" \
  "subprocess.run([\"git\","
eq "35 no tabs-file awk left" "$(grep -cE 'awk -F.\\\\t. .*(_tf|tabs_f)' "$CC/cc-dispatch.sh")" "0"
eq "35 no mkdir lock left" "$(grep -c '_cctabs_lock' "$CC/cc-dispatch.sh")" "0"
# 派发窗口：tab 一开就有板行（spec §3.1 的 bug）
# （用 §29 的 fake cmux 派发一次，在 trust 循环仍在跑时查板）
eq "35 board row exists right after the tab opens" "$(...)" "1"
```

- [ ] **Step 2: 跑它，确认失败**
- [ ] **Step 3: 实现**。注意 `surface` 里把 `cc-board.sh log` 拆成 `task-add`（今天写标记的位置）
  + `task-set-launch`（今天调 log 的位置），这是 spec §3.1 那个 bug 的修复。
- [ ] **Step 4: 跑测试，确认变绿**（全套 + §35 单独连跑 10 次防 flaky）
- [ ] **Step 5: 报告并等待**

---

## Task 7: `worktree.zsh` 切到门面

**Files**
- Modify: `worktree.zsh`（锚点：`_gwt_dead_lines`、`_gwt_drop_lines`、`_gwt_tasks_rewrite`、
  `_gwt_status_rewrite`、`_gwt_archive_branch`、`gwt-prune` 里的 `tail -r`）
- Test: `test.sh` §36（锚点：插在 `echo "== 19b. fail-closed path guards` 之前）

**Interfaces**
- Consumes：`task-drop` / `task-prune` / `task-archive` / `task-list`
- 删除：4 份 mkdir 锁、`_gwt_dead_lines`/`_gwt_drop_lines` 及其四个 keep-predicate 包装。
- **不动**：`gwt-rm` 的守卫（脏树/locked/已合并判定）、`gwt-tree`、`gwt-merge` 的闸门——那些不是状态访问。

- [ ] **Step 1: 写会红的测试**

```bash
echo ""
echo "== 36. worktree.zsh state via cc-state =="
eq "36 no zsh lock loops left" "$(grep -c 'mkdir "\$lock"' "$CC/worktree.zsh")" "0"
eq "36 no hand-rolled line dropper" "$(grep -c '_gwt_drop_lines' "$CC/worktree.zsh")" "0"
# 归档仍是"整行原样 + merged-at"，字段数 8 → 9
eq "36 archive row keeps every field" "$(zsh -c '...gwt-merge...' >/dev/null; awk -F'\t' 'END{print NF}' "$CC_ARCHIVE_FILE")" "9"
```

- [ ] **Step 2–5**：同上（先红、实现、变绿、报告）

---

## Task 8: Phase B —— 测试脱离存储格式

**Files**
- Modify: `test.sh`（19 行字段级解析；其余 178 处只是设置沙箱变量，不动）
- 不动任何生产代码。

**Interfaces**
- Consumes：`cc-state dump|task-get|task-list|tab-list`

- [ ] **Step 1: 先列出这 19 行**

```bash
grep -nE '(awk|cut|grep)[^|]*(CC_TASKS_FILE|CC_STATUS_FILE|CC_ARCHIVE_FILE|CC_TABS_FILE)' test.sh
```

把清单贴进报告——这是本任务的作用面，逐行改，逐行核对断言语义不变。

- [ ] **Step 2: 逐行替换**

模式：`cut -f2 "$CC_TASKS_FILE"` → `"$CC/cc-state" task-get <dir> | cut -f2`；
`awk -F'\t' '$4==d' "$CC_TASKS_FILE"` → `"$CC/cc-state" task-get "$d"`；
`wc -l < "$CC_TABS_FILE"` → `"$CC/cc-state" tab-list --all | wc -l`。
**断言的期望值一个字都不改**——只换取值方式。

- [ ] **Step 3: 跑全套，确认 0 failed 且断言总数不变**

改造前后 `bash test.sh | tail -1` 的 passed 数必须**完全相同**（只换取值方式，不增不减断言）。

- [ ] **Step 4: 确认存储格式已不再被测试直接依赖**

```bash
grep -cE '(awk|cut|grep)[^|]*(CC_TASKS_FILE|CC_STATUS_FILE|CC_ARCHIVE_FILE|CC_TABS_FILE)' test.sh
```
应为 **0**（§32 里刻意测格式的那几条除外——它们测的就是 `dump` 的字节兼容，注释里写明）。

- [ ] **Step 5: 报告并等待**

---

## 执行顺序与并行度

- **Task 1 → 2 → 3 串行**（同一个文件 `cc-state`，且 2/3 依赖 1 的骨架）。这三条可以合成**一条 worktree 线**跑，
  因为它们的文件所有权完全重叠——按本仓库"按文件所有权切线"的原则，硬拆反而制造冲突。
- **Task 4 / 5 / 6 / 7 并行**（四个不同文件，各自独立节号），全部依赖 Task 1–3 已落地。
- **Task 8 最后**（它要改的 19 行分散在各节，必须等前面所有线落地）。

**不在范围内**（调研确认）：`cc-merge.sh` 和 `gwt-done` 完全不碰这四个 TSV，只操作 git config；
`install.sh` 只在拷贝安装时排除这些文件、无迁移逻辑。三者本计划都不动。

**每条线必须钉住的既有缺陷**（spec §3.5，门面收敛后自动消失，但要有断言）：
Task 6 → `_ccres_dropstatus` 漏 `-F'\t'`（含空格的 dir 删不掉）、`_ccres_setref` 把 7 字段行扩成 8 字段；
Task 7 → `_gwt_archive_branch` 无仓库过滤（同名分支跨仓库误归档）、归档写入非原子；
Task 4 → sidecar join 键的原样匹配 vs 读侧再规范化（规范化要移到写侧）。

即：**第一轮 1 条线（Task 1–3），第二轮 4 条线（Task 4–7），第三轮 1 条线（Task 8）**。

## Self-Review

- **Spec 覆盖**：spec §3.1 的五个存储 → Task 2/3/6；§3.2 的两个"留在外面" → 不改，Global Constraints 里
  写明；§3.3 git config 所有者 → 不改（Task 6 只是不再自己写 parent）；§4 的动词表 → Task 1/2/3 逐条实现；
  §5 引擎 → **C 期，不在本计划**；§6 迁移 → **C 期**；§8 九条不变量 → Global Constraints 逐条抄。
  **缺口（有意）**：spec §3.1 说 `tab_opened_ts` 进 tasks 表，本计划 A 期只是把它**封装**进门面
  （后端仍是 `$TMPDIR` 标记），D 期才真正合并——Task 2 的说明里写明了这个过渡形态。
- **占位符扫描**：Task 5 的表头期望值和 Task 6 的一条断言标了"执行时用真实输出填"，并说明了理由
  （`column -t` 宽度依赖内容）——这是**必须在执行时测量**的值，不是待办。
- **类型一致性**：`task-add` 的参数在 Task 2 定义、Task 6 消费，签名一致；`tab-resolve` 在 Task 3 定义
  （每候选一行 `source \t suuid \t owner \t branch`）、Task 6 消费，一致；`task-set-launch` 在 spec §4 与 Task 2/6 同名。
