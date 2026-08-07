import CockpitTypes

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
}
