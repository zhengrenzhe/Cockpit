# Cockpit Phase 2：多 Project 与 Worktree Environment 设计

日期：2026-08-13

状态：已确认

目标版本：Host control Protocol 1.2；Host data plane Protocol 1.2；Terminal/Keeper Protocol 1.1

## 1. 目标

Phase 2 交付工作环境隔离：

- 同时管理多个 Project；
- 一个 Project 拥有 Direct Environment 和多个 Worktree Environment；
- Conversation 可选择 Direct、新分支 Worktree 或已有本地分支 Worktree；
- 文件、文档、终端和客户端状态按 Environment 完全隔离；
- ActiveContext 在目标资源准备完成后一次性切换；
- Worktree 创建与删除使用可恢复事务；
- Project、Conversation 或 Worktree 目录失效时，其他工作区继续工作；
- 保持 Phase 1 Direct 工作流和终端恢复语义。

Phase 2 不交付：

- Git status/diff/stage/commit UI；
- Search UI；
- LSP；
- 远程网络工作区；
- 外部现有 worktree 导入；
- Project 或 Worktree relink；
- 自动 `git init`；
- 删除分支；
- 自动移动既有 worktree；
- 多窗口。Phase 2 保持一个主 Workspace Window，数据模型继续携带 WindowID，为后续多窗口保留隔离键。

### 1.1 与总架构基线的关系

本文是 Phase 2 的权威细化设计。它保持 `docs/design/2026-08-05-cockpit-architecture.md` 的 Project、Conversation、Environment 和 ActiveContext 总体模型，并以本次已确认决策替换其中两条旧删除规则：

- Worktree 不再提供独立删除操作；
- 删除 Worktree Conversation 时，由用户选择仅移除 Cockpit 记录，或同时删除物理 worktree。

分支始终保留。Phase 1 Direct 行为除开发期持久化重置外保持不变。

## 2. 已确认产品行为

### 2.1 Conversation 创建模式

New Conversation 使用一个原生 sheet，并提供三个分段选项：

1. `Direct`
2. `New Branch`
3. `Existing Branch`

标题始终可编辑。`New Branch` 的新分支名是独立可编辑字段；`Existing Branch` 改为选择已有分支，不允许编辑成不存在的 ref。

新分支默认名称为标题 slug。发生冲突时依次追加 `-2`、`-3`。不增加 `cockpit/` 前缀。

Worktree 目录名固定为：

```text
<branch-slug>-<ConversationID 前 8 位>
```

Conversation 重命名不移动 worktree。

`Start From` 只在 `New Branch` 模式展示，并列出：

- Project 的 Direct Environment；
- 该 Project 下全部 Worktree Conversation；
- 每项展示 branch 或 Detached HEAD，以及短 OID。

来源 worktree 有未提交内容时允许继续，但必须明确提示未提交内容不会复制。创建意图冻结来源的完整 OID。

`Existing Branch` 只列本地分支，不展示 `Start From`。选中分支自身的完整 tip OID 是创建来源；Host 在 repository lock 内重新验证 branch ref、tip OID 和占用状态。已经被另一个 worktree checkout 的分支显示为禁用，并展示现有 worktree 路径。

### 2.2 Project Worktree 设置

Project 行内菜单提供 `Project Settings…`，打开原生 sheet。

每个 Project 独立配置 Worktree 存储父目录。未配置时，首次创建 Worktree Conversation 打开目录选择器；取消选择就取消创建。

Project 选择的是 Git 仓库子目录时，首次创建 Worktree Conversation 额外要求确认检测到的 Git repository root，并保存 Git 根 bookmark。

修改设置只影响未来 worktree，不移动既有 worktree。目录选择先解析为 Project-scoped stable capability；物理身份不同就创建新 capability，物理身份相同就复用该 capability 并追加不可变 grant version。Project 设置只切换 stable capability 指针；既有 Worktree Environment 和未完成 operation 继续引用创建时的 capability。被任一设置、Environment 或 operation 引用的 capability 禁止回收。

非 Git Project 保持 Direct 可用，并禁用两个 Worktree 模式，不执行 `git init`。

### 2.3 删除行为

Worktree 不提供独立删除入口。删除 Worktree Conversation 时提供：

- 仅删除 Conversation；
- 删除 Conversation 和 worktree；
- 取消。

任何路径都不删除分支。

删除 Project 会移除 Cockpit 中的 Project 和全部 Conversation 记录，但不删除任何 Project 文件、worktree、分支或提交。

### 2.4 缺失目录

Worktree 目录不存在或身份不匹配时，显示 `Environment Unavailable`、准确路径和删除 Conversation 入口。

Project 目录不存在或身份不匹配时，显示 `Project Unavailable`、准确路径和 Remove Project from Cockpit 入口。

两种情况都不自动删除记录，不提供 relink。

### 2.5 启动与切换

启动恢复顺序：

1. 上次成功提交的 Context；
2. 该 Context 的 Project Context；
3. 第一个可用 Project；
4. Welcome。

切换时保留旧 Context 的脏文档和终端。目标 Context 准备失败时，旧 UI 和旧 ActiveContext 完全不变。

### 2.6 外部 Git 变化

Worktree Environment 绑定物理 worktree，不绑定创建时的 branch。

用户在终端执行 `git switch` 后，Cockpit 刷新真实 branch 和 HEAD。Detached HEAD 保持可用并展示 OID。

目录存在但已不再是同一个 Git worktree、common directory 不一致或选中子目录身份变化时，Environment 进入 Unavailable。

## 3. 当前代码的确定性缺口

本节记录 Phase 2 实现前必须修复的现有边界。

### 3.1 Conversation 被数据库外键锁死在 Direct Environment

`conversations(project_id, environment_id)` 当前引用 `projects(id, base_environment_id)`。该外键只接受 base Direct Environment，无法持久化 Worktree Conversation。

### 3.2 Host 根据 Project 解析所有 Environment

`WorkspaceService.resolveContext` 和文件操作路径先注册 Project bookmark，再用该根注册解析出的 EnvironmentID。未来 Worktree Environment 会因此绑定 Direct 根。

### 3.3 终端根同样固定为 Project bookmark

`CockpitHost` 中的 `WorkspaceTerminalService.resolveWorkspaceRoot` 只读取 Project bookmark。Worktree Context 无法获得自己的工作目录。

### 3.4 Kernel 首次注册后不校验身份

`WorkspaceKernelRegistry.register` 在 EnvironmentID 已存在时直接返回。一次错误绑定会持续到 Host 退出。Registry 也没有 quiesce 和 unregister 能力。

### 3.5 ActiveContext 提前提交

`WorkspaceViewModel.selectContext` 在加载客户端状态、文档和选中内容之前调用 `ActiveContextController.select`。`ContentHostController` 又通过 fire-and-forget `Task` 执行 terminal attach 并吞掉错误。这不满足原子切换。

### 3.6 一个失效 bookmark 阻断全部 Project

`WorkspaceService.listWorkspace` 顺序解析每个 Project bookmark。任一解析失败都会让整个 workspace snapshot 失败。

### 3.7 Git 探测没有执行边界

`SecurityScopedProjectRootResolver` 使用 `Process.waitUntilExit()` 执行 `git rev-parse`，没有超时、取消或并发 drain。

### 3.8 Workspace 错误被压缩成一个 NSError

`HostXPCExport.workspaceCommand` 把全部失败映射为 `dev.cockpit.host-workspace` Code 1，App 无法展示可行动原因。

### 3.9 协议会话没有约束 workspace command

当前 XPC listener 给所有连接复用同一个 export object。Workspace command 不要求 handshake，也不校验协商 feature。

## 4. 权威与组件边界

```text
Cockpit.app
├── 收集用户意图与安全作用域 bookmark
├── 展示 WorkspaceSnapshot、operation 状态和类型化错误
└── 执行 ActiveContext prepare/commit

CockpitHost
├── WorkspaceService：Project/Environment/Conversation 权威
├── EnvironmentRootResolver：EnvironmentID 到目录能力的唯一入口
├── GitRepositoryCoordinator：全部 Git 读取和写入
├── WorkspaceOperationCoordinator：创建、删除和 Project 移除 saga
├── WorkspaceKernelRegistry：Environment Kernel 生命周期
└── SQLiteWorkspaceRepository：持久化权威

CockpitTerminalSupervisor / Keeper
└── TerminalSession 生命周期和 Context 删除协议
```

App 不执行 Git。文件、文档、Host data plane 和终端启动都不能绕过 `EnvironmentRootResolver`。

## 5. 持久化策略

### 5.1 开发期 breaking baseline

Phase 2 不兼容 Phase 1 持久化数据：

- 不实现旧 schema migration；
- 不回填旧行；
- 不实现双读或双写；
- 不兼容旧客户端状态和未完成删除 operation；
- Phase 2 首次安装前执行 Cockpit 开发数据重置并重启 Host、Supervisor。

重置只清理 Cockpit 自有数据库、恢复数据和客户端状态，不触碰 Project、Git 仓库、worktree、分支或文件。

### 5.2 核心表

#### projects

```text
id
display_name
root_bookmark
canonical_root_identity
base_environment_id
lifecycle_state: active | removing
removal_operation_id?
created_at
```

#### project_worktree_settings

