import Darwin
import Foundation
import Testing
import CockpitProtocol
import CockpitTerminalCore
import CockpitTypes
@testable import CockpitLocalTransport

@Suite("KeeperUDSTests", .serialized)
struct KeeperUDSTests {
    @Test func protocol11HandshakeRequiresPeerRoleAndRejectsWrongUID() async throws {
        let fixture = try UDSFixture(peerUID: geteuid() + 1)
        defer { fixture.server.stop() }
        try fixture.server.start()
        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        await #expect(throws: KeeperControlError.authenticationFailed) {
            _ = try await client.attach(fixture.attachRequest)
        }

        let correct = try UDSFixture(peerUID: geteuid())
        defer { correct.server.stop() }
        try correct.server.start()
        let raw = try DarwinUnixDomainSocketSystemCalls().createStreamSocket()
        defer { Darwin.close(raw) }
        try DarwinUnixDomainSocketSystemCalls().connect(
            raw,
            to: UnixDomainSocketAddress(path: correct.endpoint.path)
        )
        try KeeperControlFraming.write(
            KeeperControlEnvelope.inspect(correct.inspectRequest),
            to: raw
        )
        #expect(throws: KeeperControlError.self) {
            _ = try KeeperControlFraming.read(KeeperControlEnvelope.self, from: raw)
        }
    }

    @Test func supervisorRegistersTicketAndLeaseBeforeViewerCanWrite() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        let viewer = try await client.attach(fixture.attachRequest)
        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await viewer.send(fixture.input(sequence: 1))
        }

        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        #expect(await fixture.effects.inputs == [.text("typed")])
        await viewer.detach()
    }

    @Test func supervisorLeaseTransferIsAtomicAndAcquireCannotSteal() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let first = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(
            fixture.attachRequest
        )
        let firstGrant = try InputLeaseGrant(
            validatingLeaseID: fixture.leaseID,
            holderViewerID: fixture.viewerID,
            sequenceBase: 1,
            capabilities: [.input]
        )
        try await supervisor.registerInputLease(
            firstGrant,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        try await supervisor.registerInputLease(
            firstGrant,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        let secondViewer = ViewerID()
        let secondBinding = TerminalAttachBinding(
            sessionID: fixture.sessionID,
            workerID: fixture.workerID,
            clientInstanceID: ClientInstanceID(secondViewer.rawValue)
        )
        let secondTicket = try await fixture.tickets.issue(
            binding: secondBinding,
            capabilities: [.view, .input]
        )
        try await supervisor.registerAttachTicket(
            secondTicket.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let second = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(
            AttachRequest(
                viewerID: secondViewer,
                wireTicket: secondTicket.wireValue,
                binding: secondBinding,
                requestedCapabilities: [.view, .input],
                lastAcknowledgedOutputSequence: nil
            )
        )
        let secondLeaseID = InputLeaseID()
        let secondGrant = try InputLeaseGrant(
            validatingLeaseID: secondLeaseID,
            holderViewerID: secondViewer,
            sequenceBase: 1,
            capabilities: [.input]
        )
        await #expect(throws: TerminalStreamError.leaseHeld) {
            try await supervisor.registerInputLease(
                secondGrant,
                supervisorGeneration: fixture.supervisorGeneration,
                at: fixture.endpoint
            )
        }

        let invalidTarget = try InputLeaseGrant(
            validatingLeaseID: InputLeaseID(),
            holderViewerID: ViewerID(),
            sequenceBase: 1,
            capabilities: [.input]
        )
        await #expect(throws: TerminalStreamError.viewerNotAttached) {
            try await supervisor.transferInputLease(
                from: fixture.leaseID,
                to: invalidTarget,
                supervisorGeneration: fixture.supervisorGeneration,
                at: fixture.endpoint
            )
        }
        #expect(try await first.send(fixture.input(sequence: 1)) == 1)

        let transferred = try InputLeaseGrant(
            validatingLeaseID: secondLeaseID,
            holderViewerID: secondViewer,
            sequenceBase: 2,
            capabilities: [.input]
        )
        try await supervisor.transferInputLease(
            from: fixture.leaseID,
            to: transferred,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        #expect(try await second.send(
            fixture.input(
                sequence: 2,
                clientInstanceID: ClientInstanceID(secondViewer.rawValue),
                leaseID: secondLeaseID
            )
        ) == 2)
        #expect(await fixture.effects.resets == 2)
        #expect(await fixture.effects.revoked == [fixture.leaseID])
        await second.detach()
        await first.detach()
    }

    @Test func supervisorSynchronizationIsGenerationBoundAndLossSafe() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        let generation = try KeeperSupervisorGeneration(epoch: 2).rawValue
        let initial = try await supervisor.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: generation,
                acknowledgedThrough: 0,
                afterSequence: 0,
                waitForEvents: false
            ),
            at: fixture.endpoint
        )
        #expect(initial.currentLease == nil)
        #expect(initial.nextInputSequence == 1)
        #expect(initial.events.isEmpty)

        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: generation,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint)
            .attach(fixture.attachRequest)
        let consumed = try await supervisor.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: generation,
                acknowledgedThrough: 0,
                afterSequence: 0,
                waitForEvents: false
            ),
            at: fixture.endpoint
        )
        #expect(consumed.events == [
            KeeperSupervisorEvent(
                sequence: 1,
                payload: .attachTicketConsumed(fixture.issued.registration.ticketDigest)
            ),
        ])
        let repeated = try await supervisor.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: generation,
                acknowledgedThrough: 0,
                afterSequence: 0,
                waitForEvents: false
            ),
            at: fixture.endpoint
        )
        #expect(repeated.events == consumed.events)

        let grant = try InputLeaseGrant(
            validatingLeaseID: fixture.leaseID,
            holderViewerID: fixture.viewerID,
            sequenceBase: 1,
            capabilities: [.input]
        )
        try await supervisor.registerInputLease(
            grant,
            supervisorGeneration: generation,
            at: fixture.endpoint
        )
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        try await supervisor.revokeInputLease(
            fixture.leaseID,
            supervisorGeneration: generation,
            at: fixture.endpoint
        )
        let explicitlyRevoked = try await supervisor.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: generation,
                acknowledgedThrough: 1,
                afterSequence: 1,
                waitForEvents: false
            ),
            at: fixture.endpoint
        )
        #expect(explicitlyRevoked.events == [
            KeeperSupervisorEvent(
                sequence: 2,
                payload: .leaseRevoked(fixture.leaseID, nextSequence: 2)
            ),
        ])
        let replacementLeaseID = InputLeaseID()
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: replacementLeaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 2,
                capabilities: [.input]
            ),
            supervisorGeneration: generation,
            at: fixture.endpoint
        )
        #expect(
            try await viewer.send(
                fixture.input(sequence: 2, leaseID: replacementLeaseID)
            ) == 2
        )
        let watching = Task {
            try await supervisor.synchronizeSupervisor(
                KeeperSupervisorSyncRequest(
                    supervisorGeneration: generation,
                    acknowledgedThrough: 2,
                    afterSequence: 2,
                    waitForEvents: true
                ),
                at: fixture.endpoint
            )
        }
        await viewer.detach()
        let revoked = try await watching.value
        #expect(revoked.currentLease == nil)
        #expect(revoked.nextInputSequence == 3)
        #expect(revoked.events == [
            KeeperSupervisorEvent(
                sequence: 3,
                payload: .leaseRevoked(replacementLeaseID, nextSequence: 3)
            ),
        ])
        let acknowledged = try await supervisor.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: generation,
                acknowledgedThrough: 3,
                afterSequence: 3,
                waitForEvents: false
            ),
            at: fixture.endpoint
        )
        #expect(acknowledged.events.isEmpty)

        let replacement = try await fixture.tickets.issue(
            binding: fixture.attachRequest.binding,
            capabilities: fixture.attachRequest.requestedCapabilities
        )
        try await supervisor.registerAttachTicket(
            replacement.registration,
            supervisorGeneration: generation,
            at: fixture.endpoint
        )
        let restarted = try await supervisor.synchronizeSupervisor(
            KeeperSupervisorSyncRequest(
                supervisorGeneration: try KeeperSupervisorGeneration(epoch: 3).rawValue,
                acknowledgedThrough: 0,
                afterSequence: 0,
                waitForEvents: false
            ),
            at: fixture.endpoint
        )
        #expect(restarted.currentLease == nil)
        #expect(restarted.nextInputSequence == 3)
        #expect(restarted.events.isEmpty)
        await #expect(throws: TerminalAttachTicketError.invalidCanonicalTicket) {
            _ = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(
                AttachRequest(
                    viewerID: fixture.viewerID,
                    wireTicket: replacement.wireValue,
                    binding: fixture.attachRequest.binding,
                    requestedCapabilities: fixture.attachRequest.requestedCapabilities,
                    lastAcknowledgedOutputSequence: nil
                )
            )
        }
    }

    @Test func ticketReplayCrossSessionAndCapabilityEscalationFailClosed() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        let viewer = try await client.attach(fixture.attachRequest)
        await viewer.detach()
        await #expect(throws: TerminalAttachTicketError.replay) {
            _ = try await client.attach(fixture.attachRequest)
        }

        let escalated = AttachRequest(
            viewerID: fixture.viewerID,
            wireTicket: fixture.attachRequest.wireTicket,
            binding: fixture.attachRequest.binding,
            requestedCapabilities: .all,
            lastAcknowledgedOutputSequence: nil
        )
        await #expect(throws: TerminalAttachTicketError.self) {
            _ = try await client.attach(escalated)
        }
    }

    @Test func outputUsesChannelOneInputAckUsesChannelTwoAndViewerCloseDoesNotTerminatePTY() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        await fixture.coordinator.publish(outputSequence: 1, frame: Data("screen".utf8))
        #expect(try await viewer.nextOutput()?.fragments == [Data("screen".utf8)])
        #expect(try await viewer.send(fixture.input(sequence: 1)) == 1)
        await viewer.detach()
        #expect(await fixture.terminated.count == 0)
        #expect(await fixture.effects.revoked == [fixture.leaseID])
    }

    @Test func readOnlyViewerCannotInputResizeSignalOrTerminate() async throws {
        let fixture = try UDSFixture(peerUID: geteuid(), capabilities: [.view])
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            _ = try await viewer.send(fixture.input(sequence: 1))
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            _ = try await viewer.signal(.interrupt, leaseID: InputLeaseID())
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            try await viewer.terminate(force: false, leaseID: InputLeaseID())
        }
        await viewer.detach()
    }

    @Test func signalTargetsForegroundGroupAndTerminateUsesSessionPolicy() async throws {
        let fixture = try UDSFixture(
            peerUID: geteuid(),
            capabilities: [.view, .signal, .terminate]
        )
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.signal, .terminate]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        await #expect(throws: (any Error).self) {
            _ = try await viewer.send(
                fixture.input(
                    sequence: 1,
                    payload: .signal(.interrupt),
                    leaseID: InputLeaseID()
                )
            )
        }
        #expect(try await viewer.send(fixture.input(sequence: 1, payload: .signal(.interrupt))) == 1)
        #expect(try await viewer.signal(.interrupt, leaseID: fixture.leaseID) == 100)
        #expect(try await viewer.signal(.quit, leaseID: fixture.leaseID) == 100)
        #expect(try await viewer.signal(.suspend, leaseID: fixture.leaseID) == 100)
        #expect(try await viewer.signal(.continue, leaseID: fixture.leaseID) == 100)
        try await viewer.terminate(force: false, leaseID: fixture.leaseID)
        try await viewer.terminate(force: true, leaseID: fixture.leaseID)
        #expect(await fixture.effects.signals == [
            .interrupt, .interrupt, .quit, .suspend, .continue,
        ])
        #expect(await fixture.terminated.values == [false, true])
        await viewer.detach()
    }

    @Test func signalRetryUsesInputSequenceAndPerformsTheSignalOnlyOnce() async throws {
        let fixture = try UDSFixture(
            peerUID: geteuid(),
            capabilities: [.view, .input, .signal]
        )
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input, .signal]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        let signal = try fixture.input(sequence: 1, payload: .signal(.interrupt))
        let firstAcknowledgement = try await viewer.send(signal)
        let retryAcknowledgement = try await viewer.send(signal)
        let textAcknowledgement: UInt64?
        do {
            textAcknowledgement = try await viewer.send(fixture.input(sequence: 2))
        } catch {
            textAcknowledgement = nil
        }

        #expect(firstAcknowledgement == 1)
        #expect(retryAcknowledgement == 1)
        #expect(await fixture.effects.signals == [.interrupt])
        #expect(textAcknowledgement == 2)
        #expect(await fixture.effects.inputs == [.text("typed")])
        await viewer.detach()
    }

    @Test func supervisorSignalAndTerminateRequireTheCurrentAuthorizedViewer() async throws {
        let fixture = try UDSFixture(
            peerUID: geteuid(),
            capabilities: [.view, .signal, .terminate]
        )
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.signal, .terminate]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        await #expect(throws: (any Error).self) {
            _ = try await supervisor.signalForeground(
                .interrupt,
                viewerID: ViewerID(),
                leaseID: fixture.leaseID,
                supervisorGeneration: fixture.supervisorGeneration,
                at: fixture.endpoint
            )
        }
        await #expect(throws: (any Error).self) {
            _ = try await supervisor.signalForeground(
                .interrupt,
                viewerID: fixture.viewerID,
                leaseID: InputLeaseID(),
                supervisorGeneration: fixture.supervisorGeneration,
                at: fixture.endpoint
            )
        }
        #expect(await fixture.effects.signals.isEmpty)
        #expect(
            try await supervisor.signalForeground(
                .interrupt,
                viewerID: fixture.viewerID,
                leaseID: fixture.leaseID,
                supervisorGeneration: fixture.supervisorGeneration,
                at: fixture.endpoint
            ) == 100
        )
        await #expect(throws: (any Error).self) {
            try await supervisor.terminateAuthorized(
                force: true,
                viewerID: fixture.viewerID,
                leaseID: InputLeaseID(),
                supervisorGeneration: fixture.supervisorGeneration,
                at: fixture.endpoint
            )
        }
        try await supervisor.terminateAuthorized(
            force: true,
            viewerID: fixture.viewerID,
            leaseID: fixture.leaseID,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        #expect(await fixture.effects.signals == [.interrupt])
        #expect(await fixture.terminated.values == [true])
        await viewer.detach()
    }

    @Test func serverStopUnblocksViewerWaitingForOutputAndJoinsWorker() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        let output = Task.detached { try? await viewer.nextOutput() }

        #expect(await waitUntil { fixture.server.pendingOutputWaiterCount() == 1 })
        let completion = CompletionFlag()
        let stopping = Task.detached {
            fixture.server.stop()
            completion.markComplete()
        }
        let bounded = await waitUntil(timeout: .milliseconds(250)) { completion.isComplete }
        #expect(bounded)
        if !bounded {
            await fixture.coordinator.detach(viewerID: fixture.viewerID)
        }
        await stopping.value
        _ = await output.value
    }

    @Test func viewerDetachFinalizesPendingOutputAndRevokesItsLease() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        let output = PendingResult<TerminalOutputFrame?>()
        Task.detached {
            do { output.store(.success(try await viewer.nextOutput())) }
            catch { output.store(.failure(error)) }
        }
        #expect(await waitUntil { fixture.server.pendingOutputWaiterCount() == 1 })

        let detached = CompletionFlag()
        Task.detached {
            await viewer.detach()
            detached.markComplete()
        }
        #expect(await waitUntil(timeout: .milliseconds(250)) { detached.isComplete })
        #expect(await waitUntil(timeout: .milliseconds(250)) { output.value != nil })
        #expect(try output.value?.get() == nil)
        #expect(await fixture.effects.revoked == [fixture.leaseID])
    }

    @Test func detachAcknowledgementLinearizesBeforeSameViewerCanReattach() async throws {
        let acknowledgement = BlockingHook()
        let fixture = try UDSFixture(
            peerUID: geteuid(),
            afterViewerDetachAcknowledgement: { acknowledgement.pause() }
        )
        defer {
            acknowledgement.resume()
            fixture.server.stop()
        }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let client = KeeperUDSClient(endpoint: fixture.endpoint)
        let first = try await client.attach(fixture.attachRequest)

        let replacementTicket = try await fixture.tickets.issue(
            binding: fixture.attachRequest.binding,
            capabilities: fixture.attachRequest.requestedCapabilities
        )
        try await supervisor.registerAttachTicket(
            replacementTicket.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let replacementRequest = AttachRequest(
            viewerID: fixture.viewerID,
            wireTicket: replacementTicket.wireValue,
            binding: fixture.attachRequest.binding,
            requestedCapabilities: fixture.attachRequest.requestedCapabilities,
            lastAcknowledgedOutputSequence: nil
        )

        let detached = CompletionFlag()
        Task.detached {
            await first.detach()
            detached.markComplete()
        }
        #expect(await waitUntil { acknowledgement.entered && detached.isComplete })

        let replacement = PendingResult<KeeperViewerConnection>()
        Task.detached {
            do { replacement.store(.success(try await client.attach(replacementRequest))) }
            catch { replacement.store(.failure(error)) }
        }
        #expect(await waitUntil(timeout: .milliseconds(250)) { replacement.value != nil })
        acknowledgement.resume()
        let reattached = try #require(try replacement.value?.get())
        await reattached.detach()
    }

    @Test func liveKeeperSocketIsNeverUnlinkedByACompetingServer() throws {
        let sessionID = TerminalSessionID()
        let workerID = WorkerInstanceID()
        let parent = "/private/tmp/cockpit-keeper-startup"
        let endpoint = try KeeperEndpoint(
            path: parent + "/keeper.sock",
            sessionID: sessionID,
            workerID: workerID
        )
        let calls = KeeperStartupSocketCalls(parent: parent, path: endpoint.path)
        let secret = Data(repeating: 0x71, count: 32)
        let first = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            startHandler: { _ in
                try CLIProcessIdentity(validatingProcessID: 900, processGroupID: 900)
            },
            terminateHandler: { _ in },
            calls: calls,
            peerCredentials: FixedPeerReader(uid: geteuid())
        )
        defer { first.stop() }
        try first.start()
        let originalStatus = try calls.pathStatus(endpoint.path)
        let originalIdentity = try #require(originalStatus)
        let competing = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            startHandler: { _ in
                try CLIProcessIdentity(validatingProcessID: 901, processGroupID: 901)
            },
            terminateHandler: { _ in },
            calls: calls,
            peerCredentials: FixedPeerReader(uid: geteuid())
        )
        defer { competing.stop() }

        var startError: (any Error)?
        do {
            try competing.start()
        } catch {
            startError = error
        }
        #expect(startError as? UnixDomainSocketError == .serverAlreadyRunning)
        #expect(try calls.pathStatus(endpoint.path) == originalIdentity)
        #expect(calls.unlinkCount == 0)
    }

    @Test func frameSequenceAndAcknowledgementAreIndependentPerChannel() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        let stream = KeeperStreamConnection(descriptor: descriptors[0])
        defer {
            stream.close()
            Darwin.close(descriptors[1])
        }

        try stream.write("control", channel: .control)
        try stream.write("output", channel: .terminalOutput)
        try stream.write("input", channel: .terminalInput)
        let control = try readRawFrame(from: descriptors[1])
        let output = try readRawFrame(from: descriptors[1])
        let input = try readRawFrame(from: descriptors[1])
        #expect(control.header.channel == .control)
        #expect(control.header.sequence == 1)
        #expect(output.header.channel == .terminalOutput)
        #expect(output.header.sequence == 1)
        #expect(input.header.channel == .terminalInput)
        #expect(input.header.sequence == 1)

        try writeRawFrame("peer-input", channel: .terminalInput, sequence: 1, acknowledgement: 1, to: descriptors[1])
        try writeRawFrame("peer-control", channel: .control, sequence: 1, acknowledgement: 1, to: descriptors[1])
        #expect(try stream.read(String.self).1 == "peer-input")
        #expect(try stream.read(String.self).1 == "peer-control")

        try writeRawFrame("ack-regression", channel: .terminalInput, sequence: 2, acknowledgement: 0, to: descriptors[1])
        #expect(throws: TerminalStreamError.malformedMessage) {
            _ = try stream.read(String.self)
        }
    }

    @Test func pendingOutputDoesNotBlockConcurrentInputAcknowledgement() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        let output = Task.detached { try await viewer.nextOutput() }
        #expect(await waitUntil { fixture.server.pendingOutputWaiterCount() == 1 })
        let input = PendingResult<UInt64>()
        Task.detached {
            do { input.store(.success(try await viewer.send(fixture.input(sequence: 1)))) }
            catch { input.store(.failure(error)) }
        }
        let inputCompletedWithoutOutput = await waitUntil(timeout: .milliseconds(250)) {
            input.value != nil
        }
        #expect(inputCompletedWithoutOutput)

        await fixture.coordinator.publish(outputSequence: 1, frame: Data("screen".utf8))
        #expect(await waitUntil { input.value != nil })
        #expect(try input.value?.get() == 1)
        #expect(try await output.value?.fragments == [Data("screen".utf8)])
        await viewer.detach()
    }

    @Test func oversizedOutputIsPagedBelowFrameLimitAndReassembled() async throws {
        let fixture = try UDSFixture(peerUID: geteuid(), capabilities: [.view])
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)
        let payload = Data(
            repeating: 0xA7,
            count: Int(FrameHeader.maximumPayloadLength) + 17
        )
        let output = PendingResult<TerminalOutputFrame?>()
        Task.detached {
            do { output.store(.success(try await viewer.nextOutput())) }
            catch { output.store(.failure(error)) }
        }

        await fixture.coordinator.publish(outputSequence: 1, frame: payload)
        let delivered = await waitUntil { output.value != nil }
        #expect(delivered)
        guard delivered else {
            await viewer.detach()
            return
        }
        let result = try #require(output.value)
        let frame = try #require(try result.get())
        #expect(frame.fragments == [payload])
        let pages = KeeperOutputPage.pages(for: frame)
        #expect(pages.count > 1)
        #expect(try pages.allSatisfy {
            try JSONEncoder().encode(KeeperViewerResponse.outputPage($0)).count
                <= Int(FrameHeader.maximumPayloadLength)
        })
        await viewer.detach()
    }

    @Test func terminalInputChannelCarriesNearLimitProtobufWithoutBase64Expansion() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let viewer = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(
            fixture.attachRequest
        )
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        let text = String(repeating: "x", count: 13 * 1_024 * 1_024)
        let input = try fixture.input(sequence: 1, payload: .text(text))
        let protobuf = try TerminalMessages.encode(
            input,
            channelID: .terminalInput,
            negotiatedVersion: .current
        ).serializedData()
        #expect(protobuf.count < Int(FrameHeader.maximumPayloadLength))
        #expect(
            try JSONEncoder().encode(protobuf).count
                > Int(FrameHeader.maximumPayloadLength)
        )

        #expect(try await viewer.send(input) == 1)
        #expect(await fixture.effects.inputTextUTF8Count == text.utf8.count)
        await viewer.detach()
    }

    @Test func nonHolderConnectionCannotSpoofLeaseHolderContext() async throws {
        let fixture = try UDSFixture(peerUID: geteuid())
        defer { fixture.server.stop() }
        try fixture.server.start()
        let supervisor = KeeperControlClient(secretProvider: { _, _ in fixture.secret })
        try await supervisor.registerAttachTicket(
            fixture.issued.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let holder = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(fixture.attachRequest)

        let otherViewerID = ViewerID()
        let otherBinding = TerminalAttachBinding(
            sessionID: fixture.sessionID,
            workerID: fixture.workerID,
            clientInstanceID: ClientInstanceID(otherViewerID.rawValue)
        )
        let otherTicket = try await fixture.tickets.issue(
            binding: otherBinding,
            capabilities: [.view, .input]
        )
        try await supervisor.registerAttachTicket(
            otherTicket.registration,
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )
        let other = try await KeeperUDSClient(endpoint: fixture.endpoint).attach(
            AttachRequest(
                viewerID: otherViewerID,
                wireTicket: otherTicket.wireValue,
                binding: otherBinding,
                requestedCapabilities: [.view, .input],
                lastAcknowledgedOutputSequence: nil
            )
        )
        try await supervisor.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseID,
                holderViewerID: fixture.viewerID,
                sequenceBase: 1,
                capabilities: [.input]
            ),
            supervisorGeneration: fixture.supervisorGeneration,
            at: fixture.endpoint
        )

        await #expect(throws: TerminalStreamError.inputLeaseRequired) {
            _ = try await other.send(
                fixture.input(
                    sequence: 1,
                    clientInstanceID: ClientInstanceID(fixture.viewerID.rawValue)
                )
            )
        }
        #expect(await fixture.effects.inputs.isEmpty)
        #expect(try await holder.send(fixture.input(sequence: 1)) == 1)
        #expect(await fixture.effects.inputs == [.text("typed")])
        await fixture.coordinator.publish(outputSequence: 1, frame: Data("shared".utf8))
        #expect(try await holder.nextOutput()?.fragments == [Data("shared".utf8)])
        #expect(try await other.nextOutput()?.fragments == [Data("shared".utf8)])
        await other.detach()
        await holder.detach()
    }
}

