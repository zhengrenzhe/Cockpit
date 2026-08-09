# Cockpit Phase 1 Direct Workspace Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 交付一个原生 macOS Direct Workspace 垂直切片：一个固定物理 Project、零到多个 Direct Conversation、可恢复文件编辑与文件管理、可在 App 退出后继续运行并重新连接的 Shell/Codex/Claude 终端，以及 AppKit 三栏工作区。

**Architecture:** CockpitHost 是 Project、Environment、Conversation、DocumentSession、文件树和设备布局的唯一权威端；CockpitTerminalSupervisor 是 TerminalSession 注册表和两阶段创建的唯一权威端；每个 CockpitPTYKeeper 独占一个 PTY、CLI 进程组、Ghostty VT、scrollback 与本地 UDS 数据面；Cockpit.app 只持有 AppKit 视图、每窗口一个 Monaco WKWebView、Ghostty Metal viewer 和客户端状态。Project Context 与全部 Direct Conversation 共享一个 Direct Environment，页签与 TerminalSession 按 WorkspaceContext 隔离。

**Tech Stack:** macOS 15、Xcode 26.6 (17F113)、Swift 6.3.3、Swift tools 6.3、AppKit、WebKit、NSXPCConnection、Unix Domain Socket、SQLite3、Security/Keychain、CryptoKit、FSEvents、SwiftProtobuf 1.38.1、Monaco 0.56.0、esbuild 0.28.1、Node 26.7.0、pnpm 11.20.0、XcodeGen 2.46.0、Ghostty 1.3.2-dev (`05221c11c9db0715666fc6e038915128fc6a563e`) 与 Zig 0.16.0。

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
- 当前依赖基线已由本机命令与官方来源核验。Ghostty 1.3.2-dev 的精确提交与其 `build.zig.zon` 声明的 Zig 0.16.0 是用户为 Task 11 明确批准的例外；其余依赖发现正式稳定版本发生变化时停止，不修改版本，先按 `AGENTS.md` 向用户报告必要性、范围、成本、耗时、风险与不更新结果。

## Execution Protocol

- [ ] 在 `main` 工作树确认 `git status --short --branch` 只有 `## main`。
- [ ] 创建隔离工作树与分支：

```bash
git worktree add .worktrees/phase-1 -b codex/phase-1-direct-workspace main
```

- [ ] 按 Phase 1 manifest 的精确提交与官方归档准备 Ghostty/Zig 输入：

```bash
git -C .worktrees/phase-1 submodule update --init ThirdParty/ghostty
mkdir -p .worktrees/phase-1/.tools/archives
.worktrees/phase-1/Tools/bootstrap-zig.zsh
```

Expected: Phase 1 worktree 的 Ghostty HEAD 为 `05221c11c9db0715666fc6e038915128fc6a563e`；归档 SHA/size 与 `Config/Toolchains/ghostty.env` 一致；`.tools/zig/0.16.0/zig version` 输出 `0.16.0`。

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
git -C ThirdParty/ghostty cat-file -e 05221c11c9db0715666fc6e038915128fc6a563e^{commit}
git ls-remote --tags --refs https://github.com/yonaskolb/XcodeGen.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(2,46,0)'
git ls-remote --tags --refs https://github.com/apple/swift-protobuf.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(1,38,1)'
git ls-remote --tags --refs https://github.com/microsoft/monaco-editor.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(0,56,0)'
git ls-remote --tags --refs https://github.com/evanw/esbuild.git | /usr/bin/python3 -c 'import re,sys; v=[tuple(map(int,m.groups())) for x in sys.stdin for m in [re.search(r"refs/tags/v?(\d+)\.(\d+)\.(\d+)$",x)] if m]; assert max(v)==(0,28,1)'
Tools/verify-ghostty.zsh --no-bootstrap
```

Expected: 与本计划 Tech Stack 完全一致；Ghostty commit、source version/minimum Zig contract 和 Zig 0.16.0 校验通过。

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

- Modify: `Package.swift`
- Modify: `Sources/CockpitTypes/WorkspaceModels.swift`
- Create: `Sources/CockpitHostCore/FileTreeProviding.swift`
- Create: `Sources/CockpitWorkspace/FileTreeProvider.swift`
- Create: `Sources/CockpitWorkspace/FileSystemEventSource.swift`
- Create: `Sources/CockpitWorkspace/FileTreeReconciler.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
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

用记录访问路径的 fake filesystem 断言展开根目录不访问孙目录；同一 Environment 的两个 Context 返回相同 provider identity；FSEvents drop/root-changed 触发已展开目录的定向重扫；旧 generation 的结果被客户端拒绝；符号链接以叶节点展示且不跟随扫描。`CockpitWorkspaceTests` 仅增加对 `CockpitClientCore` 测试依赖，以复用 Task 5 的 `ActiveContextController` 验证 generation 门禁；生产 target 依赖图不变。`WorkspaceKernelRegistry` 把同一个 Environment 的唯一 `FileTreeProvider` 挂在既有 `WorkspaceKernel` 上，以满足既定的 Environment 级复用合同。

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
git add Package.swift Sources/CockpitTypes/WorkspaceModels.swift Sources/CockpitHostCore/FileTreeProviding.swift Sources/CockpitWorkspace Tests/CockpitWorkspaceTests
git commit -m "feat: add lazy environment file tree"
```

---

### Task 7: 实现根目录内串行文件管理

**Depends on:** Task 6。

**Files:**

- Create: `Sources/CockpitHostCore/FileOperationServing.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Create: `Sources/CockpitWorkspace/WorkspaceRootHandle.swift`
- Create: `Sources/CockpitWorkspace/FileOperationCoordinator.swift`
- Create: `Sources/CockpitWorkspace/FileOperationError.swift`
- Modify: `Sources/CockpitWorkspace/FileTreeProvider.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceCommandRouter.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Create: `Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift`
- Create: `Tests/CockpitWorkspaceTests/FileOperationCoordinatorTests.swift`
- Modify: `Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift`
- Modify: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
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

`WorkspaceRootHandle` 持有 root directory FD。祖先遍历使用 `openat(..., O_DIRECTORY | O_NOFOLLOW)`；创建使用 `openat`/`mkdirat`；重命名和移动使用 `renameatx_np(..., RENAME_EXCL)`，目标已存在时原子失败且不覆盖；删除在重新验证 file identity 后调用 macOS Trash，不调用 unlink/rmdir。

Host 控制面使用 `performFileOperation(context: RequestContext, operation: FileOperation)`；`WorkspaceService` 解析 `workspaceContextID` 并验证其当前 `EnvironmentID` 与请求一致后，才路由到 Environment 级 `FileOperationServing`。`FileOperationResult` 只返回相对路径：create 返回新路径，rename/move 返回旧路径与新路径，trash 返回原路径，不返回 root URL/FD。

`WorkspaceRepository` 提供 Environment 级 Document locator 重定位端口；文件或目录 rename/move 时在同一事务更新精确路径和全部后代路径。`TabRecord.Resource.file` 只保存稳定 `DocumentID`，不保存路径，因此 Context tabs 在重定位时保持原引用和值不变。Task 9 在同一 coordinator 元数据端口接入运行中的 `DocumentRegistry`。

- [ ] **Step 1: 写失败测试**

断言根目录下 create/move 成功；`..`、绝对路径、空文件名、`.`、`/`、NUL、符号链接祖先和跨根目标全部被拒绝；已存在目标不会被覆盖；失败操作不增加 tree revision、不更新 Document path、不更新 tabs；成功 rename/move 返回旧 path 与新 path，并在一个事务重定位精确 Document locator 与目录后代 locator、保持稳定 DocumentID/tab 引用；目录 rename/move/trash 清除旧路径下已展开 tree cache；trash 后物理文件位于系统废纸篓且源路径消失。Host 测试同时覆盖 Context→Environment 不匹配拒绝、显式 wire tag/未知字段拒绝和 NSError domain/code/path 保真。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitWorkspaceTests|CockpitHostCoreTests|CockpitPersistenceTests|CockpitLocalTransportTests'
```

Expected: 失败，原因是 WorkspaceRootHandle 与文件操作协调器不存在。

- [ ] **Step 3: 实现每 Environment 一个串行 coordinator**

`WorkspaceKernelRegistry` 为每个 Environment 创建并持有一个串行 `FileOperationCoordinator`。所有元数据更新发生在文件系统操作成功之后；成功后 coordinator 依次更新 Document locator、保持稳定 DocumentID/tab 引用，并通过 FileTree provider 的同一 mutation gate 丢弃已移动/删除目录的旧 expanded cache、对账受影响父目录和递增 revision，避免 FSEvents 在元数据提交前发布中间树状态。`WorkspaceService` 通过现有 Host XPC `workspaceCommand(Data)` 暴露类型化 `performFileOperation` 低频命令，并在路由前校验当前 Context→Environment；App 不取得 root URL/FD。错误保留真实 URL、`NSPOSIXErrorDomain`/`NSCocoaErrorDomain` 与 code。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitWorkspaceTests|CockpitHostCoreTests|CockpitPersistenceTests|CockpitLocalTransportTests'
/usr/bin/git diff --check
git add Applications/CockpitHost/main.swift Sources/CockpitHostCore Sources/CockpitWorkspace Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift Sources/CockpitLocalTransport Tests/CockpitWorkspaceTests Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift Tests/CockpitLocalTransportTests/HostXPCTests.swift
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
- Modify: `Sources/CockpitWorkspace/WorkspaceRootHandle.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentCodecTests.swift`
- Create: `Tests/CockpitWorkspaceTests/DocumentRecoveryLogTests.swift`
- Create: `Tests/CockpitWorkspaceTests/AtomicFileWriterTests.swift`
- Modify: `Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift`
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

public struct DiskFingerprint: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let byteCount: UInt64
    public let modificationTimeSeconds: Int64
    public let modificationTimeNanoseconds: UInt32
    public let contentSHA256: SHA256Digest
}

public struct DocumentTextBuffer: Sendable {
    public private(set) var text: String
    public private(set) var lineEndings: LineEndingProfile

    public mutating func replaceUTF16(
        range: Range<Int>,
        with replacement: String
    ) throws
}

public struct DocumentFileSnapshot: Sendable {
    public let data: Data
    public let fingerprint: DiskFingerprint
}

public enum DocumentWriteRecoveryState: Hashable, Sendable {
    case staged(RelativePath)
    case stagedLocationUnknown
    case committedButDurabilityUnknown(DiskFingerprint)
}

public struct DocumentWriteRecoveryRequiredError: Error, @unchecked Sendable {
    public let path: RelativePath
    public let state: DocumentWriteRecoveryState
    public let originalError: any Error
}

public enum DocumentStorageError: Error, Hashable, Sendable {
    case fingerprintMismatch(expected: DiskFingerprint, actual: DiskFingerprint)
    case unsupportedFileType
    case unstableRead
}

public protocol DocumentServing: Sendable {
    func readDocument(at path: RelativePath) async throws -> DocumentFileSnapshot
    func atomicallyWriteDocument(
        _ data: Data,
        to path: RelativePath,
        expectedFingerprint: DiskFingerprint
    ) async throws -> DiskFingerprint
}
```

`DiskFingerprint` 定义在 `CockpitProtocol/DocumentMessages.swift`，由打开文件的 FD 上两次稳定 `fstat` 与实际读取 bytes 生成；`modificationTimeNanoseconds` 只允许 `0..<1_000_000_000`，SHA-256 固定 32 bytes。Task 9 的 Host 与 ClientCore 都复用这一类型，不复制第二套 fingerprint。

`DocumentTextBuffer` 只接受已经归一化为 LF 的文本。`replaceUTF16` 使用 Monaco 的 UTF-16 offset，拒绝越界或切开 surrogate pair；删除 edit range 内的换行类型，为 replacement 中每个新增 LF 插入 `preferred`，range 外换行类型及顺序保持不变。由此任意位置插入或删除换行都不会把原始 CRLF/LF 样式按数组下标错误平移。Task 9 的 `DocumentActor.apply` 必须通过该 API 更新文本和换行映射。

恢复日志使用 SwiftProtobuf 的 unsigned-varint length prefix 加精确 message body，不使用固定宽度 length。record 的 `utf8_edit_payload` 由 Task 9 冻结为 exact-schema canonical UTF-8 JSON；mapper 拒绝 unknown fields、非 canonical DocumentID、零 record documentVersion/clientSequence、非 32-byte hash、空/无效 UTF-8/含 NUL payload：

```protobuf
message DocumentRecoveryRecord {
  bytes magic = 1;                 // exact ASCII "CKDR"
  uint32 format_version = 2;       // exact 1
  string document_id = 3;
  uint64 document_version = 4;
  uint64 client_sequence = 5;
  bytes record_sha256 = 6;
  bytes utf8_edit_payload = 7;
}

message DocumentRecoveryCheckpoint {
  bytes magic = 1;                 // exact ASCII "CKDR"
  uint32 format_version = 2;       // exact 2
  string document_id = 3;
  uint64 persisted_document_version = 4;
  uint64 persisted_client_sequence = 5;
  uint64 device_id = 6;
  uint64 inode = 7;
  uint64 byte_count = 8;
  sint64 modification_time_seconds = 9;
  uint32 modification_time_nanoseconds = 10;
  bytes content_sha256 = 11;
  bytes checkpoint_sha256 = 12;
  bytes persisted_document_bytes = 13;
}
```

record format version 保持 1；checkpoint format version 从本补充起固定为 2。record hash 覆盖 ASCII `CKDR-RECORD\0`、big-endian UInt32 record format version、DocumentID 的 16 个 UUID bytes、big-endian UInt64 documentVersion/clientSequence/payload byte count 和原始 payload。checkpoint hash 使用独立 ASCII `CKDR-CHECKPOINT\0` domain separator，并按冻结顺序覆盖 checkpoint format version、DocumentID、persisted versions、完整 fingerprint、persisted bytes 长度与完整 persisted bytes；hash 不依赖 protobuf serialization order。checkpoint mapper 同时验证 `persistedClientSequence <= persistedDocumentVersion`、fingerprint byte count/SHA-256 与 persisted bytes 完全一致；这允许初始 `(0, 0)` baseline，也允许外部 clean reload 后 documentVersion 前进而 clientSequence 保持不变。

`DocumentMessages.swift` 同时提供经验证的 `DocumentRecoveryRecord`、`DocumentRecoveryCheckpoint`、encode/decode/delimited framing mapper；`DocumentRecoveryLog.swift` 的公开边界固定为：

```swift
public enum DocumentRecoveryDiagnostic: Hashable, Sendable {
    case truncatedTail(byteOffset: UInt64)
    case corruptRecord(byteOffset: UInt64)
    case compactionDeferred
}

public struct DocumentRecoveryResult: Sendable {
    public let checkpoint: DocumentRecoveryCheckpoint?
    public let records: [DocumentRecoveryRecord]
    public let diagnostics: [DocumentRecoveryDiagnostic]
}

