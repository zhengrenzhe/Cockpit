# Cockpit Phase 1 Protocol 1.1 与基础领域模型设计

- 状态：已批准
- 日期：2026-08-06
- 适用任务：Phase 1 Task 2
- 上位设计：`docs/superpowers/specs/2026-08-06-cockpit-phase-1-design.md`
- 首要约束：高性能、稳定性、严格类型边界

## 1. 目标与冻结边界

Task 2 交付可被后续 Phase 1 任务直接消费的基础 Swift 领域模型，以及跨进程所需的最小强类型 protobuf ABI。

Protocol 1.1 从 Task 2 合入起冻结以下 ABI：

- protobuf field number；
- enum numeric value；
- `oneof` membership；
- ChannelID 数值；
- Cockpit 自有键盘、鼠标和 signal 数值语义。

后续协议演进只允许兼容性新增。删除 protobuf 字段时永久 `reserved` 原 field number 与 field name；删除 enum value 时永久保留原数值与名称。禁止复用 protobuf 保留区间 `19000...19999`。

本设计不提前定义 Tasks 3–20 的全部业务 request/event。具体文件树、文档事务、终端控制和客户端布局消息在各自任务中按未使用 field number 追加，并受 negotiated protocol minor version 约束。

## 2. 类型归属

### 2.1 CockpitTypes

Task 2 在 `CockpitTypes` 定义：

- 稳定 ID；
- WorkspaceContext、ResolvedWorkspaceContext、ActiveContext 和 RequestContext；
- TabRecord、TextPosition、TextRange 和 DocumentViewState；
- TerminalInput、键盘、鼠标、resize、signal；
- terminal archive 领域值。

`CockpitTypes` 不依赖 SwiftProtobuf、AppKit、WebKit、XPC、UDS 或产品子系统。

### 2.2 CockpitProtocol

Protocol 1.1 protobuf 只定义跨进程使用的：

- `WorkspaceContextID`；
- `RequestContext`；
- `TerminalInput` 及其输入子消息；
- `TerminalArchiveManifest` 及其组成消息。

`TabRecord`、DocumentViewState、sidebar state 和 split-view state 是设备本地持久状态，不进入 protobuf。

`DocumentMessages.swift` 只提供 DocumentID 的显式 UUID 字符串映射工具；Task 2 不创建没有实际消费者的 Document protobuf message。

### 2.3 明确排除

- 不把 AppKit `NSEvent` 放入领域层或协议层。
- 不把绝对路径放入通用 ClientCore payload。
- 不把 Swift Codable JSON 塞入 protobuf `bytes`。
- 不在 protobuf 中复制 terminal output sequence/ack。
- 不修改 Task 11 已批准的 key/mouse C struct 布局。
- 不在 Task 2 处理 Task 12/13 的 LaunchSpec 任务边界。

## 3. Swift 领域模型

### 3.1 稳定 ID

Task 2 新增：

```swift
public typealias WindowID = CockpitID<WindowScope>
public typealias ClientInstanceID = CockpitID<ClientInstanceScope>
public typealias EditLeaseID = CockpitID<EditLeaseScope>
public typealias DocumentID = CockpitID<DocumentScope>
public typealias ViewerID = CockpitID<ViewerScope>
public typealias InputLeaseID = CockpitID<InputLeaseScope>
public typealias DeletionOperationID = CockpitID<DeletionOperationScope>
```

现有 `DocumentSessionID` 与 `DocumentSessionScope` 直接迁移为 `DocumentID` 与 `DocumentScope`，不保留兼容 typealias。

`CockpitID.description` 与全部 protobuf encoder 固定输出小写、带连字符的 UUID。Decoder 接受 Foundation `UUID(uuidString:)` 可解析的 UUID 字符串，拒绝空字符串与非法 UUID，并在领域层归一为 UUID 值。

Task 2 的领域校验统一抛出以下公开错误；case 名是测试和后续消费者使用的稳定 Swift API，不把输入文本、paste 内容、路径或原始 payload 放入错误值：

