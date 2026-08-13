# Cockpit Phase 2 Worktree Environments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver the confirmed Phase 2 multi-Project and Worktree Environment architecture with durable workspace operations, safe Git execution, atomic context presentation, recoverable deletion, and a complete Phase 2 acceptance gate.

**Architecture:** Keep the existing SwiftPM module boundaries and AppKit application. `CockpitTypes` and `CockpitProtocol` own stable domain/wire contracts, `CockpitHostCore` owns mutation and recovery coordinators, `CockpitPersistence` owns the breaking SQLite baseline, `CockpitWorkspace` owns bookmark/filesystem/Git implementations, `CockpitLocalTransport` owns connection-scoped XPC and data-plane authority, and the App owns staged presentation and user decisions. Every persistent mutation is keyed by a client-generated `WorkspaceOperationID`; every context switch is keyed by a `ContextCommitID`; external Git and filesystem effects are bounded by authenticated identities and durable observations.

**Tech Stack:** Swift 6.3.3, macOS 15.0+, AppKit, Swift Testing, XCTest, SQLite3, SwiftProtobuf 1.38.1, XPC, Unix domain sockets, Darwin `openat`/`posix_spawn`, `/usr/bin/git`, XcodeGen 2.46.0, Node 26.7.0, pnpm 11.20.0.

## Global Constraints

- The authority is `docs/superpowers/specs/2026-08-13-cockpit-phase-2-worktree-environments-design.md`, status `已确认`.
- Phase 2 uses a breaking persistence baseline. Do not migrate, backfill, dual-read, or dual-write Phase 1 workspace/terminal data.
- Host control is exactly 1.2; Host data plane supports strict 1.1 and 1.2 codecs; Terminal/Keeper remains exactly 1.1.
- Keep one main Workspace Window and the existing stable main `WindowID`; do not add multi-window ownership.
- App code never executes Git. All Git mutations run in Host-composed workspace services through `/usr/bin/git`.
- Do not add a package dependency, change `Package.resolved`, modify Ghostty, add Git status/diff/stage/commit UI, add Search/LSP, import external worktrees, relink paths, run `git init`, delete branches, or move existing worktrees.
- Existing Worktree Environments retain the stable capability IDs and relative path frozen at creation; Project Settings only affects future worktrees.
- Use fd-relative, no-follow filesystem operations. Never replace Git worktree removal with `rm -rf`.
- A failed prepare leaves the visible ActiveContext, Monaco, file tree, and terminal presentation unchanged.
- Every behavior change follows RED -> GREEN -> focused regression before the task commit.
- Before every commit, verify `git status --short` contains only that task's listed files; stage those files explicitly and stop on any unrelated path.
- Each task commit uses author `zhengrenzhe <zhengrenzhe0416@outlook.com>`.
- Final completion requires a fresh `Tools/verify-phase2.zsh` exit 0, including a fresh full `Tools/verify-phase1.zsh` pass.

---

## File Map

### Domain and persistence

- `Sources/CockpitTypes/Identifiers.swift`: add stable capability, workspace operation, decision, context commit, prepared token, and recovery identifiers.
- `Sources/CockpitTypes/WorkspacePhase2Models.swift`: Phase 2 Project, Environment, capability, worktree, availability, snapshot, creation, deletion, and typed business-error values.
- `Sources/CockpitTypes/WorkspaceOperationModels.swift`: canonical operation intents, phases, targets, observations, decisions, progress, and replayable results.
- `Sources/CockpitTypes/ContextCommitModels.swift`: prepared token, child plan, authority, commit status, recovery epoch, and presentation acknowledgement values.
- `Sources/CockpitPersistence/WorkspaceMigrations.swift`: replace the Phase 1 chain with one Phase 2 workspace baseline.
- `Sources/CockpitPersistence/TerminalMigrations.swift`: replace the Phase 1 chain with one Phase 2 terminal baseline.
- `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`: retain the repository facade and Direct/document/client-state queries.
- `Sources/CockpitPersistence/SQLiteCapabilityStore.swift`: stable capability and immutable grant-version transactions.
- `Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift`: operation tombstones, live target/capability claims, observations, decisions, and exact CAS transitions.
- `Sources/CockpitPersistence/SQLiteContextCommitStore.swift`: context commit, child journal, recovery epoch, navigation, and presentation transitions.
- `Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift`: session persistence plus prepared/deleting context gates and promotion journal.

### Protocol and transport

- `Sources/CockpitTypes/ProtocolVersion.swift`: independent protocol-family versions and feature minimum versions.
- `Sources/CockpitProtocol/Proto/cockpit.proto`: strict Host-control envelopes, Phase 2 commands/results/errors, target authorization, and data-plane authority oneof.
- `Sources/CockpitProtocol/ProtocolNegotiator.swift`: version-aware feature intersection.
- `Sources/CockpitProtocol/HostControlMessages.swift`: strict envelope and business-error codecs.
- `Sources/CockpitProtocol/HostDataPlaneMessages.swift`: independent 1.1 active binding and 1.2 active/prepared binding codecs.
- `Sources/CockpitLocalTransport/HostConnectionSession.swift`: per-connection handshake state, request cache, capability ownership, and invalidation.
- `Sources/CockpitLocalTransport/HostXPCProtocol.swift`, `HostXPCExport.swift`, `HostXPCClient.swift`: one envelope contract across workspace, ticket, terminal, and archive calls.
- `Sources/CockpitLocalTransport/HostDataPlaneTicket.swift`, `HostDataPlaneServer.swift`, `HostDataPlaneClient.swift`: peer-bound 1.1/1.2 tickets and authority promotion.
- `Sources/CockpitLocalTransport/TerminalSupervisorControlTransport.swift`, `TerminalSupervisorXPCProtocol.swift`, `TerminalSupervisorXPCExport.swift`: Host-issued target authorization and terminal context-gate promotion.

### Host, workspace, and Git

- `Sources/CockpitHostCore/WorkspaceRepository.swift`: Phase 2 repository protocols and persistence-neutral domain inputs.
- `Sources/CockpitHostCore/WorkspaceService.swift`: multi-Project queries and composition of roots, operations, context commits, and availability.
- `Sources/CockpitHostCore/WorkspaceAdmissionCoordinator.swift`: Project/Environment/Document/Terminal admission gates and drain tokens.
- `Sources/CockpitHostCore/EnvironmentRootResolving.swift`: capability-based root-resolution protocol and resolved-root identity contract.
- `Sources/CockpitHostCore/GitRepositoryCoordinating.swift`: typed Git inspection/mutation protocol and repository lock key.
- `Sources/CockpitHostCore/WorktreeCreationCoordinator.swift`: Direct/New Branch/Existing Branch durable creation saga.
- `Sources/CockpitHostCore/ContextCommitCoordinator.swift`: PreparedContextToken validation, durable promotion, child recovery, and supersession.
- `Sources/CockpitHostCore/WorktreeDeletionCoordinator.swift`: decision-driven Conversation deletion and physical worktree saga.
- `Sources/CockpitHostCore/ProjectRemovalCoordinator.swift`: cross-database Project records-only removal saga.
- `Sources/CockpitHostCore/EnvironmentAvailabilityCoordinator.swift`: Git refresh and Available -> Unavailable revocation.
- `Sources/CockpitWorkspace/SecurityScopedProjectRoot.swift`: stable capability import/refresh and access-token lifetime.
- `Sources/CockpitWorkspace/EnvironmentRootResolver.swift`: Direct/Worktree root mapping with identity/incarnation verification.
- `Sources/CockpitWorkspace/DirectoryReservation.swift`: `mkdirat` reservation and authenticated directory descriptor.
- `Sources/CockpitWorkspace/BoundedGitRunner.swift`: `posix_spawn`, output drain, timeout/cancel, PGID authentication, and exact waitpid.
- `Sources/CockpitWorkspace/GitRepositoryCoordinator.swift`: typed Git commands, repository serialization, mutation epoch, and postconditions.
- `Sources/CockpitWorkspace/WorktreeDeletionManifestBuilder.swift`: fd-relative canonical manifest including content, ACL, xattrs, resource forks, flags, and directory digests.
- `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`, `DocumentRegistry.swift`: incarnation-aware kernel registration and deletion reservations.

### App and acceptance

- `Sources/CockpitClientCore/ActiveContextController.swift`: prepared/current/presented commit state instead of immediate generation mutation.
- `Applications/CockpitApp/WorkspacePresentationCoordinator.swift`: hidden child prepare, atomic visible swap, recovery, and presentation acknowledgement.
- `Applications/CockpitApp/WorkspaceViewModel.swift`: multi-Project snapshot, unavailable state, operation IDs, and selection cancellation.
- `Applications/CockpitApp/NewConversationSheetController.swift`: Direct/New Branch/Existing Branch form with exact source/ref inputs.
- `Applications/CockpitApp/ProjectSettingsController.swift`: Project-scoped storage and Git-root capability selection.
- `Applications/CockpitApp/ConversationDeletionController.swift`: pre-begin choices, manifest reconfirmation, records-only continuation, and force decisions.
- `Applications/CockpitApp/ProjectRemovalController.swift`: exact impact display and records-only Project removal.
- `Applications/CockpitApp/ContentHostController.swift`, `FileTreeViewController.swift`, `Monaco/MonacoEditorViewController.swift`, `Terminal/TerminalTabViewController.swift`: staged hidden child lifecycle.
- `Applications/CockpitApp/WorkspaceSidebarController.swift`, `WorkspaceSplitViewController.swift`: multi-Project/Worktree/unavailable presentation and commands.
- `Applications/CockpitProbe/main.swift`: stable JSON commands for every Phase 2 process scenario.
- `Tests/ProcessIntegrationTests/phase2-worktree-environments.zsh`: multi-Project and Worktree creation/isolation/recovery.
- `Tests/ProcessIntegrationTests/phase2-context-promotion.zsh`: prepared context, child recovery, supersession, and unavailable revocation.
- `Tests/ProcessIntegrationTests/phase2-deletion-recovery.zsh`: Conversation/worktree/Project removal and crash replay.
- `Tools/verify-phase2.zsh`: complete Phase 1 gate followed by Phase 2 process and artifact gates.

---

### Task 1: Install the breaking Phase 2 domain and persistence baseline

**Files:**
- Modify: `Sources/CockpitTypes/Identifiers.swift:13-45`
- Create: `Sources/CockpitTypes/WorkspacePhase2Models.swift`
- Create: `Sources/CockpitTypes/WorkspaceOperationModels.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift:64-285`
- Replace: `Sources/CockpitPersistence/WorkspaceMigrations.swift`
- Replace: `Sources/CockpitPersistence/TerminalMigrations.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Create: `Sources/CockpitPersistence/SQLiteCapabilityStore.swift`
- Create: `Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift`
- Modify: `Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceCommandRouter.swift`
- Modify: `Sources/CockpitClientCore/CockpitTransport.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Modify: `Applications/CockpitApp/ProjectCommandController.swift`
- Modify: `Applications/CockpitApp/ConversationCommandController.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Test: `Tests/CockpitTypesTests/WorkspaceModelsTests.swift`
- Test: `Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteTerminalSessionRepositoryTests.swift`

**Interfaces:**
- Produces identifiers: `CapabilityID`, `CapabilityGrantVersionID`, `WorkspaceOperationID`, `WorkspaceDecisionID`, `ContextCommitID`, `PreparedContextTokenID`.
- Produces: `WorkspaceOperationRepository.begin(_:)`, `appendObservation(_:)`, `appendDecision(_:)`, `advance(id:from:to:)`, and `complete(id:result:)`.
- Produces: `CapabilityRepository.importGrant(_:)`, `refreshGrant(_:)`, `retain(_:for:)`, and `release(_:for:)`.
- Preserves Phase 1 Direct behavior through the new tables; legacy rows are neither migrated nor read.

- [ ] **Step 1: Add failing identifier and strict Codable tests**

Add exact round-trip tests for every new ID and reject unknown keys in the new operation/capability models.

```swift
@Test func workspaceOperationIntentRejectsUnknownKeys() throws {
    let data = Data(#"{"version":1,"kind":"renameConversation","title":"x","extra":true}"#.utf8)
    #expect(throws: CockpitDomainValidationError.self) {
        try JSONDecoder().decode(WorkspaceOperationIntent.self, from: data)
    }
}
```

- [ ] **Step 2: Run the exact type tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceModelsTests
```

Expected: compile failure for the six missing identifiers and Phase 2 model types.

- [ ] **Step 3: Add the exact shared identifiers and operation model**

Use the existing `CockpitID` pattern and define the operation union once so every later task shares the same names.

```swift
public typealias CapabilityID = CockpitID<CapabilityScope>
public typealias CapabilityGrantVersionID = CockpitID<CapabilityGrantVersionScope>
public typealias WorkspaceOperationID = CockpitID<WorkspaceOperationScope>
public typealias WorkspaceDecisionID = CockpitID<WorkspaceDecisionScope>
public typealias ContextCommitID = CockpitID<ContextCommitScope>
public typealias PreparedContextTokenID = CockpitID<PreparedContextTokenScope>

public enum WorkspaceOperationKind: String, Codable, Sendable {
    case addProject, updateProjectSettings, createConversation
    case renameConversation, deleteConversation, removeProject
}

public enum WorkspaceOperationPhase: String, Codable, Sendable {
    case prepared, targetReserved, gitRunning, gitAdded, metadataCommitted
    case targetsClaimed, resolvingDocuments, gatingAllContexts, terminatingSessions
    case quiescingEnvironment, quiescingEnvironments, validatingManifest
    case awaitingDecision, removalAuthorized, removingWorktree, worktreeRemoved
    case purgingMetadata, completed, needsAttention
}

public enum EnvironmentKind: String, Codable, Sendable {
    case direct, worktree
}

public enum EnvironmentUnavailableReason: String, Codable, Sendable {
    case projectPathMissing
    case pathMissing
    case worktreeIdentityChanged
    case commonDirectoryIdentityChanged
    case gitRegistrationMissing
    case capabilityIdentityChanged
}

public struct FileSystemIdentity: Hashable, Codable, Sendable {
    public let canonicalResourceIdentity: String
    public let device: UInt64
    public let inode: UInt64
}

public struct WorkspaceOperationBeginRequest: Hashable, Codable, Sendable {
    public let id: WorkspaceOperationID
    public let intent: WorkspaceOperationIntent
    public let targets: [WorkspaceOperationTarget]
    public let capabilityIDs: [CapabilityID]
}

public struct WorkspaceOperationRecord: Hashable, Codable, Sendable {
    public let id: WorkspaceOperationID
    public let kind: WorkspaceOperationKind
    public let requestDigest: String
    public let phase: WorkspaceOperationPhase
    public let intent: WorkspaceOperationIntent
    public let result: WorkspaceOperationResult?
    public let lastError: WorkspaceOperationFailure?
}

public enum WorkspaceOperationFailure: Error, Hashable, Codable, Sendable {
    case idempotencyConflict
    case targetBusy(conflictingOperationID: WorkspaceOperationID)
    case sourceMoved(expectedOID: String, actualOID: String)
    case identityChanged
    case needsAttention(reason: WorkspaceNeedsAttentionReason)
}

public enum WorkspaceNeedsAttentionReason: String, Codable, Sendable {
    case targetIdentityChanged
    case commonDirectoryIdentityChanged
    case ambiguousGitRegistration
    case incompleteCrossStoreGate
}

public enum WorkspaceOperationResult: Hashable, Codable, Sendable {
    case project(ProjectSnapshot)
    case settings(ProjectWorktreeSettings)
    case conversation(ConversationSnapshot)
    case conversationDeleted(ConversationDeletionResult)
    case projectRemoved(ProjectRemovalResult)
}

public enum WorkspaceOperationProgress: Hashable, Codable, Sendable {
    case running(WorkspaceOperationRecord)
    case awaitingDecision(operationID: WorkspaceOperationID, observationSequence: UInt64)
    case completed(WorkspaceOperationResult)
    case needsAttention(operationID: WorkspaceOperationID, error: WorkspaceOperationFailure)
}
```

