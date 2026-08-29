# D 期 · 收敛模型实施计划（8 处状态 → 3 张表）

> **面向执行者**：本文是 `docs/state-model.md` §3.1 / §3.4 / §6 / §7·D 的落地计划。
> C 期（换引擎）已完成并 gate 过；本期只动模型，不动引擎。

**目标**（§3.4）：

```
8 处  →  1 个状态库（tasks / archive / tabs 三表）
         + git config（分支作用域：merge target、ready）
         + cc-failures.log（追加日志）
         + 外部只读：cmux session 库
```

**顺带修掉三个既有缺陷**（§3.1），它们不是附赠，是换键的前提：

1. **窗口 A**（标记有、板行无）—— **已在 C 期前关掉**。`cc-dispatch.sh` 现在 tab 一开就
   `task-add` 落占位行、末尾 `task-set-launch` 补齐。本期无需再做，但断言要留着。
2. **窗口 B**（板行有、标记无）—— resume 重开 tab 不写标记，紧接着的同目录派发不会被去重 →
   重复 tab。**本期必须关**：`tab_opened_ts` 是独立于 `created_at` 的列，resume 也要更新它。
3. **shasum 空哈希** —— 标记路径 `<dir>/$(shasum … | cut -f1)`，`shasum` 不可用时哈希为空 →
   `marker` 指向目录本身、`[ -e ]` 恒真 → **任意一次派发后 120 秒内所有目录的派发被静默吞掉**。
   变成一个整数列之后这条路径不存在。

---

## 0. 落地前的实测（2026-08-29）

### 0.1 当前库是「通用列存」，不是模型

```
tasks    seq, nf, f1..f8,  fx
archive  seq, nf, f1..f9,  fx
tabs     seq, nf, f1..f5,  fx
status   seq, nf, f1..f3,  fx
user_version = 1
```

C 期刻意只做 1:1 映射（`nf` 记原始字段数、`fx` 存溢出），这就是 `dump` 能逐字节等价的原因。
行 ↔ 列的转换集中在 **约 40 行**（`_cols` / `_connect` / `read_lines` / `write_lines` /
`append_line`）；其上 **20 个动词函数全部只跟整行字符串打交道**。

### 0.2 作用面（生产侧极小，test.sh 是大头）

| 要退役的东西 | 生产侧 | `test.sh` |
|---|---|---|
| `status` 存储 | 4 处 | `dump status` **73** 处 · `CC_STATUS_FILE` **74** 处 · 文件名 8 处 · `load status` 1 处 |
| `$TMPDIR` 去重标记 | 1 处 | `cc-cmux-tabs` **15** 处 |
| 四个 legacy 环境覆盖（§8.9 要求本期退役） | — | 数百处（多数只是设沙箱变量，机械替换） |

**这正是 C 期栽过的坑的同一种形状**：C 期计划只数了生产代码的解析点，漏掉 `test.sh` 的写侧，
实际 117 处。本期先数了写侧再写计划。

### 0.3 `merged_into` 今天被接受但丢弃

`task-archive <branch> <merged-into>` 的第二个参数「for the target API but not persisted in
Phase A」——归档格式冻结在「行 + merged-at」。本期补上这一列。

---

## 1. 两种走法，成本差一个数量级

§3.1 的表列清单写的是「**与今天的 TSV 字段一一对应，不新增语义**」——也就是说那 13 个列名
本身不带新语义，真正带来行为变化的只有 5 个新列（`state` / `state_ts` / `tab_opened_ts` /
`merged_at` / `merged_into`）和 `dir` 主键。于是有两条路：

### 方案 D-min · 只给新语义建列，动词层不动

* `tasks` 表加 5 列；`status` 表退役（并入 `tasks.state` / `state_ts`）；
  `$TMPDIR` 标记退役（并入 `tab_opened_ts`）；`merged_into` 落库。
* `f1..f8` 保留原样 → **`dump tasks` 仍逐字节等价**，C 期那 8 条必钉断言原样成立。
* `dump status` 变成**投影**（`SELECT dir, state, state_ts FROM tasks WHERE state IS NOT NULL`），
  73 处断言不用改；`load status` 反向写进列。
* 动词层 20 个函数几乎不动，只有 4 个碰新语义的要改。
* **交付 §3.4 的全部内容 + 三个 bug 全修。**
* 不交付：`dir` 主键（今天的 newest-per-dir 去重仍由 `task-prune --compact` 显式做）、
  动词层的按名取字段。

### 方案 D-full · 完整落 §3.1 的模型

* `tasks` 变成 13 个具名列、`dir` 做主键；动词逻辑从按位置取字段改成按名字取字段。
* **代价一**：`dump tasks` 从「原始字节透传」变成「按列重建」。7 字段遗留行会被规范成 8 字段
  → **C 期的必钉断言 #2「7 字段行往返后仍是 7 字段」必须被替换**（换成「遗留 7 字段行导入后
  `launch_args` 为空」）。这是本期唯一一处有意的、需要写进 §3.5 的偏离。
* **代价二**：`nf` / `fx` 的语义消失，§39 里依赖它们的断言要重写。
* **收益**：主键吃掉手写去重；动词读得懂自己在读什么。

### 裁定建议：**先 D-min，把 D-full 的差额单列为 D2**

理由与 C 期「只换引擎不收敛模型」同构：D-min 让 `dump` 保持逐字节等价，**现有 1314 条断言原样
成立**，一旦回归能归因到「模型」而不是「模型或 dump 重建」。D-full 的收益是内部整洁，不是行为，
可以在 D-min 绿了之后单独做、单独 gate。

