import Foundation
import CockpitClientCore
import CockpitProtocol
import CockpitTypes

public enum HostDataPlaneClientError: Error, Hashable, Sendable {
    case disconnected
    case requestCancelled
    case remote(DataPlaneRemoteError)
}

public enum DocumentDataPlaneDiagnostic: Hashable, Sendable {
    case committedRecoveryRequired(EditAcknowledgement)
    case fingerprintMismatch
}

private final class HostDataPlaneDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<DocumentDataPlaneDiagnostic>.Continuation] = [:]
    func stream() -> AsyncStream<DocumentDataPlaneDiagnostic> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            lock.withLock { continuations[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) } }
        }
    }
    func yield(_ diagnostic: DocumentDataPlaneDiagnostic) {
        for continuation in lock.withLock({ Array(continuations.values) }) { continuation.yield(diagnostic) }
    }
}

public actor HostDataPlaneClient: DocumentDataTransport, FileTreeDataTransport {
    private let binding: HostDataPlaneBinding
    private let xpcClient: HostXPCClient
    private let systemCalls: any UnixDomainSocketSystemCalls
    private let diagnostics = HostDataPlaneDiagnostics()
    private var descriptor: Int32?
    private var socketPath: String?
    private var incomingSequences: [UInt32: UInt64] = [:]
    private var outgoingSequences: [UInt32: UInt64] = [:]

    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient, systemCalls: any UnixDomainSocketSystemCalls) {
        self.binding = binding; self.xpcClient = xpcClient; self.systemCalls = systemCalls
    }

    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient) {
        self.init(binding: binding, xpcClient: xpcClient, systemCalls: DarwinUnixDomainSocketSystemCalls())
    }

    public func connect() async throws {
        if descriptor != nil { return }
        let context = try requestContext()
        let ticket = try await xpcClient.issueHostDataPlaneTicket(context: context)
        let fd = try systemCalls.createStreamSocket()
        do {
            try systemCalls.setCloseOnExec(fd); try systemCalls.setNoSigPipe(fd)
            try systemCalls.connect(fd, to: UnixDomainSocketAddress(path: ticket.socketPath))
            try await authenticate(fd: fd, ticket: ticket.ticket)
            descriptor = fd; socketPath = ticket.socketPath
            incomingSequences.removeAll(); outgoingSequences.removeAll()
        } catch {
            systemCalls.close(fd)
            throw normalizeConnectionError(error)
        }
    }

    public func disconnect() async {
        if let descriptor { systemCalls.close(descriptor) }
        descriptor = nil; socketPath = nil
    }

    public nonisolated func documentDiagnostics() -> AsyncStream<DocumentDataPlaneDiagnostic> { diagnostics.stream() }

    public func openDocument(in environmentID: EnvironmentID, at path: RelativePath) async throws -> DocumentSnapshot {
        guard environmentID == binding.environmentID else { throw DocumentProtocolError.invalidValue }
        var request = CPDocumentOpenRequest(); request.relativePath = path.string
        return try await document(.openRequest(request), expecting: { payload in guard case let .snapshotResult(value) = payload else { throw DocumentProtocolError.invalidValue }; return try HostDataPlaneMessages.decode(value) })
    }

    public func snapshot(documentID: DocumentID) async throws -> DocumentSnapshot {
        var request = CPDocumentSnapshotRequest(); request.documentID = documentID.description
        return try await document(.snapshotRequest(request), expecting: snapshotResult)
    }

    public func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) async throws -> EditLease {
        guard client == binding.clientInstanceID else { throw DocumentProtocolError.invalidLease }
        var request = CPDocumentAcquireLeaseRequest(); request.documentID = documentID.description
        return try await document(.acquireLeaseRequest(request), expecting: leaseResult)
    }

    public func transferEditLease(documentID: DocumentID, from leaseID: EditLeaseID, to client: ClientInstanceID) async throws -> EditLease {
        var request = CPDocumentTransferLeaseRequest(); request.documentID = documentID.description; request.fromEditLeaseID = leaseID.description; request.targetClientInstanceID = client.description
        return try await document(.transferLeaseRequest(request), expecting: leaseResult)
    }

    public func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        try await document(.applyRequest(HostDataPlaneMessages.encode(transaction))) { payload in
            guard case let .acknowledgementResult(value) = payload else { throw DocumentProtocolError.invalidValue }
            return try HostDataPlaneMessages.decode(value)
        }
    }

    public func flush(documentID: DocumentID, through clientSequence: UInt64) async throws -> UInt64 {
        var request = CPDocumentFlushRequest(); request.documentID = documentID.description; request.throughClientSequence = clientSequence
        return try await document(.flushRequest(request)) { payload in guard case let .flushResult(value) = payload else { throw DocumentProtocolError.invalidValue }; return value.documentVersion }
    }

    public func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        var request = CPDocumentSaveRequest(); request.documentID = documentID.description; request.expectedFingerprint = try HostDataPlaneMessages.encode(expectedFingerprint)
        return try await document(.saveRequest(request), expecting: snapshotResult)
    }

    public func discard(documentID: DocumentID) async throws -> DocumentSnapshot {
        var request = CPDocumentDiscardRequest(); request.documentID = documentID.description
        return try await document(.discardRequest(request), expecting: snapshotResult)
    }

    public func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot {
        try await ensureConnected()
        var request = CPFileTreeChildrenRequest(); request.directory = try HostDataPlaneMessages.encode(directory)
        var envelope = CPFileTreeEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.childrenRequest = request
        let response = try await roundTrip(channel: .fileTreeEvents, payload: envelope.serializedData())
        guard case let .fileTree(value) = try HostDataPlaneMessages.decodeEnvelope(response), value.requestID == envelope.requestID, let payload = value.payload else { throw HostDataPlaneClientError.disconnected }
        if case let .error(error) = payload { throw mapRemote(error, diagnostics: diagnostics) }
        guard case let .snapshotResult(snapshot) = payload else { throw HostDataPlaneClientError.disconnected }
        return try HostDataPlaneMessages.decode(snapshot)
    }

    public nonisolated func changes(after revision: UInt64, expandedDirectories: Set<WorkspaceDirectory>) -> AsyncThrowingStream<FileTreeDelta, Error> {
        let state = HostDataPlaneTreeStream(binding: binding, xpcClient: xpcClient, systemCalls: systemCalls, after: revision, expandedDirectories: expandedDirectories)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await state.start()
                    while let delta = try await state.next() {
                        if case .terminated = continuation.yield(delta) { return }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: HostDataPlaneClientError.requestCancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await state.cancel() }
            }
        }
    }

    private func ensureConnected() async throws { if descriptor == nil { try await connect() } }

    private func document<Result: Sendable>(_ payload: CPDocumentEnvelope.OneOf_Payload, expecting transform: (CPDocumentEnvelope.OneOf_Payload) throws -> Result) async throws -> Result {
        try Task.checkCancellation(); try await ensureConnected()
        var envelope = CPDocumentEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.payload = payload
        let response = try await roundTrip(channel: .documentEdits, payload: envelope.serializedData())
        if Task.isCancelled { throw HostDataPlaneClientError.requestCancelled }
        guard case let .document(value) = try HostDataPlaneMessages.decodeEnvelope(response), value.requestID == envelope.requestID, let payload = value.payload else { throw HostDataPlaneClientError.disconnected }
        if case let .error(error) = payload { throw mapRemote(error, diagnostics: diagnostics) }
        return try transform(payload)
    }

    private func roundTrip(channel: ChannelID, payload: Data) async throws -> Frame {
        guard let descriptor else { throw HostDataPlaneClientError.disconnected }
        let sequence = (outgoingSequences[channel.rawValue] ?? 0) + 1
        let acknowledgement = incomingSequences[channel.rawValue] ?? 0
        do {
            try writeFrame(systemCalls, descriptor, channel: channel, sequence: sequence, acknowledgement: acknowledgement, payload: payload)
            outgoingSequences[channel.rawValue] = sequence
            let response = try await readFrameAsync(systemCalls, descriptor)
            guard response.header.channel == channel,
                  response.header.sequence == acknowledgement + 1,
                  response.header.acknowledgement == sequence
            else { throw HostDataPlaneClientError.disconnected }
            incomingSequences[channel.rawValue] = response.header.sequence
            return response
        } catch {
            systemCalls.close(descriptor); self.descriptor = nil
            throw normalizeConnectionError(error)
        }
    }

    private func authenticate(fd: Int32, ticket: String) async throws {
        var handshake = CPHostDataPlaneControlEnvelope(); handshake.handshakeRequest = .cockpit(deviceID: DeviceID(), features: [.hostDataPlane])
        try writeFrame(systemCalls, fd, channel: .control, sequence: 1, acknowledgement: 0, payload: handshake.serializedData())
        let handshakeResponse = try await readFrameAsync(systemCalls, fd)
        guard handshakeResponse.header.channel == .control, handshakeResponse.header.sequence == 1, handshakeResponse.header.acknowledgement == 1 else { throw HostDataPlaneClientError.disconnected }
        _ = try HostDataPlaneMessages.decodeHandshakeResponse(handshakeResponse.payload)
        var auth = CPHostDataPlaneAuthenticate(); auth.ticket = ticket; auth.binding = try HostDataPlaneMessages.encode(binding)
        var envelope = CPHostDataPlaneControlEnvelope(); envelope.authenticate = auth
        try writeFrame(systemCalls, fd, channel: .control, sequence: 2, acknowledgement: 1, payload: envelope.serializedData())
        let authResponse = try await readFrameAsync(systemCalls, fd)
        guard authResponse.header.channel == .control, authResponse.header.sequence == 2, authResponse.header.acknowledgement == 2 else { throw HostDataPlaneClientError.disconnected }
        let decoded = try HostDataPlaneMessages.decodeControlEnvelope(authResponse.payload)
        switch decoded.payload {
        case let .authenticated(value)?: guard try HostDataPlaneMessages.decode(value.binding) == binding else { throw HostDataPlaneClientError.disconnected }
        case let .error(error)?: throw mapRemote(error, diagnostics: diagnostics)
        default: throw HostDataPlaneClientError.disconnected
        }
    }

    private func requestContext() throws -> RequestContext {
        try RequestContext(validating: .current, clientInstanceID: binding.clientInstanceID, windowID: binding.windowID, workspaceContextID: binding.workspaceContextID, environmentID: binding.environmentID, activeContextGeneration: binding.activeContextGeneration, requestID: RequestID())
    }
}