```text
project_id
current_storage_parent_capability_id?
current_git_root_capability_id?
project_relative_path
updated_at
```

`project_relative_path` 表示 Project 根相对 Git repository root 的路径。仓库根 Project 使用空相对路径。

两个 current capability 指针在非 Git Project 或尚未完成首次 Worktree 设置时允许为空。任何 Worktree 创建 operation 进入 `prepared` 前都要求 storage-parent 与 git-root capability 同时存在；仓库根 Project 也把已确认的 repository root 保存为独立 `git_root` capability。

#### capabilities

```text
id
project_id
kind: storage_parent | git_root
canonical_identity
current_grant_version_id
created_at
```

Stable capability 的 `(project_id, kind, canonical_identity)` 唯一且不可修改。Project Settings、WorktreeEnvironment 和 WorkspaceOperation 都引用 stable capability ID，不直接引用可轮换 bookmark。

#### capability_grant_versions

```text
id
capability_id
bookmark
created_at
```

Grant version 是不可变行。Bookmark stale 时，Host 只有在新 bookmark 解析为同一 capability 的 project/kind/canonical identity 后，才能追加新 version，并原子更新该 capability 的 `current_grant_version_id`；该可轮换指针不进入 operation intent digest。设置改到不同物理身份时创建或复用另一个 stable capability，不能改变旧 capability 的 identity。Stable capability 被 settings、WorktreeEnvironment 或未完成 WorkspaceOperation 引用时不能删除；最后外部引用释放后，Host 才能在一个 transaction 中回收 capability 和全部 grant versions。

#### environments

```text
id
project_id
kind: direct | worktree
workspace_root_path
workspace_root_identity
incarnation
availability_state
availability_reason
created_at
```

#### worktree_environments

```text
environment_id
conversation_id UNIQUE
storage_parent_capability_id
git_root_capability_id
project_relative_path
worktree_root_path
worktree_root_identity
git_common_directory_path
git_common_directory_identity
head_kind: branch | detached
head_ref
head_oid
last_verified_at
```

Git worktree 根供 Git 管理；`workspace_root_path` 是进入 Project 子目录后的 Cockpit 文件、文档和终端根。两个 stable capability ID 与 relative path 是创建时快照，Project Settings 后续变化不修改它们；同身份 bookmark refresh 只追加 grant version。

#### conversations

```text
id
project_id
environment_id
title
lifecycle_state
lifecycle_operation_id?
created_at
```

Conversation 的复合外键要求 Environment 属于同一 Project。Direct Environment 可被多个 Direct Conversation 共享；Worktree Environment 通过 deferred owner 关系只能归属于一个 Worktree Conversation。

#### workspace_operations

```text
id
kind
project_id
conversation_id?
environment_id?
repository_identity?
request_digest
phase
intent_json
result_json
last_error_json
created_at
updated_at
```

`id` 由客户端在第一次提交变更意图前生成。Host 从严格 canonical encoding 的客户端 intent 自己计算 `request_digest`，不接受客户端提供的 digest 作为权威；Host 后续生成的 ConversationID、EnvironmentID 和 observed state 不参与重试 digest。同一 ID 和相同 digest 返回原 operation/progress/result，同一 ID 和不同 digest 返回 `idempotencyConflict`；并发首提交通过 `id` 唯一约束和单个 SQLite transaction 线性化。`intent_json` 冻结 Worktree creation/Project Settings 使用的 stable capability ID，但 JSON tombstone 不充当 live FK。`intent_json` 使用严格版本化 Codable 结构，不保存任意 shell 命令。最终结果必须能从 operation 与领域表重建，不能依赖已经丢失的 XPC reply。

Add Project、Project Settings、Conversation create/rename/delete 和 Project removal 等全部 Host-control metadata mutation 都使用 WorkspaceOperationID。只需一个 SQLite transaction 的操作仍在该 transaction 中验证 Project/Conversation lifecycle active 且没有冲突 live claim，并写入 operation、领域变化、可重建 result 和 completed；不能因为没有外部 Git 副作用而退回非幂等命令。

`project_id`、`conversation_id` 和 `environment_id` 是 operation tombstone UUID，不对随后会删除的领域行建立 live foreign key。Operation begin 通过下面的 live target claim 在同一 transaction 验证真实领域行；operation 完成后保留完整 result/tombstone 供幂等 replay。Phase 2 不自动 GC completed operation；只有第 5.1 节明确的 Cockpit 开发数据重置会清理它。相同 WorkspaceOperationID 始终返回原结果，不能生成第二份领域对象。

#### workspace_operation_targets

```text
operation_id
target_kind: project | conversation | environment
project_id?
conversation_id?
environment_id?
```

每行只允许一个非空 target ID，并对每种 target ID 建唯一索引；该表只保存 live claim，对应列直接引用领域表。Operation begin 在一个 workspace.sqlite transaction 中完成：插入 operation、取得全部 target claim、把 Project/Conversation lifecycle 切到 removing/deleting 并写入 owner operation ID。任一 target 已被另一非终态 operation 占用时，整个 begin 无副作用失败。

Project removal 在 Project admission gate 下重新验证用户确认的精确 membership，再在 begin transaction 同时 claim Project 及该集合的全部 Conversation/Environment，并拒绝任何已有 descendant claim。Project 进入 `removing` 后，数据库 trigger 与 Host admission 统一拒绝新 Conversation、Project Settings、Environment、Document/Terminal admission 和其他 operation。完成 metadata purge 时，同一个 transaction 写入 operation result、删除 live claim rows、删除领域行并标记 completed；operation tombstone 不随领域行删除。

#### workspace_operation_capabilities

```text
operation_id
capability_id
role: storage_parent | git_root
```

该表只保存非终态 operation 的 live capability binding，并以真实外键阻止 capability 提前回收；role 必须匹配 capability kind，capability project 必须匹配 operation project。Worktree metadata commit 在同一 transaction 插入 Environment capability FK、删除 operation binding并推进 phase；Project Settings transaction 先写 settings capability FK，再删除 binding并 completed。Completed operation 的 JSON/result 保留 capability tombstone ID，但不再阻止没有 live Settings/Environment 引用的 capability 回收。

#### workspace_operation_observations

```text
operation_id
sequence
kind
payload_digest
payload_json
created_at
```

这是 append-only Host observation journal。Target reservation identity 在 `targetReserved` phase CAS 的同一 transaction 追加，不能写回 immutable root intent。

#### workspace_operation_decisions

```text
operation_id
decision_id
revision
kind
request_digest
payload_json
accepted_at
```

Manifest 重新确认、records-only fallback 和 force-termination confirmation 都以客户端稳定 DecisionID、独立 canonical digest 和单调 revision 追加。相同 DecisionID/digest 幂等返回；不同 digest 冲突。每个需要决策的 phase CAS 显式引用已接受的 decision revision，崩溃恢复不能依赖一次 XPC resume 参数。

#### workspace_operation_contexts

```text
operation_id
workspace_context_id
terminal_child_operation_id UNIQUE
document_decision_revision?
terminal_gate_phase
terminal_purge_phase
```

Project removal 在任何 session 终止前持久化全部 Context 及稳定、逐 Context 唯一的 terminal child operation ID；child ID 由 parent WorkspaceOperationID + ContextID 确定性派生。Workspace 与 terminal 数据库不能原子提交，因此 Supervisor gate 使用 `prepared | deleting | purged` 状态：prepared 只阻断该 Context 新 session/ticket/attachment admission，不终止现有 session。恢复器按 child ID 幂等建立/查询/promote 每个 terminal deletion gate，并把 ack 写回该 journal。只有全部 Context gate 进入 deleting 后，父 operation 才能进入终止阶段。

Supervisor/Host 启动都先完成跨库 gate reconciliation，再开放 terminal admission：terminal.sqlite 有 prepared child 但 workspace.sqlite 不存在 parent operation 时，在 Host 权威证明 absent 后释放孤儿 gate；workspace operation 已是 targetsClaimed 但 child 仍 prepared/missing 时，按 context journal 创建或 promote；身份或集合不一致时 fail closed 并保持 admission blocked。

### 5.3 数据库不变量

Phase 2 fresh schema 直接用外键、唯一约束、CHECK、deferred foreign key 和必要 trigger 固化以下规则：

- `projects.base_environment_id` 必须引用同 Project 的 Direct Environment；
- `conversations(project_id, environment_id)` 必须引用同 Project 的 Environment；
- Direct Environment 的 owner 为空，可被多个 Direct Conversation 共享；
- Worktree Environment 必须且只能被一个 Conversation 拥有，Conversation 与 WorktreeEnvironment 双向关系在同一 deferred transaction 提交；
- `workspace_root_identity` 和 `worktree_root_identity` 在活动记录中唯一；
- WorktreeEnvironment 与非终态 operation capability binding 的 stable capability 必须存在、类型正确，并通过真实外键阻止被提前回收；
- capability 的 project_id 必须与 settings、Environment 和 operation binding 的 project_id 一致；grant version 必须属于该 capability；
- stable capability identity、grant version、operation intent、request digest 和已生成的领域 ID 创建后不可修改；
- Project/Conversation lifecycle owner 必须与 active target claim 的 operation 一致；没有 owner 的 deleting/removing 行和没有领域 lifecycle 的活跃 claim 都被 constraint/trigger 拒绝；
- Project removal 的全部 Context child row 必须在父 phase 离开 gating 前 durable；
- operation phase 只允许 compare-and-swap 前进，终态不可退回。