```swift
public enum CockpitDomainValidationError: Error, Equatable, Sendable {
    case inconsistentWorkspaceContext
    case emptyWorkspaceRootIdentity
    case zeroActiveContextGeneration
    case invalidProtocolVersion
    case protocolVersionMismatch
    case zeroTextPosition
    case invalidHorizontalScrollOffset
    case invalidTabViewState
    case duplicateTabID
    case selectedTabNotFound
    case invalidSplitViewWidth
    case zeroInputSequence
    case emptyTerminalText
    case emptyTerminalPaste
    case terminalTextOrPasteTooLarge
    case invalidTerminalKeyIdentity
    case invalidTerminalLogicalKey
    case invalidTerminalModifiers
    case invalidTerminalMouseButtons
    case invalidTerminalMouseWheel
    case invalidTerminalResize
    case invalidSHA256DigestLength
    case invalidTerminalArchiveChunkName
    case invalidTerminalArchiveChunkRange
    case invalidTerminalExitStatus
    case invalidTerminalArchiveRange
    case invalidTerminalArchiveChunks
    case invalidTerminalArchiveCompletionDate
}
```

下文所有 `Codable` 且带不变量的类型都实现显式 `init(from:)`：先解码字段，再调用同一个 `init(validating:...)` 或 validating factory；`encode(to:)` 先用同一 validation path 重建/校验值再写出。禁止 synthesized `Decodable` 绕过构造校验。

### 3.2 Workspace Context

```swift
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

    public init(
        validating contextID: WorkspaceContextID,
        projectID: ProjectID,
        conversationID: ConversationID?,
        environmentID: EnvironmentID,
        workspaceRootIdentity: String
    ) throws
}

public struct ActiveContext: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let projectID: ProjectID
    public let conversationID: ConversationID?
    public let environmentID: EnvironmentID
    public let workspaceRootIdentity: String
    public let generation: UInt64

    public init(
        validating contextID: WorkspaceContextID,
        projectID: ProjectID,
        conversationID: ConversationID?,
        environmentID: EnvironmentID,
        workspaceRootIdentity: String,
        generation: UInt64
    ) throws
}
```

固定不变量：

- project context 的 ProjectID 等于 `projectID`，且 `conversationID == nil`；
- conversation context 的 ConversationID 等于非空 `conversationID`；
- `workspaceRootIdentity` 非空；
- ActiveContext generation 大于 0。

`ResolvedWorkspaceContext` 位于 CockpitTypes，因为 Task 3 的 HostCore 与 Task 5 的 ClientCore 都消费它，而 ClientCore 不依赖 HostCore。

### 3.3 RequestContext

```swift
public struct RequestContext: Hashable, Codable, Sendable {
    public let protocolVersion: ProtocolVersion
    public let clientInstanceID: ClientInstanceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let activeContextGeneration: UInt64
    public let requestID: RequestID

    public init(
        validating protocolVersion: ProtocolVersion,
        clientInstanceID: ClientInstanceID,
        windowID: WindowID,
        workspaceContextID: WorkspaceContextID,
        environmentID: EnvironmentID,
        activeContextGeneration: UInt64,
        requestID: RequestID
    ) throws

    public func validated(negotiatedVersion: ProtocolVersion) throws -> Self
}
```

固定不变量：

- protocol major 大于 0；
- activeContextGeneration 大于 0；
- receiver 在业务 dispatch 前校验 RequestContext version 等于连接握手得到的 negotiated version；
- mapper 只校验数值可映射为 UInt16，不在基础映射器中硬编码只接受 1.1；
- resource ID、document version、tree revision 与 terminal sequence 属于具体 payload，不进入 RequestContext。

### 3.4 文档视图与 TabRecord

```swift
public struct TextPosition: Hashable, Codable, Sendable {
    public let line: UInt64
    public let column: UInt64

    public init(validatingLine line: UInt64, column: UInt64) throws
}

public struct TextRange: Hashable, Codable, Sendable {
    public let anchor: TextPosition
    public let active: TextPosition

    public init(validatingAnchor anchor: TextPosition, active: TextPosition) throws
}

public struct DocumentViewState: Hashable, Codable, Sendable {
    public var cursor: TextPosition
    public var selections: [TextRange]
    public var firstVisibleLine: UInt64
    public var horizontalScrollOffset: Double

    public init(
        validatingCursor cursor: TextPosition,
        selections: [TextRange],
        firstVisibleLine: UInt64,
        horizontalScrollOffset: Double
    ) throws

    public static func initial() -> Self
    public func validated() throws -> Self
}

public struct TabRecord: Hashable, Codable, Sendable {
    public enum Resource: Hashable, Codable, Sendable {
        case file(DocumentID)
        case terminal(TerminalSessionID)
        case newTabPicker
    }

    public let id: TabID
    public var resource: Resource
    public var fileViewState: DocumentViewState?

    public init(
        validatingID id: TabID,
        resource: Resource,
        fileViewState: DocumentViewState?
    ) throws

    public func validated() throws -> Self
}
```

