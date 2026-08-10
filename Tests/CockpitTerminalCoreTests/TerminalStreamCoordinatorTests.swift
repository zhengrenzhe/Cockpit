import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("TerminalStreamCoordinatorTests")
struct TerminalStreamCoordinatorTests {
    @Test func boundedOutputBufferKeepsLatestFrameAndPeriodicSnapshotBoundsBytes() throws {
        var buffered: [TerminalOutputFrame] = []
        for sequence in UInt64(1)...20 {
            let frame = try TerminalOutputFrame(
                firstOutputSequence: sequence,
                outputSequence: sequence,
                kind: sequence.isMultiple(of: 2) ? .delta : .snapshot,
                fragments: [Data(repeating: UInt8(sequence), count: 1_024)]
            )
            TerminalOutputFrame.enqueueBounded(frame, into: &buffered)
        }

        #expect(buffered.count == 2)
        #expect(buffered.map(\.outputSequence) == [19, 20])
        #expect(buffered.flatMap(\.fragments).reduce(0) { $0 + $1.count } == 2_048)

        let replacement = try TerminalOutputFrame(
            firstOutputSequence: 21,
            outputSequence: 21,
            kind: .snapshot,
            fragments: [Data("replacement".utf8)]
        )
        TerminalOutputFrame.enqueueBounded(replacement, into: &buffered)
        #expect(buffered.count == 2)
        #expect(buffered[0].firstOutputSequence == 1)
        #expect(buffered[0].outputSequence == 20)
        #expect(buffered[1] == replacement)
    }

