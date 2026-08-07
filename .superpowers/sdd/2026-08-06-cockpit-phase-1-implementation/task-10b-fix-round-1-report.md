# Task 10B Fix Round 1 Report

## Scope

- Base commit: `786911c93bf2eb8598abf1bb48abd5e0e2ec2ff6`.
- Review source: `task-10b-reviewer-report.md` with 1 Critical, 7 Important, and 1 Minor finding.
- Scope stayed inside the approved Task 10B Host data-plane production and focused-test files. No Task 10C, Workspace, UI, package dependency, protocol declaration, or third-party version changed.
- Commit subject: `fix: harden host data plane lifecycle`.

## RED evidence

The preserved authoritative RED node from the interrupted implementation ran the frozen filter with production still unmodified: exit 1, xUnit actual 36 equalled expected 36, and there was no crash or hang. Those failures covered the reviewer findings before the production fixes were started.

Additional focused RED nodes added while closing the interrupted implementation were:

- Shutdown/subscription registration race: after correcting an overlong test namespace, exit 1 because `treeAfterRevisions` was `[10]` rather than empty. This proved that the old server could start a provider after shutdown had begun.
- Delta correlation: exit 1 because a mismatched delta envelope/event identity and a nonadvancing revision returned a value and left `closeCount == 0`.
- Cross-subscription ACK isolation: after making the test stop immediately on a non-`ackAccepted` reply, exit 1 with `wrong tree ACK cancelled the unrelated subscription`.
- Coordinator migration: the behavior test first failed to compile because `HostShutdownCoordinator` was private to the executable target; moving the same implementation into the approved LocalTransport boundary made the production composition directly testable.

Two pre-fix full focused attempts were interrupted with exit 130 after exceeding the hang sampling threshold. Both `/usr/bin/sample` captures placed the active test in `hostDataPlaneClientRejectsAcquireIdentityAndWireBindingMismatchWithoutHostCall` at `RawHostDataPlanePeer.handshake -> readFrame -> read`. The other runnable `com.apple.root.default-qos` workers were blocked in a client read loop, server `accept`, and server reads; neither sample contained a subscription `Task.value` stack. Isolated handshake, shutdown-order, wrong-ACK, and reconnect tests all exited 0. The production blocking accept/read operations were then moved from the shared global queue to private serial queues owned by each listener/connection. The frozen concurrent gate subsequently completed twice at 41/41, and the final 42-test gate also completed.

## Finding dispositions

### C1 — descriptor ownership and ordered shutdown

Resolved.

- Listener, accepted-client, unary-client, and tree-client descriptors now use a close-once owner.
- Server shutdown changes state first, closes active clients, cancels and awaits registered subscriptions, closes the listener, performs inode-guarded unlink, and waits for accept/connection workers.
- Subscription creation and registration share the connection lock with the shutdown snapshot, so registration and shutdown cannot pass one another.
- The accepted-after-stop path and worker cleanup use the same descriptor owner.
- Direct proofs: `hostDataPlaneServerShutdownClosesClientOnceListenerLastAndJoinsWorker`, `hostDataPlaneClientDisconnectAndInflightReadCloseDescriptorExactlyOnce`, `hostDataPlaneServerShutdownCancelsSubscriptionBeforeListenerClose`, and `hostDataPlaneServerShutdownRejectsSubscriptionRegistrationAfterStopBegins`.

### I1 — one reader, pending dispatch, cancellation, monotonic ACK

Resolved.

- Each shared unary connection has one read pump and a pending table keyed by channel/request ID.
- Writes and per-channel sequence allocation are serialized. Server outgoing ACKs retain the maximum acknowledged incoming sequence.
- Cancelled unary entries become discard-only until their late replies are consumed; teardown completes all live pending continuations as disconnected.
- Blocking accept/read work uses listener/connection-owned serial queues rather than the shared global root queue.
- Direct proofs: `hostDataPlaneClientSingleReadPumpDispatchesReorderedConcurrentUnaryReplies` and `hostDataPlaneClientCancellationCompletesBeforeLateReplyAndDiscardKeepsConnectionUsable`; the final concurrent frozen gate completed without the sampled root-queue starvation.

### I2 — wrong tree ACK cancels only its subscription

Resolved.

- ACK mismatch removes and cancels the subscription named by the ACK, removes only that subscription's waiters, and returns `TREE_BACKPRESSURE`.
- A cross-subscription event ID no longer cancels the event owner's unrelated subscription.
- Direct proof: `hostDataPlaneWrongTreeEventOrRevisionAckCancelsOnlyThatSubscription` covers wrong revision and an event ID owned by the other live subscription, then proves the other subscription ACKs and emits again.

### I3 — tree reconnect and revision recovery

Resolved.

- Disconnect closes and clears the old descriptor, obtains a fresh XPC ticket/socket, reauthenticates, and resubscribes after the last delivered revision.
- Revision-unavailable recovery refreshes only the captured sorted/deduplicated expanded-directory snapshot, then subscribes from the maximum returned revision.
- Delta revisions must strictly advance, and mutation requests are never replayed.
- Direct proofs: `hostDataPlaneFileTreeDisconnectGetsNewTicketAndResubscribesFromLastAppliedRevision`, `hostDataPlaneFileTreeEnforcesBackpressureCancelAndRevisionReconnect`, and `hostDataPlaneTreeClientRejectsMismatchedDeltaIdentityAndNonadvancingRevision`.

