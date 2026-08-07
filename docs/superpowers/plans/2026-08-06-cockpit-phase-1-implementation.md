# Cockpit Phase 1 Direct Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个原生 macOS Direct Workspace 垂直切片：一个固定物理 Project、零到多个 Direct Conversation、可恢复文件编辑与文件管理、可在 App 退出后继续运行并重新连接的 Shell/Codex/Claude 终端，以及 AppKit 三栏工作区。

**Architecture:** CockpitHost 是 Project、Environment、Conversation、DocumentSession、文件树和设备布局的唯一权威端；CockpitTerminalSupervisor 是 TerminalSession 注册表和两阶段创建的唯一权威端；每个 CockpitPTYKeeper 独占一个 PTY、CLI 进程组、Ghostty VT、scrollback 与本地 UDS 数据面；Cockpit.app 只持有 AppKit 视图、每窗口一个 Monaco WKWebView、Ghostty Metal viewer 和客户端状态。Project Context 与全部 Direct Conversation 共享一个 Direct Environment，页签与 TerminalSession 按 WorkspaceContext 隔离。

**Tech Stack:** macOS 15、Xcode 26.6 (17F113)、Swift 6.3.3、Swift tools 6.3、AppKit、WebKit、NSXPCConnection、Unix Domain Socket、SQLite3、Security/Keychain、CryptoKit、FSEvents、SwiftProtobuf 1.38.1、Monaco 0.56.0、esbuild 0.28.1、Node 26.7.0、pnpm 11.20.0、XcodeGen 2.46.0、Ghostty v1.3.1 (`332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`) 与 Zig 0.15.2。

## Global Constraints

- 只实现 `docs/superpowers/specs/2026-08-06-cockpit-phase-1-design.md` 已批准的 Phase 1 范围。
- 不实现多 Project、Worktree、搜索、Git、Diff、LSP、Agent 结构化对话、自动标题、自动保存、CRDT/OT、多设备连接、远程监听、通用 Agent Profile、Project 删除或 Conversation 归档。
- 不引入 SwiftUI、React、Electron、本地 HTTP Server 或浏览器路由。
- `CockpitTypes` 不依赖产品子系统；`CockpitProtocol` 只依赖 `CockpitTypes` 与 SwiftProtobuf；`CockpitClientCore` 不依赖 AppKit、WebKit、XPC、UDS 或本地文件系统；Composition Root 不包含业务逻辑。
- `workspace.sqlite` 只有 CockpitHost 写入；`terminal.sqlite` 只有 CockpitTerminalSupervisor 写入；Cockpit.app 不直接打开这两个数据库。
- 文件、DocumentSession 与文件树按 EnvironmentID 共享；页签、Shell 与 Agent CLI 按 WorkspaceContextID 隔离；布局按 DeviceID + WindowID + WorkspaceContextID 保存。
- 一个窗口只有一个 Monaco WKWebView。关闭终端页签只 detach；终止 TerminalSession 必须走明确命令。
- 终端热路径固定为 Cockpit.app 直连 CockpitPTYKeeper UDS，不经过 CockpitHost 或 CockpitTerminalSupervisor。
- Ghostty 使用 `docs/design/2026-08-05-cockpit-architecture.md:20` 已批准的固定版本轻量 fork：上游 submodule 始终保持干净，Cockpit 补丁在派生构建目录应用；产物中不包含 Zig 编译器或 Ghostty 源码。
- 不设置主观性能数字。结构验收固定为：文件树延迟展开、每 Environment 一个 Kernel、每窗口一个 WKWebView、终端热路径不转发、非活动终端停止 Metal 帧、PTY 读取不等待 viewer 或归档。
- 每个任务只运行本任务列出的 focused checks；Task 20 只运行一次统一 Phase 1 gate，不增加独立“再验证”任务。
- 每项功能先提交能失败的测试，再实现，再运行同一测试通过；禁止用只验证 mock 的测试替代进程或磁盘所有权场景。
- 当前依赖基线已由本机命令与官方来源核验。Task 1 再执行一次固定版本检查；发现正式稳定版本发生变化时停止，不修改版本，先按 `AGENTS.md` 向用户报告必要性、范围、成本、耗时、风险与不更新结果。

## Execution Protocol

- [ ] 在 `main` 工作树确认 `git status --short --branch` 只有 `## main`。
- [ ] 创建隔离工作树与分支：

```bash
git worktree add .worktrees/phase-1 -b codex/phase-1-direct-workspace main
```

- [ ] 从已验收的 Phase 0 本地输入准备 Phase 1 工作树，不下载替代归档：

```bash
git -C .worktrees/phase-1 submodule update --init ThirdParty/ghostty
mkdir -p .worktrees/phase-1/.tools/archives
cp .worktrees/phase-0/.tools/archives/zig-aarch64-macos-0.15.2.tar.xz .worktrees/phase-1/.tools/archives/
.worktrees/phase-1/Tools/bootstrap-zig.zsh
```

Expected: Phase 1 worktree 的 Ghostty HEAD 为 `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`；归档 SHA/size 与 `Config/Toolchains/ghostty.env` 一致；`.tools/zig/0.15.2/zig version` 输出 `0.15.2`。

- [ ] 后续全部命令在 `.worktrees/phase-1` 执行，禁止直接修改 `main`。
- [ ] 创建计划账本 `.superpowers/sdd/phase1-direct-workspace/ledger.md`，只记录 Task 1–20 的 `pending | implementing | spec-review | quality-review | complete`、实现 commit、review commit 和 focused check 结果。
- [ ] Task 1–20 严格串行。每个 Task 使用新的实现子 Agent；实现提交后先做规格审查，再做代码质量审查；两项审查完成后才进入下一个 Task。
- [ ] 子 Agent 不得修改计划、架构、Phase 范围或依赖版本。发现计划缺口时停止当前 Task 并交回主 Agent，按 `AGENTS.md` 征得用户同意。

---

### Task 1: 固定 Phase 1 模块、存储目录和构建基线

**Depends on:** 无。

**Files:**

- Modify: `Package.swift`
- Modify: `project.yml`
- Create: `Sources/CockpitPersistence/StorageLocations.swift`
- Create: `Sources/CockpitWorkspace/WorkspaceModule.swift`
- Create: `Sources/CockpitTerminalClient/TerminalClientModule.swift`
- Create: `Tests/CockpitPersistenceTests/StorageLocationsTests.swift`
- Create: `Tests/CockpitWorkspaceTests/ModuleBoundaryTests.swift`
- Create: `Tests/CockpitTerminalClientTests/ModuleBoundaryTests.swift`
- Create: `Tests/CockpitAppTests/AppTestScaffoldTests.swift`

**Contract:**

```swift
public struct CockpitStorageLocations: Sendable {
    public let applicationSupport: URL
    public let workspaceDatabase: URL
    public let terminalDatabase: URL
    public let documentRecoveryRoot: URL
    public let terminalArchiveRoot: URL

    public static func production(
        fileManager: FileManager = .default
    ) throws -> CockpitStorageLocations

    public static func under(
        _ applicationSupport: URL,
        fileManager: FileManager = .default
    ) throws -> CockpitStorageLocations
}
```

生产路径固定为：

```text
~/Library/Application Support/dev.cockpit.Cockpit/
├── workspace.sqlite
├── terminal.sqlite
├── DocumentRecovery/
└── TerminalArchives/
```

根目录与子目录权限为 `0700`；数据库、恢复日志、快照、分块和 manifest 权限为 `0600`。SQLite 使用 macOS SDK 自带 `SQLite3`，不新增第三方数据库包。

- [ ] **Step 1: 只添加可编译的 target scaffold**

`Package.swift` 的依赖方向固定为：

```text
CockpitPersistence -> CockpitTypes + CockpitHostCore + CockpitTerminalCore; linker: sqlite3
CockpitWorkspace   -> CockpitTypes + CockpitProtocol + CockpitHostCore
CockpitTerminalClient -> CockpitTypes + CockpitProtocol + CockpitClientCore
CockpitLocalTransport -> CockpitClientCore + CockpitHostCore + CockpitProtocol + CockpitTerminalCore + CockpitTerminalClient
```

`Package.swift` 先创建三个 library/product 及 `CockpitPersistenceTests`、`CockpitWorkspaceTests`、`CockpitTerminalClientTests` test targets；三个 source 文件在本步骤只包含空的 module marker，不实现 `CockpitStorageLocations`。`project.yml` 把三个 package product 接入实际使用它们的 Host、Supervisor 和 App target，不创建新进程；同时创建 `CockpitAppTests` 的 macOS `bundle.unit-test` target，sources 固定为 `Tests/CockpitAppTests`，依赖 `Cockpit`，`TEST_HOST`/`BUNDLE_LOADER` 指向构建出的 Cockpit.app，并把该 target 加入 `Cockpit` scheme 的 Test Action。

`CockpitPersistence` 直接使用 macOS SDK 已提供的 `import SQLite3` module，并在 target 设置 `linkerSettings: [.linkedLibrary("sqlite3")]`；不把 `SQLite3` 写成 SwiftPM target dependency，不新增 system-library target/module map。

- [ ] **Step 2: 写失败测试**

测试明确断言生产相对路径、注入临时根目录、目录权限、禁止符号链接根目录，以及 `CockpitWorkspace`/`CockpitPersistence`/`CockpitTerminalClient` 三个产品可以被 SwiftPM 导入。`CockpitAppTests` scaffold 断言 XCTest bundle 能加载宿主 App。

- [ ] **Step 3: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitPersistenceTests|CockpitWorkspaceTests|CockpitTerminalClientTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation -only-testing:CockpitAppTests/AppTestScaffoldTests test
```

Expected: Swift 测试进入新 test targets 后，因 `CockpitStorageLocations` 尚未实现而编译失败；App scaffold 测试通过并证明 test host/scheme 已接通。

- [ ] **Step 4: 实现存储路径与模块边界**

按本任务 Contract 实现 `CockpitStorageLocations`，不增加数据库 schema 或业务服务。

- [ ] **Step 5: 核验固定工具链与依赖**

```bash
xcodebuild -version
swift --version
xcodegen --version
fnm exec --using 26.7.0 node --version
fnm exec --using 26.7.0 pnpm --version
curl -fsSL https://nodejs.org/dist/index.json | /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)[0]["version"] == "v26.7.0"'
curl -fsSL https://registry.npmjs.org/pnpm/latest | /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)["version"] == "11.20.0"'
git ls-remote --tags https://github.com/yonaskolb/XcodeGen.git refs/tags/2.46.0
git ls-remote --tags https://github.com/apple/swift-protobuf.git refs/tags/1.38.1
git ls-remote --tags https://github.com/microsoft/monaco-editor.git refs/tags/v0.56.0
git ls-remote --tags https://github.com/evanw/esbuild.git refs/tags/v0.28.1
git ls-remote --tags https://github.com/ghostty-org/ghostty.git refs/tags/v1.3.1 refs/tags/v1.3.1^{}
git ls-remote --tags --refs https://github.com/yonaskolb/XcodeGen.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(2,46,0)'
git ls-remote --tags --refs https://github.com/apple/swift-protobuf.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(1,38,1)'
git ls-remote --tags --refs https://github.com/microsoft/monaco-editor.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(0,56,0)'
git ls-remote --tags --refs https://github.com/evanw/esbuild.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(0,28,1)'
git ls-remote --tags --refs https://github.com/ghostty-org/ghostty.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(1,3,1)'
Tools/verify-ghostty.zsh --no-bootstrap
```

Expected: 与本计划 Tech Stack 完全一致；Ghostty commit 和 Zig 0.15.2 校验通过。

- [ ] **Step 6: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitPersistenceTests|CockpitWorkspaceTests|CockpitTerminalClientTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation -only-testing:CockpitAppTests/AppTestScaffoldTests test
/usr/bin/git diff --check
git add Package.swift project.yml Cockpit.xcodeproj Cockpit.xcworkspace Sources/CockpitPersistence Sources/CockpitWorkspace Sources/CockpitTerminalClient Tests/CockpitPersistenceTests Tests/CockpitWorkspaceTests Tests/CockpitTerminalClientTests Tests/CockpitAppTests/AppTestScaffoldTests.swift
git commit -m "build: add phase 1 module boundaries"
```

---

### Task 2: 实现稳定身份、WorkspaceContext 和版本化协议

**Depends on:** Task 1。

**Files:**

- Modify: `Sources/CockpitTypes/Identifiers.swift`
- Modify: `Sources/CockpitTypes/ProtocolVersion.swift`
- Create: `Sources/CockpitTypes/WorkspaceModels.swift`
- Create: `Sources/CockpitTypes/DocumentModels.swift`
- Create: `Sources/CockpitTypes/TerminalModels.swift`
- Modify: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Create: `Sources/CockpitProtocol/WorkspaceMessages.swift`
- Create: `Sources/CockpitProtocol/DocumentMessages.swift`
- Create: `Sources/CockpitProtocol/TerminalMessages.swift`
- Modify: `Tests/CockpitTypesTests/IdentifiersTests.swift`
- Create: `Tests/CockpitTypesTests/WorkspaceModelsTests.swift`
- Create: `Tests/CockpitTypesTests/DocumentModelsTests.swift`
- Create: `Tests/CockpitTypesTests/TerminalModelsTests.swift`
- Create: `Tests/CockpitProtocolTests/Phase1MessageTests.swift`
- Modify: `Tests/CockpitClientCoreTests/ConnectionControllerTests.swift`

**Normative design:** `docs/superpowers/specs/2026-08-06-cockpit-phase-1-protocol-1-1-design.md`。该文档已经逐项批准，固定本任务的 Swift 领域类型、tagged Codable、protobuf field number、enum numeric value、oneof、ChannelID、校验顺序和 malformed-message 行为；实现不得重新选择 wire shape。Protocol 1.1 从本任务合入起成为冻结 ABI，后续只允许 additive evolution。

**Contract:**

```swift
public typealias WindowID = CockpitID<WindowScope>
public typealias ClientInstanceID = CockpitID<ClientInstanceScope>
public typealias EditLeaseID = CockpitID<EditLeaseScope>
public typealias DocumentID = CockpitID<DocumentScope>
public typealias ViewerID = CockpitID<ViewerScope>
public typealias InputLeaseID = CockpitID<InputLeaseScope>
public typealias DeletionOperationID = CockpitID<DeletionOperationScope>

public enum WorkspaceContextID: Hashable, Codable, Sendable {
    case project(ProjectID)
    case conversation(ConversationID)
}

public struct ResolvedWorkspaceContext: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let projectID: ProjectID
    public let conversationID: ConversationID?
    public let environmentID: EnvironmentID
    public let workspaceRootIdentity: String
}

public struct ActiveContext: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let projectID: ProjectID
    public let conversationID: ConversationID?
    public let environmentID: EnvironmentID
    public let workspaceRootIdentity: String
    public let generation: UInt64
}
```

