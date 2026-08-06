# Cockpit

Cockpit is a native macOS agent development environment. The Mac owns projects, worktrees, files, Git, language servers, and terminal processes; Apple-platform clients consume the same versioned protocol locally or remotely.

## Phase 0 prerequisites and verification

Phase 0 accepts only paired profiles: Profile A is Node `25.9.0` with pnpm `9.15.9`; Profile B is Node `26.7.0` with pnpm `11.20.0`. `packageManager` remains pnpm 11.20.0 for reproducible lockfile metadata. The aggregate gate requires canonical Profile B for its pnpm install/build/test steps; an ambient Profile A shell must expose local `fnm` with Node 26.7.0 and pnpm 11.20.0. Xcode 26.6 (17F113), Swift 6.3.3, XcodeGen 2.46.0, initialized source packages, Ghostty, and Zig archive/install inputs are required. Verification is offline and validation-only: it invokes Ghostty verification with `--no-bootstrap` and never bootstraps dependencies.

```bash
Tools/verify-phase0.zsh
```

Run `Tools/verify-phase0.zsh` after the pinned Ghostty, Zig archive/compiler, and offline package inputs are present locally. It runs the Phase 0 build and test commands sequentially without downloading or bootstrapping dependencies.

## Phase 0 scope

The app only displays Host and TerminalSupervisor protocol status. Protocol 1.0, local XPC, Keeper crash isolation, TLS 1.3 loopback, app-bundle assembly, and an isolated Monaco bundle exist. Keeper reads the FD 3 bootstrap, writes a runtime descriptor, and stays alive; no real PTY or Agent CLI exists. Ghostty and Zig are pinned source/toolchain inputs only: libghostty is neither built nor linked.

Project and Conversation persistence, attach tickets, session recovery, scrollback, editor integration or persistence, file tree, Git, and LSP are not implemented.

Architecture: `docs/design/2026-08-05-cockpit-architecture.md`
Terminal resilience: `docs/superpowers/specs/2026-08-05-terminal-session-resilience-design.md`
Phase 1 design: `docs/superpowers/specs/2026-08-06-cockpit-phase-1-design.md`
Phase 0 implementation plan: `docs/superpowers/plans/2026-08-05-cockpit-phase-0-implementation.md`