private actor HostDataPlaneTreeStream {
    private let binding: HostDataPlaneBinding
    private let xpcClient: HostXPCClient
    private let calls: any UnixDomainSocketSystemCalls
    private var after: UInt64
    private let expanded: [WorkspaceDirectory]
    private var descriptor: Int32?
    private var nextOutgoing: UInt64 = 1
    private var lastIncoming: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0
    private var subscriptionID: String?
    private var pendingEvent: (id: String, revision: UInt64)?
    private var startup: Task<Void, Error>?
    private var cancelled = false

    init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient, systemCalls: any UnixDomainSocketSystemCalls, after: UInt64, expandedDirectories: Set<WorkspaceDirectory>) {
        self.binding = binding; self.xpcClient = xpcClient; calls = systemCalls; self.after = after
        expanded = expandedDirectories.sorted { String(describing: $0) < String(describing: $1) }
    }

    func start() { guard startup == nil else { return }; startup = Task { try await establishAndSubscribe() } }

    func next() async throws -> FileTreeDelta? {
        if cancelled { throw CancellationError() }
        if startup == nil { start() }
        try await startup?.value
        if let pendingEvent { try await acknowledge(pendingEvent); self.pendingEvent = nil }
        while true {
            guard let descriptor else { throw HostDataPlaneClientError.disconnected }
            let frame = try await readFrameAsync(calls, descriptor)
            guard frame.header.channel == .fileTreeEvents,
                  frame.header.sequence == lastIncoming + 1,
                  frame.header.acknowledgement >= lastAcknowledged,
                  frame.header.acknowledgement < nextOutgoing
            else { throw HostDataPlaneClientError.disconnected }
            lastIncoming = frame.header.sequence
            lastAcknowledged = frame.header.acknowledgement
            guard case let .fileTree(envelope) = try HostDataPlaneMessages.decodeEnvelope(frame), let payload = envelope.payload else { throw HostDataPlaneClientError.disconnected }
            switch payload {
            case let .deltaEvent(event):
                guard event.subscriptionID == subscriptionID else { throw HostDataPlaneClientError.disconnected }
                let delta = try HostDataPlaneMessages.decode(event.delta); pendingEvent = (event.eventID, delta.revision); return delta
            case let .error(error):
                if error.code == .treeRevisionUnavailable { try await recover(current: error.expected); continue }
                throw mapRemote(error, diagnostics: nil)
            default: continue
            }
        }
    }

    func cancel() {
        cancelled = true; startup?.cancel()
        if let descriptor {
            if let subscriptionID {
                var request = CPFileTreeCancelRequest(); request.subscriptionID = subscriptionID
                var envelope = CPFileTreeEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try! HostDataPlaneMessages.encode(binding); envelope.cancelRequest = request
                try? send(envelope)
            }
            calls.close(descriptor); self.descriptor = nil
        }
    }

    private func establishAndSubscribe() async throws {
        let context = try RequestContext(validating: .current, clientInstanceID: binding.clientInstanceID, windowID: binding.windowID, workspaceContextID: binding.workspaceContextID, environmentID: binding.environmentID, activeContextGeneration: binding.activeContextGeneration, requestID: RequestID())
        let ticket = try await xpcClient.issueHostDataPlaneTicket(context: context)
        let fd = try calls.createStreamSocket()
        do {
            try calls.setCloseOnExec(fd); try calls.setNoSigPipe(fd); try calls.connect(fd, to: UnixDomainSocketAddress(path: ticket.socketPath))
            try await authenticateTree(fd: fd, ticket: ticket.ticket, binding: binding, calls: calls)
            descriptor = fd
            try await subscribe()
        } catch { calls.close(fd); throw normalizeConnectionError(error) }
    }

    private func subscribe() async throws {
        var request = CPFileTreeSubscribeRequest(); request.afterRevision = after
        let id = RequestID().description
        var envelope = CPFileTreeEnvelope(); envelope.requestID = id; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.subscribeRequest = request
        try send(envelope)
        let response = try await receive()
        guard case let .subscriptionAccepted(value)? = response.payload, value.subscriptionID == id else { throw HostDataPlaneClientError.disconnected }
        subscriptionID = id
    }

    private func acknowledge(_ event: (id: String, revision: UInt64)) async throws {
        guard let subscriptionID else { throw HostDataPlaneClientError.disconnected }
        var ack = CPFileTreeDeltaAck(); ack.subscriptionID = subscriptionID; ack.eventID = event.id; ack.revision = event.revision
        var envelope = CPFileTreeEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.deltaAck = ack
        try send(envelope); _ = try await receive()
    }

    private func recover(current: UInt64) async throws {
        var maximum = current
        for directory in expanded {
            var request = CPFileTreeChildrenRequest(); request.directory = try HostDataPlaneMessages.encode(directory)
            var envelope = CPFileTreeEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.childrenRequest = request
            try send(envelope); let response = try await receive()
            guard case let .snapshotResult(value)? = response.payload else { throw HostDataPlaneClientError.disconnected }
            maximum = max(maximum, try HostDataPlaneMessages.decode(value).revision)
        }
        after = maximum; try await subscribe()
    }

    private func send(_ envelope: CPFileTreeEnvelope) throws {
        guard let descriptor else { throw HostDataPlaneClientError.disconnected }
        try writeFrame(calls, descriptor, channel: .fileTreeEvents, sequence: nextOutgoing, acknowledgement: lastIncoming, payload: envelope.serializedData()); nextOutgoing += 1
    }
    private func receive() async throws -> CPFileTreeEnvelope {
        guard let descriptor else { throw HostDataPlaneClientError.disconnected }
        let frame = try await readFrameAsync(calls, descriptor)
        guard frame.header.channel == .fileTreeEvents,
              frame.header.sequence == lastIncoming + 1,
              frame.header.acknowledgement >= lastAcknowledged,
              frame.header.acknowledgement < nextOutgoing
        else { throw HostDataPlaneClientError.disconnected }
        lastIncoming = frame.header.sequence
        lastAcknowledged = frame.header.acknowledgement
        guard case let .fileTree(envelope) = try HostDataPlaneMessages.decodeEnvelope(frame) else { throw HostDataPlaneClientError.disconnected }
        if case let .error(error)? = envelope.payload { throw mapRemote(error, diagnostics: nil) }
        return envelope
    }
}