Move `Project`, `Environment`, `Conversation`, their snapshot values, `ProjectWorktreeSettings`, `GitHead`, `GitLocalBranch`, `GitWorktreeSnapshot`, and the deletion result structs from Host-only declarations into `WorkspacePhase2Models.swift` so persistence, operation results, Git coordination, and Host-control wire use one type definition. `WorkspaceOperationIntent`, `WorkspaceOperationTarget`, `WorkspaceOperationObservation`, and `WorkspaceOperationDecision` are strict versioned enums; their payload cases are the exact Add Project, settings, create, rename, deletion, Project removal, reservation, Git epoch/result, manifest, reconfirm, records-only, and force decisions named by the confirmed design.

- [ ] **Step 4: Write failing baseline-schema tests**

Create fresh workspace and terminal databases, read `sqlite_master`, and assert the exact table/index/trigger set from design section 5. Verify the old `conversation_deletions` schema and the one-Project count guard do not exist. Verify live target uniqueness, composite Conversation/Environment ownership, immutable grant rows, operation tombstone survival after domain-row deletion, and terminal prepared/deleting gates.

```swift
@Test func phase2BaselineKeepsCompletedOperationAfterConversationPurge() async throws {
    let fixture = try await Phase2PersistenceFixture()
    let completed = try await fixture.completeDeleteConversationOperation()
    try await fixture.purgeConversationAndEnvironment()
    #expect(try await fixture.operations.operation(id: completed.id)?.result == completed.result)
}
```

- [ ] **Step 5: Run migration and repository tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceMigrationTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter SQLiteWorkspaceRepositoryTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter SQLiteTerminalSessionRepositoryTests
```

Expected: schema/table assertions fail against the Phase 1 migration chain.

- [ ] **Step 6: Replace both migration chains with the Phase 2 baseline**

Make `WorkspaceMigrations.all` and `TerminalMigrations.all` each contain one version-1 migration. Encode every table, CHECK, deferred foreign key, unique index, and admission trigger from design section 5. The workspace transaction helper must insert the operation tombstone, all live target claims, lifecycle owner, domain changes, replayable result, and `completed` phase atomically for Add Project, Direct Conversation, and rename operations.

```swift
public protocol WorkspaceOperationRepository: Sendable {
    func begin(_ request: WorkspaceOperationBeginRequest) async throws -> WorkspaceOperationRecord
    func appendObservation(_ observation: WorkspaceOperationObservation) async throws
    func appendDecision(_ decision: WorkspaceOperationDecision) async throws
    func advance(
        id: WorkspaceOperationID,
        from expected: WorkspaceOperationPhase,
        to next: WorkspaceOperationPhase
    ) async throws -> WorkspaceOperationRecord
    func complete(
        id: WorkspaceOperationID,
        result: WorkspaceOperationResult
    ) async throws -> WorkspaceOperationRecord
}

public protocol CapabilityRepository: Sendable {
    func importGrant(_ request: CapabilityGrantImport) async throws -> CapabilityGrantReference
    func refreshGrant(_ request: CapabilityGrantRefresh) async throws -> CapabilityGrantReference
    func retain(_ capabilityID: CapabilityID, for reference: CapabilityLiveReference) async throws
    func release(_ capabilityID: CapabilityID, for reference: CapabilityLiveReference) async throws
}

public struct CapabilityGrantImport: Hashable, Sendable {
    public let projectID: ProjectID
    public let kind: CapabilityKind
    public let bookmark: Data
    public let canonicalIdentity: String
}

public typealias CapabilityGrantRefresh = CapabilityGrantImport

public struct CapabilityGrantReference: Hashable, Codable, Sendable {
    public let capabilityID: CapabilityID
    public let grantVersionID: CapabilityGrantVersionID
}

public enum CapabilityKind: String, Codable, Sendable {
    case storageParent, gitRoot
}

public enum CapabilityLiveReference: Hashable, Codable, Sendable {
    case projectSettings(ProjectID)
    case environment(EnvironmentID)
    case operation(WorkspaceOperationID)
}
```

- [ ] **Step 7: Move Direct metadata mutations onto stable operation IDs**

Change the repository/Host-facing Direct methods to require `WorkspaceOperationID`, canonicalize their intent server-side, and return the stored result on identical replay. Update current App and Probe call sites to generate one ID per user action and retain it across retries.

```swift
func addProject(
    operationID: WorkspaceOperationID,
    bookmark: Data,
    displayName: String
) async throws -> ProjectSnapshot

func createDirectConversation(
    operationID: WorkspaceOperationID,
    projectID: ProjectID,
    title: String
) async throws -> Conversation
```

- [ ] **Step 8: Run all focused persistence/type/Host tests GREEN**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitTypesTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitPersistenceTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceServiceTests
```

- [ ] **Step 9: Commit the baseline**

```bash
git add -- Sources/CockpitTypes/Identifiers.swift \
  Sources/CockpitTypes/WorkspacePhase2Models.swift \
  Sources/CockpitTypes/WorkspaceOperationModels.swift \
  Sources/CockpitHostCore/WorkspaceRepository.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitHostCore/WorkspaceCommandRouter.swift \
  Sources/CockpitClientCore/CockpitTransport.swift \
  Sources/CockpitLocalTransport/HostXPCClient.swift \
  Sources/CockpitLocalTransport/HostXPCExport.swift \
  Sources/CockpitPersistence/WorkspaceMigrations.swift \
  Sources/CockpitPersistence/TerminalMigrations.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift \
  Sources/CockpitPersistence/SQLiteCapabilityStore.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift \
  Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift \
  Applications/CockpitApp/ProjectCommandController.swift \
  Applications/CockpitApp/ConversationCommandController.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift Applications/CockpitProbe/main.swift \
  Tests/CockpitTypesTests/WorkspaceModelsTests.swift \
  Tests/CockpitPersistenceTests/WorkspaceMigrationTests.swift \
  Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift \
  Tests/CockpitPersistenceTests/SQLiteTerminalSessionRepositoryTests.swift \
  Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift
git commit -m "feat: install phase 2 workspace baseline"
```

---

### Task 2: Split protocol families and enforce feature minimum versions

**Files:**
- Modify: `Sources/CockpitTypes/ProtocolVersion.swift`
- Modify: `Sources/CockpitProtocol/ProtocolNegotiator.swift`
- Modify: `Sources/CockpitProtocol/WorkspaceMessages.swift`
- Modify: `Sources/CockpitProtocol/HostDataPlaneMessages.swift`
- Modify: `Sources/CockpitProtocol/DocumentMessages.swift`
- Modify: `Sources/CockpitProtocol/TerminalMessages.swift`
- Modify: all `.current` call sites under `Sources`, `Applications`, and `Tests`
- Test: `Tests/CockpitProtocolTests/HandshakeCodecTests.swift`
- Test: `Tests/CockpitProtocolTests/HostDataPlaneProtocolTests.swift`
- Test: `Tests/CockpitProtocolTests/Phase1MessageTests.swift`

**Interfaces:**
- Produces: `HostControlProtocol.current == 1.2`, `HostDataPlaneProtocol.current == 1.2`, `HostDataPlaneProtocol.legacy == 1.1`, `TerminalStreamProtocol.current == 1.1`.
- Produces: `ProtocolFeature.minimumHostControlVersion` and version-aware negotiation.
- Keeps the Host data-plane 1.1 byte contract and Terminal/Keeper 1.1 byte contract unchanged.

- [ ] **Step 1: Write failing family-isolation and raw-feature tests**

```swift
@Test func hostControl11CannotNegotiateRawWorktreeFeature() throws {
    let request = handshake(version: .init(major: 1, minor: 1), features: ["worktree-control"])
    let response = try hostNegotiator.negotiate(request)
    #expect(!response.acceptedFeatures.contains("worktree-control"))
}

@Test func changingHostControlCurrentDoesNotChangeTerminalOrDataPlaneLegacy() {
    #expect(HostControlProtocol.current == .init(major: 1, minor: 2))
    #expect(HostDataPlaneProtocol.legacy == .init(major: 1, minor: 1))
    #expect(TerminalStreamProtocol.current == .init(major: 1, minor: 1))
}
```

- [ ] **Step 2: Run protocol tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HandshakeCodecTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HostDataPlaneProtocolTests
```

Expected: the single global `ProtocolVersion.current` and feature-only intersection violate the new assertions.

- [ ] **Step 3: Introduce protocol-family constants and minimum-version rules**

```swift
public enum HostControlProtocol {
    public static let current = ProtocolVersion(major: 1, minor: 2)
    public static let legacy = ProtocolVersion(major: 1, minor: 1)
}

public enum HostDataPlaneProtocol {
    public static let current = ProtocolVersion(major: 1, minor: 2)
    public static let legacy = ProtocolVersion(major: 1, minor: 1)
}

public enum TerminalStreamProtocol {
    public static let current = ProtocolVersion(major: 1, minor: 1)
}

public extension ProtocolFeature {
    var minimumHostControlVersion: ProtocolVersion {
        self == .worktreeControl ? .init(major: 1, minor: 2) : .init(major: 1, minor: 1)
    }
}
```

Change `ProtocolNegotiator.negotiate` to accept a feature only when requested, supported, and `minimumHostControlVersion <= negotiatedVersion`. Make every codec accept an explicit family version; remove all production uses of a global `.current`.

- [ ] **Step 4: Prove legacy bytes and Phase 1 Direct behavior remain strict**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitProtocolTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter TerminalStreamCoordinatorTests
```

Expected: all protocol suites pass; literal Phase 1 data-plane and Terminal fixtures retain their exact bytes.

- [ ] **Step 5: Commit protocol-family isolation**

```bash
git add -- Sources/CockpitTypes/ProtocolVersion.swift \
  Sources/CockpitProtocol/ProtocolNegotiator.swift \
  Sources/CockpitProtocol/WorkspaceMessages.swift \
  Sources/CockpitProtocol/HostDataPlaneMessages.swift \
  Sources/CockpitProtocol/DocumentMessages.swift Sources/CockpitProtocol/TerminalMessages.swift \
  Sources/CockpitClientCore/ConnectionController.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitLocalTransport/HostXPCClient.swift \
  Sources/CockpitLocalTransport/HostXPCExport.swift \
  Sources/CockpitLocalTransport/KeeperUDSClient.swift \
  Sources/CockpitLocalTransport/KeeperUDSServer.swift \
  Sources/CockpitTerminalCore/TerminalArchiveStore.swift \
  Sources/CockpitTerminalCore/TerminalSupervisor.swift \
  Tests/CockpitProtocolTests/HandshakeCodecTests.swift \
  Tests/CockpitProtocolTests/HostDataPlaneProtocolTests.swift \
  Tests/CockpitProtocolTests/Phase1MessageTests.swift \
  Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift \
  Tests/CockpitLocalTransportTests/HostXPCTests.swift \
  Tests/CockpitLocalTransportTests/KeeperUDSTests.swift \
  Tests/CockpitLocalTransportTests/TerminalSupervisorXPCTests.swift \
  Tests/CockpitPersistenceTests/SQLiteTerminalSessionRepositoryTests.swift \
  Tests/CockpitTerminalCoreTests/ContextTerminationTests.swift \
  Tests/CockpitTerminalCoreTests/TerminalArchiveTests.swift \
  Tests/CockpitTerminalCoreTests/TerminalReconcilerTests.swift
git commit -m "feat: isolate cockpit protocol families"
```

---

### Task 3: Add connection-scoped Host control envelopes and target authorization

**Files:**
- Modify: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Create: `Sources/CockpitProtocol/HostControlMessages.swift`
- Create: `Sources/CockpitLocalTransport/HostConnectionSession.swift`
- Modify: `Sources/CockpitLocalTransport/MachServiceListenerDelegate.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCExport.swift`
- Modify: `Sources/CockpitLocalTransport/HostXPCClient.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceCommandRouter.swift`
- Modify: `Sources/CockpitHostCore/HostHandshakeHandler.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceTerminalService.swift`
- Test: `Tests/CockpitProtocolTests/HandshakeCodecTests.swift`
- Test: `Tests/CockpitLocalTransportTests/HostXPCTests.swift`
- Test: `Tests/CockpitLocalTransportTests/XPCClientTests.swift`
- Test: `Tests/CockpitHostCoreTests/HostHandshakeHandlerTests.swift`

**Interfaces:**
- Produces: `BootstrapResponseEnvelope`, `HostControlRequestEnvelope<Command>`, `HostControlResponseEnvelope<Payload>`, `HostControlBusinessError`, and `TargetAuthorization`.
- Produces actor: `HostConnectionSession.handle(_:) async -> HostControlResponseEnvelope`.
- Every physical XPC connection owns one session and one request cache; no session object is shared across connections.

- [ ] **Step 1: Write failing bootstrap, connection, and duplicate-request tests**

Test all five boundaries: command before handshake, duplicate handshake, old connection ID after reconnect, two simultaneous identical RequestIDs, and identical RequestID with a different canonical digest.

```swift
@Test func duplicateInFlightRequestExecutesRouterOnce() async throws {
    async let first = session.handle(literalCreateEnvelope)
    async let second = session.handle(literalCreateEnvelope)
    let responses = try await [first, second]
    #expect(responses[0] == responses[1])
    #expect(await router.executionCount == 1)
}
```

- [ ] **Step 2: Run Host XPC tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HostXPCTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter XPCClientTests
```

Expected: the current global export accepts method calls without a connection-owned state/cache.

- [ ] **Step 3: Add strict envelope and business-error codecs**

Define protobuf oneofs for bootstrap success/failure and Host-control success/failure. Encode `protocolVersion`, `connectionID`, and `requestID` in every ready-state envelope. Make unknown command/error cases strict decode failures. `NSError` remains restricted to XPC transport, peer validation, and envelope codec failure.

```swift
public enum HostControlBusinessError: Error, Hashable, Codable, Sendable {
    case projectNotGitRepository
    case branchAlreadyCheckedOut(path: String)
    case sourceMoved(expectedOID: String, actualOID: String)
    case worktreeDirty(manifestDigest: String)
    case worktreeManifestChanged(expectedDigest: String, actualDigest: String)
    case worktreeLocked(reason: String)
    case environmentUnavailable(path: String, reason: String)
    case authorizationExpired
    case operationNeedsAttention(WorkspaceOperationID)
    case contextPreparationFailed
    case protocolFeatureNotNegotiated(ProtocolFeature)
    case protocolVersionInsufficient(required: ProtocolVersion, negotiated: ProtocolVersion)
    case targetRequiresWorktreeControl(contextID: WorkspaceContextID, environmentID: EnvironmentID)
    case idempotencyConflict(WorkspaceOperationID)
    case requestIDConflict(RequestID)
    case contextCommitConflict(ContextCommitID)
    case contextRecoveryEpochStale(expected: UInt64, actual: UInt64)
    case superseded(currentContextCommitID: ContextCommitID)
    case operationTargetBusy(WorkspaceOperationID)
    case decisionConflict(WorkspaceDecisionID)
    case unsupportedWorktreeEntry(path: Data, type: String)
    case branchRetained(ref: String, oid: String)
}

public enum HostControlRetryDisposition: String, Codable, Sendable {
    case never, sameRequest, resumeOperation, requiresUserDecision
}

public struct HostControlBusinessFailure: Hashable, Codable, Sendable {
    public let error: HostControlBusinessError
    public let retryDisposition: HostControlRetryDisposition
    public let operationID: WorkspaceOperationID?
    public let contextCommitID: ContextCommitID?
}

