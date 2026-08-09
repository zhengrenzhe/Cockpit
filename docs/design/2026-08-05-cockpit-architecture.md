# Cockpit 总体架构设计

- 状态：已批准
- 日期：2026-08-05
- 首发平台：macOS
- 终态客户端：Apple 平台
- 首要约束：原生性能

## 1. 产品定义

Cockpit 是一个原生 Agent 开发环境，提供项目、对话、代码编辑、终端、文件工具、搜索和 Git 工作流。Agent 编排继续由 Codex、Claude Code 等外部 CLI 程序负责。

首个版本运行在 macOS 上。Mac 是项目、worktree、文件、Git 仓库、语言服务器、终端进程和对话状态的权威端。其他 Apple 设备作为远程客户端连接 Mac。

### 目标

- 使用 Swift 和 macOS 原生 UI 构建应用外壳。
- 在 CLI 持续输出时，保持 UI 输入、终端渲染、文件导航和工作环境切换流畅响应。
- 通过隔离的 Monaco 运行时实现对标 VS Code 的编辑能力。
- 通过固定版本的轻量 fork 使用 Ghostty 终端核心和 Metal 渲染器。
- 在 Cockpit.app、CockpitHost 和 CockpitTerminalSupervisor 重启期间保留所有活动终端会话。
- 从首个实现阶段开始，确保每个产品 API 都具备远程调用能力。
- 保持 Project、Conversation、WorkspaceContext 和 Environment 身份稳定且明确。
- 文件、搜索、Git、编辑器和终端工作目录绑定到不可变的 EnvironmentID；页签和终端产品归属绑定到 WorkspaceContextID。

### 首个开发者预览版不包含

- 内置 Agent 编排。
- 插件市场。
- CRDT 多写入端编辑。
- 互联网 Relay 服务。
- 容器或虚拟机隔离。
- 非 Apple 平台客户端。
- Web 应用外壳。

## 2. 产品布局

### 左侧栏

左侧栏承载产品的项目层级：

```text
项目 A
├── 对话 A1
└── 对话 A2 · worktree: feature/a

项目 B
├── 对话 B1
└── 对话 B2 · worktree: fix/b
```

- Project 映射到用户选择的一个物理文件夹。
- Project 本身是可选择的完整 IDE 工作上下文，可以不包含 Conversation。
- 一个 Project 可以包含多个 Conversation。
- Conversation 展示自身是直接使用项目目录，还是使用一个 Git worktree。
- 选择 Project 或 Conversation 会切换整个活动 WorkspaceContext。

### 中央工作区

中央区域是核心工作区，使用原生页签。

- 页签可展示文件编辑器、Agent CLI 终端、普通 Shell、Diff 编辑器或新建页签选择器。
- 原生页签状态与文档、终端的生命周期相互独立。
- 关闭页签只会断开视图，不会终止 TerminalSession。

### 右侧工具栏

右侧栏跟随当前 ActiveContext 的 EnvironmentID。

- 文件树。
- 文件搜索。
- 源代码搜索。
- 源代码管理状态和本地变更。
- Diff 和提交界面。
- Git Toolbox 快捷操作。

右侧栏的 Provider 不直接读取 Project 根目录。每个 Provider 都从当前活动 EnvironmentID 解析自身根目录。

## 3. 核心数据模型

### Project

```text
ProjectID
displayName
rootBookmark
canonicalRootIdentity
baseEnvironmentID
createdAt
```

一个 Project 表示用户选择的一个固定物理文件夹。Project 自身对应 `WorkspaceContextID.project(ProjectID)`，并通过 baseEnvironmentID 使用项目目录唯一的 Direct Environment。

### Conversation

```text
ConversationID
ProjectID
EnvironmentID
title
lifecycleState: active | deleting(phase)
deletionOperationID?
createdAt
archivedAt
```

Conversation 是左侧栏展示的产品级任务容器。它既不是 PTY、Agent 进程，也不是 UI 页签。一个 Conversation 可以拥有多个 Shell 和 Agent TerminalSession。Agent Profile 属于单个 TerminalSession 的 LaunchSpec，页签属于客户端 WorkspaceContext 状态。

### WorkspaceContext

WorkspaceContext 统一表示可选择的产品上下文：

```text
WorkspaceContextID
├── project(ProjectID)
└── conversation(ConversationID)
```

