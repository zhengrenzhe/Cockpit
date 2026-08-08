import CockpitTypes

public enum WorkspaceClientStateError: Error, Hashable, Sendable {
    case stateNotFound
    case tabNotFound
    case tabDocumentMismatch
}

public actor WorkspaceClientState {
    private var states: [ClientWorkspaceStateKey: ClientWorkspaceState] = [:]

    public init() {}

    public func store(_ state: ClientWorkspaceState) throws {
        let valid = try state.validated()
        states[valid.key] = valid
    }

    public func state(for key: ClientWorkspaceStateKey) -> ClientWorkspaceState? {
        states[key]
    }

    public func updateFileViewState(
        key: ClientWorkspaceStateKey,
        tabID: TabID,
        documentID: DocumentID,
        viewState: DocumentViewState
    ) throws {
        let validViewState = try viewState.validated()
        guard var state = states[key] else {
            throw WorkspaceClientStateError.stateNotFound
        }
        guard let tabIndex = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw WorkspaceClientStateError.tabNotFound
        }
        guard case let .file(currentDocumentID) = state.tabs[tabIndex].resource,
              currentDocumentID == documentID
        else {
            throw WorkspaceClientStateError.tabDocumentMismatch
        }

        state.tabs[tabIndex] = try TabRecord(
            validatingID: tabID,
            resource: .file(documentID),
            fileViewState: validViewState
        )
        states[key] = try state.validated()
    }
}