    @Test func coalescedSnapshotDeltaChainKeepsAuthoritativeBaselineKind() throws {
        let snapshot = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("snapshot".utf8)]
        )
        let firstDelta = try TerminalOutputFrame(
            firstOutputSequence: 2,
            outputSequence: 2,
            kind: .delta,
            fragments: [Data("delta-2".utf8)]
        )
        let secondDelta = try TerminalOutputFrame(
            firstOutputSequence: 3,
            outputSequence: 3,
            kind: .delta,
            fragments: [Data("delta-3".utf8)]
        )

        let firstMerge = TerminalOutputFrame.coalescing(snapshot, firstDelta)
        let merged = TerminalOutputFrame.coalescing(firstMerge, secondDelta)

        #expect(merged.kind == .snapshot)
        #expect(merged.firstOutputSequence == 1)
        #expect(merged.outputSequence == 3)
        #expect(merged.fragments == [
            Data("snapshot".utf8),
            Data("delta-2".utf8),
            Data("delta-3".utf8),
        ])
    }

    @Test func nestedCoalescingPreservesCompositeSnapshotBaselineChain() throws {
        let oldSnapshot = try TerminalOutputFrame(
            firstOutputSequence: 1,
            outputSequence: 1,
            kind: .snapshot,
            fragments: [Data("old-snapshot".utf8)]
        )
        let currentSnapshot = try TerminalOutputFrame(
            firstOutputSequence: 2,
            outputSequence: 2,
            kind: .snapshot,
            fragments: [Data("current-snapshot".utf8)]
        )
        let delta = try TerminalOutputFrame(
            firstOutputSequence: 3,
            outputSequence: 3,
            kind: .delta,
            fragments: [Data("delta".utf8)]
        )
        let composite = TerminalOutputFrame.coalescing(currentSnapshot, delta)

        let nested = TerminalOutputFrame.coalescing(oldSnapshot, composite)

        #expect(nested.kind == .snapshot)
        #expect(nested.fragments == [
            Data("current-snapshot".utf8),
            Data("delta".utf8),
        ])
    }

    @Test func attachConsumesOneTimeTicketAndRejectsBindingOrCapabilityEscalation() async throws {
        let fixture = StreamFixture()
        let valid = try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input])
        let attachment = try await fixture.coordinator.attach(valid)
        #expect(attachment.viewerID == fixture.viewerA)
        #expect(attachment.capabilities == [.view, .input])

        await #expect(throws: TerminalAttachTicketError.replay) {
            _ = try await fixture.coordinator.attach(valid)
        }

        let crossSession = try await fixture.issue(
            viewer: fixture.viewerB,
            capabilities: [.view],
            bindingSession: TerminalSessionID()
        )
        await #expect(throws: TerminalAttachTicketError.bindingMismatch) {
            _ = try await fixture.coordinator.attach(crossSession)
        }

        let escalation = try await fixture.issue(viewer: fixture.viewerB, capabilities: [.view])
        let escalated = AttachRequest(
            viewerID: escalation.viewerID,
            wireTicket: escalation.wireTicket,
            binding: escalation.binding,
            requestedCapabilities: [.view, .signal],
            lastAcknowledgedOutputSequence: nil
        )
        await #expect(throws: TerminalAttachTicketError.capabilityEscalation) {
            _ = try await fixture.coordinator.attach(escalated)
        }
        fixture.clock.advance(by: 30)
        await #expect(throws: TerminalAttachTicketError.expired) {
            _ = try await fixture.coordinator.attach(escalation)
        }
    }

    @Test func supervisorGenerationChangeInvalidatesTicketsBeforeConcurrentAttach() async throws {
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let viewerID = ViewerID()
        let clock = TestClock(Date(timeIntervalSince1970: 10_000))
        let issuer = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: IncrementingBytes()
        )
        let policy = PausingInvalidateTicketPolicy(
            base: TerminalAttachTicketStore(
                clock: clock,
                randomBytes: IncrementingBytes()
            )
        )
        let binding = TerminalAttachBinding(
            sessionID: sessionID,
            workerID: workerID,
            clientInstanceID: ClientInstanceID(viewerID.rawValue)
        )
        let ticket = try await issuer.issue(binding: binding, capabilities: [.view])
        let request = AttachRequest(
            viewerID: viewerID,
            wireTicket: ticket.wireValue,
            binding: binding,
            requestedCapabilities: [.view],
            lastAcknowledgedOutputSequence: nil
        )
        let coordinator = TerminalStreamCoordinator(
            sessionID: sessionID,
            workerID: workerID,
            attachTicketPolicy: policy,
            performInput: { _ in },
            resetInputState: {},
            reportLeaseRevoked: { _, _ in },
            signalForeground: { _ in 0 },
            terminateSession: { _ in }
        )
        let events = InputLeaseRevocationBuffer()
        let generationA = try KeeperSupervisorGeneration(epoch: 1).rawValue
        let generationB = try KeeperSupervisorGeneration(epoch: 2).rawValue
        #expect(try await coordinator.beginSupervisorGeneration(generationA, events: events))
        try await coordinator.registerAttachTicket(
            ticket.registration,
            supervisorGeneration: generationA
        )
        await policy.pauseNextInvalidation()
        let changing = Task {
            try await coordinator.beginSupervisorGeneration(generationB, events: events)
        }
        #expect(await streamWaitUntil { await policy.invalidationIsPaused })

        let attachCompleted = StreamCompletion()
        let registrationCompleted = StreamCompletion()
        let lateTicket = try await issuer.issue(binding: binding, capabilities: [.view])
        let lateRegistration = Task {
            do {
                try await coordinator.registerAttachTicket(
                    lateTicket.registration,
                    supervisorGeneration: generationA
                )
                await registrationCompleted.complete()
                return Result<Void, any Error>.success(())
            } catch {
                await registrationCompleted.complete()
                return Result<Void, any Error>.failure(error)
            }
        }
        let attaching = Task {
            do {
                _ = try await coordinator.attach(request)
                await attachCompleted.complete()
                return Result<Void, any Error>.success(())
            } catch {
                await attachCompleted.complete()
                return Result<Void, any Error>.failure(error)
            }
        }
        try? await Task.sleep(for: .milliseconds(25))
        #expect(await !attachCompleted.completed)
        #expect(await !registrationCompleted.completed)

        await policy.resumeInvalidation()
        #expect(try await changing.value)
        let registrationResult = await lateRegistration.value
        #expect(throws: KeeperControlError.identityMismatch) {
            try registrationResult.get()
        }
        let result = await attaching.value
        #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            try result.get()
        }

        let staleGrant = try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: viewerID,
            sequenceBase: 1,
            capabilities: [.input, .signal, .terminate]
        )
        await #expect(throws: KeeperControlError.identityMismatch) {
            try await coordinator.registerInputLease(
                staleGrant,
                supervisorGeneration: generationA
            )
        }
        await #expect(throws: KeeperControlError.identityMismatch) {
            try await coordinator.revokeInputLease(
                staleGrant.leaseID,
                supervisorGeneration: generationA
            )
        }
        await #expect(throws: KeeperControlError.identityMismatch) {
            _ = try await coordinator.signal(
                .interrupt,
                viewerID: viewerID,
                leaseID: staleGrant.leaseID,
                supervisorGeneration: generationA
            )
        }
        await #expect(throws: KeeperControlError.identityMismatch) {
            try await coordinator.terminate(
                force: false,
                viewerID: viewerID,
                leaseID: staleGrant.leaseID,
                supervisorGeneration: generationA
            )
        }
        await #expect(throws: KeeperControlError.identityMismatch) {
            _ = try await coordinator.supervisorInputLeaseSnapshot(
                supervisorGeneration: generationA
            )
        }
    }

    @Test func retiredSupervisorGenerationCannotReclaimKeeperAuthority() async throws {
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let viewerID = ViewerID()
        let secondViewerID = ViewerID()
        let events = InputLeaseRevocationBuffer()
        let ticketStore = TerminalAttachTicketStore(
            clock: TestClock(Date(timeIntervalSince1970: 10_000)),
            randomBytes: IncrementingBytes()
        )
        let coordinator = TerminalStreamCoordinator(
            sessionID: sessionID,
            workerID: workerID,
            attachTicketPolicy: ticketStore,
            performInput: { _ in },
            resetInputState: {},
            reportLeaseRevoked: { _, _ in },
            signalForeground: { _ in 0 },
            terminateSession: { _ in }
        )
        let generationA = try KeeperSupervisorGeneration(epoch: 1).rawValue
        let generationB = try KeeperSupervisorGeneration(epoch: 2).rawValue
        #expect(try await coordinator.beginSupervisorGeneration(generationA, events: events))
        #expect(try await coordinator.beginSupervisorGeneration(generationB, events: events))

        let binding = TerminalAttachBinding(
            sessionID: sessionID,
            workerID: workerID,
            clientInstanceID: ClientInstanceID(viewerID.rawValue)
        )
        let ticket = try await ticketStore.issue(
            binding: binding,
            capabilities: [.view, .input]
        )
        try await coordinator.registerAttachTicket(
            ticket.registration,
            supervisorGeneration: generationB
        )
        _ = try await coordinator.attach(
            AttachRequest(
                viewerID: viewerID,
                wireTicket: ticket.wireValue,
                binding: binding,
                requestedCapabilities: [.view, .input],
                lastAcknowledgedOutputSequence: nil
            )
        )
        let grant = try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: viewerID,
            sequenceBase: 1,
            capabilities: [.input]
        )
        try await coordinator.registerInputLease(
            grant,
            supervisorGeneration: generationB
        )
        await events.recordLeaseRevocation(grant.leaseID, nextSequence: 2)
        let secondBinding = TerminalAttachBinding(
            sessionID: sessionID,
            workerID: workerID,
            clientInstanceID: ClientInstanceID(secondViewerID.rawValue)
        )
        let retainedTicket = try await ticketStore.issue(
            binding: secondBinding,
            capabilities: TerminalAttachCapabilities.view
        )
        try await coordinator.registerAttachTicket(
            retainedTicket.registration,
            supervisorGeneration: generationB
        )

        await #expect(throws: KeeperControlError.identityMismatch) {
            _ = try await coordinator.beginSupervisorGeneration(generationA, events: events)
        }

        _ = try await coordinator.attach(
            AttachRequest(
                viewerID: secondViewerID,
                wireTicket: retainedTicket.wireValue,
                binding: secondBinding,
                requestedCapabilities: [.view],
                lastAcknowledgedOutputSequence: nil
            )
        )
        let snapshot = try await coordinator.supervisorInputLeaseSnapshot(
            supervisorGeneration: generationB
        )
        #expect(snapshot.currentLease?.grant.leaseID == grant.leaseID)
        let retainedEvents = await events.events(
            generation: generationB,
            acknowledgedThrough: 0,
            afterSequence: 0,
            waitForEvents: false
        )
        #expect(retainedEvents.count == 1)
        if case let .leaseRevoked(leaseID, nextSequence) = retainedEvents.first?.payload {
            #expect(leaseID == grant.leaseID)
            #expect(nextSequence == 2)
        } else {
            Issue.record("expected retained lease revocation")
        }
    }

    @Test func firstSeenOlderSupervisorEpochCannotReplaceCurrentAuthority() async throws {
        let fixture = StreamFixture()
        let events = InputLeaseRevocationBuffer()
        let older = try KeeperSupervisorGeneration(epoch: 41).rawValue
        let current = try KeeperSupervisorGeneration(epoch: 42).rawValue

        #expect(try await fixture.coordinator.beginSupervisorGeneration(current, events: events))
        await #expect(throws: KeeperControlError.identityMismatch) {
            _ = try await fixture.coordinator.beginSupervisorGeneration(older, events: events)
        }
        _ = try await fixture.coordinator.supervisorInputLeaseSnapshot(
            supervisorGeneration: current
        )
    }

    @Test func supervisorGrantIsOnlyWriteAuthorityAndRetriesReturnOriginalACK() async throws {
        let fixture = StreamFixture()
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input, .resize])
        )
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerB, capabilities: [.view, .input])
        )
        let frame = try fixture.input(sequence: 41, leaseID: fixture.leaseA, payload: .text("hello"))

        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await fixture.coordinator.acceptInput(frame)
        }

        try await fixture.coordinator.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseA,
                holderViewerID: fixture.viewerA,
                sequenceBase: 41,
                capabilities: [.input, .resize]
            )
        )
        #expect(try await fixture.coordinator.acceptInput(frame) == 41)
        #expect(try await fixture.coordinator.acceptInput(frame) == 41)
        #expect(await fixture.effects.inputs == [.text("hello")])

        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await fixture.coordinator.acceptInput(
                fixture.input(
                    sequence: 42,
                    leaseID: fixture.leaseA,
                    payload: .text("non-holder"),
                    clientInstanceID: ClientInstanceID(fixture.viewerB.rawValue)
                )
            )
        }

        await #expect(throws: TerminalStreamError.nonMonotonicInputSequence) {
            _ = try await fixture.coordinator.acceptInput(
                fixture.input(sequence: 43, leaseID: fixture.leaseA, payload: .text("gap"))
            )
        }
        #expect(await fixture.effects.inputs == [.text("hello")])
    }

    @Test func grantTransferRevokeAndHolderDisconnectResetEncoderState() async throws {
        let fixture = StreamFixture()
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input])
        )
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerB, capabilities: [.view, .input])
        )
        try await fixture.coordinator.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseA,
                holderViewerID: fixture.viewerA,
                sequenceBase: 1,
                capabilities: [.input]
            )
        )
        let transferred = try InputLeaseGrant(
            validatingLeaseID: fixture.leaseB,
            holderViewerID: fixture.viewerB,
            sequenceBase: 8,
            capabilities: [.input]
        )
        try await fixture.coordinator.transferInputLease(
            from: fixture.leaseA,
            to: transferred,
            supervisorGeneration: try await fixture.currentSupervisorGeneration()
        )
        await fixture.coordinator.detach(viewerID: fixture.viewerB)

        #expect(await fixture.effects.resetCount == 3)
        #expect(await fixture.effects.revoked == [fixture.leaseA, fixture.leaseB])
        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await fixture.coordinator.acceptInput(
                fixture.input(sequence: 8, leaseID: fixture.leaseB, payload: .text("blocked"))
            )
        }
    }

    @Test func inputLeaseAcquireCannotStealAndTransferIsAtomic() async throws {
        let fixture = StreamFixture()
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input])
        )
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerB, capabilities: [.view, .input])
        )
        let generation = try await fixture.currentSupervisorGeneration()
        let grantA = try InputLeaseGrant(
            validatingLeaseID: fixture.leaseA,
            holderViewerID: fixture.viewerA,
            sequenceBase: 1,
            capabilities: [.input]
        )
        try await fixture.coordinator.registerInputLease(
            grantA,
            supervisorGeneration: generation
        )
        try await fixture.coordinator.registerInputLease(
            grantA,
            supervisorGeneration: generation
        )
        #expect(await fixture.effects.resetCount == 1)

        let grantB = try InputLeaseGrant(
            validatingLeaseID: fixture.leaseB,
            holderViewerID: fixture.viewerB,
            sequenceBase: 1,
            capabilities: [.input]
        )
        await #expect(throws: TerminalStreamError.leaseHeld) {
            try await fixture.coordinator.registerInputLease(
                grantB,
                supervisorGeneration: generation
            )
        }
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(sequence: 1, leaseID: fixture.leaseA, payload: .text("still-a"))
        ) == 1)

        let unattachedGrant = try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: ViewerID(),
            sequenceBase: 2,
            capabilities: [.input]
        )
        await #expect(throws: TerminalStreamError.viewerNotAttached) {
            try await fixture.coordinator.transferInputLease(
                from: fixture.leaseA,
                to: unattachedGrant,
                supervisorGeneration: generation
            )
        }
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(sequence: 2, leaseID: fixture.leaseA, payload: .text("still-a-after-failure"))
        ) == 2)

        let transferred = try InputLeaseGrant(
            validatingLeaseID: fixture.leaseB,
            holderViewerID: fixture.viewerB,
            sequenceBase: 3,
            capabilities: [.input]
        )
        try await fixture.coordinator.transferInputLease(
            from: fixture.leaseA,
            to: transferred,
            supervisorGeneration: generation
        )
        #expect(await fixture.effects.resetCount == 2)
        #expect(await fixture.effects.revoked == [fixture.leaseA])
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(
                sequence: 3,
                leaseID: fixture.leaseB,
                payload: .text("now-b"),
                clientInstanceID: ClientInstanceID(fixture.viewerB.rawValue)
            )
        ) == 3)
    }

    @Test func inputEffectAndLeaseTransferShareOneLinearizationGate() async throws {
        let fixture = StreamFixture()
        let generation = try await fixture.currentSupervisorGeneration()
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input])
        )
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerB, capabilities: [.view, .input])
        )
        try await fixture.coordinator.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseA,
                holderViewerID: fixture.viewerA,
                sequenceBase: 1,
                capabilities: [.input]
            )
        )
        await fixture.effects.pauseNextInput()
        let accepted = Task {
            try await fixture.coordinator.acceptInput(
                fixture.input(sequence: 1, leaseID: fixture.leaseA, payload: .text("held"))
            )
        }
        #expect(await streamWaitUntil { await fixture.effects.inputEffectIsPaused })

        let transfer = StreamCompletion()
        let transferring = Task {
            try await fixture.coordinator.transferInputLease(
                from: fixture.leaseA,
                to: try InputLeaseGrant(
                    validatingLeaseID: fixture.leaseB,
                    holderViewerID: fixture.viewerB,
                    sequenceBase: 8,
                    capabilities: [.input]
                ),
                supervisorGeneration: generation
            )
            await transfer.complete()
        }
        try? await Task.sleep(for: .milliseconds(25))
        #expect(await !transfer.completed)

        await fixture.effects.resumeInput()
        #expect(try await accepted.value == 1)
        try await transferring.value
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(
                sequence: 8,
                leaseID: fixture.leaseB,
                payload: .text("new-holder"),
                clientInstanceID: ClientInstanceID(fixture.viewerB.rawValue)
            )
        ) == 8)
        #expect(await fixture.effects.inputs == [.text("held"), .text("new-holder")])
    }

    @Test func inputSequenceOverflowFailsBeforeWritingPTY() async throws {
        let fixture = StreamFixture()
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input])
        )
        try await fixture.coordinator.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseA,
                holderViewerID: fixture.viewerA,
                sequenceBase: UInt64.max,
                capabilities: [.input]
            )
        )
        await #expect(throws: TerminalStreamError.nonMonotonicInputSequence) {
            _ = try await fixture.coordinator.acceptInput(
                fixture.input(
                    sequence: UInt64.max,
                    leaseID: fixture.leaseA,
                    payload: .text("must-not-write")
                )
            )
        }
        #expect(await fixture.effects.inputs.isEmpty)
        #expect(await fixture.effects.revoked == [fixture.leaseA])
    }

    @Test func capabilityChecksSeparateInputResizeSignalAndTerminate() async throws {
        let fixture = StreamFixture()
        _ = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view, .input])
        )
        try await fixture.coordinator.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseA,
                holderViewerID: fixture.viewerA,
                sequenceBase: 1,
                capabilities: [.input]
            )
        )
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(sequence: 1, leaseID: fixture.leaseA, payload: .key(
                try TerminalKeyEvent(validatingLogicalKey: 3, physicalKey: 6, modifiers: 2, action: .press)
            ))
        ) == 1)
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(sequence: 2, leaseID: fixture.leaseA, payload: .paste("paste"))
        ) == 2)
        #expect(try await fixture.coordinator.acceptInput(
            fixture.input(sequence: 3, leaseID: fixture.leaseA, payload: .mouse(
                try TerminalMouseEvent(
                    validatingCellX: -1, cellY: 2, buttons: 1, wheelX: 0, wheelY: 0,
                    modifiers: 0, action: .press
                )
            ))
        ) == 3)
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            _ = try await fixture.coordinator.acceptInput(
                fixture.input(
                    sequence: 4,
                    leaseID: fixture.leaseA,
                    payload: .resize(try TerminalResize(validatingColumns: 120, rows: 40))
                )
            )
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            _ = try await fixture.coordinator.signal(
                .interrupt,
                viewerID: fixture.viewerA,
                leaseID: fixture.leaseA
            )
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            try await fixture.coordinator.terminate(
                force: false,
                viewerID: fixture.viewerA,
                leaseID: fixture.leaseA
            )
        }
    }

    @Test func slowViewerCoalescesAtTwoFramesWithoutAffectingFastViewer() async throws {
        let fixture = StreamFixture()
        let slow = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view])
        )
        let fast = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerB, capabilities: [.view])
        )
        var slowFrames = slow.frames.makeAsyncIterator()
        var fastFrames = fast.frames.makeAsyncIterator()

        await fixture.coordinator.publish(outputSequence: 1, frame: Data([1]))
        #expect(await fastFrames.next()?.outputSequence == 1)
        await fixture.coordinator.publish(outputSequence: 2, frame: Data([2]))
        #expect(await fastFrames.next()?.outputSequence == 2)
        await fixture.coordinator.publish(outputSequence: 3, frame: Data([3]))
        #expect(await fastFrames.next()?.outputSequence == 3)

        let merged = try #require(await slowFrames.next())
        let latest = try #require(await slowFrames.next())
        #expect(merged.firstOutputSequence == 1)
        #expect(merged.outputSequence == 2)
        #expect(merged.fragments == [Data([2])])
        #expect(latest.firstOutputSequence == 3)
        #expect(latest.outputSequence == 3)
        #expect(latest.fragments == [Data([3])])
    }

    @Test func outputSequenceIsMonotonicAndScrollbackPagesStayUnderFrameLimit() async throws {
        let fixture = StreamFixture()
        let attachment = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view])
        )
        var iterator = attachment.frames.makeAsyncIterator()
        await fixture.coordinator.publish(outputSequence: 2, frame: Data([2]))
        await fixture.coordinator.publish(outputSequence: 2, frame: Data([9]))
        #expect(await iterator.next()?.fragments == [Data([2])])

        let oversized = Data(repeating: 0xA5, count: Int(TerminalStreamPage.maximumPayloadBytes) + 17)
        let pages = TerminalStreamPage.paginate(oversized, kind: .scrollback)
        #expect(pages.count == 2)
        #expect(pages.allSatisfy { $0.payload.count <= Int(TerminalStreamPage.maximumPayloadBytes) })
        #expect(Data(pages.flatMap(\.payload)) == oversized)
    }

    @Test func attachResumesRetainedSequenceOrFallsBackToLatestSnapshot() async throws {
        let fixture = StreamFixture()
        for sequence in UInt64(1)...260 {
            await fixture.coordinator.publish(
                outputSequence: sequence,
                kind: sequence.isMultiple(of: 2) ? .delta : .snapshot,
                frame: Data([UInt8(truncatingIfNeeded: sequence)])
            )
        }

        let initial = try await fixture.coordinator.attach(
            try await fixture.issue(
                viewer: fixture.viewerA,
                capabilities: [.view],
                lastAcknowledgedOutputSequence: nil
            )
        )
        var initialFrames = initial.frames.makeAsyncIterator()
        #expect(await initialFrames.next()?.outputSequence == 259)
        #expect(await initialFrames.next()?.outputSequence == 260)
        await fixture.coordinator.detach(viewerID: fixture.viewerA)

        let resumed = try await fixture.coordinator.attach(
            try await fixture.issue(
                viewer: fixture.viewerB,
                capabilities: [.view],
                lastAcknowledgedOutputSequence: 258
            )
        )
        var resumedFrames = resumed.frames.makeAsyncIterator()
        #expect(await resumedFrames.next()?.outputSequence == 259)
        #expect(await resumedFrames.next()?.outputSequence == 260)
        await fixture.coordinator.detach(viewerID: fixture.viewerB)

        let fallbackViewer = ViewerID()
        let fallback = try await fixture.coordinator.attach(
            try await fixture.issue(
                viewer: fallbackViewer,
                capabilities: [.view],
                lastAcknowledgedOutputSequence: 3
            )
        )
        var fallbackFrames = fallback.frames.makeAsyncIterator()
        #expect(await fallbackFrames.next()?.outputSequence == 259)
        #expect(await fallbackFrames.next()?.outputSequence == 260)
        await fixture.coordinator.detach(viewerID: fallbackViewer)
    }

    @Test func attachRetainsDeltaFromExactBaselineAndFallsBackThroughLatestSnapshot() async throws {
        let fixture = StreamFixture()
        await fixture.coordinator.publish(
            outputSequence: 1,
            kind: .snapshot,
            frame: Data("snapshot-1".utf8)
        )
        await fixture.coordinator.publish(
            outputSequence: 2,
            kind: .delta,
            frame: Data("delta-2".utf8)
        )

        let resumed = try await fixture.coordinator.attach(
            try await fixture.issue(
                viewer: fixture.viewerA,
                capabilities: [.view],
                lastAcknowledgedOutputSequence: 1
            )
        )
        var resumedFrames = resumed.frames.makeAsyncIterator()
        let retainedDelta = try #require(await resumedFrames.next())
        #expect(retainedDelta.kind == .delta)
        #expect(retainedDelta.outputSequence == 2)
        #expect(retainedDelta.fragments == [Data("delta-2".utf8)])
        await fixture.coordinator.detach(viewerID: fixture.viewerA)

        let fresh = try await fixture.coordinator.attach(
            try await fixture.issue(
                viewer: fixture.viewerB,
                capabilities: [.view],
                lastAcknowledgedOutputSequence: nil
            )
        )
        var freshFrames = fresh.frames.makeAsyncIterator()
        let freshSnapshot = try #require(await freshFrames.next())
        try #require(freshSnapshot.kind == .snapshot)
        let freshDelta = try #require(await freshFrames.next())
        #expect(freshSnapshot.outputSequence == 1)
        #expect(freshDelta.kind == .delta)
        #expect(freshDelta.outputSequence == 2)
        await fixture.coordinator.detach(viewerID: fixture.viewerB)

        await fixture.coordinator.publish(
            outputSequence: 3,
            kind: .snapshot,
            frame: Data("snapshot-3".utf8)
        )
        await fixture.coordinator.publish(
            outputSequence: 4,
            kind: .delta,
            frame: Data("delta-4".utf8)
        )
        let fallbackViewer = ViewerID()
        let fallback = try await fixture.coordinator.attach(
            try await fixture.issue(
                viewer: fallbackViewer,
                capabilities: [.view],
                lastAcknowledgedOutputSequence: 1
            )
        )
        var fallbackFrames = fallback.frames.makeAsyncIterator()
        let fallbackSnapshot = try #require(await fallbackFrames.next())
        try #require(fallbackSnapshot.kind == .snapshot)
        let fallbackDelta = try #require(await fallbackFrames.next())
        #expect(fallbackSnapshot.outputSequence == 3)
        #expect(fallbackDelta.kind == .delta)
        #expect(fallbackDelta.outputSequence == 4)
        await fixture.coordinator.detach(viewerID: fallbackViewer)
    }

    @Test func slowViewerQueueReplacesObsoleteChainWithLatestSnapshotBaseline() async throws {
        let fixture = StreamFixture()
        let attachment = try await fixture.coordinator.attach(
            try await fixture.issue(viewer: fixture.viewerA, capabilities: [.view])
        )
        var frames = attachment.frames.makeAsyncIterator()
        await fixture.coordinator.publish(
            outputSequence: 1,
            kind: .snapshot,
            frame: Data("snapshot-1".utf8)
        )
        await fixture.coordinator.publish(
            outputSequence: 2,
            kind: .delta,
            frame: Data("delta-2".utf8)
        )
        await fixture.coordinator.publish(
            outputSequence: 3,
            kind: .snapshot,
            frame: Data("snapshot-3".utf8)
        )
        await fixture.coordinator.publish(
            outputSequence: 4,
            kind: .delta,
            frame: Data("delta-4".utf8)
        )

        let snapshot = try #require(await frames.next())
        let delta = try #require(await frames.next())
        #expect(snapshot.kind == .snapshot)
        #expect(snapshot.outputSequence == 3)
        #expect(snapshot.fragments == [Data("snapshot-3".utf8)])
        #expect(delta.kind == .delta)
        #expect(delta.outputSequence == 4)
        #expect(delta.fragments == [Data("delta-4".utf8)])
    }
}

