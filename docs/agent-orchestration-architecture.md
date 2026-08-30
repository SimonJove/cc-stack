# cc-stack Agent 编排架构设计

状态：目标架构记录

## 1. 背景

cc-stack 当前是以 cmux、Claude Code 和 Git worktree 为中心的并行开发工作流。它已经拥有任务板、父子分支关系、worktree 生命周期、Agent 状态和合并门禁，但派发、tab 生命周期、消息回传和 Agent 启动仍然集中在 cmux/Claude Code 路径中。

未来需要支持 Claude Code、Codex 和 Pi。三者都可以读取文件、执行命令和修改代码，但它们属于 Agent 执行器；cc-stack 的职责应当是编排和治理，而不是再实现一个 Agent。

## 2. 目标

- 让 Claude Code、Codex 和 Pi 可以作为可替换的任务执行器。
- 保留 cmux 作为当前最完整的本地交互后端。
- 将任务状态、Git worktree、验证和合并政策从 UI 与具体 Agent 中抽离。
- 允许未来增加 terminal、tmux、headless 或 remote 执行后端。
- 保持现有 `gwt-*` 工作流、人工授权边界和任务板语义稳定。

## 3. 非目标

- 不在 cc-stack 内重新实现模型调用、上下文管理或 Agent 推理循环。
- 不让 cc-stack 决定哪个模型“更聪明”。模型和执行器路由属于上层调度策略。
- 不立即移除 cmux，也不为了抽象而同时实现 terminal、tmux 和 remote 后端。
- 不让 Agent 自动获得 merge、push、删除分支或删除 worktree 的权限。

## 4. 分层架构

```text
Human / optional intelligent controller
                │
                ▼
        cc-stack-core
        ├─ task/state
        ├─ worktree/branch
        ├─ verification
        └─ merge policy
                │
                ├──────────────┬──────────────┐
                ▼              ▼              ▼
        cmux adapter     terminal/tmux    headless/remote
                │              │              │
                ▼              ▼              ▼
          Agent runner   Agent runner   Agent runner
          ├─ Claude Code
          ├─ Codex
          └─ Pi
```

这里有两个独立的替换轴：

1. **交互后端**：cmux、普通 terminal/tmux、headless/remote。
2. **Agent 执行器**：Claude Code、Codex、Pi。

交互后端不应与 Agent 类型绑定。例如，Codex 可以运行在 cmux 中，Claude Code 也可以通过 headless runner 运行；cc-stack 不应将二者写成固定组合。

## 5. 各层职责

### 5.1 cc-stack-core

cc-stack-core 是确定性编排层，不调用模型，不解释自然语言。它负责：

- 创建、复用和清理 Git worktree。
- 记录任务 ID、任务摘要、分支、父分支和目标分支。
- 维护任务状态、执行器信息、运行记录和结果索引。
- 定义任务输入、完成条件、阻塞状态和失败状态。
- 执行测试、lint、diff 检查和其他验证命令。
- 判断任务是否满足 ready 条件。
- 强制执行 commit、merge、push、分支删除和 worktree 删除的人工授权。
- 为上层控制器提供稳定的 CLI/JSON 接口。

`cc-state` 是这一层的状态实现。任务状态的唯一事实来源应保持在 cc-stack 内部，而不是分散到 Pi、Claude Code 或 Codex 的会话历史中。

### 5.2 cc-stack-adapters

Adapter 把 core 的生命周期动作映射到具体运行环境：

- `cmux adapter`：创建 workspace/tab，启动 Agent，发送消息，读取状态，处理 surface 生命周期和恢复。
- `terminal/tmux adapter`：在普通终端或 tmux 中启动 Agent；没有 cmux surface 时使用进程、PID、日志或退出码跟踪运行状态。
- `headless/remote adapter`：通过非交互 CLI、SSH、远程 runner 或 RPC 启动任务，收集结构化结果。

Adapter 可以提供 UI 和传输能力，但不拥有任务状态、分支关系或合并政策。

### 5.3 agent runners

Runner 是 Agent 类型的启动和结果协议：

- Claude Code runner：启动 Claude Code，传递 worktree、权限模式、模型和任务简报。
- Codex runner：启动 Codex，传递相同的任务上下文和权限边界。
- Pi runner：启动 Pi；Pi 在“执行器模式”下可以直接完成一个任务，在“控制器模式”下则只能调用 cc-stack 的受控接口。

Runner 必须向 core 提供统一的启动结果、运行状态、完成结果和阻塞原因。Agent 自己的会话格式、提示词、工具名称和 UI 不应泄漏到 core 的任务模型中。

## 6. 控制器与执行器

Pi、Codex 和 Claude Code 都具备成为控制器的能力，但在本架构中建议明确区分运行角色：

- **控制器**：拆分任务、选择 runner、派发任务、读取结果、决定是否重试。
- **执行器**：只在自己的 worktree 中实现任务并报告结果。

推荐的个人工作流是：

