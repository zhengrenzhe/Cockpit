# Cockpit Architecture Design

- Status: Approved
- Date: 2026-08-05
- Initial platform: macOS
- Long-term clients: Apple platforms
- Primary constraint: native performance

## 1. Product Definition

Cockpit is a native agent development environment. It provides projects, conversations, code editing, terminals, file tools, search, and Git workflows. Agent orchestration remains inside external CLI programs such as Codex and Claude Code.

The initial product runs on macOS. The Mac remains the authority for projects, worktrees, files, Git repositories, language servers, terminal processes, and conversation state. Other Apple devices connect as remote clients.

### Goals

- Use Swift and native macOS UI for the application shell.
- Keep UI input, terminal rendering, file navigation, and workspace switching responsive under sustained CLI output.
- Reach VS Code-class editing through an isolated Monaco runtime.
- Use Ghostty's terminal core and Metal renderer through a pinned thin fork.
- Preserve live terminal sessions across Cockpit.app, CockpitHost, and CockpitTerminalSupervisor restarts.
- Make every product API remote-capable from the first implementation phase.
- Keep Project, Conversation, and Environment identities stable and explicit.
- Scope all file, search, Git, editor, and terminal operations to an immutable EnvironmentID.

### Non-goals for the first Developer Preview

- Built-in agent orchestration.
- A plugin marketplace.
- CRDT multi-writer editing.
- An internet Relay service.
- Container or virtual-machine isolation.
- Non-Apple clients.
- A web application shell.

## 2. Product Layout

### Left sidebar

The left sidebar owns the product hierarchy:

```text
Project A
├── Conversation A1
└── Conversation A2 · worktree: feature/a

Project B
├── Conversation B1
└── Conversation B2 · worktree: fix/b
```

- Project maps to a physical folder selected by the user.
- Project contains multiple Conversations.
- Conversation displays whether it uses the project directory directly or a Git worktree.
- Selecting a Conversation changes the entire active work context.

### Center workspace

The center is the core work area and uses native tabs.

- A tab can display a file editor, Agent CLI terminal, ordinary shell, diff editor, or new-tab chooser.
- Native tab state is separate from document and terminal lifetimes.
- Closing a tab detaches a view; it does not terminate a TerminalSession.

### Right tool sidebar

The right sidebar follows the selected Conversation's EnvironmentID.

- File tree.
- File search.
- Source search.
- Source control status and local changes.
- Diff and commit UI.
- Git Toolbox quick operations.

No right-sidebar provider reads the Project root directly. Every provider resolves its root from the active EnvironmentID.

## 3. Core Data Model

### Project

```text
ProjectID
displayName
rootBookmark
canonicalRootIdentity
createdAt
```

A Project represents one user-selected physical folder.

### Conversation

```text
ConversationID
ProjectID
EnvironmentID
title
agentProfile
primaryTerminalSessionID
tabRecords
archivedAt
```

A Conversation is the product-level work context shown in the left sidebar. It is not a PTY and is not a UI tab.

### Environment

An Environment is immutable after Conversation creation.

```text
EnvironmentID
ProjectID
kind: direct | worktree
workspaceRoot
gitCommonDirectory
worktreeBranch
```

- A Direct Environment resolves to the Project root.
- A Worktree Environment resolves to one Git worktree root.
- Multiple Direct Environments can share the same physical root.
- WorkspaceKernel resources are deduplicated by canonical physical root while product state remains keyed by EnvironmentID.

Changing a Conversation from Direct to Worktree creates a new Conversation. Existing terminal, document, and Git history never changes environment identity.

### TerminalSession

```text
TerminalSessionID
ConversationID
EnvironmentID
launchSpec
workerInstanceID
keeperProcessIdentifier
cliProcessIdentifier
lifecycleState
protocolVersion
latestSequence
```

Agent CLI and ordinary shell sessions use the same model.

### DocumentSession

Document identity is:

```text
EnvironmentID + RelativePath
```

The same relative path in two worktrees produces two distinct DocumentSessions.