private final class StreamFixture: @unchecked Sendable {
    let sessionID = TerminalSessionID()
    let workerID = WorkerInstanceID()
    let viewerA = ViewerID()
    let viewerB = ViewerID()
    let leaseA = InputLeaseID()
    let leaseB = InputLeaseID()
    let effects = StreamEffects()
    let clock = TestClock(Date(timeIntervalSince1970: 10_000))
    let tickets: TerminalAttachTicketStore
    let coordinator: TerminalStreamCoordinator

    init() {
        let tickets = TerminalAttachTicketStore(
            clock: clock,
            randomBytes: IncrementingBytes()
        )
        self.tickets = tickets
        coordinator = TerminalStreamCoordinator(
            sessionID: sessionID,
            workerID: workerID,
            attachTicketPolicy: tickets,
            performInput: { [effects] payload in await effects.record(payload) },
            resetInputState: { [effects] in await effects.reset() },
            reportLeaseRevoked: { [effects] grant, _ in await effects.revoke(grant.leaseID) },
            signalForeground: { [effects] signal in await effects.signal(signal); return 0 },
            terminateSession: { [effects] force in await effects.terminate(force) }
        )
    }

    func currentSupervisorGeneration() async throws -> UUID {
        let generation = try KeeperSupervisorGeneration(epoch: 1).rawValue
        _ = try await coordinator.beginSupervisorGeneration(generation, events: InputLeaseRevocationBuffer())
        return generation
    }

