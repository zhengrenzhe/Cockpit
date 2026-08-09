# Cockpit Phase 1 本地 Direct Workspace 垂直切片设计

- 状态：已逐节批准
- 日期：2026-08-06
- 前置阶段：Phase 0 已完成
- 首要约束：高性能与稳定性
- 实现状态：本文只定义设计，不声明实现已经存在

## 1. 目标

Phase 1 交付一个可独立使用的原生 macOS 开发环境垂直切片：用户添加一个物理项目目录后，无需创建 Conversation，即可浏览和编辑文件、管理文件并运行 Shell 或 Agent CLI；用户还可以在同一个 Project 下创建多个 Direct Conversation，把多个 Agent CLI 组织成独立开发任务。

Phase 1 固定以下产品语义：

- Project 是用户选择的固定物理目录。
- Project 本身是完整、可选择的 IDE 工作上下文。
- Project 可以不包含任何 Conversation。
- Conversation 是开发任务的组织容器，不是 PTY、页签或单个 Agent 进程。
- 一个 Conversation 可以包含多个互相独立的 Shell、Codex 和 Claude TerminalSession。
- Project Context 与全部 Direct Conversation 使用同一个物理项目目录和同一个 Direct Environment。
- 页签和终端按 WorkspaceContext 隔离；文件、文档、文件树及后续 Git/LSP 服务按 Environment 共享。
- Phase 1 只交付本地 Direct Environment；Worktree 与远程客户端保留协议边界，不在本阶段实现。

## 2. Phase 1 范围

### 2.1 包含

- 一个 Project、零到多个 Direct Conversation。
- 始终可选择的 Project Context。
- 每台设备、每个窗口、每个 WorkspaceContext 独立保存的页签与界面状态。
- AppKit 三栏窗口、原生页签和新建页签选择器。
- 延迟加载文件树。
- 新建文件与文件夹、重命名、项目内移动及删除到 macOS 废纸篓。
- UTF-8 与 UTF-8 BOM 文件的打开、编辑、恢复和原子保存。
- 每窗口一个隔离的 Monaco WKWebView 运行时。
- 普通 Shell、Codex 和 Claude 专用 Agent CLI 页签。
- 一个 Conversation 中多个独立 Agent CLI。
- Ghostty Metal 终端渲染、每 TerminalSession 一个 PTYKeeper、App 退出后继续运行及重连。
- Conversation 手动重命名。
- Conversation 可恢复删除状态机。

### 2.2 不包含

- 多 Project。
- Worktree Environment。
- 文件搜索、内容搜索、Git、Diff 和 Git Toolbox。
- LSP、语义 Token、格式化、代码重命名和 Code Action。
- Agent 结构化对话适配与自动标题。
- 通用 Agent Profile 配置器、插件系统和自定义命令 UI。
- 多设备远程连接。
- 多客户端同时编辑同一文档。
- 非 UTF-8 编码选择与转换。
- 自动保存。
- Project 删除和 Conversation 归档。

用户已经批准三项相对原交付顺序的范围调整：

| 调整 | 新增实施任务 | 工期预算 |
|---|---:|---:|
| 一个 Project 下支持多个 Direct Conversation | 1 | 1 个研发日 |
| 基础文件管理 | 3 | 3 个研发日 |
| 删除 Conversation | 2 | 2 个研发日 |
| 合计 | 6 | 6 个研发日 |

以上调整不增加第三方依赖。

## 3. 核心身份与资源归属

### 3.1 Project

```text
Project
- ProjectID
- displayName
- rootBookmark
- canonicalRootIdentity
- baseEnvironmentID
- createdAt
```

Project 表示一个固定物理目录。`baseEnvironmentID` 指向该目录唯一的 Direct Environment。

### 3.2 Conversation

```text
Conversation
- ConversationID
- ProjectID
- EnvironmentID
- title
- lifecycleState: active | deleting(phase)
- deletionOperationID?
- createdAt
```

