import Foundation
import CockpitClientCore
import CockpitHostCore
import CockpitLocalTransport
import CockpitTypes

enum WorkspaceViewModelError: Error, Equatable {
    case noActiveContext
    case tabNotFound
    case newTabPickerRequired
    case invalidTabKind
    case relocationUnavailable
    case tabCommandUnavailable
}

@MainActor
struct WorkspaceCommandDependencies {
    let hostClient: HostXPCClient
    let monacoBridge: MonacoBridge
}

enum WorkspaceSidebarItem: Hashable {
    case project(ProjectID)
    case conversation(ConversationID)
}

enum WorkspaceTabKind: Hashable {
    case file(DocumentID)
    case shell(TerminalSessionID)
    case codex(TerminalSessionID)
    case claude(TerminalSessionID)
    case newTabPicker

    var terminalSessionID: TerminalSessionID? {
        switch self {
        case let .shell(value), let .codex(value), let .claude(value): value
        case .file, .newTabPicker: nil
        }
    }

    fileprivate var resource: TabRecord.Resource {
        switch self {
        case let .file(documentID): .file(documentID)
        case let .shell(sessionID), let .codex(sessionID), let .claude(sessionID):
            .terminal(sessionID)
        case .newTabPicker: .newTabPicker
        }
    }

    fileprivate var terminalKind: TerminalTabKind? {
        switch self {
        case .file, .newTabPicker: nil
        case .shell: .shell
        case .codex: .codex
        case .claude: .claude
        }
    }

    fileprivate func matches(_ record: TabRecord) -> Bool {
        resource == record.resource && terminalKind == record.terminalKind
    }
}

struct WorkspaceTab: Hashable {
    let record: TabRecord
    let kind: WorkspaceTabKind

    init(record: TabRecord, kind: WorkspaceTabKind) throws {
        let valid = try record.validated()
        guard kind.matches(valid) else {
            throw WorkspaceViewModelError.invalidTabKind
        }
        self.record = valid
        self.kind = kind
    }

    init(record: TabRecord) throws {
        let valid = try record.validated()
        let kind: WorkspaceTabKind
        switch valid.resource {
        case let .file(documentID):
            kind = .file(documentID)
        case let .terminal(sessionID):
            switch valid.terminalKind {
            case .shell?: kind = .shell(sessionID)
            case .codex?: kind = .codex(sessionID)
            case .claude?: kind = .claude(sessionID)
            case nil: throw WorkspaceViewModelError.invalidTabKind
            }
        case .newTabPicker:
            kind = .newTabPicker
        }
        self.record = valid
        self.kind = kind
    }

    var id: TabID { record.id }
}

typealias WorkspaceFileSelectionHandler = @MainActor @Sendable (
    WorkspaceContextID,
    TabID,
    DocumentID
) async throws -> Void