ProjectContext 和 ConversationContext 是 WorkspaceContextID 的两个变体，不建立额外数据库实体。

### Environment

```text
EnvironmentID
ProjectID
kind: direct | worktree
workspaceRoot
workspaceRootIdentity
gitCommonDirectory
worktreeBranch?
```

- 一个规范化物理工作目录对应一个 EnvironmentID。
- 每个 Project 的 baseEnvironmentID 指向项目根目录唯一的 Direct Environment。
- Project Context 与该 Project 下全部 Direct Conversation 共享 baseEnvironmentID。
- Worktree Environment 解析到一个 Git worktree 根目录。
- WorkspaceKernel 以 EnvironmentID 为键，不为同一规范化物理目录创建重复实例。

把 Conversation 从 Direct 改为 Worktree 时，将创建一个新 Conversation。已有终端、文档和 Git 历史的 Environment 身份不会发生变化。

### TerminalSession

```text
TerminalSessionID
WorkspaceContextID
EnvironmentID
kind: shell | agent
launchSpec
workerInstanceID
keeperProcessIdentifier
cliProcessIdentifier
lifecycleState
protocolVersion
latestSequence
```

Agent CLI 和普通 Shell 会话使用同一套模型。Project Context 与 Conversation Context 都可以拥有 TerminalSession。Conversation 不包含 primaryTerminalSessionID，一个 Context 可以拥有任意数量的独立 TerminalSession。

### DocumentSession

```text
DocumentID
EnvironmentID
relativePath
documentVersion
persistedVersion
dirtyState
editLease
```

`EnvironmentID + normalized RelativePath` 是唯一文件定位键，DocumentID 是稳定身份。Cockpit 发起重命名或移动时保持 DocumentID 不变，并原子更新 relativePath 和所有页签引用。两个 worktree 中相同的相对路径仍产生不同 DocumentSession。

### TabRecord

TabRecord 只保存界面展示引用：

```text
TabID
kind
resourceID
position
```

关闭 TabRecord 永远不会终止 PTY。终止 PTY 必须发送明确的 TerminalSession 命令。

### ClientWorkspaceState

ClientWorkspaceState 按 `DeviceID + WindowID + WorkspaceContextID` 分别保存界面状态：

- 当前选中的页签。
- 侧栏宽度。
- 已展开节点。
- 滚动位置。
- 焦点和本地选区。

它不属于跨设备共享的领域状态。文件、Conversation、DocumentSession 和 TerminalSession 继续作为跨设备领域状态。

## 4. 活动上下文

选择 Project 或 Conversation 会创建新的 ActiveContextGeneration，并订阅一个不可变的 ActiveContext：

```text
ActiveContext
├── WorkspaceContextID
├── ProjectID
├── ConversationID?
├── EnvironmentID
├── WorkspaceRootIdentity
├── GitContext
└── generation
```

CockpitHost 返回一个带 revision 的启动快照，其中包含页签、文档、终端、文件树和 Git 状态。客户端以原子方式显示该快照，随后只应用 revision 大于启动快照的增量。

ConversationID 在 Project Context 中为空。Generation 是客户端窗口内单调递增的选择版本，不写入数据库。每个异步结果都携带 WorkspaceContextID、EnvironmentID、generation、resource ID 和本地 revision。来自旧 generation 的结果直接丢弃；Environment 级缓存仍可复用。

## 5. 进程架构

Cockpit 定义四种应用自有的可执行进程角色。每个活动 TerminalSession 都有一个独立 CockpitPTYKeeper 进程实例。WKWebView 还会创建由系统管理的 WebContent 和 GPU 辅助进程。

### Cockpit.app

职责：

- AppKit 窗口和分栏外壳。
- 原生项目、对话、页签和工具界面。
- 每个窗口一个 Monaco WKWebView 运行时。
- Ghostty Metal NSView 渲染表面。
- CockpitClientCore、ActiveContextGeneration 和 ClientWorkspaceState。
- 本地用户输入和命令路由。

Cockpit.app 不拥有文件系统、Git、PTY 或持久化文档状态。

### CockpitHost

职责：

