# cc-stack roadmap — 2026-08-15 存档

当日已完成(详见 git log):A 状态追踪(hook 侧列)、B 非交互看板(cc-board.sh,PARENT 列 / merge 归档 / gwt-log)、
cc-* 脚本 10→6 收拢重构(install 自动迁移)、审计修复 P1-P4、hook 过滤误伤修复、rules 精简 30%。
测试 92 → 180。剩余工作如下,按建议顺序:

## 1. 验证 hook 重写后的真实派发(优先,半小时)

任务 #6 的遗留:重构前**原生长简报派发两次静默失败**(无触发词也失败;提取器单测正常、管道重放正常、注册正确、无面包屑,根因未明)。hook 已被重构整体重写——下次在任何项目里真实派发一个子任务,确认 tab 正常打开即关闭此项;若复现,用临时探针抓 hook 的原生 stdin/input 对比管道输入。相关:docs/known-issues.md 的非规范引号角落。

## 2. Feature C · gwt-resume(断线重建)

痛点:cmux 重启后子任务 tab 全丢(板显示 `?old-session`),worktree 和分支都活着,只能手工逐个重建。
设计要点(已讨论):
- 扫任务板:dir 存在但 surface 已死的行(复用 some_live 启发式判断"重启"vs"真关闭");
- 每行重开 tab(cc-dispatch.sh surface 已有全部能力:信任/启动/注册),claude 用 `--continue` 恢复上次会话;
- TSV 刷新新 surface ref;状态侧列清旧行;
- 注意:cc-dispatch.sh surface 目前首发 prompt,需要一个 no-prompt + resume 变体或参数。

## 3. Feature D · gwt-review(验收 diff 一键看)

痛点:gate 通过后想人眼看完整 diff,得手敲 git diff。
设计要点(已讨论):`gwt-review <name>` 包装 cmux 内置 diff viewer
(`cmux diff --source <branch> --base <merge-target> --focus true`),target 从 ccMergeInto 取。
低成本:一个薄 zsh 函数 + README 一行 + 一两条测试。

## 工作流备忘

后续功能继续走已验证的流程:campaign 分支(trunk 规则)→ CC_WT_PROMPT 派发 → 子任务 TDD →
gatekeeper 独立核验 → 人工授权落地(哨兵 commit → squash 进 campaign → campaign 进 main →
重跑 install.sh(若动 hook/规则)→ gwt-rm 清理)。参考 docs/consolidation-map.md 的任务书格式。