固定不变量：

- line、column 与 firstVisibleLine 均从 1 开始；
- TextRange 保存 anchor/active，不归一化顺序，以保留选区方向；
- horizontalScrollOffset 必须是有限数且不小于 0；
- file resource 必须携带 fileViewState；
- terminal 与 newTabPicker 禁止携带 fileViewState；
- 初始 DocumentViewState 为 cursor `(1,1)`、空 selections、firstVisibleLine `1`、horizontalScrollOffset `0`。

TabRecord 使用显式 tagged Codable，禁止依赖 Swift synthesized enum representation。持久格式固定为：

```json
{
  "id": "<uuid>",
  "resource": {
    "kind": "file | terminal | new-tab-picker",
    "documentID": "<uuid, file only>",
    "terminalSessionID": "<uuid, terminal only>"
  },
  "fileViewState": "<object, file only>"
}
```

Decoder 拒绝未知 kind、缺少对应 ID、同时出现两个资源 ID，以及不符合 resource/view-state 组合的不合法持久数据。

### 3.5 Task 5 客户端持久状态

以下共享值在 Task 5 加入 `CockpitTypes/WorkspaceModels.swift`，不在 Task 2 提前实现。它们只表达 Phase 1 已批准的 Device + Window + WorkspaceContext 布局、三栏宽度/左栏折叠和 Context-local tabs；不进入 protobuf：

```swift
public struct ClientWorkspaceStateKey: Hashable, Codable, Sendable {
    public let deviceID: DeviceID
    public let windowID: WindowID
    public let workspaceContextID: WorkspaceContextID

    public init(
        deviceID: DeviceID,
        windowID: WindowID,
        workspaceContextID: WorkspaceContextID
    )
}

public struct SidebarState: Hashable, Codable, Sendable {
    public var isCollapsed: Bool

    public init(isCollapsed: Bool)
}

public struct SplitViewState: Hashable, Codable, Sendable {
    public var leadingPaneWidth: Double
    public var trailingPaneWidth: Double

    public init(
        validatingLeadingPaneWidth leadingPaneWidth: Double,
        trailingPaneWidth: Double
    ) throws

    public func validated() throws -> Self
}

public struct ClientWorkspaceState: Hashable, Codable, Sendable {
    public let key: ClientWorkspaceStateKey
    public var tabs: [TabRecord]
    public var selectedTabID: TabID?
    public var sidebar: SidebarState
    public var splitView: SplitViewState

    public init(
        validatingKey key: ClientWorkspaceStateKey,
        tabs: [TabRecord],
        selectedTabID: TabID?,
        sidebar: SidebarState,
        splitView: SplitViewState
    ) throws

    public func validated() throws -> Self
}
```

`SplitViewState` 的两个宽度都必须是有限数且不小于 0。`ClientWorkspaceState` 拒绝重复 TabID；`selectedTabID` 非空时必须引用 `tabs` 中的记录。上述带不变量的 Codable 值同样使用本节开头冻结的显式 decode/encode validation path。

### 3.6 TerminalInput 领域值

Swift 领域值由一个 envelope 和一个 payload enum 组成：