### TabRecord

TabRecord contains only presentation references:

```text
TabID
kind
resourceID
position
```

Closing a TabRecord never terminates a PTY. Termination requires an explicit TerminalSession command.

### ClientViewState

ClientViewState is device-specific:

- Selected tab.
- Sidebar widths.
- Expanded nodes.
- Scroll positions.
- Focus and local selection.

It is not shared domain state.

## 4. Active Context

Selecting a Conversation creates a new client generation and subscribes to one immutable ActiveContext:

```text
ActiveContext
├── ConversationID
├── EnvironmentID
├── WorkspaceRootIdentity
├── GitContext
└── generation
```

CockpitHost returns a revisioned bootstrap snapshot for tabs, documents, terminals, file tree, and Git state. The client atomically displays the snapshot, then applies deltas whose revision is greater than the bootstrap revision.

Every asynchronous result carries EnvironmentID, generation, resource ID, and local revision. Results from an old generation are discarded.

## 5. Process Architecture

Cockpit defines four app-owned executable roles. CockpitPTYKeeper has one process instance per live TerminalSession. WKWebView also creates system-managed WebContent and GPU helper processes.

### Cockpit.app

Responsibilities:

- AppKit window and split-view shell.
- Native project, conversation, tab, and tool UI.
- One Monaco WKWebView runtime per window.
- Ghostty Metal NSView surfaces.
- CockpitClientCore and ClientViewState.
- Local user input and command routing.

Cockpit.app does not own filesystem, Git, PTY, or durable document state.

### CockpitHost

Responsibilities:

- Project, Conversation, and Environment authority.
- WorkspaceKernel pool.
- File service, FSEvents reconciliation, file index, and search.
- Git model and serialized Git operations.
- DocumentStore, recovery journal, and external-change conflicts.
- LSP process lifecycle and request routing.
- workspace.sqlite.
- Local control endpoint.
- Network.framework remote gateway.
- Device, project, and capability authorization.
- Conversation-to-TerminalSession product metadata.

CockpitHost does not own live PTYs.

### CockpitTerminalSupervisor

CockpitTerminalSupervisor is an independent per-user LaunchAgent with `KeepAlive` enabled.

Responsibilities:

- TerminalSession registry.
- Two-phase TerminalSession creation transactions.
- PTYKeeper spawning, discovery, authentication, and reconciliation.
- Single-use local attach tickets.
- Terminal input-lease coordination.
- Final terminal archive serving.
- terminal.sqlite.

CockpitTerminalSupervisor never owns a PTY master, never parses VT output, and never proxies the live local terminal data path. It does not expose a network listener and does not implement files, Git, search, or LSP.

### CockpitPTYKeeper

