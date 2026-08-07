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
    private let bootstrapReadQueue = DispatchQueue(
        label: "dev.cockpit.host-data-plane.client-bootstrap-read"
    )
    private var connection: HostDataPlaneClientConnection?

    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient, systemCalls: any UnixDomainSocketSystemCalls) {
        self.binding = binding; self.xpcClient = xpcClient; self.systemCalls = systemCalls
    }

    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient) {
        self.init(binding: binding, xpcClient: xpcClient, systemCalls: DarwinUnixDomainSocketSystemCalls())
    }

    public func connect() async throws {
        if let connection, !connection.isClosed { return }
        connection = nil
        let context = try requestContext()
        let ticket: CPHostDataPlaneTicketResponse
        do {
            ticket = try await xpcClient.issueHostDataPlaneTicket(context: context)
        } catch {
            throw HostDataPlaneClientError.disconnected
        }
        let fd = try systemCalls.createStreamSocket()
        let owner = HostDataPlaneDescriptorOwner(fd, calls: systemCalls)
        do {
            try systemCalls.setCloseOnExec(fd); try systemCalls.setNoSigPipe(fd)
            try systemCalls.connect(fd, to: UnixDomainSocketAddress(path: ticket.socketPath))
            try await authenticate(fd: fd, ticket: ticket.ticket)
            let established = HostDataPlaneClientConnection(
                descriptorOwner: owner,
                systemCalls: systemCalls,
                binding: binding
            )
            connection = established
            established.start()
        } catch {
            owner.close()
            throw normalizeConnectionError(error)
        }
    }

    public func disconnect() async {
        let current = connection
        connection = nil
        await current?.shutdown()
    }

    public nonisolated func documentDiagnostics() -> AsyncStream<DocumentDataPlaneDiagnostic> { diagnostics.stream() }

    public func openDocument(in environmentID: EnvironmentID, at path: RelativePath) async throws -> DocumentSnapshot {
        guard environmentID == binding.environmentID else { throw DocumentProtocolError.invalidValue }
        var request = CPDocumentOpenRequest(); request.relativePath = path.string
        return try await document(
            .openRequest(request),
            expectation: .opened(environmentID: environmentID, path: path),
            expecting: snapshotResult
        )
    }

    public func snapshot(documentID: DocumentID) async throws -> DocumentSnapshot {
        var request = CPDocumentSnapshotRequest(); request.documentID = documentID.description
        return try await document(
            .snapshotRequest(request),
            expectation: .snapshot(documentID),
            expecting: snapshotResult
        )
    }

    public func acquireEditLease(documentID: DocumentID, client: ClientInstanceID) async throws -> EditLease {
        guard client == binding.clientInstanceID else { throw DocumentProtocolError.invalidLease }
        var request = CPDocumentAcquireLeaseRequest(); request.documentID = documentID.description
        return try await document(
            .acquireLeaseRequest(request),
            expectation: .lease(documentID: documentID, client: client),
            expecting: leaseResult
        )
    }

    public func transferEditLease(documentID: DocumentID, from leaseID: EditLeaseID, to client: ClientInstanceID) async throws -> EditLease {
        var request = CPDocumentTransferLeaseRequest(); request.documentID = documentID.description; request.fromEditLeaseID = leaseID.description; request.targetClientInstanceID = client.description
        return try await document(
            .transferLeaseRequest(request),
            expectation: .lease(documentID: documentID, client: client),
            expecting: leaseResult
        )
    }

    public func apply(_ transaction: EditTransaction) async throws -> EditAcknowledgement {
        try await document(
            .applyRequest(HostDataPlaneMessages.encode(transaction)),
            expectation: .acknowledgement(
                documentID: transaction.documentID,
                clientSequence: transaction.clientSequence
            )
        ) { payload in
            guard case let .acknowledgementResult(value) = payload else { throw DocumentProtocolError.invalidValue }
            return try HostDataPlaneMessages.decode(value)
        }
    }

    public func flush(documentID: DocumentID, through clientSequence: UInt64) async throws -> UInt64 {
        var request = CPDocumentFlushRequest(); request.documentID = documentID.description; request.throughClientSequence = clientSequence
        return try await document(
            .flushRequest(request),
            expectation: .flush
        ) { payload in
            guard case let .flushResult(value) = payload else {
                throw DocumentProtocolError.invalidValue
            }
            return value.documentVersion
        }
    }

    public func save(documentID: DocumentID, expectedFingerprint: DiskFingerprint) async throws -> DocumentSnapshot {
        var request = CPDocumentSaveRequest(); request.documentID = documentID.description; request.expectedFingerprint = try HostDataPlaneMessages.encode(expectedFingerprint)
        return try await document(
            .saveRequest(request),
            expectation: .snapshot(documentID),
            expecting: snapshotResult
        )
    }

    public func discard(documentID: DocumentID) async throws -> DocumentSnapshot {
        var request = CPDocumentDiscardRequest(); request.documentID = documentID.description
        return try await document(
            .discardRequest(request),
            expectation: .snapshot(documentID),
            expecting: snapshotResult
        )
    }

    public func children(at directory: WorkspaceDirectory) async throws -> FileTreeSnapshot {
        try await ensureConnected()
        var request = CPFileTreeChildrenRequest(); request.directory = try HostDataPlaneMessages.encode(directory)
        var envelope = CPFileTreeEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.childrenRequest = request
        let response = try await roundTrip(
            channel: .fileTreeEvents,
            requestID: envelope.requestID,
            payload: envelope.serializedData()
        )
        let value: CPFileTreeEnvelope
        do {
            guard case let .fileTree(decoded) = try HostDataPlaneMessages.decodeEnvelope(response),
                  decoded.requestID == envelope.requestID,
                  try HostDataPlaneMessages.decode(decoded.binding) == binding,
                  decoded.payload != nil else {
                throw HostDataPlaneResponseValidationError()
            }
            value = decoded
        } catch {
            await invalidateConnection()
            throw HostDataPlaneClientError.disconnected
        }
        guard let responsePayload = value.payload else {
            await invalidateConnection()
            throw HostDataPlaneClientError.disconnected
        }
        if case let .error(error) = responsePayload {
            throw mapRemote(error, diagnostics: diagnostics)
        }
        do {
            guard case let .snapshotResult(snapshot) = responsePayload else {
                throw HostDataPlaneResponseValidationError()
            }
            let decoded = try HostDataPlaneMessages.decode(snapshot)
            guard decoded.environmentID == binding.environmentID,
                  decoded.generation == binding.activeContextGeneration,
                  decoded.directory == directory else {
                throw HostDataPlaneResponseValidationError()
            }
            return decoded
        } catch {
            await invalidateConnection()
            throw HostDataPlaneClientError.disconnected
        }
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

    private func ensureConnected() async throws {
        if connection == nil || connection?.isClosed == true { try await connect() }
    }

    private func document<Result: Sendable>(
        _ payload: CPDocumentEnvelope.OneOf_Payload,
        expectation: HostDataPlaneDocumentExpectation,
        expecting transform: (CPDocumentEnvelope.OneOf_Payload) throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation(); try await ensureConnected()
        var envelope = CPDocumentEnvelope(); envelope.requestID = RequestID().description; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.payload = payload
        let response = try await roundTrip(
            channel: .documentEdits,
            requestID: envelope.requestID,
            payload: envelope.serializedData()
        )
        if Task.isCancelled { throw HostDataPlaneClientError.requestCancelled }
        let value: CPDocumentEnvelope
        do {
            guard case let .document(decoded) = try HostDataPlaneMessages.decodeEnvelope(response),
                  decoded.requestID == envelope.requestID,
                  try HostDataPlaneMessages.decode(decoded.binding) == binding,
                  decoded.payload != nil else {
                throw HostDataPlaneResponseValidationError()
            }
            value = decoded
        } catch {
            await invalidateConnection()
            throw HostDataPlaneClientError.disconnected
        }
        guard let responsePayload = value.payload else {
            await invalidateConnection()
            throw HostDataPlaneClientError.disconnected
        }
        if case let .error(error) = responsePayload {
            let mapped = mapRemote(
                error,
                diagnostics: diagnostics,
                expectation: expectation
            )
            switch mapped {
            case let .application(error): throw error
            case .protocolViolation:
                await invalidateConnection()
                throw HostDataPlaneClientError.disconnected
            }
        }
        do {
            try expectation.validate(responsePayload)
            return try transform(responsePayload)
        } catch {
            await invalidateConnection()
            throw HostDataPlaneClientError.disconnected
        }
    }

    private func roundTrip(
        channel: ChannelID,
        requestID: String,
        payload: Data
    ) async throws -> Frame {
        guard let connection else { throw HostDataPlaneClientError.disconnected }
        do {
            return try await connection.roundTrip(
                channel: channel,
                requestID: requestID,
                payload: payload
            )
        } catch {
            if connection.isClosed, self.connection === connection {
                self.connection = nil
            }
            throw normalizeConnectionError(error)
        }
    }

    private func invalidateConnection() async {
        let current = connection
        connection = nil
        await current?.shutdown()
    }

    private func authenticate(fd: Int32, ticket: String) async throws {
        var handshake = CPHostDataPlaneControlEnvelope(); handshake.handshakeRequest = .cockpit(deviceID: DeviceID(), features: [.hostDataPlane])
        try writeFrame(systemCalls, fd, channel: .control, sequence: 1, acknowledgement: 0, payload: handshake.serializedData())
        let handshakeResponse = try await readFrameAsync(
            systemCalls,
            fd,
            queue: bootstrapReadQueue
        )
        guard handshakeResponse.header.channel == .control, handshakeResponse.header.sequence == 1, handshakeResponse.header.acknowledgement == 1 else { throw HostDataPlaneClientError.disconnected }
        _ = try HostDataPlaneMessages.decodeHandshakeResponse(handshakeResponse.payload)
        var auth = CPHostDataPlaneAuthenticate(); auth.ticket = ticket; auth.binding = try HostDataPlaneMessages.encode(binding)
        var envelope = CPHostDataPlaneControlEnvelope(); envelope.authenticate = auth
        try writeFrame(systemCalls, fd, channel: .control, sequence: 2, acknowledgement: 1, payload: envelope.serializedData())
        let authResponse = try await readFrameAsync(
            systemCalls,
            fd,
            queue: bootstrapReadQueue
        )
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

private struct HostDataPlaneResponseValidationError: Error {}

private enum HostDataPlaneDocumentExpectation {
    case opened(environmentID: EnvironmentID, path: RelativePath)
    case snapshot(DocumentID)
    case lease(documentID: DocumentID, client: ClientInstanceID)
    case acknowledgement(documentID: DocumentID, clientSequence: UInt64)
    case flush

    func validate(_ payload: CPDocumentEnvelope.OneOf_Payload) throws {
        switch self {
        case let .opened(environmentID, path):
            guard case let .snapshotResult(value) = payload else { throw HostDataPlaneResponseValidationError() }
            let snapshot = try HostDataPlaneMessages.decode(value)
            guard snapshot.environmentID == environmentID,
                  snapshot.relativePath == path else {
                throw HostDataPlaneResponseValidationError()
            }
        case let .snapshot(documentID):
            guard case let .snapshotResult(value) = payload,
                  try HostDataPlaneMessages.decode(value).documentID == documentID else {
                throw HostDataPlaneResponseValidationError()
            }
        case let .lease(documentID, client):
            guard case let .leaseResult(value) = payload else { throw HostDataPlaneResponseValidationError() }
            let lease = try HostDataPlaneMessages.decode(value)
            guard lease.documentID == documentID,
                  lease.clientInstanceID == client else {
                throw HostDataPlaneResponseValidationError()
            }
        case let .acknowledgement(documentID, clientSequence):
            guard case let .acknowledgementResult(value) = payload else { throw HostDataPlaneResponseValidationError() }
            let acknowledgement = try HostDataPlaneMessages.decode(value)
            guard acknowledgement.documentID == documentID,
                  acknowledgement.clientSequence == clientSequence else {
                throw HostDataPlaneResponseValidationError()
            }
        case .flush:
            guard case .flushResult = payload else { throw HostDataPlaneResponseValidationError() }
        }
    }

    func matchesCommittedAcknowledgement(_ acknowledgement: EditAcknowledgement) -> Bool {
        guard case let .acknowledgement(documentID, clientSequence) = self else {
            return false
        }
        return acknowledgement.documentID == documentID
            && acknowledgement.clientSequence == clientSequence
    }
}

private enum HostDataPlaneRemoteMapping {
    case application(any Error)
    case protocolViolation
}

private final class HostDataPlaneClientConnection: @unchecked Sendable {
    private struct PendingKey: Hashable {
        let channel: UInt32
        let requestID: String
    }

    private struct PendingRequest {
        let outgoingSequence: UInt64
        var continuation: CheckedContinuation<Frame, any Error>?
    }

    private let descriptorOwner: HostDataPlaneDescriptorOwner
    private let calls: any UnixDomainSocketSystemCalls
    private let binding: HostDataPlaneBinding
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let readQueue = DispatchQueue(label: "dev.cockpit.host-data-plane.client-read")
    private var readerStarted = false
    private var closed = false
    private var pending: [PendingKey: PendingRequest] = [:]
    private var usedRequestIDs: Set<String> = []
    private var lastIncoming: [UInt32: UInt64] = [:]
    private var lastAcknowledged: [UInt32: UInt64] = [:]
    private var lastOutgoing: [UInt32: UInt64] = [:]

    init(
        descriptorOwner: HostDataPlaneDescriptorOwner,
        systemCalls: any UnixDomainSocketSystemCalls,
        binding: HostDataPlaneBinding
    ) {
        self.descriptorOwner = descriptorOwner
        calls = systemCalls
        self.binding = binding
    }

    var isClosed: Bool { lock.withLock { closed } }

    func start() {
        let startsReader = lock.withLock { () -> Bool in
            guard !readerStarted, !closed else { return false }
            readerStarted = true
            return true
        }
        guard startsReader else { return }
        readQueue.async { [self] in
            readLoop()
        }
    }

    func roundTrip(
        channel: ChannelID,
        requestID: String,
        payload: Data
    ) async throws -> Frame {
        let key = PendingKey(channel: channel.rawValue, requestID: requestID)
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                submit(
                    key: key,
                    channel: channel,
                    payload: payload,
                    cancelled: withUnsafeCurrentTask { $0?.isCancelled == true },
                    continuation: continuation
                )
            }
        } onCancel: {
            self.cancel(key)
        }
    }

    func shutdown() async {
        failConnection()
    }

    private func submit(
        key: PendingKey,
        channel: ChannelID,
        payload: Data,
        cancelled: Bool,
        continuation: CheckedContinuation<Frame, any Error>
    ) {
        guard !cancelled else {
            continuation.resume(throwing: HostDataPlaneClientError.requestCancelled)
            return
        }
        var registered = false
        do {
            try writeLock.withLock {
                guard let descriptor = descriptorOwner.descriptor else {
                    throw HostDataPlaneClientError.disconnected
                }
                let state = try lock.withLock { () -> (UInt64, UInt64) in
                    guard !closed,
                          usedRequestIDs.insert(key.requestID).inserted,
                          case let .value(sequence) = hostDataPlaneAdvanceSequence(
                            lastOutgoing[channel.rawValue] ?? 0
                          ) else {
                        throw HostDataPlaneClientError.disconnected
                    }
                    lastOutgoing[channel.rawValue] = sequence
                    pending[key] = PendingRequest(
                        outgoingSequence: sequence,
                        continuation: continuation
                    )
                    registered = true
                    return (sequence, lastIncoming[channel.rawValue] ?? 0)
                }
                try writeFrame(
                    calls,
                    descriptor,
                    channel: channel,
                    sequence: state.0,
                    acknowledgement: state.1,
                    payload: payload
                )
            }
        } catch {
            if registered {
                failConnection()
            } else {
                continuation.resume(throwing: HostDataPlaneClientError.disconnected)
            }
        }
    }

    private func cancel(_ key: PendingKey) {
        let continuation = lock.withLock { () -> CheckedContinuation<Frame, any Error>? in
            guard var request = pending[key], let continuation = request.continuation else {
                return nil
            }
            request.continuation = nil
            pending[key] = request
            return continuation
        }
        continuation?.resume(throwing: HostDataPlaneClientError.requestCancelled)
    }

    private func readLoop() {
        do {
            while let descriptor = descriptorOwner.descriptor {
                try dispatch(try readFrame(calls, descriptor))
            }
        } catch {
            failConnection()
        }
    }

    private func dispatch(_ frame: Frame) throws {
        let requestID: String
        let responseBinding: HostDataPlaneBinding
        switch try HostDataPlaneMessages.decodeEnvelope(frame) {
        case let .document(envelope):
            guard frame.header.channel == .documentEdits else {
                throw HostDataPlaneResponseValidationError()
            }
            requestID = envelope.requestID
            responseBinding = try HostDataPlaneMessages.decode(envelope.binding)
        case let .fileTree(envelope):
            guard frame.header.channel == .fileTreeEvents else {
                throw HostDataPlaneResponseValidationError()
            }
            requestID = envelope.requestID
            responseBinding = try HostDataPlaneMessages.decode(envelope.binding)
        case .control:
            throw HostDataPlaneResponseValidationError()
        }
        guard responseBinding == binding else { throw HostDataPlaneResponseValidationError() }

        let key = PendingKey(channel: frame.header.channel.rawValue, requestID: requestID)
        let continuation = try lock.withLock { () -> CheckedContinuation<Frame, any Error>? in
            guard !closed,
                  let request = pending[key],
                  case let .value(expectedSequence) = hostDataPlaneAdvanceSequence(
                    lastIncoming[frame.header.channel.rawValue] ?? 0
                  ),
                  frame.header.sequence == expectedSequence,
                  frame.header.acknowledgement >= request.outgoingSequence,
                  frame.header.acknowledgement >= (lastAcknowledged[frame.header.channel.rawValue] ?? 0),
                  frame.header.acknowledgement <= (lastOutgoing[frame.header.channel.rawValue] ?? 0) else {
                throw HostDataPlaneResponseValidationError()
            }
            lastIncoming[frame.header.channel.rawValue] = frame.header.sequence
            lastAcknowledged[frame.header.channel.rawValue] = frame.header.acknowledgement
            pending.removeValue(forKey: key)
            return request.continuation
        }
        continuation?.resume(returning: frame)
    }

    private func failConnection() {
        let continuations = lock.withLock { () -> [CheckedContinuation<Frame, any Error>] in
            guard !closed else { return [] }
            closed = true
            let continuations = pending.values.compactMap(\.continuation)
            pending.removeAll()
            return continuations
        }
        descriptorOwner.close()
        for continuation in continuations {
            continuation.resume(throwing: HostDataPlaneClientError.disconnected)
        }
    }
}