private final class UDSFixture: @unchecked Sendable {
    let endpoint: KeeperEndpoint
    let secret = Data(repeating: 0x72, count: 32)
    let sessionID = TerminalSessionID()
    let workerID = WorkerInstanceID()
    let viewerID = ViewerID()
    let leaseID = InputLeaseID()
    let supervisorGeneration: UUID
    let tickets: TerminalAttachTicketStore
    let coordinator: TerminalStreamCoordinator
    let effects = UDSEffects()
    let terminated = TerminationCounter()
    let supervisorEvents: InputLeaseRevocationBuffer
    let issued: IssuedTerminalAttachTicket
    let attachRequest: AttachRequest
    let inspectRequest: KeeperInspectRequest
    let server: KeeperUDSServer
    private let root: URL

    init(
        peerUID: uid_t,
        capabilities: TerminalAttachCapabilities = [.view, .input],
        afterViewerDetachAcknowledgement: (@Sendable () -> Void)? = nil
    ) throws {
        root = URL(fileURLWithPath: "/private/tmp/cockpit-keeper-stream.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        endpoint = try KeeperEndpoint(
            path: root.appendingPathComponent("keeper.sock").path,
            sessionID: sessionID,
            workerID: workerID
        )
        let clock = FixedClock()
        let tickets = TerminalAttachTicketStore(clock: clock, randomBytes: UDSIncrementingBytes())
        self.tickets = tickets
        let supervisorEvents = InputLeaseRevocationBuffer()
        self.supervisorEvents = supervisorEvents
        let coordinator = TerminalStreamCoordinator(
            sessionID: sessionID,
            workerID: workerID,
            attachTicketPolicy: tickets,
            performInput: { [effects] payload in
                if case let .signal(signal) = payload {
                    await effects.signal(signal)
                } else {
                    await effects.record(payload)
                }
            },
            resetInputState: { [effects] in await effects.reset() },
            reportLeaseRevoked: { [effects, supervisorEvents] grant, nextSequence in
                await effects.revoke(grant.leaseID)
                await supervisorEvents.recordLeaseRevocation(
                    grant.leaseID,
                    nextSequence: nextSequence
                )
            },
            reportTicketConsumed: { [supervisorEvents] digest in
                await supervisorEvents.recordAttachTicketConsumption(digest)
            },
            signalForeground: { [effects] signal in await effects.signal(signal); return 100 },
            terminateSession: { [terminated] force in await terminated.record(force) }
        )
        self.coordinator = coordinator
        let supervisorGeneration = try KeeperSupervisorGeneration(epoch: 1).rawValue
        self.supervisorGeneration = supervisorGeneration
        _ = try waitAsync {
            try await coordinator.beginSupervisorGeneration(
                supervisorGeneration,
                events: supervisorEvents
            )
        }
        let binding = TerminalAttachBinding(
            sessionID: sessionID,
            workerID: workerID,
            clientInstanceID: ClientInstanceID(viewerID.rawValue)
        )
        issued = try waitAsync { try await tickets.issue(binding: binding, capabilities: capabilities) }
        attachRequest = AttachRequest(
            viewerID: viewerID,
            wireTicket: issued.wireValue,
            binding: binding,
            requestedCapabilities: capabilities,
            lastAcknowledgedOutputSequence: nil
        )
        let nonce = Data(repeating: 1, count: 16)
        inspectRequest = KeeperInspectRequest(
            endpoint: endpoint,
            nonce: nonce,
            proofMAC: KeeperAuthentication.inspectProof(secret: secret, endpoint: endpoint, nonce: nonce)
        )
        server = KeeperUDSServer(
            endpoint: endpoint,
            workerSecret: secret,
            streamCoordinator: coordinator,
            leaseRevocations: supervisorEvents,
            startHandler: { _ in try CLIProcessIdentity(validatingProcessID: 900, processGroupID: 900) },
            terminateHandler: { [terminated] force in await terminated.record(force) },
            afterViewerDetachAcknowledgement: afterViewerDetachAcknowledgement,
            calls: DarwinUnixDomainSocketSystemCalls(),
            peerCredentials: FixedPeerReader(uid: peerUID)
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func input(
        sequence: UInt64,
        payload: TerminalInput.Payload = .text("typed"),
        clientInstanceID: ClientInstanceID? = nil,
        leaseID: InputLeaseID? = nil
    ) throws -> TerminalInput {
        try TerminalInput(
            validatingContext: RequestContext(
                validating: .current,
                clientInstanceID: clientInstanceID ?? ClientInstanceID(viewerID.rawValue),
                windowID: WindowID(),
                workspaceContextID: .project(ProjectID()),
                environmentID: EnvironmentID(),
                activeContextGeneration: 1,
                requestID: RequestID()
            ),
            terminalSessionID: sessionID,
            inputLeaseID: leaseID ?? self.leaseID,
            inputSequence: sequence,
            payload: payload
        )
    }
}

private struct FixedPeerReader: PeerCredentialReading {
    let uid: uid_t
    func peerCredentials(for descriptor: Int32) throws -> (uid: uid_t, gid: gid_t) {
        (uid: uid, gid: getegid())
    }
}

private final class KeeperStartupSocketCalls: UnixDomainSocketSystemCalls, @unchecked Sendable {
    private let lock = NSLock()
    private let parent: String
    private let path: String
    private var nextDescriptor: Int32 = 40
    private var nextInode: ino_t = 100
    private var socketStatus: UnixSocketPathStatus?
    private var unlinks = 0

    init(parent: String, path: String) {
        self.parent = parent
        self.path = path
    }

    var unlinkCount: Int { lock.withLock { unlinks } }

    func effectiveUserID() -> uid_t { geteuid() }

    func createStreamSocket() throws -> Int32 {
        lock.withLock {
            defer { nextDescriptor += 1 }
            return nextDescriptor
        }
    }

    func setCloseOnExec(_ descriptor: Int32) throws {}
    func setNoSigPipe(_ descriptor: Int32) throws {}

    func bind(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        try lock.withLock {
            guard socketStatus == nil else {
                throw UnixDomainSocketError.systemCall(function: "bind", errno: EADDRINUSE)
            }
            socketStatus = UnixSocketPathStatus(
                kind: .socket,
                owner: geteuid(),
                permissions: 0o777,
                device: 7,
                inode: nextInode
            )
            nextInode += 1
        }
    }

    func listen(_ descriptor: Int32, backlog: Int32) throws {}

    func accept(_ descriptor: Int32) throws -> Int32 {
        throw UnixDomainSocketError.systemCall(function: "accept", errno: EBADF)
    }

    func connect(_ descriptor: Int32, to address: UnixDomainSocketAddress) throws {
        guard lock.withLock({ socketStatus != nil }) else {
            throw UnixDomainSocketError.systemCall(function: "connect", errno: ENOENT)
        }
    }

    func pathStatus(_ requestedPath: String) throws -> UnixSocketPathStatus? {
        lock.withLock {
            if requestedPath == parent {
                return UnixSocketPathStatus(
                    kind: .directory,
                    owner: geteuid(),
                    permissions: 0o700,
                    device: 7,
                    inode: 1
                )
            }
            return requestedPath == path ? socketStatus : nil
        }
    }

    func makeDirectory(_ path: String, permissions: mode_t) throws {}

    func setPermissions(_ requestedPath: String, permissions: mode_t) throws {
        lock.withLock {
            guard requestedPath == path, let current = socketStatus else { return }
            socketStatus = UnixSocketPathStatus(
                kind: current.kind,
                owner: current.owner,
                permissions: permissions,
                device: current.device,
                inode: current.inode
            )
        }
    }

    func unlink(_ requestedPath: String) throws {
        lock.withLock {
            guard requestedPath == path else { return }
            socketStatus = nil
            unlinks += 1
        }
    }

    func close(_ descriptor: Int32) {}

    func read(
        _ descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) throws -> Int {
        throw UnixDomainSocketError.systemCall(function: "read", errno: EBADF)
    }

    func write(
        _ descriptor: Int32,
        from buffer: UnsafeRawBufferPointer
    ) throws -> Int {
        throw UnixDomainSocketError.systemCall(function: "write", errno: EBADF)
    }
}

private struct FixedClock: TerminalSecurityClock {
    func now() -> Date { Date(timeIntervalSince1970: 20_000) }
}

private final class UDSIncrementingBytes: TerminalSecurityRandomBytes, @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0x35
    func bytes(count: Int) throws -> [UInt8] {
        lock.withLock {
            defer { value &+= 1 }
            return Array(repeating: value, count: count)
        }
    }
}

private actor UDSEffects {
    private(set) var inputs: [TerminalInput.Payload] = []
    private(set) var resets = 0
    private(set) var revoked: [InputLeaseID] = []
    private(set) var signals: [TerminalSignal] = []
    var inputTextUTF8Count: Int {
        inputs.reduce(0) { partial, payload in
            switch payload {
            case let .text(value), let .paste(value): partial + value.utf8.count
            default: partial
            }
        }
    }
    func record(_ payload: TerminalInput.Payload) { inputs.append(payload) }
    func reset() { resets += 1 }
    func revoke(_ lease: InputLeaseID) { revoked.append(lease) }
    func signal(_ signal: TerminalSignal) { signals.append(signal) }
}

private actor TerminationCounter {
    private(set) var values: [Bool] = []
    var count: Int { values.count }
    func record(_ force: Bool) { values.append(force) }
}

private func waitAsync<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) throws -> Value {
    let semaphore = DispatchSemaphore(value: 0)
    let box = LockedResult<Value>()
    Task.detached {
        do { box.store(.success(try await operation())) }
        catch { box.store(.failure(error)) }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.load().get()
}

private final class LockedResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, any Error>?
    func store(_ value: Result<Value, any Error>) { lock.withLock { self.value = value } }
    func load() -> Result<Value, any Error> { lock.withLock { value! } }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var isComplete: Bool { lock.withLock { completed } }
    func markComplete() { lock.withLock { completed = true } }
}