- Project、Conversation 和 Environment 的权威状态。
- WorkspaceContext 解析和设备布局状态。
- WorkspaceKernel 池。
- 文件服务、FSEvents 对账、文件索引和搜索。
- Git 模型和串行化 Git 操作。
- DocumentStore、恢复日志和外部变更冲突处理。
- LSP 进程生命周期和请求路由。
- workspace.sqlite。
- 本地控制端点。
- 基于 Network.framework 的远程网关。
- 设备、项目和能力授权。

CockpitHost 不拥有活动 PTY。

### CockpitTerminalSupervisor

CockpitTerminalSupervisor 是独立的当前用户级 LaunchAgent，并启用 `KeepAlive`。

职责：

- TerminalSession 注册表。
- TerminalSession 到 WorkspaceContext 和 Environment 的权威绑定。
- TerminalSession 两阶段创建事务。
- PTYKeeper 启动、发现、认证和恢复对账。
- 单次使用的本地连接票据。
- 终端输入租约协调。
- 最终终端归档服务。
- terminal.sqlite。

CockpitTerminalSupervisor 永远不持有 PTY master，不解析 VT 输出，也不代理本地活动终端的数据热路径。它不开放网络监听，也不实现文件、Git、搜索或 LSP。

### CockpitPTYKeeper

CockpitTerminalSupervisor 为每个已提交且处于活动状态的 TerminalSession 启动一个 CockpitPTYKeeper。每个 Keeper 使用 `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT` 进入独立的 Unix session 和进程组；只有明确声明的引导文件描述符可以跨越 spawn 边界。

职责：

- 独占一个 PTY master。
- 管理 Agent CLI 或 Shell 进程组的生命周期。
- 收到已提交的启动命令后执行结构化 LaunchSpec。
- Ghostty VT 解析和权威屏幕状态。
- scrollback 分块、快照和终端帧增量。
- 不依赖已连接客户端，持续排空 PTY 输出。
- 按客户端处理背压、有序输入、去重和租约强制执行。
- 一个经过认证的 Unix Domain Socket 端点。
- CLI 退出时保存最终屏幕和 scrollback 检查点。

CockpitPTYKeeper 永远不监听网络，也不写入 terminal.sqlite。Supervisor 退出后，活动 Keeper 会被重新托管到 launchd/PID 1；由于 Keeper 位于独立进程组，launchd 针对原进程组的清理不会影响它们。

## 6. 进程通信

### 本地控制面

NSXPCConnection 在 Cockpit.app、CockpitHost 和 CockpitTerminalSupervisor 之间传输生命周期及低频控制消息：

- 创建、列出、归档和删除产品记录。
- 创建、列出、连接、终止和对账 TerminalSession。
- 获取和释放输入租约。
- 注册订阅。
- 上报服务能力和协议版本。

XPC 端点接受命令前会校验对端身份。Phase 0 对临时签名的开发构建强制执行有效用户身份边界；Phase 6 增加正式 Team ID 和 designated requirement 校验。

### 本地数据面

Unix Domain Socket 传输带帧结构的多路复用数据流：

- 终端输入和屏幕帧。
- 文档编辑事务及确认。
- 文件树增量。
- 搜索、Diff 和 scrollback 批次。
- LSP 请求和响应载荷。

完成授权后，本地终端热路径绕过 CockpitHost 和 CockpitTerminalSupervisor：

```text
Cockpit.app <-> CockpitPTYKeeper <-> PTY <-> Agent CLI
```

CockpitHost 负责 Environment 授权，并向 CockpitTerminalSupervisor 请求单次使用的 attach ticket。Supervisor 向目标 Keeper 注册该票据，然后把端点描述符返回给 Cockpit.app。Cockpit.app 打开直连终端 socket 时提交该票据。

CockpitTerminalSupervisor 重启期间，已经建立的 App-to-Keeper 数据流继续工作。launchd 重新启动并完成 Supervisor 对账后，新的连接、终止和租约转移命令恢复工作。

### 远程数据路径

```text
远程 Apple 客户端
    <-> Network.framework TLS 1.3
    <-> CockpitHost
    <-> 本地认证终端数据流
    <-> CockpitPTYKeeper
```

CockpitTerminalSupervisor 和 CockpitPTYKeeper 均无法从网络直接访问。

## 7. CockpitProtocol

CockpitProtocol 使用固定的 32 字节二进制传输头和类型化载荷。