```swift
public enum TerminalKeyAction: UInt8, Hashable, Codable, Sendable {
    case press = 1
    case `repeat` = 2
    case release = 3
}

public struct TerminalKeyEvent: Hashable, Codable, Sendable {
    public let logicalKey: UInt32
    public let physicalKey: UInt32
    public let modifiers: UInt32
    public let action: TerminalKeyAction

    public init(
        validatingLogicalKey logicalKey: UInt32,
        physicalKey: UInt32,
        modifiers: UInt32,
        action: TerminalKeyAction
    ) throws
}

public enum TerminalMouseAction: UInt8, Hashable, Codable, Sendable {
    case press = 1
    case release = 2
    case motion = 3
    case scroll = 4
}

public struct TerminalMouseEvent: Hashable, Codable, Sendable {
    public let cellX: Int32
    public let cellY: Int32
    public let buttons: UInt32
    public let wheelX: Int32
    public let wheelY: Int32
    public let modifiers: UInt32
    public let action: TerminalMouseAction

    public init(
        validatingCellX cellX: Int32,
        cellY: Int32,
        buttons: UInt32,
        wheelX: Int32,
        wheelY: Int32,
        modifiers: UInt32,
        action: TerminalMouseAction
    ) throws
}

public struct TerminalResize: Hashable, Codable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(validatingColumns columns: UInt32, rows: UInt32) throws
}

public enum TerminalSignal: UInt8, Hashable, Codable, Sendable {
    case interrupt = 1
    case quit = 2
    case suspend = 3
    case `continue` = 4
}

public struct TerminalInput: Hashable, Sendable {
    public let context: RequestContext
    public let terminalSessionID: TerminalSessionID
    public let inputLeaseID: InputLeaseID
    public let inputSequence: UInt64
    public let payload: Payload

    public enum Payload: Hashable, Sendable {
        case text(String)
        case key(TerminalKeyEvent)
        case paste(String)
        case mouse(TerminalMouseEvent)
        case resize(TerminalResize)
        case signal(TerminalSignal)
    }

    public static let maximumTextOrPasteUTF8Bytes = 16 * 1_024 * 1_024

    public init(
        validatingContext context: RequestContext,
        terminalSessionID: TerminalSessionID,
        inputLeaseID: InputLeaseID,
        inputSequence: UInt64,
        payload: Payload
    ) throws

    public func validated() throws -> Self
}

public typealias TerminalInputFrame = TerminalInput
```

inputSequence 大于 0，并作为 Task 14 input lease ACK/retry 去重序号。它与 terminal output sequence 无关。

text 与 paste 必须非空，并受现有 16 MiB Frame payload 上限约束。text 是已提交 UTF-8 文本；IME preedit 留在客户端，不进入 PTY 或通用协议。

`TerminalInput` 构造器拒绝 text/paste UTF-8 byte count 大于 `maximumTextOrPasteUTF8Bytes`；`TerminalMessages.encode` 还必须对完整 protobuf `serializedData()` 执行 `FrameHeader.maximumPayloadLength` 检查，因为 envelope 与 protobuf tag 也占用 Frame payload。

### 3.7 Terminal archive 领域值

```swift
public struct SHA256Digest: Hashable, Codable, Sendable {
    public let bytes: Data

    public init(validating bytes: Data) throws
}

public struct TerminalArchiveChunk: Hashable, Codable, Sendable {
    public let name: String
    public let firstOutputSequence: UInt64
    public let lastOutputSequence: UInt64
    public let sha256: SHA256Digest

    public init(
        validatingName name: String,
        firstOutputSequence: UInt64,
        lastOutputSequence: UInt64,
        sha256: SHA256Digest
    ) throws
}

public enum TerminalExitStatus: Hashable, Codable, Sendable {
    case exited(UInt8)
    case signaled(Int32)

    public func validated() throws -> Self
}

public struct TerminalArchiveManifest: Hashable, Codable, Sendable {
    public let terminalSessionID: TerminalSessionID
    public let workerInstanceID: WorkerInstanceID
    public let firstOutputSequence: UInt64
    public let latestOutputSequence: UInt64
    public let chunks: [TerminalArchiveChunk]
    public let finalSnapshotSHA256: SHA256Digest
    public let exitStatus: TerminalExitStatus
    public let completedAt: Date

    public init(
        validatingTerminalSessionID terminalSessionID: TerminalSessionID,
        workerInstanceID: WorkerInstanceID,
        firstOutputSequence: UInt64,
        latestOutputSequence: UInt64,
        chunks: [TerminalArchiveChunk],
        finalSnapshotSHA256: SHA256Digest,
        exitStatus: TerminalExitStatus,
        completedAt: Date
    ) throws

    public func validated() throws -> Self
}
```

`TerminalExitStatus` 的显式 Codable decoder 和 `TerminalArchiveManifest` validator 固定拒绝 `.signaled` 不在 Darwin signal `1...31` 的值；`.exited(UInt8)` 由类型范围固定为 `0...255`。SHA256Digest 的构造器固定拒绝不是 32 bytes 的输入。归档需要完整表达包括崩溃在内的自然退出结果，因此这里记录 Host 的原始 Darwin signal，而 TerminalInput 使用 Cockpit 语义 signal enum。

