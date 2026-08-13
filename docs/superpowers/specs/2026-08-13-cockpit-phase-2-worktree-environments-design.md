# Cockpit Phase 2：多 Project 与 Worktree Environment 设计

日期：2026-08-13

状态：已确认

目标版本：Protocol 1.2

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
- 自动移动既有 worktree。

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

标题和分支名是两个独立可编辑字段。

新分支默认名称为标题 slug。发生冲突时依次追加 `-2`、`-3`。不增加 `cockpit/` 前缀。

Worktree 目录名固定为：

```text
<branch-slug>-<ConversationID 前 8 位>
```

Conversation 重命名不移动 worktree。

`Start From` 列出：

- Project 的 Direct Environment；
- 该 Project 下全部 Worktree Conversation；
- 每项展示 branch 或 Detached HEAD，以及短 OID。

来源 worktree 有未提交内容时允许继续，但必须明确提示未提交内容不会复制。创建意图冻结来源的完整 OID。

`Existing Branch` 只列本地分支。已经被另一个 worktree checkout 的分支显示为禁用，并展示现有 worktree 路径。

### 2.2 Project Worktree 设置

Project 行内菜单提供 `Project Settings…`，打开原生 sheet。

每个 Project 独立配置 Worktree 存储父目录。未配置时，首次创建 Worktree Conversation 打开目录选择器；取消选择就取消创建。

Project 选择的是 Git 仓库子目录时，首次创建 Worktree Conversation 额外要求确认检测到的 Git repository root，并保存 Git 根 bookmark。

修改设置只影响未来 worktree，不移动既有 worktree。

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
created_at
```

#### project_worktree_settings

```text
project_id
storage_parent_bookmark
storage_parent_identity
git_root_bookmark
git_root_identity
project_relative_path
updated_at
```

`project_relative_path` 表示 Project 根相对 Git repository root 的路径。仓库根 Project 使用空相对路径。

#### environments

```text
id
project_id
kind: direct | worktree
workspace_root_path
workspace_root_identity
availability_state
availability_reason
created_at
```

#### worktree_environments

```text
environment_id
conversation_id UNIQUE
worktree_root_path
worktree_root_identity
git_common_directory_path
git_common_directory_identity
head_kind: branch | detached
head_ref
head_oid
last_verified_at
```

Git worktree 根供 Git 管理；`workspace_root_path` 是进入 Project 子目录后的 Cockpit 文件、文档和终端根。

#### conversations

```text
id
project_id
environment_id
title
lifecycle_state
created_at
```

外键只要求 Environment 属于同一 Project。Direct Environment 可被多个 Direct Conversation 共享；Worktree Environment 只能归属于一个 Worktree Conversation。

#### workspace_operations

```text
id
kind
project_id
conversation_id
environment_id
repository_identity
phase
intent_json
observed_state_json
last_error_json
created_at
updated_at
```

`intent_json` 使用严格版本化 Codable 结构，不保存任意 shell 命令。

#### client_window_navigation

```text
device_id
window_id
last_context_kind
last_context_id
updated_at
```

这里只保存最后一次成功 commit 的 Context。

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
└── accessTokens
```

Direct Environment 从 Project bookmark 恢复能力。Worktree Environment 从存储父目录和 Git 根 bookmark 恢复能力，然后验证已持久化物理身份。

Resolver 每次返回前验证：

- 路径存在且是目录；
- canonical path 和资源身份一致；
- Worktree 仍注册在预期 Git common directory；
- Project 子目录仍映射到同一物理目录；
- 当前 branch/Detached HEAD 和完整 OID 可读取。

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
- 取消时只终止本次认证过的 Git process group；
- 返回 argv、退出状态、stdout、stderr 和 timeout/cancel 分类；
- 用户 Git hooks 按 Git 标准行为执行并受同一超时控制。

机器读取使用：

- `git worktree list --porcelain -z`；
- `git for-each-ref` 的机器格式；
- `git status --porcelain=v2 -z --untracked-files=all --ignored=matching`；
- `git rev-parse` 获取完整 OID 和 common directory。

UI 中的 branch 可用性只是快照。Host 在仓库锁内再次验证分支占用和来源 OID。

## 8. Worktree 创建 saga

### 8.1 准备

App 提交标题、模式、来源 Environment、branch、storage bookmark 和必要 Git root bookmark。

Host：

1. 验证 Project 和授权；
2. 解析来源真实 worktree；
3. 读取完整 source OID；
4. 检查来源 dirty 状态并返回显式确认要求；
5. 生成 ConversationID、EnvironmentID 和目标目录；
6. 写入 `prepared` operation。

