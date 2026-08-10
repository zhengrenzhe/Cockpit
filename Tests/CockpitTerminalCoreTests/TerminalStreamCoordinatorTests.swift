import Foundation
import Testing
import CockpitTypes
@testable import CockpitTerminalCore

@Suite("TerminalStreamCoordinatorTests")
struct TerminalStreamCoordinatorTests {
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
        try await fixture.coordinator.registerInputLease(
            try InputLeaseGrant(
                validatingLeaseID: fixture.leaseB,
                holderViewerID: fixture.viewerB,
                sequenceBase: 8,
                capabilities: [.input]
            )
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

    @Test func inputEffectAndLeaseTransferShareOneLinearizationGate() async throws {
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
        await fixture.effects.pauseNextInput()
        let accepted = Task {
            try await fixture.coordinator.acceptInput(
                fixture.input(sequence: 1, leaseID: fixture.leaseA, payload: .text("held"))
            )
        }
        #expect(await streamWaitUntil { await fixture.effects.inputEffectIsPaused })

        let transfer = StreamCompletion()
        let transferring = Task {
            try await fixture.coordinator.registerInputLease(
                try InputLeaseGrant(
                    validatingLeaseID: fixture.leaseB,
                    holderViewerID: fixture.viewerB,
                    sequenceBase: 8,
                    capabilities: [.input]
                )
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
            _ = try await fixture.coordinator.signal(.interrupt, viewerID: fixture.viewerA)
        }
        await #expect(throws: TerminalStreamError.capabilityDenied) {
            try await fixture.coordinator.terminate(force: false, viewerID: fixture.viewerA)
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
        #expect(await fallbackFrames.next()?.outputSequence == 260)
        await fixture.coordinator.detach(viewerID: fallbackViewer)
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
            reportLeaseRevoked: { [effects] leaseID in await effects.revoke(leaseID) },
            signalForeground: { [effects] signal in await effects.signal(signal); return 0 },
            terminateSession: { [effects] force in await effects.terminate(force) }
        )
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