Repository 层仍执行同样验证并返回类型化错误，但数据库约束是最后一道权威边界。

#### context_commits

```text
context_commit_id
device_id
window_id
workspace_context_id
environment_id
environment_incarnation
committed_generation
workspace_state_revision
phase: durablePendingChildren | childrenActive | superseding | revoking | released
predecessor_context_commit_id?
recovery_epoch
created_at
```

#### context_commit_children

```text
context_commit_id
kind: data_plane | file_tree | document_viewer | terminal_attachment
logical_child_id
prepared_authority_digest
active_authority_digest
promotion_phase: pending | active
```

Durable promotion transaction CAS `client_window_navigation.context_commit_id == predecessor_context_commit_id`，同时写新 `context_commits`、完整 child journal、更新 navigation，并把 predecessor 标为 `superseding`。Child journal 保存能重建逻辑资源的 Context/tab/session identity，不保存只能在旧进程使用的 FD。Host 只有在每个 child 都完成 authority handoff 并 CAS 为 active 后，才把新 commit phase 标记 `childrenActive` 并返回 `CommittedContext`；崩溃恢复从 durablePendingChildren 继续，不能回滚 navigation。

只有 ID 等于当前 `client_window_navigation.context_commit_id` 的 commit 能继续 child recovery 或发行 ticket。旧 ID 返回 `superseded(currentContextCommitID)`。Predecessor 在 superseding 期间禁止新 admission，但其 child 在仍属于从 current 到 `presented_context_commit_id` 的 predecessor chain 时保持可恢复，防止旧 visible UI 被提前拆除。

`presentationCommitted(currentID)` 在一个 SQLite transaction 验证 currentID 等于 navigation current、旧 presented ID 可沿 predecessor chain 从 current 到达，然后把 `presented_context_commit_id` 更新为 currentID，并把该链上 current 的全部 predecessor（包含旧 presented）CAS 为 revoking。异步撤销逐 commit 幂等释放 data-plane/viewer/terminal/Kernel child，最后标记 released；崩溃后扫描 revoking 继续。Released commit 只保留 tombstone/status，不再发行 capability。由此 A 已展示、B durable 未展示、C 再取代 B 时，C 的 presentation ack 会同时回收 B 和 A，不留下 superseding ancestor。

#### client_window_navigation

```text
device_id
window_id
last_context_kind
last_context_id
last_committed_generation
context_commit_id UNIQUE
presented_context_commit_id?
updated_at
```

`context_commit_id` 是最后一次 durable commit；`presented_context_commit_id` 是 App 已确认完成可见交换的 commit。两者之间的 predecessor chain 表示 durable 但未最终展示或等待回收的 commit。Phase 2 只有一个主窗口；`window_id` 仍使用当前稳定 main WindowID，不创建第二个窗口记录。

## 6. EnvironmentRootResolver

`EnvironmentRootResolver` 接受 EnvironmentID，返回：

```text
ResolvedEnvironmentRoot
├── environmentID
├── projectID
├── kind
├── workspaceRootPath
├── workspaceRootIdentity
├── worktreeRootPath?
├── worktreeRootIdentity?
├── gitCommonDirectoryIdentity?
├── incarnation
├── capabilityIDs
├── grantVersionIDs
└── accessTokens
```

Direct Environment 从 Project bookmark 恢复能力。Worktree Environment 从自身冻结的 storage-parent/git-root stable capability ID 读取各自 current immutable grant version，然后验证已持久化物理身份；Resolver 禁止改用 Project Settings 的 current capability。Project Settings 指向不同物理身份时，不会影响既有 Environment 或未完成 operation。

Resolver 每次返回前验证：

- 路径存在且是目录；
- canonical path 和资源身份一致；
- Worktree 仍注册在预期 Git common directory；
- Project 子目录仍映射到同一物理目录；
- 当前 branch/Detached HEAD 和完整 OID 可读取。

每次从 Unavailable 恢复到 Available 都生成新的 Environment incarnation。Host data-plane ticket、文件树 subscription、Document viewer、Terminal launch/attach authorization 和 prepared-context token 都绑定 incarnation；旧 incarnation 不能继续访问新注册的 Kernel。

失败返回类型化 availability，不把错误传播为整个 workspace snapshot 失败。

`WorkspaceKernelRegistry.register` 改为身份校验注册。相同 EnvironmentID 与不同 root identity 直接 fail closed。

Registry 增加：

- `prepareKernel`；
- `quiesce`；
- `unregister`；
- 活跃 viewer/operation 计数；
- 确定性停止 FSEvents、DocumentRegistry 和文件操作协调器。

## 7. GitRepositoryCoordinator

所有 Git 命令由 Host 执行，且以 canonical Git common-directory 物理身份为锁键。多个 Project 指向同一仓库或不同子目录时共享同一个串行队列。

Git runner 固定规则：

- executable 固定为 `/usr/bin/git`；
- 参数使用 typed argv；
- 禁止 shell 字符串拼接；
- 设置 `GIT_TERMINAL_PROMPT=0`；
- stdout 和 stderr 并发有界读取；
- 命令具备阶段化超时和 Task 取消；
- 通过 `posix_spawn` 的 `POSIX_SPAWN_SETSID` 与 close-on-exec defaults 启动，验证 direct child PID 等于新 PGID，并记录不可复用进程身份；
- 取消时只对本次认证过的 Git process group 执行 TERM、bounded grace、KILL，期间持续 drain stdout/stderr 但只保留有界字节，最后对 direct child 执行 exact `waitpid` 后才返回；
- 返回 argv、退出状态、stdout、stderr 和 timeout/cancel 分类；
- 用户 Git hooks 按 Git 标准行为执行并受同一超时控制。

取消门禁只承诺 initial authenticated Git PGID 无成员残留、direct child 已回收。用户 hook、filter 或 helper 通过 `setpgid` 或 `setsid` 离开 initial PGID 后不再属于 Cockpit 可认证信号范围，Phase 2 不宣称终止该进程；UI 和日志必须把它归类为仓库自有外部行为。禁止用未经认证的全局进程扫描或信号扩大清理范围。

机器读取使用：

- `git worktree list --porcelain -z`；
- `git for-each-ref` 的机器格式；
- `git status --porcelain=v2 -z --untracked-files=all --ignored=traditional`，只用于变化分类，不作为删除授权 fingerprint；
- `git rev-parse` 获取完整 OID 和 common directory。

UI 中的 branch 可用性只是快照。Host 在仓库锁内再次验证分支占用和来源 OID。Repository lock 只串行 Cockpit 自己的 Git 操作，不声称阻止外部 Git 或文件系统写入；每个有破坏性的操作都必须定义自己的最终 revalidation 和线性化点。

`/usr/bin/git` 不能从 directory FD 接受 Git common directory；本机 Apple Git 2.50.1 对 `/dev/fd/<directory-fd>` 明确返回 not-a-git-repository。因此 mutation runner 在 durable `gitMutationEpoch` 开始后，立即 fresh 验证 common-directory pathname/identity、冻结 Cockpit repository admission并 spawn。Epoch 开始前完成的外部 repo/path 变化必须被验证拒绝；epoch 同时或之后替换 common-directory path 属于与 Git mutation 并发的外部操作，Cockpit 不宣称阻止它。Git 返回后 identity 不一致时不提交 metadata、不自动补偿 Git/branch/path，operation 进入 `needsAttention`。UI 在执行 Worktree create/delete 前明确要求停止其他会移动、替换或修改该 repository 的工具。

### 7.1 目标路径 reservation

Worktree 创建不使用“`lstat` 不存在后直接把路径交给 Git”的两步协议。Host 必须：

1. 通过已授权 storage parent 的打开目录句柄执行 fd-relative `mkdirat`，以 `O_EXCL` 等价语义原子创建最终目标空目录；
2. 把目标目录的 device/inode/resource identity 和 operation ID 追加到 immutable intent 之外的 durable `workspace_operation_observations`，并与 `targetReserved` phase CAS 同 transaction 提交；
3. 保持目录句柄，在执行 Git 前再次验证 pathname 仍指向同一空目录；
4. Git runner 对 reservation directory descriptor 使用 `posix_spawn_file_actions_addfchdir_np`（macOS 15–25）或 `posix_spawn_file_actions_addfchdir`（macOS 26+），使 child 的 cwd 直接绑定该目录对象；命令只使用 target `.`，不能再次解析 target pathname；
5. `/usr/bin/git` 使用经过身份验证的 `--git-dir=<common-directory>` 和 fd-bound cwd 执行 `worktree add -- . ...`；无法建立 fd-bound cwd 时该平台禁用 Worktree 创建；
6. Git 返回后同时验证打开句柄、pathname、Git 注册和 observation 中的物理身份完全一致。

路径被重命名、替换、提前写入内容或身份无法证明时，Host 不提交 metadata，也不删除未知路径，operation 进入 `needsAttention`。验收必须用系统 Git 版本证明其接受 Cockpit 预创建的空目标目录；若系统 Git 不接受，该平台直接禁用 Worktree 创建，不退回 `lstat + path`。