Operation 冻结：

- source EnvironmentID；
- source full OID；
- new/existing branch 模式；
- branch ref；
- storage parent identity；
- target absolute path；
- Project relative path；
- ConversationID；
- EnvironmentID。

### 8.2 Git 变更与提交

在 repository lock 内：

1. 重新验证 source OID；
2. 重新验证 branch 是否被其他 worktree 占用；
3. 通过 `lstat` 验证目标路径不存在且不是符号链接；
4. 更新 operation 为 `gitRunning`；
5. 执行 `git worktree add`；
6. 校验目标 worktree 的物理身份、Git 注册、common directory 和 OID；
7. 验证 Project 子目录存在并取得 workspace root identity；
8. 更新 operation 为 `gitAdded`；
9. 一个 SQLite 事务写入 Environment、WorktreeEnvironment、Conversation 和 `metadataCommitted`；
10. 标记 `completed`。

来源 OID 变化时返回 `sourceMoved(expectedOID, actualOID)`，不从新 OID 静默创建。

### 8.3 崩溃恢复

Host 启动扫描未完成 operation：

- 未发生 Git 变更：标记失败，不产生 Conversation；
- worktree 已创建且全部身份与 intent 完全一致：继续数据库提交；
- Cockpit 本次创建的 worktree 身份完全匹配：允许补偿移除 worktree；
- 任一身份无法证明：不删除路径，标记 `needsAttention`。

补偿永远不删除 branch。

## 9. ActiveContext 两阶段切换

### 9.1 Prepare

`ActiveContextController` 增加不可见的 prepare token。Prepare 不改变 current Context 或 generation。

Prepare 同时完成：

- resolve target Context；
- 验证 Environment availability；
- 获取或准备 WorkspaceKernel；
- 加载 ClientWorkspaceState；
- 取得文件树首帧；
- 恢复 tabs；
- 恢复选中文档并确认 Monaco 接受；或
- 等待选中 TerminalTab 的真实 attach 和首帧。

所有异步结果都绑定 selection request generation 和 prepare token。

### 9.2 Commit

MainActor 在一个同步提交中更新：

- ActiveContext；
- ActiveContextGeneration；
- tabs；
- selectedTab；
- content controller；
- file tree binding；
- sidebar selection。

提交成功后保存 `client_window_navigation`。

Prepare 失败或被新选择取消时，释放 staged resource，旧 Context 保持权威且 UI 不变。

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

Dirty 判断覆盖完整 Git worktree，不只覆盖 Project 子目录，因为 HEAD 和 index 属于整个 repository worktree。

## 12. Conversation 删除 saga

### 12.1 共同前置

删除 operation 先：

