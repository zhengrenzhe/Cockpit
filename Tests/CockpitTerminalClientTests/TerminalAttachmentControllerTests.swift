import Foundation
import Testing
import CockpitTerminalCore
import CockpitTypes
@_spi(CockpitTerminalApp) @testable import CockpitTerminalClient

@Test func terminalAttachmentForwardsResumeSequenceAndDetachDoesNotTerminate() async throws {
    let sessionID = TerminalSessionID()
    let connection = RecordingTerminalDataConnection()
    let data = RecordingTerminalDataTransport(connection: connection)
    let control = RecordingTerminalControlTransport()
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view, .input, .resize],
        controlTransport: control,
        dataTransport: data
    )

    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: 41)
    #expect(await control.issuedSessions == [sessionID])
    #expect(await data.resumeSequences == [41])

    await controller.detach()
    #expect(await connection.detachCount == 1)
    #expect(await control.terminateCount == 0)
}

@Test func terminalAttachmentEmitsRetainedDeltaAndSnapshotFallback() async throws {
    let delta = try TerminalOutputFrame(
        firstOutputSequence: 8,
        outputSequence: 9,
        kind: .delta,
        fragments: [Data("delta".utf8)]
    )
    let snapshot = try TerminalOutputFrame(
        firstOutputSequence: 20,
        outputSequence: 20,
        kind: .snapshot,
        fragments: [Data("snapshot".utf8)]
    )
    let first = RecordingTerminalDataConnection(frames: [delta])
    let second = RecordingTerminalDataConnection(frames: [snapshot])
    let data = RecordingTerminalDataTransport(connections: [first, second])
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: data
    )
    let events = await controller.events()
    let collector = Task { () -> [TerminalOutputFrame] in
        var frames: [TerminalOutputFrame] = []
        for await event in events {
            if case let .frame(_, frame) = event {
                frames.append(frame)
                if frames.count == 2 { return frames }
            }
        }
        return frames
    }

    try await controller.attach(sessionID: TerminalSessionID(), lastAcknowledgedSequence: 7)
    try await eventually { await first.didDrain }
    try await controller.attach(sessionID: TerminalSessionID(), lastAcknowledgedSequence: 1)
    let received = try await withTimeout { await collector.value }

    #expect(received.map(\.kind) == [.delta, .snapshot])
    #expect(await data.resumeSequences == [7, 1])
    await controller.detach()
}

@Test func terminalAttachmentBoundsPausedEventConsumerWithoutDroppingDeltaChain() async throws {
    let connection = RecordingTerminalDataConnection()
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )
    let events = await controller.events()
    try await controller.attach(
        sessionID: TerminalSessionID(),
        lastAcknowledgedSequence: nil
    )
    let frameCount: UInt64 = 20
    for sequence in UInt64(1)...frameCount {
        await connection.push(
            try TerminalOutputFrame(
                firstOutputSequence: sequence,
                outputSequence: sequence,
                kind: sequence == 1 ? .snapshot : .delta,
                fragments: [Data([UInt8(sequence)])]
            )
        )
    }
    try await eventually { await connection.deliveredFrameCount == frameCount }

    var iterator = events.makeAsyncIterator()
    guard case .attached = await iterator.next() else {
        Issue.record("attached state was not retained ahead of frames")
        return
    }
    let first = try #require(await iterator.next())
    let second = try #require(await iterator.next())
    guard case let .frame(_, coalesced) = first,
          case let .frame(_, latest) = second else {
        Issue.record("bounded queue did not retain two frame events")
        return
    }

    #expect(coalesced.kind == .snapshot)
    #expect(coalesced.firstOutputSequence == 1)
    #expect(coalesced.outputSequence == 19)
    #expect(coalesced.fragments == (UInt8(1)...UInt8(19)).map { Data([$0]) })
    #expect(latest.outputSequence == 20)
    #expect(latest.fragments == [Data([20])])
    await controller.detach()
}

@Test func terminalAttachmentDropsEventsFromOldGeneration() async throws {
    let stale = RecordingTerminalDataConnection()
    let current = RecordingTerminalDataConnection()
    let data = RecordingTerminalDataTransport(connections: [stale, current])
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: data
    )
    let events = await controller.events()
    let collector = Task { () -> TerminalOutputFrame? in
        for await event in events {
            if case let .frame(_, frame) = event { return frame }
        }
        return nil
    }

    try await controller.attach(sessionID: TerminalSessionID(), lastAcknowledgedSequence: nil)
    try await controller.attach(sessionID: TerminalSessionID(), lastAcknowledgedSequence: nil)
    let staleFrame = try TerminalOutputFrame(
        firstOutputSequence: 1,
        outputSequence: 1,
        fragments: [Data("stale".utf8)]
    )
    let currentFrame = try TerminalOutputFrame(
        firstOutputSequence: 2,
        outputSequence: 2,
        fragments: [Data("current".utf8)]
    )
    await stale.push(staleFrame)
    await current.push(currentFrame)

    let received = try await withTimeout { await collector.value }
    #expect(received == currentFrame)
    await controller.detach()
}