## 8. Conversation 创建与 Worktree saga

### 8.1 准备

App 在 sheet 首次确认时为 Direct/New Branch/Existing Branch 都生成稳定的 WorkspaceOperationID，并提交标题、模式及该模式需要的来源、branch 和 capability。网络重试和 App 重连必须复用同一个 operation ID。

- `Direct` 提交 ProjectID 和标题；Host 在一个 transaction 中写入 operation、复用 base Direct Environment、创建唯一 Conversation、写入可重建 result 并 completed；
- `New Branch` 提交 source EnvironmentID 和 source full OID；
- `Existing Branch` 不提交独立 Start From，只提交完整 local branch ref 和确认时的 branch tip OID；
- 三种模式都由 Host 对 canonical client intent 计算 digest；Phase 2 App 不使用无 WorkspaceOperationID 的 legacy Direct create command。

Direct 在上述 transaction 完成后结束，不进入 Git saga。New Branch/Existing Branch 的 Host 准备步骤是：

1. 验证 Project 和授权；
2. `New Branch` 解析来源真实 worktree并读取完整 source OID；`Existing Branch` 读取完整 branch tip OID；
3. `New Branch` 检查来源 dirty 状态并返回显式确认要求；
4. 生成新的 ConversationID、EnvironmentID 和目标目录；
5. 写入 `prepared` operation。

Worktree creation operation 冻结：

- client WorkspaceOperationID 和 request digest；
- `New Branch` 的 source EnvironmentID 和 source full OID；
- `Existing Branch` 的完整 local branch ref 和 expected branch tip OID；
- new/existing branch 模式；
- branch ref；
- storage-parent/git-root stable capability ID 与 identity；
- target absolute path；
- Project relative path；
- ConversationID；
- EnvironmentID。

### 8.2 Git 变更与提交

在 repository lock 内：

1. `New Branch` 重新验证 source OID 和 branch ref 不存在；`Existing Branch` 重新验证 branch tip OID；
2. 重新验证 branch 未被其他 worktree 占用；
3. 按 7.1 原子创建并记录 operation-owned 目标目录，更新为 `targetReserved`；
4. 追加 `gitMutationEpoch` observation，fresh 验证 common-directory identity，并在同一 CAS 更新 operation 为 `gitRunning` 后立即 spawn；
5. `New Branch` 在 fd-bound target cwd 执行 `git --git-dir=<common> worktree add -b <validated-new-branch> -- . <sourceOID>`；`Existing Branch` 持久化完整 `refs/heads/...`，验证前缀与 `check-ref-format` 后派生 canonical short branch argv，并执行 `git --git-dir=<common> worktree add -- . <short-branch>`；两者都不使用 `--force` 或 `-B`；
6. 校验目标 worktree 的物理身份、Git 注册、common directory、实际 branch ref 和完整 OID；`New Branch` 要求 branch tip 等于 source OID，`Existing Branch` 要求 branch tip 等于 expected tip OID；
7. 验证 Project 子目录存在并取得 workspace root identity；
8. 更新 operation 为 `gitAdded`；
9. 一个 SQLite deferred transaction 写入 Environment、WorktreeEnvironment、Conversation 和 `metadataCommitted`；
10. 写入可重建的 result 并标记 `completed`。

来源或 Existing Branch tip 变化时返回 `sourceMoved(expectedOID, actualOID)`，不从新 OID 静默创建。Git 的 branch-exists、branch-occupied、target-not-empty 和 hook/checkout failure 分别映射成类型化结果，不压成通用 Git failure。

### 8.3 崩溃恢复

Host 启动扫描未完成 operation：

- 只有 `targetReserved` 且 Git 尚未注册、目标仍是 operation-owned 同一空目录时，允许用 `rmdir` 移除空 reservation 并标记失败；
- worktree 已创建且全部身份与 intent 完全一致：继续数据库提交；
- `New Branch` 已出现但 worktree 未创建：保留 branch，记录 `branchRetained(ref, oid)` 并进入 `needsAttention`；自动恢复和补偿都不删除或 reset branch；
- Git 已开始且无法满足“完整 worktree 可继续提交”的条件：不自动移除物理 worktree。用户 hook、checkout 或外部进程产生的文件都视为未知数据，operation 进入 `needsAttention`；
- 任一身份无法证明：不删除路径，标记 `needsAttention`。

自动补偿只删除已认证的空 reservation，永远不删除 branch 或 Git 已经物化的 worktree。重复提交同一 operation ID 返回已有 progress/result；不同 request digest 使用同一 ID 时返回 `idempotencyConflict`，不能启动第二个 Git 操作。

## 9. ActiveContext 两阶段切换

### 9.1 PreparedContextToken

App 发起选择时先增加本地 selection-request 序号，但不修改当前 ActiveContext。Host 的 `prepareContext` 返回短期、单次使用的 `PreparedContextToken`：

```text
PreparedContextToken
├── tokenID
├── contextCommitID
├── issuerHostControlConnectionID
├── issuerPeerIdentity
├── windowID
├── workspaceContextID
├── environmentID
├── environmentIncarnation
├── proposedGeneration
├── workspaceStateRevision
└── expiresAt
```

`contextCommitID` 由 App 为一次逻辑选择生成并跨重连保持稳定。`proposedGeneration` 从该窗口的最后 committed generation 单调预留，但在 commit 前不是 active generation。Host data-plane ticket、文件树 subscription、Document viewer 和 terminal attach 增加 prepared-token binding；它们验证 token、issuer session/peer、window、Context、Environment、incarnation 和 expiry，不能拿旧 active generation 代替。

Host data-plane 1.2 authority 从 1.1 的单一 active-generation 数值改成严格 oneof：`active(generation, incarnation) | prepared(tokenID, proposedGeneration, incarnation)`，并增加明确的 `environmentUnavailable` revocation error。Prepared frame 只能交给同一个 prepared token；commit promotion 后才转换为 active authority，abort 后统一拒绝。Host data-plane 1.1 codec 保留原字段和错误集合，严格不解码 1.2 binding。

Host-control 发行的 prepared ticket 绑定 issuer Host-control connection、peer identity、token 和 incarnation。Ticket 被独立 UDS data-plane connection 消费后记录新的 `dataPlaneConnectionID` 与 issuer parent；Terminal ticket 被 Supervisor 消费后记录独立 attachment identity。Prepared terminal authorization 通过 Host-control 1.2 的内部 `TerminalAuthorizationRegistration` 在 Host/Supervisor 之间传递，不属于 TerminalStreamProtocol。Terminal/Keeper 1.1 wire 不承载 PreparedContextToken 或 incarnation：Supervisor 必须先验证 registration，再签发普通 1.1 Keeper ticket；token 撤销时 Supervisor 通过父子记录撤销未消费 ticket或 detach 已建立 attachment。

Host data-plane 1.2 child connection authority state 固定为：

```text
prepared(tokenID, proposedGeneration, incarnation)
→ promoting(contextCommitID, activeGeneration, handoffEpoch)
→ active(activeGeneration, incarnation)
```

进入 promoting 后连接停止普通 data request，只交换 `authorityPromoted`/ack control frame；client 收到后切换后续 frame binding 并 ack，server 才转 active。Prepared token expiry 或旧 issuer connection invalidation只撤销仍处于 prepared 的 child；durable commit journal 已接管的 promoting/active child 按 ContextCommitID 处理，不能被旧 token cleanup detach。

Supervisor 为 terminal attachment 保存同构的 durable promotion journal。Commit coordinator 用 ContextCommitID 把 prepared registration 转成 active Context/generation authority；Keeper 1.1 attachment/binding 不变，Supervisor 只改变其上层授权 owner。Supervisor crash 后按 journal 查询 Keeper attachment identity并恢复 active owner，身份不匹配则由 Host 在隐藏 presentation 中重新 attach。

同一窗口同时只有一个 live prepared token。新选择、连接失效、超时或显式 abort 会撤销旧 token 及其全部 ticket、subscription、viewer 和 terminal attachment。

### 9.2 不可见 Prepare

Prepare 同时完成：

- resolve target Context 并验证 Environment availability/incarnation；
- 获取 staged WorkspaceKernel 引用；
- 加载 ClientWorkspaceState；
- 构造不可变 `PreparedFileTree` 首帧，不调用当前可见 FileTreeViewController；
- 恢复 tabs；
- 对 file tab 创建隐藏的 `PreparedMonacoPresentation`，在独立、不可见的 Monaco runtime 中加载 model/view state 并确认 ready；
- 对 live TerminalTab 创建隐藏的 `PreparedTerminalPresentation`，完成认证 attach 并取得首个可渲染 frame；
- 对 finalized TerminalTab 加载 archive snapshot 并取得首个可渲染 frame；没有 archive 的 finalized session 产生明确空终态，不尝试 live attach。

现有会立即调用 `selectModel` 的 `MonacoBridge.select`、会 reload 当前列表的 file-tree `activate`、以及会安装可见 controller 的 terminal `show` 都不能作为 Prepare API。三个 staged presentation 分别提供 `commit()` 和 `abort()`；Prepare 与 abort 不修改旧 UI，不销毁旧 terminal controller。

所有异步结果都绑定本地 selection-request 序号和 PreparedContextToken。任一资源失败时 Host abort token，App 销毁 staged presentation，旧 Context 保持权威。

