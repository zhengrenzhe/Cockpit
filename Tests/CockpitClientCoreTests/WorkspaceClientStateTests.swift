import Foundation
import Testing
import CockpitTypes
@testable import CockpitClientCore

@Test func workspaceClientStateCoordinatesValidatedValuesByExactContextKey() async throws {
    let coordinator = WorkspaceClientState()
    let deviceID = DeviceID()
    let windowID = WindowID()
    let projectID = ProjectID()
    let conversationID = ConversationID()
    let project = try makeClientState(
        key: ClientWorkspaceStateKey(
            deviceID: deviceID,
            windowID: windowID,
            workspaceContextID: .project(projectID)
        ),
        tabID: TabID(),
        documentID: DocumentID(),
        leadingWidth: 220,
        trailingWidth: 310
    )
    let conversation = try makeClientState(
        key: ClientWorkspaceStateKey(
            deviceID: deviceID,
            windowID: windowID,
            workspaceContextID: .conversation(conversationID)
        ),
        tabID: TabID(),
        documentID: DocumentID(),
        leadingWidth: 180,
        trailingWidth: 360
    )

    try await coordinator.store(project)
    try await coordinator.store(conversation)

    #expect(await coordinator.state(for: project.key) == project)
    #expect(await coordinator.state(for: conversation.key) == conversation)
    #expect(await coordinator.state(for: ClientWorkspaceStateKey(
        deviceID: DeviceID(),
        windowID: windowID,
        workspaceContextID: .project(projectID)
    )) == nil)
}

@Test func splitViewRejectsNonfiniteAndNegativeWidthsThroughEveryValidationPath() throws {
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try SplitViewState(validatingLeadingPaneWidth: -.infinity, trailingPaneWidth: 1)
    }
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try SplitViewState(validatingLeadingPaneWidth: 1, trailingPaneWidth: -.leastNonzeroMagnitude)
    }
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try SplitViewState(validatingLeadingPaneWidth: .nan, trailingPaneWidth: 1)
    }

    var mutated = try SplitViewState(validatingLeadingPaneWidth: 1, trailingPaneWidth: 2)
    mutated.trailingPaneWidth = .infinity
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try mutated.validated()
    }
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try JSONEncoder().encode(mutated)
    }

    let invalidJSON = Data(#"{"leadingPaneWidth":40,"trailingPaneWidth":-1}"#.utf8)
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try JSONDecoder().decode(SplitViewState.self, from: invalidJSON)
    }
}

@Test func clientWorkspaceStateRecursivelyRejectsInvalidTabsAndSelection() throws {
    let key = ClientWorkspaceStateKey(
        deviceID: DeviceID(),
        windowID: WindowID(),
        workspaceContextID: .project(ProjectID())
    )
    let documentID = DocumentID()
    let tabID = TabID()
    let tab = try makeFileTab(id: tabID, documentID: documentID, line: 3)
    let split = try SplitViewState(validatingLeadingPaneWidth: 200, trailingPaneWidth: 300)

    #expect(throws: CockpitDomainValidationError.duplicateTabID) {
        _ = try ClientWorkspaceState(
            validatingKey: key,
            tabs: [tab, tab],
            selectedTabID: tabID,
            sidebar: SidebarState(isCollapsed: false),
            splitView: split
        )
    }
    #expect(throws: CockpitDomainValidationError.selectedTabNotFound) {
        _ = try ClientWorkspaceState(
            validatingKey: key,
            tabs: [tab],
            selectedTabID: TabID(),
            sidebar: SidebarState(isCollapsed: false),
            splitView: split
        )
    }

    var invalidTab = tab
    invalidTab.fileViewState = nil
    #expect(throws: CockpitDomainValidationError.invalidTabViewState) {
        _ = try ClientWorkspaceState(
            validatingKey: key,
            tabs: [invalidTab],
            selectedTabID: tabID,
            sidebar: SidebarState(isCollapsed: false),
            splitView: split
        )
    }
}

@Test func clientWorkspaceStateCodableRejectsMutatedInvalidDomainValues() throws {
    let state = try makeClientState(
        key: ClientWorkspaceStateKey(
            deviceID: DeviceID(),
            windowID: WindowID(),
            workspaceContextID: .project(ProjectID())
        ),
        tabID: TabID(),
        documentID: DocumentID(),
        leadingWidth: 240,
        trailingWidth: 320
    )

    var invalidForEncoding = state
    invalidForEncoding.tabs.append(state.tabs[0])
    #expect(throws: CockpitDomainValidationError.duplicateTabID) {
        _ = try JSONEncoder().encode(invalidForEncoding)
    }

    let validData = try JSONEncoder().encode(state)
    var object = try #require(JSONSerialization.jsonObject(with: validData) as? [String: Any])
    var split = try #require(object["splitView"] as? [String: Any])
    split["leadingPaneWidth"] = -5
    object["splitView"] = split
    let invalidData = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: CockpitDomainValidationError.invalidSplitViewWidth) {
        _ = try JSONDecoder().decode(ClientWorkspaceState.self, from: invalidData)
    }
}

private func makeClientState(
    key: ClientWorkspaceStateKey,
    tabID: TabID,
    documentID: DocumentID,
    leadingWidth: Double,
    trailingWidth: Double
) throws -> ClientWorkspaceState {
    try ClientWorkspaceState(
        validatingKey: key,
        tabs: [makeFileTab(id: tabID, documentID: documentID, line: 3)],
        selectedTabID: tabID,
        sidebar: SidebarState(isCollapsed: false),
        splitView: SplitViewState(
            validatingLeadingPaneWidth: leadingWidth,
            trailingPaneWidth: trailingWidth
        )
    )
}
private func makeFileTab(id: TabID, documentID: DocumentID, line: UInt64) throws -> TabRecord {
    let cursor = try TextPosition(validatingLine: line, column: 2)
    let selection = try TextRange(
        validatingAnchor: cursor,
        active: TextPosition(validatingLine: line, column: 6)
    )
    return try TabRecord(
        validatingID: id,
        resource: .file(documentID),
        fileViewState: DocumentViewState(
            validatingCursor: cursor,
            selections: [selection],
            firstVisibleLine: line,
            horizontalScrollOffset: 12
        )
    )
}