private final class BlockingHook: @unchecked Sendable {
    private let condition = NSCondition()
    private var didEnter = false
    private var released = false

    var entered: Bool { condition.withLock { didEnter } }

    func pause() {
        condition.lock()
        didEnter = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func resume() {
        condition.withLock {
            released = true
            condition.broadcast()
        }
    }
}

private final class PendingResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<Value, any Error>?
    var value: Result<Value, any Error>? { lock.withLock { stored } }
    func store(_ value: Result<Value, any Error>) { lock.withLock { stored = value } }
}

private func waitUntil(
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

private func readRawFrame(from descriptor: Int32) throws -> (header: FrameHeader, payload: Data) {
    var headerBytes = Data(count: FrameHeader.encodedLength)
    try headerBytes.withUnsafeMutableBytes { try readExactly($0, from: descriptor) }
    let header = try FrameHeader(decoding: headerBytes)
    var payload = Data(count: Int(header.payloadLength))
    try payload.withUnsafeMutableBytes { try readExactly($0, from: descriptor) }
    return (header, payload)
}

private func writeRawFrame<Value: Encodable>(
    _ value: Value,
    channel: ChannelID,
    sequence: UInt64,
    acknowledgement: UInt64,
    to descriptor: Int32
) throws {
    let payload = try JSONEncoder().encode(value)
    let header = FrameHeader(
        flags: 0,
        channel: channel,
        sequence: sequence,
        acknowledgement: acknowledgement,
        payloadLength: UInt32(payload.count)
    )
    try writeExactly(header.encoded(), to: descriptor)
    try writeExactly(payload, to: descriptor)
}

private func readExactly(_ bytes: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
    guard let base = bytes.baseAddress else { return }
    var offset = 0
    while offset < bytes.count {
        let count = Darwin.read(descriptor, base.advanced(by: offset), bytes.count - offset)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { throw TerminalStreamError.disconnected }
        offset += count
    }
}

private func writeExactly(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw TerminalStreamError.disconnected }
            offset += count
        }
    }
}