### 9.3 Durable commit 与可见交换

Commit 前，Environment admission coordinator 在排他的 availability transition gate 内执行一次 fresh fd-backed resolve，重新验证 root/common-directory/Project-subdirectory identity，持有已认证 root/Kernel handles，并以 CAS 确认 Environment 仍 Available、incarnation 与 workspace state revision 未变化。无法取得该 admission lease时先进入 quiescing/unavailable，再拒绝 promotion。

Commit 的线性化点是 Host 对 PreparedContextToken 的 durable promotion：在一个 SQLite transaction 中验证 token、admission lease 和 `contextCommitID` 尚有效，写入 `context_commits(durablePendingChildren)`、完整 child journal、`client_window_navigation` 的 Context/Environment/generation/commit ID，并把 proposed generation 标为 committed。失败发生在线性化点之前，旧 Context 完全不变。外部身份变化发生在 fresh resolve 后时，已持有 descriptor 仍绑定同一目录对象；pathname/registration 不再匹配会触发下一次 availability transition，不能把新对象注入本次 committed authority。

SQLite commit 后，Host 按 child journal 执行 data-plane authority frame handoff、file-tree/viewer active owner handoff和 Supervisor terminal promotion。每个 child active CAS 都可幂等重放；全部完成后把 context commit phase 置为 `childrenActive`，再返回 `CommittedContext`。Child handoff 失败或进程崩溃不回滚 durable Context，也不允许 App 提前交换可见 UI；进入第 9.4 节的 frozen recovery。

Host 返回 `CommittedContext` 后，MainActor 只执行已经准备完成且定义为不抛错的同步交换：

- ActiveContext 和 ActiveContextGeneration；
- tabs 和 selectedTab；
- PreparedMonaco/Terminal content controller；
- PreparedFileTree model；
- sidebar selection。

可见交换后再释放旧 presentation、旧 viewer 和旧 Kernel 引用。交换之后没有决定本次选择成功与否的 fallible I/O。若进程在 durable promotion 后、可见交换前崩溃，重启按已 committed 的 `client_window_navigation` 恢复目标 Context；该 durable promotion 是“最后一次成功 commit”的权威含义。

App 完成同步可见交换后发送幂等 `presentationCommitted(contextCommitID)`；该 ack 原子推进 navigation presented ID，并触发整条 superseding predecessor chain 的 child revocation，不改变本次 commit 成功结果。Ack reply 丢失时重试；App 崩溃时，下一次启动恢复 current navigation 并在其 hidden presentation ready 后代发该 ack。Host 不能在 successor childrenActive 且 presentation ack durable 之前撤销旧 presented children。

### 9.4 Commit reply 丢失与重连

`contextCommitID` 在 prepare token、commit request、navigation row 和 `CommittedContext` 中完全一致。Host 对相同 ID/相同 token intent 幂等返回同一 committed result；相同 ID 指向不同 Context/generation 时返回 `contextCommitConflict`。

Commit 遇到 transport error 后，App 保留旧 UI 画面但冻结旧 Context 的新 admission，不把该错误当作未提交。重连并完成 handshake 后，App 调用 `contextCommitStatus(contextCommitID)`：

- `committedReady`：Host 已完成或在新连接下幂等重建全部 active child，返回 committed Context、generation 和 active-authority tickets；App 在隐藏 presentation 中恢复 B，ready 后执行同一不抛错可见交换；
- `committedNeedsChildren(recoveryEpoch, childPlan, tickets)`：durable row 是当前 navigation owner，但一个或多个旧进程 child 不存在或尚未 active；App 在隐藏 presentation 中按 plan 消费 ticket、建立 data-plane/viewer/terminal child，并提交 `completeContextRecovery(contextCommitID, recoveryEpoch, childReadyProofs)`；Host 验证 proof 的 peer、connection、logical child、active authority 与 journal，CAS 全部 child active 和 commit childrenActive 后返回 committedReady；
- `committedUnavailable`：durable row 证明 B 已提交，但 Environment 已 Unavailable，Host 返回 Context、generation、availability 和 owning ProjectID，不发行 ticket；App 显示明确 unavailable 恢复状态，并立即按第 2.5 节的顺序使用新的 ContextCommitID 切换 owning Project Context、首个可用 Project 或 Welcome；
- `notCommitted`：Host 证明没有该 commit ID 的 durable row，App 销毁旧 staged resource、重新激活 A；
- `superseded(currentContextCommitID)`：该 ID 已被同一窗口的新 commit 替代，不发行 ticket，App 只恢复 current ID；
- 查询 transport 失败：UI 保持冻结并展示可重试连接错误，不能同时向 A/B 发新请求。

每个 commit 同时只有一个 durable recovery epoch。相同 epoch 的 status/complete 重试返回同一 child plan/result；旧 epoch 的 ticket、ack 和 proof 全部拒绝。Epoch ticket 因 connection invalidation 或 expiry 失效时，Host 先撤销该 epoch 已建立但未完成的 child，再 CAS 递增 epoch 并生成新计划。Host 不在客户端消费 ticket前等待 child active，App 不在取得 committedNeedsChildren 前自行猜测 child。

旧 connection invalidation 仍撤销未 durable 的 prepared token/tickets；durablePendingChildren/childrenActive/superseding 由 ContextCommitID journal 接管，不能被旧 connection cleanup 删除。Durable `contextCommitID` 状态不在 connection request cache 中，不能随重连丢失。

## 10. Workspace snapshot 与不可用状态

Workspace snapshot 返回每个 Project 和 Environment 的独立状态，不返回 bookmark。

Project snapshot 包含：

- ProjectID、名称；
- Project Context；
- availability 和准确诊断；
- Worktree 设置是否完成；
- Conversation summaries。

Conversation summary 包含：

- ConversationID、EnvironmentID、标题；
- Direct/Worktree；
- branch 或 Detached HEAD；
- 短/完整 OID；
- availability；
- worktree path；
- lifecycle/operation 状态。

一个 Project 或 Environment 失败不会阻断其他 snapshot。

## 11. 外部 Git 变化

每次使用 Worktree Environment 前和 Git 相关 UI 刷新时，Host 读取真实 branch/HEAD。

- `git switch` 后更新 branch 和 OID；
- Detached HEAD 更新为 detached + OID；
- worktree 被外部移动、prune、重新注册到其他 common directory，或物理身份变化时标记 Unavailable；
- 不自动重新创建或 relink；
- 用户只能删除 Conversation 记录。

Available → Unavailable 是 Host 权威状态转换，不只是 snapshot 标签。转换顺序固定为：

1. 在 admission coordinator 内原子把 incarnation 标为 revoked，并冻结新 admission；
2. 撤销 prepared token、未消费 ticket 和 ContextCommit child promotion；
3. 主动关闭该 incarnation 的全部 data-plane UDS child connection，取消 stream/subscription，并按 Environment/incarnation 调用 DocumentRegistry removeViewers；
4. 撤销 Supervisor registration 并 detach 全部 active terminal attachment；底层 TerminalSession process 保持运行但不能输入/取帧；
5. 只等待已经进入执行区的 file/document operation drain；
6. quiesce 并 unregister Kernel，释放 root token。

旧 incarnation 的连接统一得到 `environmentUnavailable`，不能继续持有 watcher、viewer、attachment 或 root token。目录以同一物理身份恢复后生成新 incarnation；App 重新 prepare 时，Host 可以为仍存活且 Context/Environment identity 匹配的 TerminalSession 发行新 authorization并重新 attach，旧 attachment 本身不会复活。

目录恢复且物理身份、Git common directory 和 Project 子目录全部仍匹配时，Host 以新 incarnation 重新开放 Environment；旧连接不会自动复活，App 必须重新 prepare/attach。

Dirty 判断覆盖完整 Git worktree，不只覆盖 Project 子目录，因为 HEAD 和 index 属于整个 repository worktree。

## 12. Conversation 删除 saga

### 12.1 共同前置

App 先调用只读 `deletionImpact`，取得 preparation ID、相关脏 Document、活动 Shell/Codex/Claude、Environment incarnation，以及 Worktree 模式下的删除 manifest。用户在 operation 开始前完成：

1. Conversation only / Conversation + worktree / Cancel 选择；
2. 每个脏 Document 的保存或丢弃选择；
3. dirty worktree 的二次高风险确认。

Cancel 只存在于 operation 开始前，此时不修改 Document、Terminal、Kernel 或 metadata。App 为 begin 请求生成稳定 WorkspaceOperationID；Host 重新验证 preparation、Document revision、Environment incarnation 和 manifest digest。Begin 在同一个 workspace.sqlite transaction 插入 operation、取得 Conversation/Environment live target claim、把 Conversation 置为 deleting 并写入 lifecycle owner；任何变化或 claim 冲突都在终止 session 前无副作用返回新的 impact。

begin 成功后 Conversation 进入 deleting，不能取消回 active。Host 冻结目标 Context 新操作、执行已确认的 Document 决策、正常终止 sessions；正常终止失败时单独请求 force confirmation。Force 确认通过 `workspace_operation_decisions` durable 记录后才继续；用户不确认时 operation 保持暂停，已经正常退出的 session 不会复活。

### 12.2 仅删除 Conversation