private func authenticateTree(fd: Int32, ticket: String, binding: HostDataPlaneBinding, calls: any UnixDomainSocketSystemCalls) async throws {
    var handshake = CPHostDataPlaneControlEnvelope(); handshake.handshakeRequest = .cockpit(deviceID: DeviceID(), features: [.hostDataPlane])
    try writeFrame(calls, fd, channel: .control, sequence: 1, acknowledgement: 0, payload: handshake.serializedData())
    let handshakeResponse = try await readFrameAsync(calls, fd)
    guard handshakeResponse.header.channel == .control,
          handshakeResponse.header.sequence == 1,
          handshakeResponse.header.acknowledgement == 1
    else { throw HostDataPlaneClientError.disconnected }
    _ = try HostDataPlaneMessages.decodeHandshakeResponse(handshakeResponse.payload)
    var auth = CPHostDataPlaneAuthenticate(); auth.ticket = ticket; auth.binding = try HostDataPlaneMessages.encode(binding)
    var envelope = CPHostDataPlaneControlEnvelope(); envelope.authenticate = auth
    try writeFrame(calls, fd, channel: .control, sequence: 2, acknowledgement: 1, payload: envelope.serializedData())
    let response = try await readFrameAsync(calls, fd)
    guard response.header.channel == .control,
          response.header.sequence == 2,
          response.header.acknowledgement == 2
    else { throw HostDataPlaneClientError.disconnected }
    let decoded = try HostDataPlaneMessages.decodeControlEnvelope(response.payload)
    guard case let .authenticated(value)? = decoded.payload,
          try HostDataPlaneMessages.decode(value.binding) == binding
    else { throw HostDataPlaneClientError.disconnected }
}

