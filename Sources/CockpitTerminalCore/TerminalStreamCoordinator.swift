import Foundation
import CockpitTypes

public actor TerminalStreamCoordinator {
    public typealias InputHandler = @Sendable (TerminalInput.Payload) async throws -> Void
    public typealias ResetInputStateHandler = @Sendable () async -> Void
    public typealias LeaseRevokedHandler = @Sendable (
        InputLeaseGrant,
        UInt64
    ) async -> Void
    public typealias TicketConsumedHandler = @Sendable (Data) async -> Void
    public typealias SignalHandler = @Sendable (TerminalSignal) async throws -> Int32
    public typealias TerminateHandler = @Sendable (Bool) async throws -> Void

    private struct ViewerState {
        let capabilities: TerminalAttachCapabilities
        let queue: TerminalViewerFrameQueue
    }

    private struct LeaseState {
        let grant: InputLeaseGrant
        var nextSequence: UInt64
    }

    private let sessionID: TerminalSessionID
    private let workerID: WorkerInstanceID
    private let attachTicketPolicy: any AttachTicketPolicy
    private let performInput: InputHandler
    private let resetInputState: ResetInputStateHandler
    private let reportLeaseRevoked: LeaseRevokedHandler
    private let reportTicketConsumed: TicketConsumedHandler
    private let signalForeground: SignalHandler
    private let terminateSession: TerminateHandler
    private let operationGate = TerminalStreamOperationGate()
    private var viewers: [ViewerID: ViewerState] = [:]
    private var lease: LeaseState?
    private var supervisorGeneration: UUID?
    private var supervisorEpoch: UInt64?
    private var nextInputSequence: UInt64 = 1
    private var latestOutputSequence: UInt64 = 0
    private var latestSnapshot: TerminalOutputFrame?
    private var retainedFrames: [TerminalOutputFrame] = []

    public init(
        sessionID: TerminalSessionID,
        workerID: WorkerInstanceID,
        attachTicketPolicy: any AttachTicketPolicy,
        performInput: @escaping InputHandler,
        resetInputState: @escaping ResetInputStateHandler,
        reportLeaseRevoked: @escaping LeaseRevokedHandler,
        reportTicketConsumed: @escaping TicketConsumedHandler = { _ in },
        signalForeground: @escaping SignalHandler,
        terminateSession: @escaping TerminateHandler
    ) {
        self.sessionID = sessionID
        self.workerID = workerID
        self.attachTicketPolicy = attachTicketPolicy
        self.performInput = performInput
        self.resetInputState = resetInputState
        self.reportLeaseRevoked = reportLeaseRevoked
        self.reportTicketConsumed = reportTicketConsumed
        self.signalForeground = signalForeground
        self.terminateSession = terminateSession
    }

    public func registerAttachTicket(_ registration: TerminalAttachTicketRegistration) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try await registerAttachTicketLocked(registration)
    }

    package func registerAttachTicket(
        _ registration: TerminalAttachTicketRegistration,
        supervisorGeneration: UUID
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        try await registerAttachTicketLocked(registration)
    }

    private func registerAttachTicketLocked(
        _ registration: TerminalAttachTicketRegistration
    ) async throws {
        guard registration.binding.sessionID == sessionID,
              registration.binding.workerID == workerID else {
            throw TerminalAttachTicketError.bindingMismatch
        }
        try await attachTicketPolicy.register(registration)
    }

    public func attach(_ request: AttachRequest) async throws -> Attachment {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard request.binding.sessionID == sessionID,
              request.binding.workerID == workerID,
              request.binding.clientInstanceID.rawValue == request.viewerID.rawValue
        else {
            throw TerminalAttachTicketError.bindingMismatch
        }
        guard request.requestedCapabilities.contains(.view) else {
            throw TerminalAttachTicketError.invalidCapabilities
        }
        let registration = try await attachTicketPolicy.consume(
            wireValue: request.wireTicket,
            binding: request.binding,
            capabilities: request.requestedCapabilities
        )
        await reportTicketConsumed(registration.ticketDigest)
        guard viewers[request.viewerID] == nil else {
            throw TerminalStreamError.viewerAlreadyAttached
        }
        let queue = TerminalViewerFrameQueue()
        viewers[request.viewerID] = ViewerState(
            capabilities: request.requestedCapabilities,
            queue: queue
        )
        let pending: [TerminalOutputFrame]
        if let acknowledged = request.lastAcknowledgedOutputSequence {
            guard acknowledged <= latestOutputSequence else {
                viewers.removeValue(forKey: request.viewerID)
                throw TerminalStreamError.malformedMessage
            }
            if acknowledged == latestOutputSequence {
                pending = []
            } else if let snapshot = latestSnapshot,
                      acknowledged >= snapshot.outputSequence {
                pending = retainedFrames.filter { $0.outputSequence > acknowledged }
            } else {
                pending = retainedFrames
            }
        } else {
            pending = retainedFrames
        }
        for frame in pending {
            await queue.enqueue(frame)
        }
        return Attachment(
            viewerID: request.viewerID,
            capabilities: request.requestedCapabilities.intersection(registration.capabilities),
            frames: TerminalFrameSubscription { await queue.next() }
        )
    }

    public func detach(viewerID: ViewerID) async {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard let viewer = viewers.removeValue(forKey: viewerID) else { return }
        await viewer.queue.finish()
        if lease?.grant.holderViewerID == viewerID {
            await invalidateCurrentLease(report: true)
        }
    }

    public func registerInputLease(_ grant: InputLeaseGrant) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try await registerInputLeaseLocked(grant)
    }

    package func registerInputLease(
        _ grant: InputLeaseGrant,
        supervisorGeneration: UUID
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        try await registerInputLeaseLocked(grant)
    }

    package func transferInputLease(
        from leaseID: InputLeaseID,
        to grant: InputLeaseGrant,
        supervisorGeneration: UUID
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        let valid = try validatedInputLeaseGrant(grant)
        guard let previous = lease,
              previous.grant.leaseID == leaseID,
              valid.leaseID != leaseID else {
            throw TerminalStreamError.invalidInputLease
        }
        lease = LeaseState(grant: valid, nextSequence: valid.sequenceBase)
        nextInputSequence = valid.sequenceBase
        await reportLeaseRevoked(previous.grant, previous.nextSequence)
        await resetInputState()
    }

    private func registerInputLeaseLocked(_ grant: InputLeaseGrant) async throws {
        let valid = try validatedInputLeaseGrant(grant)
        if let current = lease {
            guard current.grant == valid else {
                throw TerminalStreamError.leaseHeld
            }
            return
        }
        lease = LeaseState(grant: valid, nextSequence: valid.sequenceBase)
        nextInputSequence = valid.sequenceBase
        await resetInputState()
    }

    private func validatedInputLeaseGrant(
        _ grant: InputLeaseGrant
    ) throws -> InputLeaseGrant {
        let valid = try InputLeaseGrant(
            validatingLeaseID: grant.leaseID,
            holderViewerID: grant.holderViewerID,
            sequenceBase: grant.sequenceBase,
            capabilities: grant.capabilities
        )
        guard let holder = viewers[valid.holderViewerID] else {
            throw TerminalStreamError.viewerNotAttached
        }
        guard valid.capabilities.isSubset(of: holder.capabilities) else {
            throw TerminalStreamError.capabilityDenied
        }
        guard valid.sequenceBase >= nextInputSequence else {
            throw TerminalStreamError.nonMonotonicInputSequence
        }
        return valid
    }

    public func revokeInputLease(_ leaseID: InputLeaseID) async {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard lease?.grant.leaseID == leaseID else { return }
        await invalidateCurrentLease(report: true)
    }

    package func revokeInputLease(
        _ leaseID: InputLeaseID,
        supervisorGeneration: UUID
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        guard lease?.grant.leaseID == leaseID else { return }
        await invalidateCurrentLease(report: true)
    }

    public func acceptInput(_ frame: TerminalInputFrame) async throws -> UInt64 {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard frame.terminalSessionID == sessionID else {
            throw TerminalStreamError.sessionMismatch
        }
        guard var current = lease,
              current.grant.leaseID == frame.inputLeaseID else {
            throw TerminalStreamError.inputLeaseRequired
        }
        guard frame.context.clientInstanceID.rawValue == current.grant.holderViewerID.rawValue else {
            throw TerminalStreamError.inputLeaseRequired
        }
        guard viewers[current.grant.holderViewerID] != nil else {
            await invalidateCurrentLease(report: true)
            throw TerminalStreamError.inputLeaseRequired
        }
        if frame.inputSequence < current.nextSequence {
            guard frame.inputSequence >= current.grant.sequenceBase else {
                throw TerminalStreamError.nonMonotonicInputSequence
            }
            return frame.inputSequence
        }
        guard frame.inputSequence == current.nextSequence else {
            throw TerminalStreamError.nonMonotonicInputSequence
        }
        let required = Self.requiredCapability(for: frame.payload)
        guard current.grant.capabilities.contains(required) else {
            throw TerminalStreamError.capabilityDenied
        }
        guard current.nextSequence < UInt64.max else {
            await invalidateCurrentLease(report: true)
            throw TerminalStreamError.nonMonotonicInputSequence
        }
        do {
            try await performInput(frame.payload)
        } catch {
            await invalidateCurrentLease(report: true)
            throw error
        }
        current.nextSequence += 1
        nextInputSequence = current.nextSequence
        lease = current
        return frame.inputSequence
    }

    public func signal(
        _ signal: TerminalSignal,
        viewerID: ViewerID,
        leaseID: InputLeaseID
    ) async throws -> Int32 {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard let viewer = viewers[viewerID] else { throw TerminalStreamError.viewerNotAttached }
        guard viewer.capabilities.contains(.signal),
              let lease,
              lease.grant.leaseID == leaseID,
              lease.grant.holderViewerID == viewerID,
              lease.grant.capabilities.contains(.signal) else {
            throw TerminalStreamError.capabilityDenied
        }
        return try await signalForeground(signal)
    }

    package func signal(
        _ signal: TerminalSignal,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        supervisorGeneration: UUID
    ) async throws -> Int32 {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        guard let viewer = viewers[viewerID] else { throw TerminalStreamError.viewerNotAttached }
        guard viewer.capabilities.contains(.signal),
              let lease,
              lease.grant.leaseID == leaseID,
              lease.grant.holderViewerID == viewerID,
              lease.grant.capabilities.contains(.signal) else {
            throw TerminalStreamError.capabilityDenied
        }
        return try await signalForeground(signal)
    }

    public func terminate(
        force: Bool,
        viewerID: ViewerID,
        leaseID: InputLeaseID
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard let viewer = viewers[viewerID] else { throw TerminalStreamError.viewerNotAttached }
        guard viewer.capabilities.contains(.terminate),
              let lease,
              lease.grant.leaseID == leaseID,
              lease.grant.holderViewerID == viewerID,
              lease.grant.capabilities.contains(.terminate) else {
            throw TerminalStreamError.capabilityDenied
        }
        try await terminateSession(force)
    }

    package func terminate(
        force: Bool,
        viewerID: ViewerID,
        leaseID: InputLeaseID,
        supervisorGeneration: UUID
    ) async throws {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        guard let viewer = viewers[viewerID] else { throw TerminalStreamError.viewerNotAttached }
        guard viewer.capabilities.contains(.terminate),
              let lease,
              lease.grant.leaseID == leaseID,
              lease.grant.holderViewerID == viewerID,
              lease.grant.capabilities.contains(.terminate) else {
            throw TerminalStreamError.capabilityDenied
        }
        try await terminateSession(force)
    }

    public func publish(
        outputSequence: UInt64,
        kind: TerminalStreamFrameKind = .snapshot,
        frame: Data
    ) async {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard outputSequence > latestOutputSequence,
              let output = try? TerminalOutputFrame(
                firstOutputSequence: outputSequence,
                outputSequence: outputSequence,
                kind: kind,
                fragments: [frame]
              )
        else { return }
        switch kind {
        case .snapshot:
            latestSnapshot = output
            retainedFrames = [output]
        case .delta:
            let (expected, overflow) = latestOutputSequence.addingReportingOverflow(1)
            guard !overflow,
                  outputSequence == expected,
                  latestSnapshot != nil,
                  retainedFrames.last?.kind == .snapshot else { return }
            retainedFrames.append(output)
        case .scrollback:
            break
        }
        latestOutputSequence = outputSequence
        for viewer in viewers.values {
            await viewer.queue.enqueue(output)
        }
    }

    public func activeViewerCount() -> Int { viewers.count }

    package func supervisorInputLeaseSnapshot(
        supervisorGeneration: UUID
    ) async throws -> KeeperSupervisorLeaseSnapshot {
        await operationGate.acquire()
        defer { operationGate.release() }
        try requireSupervisorGeneration(supervisorGeneration)
        return try supervisorInputLeaseSnapshotLocked()
    }

    private func supervisorInputLeaseSnapshotLocked() throws -> KeeperSupervisorLeaseSnapshot {
        let current = lease.flatMap {
            try? KeeperInputLeaseState(grant: $0.grant, nextSequence: $0.nextSequence)
        }
        return try KeeperSupervisorLeaseSnapshot(
            currentLease: current,
            nextInputSequence: nextInputSequence
        )
    }

    package func beginSupervisorGeneration(
        _ generation: UUID,
        events: InputLeaseRevocationBuffer
    ) async throws -> Bool {
        await operationGate.acquire()
        defer { operationGate.release() }
        guard supervisorGeneration != generation else { return false }
        let incoming = try KeeperSupervisorGeneration(validating: generation)
        guard supervisorEpoch == nil || incoming.epoch > supervisorEpoch! else {
            throw KeeperControlError.identityMismatch
        }
        let changed = try await events.beginSupervisorGeneration(generation)
        if changed {
            await attachTicketPolicy.invalidateAll()
        }
        supervisorGeneration = generation
        supervisorEpoch = incoming.epoch
        return changed
    }

    public func nextOutput(viewerID: ViewerID) async throws -> TerminalOutputFrame? {
        await operationGate.acquire()
        guard let viewer = viewers[viewerID] else {
            operationGate.release()
            throw TerminalStreamError.viewerNotAttached
        }
        operationGate.release()
        return await viewer.queue.next()
    }

    private func invalidateCurrentLease(report: Bool) async {
        guard let previous = lease else { return }
        lease = nil
        nextInputSequence = previous.nextSequence
        await resetInputState()
        if report { await reportLeaseRevoked(previous.grant, previous.nextSequence) }
    }

    private func requireSupervisorGeneration(_ generation: UUID) throws {
        guard supervisorGeneration == generation else {
            throw KeeperControlError.identityMismatch
        }
    }

    private static func requiredCapability(
        for payload: TerminalInput.Payload
    ) -> TerminalAttachCapabilities {
        switch payload {
        case .text, .key, .paste, .mouse: .input
        case .resize: .resize
        case .signal: .signal
        }
    }
}

private final class TerminalStreamOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock { () -> Bool in
                if !occupied {
                    occupied = true
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if acquired { continuation.resume() }
        }
    }

    func release() {
        let next = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty {
                occupied = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

private actor TerminalViewerFrameQueue {
    private var buffered: [TerminalOutputFrame] = []
    private var waiter: CheckedContinuation<TerminalOutputFrame?, Never>?
    private var finished = false

    func enqueue(_ frame: TerminalOutputFrame) {
        guard !finished else { return }
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: frame)
            return
        }
        TerminalOutputFrame.enqueueBounded(frame, into: &buffered)
    }

    func next() async -> TerminalOutputFrame? {
        if !buffered.isEmpty { return buffered.removeFirst() }
        if finished { return nil }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func finish() {
        finished = true
        buffered.removeAll(keepingCapacity: false)
        waiter?.resume(returning: nil)
        waiter = nil
    }
}