现有 `DocumentSessionID`/`DocumentSessionScope` 在本任务迁移为 `DocumentID`/`DocumentScope`；仓库内调用点和测试一起更新，不保留两套文档身份。`TextPosition`、`TextRange`、`DocumentViewState` 与 `TabRecord` 在本任务定义，供 Task 5 直接消费；Task 5 不再重复定义这些基础值。`TabRecord.Resource` 固定为 `.file(DocumentID)`、`.terminal(TerminalSessionID)`、`.newTabPicker`，并使用批准设计中的显式 tagged Codable 和 resource/view-state 组合校验。

`TerminalInput` 固定为 RequestContext + TerminalSessionID + InputLeaseID + inputSequence envelope，并以 oneof 定义 text、key、paste、mouse、resize、signal。key 使用 Cockpit `1/2/3` action、Unicode logical key、USB HID physical key 与固定 modifier bits；Cockpit `1 PRESS`/`2 REPEAT`/`3 RELEASE` 分别显式转换为 Ghostty press/repeat/release，禁止使用 Ghostty ordinal。mouse 使用 `1...4` action、固定 button bits 与 Q16.16 cell wheel；signal 只允许 interrupt/quit/suspend/continue，且只走 Channel 0。signal capability 控制当前 foreground job，并允许 SIGINT/SIGQUIT/SIGTSTP/SIGCONT 按 Darwin 语义结束、中断、挂起或继续该 job；input capability 写入的 terminal-driver Ctrl+C/Ctrl+\\ 同样可以产生 SIGINT/SIGQUIT。terminate capability 独立控制整个 TerminalSession process group 及 lifecycle/archive state。不得把 AppKit `NSEvent`、IME preedit 或本地路径放入协议。

协议版本从 `1.0` 升为 `1.1`。Channel 固定为：

```swift
extension ChannelID {
    public static let control = ChannelID(rawValue: 0)
    public static let terminalOutput = ChannelID(rawValue: 1)
    public static let terminalInput = ChannelID(rawValue: 2)
    public static let documentEdits = ChannelID(rawValue: 3)
    public static let fileTreeEvents = ChannelID(rawValue: 4)
    public static let bulk = ChannelID(rawValue: 5)
}
```

所有 Phase 1 request/event 复用同一个 `RequestContext`：protocol version、ClientInstanceID、WindowID、WorkspaceContextID、EnvironmentID、ActiveContextGeneration、RequestID。terminal output 的 sequence/ack 使用现有 32-byte `FrameHeader`，protobuf 不复制第二套传输序号。

`cockpit.proto` 只新增批准设计列出的 WorkspaceContextID、RequestContext、TerminalInput 子图与 Task 15 直接消费的 TerminalArchiveManifest 子图。TabRecord 和 DocumentViewState 不进入 protobuf；`DocumentMessages.swift` 只提供 DocumentID 的显式 UUID 字符串映射工具。archive 使用 oneof exit status 与 `google.protobuf.Timestamp`；路径只允许固定格式的单文件名；SHA-256 固定 32 bytes；映射器拒绝缺字段、重复 chunk name、倒序/重叠 sequence、非法 timestamp/exit status 和绝对路径，并接受批准设计明确允许的 chunk sequence 间隔。

- [ ] **Step 1: 写领域值与 protobuf round-trip 失败测试**

先写且只写测试，不创建 production 类型或 mapper：

- `IdentifiersTests.swift`：新增 ID、DocumentSessionID 完整迁移与 ChannelID `0...5`；
- `WorkspaceModelsTests.swift`：project/conversation 不变量、`workspaceRootIdentity` 非空、ResolvedWorkspaceContext、RequestContext negotiated-version 完全匹配/不匹配和 `A(17) -> B(18) -> A(19)`；
- `DocumentModelsTests.swift`：一基 TextPosition、anchor/active 方向、horizontal scroll finite/nonnegative、三种 Tab resource、tagged Codable 与非法 view-state 组合；
- `TerminalModelsTests.swift`：key/mouse/resize/signal 数值和领域校验、text/paste 非空及 16 MiB byte-count 边界、SHA-256、exit status 与 archive range/name；
- `Phase1MessageTests.swift`：批准 schema 的全部 round-trip、unknown field/oneof/enum、非法 UUID/scalar/hash/path/timestamp/sequence、signal Channel 0/其他 input Channel 2 的 encoder/decoder route、完整 protobuf Frame 上限、ProtocolMappingError redaction 与 malformed wire code 3、encoder 拒绝 mutation 后的非法领域值；
- `ConnectionControllerTests.swift`：ProtocolVersion.current 与 handshake 从 1.0 更新为 1.1，并保留现有 negotiation 行为。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitTypesTests|CockpitProtocolTests|CockpitClientCoreTests.ConnectionControllerTests'
```

Expected: 失败，原因是 Phase 1 类型、消息和 protocol 1.1 尚不存在。

- [ ] **Step 3: 实现类型、protobuf schema 和显式映射器**

严格按 normative design 实现：

1. 在 `Identifiers.swift` 完成 ID 迁移与 ChannelID；在 `ProtocolVersion.swift` 把 current 改为 1.1。
2. 在三个 CockpitTypes model 文件实现 normative design 冻结的 `CockpitDomainValidationError`、全部 public validating initializer/factory、所有带不变量 Codable 类型的显式 decode/encode validation path，以及 TabRecord tagged Codable。
3. 在 `cockpit.proto` 使用批准的固定 field number、enum value、oneof 与 Google Timestamp；不得添加额外业务 message。
4. 在三个 message mapper 文件只暴露 normative design 冻结的 `WorkspaceMessages`、`DocumentMessages`、`TerminalMessages` 精确入口；需要版本校验的 decode/encode 接收 negotiatedVersion，TerminalInput decode/encode 同时接收 ChannelID；`ProtocolMappingError.asWireProtocolError()` 是唯一 wire 转换入口并固定映射 malformed-message wire code 3。
5. Protocol 1.1 mapper 拒绝 SwiftProtobuf unknownFields、nil/unknown oneof 与 `.UNRECOGNIZED` enum；不得把 Swift Codable JSON 放入 protobuf bytes 字段。
6. 保持现有 32-byte FrameHeader 不变，terminal output protobuf 不增加 sequence/ack。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitTypesTests|CockpitProtocolTests|CockpitClientCoreTests.ConnectionControllerTests'
/usr/bin/git diff --check
git add Sources/CockpitTypes Sources/CockpitProtocol Tests/CockpitTypesTests Tests/CockpitProtocolTests Tests/CockpitClientCoreTests/ConnectionControllerTests.swift
git commit -m "feat: define phase 1 domain protocol"
```

---

### Task 3: 实现 SQLite 基础与 workspace.sqlite 迁移

**Depends on:** Task 2。

**Files:**

- Create: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Create: `Sources/CockpitPersistence/SQLiteConnection.swift`
- Create: `Sources/CockpitPersistence/SQLiteMigration.swift`
- Create: `Sources/CockpitPersistence/WorkspaceMigrations.swift`
- Create: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Create: `Tests/CockpitPersistenceTests/SQLiteConnectionTests.swift`
- Create: `Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift`
- Create: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`

**Contract:**

```swift
public protocol WorkspaceRepository: Sendable {
    func createProjectWithDirectEnvironment(_ input: NewProject) async throws -> Project
    func listProjects() async throws -> [Project]
    func createConversation(_ input: NewConversation) async throws -> Conversation
    func listConversations(projectID: ProjectID) async throws -> [Conversation]
    func renameConversation(id: ConversationID, title: String) async throws
    func resolve(_ contextID: WorkspaceContextID) async throws -> ResolvedWorkspaceContext
}
```

Migration v1 一次创建 `projects`、`environments`、`conversations`、`documents`、`conversation_deletions` 和 `schema_migrations`；本任务不创建 `client_workspace_states`。约束固定为：一个规范化 root identity 只能对应一个 Environment；Phase 1 一个数据库最多一个 Project；Conversation.environment_id 必须引用所属 Project.base_environment_id。`Environment.gitCommonDirectory` 与 `NewProject.gitCommonDirectory` 可空，非 Git 目录以 NULL 持久化。

- [ ] **Step 1: 写失败测试**

覆盖 WAL、foreign keys、busy timeout、migration v1 事务回滚、Project+Direct Environment 原子创建、第二个 Project 被 `phaseOneProjectLimit` 拒绝、多个 Conversation 共享 base Environment、非 Git Project 的空 gitCommonDirectory 创建与重开解析，以及显式关闭后只凭 databaseURL 重建 repository 仍能枚举完整 Conversation 并保持 Project/Conversation/Environment 解析结果不变；本任务不写布局持久化测试。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter CockpitPersistenceTests
```

Expected: 失败，原因是 SQLite 封装、迁移和 repository 尚不存在。

- [ ] **Step 3: 实现单 actor 连接与迁移**

`SQLiteConnection` 是 actor；每个公开写操作使用 `BEGIN IMMEDIATE`；启动执行 `PRAGMA journal_mode=WAL`、`PRAGMA foreign_keys=ON`、`PRAGMA busy_timeout=5000`；所有 bind 使用 sqlite bind API，不拼接用户值。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter CockpitPersistenceTests
/usr/bin/git diff --check
git add Sources/CockpitHostCore/WorkspaceRepository.swift Sources/CockpitPersistence Tests/CockpitPersistenceTests
git commit -m "feat: persist direct workspace state"
```

---

### Task 4: 实现 Project、Direct Conversation 与 Host 控制面

**Depends on:** Task 3。

**Files:**

- Create: `Sources/CockpitHostCore/WorkspaceService.swift`
- Create: `Sources/CockpitHostCore/WorkspaceCommandRouter.swift`
- Create: `Sources/CockpitWorkspace/SecurityScopedProjectRoot.swift`
- Create: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Create: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Create: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Create: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Create: `Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift`
- Create: `Tests/CockpitLocalTransportTests/HostXPCTests.swift`
- Modify: `Package.swift`

**Contract:**

```swift
public protocol WorkspaceServing: Sendable {
    func addProject(bookmark: Data, displayName: String) async throws -> ProjectSnapshot
    func listWorkspace() async throws -> WorkspaceSnapshot
    func createDirectConversation(projectID: ProjectID) async throws -> Conversation
    func renameConversation(id: ConversationID, title: String) async throws
    func resolveContext(_ id: WorkspaceContextID) async throws -> ResolvedWorkspaceContext
}
```

Host 解析 security-scoped bookmark、取得 canonical path 与 volume/file resource identity，并把绝对路径留在 Host 内。App 和协议只传 ProjectID、EnvironmentID 与 RelativePath。

- [ ] **Step 1: 写失败测试**

覆盖：添加目录后自动得到 Project Context、没有 Conversation、没有 TerminalSession；创建两个 Conversation 都解析到同一个 EnvironmentID；Project 行持续可选；损坏或失效 bookmark 返回真实 Cocoa error domain/code；XPC 拒绝非当前 UID。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitHostCoreTests|CockpitLocalTransportTests'
```

Expected: 失败，原因是 WorkspaceServing 与 Host XPC 命令不存在。

- [ ] **Step 3: 实现服务与 Composition Root**

`WorkspaceKernelRegistry` 以 EnvironmentID 为键；Project Context 和 Conversation Context 解析时返回同一 Kernel 实例。`Applications/CockpitHost/main.swift` 只创建 StorageLocations、Repository、WorkspaceService 和 XPC export。SwiftPM 的 `CockpitHost` target 依赖 `CockpitPersistence` 与 `CockpitWorkspace`，`CockpitHostCoreTests` target 依赖 `CockpitWorkspace`。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitHostCoreTests|CockpitLocalTransportTests'
/usr/bin/git diff --check
git add Package.swift Sources/CockpitHostCore Sources/CockpitWorkspace Sources/CockpitLocalTransport Applications/CockpitHost Tests/CockpitHostCoreTests Tests/CockpitLocalTransportTests
git commit -m "feat: add direct workspace control plane"
```

---

### Task 5: 实现 ActiveContext generation 与 Context 布局恢复

**Depends on:** Task 4。

**Files:**

- Modify: `Sources/CockpitTypes/WorkspaceModels.swift`
- Create: `Sources/CockpitClientCore/ActiveContextController.swift`
- Create: `Sources/CockpitClientCore/WorkspaceClientState.swift`
- Create: `Sources/CockpitLocalTransport/ClientIdentityStore.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Modify: `Sources/CockpitPersistence/WorkspaceMigrations.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Create: `Tests/CockpitClientCoreTests/ActiveContextControllerTests.swift`
- Create: `Tests/CockpitClientCoreTests/WorkspaceClientStateTests.swift`
- Create: `Tests/CockpitLocalTransportTests/ClientIdentityStoreTests.swift`
- Modify: `Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift`
- Modify: `Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift`
- Modify: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`

**Contract:**

```swift
public actor ActiveContextController {
    public func select(_ context: ResolvedWorkspaceContext) -> ActiveContext
    public func accepts(generation: UInt64) -> Bool
    public func current() -> ActiveContext?
}

public struct ClientWorkspaceStateKey: Hashable, Codable, Sendable {
    public let deviceID: DeviceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID

    public init(deviceID: DeviceID,
                windowID: WindowID,
                workspaceContextID: WorkspaceContextID)
}

public struct SidebarState: Hashable, Codable, Sendable {
    public var isCollapsed: Bool
    public init(isCollapsed: Bool)
}

public struct SplitViewState: Hashable, Codable, Sendable {
    public var leadingPaneWidth: Double
    public var trailingPaneWidth: Double

    public init(validatingLeadingPaneWidth leadingPaneWidth: Double,
                trailingPaneWidth: Double) throws
    public func validated() throws -> Self
}

public struct ClientWorkspaceState: Hashable, Codable, Sendable {
    public let key: ClientWorkspaceStateKey
    public var tabs: [TabRecord]
    public var selectedTabID: TabID?
    public var sidebar: SidebarState
    public var splitView: SplitViewState

    public init(validatingKey key: ClientWorkspaceStateKey,
                tabs: [TabRecord],
                selectedTabID: TabID?,
                sidebar: SidebarState,
                splitView: SplitViewState) throws
    public func validated() throws -> Self
}
```