    func issue(
        viewer: ViewerID,
        capabilities: TerminalAttachCapabilities,
        bindingSession: TerminalSessionID? = nil,
        lastAcknowledgedOutputSequence: UInt64? = nil
    ) async throws -> AttachRequest {
        let binding = TerminalAttachBinding(
            sessionID: bindingSession ?? sessionID,
            workerID: workerID,
            clientInstanceID: ClientInstanceID(viewer.rawValue)
        )
        let issued = try await tickets.issue(binding: binding, capabilities: capabilities)
        return AttachRequest(
            viewerID: viewer,
            wireTicket: issued.wireValue,
            binding: binding,
            requestedCapabilities: capabilities,
            lastAcknowledgedOutputSequence: lastAcknowledgedOutputSequence
        )
    }

    func input(
        sequence: UInt64,
        leaseID: InputLeaseID,
        payload: TerminalInput.Payload,
        clientInstanceID: ClientInstanceID? = nil
    ) throws -> TerminalInput {
        try TerminalInput(
            validatingContext: RequestContext(
                validating: .current,
                clientInstanceID: clientInstanceID ?? ClientInstanceID(viewerA.rawValue),
                windowID: WindowID(),
                workspaceContextID: .project(ProjectID()),
                environmentID: EnvironmentID(),
                activeContextGeneration: 1,
                requestID: RequestID()
            ),
            terminalSessionID: sessionID,
            inputLeaseID: leaseID,
            inputSequence: sequence,
            payload: payload
        )
    }
}