public final class DocumentRecoveryLog: @unchecked Sendable {
    public init(rootURL: URL, documentID: DocumentID)
    public func append(
        documentVersion: UInt64,
        clientSequence: UInt64,
        utf8EditPayload: Data
    ) async throws
    public func recover() async throws -> DocumentRecoveryResult
    public func checkpoint(
        persistedDocumentVersion: UInt64,
        persistedClientSequence: UInt64,
        diskFingerprint: DiskFingerprint,
        persistedDocumentBytes: Data
    ) async throws -> DocumentRecoveryDiagnostic?
}
```

每个 DocumentID 使用独立的 `<lowercase-uuid>.records.ckdr` 与 `<lowercase-uuid>.checkpoint.ckdr`，文件权限 `0600`。每次 acknowledgement 前必须完整追加 record 并 `fsync`；短写、`fsync` 失败均不得 acknowledgement。恢复从有效 checkpoint 开始，只按严格递增 documentVersion/clientSequence 重放完整且 hash 正确的同一 DocumentID record。clean EOF 正常结束；截断尾 record 不重放并返回带 byte offset 的 `truncatedTail` 诊断；完整 malformed/hash/identity/sequence 错误在首个坏 record 处停止并保留诊断，不跳过坏 record 继续重放。

checkpoint 的 persisted bytes 是该 fingerprint 对应的精确磁盘 bytes（包括 UTF-8 BOM 与原始 LF/CRLF），不是 Monaco 的 LF-normalized text。Task 9 在首次发放 edit lease 前保证 baseline checkpoint 已持久化；后续恢复即使发现磁盘已被外部改写或删除，也从 checkpoint bytes 加完整 records 重建 Host 已确认文本，再进入 conflict/missing，禁止丢弃已确认 edit 或把增量 edit 猜测性应用到外部新文本。

checkpoint/compaction 顺序固定为：同目录唯一 temp 写完整 checkpoint、`fsync` temp、atomic rename、`fsync` recovery root；checkpoint 成为恢复基线后，再以同样的 temp + `fsync` + rename + parent `fsync` 原子发布只含 checkpoint 之后 records 的 compacted log。checkpoint 已提交而 compaction 失败时，旧 log 仍由 checkpoint 过滤，恢复结果不重复 edit，并返回 maintenance diagnostic；不得回滚 checkpoint。Task 8 只保证 checkpoint/compaction 自身所有崩溃点可恢复；磁盘保存成功但 Task 9 尚未调用 checkpoint 的跨组件窗口由 Task 9 作为 fingerprint conflict 处理，禁止静默重复重放。

`DocumentServing.swift` 定义 HostCore port，`WorkspaceRootHandle` 在现有串行 I/O queue 上实现 secure read/write；App 不取得 URL/FD。读写完整相对路径都从 retained root FD 使用 `O_RESOLVE_BENEATH`/`O_NOFOLLOW_ANY`，符号链接祖先不得被跟随。写 temp 前先从仍持有的目标 FD 生成当前 fingerprint；与 `expectedFingerprint` 不同则抛 `fingerprintMismatch`，不得创建 temp 或改写目标。`AtomicFileWriter` 在目标同目录创建唯一 `.cockpit-save-<UUID>`，继承目标 POSIX permissions，写完整 bytes 并 `fsync` temp 后，使用 root-FD-relative `renameatx_np(..., RENAME_RESOLVE_BENEATH | RENAME_NOFOLLOW_ANY)` 原子替换，随后 `fsync` 目标 parent directory。写入、temp fsync 或 rename 失败时原文件保持不变；已创建 temp 不做 identity-check-then-unlink，返回携带真实 staged path 或 location-unknown 的 recovery-required error。rename 成功后 parent `fsync` 失败时返回携带新 fingerprint 的 committed-but-durability-unknown error，不得报告普通未写入失败或回滚。保存前后 fingerprint 都从仍持有的 FD 生成；保存成功返回新 fingerprint。

- [ ] **Step 1: 写失败测试**

覆盖 UTF-8、UTF-8 BOM、LF、CRLF、混合换行打开与逐换行 round-trip、孤立 CR/NUL/无效 UTF-8 拒绝、BOM round-trip；在首部/中部/尾部插入和删除换行后，未触及 CRLF/LF 保持且新增换行使用 preferred，UTF-16 range 切开 surrogate pair 被拒绝。覆盖 fingerprint FD identity/hash/validation、临时文件与目标同目录、原权限保留、temp `fsync` 后 atomic rename、parent directory `fsync`、写入失败保留原文件与 staged recovery、rename 后 parent-fsync 失败报告 committed fingerprint。恢复日志测试使用手写 protobuf fixtures 覆盖 exact magic/version/hash/unknown field、严格 sequence、每次 append fsync、clean EOF、尾部截断恢复到最后完整 record、完整坏 record 停止、checkpoint-first compaction 及 checkpoint 已提交而 compaction 失败不重复重放。每个测试名称分别使用 `documentRecovery`、`documentCodec`、`documentTextBuffer`、`atomicFileWriter` 或 `workspaceRootDocument` 前缀。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'documentRecovery|documentCodec|documentTextBuffer|atomicFileWriter|workspaceRootDocument'
```

Expected: 失败，原因是 codec、recovery log、root document port 和 atomic writer 不存在。当前 Swift Testing test ID 不包含 source filename；原 `CockpitProtocolTests.Phase1MessageTests|CockpitWorkspaceTests.*Tests` filter 本地实测为 `No matching test cases were run` / 0 tests，因此禁止继续使用。GREEN 前后都必须用 `swift test list --skip-build` 对同一 regex 证明匹配集合非空，并让列表匹配数等于实际执行数。

- [ ] **Step 3: 实现无自动保存的持久层**

`DocumentCodec` 给 Monaco 的文本统一为 LF，同时保存每个原始换行的类型；未触及的换行通过 `DocumentTextBuffer.replaceUTF16` 逐个保留，编辑新增的换行使用 `preferred`（LF/CRLF 数量多者，数量相同时取文件首个换行，无换行时取 LF）。`AtomicFileWriter`、`WorkspaceRootHandle`、recovery log 与 checkpoint 严格使用上述 commit point 和 recovery state；保存成功后返回新 fingerprint，Task 9 再写 checkpoint 并压缩已持久化 records。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'documentRecovery|documentCodec|documentTextBuffer|atomicFileWriter|workspaceRootDocument'
/usr/bin/git diff --check
git add Sources/CockpitProtocol/Proto/cockpit.proto Sources/CockpitProtocol/DocumentMessages.swift Sources/CockpitHostCore/DocumentServing.swift Sources/CockpitWorkspace Tests/CockpitProtocolTests/Phase1MessageTests.swift Tests/CockpitWorkspaceTests docs/superpowers/plans/2026-08-06-cockpit-phase-1-implementation.md
git commit -m "feat: add recoverable utf8 document storage"
```

---

### Task 9: 实现 DocumentActor、编辑租约、保存与外部冲突

**Depends on:** Task 8。

**Files:**

- Create: `Sources/CockpitProtocol/DocumentEditing.swift`
- Modify: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Modify: `Sources/CockpitProtocol/DocumentMessages.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Create: `Sources/CockpitWorkspace/DocumentActor.swift`
- Create: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Sources/CockpitWorkspace/DocumentRecoveryLog.swift`
- Modify: `Sources/CockpitWorkspace/FileOperationCoordinator.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Modify: `Sources/CockpitWorkspace/FileTreeReconciler.swift`
- Create: `Sources/CockpitClientCore/DocumentDataTransport.swift`
- Create: `Sources/CockpitClientCore/DocumentClientController.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Modify: `Tests/CockpitProtocolTests/Phase1MessageTests.swift`
- Modify: `Tests/CockpitWorkspaceTests/DocumentRecoveryLogTests.swift`
- Modify: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
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

#### 共享文档值与冻结编辑格式

`CockpitProtocol/DocumentEditing.swift` 是 Workspace 与 ClientCore 共享值的唯一归属，至少定义并完整验证：`DocumentDirtyState(clean/dirty/conflict/missing)`、`UTF16TextEdit`、`DocumentSnapshot`、`EditLease`、`EditTransaction`、`EditAcknowledgement`、maintenance state 与 typed document errors。`DocumentSnapshot` 固定携带 DocumentID、EnvironmentID、RelativePath、LF-normalized text、documentVersion、persistedVersion、last accepted clientSequence、dirty state、当前 observed disk fingerprint（missing 时为 nil）与当前 lease。所有传给 JavaScript 的 counter/offset 都限制在 `0...9_007_199_254_740_991`；public initializer 与 decoder 走同一 validation path。

一个 transaction 含非空 `changes`；所有 change 使用 transaction 前同一文本的 UTF-16 offset/length，按 offset 严格升序且互不重叠。Actor 在 buffer copy 上逆序逐项调用 `DocumentTextBuffer.replaceUTF16`，禁止直接改 `String`。恢复 payload 固定为该 validated transaction 的 sorted-key、exact-schema UTF-8 JSON，包含 canonical DocumentID、EditLeaseID、baseVersion、clientSequence 和 changes；decoder 拒绝 unknown/missing key、非 canonical ID、空 changes、CR/NUL replacement、越界 counter 及非升序/重叠 change。raw canonical JSON 是 recovery record hash 的 payload；不再创建第二种 recovery edit 格式。

#### 身份、持久化与恢复

一个 `(EnvironmentID, RelativePath)` 对应一个稳定 DocumentID。Cockpit rename/move 原子更新 locator 并保持 DocumentID；同一 Environment 中跨 Project/Conversation Context 打开的同一文件共享一个 actor。`WorkspaceRepository.swift` 新增独立 `DocumentMetadataRepository` port 与 validated metadata value：atomic find-or-create by locator、load by DocumentID、compare-and-set persist documentVersion/persistedVersion/dirtyState/editLease。SQLite 实现复用现有 `documents` 表，不新增 migration；UInt64 写 SQLite 前拒绝超过 `Int64.max` 的值。recovery checkpoint/records 是已接受文本与版本的恢复权威，SQLite 是 DocumentID/locator/query state；open 时使用恢复结果校正 SQLite 中因 crash 落后的 metadata。

首次 open 的新文档从 version 0、persistedVersion 0、clientSequence 0 开始。Registry 在发放首个 edit lease 或接受 edit 前持久化 Task 8 exact-bytes baseline checkpoint。恢复规则固定为：

1. checkpoint fingerprint 等于当前磁盘时，从 checkpoint bytes decode baseline 并只重放 checkpoint 后完整、hash 正确、严格递增 records；
2. checkpoint 存在且磁盘已改写时，仍从 checkpoint bytes 加 records 重建 Host 文本并进入 conflict；磁盘已删除则以同一 Host 文本进入 missing；
3. 没有 checkpoint 且没有 records、metadata 为 clean 时，以真实磁盘建立 baseline；没有 checkpoint 但存在 records，或 metadata 表示未持久化状态时，返回 recovery-unavailable，禁止猜测；
4. truncated tail 只忽略未完整 record；完整 corrupt record 在首个坏 record 停止。只重放此点之前完整且 durable 的 records，并保留 diagnostic。

每次 Host 重启都清除旧 edit lease；远端/客户端必须重新获取 lease。一个 lease 可写，其他 viewer 只读。

#### Lease、sequence 与 Actor commit point

`clientSequence` 是 document-global sequence，首个 edit 为 1，每次 accepted transaction 精确加 1，跨 client 和 lease transfer 永不重置。`documentVersion` 每次 accepted edit 或替换 Host 文本的 reload/discard 精确加 1，因此始终满足 `clientSequence <= documentVersion`。transfer 校验当前 lease ID，生成新 lease ID、保留 last accepted sequence；同一 owner 重复 acquire 返回当前 lease，其他 client acquire 返回 typed lease-held。

`apply` 固定顺序：校验 document/lease/baseVersion/next clientSequence 与 normalized changes → 在 `DocumentTextBuffer` copy 上逆序 apply → canonical encode → append recovery record 并 `fsync` → 原子提交 Actor text/version/dirty/last transaction → compare-and-set 持久化 metadata → acknowledgement。metadata 在 durable record 后失败时 Actor 进入 fail-closed recovery-required，返回携带 committed acknowledgement 的 typed error，不发送普通 ack；restart 从 log 修复 SQLite 后，同一 last sequence + 同一 canonical payload 返回原 acknowledgement 且不追加 record。同一 last sequence + 不同 payload 返回 duplicate-mismatch；更旧 sequence 返回 stale；大于 next sequence 返回 gap。只保证最后一个 accepted transaction 的 retry 幂等，ClientController 使用 stop-and-wait 保证不会需要更早 transaction 的 retry。

Actor 所有会 `await` 的 mutating operation 使用同一 non-reentrant operation gate；save/discard/external reload/lease transfer 期间不得由 actor reentrancy 插入 apply。`flush(through:)` 在 `through <= lastAcceptedClientSequence` 时返回当前 authoritative documentVersion；大于 last accepted 时返回 sequence-gap，不无限等待。ClientController 先排空本地有序发送队列，再调用 Host flush。

#### Save、discard 与外部修改

save 固定顺序：确认 flush barrier 与 expected fingerprint 等于 Actor 当前 observed fingerprint → encode exact BOM/line endings bytes → Task 8 root-capability atomic write → checkpoint(new fingerprint + exact saved bytes + current version/sequence) → compare-and-set metadata persistedVersion/clean → 更新 Actor 并返回 snapshot。checkpoint 的 `.compactionDeferred` 不回滚已提交 checkpoint，snapshot maintenance state 暴露该 diagnostic。atomic write 的 `committedButDurabilityUnknown` 不写 checkpoint，Actor 进入 conflict/recovery-required；磁盘已提交但 checkpoint/metadata 失败同样不得报告 clean，restart 按 fingerprint mismatch 重建 Host 文本并进入 conflict。

discard 读取并 decode 当前真实磁盘，Host 文本替换后 documentVersion +1、persistedVersion 同步、写 exact-bytes checkpoint、持久化 clean；missing 时返回 typed file-missing。外部 fingerprint 未变化时 no-op；clean 文档被改写时 reload、version +1、checkpoint 并保持 clean；dirty/conflict 文档被改写时保留 Host 文本、更新 observed fingerprint 并进入 conflict；外部删除始终保留 Host 文本、observed fingerprint 置 nil 并标记 missing。missing 文件重新出现时，原本 clean（documentVersion == persistedVersion）则 reload；原本 dirty 则进入 conflict。conflict 可在显式使用最新 observed fingerprint 的 save 中覆盖外部版本，或通过 discard 接受外部版本；missing 不在 Task 9 中自动重建文件。

#### Registry、文件操作与 production wiring

`DocumentRegistry` 同时按 locator 与 DocumentID 索引，只保留已打开 actor；open 通过 metadata repository atomic find-or-create，确保同一 locator 返回同一 actor。`WorkspaceKernel` 只创建一个共享 `WorkspaceRootHandle`，同时供 file operations 与 document serving 使用，并持有 DocumentRegistry。`WorkspaceKernelRegistry` 明确注入 metadata repository 与 `documentRecoveryRoot`；`CockpitHost/main.swift` 传入 `storage.documentRecoveryRoot` 和 SQLite repository，禁止只在测试中 wiring。

`FileTreeReconciler` 对每次 invalidation 都通知 Registry，通知不依赖目录是否展开，也不依赖 `FileTreeDelta` 是否为 nil。targeted directory scope 通知该目录直接文件及子树内匹配的全部 open actor；`allExpanded` 对 Registry 的语义是全部 open actor。Registry 对每个匹配 actor 经 `DocumentServing` 读取真实磁盘并生成 `ExternalDocumentChange`，只通知 open actor，不扫描整个项目。

为避免 Cockpit 内部 rename/move 的 FSEvent 在物理提交与 locator 提交之间被误判成 external delete，FileOperationCoordinator 在物理 mutation 前取得 Registry internal-mutation lease；期间 invalidation 只排队。成功顺序固定为 repository preflight → physical mutation → stage tree → repository locator transaction → nonthrowing live-registry relocation → tree commit → release Registry lease and reconcile queued invalidations。repository 失败沿用 Task 7 committed recovery-required；Registry 不得先于 DB 改 locator。

#### ClientCore port 与状态机

`DocumentDataTransport` 固定提供 open/snapshot/acquire lease/transfer/apply/flush/save/discard，方法只使用 CockpitProtocol shared values。`DocumentClientController` 只依赖该 port，不引用 DocumentActor、XPC、UDS、AppKit 或 WebKit；状态固定为 `.closed`、`.ready`、`.readOnly`、`.resynchronizing`。Controller 为每个 document 维护有序 stop-and-wait queue 与 document-global next clientSequence；本地可继续排队，网络只发送一个 transaction。lease/baseVersion/stale/gap/duplicate-mismatch/recovery-required 任一错误立即进入 `.resynchronizing`，停止 dequeue；完整 snapshot（及可写时的新 lease）replace 完成前禁止继续发送。flush 等待 through sequence 的全部 queued transaction 得到 acknowledgement 后再调用 transport flush。

- [ ] **Step 1: 写失败测试**

所有新 Swift Testing 函数强制使用 `documentEditing`、`documentPersistence`、`documentActor`、`documentRegistry`、`documentExternalChange` 或 `documentClientController` lowerCamel 前缀；Task 8 checkpoint compatibility test 使用 `documentRecovery` 前缀。覆盖 exact canonical recovery JSON、checkpoint v2 exact bytes/hash/0 baseline/`clientSequence <= documentVersion`、SQLite find-or-create/CAS/stale repair；覆盖 baseVersion/clientSequence 单调校验、最后一个重复 edit 幂等确认、same-sequence different-payload、sequence gap、错误 lease、lease transfer sequence 不重置、actor await reentrancy gate、metadata-after-log failure fail-closed、flush barrier、save/checkpoint/metadata commit points、compaction diagnostic、discard、rename/move 后 DocumentID 不变、崩溃恢复只包含 durable accepted edit。用真实临时目录分别改写和删除磁盘文件，触发未展开目录/content-only/allExpanded invalidation，断言干净文档重载、脏文档 conflict、外部删除保留 Host 文本并 missing，以及内部 rename invalidation 不产生瞬时 missing。

- [ ] **Step 2: 运行失败测试**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'documentRecovery|documentEditing|documentPersistence|documentActor|documentRegistry|documentExternalChange|documentClientController'
```