actor WorkspaceStateCoordinator {
    private let clientState: WorkspaceClientState
    private let remote: any ClientWorkspaceStateServing
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        clientState: WorkspaceClientState,
        remote: any ClientWorkspaceStateServing
    ) {
        self.clientState = clientState
        self.remote = remote
    }

    func storedState(
        for key: ClientWorkspaceStateKey
    ) async throws -> ClientWorkspaceState? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await storedStateInsideGate(for: key)
    }

    func loadOrCreate(
        key: ClientWorkspaceStateKey,
        initial: ClientWorkspaceState
    ) async throws -> ClientWorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        if let state = try await storedStateInsideGate(for: key) { return state }
        let valid = try initial.validated()
        guard valid.key == key else { throw WorkspaceRepositoryError.invalidStoredValue }
        try await remote.saveClientState(valid)
        try await clientState.store(valid)
        return valid
    }

    func mutate(
        key: ClientWorkspaceStateKey,
        initial: ClientWorkspaceState,
        _ mutation: @Sendable (inout ClientWorkspaceState) throws -> Void
    ) async throws -> ClientWorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        var state = try await storedStateInsideGate(for: key) ?? initial
        guard state.key == key else { throw WorkspaceRepositoryError.invalidStoredValue }
        try mutation(&state)
        let valid = try state.validated()
        try await remote.saveClientState(valid)
        try await clientState.store(valid)
        return valid
    }

    func updateFileViewState(
        key: ClientWorkspaceStateKey,
        tabID: TabID,
        documentID: DocumentID,
        viewState: DocumentViewState
    ) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        guard var state = try await storedStateInsideGate(for: key) else {
            throw WorkspaceClientStateError.stateNotFound
        }
        guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw WorkspaceClientStateError.tabNotFound
        }
        guard case let .file(currentDocumentID) = state.tabs[index].resource,
              currentDocumentID == documentID
        else { throw WorkspaceClientStateError.tabDocumentMismatch }
        state.tabs[index] = try TabRecord(
            validatingID: tabID,
            resource: .file(documentID),
            fileViewState: viewState.validated()
        )
        let valid = try state.validated()
        try await remote.saveClientState(valid)
        try await clientState.store(valid)
    }

    private func storedStateInsideGate(
        for key: ClientWorkspaceStateKey
    ) async throws -> ClientWorkspaceState? {
        if let local = await clientState.state(for: key) {
            return try local.validated()
        }
        guard let loaded = try await remote.loadClientState(key) else { return nil }
        let valid = try loaded.validated()
        guard valid.key == key else { throw WorkspaceRepositoryError.invalidStoredValue }
        try await clientState.store(valid)
        return valid
    }

    private func acquire() async {
        if !occupied {
            occupied = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        waiters.removeFirst().resume()
    }
}

@MainActor
final class WorkspaceViewModel: FileRelocationCoordinating {
    let workspaceService: any WorkspaceServing
    let stateCoordinator: WorkspaceStateCoordinator
    let activeContexts: ActiveContextController
    let deviceID: DeviceID
    let windowID: WindowID
    let clientInstanceID: ClientInstanceID
    let commandDependencies: WorkspaceCommandDependencies?

    private(set) var projects: WorkspaceSnapshot = []
    private(set) var sidebarItems: [WorkspaceSidebarItem] = []
    private(set) var activeContext: ActiveContext?
    private(set) var currentTabs: [WorkspaceTab] = []
    private(set) var selectedTabID: TabID?

    private var selectionRequest: UInt64 = 0
    private var tabSelectionRequest: UInt64 = 0
    private var workspaceLoadRequest: UInt64 = 0
    private var changeHandler: (@MainActor () -> Void)?
    private let fileSelection: WorkspaceFileSelectionHandler

    init(
        workspaceService: any WorkspaceServing,
        stateCoordinator: WorkspaceStateCoordinator,
        activeContexts: ActiveContextController,
        deviceID: DeviceID,
        windowID: WindowID,
        clientInstanceID: ClientInstanceID,
        commandDependencies: WorkspaceCommandDependencies? = nil,
        fileSelection: @escaping WorkspaceFileSelectionHandler
    ) {
        self.workspaceService = workspaceService
        self.stateCoordinator = stateCoordinator
        self.activeContexts = activeContexts
        self.deviceID = deviceID
        self.windowID = windowID
        self.clientInstanceID = clientInstanceID
        self.commandDependencies = commandDependencies
        self.fileSelection = fileSelection
    }

    func setChangeHandler(_ handler: @escaping @MainActor () -> Void) {
        changeHandler = handler
    }

    func loadWorkspace() async throws {
        precondition(workspaceLoadRequest < UInt64.max, "Workspace load generation exhausted")
        workspaceLoadRequest += 1
        let request = workspaceLoadRequest
        let loaded = try await workspaceService.listWorkspace()
        guard request == workspaceLoadRequest else { throw CancellationError() }
        projects = loaded
        sidebarItems = loaded.flatMap { project in
            [.project(project.projectID)]
                + project.conversations.map { .conversation($0.id) }
        }
        notifyChange()
    }