### I4 — exact response and tree control correlation

Resolved.

- Unary responses validate full binding, request ID, expected response variant, document identity, lease owner, transaction sequence, tree directory, and generation before returning a value.
- Committed recovery diagnostics require the exact apply document/sequence.
- Tree subscription, delta envelope/event identity, ACK, cancel, event, revision, and subscription fields are validated; protocol mismatch closes the connection.
- Cancel waits for and consumes the correlated `cancelled` response.
- Direct proofs: `hostDataPlaneClientRejectsMismatchedDocumentBindingAndPayloadAndCloses`, `hostDataPlaneClientRejectsMismatchedLeaseAckAndTreeSnapshotCorrelation`, `hostDataPlaneCommittedDiagnosticMustMatchApplyDocumentAndSequence`, `hostDataPlaneTreeClientRejectsEveryMismatchedAckReplyField`, `hostDataPlaneTreeClientWaitsForAndConsumesCorrelatedCancelReply`, and `hostDataPlaneTreeClientRejectsMismatchedDeltaIdentityAndNonadvancingRevision`.

### I5 — exact XPC context and one issuance permit

Resolved.

- Ticket export validates every canonical wire ID and generation `1...9_007_199_254_740_991` before readiness/issuance and returns invalid-context code 2 on failure.
- The issuer closes admission on stop and serializes admitted issue bodies through one permit retained through synchronous delivery; stop waits for all admitted work.
- Direct proofs: `hostDataPlaneXPCRejectsEveryNoncanonicalContextIDAndUnsafeGenerationAsInvalidContext`, `hostDataPlaneIssuanceUsesOnePermitForTwoAdmittedIssuesThroughStop`, and `hostDataPlaneIssuanceShutdownGateOrdersDeliverStopAndRejectsNewIssues`.

### I6 — ticket digest collision and tombstone preservation

Resolved.

- Issuance never overwrites an unexpired live or consumed digest, retries a bounded eight random values, and permits digest reuse only after expiry.
- Direct proof: `hostDataPlaneTicketCollisionPreservesLiveAndConsumedEntriesUntilExpiry`.

### I7 — missing direct behavior proofs

Resolved.

- Raw wire tests now execute ACK violation and request-ID reuse.
- LocalTransport integration tests traverse numeric document-error mapping and controller resynchronization.
- Reconnect/new-ticket, cross-subscription cancellation, descriptor reuse, and shutdown order have direct behavior tests.
- The production `HostShutdownCoordinator` directly proves admitted reply completion, issuer stop, server shutdown, listener invalidation, and run-loop stop order. `CockpitHost/main.swift` constructs that same implementation with the real listener and run loop.
- The real SIGTERM test resolves only `.build/debug/CockpitHost`, connects an active peer, sends SIGTERM, observes peer EOF, process exit 0, and socket removal.
- Direct proofs include `hostDataPlaneRawWireRejectsAckViolationAndRequestIDReuse`, `hostDataPlaneLocalTransportNumericApplyErrorsSendOnceAndResynchronizeController`, `hostDataPlaneHostShutdownCoordinatorOrdersAdmittedReplyServerAndListener`, `hostDataPlaneModuleBoundaryKeepsSIGTERMCompositionInFrozenOrder`, and `hostDataPlaneCockpitHostSIGTERMStopsTicketsUnlinksSocketAndExits`.

### M1 — sequence overflow before trap

Resolved.

- Every mutable client/server channel transition uses `addingReportingOverflow` through `hostDataPlaneAdvanceSequence`.
- Server outgoing state stores the last emitted sequence, so `UInt64.max - 1` advances to and emits the final legal `UInt64.max`; the following transition fails before arithmetic overflow.
- Direct proof: `hostDataPlaneModuleBoundaryGuardsEverySequenceTransitionBeforeOverflow`.

## Final verification

- Frozen focused gate:
  - Command: `swift test --disable-automatic-resolution --filter '^CockpitLocalTransportTests\.hostDataPlane' --xunit-output .build/task10b-fix-round1-final.xml`
  - Exit: 0.
  - Result: 42 tests, 0 failures, 0 skipped, 0.8238475 seconds.
- Count gate:
  - `swift test list --skip-build` filtered expected: 42.
  - `.build/task10b-fix-round1-final-swift-testing.xml` actual: 42.
- Target build:
  - Command: `swift build --disable-automatic-resolution --target CockpitLocalTransport`.
  - Exit: 0; 36.52 seconds.
- `git diff --check`: exit 0.
- Full suite: not run, as required by the frozen Task 10B verification scope.

## Changed files

- `Applications/CockpitHost/main.swift`
- `Sources/CockpitLocalTransport/HostDataPlaneClient.swift`
- `Sources/CockpitLocalTransport/HostDataPlaneServer.swift`
- `Sources/CockpitLocalTransport/HostDataPlaneTicket.swift`
- `Sources/CockpitLocalTransport/HostXPCExport.swift`
- `Sources/CockpitLocalTransport/UnixDomainSocket.swift`
- `Tests/CockpitLocalTransportTests/HostDataPlaneModuleBoundaryTests.swift`
- `Tests/CockpitLocalTransportTests/HostDataPlaneTests.swift`