public struct NegotiatedSession: Hashable, Sendable {
    public let connectionID: ConnectionID
    public let protocolVersion: ProtocolVersion
    public let features: Set<ProtocolFeature>
    public let peerIdentityDigest: String
}

public struct ResolvedTarget: Hashable, Sendable {
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let environmentKind: EnvironmentKind
    public let incarnation: UUID
}

public struct TargetAuthorization: Hashable, Codable, Sendable {
    public let peerIdentityDigest: String
    public let connectionID: ConnectionID
    public let environmentKind: EnvironmentKind
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let incarnation: UUID
    public let expiresAtUnixMilliseconds: UInt64
}

public protocol HostControlCommandValue: Sendable {}
public protocol HostControlPayloadValue: Sendable {}
```

- [ ] **Step 4: Implement the per-connection state machine and in-flight cache**

```swift
public actor HostConnectionSession {
    public enum State: Sendable {
        case preHandshake
        case ready(NegotiatedSession)
        case invalidated
    }

    public func exchangeHandshake(_ request: CPHandshakeRequest) throws -> BootstrapResponseEnvelope
    public func handle(_ request: HostControlRequestEnvelope) async -> HostControlResponseEnvelope
    public func invalidate() async
}
```

Set `.inFlight(digest, waiters)` before the first `await`. On invalidation, fail waiters, revoke connection-owned prepared tokens/tickets, close cached archive master FDs, and reject all later requests. `MachServiceListenerDelegate` must create this actor and an export per accepted connection.

- [ ] **Step 5: Gate every command by server-owned metadata and resolved target**

Add a static command descriptor table with `minimumHostControlVersion` and required features. Resolve Context/Environment before issuing data-plane, terminal, archive, or client-state authority. Worktree targets require 1.2 plus `workspace-control` and `worktree-control`. Embed peer, connection, target kind, context, environment, incarnation, and expiry in `TargetAuthorization`; Supervisor validates the same values.

```swift
struct HostCommandDescriptor: Sendable {
    let minimumHostControlVersion: ProtocolVersion
    let requiredFeatures: Set<ProtocolFeature>
    let requiresResolvedTarget: Bool
}

func authorize(
    command: HostControlCommand,
    session: NegotiatedSession,
    resolvedTarget: ResolvedTarget?
) throws -> TargetAuthorization?
```

- [ ] **Step 6: Convert Host client/export methods and archive sidecars**

All workspace, ticket, terminal, and archive methods send the common request envelope and receive the common response envelope. For archive replay retain one read-only master FD, validate it, and `dup` a new sidecar per waiter/replay; never cache a previously transferred `FileHandle`.

```swift
func request<Command: HostControlCommandValue, Payload: HostControlPayloadValue>(
    _ command: Command,
    requestID: RequestID,
    expecting: Payload.Type
) async throws -> Payload

func duplicateArchiveHandle(from masterFD: Int32) throws -> FileHandle
```

- [ ] **Step 7: Run transport, Host, and protocol tests GREEN**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitProtocolTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitLocalTransportTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitHostCoreTests
```

- [ ] **Step 8: Commit connection-scoped Host control**

```bash
git add -- Sources/CockpitProtocol/Proto/cockpit.proto \
  Sources/CockpitProtocol/HostControlMessages.swift \
  Sources/CockpitLocalTransport/HostConnectionSession.swift \
  Sources/CockpitLocalTransport/MachServiceListenerDelegate.swift \
  Sources/CockpitLocalTransport/HostXPCProtocol.swift \
  Sources/CockpitLocalTransport/HostXPCExport.swift \
  Sources/CockpitLocalTransport/HostXPCClient.swift \
  Sources/CockpitHostCore/WorkspaceCommandRouter.swift \
  Sources/CockpitHostCore/HostHandshakeHandler.swift \
  Sources/CockpitHostCore/WorkspaceTerminalService.swift \
  Applications/CockpitHost/main.swift Applications/CockpitProbe/main.swift \
  Tests/CockpitProtocolTests/HandshakeCodecTests.swift \
  Tests/CockpitLocalTransportTests/HostXPCTests.swift \
  Tests/CockpitLocalTransportTests/XPCClientTests.swift \
  Tests/CockpitHostCoreTests/HostHandshakeHandlerTests.swift
git commit -m "feat: add connection scoped host control"
```

---

### Task 4: Resolve Environment roots through stable capabilities and incarnations

**Files:**
- Create: `Sources/CockpitHostCore/EnvironmentRootResolving.swift`
- Create: `Sources/CockpitHostCore/WorkspaceAdmissionCoordinator.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift:159-486`
- Modify: `Sources/CockpitWorkspace/SecurityScopedProjectRoot.swift`
- Create: `Sources/CockpitWorkspace/EnvironmentRootResolver.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceModule.swift`
- Modify: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Applications/CockpitHost/main.swift`
- Test: `Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift`
- Test: `Tests/CockpitWorkspaceTests/WorkspaceKernelDataPlaneTests.swift`
- Test: `Tests/CockpitWorkspaceTests/DocumentRegistryTests.swift`
- Test: `Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift`

**Interfaces:**
- Produces: `EnvironmentRootResolver.resolve(environmentID:) async throws -> ResolvedEnvironmentRoot`.
- Produces: `EnvironmentAccessLease`, whose lifetime retains exact stable capability grant versions and security-scoped tokens.
- Produces: `WorkspaceAdmissionCoordinator.reserveProject`, `reserveEnvironment`, and deletion reservation/drain APIs.

- [ ] **Step 1: Write failing Direct/Worktree root and incarnation tests**

Verify a Worktree Context reads from `worktree_root/project_relative_path`, never the Project root; a stale same-identity bookmark appends a grant version; a different identity marks the environment unavailable; and a kernel registration with mismatched incarnation is rejected.

```swift
@Test func worktreeConversationNeverFallsBackToProjectRoot() async throws {
    let resolved = try await resolver.resolve(environmentID: fixture.worktreeEnvironmentID)
    #expect(resolved.workspaceRootPath == fixture.worktreeProjectSubdirectory.path)
    #expect(resolved.workspaceRootIdentity == fixture.worktreeProjectSubdirectoryIdentity)
    #expect(resolved.incarnation == fixture.worktreeIncarnation)
}
```

- [ ] **Step 2: Run focused Workspace/Host tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceKernelDataPlaneTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceServiceTests
```

Expected: `WorkspaceService.resolveContext` registers every Environment from the Project bookmark and kernel identity lacks incarnation.

- [ ] **Step 3: Define the capability-root contract**

```swift
public struct ResolvedEnvironmentRoot: Sendable {
    public let environmentID: EnvironmentID
    public let projectID: ProjectID
    public let kind: EnvironmentKind
    public let workspaceRootPath: String
    public let workspaceRootIdentity: FileSystemIdentity
    public let incarnation: UUID
    public let gitCommonDirectoryPath: String?
    public let gitCommonDirectoryIdentity: FileSystemIdentity?
    public let accessLease: any EnvironmentAccessLease
}

public protocol EnvironmentAccessLease: AnyObject, Sendable {}

public protocol EnvironmentDeletionReservation: AnyObject, Sendable {
    func finish() async
}

public protocol EnvironmentRootResolving: Sendable {
    func resolve(environmentID: EnvironmentID) async throws -> ResolvedEnvironmentRoot
}
```

The implementation loads the Environment and its frozen stable capability IDs, resolves the current immutable grant version, validates physical identity, enters security scope, maps `project_relative_path`, opens the final directory descriptor, and compares stored identity/incarnation before returning.

- [ ] **Step 4: Make kernel and Document admission incarnation-aware**

Key `WorkspaceKernelRegistry` entries by `EnvironmentID` plus incarnation. Re-registration with the same identity/incarnation reuses the kernel; any mismatch revokes the old entry and requires a new kernel. Admission leases reject Project/Environment lifecycle gates and wait for in-flight operations before deletion reservations are granted.

```swift
struct WorkspaceKernelKey: Hashable, Sendable {
    let environmentID: EnvironmentID
    let incarnation: UUID
}

func register(root: ResolvedEnvironmentRoot) async throws -> WorkspaceKernel
func reserveDeletion(environmentID: EnvironmentID) async throws -> EnvironmentDeletionReservation
```

- [ ] **Step 5: Route every Host file/document/terminal root through the resolver**

Replace `registerProject(id:)` calls in context resolution and file operations. `WorkspaceTerminalService` receives only `ResolvedEnvironmentRoot`; terminal create uses its workspace root and incarnation. Delete the code path that reconstructs any Environment from `Project.rootBookmark`.

```swift
let resolved = try await repository.resolve(context.workspaceContextID)
let root = try await environmentRoots.resolve(environmentID: resolved.environmentID)
let kernel = try await kernelRegistry.register(root: root)
return try await kernel.perform(operation, context: context)
```

- [ ] **Step 6: Run focused suites GREEN and commit**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter CockpitWorkspaceTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceServiceTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ContextTerminationTests
```

Then:

```bash
git add -- Sources/CockpitHostCore/EnvironmentRootResolving.swift \
  Sources/CockpitHostCore/WorkspaceAdmissionCoordinator.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitWorkspace/SecurityScopedProjectRoot.swift \
  Sources/CockpitWorkspace/EnvironmentRootResolver.swift \
  Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift \
  Sources/CockpitWorkspace/WorkspaceModule.swift \
  Sources/CockpitWorkspace/DocumentRegistry.swift Applications/CockpitHost/main.swift \
  Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift \
  Tests/CockpitWorkspaceTests/WorkspaceKernelDataPlaneTests.swift \
  Tests/CockpitWorkspaceTests/DocumentRegistryTests.swift \
  Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift \
  Tests/CockpitTerminalCoreTests/ContextTerminationTests.swift
git commit -m "feat: resolve environment scoped roots"
```

---

### Task 5: Return multi-Project snapshots and deterministic availability

**Files:**
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift:5-486`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Sources/CockpitTypes/WorkspacePhase2Models.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift:244-975`
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift:53-351`
- Modify: `Applications/CockpitApp/WorkspaceSplitViewController.swift`
- Test: `Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceViewModelTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceHierarchyTests.swift`

**Interfaces:**
- Replaces the array typealias with `WorkspaceSnapshot(projects:navigationRevision:)`.
- Produces `ProjectSnapshot.environments` and `EnvironmentSnapshot.availability`.
- Produces startup selection order: persisted Context -> Project Context -> first available Project -> Welcome.

- [ ] **Step 1: Write failing multi-Project and partial-unavailability tests**

Insert two Projects and three Environments, make one root identity fail, and assert list returns all Projects while only the affected Environment is unavailable. Add App tests for deterministic startup selection and stable main WindowID.

```swift
@Test func oneUnavailableProjectDoesNotBlockWorkspaceSnapshot() async throws {
    let snapshot = try await service.listWorkspace()
    #expect(snapshot.projects.map(\.projectID) == [fixture.firstProjectID, fixture.secondProjectID])
    #expect(snapshot.projects[0].availability.isAvailable)
    #expect(snapshot.projects[1].availability == .unavailable(reason: fixture.reason))
}
```

- [ ] **Step 2: Run repository, Host, and App tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter SQLiteWorkspaceRepositoryTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceServiceTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/WorkspaceViewModelTests \
  -only-testing:CockpitAppTests/WorkspaceHierarchyTests test
```

Expected: the Phase 1 repository rejects Project two and `listWorkspace` throws when one bookmark fails.

- [ ] **Step 3: Implement a non-failing aggregate snapshot**

Remove the one-Project guard. Load all metadata first; resolve each Project/Environment independently; persist availability reason/incarnation transitions; return unavailable entries in place. Do not hide missing paths and do not auto-delete records.

```swift
public struct WorkspaceSnapshot: Hashable, Codable, Sendable {
    public let projects: [ProjectSnapshot]
    public let navigationRevision: UInt64
}

public enum EnvironmentAvailability: Hashable, Codable, Sendable {
    case available
    case unavailable(path: String, reason: EnvironmentUnavailableReason)
}
```

- [ ] **Step 4: Implement deterministic App restoration**

Load client navigation for the existing main `WindowID`; select the persisted Context only when available, otherwise its Project Context, then the first available Project, otherwise Welcome. Do not create a second window/navigation row. Sidebar selection must reject unavailable items but preserve and label them.

```swift
func restoredContext(from snapshot: WorkspaceSnapshot) -> WorkspaceContextID? {
    if let persisted = snapshot.availablePersistedContext { return persisted }
    if let project = snapshot.availablePersistedProjectContext { return project }
    return snapshot.firstAvailableProjectContext
}
```

- [ ] **Step 5: Run focused tests GREEN and commit**

Run the three commands from Step 2 and then:

```bash
git add -- Sources/CockpitTypes/WorkspacePhase2Models.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitHostCore/WorkspaceRepository.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift \
  Applications/CockpitApp/WorkspaceSidebarController.swift \
  Applications/CockpitApp/WorkspaceSplitViewController.swift \
  Tests/CockpitHostCoreTests/WorkspaceServiceTests.swift \
  Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift \
  Tests/CockpitAppTests/WorkspaceViewModelTests.swift \
  Tests/CockpitAppTests/WorkspaceHierarchyTests.swift
git commit -m "feat: support multiple cockpit projects"
```

---

### Task 6: Build the authenticated bounded Git runner and repository coordinator

**Files:**
- Create: `Sources/CockpitHostCore/GitRepositoryCoordinating.swift`
- Create: `Sources/CockpitWorkspace/DirectoryReservation.swift`
- Create: `Sources/CockpitWorkspace/BoundedGitRunner.swift`
- Create: `Sources/CockpitWorkspace/GitRepositoryCoordinator.swift`
- Test: `Tests/CockpitWorkspaceTests/DirectoryReservationTests.swift`
- Test: `Tests/CockpitWorkspaceTests/BoundedGitRunnerTests.swift`
- Test: `Tests/CockpitWorkspaceTests/GitRepositoryCoordinatorTests.swift`

**Interfaces:**
- Produces: `BoundedGitRunner.run(_:) async throws -> GitCommandResult`.
- Produces: `GitRepositoryCoordinator.withRepositoryLock(identity:_:)` plus inspect/add/remove/refresh methods.
- Produces: operation-owned `DirectoryReservation` with descriptor, device/inode/resource identity, and exact-empty cleanup.

- [ ] **Step 1: Write failing real-Git reservation and Existing Branch tests**

Use a temporary repository with two commits. Test a pre-created empty target, New Branch from an exact source OID, Existing Branch from a validated short name, and postconditions for branch/OID/registration. Mutate the target pathname after reservation and assert Git still writes only through the reservation FD-bound cwd.

```swift
@Test func existingBranchUsesShortArgvAndRemainsAttached() async throws {
    let result = try await coordinator.addWorktree(
        request: fixture.existingBranchRequest(fullRef: "refs/heads/existing")
    )
    #expect(result.head == .branch(fullRef: "refs/heads/existing"))
    #expect(result.oid == fixture.existingTipOID)
}
```

- [ ] **Step 2: Write failing cancellation/output tests**

Launch a fixture executable that fills stdout and stderr concurrently and another that ignores TERM. Assert bounded retained output, no pipe deadlock, TERM -> grace -> KILL, authenticated initial PGID empty, and exact direct-child waitpid. Assert a hook that calls `setpgid` is reported as external and is not globally signalled.

```swift
@Test func cancellationReapsOnlyAuthenticatedInitialProcessGroup() async throws {
    let result = try await fixture.cancelIgnoringTermChildWithDetachedHook()
    #expect(result.directChildWasWaited)
    #expect(result.initialProcessGroupMemberCount == 0)
    #expect(result.detachedHookWasNotSignalled)
}
```

- [ ] **Step 3: Run the new tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter DirectoryReservationTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter BoundedGitRunnerTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter GitRepositoryCoordinatorTests
```