    @discardableResult
    func selectContext(_ contextID: WorkspaceContextID) async throws -> ActiveContext {
        precondition(selectionRequest < UInt64.max, "Workspace selection generation exhausted")
        selectionRequest += 1
        let request = selectionRequest
        let resolved = try await workspaceService.resolveContext(contextID)
        guard request == selectionRequest else { throw CancellationError() }

        let selected = await activeContexts.select(resolved)
        guard request == selectionRequest,
              await activeContexts.accepts(generation: selected.generation)
        else { throw CancellationError() }

        let state = try await state(for: selected.contextID)
        guard request == selectionRequest,
              await activeContexts.accepts(generation: selected.generation)
        else { throw CancellationError() }

        let tabs = try workspaceTabs(from: state.tabs)
        if let selectedTabID = state.selectedTabID,
           let selectedTab = tabs.first(where: { $0.id == selectedTabID }),
           case let .file(documentID) = selectedTab.kind
        {
            try await fileSelection(selected.contextID, selectedTabID, documentID)
            guard request == selectionRequest,
                  await activeContexts.accepts(generation: selected.generation)
            else { throw CancellationError() }
        }

        activeContext = selected
        currentTabs = tabs
        selectedTabID = state.selectedTabID
        notifyChange()
        return selected
    }

    func tabs(for contextID: WorkspaceContextID) async throws -> [WorkspaceTab] {
        let state = try await state(for: contextID)
        return try workspaceTabs(from: state.tabs)
    }

    @discardableResult
    func openNewTabPicker() async throws -> TabID {
        let active = try requireActiveContext()
        let initial = try await state(for: active.contextID)
        try await requireAccepted(active)

        let tabID = TabID()
        let record = try TabRecord(
            validatingID: tabID,
            resource: .newTabPicker,
            fileViewState: nil
        )
        let state = try await stateCoordinator.mutate(
            key: initial.key,
            initial: initial
        ) { state in
            state = try Self.replacing(
                state,
                tabs: state.tabs + [record],
                selectedTabID: tabID
            )
        }
        try await requireAccepted(active)

        applyCurrentState(state)
        return tabID
    }

    func replaceNewTabPicker(
        _ tabID: TabID,
        with kind: WorkspaceTabKind
    ) async throws {
        guard kind != .newTabPicker else {
            throw WorkspaceViewModelError.invalidTabKind
        }
        let active = try requireActiveContext()
        let initial = try await state(for: active.contextID)
        try await requireAccepted(active)
        let state = try await stateCoordinator.mutate(
            key: initial.key,
            initial: initial
        ) { state in
            guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceViewModelError.tabNotFound
            }
            guard state.tabs[index].resource == .newTabPicker else {
                throw WorkspaceViewModelError.newTabPickerRequired
            }
            state.tabs[index] = try TabRecord(
                validatingID: tabID,
                resource: kind.resource,
                terminalKind: kind.terminalKind,
                fileViewState: kind.resource.isFile ? .initial() : nil
            )
            state = try Self.replacing(
                state,
                tabs: state.tabs,
                selectedTabID: tabID
            )
        }
        try await requireAccepted(active)