```text
magic             UInt32
protocolVersion   UInt16
flags             UInt16
channelID         UInt32
sequence          UInt64
acknowledgement   UInt64
payloadLength     UInt32
```

channelID 只在一条连接内有效，不是 UUID 领域身份。featureSet、deviceID、connectionID、windowID、requestID、workspaceContextID、environmentID、activeContextGeneration 和 payloadType 位于握手消息或 SwiftProtobuf 控制载荷中，不占用固定传输头。

载荷策略：

- 控制消息和结构化数据使用 SwiftProtobuf。
- 终端单元格增量使用紧凑二进制格式。
- 快照、scrollback、搜索结果和大型 Diff 使用协商压缩。
- 键盘输入、编辑确认和小型控制消息不压缩。

各 Channel 独立维护顺序和流量控制：

- Control：可靠、有序，最高优先级。
- Document：可靠、有序，并带版本确认。
- TerminalInput：可靠且有序。
- TerminalFrame：有序且可合并；序列缺口会触发快照恢复。
- Bulk：可取消、可分页。

变更类命令携带 request ID，保证重试具有幂等性。

## 8. 远程就绪边界

CockpitClientCore 是 macOS App 与未来 Apple 客户端共享的纯 Swift Package。

它不依赖 AppKit、WKWebView、NSXPCConnection、NWConnection 或本地文件系统 API。

```swift
public protocol CockpitTransport: Sendable {
    func connect() async throws -> NegotiatedSession
    func request(_ envelope: RequestEnvelope) async throws -> ResponseEnvelope
    func openChannel(_ descriptor: ChannelDescriptor) async throws -> any CockpitChannel
    func disconnect() async
}
```

Transport 实现：

- LocalTransport：XPC 控制面和本地 socket 数据面。
- RemoteDirectTransport：通过 Network.framework 和 TLS 1.3 在局域网或 VPN 内直连。
- RelayTransport：未来的可靠字节流适配器。

CockpitHostCore 接收命令、查询和订阅值，不检查具体 Transport 类型。

远程规则：

- 默认关闭远程监听。
- 配对流程从 Mac 发起。
- 每台设备都有独立密钥、允许列表记录和授权集合。
- 协议身份不绑定 IP 地址。
- 请求使用稳定 ID 和相对路径。
- Host 校验 Environment 授权和规范化路径包含关系。
- 一个 DocumentSession 只有一个写入租约。
- 一个 TerminalSession 只有一个输入租约。
- 控制权转移前，其他已连接设备保持只读。
- 不支持离线编辑。

远程终端权限等同于 macOS 用户的交互式 Shell 权限。项目范围内的文件 API 无法限制 Shell 命令。容器或虚拟机隔离属于独立的产品安全边界。

## 9. 终端架构

### 输出路径

```text
CLI stdout/stderr
-> PTY master
-> PTYKeeper 读取循环
-> Ghostty VT 核心
-> 权威单元格网格和 scrollback
-> 快照/增量编码器
-> 本地或代理 Channel
-> Ghostty Metal 渲染器
```

每个 CockpitPTYKeeper 都独立于渲染速度持续排空自己的 PTY。当某个客户端消费过慢时，Keeper 只合并该客户端的中间屏幕帧，同时保留最新终端状态。客户端渲染或归档 I/O 永远不会阻塞 PTY 读取。

sequence 出现缺口时触发完整屏幕快照。scrollback 使用分页分块。

### 输入路径

```text
键盘 / 粘贴 / 调整尺寸
-> 输入租约校验
-> 有序 TerminalInput Channel
-> PTY
```

每个输入租约中的输入帧都使用单调递增 sequence。Keeper 对已接收输入进行确认，并对数据流重连后的重试进行去重。一个 TerminalSession 只有一个输入租约，同时允许任意数量的只读查看端。

### 会话创建事务

对外可见的生命周期：

```text
Preparing -> Committed -> Running
                           |-> Exited
                           |-> Terminated
                           └-> Interrupted
```

连接状态是独立状态。关闭页签、退出 Cockpit.app 或断开远程客户端，只会移除一个查看端，不会改变 Running 会话。

创建过程使用持久化的两阶段事务：