Expected: compile failure because the runner, reservation, and coordinator do not exist.

- [ ] **Step 4: Implement fd-bound directory reservation**

Open the authorized storage parent descriptor, validate it, create the final child with `mkdirat`, open it with `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`, and persist identity before Git starts. Cleanup only when the same descriptor/path identity remains operation-owned and the directory is exactly empty.

```swift
public final class DirectoryReservation: @unchecked Sendable {
    public let absolutePath: String
    public let directoryFD: Int32
    public let identity: FileSystemIdentity
    public let operationID: WorkspaceOperationID
    public func removeIfStillOwnedAndEmpty() throws
}

extension DirectoryReservation: GitTargetReservation {}
```

- [ ] **Step 5: Implement `posix_spawn` execution and bounded drain**

Spawn `/usr/bin/git` with `POSIX_SPAWN_SETSID`, CLOEXEC defaults, stdout/stderr pipes, and a verified direct child whose PID equals initial PGID. For target mutations call `posix_spawn_file_actions_addfchdir_np` on macOS 15-25 and `posix_spawn_file_actions_addfchdir` on macOS 26+, and pass target `.`. Drain both pipes until EOF while retaining fixed byte limits. On cancellation/timeout send TERM then KILL only to the authenticated initial PGID, then exact `waitpid(childPID, ...)` before returning.

```swift
public actor BoundedGitRunner {
    public func run(_ request: GitCommandRequest) async throws -> GitCommandResult
}

private func terminateAndReapAuthenticatedChild(
    pid: pid_t,
    pgid: pid_t,
    auditToken: audit_token_t
) async throws -> Int32
```

- [ ] **Step 6: Implement repository serialization and mutation epoch**

Key actor locks by canonical common-directory identity. Before mutation append a durable `gitMutationEpoch`, fresh-validate the common-directory pathname/identity, then immediately spawn. After Git exits, revalidate common identity, target registration, branch, and OID. Identity mismatch returns `needsAttention` and never compensates by deleting an unknown path/ref.

```swift
public protocol GitRepositoryCoordinating: Sendable {
    func inspect(_ request: GitInspectionRequest) async throws -> GitRepositorySnapshot
    func addWorktree(_ request: GitAddWorktreeRequest) async throws -> GitWorktreeResult
    func removeWorktree(_ request: GitRemoveWorktreeRequest) async throws -> GitWorktreeRemovalResult
    func refresh(_ request: GitRefreshRequest) async throws -> GitWorktreeSnapshot
}
```

Define the consumed values in `GitRepositoryCoordinating.swift` so no caller passes arbitrary argv or paths:

```swift
public struct GitCommandRequest: Sendable {
    public let arguments: [String]
    public let workingDirectoryFD: Int32?
    public let timeout: Duration
    public let retainedOutputLimit: Int
}

public struct GitCommandResult: Hashable, Sendable {
    public let exitStatus: Int32
    public let standardOutput: Data
    public let standardError: Data
}

public struct GitInspectionRequest: Hashable, Sendable {
    public let repository: GitRepositoryIdentity
}

public struct GitRepositoryIdentity: Hashable, Codable, Sendable {
    public let commonDirectoryPath: String
    public let commonDirectoryIdentity: FileSystemIdentity
}

public struct AuthenticatedDirectory: Sendable {
    public let absolutePath: String
    public let directoryFD: Int32
    public let identity: FileSystemIdentity
}

public protocol GitTargetReservation: AnyObject, Sendable {
    var absolutePath: String { get }
    var directoryFD: Int32 { get }
    var identity: FileSystemIdentity { get }
    var operationID: WorkspaceOperationID { get }
}

public struct GitAddWorktreeRequest: Sendable {
    public let repository: GitRepositoryIdentity
    public let reservation: any GitTargetReservation
    public let sourceOID: String
    public let branch: GitWorktreeBranchIntent
}

public enum GitWorktreeBranchIntent: Hashable, Sendable {
    case new(shortName: String, fullRef: String)
    case existing(shortName: String, fullRef: String, expectedTipOID: String)
}

public struct GitRemoveWorktreeRequest: Sendable {
    public let repository: GitRepositoryIdentity
    public let worktreeRoot: AuthenticatedDirectory
    public let force: Bool
}

public struct GitRefreshRequest: Hashable, Sendable {
    public let repository: GitRepositoryIdentity
    public let expectedWorktreeIdentity: FileSystemIdentity
}

public struct GitRepositorySnapshot: Hashable, Sendable {
    public let repository: GitRepositoryIdentity
    public let localBranches: [GitLocalBranch]
    public let worktrees: [GitWorktreeSnapshot]
}

public struct GitWorktreeResult: Hashable, Sendable {
    public let rootIdentity: FileSystemIdentity
    public let head: GitHead
    public let oid: String
}

public enum GitWorktreeRemovalResult: Hashable, Sendable {
    case removed
    case locked(reason: String)
}
```

- [ ] **Step 7: Run real-Git tests GREEN and commit**

Run all three filters from Step 3, then:

```bash
git add -- Sources/CockpitHostCore/GitRepositoryCoordinating.swift \
  Sources/CockpitWorkspace/DirectoryReservation.swift \
  Sources/CockpitWorkspace/BoundedGitRunner.swift \
  Sources/CockpitWorkspace/GitRepositoryCoordinator.swift \
  Tests/CockpitWorkspaceTests/DirectoryReservationTests.swift \
  Tests/CockpitWorkspaceTests/BoundedGitRunnerTests.swift \
  Tests/CockpitWorkspaceTests/GitRepositoryCoordinatorTests.swift
git commit -m "feat: add bounded git repository runner"
```

---

### Task 7: Add Project Worktree Settings and stable capability lifecycle

**Files:**
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitPersistence/SQLiteCapabilityStore.swift`
- Modify: `Sources/CockpitWorkspace/SecurityScopedProjectRoot.swift`
- Create: `Applications/CockpitApp/ProjectSettingsController.swift`
- Modify: `Applications/CockpitApp/ProjectCommandController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
- Test: `Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift`
- Test: `Tests/CockpitAppTests/ProjectCommandControllerTests.swift`

**Interfaces:**
- Produces `WorkspaceServing.projectWorktreeSettings(projectID:)` and `updateProjectWorktreeSettings(operationID:projectID:selection:)`.
- Produces `ProjectSettingsController.present(project:) async throws -> ProjectWorktreeSettings?`.
- Reuses stable capability IDs on equal physical identity and only appends immutable grant versions.

- [ ] **Step 1: Write failing capability reuse, refresh, and retention tests**

Test four exact transitions: first selection creates two stable capabilities; same identity adds grant versions without changing IDs; different storage identity changes only future settings; capability deletion is rejected while referenced by settings/Environment/live operation and succeeds after the final reference is released.

```swift
@Test func sameIdentityRefreshKeepsStableCapabilityID() async throws {
    let first = try await store.importGrant(fixture.firstGrant)
    let refreshed = try await store.refreshGrant(fixture.sameIdentityReplacement)
    #expect(refreshed.capabilityID == first.capabilityID)
    #expect(refreshed.grantVersionID != first.grantVersionID)
}
```

- [ ] **Step 2: Run focused persistence/App tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter SQLiteWorkspaceRepositoryTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/ProjectCommandControllerTests test
```

Expected: no settings command/controller exists and capability identity is still a Project bookmark field.

- [ ] **Step 3: Implement stable capability transactions**

Import the client bookmark, resolve canonical identity under security scope, and perform one transaction that finds or inserts `(project_id, kind, canonical_identity)`, inserts a new immutable grant version, and updates `current_grant_version_id`. Reject a refresh when project/kind/identity differs. Keep live capability references in `workspace_operation_capabilities`; remove them only at operation completion/needsAttention resolution.

```swift
let reference = try await capabilities.importGrant(
    CapabilityGrantImport(
        projectID: projectID,
        kind: .storageParent,
        bookmark: bookmark,
        canonicalIdentity: resolvedIdentity
    )
)
try await capabilities.retain(reference.capabilityID, for: .projectSettings(projectID))
```

- [ ] **Step 4: Implement the native settings sheet**

Show current storage parent and Git root summaries. `Choose…` uses `NSOpenPanel` for directories. For a Project nested below the Git root, show the detected repository root and require explicit confirmation before returning both bookmarks plus `projectRelativePath`. Cancel has no Host mutation. Non-Git Projects show Worktree modes disabled and never call `git init`.

```swift
struct ProjectWorktreeSettingsSelection: Sendable {
    let storageParentBookmark: Data
    let gitRootBookmark: Data
    let projectRelativePath: RelativePath?
}
```

- [ ] **Step 5: Add Probe settings commands and exact JSON assertions**

Add `project settings show` and `project settings update` commands. JSON returns only IDs, paths, relative path, and capability kinds; bookmark bytes never appear in the envelope.

```json
{
  "projectID": "00000000-0000-0000-0000-000000000001",
  "storageParentCapabilityID": "00000000-0000-0000-0000-000000000002",
  "gitRootCapabilityID": "00000000-0000-0000-0000-000000000003",
  "projectRelativePath": "Sources"
}
```

- [ ] **Step 6: Run focused tests GREEN and commit**

Run the commands from Step 2 plus `Tests/ProcessIntegrationTests/probe-json.zsh`, then:

```bash
git add -- Sources/CockpitHostCore/WorkspaceRepository.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitPersistence/SQLiteCapabilityStore.swift \
  Sources/CockpitWorkspace/SecurityScopedProjectRoot.swift \
  Applications/CockpitApp/ProjectSettingsController.swift \
  Applications/CockpitApp/ProjectCommandController.swift \
  Applications/CockpitApp/WorkspaceSidebarController.swift Applications/CockpitProbe/main.swift \
  Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift \
  Tests/CockpitWorkspaceTests/WorkspaceRootHandleTests.swift \
  Tests/CockpitAppTests/ProjectCommandControllerTests.swift \
  Tests/ProcessIntegrationTests/probe-json.zsh
git commit -m "feat: add project worktree settings"
```

---

### Task 8: Implement Direct, New Branch, and Existing Branch creation sagas

**Files:**
- Create: `Sources/CockpitHostCore/WorktreeCreationCoordinator.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceRepository.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Sources/CockpitWorkspace/GitRepositoryCoordinator.swift`
- Create: `Applications/CockpitApp/NewConversationSheetController.swift`
- Modify: `Applications/CockpitApp/ConversationCommandController.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Test: `Tests/CockpitHostCoreTests/WorktreeCreationCoordinatorTests.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
- Test: `Tests/CockpitWorkspaceTests/GitRepositoryCoordinatorTests.swift`
- Test: `Tests/CockpitAppTests/ConversationCommandControllerTests.swift`
- Test: `Tests/ProcessIntegrationTests/probe-json.zsh`

**Interfaces:**
- Produces: `WorkspaceServing.prepareConversationCreation(projectID:)`.
- Produces: `WorkspaceServing.createConversation(operationID:intent:) async throws -> WorkspaceOperationProgress`.
- Produces: `WorktreeCreationCoordinator.run(operationID:)` and `recoverNonterminalOperations()`.
- `Existing Branch` stores a full local ref and tip OID but passes only a validated canonical short name to Git.

- [ ] **Step 1: Write failing intent and source-freeze tests**

Cover Direct, New Branch, and Existing Branch canonical digests. Assert Existing Branch rejects `startFrom`; occupied branches are disabled; source OID and selected branch tip changes produce `sourceMoved`; same operation/digest replays the same IDs; same operation/different digest produces `idempotencyConflict`.

```swift
@Test func existingBranchIntentHasNoStartFromAndFreezesTip() throws {
    let intent = try ConversationCreationIntent.existingBranch(
        projectID: projectID,
        title: "Existing",
        fullRef: "refs/heads/existing",
        selectedTipOID: literalOID,
        storageParentCapabilityID: storageID,
        gitRootCapabilityID: gitID,
        projectRelativePath: nil
    )
    guard case let .existingBranch(value) = intent else {
        Issue.record("Expected Existing Branch intent")
        return
    }
    #expect(value.selectedTipOID == literalOID)
}
```

- [ ] **Step 2: Write failing crash-matrix tests**

Inject a stop after each durable phase: `prepared`, `targetReserved`, `gitRunning`, `gitAdded`, and `metadataCommitted`. Restart the coordinator and assert it returns the same ConversationID/EnvironmentID/result, preserves created branch/worktree after Git started, and enters `needsAttention` rather than deleting when identity cannot be proven.

```swift
for phase in [
    WorkspaceOperationPhase.prepared, .targetReserved, .gitRunning,
    .gitAdded, .metadataCommitted,
] {
    let first = try await fixture.runUntil(phase: phase)
    let recovered = try await fixture.restartAndResume(operationID: first.id)
    #expect(recovered == .completed(fixture.expectedResult))
}
```

- [ ] **Step 3: Run focused creation tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorktreeCreationCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter GitRepositoryCoordinatorTests
```

Expected: compile failure because the creation coordinator and Worktree intents do not exist.

- [ ] **Step 4: Implement preparation and immutable intent capture**

Under the repository lock, resolve the Project Git identity, settings capability IDs, source full OID, Existing Branch full ref/tip/occupancy, canonical target name, and `project_relative_path`. Store only the immutable intent and live capability/Project claims. New Branch derives the default slug and deterministic `-2`, `-3` conflict suffix before begin.

```swift
public enum ConversationCreationIntent: Hashable, Codable, Sendable {
    case direct(projectID: ProjectID, title: String)
    case newBranch(NewBranchConversationIntent)
    case existingBranch(ExistingBranchConversationIntent)
}

public struct NewBranchConversationIntent: Hashable, Codable, Sendable {
    public let projectID: ProjectID
    public let title: String
    public let branchShortName: String
    public let branchFullRef: String
    public let sourceOID: String
    public let storageParentCapabilityID: CapabilityID
    public let gitRootCapabilityID: CapabilityID
    public let projectRelativePath: RelativePath?
}

public struct ExistingBranchConversationIntent: Hashable, Codable, Sendable {
    public let projectID: ProjectID
    public let title: String
    public let branchShortName: String
    public let branchFullRef: String
    public let selectedTipOID: String
    public let storageParentCapabilityID: CapabilityID
    public let gitRootCapabilityID: CapabilityID
    public let projectRelativePath: RelativePath?
}

public protocol WorktreeCreationCoordinating: Sendable {
    func create(
        operationID: WorkspaceOperationID,
        intent: ConversationCreationIntent
    ) async throws -> WorkspaceOperationProgress
    func resume(operationID: WorkspaceOperationID) async throws -> WorkspaceOperationProgress
}
```

- [ ] **Step 5: Implement Git and metadata phase transitions**

For Worktree modes: reserve the final target through `DirectoryReservation`; append its identity observation and CAS `targetReserved`; append/fresh-check `gitMutationEpoch`; CAS `gitRunning`; invoke fd-cwd Git add; verify common directory, registration, branch/detached state, and exact source OID; CAS `gitAdded`; verify the Project subdirectory; then one deferred SQLite transaction inserts Environment, WorktreeEnvironment, Conversation, client defaults, replayable result, and `metadataCommitted`; finally mark `completed`. Direct creation is one metadata transaction using the same operation ID.

```swift
let reservation = try directoryReservations.reserve(target, operationID: operationID)
try await operations.appendObservation(.targetReserved(operationID, reservation.identity))
_ = try await operations.advance(id: operationID, from: .prepared, to: .targetReserved)
let gitResult = try await git.addWorktree(request)
try verify(gitResult, against: intent)
return try await repository.commitWorktreeConversation(
    operationID: operationID,
    gitResult: gitResult
)
```