## 4. Protocol 1.1 protobuf ABI

`cockpit.proto` 保持 `package cockpit.protocol.v1` 与 `swift_prefix = "CP"`，新增：

```proto
import "google/protobuf/timestamp.proto";

message WorkspaceContextID {
  oneof kind {
    string project_id = 1;
    string conversation_id = 2;
  }
}

message RequestContext {
  uint32 protocol_major = 1;
  uint32 protocol_minor = 2;
  string client_instance_id = 3;
  string window_id = 4;
  WorkspaceContextID workspace_context_id = 5;
  string environment_id = 6;
  uint64 active_context_generation = 7;
  string request_id = 8;
}

enum TerminalKeyAction {
  TERMINAL_KEY_ACTION_UNSPECIFIED = 0;
  TERMINAL_KEY_ACTION_PRESS = 1;
  TERMINAL_KEY_ACTION_REPEAT = 2;
  TERMINAL_KEY_ACTION_RELEASE = 3;
}

message TerminalKeyEvent {
  uint32 logical_key = 1;
  uint32 physical_key = 2;
  uint32 modifiers = 3;
  TerminalKeyAction action = 4;
}

enum TerminalMouseAction {
  TERMINAL_MOUSE_ACTION_UNSPECIFIED = 0;
  TERMINAL_MOUSE_ACTION_PRESS = 1;
  TERMINAL_MOUSE_ACTION_RELEASE = 2;
  TERMINAL_MOUSE_ACTION_MOTION = 3;
  TERMINAL_MOUSE_ACTION_SCROLL = 4;
}

message TerminalMouseEvent {
  int32 cell_x = 1;
  int32 cell_y = 2;
  uint32 buttons = 3;
  sint32 wheel_x = 4;
  sint32 wheel_y = 5;
  uint32 modifiers = 6;
  TerminalMouseAction action = 7;
}

message TerminalResize {
  uint32 columns = 1;
  uint32 rows = 2;
}

enum TerminalSignal {
  TERMINAL_SIGNAL_UNSPECIFIED = 0;
  TERMINAL_SIGNAL_INTERRUPT = 1;
  TERMINAL_SIGNAL_QUIT = 2;
  TERMINAL_SIGNAL_SUSPEND = 3;
  TERMINAL_SIGNAL_CONTINUE = 4;
}

message TerminalInput {
  RequestContext context = 1;
  string terminal_session_id = 2;
  string input_lease_id = 3;
  uint64 input_sequence = 4;

  oneof payload {
    string text = 5;
    TerminalKeyEvent key = 6;
    string paste = 7;
    TerminalMouseEvent mouse = 8;
    TerminalResize resize = 9;
    TerminalSignal signal = 10;
  }
}

message TerminalArchiveChunk {
  string name = 1;
  uint64 first_output_sequence = 2;
  uint64 last_output_sequence = 3;
  bytes sha256 = 4;
}

message TerminalExitStatus {
  oneof result {
    uint32 exit_code = 1;
    int32 darwin_signal = 2;
  }
}

message TerminalArchiveManifest {
  string terminal_session_id = 1;
  string worker_instance_id = 2;
  uint64 first_output_sequence = 3;
  uint64 latest_output_sequence = 4;
  repeated TerminalArchiveChunk chunks = 5;
  bytes final_snapshot_sha256 = 6;
  TerminalExitStatus exit_status = 7;
  google.protobuf.Timestamp completed_at = 8;
}
```

## 5. 输入数值语义

### 5.1 键盘

- logicalKey 是未加修饰键的 Unicode scalar；没有逻辑字符时为 0。
- physicalKey 是 W3C/Chromium keycode table 使用的 USB HID usage code；未知物理键为 0。
- logicalKey 与 physicalKey 不得同时为 0。
- logicalKey 非 0 时必须小于等于 `0x10FFFF` 且不在 surrogate 区间 `0xD800...0xDFFF`。
- modifiers bit `0...9` 固定为 Shift、Control、Alt、Super、Caps Lock、Num Lock、右 Shift、右 Control、右 Alt、右 Super；其他位在 Protocol 1.1 必须为 0。
- Cockpit key action 与 Ghostty action 固定使用下表，转换必须显式实现，禁止直接使用 Ghostty ordinal：