1. Supervisor 分配 TerminalSessionID 和 WorkerInstanceID，把 Preparing 状态及结构化 LaunchSpec 写入 terminal.sqlite 并提交。
2. Supervisor 通过继承的私有文件描述符传递引导材料和派生会话密钥，然后启动一个独立 Keeper。此时 Keeper 不创建 PTY 或 CLI。
3. Keeper 绑定自己的 UDS 端点并返回 Ready。
4. Supervisor 持久化 Committed 状态，然后发送 Start。
5. Keeper 创建 PTY 和 CLI，返回进程身份，Supervisor 随后记录 Running。

如果 Supervisor 在 Committed 之前退出，Keeper 永远不会启动 CLI，并在 30 秒引导期限结束时退出。如果 Supervisor 在 Committed 之后退出，替代它的新 Supervisor 会完成启动或执行恢复对账。因此，每个已启动 CLI 都对应一条持久化的 committed TerminalSession 记录。

### Shell 与 Agent LaunchSpec

- Project Context 和 Conversation Context 都可以创建普通 Shell、Codex 与 Claude TerminalSession。
- 普通 Shell 在 Environment.workspaceRoot 启动用户登录 Shell。
- Codex 与 Claude 是 Phase 1 内建 Agent Profile；其他 Agent 可以由用户在普通 Shell 中手动启动。
- 专用 Agent 页签完成登录 Shell 环境初始化后使用结构化参数执行 `exec`。Agent 退出时 TerminalSession 同步结束，不退回普通 Shell。
- Agent 可执行文件首次解析后保存绝对路径，每次启动前重新验证。
- LaunchSpec 不持久化完整用户环境或密钥，只保存明确的非敏感覆盖项。
- 重新启动已结束 Agent 时创建新的 TerminalSessionID，原页签改为连接新会话。

### 连接与恢复

- UDS 运行目录是 `/private/tmp/cockpit.<uid>/terminal`，归当前用户所有，权限为 `0700`；每个 socket 的权限为 `0600`。
- Keeper 端点使用 `getpeereid` 校验有效用户，并对协议握手进行认证。
- 安装主密钥保存在 Keychain 中。会话密钥通过主密钥、TerminalSessionID 和 WorkerInstanceID 派生，再经引导文件描述符传递给 Keeper，不进入 argv 或环境变量。Keychain 不可访问时，对账操作等待恢复，不会终止活动 Keeper。
- attach ticket 只能使用一次，并绑定 TerminalSessionID、客户端身份、能力集合和过期时间。
- 重连时提交最后确认的输出 sequence。对应增量仍保留时，Keeper 从下一条增量继续发送；增量范围已淘汰时，Keeper 发送新的权威 VT 完整快照。
- 启动时，Supervisor 使用 TerminalSessionID 和 WorkerInstanceID，将 terminal.sqlite 记录与已认证的运行时描述符进行匹配。已提交的活动 Keeper 会被接管；找不到 Keeper 的记录转为 Interrupted；未提交 Keeper 永远不会被接管。
- 活动 Agent CLI 不设置空闲超时。

CLI 退出时，Keeper 在 PTY 读取循环之外写入最终 VT 快照和不可变 scrollback 分块，上报退出状态，然后退出。CockpitTerminalSupervisor 以只读归档形式提供该已结束会话，不再创建 PTY。

### 故障边界

- Cockpit.app 退出：TerminalSession 保持活动。
- Cockpit.app 崩溃：TerminalSession 保持活动。
- CockpitHost 重启：TerminalSession 保持活动。
- CockpitTerminalSupervisor 重启：所有 Keeper、PTY、Agent CLI 和已经建立的本地终端数据流保持活动。
- CockpitPTYKeeper 崩溃：只有该 Keeper 对应的 TerminalSession 转为 Interrupted。
- 用户退出登录或 macOS 重启：所有活动 PTY 结束。

## 10. 编辑器架构

EditorRuntime 是唯一使用 Web 技术的区域。

- 每个 Cockpit 窗口使用一个 WKWebView 和 Monaco 运行时。
- 多个 Monaco text model 共享该运行时。
- 原生页签负责切换活动 model。
- 不为每个文件创建独立 WKWebView。
- 不使用 React、Electron、本地 HTTP Server、浏览器路由或 Web 版侧栏。
- 编辑器资源从签名后的 App Bundle 加载。

Monaco 是低延迟编辑副本。CockpitHost 的 DocumentActor 是持久恢复的权威端。