- [ ] **Step 6: Implement deterministic recovery without destructive compensation**

At Host startup scan nonterminal creation operations. Before Git starts, an exact-empty owned reservation can be removed. After `gitRunning`, never delete a branch, worktree, or unknown path. Reinspect and advance when postconditions match; otherwise append the observation and enter `needsAttention`.

```swift
for operation in try await operations.nonterminal(kind: .createConversation) {
    switch operation.phase {
    case .prepared, .targetReserved: try await recoverBeforeGit(operation)
    case .gitRunning, .gitAdded, .metadataCommitted: try await recoverAfterGit(operation)
    default:
        throw WorkspaceOperationFailure.needsAttention(reason: .ambiguousGitRegistration)
    }
}
```

- [ ] **Step 7: Implement the native New Conversation sheet**

Use a three-segment control. Direct shows title only. New Branch shows title, editable branch name, Start From rows with branch/detached label and short OID, and dirty-source warning. Existing Branch shows local branches, disables occupied rows with their paths, and omits Start From. First Worktree creation with missing settings invokes the Project Settings sheet; cancel ends creation without an operation.

```swift
enum NewConversationMode: Int, CaseIterable {
    case direct, newBranch, existingBranch
}

func submit() async throws -> ConversationCreationIntent? {
    guard let selection = validatedSelection else { return nil }
    return selection.intent
}
```

- [ ] **Step 8: Add Probe commands and run focused tests GREEN**

Add `conversation prepare-create`, `conversation create --mode direct|new-branch|existing-branch`, and `operation inspect/resume`. Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorktreeCreationCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter GitRepositoryCoordinatorTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/ConversationCommandControllerTests test
Tests/ProcessIntegrationTests/probe-json.zsh
```

- [ ] **Step 9: Commit Worktree creation**

```bash
git add -- Sources/CockpitHostCore/WorktreeCreationCoordinator.swift \
  Sources/CockpitHostCore/WorkspaceRepository.swift Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift \
  Sources/CockpitWorkspace/GitRepositoryCoordinator.swift \
  Applications/CockpitApp/NewConversationSheetController.swift \
  Applications/CockpitApp/ConversationCommandController.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift Applications/CockpitProbe/main.swift \
  Tests/CockpitHostCoreTests/WorktreeCreationCoordinatorTests.swift \
  Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift \
  Tests/CockpitWorkspaceTests/GitRepositoryCoordinatorTests.swift \
  Tests/CockpitAppTests/ConversationCommandControllerTests.swift \
  Tests/ProcessIntegrationTests/probe-json.zsh
git commit -m "feat: create worktree conversations"
```

---

### Task 9: Add PreparedContextToken and durable context/child journals

**Files:**
- Create: `Sources/CockpitTypes/ContextCommitModels.swift`
- Modify: `Sources/CockpitTypes/WorkspacePhase2Models.swift`
- Modify: `Sources/CockpitProtocol/Proto/cockpit.proto`
- Modify: `Sources/CockpitProtocol/HostDataPlaneMessages.swift`
- Create: `Sources/CockpitPersistence/SQLiteContextCommitStore.swift`
- Create: `Sources/CockpitHostCore/ContextCommitCoordinator.swift`
- Modify: `Sources/CockpitLocalTransport/HostDataPlaneTicket.swift`
- Modify: `Sources/CockpitLocalTransport/HostDataPlaneServer.swift`
- Modify: `Sources/CockpitLocalTransport/HostDataPlaneClient.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Test: `Tests/CockpitTypesTests/WorkspaceModelsTests.swift`
- Test: `Tests/CockpitProtocolTests/HostDataPlaneProtocolTests.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift`
- Test: `Tests/CockpitHostCoreTests/ContextCommitCoordinatorTests.swift`
- Test: `Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift`

**Interfaces:**
- Produces: `prepareContext`, `commitPreparedContext`, `contextCommitStatus`, `completeContextRecovery`, and `presentationCommitted` Host commands.
- Produces data-plane 1.2 `HostDataPlaneAuthority.active` and `.prepared`; 1.1 remains active-only.
- Produces durable `context_commits`, `context_commit_children`, and `client_window_navigation` transitions.

- [ ] **Step 1: Write failing strict-authority codec tests**

Assert data-plane 1.2 encodes exactly one of active/prepared authority, prepared includes token/proposed generation/incarnation, and data-plane 1.1 rejects every 1.2-only field.

```swift
@Test func legacyDataPlaneRejectsPreparedAuthority() throws {
    let encoded12 = try HostDataPlaneMessages.encode(
        binding: fixture.preparedBinding,
        version: HostDataPlaneProtocol.current
    )
    #expect(throws: ProtocolMappingError.self) {
        try HostDataPlaneMessages.decodeBinding(
            encoded12,
            version: HostDataPlaneProtocol.legacy
        )
    }
}
```

- [ ] **Step 2: Write failing commit-journal crash/reply-loss tests**

Test durable commit before children, reply loss, recovery epoch increment after ticket invalidation, old epoch rejection, committed-unavailable fallback, and predecessor supersession. Assert a prepared token is bound to issuer connection/peer and cannot survive connection invalidation before durable commit.

```swift
@Test func durableCommitReplyLossReturnsSameRecoveryPlan() async throws {
    let first = try await fixture.commitAndDropReply()
    let recovered = try await coordinator.status(contextCommitID: first.contextCommitID)
    #expect(recovered == .committedNeedsChildren(
        recoveryEpoch: first.recoveryEpoch,
        plan: first.childPlan
    ))
}
```

- [ ] **Step 3: Run protocol/persistence/coordinator tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HostDataPlaneProtocolTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ContextCommitCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HostDataPlaneTests
```

Expected: Host data-plane has only `activeContextGeneration`, and no context journal/coordinator exists.

- [ ] **Step 4: Define the shared prepared/commit contract**

```swift
public struct PreparedContextToken: Hashable, Codable, Sendable {
    public let id: PreparedContextTokenID
    public let contextCommitID: ContextCommitID
    public let issuerConnectionID: ConnectionID
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let incarnation: UUID
    public let proposedGeneration: UInt64
    public let stateRevision: UInt64
}

public enum ContextChildKind: String, Codable, Sendable {
    case kernel, fileTree, document, terminal
}

public struct ContextChildPlan: Hashable, Codable, Sendable {
    public let childID: UUID
    public let kind: ContextChildKind
    public let capabilityID: String
    public let authority: HostDataPlaneAuthority?
}

public enum HostDataPlaneAuthority: Hashable, Codable, Sendable {
    case active(generation: UInt64, incarnation: UUID)
    case prepared(
        tokenID: PreparedContextTokenID,
        proposedGeneration: UInt64,
        incarnation: UUID
    )
}

public enum ContextCommitStatus: Hashable, Codable, Sendable {
    case notCommitted
    case committedNeedsChildren(recoveryEpoch: UInt64, plan: [ContextChildPlan])
    case committedReady(ActiveContext)
    case committedUnavailable(EnvironmentAvailability)
    case superseded(currentContextCommitID: ContextCommitID)
}

public struct ContextPrepareRequest: Hashable, Codable, Sendable {
    public let contextCommitID: ContextCommitID
    public let predecessorContextCommitID: ContextCommitID?
    public let contextID: WorkspaceContextID
    public let windowID: WindowID
}

public struct ContextCommitRequest: Hashable, Codable, Sendable {
    public let tokenID: PreparedContextTokenID
    public let contextCommitID: ContextCommitID
    public let expectedStateRevision: UInt64
}

public struct ContextChildReadyProof: Hashable, Codable, Sendable {
    public let childID: UUID
    public let kind: ContextChildKind
    public let peerIdentityDigest: String
    public let connectionID: ConnectionID
    public let authority: HostDataPlaneAuthority
}

public struct ContextRecoveryCompletion: Hashable, Codable, Sendable {
    public let contextCommitID: ContextCommitID
    public let recoveryEpoch: UInt64
    public let childProofs: [ContextChildReadyProof]
}

public struct ContextPresentationAcknowledgement: Hashable, Codable, Sendable {
    public let contextCommitID: ContextCommitID
    public let windowID: WindowID
}
```

- [ ] **Step 5: Implement invisible prepare and durable promotion**

Prepare resolves a fresh fd-backed Environment root, allocates proposed generation, registers a prepared Kernel, and issues peer/connection-bound prepared child tickets without changing navigation or visible state. Commit performs one SQLite transaction validating token/admission/current predecessor, inserts `context_commits(durablePendingChildren)`, inserts the complete child journal, updates navigation current commit/context/environment/generation, and marks the generation committed.

```swift
public protocol ContextCommitCoordinating: Sendable {
    func prepare(_ request: ContextPrepareRequest) async throws -> PreparedContextToken
    func commit(_ request: ContextCommitRequest) async throws -> ContextCommitStatus
    func status(contextCommitID: ContextCommitID) async throws -> ContextCommitStatus
    func completeRecovery(_ request: ContextRecoveryCompletion) async throws -> ContextCommitStatus
    func presentationCommitted(_ request: ContextPresentationAcknowledgement) async throws
}
```

- [ ] **Step 6: Implement data-plane child promotion and recovery epochs**

Data-plane child state is `prepared -> promoting -> active`. During promoting, only authority control frames flow. Server emits `authorityPromoted`; client switches binding and acks; server marks child active. Context status returns a deterministic child plan and epoch when child recovery is required. `completeContextRecovery` validates each proof's peer, connection, logical child, active authority, and journal before CAS to `childrenActive`.

```swift
public enum HostDataPlaneAuthorityState: Hashable, Sendable {
    case prepared(HostDataPlaneAuthority)
    case promoting(HostDataPlaneAuthority)
    case active(HostDataPlaneAuthority)
    case revoked
}

func acknowledgeAuthorityPromotion(
    connectionID: ConnectionID,
    contextCommitID: ContextCommitID,
    recoveryEpoch: UInt64
) async throws
```

- [ ] **Step 7: Run focused suites GREEN and commit**

Run the commands from Step 3 plus:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter SQLiteWorkspaceRepositoryTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorkspaceKernelDataPlaneTests
```

Then:

```bash
git add -- Sources/CockpitTypes/ContextCommitModels.swift \
  Sources/CockpitTypes/WorkspacePhase2Models.swift \
  Sources/CockpitProtocol/Proto/cockpit.proto \
  Sources/CockpitProtocol/HostDataPlaneMessages.swift \
  Sources/CockpitPersistence/SQLiteContextCommitStore.swift \
  Sources/CockpitHostCore/ContextCommitCoordinator.swift \
  Sources/CockpitLocalTransport/HostDataPlaneTicket.swift \
  Sources/CockpitLocalTransport/HostDataPlaneServer.swift \
  Sources/CockpitLocalTransport/HostDataPlaneClient.swift \
  Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift \
  Tests/CockpitTypesTests/WorkspaceModelsTests.swift \
  Tests/CockpitProtocolTests/HostDataPlaneProtocolTests.swift \
  Tests/CockpitPersistenceTests/SQLiteWorkspaceRepositoryTests.swift \
  Tests/CockpitHostCoreTests/ContextCommitCoordinatorTests.swift \
  Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift \
  Tests/CockpitWorkspaceTests/WorkspaceKernelDataPlaneTests.swift
git commit -m "feat: add durable context preparation"
```

---

### Task 10: Stage Monaco, file tree, and terminal children before visible context swap

**Files:**
- Modify: `Sources/CockpitClientCore/ActiveContextController.swift:3-30`
- Modify: `Sources/CockpitTerminalClient/TerminalAttachmentController.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSupervisor.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSessionRepository.swift`
- Modify: `Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorControlTransport.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift`
- Create: `Applications/CockpitApp/WorkspacePresentationCoordinator.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Modify: `Applications/CockpitApp/ContentHostController.swift`
- Modify: `Applications/CockpitApp/FileTreeViewController.swift`
- Modify: `Applications/CockpitApp/Monaco/MonacoEditorViewController.swift`
- Modify: `Applications/CockpitApp/Terminal/TerminalTabViewController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSplitViewController.swift`
- Test: `Tests/CockpitClientCoreTests/ActiveContextControllerTests.swift`
- Test: `Tests/CockpitTerminalClientTests/TerminalAttachmentControllerTests.swift`
- Test: `Tests/CockpitTerminalCoreTests/TerminalSupervisorTwoPhaseTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceViewModelTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceHierarchyTests.swift`

**Interfaces:**
- Produces: `PreparedClientContext`, `StagedWorkspacePresentation`, and `WorkspacePresentationCoordinator.select(_:)`.
- Produces terminal prepared-registration/promotion journal without changing Terminal/Keeper 1.1 wire.
- Visible state changes only after Host reports `committedReady` and all hidden child controllers report ready.

- [ ] **Step 1: Write failing no-visible-change and A/B/C tests**

Assert target file tree, Monaco, and terminal prepare remain hidden; any prepare/commit/child failure leaves old visible controllers and old ActiveContext unchanged. Add A-visible/B-durable-not-presented/C-supersedes-B and assert `presentationCommitted(C)` releases A and B, while old IDs return `superseded(C)`.

```swift
@MainActor
func testFailedPreparedTerminalLeavesOldPresentationUntouched() async throws {
    let old = harness.visibleSnapshot
    harness.nextTerminalPrepareResult = .failure(TestError.attach)
    await XCTAssertThrowsErrorAsync {
        try await harness.presentation.select(fixture.targetContextID)
    }
    XCTAssertEqual(harness.visibleSnapshot, old)
    XCTAssertEqual(await harness.activeContexts.current(), fixture.oldActiveContext)
}
```

- [ ] **Step 2: Run client/terminal/App tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ActiveContextControllerTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter TerminalSupervisorTwoPhaseTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/WorkspaceViewModelTests \
  -only-testing:CockpitAppTests/WorkspaceHierarchyTests test
```

Expected: `ActiveContextController.select` mutates immediately and App child controllers publish during prepare.

- [ ] **Step 3: Replace immediate selection with prepared/current/presented state**

```swift
public actor ActiveContextController {
    public func beginPreparation(_ token: PreparedContextToken) throws -> PreparedClientContext
    public func recordDurableCommit(_ active: ActiveContext, commitID: ContextCommitID) throws
    public func recordPresented(commitID: ContextCommitID) throws
    public func abortPreparation(tokenID: PreparedContextTokenID)
    public func current() -> ActiveContext?
}
```

Generation remains unchanged until durable commit. A stale selection request checks its request generation after every await and aborts only its own prepared token/hidden children.

- [ ] **Step 4: Add hidden staging APIs to all three child families**

Monaco prepares document controllers and model references without calling visible select. File tree opens the 1.2 prepared data-plane subscription without installing its view model. Terminal consumes the Host/Supervisor prepared registration and attaches without showing its view. Each staged object has exact `commitVisibility()` and `abort()` methods; abort closes subscriptions/viewers/attachments it created.

```swift
@MainActor
struct PreparedClientContext: Sendable {
    let token: PreparedContextToken
    let requestGeneration: UInt64
}

@MainActor
protocol StagedChildPresentation: AnyObject {
    func commitVisibility()
    func abort()
}

@MainActor
struct StagedWorkspacePresentation {
    let commitID: ContextCommitID
    let activeContext: ActiveContext
    let monaco: any StagedChildPresentation
    let fileTree: any StagedChildPresentation
    let terminals: [any StagedChildPresentation]
    let commitVisibility: @MainActor () -> Void
    let abort: @MainActor () -> Void
}
```

- [ ] **Step 5: Add Supervisor terminal authority promotion journal**

Host registers prepared terminal authorization with ContextCommitID/token/incarnation/target authorization. Supervisor validates it, issues normal Terminal 1.1 Keeper tickets, journals prepared attachment identity, and promotes its owner to active on commit. Crash recovery verifies Keeper attachment identity or asks the App recovery plan to recreate it. Token invalidation only detaches children still prepared.