@Test func terminalAttachmentKeepsSecondViewerReadOnlyWhenInputLeaseIsHeld() async throws {
    let clientID = ClientInstanceID()
    let sessionID = TerminalSessionID()
    let connection = RecordingTerminalDataConnection(frames: [
        try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("read-only".utf8)]
        ),
    ])
    let control = RecordingTerminalControlTransport(acquireError: .leaseHeld)
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: .all,
        controlTransport: control,
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )
    let events = await controller.events()
    let frameCollector = Task { () -> TerminalOutputFrame? in
        for await event in events {
            if case let .frame(_, frame) = event { return frame }
        }
        return nil
    }
    defer { frameCollector.cancel() }

    let identity = try await controller.attach(
        sessionID: sessionID,
        lastAcknowledgedSequence: nil
    )
    let frame = try await withTimeout { await frameCollector.value }
    #expect(identity.sessionID == sessionID)
    #expect(frame?.fragments == [Data("read-only".utf8)])
    #expect(await connection.detachCount == 0)

    let context = try RequestContext(
        validating: .current,
        clientInstanceID: clientID,
        windowID: WindowID(),
        workspaceContextID: .project(ProjectID()),
        environmentID: EnvironmentID(),
        activeContextGeneration: 1,
        requestID: RequestID()
    )
    func input(_ payload: TerminalInput.Payload) throws -> TerminalInput {
        try TerminalInput(
            validatingContext: context,
            terminalSessionID: sessionID,
            inputLeaseID: InputLeaseID(),
            inputSequence: 1,
            payload: payload
        )
    }

    await #expect(throws: TerminalStreamError.inputLeaseRequired) {
        try await controller.send(input(.text("blocked")))
    }
    await #expect(throws: TerminalStreamError.inputLeaseRequired) {
        try await controller.send(input(.resize(
            try TerminalResize(validatingColumns: 120, rows: 40)
        )))
    }
    await #expect(throws: TerminalStreamError.inputLeaseRequired) {
        _ = try await controller.signal(.interrupt)
    }
    await #expect(throws: TerminalStreamError.inputLeaseRequired) {
        try await controller.terminate(force: false)
    }
    #expect(await connection.sentInputs.isEmpty)
    #expect(await control.signalRequests.isEmpty)
    #expect(await control.terminateRequests.isEmpty)

    await controller.detach()
    #expect(await connection.detachCount == 1)
    #expect(await control.releasedLeases.isEmpty)
}

@Test func terminalAttachmentOwnsLeaseAndInputSequenceAndReleasesOnDetach() async throws {
    let clientID = ClientInstanceID()
    let sessionID = TerminalSessionID()
    let lease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: ViewerID(clientID.rawValue),
        sequenceBase: 41,
        capabilities: [.input, .resize, .signal]
    )
    let control = RecordingTerminalControlTransport(lease: lease)
    let connection = RecordingTerminalDataConnection()
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: [.view, .input, .resize, .signal],
        controlTransport: control,
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )

    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
    let supplied = try TerminalInput(
        validatingContext: RequestContext(
            validating: .current,
            clientInstanceID: clientID,
            windowID: WindowID(),
            workspaceContextID: .project(ProjectID()),
            environmentID: EnvironmentID(),
            activeContextGeneration: 1,
            requestID: RequestID()
        ),
        terminalSessionID: sessionID,
        inputLeaseID: InputLeaseID(),
        inputSequence: 999,
        payload: .text("first")
    )
    try await controller.send(supplied)
    let signal = try TerminalInput(
        validatingContext: supplied.context,
        terminalSessionID: supplied.terminalSessionID,
        inputLeaseID: supplied.inputLeaseID,
        inputSequence: supplied.inputSequence,
        payload: .signal(.interrupt)
    )
    try await controller.send(signal)
    try await controller.send(supplied)

    let sent = await connection.sentInputs
    #expect(sent.map(\.inputLeaseID) == [lease.leaseID, lease.leaseID, lease.leaseID])
    #expect(sent.map(\.inputSequence) == [41, 42, 43])
    #expect(await control.acquiredSessions == [sessionID])
    await controller.detach()
    #expect(await control.releasedLeases == [lease.leaseID])
}