`ClientWorkspaceStateKey`、`ClientWorkspaceState`、`SidebarState` 与 `SplitViewState` 在本任务加入 `CockpitTypes/WorkspaceModels.swift`，供 HostCore 与 ClientCore 共同依赖；HostCore 永远不依赖 ClientCore。`SplitViewState` 的宽度必须有限且不小于 0；state 拒绝重复 TabID，非空 selectedTabID 必须引用 tabs。`WorkspaceClientState.swift` 只实现 ClientCore 的状态协调逻辑，不拥有这些共享类型。`TabRecord`、`TextPosition`、`TextRange` 与 `DocumentViewState` 直接使用 Task 2 已批准并实现的 CockpitTypes 领域值，不在本任务重复定义。Generation 从进程内 1 单调递增，不写数据库。每个异步 UI response/event 必须先通过 `accepts(generation:)`，相同 Context 的旧 generation 也被拒绝。file `TabRecord` 按 WorkspaceContext 保存 `DocumentViewState`；文本仍由 Environment 级 DocumentID 共享。

Task 5 在 `WorkspaceMigrations` 新增 migration v2，且只创建 `client_workspace_states(device_id, window_id, context_kind, context_id, state_json)`；复合主键固定为 `(device_id, window_id, context_kind, context_id)`。`state_json` 是 `ClientWorkspaceState` 的 UTF-8 Codable JSON，写入前和读取后都执行批准设计中的 validation path。`WorkspaceRepository` 从本任务起增加：

```swift
func loadClientState(_ key: ClientWorkspaceStateKey) async throws -> ClientWorkspaceState?
func saveClientState(_ state: ClientWorkspaceState) async throws
```

`ClientIdentityStore` 使用可注入的 Keychain/Preferences ports：DeviceID 以 service `dev.cockpit.client-identity`、account `device-id-v1` 持久化；Phase 1 主窗口的 WindowID 以 preferences key `main-window-id-v1` 持久化；ClientInstanceID 每次 App 启动重新生成。生产实现只在 App composition root 使用，测试使用 UUID 隔离的 service 与独立 `UserDefaults` suite。

- [ ] **Step 1: 写失败测试**

使用固定序列 `A(17) -> B(18) -> A(19)` 断言 17 的文件树、Document 与布局结果均不被应用；断言 migration v1 数据库升级到 v2 后才出现 `client_workspace_states`，v2 事务回滚不留下表或版本记录；断言 Project Context 和两个 Conversation 各自恢复不同 tabs/selectedTab/sidebar/splitView/cursor/selection/scroll，同时引用同一个 DocumentID；覆盖非法 split width、重复 TabID、selectedTabID 不存在及非法 Codable JSON 拒绝；重建 store 后 DeviceID 和主 WindowID 不变，ClientInstanceID 改变。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'activeContextGenerationRejectsEveryStaleResultKindAcrossRepeatedContextSelection|workspaceClientStateCoordinatesValidatedValuesByExactContextKey|splitViewRejectsNonfiniteAndNegativeWidthsThroughEveryValidationPath|clientWorkspaceState(RecursivelyRejectsInvalidTabsAndSelection|CodableRejectsMutatedInvalidDomainValues)|clientIdentityPersistsDeviceAndMainWindowAcrossStoresButNotClientInstance|invalidPersisted(DeviceIDFailsClosedWithoutOverwritingKeychain|MainWindowIDFailsClosedWithoutOverwritingPreferences)|createsProjectAndDirectEnvironmentAtomically|failedEnvironmentInsertRollsBackProjectAndEnvironment|rejectsASecondProjectAtThePhaseOneLimit|conversationsShareTheProjectBaseEnvironment|reopening(PreservesProjectConversationAndEnvironmentResolution|RepositoryEnumeratesAllConversationsFromDatabaseURL)|repositoryTextValuesRoundTripEmbeddedNUL|nonGitProjectRoundTripsWithoutGitCommonDirectory|clientWorkspace(LayoutsRoundTripIndependentlyAcrossProjectAndConversations|State(SaveValidatesAndUpsertsOneExactKey|LoadRejectsSQLJSONKeyMismatchAndMalformedStoredValues))|workspaceMigration(sCreateOnlyTheApprovedTables|UpgradesV1DataToV2AndCreatesExactClientStateSchema)|failedV2MigrationLeavesV1DataWithoutV2TableOrVersion|failedMigrationRollsBackItsSchemaChanges|documentsMigration(UsesEnvironmentLocatorAndApprovedPersistentState|EnforcesLocatorDirtyStateAndNonnegativeVersions)|environmentsMigrationAllowsMissingGitCommonDirectory'
```

Expected: 失败，原因是 ActiveContextController 与布局模型不存在。

- [ ] **Step 3: 实现 actor 与 repository 映射**

在 CockpitTypes 实现共享 client-state 值与显式 Codable validation；ClientCore 只保存稳定 ID 和值类型，不导入 AppKit、XPC 或 SQLite3。WorkspaceMigrations 实现 v2；SQLite repository 实现 load/save，布局保存是 Host 的单条 upsert，Terminal tab 只保存 TerminalSessionID 引用。HostCore 只依赖 CockpitTypes 中的共享值，不导入或依赖 ClientCore。

Task 4 的 `InMemoryWorkspaceRepository` 测试替身同步实现新增的 client-state load/save requirements，并使用内存字典保持真实协议语义；该维护变更只保证现有 HostCore 测试目标继续编译，不增加 Task 5 产品行为。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'activeContextGenerationRejectsEveryStaleResultKindAcrossRepeatedContextSelection|workspaceClientStateCoordinatesValidatedValuesByExactContextKey|splitViewRejectsNonfiniteAndNegativeWidthsThroughEveryValidationPath|clientWorkspaceState(RecursivelyRejectsInvalidTabsAndSelection|CodableRejectsMutatedInvalidDomainValues)|clientIdentityPersistsDeviceAndMainWindowAcrossStoresButNotClientInstance|invalidPersisted(DeviceIDFailsClosedWithoutOverwritingKeychain|MainWindowIDFailsClosedWithoutOverwritingPreferences)|createsProjectAndDirectEnvironmentAtomically|failedEnvironmentInsertRollsBackProjectAndEnvironment|rejectsASecondProjectAtThePhaseOneLimit|conversationsShareTheProjectBaseEnvironment|reopening(PreservesProjectConversationAndEnvironmentResolution|RepositoryEnumeratesAllConversationsFromDatabaseURL)|repositoryTextValuesRoundTripEmbeddedNUL|nonGitProjectRoundTripsWithoutGitCommonDirectory|clientWorkspace(LayoutsRoundTripIndependentlyAcrossProjectAndConversations|State(SaveValidatesAndUpsertsOneExactKey|LoadRejectsSQLJSONKeyMismatchAndMalformedStoredValues))|workspaceMigration(sCreateOnlyTheApprovedTables|UpgradesV1DataToV2AndCreatesExactClientStateSchema)|failedV2MigrationLeavesV1DataWithoutV2TableOrVersion|failedMigrationRollsBackItsSchemaChanges|documentsMigration(UsesEnvironmentLocatorAndApprovedPersistentState|EnforcesLocatorDirtyStateAndNonnegativeVersions)|environmentsMigrationAllowsMissingGitCommonDirectory'
/usr/bin/git diff --check
git add Sources/CockpitTypes/WorkspaceModels.swift Sources/CockpitClientCore Sources/CockpitLocalTransport/ClientIdentityStore.swift Sources/CockpitHostCore/WorkspaceRepository.swift Sources/CockpitPersistence/WorkspaceMigrations.swift Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift Tests/CockpitClientCoreTests Tests/CockpitLocalTransportTests/ClientIdentityStoreTests.swift Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift
git commit -m "feat: isolate workspace context state"
```

---

### Task 6: 实现延迟文件树与 FSEvents 对账

**Depends on:** Task 5。

**Files:**

- Modify: `Sources/CockpitTypes/WorkspaceModels.swift`
- Create: `Sources/CockpitHostCore/FileTreeProviding.swift`
- Create: `Sources/CockpitWorkspace/FileTreeProvider.swift`
- Create: `Sources/CockpitWorkspace/FileSystemEventSource.swift`
- Create: `Sources/CockpitWorkspace/FileTreeReconciler.swift`
- Create: `Tests/CockpitWorkspaceTests/FileTreeProviderTests.swift`
- Create: `Tests/CockpitWorkspaceTests/FileTreeReconcilerTests.swift`

**Contract:**

```swift
public enum WorkspaceDirectory: Hashable, Codable, Sendable {
    case root
    case relative(RelativePath)
}

public protocol FileTreeProviding: Sendable {
    func children(
        environmentID: EnvironmentID,
        at directory: WorkspaceDirectory,
        generation: UInt64
    ) async throws -> FileTreeSnapshot

    func changes(
        environmentID: EnvironmentID,
        after revision: UInt64
    ) -> AsyncThrowingStream<FileTreeDelta, Error>
}
```

文件树只读取被展开目录的直接子项。FSEvents 只产生 invalidation；`FileTreeReconciler` 重新枚举受影响目录，以文件系统结果生成单调 revision 的 insert/remove/update delta。

- [ ] **Step 1: 写失败测试**

用记录访问路径的 fake filesystem 断言展开根目录不访问孙目录；同一 Environment 的两个 Context 返回相同 provider identity；FSEvents drop/root-changed 触发已展开目录的定向重扫；旧 generation 的结果被客户端拒绝；符号链接以叶节点展示且不跟随扫描。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter CockpitWorkspaceTests
```

Expected: 失败，原因是 FileTree provider、event source 和 reconciler 不存在。

- [ ] **Step 3: 实现 actor provider 和 Darwin FSEventStream adapter**

`RelativePath` 继续拒绝空字符串；只有 `WorkspaceDirectory.root` 表示 Environment 根。每个 Environment 一个 `FileTreeProvider` actor；目录项排序固定为目录优先、再按 `localizedStandardCompare`；inode 不作为跨重启身份，协议身份使用 EnvironmentID + RelativePath。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter CockpitWorkspaceTests
/usr/bin/git diff --check
git add Sources/CockpitTypes/WorkspaceModels.swift Sources/CockpitHostCore/FileTreeProviding.swift Sources/CockpitWorkspace Tests/CockpitWorkspaceTests
git commit -m "feat: add lazy environment file tree"
```

---

### Task 7: 实现根目录内串行文件管理

**Depends on:** Task 6。

**Files:**

- Create: `Sources/CockpitHostCore/FileOperationServing.swift`
- Create: `Sources/CockpitWorkspace/WorkspaceRootHandle.swift`
- Create: `Sources/CockpitWorkspace/FileOperationCoordinator.swift`
- Create: `Sources/CockpitWorkspace/FileOperationError.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Create: `Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift`
- Create: `Tests/CockpitWorkspaceTests/FileOperationCoordinatorTests.swift`
- Modify: `Tests/CockpitLocalTransportTests/HostXPCTests.swift`

**Contract:**

```swift
public enum FileOperation: Sendable {
    case createFile(parent: WorkspaceDirectory, name: String)
    case createDirectory(parent: WorkspaceDirectory, name: String)
    case rename(source: RelativePath, newName: String)
    case move(source: RelativePath, destinationDirectory: WorkspaceDirectory)
    case trash(path: RelativePath)
}

public protocol FileOperationServing: Sendable {
    func perform(
        _ operation: FileOperation,
        in environmentID: EnvironmentID
    ) async throws -> FileOperationResult
}
```

`WorkspaceRootHandle` 持有 root directory FD。祖先遍历使用 `openat(..., O_DIRECTORY | O_NOFOLLOW)`；创建使用 `openat`/`mkdirat`；重命名和移动使用 `renameat`；删除在重新验证 file identity 后调用 macOS Trash，不调用 unlink/rmdir。

- [ ] **Step 1: 写失败测试**

断言根目录下 create/move 成功；`..`、绝对路径、空文件名、`/`、NUL、符号链接祖先和跨根目标全部被拒绝；失败操作不增加 tree revision、不更新 Document path、不更新 tabs；成功 rename/move 返回旧 path 与新 path；trash 后物理文件位于系统废纸篓且源路径消失。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitWorkspaceTests.FileOperationCoordinatorTests|CockpitLocalTransportTests.HostXPCTests'
```

Expected: 失败，原因是 WorkspaceRootHandle 与文件操作协调器不存在。

- [ ] **Step 3: 实现每 Environment 一个串行 coordinator**

所有元数据更新发生在文件系统操作成功之后；成功后同一个 actor 依次更新 Document locator、Context tab 引用和 FileTree revision。`WorkspaceService` 通过 Host XPC 暴露类型化 `performFileOperation` 低频命令，并在路由前校验当前 Context→Environment；App 不取得 root URL/FD。错误保留真实 URL、`NSPOSIXErrorDomain`/`NSCocoaErrorDomain` 与 code。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitWorkspaceTests.WorkspaceRootHandleTests|CockpitWorkspaceTests.FileOperationCoordinatorTests|CockpitLocalTransportTests.HostXPCTests'
/usr/bin/git diff --check
git add Sources/CockpitHostCore Sources/CockpitWorkspace Sources/CockpitLocalTransport Tests/CockpitWorkspaceTests Tests/CockpitLocalTransportTests/HostXPCTests.swift
git commit -m "feat: manage files inside environment root"
```

---

### Task 8: 实现 UTF-8 文档编解码、恢复日志与原子写入

**Depends on:** Task 7。

**Files:**

- Modify: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Modify: `Sources/CockpitProtocol/DocumentMessages.swift`
- Create: `Sources/CockpitHostCore/DocumentServing.swift`
- Create: `Sources/CockpitWorkspace/DocumentCodec.swift`
- Create: `Sources/CockpitWorkspace/DocumentRecoveryLog.swift`
- Create: `Sources/CockpitWorkspace/AtomicFileWriter.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentCodecTests.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentRecoveryLogTests.swift`
- Create: `Tests/CockpitWorkspaceTests/AtomicFileWriterTests.swift`
- Modify: `Tests/CockpitProtocolTests/Phase1MessageTests.swift`

**Contract:**

```swift
public enum UTF8Signature: UInt8, Codable, Sendable { case none, bom }
public enum LineEnding: UInt8, Codable, Sendable { case lf, crlf }

public struct LineEndingProfile: Codable, Sendable {
    public let preferred: LineEnding
    public let originalByLineBreak: [LineEnding]
}