```swift
public struct TerminalAuthorizationRegistration: Hashable, Codable, Sendable {
    public let contextCommitID: ContextCommitID
    public let tokenID: PreparedContextTokenID
    public let incarnation: UUID
    public let targetAuthorization: TargetAuthorization
    public let attachmentID: UUID
}

func registerPreparedAuthorization(_ value: TerminalAuthorizationRegistration) async throws
func promoteAuthorization(contextCommitID: ContextCommitID, attachmentID: UUID) async throws
```

- [ ] **Step 6: Implement visible swap and predecessor release**

`WorkspacePresentationCoordinator` prepares hidden children, requests durable commit, completes missing children for the returned recovery epoch, waits for `committedReady`, commits all child visibility in one MainActor turn, updates `ActiveContextController`, and sends `presentationCommitted`. Host atomically updates `presented_context_commit_id` and marks all predecessors between old presented and new current `revoking`; recovery drains them to `released`.

```swift
@MainActor
func select(_ contextID: WorkspaceContextID) async throws -> ActiveContext {
    let staged = try await prepareHiddenPresentation(contextID)
    do {
        let active = try await finishDurableCommitAndChildren(staged)
        staged.commitVisibility()
        try await host.presentationCommitted(.init(
            contextCommitID: staged.commitID,
            windowID: windowID
        ))
        return active
    } catch {
        staged.abort()
        throw error
    }
}
```

- [ ] **Step 7: Run focused suites GREEN and commit**

Run all commands from Step 2 plus:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter TerminalAttachmentControllerTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HostDataPlaneTests
```

Then:

```bash
git add -- Sources/CockpitClientCore/ActiveContextController.swift \
  Sources/CockpitTerminalClient/TerminalAttachmentController.swift \
  Sources/CockpitTerminalCore/TerminalSupervisor.swift \
  Sources/CockpitTerminalCore/TerminalSessionRepository.swift \
  Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift \
  Sources/CockpitLocalTransport/TerminalSupervisorControlTransport.swift \
  Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift \
  Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift \
  Applications/CockpitApp/WorkspacePresentationCoordinator.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift Applications/CockpitApp/ContentHostController.swift \
  Applications/CockpitApp/FileTreeViewController.swift \
  Applications/CockpitApp/Monaco/MonacoEditorViewController.swift \
  Applications/CockpitApp/Terminal/TerminalTabViewController.swift \
  Applications/CockpitApp/WorkspaceSplitViewController.swift \
  Tests/CockpitClientCoreTests/ActiveContextControllerTests.swift \
  Tests/CockpitTerminalClientTests/TerminalAttachmentControllerTests.swift \
  Tests/CockpitTerminalCoreTests/TerminalSupervisorTwoPhaseTests.swift \
  Tests/CockpitAppTests/WorkspaceViewModelTests.swift \
  Tests/CockpitAppTests/WorkspaceHierarchyTests.swift
git commit -m "feat: stage active context presentation"
```

---

### Task 11: Replace Conversation deletion with manifest-bound recoverable operations

**Files:**
- Modify: `Sources/CockpitTypes/WorkspaceOperationModels.swift`
- Create: `Sources/CockpitWorkspace/WorktreeDeletionManifestBuilder.swift`
- Replace: `Sources/CockpitHostCore/ConversationDeletionOperation.swift`
- Replace: `Sources/CockpitHostCore/ConversationDeletionCoordinator.swift`
- Create: `Sources/CockpitHostCore/WorktreeDeletionCoordinator.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Sources/CockpitWorkspace/GitRepositoryCoordinator.swift`
- Replace: `Applications/CockpitApp/ConversationDeletionController.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Test: `Tests/CockpitWorkspaceTests/WorktreeDeletionManifestBuilderTests.swift`
- Test: `Tests/CockpitHostCoreTests/ConversationDeletionCoordinatorTests.swift`
- Test: `Tests/CockpitHostCoreTests/WorktreeDeletionCoordinatorTests.swift`
- Test: `Tests/CockpitAppTests/ConversationDeletionControllerTests.swift`

**Interfaces:**
- Produces: `WorktreeDeletionManifest` and canonical SHA-256 digest.
- Produces: `prepareConversationDeletion`, `beginConversationDeletion`, `submitWorkspaceDecision`, and `resumeWorkspaceOperation`.
- Supports only `conversationOnly`, `conversationAndWorktree`, and pre-begin cancel; every branch is retained.

- [ ] **Step 1: Write failing manifest completeness/mutation tests**

Build a worktree with tracked, untracked, ignored directory contents, symlink, ACL, xattr, and resource fork. Assert changing only content, ACL, xattr, resource fork, flags, or directory entries changes the digest. Assert socket/FIFO/device returns `unsupportedWorktreeEntry` and symlinks are never followed.

```swift
@Test func xattrOnlyChangeInvalidatesDeletionManifest() async throws {
    let first = try await builder.build(root: fixture.root)
    try fixture.setXattr(name: "user.phase2", value: Data("beta".utf8))
    let second = try await builder.build(root: fixture.root)
    #expect(first.digest != second.digest)
}
```

- [ ] **Step 2: Write failing decision/replay/crash tests**

Cover clean/dirty/locked worktrees, manifest change after confirmation, append-only reconfirm DecisionID, records-only continuation, force-terminal decision, Git removed but phase not committed, single-sided Git/path existence, and reply loss. Assert no branch deletion and no `rm -rf` invocation.

```swift
@Test func changedManifestRejectsOldConfirmationAndPreservesWorktree() async throws {
    let prepared = try await coordinator.prepare(fixture.deleteWorktreeRequest)
    try fixture.writeUntracked("after-confirmation.txt")
    let result = try await coordinator.begin(.init(
        operationID: fixture.operationID,
        preparationID: prepared.preparationID,
        decisions: [.confirmManifest(prepared.manifest.digest)]
    ))
    #expect(result.phase == .awaitingDecision)
    #expect(result.observation?.manifestDigest != prepared.manifest.digest)
    #expect(fixture.worktreeExists)
    #expect(fixture.git.branchExists(fixture.branchName))
    #expect(fixture.processes.invocations(named: "rm").isEmpty)
}
```

- [ ] **Step 3: Run manifest and deletion tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorktreeDeletionManifestBuilderTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ConversationDeletionCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorktreeDeletionCoordinatorTests
```

Expected: the Phase 1 coordinator has no Worktree manifest or decision journal.

- [ ] **Step 4: Implement canonical no-follow manifest traversal**

Start from an authenticated worktree root FD. Traverse with directory descriptors; open regular files no-follow; fstat before and after content/ACL/xattr reads; use `readlinkat` for symlinks; include Git common/worktree/workspace identities, incarnation, HEAD/ref, index digest, porcelain categories, and every required metadata field. Sort byte paths/xattr names/directory entries before canonical encoding and SHA-256. Concurrent observation changes abort without producing authorization.

```swift
public struct WorktreeDeletionManifest: Hashable, Codable, Sendable {
    public let version: UInt16
    public let repositoryIdentity: GitRepositoryIdentity
    public let worktreeRootIdentity: FileSystemIdentity
    public let workspaceRootIdentity: FileSystemIdentity
    public let environmentIncarnation: UUID
    public let head: GitHead
    public let indexDigest: String
    public let statusEntries: [WorktreeStatusEntry]
    public let filesystemEntries: [WorktreeManifestEntry]
    public let digest: String
}

public struct WorktreeStatusEntry: Hashable, Codable, Sendable {
    public let pathBytes: Data
    public let classification: WorktreeStatusClassification
}

public enum WorktreeStatusClassification: String, Codable, Sendable {
    case tracked, untracked, ignored
}

public struct WorktreeManifestEntry: Hashable, Codable, Sendable {
    public let pathBytes: Data
    public let identity: FileSystemIdentity
    public let nodeType: WorktreeNodeType
    public let mode: UInt32
    public let uid: UInt32
    public let gid: UInt32
    public let flags: UInt32
    public let linkCount: UInt64
    public let size: UInt64
    public let contentOrLinkDigest: String?
    public let aclDigest: String
    public let xattrDigest: String
    public let directoryEntriesDigest: String?
}

public enum WorktreeNodeType: String, Codable, Sendable {
    case regularFile, directory, symbolicLink
}

public protocol WorktreeDeletionManifestBuilding: Sendable {
    func build(
        worktreeRoot: AuthenticatedDirectory,
        workspaceRoot: AuthenticatedDirectory,
        repository: GitRepositoryIdentity,
        incarnation: UUID
    ) async throws -> WorktreeDeletionManifest
}
```

- [ ] **Step 5: Implement begin, decisions, and physical deletion phases**

Preparation returns dirty Documents, terminal impact, status classification, and manifest digest without mutation. Begin claims Conversation/Environment, freezes admission, validates preparation/revisions/incarnation/manifest, and records user mode. Conversation-only purges Cockpit metadata and preserves physical worktree. Physical mode executes document decisions, normal/force terminal decisions, quiesces Environment, appends validation epoch, rebuilds manifest, requests reconfirm/records-only on change, rejects locked worktree, then invokes `git worktree remove --force` only after explicit dirty confirmation.

```swift
public protocol ConversationDeletionCoordinating: Sendable {
    func prepare(_ request: ConversationDeletionPreparationRequest) async throws
        -> ConversationDeletionPreparation
    func begin(_ request: ConversationDeletionBeginRequest) async throws
        -> WorkspaceOperationProgress
    func submitDecision(_ request: WorkspaceDecisionSubmission) async throws
        -> WorkspaceOperationProgress
    func resume(operationID: WorkspaceOperationID) async throws
        -> WorkspaceOperationProgress
}

switch operation.phase {
case .targetsClaimed: return try await resolveDocuments(operation)
case .resolvingDocuments: return try await gateAndTerminateSessions(operation)
case .quiescingEnvironment: return try await validateDeletionManifest(operation)
case .removalAuthorized: return try await removeRegisteredWorktree(operation)
case .worktreeRemoved, .purgingMetadata: return try await purgeCockpitMetadata(operation)
default: return try await operationStore.progress(id: operation.id)
}
```

- [ ] **Step 6: Implement deterministic removal recovery**

At `removingWorktree`: both registration and path present with matching identities retries; both absent appends the observation and advances `worktreeRemoved`; exactly one present or any identity mismatch enters `needsAttention`. Metadata purge is allowed only after `worktreeRemoved` or a durable records-only decision.

```swift
enum WorktreeRemovalRecoveryAction: Equatable {
    case retryRemoval
    case advanceRemoved
    case stopNeedsAttention(WorkspaceNeedsAttentionReason)
}

func recoveryAction(
    registration: GitWorktreeSnapshot?,
    pathIdentity: FileSystemIdentity?,
    authorized: WorktreeDeletionManifest
) -> WorktreeRemovalRecoveryAction {
    switch (registration, pathIdentity) {
    case let (.some(current), .some(identity))
        where current.rootIdentity == identity && identity == authorized.worktreeRootIdentity:
        return .retryRemoval
    case (nil, nil):
        return .advanceRemoved
    case (nil, .some), (.some, nil):
        return .stopNeedsAttention(.ambiguousGitRegistration)
    default:
        return .stopNeedsAttention(.targetIdentityChanged)
    }
}
```

- [ ] **Step 7: Implement deletion UI and focused GREEN tests**

Before begin show Conversation only / Conversation + worktree / Cancel, Document decisions, and dirty-worktree high-risk confirmation. After begin never show active-cancel; manifest changes offer only confirm-new-manifest or records-only. Force termination is a separate durable confirmation.

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorktreeDeletionManifestBuilderTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ConversationDeletionCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter WorktreeDeletionCoordinatorTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/ConversationDeletionControllerTests test
```

- [ ] **Step 8: Commit Conversation/worktree deletion**

```bash
git add -- Sources/CockpitTypes/WorkspaceOperationModels.swift \
  Sources/CockpitWorkspace/WorktreeDeletionManifestBuilder.swift \
  Sources/CockpitWorkspace/GitRepositoryCoordinator.swift \
  Sources/CockpitHostCore/ConversationDeletionOperation.swift \
  Sources/CockpitHostCore/ConversationDeletionCoordinator.swift \
  Sources/CockpitHostCore/WorktreeDeletionCoordinator.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift \
  Applications/CockpitApp/ConversationDeletionController.swift Applications/CockpitProbe/main.swift \
  Tests/CockpitWorkspaceTests/WorktreeDeletionManifestBuilderTests.swift \
  Tests/CockpitHostCoreTests/ConversationDeletionCoordinatorTests.swift \
  Tests/CockpitHostCoreTests/WorktreeDeletionCoordinatorTests.swift \
  Tests/CockpitAppTests/ConversationDeletionControllerTests.swift
git commit -m "feat: add recoverable worktree deletion"
```

---

### Task 12: Implement Project records-only removal across workspace and terminal stores

**Files:**
- Create: `Sources/CockpitHostCore/ProjectRemovalCoordinator.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceAdmissionCoordinator.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitHostCore/ContextTerminalDeletionControlling.swift`
- Modify: `Sources/CockpitHostCore/TerminalSupervisorControlling.swift`
- Modify: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSessionRepository.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSupervisor.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift`
- Modify: `Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift`
- Modify: `Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorControlTransport.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift`
- Modify: `Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift`
- Create: `Applications/CockpitApp/ProjectRemovalController.swift`
- Modify: `Applications/CockpitApp/ProjectCommandController.swift`
- Test: `Tests/CockpitHostCoreTests/ProjectRemovalCoordinatorTests.swift`
- Test: `Tests/CockpitWorkspaceTests/DocumentRegistryTests.swift`
- Test: `Tests/CockpitTerminalCoreTests/ContextTerminationTests.swift`
- Test: `Tests/CockpitPersistenceTests/SQLiteTerminalSessionRepositoryTests.swift`
- Test: `Tests/CockpitAppTests/ProjectCommandControllerTests.swift`

**Interfaces:**
- Produces: `prepareProjectRemoval`, `beginProjectRemoval`, and `resumeProjectRemoval`.
- Produces terminal gate APIs: `prepareContextDeletion`, `promoteContextDeletion`, `abortPreparedContextDeletion`, and startup reconciliation.
- Project removal never calls Git and never removes Project/worktree/branch/commit/files.

```swift
public struct ProjectRemovalPreparation: Hashable, Codable, Sendable {
    public let preparationID: UUID
    public let projectID: ProjectID
    public let membershipRevision: UInt64
    public let contexts: [ProjectRemovalContextImpact]
}

public struct ProjectRemovalContextImpact: Hashable, Codable, Sendable {
    public let contextID: WorkspaceContextID
    public let environmentID: EnvironmentID
    public let documentRevisions: [WorkspaceDocumentRevision]
    public let terminalSessionIDs: [TerminalSessionID]
    public let terminalImpactRevision: UInt64
}

public struct WorkspaceDocumentRevision: Hashable, Codable, Sendable {
    public let documentID: DocumentID
    public let revision: UInt64
}

public enum WorkspaceDocumentDecision: String, Codable, Sendable {
    case save, discard
}

public struct WorkspaceDocumentDecisionRecord: Hashable, Codable, Sendable {
    public let documentID: DocumentID
    public let expectedRevision: UInt64
    public let decision: WorkspaceDocumentDecision
}

public struct ProjectRemovalBeginRequest: Hashable, Codable, Sendable {
    public let operationID: WorkspaceOperationID
    public let preparationID: UUID
    public let projectID: ProjectID
    public let membershipRevision: UInt64
    public let documentDecisions: [WorkspaceDocumentDecisionRecord]
}