CockpitTerminalSupervisor spawns one CockpitPTYKeeper for each committed live TerminalSession. Every Keeper starts in a separate Unix session and process group with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`; only explicitly declared bootstrap descriptors cross the spawn boundary.

Responsibilities:

- Exclusive ownership of one PTY master.
- Agent CLI or shell process-group lifecycle.
- Structured LaunchSpec execution after a committed start command.
- Ghostty VT parsing and authoritative screen state.
- Scrollback chunks, snapshots, and terminal frame deltas.
- Continuous PTY draining independent of attached clients.
- Per-client backpressure, ordered input, deduplication, and lease enforcement.
- One authenticated Unix Domain Socket endpoint.
- Final screen and scrollback checkpointing when the CLI exits.

CockpitPTYKeeper never listens on the network and never writes terminal.sqlite. A Supervisor exit reparents live Keepers to launchd/PID 1; their separate process groups keep them outside launchd's same-process-group cleanup boundary.

## 6. Process Communication

### Local control plane

NSXPCConnection carries lifecycle and low-frequency control messages between Cockpit.app, CockpitHost, and CockpitTerminalSupervisor:

- Create, list, archive, and delete product records.
- Create, list, attach, terminate, and reconcile TerminalSessions.
- Acquire and release input leases.
- Register subscriptions.
- Report service capabilities and protocol versions.

XPC endpoints validate peer identity before accepting commands. Phase 0 enforces the effective user boundary for ad-hoc development builds; Phase 6 adds the release Team ID and designated-requirement checks.

### Local data plane

Unix Domain Sockets carry framed, multiplexed streams:

- Terminal input and screen frames.
- Document edit transactions and acknowledgements.
- File-tree patches.
- Search, diff, and scrollback batches.
- LSP request and response payloads.

The local terminal hot path bypasses CockpitHost and CockpitTerminalSupervisor after authorization:

```text
Cockpit.app <-> CockpitPTYKeeper <-> PTY <-> Agent CLI
```

CockpitHost authorizes the Environment and asks CockpitTerminalSupervisor for a single-use attach ticket. The Supervisor registers that ticket with the target Keeper, then returns the endpoint descriptor to Cockpit.app. Cockpit.app presents the ticket when opening the direct terminal socket.

An established App-to-Keeper stream remains usable while CockpitTerminalSupervisor restarts. New attach, terminate, and lease-transfer commands resume after launchd relaunches and reconciles the Supervisor.

### Remote data path

```text
Remote Apple Client
    <-> Network.framework TLS 1.3
    <-> CockpitHost
    <-> local authenticated terminal stream
    <-> CockpitPTYKeeper
```

CockpitTerminalSupervisor and CockpitPTYKeeper remain unreachable from the network.

## 7. CockpitProtocol

CockpitProtocol uses a fixed binary frame header and typed payloads.

```text
magic
protocolVersion
featureSet
flags
deviceID
connectionID
requestID
environmentID
channelID
sequence
acknowledgement
payloadType
payloadLength
```

Payload policy:

- SwiftProtobuf for control messages and structured data.
- Packed binary terminal cell deltas.
- Negotiated compression for snapshots, scrollback, search, and large diffs.
- No compression for keyboard input, edit acknowledgement, or small control messages.

Channels have independent sequencing and flow control:

- Control: reliable and ordered, highest priority.
- Document: reliable, ordered, version-acknowledged.
- TerminalInput: reliable and ordered.
- TerminalFrame: ordered and coalescible; a gap triggers snapshot recovery.
- Bulk: cancellable and paged.

Mutating commands carry request IDs so retries remain idempotent.

## 8. Remote-Ready Boundaries

CockpitClientCore is a pure Swift package shared by the macOS app and future Apple clients.

It depends on no AppKit, WKWebView, NSXPCConnection, NWConnection, or local filesystem API.

```swift
public protocol CockpitTransport: Sendable {
    func connect() async throws -> NegotiatedSession
    func request(_ envelope: RequestEnvelope) async throws -> ResponseEnvelope
    func openChannel(_ descriptor: ChannelDescriptor) async throws -> any CockpitChannel
    func disconnect() async
}
```

Transport implementations:

- LocalTransport: XPC control and local socket data.
- RemoteDirectTransport: Network.framework and TLS 1.3 for LAN or VPN.
- RelayTransport: future reliable byte-stream adapter.

CockpitHostCore accepts command, query, and subscription values and does not inspect the transport type.

Remote rules:

- Remote listening is disabled by default.
- Pairing starts on the Mac.
- Each device has its own key, allowlist entry, and grants.
- Protocol identity does not bind to an IP address.
- Requests use stable IDs and relative paths.
- The Host validates Environment authorization and canonical path containment.
- One DocumentSession has one write lease.
- One TerminalSession has one input lease.
- Other connected devices remain read-only until control transfers.
- Offline editing is not supported.

Remote terminal permission is equivalent to the macOS user's interactive shell permission. Project-scoped file APIs cannot constrain shell commands. Container or virtual-machine isolation is a separate product boundary.

## 9. Terminal Architecture

### Output path

```text
CLI stdout/stderr
-> PTY master
-> PTYKeeper read loop
-> Ghostty VT core
-> authoritative cell grid and scrollback
-> snapshot/delta encoder
-> local or proxied channel
-> Ghostty Metal renderer
```

Each CockpitPTYKeeper drains its PTY independently of renderer speed. When one client falls behind, the Keeper coalesces that client's intermediate screen frames while preserving the latest terminal state. It never blocks PTY reading on client rendering or archive I/O.

Sequence gaps trigger a full screen snapshot. Scrollback uses paged chunks.

### Input path

```text
keyboard / paste / resize
-> input lease validation
-> ordered TerminalInput channel
-> PTY
```

Input frames use a monotonically increasing sequence per lease. The Keeper acknowledges accepted input and deduplicates retries after a stream reconnect. One TerminalSession has one input lease and any number of read-only viewers.

### Session creation transaction

The externally visible lifecycle is:

```text
Preparing -> Committed -> Running
                           |-> Exited
                           |-> Terminated
                           `-> Interrupted
```