private actor PausingInvalidateTicketPolicy: AttachTicketPolicy {
    private let base: TerminalAttachTicketStore
    private var pauseInvalidation = false
    private var invalidationContinuation: CheckedContinuation<Void, Never>?
    private(set) var invalidationIsPaused = false

    init(base: TerminalAttachTicketStore) { self.base = base }

    func pauseNextInvalidation() { pauseInvalidation = true }

    func resumeInvalidation() {
        invalidationContinuation?.resume()
        invalidationContinuation = nil
    }

    func issue(
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities
    ) async throws -> IssuedTerminalAttachTicket {
        try await base.issue(binding: binding, capabilities: capabilities)
    }

    func register(_ registration: TerminalAttachTicketRegistration) async throws {
        try await base.register(registration)
    }

    func acknowledgeConsumption(ticketDigest: Data) async throws {
        try await base.acknowledgeConsumption(ticketDigest: ticketDigest)
    }

    func invalidateAll() async {
        if pauseInvalidation {
            pauseInvalidation = false
            invalidationIsPaused = true
            await withCheckedContinuation { continuation in
                invalidationContinuation = continuation
            }
            invalidationIsPaused = false
        }
        await base.invalidateAll()
    }

    func consume(
        wireValue: String,
        binding: TerminalAttachBinding,
        capabilities: TerminalAttachCapabilities
    ) async throws -> TerminalAttachTicketRegistration {
        try await base.consume(
            wireValue: wireValue,
            binding: binding,
            capabilities: capabilities
        )
    }
}