```text
Monaco 编辑事务
-> 异步有序编辑消息(EditLeaseID, baseVersion, clientSequence)
-> DocumentActor 校验租约并应用版本
-> 追加恢复日志
-> LSP didChange
-> acknowledgement(version)
```

保存操作先执行 flush barrier，等待 Host 收到当前版本，再以原子方式替换磁盘文件，最后返回新的磁盘指纹。

`EnvironmentID + normalized RelativePath` 是唯一文件定位键，DocumentID 是稳定身份。Cockpit 内发起重命名或移动时保持 DocumentID 不变，并同步更新全部页签引用。

Phase 1 只支持 UTF-8 与 UTF-8 BOM，保存时保留 BOM 和原有 LF/CRLF。二进制文件与无效 UTF-8 不进入 Monaco。Phase 1 使用手动保存和未保存文档恢复日志，不实现自动保存。

外部修改处理：

- 干净文档：从磁盘重新加载。
- 脏文档：进入冲突状态，禁止静默覆盖。

崩溃恢复只保证保留 Host 已确认的文档版本。

## 11. 工作区、搜索、Git 与 LSP

### 文件树

- 延迟加载目录。
- 使用稳定相对路径。
- FSEvents 只作为失效信号，不作为最终事实来源。
- 收到事件后执行针对性的文件系统对账。
- 使用树增量，不执行整树重新加载。
- 新建、重命名和移动限制在 Environment 根目录内。
- 删除使用 macOS 废纸篓。
- 每个 Environment 使用一个串行文件操作协调器。
- 文件系统操作成功后再提交 DocumentSession、页签和树状态。

### 搜索

- 使用常驻增量路径索引实现文件搜索。
- 使用 ripgrep JSON 流实现内容搜索。
- 每批结果都携带 Query ID。
- 新查询会取消上一个搜索进程。

### Git

- 仓库状态绑定 EnvironmentID。
- 根目录相同时，物理仓库服务进行去重。
- 使用 `git status --porcelain=v2 -z` 获取状态数据。
- 按需计算 Diff 内容。
- 每个仓库只有一个变更操作队列。
- 变更操作包括 stage、unstage、discard、commit、branch、pull、push、merge 和 rebase。
- 变更操作失败后，Cockpit 展示准确 stderr，并重新加载仓库状态。

### LSP

- 语言服务器运行在 CockpitHost 下。
- 进程以 Environment 为键，只有物理工作区身份相同时才去重。
- DocumentActor 是发送给 LSP 的唯一文本同步来源。
- Monaco Provider 请求通过 CockpitClientCore 桥接。

## 12. 持久化与资源生命周期

### 存储所有权

- 只有 CockpitHost 可以写入 workspace.sqlite。
- 只有 CockpitTerminalSupervisor 可以写入 terminal.sqlite。
- 每个 CockpitPTYKeeper 只能写入自己的运行时描述符、不可变 scrollback 分块和最终 VT 快照。
- workspace.sqlite 保存 Project、Environment、Conversation、DocumentSession 和设备 WorkspaceContext 布局。
- terminal.sqlite 保存 TerminalSession、LaunchSpec、生命周期以及 WorkspaceContextID 和 EnvironmentID 权威绑定。
- Host 页签状态只保存 TerminalSessionID 引用，不复制 TerminalSession 权威记录。
- 不同进程永远不共享可变数据库的写入所有权。
- 启动恢复通过 IPC 完成对账。

### WorkspaceKernel 状态

```text
Cold -> Active -> Background -> Evicted
```

- Cold：仅保留元数据。
- Active：至少有一个已连接客户端。
- Background：没有客户端，但仍有活动终端或脏文档。
- Evicted：引用计数为零，且状态已经保存检查点。

资源规则：

- TerminalSession 处于 Running 时保留 PTY 和 VT。
- 活动 Agent CLI 不设置空闲超时。
- 关闭终端页签或退出 Cockpit.app 只会断开客户端。
- 已结束会话通过最终只读快照和 scrollback 归档提供访问。
- 脏 DocumentSession 保留到保存或丢弃为止。
- 编辑器需要 LSP 时，语言服务器保持运行。
- 搜索进程只在查询活动期间存在。
- Watcher 和 Git 模型按规范化根目录共享，并随 WorkspaceKernel 一同逐出。