创建 Conversation 时标题固定为“新任务”，用户可以手动重命名。基于 Agent 对话生成和更新标题属于后续独立 Agent Integration 设计。

Conversation 不再包含以下字段：

- `agentProfile`
- `primaryTerminalSessionID`
- `tabRecords`

Agent Profile 属于单个 TerminalSession 的 LaunchSpec；页签属于设备和 WorkspaceContext 的客户端状态。

### 3.3 WorkspaceContext

WorkspaceContext 是统一的产品上下文身份，ProjectContext 与 ConversationContext 是它的两个变体，不建立额外数据库实体：

```swift
enum WorkspaceContextID {
    case project(ProjectID)
    case conversation(ConversationID)
}
```

解析后的值为：

```text
ResolvedWorkspaceContext
- WorkspaceContextID
- ProjectID
- ConversationID?
- EnvironmentID
- WorkspaceRootIdentity
```

### 3.4 Environment

```text
Environment
- EnvironmentID
- ProjectID
- kind: direct | worktree
- workspaceRoot
- workspaceRootIdentity
- gitCommonDirectory
- worktreeBranch?
```

一个规范化物理工作目录对应一个 EnvironmentID。Phase 1 中：

```text
Project A /repo
│
└── Direct Environment E0 /repo
    ├── ProjectContext        -> E0
    ├── Direct Conversation A -> E0
    └── Direct Conversation B -> E0
```

需要物理隔离的 Conversation 在 Phase 2 绑定独立 Worktree Environment。

### 3.5 TerminalSession

```text
TerminalSession
- TerminalSessionID
- WorkspaceContextID
- EnvironmentID
- kind: shell | agent
- launchSpec
- workerInstanceID
- keeperProcessIdentifier
- cliProcessIdentifier
- lifecycleState
- protocolVersion
- latestSequence
```

TerminalSession 不再要求 ConversationID。Project Context 可以直接拥有 Shell 和 Agent CLI。

### 3.6 DocumentSession

```text
DocumentSession
- DocumentID
- EnvironmentID
- relativePath
- documentVersion
- persistedVersion
- dirtyState
- editLease
```

`EnvironmentID + normalized RelativePath` 是唯一文件定位键，`DocumentID` 是稳定身份。Cockpit 内发起重命名或移动时保持 DocumentID 不变，并原子更新路径以及所有页签引用。

### 3.7 资源归属矩阵

| 资源 | 权威归属键 |
|---|---|
| 文件、DocumentSession、文件树、后续搜索/Git/LSP | EnvironmentID |
| 页签布局、Shell、Agent CLI | WorkspaceContextID |
| Conversation 标题、生命周期和任务组织 | ConversationID |
| 设备布局 | DeviceID + WindowID + WorkspaceContextID |
| 当前选择及异步界面结果 | ClientInstanceID + WindowID + ActiveContextGeneration |

## 4. ActiveContext 与切换

选择 Project：

```text
WorkspaceContextID.project(ProjectID)
-> Project.baseEnvironmentID
```

选择 Direct Conversation：

```text
WorkspaceContextID.conversation(ConversationID)
-> Conversation.environmentID
```

每次选择产生新的 `ActiveContextGeneration`：

```text
ActiveContext
- WorkspaceContextID
- ProjectID
- ConversationID?
- EnvironmentID
- WorkspaceRootIdentity
- generation
```

Generation 是客户端窗口内单调递增的选择版本，不写入数据库。所有面向当前界面的异步请求与事件都回传 generation；客户端只应用当前 generation 的结果。

该规则处理以下竞态：

```text
A(generation 17) -> B(18) -> A(19)
```

即使 generation 17 与 19 拥有相同 WorkspaceContextID，17 的迟到结果也不会覆盖当前界面。

切换 Project Context 和 Direct Conversation 时 EnvironmentID 不变，因此 WorkspaceKernel、文件监听、文件树、DocumentSession 以及后续 Git/LSP 实例保持复用。客户端只切换 Context 自己的页签、终端附件和界面状态。

