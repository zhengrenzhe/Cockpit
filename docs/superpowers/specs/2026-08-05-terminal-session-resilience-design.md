# Cockpit Terminal Session Resilience Design

- Status: Written-spec review requested
- Date: 2026-08-05
- Scope: macOS local terminal lifecycle, crash isolation, and remote-ready attachment
- Priority: stability first, then native terminal throughput and latency

## 1. Decision

Cockpit keeps every live Agent CLI and PTY running after Cockpit.app quits or crashes. Reopening Cockpit reconnects to the same TerminalSession, restores the authoritative Ghostty VT state and scrollback, and resumes input without restarting the Agent CLI.

The lifetime authority is one native CockpitPTYKeeper process per live TerminalSession. CockpitTerminalSupervisor is a launchd-managed control-plane service and never owns PTY master descriptors.

This design replaces the previous shared TerminalService ownership model. The existing Phase 0 implementation plan must not be executed until it is rewritten for the Supervisor and PTYKeeper split.

## 2. Goals

- Normal Command-Q exits the Cockpit UI while live Agent CLI sessions continue.
- Cockpit.app, CockpitHost, and CockpitTerminalSupervisor crashes do not close a live PTY.
- Reopening the App attaches to the original Keeper and sends the current screen immediately.
- A Keeper crash affects exactly one TerminalSession.
- A slow or disconnected client never blocks PTY draining.
- Every running CLI maps to a durable committed TerminalSession record.
- Startup reconciliation never adopts an unauthenticated process.
- The same attachment contract supports future Apple-device clients through CockpitHost.

## 3. Non-goals

- Preserving a live PTY across user logout or macOS restart.
- Recovering a PTY after its owning Keeper crashes.
- Internet relay infrastructure.
- Container or virtual-machine isolation.
- Replacing Agent CLI orchestration with Cockpit logic.
- Shared-memory terminal transport in the first implementation.

## 4. Process Model

### Cockpit.app

Cockpit.app owns AppKit UI, Ghostty Metal surfaces, local keyboard routing, and client view state. It owns no PTY, CLI, project filesystem authority, or terminal lifecycle state.

### CockpitHost

CockpitHost owns Project, Conversation, Environment, files, Git, documents, LSP, remote authorization, and remote stream proxying. It owns no PTY.

### CockpitTerminalSupervisor

CockpitTerminalSupervisor runs as the current user's LaunchAgent with `KeepAlive` enabled. It owns:

- terminal.sqlite and the durable TerminalSession registry;
- two-phase session creation;
- Keeper spawning and reconciliation;
- attach-ticket issuance;
- input-lease coordination;
- completed-session archive serving.

It owns no PTY master, Ghostty parser, live screen state, or live terminal data proxy.

### CockpitPTYKeeper

Each live TerminalSession has one Keeper. It owns:

- one PTY master;
- one Agent CLI or shell process group;
- one Ghostty VT parser and authoritative grid;
- scrollback, snapshots, and frame deltas;
- one authenticated UDS endpoint;
- input ordering, retry deduplication, and viewer backpressure;
- final terminal checkpointing.

The Supervisor spawns each Keeper with `POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT`. The Keeper enters a distinct Unix session and process group, and only declared bootstrap file descriptors are inherited. When the Supervisor exits, the Keeper is reparented to launchd/PID 1 and remains outside the Supervisor's process-group cleanup boundary.

## 5. IPC Topology

### Control plane

```text
Cockpit.app / CockpitHost
    <-> NSXPCConnection
    <-> CockpitTerminalSupervisor
```

The control plane creates, lists, attaches, terminates, reconciles, and archives TerminalSessions. It also issues attach tickets and coordinates input leases.

### Local live data plane

```text
Cockpit.app
    <-> authenticated Unix Domain Socket
    <-> CockpitPTYKeeper
    <-> PTY
    <-> Agent CLI
```

After authorization, Cockpit.app bypasses CockpitHost and CockpitTerminalSupervisor. An established terminal stream remains active while either service restarts.

### Remote live data plane

```text
Remote Apple client
    <-> Network.framework TLS 1.3
    <-> CockpitHost
    <-> authenticated Unix Domain Socket
    <-> CockpitPTYKeeper
```

Neither Supervisor nor Keeper exposes a network listener.

Shared-memory transport is excluded from the initial implementation. It adds crash reclamation, lock-free cursor synchronization, ABI versioning, and snapshot coordination before a UDS bottleneck has been demonstrated.

## 6. Authentication and Endpoint Security

- Runtime UDS directory: `/private/tmp/cockpit.<uid>/terminal`, owner mode `0700`.
- Per-session socket mode: `0600`.
- Keeper verifies the effective peer user through `getpeereid`.
- An installation master key is stored in Keychain.
- The per-worker secret is derived from the master key, TerminalSessionID, and WorkerInstanceID.
- Bootstrap secrets and LaunchSpec cross an inherited private descriptor; they never enter argv or environment variables.
- An attach ticket is single-use and binds TerminalSessionID, client identity, capabilities, and expiry.
- Authentication precedes all screen, input, resize, signal, and termination commands.
- If Keychain is unavailable, Supervisor reconciliation waits without terminating or replacing a live Keeper.

## 7. Lifecycle Model

```text
Preparing -> Committed -> Running
                           |-> Exited
                           |-> Terminated
                           `-> Interrupted
