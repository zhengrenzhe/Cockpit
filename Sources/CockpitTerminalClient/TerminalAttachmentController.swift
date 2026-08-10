import Foundation
import CockpitTerminalCore
import CockpitTypes

public struct TerminalAttachmentIdentity: Hashable, Sendable {
    public let sessionID: TerminalSessionID
    public let generation: UInt64

    init(sessionID: TerminalSessionID, generation: UInt64) {
        self.sessionID = sessionID
        self.generation = generation
    }
}

public enum TerminalClientEvent: Sendable {
    case attached(TerminalAttachmentIdentity)
    case frame(TerminalAttachmentIdentity, TerminalOutputFrame)
    case detached(TerminalAttachmentIdentity)
    case failed(TerminalAttachmentIdentity, String)
}

public enum TerminalAttachmentError: Error, Equatable, Sendable {
    case notAttached
    case invalidAuthorization
    case generationOverflow
}

public actor TerminalAttachmentController {
    private final class ActiveAttachment: @unchecked Sendable {
        let generation: UInt64
        let sessionID: TerminalSessionID
        let connection: any TerminalDataConnection
        let frameClient: TerminalFrameClient
        var inputLease: InputLeaseGrant?
        var nextInputSequence: UInt64?
        var recoveryStarted = false
        var reader: Task<Void, Never>?
        var retired = false
        let inputGate = TerminalAttachmentCancellableOperationGate()
        let visibilityGate = TerminalAttachmentOperationGate()

        init(
            generation: UInt64,
            sessionID: TerminalSessionID,
            connection: any TerminalDataConnection,
            frameClient: TerminalFrameClient,
            inputLease: InputLeaseGrant?
        ) {
            self.generation = generation
            self.sessionID = sessionID
            self.connection = connection
            self.frameClient = frameClient
            self.inputLease = inputLease
            nextInputSequence = inputLease?.sequenceBase
        }
    }

    private let clientInstanceID: ClientInstanceID
    private let viewerID: ViewerID
    private let requestedCapabilities: TerminalAttachCapabilities
    private let controlTransport: any TerminalControlTransport
    private let dataTransport: any TerminalDataTransport
    private let lifecycleGate = TerminalAttachmentOperationGate()
    private var generation: UInt64 = 0
    private var active: ActiveAttachment?
    private var provisional: ActiveAttachment?
    private var visible = true
    private var visibilityToken = UUID()
    private var eventBuffers: [UUID: TerminalClientEventBuffer] = [:]

    public init(
        clientInstanceID: ClientInstanceID,
        requestedCapabilities: TerminalAttachCapabilities,
        controlTransport: any TerminalControlTransport,
        dataTransport: any TerminalDataTransport
    ) {
        self.clientInstanceID = clientInstanceID
        viewerID = ViewerID(clientInstanceID.rawValue)
        self.requestedCapabilities = requestedCapabilities
        self.controlTransport = controlTransport
        self.dataTransport = dataTransport
    }

    @discardableResult
    public func attach(
        sessionID: TerminalSessionID,
        lastAcknowledgedSequence: UInt64?
    ) async throws -> TerminalAttachmentIdentity {
        let next = try reserveGeneration()
        return try await attach(
            sessionID: sessionID,
            lastAcknowledgedSequence: lastAcknowledgedSequence,
            generation: next
        )
    }

    private func attach(
        sessionID: TerminalSessionID,
        lastAcknowledgedSequence: UInt64?,
        generation next: UInt64
    ) async throws -> TerminalAttachmentIdentity {
        let replaced = await closeCurrentData()
        await releaseLease(replaced)
        guard generation == next else { throw CancellationError() }
        let authorization = try await controlTransport.issueAttachTicket(
            sessionID: sessionID,
            clientInstanceID: clientInstanceID,
            viewerID: viewerID,
            capabilities: requestedCapabilities
        )
        guard generation == next else { throw CancellationError() }
        guard authorization.binding.sessionID == sessionID,
              authorization.binding.clientInstanceID == clientInstanceID,
              authorization.viewerID == viewerID,
              requestedCapabilities == authorization.capabilities,
              authorization.endpoint.sessionID == sessionID,
              authorization.endpoint.workerID == authorization.binding.workerID else {
            throw TerminalAttachmentError.invalidAuthorization
        }
        await lifecycleGate.acquire()
        let attachment: ActiveAttachment
        do {
            guard generation == next else { throw CancellationError() }
            let connection = try await dataTransport.attach(
                authorization: authorization,
                lastAcknowledgedSequence: lastAcknowledgedSequence
            )
            guard generation == next else {
                await connection.detach()
                throw CancellationError()
            }
            attachment = ActiveAttachment(
                generation: next,
                sessionID: sessionID,
                connection: connection,
                frameClient: TerminalFrameClient(
                    lastAcknowledgedSequence: lastAcknowledgedSequence
                ),
                inputLease: nil
            )
            provisional = attachment
            lifecycleGate.release()
        } catch {
            lifecycleGate.release()
            throw error
        }
        do {
            try await synchronizeVisibility(attachment)
            let synchronizedVisibilityToken = visibilityToken
            try requireCurrentProvisional(attachment)
            let leaseCapabilities = requestedCapabilities.intersection([
                .input, .resize, .signal, .terminate,
            ])
            if !leaseCapabilities.isEmpty {
                let inputLease: InputLeaseGrant?
                do {
                    inputLease = try await controlTransport.acquireInputLease(
                        sessionID: sessionID,
                        viewerID: viewerID,
                        capabilities: leaseCapabilities
                    )
                } catch TerminalStreamError.leaseHeld {
                    inputLease = nil
                }
                if let inputLease {
                    guard isCurrentProvisional(attachment) else {
                        try? await controlTransport.releaseInputLease(
                            sessionID: sessionID,
                            leaseID: inputLease.leaseID
                        )
                        throw CancellationError()
                    }
                    guard inputLease.holderViewerID == viewerID,
                          inputLease.capabilities == leaseCapabilities else {
                        try? await controlTransport.releaseInputLease(
                            sessionID: sessionID,
                            leaseID: inputLease.leaseID
                        )
                        throw TerminalAttachmentError.invalidAuthorization
                    }
                    attachment.inputLease = inputLease
                    attachment.nextInputSequence = inputLease.sequenceBase
                }
            }
            if synchronizedVisibilityToken != visibilityToken {
                try await synchronizeVisibility(attachment)
            }
            try requireCurrentProvisional(attachment)
            provisional = nil
            active = attachment
        } catch {
            let cleanup = await closeSpecificData(attachment)
            await releaseLease(cleanup)
            throw error
        }
        attachment.reader = Task { [weak self, connection = attachment.connection] in
            do {
                while !Task.isCancelled, let frame = try await connection.nextOutput() {
                    await self?.receive(frame, generation: next)
                }
                await self?.readerFinished(generation: next, error: nil)
            } catch {
                await self?.readerFinished(generation: next, error: error)
            }
        }
        let identity = TerminalAttachmentIdentity(sessionID: sessionID, generation: next)
        emit(.attached(identity))
        return identity
    }

    public func detach() async {
        _ = try? reserveGeneration()
        let retirement = await closeCurrentData()
        if let identity = retirement?.identity { emit(.detached(identity)) }
        await releaseLease(retirement)
    }

    public func send(_ input: TerminalInput) async throws {
        guard let active else { throw TerminalAttachmentError.notAttached }
        try await active.inputGate.acquire()
        defer { active.inputGate.release() }
        try Task.checkCancellation()
        guard self.active === active, !active.retired else {
            throw CancellationError()
        }
        guard input.terminalSessionID == active.sessionID else {
            throw TerminalStreamError.sessionMismatch
        }
        guard input.context.clientInstanceID == clientInstanceID,
              let lease = active.inputLease,
              let sequence = active.nextInputSequence else {
            throw TerminalStreamError.inputLeaseRequired
        }
        let outgoing = try TerminalInput(
            validatingContext: input.context,
            terminalSessionID: input.terminalSessionID,
            inputLeaseID: lease.leaseID,
            inputSequence: sequence,
            payload: input.payload
        )
        let acknowledged = try await active.connection.send(outgoing)
        guard self.active?.generation == active.generation else {
            throw CancellationError()
        }
        guard acknowledged == sequence else {
            throw TerminalStreamError.nonMonotonicInputSequence
        }
        let (next, overflow) = sequence.addingReportingOverflow(1)
        guard !overflow else { throw TerminalStreamError.nonMonotonicInputSequence }
        active.nextInputSequence = next
    }

    @_spi(CockpitTerminalApp)
    public func signal(_ signal: TerminalSignal) async throws -> Int32 {
        guard let active,
              let lease = active.inputLease,
              lease.capabilities.contains(.signal) else {
            throw TerminalStreamError.inputLeaseRequired
        }
        try await active.inputGate.acquire()
        defer { active.inputGate.release() }
        try Task.checkCancellation()
        guard self.active === active, !active.retired else { throw CancellationError() }
        let group = try await controlTransport.signal(
            sessionID: active.sessionID,
            viewerID: viewerID,
            leaseID: lease.leaseID,
            signal: signal
        )
        guard self.active === active, !active.retired else { throw CancellationError() }
        return group
    }

    @_spi(CockpitTerminalApp)
    public func terminate(force: Bool) async throws {
        guard let active,
              let lease = active.inputLease,
              lease.capabilities.contains(.terminate) else {
            throw TerminalStreamError.inputLeaseRequired
        }
        try await active.inputGate.acquire()
        defer { active.inputGate.release() }
        try Task.checkCancellation()
        guard self.active === active, !active.retired else { throw CancellationError() }
        try await controlTransport.terminate(
            sessionID: active.sessionID,
            viewerID: viewerID,
            leaseID: lease.leaseID,
            force: force
        )
        guard self.active === active, !active.retired else { throw CancellationError() }
    }

    public func setVisible(_ visible: Bool) async {
        self.visible = visible
        visibilityToken = UUID()
        if let active { try? await synchronizeVisibility(active) }
    }

    public func events() -> AsyncStream<TerminalClientEvent> {
        let id = UUID()
        let buffer = TerminalClientEventBuffer()
        eventBuffers[id] = buffer
        return AsyncStream(
            unfolding: { await buffer.next() },
            onCancel: { [weak self] in
                buffer.finish()
                Task { await self?.removeEventBuffer(id) }
            }
        )
    }

    private func reserveGeneration() throws -> UInt64 {
        let (next, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else { throw TerminalAttachmentError.generationOverflow }
        generation = next
        return next
    }

    private struct AttachmentRetirement: Sendable {
        let identity: TerminalAttachmentIdentity
        let sessionID: TerminalSessionID
        let leaseID: InputLeaseID?
    }

    private func closeCurrentData() async -> AttachmentRetirement? {
        await lifecycleGate.acquire()
        let current = provisional ?? active
        let cleanup = await closeData(current)
        if provisional === current { provisional = nil }
        if active === current { active = nil }
        lifecycleGate.release()
        return cleanup
    }

    private func closeSpecificData(_ attachment: ActiveAttachment) async -> AttachmentRetirement? {
        await lifecycleGate.acquire()
        let cleanup = await closeData(attachment)
        if provisional === attachment { provisional = nil }
        if active === attachment { active = nil }
        lifecycleGate.release()
        return cleanup
    }

    private func closeData(_ attachment: ActiveAttachment?) async -> AttachmentRetirement? {
        guard let attachment, !attachment.retired else { return nil }
        await attachment.inputGate.closeAndAcquire()
        defer { attachment.inputGate.release() }
        attachment.retired = true
        attachment.reader?.cancel()
        await attachment.connection.detach()
        if let reader = attachment.reader { await reader.value }
        let leaseID = attachment.inputLease?.leaseID
        attachment.inputLease = nil
        return AttachmentRetirement(
            identity: TerminalAttachmentIdentity(
                sessionID: attachment.sessionID,
                generation: attachment.generation
            ),
            sessionID: attachment.sessionID,
            leaseID: leaseID
        )
    }

    private func releaseLease(_ cleanup: AttachmentRetirement?) async {
        guard let cleanup, let leaseID = cleanup.leaseID else { return }
        try? await controlTransport.releaseInputLease(
            sessionID: cleanup.sessionID,
            leaseID: leaseID
        )
    }

    private func requireCurrentProvisional(_ attachment: ActiveAttachment) throws {
        guard isCurrentProvisional(attachment) else { throw CancellationError() }
    }

    private func isCurrentProvisional(_ attachment: ActiveAttachment) -> Bool {
        generation == attachment.generation
            && provisional === attachment
            && !attachment.retired
    }

    private func synchronizeVisibility(_ attachment: ActiveAttachment) async throws {
        await attachment.visibilityGate.acquire()
        defer { attachment.visibilityGate.release() }
        while true {
            guard generation == attachment.generation,
                  !attachment.retired,
                  provisional === attachment || active === attachment else {
                throw CancellationError()
            }
            let target = visible
            let token = visibilityToken
            try await attachment.connection.setVisible(target)
            guard generation == attachment.generation,
                  !attachment.retired,
                  provisional === attachment || active === attachment else {
                throw CancellationError()
            }
            if token == visibilityToken { return }
        }
    }

    private func receive(_ frame: TerminalOutputFrame, generation expected: UInt64) async {
        guard generation == expected, let active, active.generation == expected else { return }
        let decision = await active.frameClient.accept(frame)
        guard generation == expected, self.active?.generation == expected else { return }
        switch decision {
        case let .accepted(value):
            emit(.frame(
                TerminalAttachmentIdentity(sessionID: active.sessionID, generation: expected),
                value
            ))
        case .ignored: break
        case .requiresSnapshot:
            guard !active.recoveryStarted else { return }
            active.recoveryStarted = true
            let sessionID = active.sessionID
            Task { [weak self] in
                guard let self else { return }
                await self.recoverSnapshot(
                    sessionID: sessionID,
                    generation: expected
                )
            }
        }
    }

    private func recoverSnapshot(
        sessionID: TerminalSessionID,
        generation expected: UInt64
    ) async {
        guard generation == expected, active?.generation == expected else {
            return
        }
        let recoveryGeneration: UInt64
        do {
            recoveryGeneration = try reserveGeneration()
        } catch {
            emit(.failed(
                TerminalAttachmentIdentity(sessionID: sessionID, generation: expected),
                String(describing: error)
            ))
            return
        }
        do {
            _ = try await attach(
                sessionID: sessionID,
                lastAcknowledgedSequence: nil,
                generation: recoveryGeneration
            )
        } catch is CancellationError {
        } catch {
            guard generation == recoveryGeneration else { return }
            emit(.failed(
                TerminalAttachmentIdentity(
                    sessionID: sessionID,
                    generation: recoveryGeneration
                ),
                String(describing: error)
            ))
        }
    }

    private func readerFinished(generation expected: UInt64, error: (any Error)?) {
        guard generation == expected,
              let current = active,
              current.generation == expected else { return }
        let identity = TerminalAttachmentIdentity(
            sessionID: current.sessionID,
            generation: expected
        )
        active = nil
        if let error { emit(.failed(identity, String(describing: error))) }
        else { emit(.detached(identity)) }
    }

    private func emit(_ event: TerminalClientEvent) {
        for buffer in eventBuffers.values { buffer.enqueue(event) }
    }

    private func removeEventBuffer(_ id: UUID) {
        eventBuffers.removeValue(forKey: id)?.finish()
    }
}

private final class TerminalClientEventBuffer: @unchecked Sendable {
    private enum PollResult {
        case event(TerminalClientEvent)
        case finished
        case pending
    }

    private let lock = NSLock()
    private var buffered: [TerminalClientEvent] = []
    private var waiter: CheckedContinuation<TerminalClientEvent?, Never>?
    private var finished = false

    func enqueue(_ event: TerminalClientEvent) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let waiting = waiter {
            waiter = nil
            lock.unlock()
            waiting.resume(returning: event)
            return
        }
        bufferLocked(event)
        lock.unlock()
    }

    func next() async -> TerminalClientEvent? {
        switch poll() {
        case let .event(immediate):
            return immediate
        case .finished:
            return nil
        case .pending:
            return await withCheckedContinuation(register)
        }
    }

    func finish() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        buffered.removeAll(keepingCapacity: false)
        let waiting = waiter
        waiter = nil
        lock.unlock()
        waiting?.resume(returning: nil)
    }

    private func bufferLocked(_ event: TerminalClientEvent) {
        switch event {
        case .attached, .detached, .failed:
            buffered = [event]
        case let .frame(identity, frame):
            var frames = buffered.compactMap { event -> TerminalOutputFrame? in
                guard case let .frame(bufferedIdentity, frame) = event,
                      bufferedIdentity == identity else { return nil }
                return frame
            }
            TerminalOutputFrame.enqueueBounded(frame, into: &frames)
            buffered.removeAll { event in
                if case .frame = event { return true }
                return false
            }
            buffered.append(contentsOf: frames.map { .frame(identity, $0) })
        }
    }

    private func poll() -> PollResult {
        lock.lock()
        defer { lock.unlock() }
        if !buffered.isEmpty { return .event(buffered.removeFirst()) }
        return finished ? .finished : .pending
    }

    private func register(
        _ continuation: CheckedContinuation<TerminalClientEvent?, Never>
    ) {
        lock.lock()
        let result: PollResult
        if !buffered.isEmpty {
            result = .event(buffered.removeFirst())
        } else if finished {
            result = .finished
        } else {
            waiter = continuation
            result = .pending
        }
        lock.unlock()
        switch result {
        case let .event(event): continuation.resume(returning: event)
        case .finished: continuation.resume(returning: nil)
        case .pending: break
        }
    }
}

