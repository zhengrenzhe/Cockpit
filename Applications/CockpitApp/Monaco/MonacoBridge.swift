import Foundation
import CockpitClientCore
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public struct MonacoRelocationToken: Hashable, Sendable {
    public let id: RequestID
    public let workspaceContextID: WorkspaceContextID
    public let operation: FileOperation
    public let sourcePath: RelativePath
    public let affectedDocumentIDs: [DocumentID]

    fileprivate init(
        id: RequestID,
        workspaceContextID: WorkspaceContextID,
        operation: FileOperation,
        sourcePath: RelativePath,
        affectedDocumentIDs: [DocumentID]
    ) {
        self.id = id
        self.workspaceContextID = workspaceContextID
        self.operation = operation
        self.sourcePath = sourcePath
        self.affectedDocumentIDs = affectedDocumentIDs
    }
}

public enum MonacoRelocationDisposition: Hashable, Sendable {
    case complete
    case incomplete(pendingDocumentIDs: [DocumentID])
    case abandonedAllStale
}

public typealias MonacoNativeMessageSink = @MainActor @Sendable (MonacoNativeMessage) throws -> Void
public typealias MonacoOwnerErrorHandler = @MainActor @Sendable (DocumentID, MonacoBridgeError) -> Void

@MainActor
public final class MonacoBridge {
    private struct PreparedDocument {
        let documentID: DocumentID
        let environmentID: EnvironmentID
        let sourcePath: RelativePath
        let language: String
        let priorWritable: Bool
        let originalSnapshot: DocumentSnapshot
        let references: [MonacoDocumentReference]
        let viewStates: [MonacoDocumentReference: DocumentViewState]
    }

    private final class LiveRelocation {
        let token: MonacoRelocationToken
        let documents: [DocumentID: PreparedDocument]
        var committedResult: FileOperationResult?
        var pendingDocumentIDs: Set<DocumentID>
        var migratedDocumentIDs: Set<DocumentID> = []
        var destinationSnapshots: [DocumentID: DocumentSnapshot] = [:]

        init(
            token: MonacoRelocationToken,
            documents: [DocumentID: PreparedDocument]
        ) {
            self.token = token
            self.documents = documents
            self.pendingDocumentIDs = Set(token.affectedDocumentIDs)
        }
    }

    public let resolver: MonacoWindowSessionResolver
    public private(set) var webContentGeneration: UInt64
    private var sink: MonacoNativeMessageSink
    private let ownerErrorHandler: MonacoOwnerErrorHandler
    private var relocations: [RequestID: LiveRelocation] = [:]
    private var blockedDocumentIDs: Set<DocumentID> = []
    private var restartPending = false
    private var restartSelection: MonacoDocumentReference?

    public init(
        resolver: MonacoWindowSessionResolver,
        webContentGeneration: UInt64 = 1,
        sink: @escaping MonacoNativeMessageSink = { _ in },
        ownerErrorHandler: @escaping MonacoOwnerErrorHandler = { _, _ in }
    ) {
        precondition(webContentGeneration > 0 && webContentGeneration <= documentJavaScriptMaximum)
        self.resolver = resolver
        self.webContentGeneration = webContentGeneration
        self.sink = sink
        self.ownerErrorHandler = ownerErrorHandler
    }

    public func setSink(_ sink: @escaping MonacoNativeMessageSink) {
        self.sink = sink
    }