## 13. 恢复语义

| 事件 | 保留内容 | 恢复方式 |
|---|---|---|
| Cockpit.app 退出或崩溃 | Host、Supervisor、Keeper、PTY、CLI、持久化文档版本 | 重新连接各 Keeper，并加载快照与增量 |
| WKWebView 崩溃 | 原生 UI、服务、已确认文档版本 | 重建 Monaco 运行时并恢复 model |
| 本地数据流断开 | Host 和终端权威状态 | 从 sequence 继续，或用快照替换 |
| 外部文件变更 | 磁盘版本和脏缓冲区 | 干净文件重新加载；脏文件进入冲突状态 |
| CockpitHost 崩溃 | Supervisor、Keeper 和活动 PTY | 重启 Host 并对账 TerminalSession ID |
| CockpitTerminalSupervisor 崩溃 | Keeper、PTY、CLI 和已建立的本地数据流 | launchd 重启 Supervisor，并对账已提交 WorkerInstanceID |
| 一个 CockpitPTYKeeper 崩溃 | 其他全部会话及最终归档 | 仅将受影响 TerminalSession 标记为 Interrupted |
| 远程客户端断开 | Mac 端全部状态 | 释放输入租约，并在重连后重新同步 |
| 用户退出登录或 macOS 重启 | 工作区和最终终端归档 | 将此前活动的 TerminalSession 标记为 Interrupted |

归档和删除规则：

- Archive 隐藏 Conversation，但保留状态。
- 删除 Conversation 使用 Active、Deleting、TerminatingSessions、PurgingTerminalRecords、RemovingClientState、Deleted 的可恢复状态机。
- 删除 Conversation 前先明确处理因移除该 Context 而失去最后一个 viewer 的脏 DocumentSession，以及全部活动 TerminalSession。
- 正常终止未完成时提供单独的强制终止确认，不自动强杀。
- 删除 Direct Conversation 不删除 Project 文件或共享 Direct Environment。
- 删除 Conversation 永远不会隐式删除 worktree。
- 删除 worktree 是独立操作，执行前检查本地变更。

## 14. 仓库与模块布局

```text
Cockpit/
├── Cockpit.xcworkspace
├── Cockpit.xcodeproj
├── Package.swift
├── Config/
├── Applications/
│   ├── CockpitApp/
│   ├── CockpitHost/
│   ├── CockpitTerminalSupervisor/
│   └── CockpitPTYKeeper/
├── Sources/
│   ├── CockpitTypes/
│   ├── CockpitProtocol/
│   ├── CockpitClientCore/
│   ├── CockpitHostCore/
│   ├── CockpitWorkspace/
│   ├── CockpitPersistence/
│   ├── CockpitTerminalClient/
│   ├── CockpitTerminalCore/
│   ├── CockpitLocalTransport/
│   └── CockpitRemoteTransport/
├── EditorRuntime/
├── ThirdParty/ghostty/
├── Tests/
├── UITests/
├── Tools/
└── docs/
```

依赖规则：

- CockpitTypes 不导入任何产品子系统。
- CockpitProtocol 只依赖 CockpitTypes 和 SwiftProtobuf。
- CockpitClientCore 不导入 UI 框架。
- CockpitHostCore 不导入具体 Transport 实现。
- CockpitWorkspace 和 CockpitPersistence 实现 CockpitHostCore 接口。
- CockpitLocalTransport 负责 NSXPCConnection 和 Unix Domain Socket 适配器。
- CockpitRemoteTransport 负责 Network.framework 和 TLS 适配器。
- 作为 Composition Root 的可执行 Target 不包含业务逻辑。

## 15. 固定的基础依赖

以下版本已于 2026-08-05 验证，并固定为当日最新正式稳定版；Beta 和 RC 不进入工程基线：