private actor HostDataPlaneTreeStream {
    private struct CancelWaiter {
        let requestID: String
        let subscriptionID: String
        let continuation: CheckedContinuation<Void, Never>
    }

    private let binding: HostDataPlaneBinding
    private let xpcClient: HostXPCClient
    private let calls: any UnixDomainSocketSystemCalls
    private let readQueue = DispatchQueue(label: "dev.cockpit.host-data-plane.tree-read")
    private var after: UInt64
    private let expanded: [WorkspaceDirectory]
    private var descriptorOwner: HostDataPlaneDescriptorOwner?
    private var lastOutgoing: UInt64 = 0
    private var lastIncoming: UInt64 = 0
    private var lastAcknowledged: UInt64 = 0
    private var subscriptionID: String?
    private var pendingEvent: (id: String, revision: UInt64)?
    private var startup: Task<Void, Error>?
    private var established = false
    private var cancelled = false
    private var readInFlight = false
    private var cancelWaiter: CancelWaiter?

    init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient, systemCalls: any UnixDomainSocketSystemCalls, after: UInt64, expandedDirectories: Set<WorkspaceDirectory>) {
        self.binding = binding; self.xpcClient = xpcClient; calls = systemCalls; self.after = after
        expanded = expandedDirectories.sorted { String(describing: $0) < String(describing: $1) }
    }

    func start() {
        guard !established, startup == nil else { return }
        startup = Task { try await establishAndSubscribe() }
    }

    func next() async throws -> FileTreeDelta? {
        if cancelled { throw CancellationError() }
        try await ensureEstablished()
        while true {
            do {
                if let pendingEvent {
                    try await acknowledge(pendingEvent)
                    self.pendingEvent = nil
                }
                readInFlight = true
                let envelope: CPFileTreeEnvelope
                do {
                    envelope = try await receive()
                } catch {
                    readInFlight = false
                    throw error
                }
                readInFlight = false

                if cancelled {
                    if try completeCancellationIfMatched(envelope) {
                        throw CancellationError()
                    }
                    continue
                }
                guard let payload = envelope.payload else {
                    throw HostDataPlaneResponseValidationError()
                }
                switch payload {
                case let .deltaEvent(event):
                    guard event.subscriptionID == subscriptionID,
                          envelope.requestID == event.eventID else {
                        throw HostDataPlaneResponseValidationError()
                    }
                    let delta = try HostDataPlaneMessages.decode(event.delta)
                    guard delta.environmentID == binding.environmentID,
                          delta.revision > after else {
                        throw HostDataPlaneResponseValidationError()
                    }
                    after = delta.revision
                    pendingEvent = (event.eventID, delta.revision)
                    return delta
                case let .error(error):
                    if error.code == .treeRevisionUnavailable {
                        try await recover(current: error.expected)
                        continue
                    }
                    throw mapRemote(error, diagnostics: nil)
                default:
                    throw HostDataPlaneResponseValidationError()
                }
            } catch is CancellationError {
                closeConnection()
                throw CancellationError()
            } catch let error as HostDataPlaneClientError where error == .disconnected {
                closeConnection()
                guard !cancelled else { throw CancellationError() }
                try await reconnectAfterDisconnect()
                continue
            } catch {
                closeConnection()
                throw HostDataPlaneClientError.disconnected
            }
        }
    }

    func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        startup?.cancel()
        guard descriptorOwner != nil, let subscriptionID else {
            closeConnection()
            return
        }
        let requestID = RequestID().description
        var request = CPFileTreeCancelRequest()
        request.subscriptionID = subscriptionID
        var envelope = CPFileTreeEnvelope()
        envelope.requestID = requestID
        envelope.binding = try! HostDataPlaneMessages.encode(binding)
        envelope.cancelRequest = request
        if readInFlight {
            await withCheckedContinuation { continuation in
                cancelWaiter = CancelWaiter(
                    requestID: requestID,
                    subscriptionID: subscriptionID,
                    continuation: continuation
                )
                do {
                    try send(envelope)
                } catch {
                    let waiter = cancelWaiter
                    cancelWaiter = nil
                    waiter?.continuation.resume()
                }
            }
        } else {
            do {
                try send(envelope)
                let response = try await receive()
                guard response.requestID == requestID,
                      case let .cancelled(value)? = response.payload,
                      value.subscriptionID == subscriptionID else {
                    throw HostDataPlaneResponseValidationError()
                }
            } catch {}
        }
        closeConnection()
    }

    private func establishAndSubscribe() async throws {
        let context = try RequestContext(validating: .current, clientInstanceID: binding.clientInstanceID, windowID: binding.windowID, workspaceContextID: binding.workspaceContextID, environmentID: binding.environmentID, activeContextGeneration: binding.activeContextGeneration, requestID: RequestID())
        let ticket: CPHostDataPlaneTicketResponse
        do {
            ticket = try await xpcClient.issueHostDataPlaneTicket(context: context)
        } catch {
            throw HostDataPlaneClientError.disconnected
        }
        let fd = try calls.createStreamSocket()
        let owner = HostDataPlaneDescriptorOwner(fd, calls: calls)
        do {
            try calls.setCloseOnExec(fd); try calls.setNoSigPipe(fd); try calls.connect(fd, to: UnixDomainSocketAddress(path: ticket.socketPath))
            try await authenticateTree(
                fd: fd,
                ticket: ticket.ticket,
                binding: binding,
                calls: calls,
                readQueue: readQueue
            )
            descriptorOwner = owner
            lastOutgoing = 0
            lastIncoming = 0
            lastAcknowledged = 0
            subscriptionID = nil
            pendingEvent = nil
            try await subscribe()
        } catch {
            if descriptorOwner === owner { descriptorOwner = nil }
            owner.close()
            throw normalizeConnectionError(error)
        }
    }

    private func ensureEstablished() async throws {
        if established { return }
        if startup == nil { start() }
        do {
            try await startup?.value
            established = true
            startup = nil
        } catch {
            startup = nil
            closeConnection()
            throw normalizeConnectionError(error)
        }
    }

    private func reconnectAfterDisconnect() async throws {
        while !cancelled {
            do {
                try await establishAndSubscribe()
                established = true
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                closeConnection()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        throw CancellationError()
    }

    private func subscribe() async throws {
        var request = CPFileTreeSubscribeRequest(); request.afterRevision = after
        let id = RequestID().description
        var envelope = CPFileTreeEnvelope(); envelope.requestID = id; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.subscribeRequest = request
        try send(envelope)
        let response = try await receive()
        if case let .error(error)? = response.payload {
            throw mapRemote(error, diagnostics: nil)
        }
        guard response.requestID == id,
              case let .subscriptionAccepted(value)? = response.payload,
              value.subscriptionID == id,
              value.revision == after else {
            throw HostDataPlaneResponseValidationError()
        }
        subscriptionID = id
    }

    private func acknowledge(_ event: (id: String, revision: UInt64)) async throws {
        guard let subscriptionID else { throw HostDataPlaneClientError.disconnected }
        var ack = CPFileTreeDeltaAck(); ack.subscriptionID = subscriptionID; ack.eventID = event.id; ack.revision = event.revision
        let requestID = RequestID().description
        var envelope = CPFileTreeEnvelope(); envelope.requestID = requestID; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.deltaAck = ack
        try send(envelope)
        let response = try await receive()
        if case let .error(error)? = response.payload {
            throw mapRemote(error, diagnostics: nil)
        }
        guard response.requestID == requestID,
              case let .ackAccepted(value)? = response.payload,
              value.subscriptionID == subscriptionID,
              value.eventID == event.id,
              value.revision == event.revision else {
            throw HostDataPlaneResponseValidationError()
        }
    }

    private func recover(current: UInt64) async throws {
        var maximum = current
        for directory in expanded {
            var request = CPFileTreeChildrenRequest(); request.directory = try HostDataPlaneMessages.encode(directory)
            let requestID = RequestID().description
            var envelope = CPFileTreeEnvelope(); envelope.requestID = requestID; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.childrenRequest = request
            try send(envelope)
            let response = try await receive()
            if case let .error(error)? = response.payload {
                throw mapRemote(error, diagnostics: nil)
            }
            guard response.requestID == requestID,
                  case let .snapshotResult(value)? = response.payload else {
                throw HostDataPlaneResponseValidationError()
            }
            let snapshot = try HostDataPlaneMessages.decode(value)
            guard snapshot.environmentID == binding.environmentID,
                  snapshot.generation == binding.activeContextGeneration,
                  snapshot.directory == directory else {
                throw HostDataPlaneResponseValidationError()
            }
            maximum = max(maximum, snapshot.revision)
        }
        after = maximum; try await subscribe()
    }

    private func send(_ envelope: CPFileTreeEnvelope) throws {
        guard let descriptor = descriptorOwner?.descriptor,
              case let .value(sequence) = hostDataPlaneAdvanceSequence(lastOutgoing) else {
            throw HostDataPlaneClientError.disconnected
        }
        do {
            try writeFrame(
                calls,
                descriptor,
                channel: .fileTreeEvents,
                sequence: sequence,
                acknowledgement: lastIncoming,
                payload: envelope.serializedData()
            )
            lastOutgoing = sequence
        } catch {
            throw normalizeConnectionError(error)
        }
    }

    private func receive() async throws -> CPFileTreeEnvelope {
        guard let descriptor = descriptorOwner?.descriptor else {
            throw HostDataPlaneClientError.disconnected
        }
        let frame: Frame
        do {
            frame = try await readFrameAsync(calls, descriptor, queue: readQueue)
        } catch {
            throw normalizeConnectionError(error)
        }
        guard case let .value(expectedSequence) = hostDataPlaneAdvanceSequence(lastIncoming),
              frame.header.channel == .fileTreeEvents,
              frame.header.sequence == expectedSequence,
              frame.header.acknowledgement >= lastAcknowledged,
              frame.header.acknowledgement <= lastOutgoing,
              case let .fileTree(envelope) = try HostDataPlaneMessages.decodeEnvelope(frame),
              try HostDataPlaneMessages.decode(envelope.binding) == binding else {
            throw HostDataPlaneResponseValidationError()
        }
        self.lastIncoming = frame.header.sequence
        self.lastAcknowledged = frame.header.acknowledgement
        return envelope
    }

    private func completeCancellationIfMatched(_ envelope: CPFileTreeEnvelope) throws -> Bool {
        guard let waiter = cancelWaiter else { return false }
        guard envelope.requestID == waiter.requestID,
              case let .cancelled(value)? = envelope.payload,
              value.subscriptionID == waiter.subscriptionID else {
            if case .deltaEvent? = envelope.payload { return false }
            throw HostDataPlaneResponseValidationError()
        }
        cancelWaiter = nil
        waiter.continuation.resume()
        return true
    }

    private func closeConnection() {
        let owner = descriptorOwner
        descriptorOwner = nil
        owner?.close()
        established = false
        startup = nil
        subscriptionID = nil
        pendingEvent = nil
        if let waiter = cancelWaiter {
            cancelWaiter = nil
            waiter.continuation.resume()
        }
    }
}

private func authenticateTree(
    fd: Int32,
    ticket: String,
    binding: HostDataPlaneBinding,
    calls: any UnixDomainSocketSystemCalls,
    readQueue: DispatchQueue
) async throws {
    var handshake = CPHostDataPlaneControlEnvelope(); handshake.handshakeRequest = .cockpit(deviceID: DeviceID(), features: [.hostDataPlane])
    try writeFrame(calls, fd, channel: .control, sequence: 1, acknowledgement: 0, payload: handshake.serializedData())
    let handshakeResponse = try await readFrameAsync(calls, fd, queue: readQueue)
    guard handshakeResponse.header.channel == .control,
          handshakeResponse.header.sequence == 1,
          handshakeResponse.header.acknowledgement == 1
    else { throw HostDataPlaneClientError.disconnected }
    _ = try HostDataPlaneMessages.decodeHandshakeResponse(handshakeResponse.payload)
    var auth = CPHostDataPlaneAuthenticate(); auth.ticket = ticket; auth.binding = try HostDataPlaneMessages.encode(binding)
    var envelope = CPHostDataPlaneControlEnvelope(); envelope.authenticate = auth
    try writeFrame(calls, fd, channel: .control, sequence: 2, acknowledgement: 1, payload: envelope.serializedData())
    let response = try await readFrameAsync(calls, fd, queue: readQueue)
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

private func mapRemote(
    _ value: CPDataPlaneError,
    diagnostics: HostDataPlaneDiagnostics?,
    expectation: HostDataPlaneDocumentExpectation
) -> HostDataPlaneRemoteMapping {
    if value.code == .documentRecoveryRequired {
        guard value.hasCommittedAcknowledgement,
              let acknowledgement = try? HostDataPlaneMessages.decode(
                value.committedAcknowledgement
              ),
              expectation.matchesCommittedAcknowledgement(acknowledgement) else {
            return .protocolViolation
        }
        diagnostics?.yield(.committedRecoveryRequired(acknowledgement))
        return .application(DocumentProtocolError.recoveryRequired)
    }
    return .application(mapRemote(value, diagnostics: diagnostics))
}

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