public struct DecodedDocument: Sendable {
    public let text: String
    public let signature: UTF8Signature
    public let lineEndings: LineEndingProfile
    public let diskFingerprint: DiskFingerprint
}
```

恢复日志格式固定为 length-delimited protobuf records：magic `CKDR`、format version 1、DocumentID、documentVersion、clientSequence、SHA-256、UTF-8 edit payload。每次 acknowledgement 前 `fsync` 日志；checkpoint 原子替换；恢复只重放完整且 hash 正确的 record，截断尾记录被忽略并保留诊断。

- [ ] **Step 1: 写失败测试**

覆盖 UTF-8、UTF-8 BOM、LF、CRLF、混合换行打开与逐换行 round-trip、NUL/无效 UTF-8 拒绝、BOM round-trip、临时文件与目标同目录、fsync 后 atomic rename、写入失败保留原文件、日志尾部截断恢复到最后确认版本。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitProtocolTests.Phase1MessageTests|CockpitWorkspaceTests.DocumentCodecTests|CockpitWorkspaceTests.DocumentRecoveryLogTests|CockpitWorkspaceTests.AtomicFileWriterTests'
```

Expected: 失败，原因是 codec、recovery log 和 atomic writer 不存在。

- [ ] **Step 3: 实现无自动保存的持久层**

`DocumentCodec` 给 Monaco 的文本统一为 LF，同时保存每个原始换行的类型；未触及的换行逐个保留，编辑新增的换行使用 `preferred`（LF/CRLF 数量多者，数量相同时取文件首个换行，无换行时取 LF）。`AtomicFileWriter` 保留原文件 POSIX permissions；保存成功后更新 fingerprint；恢复日志与磁盘文件分离，保存成功后写 checkpoint 并压缩已持久化 records。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitProtocolTests.Phase1MessageTests|CockpitWorkspaceTests.DocumentCodecTests|CockpitWorkspaceTests.DocumentRecoveryLogTests|CockpitWorkspaceTests.AtomicFileWriterTests'
/usr/bin/git diff --check
git add Sources/CockpitProtocol/Proto/cockpit.proto Sources/CockpitProtocol/DocumentMessages.swift Sources/CockpitHostCore/DocumentServing.swift Sources/CockpitWorkspace Tests/CockpitProtocolTests/Phase1MessageTests.swift Tests/CockpitWorkspaceTests
git commit -m "feat: add recoverable utf8 document storage"
```

---

### Task 9: 实现 DocumentActor、编辑租约、保存与外部冲突

**Depends on:** Task 8。

**Files:**

- Create: `Sources/CockpitWorkspace/DocumentActor.swift`
- Create: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Sources/CockpitWorkspace/FileTreeReconciler.swift`
- Create: `Sources/CockpitClientCore/DocumentDataTransport.swift`
- Create: `Sources/CockpitClientCore/DocumentClientController.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentActorTests.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentRegistryTests.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentExternalChangeTests.swift`
- Create: `Tests/CockpitClientCoreTests/DocumentClientControllerTests.swift`

**Contract:**

```swift
public actor DocumentActor {
    public func snapshot() -> DocumentSnapshot
    public func acquireEditLease(client: ClientInstanceID) throws -> EditLease
    public func transferEditLease(from: EditLeaseID, to: ClientInstanceID) throws -> EditLease
    public func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement
    public func flush(through clientSequence: UInt64) async throws -> UInt64
    public func save(expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot
    public func discard() async throws -> DocumentSnapshot
    public func handleExternalChange(_ event: ExternalDocumentChange) async throws -> DocumentSnapshot
}
```

一个 `(EnvironmentID, RelativePath)` 对应一个稳定 DocumentID。Cockpit rename/move 原子更新 locator 并保持 DocumentID；同一文档跨 Context 共享 actor。一个 lease 可写，其他 viewer 只读。

`DocumentClientController` 只依赖 `DocumentDataTransport` port，不引用 DocumentActor、XPC 或 UDS。`FileTreeReconciler` 每次磁盘重扫把受影响 RelativePath 集合交给 `DocumentRegistry`; registry 只通知已经打开的 DocumentActor，并读取真实磁盘状态生成 `ExternalDocumentChange`。

- [ ] **Step 1: 写失败测试**

覆盖 baseVersion/clientSequence 单调校验、重复 edit 幂等确认、sequence 缺口触发 resync、错误 lease 拒绝、flush barrier、保存清 dirty、rename/move 后 DocumentID 不变、崩溃恢复只包含已确认 edit；用真实临时目录分别改写和删除磁盘文件，触发 reconciler 后断言干净文档重载、脏文档进入 conflict、外部删除保留 Host 文本并标记 missing。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitWorkspaceTests.Document|CockpitClientCoreTests.DocumentClientControllerTests'
```

Expected: 失败，原因是 DocumentActor、registry 与 client controller 不存在。

- [ ] **Step 3: 实现 actor 与客户端停止/重同步状态机**

Monaco 本地 edit 在 Host acknowledgement 前只存在于客户端副本；Host 每次接受 edit 后先写恢复日志，再返回新 documentVersion。版本或 lease 错误使 client controller 进入 `.resynchronizing`，在完整 snapshot 应用前不继续发送。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitWorkspaceTests.Document|CockpitClientCoreTests.DocumentClientControllerTests'
/usr/bin/git diff --check
git add Sources/CockpitWorkspace Sources/CockpitClientCore Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift Tests/CockpitWorkspaceTests Tests/CockpitClientCoreTests
git commit -m "feat: coordinate authoritative documents"
```

---

### Task 10: 接入每窗口一个 Monaco WKWebView

**Depends on:** Task 9。

**Files:**

- Modify: `EditorRuntime/src/protocol.mjs`
- Modify: `EditorRuntime/src/bootstrap.ts`
- Create: `EditorRuntime/test/protocol.test.mjs`
- Create: `Sources/CockpitClientCore/FileTreeDataTransport.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Create: `Sources/CockpitLocalTransport/UnixDomainSocket.swift`
- Create: `Sources/CockpitLocalTransport/HostDataPlaneServer.swift`
- Create: `Sources/CockpitLocalTransport/HostDataPlaneClient.swift`
- Create: `Sources/CockpitLocalTransport/HostDataPlaneTicket.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoMessage.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoBridge.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoEditorViewController.swift`
- Create: `Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift`
- Create: `Tests/CockpitAppTests/MonacoBridgeTests.swift`
- Modify: `Tests/ProcessIntegrationTests/app-bundle-layout.zsh`
- Modify: `project.yml`

**Contract:**

```typescript
type NativeToMonaco =
  | { type: "open"; uri: string; language: string; text: string; documentVersion: number; editLeaseID: string; viewState: ViewState | null }
  | { type: "ack"; uri: string; clientSequence: number; documentVersion: number }
  | { type: "replace"; uri: string; text: string; documentVersion: number; editLeaseID: string }
  | { type: "setWritable"; uri: string; writable: boolean };

type MonacoToNative =
  | { type: "ready" }
  | { type: "edit"; uri: string; editLeaseID: string; baseVersion: number; clientSequence: number; changes: TextChange[] }
  | { type: "save"; uri: string; throughClientSequence: number }
  | { type: "viewState"; uri: string; value: ViewState };
```

`MonacoEditorViewController` 在一个 Window 生命周期内只创建一个 WKWebView；每个 DocumentID 使用 `cockpit-file://{environmentID}/{percentEncodedRelativePath}` model URI；切换页签只调用 `editor.setModel`。Monaco `saveViewState` 的 cursor/selection/scroll 映射到 Task 5 的 Context-local `DocumentViewState`，切回同一 Context/file 时恢复。

Host 本地数据面固定为 `/private/tmp/cockpit.{uid}/host/{serviceNamespace}/host.sock`，production namespace 为 `default`；目录 `0700`、socket `0600`。Host XPC 为当前 ClientInstanceID + WindowID + WorkspaceContextID + EnvironmentID + generation 签发 30 秒、单次消费的数据面票据。`HostDataPlaneServer` 完成 `getpeereid`、protocol 1.1 handshake 和票据校验后，只在 Channel 3 路由 document transaction/snapshot/ack，在 Channel 4 路由 lazy-tree request/delta。每条消息再次校验 Context 与 Environment 绑定、generation、documentVersion/tree revision；错误返回类型化 protocol error。

`HostDataPlaneClient` 实现 ClientCore 的 `DocumentDataTransport` 与 `FileTreeDataTransport` ports。`MonacoBridge` 只依赖 `DocumentClientController`，不得持有或导入 `DocumentActor`；文件树 UI 后续只依赖 `FileTreeDataTransport`。

- [ ] **Step 1: 写失败测试**

JS 测试断言 schema 拒绝未知消息、edit sequence 单调、model 复用和 replace 不产生回传 edit；Swift 测试断言一个 window factory 只创建一次 WebView、消息映射完整、Context-local view state round-trip、旧 generation 被丢弃、WebContent crash 后经 DocumentDataTransport 获取 acknowledged snapshot 重建。Host 数据面进程测试断言票据单次消费、错 UID/context/environment/generation/revision 被拒绝，document ack 与 file-tree delta 实际经过 UDS Channel 3/4。

- [ ] **Step 2: 运行失败测试**

```bash
fnm exec --using 26.7.0 pnpm --dir EditorRuntime test
/usr/bin/swift test --disable-automatic-resolution --filter HostDataPlaneTests
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -only-testing:CockpitAppTests/MonacoBridgeTests test
```

Expected: JS 和 App 测试失败，原因是双向 protocol 与 AppKit bridge 不存在。

- [ ] **Step 3: 实现 bundle-only WKWebView bridge**

WKWebView 禁止任意导航、网络请求和新窗口；只加载签名 App Bundle 中 `Contents/Resources/MonacoRuntime.bundle/index.html`。`WKScriptMessageHandlerWithReply` 只接受已知 schema 和当前 generation。

`project.yml` 把构建前已经由 `EditorRuntime/build.mjs` 原子产出的 `EditorRuntime/dist/MonacoRuntime.bundle` 作为 folder resource 复制到 `Contents/Resources/MonacoRuntime.bundle`；资源输入固定为 `index.html`、`editor.js`、`editor.js.map`、`editor.css`，任一缺失即构建失败。Task 10 和统一 gate 都先执行 pnpm build 再执行 XcodeGen；`app-bundle-layout.zsh` 断言四个文件存在、非 symlink、非空，且 App 内没有 `node_modules`、Node、pnpm 或 Monaco 源码。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
fnm exec --using 26.7.0 pnpm --dir EditorRuntime build
fnm exec --using 26.7.0 pnpm --dir EditorRuntime test
/usr/bin/swift test --disable-automatic-resolution --filter HostDataPlaneTests
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -only-testing:CockpitAppTests/MonacoBridgeTests test
Tests/ProcessIntegrationTests/app-bundle-layout.zsh
/usr/bin/git diff --check
git add EditorRuntime Sources/CockpitClientCore/FileTreeDataTransport.swift Sources/CockpitLocalTransport Applications/CockpitHost/main.swift Applications/CockpitApp/Monaco Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift Tests/CockpitAppTests Tests/ProcessIntegrationTests/app-bundle-layout.zsh project.yml Cockpit.xcodeproj Cockpit.xcworkspace
git commit -m "feat: bridge monaco document editing"
```

---

### Task 11: 构建 Cockpit Ghostty 轻量 fork 与稳定 C ABI

**Depends on:** Task 2。可在 Task 10 后执行以保持串行账本。

**Files:**

- Create: `Patches/ghostty/series`
- Create: `Patches/ghostty/0001-cockpit-external-vt-renderer.patch`
- Create: `Native/CockpitGhosttyBridge/include/cockpit_ghostty.h`
- Create: `Native/CockpitGhosttyBridge/include/module.modulemap`
- Create: `Native/CockpitGhosttyBridge/FrameFormat.md`
- Create: `Tools/build-ghostty-bridge.zsh`
- Create: `Tests/ToolingTests/ghostty-bridge.zsh`
- Modify: `Tools/verify-ghostty.zsh`
- Modify: `project.yml`

**Upstream boundary and hard gate:** 已初始化的 Phase 0 checkout `.worktrees/phase-0/ThirdParty/ghostty` 在本计划编写时为 commit `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` 且 clean；其中 `src/Surface.zig` 明确写明 Surface 创建并拥有 PTY，`include/ghostty.h` 没有外部 VT snapshot/delta 注入 API，`include/ghostty/vt.h` 标记 incomplete/work-in-progress，`src/lib_vt.zig` 导出 Terminal input encoding 与 RenderState。Task 11 执行时必须先在 Phase 1 worktree 重新通过 submodule HEAD/clean 和 `Tools/verify-ghostty.zsh --no-bootstrap`；任一门槛失败立即停止，不生成补丁。通过后实现总体架构已批准的固定版本轻量 fork，不改用 Ghostty 自己持有 App 内 PTY 的 Surface。

**C ABI:**

```c
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

#if defined(_WIN32)
#define COCKPIT_GHOSTTY_API __declspec(dllexport)
#else
#define COCKPIT_GHOSTTY_API __attribute__((visibility("default")))
#endif

typedef struct cockpit_ghostty_vt cockpit_ghostty_vt_t;
typedef struct cockpit_ghostty_renderer cockpit_ghostty_renderer_t;
typedef struct {
  const uint8_t *bytes;
  size_t length;
} cockpit_ghostty_bytes_t;

typedef enum {
  COCKPIT_GHOSTTY_MOD_SHIFT = 1u << 0,
  COCKPIT_GHOSTTY_MOD_CONTROL = 1u << 1,
  COCKPIT_GHOSTTY_MOD_ALT = 1u << 2,
  COCKPIT_GHOSTTY_MOD_SUPER = 1u << 3,
  COCKPIT_GHOSTTY_MOD_CAPS_LOCK = 1u << 4,
  COCKPIT_GHOSTTY_MOD_NUM_LOCK = 1u << 5,
  COCKPIT_GHOSTTY_MOD_SHIFT_RIGHT = 1u << 6,
  COCKPIT_GHOSTTY_MOD_CONTROL_RIGHT = 1u << 7,
  COCKPIT_GHOSTTY_MOD_ALT_RIGHT = 1u << 8,
  COCKPIT_GHOSTTY_MOD_SUPER_RIGHT = 1u << 9
} cockpit_ghostty_modifiers_t;
typedef enum {
  COCKPIT_GHOSTTY_KEY_PRESS = 1,
  COCKPIT_GHOSTTY_KEY_REPEAT = 2,
  COCKPIT_GHOSTTY_KEY_RELEASE = 3
} cockpit_ghostty_key_action_t;
typedef enum {
  COCKPIT_GHOSTTY_MOUSE_PRESS = 1,
  COCKPIT_GHOSTTY_MOUSE_RELEASE = 2,
  COCKPIT_GHOSTTY_MOUSE_MOTION = 3,
  COCKPIT_GHOSTTY_MOUSE_SCROLL = 4
} cockpit_ghostty_mouse_action_t;
typedef struct {
  uint32_t logical_key;
  uint32_t physical_key;
  uint32_t modifiers;
  uint8_t action;
  uint8_t reserved[3];
} cockpit_ghostty_key_event_t;
typedef struct {
  int32_t cell_x;
  int32_t cell_y;
  uint32_t buttons;
  int32_t wheel_x;
  int32_t wheel_y;
  uint32_t modifiers;
  uint8_t action;
  uint8_t reserved[3];
} cockpit_ghostty_mouse_event_t;