| Cockpit value | Ghostty action |
|---|---|
| Cockpit 1 PRESS | Ghostty press |
| Cockpit 2 REPEAT | Ghostty repeat |
| Cockpit 3 RELEASE | Ghostty release |
- IME committed text 走 text payload；不传 NSEvent 或 IME preedit。

### 5.2 鼠标

- cellX/cellY 是零基 terminal cell 坐标；负数保留为 viewport 外坐标。
- buttons 是事件处理后的当前按键集合：bit 0 为 left、bit 1 为 right、bit 2 为 middle、bit `3...10` 为 button `4...11`；其他位在 Protocol 1.1 必须为 0。
- PRESS/RELEASE 由 Task 11 encoder 与上一状态比较得到变化按钮；input lease 切换时重置该 viewer 的按钮状态。
- wheelX/wheelY 使用有符号 Q16.16 cell 单位，`65536` 表示一格。
- 非 SCROLL 事件要求 wheelX 与 wheelY 均为 0；SCROLL 要求至少一个方向非 0。
- modifiers 使用与键盘完全相同的 bitset。

### 5.3 Resize

columns 与 rows 固定为 `1...65535`，对应 Darwin `winsize` 的 `unsigned short` 范围。

### 5.4 Signal 与 Channel

TerminalInput signal 使用 Cockpit 语义值并固定映射：

| Cockpit value | Darwin signal |
|---|---:|
| INTERRUPT = 1 | SIGINT |
| QUIT = 2 | SIGQUIT |
| SUSPEND = 3 | SIGTSTP |
| CONTINUE = 4 | SIGCONT |

signal capability 控制 PTY 当前 foreground job：把 SIGINT、SIGQUIT、SIGTSTP 或 SIGCONT 发送给当前 foreground process group，并明确允许这些 Darwin signal 按系统语义中断、退出、挂起或继续该 foreground job，其中 SIGINT/SIGQUIT 可以结束进程。input capability 写入 text/key/paste/mouse 所产生的 PTY bytes；它已经可以通过终端驱动的 Ctrl+C/Ctrl+\\ 行为向 foreground job 产生 SIGINT/SIGQUIT，不能把 input 描述为无法结束进程。

terminate capability 控制整个 TerminalSession process group，并负责 TerminalSession lifecycle 与 archive state。SIGHUP、SIGTERM 与 SIGKILL 不属于 TerminalInput signal enum；正常/强制 terminate 分别通过独立 terminate policy 对整个 session process group 执行 SIGTERM/SIGKILL。signal capability 与 terminate capability 的区别是控制目标和生命周期职责，不是“signal 不能终止进程”。

ChannelID 固定为：

| Channel | 数值 | 用途 |
|---|---:|---|
| control | 0 | handshake、signal、terminate 与控制面 |
| terminalOutput | 1 | snapshot/delta/scrollback |
| terminalInput | 2 | text/key/paste/mouse/resize/ACK |
| documentEdits | 3 | document transaction/snapshot/ACK |
| fileTreeEvents | 4 | lazy tree request/delta |
| bulk | 5 | 分页或大块数据 |

TerminalInput 的 signal payload 只允许走 Channel 0；其他 TerminalInput payload 只允许走 Channel 2。Router 对错误 channel 返回 malformed-message。

Terminal output 的 sequence/ack 只使用现有 32-byte FrameHeader。inputSequence 是 input lease 幂等序号，保留在 TerminalInput protobuf 中。

## 6. Archive 校验

固定规则：

- terminalSessionID 与 workerInstanceID 必须是合法 UUID；
- final snapshot 与每个 chunk 的 SHA-256 必须恰好 32 bytes；
- exit status 与 completedAt message presence 必须存在；
- exitCode 为 `0...255`；darwinSignal 为 `1...31`；
- Google Timestamp 必须满足 SwiftProtobuf/Protobuf 的有效 seconds/nanos 范围；
- `firstOutputSequence == 0 && latestOutputSequence == 0` 表示没有 sequenced output，并要求 chunks 为空；
- 其他情况固定满足 `1 <= firstOutputSequence <= latestOutputSequence`；
- 每个 chunk 固定满足 `1 <= first <= last` 且 range 位于 manifest 全局范围内；
- chunks 按 first 严格递增，拒绝重复 name、倒序和重叠；
- chunks 允许 sequence 间隔，因为 final snapshot 与 scrollback chunks 承载不同数据；
- chunk name 必须等于 first sequence 的 20 位十进制补零形式加 `.ckgs`；
- chunk name 拒绝 `/`、`\\`、NUL、`.`、`..`；
- final snapshot 文件名固定为 `final-snapshot.ckgf`，manifest 只保存它的 SHA-256。