Attachment is independent state. Closing a tab, quitting Cockpit.app, or disconnecting a remote client detaches a viewer without changing a Running session.

Creation uses a durable two-phase transaction:

1. The Supervisor allocates TerminalSessionID and WorkerInstanceID, writes Preparing plus the structured LaunchSpec to terminal.sqlite, and commits.
2. The Supervisor passes bootstrap material and the derived session secret through an inherited private descriptor, then spawns a detached Keeper. The Keeper does not create a PTY or CLI yet.
3. The Keeper binds its UDS endpoint and returns Ready.
4. The Supervisor durably records Committed, then sends Start.
5. The Keeper creates the PTY and CLI, returns process identities, and the Supervisor records Running.

If the Supervisor exits before Committed, the Keeper never starts the CLI and exits when its 30-second bootstrap deadline expires. If the Supervisor exits after Committed, its replacement completes or reconciles the start. Therefore every started CLI has a durable committed TerminalSession record.

### Attach and recovery

- The UDS runtime directory is `/private/tmp/cockpit.<uid>/terminal`, owned by the current user with mode `0700`; each socket uses mode `0600`.
- Keeper endpoints verify the effective user with `getpeereid` and authenticate the protocol handshake.
- An installation master key lives in Keychain. Session secrets are derived from the master key, TerminalSessionID, and WorkerInstanceID, then passed to the Keeper through the bootstrap descriptor rather than argv or environment variables. If Keychain is unavailable, reconciliation waits without terminating a live Keeper.
- Attach tickets are single-use and bind TerminalSessionID, client identity, capabilities, and expiry.
- A reconnect supplies the last acknowledged output sequence. The Keeper resumes retained deltas or sends a fresh authoritative VT snapshot when the delta range is unavailable.
- On launch, the Supervisor matches terminal.sqlite records with authenticated runtime descriptors using TerminalSessionID and WorkerInstanceID. A committed live Keeper is adopted; a record with no Keeper becomes Interrupted; an uncommitted Keeper is never adopted.
- A live Agent CLI has no idle timeout.

When a CLI exits, its Keeper writes the final VT snapshot and immutable scrollback chunks outside the PTY read loop, reports the exit status, and exits. CockpitTerminalSupervisor serves this completed session as a read-only archive without creating another PTY.

### Failure boundary

- Cockpit.app exit: TerminalSession remains live.
- Cockpit.app crash: TerminalSession remains live.
- CockpitHost restart: TerminalSession remains live.
- CockpitTerminalSupervisor restart: all Keepers, PTYs, Agent CLIs, and established local terminal streams remain live.
- CockpitPTYKeeper crash: only that Keeper's TerminalSession becomes Interrupted.
- User logout or macOS restart: all live PTYs end.

## 10. Editor Architecture

EditorRuntime is the only web technology region.

- One WKWebView and Monaco runtime per Cockpit window.
- Multiple Monaco text models share the runtime.
- Native tabs switch the active model.
- No WKWebView per file.
- No React, Electron, local HTTP server, browser router, or web implementation of sidebars.
- Editor assets load from the signed app bundle.