1. 冻结目标 Context 新操作；
2. 收集全部相关脏 Document；
3. 逐项保存或丢弃；
4. 列出活动 Shell、Codex、Claude；
5. 正常终止；
6. 对失败会话单独请求强制终止确认；
7. 等待 viewer 和 file operation 清空；
8. quiesce 并逐出 Kernel。

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
→ validatingWorktree
→ removingWorktree
→ purgingMetadata
→ completed
```

在 repository lock 内重新计算包含 tracked、untracked 和 ignored 文件的 status fingerprint。

用户的强制删除确认绑定该 fingerprint。确认后状态变化则返回 `worktreeStatusChanged` 并要求重新确认。

Git locked worktree 直接返回 `worktreeLocked(reason)`。Cockpit 不使用 `--force` 绕过 lock。

脏 worktree 经二次高风险确认后执行 `git worktree remove --force`。确认文案明确说明 tracked、untracked 和 ignored 本地文件都会被删除。

只对 Git 注册和物理身份完全匹配的目标执行删除。禁止使用 `rm -rf` 代替 Git。

Git 删除失败时保留 Cockpit 记录和 operation，供恢复或取消。

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

## 14. Protocol 1.2

新增：

```text
ProtocolVersion.current = 1.2
ProtocolFeature.worktreeControl
```

XPC listener 为每条连接创建独立 session export。连接必须完成 handshake，才能执行 workspace command。

Phase 2 workspace request envelope 携带：

- protocol version；
- connection/session identity；
- RequestID；
- command payload。

未协商 `worktree-control` 的连接不能执行 Worktree 命令。

Bookmark 只存在于本地 capability command，不进入 workspace snapshot、Host data plane 或未来 remote domain snapshot。

类型化错误至少包含：

- `projectNotGitRepository`；
- `branchAlreadyCheckedOut(path)`；
- `sourceMoved(expectedOID, actualOID)`；
- `worktreeDirty(fingerprint)`；
- `worktreeStatusChanged`；
- `worktreeLocked(reason)`；
- `environmentUnavailable(path, reason)`；
- `authorizationExpired`；
- `operationNeedsAttention`；
- `contextPreparationFailed`；
- `protocolFeatureNotNegotiated`。

XPC transport error 只表示连接或编码失败。业务失败通过 Codable response 返回。

## 15. 路径与授权安全

- App 通过 NSOpenPanel 获取 Project、storage parent 和 Git root bookmark；
- Host 导入并持久化 bookmark；
- 生成目标必须是已授权 storage parent 的直接子目录；
- 创建前使用 `lstat` 拒绝现有路径和符号链接；
- 创建后 canonicalize 并验证 descendant relationship、物理身份和 Git 注册；
- Project 子目录通过已持久化相对路径映射，不接受客户端提交任意绝对 child path；
- 删除前再次验证 target identity；
- 无法证明目录属于 operation 时不 signal、不删除并进入 `needsAttention`；
- Kernel 释放后终止对应安全作用域访问令牌。

## 16. UI 行为

### Sidebar

- 同时展示多个 Project；
- Project 行内菜单包含 New Conversation、Project Settings、Remove Project；
- Conversation 展示 Direct、branch 或 Detached HEAD；
- Unavailable 项保留原位置并显示警告；
- Worktree 分支/HEAD 变化后刷新副标题。

### New Conversation sheet

- Direct/New Branch/Existing Branch segmented control；
- 标题、branch、Start From、目标目录摘要；
- dirty source warning；
- branch occupied disabled row 和 existing path；
- Project 非 Git 时禁用 Worktree 模式并展示明确原因。

### 删除确认

- Worktree Conversation：Conversation only / Conversation + worktree / Cancel；
- dirty worktree 的二次确认展示变化分类和准确路径；
- Project removal 展示将移除的 Conversation、脏文档和活动终端，并明确物理数据全部保留。

## 17. 验收与门禁

新增 `Tools/verify-phase2.zsh`，包含完整 Phase 1 unified gate，并按首错停止。

必须覆盖：

1. 多 Project 创建、恢复和独立不可用状态；
2. Direct 与多个 Worktree 的文件、DocumentID、TerminalSession 和 client state 隔离；
3. Git 子目录 Project 的 worktree 根/workspace 根映射；
4. 同一 Git common directory 下多个 Project 的串行化；
5. New Branch 和 Existing Branch；
6. 已占用分支禁用和路径展示；
7. source OID 在确认后变化；
8. 创建 saga 每个阶段的 Host crash recovery；
9. 无法证明身份时进入 `needsAttention` 且不删除路径；
10. dirty、untracked、ignored 和 locked worktree 删除；
11. status fingerprint 变化使旧确认失效；
12. Conversation only、Conversation + worktree、Project records-only；
13. Project Context 的文档和终端纳入 Project removal；
14. 丢失 Project 不影响其他 Project；
15. 丢失 Worktree 不影响同 Project 其他 Context；
16. `git switch` 和 Detached HEAD 刷新；
17. ActiveContext prepare 失败时旧 Context 完全不变；
18. terminal attach 失败时不 commit；
19. Kernel root identity mismatch fail closed；
20. Kernel quiesce 后无 watcher、DocumentRegistry 或 access token 残留；
21. Protocol 1.1 客户端无法执行 Worktree command；
22. 类型化业务错误不被压成通用 NSError；
23. Git timeout/cancel 不残留子进程；
24. App、Host、Supervisor 和 Keeper 崩溃恢复；
25. 完整 Phase 1 Direct、文件、Monaco 和 terminal 回归。

## 18. 实施顺序约束

实施计划必须按照依赖顺序拆分：

1. 新 schema baseline 和严格模型；
2. Protocol 1.2 与 connection-scoped workspace envelope；
3. EnvironmentRootResolver 与 Kernel identity/lifecycle；
4. 多 Project snapshot 和 availability；
5. bounded Git runner 和 repository coordinator；
6. Project Settings 与 bookmarks；
7. Worktree creation saga；
8. ActiveContext prepare/commit；
9. Conversation deletion saga 扩展；
10. Project removal saga；
11. 外部 Git refresh/unavailable；
12. UI 收尾与统一 Phase 2 gate。

任何阶段不得先用 Project root 代替 Worktree root，不得先提交 UI Context 再补资源，不得用通用 NSError 或 `rm -rf` 绕过已确认边界。