@Test func terminalAttachmentRoutesSignalAndTerminateThroughTheCurrentControlLease() async throws {
    let sessionID = TerminalSessionID()
    let viewerID = ViewerID()
    let lease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: viewerID,
        sequenceBase: 1,
        capabilities: [.signal, .terminate]
    )
    let control = RecordingTerminalControlTransport(lease: lease)
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(viewerID.rawValue),
        requestedCapabilities: [.view, .signal, .terminate],
        controlTransport: control,
        dataTransport: RecordingTerminalDataTransport(
            connection: RecordingTerminalDataConnection()
        )
    )

    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
    let foregroundGroup = try await controller.signal(.interrupt)
    try await controller.terminate(force: true)

    #expect(foregroundGroup == 404)
    #expect(await control.signalRequests == [
        .init(sessionID: sessionID, viewerID: viewerID, leaseID: lease.leaseID, signal: .interrupt),
    ])
    #expect(await control.terminateRequests == [
        .init(sessionID: sessionID, viewerID: viewerID, leaseID: lease.leaseID, force: true),
    ])
    await controller.detach()
}

@Test func terminalAttachmentCannotInstallAStaleConnectionAfterVisibleAwait() async throws {
    let stale = RecordingTerminalDataConnection(blockVisible: true)
    let current = RecordingTerminalDataConnection()
    let data = RecordingTerminalDataTransport(connections: [stale, current])
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: data
    )
    let first = Task {
        try await controller.attach(
            sessionID: TerminalSessionID(),
            lastAcknowledgedSequence: nil
        )
    }
    try await eventually { await stale.visibleIsBlocked }
    let currentSession = TerminalSessionID()
    try await controller.attach(sessionID: currentSession, lastAcknowledgedSequence: nil)
    await stale.releaseVisible()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await stale.detachCount == 1)
    #expect(await current.detachCount == 0)
    await controller.detach()
}

@Test func terminalAttachmentRetiresProvisionalViewerAndReplaysLatestVisibility() async throws {
    let data = ExclusiveTerminalDataTransport(blockFirstVisible: true)
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: data
    )
    let first = Task {
        try await controller.attach(
            sessionID: TerminalSessionID(),
            lastAcknowledgedSequence: nil
        )
    }
    try await eventually { await data.firstVisibleIsBlocked }
    await controller.setVisible(false)

    let secondSession = TerminalSessionID()
    let second = Task {
        do {
            try await controller.attach(
                sessionID: secondSession,
                lastAcknowledgedSequence: nil
            )
            return Result<Void, any Error>.success(())
        } catch {
            return Result<Void, any Error>.failure(error)
        }
    }
    let secondResult = await second.value
    await data.releaseFirstVisible()
    _ = await first.result

    switch secondResult {
    case .success:
        break
    case let .failure(error):
        Issue.record("successor attach failed after the provisional viewer was retired: \(error)")
    }
    #expect(await data.firstDetachCount == 1)
    #expect(await data.secondVisibility == [false])
    await controller.detach()
}

@Test func terminalAttachmentReplaysVisibilityChangedWhileLeaseAcquireIsBlocked() async throws {
    let clientID = ClientInstanceID()
    let connection = RecordingTerminalDataConnection()
    let control = RecordingTerminalControlTransport(blockAcquire: true)
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: [.view, .input],
        controlTransport: control,
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )
    let attaching = Task {
        try await controller.attach(
            sessionID: TerminalSessionID(),
            lastAcknowledgedSequence: nil
        )
    }
    try await eventually { await control.acquireIsBlocked }

    await controller.setVisible(false)
    await control.releaseBlockedAcquire()
    try await attaching.value

    #expect(await connection.visibility == [true, false])
    await controller.detach()
}

@Test func terminalAttachmentClosesViewerBeforeBlockedLeaseReleaseAndAllowsSuccessor() async throws {
    let clientID = ClientInstanceID()
    let lease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: ViewerID(clientID.rawValue),
        sequenceBase: 1,
        capabilities: [.input]
    )
    let control = RecordingTerminalControlTransport(lease: lease, blockRelease: true)
    let data = ExclusiveTerminalDataTransport()
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: [.view, .input],
        controlTransport: control,
        dataTransport: data
    )
    try await controller.attach(sessionID: TerminalSessionID(), lastAcknowledgedSequence: nil)

    let detaching = Task { await controller.detach() }
    try await eventually { await control.releaseIsBlocked }
    #expect(await data.firstDetachCount == 1)

    let successor = Task {
        do {
            try await controller.attach(
                sessionID: TerminalSessionID(),
                lastAcknowledgedSequence: nil
            )
            return Result<Void, any Error>.success(())
        } catch {
            return Result<Void, any Error>.failure(error)
        }
    }
    try await Task.sleep(for: .milliseconds(25))
    await control.releaseBlockedLease()
    await detaching.value
    switch await successor.value {
    case .success:
        #expect(await data.connectionCount == 2)
        let finalDetach = Task { await controller.detach() }
        try await eventually { await control.releaseIsBlocked }
        await control.releaseBlockedLease()
        await finalDetach.value
    case let .failure(error):
        Issue.record("successor attach failed while the retired lease release was pending: \(error)")
    }
}