Direct Conversation：删除 Conversation、Context client state 和只属于该 Context 的 viewer 状态；保留共享 Direct Environment。

Worktree Conversation：删除 Conversation、Environment、client state、document metadata 和 recovery data；保留物理 worktree、branch、commit 和文件。

确认框明确告知：保留 worktree 仍占用 branch，Phase 2 无法重新导入该 worktree。

### 12.3 同时删除 worktree

Operation 阶段：

```text
prepared
→ resolvingDocuments
→ terminatingSessions
→ quiescingEnvironment
→ validatingManifest
→ removalAuthorized
→ removingWorktree
→ worktreeRemoved
→ purgingMetadata
→ completed
```

### 12.4 WorktreeDeletionManifest

`git status` 输出只用于 UI 变化分类。物理删除授权绑定版本化 `WorktreeDeletionManifest`，内容至少包括：

- repository/worktree/workspace root identity、Environment incarnation、Git common-directory identity；
- 完整 HEAD OID、branch/detached 状态，以及 canonical `git ls-files --stage -z` 的 SHA-256 index digest；
- canonical porcelain-v2 tracked/untracked/ignored 分类；
- fd-relative、no-follow 遍历得到的每个用户条目：相对路径字节、device/inode/resource identity、类型、mode、uid/gid、BSD flags、link count、size、birth/modify/change metadata；
- regular file 的 SHA-256 内容摘要；
- symlink 的 link-target 字节摘要；
- 每个 regular file、directory 和 symlink 的 canonical ACL 摘要，以及排序后的 extended-attribute name/value SHA-256 摘要；macOS resource fork 作为 extended attribute 覆盖；
- 排序后的目录项摘要。

根目录的已验证 `.git` administrative file 不作为用户内容计入 manifest，由 Git identity 校验单独覆盖。Socket、FIFO、device 等无法稳定内容化的节点使物理删除返回 `unsupportedWorktreeEntry(path, type)`，Phase 2 不 force 删除该 worktree。Ignored directory 必须递归展开；禁止用 `--ignored=matching` 的单一目录记录代替其内容。

Manifest builder 只从已认证的 root directory descriptor 出发。Regular file 通过 fd 打开并在读取内容、ACL 和 xattr 前后执行 `fstat`；directory 通过自身 descriptor 枚举；symlink 使用 no-follow metadata 与 `readlinkat`。同一遍历中 identity 或受摘要保护的 metadata 发生变化时，本次 manifest 无效，不能产生删除授权。

初始确认的 Manifest canonical encoding 与 SHA-256 digest 属于 immutable root intent。Host 在 sessions 已停止、viewer/file operation 已 drain、Kernel 已 quiesce 后，先用 phase CAS 把本次 durable `validationEpoch` 追加到 observation journal，冻结全部 Cockpit admission，再在 repository lock 内重新计算 manifest。每次重新确认或重试都通过新 DecisionID/observation sequence 开始新的 validation epoch，不修改 root request digest：

- digest 与用户确认值相同：原子推进到 `removalAuthorized`；
- digest 不同：operation 保持在 `validatingManifest`，追加本轮 manifest observation 并进入 `awaitingDecision` 子状态，不调用 Git；用户只能以新 DecisionID 确认该 manifest revision，或选择“保留 worktree 并完成 records-only 删除”，不能恢复为 active Conversation。接受新确认后递增 validation round，phase 不回退。

`validationEpoch` 是 Cockpit 删除执行的外部并发边界，不是文件系统锁。epoch 开始前已经完成的变化由最终遍历覆盖；遍历观察到的并发变化使本次验证失败。非 Cockpit 进程与 epoch 同时或之后继续写入属于与删除执行并发的外部操作，Cockpit 不宣称阻止它。`removalAuthorized` 只表示该 epoch 得到了稳定且与用户确认一致的 manifest；进入该阶段后不再接受取消。UI 必须要求用户先停止其他会修改该 worktree 的工具，并明确这条并发边界。

Git locked worktree 直接返回 `worktreeLocked(reason)`。Cockpit 不使用 `--force` 绕过 lock。

脏 worktree 经二次高风险确认后，在新的 `gitMutationEpoch` fresh 验证 common-directory identity，再执行 `git worktree remove --force`。确认文案明确说明 tracked、untracked 和 ignored 本地文件都会被删除，并包含第 7 节的外部 repository 并发边界。

只对 Git 注册和物理身份完全匹配的目标执行删除。禁止使用 `rm -rf` 代替 Git。

Git 删除失败时保留 Cockpit 记录和 operation。恢复选择只有以新 DecisionID 重试物理删除，或以新 DecisionID 保留 worktree 并完成 records-only 删除；不提供恢复为 active Conversation 的“取消”。两条路径都保留 branch。

`removingWorktree` 的 crash recovery 固定为：Git 注册和目标路径都存在且身份匹配时重试同一删除；两者都不存在时把已观察结果 append 到 journal 并 CAS 到 `worktreeRemoved`；只有一方存在、路径被其他对象复用或身份不匹配时进入 `needsAttention`，不删除任何对象。只有 `worktreeRemoved` 或已接受 records-only decision 才能进入 metadata purge。

## 13. Project 移除 saga

Remove Project from Cockpit 覆盖：

- Project Context；
- 全部 Direct/Worktree Conversation；
- 全部相关 Document viewer；
- 全部相关 TerminalSession；
- 全部 Kernel；
- Project settings、client state、metadata 和 recovery data。

脏 Document 必须逐项保存或丢弃。终端先正常终止，失败后单独确认 force。

Project 移除不调用任何 Git worktree 删除，不删除 Project 文件、worktree、branch 或 commit。

确认框明确告知保留 worktree 仍在 Git 中占用 branch，后续由用户在 Cockpit 外管理。

Project 移除不能简单循环现有 Conversation deletion：Project Context 自身的文档和终端也必须纳入同一 impact、reservation 和可恢复 operation。

App 先取得只读 Project removal impact，包含 preparation ID、精确 Project membership revision、全部 Context/Environment ID、Document revision/decision input 和 Terminal impact revision；用户确认后生成稳定 WorkspaceOperationID。Begin 成功的 operation 冻结这组 Project、Context/Environment、Document preparation 和 Terminal impact；重试返回同一 progress/result。该 saga 只删除 Cockpit 记录，任何阶段都不解析物理 worktree 作为删除目标，也不调用 Git remove。

Project removal phase 固定为：

```text
targetsClaimed
→ resolvingDocuments
→ gatingAllContexts
→ terminatingSessions
→ quiescingEnvironments
→ purgingMetadata
→ completed
```

Begin 先取得 Project-scoped admission gate，并为精确 Context 集合取得 DocumentRegistry deletion reservation 与 Supervisor terminal-impact reservation。三者共同冻结新的 Conversation/Settings/Environment/Document/Terminal admission，等待已经进入的创建、Document edit/save/discard/viewer mutation 和 terminal lifecycle operation 全部 drain；reservation 在 fresh impact 读取、比较和跨库 begin protocol 期间持续持有。然后 fresh 读取 workspace/document/terminal impact，并与用户确认的 preparation ID、membership、Document revisions/viewer set 和 Terminal impact revision/session set 完全比较。任一差异时释放全部 reservation、无 durable workspace 变更返回新 impact。

验证一致后，Host 先要求 Supervisor 在 terminal.sqlite 为每个确定性 child ID 写入 prepared gate；全部 prepared durable 后，一个 workspace.sqlite transaction 插入 operation、取得 Project 与精确 membership 中全部 Conversation/Environment claim、把 Project 置为 removing、把全部 Conversation 置为 deleting、给每行写同一个 lifecycle owner，并写入完整 `workspace_operation_contexts`，phase 提交为 `targetsClaimed`。Workspace transaction 失败时 Host 精确撤销 prepared gates；在撤销前崩溃则由启动 reconciliation 处理。

Workspace commit 后，Project/Document reservation 把权威交给 durable removing state；Terminal reservation继续持有，Host 以 context journal promote 全部 prepared child gate到 deleting。每个 promote ack 只更新对应 `workspace_operation_contexts.terminal_gate_phase`；全部 ack durable 后，terminal reservation 才把权威交给 terminal.sqlite gates并释放，父 operation 从 `targetsClaimed` CAS 到 `resolvingDocuments`。Document decisions 全部完成后，父进入 `gatingAllContexts`，该 phase 只聚合验证每个 child gate 已 deleting，再推进 `terminatingSessions`。Host 在 workspace commit 后崩溃时，重启在开放任何 terminal admission 前按 journal补齐/promote gates。每个 child 的 document decision、terminal gate、termination 和 purge 独立 CAS，Host 崩溃后按 journal 精确重放。

## 14. Protocol 1.2

Phase 2 不把一个全局 `.current` 同时用于所有协议族。版本常量拆分为：

```text
HostControlProtocol.current = 1.2
HostDataPlaneProtocol.current = 1.2
TerminalStreamProtocol.current = 1.1
ProtocolFeature.worktreeControl
```

Host data plane 1.2 新增 prepared/active authority oneof、Environment incarnation 和 revocation error；1.1 codec/server 保留原 active-generation contract，两个版本严格独立解码。Terminal/Keeper 在 Phase 2 保持 1.1，因为 PreparedContextToken/incarnation 只存在于 Host/Supervisor ticket registration，不进入 Keeper wire。任何 client、codec、server 和 archive 都禁止从另一个协议族读取全局默认值；未来升级某一协议族时必须单独升级并验证该协议族两端。