合法示例：

```text
first=1 latest=30
chunks/00000000000000000001.ckgs -> range 1...10
chunks/00000000000000000021.ckgs -> range 21...25
final-snapshot.ckgf             -> authoritative state at latest=30
```

## 7. 显式 Mapper 与错误

Task 2 使用显式 mapper，不依赖 Codable wire encoding：

```swift
public enum ProtocolMappingError: Error, Equatable, Sendable {
    case missingRequiredField(String)
    case invalidIdentifier(String)
    case invalidValue(String)
    case unknownOneOf(String)
    case unknownEnum(field: String, rawValue: Int)
    case unknownFields(String)
}

public enum WorkspaceMessages {
    public static func encode(
        _ value: WorkspaceContextID
    ) throws -> CPWorkspaceContextID

    public static func decode(
        _ message: CPWorkspaceContextID
    ) throws -> WorkspaceContextID

    public static func encode(
        _ value: RequestContext,
        negotiatedVersion: ProtocolVersion
    ) throws -> CPRequestContext

    public static func decode(
        _ message: CPRequestContext,
        negotiatedVersion: ProtocolVersion
    ) throws -> RequestContext
}

public enum DocumentMessages {
    public static func encode(_ value: DocumentID) -> String
    public static func decode(_ value: String) throws -> DocumentID
}

public enum TerminalMessages {
    public static func encode(
        _ value: TerminalInput,
        channelID: ChannelID,
        negotiatedVersion: ProtocolVersion
    ) throws -> CPTerminalInput

    public static func decode(
        _ message: CPTerminalInput,
        channelID: ChannelID,
        negotiatedVersion: ProtocolVersion
    ) throws -> TerminalInput

    public static func encode(
        _ value: TerminalArchiveManifest,
        negotiatedVersion: ProtocolVersion
    ) throws -> CPTerminalArchiveManifest

    public static func decode(
        _ message: CPTerminalArchiveManifest,
        negotiatedVersion: ProtocolVersion
    ) throws -> TerminalArchiveManifest
}

extension ProtocolMappingError {
    public func asWireProtocolError() -> CPProtocolError
}
```

`WorkspaceMessages` 是 `WorkspaceMessages.swift` 的唯一公开 mapper namespace；`DocumentMessages` 是 `DocumentMessages.swift` 的唯一公开 mapper namespace；`TerminalMessages` 是 `TerminalMessages.swift` 的唯一公开 mapper namespace。嵌套 key/mouse/resize/signal/chunk/exit-status helper 保持 internal，后续消费者只调用上述入口。

Protocol 1.1 顶层 RequestContext、TerminalInput 与 TerminalArchiveManifest encode/decode 都要求 `negotiatedVersion.major == 1 && negotiatedVersion.minor >= 1`。RequestContext 还必须通过 `validated(negotiatedVersion:)`，即其 message 内版本与连接协商版本完全相等；这消除了“校验顺序要求 negotiated minor、mapper 却收不到 negotiated version”的矛盾。WorkspaceContextID 和 DocumentID 是被顶层 message 复用的无版本叶值，因此其公开 helper 不接收 negotiated version。

TerminalInput encode/decode 都接收实际 Frame 的 `ChannelID`：signal payload 只接受 `.control`，其余 payload 只接受 `.terminalInput`。`TerminalMessages.encode` 在返回 `CPTerminalInput` 前校验其 `serializedData().count <= Int(FrameHeader.maximumPayloadLength)`；decode 前的 FrameCodec 已执行同一 Frame 上限，mapper 仍执行 text/paste 非空和领域 byte-count 校验。