Expected: 失败，原因是 checkpoint v2/shared document values、DocumentActor、registry、metadata repository 与 client controller 不存在。原计划 regex `CockpitWorkspaceTests.Document|CockpitClientCoreTests.DocumentClientControllerTests` 已在 Task 9 preflight 通过 `swift test list --skip-build` 实测为 0 matches，禁止继续使用。写测试前用新 regex 验证现有 `documentRecovery` compatibility 集合非空；GREEN 后必须再次用 `swift test list --skip-build | grep -E` 证明匹配 ID 数量非零且等于实际执行数。

- [ ] **Step 3: 实现 actor 与客户端停止/重同步状态机**

严格实现上述 shared model、baseline recovery、metadata、Actor/Registry 与 ClientController 合同。Monaco 本地 edit 在 Host acknowledgement 前只存在于客户端副本；Host 每次接受 edit 后先 durable 写恢复日志，再返回新 documentVersion。版本、sequence、lease 或 recovery-required 错误使 client controller 进入 `.resynchronizing`，在完整 snapshot 应用前不继续发送。

- [ ] **Step 4: 运行 focused checks 并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'documentRecovery|documentEditing|documentPersistence|documentActor|documentRegistry|documentExternalChange|documentClientController'
/usr/bin/swift test list --skip-build | grep -E 'documentRecovery|documentEditing|documentPersistence|documentActor|documentRegistry|documentExternalChange|documentClientController'
/usr/bin/git diff --check
git add docs/superpowers/plans/2026-08-06-cockpit-phase-1-implementation.md Sources/CockpitProtocol Sources/CockpitHostCore/WorkspaceRepository.swift Sources/CockpitWorkspace Sources/CockpitClientCore Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift Applications/CockpitHost/main.swift Tests/CockpitProtocolTests/Phase1MessageTests.swift Tests/CockpitWorkspaceTests Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift Tests/CockpitClientCoreTests
git commit -m "feat: coordinate authoritative documents"
```

---

### Task 10: 接入每窗口一个 Monaco WKWebView

**Depends on:** Task 9。Task 10 仍是一个 Phase 任务；按 10A/10B/10C 串行实现并各自提交，Task 总数不变。

**Pinned build inputs:** Node `26.7.0` Current、pnpm `11.20.0`、Monaco `0.56.0`、esbuild `0.28.1`、SwiftProtobuf `1.38.1`。Node/pnpm 只参与构建；不得修改 Monaco 声明的 transitive pins，不新增 npm 或 Swift 第三方依赖。App bundle gate 必须证明 App 中没有 `node`、`pnpm`、`node_modules`、`EditorRuntime/src` 或 Monaco 源码。

#### Task 10A: 冻结 SwiftProtobuf 数据面 ABI 与 Host port

**Files:**

- Modify: `Sources/CockpitTypes/ProtocolVersion.swift`
- Modify: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Create: `Sources/CockpitProtocol/HostDataPlaneMessages.swift`
- Create: `Sources/CockpitClientCore/FileTreeDataTransport.swift`
- Create: `Sources/CockpitHostCore/HostDataPlaneServing.swift`
- Modify: `Sources/CockpitWorkspace/DocumentActor.swift`
- Modify: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Create: `Sources/CockpitWorkspace/WorkspaceHostDataPlaneService.swift`
- Create: `Tests/CockpitProtocolTests/HostDataPlaneProtocolTests.swift`
- Modify: `Tests/CockpitWorkspaceTests/DocumentActorTests.swift`
- Create: `Tests/CockpitWorkspaceTests/WorkspaceKernelDataPlaneTests.swift`

**Dependency boundary:** `CockpitProtocol` 继续只依赖 `CockpitTypes` 与 SwiftProtobuf；SwiftProtobuf plugin 生成的 `cockpit.pb.swift` 仍在 `.build`，不得手改或提交。`HostDataPlaneMessages.swift` 同时定义 shared `HostDataPlaneBinding`、protobuf/domain 双向 mapper 与 validated remote error value；不得引用 HostCore。`CockpitHostCore` 定义 port，`CockpitWorkspace` 实现 port；`CockpitLocalTransport -> CockpitHostCore`，禁止给 `CockpitLocalTransport` 增加 `CockpitWorkspace` 依赖。10A 不修改 `Package.swift`。

**Shared port:**

```swift
public struct HostDataPlaneBinding: Hashable, Sendable {
    public let clientInstanceID: ClientInstanceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let activeContextGeneration: UInt64

    public init(
        validatingClientInstanceID clientInstanceID: ClientInstanceID,
        windowID: WindowID,
        workspaceContextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        activeContextGeneration: UInt64
    ) throws {
        guard activeContextGeneration > 0,
              activeContextGeneration <= documentJavaScriptMaximum
        else { throw ProtocolMappingError.invalidValue("host_data_plane_binding") }
        self.clientInstanceID = clientInstanceID
        self.windowID = windowID
        self.workspaceContextID = workspaceContextID
        self.environmentID = environmentID
        self.activeContextGeneration = activeContextGeneration
    }
}

public enum HostDataPlaneServiceError: Error, Hashable, Sendable {
    case contextMismatch
    case environmentMismatch
    case documentNotOpen
}

public enum HostDataPlaneDocumentError: Error, Hashable, Sendable {
    case committedRecoveryRequired(EditAcknowledgement)
}

public struct DataPlaneRemoteError: Error, Hashable, Sendable {
    public let code: CPDataPlaneErrorCode
    public let expected: UInt64?
    public let actual: UInt64?
    public init(validatingCode code: CPDataPlaneErrorCode,
                expected: UInt64?, actual: UInt64?) throws
}

public protocol FileTreeDataTransport: Sendable {
    func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot
    func changes(
        after revision: UInt64,
        expandedDirectories: Set<WorkspaceDirectory>
    ) -> AsyncThrowingStream<FileTreeDelta, Error>
}