Phase 2 不承诺运行旧 Phase 1 App 二进制；App、Host 和本地服务作为同一版本发布。Phase 2 App 始终请求 Host control 1.2。测试客户端可以请求 Host control 1.1，只能调用服务发现、Direct-only snapshot、既有 Direct active data-plane ticket和 Terminal 1.1 方法；Project/Conversation mutation、operation、prepare/commit、capability 和 Worktree 方法全部拒绝。完整 Phase 1 Direct 回归在 Host control 1.2 上运行，同时验证 data-plane 1.2 active authority 与 Terminal 1.1，不依赖 legacy 1.1 mutating command。

Feature 有固定最低 Host control 版本：

| Feature | 最低版本 |
| --- | --- |
| `workspace-control` | 1.1 |
| `terminal-control` | 1.1 |
| `terminal-frames` | 1.1 |
| `host-data-plane` | 1.1 |
| `worktree-control` | 1.2 |

Negotiator 只接受同时满足“客户端请求、服务端支持、negotiated version 不低于 feature 最低版本”的 feature。Command router 再执行同一版本/feature 检查；1.1 客户端即使手工发送字符串 `worktree-control` 也不能协商或执行 Worktree command。

### 14.1 Connection-scoped session

XPC listener 为每条物理连接创建独立 `HostConnectionSession` actor 和 session export，不复用一个全局 export object。状态机固定为：

```text
preHandshake → ready(NegotiatedSession) → invalidated
```

`preHandshake` 只接受一次 handshake；其他方法返回版本无关的 bootstrap envelope `bootstrapFailure(handshakeRequired)`，不返回业务 payload。`ready` 状态保存 connection ID、negotiated Host control version、accepted features 和 peer identity。Connection invalidation 撤销该 connection 的 prepared-context token、未消费 ticket 和 request cache；重连必须重新 handshake。

方法门禁：

- Direct-only snapshot 与既有 Direct active ticket：Host control 1.1 + `workspace-control`；
- Project/Conversation mutation、operation、capability 和 prepare/commit：Host control 1.2 + `workspace-control`；
- Worktree settings/create/delete/refresh：Host control 1.2 + `workspace-control` + `worktree-control`；
- Host data-plane ticket：`host-data-plane`；Direct active authority 可协商 data-plane 1.1/1.2，任何 prepared authority 或 Worktree target 强制 data-plane 1.2；
- terminal lifecycle command：`terminal-control`；
- terminal frame/attach ticket：`terminal-frames`。

每个 Host-control command case 还声明自己的 `minimumHostControlVersion` 和 required feature set，router 从服务端静态表读取，不能信任请求内自报的最低版本。未知 command case 严格解码失败。由此，1.1 connection 不仅不能执行 Worktree command，也不能绕过版本门禁调用 Phase 2 新增的 Direct-capable command。

方法名称门禁之外还执行 resolved-target authorization。1.1 snapshot 不返回 Worktree Context/Environment ID；任何 resolve/client-state/file/data-plane/terminal/archive 请求在发行 capability 前解析真实 target kind。目标是 Worktree 时统一要求 Host control 1.2、`workspace-control` 和 `worktree-control`，授权结论写入 prepared token/ticket，data-plane 与 Supervisor 消费时再次验证。Phase 2 App 不能用 bare Context/Environment UUID 直接调用 Supervisor 的 target command；terminal control/frame/archive 都携带 Host-issued、peer-bound `TargetAuthorization`，Supervisor 验证 target kind、features、incarnation 和 expiry。仅拥有 target UUID 不能绕过门禁。

Host-control RequestContext 和 control envelope codec 使用 connection 保存的 negotiated Host-control version，禁止调用 `.current` 代替实际协商结果。Host data-plane 1.1/1.2 与 Terminal 1.1 codec 分别使用自己的 family version。

### 14.2 Host-control envelopes

Handshake 使用版本无关的最小 `BootstrapResponseEnvelope`，只包含 handshake success 或 `handshakeRequired/duplicateHandshake/versionRejected/peerRejected`。完成 handshake 后，workspace command、data-plane ticket、terminal lifecycle、terminal frame ticket 和 archive capability 方法全部使用同构 envelope：

```text
HostControlRequestEnvelope<Command>
├── protocolVersion
├── connectionID
├── requestID
└── command

HostControlResponseEnvelope<Payload>
├── protocolVersion
├── connectionID
├── requestID
└── result
    ├── success(Payload)
    └── failure(HostControlBusinessError)
```

`WorkspaceResponseEnvelope` 是 payload 为 workspace command result 的类型别名，不是唯一能携带业务失败的方法。Ticket 和 terminal 方法把 capability/ticket metadata 放入 success payload。Archive 方法先返回类型化 archive capability metadata，并只在同一个 success reply sidecar 传递 FileHandle；failure 不传 handle。XPC `NSError` 只表示连接中断、peer validation 或 envelope 编解码失败，不能承载 handshake gate、authorization、target、terminal 或 archive 业务失败。

Capability/ticket issue 的 cached response 保存稳定 capability ID，不复制 side effect；同一 peer/connection 消费同一 capability 是幂等绑定，不同 peer/connection 消费返回 conflict。Handle-bearing response cache 不保存已经交给客户端的 FileHandle：Host 保留经过身份验证的 read-only master FD，每次向同一 RequestID waiter/replay 交付时 `dup` 独立 sidecar；master FD 随 connection cache invalidation 关闭。Archive identity 或 FD 无法再验证时返回 transport/resource failure，不伪造旧 success。

Connection actor 从 negotiated protocol version、command case 和严格 canonical payload 自己计算 request digest，不接受客户端提交的 digest 作为权威。Request cache 状态固定为 `absent | inFlight(digest, waiters) | completed(digest, response)`；actor 在第一次执行任何 `await` 前原子写入 inFlight。并发相同 RequestID/digest 只注册 waiter，不再次进入 router；不同 digest 立即返回 `requestIDConflict`。完成后一次性唤醒 waiters 并转 completed；connection invalidation 使 waiters得到 transport failure。该 cache 只处理传输重放，连接失效后可以丢弃。所有跨重连的变更命令另带客户端生成的 WorkspaceOperationID 或 ContextCommitID，并依赖第 5/9 节的 durable idempotency。

Bookmark 只存在于本地 capability command，不进入 workspace snapshot、Host data plane 或未来 remote domain snapshot。

类型化错误至少包含：

- `projectNotGitRepository`；
- `branchAlreadyCheckedOut(path)`；
- `sourceMoved(expectedOID, actualOID)`；
- `worktreeDirty(manifestDigest)`；
- `worktreeManifestChanged(expectedDigest, actualDigest)`；
- `worktreeLocked(reason)`；
- `environmentUnavailable(path, reason)`；
- `authorizationExpired`；
- `operationNeedsAttention`；
- `contextPreparationFailed`；
- `protocolFeatureNotNegotiated`；
- `protocolVersionInsufficient(required, negotiated)`；
- `targetRequiresWorktreeControl(contextID, environmentID)`；
- `idempotencyConflict`；
- `requestIDConflict`；
- `contextCommitConflict`；
- `contextRecoveryEpochStale(expected, actual)`；
- `superseded(currentContextCommitID)`；
- `operationTargetBusy(operationID)`；
- `decisionConflict(decisionID)`；
- `unsupportedWorktreeEntry(path, type)`；
- `branchRetained(ref, oid)`。

每个 business error 的 Codable case 明确定义字段、是否可重试、是否需要用户重新确认，以及关联 WorkspaceOperationID/ContextCommitID。未知 case 按严格解码失败处理，不降级成另一种业务错误。Host 服务、Git、授权、状态冲突和 operation 失败全部通过 `failure(HostControlBusinessError)` 返回，并原样回显 RequestID。

## 15. 路径与授权安全

- App 通过 NSOpenPanel 获取 Project、storage parent 和 Git root bookmark；
- Host 导入 bookmark，绑定 stable capability identity，并追加不可变 grant version；
- 生成目标必须是已授权 storage parent 的直接子目录；
- 创建目标必须使用第 7.1 节的 fd-relative 原子 reservation，禁止退回 `lstat` 后按字符串路径创建；
- 创建后 canonicalize 并验证 descendant relationship、物理身份和 Git 注册；
- Project 子目录通过已持久化相对路径映射，不接受客户端提交任意绝对 child path；
- 既有 Worktree 和 operation 只使用自己冻结的 stable capability，不跟随 Project Settings 指针；
- 删除前验证 target identity、Environment incarnation 和完整 WorktreeDeletionManifest；
- 无法证明目录属于 operation 时不 signal、不删除并进入 `needsAttention`；
- Kernel、prepared token 和 operation 都释放引用后才终止对应安全作用域访问并允许回收 capability/grant versions。

## 16. UI 行为

### Sidebar

- 同时展示多个 Project；
- Project 行内菜单包含 New Conversation、Project Settings、Remove Project；
- Conversation 展示 Direct、branch 或 Detached HEAD；
- Unavailable 项保留原位置并显示警告；
- Worktree 分支/HEAD 变化后刷新副标题。