    public func handleMessageBody(_ body: Any) async -> MonacoNativeReply {
        do {
            let message = try MonacoMessageCodec.decode(body)
            guard message.generation == webContentGeneration else {
                throw MonacoBridgeError.staleGeneration
            }
            switch message {
            case .ready:
                if restartPending { try await rebuildAfterWebContentRestart() }
                return .success(nil)
            case let .edit(_, incomingAccess, baseVersion, changes):
                let (session, snapshot, access) = try await validatedAccess(incomingAccess)
                guard access.writable, access.editLeaseID != nil else {
                    throw MonacoBridgeError.readOnly
                }
                guard baseVersion == snapshot.documentVersion else {
                    throw MonacoBridgeError.staleDocumentState
                }
                let acknowledgement = try await session.controller.submit(changes)
                let (_, refreshedAccess) = try await currentSnapshotAndAccess(
                    reference: incomingAccess.reference,
                    session: session
                )
                return .success(.acknowledgement(
                    webContentGeneration: webContentGeneration,
                    access: refreshedAccess,
                    acknowledgement: acknowledgement
                ))
            case let .save(_, incomingAccess):
                let (session, snapshot, access) = try await validatedAccess(incomingAccess)
                guard access.writable else { throw MonacoBridgeError.readOnly }
                guard let fingerprint = snapshot.observedDiskFingerprint else {
                    throw MonacoBridgeError.fileMissing
                }
                _ = try await session.controller.save(expectedFingerprint: fingerprint)
                let (replacement, refreshedAccess) = try await currentSnapshotAndAccess(
                    reference: incomingAccess.reference,
                    session: session
                )
                let viewState = await resolver.loadViewState(
                    incomingAccess.reference.workspaceContextID,
                    incomingAccess.reference.tabID,
                    incomingAccess.reference.documentID
                )
                return .success(.replace(
                    webContentGeneration: webContentGeneration,
                    access: refreshedAccess,
                    snapshot: replacement,
                    viewState: viewState
                ))
            case let .viewState(_, incomingAccess, value):
                _ = try await validatedAccess(incomingAccess)
                try await resolver.storeViewState(
                    incomingAccess.reference.workspaceContextID,
                    incomingAccess.reference.tabID,
                    incomingAccess.reference.documentID,
                    value
                )
                return .success(nil)
            }
        } catch {
            return .failure(Self.bridgeError(error))
        }
    }

    public func select(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) async throws {
        try resolver.select(contextID: contextID, tabID: tabID, documentID: documentID)
        guard let session = resolver.session(documentID: documentID) else {
            throw MonacoBridgeError.unknownDocument
        }
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        let (_, access) = try await currentSnapshotAndAccess(reference: reference, session: session)
        let viewState = await resolver.loadViewState(contextID, tabID, documentID)
        try sink(.selectModel(
            webContentGeneration: webContentGeneration,
            access: access,
            viewState: viewState
        ))
    }

    public func prepareForWebContentRestart(generation: UInt64) throws {
        guard webContentGeneration < documentJavaScriptMaximum,
              generation == webContentGeneration + 1
        else { throw MonacoBridgeError.invalidSchema }
        webContentGeneration = generation
        restartPending = true
        restartSelection = resolver.selectedReference
    }

    public func prepareRelocation(
        workspaceContextID: WorkspaceContextID,
        operation: FileOperation
    ) async throws -> MonacoRelocationToken {
        let sourcePath = try Self.sourcePath(for: operation)
        guard !relocations.values.contains(where: {
            $0.token.workspaceContextID == workspaceContextID && $0.token.operation == operation
        }) else { throw MonacoBridgeError.staleDocumentState }

        let sessions = resolver.allSessionsSortedByDocumentID()

        var prepared: [DocumentID: PreparedDocument] = [:]
        for session in sessions {
            let state = await session.controller.state
            let snapshot: DocumentSnapshot
            let priorWritable: Bool
            switch state {
            case let .ready(value):
                guard let lease = value.currentLease,
                      lease.clientInstanceID == resolver.clientInstanceID,
                      lease.documentID == value.documentID
                else { throw MonacoBridgeError.staleDocumentState }
                snapshot = value
                priorWritable = true
            case let .readOnly(value):
                snapshot = value
                priorWritable = false
            case .closed:
                throw MonacoBridgeError.unknownDocument
            case .resynchronizing:
                throw MonacoBridgeError.resynchronizing
            }
            guard snapshot.documentID == session.documentID else {
                throw MonacoBridgeError.staleDocumentState
            }
            guard Self.path(snapshot.relativePath, isEqualToOrDescendantOf: sourcePath) else {
                continue
            }
            prepared[session.documentID] = PreparedDocument(
                documentID: session.documentID,
                environmentID: snapshot.environmentID,
                sourcePath: snapshot.relativePath,
                language: session.language,
                priorWritable: priorWritable,
                originalSnapshot: snapshot,
                references: session.references,
                viewStates: [:]
            )
        }

        let affectedIDs = prepared.keys.sorted(by: Self.documentIDLess)
        let existingAffected = Set(relocations.values.flatMap { $0.token.affectedDocumentIDs })
        guard existingAffected.isDisjoint(with: affectedIDs) else {
            throw MonacoBridgeError.staleDocumentState
        }

        for documentID in affectedIDs {
            guard let value = prepared[documentID],
                  let session = resolver.session(documentID: documentID)
            else { throw MonacoBridgeError.unknownDocument }
            if value.priorWritable { _ = try await session.controller.flush() }
            var viewStates: [MonacoDocumentReference: DocumentViewState] = [:]
            for reference in value.references {
                if let state = await resolver.loadViewState(
                    reference.workspaceContextID,
                    reference.tabID,
                    reference.documentID
                ) {
                    viewStates[reference] = state
                }
            }
            prepared[documentID] = PreparedDocument(
                documentID: value.documentID,
                environmentID: value.environmentID,
                sourcePath: value.sourcePath,
                language: value.language,
                priorWritable: value.priorWritable,
                originalSnapshot: value.originalSnapshot,
                references: value.references,
                viewStates: viewStates
            )
        }

        let token = MonacoRelocationToken(
            id: RequestID(),
            workspaceContextID: workspaceContextID,
            operation: operation,
            sourcePath: sourcePath,
            affectedDocumentIDs: affectedIDs
        )
        relocations[token.id] = LiveRelocation(token: token, documents: prepared)
        return token
    }

