# cc-stack roadmap — 2026-08-15 存档

当日已完成(详见 git log):A 状态追踪(hook 侧列)、B 非交互看板(cc-board.sh,PARENT 列 / merge 归档 / gwt-log)、
cc-* 脚本 10→6 收拢重构(install 自动迁移)、审计修复 P1-P4、hook 过滤误伤修复、rules 精简 30%。
测试 92 → 180。剩余工作如下,按建议顺序:

## 1. 验证 hook 重写后的真实派发(优先,半小时)

任务 #6 的遗留:重构前**原生长简报派发两次静默失败**(无触发词也失败;提取器单测正常、管道重放正常、注册正确、无面包屑,根因未明)。hook 已被重构整体重写——下次在任何项目里真实派发一个子任务,确认 tab 正常打开即关闭此项;若复现,用临时探针抓 hook 的原生 stdin/input 对比管道输入。相关:docs/known-issues.md 的非规范引号角落。

## 2. Feature C · gwt-resume(断线重建)— 设计定稿 2026-08-15(已研究已验证)

**研究结论:**
- `claude --session-id <uuid>`:调用方预铸 UUID 传入(我们用 `uuidgen`),不依赖事后捕获——已实证会话文件落在铸的 UUID 下;
- `claude --resume <uuid>`:按 ID 恢复;**已实证完整回环**(tab 内铸号启动→回复 MINTOK42→resume 后仍记得,同一会话);另有 `--fork-session` 可选;
- 会话无原生命名 flag:命名住在我们板上(dir/branch→uuid→args)+ `cmux rename-tab` 设 tab 标题(worktree+branch);
- `cld <provider>`:纯 env 包装、参数透传,`cld kimi --resume <uuid> --model x` 成立;
- **cmux 原生已有恢复**:`cmux restore-session` + agent-hook 会话库(记录 session ID + 消毒过的启动命令,保留 model/sandbox/config/cwd flag),重启自动重建;
- **cmux 的缝(我们的价值)**:provider 是进程级 env,消毒器不保留——kimi/glm 启动的子任务会被恢复到默认 provider。**变味**。

**设计(薄层,补在 cmux 原生恢复之上):**
1. 派发记录:cc-dispatch.sh surface 用 `uuidgen` 铸号 → `--session-id <uuid>` 启动;板上 TSV 追加紧凑 launch-args 字段(uuid + provider + permission-mode + model);
2. `gwt-resume [--all]`:① 先 `cmux restore-session`(原生恢复)→ ② 按 cwd 匹配把板上 surface ref 刷新成恢复后的新 tab → ③ 未被恢复的行,用板上记录的完整参数补开:`cld <provider> --resume <uuid> --permission-mode <pm> --model <model>` → ④ 清陈旧状态行;
3. 交互:先列清单(BRANCH|摘要|dir|tab 态)再 y/N 确认;
4. **硬不变量:恢复必须用板上记录的原样 canonical 路径启动,不许重新解析**——claude 按路径字符串索引项目身份/trust/CLAUDE.md,`/Users` vs `/private` 差一个前缀就是另一个项目(已实证)。cc-dispatch.sh surface 的 `--working-directory <记录的dir>` 原样复用;
5. 无会话可恢复时降级为 idle ccteam,失败可见。

## 2b. #7 · backchannel 输入框撞车 — 设计方向 2026-08-15

**问题**:子任务汇报走 `cmux send` 直插父会话输入框,与用户正在输入的内容相撞(截断/冲突)。`cmux send` 无队列/安全模式,"检测对方在打字"从 shell 做不到。
**方案(inbox 通道,绕开输入框):**
- 子任务汇报改写 inbox 文件(按父会话 cwd 键控,重启安全)+ `cmux notify` 桌面提醒(即时可见);
- 父会话的 UserPromptSubmit hook(cc-hooks.sh 已挂)读取自己 cwd 的 inbox,有积压则作为 additionalContext 注入上下文后清空;
- 语义:零撞车、重启安全;注入时机=用户下次发消息(对 campaign 场景通常无损,真需即时可保留显式 urgent 直发选项);
- 实施时注意:cc-hooks.sh status 的"零 stdout"硬规则要改成"仅在有积压时输出",且注入内容要有清晰分隔标记。

## 3. ~~Feature D · gwt-review(验收 diff 一键看)~~ 已裁剪(2026-08-15)

决定不做:git 客户端已有成熟的分支 diff 功能,再造一个薄包装徒增维护面;
功能克制优先(用户决定)。

## 工作流备忘

后续功能继续走已验证的流程:campaign 分支(trunk 规则)→ CC_WT_PROMPT 派发 → 子任务 TDD →
gatekeeper 独立核验 → 人工授权落地(哨兵 commit → squash 进 campaign → campaign 进 main →
重跑 install.sh(若动 hook/规则)→ gwt-rm 清理)。参考 docs/consolidation-map.md 的任务书格式。