private func snapshotResult(_ payload: CPDocumentEnvelope.OneOf_Payload) throws -> DocumentSnapshot { guard case let .snapshotResult(value) = payload else { throw DocumentProtocolError.invalidValue }; return try HostDataPlaneMessages.decode(value) }
private func leaseResult(_ payload: CPDocumentEnvelope.OneOf_Payload) throws -> EditLease { guard case let .leaseResult(value) = payload else { throw DocumentProtocolError.invalidValue }; return try HostDataPlaneMessages.decode(value) }

private func mapRemote(_ value: CPDataPlaneError, diagnostics: HostDataPlaneDiagnostics?) -> any Error {
    switch value.code {
    case .documentInvalidValue, .documentNotOpen: return DocumentProtocolError.invalidValue
    case .documentInvalidLease: return DocumentProtocolError.invalidLease
    case .documentLeaseHeld: return DocumentProtocolError.leaseHeld
    case .documentBaseVersionMismatch: return DocumentProtocolError.baseVersionMismatch(expected: value.expected, actual: value.actual)
    case .documentSequenceGap: return DocumentProtocolError.sequenceGap(expected: value.expected, actual: value.actual)
    case .documentDuplicateMismatch: return DocumentProtocolError.duplicateMismatch
    case .documentStaleSequence: return DocumentProtocolError.staleSequence
    case .documentRecoveryRequired:
        if value.hasCommittedAcknowledgement, let ack = try? HostDataPlaneMessages.decode(value.committedAcknowledgement) { diagnostics?.yield(.committedRecoveryRequired(ack)) }
        return DocumentProtocolError.recoveryRequired
    case .documentFingerprintMismatch: diagnostics?.yield(.fingerprintMismatch); return DocumentProtocolError.recoveryRequired
    case .documentResynchronizing: return DocumentProtocolError.resynchronizing
    case .documentReadOnly: return DocumentProtocolError.readOnly
    case .documentFileMissing: return DocumentProtocolError.fileMissing
    case .requestCancelled: return HostDataPlaneClientError.requestCancelled
    default:
        return HostDataPlaneClientError.remote((try? DataPlaneRemoteError(validatingCode: value.code, expected: value.hasExpected ? value.expected : nil, actual: value.hasActual ? value.actual : nil)) ?? (try! DataPlaneRemoteError(validatingCode: .internal, expected: nil, actual: nil)))
    }
}

private func normalizeConnectionError(_ error: any Error) -> any Error {
    if error is HostDataPlaneClientError || error is DocumentProtocolError { return error }
    return HostDataPlaneClientError.disconnected
}