public enum TerminalContextGateState: String, Codable, Sendable {
    case prepared, deleting, purged
}
```

- [ ] **Step 1: Write failing fresh-impact and cross-store tests**

Prepare impact, then inject a new Conversation, Document edit/viewer, and Terminal session before begin; assert reservation/drain returns a fresh impact and no durable mutation. Test terminal prepared gates before workspace commit, workspace failure rollback, crash before promotion, crash after one child promotion, and restart reconciliation before admission opens.

```swift
@Test func projectRemovalPromotesAllTerminalGatesBeforeTermination() async throws {
    let progress = try await coordinator.begin(fixture.confirmedRequest)
    #expect(progress.phase == .resolvingDocuments)
    #expect(try await terminalStore.gates(projectID: fixture.projectID).allSatisfy {
        $0.state == .deleting
    })
    #expect(await terminal.terminatedSessionIDs.isEmpty)
}
```

- [ ] **Step 2: Run project/document/terminal tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ProjectRemovalCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter DocumentRegistryTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter ContextTerminationTests
```

Expected: no Project removal coordinator or terminal prepared-gate protocol exists.

- [ ] **Step 3: Add Project/Document/Terminal reservation and drain boundaries**

Project admission freezes Conversation/Settings/Environment/operation creation. DocumentRegistry reservation freezes new open/edit/save/discard/viewer mutation and waits active document operations to drain. Supervisor reservation freezes terminal admission/lifecycle and waits in-flight lifecycle operations. Keep all three through fresh impact compare and the cross-store begin protocol.

```swift
public protocol ProjectRemovalAdmissionReserving: Sendable {
    func reserve(projectID: ProjectID, operationID: WorkspaceOperationID) async throws
        -> ProjectRemovalAdmissionReservation
}

public protocol DocumentRegistryRemovalReserving: Sendable {
    func reserveAndDrain(contextIDs: [WorkspaceContextID]) async throws
        -> DocumentRemovalReservation
}

public protocol TerminalRemovalReserving: Sendable {
    func reserveAndDrain(contextIDs: [WorkspaceContextID]) async throws
        -> TerminalRemovalReservation
}

let projectReservation = try await admission.reserve(projectID: request.projectID, operationID: request.operationID)
let documentReservation = try await documents.reserveAndDrain(contextIDs: preparation.contexts.map(\.contextID))
let terminalReservation = try await terminals.reserveAndDrain(contextIDs: preparation.contexts.map(\.contextID))
try await validateFreshImpact(request, holding: (projectReservation, documentReservation, terminalReservation))
```

- [ ] **Step 4: Implement prepared terminal gates and workspace begin**

For every deterministic child ID write `prepared` into terminal.sqlite; after all acks, one workspace.sqlite transaction inserts operation/claims, marks Project removing, marks all Conversations deleting with the same owner, and writes full `workspace_operation_contexts` at `targetsClaimed`. On workspace failure abort exact prepared gates. After workspace commit hold Terminal reservation while promoting every child to `deleting`; persist each ack; release only after all gates are durable; then CAS parent to `resolvingDocuments`.

```swift
public protocol ContextTerminalDeletionControlling: Sendable {
    func prepareContextDeletion(_ request: PrepareContextDeletionRequest) async throws
    func promoteContextDeletion(_ request: PromoteContextDeletionRequest) async throws
    func abortPreparedContextDeletion(_ request: AbortContextDeletionRequest) async throws
}

for child in deterministicContextChildren {
    try await terminal.prepareContextDeletion(child.prepareRequest(operationID: request.operationID))
}
do {
    try await workspaceOperations.beginProjectRemoval(request, contexts: deterministicContextChildren)
} catch {
    for child in deterministicContextChildren {
        try await terminal.abortPreparedContextDeletion(child.abortRequest(operationID: request.operationID))
    }
    throw error
}
for child in deterministicContextChildren {
    try await terminal.promoteContextDeletion(child.promoteRequest(operationID: request.operationID))
    try await workspaceOperations.recordTerminalGatePromotion(request.operationID, contextID: child.contextID)
}
try await workspaceOperations.advance(id: request.operationID, from: .targetsClaimed, to: .resolvingDocuments)
```

- [ ] **Step 5: Implement strict parent phase order and recovery**

After Document decisions, CAS to `gatingAllContexts`; this phase verifies all child gates are deleting and then advances to `terminatingSessions`. Continue quiescing all Environments and metadata purge. Startup reads the workspace journal before opening terminal admission, removes orphan prepared gates without a workspace operation, and promotes missing/prepared gates for committed operations. Each child step and parent step is exact CAS replayable.

```swift
func resumeProjectRemoval(_ id: WorkspaceOperationID) async throws -> WorkspaceOperationProgress {
    let record = try await operations.require(id)
    switch record.phase {
    case .targetsClaimed:
        try await reconcilePromotedTerminalGates(record)
        return try await operations.advance(id: id, from: .targetsClaimed, to: .resolvingDocuments)
    case .resolvingDocuments:
        try await resolveDocumentDecisions(record)
        return try await operations.advance(id: id, from: .resolvingDocuments, to: .gatingAllContexts)
    case .gatingAllContexts:
        try await requireEveryContextGateDeleting(record)
        return try await operations.advance(id: id, from: .gatingAllContexts, to: .terminatingSessions)
    case .terminatingSessions: return try await terminateAllRecordedSessions(record)
    case .quiescingEnvironments: return try await quiesceAllRecordedEnvironments(record)
    case .purgingMetadata: return try await purgeProjectRecordsOnly(record)
    default: return try await operations.progress(id: id)
    }
}
```

- [ ] **Step 6: Implement Project removal UI**

Show exact Project membership, all Context/Environment IDs, dirty Documents, terminal counts, and the statement that every Project file, worktree, branch, and commit remains unchanged. Save/discard and force decisions use stable DecisionIDs. After completion return to the next available Project or Welcome.

```swift
struct ProjectRemovalConfirmationModel: Equatable {
    let projectName: String
    let contextRows: [ProjectRemovalContextRow]
    let dirtyDocuments: [WorkspaceDocumentRevision]
    let terminalSessionCount: Int
    let preservationNotice = "Project files, worktrees, branches, and commits will not be changed."
}

@MainActor
func confirmAndRemove(_ preparation: ProjectRemovalPreparation) async throws {
    let decisions = try await presenter.collectStableDecisions(for: preparation)
    let request = ProjectRemovalBeginRequest(
        operationID: operationID,
        preparationID: preparation.preparationID,
        projectID: preparation.projectID,
        membershipRevision: preparation.membershipRevision,
        documentDecisions: decisions.documents
    )
    try await driveUntilCompleted(request, forceDecisionID: decisions.forceDecisionID)
    workspace.selectNextAvailableProjectOrWelcome()
}
```

- [ ] **Step 7: Run focused suites GREEN and commit**

Run the commands from Step 2 plus:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter SQLiteTerminalSessionRepositoryTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/ProjectCommandControllerTests test
```

Then:

```bash
git add -- Sources/CockpitHostCore/ProjectRemovalCoordinator.swift \
  Sources/CockpitHostCore/WorkspaceAdmissionCoordinator.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitHostCore/ContextTerminalDeletionControlling.swift \
  Sources/CockpitHostCore/TerminalSupervisorControlling.swift \
  Sources/CockpitWorkspace/DocumentRegistry.swift \
  Sources/CockpitTerminalCore/TerminalSessionRepository.swift \
  Sources/CockpitTerminalCore/TerminalSupervisor.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceOperationStore.swift \
  Sources/CockpitPersistence/SQLiteWorkspaceRepository.swift \
  Sources/CockpitPersistence/SQLiteTerminalSessionRepository.swift \
  Sources/CockpitLocalTransport/TerminalSupervisorControlTransport.swift \
  Sources/CockpitLocalTransport/TerminalSupervisorXPCProtocol.swift \
  Sources/CockpitLocalTransport/TerminalSupervisorXPCExport.swift \
  Applications/CockpitApp/ProjectRemovalController.swift \
  Applications/CockpitApp/ProjectCommandController.swift \
  Tests/CockpitHostCoreTests/ProjectRemovalCoordinatorTests.swift \
  Tests/CockpitWorkspaceTests/DocumentRegistryTests.swift \
  Tests/CockpitTerminalCoreTests/ContextTerminationTests.swift \
  Tests/CockpitPersistenceTests/SQLiteTerminalSessionRepositoryTests.swift \
  Tests/CockpitAppTests/ProjectCommandControllerTests.swift
git commit -m "feat: remove cockpit projects transactionally"
```

---

### Task 13: Refresh external Git state and revoke unavailable incarnations

**Files:**
- Create: `Sources/CockpitHostCore/EnvironmentAvailabilityCoordinator.swift`
- Modify: `Sources/CockpitHostCore/WorkspaceService.swift`
- Modify: `Sources/CockpitWorkspace/GitRepositoryCoordinator.swift`
- Modify: `Sources/CockpitWorkspace/FileSystemEventSource.swift`
- Modify: `Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift`
- Modify: `Sources/CockpitWorkspace/DocumentRegistry.swift`
- Modify: `Sources/CockpitLocalTransport/HostDataPlaneServer.swift`
- Modify: `Sources/CockpitTerminalCore/TerminalSupervisor.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Test: `Tests/CockpitHostCoreTests/EnvironmentAvailabilityCoordinatorTests.swift`
- Test: `Tests/CockpitWorkspaceTests/FileTreeReconcilerTests.swift`
- Test: `Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift`
- Test: `Tests/CockpitTerminalCoreTests/TerminalSupervisorTwoPhaseTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceViewModelTests.swift`

**Interfaces:**
- Produces: `EnvironmentAvailabilityCoordinator.refresh(environmentID:reason:)`.
- Available refresh updates actual branch/detached HEAD/OID without changing Environment identity.
- Available -> Unavailable revokes old incarnation authority before kernel/access-token release.

```swift
public enum EnvironmentRefreshReason: String, Codable, Sendable {
    case workspaceLoad, contextPrepare, gitMutationCompleted, filesystemEvent
}

public protocol EnvironmentAvailabilityCoordinating: Sendable {
    func refresh(
        environmentID: EnvironmentID,
        reason: EnvironmentRefreshReason
    ) async throws -> EnvironmentSnapshot
}
```

- [ ] **Step 1: Write failing switch/detach/replacement/revocation tests**

Run external `git switch`, enter Detached HEAD, replace the worktree directory with another object, change common directory identity, and remove Project/Worktree paths. Assert branch/OID refresh for valid identity and unavailable state for identity mismatch. Assert old data-plane connections close, viewers are removed, terminal attachments detach, in-flight operations drain, kernel unregisters, and old tickets never reattach.

```swift
@Test func unavailableTransitionRevokesEveryOldIncarnationChild() async throws {
    try await coordinator.refresh(environmentID: fixture.environmentID, reason: .filesystemEvent)
    #expect(await dataPlane.closedIncarnations == [fixture.oldIncarnation])
    #expect(await documents.removedViewerIncarnations == [fixture.oldIncarnation])
    #expect(await terminal.detachedIncarnations == [fixture.oldIncarnation])
    #expect(await kernels.registered(environmentID: fixture.environmentID) == nil)
}
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter EnvironmentAvailabilityCoordinatorTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter HostDataPlaneTests
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter TerminalSupervisorTwoPhaseTests
```

Expected: the current workspace refresh has no Environment incarnation revocation coordinator.

- [ ] **Step 3: Implement coalesced refresh with identity-first classification**

Trigger refresh at snapshot load, before Context prepare, after Git operations, and from coalesced filesystem events on `.git`/HEAD/worktree roots. Under repository lock compare worktree root identity, common-directory identity, registration, branch/detached state, and HEAD OID. Valid same-identity changes update metadata and snapshot revision; identity/path absence transitions availability and increments incarnation only on successful restoration.

```swift
enum EnvironmentRefreshClassification: Equatable {
    case metadataChanged(head: GitHead, branch: GitLocalBranch?)
    case unchanged
    case unavailable(EnvironmentUnavailableReason)
    case restored(newIncarnation: UUID, head: GitHead, branch: GitLocalBranch?)
}

func classify(
    persisted: EnvironmentSnapshot,
    observed: GitWorktreeSnapshot?
) -> EnvironmentRefreshClassification {
    guard let observed else { return .unavailable(.pathMissing) }
    guard observed.worktreeRootIdentity == persisted.worktreeRootIdentity else {
        return .unavailable(.worktreeIdentityChanged)
    }
    guard observed.repositoryIdentity == persisted.repositoryIdentity else {
        return .unavailable(.commonDirectoryIdentityChanged)
    }
    return observed.head == persisted.head && observed.branch == persisted.branch
        ? .unchanged
        : .metadataChanged(head: observed.head, branch: observed.branch)
}
```

- [ ] **Step 4: Implement ordered active revocation**

Under admission gate atomically mark old incarnation revoked and freeze new admission; revoke prepared tokens/tickets/child promotion; close all data-plane UDS children and subscriptions; remove Document viewers; revoke Supervisor registration and detach active terminal attachments; wait entered file/document operations; quiesce/unregister kernel; release root access lease. Only a fresh resolved incarnation can issue new authorization.

```swift
func revoke(_ environment: EnvironmentSnapshot) async throws {
    let reservation = try await admission.revokeAndDrain(
        environmentID: environment.environmentID,
        incarnation: environment.incarnation
    )
    try await contextCommits.revokePrepared(environmentID: environment.environmentID, incarnation: environment.incarnation)
    await dataPlane.close(environmentID: environment.environmentID, incarnation: environment.incarnation)
    await documents.removeViewers(environmentID: environment.environmentID, incarnation: environment.incarnation)
    try await terminal.revokeRegistration(environmentID: environment.environmentID, incarnation: environment.incarnation)
    try await terminal.detachAll(environmentID: environment.environmentID, incarnation: environment.incarnation)
    try await kernels.quiesceAndUnregister(environmentID: environment.environmentID, incarnation: environment.incarnation)
    await roots.release(environmentID: environment.environmentID, incarnation: environment.incarnation)
    await reservation.finish()
}
```

- [ ] **Step 5: Surface exact unavailable state without relink**

Sidebar retains the item and displays `Environment Unavailable` or `Project Unavailable`, exact path, and only the permitted delete/remove entry. Do not auto-delete, relink, or hide sibling Projects/Environments.

```swift
enum UnavailableSidebarAction: Equatable {
    case deleteConversation(ConversationID)
    case removeProject(ProjectID)
}

struct UnavailableSidebarState: Equatable {
    let title: String
    let path: String
    let reason: EnvironmentUnavailableReason
    let action: UnavailableSidebarAction
}

#expect(viewModel.unavailableState?.title == "Environment Unavailable")
#expect(viewModel.unavailableState?.path == fixture.missingWorktreePath)
#expect(viewModel.availableActions == [.deleteConversation(fixture.conversationID)])
```

- [ ] **Step 6: Run focused suites GREEN and commit**

Run the commands from Step 2 plus:

```bash
swift test --disable-automatic-resolution --skip-update --no-parallel \
  --filter FileTreeReconcilerTests
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/WorkspaceViewModelTests test
```

Then:

```bash
git add -- Sources/CockpitHostCore/EnvironmentAvailabilityCoordinator.swift \
  Sources/CockpitHostCore/WorkspaceService.swift \
  Sources/CockpitWorkspace/GitRepositoryCoordinator.swift \
  Sources/CockpitWorkspace/FileSystemEventSource.swift \
  Sources/CockpitWorkspace/WorkspaceKernelRegistry.swift \
  Sources/CockpitWorkspace/DocumentRegistry.swift \
  Sources/CockpitLocalTransport/HostDataPlaneServer.swift \
  Sources/CockpitTerminalCore/TerminalSupervisor.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift \
  Applications/CockpitApp/WorkspaceSidebarController.swift \
  Tests/CockpitHostCoreTests/EnvironmentAvailabilityCoordinatorTests.swift \
  Tests/CockpitWorkspaceTests/FileTreeReconcilerTests.swift \
  Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift \
  Tests/CockpitTerminalCoreTests/TerminalSupervisorTwoPhaseTests.swift \
  Tests/CockpitAppTests/WorkspaceViewModelTests.swift
git commit -m "feat: reconcile external worktree state"
```