`asWireProtocolError()` 是从 `ProtocolMappingError` 到 wire error 的唯一公开转换入口。它总是构造 `CPProtocolError(code: .malformedMessage, ...)`，因此生成的 `CPProtocolError.Code.malformedMessage.rawValue` 固定为 wire code 3。message 固定为当前 case 对应的类别文本（`missing required field`、`invalid identifier`、`invalid value`、`unknown oneof`、`unknown enum` 或 `unknown fields`），不插入 associated String、raw enum value、原始 payload、text、paste 或路径；即使调用方用敏感字符串构造 `ProtocolMappingError`，wire message 也不会包含该字符串。

映射顺序固定为：

1. 拒绝当前 negotiated minor 不支持的 message；
2. 拒绝非空 SwiftProtobuf unknownFields；
3. 检查 required message/oneof presence；
4. 拒绝 `.UNRECOGNIZED(rawValue)` enum；
5. 映射 ID 与 scalar；
6. 执行领域不变量。

Protocol 1.1 下拒绝 unknownFields。后续 minor version 的 sender 只能在双方 handshake 已协商到该 minor 后发送新增字段，因此 additive schema 与严格 mapper 不冲突。

Encoder 同样执行完整领域校验，禁止把无效本地状态编码到 wire。

## 8. 测试契约

Task 2 的 focused tests 固定覆盖：

### 8.1 领域值

- 新增 ID 与 DocumentSessionID 完整迁移；
- ResolvedWorkspaceContext project/conversation 不变量；
- ResolvedWorkspaceContext/ActiveContext 的 `workspaceRootIdentity` 非空；
- ActiveContext generation 非零；
- RequestContext protocol major 非零，以及 `validated(negotiatedVersion:)` 的完全匹配/不匹配；
- TextPosition 一基坐标；
- TextRange anchor/active 方向保留；
- DocumentViewState horizontalScrollOffset 拒绝负数、NaN 和正负 infinity；
- TabRecord 三种 resource 与非法 fileViewState 组合；
- tagged Codable round-trip 与未知 kind 拒绝；
- 每个带不变量的 Codable 类型直接 decode 非法持久值时，与公开 validating initializer/factory 抛出相同的 `CockpitDomainValidationError`。

### 8.2 Protocol round-trip

- project decode 后没有 ConversationID；
- conversation 保留 ConversationID；
- `A(17) -> B(18) -> A(19)` generation 完整 round-trip；
- TerminalInput 的 text/key/paste/mouse/resize/signal 六种 payload；
- key action/modifier/Unicode/USB 数值；
- mouse action/button/wheel 数值；
- inputSequence round-trip；
- text/paste 非空、UTF-8 byte count 边界与完整 serialized protobuf 的 16 MiB Frame 上限；
- signal 走 Channel 0、其他 TerminalInput payload 走 Channel 2，encoder 与 decoder 都拒绝错误 route；
- archive normal exit、signal exit、空 output、带 chunk output 与合法 sequence gap。

### 8.3 失败路径

- 空或非法 UUID；
- protocol version overflow；
- zero generation 与 zero inputSequence；
- nil/unknown oneof、unknown enum 与 unknown field；
- key 两个 identity 同时为 0、非法 Unicode scalar 与未知 modifier bits；
- mouse 未知 action/buttons、错误 wheel/action 组合；
- resize 为 0 或超过 65535；
- unknown/disallowed signal；
- hash 长度不是 32；
- 缺少 exit status/completedAt；
- exitCode 超过 255、darwinSignal 越界、无效 Timestamp；
- chunk name 不匹配、重复、倒序、重叠或越出全局 range；
- `ProtocolMappingError.asWireProtocolError()` 对全部 case 固定生成 malformed-message wire code 3，且 associated String、enum raw value、text、paste 和路径不出现在 wire message；
- encoder 对 mutation 后的非法 DocumentViewState/TabRecord、非法 TerminalExitStatus、错误 channel 和超限 TerminalInput 执行与 decoder 相同的拒绝。

### 8.4 回归门槛

- `ProtocolVersion.current == 1.1`；
- ConnectionController 发送 1.1 并继续执行 major/minor negotiation；
- existing FrameHeader 仍为 32 bytes；
- terminal output protobuf 中不存在第二套 sequence/ack。

Task 2 只运行计划已有 focused command：

```bash
/usr/bin/swift test --disable-automatic-resolution --filter 'CockpitTypesTests|CockpitProtocolTests|CockpitClientCoreTests.ConnectionControllerTests'
/usr/bin/git diff --check
```

不增加新的 Phase、Task、第三方依赖或独立验证任务。