public protocol HostDataPlaneServing: Sendable {
    func openDocument(binding: HostDataPlaneBinding, at path: RelativePath) async throws -> DocumentSnapshot
    func snapshot(binding: HostDataPlaneBinding, documentID: DocumentID) async throws -> DocumentSnapshot
    func acquireEditLease(binding: HostDataPlaneBinding, documentID: DocumentID) async throws -> EditLease
    func transferEditLease(binding: HostDataPlaneBinding, documentID: DocumentID, from leaseID: EditLeaseID, to client: ClientInstanceID) async throws -> EditLease
    func apply(binding: HostDataPlaneBinding, transaction: EditTransaction) async throws -> EditAcknowledgement
    func flush(binding: HostDataPlaneBinding, documentID: DocumentID, through clientSequence: UInt64) async throws -> UInt64
    func save(binding: HostDataPlaneBinding, documentID: DocumentID, expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot
    func discard(binding: HostDataPlaneBinding, documentID: DocumentID) async throws -> DocumentSnapshot
    func fileTreeChildren(binding: HostDataPlaneBinding, at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot
    func fileTreeChanges(binding: HostDataPlaneBinding, after revision: UInt64) -> AsyncThrowingStream<FileTreeDelta, Error>
}
```

`HostDataPlaneDocumentError` 定义在 `CockpitHostCore/HostDataPlaneServing.swift`，其 public cases 与 associated values 是 LocalTransport 可见的 shared document data-plane boundary；它不得引用 `CockpitWorkspace`。`WorkspaceHostDataPlaneService.apply` 必须 catch concrete Workspace-only `DocumentCommitRecoveryRequiredError` 并 throw `.committedRecoveryRequired(error.committedAcknowledgement)`；其它 Task 9 `DocumentProtocolError`/`DocumentStorageError` 原样穿过 shared port。10B LocalTransport server 只识别这个 shared recovery error，不得 import/catch Workspace concrete error。

`HostDataPlaneBinding` 的唯一构造入口是上述 public validating initializer。XPC export 从已通过现有 negotiated-version/exact-key validation 的 `RequestContext` 派生 client/window/context/environment/generation；request ID 只用于 XPC correlation，不进入 ticket binding，client 不得另传或覆盖 binding 字段。`WorkspaceHostDataPlaneService` 实现 HostCore port，构造参数固定为 `any WorkspaceServing` 与 `WorkspaceKernelRegistry`：先调用 `WorkspaceServing.resolveContext(binding.workspaceContextID)` 并 exact compare EnvironmentID，再从 registry 解析该 Environment 的唯一 kernel，不复制 repository 解析逻辑。调用链固定为 service resolve/register 返回后再取 kernel，不在持有 registry actor isolation 时回调 `WorkspaceService`，因此无 actor 依赖循环。document lookup 使用 `DocumentRegistry` 新增的 public actor method `document(id:) -> DocumentActor?`，不得暴露 `byID`。每个 document 请求先验证 binding，再验证 document 已在该 Environment registry 打开，最后调用 Task 9 actor；open 只通过 `DocumentRegistry.open(at:)`。文件树只通过该 kernel 的 `FileTreeProvider`，children 传 binding generation，changes 传 binding environment/revision。

Document authorization 不信任 payload client identity：acquire wire 不含 client，service 固定调用 actor `acquireEditLease(client: binding.clientInstanceID)`；`HostDataPlaneClient.acquireEditLease(documentID:client:)` 在发包前要求参数 client exact equal immutable binding client。wire binding/payload client 字段不一致在 mapper 层拒绝，Host port/Actor 调用数为 0。通过 mapper 后，Workspace service 不做 `snapshot()` 后再 mutate 的 TOCTOU 检查，而只调用以下 Task 9 Actor authorized overload；每个 overload 在同一次 `enterOperation()`/`leaveOperation()` gate 内先 exact compare current lease owner 与 `authorizedClient`，再执行原 operation 的 locked body：

```swift
public func transferEditLease(
    from leaseID: EditLeaseID,
    to client: ClientInstanceID,
    authorizedClient: ClientInstanceID
) async throws -> EditLease
public func apply(
    _ transaction: EditTransaction,
    authorizedClient: ClientInstanceID
) async throws -> EditAcknowledgement
public func flush(
    through clientSequence: UInt64,
    authorizedClient: ClientInstanceID
) async throws -> UInt64
public func save(
    expectedFingerprint: DiskFingerprint,
    authorizedClient: ClientInstanceID
) async throws -> DocumentSnapshot
public func discard(
    authorizedClient: ClientInstanceID
) async throws -> DocumentSnapshot
```

`DocumentActor` 将现有 operation bodies 提取为仅在 gate 内调用的 private locked helpers；authorized overload 与 Task 9 已有 public overload各自只进入一次 gate，禁止 public method 互调造成二次 gate。authorized owner mismatch 抛既有 `DocumentProtocolError.invalidLease`；这次请求允许 exactly one Workspace Host port call 和 exactly one authorized Actor method call，但 storage write、recovery-log append/truncate、metadata CAS、document mutation 全为 0。transfer 与 apply/flush/save/discard 的并发交错由 actor operation gate 串行：mutation 先入 gate 则在 transfer 前完成，transfer 先入 gate 则旧 owner mutation 在 owner compare 处失败；不存在 transfer 后旧 owner mutation成功。

**Protocol feature and framing:** `ProtocolFeature` 新增 raw value `host-data-plane`。连接只协商 Protocol `1.1` 和该 feature，service kind 必须精确为 `host-data-plane`。只复用现有 32-byte big-endian `FrameHeader`，禁止定义第二套 header；布局精确为 magic `4` + frame version `2` + flags `2` + channel `4` + sequence `8` + acknowledgement `8` + payloadLength `4`。fixture 精确为 `43 4B 50 54 00 01 00 00 00 00 00 03 00 00 00 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00 05`（flags 0、Channel 3、seq 1、ack 0、payload 5），encode/decode 必须 exact round-trip。Channel `0` 是 handshake/authentication，Channel `3` 是 document，Channel `4` 是 file tree。所有 frame `flags == 0`，不支持 ack-only/compression；`payloadLength` 必须等于实际 protobuf bytes并沿用 `FrameHeader.maximumPayloadLength == 16_777_216`。

每个方向、每个 channel 独立 sequence：首帧 `seq=1`，随后严格 `+1`，溢出前关闭；`ack` 是该方向已完整验证的对端同 channel 最大连续 seq，初始 `0`，只单调递增且不得大于对端已发送 seq。Channel 0 只传 `CPHostDataPlaneControlEnvelope`：client `seq=1,ack=0` 发送其 `handshake_request`（唯一 requested feature 为 `host-data-plane`），server `seq=1,ack=1` 返回 `handshake_response`；client `seq=2,ack=1` 发送 `authenticate`，server `seq=2,ack=2` 返回 `authenticated`。任一 control failure 返回同 envelope 的 `error`，error bytes 不得被 handshake/auth response mapper 接受。握手成功后 Channel 3/4 各从 `seq=1,ack=0` 开始。错误响应使用收到请求的 channel、server 下一 seq 与已验证 ack；wrong channel/flags/length/seq/ack/malformed protobuf 发送类型化 error 后关闭连接。

每个 Channel 3/4 envelope 都带 canonical lowercase UUID `request_id` 与完整 `DataPlaneBinding`。同连接的 request ID 不得重用。响应重复 unary request ID。验证顺序固定为：读取精确 32-byte header并验证 magic/frame-version/payload length bound；验证 allowed channel/flags/seq/ack；按 channel 选择 control/document/file-tree envelope并验证 deserialize/unknown fields/oneof/enum；再验证 protocol handshake version/feature/service kind、canonical request ID/binding IDs、ticket binding/context/environment/generation，最后验证 payload-specific document/version/sequence 或 tree revision。unknown channel 在解析 payload 前拒绝。任一步失败不得调用 Host port。

**Exact protobuf declarations:** 在现有 `cockpit.protocol.v1` package 中追加以下 field numbers；不得复用、改号或把 JSON/Codable 塞入 `bytes`：

```protobuf
message DataPlaneBinding { string client_instance_id = 1; string window_id = 2; WorkspaceContextID workspace_context_id = 3; string environment_id = 4; uint64 active_context_generation = 5; }
message HostDataPlaneTicketRequest { RequestContext context = 1; }
message HostDataPlaneTicketResponse { string socket_path = 1; string ticket = 2; uint32 valid_for_milliseconds = 3; }
message HostDataPlaneAuthenticate { string ticket = 1; DataPlaneBinding binding = 2; }
message HostDataPlaneAuthenticated { DataPlaneBinding binding = 1; }

enum DataPlaneErrorCode {
  DATA_PLANE_ERROR_CODE_UNSPECIFIED = 0;
  DATA_PLANE_ERROR_CODE_MALFORMED_MESSAGE = 1;
  DATA_PLANE_ERROR_CODE_WRONG_CHANNEL = 2;
  DATA_PLANE_ERROR_CODE_SEQUENCE_VIOLATION = 3;
  DATA_PLANE_ERROR_CODE_ACK_VIOLATION = 4;
  DATA_PLANE_ERROR_CODE_UNAUTHORIZED_PEER = 5;
  DATA_PLANE_ERROR_CODE_INVALID_TICKET = 6;
  DATA_PLANE_ERROR_CODE_TICKET_EXPIRED = 7;
  DATA_PLANE_ERROR_CODE_TICKET_REPLAY = 8;
  DATA_PLANE_ERROR_CODE_CONTEXT_MISMATCH = 9;
  DATA_PLANE_ERROR_CODE_ENVIRONMENT_MISMATCH = 10;
  DATA_PLANE_ERROR_CODE_GENERATION_MISMATCH = 11;
  DATA_PLANE_ERROR_CODE_REQUEST_ID_REUSE = 12;
  DATA_PLANE_ERROR_CODE_DOCUMENT_NOT_OPEN = 20;
  DATA_PLANE_ERROR_CODE_DOCUMENT_INVALID_VALUE = 21;
  DATA_PLANE_ERROR_CODE_DOCUMENT_INVALID_LEASE = 22;
  DATA_PLANE_ERROR_CODE_DOCUMENT_LEASE_HELD = 23;
  DATA_PLANE_ERROR_CODE_DOCUMENT_BASE_VERSION_MISMATCH = 24;
  DATA_PLANE_ERROR_CODE_DOCUMENT_SEQUENCE_GAP = 25;
  DATA_PLANE_ERROR_CODE_DOCUMENT_DUPLICATE_MISMATCH = 26;
  DATA_PLANE_ERROR_CODE_DOCUMENT_STALE_SEQUENCE = 27;
  DATA_PLANE_ERROR_CODE_DOCUMENT_RECOVERY_REQUIRED = 28;
  DATA_PLANE_ERROR_CODE_DOCUMENT_RESYNCHRONIZING = 29;
  DATA_PLANE_ERROR_CODE_DOCUMENT_READ_ONLY = 30;
  DATA_PLANE_ERROR_CODE_DOCUMENT_FILE_MISSING = 31;
  DATA_PLANE_ERROR_CODE_DOCUMENT_FINGERPRINT_MISMATCH = 32;
  DATA_PLANE_ERROR_CODE_TREE_ZERO_GENERATION = 40;
  DATA_PLANE_ERROR_CODE_TREE_SYMBOLIC_LINK = 41;
  DATA_PLANE_ERROR_CODE_TREE_REVISION_UNAVAILABLE = 42;
  DATA_PLANE_ERROR_CODE_TREE_EVENT_SOURCE_UNAVAILABLE = 43;
  DATA_PLANE_ERROR_CODE_TREE_ENUMERATION_FAILED = 44;
  DATA_PLANE_ERROR_CODE_TREE_BACKPRESSURE = 45;
  DATA_PLANE_ERROR_CODE_REQUEST_CANCELLED = 50;
  DATA_PLANE_ERROR_CODE_INTERNAL = 60;
}
message DataPlaneError { DataPlaneErrorCode code = 1; optional uint64 expected = 2; optional uint64 actual = 3; DocumentAcknowledgement committed_acknowledgement = 4; }
message EmptyResult {}
message HostDataPlaneControlEnvelope {
  oneof payload {
    HandshakeRequest handshake_request = 1;
    HandshakeResponse handshake_response = 2;
    HostDataPlaneAuthenticate authenticate = 3;
    HostDataPlaneAuthenticated authenticated = 4;
    DataPlaneError error = 5;
  }
}

message UTF16TextChange { uint64 offset = 1; uint64 length = 2; string replacement = 3; }
message DiskFingerprintValue { uint64 device_id = 1; uint64 inode = 2; uint64 byte_count = 3; sint64 modification_time_seconds = 4; uint32 modification_time_nanoseconds = 5; bytes content_sha256 = 6; }
message EditLeaseValue { string edit_lease_id = 1; string document_id = 2; string client_instance_id = 3; }
enum DocumentDirtyStateValue { DOCUMENT_DIRTY_STATE_VALUE_UNSPECIFIED = 0; DOCUMENT_DIRTY_STATE_VALUE_CLEAN = 1; DOCUMENT_DIRTY_STATE_VALUE_DIRTY = 2; DOCUMENT_DIRTY_STATE_VALUE_CONFLICT = 3; DOCUMENT_DIRTY_STATE_VALUE_MISSING = 4; }
enum DocumentMaintenanceStateValue { DOCUMENT_MAINTENANCE_STATE_VALUE_UNSPECIFIED = 0; DOCUMENT_MAINTENANCE_STATE_VALUE_TRUNCATED_RECOVERY_TAIL = 1; DOCUMENT_MAINTENANCE_STATE_VALUE_CORRUPT_RECOVERY_RECORD = 2; DOCUMENT_MAINTENANCE_STATE_VALUE_COMPACTION_DEFERRED = 3; }
message DocumentSnapshotValue { string document_id = 1; string environment_id = 2; string relative_path = 3; string text = 4; uint64 document_version = 5; uint64 persisted_version = 6; uint64 last_accepted_client_sequence = 7; DocumentDirtyStateValue dirty_state = 8; DiskFingerprintValue observed_disk_fingerprint = 9; EditLeaseValue current_lease = 10; repeated DocumentMaintenanceStateValue maintenance = 11; }
message DocumentAcknowledgement { string document_id = 1; uint64 client_sequence = 2; uint64 document_version = 3; }
message DocumentOpenRequest { string relative_path = 1; }
message DocumentSnapshotRequest { string document_id = 1; }
message DocumentAcquireLeaseRequest { string document_id = 1; reserved 2; }
message DocumentTransferLeaseRequest { string document_id = 1; string from_edit_lease_id = 2; string target_client_instance_id = 3; }
message DocumentApplyRequest { string document_id = 1; string edit_lease_id = 2; uint64 base_version = 3; uint64 client_sequence = 4; repeated UTF16TextChange changes = 5; }
message DocumentFlushRequest { string document_id = 1; uint64 through_client_sequence = 2; }
message DocumentFlushResult { uint64 document_version = 1; }
message DocumentSaveRequest { string document_id = 1; DiskFingerprintValue expected_fingerprint = 2; }
message DocumentDiscardRequest { string document_id = 1; }
message DocumentEnvelope {
  string request_id = 1; DataPlaneBinding binding = 2;
  oneof payload {
    DocumentOpenRequest open_request = 10; DocumentSnapshotRequest snapshot_request = 11;
    DocumentAcquireLeaseRequest acquire_lease_request = 12; DocumentTransferLeaseRequest transfer_lease_request = 13;
    DocumentApplyRequest apply_request = 14; DocumentFlushRequest flush_request = 15;
    DocumentSaveRequest save_request = 16; DocumentDiscardRequest discard_request = 17;
    DocumentSnapshotValue snapshot_result = 30; EditLeaseValue lease_result = 31;
    DocumentAcknowledgement acknowledgement_result = 32; DocumentFlushResult flush_result = 33;
    DataPlaneError error = 40;
  }
}

enum WorkspaceDirectoryKind { WORKSPACE_DIRECTORY_KIND_UNSPECIFIED = 0; WORKSPACE_DIRECTORY_KIND_ROOT = 1; WORKSPACE_DIRECTORY_KIND_RELATIVE = 2; }
message WorkspaceDirectoryValue { WorkspaceDirectoryKind kind = 1; optional string relative_path = 2; }
enum FileTreeEntryKindValue { FILE_TREE_ENTRY_KIND_VALUE_UNSPECIFIED = 0; FILE_TREE_ENTRY_KIND_VALUE_FILE = 1; FILE_TREE_ENTRY_KIND_VALUE_DIRECTORY = 2; FILE_TREE_ENTRY_KIND_VALUE_SYMBOLIC_LINK = 3; }
message FileTreeEntryIdentityValue { string environment_id = 1; string relative_path = 2; }
message FileTreeEntryValue { FileTreeEntryIdentityValue identity = 1; FileTreeEntryKindValue kind = 2; }
message FileTreeMutationValue { oneof mutation { FileTreeEntryValue insert = 1; FileTreeEntryIdentityValue remove = 2; FileTreeEntryValue update = 3; } }
message FileTreeSnapshotValue { string environment_id = 1; WorkspaceDirectoryValue directory = 2; uint64 generation = 3; uint64 revision = 4; repeated FileTreeEntryValue children = 5; }
message FileTreeDeltaValue { string environment_id = 1; WorkspaceDirectoryValue directory = 2; uint64 revision = 3; repeated FileTreeMutationValue mutations = 4; }
message FileTreeChildrenRequest { WorkspaceDirectoryValue directory = 1; }
message FileTreeSubscribeRequest { uint64 after_revision = 1; }
message FileTreeSubscriptionAccepted { string subscription_id = 1; uint64 revision = 2; }
message FileTreeDeltaEvent { string subscription_id = 1; string event_id = 2; FileTreeDeltaValue delta = 3; }
message FileTreeDeltaAck { string subscription_id = 1; string event_id = 2; uint64 revision = 3; }
message FileTreeAckAccepted { string subscription_id = 1; string event_id = 2; uint64 revision = 3; }
message FileTreeCancelRequest { string subscription_id = 1; }
message FileTreeCancelled { string subscription_id = 1; }
message FileTreeEnvelope {
  string request_id = 1; DataPlaneBinding binding = 2;
  oneof payload {
    FileTreeChildrenRequest children_request = 10; FileTreeSubscribeRequest subscribe_request = 11;
    FileTreeDeltaAck delta_ack = 12; FileTreeCancelRequest cancel_request = 13;
    FileTreeSnapshotValue snapshot_result = 30; FileTreeSubscriptionAccepted subscription_accepted = 31;
    FileTreeDeltaEvent delta_event = 32; FileTreeAckAccepted ack_accepted = 33;
    FileTreeCancelled cancelled = 34; DataPlaneError error = 40;
  }
}
```

All IDs/paths/enums use strict manual mappers: canonical lowercase UUID textual form; `WorkspaceDirectoryKind.root` forbids `relative_path`, `.relative` requires it；FileTree mutation 必须恰有 insert/remove/update oneof；snapshot generation 为 `1...9_007_199_254_740_991`，revision 为 `0...9_007_199_254_740_991`，delta revision 为 `1...9_007_199_254_740_991`。protobuf `unknownFields`, absent/unknown oneof, `.UNRECOGNIZED`, `UNSPECIFIED`, SHA-256 not exactly 32 bytes, fingerprint nanoseconds `>=1_000_000_000`, UInt counter above JS-safe maximum, CR/NUL text, invalid Task 9 `UTF16TextEdit`, or inconsistent nested environment/document/lease are `MALFORMED_MESSAGE`/domain typed errors and never coerced。`DataPlaneError.expected/actual` 只在 generation/base-version/sequence-gap/tree-revision mismatch 同时出现；`committed_acknowledgement` 只在 `DOCUMENT_RECOVERY_REQUIRED` 出现；其它 code 禁止这些 presence fields。Workspace-only `DocumentCommitRecoveryRequiredError` 先在 Workspace service 映射为 shared `HostDataPlaneDocumentError.committedRecoveryRequired`；10B server 再把 shared error 映射到 `DOCUMENT_RECOVERY_REQUIRED` 并携带 exact committed acknowledgement；client treats it as Task 9 recovery-required and resynchronizes。

**File-tree subscription:** subscribe request ID becomes immutable `subscription_id`; accepted repeats it. Each server delta has a fresh canonical `event_id`, also used as that event envelope request ID. Client ACK has a fresh request ID and references subscription/event/revision; server replies `ack_accepted` using ACK request ID. Exactly one unacknowledged delta is allowed per subscription; the server does not pull the next `AsyncThrowingStream` element until matching ACK. Wrong ACK/revision is `TREE_BACKPRESSURE` and cancels that subscription. Cancel has a fresh request ID, references subscription ID, replies `cancelled`, and terminates the provider iterator. Socket close cancels all iterators. Reconnect obtains a new ticket/socket and subscribes after the last applied revision; `TREE_REVISION_UNAVAILABLE` triggers children refresh for the client-owned expanded-directory set, then subscribe from the maximum returned snapshot revision. No delta is silently dropped.

- [ ] **10A Step 1: 写 RED tests**

新增 Swift Testing 函数只用 `hostDataPlaneProtocol` 与 `workspaceKernelDataPlane` lowerCamel prefixes；`DocumentActorTests.swift` 新增函数使用 `workspaceKernelDataPlaneActor` prefix（因此命中同一 filter）。覆盖现有 32-byte header 的 exact `4/2/2/4/8/8/4` fixture、每个 proto oneof/enum/error numeric value、control error bytes 绝不被 handshake response 接受、header-before-channel-envelope validation、unknown fields、shared binding public init/双向 mapper/no reverse dependency、exact bytes round-trip、JS-safe bounds、binding/revision/version validation order、所有 `DocumentDataTransport` 操作、file-tree children/subscription/delta/ack/cancel/backpressure/reconnect recovery，以及 Workspace registry 的 context/environment/document/client-lease routing 和无依赖循环。Workspace tests 必须覆盖 concrete recovery error → shared recovery error、authorized Actor owner mismatch 的一次 Actor/零 storage-mutation、以及 lease transfer 与 apply/flush/save/discard 的两种 gate interleaving。测试文件先于行为实现编写；为得到可执行而非仅 compile-error 的 RED，只添加本节已经完整声明的 public types/method signatures 与 deterministic fail-closed bodies（mapper 一律 throw `ProtocolMappingError.invalidValue("host_data_plane")`，Host service 一律 throw `HostDataPlaneServiceError.contextMismatch`），不得预写任何成功分支。

- [ ] **10A Step 2: 证明 RED filter 非零并运行**

```bash
/usr/bin/swift build --disable-automatic-resolution --build-tests
expected=$(/usr/bin/swift test list --skip-build 2>/dev/null | /usr/bin/grep -Ec '^(CockpitProtocolTests\.hostDataPlaneProtocol|CockpitWorkspaceTests\.workspaceKernelDataPlane)')
test "$expected" -gt 0
set +e
/usr/bin/swift test --disable-automatic-resolution --filter 'hostDataPlaneProtocol|workspaceKernelDataPlane' --xunit-output .build/task10a-red.xml
red_status=$?
set -e
test "$red_status" -ne 0 || { echo 'Task 10A RED unexpectedly passed' >&2; exit 1; }
actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' .build/task10a-red-swift-testing.xml)
test "$actual" -eq "$expected"
```

Expected: test exit 非零且 count 非零/相等；测试因 compile scaffold 的 deterministic fail-closed behavior 不满足而失败。任何全绿 RED、缺失 xUnit 或 count mismatch 都使 Step 2 失败。

- [ ] **10A Step 3: 实现 ABI、mappers 与 Workspace port**

严格实现本节；不得使用 LocalTransport JSON 例外。Host port 的 fake 只用于 mapper/validation 单测，Workspace tests 必须直接使用实际 `WorkspaceKernelRegistry`、`DocumentRegistry`、`DocumentActor` 与 `FileTreeProvider`。

- [ ] **10A Step 4: GREEN、计数并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'hostDataPlaneProtocol|workspaceKernelDataPlane' --xunit-output .build/task10a-green.xml
green_status=$?
test "$green_status" -eq 0
expected=$(/usr/bin/swift test list --skip-build 2>/dev/null | /usr/bin/grep -Ec '^(CockpitProtocolTests\.hostDataPlaneProtocol|CockpitWorkspaceTests\.workspaceKernelDataPlane)')
actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' .build/task10a-green-swift-testing.xml)
test "$expected" -gt 0 && test "$actual" -eq "$expected"
/usr/bin/git diff --check
git add Sources/CockpitTypes/ProtocolVersion.swift Sources/CockpitProtocol Sources/CockpitClientCore/FileTreeDataTransport.swift Sources/CockpitHostCore/HostDataPlaneServing.swift Sources/CockpitWorkspace/DocumentActor.swift Sources/CockpitWorkspace/DocumentRegistry.swift Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift Sources/CockpitWorkspace/WorkspaceHostDataPlaneService.swift Tests/CockpitProtocolTests/HostDataPlaneProtocolTests.swift Tests/CockpitWorkspaceTests/DocumentActorTests.swift Tests/CockpitWorkspaceTests/WorkspaceKernelDataPlaneTests.swift
git commit -m "feat: define host data plane protocol"
```

#### Task 10B: 实现 Host XPC ticket 与 UDS 数据面

**Files:**

- Modify: `Package.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Create: `Sources/CockpitLocalTransport/UnixDomainSocket.swift`
- Create: `Sources/CockpitLocalTransport/HostDataPlaneServer.swift`
- Create: `Sources/CockpitLocalTransport/HostDataPlaneClient.swift`
- Create: `Sources/CockpitLocalTransport/HostDataPlaneTicket.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Create: `Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift`
- Create: `Tests/CockpitLocalTransportTests/HostDataPlaneModuleBoundaryTests.swift`

**Package scope:** 10B 才给 `CockpitLocalTransport` linker settings 增加 Apple SDK system frameworks `Security`、`CryptoKit`，并给 `CockpitLocalTransportTests` 增加直接 `CockpitClientCore` test dependency；Swift package dependencies/versions 不变，不新增第三方库。

**XPC issuance:** `HostXPCProtocol` 新增 `issueHostDataPlaneTicket(_ request: Data, withReply reply: @escaping (Data?, NSError?) -> Void)`；request/response 分别只编码 `CPHostDataPlaneTicketRequest`/`CPHostDataPlaneTicketResponse`。export 先按现有 XPC exact-key/version 机制验证 `CPRequestContext`，再等待 UDS server 完成 bind/listen、权限和 inode 检查并进入 `.ready`，最后签发；server 未 ready 时返回 typed XPC error，不返回票据。response `valid_for_milliseconds` 必须精确为 `30_000`。

**Exact seams and construction:** 以下是 10B 唯一允许的 clock/random/peer/filesystem 注入面；production init 固定使用列出的 Darwin/Security/ContinuousClock 实现，tests 只注入这些 seams，不增加 privileged runner 或第二套 transport：

```swift
public protocol HostDataPlaneClock: Sendable {
    func now() -> ContinuousClock.Instant
}
public struct ContinuousHostDataPlaneClock: HostDataPlaneClock {
    public init()
    public func now() -> ContinuousClock.Instant
}
public protocol HostDataPlaneRandomBytes: Sendable {
    func bytes(count: Int) throws -> [UInt8]
}
public struct SecurityHostDataPlaneRandomBytes: HostDataPlaneRandomBytes {
    public init()
    public func bytes(count: Int) throws -> [UInt8]
}
public protocol PeerCredentialReading: Sendable {
    func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t)
}
public struct DarwinPeerCredentialReader: PeerCredentialReading {
    public init()
    public func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t)
}
public struct UnixSocketPathStatus: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case directory, socket, symbolicLink, other }
    public let kind: Kind
    public let owner: uid_t
    public let permissions: mode_t
    public let device: dev_t
    public let inode: ino_t
}
public struct UnixDomainSocketAddress: @unchecked Sendable {
    public let value: sockaddr_un
    public let length: socklen_t
    public init(path: String) throws
}
public protocol UnixDomainSocketSystemCalls: Sendable {
    func effectiveUserID() -> uid_t
    func createStreamSocket() throws -> Int32
    func setCloseOnExec(_ descriptor: Int32) throws
    func setNoSigPipe(_ descriptor: Int32) throws
    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws
    func listen(_ descriptor: Int32, backlog: Int32) throws
    func accept(_ descriptor: Int32) throws -> Int32
    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws
    func pathStatus(_ path: String) throws -> UnixSocketPathStatus?
    func makeDirectory(_ path: String, permissions: mode_t) throws
    func setPermissions(_ path: String, permissions: mode_t) throws
    func unlink(_ path: String) throws
    func close(_ descriptor: Int32)
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws -> Int
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer) throws -> Int
}
public struct DarwinUnixDomainSocketSystemCalls: UnixDomainSocketSystemCalls { public init() }

public struct HostDataPlaneIssuedTicket: Hashable, Sendable {
    public let wireValue: String
    public let validForMilliseconds: UInt32
}
public actor HostDataPlaneTicketStore {
    public init(clock: any HostDataPlaneClock, randomBytes: any HostDataPlaneRandomBytes)
    public init() // ContinuousHostDataPlaneClock + SecurityHostDataPlaneRandomBytes
    public func issue(binding: HostDataPlaneBinding, expectedPeerUID: uid_t) throws -> HostDataPlaneIssuedTicket
    public func consume(wireValue: String, binding: HostDataPlaneBinding, peerUID: uid_t) throws -> HostDataPlaneBinding
}
public actor HostDataPlaneTicketIssuer {
    public init(server: HostDataPlaneServer, store: HostDataPlaneTicketStore, effectiveUserID: uid_t)
    public func issue(
        for validatedContext: RequestContext,
        deliver: @escaping @Sendable (CPHostDataPlaneTicketResponse) throws -> Void
    ) async throws
    public func stopIssuingTickets() async
}
public final class HostDataPlaneServer: @unchecked Sendable {
    public init(namespace: String, service: any HostDataPlaneServing, ticketStore: HostDataPlaneTicketStore,
                systemCalls: any UnixDomainSocketSystemCalls, peerCredentials: any PeerCredentialReading)
    public convenience init(namespace: String = "default", service: any HostDataPlaneServing,
                            ticketStore: HostDataPlaneTicketStore)
    public func start() async throws
    public func waitUntilReady() async throws
    public func shutdown() async
}
public actor HostDataPlaneClient {
    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient,
                systemCalls: any UnixDomainSocketSystemCalls)
    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient) // Darwin production
    public func connect() async throws
    public func disconnect() async
    public nonisolated func documentDiagnostics() -> AsyncStream<DocumentDataPlaneDiagnostic>
}
public enum DocumentDataPlaneDiagnostic: Hashable, Sendable {
    case committedRecoveryRequired(EditAcknowledgement)
    case fingerprintMismatch
}
```

**Ticket store:** raw ticket 是 `SecRandomCopyBytes(kSecRandomDefault, 32, ...)` 生成的 256-bit CSPRNG bytes，wire 是无 padding base64url，精确 43 ASCII chars 且 regex `^[A-Za-z0-9_-]{43}$`；decoder 必须 re-encode 后 exact equal。actor 只存 `CryptoKit.SHA256.hash(raw)`、完整 binding、expected peer UID、`ContinuousClock.Instant issuedAt`、`expiry = issuedAt + .seconds(30)` 与 consumed tombstone，绝不存 raw/wire ticket。验证/消费在一个 actor method 原子执行，顺序为 canonical decode/hash/lookup；`now >= expiry` 删除并报 expired；`getpeereid` UID 与完整 binding/context/environment/generation 逐项 exact compare；失败绑定不消费；成功后置 consumed；已 consumed 在 expiry 前报 replay；expired tombstone 删除。每次连接只能 auth 一张票据，票据只能成功一次。

**Socket path and lifecycle:** namespace 必须匹配 `^[a-z0-9][a-z0-9._-]{0,31}$`，production 为 `default`；path 固定 `/private/tmp/cockpit.{geteuid()}/host/{namespace}/host.sock`。`UnixDomainSocketAddress` 先将 value zero-initialize并设 `sun_family = sa_family_t(AF_UNIX)`，以 `MemoryLayout.size(ofValue: address.sun_path)` 取得 tuple capacity（当前 Darwin `104`），要求 UTF-8 path bytes + NUL `<= capacity`，逐 byte 写入 tuple且禁止截断；`sun_len = UInt8(MemoryLayout.offset(of: \sockaddr_un.sun_path)! + pathBytes.count + 1)`，bind/connect `socklen_t` 精确等于该 `sun_len`。不得用整个 sockaddr size 或减 `sa_family_t` 推算 capacity。

`/private/tmp/cockpit.{uid}`、`host`、namespace 各层用 `lstat/open(O_DIRECTORY|O_NOFOLLOW)/fstat` 验证真实 directory、owner=`geteuid()`、permissions exact `0700`；缺失层以 `0700` 创建。Darwin create 固定为 `socket(AF_UNIX, SOCK_STREAM, 0)`，成功后立即 `fcntl(fd, F_SETFD, FD_CLOEXEC)` 与 `fcntl(fd, F_SETNOSIGPIPE, 1)`；client socket和每个 accepted FD 同样在任何 read/write 前设置两项，任一失败立即 close。bind 后 pathname `chmod 0600`，owner/type/mode/dev/inode 只用 guarded `lstat(path)` 验证并记录；listener FD 不代表 filesystem inode，`fstat(listener)` 禁止用于 pathname identity/permissions，只允许 `getsockopt(SO_TYPE)` 等 descriptor/socket-state 检查。

启动发现现有 path 时：`lstat` 若 symlink、非 socket、wrong owner 立即 fail closed；若为本 UID socket，先 connect。connect 成功报 `serverAlreadyRunning`，不得 unlink；只有 `ECONNREFUSED` 或在复核中已 `ENOENT` 才是 stale candidate。unlink 前第二次 `lstat` 必须与第一次 `st_dev/st_ino` 完全相等且仍为本 UID socket，否则 fail closed/retry startup from beginning。shutdown 顺序固定为停止 ticket issuance、停止 accept、关闭 active clients、取消 subscriptions、close listener；仅当 shutdown `lstat` 仍与 bind 后记录的 pathname `st_dev/st_ino` 相等且 owner/type 正确时 unlink。startup 任一步失败执行同一有 pathname inode guard 的清理。

Host main 新增真实 SIGTERM shutdown path：启动前 `signal(SIGTERM, SIG_IGN)`，在 main run loop 上保留 `DispatchSourceSignal`；handler 只启动一次 async sequence `await ticketIssuer.stopIssuingTickets()` → `await server.shutdown()` → `listener.invalidate()` → `CFRunLoopStop(mainRunLoop)`，然后 main 返回退出。`HostDataPlaneTicketIssuer` actor 内用单一 issuance/shutdown gate 串行 `issue` 与 stop：`issue` 在 gate 内先检查 accepting，再等待 server ready、签发，并在 gate permit 释放前同步调用唯一 `deliver` closure；HostXPCExport 的该 closure 完成 protobuf serialization 和 XPC reply invocation。`stopIssuingTickets()` 原子改为 stopped、拒绝之后进入的 issue，并等待已经 admitted 的 issue 完成或抛错且释放 permit 后才返回。它返回后不得再调用 ticket `deliver`/XPC reply，且 server shutdown 只能在其返回后开始。Host main 保持 signal source/server/issuer 强引用；明确不依赖当前代码中不存在的 shutdown callback。所有 write 在 `F_SETNOSIGPIPE` 后执行，peer close 只转换 `EPIPE` 为 `HostDataPlaneClientError.disconnected` 并关闭连接，禁止触发进程 SIGPIPE 退出。

**Peer credentials:** accept 后、读取任意 payload 前调用 Darwin `getpeereid(fd,&uid,&gid)`，要求 uid 等于 `geteuid()`；失败或错 UID 关闭。生产使用真实 syscall；测试通过 injectable `PeerCredentialReading` system-call seam 覆盖 wrong UID，无需 root/特权 runner，同时 fork/spawn 一个真实同 UID client process 覆盖真实 UDS/getpeereid/handshake/channel 3/4。

**Client and errors:** `HostDataPlaneClient` 以 immutable authenticated binding 实现 Task 9 `DocumentDataTransport` 与 10A `FileTreeDataTransport`，每个 request 重复 binding。`changes(after:expandedDirectories:)` 固定持有调用时 validated/sorted/deduplicated directory snapshot；revision unavailable 时只刷新这组 directories。请求取消发送对应 file-tree cancel；document unary cancellation 丢弃晚到响应但不复用 request ID，Task 9 controller 继续按 ambiguous mutation 规则 resynchronize。断线将 pending unary 完成 typed transport-disconnected、终止 streams；reconnect 必须新 XPC ticket、重新 handshake/auth，禁止重放 mutation。server 将 Host/domain errors按 10A numeric enum exact map；`INTERNAL` 不带 filesystem path/message。frame/protobuf/context errors按 10A close 规则处理。

Swift typed errors 固定为：`HostDataPlaneTicketError.randomGenerationFailed/invalidCanonicalTicket/expired/replay/bindingMismatch`；`UnixDomainSocketError.invalidNamespace/pathTooLong/unsafeDirectory/unsafeSocket/serverAlreadyRunning/staleSocketRace/permissionMismatch/systemCall(function: String, errno: Int32)`；`HostDataPlaneClientError.disconnected/requestCancelled/remote(DataPlaneRemoteError)`。`DataPlaneRemoteError` 只用于非 document codes，含 code、optional expected/actual；document response 必须在 `HostDataPlaneClient` mapper 中还原 Task 9 error，禁止包进 `.remote`。`documentDiagnostics()` 是保留 committed acknowledgement/fingerprint mismatch 的唯一 side channel，buffering policy `.bufferingOldest(32)`，overflow 只丢 diagnostic、不改变 controller error。XPC issuance 使用 error domain `dev.cockpit.host-data-plane-ticket` 与 code `1 serverNotReady / 2 invalidContext / 3 ticketGenerationFailed`；不得返回 raw Swift error text/path。

Document error mapping 固定如下：`DOCUMENT_NOT_OPEN`/`DOCUMENT_INVALID_VALUE` → `.invalidValue`；`DOCUMENT_INVALID_LEASE` → `.invalidLease`；`DOCUMENT_LEASE_HELD` → `.leaseHeld`；`DOCUMENT_BASE_VERSION_MISMATCH(expected,actual)` → `.baseVersionMismatch`；`DOCUMENT_SEQUENCE_GAP(expected,actual)` → `.sequenceGap`；`DOCUMENT_DUPLICATE_MISMATCH` → `.duplicateMismatch`；`DOCUMENT_STALE_SEQUENCE` → `.staleSequence`；`DOCUMENT_RECOVERY_REQUIRED` → `.recoveryRequired`；`DOCUMENT_RESYNCHRONIZING` → `.resynchronizing`；`DOCUMENT_READ_ONLY` → `.readOnly`；`DOCUMENT_FILE_MISSING` → `.fileMissing`；`DOCUMENT_FINGERPRINT_MISMATCH` (`32`) → `.recoveryRequired`。server 只把 exact `DocumentStorageError.fingerprintMismatch` 映射到 code 32，不回传 expected/actual fingerprint/path；client yield `.fingerprintMismatch` diagnostic 后抛 `.recoveryRequired`，Task 9 save 立即进入 resynchronizing，Monaco 返回 `stale-document-state` 并等待 snapshot replacement。server 只 catch shared `HostDataPlaneDocumentError.committedRecoveryRequired(ack)` 并映射为 code 28 + exact committed acknowledgement；LocalTransport source 与 target dependencies 均禁止引用 `CockpitWorkspace` 或 concrete `DocumentCommitRecoveryRequiredError`。client yield `.committedRecoveryRequired(ack)` 后仍抛 `.recoveryRequired`，禁止把它作为成功 ack。authoritative apply code（invalid lease/lease held/base mismatch/sequence gap/duplicate/stale/recovery）各自只允许一次 transport apply，controller 必须立即 `.resynchronizing`；禁止 transient retry。

- [ ] **10B Step 1: 写 RED process/actor tests**

所有测试函数使用 `hostDataPlane` lowerCamel prefix。覆盖 raw 长度/canonical base64url/只存 hash/可推进 fake clock 的 `now == expiry`、failed binding 不消费、success/replay、RequestContext-derived binding、server-ready-before-XPC、namespace/sun_path tuple capacity/sun_len/addrlen、post-socket/post-accept CLOEXEC、F_SETNOSIGPIPE、0700/0600、pathname-lstat 与 listener-fstat identity 不混用、symlink/wrong owner/non-socket/live/stale/dev-inode race、shutdown inode guard、getpeereid/geteuid seam、真实同 UID 子进程、32-byte header fixture、Channel 0 control error 不被 response 接受、Channel 3/4 seq/ack/request correlation、所有 document operations、wire-visible binding mismatch 零 Host port call、Actor owner mismatch 一次 authorized Actor call且零 storage/mutation、file-tree backpressure/cancel/reconnect/revision、malformed/typed errors。每个 document numeric code 都断言 exact Swift error；shared committed-recovery error 断言 code 28 + acknowledgement 且 LocalTransport 不识别 Workspace concrete type；authoritative apply codes 断言只发一次并立即 resynchronizing；fingerprint mismatch 断言 code 32 → `.recoveryRequired`。`HostDataPlaneModuleBoundaryTests.swift` 以 `hostDataPlaneModuleBoundary` prefix 读取 `Package.swift` target dependency graph 并扫描 `Sources/CockpitLocalTransport/**/*.swift`，断言 CockpitLocalTransport target 不依赖 CockpitWorkspace 且没有 `import CockpitWorkspace`/`DocumentCommitRecoveryRequiredError`；同时通过 `swift build --target CockpitLocalTransport` compile proof。wrong UID/wrong owner/dev-inode race 只使用已声明 seams；不得声明特权测试未运行。issuance/shutdown test 注入暂停点，断言已 admitted issue 的 deliver/XPC reply invocation → `stopIssuingTickets` return → server shutdown → listener invalidation 的 strict order，stop 后新 issue 零 deliver/零 ticket reply。进程测试还要真实向 Host 发送 SIGTERM，断言停止 ticket、socket guarded unlink、listener invalidated、进程退出；peer-close write 断言只得到 EPIPE/disconnected且 server/client process 未被 SIGPIPE 终止。测试先写；为得到可执行 RED，只添加本节 exact public declarations，ticket store 固定返回 `.invalidCanonicalTicket`、server/client 固定返回 `.disconnected`，不得 bind/listen/connect 或添加成功分支。

- [ ] **10B Step 2: 证明 RED filter 非零并运行**

```bash
/usr/bin/swift build --disable-automatic-resolution --build-tests
/usr/bin/swift build --disable-automatic-resolution --target CockpitLocalTransport
expected=$(/usr/bin/swift test list --skip-build 2>/dev/null | /usr/bin/grep -Ec '^CockpitLocalTransportTests\.hostDataPlane')
test "$expected" -gt 0
set +e
/usr/bin/swift test --disable-automatic-resolution --filter '^CockpitLocalTransportTests\.hostDataPlane' --xunit-output .build/task10b-red.xml
red_status=$?
set -e
test "$red_status" -ne 0 || { echo 'Task 10B RED unexpectedly passed' >&2; exit 1; }
actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' .build/task10b-red-swift-testing.xml)
test "$actual" -eq "$expected"
```

Expected: test exit 非零且 count 非零/相等；测试因 compile scaffold 的 deterministic fail-closed behavior 不满足而失败。任何全绿 RED、缺失 xUnit 或 count mismatch 都使 Step 2 失败。

- [ ] **10B Step 3: 实现 ticket、UDS server/client 与 Host composition**

严格按 10A ABI 和本节生命周期实现；禁止 JSON data plane、privileged helper、launchd socket activation或新 daemon。Host 仍由现有 launchd Mach service 启动，UDS 只由该 Host process 持有。

- [ ] **10B Step 4: GREEN、计数并提交**

```bash
/usr/bin/swift test --disable-automatic-resolution --filter '^CockpitLocalTransportTests\.hostDataPlane' --xunit-output .build/task10b-green.xml
green_status=$?
test "$green_status" -eq 0
expected=$(/usr/bin/swift test list --skip-build 2>/dev/null | /usr/bin/grep -Ec '^CockpitLocalTransportTests\.hostDataPlane')
actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' .build/task10b-green-swift-testing.xml)
test "$expected" -gt 0 && test "$actual" -eq "$expected"
/usr/bin/git diff --check
git add Package.swift Sources/CockpitLocalTransport Applications/CockpitHost/main.swift Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift Tests/CockpitLocalTransportTests/HostDataPlaneModuleBoundaryTests.swift
git commit -m "feat: serve host data plane over uds"
```

#### Task 10C: 实现 bundle-only Monaco bridge

**Files:**

- Modify: `EditorRuntime/src/protocol.mjs`
- Modify: `EditorRuntime/src/bootstrap.ts`
- Modify: `EditorRuntime/build.mjs`
- Modify: `EditorRuntime/package.json`
- Modify: `EditorRuntime/toolchain-contract.mjs`
- Modify: `EditorRuntime/test/build.test.mjs`
- Create: `EditorRuntime/test/protocol.test.mjs`
- Modify: `Sources/CockpitClientCore/WorkspaceClientState.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoMessage.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoWindowSessionResolver.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoBridge.swift`
- Create: `Applications/CockpitApp/Monaco/MonacoEditorViewController.swift`
- Create: `Tests/CockpitAppTests/MonacoBridgeTests.swift`
- Modify: `Tests/CockpitClientCoreTests/WorkspaceClientStateTests.swift`
- Modify: `Tests/ProcessIntegrationTests/app-bundle-layout.zsh`
- Modify: `project.yml`

**Exact JS wire schema:** object keys must be exactly the declared keys; no additional/missing keys, numeric strings, `undefined`, NaN or infinity. All UUID strings are canonical lowercase. All integer fields are `Number.isSafeInteger`; generation/client sequence/document version are within `1...9_007_199_254_740_991` except `documentVersion` and `lastAcceptedClientSequence` permit `0`; line/column/firstVisibleLine are `1...9_007_199_254_740_991`; horizontal scroll is finite and `>=0`.

```typescript
type WorkspaceContextWire =
  | { kind: "project"; projectID: string }
  | { kind: "conversation"; conversationID: string };
type TextPosition = { line: number; column: number };
type TextRange = { anchor: TextPosition; active: TextPosition };
type ViewState = { cursor: TextPosition; selections: TextRange[]; firstVisibleLine: number; horizontalScrollOffset: number };
type TextChange = { offset: number; length: number; replacement: string };

type NativeToMonaco =
  | { type: "open"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; language: string; text: string; documentVersion: number; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean; viewState: ViewState | null }
  | { type: "ack"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; clientSequence: number; documentVersion: number; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean }
  | { type: "replace"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; text: string; documentVersion: number; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean; viewState: ViewState | null }
  | { type: "setWritable"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean }
  | { type: "renameModel"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; oldURI: string; newURI: string; language: string; text: string; documentVersion: number; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean; viewState: ViewState | null }
  | { type: "disposeModel"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean }
  | { type: "selectModel"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean; viewState: ViewState | null };

type MonacoToNative =
  | { type: "ready"; webContentGeneration: number }
  | { type: "edit"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; editLeaseID: string | null; writable: boolean; baseVersion: number; lastAcceptedClientSequence: number; changes: TextChange[] }
  | { type: "save"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean }
  | { type: "viewState"; webContentGeneration: number; workspaceContextID: WorkspaceContextWire; tabID: string; documentID: string; uri: string; lastAcceptedClientSequence: number; editLeaseID: string | null; writable: boolean; value: ViewState };

type NativeReply =
  | { ok: true; message: NativeToMonaco | null }
  | { ok: false; error: { code: "invalid-schema" | "stale-generation" | "stale-document-state" | "unknown-document" | "read-only" | "resynchronizing" | "file-missing" | "transport-failure" } };
```

`ready` 是唯一 window-scoped message，因此只含 generation；其它每条 document-scoped message 均含 generation/context/canonical lowercase TabID/document/URI/lastAcceptedClientSequence/nullable lease/writable。Swift error 固定为 `MonacoBridgeError.invalidSchema/staleGeneration/staleDocumentState/unknownDocument/readOnly/resynchronizing/fileMissing/transportFailure`，逐一映射上述 kebab-case reply code，不返回任意 error string。

`TextChange` 使用 UTF-16 offset/length；offset/length 为 safe nonnegative integers、`offset + length` safe、replacement 不含 CR/NUL；array 非空、offset 严格递增且 ranges 不重叠。JS edit 不含/不生成 authoritative `clientSequence`，只把 change 交给对应 `DocumentClientController.submit`；edit 在 mapper 层额外要求 `writable == true` 且 lease nonnull，controller 生成 sequence，native ack 再把 accepted sequence/version 返回。每个 Monaco→native document message 的 Context/TabID/DocumentID 必须命中 exact resolver ref，last sequence/lease/writable 必须匹配 controller-owned access tuple：`await controller.state == .ready(snapshot)` 时要求 `snapshot.currentLease.clientInstanceID == resolver.clientInstanceID` 并输出该 lease/true；`.readOnly(snapshot)` 无论 snapshot 是否含远端 owner lease都固定输出 nil/false，禁止把他人 lease 暴露为本 controller writable；其它 state 返回对应 typed error。mismatch 不调用 controller。save 从 state snapshot 读取 nonnull `observedDiskFingerprint` 并只调用 `controller.save(expectedFingerprint:)`（controller 内部已 flush）；成功 reply 是含返回 snapshot 的 `replace`，nil fingerprint 返回 `file-missing`；code 32/recovery-required 返回 `stale-document-state` 并等待 resync。不得由 JS 传 through sequence。`writable === (editLeaseID !== null)`，false 必须 null，true 必须 canonical lease ID。replace/open/rename 的 programmatic model write 在 suppression scope 中，scope 在 synchronous `model.setValue` 完成后释放且不得产生 edit 回传。

**URI:** exact form `cockpit-file://{canonical-lowercase-environment-uuid}/{encoded-relative-path}`。`RelativePath` 以 `/` 分 component；每个 component 转 UTF-8 bytes，只保留 RFC 3986 unreserved `ALPHA / DIGIT / - / . / _ / ~`，其余每 byte 用 uppercase `%HH`，包括 literal `%`；`/` 只作为 separator，不编码。Monaco `Uri.parse(uri).toString()` 必须 exact equal，否则拒绝。禁止 Unicode normalization、`URLComponents` 自动重编码或 lowercase percent hex。

**Public batch relocation entry:** `MonacoBridge` 可以 import `CockpitHostCore` 的 value-only `FileOperation`/`FileOperationResult`，但不得持有/call Workspace service。token 按 initiating Context + exact FileOperation source batch 建立，不以 active Tab/Document 建立；生产调用面固定为：

```swift
public struct MonacoRelocationToken: Hashable, Sendable {
    public let id: RequestID
    public let workspaceContextID: WorkspaceContextID
    public let operation: FileOperation
    public let sourcePath: RelativePath
    public let affectedDocumentIDs: [DocumentID]
    // Opaque: only MonacoBridge constructs tokens; there is no public initializer.
}
public enum MonacoRelocationDisposition: Hashable, Sendable {
    case complete
    case incomplete(pendingDocumentIDs: [DocumentID])
    case abandonedAllStale
}
@MainActor public func prepareRelocation(
    workspaceContextID: WorkspaceContextID,
    operation: FileOperation
) async throws -> MonacoRelocationToken
@MainActor public func commitRelocation(
    _ token: MonacoRelocationToken,
    result: FileOperationResult
) async throws -> MonacoRelocationDisposition
@MainActor public func retryRelocation(
    _ token: MonacoRelocationToken
) async throws -> MonacoRelocationDisposition
@MainActor public func abandonCommittedRelocation(
    _ token: MonacoRelocationToken
) throws -> MonacoRelocationDisposition
@MainActor public func cancelRelocation(_ token: MonacoRelocationToken) throws
```

prepare 只接受 `.rename(source:newName:)`/`.move(source:destinationDirectory:)`；其它 operation 抛 `.invalidSchema` 且不创建 token。bridge 在 window resolver 中选出 relative path 等于 source 或以 `source + "/"` 为 component prefix 的全部 open sessions，因此 file 是 0...1 session、directory 是 0...n descendant sessions；source 未打开时允许 `affectedDocumentIDs=[]`。每个 affected DocumentID 只出现一次并 canonical UUID 升序，batch 包含这些 session 在所有 Context 的全部 refs，而不仅 initiating Context。live token 的 `(workspaceContextID, operation)` 不得重复，且 affected DocumentID 不得与另一个 live token 重叠。

prepare 按 DocumentID 顺序先读取每个 controller 的 exact `DocumentClientControllerState` 与 access tuple：`.ready(snapshot)` 仅当 `snapshot.currentLease` nonnull 且其 `clientInstanceID == resolver.clientInstanceID` 时调用该 controller `flush()` exactly once，并记录 `priorWritable=true`；`.readOnly` 调用 `flush()` exactly zero times并记录 `priorWritable=false`。`.ready` 缺 lease或 lease owner 不匹配抛已冻结 `MonacoBridgeError.staleDocumentState`；`.closed` 抛 `.unknownDocument`；`.resynchronizing` 抛 `.resynchronizing`；这三种不可用状态均零 flush、零 token。ready/readOnly 两种可用状态都保存该 document 的全部 refs async view state。任一 state/access validation、ready flush 或任一 ref save-view-state 失败，整个 prepare 不保存 token并原样抛出该 typed error；它不调用 Host file operation。commit 使用 token 中逐 document 冻结的 `priorWritable`，分别调用 `resynchronize(requestWriteAccess: true/false)`，不得把 batch 统一升级为 writable。

caller 执行 Host rename/move；首次 commit 只接受 exact `.relocated(from:to:)` 且 `from == token.sourcePath`，其它 result/mismatch 抛 `.invalidSchema` 并保留 pre-commit token 供 cancel。每个 source session destination path 固定为：path exact equal source 时取 `to`；descendant 时把 source 之后的完整 component suffix 接到 `to`。commit 对每个 pending DocumentID 按顺序调用 controller `resynchronize(requestWriteAccess: priorWritable)`，要求返回 snapshot 的 DocumentID/EnvironmentID 不变且 relativePath exact equal mapped destination，然后执行该 document 全部 refs/model migration。空 batch 直接 consume token并返回 `.complete`。

Host commit 后的 token 记录 exact `.relocated(from:to:)` 与每个 DocumentID 的 `.pending`/`.migrated` progress。单个 document resync/migration 失败不回滚已成功 document：失败及尚未处理 session 立即进入 bridge `.resynchronizing`，edit/save 返回 typed `resynchronizing`；token 保留并返回 `.incomplete(pendingDocumentIDs:)`，pending list canonical UUID 升序。`retryRelocation` 只允许 committed-incomplete token，只重试 pending documents，成功的 migrated documents 不重复；全部成功时 consume token并返回 `.complete`。`cancelRelocation` 只允许 Host commit 前，释放 token且不改 model/controller；committed token 调 cancel 抛 `.staleDocumentState`。caller 放弃 retry 时必须调用 `abandonCommittedRelocation`：它 dispose 所有 affected old/destination models、保留 resolver refs/controllers但把全部 affected sessions 置为 `.resynchronizing`、consume token并返回 `.abandonedAllStale`；之后只允许既有 controller resynchronize/reopen path 重建 authoritative models，禁止继续使用任一部分迁移 model。

每个 document migration 使用 authoritative destination snapshot 和 prepare 保存的每个旧 ref view state，发 `renameModel`：新 URI 建新 Monaco model、载入 destination snapshot、分别转移 `(WorkspaceContextID,TabID,DocumentID)` view state、把该 document 的所有 refs 原子切到新 model、若当前选中则切换；旧 model 只有 refcount 变为 0 才 dispose。Monaco model URI immutable，因此该操作明确重置 undo/redo stack；禁止复用旧 model 或伪造可变 URI。

**Window session ownership:** `MonacoWindowSessionResolver` 是 `@MainActor`，init 固定接收本 window 的 `ClientInstanceID`；为每个 `DocumentID` 保留且只保留一个 `DocumentClientController`，每个 tab 增加 `(WorkspaceContextID,TabID,DocumentID)` ref，同 Context/同 Document 的不同 Tab 不合并。其 public surface 固定为 `retain(contextID:tabID:documentID:controller:language:)`, `session(documentID:)`, `select(contextID:tabID:documentID:)`, `release(contextID:tabID:documentID:)`, `allSessionsSortedByDocumentID()`；同 DocumentID 传入不同 controller 必须拒绝，重复 ref key 必须幂等。view state 仅通过 init 注入的

```swift
@Sendable (WorkspaceContextID, TabID, DocumentID) async -> DocumentViewState?
@Sendable (WorkspaceContextID, TabID, DocumentID, DocumentViewState) async throws -> Void
```

load callback 只用 `await WorkspaceClientState.state(for:)` 查找 exact TabID 并验证 resource 是同一 DocumentID。store callback 的 production adapter 只能执行一次 actor-isolated 调用：

```swift
public enum WorkspaceClientStateError: Error, Hashable, Sendable {
    case stateNotFound
    case tabNotFound
    case tabDocumentMismatch
}

public func updateFileViewState(
    key: ClientWorkspaceStateKey,
    tabID: TabID,
    documentID: DocumentID,
    viewState: DocumentViewState
) throws
```

`WorkspaceClientState.updateFileViewState` 在 actor isolation 内验证 key/view state、要求 state 存在、要求 exact TabID 存在且其 resource 恰为 `.file(documentID)`，然后只替换该 `TabRecord.fileViewState`、重建并 validate `ClientWorkspaceState`、写回 dictionary；三个 lookup failure 分别抛上述 exact error。禁止 production callback 执行 `state(for:)` → 本地修改 → `store` 的跨 actor 两调用 RMW；adapter 从其 init 捕获的 DeviceID/WindowID 与 callback ContextID 构造 `ClientWorkspaceStateKey`，callback body 只有 `try await workspaceClientState.updateFileViewState(key: key, tabID: tabID, documentID: documentID, viewState: viewState)`。同 Context/同 Document/两个 Tab 的并发 callback 必须各自保留更新，不得 last-writer 覆盖另一个 Tab。resolver/bridge 不 import `CockpitWorkspace`，不持有 `Workspace`、`WorkspaceKernel` 或 `DocumentActor`。除 value-only `FileOperation`/`FileOperationResult` relocation input 外，`MonacoBridge` 只通过 resolver 找到 `DocumentClientController`。

**One WebView and crash generation:** `MonacoEditorViewController` 的 designated init 由 injected factory 创建恰好一个 `WKWebView` 并在 Window 生命周期内保持同一对象；页签切换只发带 exact TabID 的 `selectModel`/调用 JS `editor.setModel`。首次 load generation=`1`；`webViewWebContentProcessDidTerminate` 对同一个 WKWebView safe-increment generation，重装 bundle URL，旧 generation 的 native/JS message 全丢弃。新 generation `ready` 后，对 resolver 的所有 open sessions 按 DocumentID 排序逐一调用各 controller `resynchronize(requestWriteAccess:)`，分别发 open 重建全部成功 snapshot model及其每个 Tab ref；每个 session 都必须尝试，失败 model 不恢复旧文本并通过 owner error callback 报错；原 selected `(ContextID,TabID,DocumentID)` 成功重建后最后恢复 selected model 和该 exact ref callback 返回的 view state。不得替换 WKWebView、只重建当前 model或恢复未 acknowledged JS buffer。

**Bundle-only WebKit:** 只用 `loadFileURL(indexHTML, allowingReadAccessTo: MonacoRuntime.bundle)`，index 必须位于签名 App Bundle `Contents/Resources/MonacoRuntime.bundle/index.html`。`build.mjs` 生成的 index `<head>` 第一项固定为 `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'none'; img-src 'self'; font-src 'self'; media-src 'none'; object-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; manifest-src 'none'; base-uri 'none'; form-action 'none'">`；build test 解析 DOM/text 并 exact compare，禁止后续 meta 覆盖。该 CSP 对 fetch/XHR/http/https/ws/wss/data/blob/javascript image/font/media/frame/worker subresource fail closed，实际 WKWebView test 从页面发起 fetch/image/WebSocket 并断言无 request 成功。navigation policy 只允许该 bundle directory 内 `file:` URL；拒绝 `http/https/ws/wss/data/blob/javascript`、外部 file URL、redirect、form submit、target frame nil/new window、`window.open` 和 download。`WKUIDelegate.createWebViewWith` 总返回 nil；无自定义 URL scheme、local HTTP server 或浏览器路由。

script handler name 固定 `cockpitMonaco`、content world 固定 `.page`。`WKUserContentController` 只强持有 `WeakMonacoScriptMessageHandler` forwarder，forwarder 对 `MonacoBridge` 是 `weak`；`MonacoEditorViewController.tearDown()` 幂等调用 `removeScriptMessageHandler(forName: "cockpitMonaco", contentWorld: .page)` 并清空 navigation/UI delegates，window close 必须调用，`deinit` 再执行同一幂等清理。测试持有 weak owner/bridge/forwarder/webView 引用，tearDown 并释放 window owner 后全部为 nil；禁止 content controller → bridge/view controller retain cycle。

`EditorRuntime/package.json` 的 `packageManager` 固定 `pnpm@11.20.0`，`engines.node` 固定 `26.7.0`，`engines.pnpm` 固定 `11.20.0`；不得保留 Node 25/pnpm 9 fallback。`toolchain-contract.mjs.evaluateToolchain` 只接受 node `26.7.0` + user agent `pnpm/11.20.0 ...` exact pair，`profileName` 对该 pair 返回 `current`，其它值均返回拒绝/null；删除 Profile A/B 与 range helper。`build.test.mjs` 的 manifest/accepted fixtures 只保留该 pair，并把 Node `25.9.0` + pnpm `9.15.9` 加入 rejected fixtures。`project.yml` 给 Cockpit app 增加直接 package product `CockpitHostCore`（只为 `FileOperation`/`FileOperationResult` relocation values），要求 XcodeGen 前 `EditorRuntime/build.mjs` 已原子生成 `EditorRuntime/dist/MonacoRuntime.bundle`，以 folder resource 复制，并给 Cockpit app 与 hosted `CockpitAppTests` 显式链接 Apple SDK `WebKit.framework`。唯一 runtime resources 为 `index.html`、`editor.js`、`editor.js.map`、`editor.css`，均 regular file、非 symlink、非空；缺一即失败。`build.mjs` 保持 external source map 但固定 esbuild `sourcesContent: false`；bundle gate 解析 map 并拒绝 `sourcesContent` key。不得把 `package.json`、lockfile、Node runtime、pnpm、node_modules 或 EditorRuntime source 放入 App。

- [ ] **10C Step 1: 写 JS/ClientCore/App RED tests**

JS tests 每个 top-level declaration 必须单行以 `test('monaco` 开头，覆盖 exact-key schema、全部 message variants、bounds/UTF-16/change ordering、JS 不生成 sequence、model refcount/reuse/suppression/rename undo reset/generation。`WorkspaceClientStateTests.swift` 新增 Swift Testing functions 以 `workspaceClientStateViewState` prefix，覆盖 exact errors、单 Tab update，以及同 Context/同 Document 两个 Tab 用 `async let` 并发更新后两个 view state 均保留。`MonacoBridgeTests` 必须是 `final class MonacoBridgeTests: XCTestCase`，method 名以 `test` 开头；覆盖 one WKWebView、CSP network subresource/new-window blocking、weak handler teardown/deinit、URI byte encoding、TabID-aware message/controller routing、同 Context/同 Document/两 Tab view-state 隔离、remote-owner lease read-only `(nil,false)`、fingerprint code 32 stale state、batch relocation 的 unopened empty、directory descendants、cross-context refs、exact relocated result、partial→retry、partial→abandoned-all-stale、cancel phase restriction、undo reset、stale generation、same-WKWebView crash rebuild all/selected ref restore/failure no stale text。directory batch 必须含一个 owned `.ready` document 与一个 `.readOnly` document：prepare 只对 ready controller flush once、readOnly zero flush，两者全部 refs view state 都保存且 Host relocation 继续；commit 分别以 `requestWriteAccess=true`/`false` resynchronize，并迁移两个 documents 的全部 refs。另覆盖 `.ready` 非 owner、`.closed`、`.resynchronizing` 的 exact typed error、零 token与零 Host call。测试先写；为使 Swift/Xcode enumeration 可执行，只添加本节 exact Swift public declarations；`WorkspaceClientState.updateFileViewState` scaffold 固定抛 `.stateNotFound`，message decoder 固定返回 `.invalidSchema`、bridge handler 固定回复 invalid-schema、factory 仍创建一个 injected WKWebView；不得路由 controller、创建 model 或添加成功分支。

- [ ] **10C Step 2: 先 build 再证明 RED 非零并运行**

```bash
fnm exec --using 26.7.0 pnpm --dir EditorRuntime build
test_enum_dir=$(mktemp -d /tmp/cockpit-task10c-enumerate.XXXXXX)
js_expected=$(/usr/bin/grep -Ec "^test\\('monaco" EditorRuntime/test/protocol.test.mjs)
test "$js_expected" -gt 0
set +e
fnm exec --using 26.7.0 pnpm --dir EditorRuntime exec node --test --test-reporter=junit --test-reporter-destination="$test_enum_dir/js-red.xml" test/protocol.test.mjs
js_red_status=$?
set -e
test "$js_red_status" -ne 0 || { echo 'Task 10C JS RED unexpectedly passed' >&2; exit 1; }
js_actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' "$test_enum_dir/js-red.xml")
test "$js_actual" -eq "$js_expected"
/usr/bin/swift build --disable-automatic-resolution --build-tests
client_expected=$(/usr/bin/swift test list --skip-build 2>/dev/null | /usr/bin/grep -Ec '^CockpitClientCoreTests\.workspaceClientStateViewState')
test "$client_expected" -gt 0
set +e
/usr/bin/swift test --disable-automatic-resolution --filter '^CockpitClientCoreTests\.workspaceClientStateViewState' --xunit-output .build/task10c-client-red.xml
client_red_status=$?
set -e
test "$client_red_status" -ne 0 || { echo 'Task 10C ClientCore RED unexpectedly passed' >&2; exit 1; }
client_actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' .build/task10c-client-red-swift-testing.xml)
test "$client_actual" -eq "$client_expected"
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation -only-testing:CockpitAppTests/MonacoBridgeTests -enumerate-tests -test-enumeration-style flat -test-enumeration-format json -test-enumeration-output-path "$test_enum_dir/tests.json" test
expected=$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for v in d["values"] for t in v["enabledTests"] if t["identifier"].startswith("CockpitAppTests/MonacoBridgeTests/")))' "$test_enum_dir/tests.json")
test "$expected" -gt 0
set +e
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation -only-testing:CockpitAppTests/MonacoBridgeTests -resultBundlePath "$test_enum_dir/red.xcresult" test
xcode_red_status=$?
set -e
test "$xcode_red_status" -ne 0 || { echo 'Task 10C Xcode RED unexpectedly passed' >&2; exit 1; }
actual=$(xcrun xcresulttool get test-results summary --path "$test_enum_dir/red.xcresult" --compact | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["totalTestCount"])')
test "$actual" -eq "$expected"
```

Expected: JS、ClientCore 与 Xcode test exit 都非零，各自 expected 非零且 actual 相等；因 compile scaffold 的 deterministic fail-closed behavior 不满足而失败。任何全绿 RED、缺失 JUnit/xUnit/xcresult 或 count mismatch 都使 Step 2 失败。

- [ ] **10C Step 3: 实现 runtime、bridge、bundle wiring**

严格实现本节 exact schema/URI/session/crash/CSP/navigation/teardown contract与 `WorkspaceClientState.updateFileViewState` actor RMW。`WKScriptMessageHandlerWithReply` 只通过 weak forwarder 注册 `cockpitMonaco` + `.page`，所有 reply 都匹配 `NativeReply`，unknown/stale message 不触达 controller。

- [ ] **10C Step 4: GREEN、计数、bundle gate 并提交**

```bash
fnm exec --using 26.7.0 pnpm --dir EditorRuntime build
fnm exec --using 26.7.0 pnpm --dir EditorRuntime test
js_suite_status=$?
test "$js_suite_status" -eq 0
test_enum_dir=$(mktemp -d /tmp/cockpit-task10c-green.XXXXXX)
js_expected=$(/usr/bin/grep -Ec "^test\\('monaco" EditorRuntime/test/protocol.test.mjs)
test "$js_expected" -gt 0
fnm exec --using 26.7.0 pnpm --dir EditorRuntime exec node --test --test-reporter=junit --test-reporter-destination="$test_enum_dir/js-green.xml" test/protocol.test.mjs
js_green_status=$?
test "$js_green_status" -eq 0
js_actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' "$test_enum_dir/js-green.xml")
test "$js_actual" -eq "$js_expected"
/usr/bin/swift test --disable-automatic-resolution --filter '^CockpitClientCoreTests\.workspaceClientStateViewState' --xunit-output .build/task10c-client-green.xml
client_green_status=$?
test "$client_green_status" -eq 0
client_expected=$(/usr/bin/swift test list --skip-build 2>/dev/null | /usr/bin/grep -Ec '^CockpitClientCoreTests\.workspaceClientStateViewState')
client_actual=$(/usr/bin/python3 -c 'import sys,xml.etree.ElementTree as E; print(len(E.parse(sys.argv[1]).findall(".//testcase")))' .build/task10c-client-green-swift-testing.xml)
test "$client_expected" -gt 0 && test "$client_actual" -eq "$client_expected"
xcodegen generate --no-env
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation -only-testing:CockpitAppTests/MonacoBridgeTests -enumerate-tests -test-enumeration-style flat -test-enumeration-format json -test-enumeration-output-path "$test_enum_dir/tests.json" test
expected=$(/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for v in d["values"] for t in v["enabledTests"] if t["identifier"].startswith("CockpitAppTests/MonacoBridgeTests/")))' "$test_enum_dir/tests.json")
test "$expected" -gt 0
/usr/bin/xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug -derivedDataPath DerivedData SYMROOT="$PWD/build" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation -only-testing:CockpitAppTests/MonacoBridgeTests -resultBundlePath "$test_enum_dir/green.xcresult" test
xcode_green_status=$?
test "$xcode_green_status" -eq 0
actual=$(xcrun xcresulttool get test-results summary --path "$test_enum_dir/green.xcresult" --compact | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["totalTestCount"])')
test "$actual" -eq "$expected"
Tests/ProcessIntegrationTests/app-bundle-layout.zsh
/usr/bin/git diff --check
git add EditorRuntime/src/protocol.mjs EditorRuntime/src/bootstrap.ts EditorRuntime/build.mjs EditorRuntime/package.json EditorRuntime/toolchain-contract.mjs EditorRuntime/test/protocol.test.mjs EditorRuntime/test/build.test.mjs Sources/CockpitClientCore/WorkspaceClientState.swift Applications/CockpitApp/Monaco Tests/CockpitClientCoreTests/WorkspaceClientStateTests.swift Tests/CockpitAppTests/MonacoBridgeTests.swift Tests/ProcessIntegrationTests/app-bundle-layout.zsh project.yml Cockpit.xcodeproj Cockpit.xcworkspace
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
- Modify: `Config/Toolchains/ghostty.env`
- Modify: `Tools/bootstrap-zig.zsh`
- Modify: `Tools/verify-ghostty.zsh`
- Modify: `Tests/ToolingTests/ghostty-toolchain.zsh`
- Modify: `Tests/ToolingTests/ghostty-toolchain-hardening.zsh`
- Modify: `ThirdParty/ghostty` gitlink
- Modify: `project.yml`

**Upstream boundary and hard gate:** 用户为 Task 11 批准的 Ghostty 基础版本固定为 1.3.2-dev commit `05221c11c9db0715666fc6e038915128fc6a563e`；该提交的 `build.zig.zon` 声明 `.version = "1.3.2-dev"` 与 `.minimum_zig_version = "0.16.0"`。其中 `src/Surface.zig` 明确写明 Surface 创建并拥有 PTY，公开 C header 没有外部 VT snapshot/delta 注入 API，`src/lib_vt.zig` 导出 Terminal input encoding 与 RenderState。Task 11 执行时必须先在 Phase 1 worktree 重新通过 submodule HEAD/clean 和 `Tools/verify-ghostty.zsh --no-bootstrap`；任一门槛失败立即停止，不生成补丁。通过后实现总体架构已批准的固定版本轻量 fork，不改用 Ghostty 自己持有 App 内 PTY 的 Surface。

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
COCKPIT_GHOSTTY_API void cockpit_ghostty_vt_reset_input_state(
    cockpit_ghostty_vt_t *);
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

`cockpit_ghostty_vt_reset_input_state` 是用户批准的 Task 11 ABI 补充：它只清零 bridge 持有的上一 mouse button bitset 与横纵 wheel Q16.16 remainder，不修改 VT grid、mode、sequence 或 scrollback。Task 14 Keeper 在 input lease grant、transfer、revoke 与 holder disconnect 时调用它，禁止把前一 holder 的按键/按钮/滚轮累积状态带入下一 holder。

header 在 typedef 前完整定义 key/mouse event 的固定宽度 enum/struct。所有返回 bytes 均由 bridge 分配，成功时由调用方且只由调用方调用 `cockpit_ghostty_bytes_free`；失败时必须返回 `{NULL, 0}`。renderer create 在 destroy 前 retain 传入的 NSView；其余指针只在调用期间借用。

`FrameFormat.md` 是 CKGF v1 的规范源：网络字节序；固定 header 为 magic `CKGF`、u16 version、u8 kind（1 snapshot/2 delta/3 scrollback）、u8 flags、u64 base sequence、u64 output sequence、u32 rows、u32 columns、u32 section count；每个 section 是 u8 type + 3 reserved zero bytes + u32 byte length + payload。文档固定 palette/cursor/row/cell/grapheme/style/scrollback section 的字段顺序、宽度、合法 enum 和边界校验，并提供 snapshot、delta、scrollback 三个 golden byte fixture。CKGF 不再增加 CRC；UDS 外层使用现有 Frame 边界，归档使用 manifest SHA-256。单帧硬上限复用 `FrameHeader.maximumPayloadLength` 的 16 MiB。Delta 只包含 Ghostty `RenderState` dirty rows；snapshot 包含完整 viewport；scrollback 使用单独分页 frame。

- [ ] **Step 1: 写失败的 ABI/build smoke test**

测试先运行 `Tools/verify-ghostty.zsh --no-bootstrap`，核对 submodule commit 和 clean state，再把 `git archive` 解包到测试临时目录、按 `series` 应用补丁、使用 `.tools/zig/0.16.0/zig` 构建两份 arm64 macOS 产物。C 与 C++ harness 编译 header，VT/renderer 两端分别对三个 golden fixture 做逐字节验证；运行时执行 feed `red + hello + reset`、key/paste/mouse mode-aware encoding、snapshot、row delta、offscreen Metal apply，隐藏 renderer 后确认不请求新帧。

- [ ] **Step 2: 运行失败测试**

```bash
test "$(git -C ThirdParty/ghostty rev-parse HEAD)" = 05221c11c9db0715666fc6e038915128fc6a563e
test -z "$(git -C ThirdParty/ghostty status --short)"
Tools/verify-ghostty.zsh --no-bootstrap
Tests/ToolingTests/ghostty-bridge.zsh
```

Expected: 失败，原因是补丁、ABI header 和构建脚本不存在。

- [ ] **Step 3: 实现派生构建与轻量补丁**

`Tools/build-ghostty-bridge.zsh` 接受 `--configuration Debug|Release --output "$DERIVED_FILE_DIR/Ghostty"`；output parent 必须与物理、canonical `DERIVED_FILE_DIR` exact equal，替换已有 output 前必须核验 Cockpit ownership marker，只删除 marker-owned leaf。cache key 固定为 Ghostty commit + patch SHA-256 + public header SHA-256 + module map SHA-256 + Zig version + configuration + target triple。脚本只写 output 与临时目录，不写 `ThirdParty/ghostty`。产物固定为：

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
git add Config/Toolchains/ghostty.env Patches/ghostty Native/CockpitGhosttyBridge ThirdParty/ghostty Tools/bootstrap-zig.zsh Tools/build-ghostty-bridge.zsh Tools/verify-ghostty.zsh Tests/ToolingTests/ghostty-bridge.zsh Tests/ToolingTests/ghostty-toolchain.zsh Tests/ToolingTests/ghostty-toolchain-hardening.zsh project.yml Cockpit.xcodeproj Cockpit.xcworkspace docs
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

Supervisor 是输入租约唯一权威端，通过 control protocol 创建/转移/释放 `InputLeaseGrant(leaseID, holderViewerID, sequenceBase, capabilities)` 并注册给 Keeper；Keeper 只校验和执行。Keeper 在 grant、transfer、revoke 与 holder disconnect 的本地线性化点调用 Task 11 `cockpit_ghostty_vt_reset_input_state`，清除前一租约的 mouse button 与 wheel remainder 状态。每个 viewer queue 固定为最多 2 个 screen frame；第三个 frame 到来时合并中间帧并保留最新权威 frame。输入 lease 单调 sequence，重复 sequence 返回原 ACK，不重复写 PTY；断开持有者时 Keeper 立即使本地 grant 失效并向 Supervisor 报告 revocation，Supervisor 不可用时不授予替代 lease。read-only viewer 无权 input/resize/signal/terminate。

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

Task 17 同时固定 Task 10C relocation 的 UI consumer port；`FileTreeViewController` 在用户提交 rename/move 时只调用该 port，不直接调用 bridge/Host：

```swift
@MainActor public protocol FileRelocationCoordinating: AnyObject {
    func performRelocation(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws
}
```

该 protocol 定义在 `FileTreeViewController.swift`；controller init 必须注入 `any FileRelocationCoordinating`。rename/move 来自树节点的 source 和 active WorkspaceContextID，source 不要求存在 active/open file Tab；未打开 file 与含多个 open descendants 的 directory 都必须发一次 batch relocation call。

左栏层级固定为 Project → zero-to-many Conversation；Project 行始终 selectable。中央 tab kinds 固定为 file、shell、codex、claude、new-tab-picker；new-tab-picker 作为 Context-local TabRecord 持久化，选择操作后原位替换为目标 file/terminal resource，取消时删除该 TabRecord。右栏 Phase 1 只显示文件树，不创建 Search/Git/Diff 占位按钮。

- [ ] **Step 1: 写失败测试**

断言 window root 是三栏 NSSplitViewController；Project 没有 Conversation 时仍有 selectable row；选择 Project/Conversation 产生新 generation；各 Context tab list 独立；同 Window 只有一个 Monaco controller；切换到 terminal 隐藏 Monaco 但不销毁 model；右栏 provider 始终来自 ActiveContext.environmentID；file-tree rename/move 把 exact FileOperation + ContextID 交给 injected `FileRelocationCoordinating`；unopened file 和 directory source 均不要求 active TabID/DocumentID。

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
9. `TabCommandController` 实现 Task 17 `FileRelocationCoordinating.performRelocation(_:workspaceContextID:)`：以 exact ContextID + FileOperation 调 `bridge.prepareRelocation`，再调用现有 Host `performFileOperation`；Host 抛错时 `try bridge.cancelRelocation(token)` 后原样抛错。Host 返回值只接受 exact `.relocated(from:to:)` 并传给 `bridge.commitRelocation`；pre-commit non-relocated/mismatch 执行 cancel 后抛 `.invalidSchema`。commit 返回 `.complete` 即结束；`.incomplete` 保留 token并由 controller 暴露 `retryRelocation(token)` 与 `abandonRelocation(token)`，分别调用 bridge retry 和 abandon，直到 `.complete` 或 `.abandonedAllStale` 终态。不得直接调用 JS rename helper。

```swift
@MainActor public func retryRelocation(
    _ token: MonacoRelocationToken
) async throws -> MonacoRelocationDisposition
@MainActor public func abandonRelocation(
    _ token: MonacoRelocationToken
) throws -> MonacoRelocationDisposition
```

- [ ] **Step 1: 写失败测试**

覆盖纯 Project 模式全部功能可用；同 Conversation 同时创建 Codex + Claude + Shell；两个 Conversation 的 tabs/sessions 隔离；全部 Context 共享同一 file/document state；手动 rename 成功/失败；文件 rename/move（含 unopened source 与 directory descendants）严格执行 batch prepare→Host exact relocated→commit，Host error/non-relocated result 执行 cancel 且不调 JS helper，partial commit 保留 token并覆盖 retry-complete 与 abandon-all-stale 两终态；Agent resolver 失败后的 executable picker 选择/取消；first agent 启动失败不回滚 Conversation；Retry/Switch Agent 生成新 session 且保留原失败记录；reattach 列表只显示当前 Context 的 detached sessions。进程测试把 Agent executable 固定到 Task 13 fixture 的绝对路径，不执行用户机器上的 codex/claude。

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
- [ ] Ghostty 轻量 fork 不污染 submodule，Ghostty 固定 1.3.2-dev commit `05221c11…`、Zig 固定 0.16.0，App Bundle 不携带工具链或源码。
- [ ] 没有独立的性能指标、额外加固、额外测试或未来功能任务。
- [ ] 实施使用 sub-Agent-driven development，任务串行、每任务新的 implementer 和两阶段 review。