@Test func terminalAttachmentSerializesConcurrentInputSequencesUntilExactACK() async throws {
    let clientID = ClientInstanceID()
    let sessionID = TerminalSessionID()
    let lease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: ViewerID(clientID.rawValue),
        sequenceBase: 41,
        capabilities: [.input]
    )
    let connection = InputAckBarrierConnection(sequenceBase: 41)
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: [.view, .input],
        controlTransport: RecordingTerminalControlTransport(lease: lease),
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )
    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
    let context = try RequestContext(
        validating: .current,
        clientInstanceID: clientID,
        windowID: WindowID(),
        workspaceContextID: .project(ProjectID()),
        environmentID: EnvironmentID(),
        activeContextGeneration: 1,
        requestID: RequestID()
    )
    let firstInput = try TerminalInput(
        validatingContext: context,
        terminalSessionID: sessionID,
        inputLeaseID: lease.leaseID,
        inputSequence: 999,
        payload: .text("first")
    )
    let secondInput = try TerminalInput(
        validatingContext: context,
        terminalSessionID: sessionID,
        inputLeaseID: lease.leaseID,
        inputSequence: 999,
        payload: .text("second")
    )
    let first = Task { try await controller.send(firstInput) }
    try await eventually { await connection.firstACKIsBlocked }
    let second = Task { try await controller.send(secondInput) }
    try await Task.sleep(for: .milliseconds(25))
    await connection.releaseFirstACK()
    try await first.value
    try await second.value

    #expect(await connection.receivedSequences == [41, 42])
    #expect(await connection.performedPayloads == [.text("first"), .text("second")])
    await controller.detach()
}

@Test func terminalAttachmentCancelledQueuedInputNeverReachesCLIOrConsumesSequence() async throws {
    let clientID = ClientInstanceID()
    let sessionID = TerminalSessionID()
    let lease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: ViewerID(clientID.rawValue),
        sequenceBase: 41,
        capabilities: [.input]
    )
    let connection = InputAckBarrierConnection(sequenceBase: 41)
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: [.view, .input],
        controlTransport: RecordingTerminalControlTransport(lease: lease),
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )
    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
    let context = try RequestContext(
        validating: .current,
        clientInstanceID: clientID,
        windowID: WindowID(),
        workspaceContextID: .project(ProjectID()),
        environmentID: EnvironmentID(),
        activeContextGeneration: 1,
        requestID: RequestID()
    )
    func input(_ text: String) throws -> TerminalInput {
        try TerminalInput(
            validatingContext: context,
            terminalSessionID: sessionID,
            inputLeaseID: lease.leaseID,
            inputSequence: 999,
            payload: .text(text)
        )
    }

    let first = Task { try await controller.send(input("first")) }
    try await eventually { await connection.firstACKIsBlocked }
    let cancellation = TerminalSendCompletionProbe()
    let cancelled = Task {
        do {
            try await controller.send(input("cancelled"))
            await cancellation.finish(cancelled: false)
        } catch is CancellationError {
            await cancellation.finish(cancelled: true)
        } catch {
            await cancellation.finish(cancelled: false)
        }
    }
    cancelled.cancel()
    let finishedBeforeFirstACK: Bool
    do {
        try await eventually { await cancellation.finished }
        finishedBeforeFirstACK = true
    } catch {
        finishedBeforeFirstACK = false
    }
    #expect(finishedBeforeFirstACK)
    #expect(await cancellation.wasCancelled)
    await connection.releaseFirstACK()
    try await first.value
    await cancelled.value
    try await controller.send(input("third"))

    #expect(await connection.receivedSequences == [41, 42])
    #expect(await connection.performedPayloads == [.text("first"), .text("third")])
    await controller.detach()
}

@Test func terminalAttachmentDetachLetsAdmittedInputFinishAndCancelsOnlyQueuedInput() async throws {
    let clientID = ClientInstanceID()
    let sessionID = TerminalSessionID()
    let lease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: ViewerID(clientID.rawValue),
        sequenceBase: 41,
        capabilities: [.input]
    )
    let connection = InputAckBarrierConnection(sequenceBase: 41)
    let controller = TerminalAttachmentController(
        clientInstanceID: clientID,
        requestedCapabilities: [.view, .input],
        controlTransport: RecordingTerminalControlTransport(lease: lease),
        dataTransport: RecordingTerminalDataTransport(connection: connection)
    )
    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: nil)
    let context = try RequestContext(
        validating: .current,
        clientInstanceID: clientID,
        windowID: WindowID(),
        workspaceContextID: .project(ProjectID()),
        environmentID: EnvironmentID(),
        activeContextGeneration: 1,
        requestID: RequestID()
    )
    func input(_ text: String) throws -> TerminalInput {
        try TerminalInput(
            validatingContext: context,
            terminalSessionID: sessionID,
            inputLeaseID: lease.leaseID,
            inputSequence: 999,
            payload: .text(text)
        )
    }

    let admitted = Task { try await controller.send(input("admitted")) }
    try await eventually { await connection.firstACKIsBlocked }
    let queuedCompletion = TerminalSendCompletionProbe()
    let queued = Task { () -> Bool in
        do {
            try await controller.send(input("queued"))
            await queuedCompletion.finish(cancelled: false)
            return false
        } catch is CancellationError {
            await queuedCompletion.finish(cancelled: true)
            return true
        } catch {
            await queuedCompletion.finish(cancelled: false)
            return false
        }
    }
    let detachCompletion = TerminalOperationCompletionProbe()
    let detaching = Task {
        await controller.detach()
        await detachCompletion.finish()
    }

    try await eventually { await queuedCompletion.finished }
    #expect(!(await detachCompletion.finished))
    await connection.releaseFirstACK()
    try await admitted.value
    #expect(await queued.value)
    await detaching.value
    #expect(await connection.performedPayloads == [.text("admitted")])
}