## 5. 客户端状态与远程预留

```text
ClientWorkspaceState
- DeviceID
- WindowID
- WorkspaceContextID
- tabRecords
- selectedTabID
- sidebarState
- splitViewState
```

- 同一台 Mac 重启 App 后恢复自己的页签布局。
- 后续远程设备拥有自己的布局，不会重排 Mac 窗口。
- TerminalSession、Conversation 和 DocumentSession 是跨设备领域状态。
- 关闭终端页签只断开该设备的查看端，不改变 TerminalSession 生命周期。
- 同一文件在多个 Context 打开时共享 DocumentSession，但分别保存光标、选区和滚动位置。

同一 DocumentSession 同时只有一个可写客户端：

```text
EditLeaseID + documentVersion + clientSequence
```

其他客户端实时查看且处于只读状态，用户可以明确转移编辑租约。Phase 1 只有本地客户端，但协议从第一天携带租约字段；不引入 CRDT 或 OT。

## 6. 原生 UI

Phase 1 继续使用 Phase 0 已建立的 AppKit 应用：

```text
NSWindow
└── NSSplitViewController
    ├── 左栏：NSOutlineView
    ├── 中央：NSCollectionView Tab Strip + Content Host
    └── 右栏：工具选择区 + NSOutlineView 文件树
```

### 6.1 左栏

- Project 行始终可选中。
- Conversation 是 Project 的子节点。
- Phase 1 展示零到多个 Direct Conversation。
- 新建和重命名 Conversation 使用原生 AppKit 控件。
- 当前选中项直接确定 WorkspaceContextID。

### 6.2 中央区域

- 原生 Tab Strip 展示文件、普通 Shell、Codex、Claude 和新建页签。
- 每个窗口只有一个 Monaco WKWebView；文件页签切换当前 text model。
- 终端页签展示 Ghostty Metal NSView。
- 非活动终端停止 Metal 帧渲染；Keeper 继续排空 PTY 并维护权威 VT 状态。
- 新建页签选择器可以重新连接当前 Context 中已脱离页签但仍在运行的 TerminalSession。

### 6.3 右栏

- Phase 1 只启用文件树。
- 文件树从 ActiveContext.EnvironmentID 解析根目录。
- Project Context 与全部 Direct Conversation 复用同一文件树 Provider。
- 搜索、Git 和 Diff 不创建占位实现。

Phase 1 交付一个主窗口。状态模型保留 WindowID，后续增加多窗口时不改变领域协议。

## 7. Project、Conversation 与页签生命周期

### 7.1 添加 Project

1. 用户选择物理目录。
2. Host 在一个 workspace.sqlite 事务中创建 Project 和唯一 Direct Environment。
3. App 自动选中 Project Context。
4. 不创建 Conversation，不自动打开终端。

Project Context 立即提供文件树、编辑器、新建 Shell 和新建 Agent CLI。

### 7.2 创建 Conversation

1. 用户在 Project 下创建 Conversation。
2. 用户选择 Codex 或 Claude。
3. Host 持久化标题为“新任务”的 Direct Conversation。
4. App 自动选中新 Conversation。
5. App 请求创建首个独立 Agent TerminalSession，并打开对应页签。
6. Agent 启动失败时保留 Conversation；页签显示真实错误并提供重试或切换 Agent。

Conversation 与首个 Agent 不执行跨数据库事务。Conversation 是任务身份，Agent 进程失败不回滚任务。

### 7.3 新建页签

Project Context 和 Conversation Context 均支持：

- 打开文件。
- 新建普通 Shell。
- 新建 Codex。
- 新建 Claude。
- 重新连接当前 Context 中已存在的 TerminalSession。

每次新建 Shell 或 Agent 都创建新的 TerminalSession。用户在普通 Shell 中手动执行 codex 或 claude 时，TerminalSession 继续记录为 shell，Cockpit 不猜测子进程语义。

