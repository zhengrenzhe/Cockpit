import Foundation
import CockpitClientCore
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

@MainActor
public final class MonacoWindowSession {
    public let documentID: DocumentID
    public let controller: DocumentClientController
    public private(set) var language: String
    public private(set) var references: [MonacoDocumentReference]

    init(
        documentID: DocumentID,
        controller: DocumentClientController,
        language: String,
        references: [MonacoDocumentReference]
    ) {
        self.documentID = documentID
        self.controller = controller
        self.language = language
        self.references = references
    }

    func add(reference: MonacoDocumentReference) {
        guard !references.contains(reference) else { return }
        references.append(reference)
        references.sort(by: Self.referenceLess)
    }

    func remove(reference: MonacoDocumentReference) {
        references.removeAll { $0 == reference }
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

    public init(
        clientInstanceID: ClientInstanceID,
        loadViewState: @escaping MonacoViewStateLoader,
        storeViewState: @escaping MonacoViewStateStorer
    ) {
        self.clientInstanceID = clientInstanceID
        self.loadViewState = loadViewState
        self.storeViewState = storeViewState
    }

    public func retain(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID,
        controller: DocumentClientController,
        language: String
    ) throws {
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        if let session = sessions[documentID] {
            guard session.controller === controller, session.language == language else {
                throw MonacoBridgeError.staleDocumentState
            }
            session.add(reference: reference)
            return
        }
        sessions[documentID] = MonacoWindowSession(
            documentID: documentID,
            controller: controller,
            language: language,
            references: [reference]
        )
    }

    public func session(documentID: DocumentID) -> MonacoWindowSession? { sessions[documentID] }

    public func select(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) throws {
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        guard sessions[documentID]?.references.contains(reference) == true else {
            throw MonacoBridgeError.unknownDocument
        }
        selection = reference
    }

    public func release(
        contextID: WorkspaceContextID,
        tabID: TabID,
        documentID: DocumentID
    ) throws {
        let reference = MonacoDocumentReference(
            workspaceContextID: contextID,
            tabID: tabID,
            documentID: documentID
        )
        guard let session = sessions[documentID], session.references.contains(reference) else {
            throw MonacoBridgeError.unknownDocument
        }
        session.remove(reference: reference)
        if selection == reference { selection = nil }
        if session.references.isEmpty { sessions.removeValue(forKey: documentID) }
    }

    public func allSessionsSortedByDocumentID() -> [MonacoWindowSession] {
        sessions.values.sorted { $0.documentID.description < $1.documentID.description }
    }

    var selectedReference: MonacoDocumentReference? { selection }
}

private func contextSortKey(_ contextID: WorkspaceContextID) -> String {
    switch contextID {
    case let .project(projectID): "0:\(projectID.description)"
    case let .conversation(conversationID): "1:\(conversationID.description)"
    }
}