@Test func terminalAttachmentDetachLetsAdmittedSignalAndTerminateReturnExactSuccess() async throws {
    let signalViewer = ViewerID()
    let signalLease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: signalViewer,
        sequenceBase: 1,
        capabilities: [.signal]
    )
    let signalControl = RecordingTerminalControlTransport(
        lease: signalLease,
        blockSignal: true
    )
    let signalController = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(signalViewer.rawValue),
        requestedCapabilities: [.view, .signal],
        controlTransport: signalControl,
        dataTransport: RecordingTerminalDataTransport(
            connection: RecordingTerminalDataConnection()
        )
    )
    try await signalController.attach(
        sessionID: TerminalSessionID(),
        lastAcknowledgedSequence: nil
    )
    let signaling = Task { try await signalController.signal(.interrupt) }
    try await eventually { await signalControl.signalIsBlocked }
    let signalDetach = TerminalOperationCompletionProbe()
    let detachingSignal = Task {
        await signalController.detach()
        await signalDetach.finish()
    }
    try await Task.sleep(for: .milliseconds(25))
    #expect(!(await signalDetach.finished))
    await signalControl.releaseBlockedSignal()
    #expect(try await signaling.value == 404)
    await detachingSignal.value

    let terminateViewer = ViewerID()
    let terminateLease = try InputLeaseGrant(
        validatingLeaseID: InputLeaseID(),
        holderViewerID: terminateViewer,
        sequenceBase: 1,
        capabilities: [.terminate]
    )
    let terminateControl = RecordingTerminalControlTransport(
        lease: terminateLease,
        blockTerminate: true
    )
    let terminateController = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(terminateViewer.rawValue),
        requestedCapabilities: [.view, .terminate],
        controlTransport: terminateControl,
        dataTransport: RecordingTerminalDataTransport(
            connection: RecordingTerminalDataConnection()
        )
    )
    try await terminateController.attach(
        sessionID: TerminalSessionID(),
        lastAcknowledgedSequence: nil
    )
    let terminating = Task { try await terminateController.terminate(force: true) }
    try await eventually { await terminateControl.terminateIsBlocked }
    let terminateDetach = TerminalOperationCompletionProbe()
    let detachingTerminate = Task {
        await terminateController.detach()
        await terminateDetach.finish()
    }
    try await Task.sleep(for: .milliseconds(25))
    #expect(!(await terminateDetach.finished))
    await terminateControl.releaseBlockedTerminate()
    try await terminating.value
    await detachingTerminate.value
}

@Test func terminalFrameClientRequiresSnapshotForInitialDeltaWithoutResumeBaseline() async throws {
    let client = TerminalFrameClient(lastAcknowledgedSequence: nil)
    let delta = try TerminalOutputFrame(
        firstOutputSequence: 1,
        outputSequence: 1,
        kind: .delta,
        fragments: [Data("delta".utf8)]
    )
    guard case .requiresSnapshot = await client.accept(delta) else {
        Issue.record("initial delta was accepted without a snapshot baseline")
        return
    }
}

@Test func terminalFrameClientDoesNotTreatInitialScrollbackAsViewportBaseline() async throws {
    let client = TerminalFrameClient(lastAcknowledgedSequence: nil)
    let scrollback = try TerminalOutputFrame(
        firstOutputSequence: 1,
        outputSequence: 1,
        kind: .scrollback,
        fragments: [Data("scrollback".utf8)]
    )
    let delta = try TerminalOutputFrame(
        firstOutputSequence: 2,
        outputSequence: 2,
        kind: .delta,
        fragments: [Data("delta".utf8)]
    )

    guard case .accepted = await client.accept(scrollback) else {
        Issue.record("initial scrollback was not delivered")
        return
    }
    guard case .requiresSnapshot = await client.accept(delta) else {
        Issue.record("scrollback incorrectly established a viewport baseline")
        return
    }
}

