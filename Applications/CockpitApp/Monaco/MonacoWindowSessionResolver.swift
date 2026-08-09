import Foundation
import CockpitClientCore
import CockpitProtocol
import CockpitTypes

public typealias MonacoViewStateLoader = @Sendable (
    WorkspaceContextID,
    TabID,
    DocumentID
) async -> DocumentViewState?

public typealias MonacoViewStateStorer = @Sendable (
    WorkspaceContextID,
    TabID,
    DocumentID,
    DocumentViewState
) async throws -> Void

typealias MonacoReferenceLifecycle = @MainActor @Sendable (
    MonacoWindowSession,
    MonacoDocumentReference
) async throws -> Void

@MainActor
final class MonacoLifecycleGate {
    private enum Waiter {
        case ordinary(CheckedContinuation<Void, Never>)
        case cancellable(UUID, CheckedContinuation<Void, any Error>)

        var cancellationID: UUID? {
            guard case let .cancellable(id, _) = self else { return nil }
            return id
        }

        func resume() {
            switch self {
            case let .ordinary(continuation):
                continuation.resume()
            case let .cancellable(_, continuation):
                continuation.resume()
            }
        }

        func cancel() {
            guard case let .cancellable(_, continuation) = self else { return }
            continuation.resume(throwing: CancellationError())
        }
    }

    private var occupied = false
    private var waiters: [Waiter] = []

    var isOccupied: Bool { occupied }

    func perform<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async rethrows -> Value {
        await acquire()
        defer { release() }
        return try await operation()
    }

    func performCancellable<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try await acquireCancellable()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append(.ordinary($0)) }
    }

    private func acquireCancellable() async throws {
        try Task.checkCancellation()
        if !occupied {
            occupied = true
            return
        }
        let cancellationID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(.cancellable(cancellationID, continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(cancellationID)
            }
        }
    }

    private func cancelWaiter(_ cancellationID: UUID) {
        guard let index = waiters.firstIndex(where: {
            $0.cancellationID == cancellationID
        }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.cancel()
    }

    private func release() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        let waiter = waiters.removeFirst()
        waiter.resume()
    }
}

@MainActor
public final class MonacoWindowSession {
    public let documentID: DocumentID
    public let controller: DocumentClientController
    public private(set) var language: String
    public private(set) var references: [MonacoDocumentReference]
    private(set) var revision: UInt64 = 0
    private(set) var lastAuthoritativeEnvironmentID: EnvironmentID?
    private(set) var lastAuthoritativePath: RelativePath?

    init(
        documentID: DocumentID,
        controller: DocumentClientController,
        language: String,
        references: [MonacoDocumentReference],
        authoritativeSnapshot: DocumentSnapshot?
    ) {
        self.documentID = documentID
        self.controller = controller
        self.language = language
        self.references = references
        lastAuthoritativeEnvironmentID = authoritativeSnapshot?.environmentID
        lastAuthoritativePath = authoritativeSnapshot?.relativePath
    }

    func add(reference: MonacoDocumentReference) {
        guard !references.contains(reference) else { return }
        references.append(reference)
        references.sort(by: Self.referenceLess)
        revision &+= 1
    }

    func remove(reference: MonacoDocumentReference) {
        let originalCount = references.count
        references.removeAll { $0 == reference }
        if references.count != originalCount { revision &+= 1 }
    }

    func remember(_ snapshot: DocumentSnapshot) {
        guard snapshot.documentID == documentID else { return }
        lastAuthoritativeEnvironmentID = snapshot.environmentID
        lastAuthoritativePath = snapshot.relativePath
    }

    private static func referenceLess(
        _ left: MonacoDocumentReference,
        _ right: MonacoDocumentReference
    ) -> Bool {
        let leftContext = contextSortKey(left.workspaceContextID)
        let rightContext = contextSortKey(right.workspaceContextID)
        if leftContext != rightContext { return leftContext < rightContext }
        return left.tabID.description < right.tabID.description
    }
}

@MainActor
public final class MonacoWindowSessionResolver {
    public let clientInstanceID: ClientInstanceID
    let loadViewState: MonacoViewStateLoader
    let storeViewState: MonacoViewStateStorer
    private var sessions: [DocumentID: MonacoWindowSession] = [:]
    private var selection: MonacoDocumentReference?
    private var retainLifecycle: MonacoReferenceLifecycle = { _, _ in }
    private var releaseLifecycle: MonacoReferenceLifecycle = { _, _ in }
    private let lifecycleGate = MonacoLifecycleGate()