    public func commitRelocation(
        _ token: MonacoRelocationToken,
        result: FileOperationResult
    ) async throws -> MonacoRelocationDisposition {
        let state = try liveRelocation(for: token)
        guard state.committedResult == nil else { throw MonacoBridgeError.staleDocumentState }
        guard case let .relocated(from, _) = result, from == token.sourcePath else {
            throw MonacoBridgeError.invalidSchema
        }
        state.committedResult = result
        if token.affectedDocumentIDs.isEmpty {
            relocations.removeValue(forKey: token.id)
            return .complete
        }
        return await migratePendingDocuments(state)
    }

    public func retryRelocation(
        _ token: MonacoRelocationToken
    ) async throws -> MonacoRelocationDisposition {
        let state = try liveRelocation(for: token)
        guard state.committedResult != nil, !state.pendingDocumentIDs.isEmpty else {
            throw MonacoBridgeError.staleDocumentState
        }
        return await migratePendingDocuments(state)
    }

    public func abandonCommittedRelocation(
        _ token: MonacoRelocationToken
    ) throws -> MonacoRelocationDisposition {
        let state = try liveRelocation(for: token)
        guard state.committedResult != nil else { throw MonacoBridgeError.staleDocumentState }
        for documentID in token.affectedDocumentIDs {
            guard let prepared = state.documents[documentID] else { continue }
            blockedDocumentIDs.insert(documentID)
            for reference in prepared.references {
                var disposedURIs: Set<String> = []
                for snapshot in [prepared.originalSnapshot, state.destinationSnapshots[documentID]].compactMap({ $0 }) {
                    let access = try Self.access(
                        reference: reference,
                        snapshot: snapshot,
                        clientInstanceID: resolver.clientInstanceID,
                        forcedWritable: prepared.priorWritable
                    )
                    guard disposedURIs.insert(access.uri).inserted else { continue }
                    try sink(.disposeModel(webContentGeneration: webContentGeneration, access: access))
                }
            }
        }
        relocations.removeValue(forKey: token.id)
        return .abandonedAllStale
    }

    public func cancelRelocation(_ token: MonacoRelocationToken) throws {
        let state = try liveRelocation(for: token)
        guard state.committedResult == nil else { throw MonacoBridgeError.staleDocumentState }
        relocations.removeValue(forKey: token.id)
    }

    private func validatedAccess(
        _ incoming: MonacoDocumentAccess
    ) async throws -> (MonacoWindowSession, DocumentSnapshot, MonacoDocumentAccess) {
        guard !blockedDocumentIDs.contains(incoming.reference.documentID) else {
            throw MonacoBridgeError.resynchronizing
        }
        guard let session = resolver.session(documentID: incoming.reference.documentID),
              session.references.contains(incoming.reference)
        else { throw MonacoBridgeError.unknownDocument }
        let (snapshot, current) = try await currentSnapshotAndAccess(
            reference: incoming.reference,
            session: session
        )
        guard current == incoming else { throw MonacoBridgeError.staleDocumentState }
        return (session, snapshot, current)
    }