@Test func terminalAttachmentDropsDuplicateAndGappedDeltaAndReconnectsForSnapshot() async throws {
    let sessionID = TerminalSessionID()
    let first = RecordingTerminalDataConnection()
    let recovery = RecordingTerminalDataConnection()
    let data = RecordingTerminalDataTransport(connections: [first, recovery])
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: data
    )
    let events = await controller.events()
    let collector = Task { () -> [TerminalOutputFrame] in
        var values: [TerminalOutputFrame] = []
        for await event in events {
            if case let .frame(_, frame) = event {
                values.append(frame)
                if values.count == 2 { return values }
            }
        }
        return values
    }

    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: 4)
    let accepted = try TerminalOutputFrame(
        firstOutputSequence: 5,
        outputSequence: 5,
        kind: .delta,
        fragments: [Data("five".utf8)]
    )
    await first.push(accepted)
    await first.push(accepted)
    await first.push(
        try TerminalOutputFrame(
            firstOutputSequence: 8,
            outputSequence: 8,
            kind: .delta,
            fragments: [Data("gap".utf8)]
        )
    )
    try await eventually { await data.resumeSequences.count == 2 }
    #expect(await data.resumeSequences == [4, nil])
    let snapshot = try TerminalOutputFrame(
        firstOutputSequence: 9,
        outputSequence: 9,
        kind: .snapshot,
        fragments: [Data("snapshot".utf8)]
    )
    await recovery.push(snapshot)
    let received = try await withTimeout { await collector.value }
    #expect(received == [accepted, snapshot])
    await controller.detach()
}

@Test func terminalAttachmentReportsSnapshotRecoveryFailureFromRecoveryGeneration() async throws {
    let sessionID = TerminalSessionID()
    let first = RecordingTerminalDataConnection()
    let data = RecordingTerminalDataTransport(connections: [first])
    let controller = TerminalAttachmentController(
        clientInstanceID: ClientInstanceID(),
        requestedCapabilities: [.view],
        controlTransport: RecordingTerminalControlTransport(),
        dataTransport: data
    )
    let events = await controller.events()
    let probe = TerminalFailureProbe()
    let collector = Task {
        for await event in events {
            if case let .failed(_, message) = event {
                await probe.record(message)
                return
            }
        }
    }
    defer { collector.cancel() }

    try await controller.attach(sessionID: sessionID, lastAcknowledgedSequence: 4)
    await first.push(
        try TerminalOutputFrame(
            firstOutputSequence: 8,
            outputSequence: 8,
            kind: .delta,
            fragments: [Data("gap".utf8)]
        )
    )

    try await eventually { await probe.message != nil }
    #expect(await probe.message?.contains("snapshotRecoveryFailed") == true)
}

