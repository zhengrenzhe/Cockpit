# Cockpit

Cockpit is a native macOS agent development environment. The Mac owns projects, worktrees, files, Git, language servers, and terminal processes; Apple-platform clients consume the same versioned protocol locally or remotely.

## Phase 1 prerequisites and verification

The unified gate uses canonical Node `26.7.0` with pnpm `11.20.0`; an ambient Node `25.9.0`/pnpm `9.15.9` shell must expose local `fnm` for that canonical profile. Xcode 26.6 (17F113), Swift 6.3.3, XcodeGen 2.46.0, initialized source packages, pinned Ghostty `1.3.2-dev` and Zig `0.16.0` inputs are required. Verification is offline and does not download or bootstrap dependencies.

```bash
Tools/verify-phase1.zsh
```

Run `Tools/verify-phase1.zsh` after those local inputs are present. This is the only Phase 1 aggregate gate.

## Implemented Phase 1 scope

Cockpit implements one direct Project with zero or more Direct Conversations. Project and Conversation contexts share one Environment, file tree and stable DocumentIDs while keeping tabs and TerminalSessions isolated. The native workspace supports file creation, directory creation, rename, move and Trash; Monaco-backed documents preserve UTF-8 BOM and LF/CRLF format, recover acknowledged edits and surface external dirty conflicts.

Shell, Codex and Claude sessions run as durable PTYs through TerminalSupervisor and PTYKeeper. Snapshot/delta, scrollback, input leases, reconnect after App/Host/Supervisor exit, independent Keeper interruption and recoverable Conversation deletion are implemented. Test-only service namespaces isolate LaunchAgents, storage, runtime sockets, Keychain items and preferences without changing production service names or storage domains.

## Not implemented (Phase 2+)

Multiple Projects, Worktrees, Search, Git UI, LSP, remote-network operation, automatic Conversation titles, automatic document saving, CRDT/OT collaboration and general Agent Profiles are not implemented.

Architecture: `docs/design/2026-08-05-cockpit-architecture.md`
Terminal resilience: `docs/superpowers/specs/2026-08-05-terminal-session-resilience-design.md`
Phase 1 design: `docs/superpowers/specs/2026-08-06-cockpit-phase-1-design.md`
Phase 0 implementation plan: `docs/superpowers/plans/2026-08-05-cockpit-phase-0-implementation.md`