private actor StreamEffects {
    private(set) var inputs: [TerminalInput.Payload] = []
    private(set) var resetCount = 0
    private(set) var revoked: [InputLeaseID] = []
    private(set) var signals: [TerminalSignal] = []
    private(set) var terminations: [Bool] = []
    private var pauseInput = false
    private var inputContinuation: CheckedContinuation<Void, Never>?
    private(set) var inputEffectIsPaused = false

    func record(_ input: TerminalInput.Payload) async {
        if pauseInput {
            pauseInput = false
            inputEffectIsPaused = true
            await withCheckedContinuation { inputContinuation = $0 }
            inputEffectIsPaused = false
        }
        inputs.append(input)
    }
    func pauseNextInput() { pauseInput = true }
    func resumeInput() {
        inputContinuation?.resume()
        inputContinuation = nil
    }
    func reset() { resetCount += 1 }
    func revoke(_ lease: InputLeaseID) { revoked.append(lease) }
    func signal(_ signal: TerminalSignal) { signals.append(signal) }
    func terminate(_ force: Bool) { terminations.append(force) }
}

private actor StreamCompletion {
    private(set) var completed = false
    func complete() { completed = true }
}

private func streamWaitUntil(
    timeout: Duration = .seconds(2),
    _ predicate: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await predicate()
}

private final class TestClock: TerminalSecurityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    func now() -> Date { lock.withLock { value } }
    func advance(by seconds: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(seconds) }
    }
}

private final class IncrementingBytes: TerminalSecurityRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 1
    func bytes(count: Int) throws -> [UInt8] {
        lock.withLock {
            defer { value &+= 1 }
            return Array(repeating: value, count: count)
        }
    }
}