        applyCurrentState(state)
    }

    func cancelNewTabPicker(_ tabID: TabID) async throws {
        let active = try requireActiveContext()
        let initial = try await state(for: active.contextID)
        try await requireAccepted(active)
        let state = try await stateCoordinator.mutate(
            key: initial.key,
            initial: initial
        ) { state in
            guard let index = state.tabs.firstIndex(where: { $0.id == tabID }) else {
                throw WorkspaceViewModelError.tabNotFound
            }
            guard state.tabs[index].resource == .newTabPicker else {
                throw WorkspaceViewModelError.newTabPickerRequired
            }
            state.tabs.remove(at: index)
            let selected = state.selectedTabID == tabID
                ? state.tabs.first?.id
                : state.selectedTabID
            state = try Self.replacing(
                state,
                tabs: state.tabs,
                selectedTabID: selected
            )
        }
        try await requireAccepted(active)

        applyCurrentState(state)
    }

    func selectTab(_ tabID: TabID) async throws {
        precondition(tabSelectionRequest < UInt64.max, "Tab selection generation exhausted")
        tabSelectionRequest += 1
        let request = tabSelectionRequest
        let active = try requireActiveContext()
        guard let tab = currentTabs.first(where: { $0.id == tabID }) else {
            throw WorkspaceViewModelError.tabNotFound
        }
        if case let .file(documentID) = tab.kind {
            try await fileSelection(active.contextID, tabID, documentID)
        }
        guard request == tabSelectionRequest else { throw CancellationError() }
        try await requireAccepted(active)
        let initial = try await state(for: active.contextID)
        let state = try await stateCoordinator.mutate(
            key: initial.key,
            initial: initial
        ) { state in
            guard state.tabs.contains(where: { $0.id == tabID }) else {
                throw WorkspaceViewModelError.tabNotFound
            }
            state = try Self.replacing(
                state,
                tabs: state.tabs,
                selectedTabID: tabID
            )
        }
        guard request == tabSelectionRequest else { throw CancellationError() }
        try await requireAccepted(active)
        applyCurrentState(state)
    }

    func routeNewTabPickerChoice(
        _ option: NewTabPickerOption,
        tabID: TabID,
        contextID: WorkspaceContextID
    ) async throws {
        let active = try requireActiveContext()
        guard active.contextID == contextID,
              currentTabs.contains(where: {
                  $0.id == tabID && $0.kind == .newTabPicker
              })
        else { throw WorkspaceViewModelError.newTabPickerRequired }
        _ = option
        throw WorkspaceViewModelError.tabCommandUnavailable
    }

    func routeNewTabPickerCancellation(
        tabID: TabID,
        contextID: WorkspaceContextID
    ) async throws {
        let active = try requireActiveContext()
        guard active.contextID == contextID else { throw CancellationError() }
        try await cancelNewTabPicker(tabID)
    }

    func accepts(generation: UInt64) async -> Bool {
        await activeContexts.accepts(generation: generation)
    }

    func performRelocation(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws {
        throw WorkspaceViewModelError.relocationUnavailable
    }

    private func requireActiveContext() throws -> ActiveContext {
        guard let activeContext else { throw WorkspaceViewModelError.noActiveContext }
        return activeContext
    }

    private func requireAccepted(_ active: ActiveContext) async throws {
        guard activeContext?.generation == active.generation,
              await activeContexts.accepts(generation: active.generation)
        else { throw CancellationError() }
    }

    private func state(for contextID: WorkspaceContextID) async throws -> ClientWorkspaceState {
        let key = ClientWorkspaceStateKey(
            deviceID: deviceID,
            windowID: windowID,
            workspaceContextID: contextID
        )
        let initial = try ClientWorkspaceState(
            validatingKey: key,
            tabs: [],
            selectedTabID: nil,
            sidebar: SidebarState(isCollapsed: false),
            splitView: SplitViewState(
                validatingLeadingPaneWidth: 240,
                trailingPaneWidth: 300
            )
        )
        return try await stateCoordinator.loadOrCreate(key: key, initial: initial)
    }

    nonisolated private static func replacing(
        _ state: ClientWorkspaceState,
        tabs: [TabRecord],
        selectedTabID: TabID?
    ) throws -> ClientWorkspaceState {
        try ClientWorkspaceState(
            validatingKey: state.key,
            tabs: tabs,
            selectedTabID: selectedTabID,
            sidebar: state.sidebar,
            splitView: state.splitView
        )
    }

    private func applyCurrentState(_ state: ClientWorkspaceState) {
        guard activeContext?.contextID == state.key.workspaceContextID else { return }
        currentTabs = try! workspaceTabs(from: state.tabs)
        selectedTabID = state.selectedTabID
        notifyChange()
    }

    private func workspaceTabs(from records: [TabRecord]) throws -> [WorkspaceTab] {
        try records.map(WorkspaceTab.init(record:))
    }

    private func notifyChange() {
        changeHandler?()
    }
}

private extension TabRecord.Resource {
    var isFile: Bool {
        if case .file = self { return true }
        return false
    }
}