### 7.4 关闭页签

- 关闭终端页签只断开查看端，不终止进程。
- 终止会话必须执行明确命令。
- Agent 自然退出后 TerminalSession 进入 Exited，页签保留退出码和最后画面。
- 关闭文件页签只关闭该设备和 Context 的编辑视图。
- 最后一个文件视图关闭且文档为 dirty 时，显示保存、放弃和取消。

## 8. Shell 与 Agent 启动

Phase 1 内建两个 Agent Profile：Codex 与 Claude。普通 Shell 可以运行任意其他 CLI；Phase 1 不实现通用 Profile 编辑器。

```text
LaunchSpec
- TerminalSessionID
- WorkspaceContextID
- EnvironmentID
- kind: shell | agent(profileID)
- loginShellPath
- executablePath
- arguments
- workspaceRoot
- terminalSize
- environmentOverrides
```

启动规则：

- 普通 Shell 在 Environment.workspaceRoot 启动用户登录 Shell。
- 首次使用 Codex 或 Claude 时，通过用户登录 Shell 解析可执行文件绝对路径并保存；解析失败时要求用户选择可执行文件。
- 每次启动前验证路径存在且可执行。
- Agent 页签完成登录 Shell 环境初始化后，以结构化参数执行 `exec`，不拼接用户路径或参数字符串。
- 不把完整用户环境或密钥保存到 terminal.sqlite；LaunchSpec 只保存明确的非敏感覆盖项。
- 专用 Agent 退出时 TerminalSession 同步结束，不退回普通 Shell。
- “重新启动”创建新的 TerminalSessionID，并让原页签连接新会话；旧会话保留最终记录，直至 Context 删除。

### 8.1 两阶段创建

```text
Preparing -> Committed -> Running
                           |-> Exited
                           |-> Terminated
                           `-> Interrupted