private actor RecordingTerminalControlTransport: TerminalControlTransport {
    struct SignalRequest: Equatable, Sendable {
        let sessionID: TerminalSessionID
        let viewerID: ViewerID
        let leaseID: InputLeaseID
        let signal: TerminalSignal
    }

    struct TerminateRequest: Equatable, Sendable {
        let sessionID: TerminalSessionID
        let viewerID: ViewerID
        let leaseID: InputLeaseID
        let force: Bool
    }

    private(set) var issuedSessions: [TerminalSessionID] = []
    private(set) var terminateCount = 0
    private(set) var acquiredSessions: [TerminalSessionID] = []
    private(set) var releasedLeases: [InputLeaseID] = []
    private(set) var signalRequests: [SignalRequest] = []
    private(set) var terminateRequests: [TerminateRequest] = []
    private let lease: InputLeaseGrant?
    private let acquireError: TerminalStreamError?
    private let blockAcquire: Bool
    private let blockRelease: Bool
    private let blockSignal: Bool
    private let blockTerminate: Bool
    private var acquireContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var signalContinuation: CheckedContinuation<Void, Never>?
    private var terminateContinuation: CheckedContinuation<Void, Never>?

    init(
        lease: InputLeaseGrant? = nil,
        acquireError: TerminalStreamError? = nil,
        blockAcquire: Bool = false,
        blockRelease: Bool = false,
        blockSignal: Bool = false,
        blockTerminate: Bool = false
    ) {
        self.lease = lease
        self.acquireError = acquireError
        self.blockAcquire = blockAcquire
        self.blockRelease = blockRelease
        self.blockSignal = blockSignal
        self.blockTerminate = blockTerminate
    }

    var acquireIsBlocked: Bool { acquireContinuation != nil }
    var releaseIsBlocked: Bool { releaseContinuation != nil }
    var signalIsBlocked: Bool { signalContinuation != nil }
    var terminateIsBlocked: Bool { terminateContinuation != nil }

    func releaseBlockedAcquire() {
        acquireContinuation?.resume()
        acquireContinuation = nil
    }

    func releaseBlockedLease() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func releaseBlockedSignal() {
        signalContinuation?.resume()
        signalContinuation = nil
    }

    func releaseBlockedTerminate() {
        terminateContinuation?.resume()
        terminateContinuation = nil
    }

    func issueAttachTicket(
        sessionID: TerminalSessionID,
        clientInstanceID: ClientInstanceID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> TerminalAttachAuthorization {
        issuedSessions.append(sessionID)
        let workerID = WorkerInstanceID()
        return TerminalAttachAuthorization(
            endpoint: try KeeperEndpoint(
                path: "/private/tmp/cockpit-test/keeper.sock",
                sessionID: sessionID,
                workerID: workerID
            ),
            wireTicket: String(repeating: "A", count: 43),
            binding: TerminalAttachBinding(
                sessionID: sessionID,
                workerID: workerID,
                clientInstanceID: clientInstanceID
            ),
            viewerID: viewerID,
            capabilities: capabilities
        )
    }

    func acquireInputLease(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        capabilities: TerminalAttachCapabilities
    ) async throws -> InputLeaseGrant {
        acquiredSessions.append(sessionID)
        if blockAcquire {
            await withCheckedContinuation { acquireContinuation = $0 }
        }
        if let acquireError { throw acquireError }
        if let lease { return lease }
        return try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: viewerID,
            sequenceBase: 1,
            capabilities: capabilities
        )
    }

    func releaseInputLease(
        sessionID: TerminalSessionID,
        leaseID: InputLeaseID
    ) async throws {
        releasedLeases.append(leaseID)
        if blockRelease {
            await withCheckedContinuation { releaseContinuation = $0 }
        }
    }

    func signal(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        signal: TerminalSignal
    ) async throws -> Int32 {
        signalRequests.append(
            SignalRequest(
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                signal: signal
            )
        )
        if blockSignal {
            await withCheckedContinuation { signalContinuation = $0 }
        }
        return 404
    }

    func terminate(
        sessionID: TerminalSessionID,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        force: Bool
    ) async throws {
        terminateCount += 1
        terminateRequests.append(
            TerminateRequest(
                sessionID: sessionID,
                viewerID: viewerID,
                leaseID: leaseID,
                force: force
            )
        )
        if blockTerminate {
            await withCheckedContinuation { terminateContinuation = $0 }
        }
    }
}

private actor TerminalOperationCompletionProbe {
    private(set) var finished = false
    func finish() { finished = true }
}


private actor TerminalFailureProbe {
    private(set) var message: String?

    func record(_ message: String) { self.message = message }
}

private actor TerminalSendCompletionProbe {
    private(set) var finished = false
    private(set) var wasCancelled = false

    func finish(cancelled: Bool) {
        finished = true
        wasCancelled = cancelled
    }
}

private actor RecordingTerminalDataTransport: TerminalDataTransport {
    private var connections: [any TerminalDataConnection]
    private(set) var resumeSequences: [UInt64?] = []

    init(connection: any TerminalDataConnection) { connections = [connection] }
    init(connections: [any TerminalDataConnection]) { self.connections = connections }

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        resumeSequences.append(lastAcknowledgedSequence)
        guard !connections.isEmpty else { throw TestTerminalDataError.snapshotRecoveryFailed }
        return connections.removeFirst()
    }
}

