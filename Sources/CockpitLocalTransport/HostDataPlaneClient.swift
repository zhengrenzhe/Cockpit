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

private final class HostDataPlaneClientBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private var owner: HostDataPlaneDescriptorOwner?
    private var cancelled = false

    func install(_ owner: HostDataPlaneDescriptorOwner) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.owner = owner
            return true
        }
    }

    func finish(_ owner: HostDataPlaneDescriptorOwner) {
        lock.withLock {
            if self.owner === owner { self.owner = nil }
        }
    }

    func cancel() {
        let owner = lock.withLock { () -> HostDataPlaneDescriptorOwner? in
            cancelled = true
            return self.owner
        }
        owner?.interrupt()
    }
}

public actor HostDataPlaneClient: DocumentDataTransport, FileTreeDataTransport {
    private struct ConnectionAttempt: Sendable {
        let id: UUID
        let bootstrap: HostDataPlaneClientBootstrap
        let task: Task<HostDataPlaneClientConnection, Error>
        var waiters: [UUID: CheckedContinuation<Void, any Error>]
    }

    private let binding: HostDataPlaneBinding
    private let xpcClient: HostXPCClient
    private let systemCalls: any UnixDomainSocketSystemCalls
    private let diagnostics = HostDataPlaneDiagnostics()
    private let bootstrapReadQueue = DispatchQueue(
        label: "dev.cockpit.host-data-plane.client-bootstrap-read"
    )
    private var connection: HostDataPlaneClientConnection?
    private var connectionAttempt: ConnectionAttempt?

    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient, systemCalls: any UnixDomainSocketSystemCalls) {
        self.binding = binding; self.xpcClient = xpcClient; self.systemCalls = systemCalls
    }

    public init(binding: HostDataPlaneBinding, xpcClient: HostXPCClient) {
        self.init(binding: binding, xpcClient: xpcClient, systemCalls: DarwinUnixDomainSocketSystemCalls())
    }

    public func connect() async throws {
        guard !Task.isCancelled else {
            throw HostDataPlaneClientError.requestCancelled
        }
        if let connection, !connection.isClosed { return }
        connection = nil
        let attemptID = try connectionAttempt?.id ?? startConnectionAttempt()
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerConnectionWaiter(
                    attemptID: attemptID,
                    waiterID: waiterID,
                    alreadyCancelled: withUnsafeCurrentTask { $0?.isCancelled == true },
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancelConnectionWaiter(
                    attemptID: attemptID,
                    waiterID: waiterID
                )
            }
        }
        guard !Task.isCancelled else {
            throw HostDataPlaneClientError.requestCancelled
        }
    }

    private func startConnectionAttempt() throws -> UUID {
        let context = try requestContext()
        let bootstrap = HostDataPlaneClientBootstrap()
        let id = UUID()
        let binding = self.binding
        let xpcClient = self.xpcClient
        let systemCalls = self.systemCalls
        let bootstrapReadQueue = self.bootstrapReadQueue
        let task = Task {
            let ticket: CPHostDataPlaneTicketResponse
            do {
                ticket = try await xpcClient.issueHostDataPlaneTicket(context: context)
            } catch {
                throw HostDataPlaneClientError.disconnected
            }
            try Task.checkCancellation()
            let fd = try systemCalls.createStreamSocket()
            let owner = HostDataPlaneDescriptorOwner(fd, calls: systemCalls)
            guard bootstrap.install(owner) else {
                owner.close()
                throw HostDataPlaneClientError.disconnected
            }
            do {
                try owner.withDescriptor { descriptor in
                    try systemCalls.setCloseOnExec(descriptor)
                    try systemCalls.setNoSigPipe(descriptor)
                    try systemCalls.connect(
                        descriptor,
                        to: UnixDomainSocketAddress(path: ticket.socketPath)
                    )
                }
                try await authenticateHostDataPlaneClient(
                    descriptorOwner: owner,
                    ticket: ticket.ticket,
                    binding: binding,
                    systemCalls: systemCalls,
                    readQueue: bootstrapReadQueue
                )
                try Task.checkCancellation()
                bootstrap.finish(owner)
                return HostDataPlaneClientConnection(
                    descriptorOwner: owner,
                    systemCalls: systemCalls,
                    binding: binding
                )
            } catch {
                bootstrap.finish(owner)
                owner.interrupt()
                owner.close()
                throw normalizeConnectionError(error)
            }
        }
        connectionAttempt = ConnectionAttempt(
            id: id,
            bootstrap: bootstrap,
            task: task,
            waiters: [:]
        )
        Task { [task] in
            await completeConnectionAttempt(id: id, result: await task.result)
        }
        return id
    }

    private func registerConnectionWaiter(
        attemptID: UUID,
        waiterID: UUID,
        alreadyCancelled: Bool,
        continuation: CheckedContinuation<Void, any Error>
    ) {
        guard var attempt = connectionAttempt, attempt.id == attemptID else {
            if let connection, !connection.isClosed, !alreadyCancelled {
                continuation.resume()
            } else {
                continuation.resume(
                    throwing: alreadyCancelled
                        ? HostDataPlaneClientError.requestCancelled
                        : HostDataPlaneClientError.disconnected
                )
            }
            return
        }
        guard !alreadyCancelled else {
            continuation.resume(throwing: HostDataPlaneClientError.requestCancelled)
            if attempt.waiters.isEmpty {
                connectionAttempt = nil
                attempt.bootstrap.cancel()
                attempt.task.cancel()
            }
            return
        }
        attempt.waiters[waiterID] = continuation
        connectionAttempt = attempt
    }

    private func cancelConnectionWaiter(attemptID: UUID, waiterID: UUID) {
        guard var attempt = connectionAttempt,
              attempt.id == attemptID,
              let continuation = attempt.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: HostDataPlaneClientError.requestCancelled)
        if attempt.waiters.isEmpty {
            connectionAttempt = nil
            attempt.bootstrap.cancel()
            attempt.task.cancel()
        } else {
            connectionAttempt = attempt
        }
    }

    private func completeConnectionAttempt(
        id: UUID,
        result: Result<HostDataPlaneClientConnection, any Error>
    ) async {
        guard let attempt = connectionAttempt, attempt.id == id else {
            if case let .success(established) = result {
                await established.shutdown()
            }
            return
        }
        connectionAttempt = nil
        switch result {
        case let .success(established):
            if connection == nil || connection?.isClosed == true {
                connection = established
                established.start()
            } else if connection !== established {
                await established.shutdown()
            }
            for continuation in attempt.waiters.values {
                continuation.resume()
            }
        case let .failure(error):
            for continuation in attempt.waiters.values {
                continuation.resume(throwing: normalizeConnectionError(error))
            }
        }
    }

    public func disconnect() async {
        let attempt = connectionAttempt
        connectionAttempt = nil
        let waiters = attempt.map { Array($0.waiters.values) } ?? []
        for continuation in waiters {
            continuation.resume(throwing: HostDataPlaneClientError.disconnected)
        }
        attempt?.bootstrap.cancel()
        attempt?.task.cancel()
        let current = connection
        connection = nil
        if let attempt, let established = try? await attempt.task.value {
            await established.shutdown()
        }
        await current?.shutdown()
    }

    public func closeDocument(documentID: DocumentID) async {
        await disconnect()
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

    public func retainViewer(documentID: DocumentID) async throws {
        var request = CPDocumentViewerRetainRequest()
        request.documentID = documentID.description
        _ = try await document(
            .retainViewerRequest(request),
            expectation: .viewer(documentID)
        ) { payload in
            guard case let .viewerResult(value) = payload else {
                throw DocumentProtocolError.invalidValue
            }
            return value.documentID
        }
    }

    public func releaseViewer(documentID: DocumentID) async {
        do {
            var request = CPDocumentViewerReleaseRequest()
            request.documentID = documentID.description
            _ = try await document(
                .releaseViewerRequest(request),
                expectation: .viewer(documentID)
            ) { payload in
                guard case let .viewerResult(value) = payload else {
                    throw DocumentProtocolError.invalidValue
                }
                return value.documentID
            }
        } catch {
            await disconnect()
        }
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

    private func requestContext() throws -> RequestContext {
        try RequestContext(validating: .current, clientInstanceID: binding.clientInstanceID, windowID: binding.windowID, workspaceContextID: binding.workspaceContextID, environmentID: binding.environmentID, activeContextGeneration: binding.activeContextGeneration, requestID: RequestID())
    }
}

private struct HostDataPlaneResponseValidationError: Error {}
private struct HostDataPlaneOutgoingSequenceOverflowError: Error {}

struct HostDataPlaneTreeOwnerPublicationState: Sendable {
    private(set) var cancelled = false

    mutating func cancel() {
        cancelled = true
    }

    mutating func publish(_ owner: HostDataPlaneDescriptorOwner) -> Bool {
        guard !cancelled else {
            owner.close()
            return false
        }
        return true
    }
}

enum HostDataPlaneUnaryRegistrationDisposition: Equatable {
    case register
    case cancelAndRetire
    case requestIDReuse
}

struct HostDataPlaneUnaryCancellationState<Key: Hashable & Sendable>: Sendable {
    private var cancelledBeforeRegistration: Set<Key> = []
    private var retiredRequestIDs: Set<String> = []

    mutating func recordBeforeRegistration(_ key: Key, requestIDWasUsed: Bool) -> Bool {
        guard !requestIDWasUsed else { return false }
        return cancelledBeforeRegistration.insert(key).inserted
    }

    mutating func consumeBeforeRegistration(_ key: Key) -> Bool {
        cancelledBeforeRegistration.remove(key) != nil
    }

    mutating func registrationDisposition(
        for key: Key,
        requestID: String,
        alreadyCancelled: Bool
    ) -> HostDataPlaneUnaryRegistrationDisposition {
        if alreadyCancelled {
            _ = cancelledBeforeRegistration.remove(key)
            guard retiredRequestIDs.insert(requestID).inserted else {
                return .requestIDReuse
            }
            return .cancelAndRetire
        }
        if consumeBeforeRegistration(key) {
            _ = retiredRequestIDs.insert(requestID)
            return .cancelAndRetire
        }
        guard retiredRequestIDs.insert(requestID).inserted else {
            return .requestIDReuse
        }
        return .register
    }

    func requestIDWasRetired(_ requestID: String) -> Bool {
        retiredRequestIDs.contains(requestID)
    }

    mutating func removeAll() {
        cancelledBeforeRegistration.removeAll()
        retiredRequestIDs.removeAll()
    }
}

private enum HostDataPlaneDocumentExpectation {
    case opened(environmentID: EnvironmentID, path: RelativePath)
    case snapshot(DocumentID)
    case lease(documentID: DocumentID, client: ClientInstanceID)
    case acknowledgement(documentID: DocumentID, clientSequence: UInt64)
    case flush
    case viewer(DocumentID)

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
        case let .viewer(documentID):
            guard case let .viewerResult(value) = payload,
                  value.documentID == documentID.description else {
                throw HostDataPlaneResponseValidationError()
            }
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

struct HostDataPlaneClientSequenceState: Sendable {
    enum Reservation: Equatable {
        case value(sequence: UInt64, acknowledgement: UInt64)
        case overflow
    }

    private(set) var lastIncoming: [UInt32: UInt64]
    private(set) var lastAcknowledged: [UInt32: UInt64]
    private(set) var lastOutgoing: [UInt32: UInt64]

    init(
        lastIncoming: [UInt32: UInt64] = [:],
        lastAcknowledged: [UInt32: UInt64] = [:],
        lastOutgoing: [UInt32: UInt64] = [:]
    ) {
        self.lastIncoming = lastIncoming
        self.lastAcknowledged = lastAcknowledged
        self.lastOutgoing = lastOutgoing
    }

    mutating func reserveOutgoing(channel: UInt32) -> Reservation {
        guard case let .value(sequence) = hostDataPlaneAdvanceSequence(
            lastOutgoing[channel] ?? 0
        ) else {
            return .overflow
        }
        lastOutgoing[channel] = sequence
        return .value(sequence: sequence, acknowledgement: lastIncoming[channel] ?? 0)
    }

    mutating func acceptResponse(_ frame: Frame, minimumAcknowledgement: UInt64) -> Bool {
        let channel = frame.header.channel.rawValue
        guard case let .value(expectedSequence) = hostDataPlaneAdvanceSequence(
            lastIncoming[channel] ?? 0
        ),
        frame.header.sequence == expectedSequence,
        frame.header.acknowledgement >= minimumAcknowledgement,
        frame.header.acknowledgement >= (lastAcknowledged[channel] ?? 0),
        frame.header.acknowledgement <= (lastOutgoing[channel] ?? 0) else {
            return false
        }
        lastIncoming[channel] = frame.header.sequence
        lastAcknowledged[channel] = frame.header.acknowledgement
        return true
    }
}

final class HostDataPlaneClientConnection: @unchecked Sendable {
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
    private var cancellationState = HostDataPlaneUnaryCancellationState<PendingKey>()
    private var sequences: HostDataPlaneClientSequenceState

    init(
        descriptorOwner: HostDataPlaneDescriptorOwner,
        systemCalls: any UnixDomainSocketSystemCalls,
        binding: HostDataPlaneBinding,
        sequences: HostDataPlaneClientSequenceState = .init()
    ) {
        self.descriptorOwner = descriptorOwner
        calls = systemCalls
        self.binding = binding
        self.sequences = sequences
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
        var registered = false
        var preRegistrationCancellation = false
        do {
            try writeLock.withLock {
                let state = try lock.withLock { () -> (UInt64, UInt64)? in
                    guard !closed else {
                        throw HostDataPlaneClientError.disconnected
                    }
                    switch cancellationState.registrationDisposition(
                        for: key,
                        requestID: key.requestID,
                        alreadyCancelled: cancelled
                    ) {
                    case .cancelAndRetire:
                        return nil
                    case .requestIDReuse:
                        throw HostDataPlaneClientError.disconnected
                    case .register:
                        break
                    }
                    guard case let .value(sequence, acknowledgement) = sequences.reserveOutgoing(
                        channel: channel.rawValue
                    ) else {
                        throw HostDataPlaneOutgoingSequenceOverflowError()
                    }
                    pending[key] = PendingRequest(
                        outgoingSequence: sequence,
                        continuation: continuation
                    )
                    registered = true
                    return (sequence, acknowledgement)
                }
                guard let state else {
                    preRegistrationCancellation = true
                    return
                }
                try descriptorOwner.withDescriptor { descriptor in
                    try writeFrame(
                        calls,
                        descriptor,
                        channel: channel,
                        sequence: state.0,
                        acknowledgement: state.1,
                        payload: payload
                    )
                }
            }
            if preRegistrationCancellation {
                continuation.resume(throwing: HostDataPlaneClientError.requestCancelled)
            }
        } catch {
            if error is HostDataPlaneOutgoingSequenceOverflowError {
                failConnection()
                continuation.resume(throwing: HostDataPlaneClientError.disconnected)
            } else if registered {
                failConnection()
            } else {
                continuation.resume(throwing: HostDataPlaneClientError.disconnected)
            }
        }
    }

    private func cancel(_ key: PendingKey) {
        let continuation = lock.withLock { () -> CheckedContinuation<Frame, any Error>? in
            guard !closed else { return nil }
            guard var request = pending[key] else {
                _ = cancellationState.recordBeforeRegistration(
                    key,
                    requestIDWasUsed: cancellationState.requestIDWasRetired(key.requestID)
                )
                return nil
            }
            guard let continuation = request.continuation else { return nil }
            request.continuation = nil
            pending[key] = request
            return continuation
        }
        continuation?.resume(throwing: HostDataPlaneClientError.requestCancelled)
    }

    private func readLoop() {
        do {
            while true {
                try dispatch(try descriptorOwner.withDescriptor { descriptor in
                    try readFrame(calls, descriptor)
                })
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
                  sequences.acceptResponse(
                    frame,
                    minimumAcknowledgement: request.outgoingSequence
                  ) else {
                throw HostDataPlaneResponseValidationError()
            }
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
            cancellationState.removeAll()
            return continuations
        }
        descriptorOwner.interrupt()
        descriptorOwner.close()
        for continuation in continuations {
            continuation.resume(throwing: HostDataPlaneClientError.disconnected)
        }
    }
}

private func authenticateHostDataPlaneClient(
    descriptorOwner: HostDataPlaneDescriptorOwner,
    ticket: String,
    binding: HostDataPlaneBinding,
    systemCalls: any UnixDomainSocketSystemCalls,
    readQueue: DispatchQueue
) async throws {
    var handshake = CPHostDataPlaneControlEnvelope()
    handshake.handshakeRequest = .cockpit(deviceID: DeviceID(), features: [.hostDataPlane])
    try descriptorOwner.withDescriptor { descriptor in
        try writeFrame(
            systemCalls,
            descriptor,
            channel: .control,
            sequence: 1,
            acknowledgement: 0,
            payload: handshake.serializedData()
        )
    }
    let handshakeResponse = try await readFrameAsync(systemCalls, descriptorOwner, queue: readQueue)
    guard handshakeResponse.header.channel == .control,
          handshakeResponse.header.sequence == 1,
          handshakeResponse.header.acknowledgement == 1 else {
        throw HostDataPlaneClientError.disconnected
    }
    _ = try HostDataPlaneMessages.decodeHandshakeResponse(handshakeResponse.payload)
    var auth = CPHostDataPlaneAuthenticate()
    auth.ticket = ticket
    auth.binding = try HostDataPlaneMessages.encode(binding)
    var envelope = CPHostDataPlaneControlEnvelope()
    envelope.authenticate = auth
    try descriptorOwner.withDescriptor { descriptor in
        try writeFrame(
            systemCalls,
            descriptor,
            channel: .control,
            sequence: 2,
            acknowledgement: 1,
            payload: envelope.serializedData()
        )
    }
    let response = try await readFrameAsync(systemCalls, descriptorOwner, queue: readQueue)
    guard response.header.channel == .control,
          response.header.sequence == 2,
          response.header.acknowledgement == 2 else {
        throw HostDataPlaneClientError.disconnected
    }
    let decoded = try HostDataPlaneMessages.decodeControlEnvelope(response.payload)
    switch decoded.payload {
    case let .authenticated(value)?:
        guard try HostDataPlaneMessages.decode(value.binding) == binding else {
            throw HostDataPlaneClientError.disconnected
        }
    case let .error(error)?:
        throw mapRemote(error, diagnostics: nil)
    default:
        throw HostDataPlaneClientError.disconnected
    }
}

actor HostDataPlaneTreeStream {
    private struct CancelWaiter {
        let requestID: String
        let subscriptionID: String
        var continuation: CheckedContinuation<Void, Never>?
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
    private var connectionWorker: Task<Void, Error>?
    private var established = false
    private var cancelled = false
    private var cancelWaiter: CancelWaiter?
    private var ownerPublication = HostDataPlaneTreeOwnerPublicationState()
    private var readerActive = false

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
        try checkActive()
        while true {
            do {
                if let pendingEvent {
                    try await acknowledge(pendingEvent)
                    self.pendingEvent = nil
                }
                let envelope = try await receiveWhileActive()
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
        ownerPublication.cancel()
        startup?.cancel()
        guard descriptorOwner != nil, let subscriptionID else {
            connectionWorker?.cancel()
            descriptorOwner?.interrupt()
            if let connectionWorker {
                _ = await connectionWorker.result
                self.connectionWorker = nil
            }
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
        cancelWaiter = CancelWaiter(
            requestID: requestID,
            subscriptionID: subscriptionID,
            continuation: nil
        )
        do {
            try send(envelope, allowingCancellation: true)
        } catch {
            abandonCancellationWaiter()
            closeConnection()
            return
        }
        if readerActive {
            await withCheckedContinuation { continuation in
                guard var waiter = cancelWaiter else {
                    continuation.resume()
                    return
                }
                waiter.continuation = continuation
                cancelWaiter = waiter
            }
        } else {
            do {
                while cancelWaiter != nil {
                    let response = try await receiveWhileActive()
                    _ = try completeCancellationIfMatched(response)
                }
            } catch {
                abandonCancellationWaiter()
            }
        }
        closeConnection()
    }

    private func establishAndSubscribe() async throws {
        let context = try RequestContext(validating: .current, clientInstanceID: binding.clientInstanceID, windowID: binding.windowID, workspaceContextID: binding.workspaceContextID, environmentID: binding.environmentID, activeContextGeneration: binding.activeContextGeneration, requestID: RequestID())
        let ticket: CPHostDataPlaneTicketResponse
        do {
            ticket = try await xpcClient.issueHostDataPlaneTicket(context: context)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HostDataPlaneClientError.disconnected
        }
        try checkActive()
        let fd = try calls.createStreamSocket()
        let owner = HostDataPlaneDescriptorOwner(fd, calls: calls)
        guard ownerPublication.publish(owner) else {
            throw CancellationError()
        }
        descriptorOwner = owner
        do {
            let calls = calls
            let binding = binding
            let readQueue = readQueue
            let worker = Task.detached {
                try owner.withDescriptor { descriptor in
                    try calls.setCloseOnExec(descriptor)
                    try calls.setNoSigPipe(descriptor)
                    try calls.connect(
                        descriptor,
                        to: UnixDomainSocketAddress(path: ticket.socketPath)
                    )
                }
                try Task.checkCancellation()
                try await authenticateTree(
                    descriptorOwner: owner,
                    ticket: ticket.ticket,
                    binding: binding,
                    calls: calls,
                    readQueue: readQueue
                )
            }
            connectionWorker = worker
            try await worker.value
            connectionWorker = nil
            try checkActive()
            lastOutgoing = 0
            lastIncoming = 0
            lastAcknowledged = 0
            subscriptionID = nil
            pendingEvent = nil
            try await subscribe()
        } catch {
            connectionWorker = nil
            if descriptorOwner === owner { descriptorOwner = nil }
            owner.interrupt()
            owner.close()
            if cancelled || Task.isCancelled || error is CancellationError {
                throw CancellationError()
            }
            throw normalizeConnectionError(error)
        }
    }

    private func ensureEstablished() async throws {
        if established { return }
        if startup == nil { start() }
        do {
            try await startup?.value
            try checkActive()
            established = true
            startup = nil
        } catch is CancellationError {
            startup = nil
            closeConnection()
            throw CancellationError()
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
                try checkActive()
                established = true
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                closeConnection()
                try await Task.sleep(for: .milliseconds(10))
                try checkActive()
            }
        }
        throw CancellationError()
    }

    private func subscribe() async throws {
        var request = CPFileTreeSubscribeRequest(); request.afterRevision = after
        let id = RequestID().description
        var envelope = CPFileTreeEnvelope(); envelope.requestID = id; envelope.binding = try HostDataPlaneMessages.encode(binding); envelope.subscribeRequest = request
        try send(envelope)
        let response = try await receiveWhileActive()
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
        let response = try await receiveWhileActive()
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
            let response = try await receiveWhileActive()
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

    private func send(
        _ envelope: CPFileTreeEnvelope,
        allowingCancellation: Bool = false
    ) throws {
        guard allowingCancellation || !cancelled else {
            throw CancellationError()
        }
        guard let descriptorOwner,
              case let .value(sequence) = hostDataPlaneAdvanceSequence(lastOutgoing) else {
            throw HostDataPlaneClientError.disconnected
        }
        do {
            try descriptorOwner.withDescriptor { descriptor in
                try writeFrame(
                    calls,
                    descriptor,
                    channel: .fileTreeEvents,
                    sequence: sequence,
                    acknowledgement: lastIncoming,
                    payload: envelope.serializedData()
                )
            }
            lastOutgoing = sequence
        } catch {
            throw normalizeConnectionError(error)
        }
    }

    private func receive() async throws -> CPFileTreeEnvelope {
        guard let descriptorOwner else {
            throw HostDataPlaneClientError.disconnected
        }
        guard !readerActive else {
            throw HostDataPlaneResponseValidationError()
        }
        readerActive = true
        defer { readerActive = false }
        let frame: Frame
        do {
            frame = try await readFrameAsync(calls, descriptorOwner, queue: readQueue)
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

    private func receiveWhileActive() async throws -> CPFileTreeEnvelope {
        while true {
            let envelope = try await receive()
            if cancelled {
                if try completeCancellationIfMatched(envelope) {
                    throw CancellationError()
                }
                continue
            }
            try Task.checkCancellation()
            return envelope
        }
    }

    private func completeCancellationIfMatched(_ envelope: CPFileTreeEnvelope) throws -> Bool {
        guard let waiter = cancelWaiter else { return false }
        guard envelope.requestID == waiter.requestID else { return false }
        guard case let .cancelled(value)? = envelope.payload,
              value.subscriptionID == waiter.subscriptionID else {
            throw HostDataPlaneResponseValidationError()
        }
        cancelWaiter = nil
        waiter.continuation?.resume()
        return true
    }

    private func abandonCancellationWaiter() {
        let waiter = cancelWaiter
        cancelWaiter = nil
        waiter?.continuation?.resume()
    }

    private func closeConnection() {
        let owner = descriptorOwner
        descriptorOwner = nil
        owner?.interrupt()
        owner?.close()
        established = false
        startup = nil
        subscriptionID = nil
        pendingEvent = nil
        abandonCancellationWaiter()
    }

    private func checkActive() throws {
        guard !cancelled else { throw CancellationError() }
        try Task.checkCancellation()
    }
}

private func authenticateTree(
    descriptorOwner: HostDataPlaneDescriptorOwner,
    ticket: String,
    binding: HostDataPlaneBinding,
    calls: any UnixDomainSocketSystemCalls,
    readQueue: DispatchQueue
) async throws {
    try Task.checkCancellation()
    var handshake = CPHostDataPlaneControlEnvelope(); handshake.handshakeRequest = .cockpit(deviceID: DeviceID(), features: [.hostDataPlane])
    try descriptorOwner.withDescriptor { descriptor in
        try writeFrame(calls, descriptor, channel: .control, sequence: 1, acknowledgement: 0, payload: handshake.serializedData())
    }
    let handshakeResponse = try await readFrameAsync(calls, descriptorOwner, queue: readQueue)
    try Task.checkCancellation()
    guard handshakeResponse.header.channel == .control,
          handshakeResponse.header.sequence == 1,
          handshakeResponse.header.acknowledgement == 1
    else { throw HostDataPlaneClientError.disconnected }
    _ = try HostDataPlaneMessages.decodeHandshakeResponse(handshakeResponse.payload)
    var auth = CPHostDataPlaneAuthenticate(); auth.ticket = ticket; auth.binding = try HostDataPlaneMessages.encode(binding)
    var envelope = CPHostDataPlaneControlEnvelope(); envelope.authenticate = auth
    try descriptorOwner.withDescriptor { descriptor in
        try writeFrame(calls, descriptor, channel: .control, sequence: 2, acknowledgement: 1, payload: envelope.serializedData())
    }
    let response = try await readFrameAsync(calls, descriptorOwner, queue: readQueue)
    try Task.checkCancellation()
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