---

### Task 14: Finish Phase 2 UI, process fixtures, reset path, and unified gate

**Files:**
- Modify: `Applications/CockpitApp/WorkspaceSidebarController.swift`
- Modify: `Applications/CockpitApp/WorkspaceSplitViewController.swift`
- Modify: `Applications/CockpitApp/WorkspaceViewModel.swift`
- Modify: `Applications/CockpitApp/NewConversationSheetController.swift`
- Modify: `Applications/CockpitApp/ProjectSettingsController.swift`
- Modify: `Applications/CockpitApp/ConversationDeletionController.swift`
- Modify: `Applications/CockpitApp/ProjectRemovalController.swift`
- Modify: `Applications/CockpitProbe/main.swift`
- Create: `Tools/reset-cockpit-development-data.zsh`
- Create: `Tests/ProcessIntegrationTests/phase2-worktree-environments.zsh`
- Create: `Tests/ProcessIntegrationTests/phase2-context-promotion.zsh`
- Create: `Tests/ProcessIntegrationTests/phase2-deletion-recovery.zsh`
- Modify: `Tests/ProcessIntegrationTests/probe-json.zsh`
- Create: `Tools/verify-phase2.zsh`
- Test: `Tests/CockpitAppTests/WorkspaceHierarchyTests.swift`
- Test: `Tests/CockpitAppTests/WorkspaceViewModelTests.swift`
- Test: `Tests/CockpitAppTests/ConversationCommandControllerTests.swift`
- Test: `Tests/CockpitAppTests/ConversationDeletionControllerTests.swift`
- Test: `Tests/CockpitAppTests/ProjectCommandControllerTests.swift`

**Interfaces:**
- Produces one native sidebar/settings/create/delete/remove experience matching design section 16.
- Produces an exact Cockpit-owned development reset that never touches Project/Git/worktree/branch/files.
- Produces `Tools/verify-phase2.zsh` with first-error stop and final line `Phase 2 unified gate: PASS`.

- [ ] **Step 1: Write failing App hierarchy/action tests**

Assert multiple Project rows, Direct/branch/Detached subtitles, occupied branch disabled reason/path, settings command, unavailable labels/paths, Worktree delete choices, Project records-only warning, and one stable main window/navigation owner. Assert no independent Worktree delete action and no relink action.

```swift
@MainActor
@Test func sidebarExposesOnlyConfirmedPhase2Actions() throws {
    let rows = try fixture.makeSidebarRows()
    #expect(rows.projects.count == 2)
    #expect(rows.conversations.map(\.subtitle).contains("Detached at a1b2c3d"))
    #expect(rows.occupiedBranch?.isEnabled == false)
    #expect(rows.occupiedBranch?.disabledReason == fixture.occupiedWorktreePath)
    #expect(rows.allActions.contains(.projectSettings))
    #expect(!rows.allActions.contains(.deleteWorktree))
    #expect(!rows.allActions.contains(.relink))
    #expect(fixture.windowRegistry.windowIDs == [fixture.mainWindowID])
}
```

- [ ] **Step 2: Run App suites and verify RED**

Run:

```bash
xcodegen generate --no-env
xcodebuild -workspace Cockpit.xcworkspace -scheme Cockpit -configuration Debug \
  -derivedDataPath DerivedData SYMROOT="$PWD/build" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates -skipPackagePluginValidation \
  -only-testing:CockpitAppTests/WorkspaceHierarchyTests \
  -only-testing:CockpitAppTests/WorkspaceViewModelTests \
  -only-testing:CockpitAppTests/ConversationCommandControllerTests \
  -only-testing:CockpitAppTests/ConversationDeletionControllerTests \
  -only-testing:CockpitAppTests/ProjectCommandControllerTests test
```

Expected: remaining menu copy/actions and unavailable/create/delete presentations fail their exact assertions.

- [ ] **Step 3: Complete App UI behavior without new product scope**

Wire the confirmed controllers into the integrated AppKit window. Keep the Phase 1 titlebar-integrated three-column shell and fixed terminal typography. Use semantic AppKit colors/SF Symbols/system fonts. Do not add Git status/diff/stage/commit, Search, LSP, remote workspaces, relink, or multi-window controls.

```swift
@MainActor
func apply(_ snapshot: WorkspaceSnapshot) {
    sidebar.apply(projects: snapshot.projects, navigationRevision: snapshot.navigationRevision)
    splitView.installSidebar(sidebar.viewController)
    splitView.installNavigator(navigator.viewController)
    splitView.installContent(content.viewController)
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.tabbingMode = .disallowed
    terminalFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
}
```

- [ ] **Step 4: Add an exact development-data reset**

The script stops only Cockpit Host/Supervisor launch labels, authenticates Cockpit storage roots, removes workspace/terminal SQLite files, document recovery, client state/preferences, and Cockpit runtime data, then restarts services. It rejects symlinks and paths outside Cockpit-owned roots. It never invokes Git and never traverses a Project/worktree path.

```zsh
#!/bin/zsh
set -euo pipefail

readonly support_root="$HOME/Library/Application Support/dev.cockpit.Cockpit"
readonly cache_root="$HOME/Library/Caches/dev.cockpit.Cockpit"
[[ -d "$support_root" && ! -L "$support_root" ]]
[[ -d "$cache_root" && ! -L "$cache_root" ]]
[[ "$(/usr/bin/stat -f '%Su' "$support_root")" == "$USER" ]]
[[ "$(/usr/bin/stat -f '%Su' "$cache_root")" == "$USER" ]]

reset_cockpit_sqlite_files "$support_root"
reset_cockpit_recovery_and_client_state "$support_root" "$cache_root"
restart_exact_cockpit_services
```

- [ ] **Step 5: Extend Probe JSON contracts for all Phase 2 commands**

Require stable operation/decision/commit IDs in commands and outputs. Add strict JSON tests for multi-Project snapshot, settings, branch preparation, operation replay/progress, context status/recovery, manifest decisions, Project removal, unavailable state, and all typed business errors. Unknown fields/cases remain failures.

```swift
enum Phase2ProbeCommand: String, CaseIterable {
    case workspaceList = "workspace list"
    case projectSettingsShow = "project settings show"
    case projectSettingsUpdate = "project settings update"
    case conversationPrepareCreate = "conversation prepare-create"
    case operationResume = "operation resume"
    case contextPrepare = "context prepare"
    case contextCommit = "context commit"
    case contextStatus = "context status"
    case contextCompleteRecovery = "context complete-recovery"
    case conversationPrepareDelete = "conversation prepare-delete"
    case operationSubmitDecision = "operation submit-decision"
    case projectPrepareRemove = "project prepare-remove"
    case environmentRefresh = "environment refresh"
}

#expect(Set(Phase2ProbeCommand.allCases.map(\.rawValue)) == fixture.expectedPhase2Commands)
```

- [ ] **Step 6: Write the multi-Project/Worktree process scenario**

Create two real Git Projects and multiple Direct/New Branch/Existing Branch Conversations. Assert exact source OID/ref, attached Existing Branch, distinct roots/DocumentIDs/terminal sessions/client state, settings change affects only a future worktree, crash recovery reuses the same operation/Conversation/Environment IDs, and no namespace/process/root/keychain/preferences residue remains.

```zsh
project_a="$(probe project add --operation-id "$add_a" --path "$repo_a")"
project_b="$(probe project add --operation-id "$add_b" --path "$repo_b")"
new_branch="$(probe conversation create --operation-id "$create_new" --mode new-branch --source "$source_oid")"
replayed="$(probe operation resume --operation-id "$create_new")"
[[ "$(json "$new_branch" result.conversationID)" == "$(json "$replayed" result.conversationID)" ]]
[[ "$(json "$new_branch" result.environmentID)" == "$(json "$replayed" result.environmentID)" ]]
assert_distinct_roots_documents_terminals "$project_a" "$project_b" "$new_branch"
assert_namespace_residue_empty
```

- [ ] **Step 7: Write the context promotion/recovery process scenario**

Exercise prepare failure with old UI unchanged, prepared data-plane read, Host crash after durable commit, child recovery epoch/proofs, App restart, A/B/C supersession, external `git switch`, Detached HEAD, directory replacement, unavailable revocation, restoration with new incarnation, and rejection of every old ticket/authorization.

```zsh
old_visible="$(probe app visible-context)"
assert_probe_fails context prepare --context-id "$broken_context"
[[ "$(probe app visible-context)" == "$old_visible" ]]
commit_b="$(probe context commit --context-id "$context_b" --commit-id "$commit_b_id")"
crash_exact_host
recovered="$(probe context complete-recovery --commit-id "$commit_b_id" --epoch "$(json "$commit_b" result.recoveryEpoch)")"
commit_c="$(probe context commit --context-id "$context_c" --commit-id "$commit_c_id")"
assert_superseded "$commit_b_id" "$commit_c_id"
assert_old_authorizations_rejected "$old_incarnation"
```

- [ ] **Step 8: Write the deletion/recovery process scenario**

Exercise Conversation-only, Conversation+clean worktree, dirty manifest reconfirm, records-only fallback, locked worktree, xattr/resource-fork change, Git removed/reply lost recovery, Project removal across Project Context and all Conversations, Supervisor/Host crashes at prepared/promote/terminate/purge boundaries, preserved branches/files, and permanent operation replay.

```zsh
prepared="$(probe conversation prepare-delete --conversation-id "$conversation_id" --mode conversation-and-worktree)"
change_only_xattr "$worktree_root"
progress="$(probe operation begin-delete --operation-id "$delete_id" --preparation-id "$(json "$prepared" result.preparationID)")"
[[ "$(json "$progress" result.phase)" == "awaitingDecision" ]]
probe operation submit-decision --operation-id "$delete_id" --decision-id "$reconfirm_id" --records-only
crash_exact_supervisor_at terminatingSessions
completed="$(probe operation resume --operation-id "$delete_id")"
[[ "$(json "$completed" result.phase)" == "completed" ]]
assert_branch_and_project_files_preserved
assert_operation_replay_identical "$delete_id" "$completed"
```

- [ ] **Step 9: Assemble the unified gate**

`Tools/verify-phase2.zsh` runs sequentially:

```text
1. canonical toolchain and clean dependency/lock/Ghostty scope checks
2. complete Tools/verify-phase1.zsh
3. fresh Swift build and full no-parallel Swift tests
4. fresh XcodeGen/App build and App tests
5. Probe JSON 1.1/1.2 strict contract
6. phase2-worktree-environments.zsh
7. phase2-context-promotion.zsh
8. phase2-deletion-recovery.zsh
9. App bundle layout and Cockpit-owned reset safety
10. exact process/launch-label/tmp/cache/preferences/keychain residue audit
11. git diff --check
```

It uses `set -euo pipefail`, stops at the first failure, authenticates every PID/label/path before cleanup, and prints `Phase 2 unified gate: PASS` only after node 11 succeeds.

- [ ] **Step 10: Run focused process scenarios GREEN**

Run:

```bash
Tests/ProcessIntegrationTests/probe-json.zsh
Tests/ProcessIntegrationTests/phase2-worktree-environments.zsh
Tests/ProcessIntegrationTests/phase2-context-promotion.zsh
Tests/ProcessIntegrationTests/phase2-deletion-recovery.zsh
```

- [ ] **Step 11: Run the one authoritative full gate**

Run:

```bash
Tools/verify-phase2.zsh
```

Expected: exit 0 and final exact line:

```text
Phase 2 unified gate: PASS
```

- [ ] **Step 12: Perform final scope/residue verification and commit**

Run:

```bash
git diff --check
git status --short
git diff -- Package.swift Package.resolved .gitmodules ThirdParty/ghostty Patches/ghostty
```

Expected: diff check has no output; dependency/Ghostty command has no output; status contains only authorized Phase 2 implementation/test/plan paths before commit; all Phase 2 labels, PIDs, tmp roots, cache roots, preferences, and keychain fixtures are absent.

Then:

```bash
git add -- Applications/CockpitApp/WorkspaceSidebarController.swift \
  Applications/CockpitApp/WorkspaceSplitViewController.swift \
  Applications/CockpitApp/WorkspaceViewModel.swift \
  Applications/CockpitApp/NewConversationSheetController.swift \
  Applications/CockpitApp/ProjectSettingsController.swift \
  Applications/CockpitApp/ConversationDeletionController.swift \
  Applications/CockpitApp/ProjectRemovalController.swift Applications/CockpitProbe/main.swift \
  Tools/reset-cockpit-development-data.zsh Tools/verify-phase2.zsh \
  Tests/CockpitAppTests/WorkspaceHierarchyTests.swift \
  Tests/CockpitAppTests/WorkspaceViewModelTests.swift \
  Tests/CockpitAppTests/ConversationCommandControllerTests.swift \
  Tests/CockpitAppTests/ConversationDeletionControllerTests.swift \
  Tests/CockpitAppTests/ProjectCommandControllerTests.swift \
  Tests/ProcessIntegrationTests/probe-json.zsh \
  Tests/ProcessIntegrationTests/phase2-worktree-environments.zsh \
  Tests/ProcessIntegrationTests/phase2-context-promotion.zsh \
  Tests/ProcessIntegrationTests/phase2-deletion-recovery.zsh
git commit -m "test: verify phase 2 worktree environments"
```

---

## Spec Coverage Matrix

| Design acceptance | Implemented and verified by |
| --- | --- |
| 1-4 multi-Project, isolation, subdirectory mapping, repository serialization | Tasks 5, 6, 8, 14 |
| 5-8 settings, stable capabilities, grant refresh, reference lifecycle | Tasks 1, 4, 7, 14 |
| 9-12 branch source/ref/occupancy and moved-source checks | Tasks 6, 8, 14 |
| 13-16 durable idempotency, target claims, fresh Project impact, creation recovery | Tasks 1, 8, 12, 14 |
| 17-20 fd-bound Git target, external path races, needsAttention, cancellation | Task 6 and Task 14 |
| 21-26 manifest completeness, locked worktree, validation epoch, recovery, decisions | Task 11 and Task 14 |
| 27-31 Conversation/Project deletion and unavailable isolation | Tasks 11, 12, 13, 14 |
| 32-33 external Git refresh and active incarnation revocation | Task 13 and Task 14 |
| 34-42 prepared context, authority handoff, recovery, supersession, kernel cleanup | Tasks 9, 10, 13, 14 |
| 43-49 protocol family, feature/target gates, connection session, envelopes, in-flight replay | Tasks 2, 3, 9, 14 |
| 50 cross-process crash recovery | Tasks 8-14 |
| 51 Cockpit-owned development reset | Task 14 |
| 52 one stable main window | Tasks 5, 10, 14 |
| 53 complete Phase 1 regression | Task 14 `Tools/verify-phase2.zsh` node 2 |

## Plan Completion Check

Before execution begins, verify:

```bash
unfinished_pattern="$(printf '%s' 'TO''DO|TB''D|FIX''ME|XX''X|implement ''later|fill ''in|similar ''to')"
rg -n "$unfinished_pattern" docs/superpowers/plans/2026-08-13-cockpit-phase-2-worktree-environments.md
git diff --check
```

Expected: both commands produce no findings. Confirm every interface consumed by a later task is produced by an earlier task, every design acceptance item maps to at least one task, and the plan changes no dependency/Ghostty path.