COCKPIT_GHOSTTY_API cockpit_ghostty_vt_t *cockpit_ghostty_vt_create(
    uint32_t columns, uint32_t rows, uint64_t scrollback_limit);
COCKPIT_GHOSTTY_API void cockpit_ghostty_vt_destroy(cockpit_ghostty_vt_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_feed(
    cockpit_ghostty_vt_t *, const uint8_t *, size_t);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_resize(
    cockpit_ghostty_vt_t *, uint32_t, uint32_t);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_snapshot(
    cockpit_ghostty_vt_t *, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_delta(
    cockpit_ghostty_vt_t *, uint64_t, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_scrollback(
    cockpit_ghostty_vt_t *, uint64_t, uint32_t, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_encode_key(
    cockpit_ghostty_vt_t *, const cockpit_ghostty_key_event_t *,
    cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_encode_paste(
    cockpit_ghostty_vt_t *, const uint8_t *, size_t, cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_vt_encode_mouse(
    cockpit_ghostty_vt_t *, const cockpit_ghostty_mouse_event_t *,
    cockpit_ghostty_bytes_t *);
COCKPIT_GHOSTTY_API void cockpit_ghostty_bytes_free(cockpit_ghostty_bytes_t);

COCKPIT_GHOSTTY_API cockpit_ghostty_renderer_t *cockpit_ghostty_renderer_create(
    void *ns_view, double scale);
COCKPIT_GHOSTTY_API void cockpit_ghostty_renderer_destroy(
    cockpit_ghostty_renderer_t *);
COCKPIT_GHOSTTY_API int cockpit_ghostty_renderer_apply(
    cockpit_ghostty_renderer_t *, const uint8_t *, size_t);
COCKPIT_GHOSTTY_API void cockpit_ghostty_renderer_resize(
    cockpit_ghostty_renderer_t *, uint32_t pixels_w, uint32_t pixels_h,
    double scale);
COCKPIT_GHOSTTY_API void cockpit_ghostty_renderer_set_visible(
    cockpit_ghostty_renderer_t *, bool);

#if defined(__cplusplus)
}
#endif
```

Task 11 的输入数值语义直接使用 Task 2 冻结的 Protocol 1.1 定义：logical key 是未加修饰键的 Unicode scalar，physical key 是 W3C/Chromium table 的 USB HID usage code；modifier 只允许 bit `0...9`；mouse buttons 使用 left/right/middle/button4...11 的 bit `0...10`；wheel 使用有符号 Q16.16 cell 单位。bridge 对 Cockpit action 与 Ghostty 内部 enum 做显式映射，不把 Ghostty ordinal 暴露为 ABI。以上补充不改变已批准 C struct 的字段顺序、类型或大小。

header 在 typedef 前完整定义 key/mouse event 的固定宽度 enum/struct。所有返回 bytes 均由 bridge 分配，成功时由调用方且只由调用方调用 `cockpit_ghostty_bytes_free`；失败时必须返回 `{NULL, 0}`。renderer create 在 destroy 前 retain 传入的 NSView；其余指针只在调用期间借用。

`FrameFormat.md` 是 CKGF v1 的规范源：网络字节序；固定 header 为 magic `CKGF`、u16 version、u8 kind（1 snapshot/2 delta/3 scrollback）、u8 flags、u64 base sequence、u64 output sequence、u32 rows、u32 columns、u32 section count；每个 section 是 u8 type + 3 reserved zero bytes + u32 byte length + payload。文档固定 palette/cursor/row/cell/grapheme/style/scrollback section 的字段顺序、宽度、合法 enum 和边界校验，并提供 snapshot、delta、scrollback 三个 golden byte fixture。CKGF 不再增加 CRC；UDS 外层使用现有 Frame 边界，归档使用 manifest SHA-256。单帧硬上限复用 `FrameHeader.maximumPayloadLength` 的 16 MiB。Delta 只包含 Ghostty `RenderState` dirty rows；snapshot 包含完整 viewport；scrollback 使用单独分页 frame。

- [ ] **Step 1: 写失败的 ABI/build smoke test**

测试先运行 `Tools/verify-ghostty.zsh --no-bootstrap`，核对 submodule commit 和 clean state，再把 `git archive` 解包到测试临时目录、按 `series` 应用补丁、使用 `.tools/zig/0.15.2/zig` 构建两份 arm64 macOS 产物。C 与 C++ harness 编译 header，VT/renderer 两端分别对三个 golden fixture 做逐字节验证；运行时执行 feed `red + hello + reset`、key/paste/mouse mode-aware encoding、snapshot、row delta、offscreen Metal apply，隐藏 renderer 后确认不请求新帧。

- [ ] **Step 2: 运行失败测试**

```bash
test "$(git -C ThirdParty/ghostty rev-parse HEAD)" = 332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28
test -z "$(git -C ThirdParty/ghostty status --short)"
Tools/verify-ghostty.zsh --no-bootstrap
Tests/ToolingTests/ghostty-bridge.zsh
```

Expected: 失败，原因是补丁、ABI header 和构建脚本不存在。

- [ ] **Step 3: 实现派生构建与轻量补丁**

`Tools/build-ghostty-bridge.zsh` 接受 `--configuration Debug|Release --output "$DERIVED_FILE_DIR/Ghostty"`；cache key 固定为 Ghostty commit + patch SHA-256 + Zig version + configuration + target triple。脚本只写 output 与临时目录，不写 `ThirdParty/ghostty`。产物固定为：

```text
${output}/include/CockpitGhostty/cockpit_ghostty.h
${output}/include/CockpitGhostty/module.modulemap
${output}/lib/libCockpitGhosttyVT.a
${output}/CockpitGhosttyRenderer.xcframework/
${output}/manifest.json
```

补丁只增加 Cockpit bridge root、外部 RenderState 输入和 build artifacts；不修改 Ghostty 键位、字体、shader、PTY 或配置语义。

- [ ] **Step 4: 接入 Xcode aggregate artifact target**

`project.yml` 新增 `CockpitGhosttyArtifacts` aggregate target，build script 的 inputs 固定为 submodule commit、`Patches/ghostty/**`、bridge header/modulemap、`Config/Toolchains/ghostty.env`，outputs 固定为上述四类产物。Cockpit 和 CockpitPTYKeeper 依赖它；renderer XCFramework 是静态 XCFramework，App 从其 macOS arm64 slice 链接静态 renderer library且不 embed，Keeper 只链接 VT static library；两者从派生 include/modulemap 设置 `SWIFT_INCLUDE_PATHS`、`LIBRARY_SEARCH_PATHS`、slice-specific linker path 与系统 Metal/CoreText/CoreGraphics 依赖。Xcode production target 设置 `COCKPIT_GHOSTTY_LINKED`；SwiftPM 测试构建编译 `GhosttyVTAdapter` 的 unavailable fallback（调用即抛 `ghosttyBridgeUnavailable`，没有未解析 C symbol），真实 bridge 由 Xcode build 和进程测试覆盖。Release build 不把 Zig、patch、source 或 manifest 放入 App Bundle。

- [ ] **Step 5: 运行 focused checks 并提交**

```bash
Tests/ToolingTests/ghostty-bridge.zsh
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation build
/usr/bin/git diff --check
git add Patches/ghostty Native/CockpitGhosttyBridge Tools/build-ghostty-bridge.zsh Tools/verify-ghostty.zsh Tests/ToolingTests/ghostty-bridge.zsh project.yml Cockpit.xcodeproj Cockpit.xcworkspace
git commit -m "feat: add cockpit ghostty bridge"
```

---

### Task 12: 实现 terminal.sqlite、Keychain worker secret 与 attach ticket

**Depends on:** Task 3、Task 11。

**Files:**

- Create: `Sources/CockpitTerminalCore/TerminalSessionRepository.swift`
- Create: `Sources/CockpitTerminalCore/TerminalSessionRecord.swift`
- Create: `Sources/CockpitTerminalCore/TerminalAttachTicket.swift`
- Create: `Sources/CockpitTerminalCore/TerminalSecurityPolicy.swift`
- Create: `Sources/CockpitTerminalCore/WorkerSecretDeriver.swift`
- Create: `Sources/CockpitPersistence/TerminalMigrations.swift`
- Create: `Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift`
- Create: `Sources/CockpitLocalTransport/InstallationMasterKeyStore.swift`
- Create: `Tests/CockpitPersistenceTests/SQLiteTerminalSessionRepositoryTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/WorkerSecretDeriverTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/TerminalAttachTicketTests.swift`
- Create: `Tests/CockpitLocalTransportTests/InstallationMasterKeyStoreTests.swift`

**Contract:**

```swift
public protocol TerminalSessionRepository: Sendable {
    func insertPreparing(_ record: TerminalSessionRecord, idempotencyKey: RequestID) async throws
    func markCommitted(sessionID: TerminalSessionID, workerID: WorkerInstanceID) async throws
    func markRunning(sessionID: TerminalSessionID, identity: CLIProcessIdentity) async throws
    func finish(sessionID: TerminalSessionID, state: TerminalLifecycleState,
                exitStatus: Int32?, latestSequence: UInt64,
                archiveManifest: RelativeArchivePath?) async throws
    func activeRecords() async throws -> [TerminalSessionRecord]
    func records(contextID: WorkspaceContextID) async throws -> [TerminalSessionRecord]
}
```

Migration v1 创建 `terminal_sessions`、`terminal_idempotency`、`agent_executables` 与 `terminal_schema_migrations`；每条 Preparing record 同时持久化 cryptographically random 16-byte `start_nonce`，替代 Supervisor 必须复用该值。Core 只依赖可注入的 `InstallationMasterKeyProviding`、`WorkerSecretDeriving` 与 `AttachTicketPolicy`。Phase 1 production policy 固定：Keychain service `dev.cockpit.terminal.master-key`、account `installation-master-key-v1`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`、32 random bytes；worker secret 使用 HKDF-SHA256(master, salt = TerminalSessionID bytes, info = `cockpit-worker-v1` + WorkerInstanceID bytes) 派生 32 bytes。

Attach ticket 固定为 30 秒有效、单次消费，并绑定 TerminalSessionID、WorkerInstanceID、ClientInstanceID 与 bitset：`view=1`、`input=2`、`resize=4`、`signal=8`、`terminate=16`。`input` 允许写 PTY bytes，包含经 terminal driver 产生 Ctrl+C/Ctrl+\\ 的路径；`signal` 允许直接控制当前 foreground job；`terminate` 允许控制整个 TerminalSession process group 及 lifecycle/archive state。ticket 原文不写数据库；Supervisor 只在内存保存其 SHA-256、expiry 与未消费状态，并经 authenticated `supervisorControl` 把相同 hash/绑定/capability/expiry 注册给目标 Keeper。Keeper 消费成功后删除本地条目并报告 Supervisor；任一方重启后未消费 ticket 失效，由客户端重新申请。

- [ ] **Step 1: 写失败测试**

覆盖 terminal 生命周期合法转换、非法回退拒绝、idempotency 返回原 session 且复用同一 start nonce、数据库重开后 nonce 不变、Keychain create/read、HKDF 固定向量、过期 ticket、重放、跨 session、跨 worker、跨 client 和 capability escalation 全部拒绝。Keychain 测试必须使用每次测试生成的 UUID service/account，并在 teardown 删除该测试项；不得读写 production service/account。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'SQLiteTerminalSessionRepositoryTests|WorkerSecretDeriverTests|TerminalAttachTicketTests|InstallationMasterKeyStoreTests'
```

Expected: 失败，原因是 terminal store、secret 与 ticket 实现不存在。

- [ ] **Step 3: 实现唯一写入者与安全材料边界**

`SQLiteTerminalSessionRepository` 只由 Supervisor composition root 构造；LaunchSpec 只保存非敏感环境覆盖；worker secret 只通过 FD 3 bootstrap bytes 进入 Keeper；日志、argv、环境、SQLite 和 runtime descriptor 均不包含 secret/ticket 原文。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'SQLiteTerminalSessionRepositoryTests|WorkerSecretDeriverTests|TerminalAttachTicketTests|InstallationMasterKeyStoreTests'
/usr/bin/git diff --check
git add Sources/CockpitTerminalCore Sources/CockpitPersistence Sources/CockpitLocalTransport Tests/CockpitPersistenceTests Tests/CockpitTerminalCoreTests Tests/CockpitLocalTransportTests
git commit -m "feat: persist authenticated terminal sessions"
```

---

### Task 13: 实现 PTY、Agent 解析与两阶段 Session 创建

**Depends on:** Task 12。

**Files:**

- Modify: `Package.swift`
- Modify: `project.yml`
- Create: `Sources/CockpitTerminalCore/LaunchSpec.swift`
- Create: `Sources/CockpitTerminalCore/AgentExecutableResolver.swift`
- Create: `Sources/CockpitTerminalCore/KeeperLaunching.swift`
- Create: `Sources/CockpitTerminalCore/KeeperControl.swift`
- Create: `Sources/CockpitTerminalCore/PTYSession.swift`
- Create: `Sources/CockpitTerminalCore/TerminalSupervisor.swift`
- Modify: `Sources/CockpitTerminalCore/KeeperBootstrap.swift`
- Modify: `Sources/CockpitLocalTransport/KeeperProcessLauncher.swift`
- Create: `Sources/CockpitLocalTransport/KeeperUDSServer.swift`
- Create: `Sources/CockpitLocalTransport/KeeperControlClient.swift`
- Create: `Applications/CockpitPTYKeeper/GhosttyVTAdapter.swift`
- Modify: `Applications/CockpitPTYKeeper/main.swift`
- Modify: `Applications/CockpitTerminalSupervisor/main.swift`
- Create: `Tests/Fixtures/Agents/codex`
- Create: `Tests/Fixtures/Agents/claude`
- Create: `Tests/Fixtures/Agents/fd-probe.c`
- Create: `Tests/CockpitTerminalCoreTests/AgentExecutableResolverTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/PTYSessionTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/TerminalSupervisorTwoPhaseTests.swift`
- Create: `Tests/CockpitLocalTransportTests/KeeperControlTests.swift`
- Create: `Tests/ProcessIntegrationTests/terminal-pty-exec.zsh`

**Contract:**

```swift
public enum TerminalKind: Codable, Sendable {
    case shell
    case agent(AgentProfileID) // only .codex and .claude in Phase 1
}

public actor TerminalSupervisor {
    public func createSession(_ request: CreateTerminalSessionRequest) async throws
        -> TerminalSessionRecord
    public func startCommittedSession(_ id: TerminalSessionID) async throws
        -> TerminalSessionRecord
    public func terminate(_ id: TerminalSessionID, force: Bool) async throws
}

public protocol KeeperLaunching: Sendable {
    func launch(_ bootstrap: KeeperBootstrap) async throws -> LaunchedKeeper
}

public protocol KeeperControlling: Sendable {
    func awaitReady(_ keeper: LaunchedKeeper) async throws -> KeeperReady
    func authenticatedStart(_ request: AuthenticatedStartRequest) async throws
        -> CLIProcessIdentity
    func inspect(_ endpoint: KeeperEndpoint) async throws -> KeeperIdentity
}

public struct KeeperReady: Sendable {
    public let endpoint: KeeperEndpoint
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let readyNonce: Data
    public let proofMAC: Data
}

public struct AuthenticatedStartRequest: Sendable {
    public let endpoint: KeeperEndpoint
    public let sessionID: TerminalSessionID
    public let workerID: WorkerInstanceID
    public let startNonce: Data
    public let proofMAC: Data
}
```

`CreateTerminalSessionRequest` 到达 Supervisor 时已经是 Host 解析出的 `LaunchSpec`；workspaceRoot 绝对路径只从 Host→Supervisor 的本地 XPC 传递，不返回 Cockpit.app，也不进入通用 ClientCore payload。Supervisor 先持久化 resolved LaunchSpec；Keeper 在 Preparing 阶段读取 bootstrap 中这份已持久化的 LaunchSpec，但在收到 Committed 后的 authenticated Start 前不得创建 PTY、CLI 或执行 LaunchSpec。

普通 Shell argv 固定为登录 Shell 的 argv0 前缀 `-`。Codex/Claude 解析固定执行：

```text
loginShellPath -l -c 'command -v -- "$1"' cockpit-resolve codex
loginShellPath -l -c 'command -v -- "$1"' cockpit-resolve claude
```

专用 Agent 启动固定执行：

```text
loginShellPath -l -c 'exec "$@"' cockpit-agent absoluteExecutablePath agentArguments...
```

Shell script 是常量，路径与参数只作为 argv 传入，不做字符串拼接。首次解析成功后把 canonical absolute executable 写入 Task 12 的 `agent_executables`；每次启动重新 `lstat` 并要求 regular file、非 symlink、当前用户可执行，失效时返回 `agentExecutableSelectionRequired`。测试使用仓库内受控 `codex`/`claude` fixture，绝不启动用户安装的 Agent。

`KeeperBootstrap` 固定包含 TerminalSessionID、WorkerInstanceID、LaunchSpec、Task 12 start nonce、Task 1 applicationSupport root、该 root 下精确的 TerminalArchives absolute path 和 worker secret。Supervisor 在 spawn 前对两个 root 做 canonical/no-symlink/ownership 验证；Keeper 再以 `open(..., O_DIRECTORY | O_NOFOLLOW)` 验证并只从该 bootstrap 构造 Task 15 archive store。

Keeper 与 Supervisor 的继承 bootstrap channel 使用 `socketpair(AF_UNIX, SOCK_STREAM)`：子端固定 dup 到 FD 3，承载 length-delimited bootstrap + worker secret、认证 Ready、认证 Start；不进入 argv/environment。本机验证 `AF_UNIX + SOCK_SEQPACKET` 返回 `EPROTONOSUPPORT`，因此不使用。Keeper 先建立与 Task 14 共用的 UDS control endpoint并原子写 runtime descriptor（TerminalSessionID、WorkerInstanceID、Keeper PID、endpoint），再返回 `KeeperReady`；Ready MAC 覆盖 domain separator、endpoint、session、worker、ready nonce。Committed 后 Supervisor 发送 `AuthenticatedStartRequest`，Start MAC 覆盖 domain separator、endpoint、session、worker、持久化 start nonce。若 Supervisor 已退出，替代 Supervisor 通过 UDS `supervisorControl` role 发送同一 request；Keeper 对完全相同的 request 返回原 CLI identity，错 nonce/session/worker/MAC 被拒绝，最多创建一个 CLI。

PTY 固定使用 `openpty` 取得 master 与 slave path，然后关闭 parent slave；收到 authenticated Start 后 Keeper 先关闭 bootstrap FD 3，再使用 `posix_spawn`，flags 固定为 `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`，file actions 在新 session 中重新 open slave 到 stdin、dup 到 stdout/stderr、使用 Xcode 26 SDK 的 `posix_spawn_file_actions_addchdir` 到 workspace root。CLI PID 同时是 session/process-group ID；测试必须断言 `getsid(pid) == pid` 与 `tcgetpgrp(masterFD) == pid`。`fd-probe.c` 在 exec 入口枚举 inherited FD，除 0/1/2 外全部不存在。显式 terminate 发送 `SIGTERM` 到 process group，force 发送 `SIGKILL`；Keeper 不调用多线程进程中的裸 `fork`/`forkpty`。

- [ ] **Step 1: 写失败测试**

用 fake `KeeperLaunching`/`KeeperControlling` 在 Preparing、Ready、Committed、Start、Running 每个边界注入退出，断言 Committed 前没有 CLI；Committed 后替代 Supervisor 启动同一 Worker；Start 后重试不创建第二个 CLI。LocalTransport 测试验证 FD 3 bootstrap、archive root 校验、UDS supervisor role、Ready/Start HMAC、nonce/session/worker mismatch 和 runtime descriptor endpoint。进程测试断言真实 PTY、cwd、resize、session/process-group identity、无额外 inherited FD、Shell 自然退出、两个 fixture Agent `exec` 后不回 Shell、killpg 清理后代。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'AgentExecutableResolverTests|PTYSessionTests|TerminalSupervisorTwoPhaseTests|KeeperControlTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -target CockpitPTYKeeper -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation build
COCKPIT_KEEPER_EXECUTABLE="$PWD/build/Debug/CockpitPTYKeeper" Tests/ProcessIntegrationTests/terminal-pty-exec.zsh
```

Expected: 失败，原因是 LaunchSpec、真实 PTY 和两阶段 Supervisor 尚不存在。

- [ ] **Step 3: 实现 Supervisor 与 Keeper 启动**

`TerminalSupervisor` 只依赖 Core protocols；`Applications/CockpitTerminalSupervisor/main.swift` 构造 LocalTransport launcher/control adapter并注入。`Package.swift` 与 `project.yml` 给 CockpitPTYKeeper executable/target 增加 `CockpitLocalTransport` 依赖。Keeper bootstrap deadline 固定 30 秒。Ready 前不创建 PTY。`GhosttyVTAdapter` 在 Xcode production build 的 `COCKPIT_GHOSTTY_LINKED` 分支调用真实 C ABI；SwiftPM compile-only fallback 明确抛错且不引用 C symbol。Keeper 的 PTY read source 持续把 bytes 送入 `cockpit_ghostty_vt_feed`，再由非读取队列生成 frame；archive I/O 与 viewer send 都不得在 read handler 内等待。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'AgentExecutableResolverTests|PTYSessionTests|TerminalSupervisorTwoPhaseTests|KeeperControlTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -target CockpitPTYKeeper -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation build
COCKPIT_KEEPER_EXECUTABLE="$PWD/build/Debug/CockpitPTYKeeper" Tests/ProcessIntegrationTests/terminal-pty-exec.zsh
/usr/bin/git diff --check
git add Package.swift project.yml Cockpit.xcodeproj Cockpit.xcworkspace Sources/CockpitTerminalCore Sources/CockpitLocalTransport Applications/CockpitPTYKeeper Applications/CockpitTerminalSupervisor Tests/Fixtures/Agents Tests/CockpitTerminalCoreTests Tests/CockpitLocalTransportTests/KeeperControlTests.swift Tests/ProcessIntegrationTests/terminal-pty-exec.zsh
git commit -m "feat: launch durable pty sessions"
```

---

### Task 14: 实现 authenticated Keeper UDS、viewer 与输入租约

**Depends on:** Task 13。

**Files:**

- Modify: `Sources/CockpitLocalTransport/KeeperUDSServer.swift`
- Create: `Sources/CockpitLocalTransport/KeeperUDSClient.swift`
- Create: `Sources/CockpitTerminalCore/TerminalStreamCoordinator.swift`
- Create: `Sources/CockpitTerminalCore/InputLease.swift`
- Create: `Sources/CockpitTerminalCore/TerminalStreamMessage.swift`
- Modify: `Applications/CockpitPTYKeeper/main.swift`
- Create: `Tests/CockpitLocalTransportTests/KeeperUDSTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/TerminalStreamCoordinatorTests.swift`

**Contract:**

UDS 路径固定为 `/private/tmp/cockpit.{uid}/terminal/{terminalSessionID}.{workerInstanceID}.sock`；父目录 `0700`，socket `0600`。Task 13 已建立 control endpoint，本任务在同一 listener 增加 viewer channel。`getpeereid` 与 protocol 1.1 handshake 后的首个 typed payload 必须是 `PeerRole`，仅允许两条互斥流程：

- `supervisorControl`：worker-secret challenge → Ready/Start/inspect/input-lease grant/revoke/completion；不提交 attach ticket。
- `viewer`：单次 attach ticket → capability confirmation → snapshot/resume；不接触 worker secret/challenge。

```swift
public actor TerminalStreamCoordinator {
    public func attach(_ request: AttachRequest) async throws -> Attachment
    public func detach(viewerID: ViewerID)
    public func registerInputLease(_ grant: InputLeaseGrant) async throws
    public func revokeInputLease(_ leaseID: InputLeaseID) async
    public func acceptInput(_ frame: TerminalInputFrame) async throws -> UInt64
    public func publish(outputSequence: UInt64, frame: Data)
}
```

Supervisor 是输入租约唯一权威端，通过 control protocol 创建/转移/释放 `InputLeaseGrant(leaseID, holderViewerID, sequenceBase, capabilities)` 并注册给 Keeper；Keeper 只校验和执行。每个 viewer queue 固定为最多 2 个 screen frame；第三个 frame 到来时合并中间帧并保留最新权威 frame。输入 lease 单调 sequence，重复 sequence 返回原 ACK，不重复写 PTY；断开持有者时 Keeper 立即使本地 grant 失效并向 Supervisor 报告 revocation，Supervisor 不可用时不授予替代 lease。read-only viewer 无权 input/resize/signal/terminate。

text 直接写 UTF-8；key/paste/mouse 必须调用 Task 11 基于当前 Ghostty VT mode 的 encoder 后再写 PTY；resize 在 Keeper 调用 `TIOCSWINSZ`。input capability 已允许 key encoder 产生 terminal-driver Ctrl+C/Ctrl+\\ bytes，并可由终端驱动向 foreground job 产生 SIGINT/SIGQUIT。signal capability 只接受 Task 2 冻结的 interrupt/quit/suspend/continue，经 Channel 0 control transport 直接把 SIGINT/SIGQUIT/SIGTSTP/SIGCONT 发送给 PTY 当前 foreground process group；这些 signal 按 Darwin 语义可以结束、中断、挂起或继续 foreground job。terminate capability 使用独立 policy 对整个 TerminalSession process group 发送 SIGTERM/SIGKILL，并驱动 lifecycle 与 archive state。SIGHUP 被拒绝。signal/terminate 都不伪装成 PTY bytes，二者区别在控制目标与生命周期职责。所有输入只接受 Task 2 的结构化 `TerminalInput`，不传 AppKit `NSEvent`。

- [ ] **Step 1: 写失败测试**

覆盖错 UID、未认证 payload、ticket 重放、跨 session ticket、过期 ticket、能力升级、Supervisor grant 之外无法取得写权、两个 viewer 单写多读、输入 ACK 丢失重试去重、key/paste/mouse mode-aware 编码、input capability 的 Ctrl+C/Ctrl+\\ terminal-driver 路径、signal capability 的 interrupt/quit/suspend/continue foreground-job 控制及可结束 foreground process、terminate capability 对整个 session process group 与 lifecycle/archive 的控制、慢 viewer 合并且另一个 viewer 不受影响、关闭 viewer 后 PTY PID 不变。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'KeeperUDSTests|TerminalStreamCoordinatorTests'
```

Expected: 失败，原因是 UDS server/client 与 stream coordinator 不存在。

- [ ] **Step 3: 实现 Frame channel 路由**

Channel 1 只发 snapshot/delta/scrollback，Channel 2 只发 input/resize/ack；Channel 0 按 PeerRole 承载认证，以及 supervisor 的 Ready/Start/inspect/lease grant/revoke/completion 或 viewer 的 capability/visibility control。payload 超过 16 MiB 时 scrollback 分页，不提高全局 frame 上限。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'KeeperUDSTests|TerminalStreamCoordinatorTests'
/usr/bin/git diff --check
git add Sources/CockpitLocalTransport Sources/CockpitTerminalCore Applications/CockpitPTYKeeper Tests/CockpitLocalTransportTests Tests/CockpitTerminalCoreTests
git commit -m "feat: stream terminal sessions over keeper uds"
```

---

### Task 15: 实现 Supervisor 对账与不可变终端归档

**Depends on:** Task 14。

**Files:**

- Create: `Sources/CockpitTerminalCore/TerminalArchive.swift`
- Create: `Sources/CockpitTerminalCore/TerminalArchiveStore.swift`
- Create: `Sources/CockpitTerminalCore/TerminalReconciler.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSupervisor.swift`
- Modify: `Applications/CockpitPTYKeeper/main.swift`
- Create: `Tests/CockpitTerminalCoreTests/TerminalArchiveTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/TerminalReconcilerTests.swift`
- Create: `Tests/ProcessIntegrationTests/terminal-reconciliation.zsh`

**Contract:**

每个已结束会话归档固定为：

```text
TerminalArchives/{terminalSessionID}/
├── chunks/00000000000000000001.ckgs
├── chunks/00000000000000000002.ckgs
├── final-snapshot.ckgf
└── manifest.pb
```

chunk 是不可变、按首 sequence 命名的 Ghostty scrollback frame；`manifest.pb` 使用 Task 2 生成的 `TerminalArchiveManifest`。`TerminalArchiveStore` 与 runtime directory 分离，只能写 Task 1 的 Application Support archive root，创建目录 `0700`、文件 `0600`，拒绝 symlink；Keeper 先 fsync chunks/snapshot，再用临时文件 + rename + 父目录 fsync 原子发布 manifest。Supervisor 只把存在且 hash 全部匹配的 manifest 标为 Exited/Terminated archive。

manifest 的 field number、exit-status oneof、Google Timestamp、32-byte hash、20 位 chunk name、sequence range 与允许 gap 的规则固定引用 `docs/superpowers/specs/2026-08-06-cockpit-phase-1-protocol-1-1-design.md`；Task 15 不修改或重新解释 Task 2 已冻结 ABI。

- [ ] **Step 1: 写失败测试**

覆盖 committed/running 同 Worker 被采纳、Preparing 不采纳、worker mismatch 拒绝、找不到 Keeper 标 Interrupted、Keychain unavailable 保持原状态、Supervisor 被杀后现有 UDS 输入输出继续、bootstrap archive root 为 symlink/越出 Application Support 时拒绝、archive 目录 `0700`/文件 `0600`、尾部不完整 archive 不发布、篡改 chunk 被拒绝、final snapshot 可只读打开。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'TerminalArchiveTests|TerminalReconcilerTests'
Tests/ProcessIntegrationTests/terminal-reconciliation.zsh
```

Expected: 失败，原因是 archive/reconciler 不存在，Supervisor 仍是 probe-only。

- [ ] **Step 3: 实现启动对账与自然退出发布**

Supervisor 启动只读取 Committed/Running records，枚举 Task 13 含 endpoint/process identity 的 runtime descriptor，通过 `KeeperControlling.inspect` 完成 challenge，匹配 TerminalSessionID + WorkerInstanceID。逻辑接管不改变 Unix parent。CLI 自然退出后 Keeper 排空 PTY、发布 archive；Supervisor control connection存在时上报完成状态，不存在时直接退出。替代 Supervisor 仅依据已认证 descriptor + 已验证 archive 对账，不依赖已经丢失的即时上报。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'TerminalArchiveTests|TerminalReconcilerTests'
Tests/ProcessIntegrationTests/terminal-reconciliation.zsh
/usr/bin/git diff --check
git add Sources/CockpitTerminalCore Applications/CockpitPTYKeeper Tests/CockpitTerminalCoreTests Tests/ProcessIntegrationTests/terminal-reconciliation.zsh
git commit -m "feat: reconcile and archive terminal sessions"
```

---

### Task 16: 接入 Terminal XPC 控制面、TerminalClient 与 Ghostty Metal viewer

**Depends on:** Task 15。

**Files:**

- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Create: `Sources/CockpitLocalTransport/TerminalSupervisorControlTransport.swift`
- Create: `Sources/CockpitLocalTransport/HostTerminalControlTransport.swift`
- Create: `Sources/CockpitLocalTransport/KeeperTerminalDataTransport.swift`
- Create: `Sources/CockpitHostCore/TerminalSupervisorControlling.swift`
- Create: `Sources/CockpitHostCore/WorkspaceTerminalService.swift`
- Create: `Sources/CockpitTerminalClient/TerminalControlTransport.swift`
- Create: `Sources/CockpitTerminalClient/TerminalDataTransport.swift`
- Create: `Sources/CockpitTerminalClient/TerminalAttachmentController.swift`
- Create: `Sources/CockpitTerminalClient/TerminalFrameClient.swift`
- Create: `Applications/CockpitApp/Terminal/GhosttyTerminalView.swift`
- Create: `Applications/CockpitApp/Terminal/TerminalTabViewController.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Modify: `Applications/CockpitTerminalSupervisor/main.swift`
- Modify: `project.yml`
- Create: `Tests/CockpitTerminalClientTests/TerminalAttachmentControllerTests.swift`
- Create: `Tests/CockpitLocalTransportTests/TerminalSupervisorXPCTests.swift`
- Modify: `Tests/CockpitLocalTransportTests/HostXPCTests.swift`
- Create: `Tests/CockpitAppTests/GhosttyTerminalViewTests.swift`
- Create: `Tests/ProcessIntegrationTests/terminal-app-reattach.zsh`

**Contract:**

TerminalSupervisor XPC 只向 CockpitHost composition root 提供：`createResolved`、`list(contextID)`、`issueAttachTicket`、`acquire/transfer/releaseInputLease`、`signal`、`terminate`、`purgeFinishedRecords`、`reconcile` 和 `openArchive`。`signal` 只控制当前 foreground job，允许批准的 Darwin signal 按系统语义结束、中断、挂起或继续该 job；`terminate` 控制整个 TerminalSession process group 并驱动 lifecycle/archive state。Host XPC 向客户端提供不含绝对路径的对应 typed commands。`WorkspaceTerminalService` 对每个请求解析 WorkspaceContext→Environment、校验 session/context 绑定，并通过注入的 `TerminalSupervisorControlling` 调用 Supervisor；只有该层把 resolved workspaceRoot 放入 `createResolved`。真实 screen/input bytes 不经过任何 XPC。

```swift
public actor TerminalAttachmentController {
    public func attach(sessionID: TerminalSessionID,
                       lastAcknowledgedSequence: UInt64?) async throws
    public func detach() async
    public func send(_ input: TerminalInput) async throws
    public func setVisible(_ visible: Bool) async
    public func events() -> AsyncStream<TerminalClientEvent>
}
```

`TerminalAttachmentController` 只依赖 `TerminalControlTransport` 与 `TerminalDataTransport` ports。LocalTransport 的 `HostTerminalControlTransport` 适配 App→Host XPC；`TerminalSupervisorControlTransport` 适配 Host→Supervisor XPC 并实现 HostCore port；`KeeperTerminalDataTransport` 适配 App→Keeper UDS。App composition root 只注入 Host control 与 Keeper data，不直接构造 Supervisor XPC client。这样 `CockpitTerminalClient` target 不导入 XPC/UDS，也不反向依赖 LocalTransport，同时远程 Transport 后续仍由 Host 承担授权入口。

`GhosttyTerminalView` 是 AppKit `NSView`，持有一个 `cockpit_ghostty_renderer_t`。`isHidden == true`、窗口 occluded 或 tab inactive 时立即调用 `cockpit_ghostty_renderer_set_visible(false)`；Keeper 继续 drain PTY。恢复 visible 后先应用最新 frame，再启动 Metal draw。

- [ ] **Step 1: 写失败测试**

覆盖两段 XPC 请求类型和当前 UID 校验、App payload 不含 workspaceRoot、Host 拒绝 context/environment/session mismatch、Supervisor 接收 Host resolved root、attach 时 retained delta 命中与 snapshot fallback、detach 不 terminate、旧 generation event 丢弃、inactive viewer 不触发 draw、reopen App 后 TerminalSessionID/Keeper PID/CLI PID 不变且 input 可继续。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitTerminalClientTests|TerminalSupervisorXPCTests|HostXPCTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/GhosttyTerminalViewTests test
Tests/ProcessIntegrationTests/terminal-app-reattach.zsh
```

Expected: 失败，原因是正式 XPC API、TerminalClient 和 Metal view 不存在。

- [ ] **Step 3: 实现控制面与 viewer**

`TerminalAttachmentController` 先用 control port 获取 ticket，再用 data port 直连 Keeper UDS；连接建立后 Supervisor/Host 重启不关闭该 socket。App quit 统一调用 detach，不发送 terminate。`project.yml` 让 Cockpit App 明确依赖 `CockpitTerminalClient` 与 Task 11 renderer artifact，并保留 Task 1 的 AppTests host/scheme 配置。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitTerminalClientTests|TerminalSupervisorXPCTests|HostXPCTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/GhosttyTerminalViewTests test
Tests/ProcessIntegrationTests/terminal-app-reattach.zsh
/usr/bin/git diff --check
git add Sources/CockpitHostCore Sources/CockpitLocalTransport Sources/CockpitTerminalClient Applications/CockpitHost/main.swift Applications/CockpitApp/Terminal Applications/CockpitTerminalSupervisor Tests/CockpitTerminalClientTests Tests/CockpitLocalTransportTests Tests/CockpitAppTests Tests/ProcessIntegrationTests/terminal-app-reattach.zsh project.yml Cockpit.xcodeproj Cockpit.xcworkspace
git commit -m "feat: attach ghostty terminal viewers"
```

---

### Task 17: 构建 AppKit 三栏工作区与原生页签

**Depends on:** Task 10、Task 16。

**Files:**

- Modify: `Applications/CockpitApp/AppDelegate.swift`
- Create: `Applications/CockpitApp/WorkspaceWindowController.swift`
- Create: `Applications/CockpitApp/WorkspaceSplitViewController.swift`
- Create: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Create: `Applications/CockpitApp/TabStripController.swift`
- Create: `Applications/CockpitApp/ContentHostController.swift`
- Create: `Applications/CockpitApp/FileTreeViewController.swift`
- Create: `Applications/CockpitApp/NewTabPickerController.swift`
- Create: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Create: `Tests/CockpitAppTests/WorkspaceViewModelTests.swift`
- Create: `Tests/CockpitAppTests/WorkspaceHierarchyTests.swift`

**Contract:**

```text
NSWindow
└── NSSplitViewController
    ├── WorkspaceSidebarController / NSOutlineView
    ├── center NSSplitViewItem
    │   └── TabStripController / NSCollectionView + ContentHostController
    └── FileTreeViewController / NSOutlineView
```

左栏层级固定为 Project → zero-to-many Conversation；Project 行始终 selectable。中央 tab kinds 固定为 file、shell、codex、claude、new-tab-picker；new-tab-picker 作为 Context-local TabRecord 持久化，选择操作后原位替换为目标 file/terminal resource，取消时删除该 TabRecord。右栏 Phase 1 只显示文件树，不创建 Search/Git/Diff 占位按钮。

- [ ] **Step 1: 写失败测试**

断言 window root 是三栏 NSSplitViewController；Project 没有 Conversation 时仍有 selectable row；选择 Project/Conversation 产生新 generation；各 Context tab list 独立；同 Window 只有一个 Monaco controller；切换到 terminal 隐藏 Monaco 但不销毁 model；右栏 provider 始终来自 ActiveContext.environmentID。

- [ ] **Step 2: 运行失败测试**

```bash
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/WorkspaceViewModelTests -only-testing:CockpitAppTests/WorkspaceHierarchyTests test
```

Expected: 失败，原因是 App 仍只有 720x480 service status label。

- [ ] **Step 3: 实现 AppKit controllers 与 diffable data sources**

AppDelegate 只构造 clients、WorkspaceViewModel 和 WorkspaceWindowController。所有 async completion 带捕获的 generation，并在 mutation 前调用 `ActiveContextController.accepts`。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/WorkspaceViewModelTests -only-testing:CockpitAppTests/WorkspaceHierarchyTests test
/usr/bin/git diff --check
git add Applications/CockpitApp Tests/CockpitAppTests Cockpit.xcodeproj Cockpit.xcworkspace
git commit -m "feat: build native workspace shell"
```

---

### Task 18: 接通 Add Project、Conversation 与多 Terminal 产品流程

**Depends on:** Task 17。

**Files:**

- Create: `Applications/CockpitApp/ProjectCommandController.swift`
- Create: `Applications/CockpitApp/ConversationCommandController.swift`
- Create: `Applications/CockpitApp/TabCommandController.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Modify: `Applications/CockpitApp/NewTabPickerController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Create: `Tests/CockpitAppTests/ProjectCommandControllerTests.swift`
- Create: `Tests/CockpitAppTests/ConversationCommandControllerTests.swift`
- Create: `Tests/CockpitAppTests/TabCommandControllerTests.swift`
- Create: `Tests/ProcessIntegrationTests/phase1-context-workflows.zsh`

**Product flow:**

1. Add Project 使用 `NSOpenPanel` 选择一个目录并创建 security-scoped bookmark；成功后选中 Project Context；不创建 Conversation，不创建 terminal。
2. New Conversation 先让用户选择 Codex 或 Claude，再持久化标题“新任务”，选中 Conversation，创建第一个 Agent TerminalSession；登录 Shell 无法解析 Agent 时用 `NSOpenPanel` 让用户选择可执行文件并保存绝对路径，取消或启动失败都保留 Conversation 和错误页签。
3. New Tab 在 Project/Conversation Context 都提供 open file、Shell、Codex、Claude、reattach current-context terminal。
4. 每次 Shell/Codex/Claude 都创建新 TerminalSessionID；普通 Shell 内手动运行 codex/claude 不改变 `.shell` kind。
5. Agent 自然退出保留 exit code 与 final frame；restart 创建新 TerminalSessionID 并让原 TabRecord 指向新 ID。
6. 关闭 terminal tab 只 detach；关闭 dirty 文件最后一个 viewer 显示 Save/Discard/Cancel。
7. Conversation 行提供原生 inline rename；提交调用 `renameConversation`，空标题被拒绝，失败保留原标题并展示真实错误。
8. 首 Agent 或后续 Agent 启动失败的错误页签提供 Retry 和 Switch Agent；Retry 以相同 profile 创建新的 TerminalSessionID，Switch Agent 先选择另一个内建 profile 再创建新的 TerminalSessionID，Conversation 本身不重建。

- [ ] **Step 1: 写失败测试**

覆盖纯 Project 模式全部功能可用；同 Conversation 同时创建 Codex + Claude + Shell；两个 Conversation 的 tabs/sessions 隔离；全部 Context 共享同一 file/document state；手动 rename 成功/失败；Agent resolver 失败后的 executable picker 选择/取消；first agent 启动失败不回滚 Conversation；Retry/Switch Agent 生成新 session 且保留原失败记录；reattach 列表只显示当前 Context 的 detached sessions。进程测试把 Agent executable 固定到 Task 13 fixture 的绝对路径，不执行用户机器上的 codex/claude。

- [ ] **Step 2: 运行失败测试**

```bash
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/ProjectCommandControllerTests -only-testing:CockpitAppTests/ConversationCommandControllerTests -only-testing:CockpitAppTests/TabCommandControllerTests test
Tests/ProcessIntegrationTests/phase1-context-workflows.zsh
```

Expected: 失败，原因是产品命令 controller 与端到端 Context 流程未接通。

- [ ] **Step 3: 实现命令 controller**

controller 只编排已存在的 Host/Terminal client API，不复制领域状态。Conversation 与首 Agent 不执行跨数据库事务；页面只显示服务返回的真实错误 domain/code/message。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/ProjectCommandControllerTests -only-testing:CockpitAppTests/ConversationCommandControllerTests -only-testing:CockpitAppTests/TabCommandControllerTests test
Tests/ProcessIntegrationTests/phase1-context-workflows.zsh
/usr/bin/git diff --check
git add Applications/CockpitApp Tests/CockpitAppTests Tests/ProcessIntegrationTests/phase1-context-workflows.zsh Cockpit.xcodeproj Cockpit.xcworkspace
git commit -m "feat: connect direct workspace workflows"
```

---

### Task 19: 实现 Conversation 可恢复删除 saga

**Depends on:** Task 18。

**Files:**

- Create: `Sources/CockpitHostCore/ConversationDeletionCoordinator.swift`
- Create: `Sources/CockpitHostCore/ConversationDeletionOperation.swift`
- Create: `Sources/CockpitHostCore/ContextTerminalDeletionControlling.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSessionRepository.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSupervisor.swift`
- Modify: `Sources/CockpitPersistence/TerminalMigrations.swift`
- Modify: `Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift`
- Create: `Sources/CockpitLocalTransport/ContextTerminalDeletionTransport.swift`
- Create: `Applications/CockpitApp/ConversationDeletionController.swift`
- Create: `Tests/CockpitHostCoreTests/ConversationDeletionCoordinatorTests.swift`
- Create: `Tests/CockpitTerminalCoreTests/ContextTerminationTests.swift`
- Modify: `Tests/CockpitLocalTransportTests/TerminalSupervisorXPCTests.swift`
- Create: `Tests/CockpitAppTests/ConversationDeletionControllerTests.swift`
- Create: `Tests/ProcessIntegrationTests/phase1-conversation-deletion.zsh`

**Contract:**

```swift
public enum ConversationDeletionPhase: Int, Codable, Sendable {
    case deleting
    case terminatingSessions
    case purgingTerminalRecords
    case removingClientState
    case deleted
}

public actor ConversationDeletionCoordinator {
    public func begin(conversationID: ConversationID,
                      operationID: DeletionOperationID) async throws
    public func resume(operationID: DeletionOperationID) async throws
}

public protocol ContextTerminalDeletionControlling: Sendable {
    func beginContextDeletion(contextID: WorkspaceContextID,
                              operationID: DeletionOperationID) async throws
    func terminateSessions(contextID: WorkspaceContextID,
                           operationID: DeletionOperationID,
                           force: Bool) async throws -> ContextTerminationResult
    func purgeDeletedContext(contextID: WorkspaceContextID,
                             operationID: DeletionOperationID) async throws
}
```

`WorkspaceService.deletionImpact` 结合全部持久化 TabRecord 与 `DocumentRegistry` 的 live viewers，返回移除该 Context 后 viewer 数为零的 dirty Document。App 在 `begin` 前逐个处理 Save/Discard/Cancel；Cancel 不创建 deletion operation。用户确认正常 terminate 后 Host 写 `.deleting`，再经注入的 `ContextTerminalDeletionControlling` 调用 Supervisor；HostCore 不导入 LocalTransport。每个跨进程步骤完成后单独持久化 phase。正常终止未结束时，操作停在 `.terminatingSessions` 并返回 `forceConfirmationRequired`；只有第二次明确确认才发 force。

Task 19 新增 terminal migration v2 表 `terminal_context_deletions(context_kind, context_id, operation_id, state)`。`beginContextDeletion` 写入 gate；`createSession` 在插入 Preparing 前检查 gate 并返回 `contextDeleting`；`terminateSessions` 和 `purgeDeletedContext` 均以相同 operation ID 幂等，错误 operation ID 被拒绝。purge 只在全部 session 非活动后删除该 Context 的 terminal rows、archive/chunks/snapshot/manifest 与 gate。LocalTransport XPC 新增这三个 Context-scoped 命令并由 `ContextTerminalDeletionTransport` 实现 HostCore port。

- [ ] **Step 1: 写失败测试**

覆盖多个 Context viewer 时不提示、删除后失去最后 viewer 的 dirty 文档逐个 Save/Discard/Cancel、dirty Cancel 零变更、begin 返回后 Host 与 Supervisor 都拒绝新 tab/session、正常 terminate、单独 force 确认、Host 每个 phase 崩溃后 resume 同 operation、错误 operation ID 拒绝、Supervisor 崩溃后重复 terminate/purge 幂等、删除后 Project/Environment/物理文件/外部 Codex/Claude history 不变、App 切回 Project Context。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'ConversationDeletionCoordinatorTests|ContextTerminationTests|TerminalSupervisorXPCTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/ConversationDeletionControllerTests test
Tests/ProcessIntegrationTests/phase1-conversation-deletion.zsh
```

Expected: 失败，原因是 deletion saga 与 UI confirmation controller 不存在。

- [ ] **Step 3: 实现可重入 phase handler**

每个 phase 读取当前持久状态再执行；已完成动作返回成功。`PurgingTerminalRecords` 通过 port 调用 Supervisor，不直接写 terminal.sqlite；`RemovingClientState` 只删除该 Context 的全部设备布局和 Conversation row。Host/Supervisor composition roots 分别注入 transport export/client，跨库无共享连接。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'ConversationDeletionCoordinatorTests|ContextTerminationTests|TerminalSupervisorXPCTests'
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData -only-testing:CockpitAppTests/ConversationDeletionControllerTests test
Tests/ProcessIntegrationTests/phase1-conversation-deletion.zsh
/usr/bin/git diff --check
git add Sources/CockpitHostCore Sources/CockpitWorkspace/DocumentRegistry.swift Sources/CockpitPersistence Sources/CockpitTerminalCore Sources/CockpitLocalTransport Applications/CockpitApp/ConversationDeletionController.swift Tests/CockpitHostCoreTests Tests/CockpitTerminalCoreTests Tests/CockpitAppTests Tests/ProcessIntegrationTests/phase1-conversation-deletion.zsh Cockpit.xcodeproj Cockpit.xcworkspace
git commit -m "feat: delete conversations recoverably"
```

---

### Task 20: 交付 Phase 1 端到端垂直切片与统一 gate

**Depends on:** Task 19。

**Files:**

- Modify: `Sources/CockpitLocalTransport/XPCConnectionBoundary.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Modify: `Applications/CockpitTerminalSupervisor/main.swift`
- Modify: `Applications/CockpitApp/AppDelegate.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Modify: `Config/LaunchAgents/dev.cockpit.host.local.plist.template`
- Modify: `Config/LaunchAgents/dev.cockpit.terminal.local.plist.template`
- Create: `Tools/render-test-launchagents.zsh`
- Create: `Tests/ProcessIntegrationTests/probe-json.zsh`
- Create: `Tests/ProcessIntegrationTests/phase1-direct-workspace.zsh`
- Create: `Tools/verify-phase1.zsh`
- Modify: `Tests/ProcessIntegrationTests/app-bundle-layout.zsh`
- Modify: `README.md`

**Acceptance scenarios:**

1. 添加 Project 后没有 Conversation/terminal，文件树、编辑、新建/移动/重命名/Trash、Shell、Codex、Claude 可用。
2. 两个 Direct Conversation 的 tab 与 TerminalSession 隔离，Project Context 与两者共享同一 Environment、文件树和 DocumentID。
3. UTF-8 BOM/CRLF 保存保留格式；rename/move 保持 DocumentID；dirty 外部修改进入 conflict；Host crash 后恢复 acknowledged edit。
4. 一个 Conversation 同时运行 Codex、Claude 和 Shell；关闭 tab 不终止；Agent 退出不回 Shell。
5. Command-Q、kill App、kill Host、kill Supervisor 后同一 Keeper PID、CLI PID、TerminalSessionID 与 output sequence 继续；重新打开后 snapshot/delta、scrollback 和 input 恢复。
6. 删除 Conversation 经过 dirty/terminate/force 分支并可在 Host/Supervisor crash 后续作；Project、Environment 与文件不删除。
7. 同时运行两个 TerminalSession，kill 其中一个 Keeper 后只把对应 session 标为 Interrupted，另一个 session 的 PID、输出与输入不变。

- [ ] **Step 1: 写失败的统一场景脚本**

`XPCServiceNamespace` 生产值为空并继续使用 `dev.cockpit.host` / `dev.cockpit.terminal`；测试值只允许 `[a-z0-9-]{1,32}`，Mach service 与 LaunchAgent label 固定追加 `.<namespace>`。Host、Supervisor、全部 XPC client 和 Probe 从显式构造参数读取同一 namespace；composition root 只把 `COCKPIT_SERVICE_NAMESPACE` 解析为该值。测试 composition root 同时从 `COCKPIT_APPLICATION_SUPPORT_ROOT` 取得 Task 1 的临时存储根，把 terminal/client-identity Keychain service 与 ClientIdentity `UserDefaults` suite 追加同一 namespace；production 未设置时仍使用正式路径、正式 Keychain service 和正式 preferences domain。测试退出删除且只删除带该 namespace 的 Keychain items/preferences suite。

`Tools/render-test-launchagents.zsh` 接受 `--namespace`、`--home`、`--path`、Host/Supervisor/Keeper 绝对路径、runtime root、storage root、output directory，渲染两个只属于该 namespace 的 plist；两个 plist 的 `EnvironmentVariables` 固定写入本次 HOME、受控 PATH、service namespace、runtime root 与 storage root。脚本拒绝空 namespace、symlink output 和非绝对 executable，并在 bootstrap 前用 `plutil` 逐项断言渲染值与本次 fixture 完全一致。端到端脚本创建独立 temporary HOME、临时 Project、唯一 service namespace，通过 `launchctl bootstrap gui/$UID` 只加载生成的两个 plist，并在 EXIT trap 用相同 label bootout；Keeper 继承 Supervisor 环境，App/Probe 以同一显式环境启动，fixture Agent 输出并断言 HOME/PATH。所有清理 PID 都来自本次 Probe JSON，不执行 `pkill`/`killall`，不结束用户现有 Cockpit/Ghostty/Agent 进程。

Probe 每个命令 stdout 只输出一个 JSON object，顶层固定为 `schemaVersion: 1`、`ok`、`command`、`requestID`、`result | error`；stderr 只输出诊断，退出码非零表示失败。Phase 1 命令固定为：`services`、`workspace snapshot`、`workspace add-project --path`、`conversation create|rename|delete`、`terminal create|list|inspect|attach|input|terminate`、`document open|edit|save|snapshot`、`file create|mkdir|move|rename|trash|tree`；相关 result 固定包含 WorkspaceContextID、EnvironmentID、generation、DocumentID/version、TerminalSessionID/WorkerInstanceID/Keeper PID/CLI PID/latest sequence。Agent create 接受测试专用 `--resolved-executable`，只允许测试 storage root 打开的进程场景使用；production App API 不暴露该参数。

- [ ] **Step 2: 运行新场景确认当前失败**

```bash
Tests/ProcessIntegrationTests/probe-json.zsh
Tests/ProcessIntegrationTests/phase1-direct-workspace.zsh
```

Expected: 在 Probe JSON schema、隔离 service namespace 和最终场景接线完成前失败。

- [ ] **Step 3: 实现唯一统一 gate**

`Tools/verify-phase1.zsh` 固定顺序：canonical Node/pnpm profile → Monaco offline install/build/test → Swift build/test → Probe JSON contract → Ghostty bridge build/smoke → XcodeGen/App build/App tests → Phase 0 process invariants → Phase 1 direct-workspace scenario → bundle layout → `git diff --check`。脚本不下载、不 bootstrap、不修改依赖版本。

- [ ] **Step 4: 更新 README 实现边界**

README 明确列出已实现 Phase 1 能力和仍未实现的 Phase 2+ 能力，并把标准命令改为：

```bash
Tools/verify-phase1.zsh
```

- [ ] **Step 5: 运行一次完整 gate 并提交**

```bash
Tools/verify-phase1.zsh
git status --short
/usr/bin/git diff --check
git add Sources/CockpitLocalTransport/XPCConnectionBoundary.swift Applications/CockpitHost/main.swift Applications/CockpitTerminalSupervisor/main.swift Applications/CockpitApp/AppDelegate.swift Applications/CockpitProbe/main.swift Config/LaunchAgents/dev.cockpit.host.local.plist.template Config/LaunchAgents/dev.cockpit.terminal.local.plist.template Tools/render-test-launchagents.zsh Tests/ProcessIntegrationTests/probe-json.zsh Tests/ProcessIntegrationTests/phase1-direct-workspace.zsh Tests/ProcessIntegrationTests/app-bundle-layout.zsh Tools/verify-phase1.zsh README.md
git commit -m "test: verify phase 1 direct workspace"
```

Expected: gate 全部通过；提交后工作树干净。

---

## Spec Coverage Matrix

| 已批准要求 | 实施任务 |
|---|---:|
| 一个 Project、零到多个 Direct Conversation、Project 始终可选 | 2–5, 17–18 |
| Project/Conversation 共享 Direct Environment，Context 状态隔离 | 3–6, 18 |
| 文件树延迟加载和 FSEvents 对账 | 6 |
| 新建、重命名、移动、Trash | 7 |
| UTF-8/BOM、LF/CRLF、恢复、原子保存、外部冲突 | 8–10 |
| 每窗口一个 Monaco WKWebView | 10, 17 |
| Shell/Codex/Claude、多 Agent、Agent exec 退出 | 12–13, 18 |
| terminal.sqlite、两阶段创建、PTYKeeper | 12–13 |
| Ghostty VT、Metal、snapshot/delta/scrollback | 11, 13–16 |
| App/Host/Supervisor 退出或崩溃后终端存活与重连 | 14–16, 20 |
| AppKit 三栏、原生 tab、右栏文件树 | 17 |
| Conversation 可恢复删除 | 19 |
| 远程就绪身份、generation、typed payload；Phase 1 不监听网络 | 2, 5, 14, 16 |

## Plan Self-Review Gate

- [ ] `/usr/bin/python3 -c 'from pathlib import Path; p=Path("docs/superpowers/plans/2026-08-06-cockpit-phase-1-implementation.md"); banned=["TO"+"DO", "TB"+"D", "FIX"+"ME", "待"+"定", "后续"+"补充", "自行"+"决定"]; assert not any(x in p.read_text() for x in banned)'` 退出码为 0。
- [ ] Task 1–20 每项都有依赖、精确文件、失败测试、实现契约、通过命令和 commit 命令。
- [ ] `Package.swift` target DAG 与总体架构依赖规则一致，无环。
- [ ] 设计文档的 6 个 Phase 1 acceptance scenarios 全部映射到 Task 20，并单独覆盖“一个 Keeper 崩溃不影响其他会话”子场景。
- [ ] 明确排除多 Project、Worktree、Search/Git/LSP、远程网络、自动标题、自动保存、CRDT/OT 和通用 Agent Profile。
- [ ] Ghostty 轻量 fork 不污染 submodule，Zig 固定 0.15.2，App Bundle 不携带工具链或源码。
- [ ] 没有独立的性能指标、额外加固、额外测试或未来功能任务。
- [ ] 实施使用 sub-Agent-driven development，任务串行、每任务新的 implementer 和两阶段 review。