Monaco is the low-latency editing replica. CockpitHost's DocumentActor is the durable recovery authority.

```text
Monaco edit transaction
-> asynchronous ordered edit message
-> DocumentActor applies version
-> recovery journal append
-> LSP didChange
-> acknowledgement(version)
```

Save performs a flush barrier, waits for the Host to receive the current version, atomically replaces the disk file, and returns the new disk fingerprint.

External modification behavior:

- Clean document: reload from disk.
- Dirty document: enter conflict state and block silent overwrite.

Crash recovery guarantees only Host-acknowledged document versions.

## 11. Workspace, Search, Git, and LSP

### File tree

- Lazy directory loading.
- Stable relative paths.
- FSEvents as invalidation input, not final truth.
- Targeted filesystem reconciliation after events.
- Tree patches instead of full reloads.

### Search

- Resident incremental path index for file search.
- ripgrep JSON streaming for content search.
- Query ID on every batch.
- New query cancels the previous process.

### Git

- Repository state is scoped to EnvironmentID.
- Physical repository services are deduplicated when roots are identical.
- `git status --porcelain=v2 -z` supplies status data.
- Diff content is computed lazily.
- Each repository has one mutation queue.
- Mutations include stage, unstage, discard, commit, branch, pull, push, merge, and rebase actions.
- After a failed mutation, Cockpit reports exact stderr and reloads repository state.

### LSP

- Language servers run under CockpitHost.
- Processes are keyed by Environment and deduplicated only when the physical workspace identity matches.
- DocumentActor is the only text-sync source sent to LSP.
- Monaco provider requests are bridged through CockpitClientCore.

## 12. Persistence and Resource Lifecycle

### Storage ownership

- CockpitHost exclusively writes workspace.sqlite.
- CockpitTerminalSupervisor exclusively writes terminal.sqlite.
- Each CockpitPTYKeeper exclusively writes its own runtime descriptor, immutable scrollback chunks, and final VT snapshot.
- Processes never share mutable database ownership.
- Startup reconciliation happens through IPC.

### EnvironmentKernel states

```text
Cold -> Active -> Background -> Evicted
```

- Cold: metadata only.
- Active: at least one attached client.
- Background: no client, but a live terminal or dirty document remains.
- Evicted: reference count is zero and state has been checkpointed.

Resource rules:

- PTY and VT remain while TerminalSession is running.
- A live Agent CLI has no idle timeout.
- Closing a terminal tab or quitting Cockpit.app only detaches the client.
- A completed session is served from its final read-only snapshot and scrollback archive.
- Dirty DocumentSession remains until saved or discarded.
- LSP runs while an editor requires it.
- Search process exists only for a live query.
- Watcher and Git models are shared by canonical root and evicted with WorkspaceKernel.

## 13. Recovery Semantics

| Event | Preserved | Recovery |
|---|---|---|
| Cockpit.app exits or crashes | Host, Supervisor, Keepers, PTYs, CLIs, durable document versions | Reattach to each Keeper and load snapshot plus delta |
| WKWebView crashes | Native UI, services, acknowledged document versions | Recreate Monaco runtime and hydrate models |
| Local stream disconnects | Host and terminal authority | Resume from sequence or replace with snapshot |
| External file change | Disk version and dirty buffer | Reload clean file or enter conflict state |
| CockpitHost crashes | Supervisor, Keepers, and live PTYs | Restart Host and reconcile TerminalSession IDs |
| CockpitTerminalSupervisor crashes | Keepers, PTYs, CLIs, and established local streams | launchd restarts Supervisor; reconcile committed WorkerInstanceIDs |
| One CockpitPTYKeeper crashes | Every other session plus final archives | Mark only the affected TerminalSession Interrupted |
| Remote client disconnects | All Mac-side state | Expire input leases and resynchronize on reconnect |
| User logout or macOS restart | Workspace and final terminal archives | Mark previously live TerminalSessions Interrupted |

Archive and deletion rules:

- Archive hides Conversation but preserves state.
- Delete Conversation first resolves live sessions.
- Delete Conversation never deletes a worktree implicitly.
- Worktree removal is an independent operation that checks local changes.

## 14. Repository and Module Layout

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

Dependency rules:

- CockpitTypes imports no product subsystem.
- CockpitProtocol depends only on CockpitTypes and SwiftProtobuf.
- CockpitClientCore imports no UI framework.
- CockpitHostCore imports no transport implementation.
- CockpitWorkspace and CockpitPersistence implement HostCore interfaces.
- CockpitLocalTransport owns NSXPCConnection and Unix Domain Socket adapters.
- CockpitRemoteTransport owns Network.framework and TLS adapters.
- Composition-root executable targets contain no business logic.

## 15. Pinned Foundation Dependencies

Versions verified on 2026-08-05:

| Component | Version | Source |
|---|---:|---|
| Xcode | 26.6 | local `xcodebuild -version` |
| Swift | 6.3.3 | local `swift --version` |
| Swift tools version | 6.2 | package manifest baseline |
| SwiftProtobuf | 1.38.1 | https://github.com/apple/swift-protobuf/releases/tag/1.38.1 |
| Monaco Editor | 0.55.1 | https://github.com/microsoft/monaco-editor/releases/tag/v0.55.1 |
| esbuild | 0.28.1 | https://github.com/evanw/esbuild/releases/tag/v0.28.1 |
| Ghostty upstream base | v1.3.1 / `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28` | https://github.com/ghostty-org/ghostty/releases/tag/v1.3.1 |
| Zig for Ghostty 1.3.x | 0.15.2 | https://ghostty.org/docs/install/build |
| Node | 25.9.0 | local `node --version` |
| pnpm | 9.15.9 | local `pnpm --version` |
| XcodeGen | 2.46.0 | https://github.com/yonaskolb/XcodeGen/releases/tag/2.46.0 |

Ghostty's official build documentation binds Ghostty 1.3.x to Zig 0.15.2. Cockpit therefore pins Zig 0.15.2 even though Zig 0.16.0 exists.

Phase 0 development identifiers:

```text
dev.cockpit.Cockpit
dev.cockpit.CockpitHost
dev.cockpit.CockpitTerminalSupervisor
dev.cockpit.CockpitPTYKeeper
dev.cockpit.host
dev.cockpit.terminal
```

The release Team ID and public bundle identifiers are distribution settings and do not alter protocol or domain identities.

## 16. Delivery Order

### Phase 0: engineering foundation

- Xcode and SwiftPM structure.
- Stable value types and versioned protocol.
- CockpitClientCore and CockpitHostCore handshakes.
- Four executable composition roots, including the per-session PTYKeeper boundary.
- Local control and frame transport foundations.
- Monaco and Ghostty pinned build inputs.
- Remote transport conformance harness.

### Phase 1: local direct conversation vertical slice

- Add Project.
- Create Direct Conversation.
- File tree.
- Basic Monaco open and save.
- TerminalSupervisor plus per-session PTYKeeper shell and Agent CLI launch.
- App exit, Supervisor crash, and state recovery.

### Phase 2: environment isolation

- Multiple projects and conversations.
- Direct and Worktree environments.
- Atomic ActiveContext switching.
- Cross-environment isolation tests.

### Phase 3: developer tools

- File and content search.
- Git status, diff, stage, commit, and Toolbox operations.
- First Developer Preview.

### Phase 4: editor intelligence

- LSP features, semantic tokens, rename, formatting, code actions, and diff editor.

### Phase 5: remote direct control

- TLS pairing, device grants, input leases, reconnection, and a second Apple-device client.

### Phase 6: productization

- Hardened Runtime, signing, notarization, service upgrades, migration, recovery, security verification, and performance diagnostics.

## 17. Phase Completion Rule

A phase completes only when its end-to-end macOS user flow, Swift unit tests, protocol fixtures, and process integration tests all pass. A collection of isolated modules is not a completed phase.