```

- Preparing: the durable record and launch intent exist; no CLI exists.
- Committed: the launch transaction is durable and can be completed after Supervisor restart.
- Running: Keeper, PTY, and CLI are live.
- Exited: CLI ended normally and a final archive exists.
- Terminated: an explicit user command ended the session.
- Interrupted: the Keeper or PTY disappeared unexpectedly.

Viewer attachment is orthogonal state. Closing a tab, quitting Cockpit.app, archiving a Conversation, or losing a remote connection never changes Running.

Live sessions have no idle timeout.

## 8. Two-Phase Session Creation

1. The Supervisor creates TerminalSessionID and WorkerInstanceID.
2. It writes Preparing plus the structured LaunchSpec to terminal.sqlite and commits the transaction.
3. It creates a private bootstrap descriptor and spawns the detached Keeper. The Keeper does not create a PTY or CLI.
4. The Keeper validates bootstrap data, creates its protected runtime endpoint, and reports Ready.
5. The Supervisor records Committed in terminal.sqlite.
6. The Supervisor sends the authenticated Start command.
7. The Keeper creates the PTY and CLI process group, then returns their process identities.
8. The Supervisor records Running and replies to the original idempotent request.

Crash handling at every boundary is deterministic:

- Before Committed: no CLI starts. An uncommitted Keeper exits after a 30-second bootstrap deadline.
- After Committed and before Start: the replacement Supervisor completes Start.
- After Start and before Running is recorded: the replacement Supervisor authenticates the Keeper, verifies WorkerInstanceID, and records Running.
- After Running: Supervisor absence has no effect on the PTY or existing App-to-Keeper stream.

## 9. Reconciliation

On launch, CockpitTerminalSupervisor:

1. Reads committed and running records from terminal.sqlite.
2. Enumerates protected runtime descriptors.
3. Connects to each endpoint and completes an authenticated challenge.
4. Matches TerminalSessionID and WorkerInstanceID.
5. Adopts the exact committed instance.
6. Marks a record without a live Keeper as Interrupted.
7. Rejects every uncommitted or identity-mismatched Keeper.
8. Rebuilds control subscriptions and attach-ticket state.

A new Supervisor performs logical IPC adoption. Unix parent-child relationships are not reassigned.

## 10. Terminal Streams

### Output

The Keeper continuously drains the PTY, updates Ghostty VT state, and advances an authoritative output sequence. Each viewer has its own queue and acknowledgement position.

- Retained delta range available: resume at the next sequence.
- Delta range unavailable: send a current full VT snapshot, then live deltas.
- Slow viewer: coalesce intermediate frames for that viewer.
- Blocked archive writer: retain live VT authority and keep draining the PTY.

Client rendering and archive I/O never block the PTY read loop.

### Input

One TerminalSession has one input lease. Input frames use a monotonically increasing sequence within that lease. The Keeper acknowledges accepted input and deduplicates reconnect retries. Read-only viewers receive output but cannot write input, resize the PTY, send signals, or terminate the session.

## 11. Normal Exit and Explicit Termination

When the CLI exits, the Keeper drains remaining PTY output, stores the exit status, writes the final VT snapshot and immutable scrollback chunks, atomically publishes the final manifest, and exits. The Supervisor serves the completed terminal as a read-only archive without creating another PTY.

Closing a tab or quitting Cockpit.app only detaches the viewer. Deleting a Conversation requires resolving every live TerminalSession first. Deleting a Conversation never removes a Git worktree implicitly.

Explicit session termination targets the complete terminal process group so Agent CLI child processes do not remain behind.

## 12. Failure Matrix

| Failure | Result |
|---|---|
| Cockpit.app quits or crashes | Keeper, PTY, CLI, VT state, and scrollback remain live |
| CockpitHost crashes | Local terminal remains live; remote stream reconnects after Host restart |
| CockpitTerminalSupervisor crashes | Existing local terminal streams remain live; launchd restarts and reconciles control state |
| Monaco WebContent or Ghostty Metal view crashes | Recreate the view and hydrate it from the Keeper snapshot |
| One CockpitPTYKeeper crashes | Only its TerminalSession becomes Interrupted |
| Client consumes output too slowly | Its frames coalesce; PTY draining continues |
| Client disconnects while holding input lease | Keeper releases the disconnected lease; CLI continues |
| User logs out or macOS restarts | Live PTYs end; durable workspace and completed archives remain |

## 13. Acceptance Tests

- Start a deterministic long-running CLI, quit Cockpit.app with Command-Q, continue producing output, reopen the App, and verify the same CLI PID, Keeper PID, TerminalSessionID, output sequence, current screen, scrollback, and input path.
- Kill Cockpit.app and repeat the same identity and state assertions.
- Kill CockpitTerminalSupervisor while a local terminal is active and verify output and input continue without reconnecting the App-to-Keeper socket.
- Relaunch the Supervisor and verify it adopts the original WorkerInstanceID.
- Kill CockpitHost and verify the local terminal remains interactive.
- Run two sessions, kill one Keeper, and verify only that session becomes Interrupted.
- Inject a crash after every two-phase creation step and verify that no CLI exists without a Committed record.
- Disconnect after an input write but before acknowledgement, reconnect, resend, and verify the CLI receives the input once.
- Exhaust a viewer's output budget and verify PTY draining and another viewer continue.
- Replay an attach ticket and verify rejection.
- Present a ticket for another TerminalSessionID and verify rejection.
- Let a CLI exit while the Supervisor is unavailable, restart the Supervisor, and verify the final read-only archive is discovered.

## 14. Implementation Boundary

This specification authorizes a rewritten implementation plan, not implementation. The next plan must replace every CockpitTerminalService composition-root, bundle identifier, LaunchAgent fixture, process integration test, and direct data path with the approved CockpitTerminalSupervisor plus per-session CockpitPTYKeeper model.