    private func currentSnapshotAndAccess(
        reference: MonacoDocumentReference,
        session: MonacoWindowSession
    ) async throws -> (DocumentSnapshot, MonacoDocumentAccess) {
        guard !blockedDocumentIDs.contains(reference.documentID) else {
            throw MonacoBridgeError.resynchronizing
        }
        let snapshot: DocumentSnapshot
        let forcedWritable: Bool
        switch await session.controller.state {
        case let .ready(value):
            snapshot = value
            forcedWritable = true
        case let .readOnly(value):
            snapshot = value
            forcedWritable = false
        case .closed:
            throw MonacoBridgeError.unknownDocument
        case .resynchronizing:
            throw MonacoBridgeError.resynchronizing
        }
        guard snapshot.documentID == reference.documentID else {
            throw MonacoBridgeError.staleDocumentState
        }
        return (
            snapshot,
            try Self.access(
                reference: reference,
                snapshot: snapshot,
                clientInstanceID: resolver.clientInstanceID,
                forcedWritable: forcedWritable
            )
        )
    }

    private func rebuildAfterWebContentRestart() async throws {
        let selected = restartSelection
        var rebuilt: Set<DocumentID> = []
        for session in resolver.allSessionsSortedByDocumentID() {
            let requestWriteAccess: Bool
            switch await session.controller.state {
            case let .ready(snapshot):
                requestWriteAccess = snapshot.currentLease?.clientInstanceID == resolver.clientInstanceID
            case .readOnly:
                requestWriteAccess = false
            case .closed, .resynchronizing:
                ownerErrorHandler(session.documentID, .resynchronizing)
                continue
            }
            do {
                _ = try await session.controller.resynchronize(
                    requestWriteAccess: requestWriteAccess
                )
                blockedDocumentIDs.remove(session.documentID)
                for reference in session.references {
                    let (snapshot, access) = try await currentSnapshotAndAccess(
                        reference: reference,
                        session: session
                    )
                    let viewState = await resolver.loadViewState(
                        reference.workspaceContextID,
                        reference.tabID,
                        reference.documentID
                    )
                    try sink(.open(
                        webContentGeneration: webContentGeneration,
                        access: access,
                        language: session.language,
                        snapshot: snapshot,
                        viewState: viewState
                    ))
                }
                rebuilt.insert(session.documentID)
            } catch {
                blockedDocumentIDs.insert(session.documentID)
                ownerErrorHandler(session.documentID, .transportFailure)
            }
        }
        if let selected, rebuilt.contains(selected.documentID),
           let session = resolver.session(documentID: selected.documentID) {
            let (_, access) = try await currentSnapshotAndAccess(reference: selected, session: session)
            let viewState = await resolver.loadViewState(
                selected.workspaceContextID,
                selected.tabID,
                selected.documentID
            )
            try sink(.selectModel(
                webContentGeneration: webContentGeneration,
                access: access,
                viewState: viewState
            ))
        }
        restartPending = false
        restartSelection = nil
    }

    private func migratePendingDocuments(
        _ state: LiveRelocation
    ) async -> MonacoRelocationDisposition {
        guard case let .relocated(_, destination)? = state.committedResult else {
            return .incomplete(pendingDocumentIDs: state.pendingDocumentIDs.sorted(by: Self.documentIDLess))
        }
        let orderedPending = state.pendingDocumentIDs.sorted(by: Self.documentIDLess)
        for (index, documentID) in orderedPending.enumerated() {
            guard let prepared = state.documents[documentID],
                  let session = resolver.session(documentID: documentID)
            else {
                markBlocked(orderedPending[index...])
                return .incomplete(pendingDocumentIDs: state.pendingDocumentIDs.sorted(by: Self.documentIDLess))
            }
            do {
                let replacement = try await session.controller.resynchronize(
                    requestWriteAccess: prepared.priorWritable
                )
                let mappedPath = try Self.destinationPath(
                    sourcePath: state.token.sourcePath,
                    documentPath: prepared.sourcePath,
                    destinationPath: destination
                )
                guard replacement.documentID == prepared.documentID,
                      replacement.environmentID == prepared.environmentID,
                      replacement.relativePath == mappedPath
                else { throw MonacoBridgeError.staleDocumentState }
                blockedDocumentIDs.remove(documentID)
                for reference in prepared.references {
                    let (authoritative, access) = try await currentSnapshotAndAccess(
                        reference: reference,
                        session: session
                    )
                    guard authoritative.relativePath == mappedPath else {
                        throw MonacoBridgeError.staleDocumentState
                    }
                    state.destinationSnapshots[documentID] = authoritative
                    let oldURI = try MonacoFileURI.make(
                        environmentID: prepared.originalSnapshot.environmentID,
                        path: prepared.originalSnapshot.relativePath
                    )
                    try sink(.renameModel(
                        webContentGeneration: webContentGeneration,
                        access: access,
                        oldURI: oldURI,
                        language: prepared.language,
                        snapshot: authoritative,
                        viewState: prepared.viewStates[reference]
                    ))
                }
                state.pendingDocumentIDs.remove(documentID)
                state.migratedDocumentIDs.insert(documentID)
                blockedDocumentIDs.remove(documentID)
            } catch {
                markBlocked(orderedPending[index...])
                return .incomplete(pendingDocumentIDs: state.pendingDocumentIDs.sorted(by: Self.documentIDLess))
            }
        }
        relocations.removeValue(forKey: state.token.id)
        return .complete
    }