private final class TerminalAttachmentOperationGate: @unchecked Sendable {
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
            guard !waiters.isEmpty else {
                occupied = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

private final class TerminalAttachmentCancellableOperationGate: @unchecked Sendable {
    private enum WaiterState {
        case registering(cancelled: Bool)
        case waiting(CheckedContinuation<Void, any Error>)
        case owned
    }

    private let lock = NSLock()
    private var occupied = false
    private var closed = false
    private var order: [UUID] = []
    private var states: [UUID: WaiterState] = [:]
    private var retirementWaiter: CheckedContinuation<Void, Never>?

    func acquire() async throws {
        try Task.checkCancellation()
        let id = UUID()
        lock.withLock { states[id] = .registering(cancelled: false) }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    register(id, continuation: continuation)
                }
            } onCancel: {
                cancel(id)
            }
            do {
                try Task.checkCancellation()
            } catch {
                _ = lock.withLock { states.removeValue(forKey: id) }
                release()
                throw error
            }
            _ = lock.withLock { states.removeValue(forKey: id) }
        } catch {
            _ = lock.withLock { states.removeValue(forKey: id) }
            throw error
        }
    }

    func release() {
        enum Next {
            case operation(CheckedContinuation<Void, any Error>)
            case retirement(CheckedContinuation<Void, Never>)
            case none
        }
        let next = lock.withLock { () -> Next in
            if closed {
                if let retirementWaiter {
                    self.retirementWaiter = nil
                    return .retirement(retirementWaiter)
                }
                occupied = false
                return .none
            }
            while !order.isEmpty {
                let id = order.removeFirst()
                guard case let .waiting(continuation) = states[id] else { continue }
                states[id] = .owned
                return .operation(continuation)
            }
            occupied = false
            return .none
        }
        switch next {
        case let .operation(continuation): continuation.resume()
        case let .retirement(continuation): continuation.resume()
        case .none: break
        }
    }

    func closeAndAcquire() async {
        await withCheckedContinuation { retirement in
            let result = lock.withLock {
                () -> (immediate: Bool, cancelled: [CheckedContinuation<Void, any Error>]) in
                closed = true
                var cancelled: [CheckedContinuation<Void, any Error>] = []
                for id in order {
                    guard let state = states[id] else { continue }
                    switch state {
                    case .registering:
                        states[id] = .registering(cancelled: true)
                    case let .waiting(continuation):
                        states.removeValue(forKey: id)
                        cancelled.append(continuation)
                    case .owned:
                        break
                    }
                }
                order.removeAll(keepingCapacity: false)
                guard occupied else {
                    occupied = true
                    return (true, cancelled)
                }
                retirementWaiter = retirement
                return (false, cancelled)
            }
            for continuation in result.cancelled {
                continuation.resume(throwing: CancellationError())
            }
            if result.immediate { retirement.resume() }
        }
    }

    private func register(
        _ id: UUID,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        enum RegistrationResult {
            case acquired
            case cancelled
            case queued
        }
        let result = lock.withLock { () -> RegistrationResult in
            guard case let .registering(cancelled) = states[id] else {
                return .cancelled
            }
            if cancelled {
                states.removeValue(forKey: id)
                return .cancelled
            }
            if closed {
                states.removeValue(forKey: id)
                return .cancelled
            }
            if !occupied {
                occupied = true
                states[id] = .owned
                return .acquired
            }
            states[id] = .waiting(continuation)
            order.append(id)
            return .queued
        }
        switch result {
        case .acquired: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        case .queued: break
        }
    }

    private func cancel(_ id: UUID) {
        let continuation = lock.withLock {
            () -> CheckedContinuation<Void, any Error>? in
            guard let state = states[id] else { return nil }
            switch state {
            case .registering:
                states[id] = .registering(cancelled: true)
                return nil
            case let .waiting(continuation):
                states.removeValue(forKey: id)
                order.removeAll { $0 == id }
                return continuation
            case .owned:
                return nil
            }
        }
        continuation?.resume(throwing: CancellationError())
    }
}