> **待人工拍板**：本节。选 D-min 则下面的 Task 1/2 成立；选 D-full 需要额外一轮
> 「动词层按名取字段 + 断言重写」，且必须先接受上面那处 `dump` 偏离。

---

## 2. Task 1 · schema v2 + status 并表（D-min）

**前提**：C 期已绿。**分支**：以 `feature/state-sqlite` 为 base 与 merge target。

### schema

```sql
PRAGMA user_version=2;
-- tasks: 保留 f1..f8/nf/fx 不动，追加 5 列（全部可空，默认 NULL）
ALTER TABLE tasks ADD COLUMN state TEXT;
ALTER TABLE tasks ADD COLUMN state_ts INTEGER;
ALTER TABLE tasks ADD COLUMN tab_opened_ts INTEGER;
ALTER TABLE tasks ADD COLUMN merged_at INTEGER;
ALTER TABLE tasks ADD COLUMN merged_into TEXT;
-- status 表在迁移末尾 DROP
```

### 库内迁移 1 → 2（一个事务）

1. `ALTER TABLE` 加 5 列；
2. 把 `status` 表每行按 `f1`(dir) 找到 `tasks` 行，写 `state` / `state_ts`；
   **找不到对应任务行的 sidecar 行直接丢弃**（今天 `task-prune` 已经会扫掉它们，
   保留反而会造出没有任务行的孤儿状态）；
3. `DROP TABLE status`；
4. `PRAGMA user_version=2`。

迁移失败 → 事务回滚、库停在 v1、按 v1 路径继续（沿用 C 期的降级契约）。
**v0（四个 TSV）→ v2 的直达路径也要有**：新机器不该被迫先建 v1 再升 v2。

### 动词层要改的 4 处

| 动词 | 今天 | 之后 |
|---|---|---|
| `task-set-state` | 写 `status` 存储 | 写 `tasks.state` / `state_ts` |
| `dump status` | 读 `status` 存储原始行 | 投影 `dir\tstate\tstate_ts`，**按 seq 序** |
| `load status` | 整表替换 `status` | 反向写进两列（dir 匹配不上的行丢弃并 rc 1） |
| `task-prune` | 分别扫两个存储 | 扫一次（sidecar 随任务行一起消失） |

### 必须钉住的断言

1. **`dump tasks` 仍逐字节等价**（C 期 8 条原样跑绿，一条都不许改）。
2. **`dump status` 的投影与今天的原始行逐字节相同**（含 24 行那组并发夹具）。
3. **迁移 1→2 幂等**：跑两次结果一致；`status` 表消失且不重建。
4. **孤儿 sidecar 行被丢弃**：造一条无对应任务行的 status 行 → 迁移后不出现在投影里。
5. **hook 契约不变**：零 stdout、exit 0、无库时 0 次 python 派生。
6. **v0 → v2 直达**：只有四个 TSV 的机器一次迁移到 v2，不经过 v1。

---

## 3. Task 2 · 退役标记与旧变量（依赖 Task 1）

1. `task-mark-opened` 写 `tasks.tab_opened_ts`；`task-opened-recently` 只读这一列，
   **永不看 `created_at`**（§3.1 明写）。删掉 `$TMPDIR/cc-cmux-tabs` 整条路径 → shasum 空哈希缺陷消失。
2. **关窗口 B**：`cc-dispatch.sh resume` 重开 tab 时也 `task-mark-opened`。
   配一条断言：resume 之后 120 秒内的同目录派发被去重。
3. `task-archive` 落 `merged_into`；归档行仍**移出**到 `archive` 表（移动是一个事务，
   C 期已保证「never shows a row in neither store」）。
4. 退役四个 legacy 环境覆盖（§8.9），沙箱只留 `CC_STATE_DB`。
   **这一步机械但量大**，且是唯一会碰到数百处 test.sh 的一步——**单独一条子任务线，单独 gate**。

### 必须钉住的断言

1. `grep -c 'cc-cmux-tabs' cc-state cc-dispatch.sh` = 0（**这条容易恒绿**——先在实现前跑一遍
   确认它是红的，同 C 期第 7 条的教训）。
2. **窗口 B 关上了**：resume 重开 → 立刻同目录派发 → 被去重（行为断言，不是 grep）。
3. `merged_into` 真的落库并能读回。
4. 沙箱只设 `CC_STATE_DB` 时全套仍绿（旧变量全部删掉之后）。

---

## 4. 派发顺序

```
feature/state-sqlite
      │
      ├── d1-schema-v2     ← 先派，独立 gate，落地
      │
      └── d2-retire        ← 以 d1 落地后的 tip 为 base
```

不能并行：Task 2 的 `tab_opened_ts` 列由 Task 1 建出来。

## 5. gate 的固定动作（父会话，不可跳）

沿用 C 期，一字不改：

1. `git status --short` / `log --oneline <base>..HEAD` / `diff <base> --stat` —— 有没有未授权的
   commit、有没有碰不属于这条线的文件。
2. **自己重跑套件**，读自己产出的 tally，不接受形容词。
3. **自己重跑变异测试的抽样**，不接受"我做过了"。
4. rebase 到最新 base → **在新 base 上重新验证** → `gwt-merge` → `gwt-done`。

## 6. 明确不做

* 不动 `gwt-new` 的 workspace 去重（§3.1 明写不在覆盖范围）；
* 不动 `tabs` 表（键是 surface uuid，回答的是另一个问题，**永不与 tasks 去重**，§8.5）；
* 不把 `cc-failures.log` 收进库（追加日志，§3.2 有意留在外面）；
* 不动 git config 承载的分支作用域事实（merge target / ready，§3.3）。