### New Conversation sheet

- Direct/New Branch/Existing Branch segmented control；
- 标题和目标目录摘要；
- New Branch 展示 branch、Start From 和 dirty source warning；
- Existing Branch 展示 local branch 与确认时 tip OID，不展示 Start From；
- branch occupied disabled row 和 existing path；
- Project 非 Git 时禁用 Worktree 模式并展示明确原因。

### 删除确认

- Worktree Conversation：Conversation only / Conversation + worktree / Cancel；
- dirty worktree 的二次确认展示变化分类、准确路径和 manifest 摘要；
- operation 开始后的 manifest 变化只提供“确认新 manifest”或“保留 worktree 并完成 records-only 删除”，不显示可恢复 active Conversation 的 Cancel；
- Project removal 展示将移除的 Conversation、脏文档和活动终端，并明确物理数据全部保留。

## 17. 验收与门禁

新增 `Tools/verify-phase2.zsh`，包含完整 Phase 1 unified gate，并按首错停止。

必须覆盖：

1. 多 Project 创建、恢复和独立不可用状态；
2. Direct 与多个 Worktree 的文件、DocumentID、TerminalSession 和 client state 隔离；
3. Git 子目录 Project 的 worktree 根/workspace 根映射；
4. 同一 Git common directory 下多个 Project 的串行化；
5. Worktree 设置未完成时两个 current capability 可为空，但创建 operation 在缺少任一必要 capability 时 fail closed；
6. Project Settings 切换 storage capability 后，旧 Worktree 仍使用冻结 capability，未来 Worktree 使用新 capability；
7. stale bookmark 只能给同一 stable capability 追加同身份 grant version，既有 Environment/operation intent 不改写；
8. capability 被 settings/Environment/operation 引用时不能回收，最后引用释放后停止 security scope；
9. New Branch 使用 Start From full OID；Existing Branch 不接收 Start From 并绑定 selected branch tip；
10. Existing Branch 从 full `refs/heads/...` 派生 canonical short argv，创建后仍是该 branch 而非 Detached HEAD；
11. 已占用分支禁用和路径展示；
12. source OID 或 Existing Branch tip 在确认后变化；
13. Direct/New/Existing 使用相同 operation ID 的串行/并发重试返回同一 Conversation/Environment/result，不同 canonical intent 被拒绝；
14. 两个删除 operation 或 Project removal 与 descendant operation 竞争时只有一个取得 durable target owner；
15. Project impact 后、begin 前新增 Conversation/Document/Terminal 或在途 edit/save/lifecycle 完成时，Project+Document+Terminal reservation drain 后 fresh compare 返回新 impact；terminal prepared gates→workspace targetsClaimed→terminal deleting gates的跨库恢复始终阻断旧授权消费；
16. 创建 saga 每个阶段的 Host crash recovery，包括 branch 已创建但 worktree 未完成；
17. 系统 Git 接受 operation-owned 预创建空目录，runner 通过 authenticated directory FD 把 child cwd 绑定该对象，target argv 固定为 `.`；
18. 外部进程在 reservation 前后创建、替换、重命名或写入目标 pathname 时 fail closed；common directory 在 gitMutationEpoch 前变化时拒绝，epoch 同时/之后变化时进入 needsAttention；两者都不自动删除未知路径、repo 或 branch；
19. 无法证明身份时进入 `needsAttention` 且不删除路径或 branch；
20. Git timeout/cancel 后 initial authenticated Git PGID 无成员、direct child 已 waitpid；通过 setpgid/setsid 离开 initial PGID 的 hook 后代被明确归类为外部行为；
21. dirty、tracked、untracked、ignored 和 locked worktree 删除；
22. 同一路径文件只改变内容、metadata、ACL、xattr 或 resource fork 时，旧 manifest 确认失效；
23. ignored directory 被递归内容化，symlink 被 no-follow 摘要，特殊文件节点阻止 force 删除；
24. manifest 在 quiesce 后、validation epoch 前变化时不调用 Git；遍历观察到并发变化时验证失败，并只提供重新确认或 records-only；
25. Git 已删除 worktree 但 phase 未提交时，从“注册与路径都不存在”恢复到 `worktreeRemoved`；单边存在时进入 needsAttention；
26. manifest reconfirm、records-only 和 force confirmation 使用 append-only stable DecisionID，XPC reply 丢失后精确 replay；
27. Conversation only、Conversation + worktree 的稳定 operation replay 与物理数据结果；
28. Project removal 先 durable gate 全部 Context child，再终止任何 session，并始终 records-only；
29. 完成删除后 operation tombstone 直到明确开发数据重置前始终返回原 result，不被领域 FK cascade 删除；
30. 丢失 Project 不影响其他 Project；
31. 丢失 Worktree 不影响同 Project 其他 Context；
32. `git switch` 和 Detached HEAD 刷新；
33. Available → Unavailable 主动关闭旧 incarnation 的 UDS child、remove viewer、detach terminal attachment，再 drain operation 与 unregister Kernel；恢复后仅新 authorization 可重新 attach 存活 session；
34. ActiveContext prepare 失败/取消时旧 ActiveContext、Monaco、file tree 和 terminal controller 完全不变；
35. Host data-plane 1.2 prepared generation 能读取目标 data plane；durable promotion 后 data-plane frame ack、viewer owner 和 Supervisor journal 全部 handoff 到 active authority，1.1 decoder 严格拒绝 prepared binding；
36. live terminal attach、finalized terminal archive 和无 archive 终态分别达到确定 readiness，Keeper wire 保持 1.1；
37. Prepare 后、promotion 前外部替换 worktree 时，fresh fd-backed admission resolve 拒绝 commit；
38. SQLite promotion 成功但 reply 丢失时，ContextCommitID 查询区分 committedNeedsChildren/committedReady/committedUnavailable/notCommitted，并通过 recovery epoch/proofs 恢复或 fallback；
39. durable promotion、任一 child handoff、可见交换前后崩溃都从 context commit/child journal 恢复同一 committed Context；旧 recovery epoch 被拒绝；
40. A 已展示、B durable 未展示、C 再取代 B 时，presentationCommitted(C) 原子更新 presented ID 并把 A/B predecessor chain 全部 revoking→released；旧 ID 只返回 superseded且不能发行 ticket；
41. Kernel root identity/incarnation mismatch fail closed；
42. Kernel quiesce 后无 watcher、DocumentRegistry、viewer 或 access token 残留；
43. Host control 1.1 raw 客户端请求 `worktree-control` 时协商和命令路由都拒绝；
44. Host control 1.1 raw 客户端调用最低版本 1.2 command 或以 UUID 访问 Worktree target 时拒绝且 snapshot 不泄露该 target；
45. Host control 1.2、Host data-plane 1.2/1.1 和 Terminal 1.1 独立协商工作，禁止全局 version 漂移；
46. 每条 XPC connection 在 handshake 前只能收到 bootstrap envelope，重连后旧 session 不能复用；
47. workspace、ticket、terminal 和 archive 方法逐项执行版本、feature 与 resolved-target gate；
48. 所有 Host-control 方法的 success/failure envelope 原样回显 RequestID，archive failure 不传 handle，业务错误不压成通用 NSError；
49. 并发重复 RequestID 在 `inFlight` 状态只执行一次，相同 digest共享结果、冲突 digest 被拒绝；
50. App、Host、Supervisor 和 Keeper 在各 saga/prepare phase 崩溃后的确定恢复；
51. 开发数据重置只清理 Cockpit 自有数据，不触碰 Project、Git、worktree、branch 或文件；
52. 单主窗口恢复稳定 WindowID，不创建第二个 window navigation owner；
53. 完整 Phase 1 Direct、文件、Monaco 和 terminal 回归。

## 18. 实施顺序约束

实施计划必须按照依赖顺序拆分：

1. 新 schema baseline、stable capability/grant version、operation target owner、append-only journal、tombstone retention 与 durable idempotency；
2. Host control/data-plane/terminal 协议族版本拆分与 feature/command minimum-version matrix；
3. connection-scoped Host session、bootstrap/control envelopes、in-flight request gate 和 resolved-target authorization；
4. EnvironmentRootResolver、incarnation 与 Kernel identity/lifecycle；
5. 多 Project snapshot 和 availability transition；
6. bounded Git runner、repository coordinator、fd-bound child cwd 和 target reservation；
7. Project Settings 与 stable capability/grant-version 生命周期；
8. Worktree creation saga 与完整 crash/replay recovery；
9. PreparedContextToken、context commit/child journal 和 prepared data-plane binding；
10. staged Monaco/FileTree/Terminal presentation、child authority handoff 与 durable commit；
11. WorktreeDeletionManifest 和 Conversation deletion saga；
12. Project removal parent/child journal saga；
13. 外部 Git refresh/unavailable 与旧 incarnation 撤销；
14. UI 收尾与统一 Phase 2 gate。

任何阶段不得先用 Project root 代替 Worktree root，不得从 current settings 解析旧 Worktree，不得先提交 UI Context 再补资源，不得让 Host control 版本隐式升级 data-plane/terminal，不得用 status path 列表代替内容 manifest，不得用通用 NSError、裸字符串路径或 `rm -rf` 绕过已确认边界。