private actor ExclusiveTerminalDataTransport: TerminalDataTransport {
    private let blockFirstVisible: Bool
    private var activeConnection: UUID?
    private var connections: [ExclusiveTerminalDataConnection] = []
    private(set) var connectionCount = 0

    init(blockFirstVisible: Bool = false) {
        self.blockFirstVisible = blockFirstVisible
    }

    var firstVisibleIsBlocked: Bool {
        get async { await connections.first?.visibleIsBlocked ?? false }
    }
    var firstDetachCount: Int {
        get async { await connections.first?.detachCount ?? 0 }
    }
    var secondVisibility: [Bool] {
        get async { await connections.count > 1 ? connections[1].visibility : [] }
    }

    func attach(
        authorization: TerminalAttachAuthorization,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> any TerminalDataConnection {
        guard activeConnection == nil else { throw TerminalStreamError.viewerAlreadyAttached }
        let id = UUID()
        let connection = ExclusiveTerminalDataConnection(
            id: id,
            owner: self,
            blockFirstVisible: blockFirstVisible && connections.isEmpty
        )
        activeConnection = id
        connections.append(connection)
        connectionCount += 1
        return connection
    }

    func release(_ id: UUID) {
        if activeConnection == id { activeConnection = nil }
    }

    func releaseFirstVisible() async { await connections.first?.releaseVisible() }
}

private actor ExclusiveTerminalDataConnection: TerminalDataConnection {
    let id: UUID
    private let owner: ExclusiveTerminalDataTransport
    private let blockFirstVisible: Bool
    private var visibleContinuation: CheckedContinuation<Void, Never>?
    private var outputContinuation: CheckedContinuation<TerminalOutputFrame?, Never>?
    private(set) var visibility: [Bool] = []
    private(set) var detachCount = 0

    init(
        id: UUID,
        owner: ExclusiveTerminalDataTransport,
        blockFirstVisible: Bool
    ) {
        self.id = id
        self.owner = owner
        self.blockFirstVisible = blockFirstVisible
    }

    var visibleIsBlocked: Bool { visibleContinuation != nil }
    func nextOutput() async throws -> TerminalOutputFrame? {
        await withCheckedContinuation { outputContinuation = $0 }
    }
    func send(_ input: TerminalInput) async throws -> UInt64 { input.inputSequence }
    func setVisible(_ visible: Bool) async throws {
        visibility.append(visible)
        if blockFirstVisible, visibility.count == 1 {
            await withCheckedContinuation { visibleContinuation = $0 }
        }
    }
    func releaseVisible() {
        visibleContinuation?.resume()
        visibleContinuation = nil
    }
    func detach() async {
        detachCount += 1
        releaseVisible()
        outputContinuation?.resume(returning: nil)
        outputContinuation = nil
        await owner.release(id)
    }
}

private actor InputAckBarrierConnection: TerminalDataConnection {
    private var expectedSequence: UInt64
    private var firstACKContinuation: CheckedContinuation<Void, Never>?
    private var outputContinuation: CheckedContinuation<TerminalOutputFrame?, Never>?
    private(set) var receivedSequences: [UInt64] = []
    private(set) var performedPayloads: [TerminalInput.Payload] = []

    init(sequenceBase: UInt64) { expectedSequence = sequenceBase }

    var firstACKIsBlocked: Bool { firstACKContinuation != nil }
    func nextOutput() async throws -> TerminalOutputFrame? {
        await withCheckedContinuation { outputContinuation = $0 }
    }
    func setVisible(_ visible: Bool) async throws {}
    func detach() async {
        firstACKContinuation?.resume()
        firstACKContinuation = nil
        outputContinuation?.resume(returning: nil)
        outputContinuation = nil
    }
    func send(_ input: TerminalInput) async throws -> UInt64 {
        receivedSequences.append(input.inputSequence)
        if input.inputSequence < expectedSequence { return input.inputSequence }
        guard input.inputSequence == expectedSequence else {
            throw TerminalStreamError.nonMonotonicInputSequence
        }
        performedPayloads.append(input.payload)
        expectedSequence += 1
        if performedPayloads.count == 1 {
            await withCheckedContinuation { firstACKContinuation = $0 }
        }
        return input.inputSequence
    }
    func releaseFirstACK() {
        firstACKContinuation?.resume()
        firstACKContinuation = nil
    }
}

private actor RecordingTerminalDataConnection: TerminalDataConnection {
    private var frames: [TerminalOutputFrame]
    private var waiter: CheckedContinuation<TerminalOutputFrame?, Never>?
    private(set) var detachCount = 0
    private(set) var didDrain = false
    private(set) var deliveredFrameCount: UInt64 = 0
    private(set) var sentInputs: [TerminalInput] = []
    private(set) var visibility: [Bool] = []
    private let blockVisible: Bool
    private var visibleContinuation: CheckedContinuation<Void, Never>?

    init(frames: [TerminalOutputFrame] = [], blockVisible: Bool = false) {
        self.frames = frames
        self.blockVisible = blockVisible
    }

    var visibleIsBlocked: Bool { visibleContinuation != nil }

    func nextOutput() async throws -> TerminalOutputFrame? {
        if !frames.isEmpty {
            let value = frames.removeFirst()
            didDrain = true
            deliveredFrameCount += 1
            return value
        }
        let value = await withCheckedContinuation { waiter = $0 }
        if value != nil { deliveredFrameCount += 1 }
        return value
    }

    func push(_ frame: TerminalOutputFrame) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func send(_ input: TerminalInput) async throws -> UInt64 {
        sentInputs.append(input)
        return input.inputSequence
    }
    func setVisible(_ visible: Bool) async throws {
        visibility.append(visible)
        if blockVisible {
            await withCheckedContinuation { visibleContinuation = $0 }
        }
    }
    func releaseVisible() {
        visibleContinuation?.resume()
        visibleContinuation = nil
    }
    func detach() async {
        detachCount += 1
        waiter?.resume(returning: nil)
        waiter = nil
    }
}

private enum TestTerminalDataError: Error { case snapshotRecoveryFailed }
private enum TestTimeout: Error { case expired }

private func eventually(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw TestTimeout.expired
}

private func withTimeout<Value: Sendable>(
    _ operation: @escaping @Sendable () async -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(2))
            throw TestTimeout.expired
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}