```text
Pi（可选控制器）
  → cc-stack CLI/API
    → cmux adapter
      → Claude Code / Codex runner
```

控制器不应直接执行 `cmux send`、直接创建 worktree 或自行维护第二套任务板。所有这些动作都经过 cc-stack 的 adapter 和 core 状态接口。

如果不需要 Pi，Codex 或人工也可以直接调用 cc-stack；Pi 不是架构必需品，而是一个可替换的智能调度层。

## 7. 统一任务协议

每个执行任务至少包含：

```text
task_id
parent_task_id / parent_branch
worktree_dir
branch
merge_target
agent_runner
adapter
permission_mode
prompt
acceptance_criteria
verification_commands
```

执行器返回：

```text
task_id
status: working | blocked | succeeded | failed
summary
changed_files
verification_results
blockers
artifacts
```

`succeeded` 不等于已合并。任务完成、分支 ready、merge、push 和清理仍然是不同状态和不同授权动作。

## 8. cmux 的位置

cmux 是当前的本地交互和可视化后端，不是 cc-stack-core 的必要依赖。

当前实现仍然以 cmux 为中心：`cc-dispatch.sh` 的主要路径是 `wt-claude` 和 `surface`，并通过 cmux 完成 tab、消息注入、状态探测和恢复。未来抽象时应保留这条路径作为默认 adapter，先把接口边界抽出来，再增加其他 adapter。

没有 cmux 时，core 仍应能够完成 worktree、任务状态和验证；缺失的只是 tab UI、跨 tab 通信和 cmux liveness。headless/remote adapter 应明确返回这些能力不可用，而不是伪造 live tab 状态。

## 9. 数据所有权

| 数据 | 所有者 | 其他层的权限 |
|---|---|---|
| 任务 ID、父子关系、分支目标 | cc-stack-core | 读取 |
| worktree 生命周期 | cc-stack-core | 请求创建/清理 |
| tab、surface、PID、远程 job | adapter | core 读取摘要 |
| Agent 会话和上下文 | runner/Agent | 返回结果索引 |
| 测试和验证结果 | cc-stack-core | 读取和附加日志 |
| merge/push/删除授权 | 人 | core 强制执行 |

任何控制器都不能成为任务状态的第二事实来源。控制器可以保存自己的规划和对话，但 cc-stack 的任务板必须能够脱离控制器恢复任务生命周期。

## 10. 迁移顺序

### 阶段一：稳定现有 cmux/Claude 路径

- 保持 `gwt-*` 和现有 `wt-claude` 行为不变。
- 明确 core、adapter、runner 的接口边界。
- 让状态模型不再要求某一种 Agent 会话格式。

### 阶段二：抽取 Agent 启动协议

- 将当前 Claude 启动参数、权限模式、模型和恢复参数整理成 runner contract。
- 保留 `wt-claude` 作为兼容入口，内部转到通用 dispatch 流程。
- 将状态回传从 Claude 专属 hook 扩展为 runner 可提交的统一事件。

### 阶段三：增加 Codex runner

- 增加 Codex 的启动、状态、结果和 resume 适配。
- 让 Codex 任务复用相同的 worktree、任务板和 merge gate。
- 验证 Codex 在 cmux 和 headless 两种模式下的差异。

### 阶段四：增加 Pi controller/runner

- Pi controller 只调用 cc-stack 的受控接口。
- Pi runner 用于需要 Pi 自身扩展能力的独立任务。
- 不让 Pi controller 和 cc-stack 同时拥有 worktree 或 merge 的生命周期控制权。

### 阶段五：增加非 cmux adapter

- 先实现 headless adapter，再考虑 terminal/tmux adapter。
- 为没有 UI surface 的运行明确设计状态、日志、超时和取消协议。
- 只有在实际使用场景证明需要时，才增加远程 runner。

## 11. 设计不变量

- 一个任务只能有一个写入 worktree 的执行器。
- 一个任务的 merge target 在创建时确定，不能由执行器自行改变。
- Adapter 失败不能伪装成 Agent 成功。
- cmux tab 消失不等于 worktree 或任务消失。
- Agent 完成不等于分支已合并。
- 控制器可以失败，cc-stack 仍必须能从任务状态恢复。
- 所有跨进程输入都必须经过显式参数或结构化协议，不能依赖隐式环境变量猜测父任务。
- commit、rebase、merge、push、删除 worktree 和删除分支继续需要人工授权。

## 12. 成功标准

该架构落地后，应满足：

1. Claude Code、Codex 和 Pi 可以使用同一个任务协议完成不同任务。
2. cmux 不可用时，任务仍能创建 worktree、运行 headless Agent、保存状态并完成验证。
3. 替换 cmux adapter 不需要修改任务模型和 merge policy。
4. 替换 Pi controller 不需要修改 Claude/Codex runner。
5. `gwt-status`、`gwt-tree` 和 merge gate 的核心语义不依赖某个模型供应商。