    public init(
        clientInstanceID: ClientInstanceID,
        loadViewState: @escaping MonacoViewStateLoader,
        storeViewState: @escaping MonacoViewStateStorer
    ) {
        self.clientInstanceID = clientInstanceID
        self.loadViewState = loadViewState
        self.storeViewState = storeViewState
    }

    func setReferenceLifecycle(
        retain: @escaping MonacoReferenceLifecycle,
        release: @escaping MonacoReferenceLifecycle
    ) {
        retainLifecycle = retain
        releaseLifecycle = release
    }

    public func retain(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID,
        controller: DocumentClientController,
        language: String
    ) async throws {
        try await lifecycleGate.perform {
            try await self.retainInsideLifecycleGate(
                contextID: contextID,
                tabID: tabID,
                documentID: documentID,
                controller: controller,
                language: language
            )
        }
    }

    private func retainInsideLifecycleGate(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID,
        controller: DocumentClientController,
        language: String
    ) async throws {
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        let authoritativeSnapshot = Self.authoritativeSnapshot(from: await controller.state)
        if let session = sessions[documentID] {
            guard session.controller === controller, session.language == language else {
                throw MonacoBridgeError.staleDocumentState
            }
            guard !session.references.contains(reference) else { return }
            let revision = session.revision
            if let authoritativeSnapshot { session.remember(authoritativeSnapshot) }
            try await retainLifecycle(session, reference)
            guard sessions[documentID] === session, session.revision == revision else {
                throw MonacoBridgeError.staleDocumentState
            }
            session.add(reference: reference)
            return
        }
        let session = MonacoWindowSession(
            documentID: documentID,
            controller: controller,
            language: language,
            references: [reference],
            authoritativeSnapshot: authoritativeSnapshot
        )
        try await retainLifecycle(session, reference)
        guard sessions[documentID] == nil else { throw MonacoBridgeError.staleDocumentState }
        sessions[documentID] = session
    }

    public func session(documentID: DocumentID) -> MonacoWindowSession? { sessions[documentID] }

    public func select(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) throws {
        guard !lifecycleGate.isOccupied else { throw MonacoBridgeError.resynchronizing }
        let reservation = try selectionReservation(
            contextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        try commitSelection(reservation)
    }

    public func release(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) async throws {
        try await lifecycleGate.perform {
            try await self.releaseInsideLifecycleGate(
                contextID: contextID,
                tabID: tabID,
                documentID: documentID
            )
        }
    }

    private func releaseInsideLifecycleGate(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) async throws {
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        guard let session = sessions[documentID], session.references.contains(reference) else {
            throw MonacoBridgeError.unknownDocument
        }
        let revision = session.revision
        try await releaseLifecycle(session, reference)
        guard sessions[documentID] === session, session.revision == revision,
              session.references.contains(reference)
        else { throw MonacoBridgeError.staleDocumentState }
        session.remove(reference: reference)
        if selection == reference { selection = nil }
        if session.references.isEmpty { sessions.removeValue(forKey: documentID) }
    }

    public func allSessionsSortedByDocumentID() -> [MonacoWindowSession] {
        sessions.values.sorted { $0.documentID.description < $1.documentID.description }
    }

    var selectedReference: MonacoDocumentReference? { selection }

    func withLifecycleGate<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async rethrows -> Value {
        try await lifecycleGate.perform(operation)
    }

    func withCancellableLifecycleGate<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        try await lifecycleGate.performCancellable(operation)
    }

    struct SelectionReservation {
        let reference: MonacoDocumentReference
        let session: MonacoWindowSession
        let sessionRevision: UInt64
    }

    func selectionReservation(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) throws -> SelectionReservation {
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        guard let session = sessions[documentID], session.references.contains(reference) else {
            throw MonacoBridgeError.unknownDocument
        }
        return SelectionReservation(
            reference: reference,
            session: session,
            sessionRevision: session.revision
        )
    }

    func commitSelection(_ reservation: SelectionReservation) throws {
        guard sessions[reservation.reference.documentID] === reservation.session,
              reservation.session.revision == reservation.sessionRevision,
              reservation.session.references.contains(reservation.reference)
        else { throw MonacoBridgeError.staleDocumentState }
        selection = reservation.reference
    }

    private static func authoritativeSnapshot(
        from state: DocumentClientControllerState
    ) -> DocumentSnapshot? {
        switch state {
        case let .ready(snapshot), let .readOnly(snapshot): snapshot
        case .closed, .resynchronizing: nil
        }
    }
}

private func contextSortKey(_ contextID: WorkspaceContextID) -> String {
    switch contextID {
    case let .project(projectID): "0:\(projectID.description)"
    case let .conversation(conversationID): "1:\(conversationID.description)"
    }
}