```

1. Supervisor 分配 TerminalSessionID 与 WorkerInstanceID。
2. 将 Preparing 与 LaunchSpec 写入 terminal.sqlite 并提交。
3. 启动独立 PTYKeeper；Keeper 此时不创建 PTY 或 CLI。
4. Keeper 建立受保护 runtime endpoint 并报告 Ready。
5. Supervisor 持久化 Committed。
6. Supervisor 发送认证后的 Start。
7. Keeper 创建 PTY 和进程组并执行 Shell 或 Agent。
8. Supervisor 持久化 Running。

Committed 之前不启动 CLI；Committed 之后 Supervisor 崩溃，由 launchd 重启后的 Supervisor 完成或对账同一个启动事务。

### 8.2 运行与重连

- 每个 TerminalSession 由一个 Keeper 独占 PTY master、Ghostty VT、scrollback 和输出 sequence。
- Cockpit.app 退出只断开 viewer。
- App 重启连接原 TerminalSession，并通过快照加增量恢复 VT、scrollback 和输入。
- 本地终端数据流从 App 直连 Keeper，不经过 Host 或 Supervisor。
- 每个 TerminalSession 同时只有一个输入租约，允许任意数量只读 viewer。

## 9. 编辑器与文件系统

### 9.1 Monaco 边界

- EditorRuntime 是应用唯一使用 Web 技术的区域。
- 每个窗口一个 WKWebView 和 Monaco 运行时。
- 多个 Monaco text model 共享运行时。
- 不为每个文件创建 WKWebView。
- 不使用 React、Electron、本地 HTTP Server 或浏览器路由。
- 资源从签名后的 App Bundle 加载。

Monaco 是低延迟编辑副本，CockpitHost 的 DocumentActor 是恢复权威端。

### 9.2 编辑事务

```text
Monaco 立即应用本地编辑
-> 增量编辑消息(EditLeaseID, baseVersion, clientSequence)
-> DocumentActor 串行校验并应用
-> 追加恢复日志
-> acknowledgement(documentVersion)
```

版本或租约不匹配时，客户端停止提交并从 Host 重新同步，不静默覆盖 Host 状态。

### 9.3 保存

1. 执行 flush barrier，等待所有本地编辑得到 Host 确认。
2. 在目标目录写入临时文件。
3. 原子替换目标文件。
4. 更新磁盘指纹和 persistedVersion。
5. 清除 dirty 状态。

Phase 1 只支持 UTF-8 与 UTF-8 BOM，并保留 BOM 与原始 LF/CRLF。二进制文件或无效 UTF-8 不进入 Monaco，也不修改原文件。Phase 1 使用手动保存和未保存文档恢复日志，不实现自动保存。

### 9.4 外部修改

- 干净文档：重新加载磁盘版本。
- 脏文档：进入冲突状态，禁止静默覆盖。
- 外部删除：保留 Host 文本并标记文件缺失。
- 错误展示真实路径、系统错误 domain 和 code。

### 9.5 文件树与文件操作

- 目录按需展开，不预扫描整个项目。
- FSEvents 只作为失效信号，Host 对受影响路径执行文件系统对账。
- 文件树发送 revision 化增量。
- 新建、重命名和移动限制在 Environment 根目录内。
- 删除使用 macOS 废纸篓。
- 每个 Environment 使用一个串行文件操作协调器。
- 文件系统操作成功后再提交 DocumentSession、页签和文件树变更；失败时不提交界面状态。

## 10. 持久化与所有权

| 存储 | 唯一写入者 | 内容 |
|---|---|---|
| workspace.sqlite | CockpitHost | Project、Environment、Conversation、DocumentSession、设备和 Context 布局 |
| terminal.sqlite | TerminalSupervisor | TerminalSession、LaunchSpec、生命周期、Keeper 绑定与输出序号 |

- Cockpit.app 不直接写数据库。
- TerminalSession 的 WorkspaceContextID 与 EnvironmentID 以 terminal.sqlite 为权威来源。
- Host 的页签状态只保存 TerminalSessionID 引用。
- 文档恢复日志和终端输出不按字节写 SQLite。
- 数据库使用版本化迁移。
- Worker 主密钥保存在 Keychain；会话密钥经私有引导文件描述符交给 Keeper，不进入数据库、argv 或环境变量。

## 11. 进程通信

### 11.1 本地控制面

NSXPCConnection 承载低频命令：

- Project 与 Conversation 生命周期。
- TerminalSession 创建、列出、连接、终止与对账。
- attach ticket 与输入租约。
- 订阅、能力和协议协商。

### 11.2 本地数据面

Unix Domain Socket 承载：

- 终端输入、VT 快照和增量。
- 文档编辑事务与确认。
- 文件树增量。

每个面向当前界面的请求或事件携带：

```text
protocolVersion
clientInstanceID
windowID
workspaceContextID
environmentID
activeContextGeneration
requestID
resourceID
revision | sequence
```

客户端只提交 EnvironmentID 与 RelativePath。Host 解析绝对路径、校验 WorkspaceContext 与 Environment 的绑定，并拒绝越出 Environment 根目录的文件操作。

### 11.3 远程预留

- CockpitClientCore 不依赖 AppKit、XPC、UDS 或本地文件系统。
- 本地与远程 Transport 使用相同类型化协议载荷。
- Phase 5 只增加 Network.framework TLS Transport、配对和设备授权，不重写领域模型。
- TerminalSupervisor 与 PTYKeeper 不监听网络；远程流量统一经过 CockpitHost。
- Phase 1 不开放网络端点。

## 12. Conversation 删除

删除使用可恢复状态机：

```text
Active
-> Deleting
-> TerminatingSessions
-> PurgingTerminalRecords
-> RemovingClientState
-> Deleted
```

1. 处理因删除该 Context 而失去最后一个 viewer 的脏 DocumentSession：保存、放弃或取消。
2. 用户明确确认终止全部运行中的 Shell 和 Agent。
3. Host 标记 Deleting，并拒绝为该 Context 创建新页签或 TerminalSession。
4. Supervisor 终止该 Context 的全部进程组。
5. 正常终止未完成时，界面提供单独的强制终止确认，不自动强杀。
6. 所有会话结束后，删除 Cockpit 保存的终端记录和 scrollback。
7. 删除设备布局、Context 状态和 Conversation 记录。
8. App 切换回所属 Project Context。

Host 或 Supervisor 中途崩溃后，从持久化状态继续同一个删除操作。全部步骤完成前不报告成功。

删除 Direct Conversation 不删除 Project 文件、Direct Environment 或 Codex/Claude 保存在 Cockpit 外部的历史数据。未来删除 Worktree Conversation 也不隐式删除 Git worktree。

## 13. 故障行为

| 故障 | 确定结果 |
|---|---|
| Cockpit.app 退出或崩溃 | Host、Supervisor、Keeper、PTY 与 Agent 继续运行 |
| WKWebView 崩溃 | 重建 Monaco，并从 DocumentActor 已确认版本恢复 |
| CockpitHost 崩溃 | launchd 重启 Host；文档从恢复日志恢复；本地终端不受影响 |
| TerminalSupervisor 崩溃 | launchd 重启并重新认证、对账原 Keeper |
| 一个 PTYKeeper 崩溃 | 仅对应 TerminalSession 进入 Interrupted |
| 用户退出登录或 macOS 重启 | 原活动终端标记 Interrupted；工作区与恢复记录保留 |

每个运行 CLI 必须同时拥有：

```text
Committed TerminalSession
+ 已认证 Keeper runtime descriptor
+ 匹配的 TerminalSessionID 与 WorkerInstanceID
```

因此 App、Host 或 Supervisor 重启不会产生无法识别的运行 Agent。

## 14. Phase 1 验收

以下是端到端验收场景，不拆成额外产品功能：

1. **纯 Project 模式**：添加目录后不创建 Conversation，文件树、编辑器、Shell 和 Agent CLI 正常工作。
2. **多个 Direct Conversation**：页签与终端隔离，全部共享同一个目录和文件状态。
3. **文档与文件操作**：同一文件跨 Context 同步；重命名、移动、保存和外部冲突不丢内容。
4. **多个 Agent**：同一 Conversation 同时运行 Codex 与 Claude；关闭页签不终止进程；退出状态准确。
5. **崩溃恢复**：App、Host、Supervisor 分别退出后恢复原 TerminalSession、CLI PID、屏幕、scrollback 与已确认文档版本；一个 Keeper 崩溃不影响其他会话。
6. **Conversation 删除**：活动终端明确处理后才完成；中途崩溃可以继续；Project 和项目文件不受影响。

Phase 1 不设置性能数字指标，强制验证以下结构事实：

- 每窗口一个 WKWebView。
- 每个规范化物理目录一个 Environment 与 WorkspaceKernel。
- 终端热路径绕过 Host 和 Supervisor。
- 非活动终端停止 Metal 帧渲染。
- 文件树不执行整项目预扫描。

## 15. 依赖与实施入口

- Phase 1 实施开始前，按照各依赖官方发布源重新核验全部正式稳定版。
- Beta、RC 与 nightly 不进入基线。
- Ghostty 固定为用户已确认的 1.3.2-dev commit `05221c11c9db0715666fc6e038915128fc6a563e`，Zig 固定为该提交 `build.zig.zon` 声明的 0.16.0。
- 依赖变化先更新固定版本、构建输入和验证，再开始功能任务。
- 本设计批准并提交后，下一步是编写逐任务、逐测试、逐文件的 Phase 1 实施计划。
- 实施计划按用户已确认的子 Agent 驱动方式组织执行与复核任务。
- 实施计划获批前不编写 Phase 1 功能代码。