| 组件 | 版本 | 来源 |
|---|---:|---|
| Xcode | 26.6 (17F113) | https://developer.apple.com/news/releases/?id=06252026a |
| Swift | 6.3.3 | https://forums.swift.org/t/announcing-swift-6-3-3/87888 |
| Swift tools version | 6.3 | 本机 `swift package init` 生成的 Package Manifest |
| SwiftProtobuf | 1.38.1 | https://github.com/apple/swift-protobuf/releases/tag/1.38.1 |
| Monaco Editor | 0.56.0 | https://github.com/microsoft/monaco-editor/releases/tag/v0.56.0 |
| esbuild | 0.28.1 | https://github.com/evanw/esbuild/releases/tag/v0.28.1 |
| Ghostty 上游基础版本 | 1.3.2-dev / `05221c11c9db0715666fc6e038915128fc6a563e` | https://github.com/ghostty-org/ghostty/commit/05221c11c9db0715666fc6e038915128fc6a563e |
| Ghostty 使用的 Zig | 0.16.0 | Ghostty `build.zig.zon` 的 `minimum_zig_version` 与 Zig 官方 macOS arm64 archive |
| Node | 26.7.0 | https://nodejs.org/dist/index.json |
| pnpm | 11.20.0 | https://github.com/pnpm/pnpm/releases/tag/v11.20.0 |
| XcodeGen | 2.46.0 | https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0 |

Task 11 执行时，本机 Xcode 26.6 / SDK 26.5 无法链接 Zig 0.15.2 的 native build runner；用户明确批准切换到 Ghostty 1.3.2-dev 精确提交 `05221c11…`。该提交的 `build.zig.zon` 同时声明版本 1.3.2-dev 与最低 Zig 0.16.0，因此 Cockpit 固定使用该提交和 Zig 0.16.0 官方 macOS arm64 archive，不跟随 `main` 漂移。

Phase 0 开发标识：

```text
dev.cockpit.Cockpit
dev.cockpit.CockpitHost
dev.cockpit.CockpitTerminalSupervisor
dev.cockpit.CockpitPTYKeeper
dev.cockpit.host
dev.cockpit.terminal
```

正式发布使用的 Team ID 和公开 Bundle Identifier 属于分发配置，不会改变协议身份或领域身份。

## 16. 交付顺序

### Phase 0：工程基础

- Xcode 和 SwiftPM 结构。
- 稳定值类型和版本化协议。
- CockpitClientCore 与 CockpitHostCore 握手。
- 四个 Composition Root 可执行 Target，其中包含每会话 PTYKeeper 边界。
- 本地控制面和帧传输基础。
- 固定版本的 Monaco 与 Ghostty 构建输入。
- 远程 Transport 一致性测试框架。

### Phase 1：本地 Direct Workspace 垂直切片

详细设计：`docs/superpowers/specs/2026-08-06-cockpit-phase-1-design.md`

- 添加一个 Project，并提供无需 Conversation 的完整 Project Context。
- 在一个 Project 下创建、重命名和删除多个 Direct Conversation。
- Project Context 与 Direct Conversation 共享一个 Direct Environment，分别保存页签和终端。
- 文件树、新建、重命名、移动和删除到废纸篓。
- Monaco UTF-8 基础打开、编辑、恢复和原子保存。
- TerminalSupervisor 与每会话 PTYKeeper 启动普通 Shell、Codex 和 Claude。
- 一个 Conversation 运行多个独立 Agent TerminalSession。
- App、Host、Supervisor 和单 Keeper 故障恢复。

### Phase 2：工作环境隔离

- 多 Project。
- Direct 与 Worktree Environment。
- ActiveContext 原子切换。
- 跨 Environment 隔离测试。

### Phase 3：开发工具

- 文件和内容搜索。
- Git 状态、Diff、stage、commit 和 Toolbox 操作。
- 首个开发者预览版。

### Phase 4：编辑器智能能力

- LSP 能力、语义 Token、重命名、格式化、Code Action 和 Diff 编辑器。

### Phase 5：远程直连控制

- TLS 配对、设备授权、输入租约、重连和第二个 Apple 设备客户端。

### Phase 6：产品化

- Hardened Runtime、签名、公证、服务升级、迁移、恢复、安全验证和性能诊断。

### 后续独立 Agent Integration

- 为 Codex 与 Claude 分别实现结构化对话适配。
- 根据 Conversation 内的 Agent 对话更新默认标题。
- 普通终端 VT 输出不作为语义对话数据源。
- 本总体架构不为该阶段分配编号；编号、范围和工期通过单独设计审批确定。

## 17. Phase 完成规则

只有端到端 macOS 用户流程、Swift 单元测试、协议 Fixture 和进程集成测试全部通过，Phase 才算完成。一组彼此孤立的模块不构成完成的 Phase。