    private func markBlocked(_ documentIDs: ArraySlice<DocumentID>) {
        for documentID in documentIDs { blockedDocumentIDs.insert(documentID) }
    }

    private func liveRelocation(for token: MonacoRelocationToken) throws -> LiveRelocation {
        guard let state = relocations[token.id], state.token == token else {
            throw MonacoBridgeError.invalidSchema
        }
        return state
    }

    private static func sourcePath(for operation: FileOperation) throws -> RelativePath {
        switch operation {
        case let .rename(source, _), let .move(source, _): source
        case .createFile, .createDirectory, .trash:
            throw MonacoBridgeError.invalidSchema
        }
    }

    private static func destinationPath(
        sourcePath: RelativePath,
        documentPath: RelativePath,
        destinationPath: RelativePath
    ) throws -> RelativePath {
        if documentPath == sourcePath { return destinationPath }
        let prefix = sourcePath.string + "/"
        guard documentPath.string.hasPrefix(prefix) else {
            throw MonacoBridgeError.invalidSchema
        }
        return try RelativePath(destinationPath.string + "/" + documentPath.string.dropFirst(prefix.count))
    }

    private static func path(_ path: RelativePath, isEqualToOrDescendantOf source: RelativePath) -> Bool {
        path == source || path.string.hasPrefix(source.string + "/")
    }

    private static func documentIDLess(_ left: DocumentID, _ right: DocumentID) -> Bool {
        left.description < right.description
    }

    private static func access(
        reference: MonacoDocumentReference,
        snapshot: DocumentSnapshot,
        clientInstanceID: ClientInstanceID,
        forcedWritable: Bool? = nil
    ) throws -> MonacoDocumentAccess {
        let writable: Bool
        let leaseID: EditLeaseID?
        if let forcedWritable {
            writable = forcedWritable
            if forcedWritable {
                guard let lease = snapshot.currentLease,
                      lease.clientInstanceID == clientInstanceID,
                      lease.documentID == snapshot.documentID
                else { throw MonacoBridgeError.staleDocumentState }
                leaseID = lease.id
            } else {
                leaseID = nil
            }
        } else if let lease = snapshot.currentLease,
                  lease.clientInstanceID == clientInstanceID,
                  lease.documentID == snapshot.documentID {
            writable = true
            leaseID = lease.id
        } else {
            writable = false
            leaseID = nil
        }
        return MonacoDocumentAccess(
            reference: reference,
            uri: try MonacoFileURI.make(environmentID: snapshot.environmentID, path: snapshot.relativePath),
            lastAcceptedClientSequence: snapshot.lastAcceptedClientSequence,
            editLeaseID: leaseID,
            writable: writable
        )
    }

    private static func bridgeError(_ error: any Error) -> MonacoBridgeError {
        if let error = error as? MonacoBridgeError { return error }
        guard let error = error as? DocumentProtocolError else { return .transportFailure }
        switch error {
        case .invalidValue, .unknownFields:
            return .invalidSchema
        case .invalidLease, .leaseHeld, .baseVersionMismatch, .sequenceGap,
             .duplicateMismatch, .staleSequence, .recoveryRequired:
            return .staleDocumentState
        case .resynchronizing:
            return .resynchronizing
        case .readOnly:
            return .readOnly
        case .fileMissing:
            return .fileMissing
        }
    }
}

private extension MonacoToNativeMessage {
    var generation: UInt64 {
        switch self {
        case let .ready(value), let .edit(value, _, _, _), let .save(value, _),
             let .viewState(value, _, _): value
        }
    }
}
