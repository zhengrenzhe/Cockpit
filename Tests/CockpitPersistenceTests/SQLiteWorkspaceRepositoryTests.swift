import Foundation
import SQLite3
import Testing
import CockpitHostCore
import CockpitTypes
@testable import CockpitPersistence

@Test func createsProjectAndDirectEnvironmentAtomically() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)

        let project = try await repository.createProjectWithDirectEnvironment(
            NewProject(
                displayName: "Cockpit",
                rootBookmark: Data([0x01, 0x02, 0x03]),
                canonicalRootIdentity: "file-id:cockpit",
                workspaceRoot: "/Users/example/Cockpit",
                gitCommonDirectory: "/Users/example/Cockpit/.git"
            )
        )

        #expect(project.displayName == "Cockpit")
        #expect(project.rootBookmark == Data([0x01, 0x02, 0x03]))
        #expect(project.canonicalRootIdentity == "file-id:cockpit")
        let resolved = try await repository.resolve(.project(project.id))
        #expect(resolved.projectID == project.id)
        #expect(resolved.conversationID == nil)
        #expect(resolved.environmentID == project.baseEnvironmentID)
        #expect(resolved.workspaceRootIdentity == "file-id:cockpit")
        let inspectionConnection = try SQLiteConnection(databaseURL: databaseURL)
        #expect(
            try await inspectionConnection.textValue(
                for: "SELECT git_common_directory FROM environments"
            ) == "/Users/example/Cockpit/.git"
        )
        #expect(await inspectionConnection.close() == SQLITE_OK)
    }
}

@Test func failedEnvironmentInsertRollsBackProjectAndEnvironment() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let inspectionConnection = try SQLiteConnection(databaseURL: databaseURL)
        try await inspectionConnection.execute(
            """
            CREATE TRIGGER reject_environment_insert
            BEFORE INSERT ON environments
            BEGIN
                SELECT RAISE(ABORT, 'environment insert rejected');
            END
            """
        )

        await #expect(throws: (any Error).self) {
            try await repository.createProjectWithDirectEnvironment(makeProjectInput())
        }

        #expect(try await inspectionConnection.integerValue(for: "SELECT COUNT(*) FROM projects") == 0)
        #expect(try await inspectionConnection.integerValue(for: "SELECT COUNT(*) FROM environments") == 0)

        try await inspectionConnection.execute("DROP TRIGGER reject_environment_insert")
        _ = try await repository.createProjectWithDirectEnvironment(makeProjectInput())
        #expect(try await inspectionConnection.integerValue(for: "SELECT COUNT(*) FROM projects") == 1)
        #expect(try await inspectionConnection.integerValue(for: "SELECT COUNT(*) FROM environments") == 1)
    }
}

@Test func rejectsASecondProjectAtThePhaseOneLimit() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        _ = try await repository.createProjectWithDirectEnvironment(makeProjectInput())

        await #expect(throws: WorkspaceRepositoryError.phaseOneProjectLimit) {
            try await repository.createProjectWithDirectEnvironment(
                NewProject(
                    displayName: "Other",
                    rootBookmark: Data([0x09]),
                    canonicalRootIdentity: "file-id:other",
                    workspaceRoot: "/Users/example/Other",
                    gitCommonDirectory: "/Users/example/Other/.git"
                )
            )
        }

        #expect(try await repository.listProjects().count == 1)
    }
}

@Test func conversationsShareTheProjectBaseEnvironment() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let project = try await repository.createProjectWithDirectEnvironment(makeProjectInput())

        let first = try await repository.createConversation(
            NewConversation(projectID: project.id, title: "First")
        )
        let second = try await repository.createConversation(
            NewConversation(projectID: project.id, title: "Second")
        )

        #expect(first.environmentID == project.baseEnvironmentID)
        #expect(second.environmentID == project.baseEnvironmentID)
        #expect(first.lifecycleState == .active)
        #expect(second.lifecycleState == .active)
    }
}

@Test func reopeningPreservesProjectConversationAndEnvironmentResolution() async throws {
    try await withRepositoryDatabase { databaseURL in
        let firstRepository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let createdProject = try await firstRepository.createProjectWithDirectEnvironment(makeProjectInput())
        let createdConversation = try await firstRepository.createConversation(
            NewConversation(projectID: createdProject.id, title: "Persistent")
        )
        try await firstRepository.renameConversation(id: createdConversation.id, title: "Renamed")
        let projectResolution = try await firstRepository.resolve(.project(createdProject.id))
        let conversationResolution = try await firstRepository.resolve(.conversation(createdConversation.id))
        #expect(await firstRepository.close() == SQLITE_OK)

        let reopenedRepository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let reopenedProjects = try await reopenedRepository.listProjects()
        let reopenedProjectResolution = try await reopenedRepository.resolve(.project(createdProject.id))
        let reopenedConversationResolution = try await reopenedRepository.resolve(.conversation(createdConversation.id))
        let inspectionConnection = try SQLiteConnection(databaseURL: databaseURL)

        #expect(reopenedProjects == [createdProject])
        #expect(reopenedProjectResolution == projectResolution)
        #expect(reopenedConversationResolution == conversationResolution)
        #expect(try await inspectionConnection.textValue(for: "SELECT title FROM conversations") == "Renamed")
        #expect(await inspectionConnection.close() == SQLITE_OK)
        #expect(await reopenedRepository.close() == SQLITE_OK)
    }
}

@Test func reopeningRepositoryEnumeratesAllConversationsFromDatabaseURL() async throws {
    try await withRepositoryDatabase { databaseURL in
        let expectedConversations = try await seedConversationsAndClose(databaseURL: databaseURL)

        let reopenedRepository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let persistedProjects = try await reopenedRepository.listProjects()
        let persistedProject = try #require(persistedProjects.only)
        let persistedConversations = try await reopenedRepository.listConversations(
            projectID: persistedProject.id
        )

        #expect(persistedConversations == expectedConversations)
        #expect(await reopenedRepository.close() == SQLITE_OK)
    }
}

@Test func repositoryTextValuesRoundTripEmbeddedNUL() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let input = NewProject(
            displayName: "Cock\0pit",
            rootBookmark: Data([0x01]),
            canonicalRootIdentity: "file-id:cock\0pit",
            workspaceRoot: "/Users/example/Cock\0pit",
            gitCommonDirectory: "/Users/example/Cock\0pit/.git"
        )
        let project = try await repository.createProjectWithDirectEnvironment(input)
        let conversation = try await repository.createConversation(
            NewConversation(projectID: project.id, title: "Before")
        )
        try await repository.renameConversation(id: conversation.id, title: "A\0B")
        #expect(await repository.close() == SQLITE_OK)

        let reopenedRepository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        #expect(try await reopenedRepository.listProjects() == [project])
        let conversations = try await reopenedRepository.listConversations(projectID: project.id)
        #expect(conversations.count == 1)
        #expect(conversations.first?.title == "A\0B")
        #expect(await reopenedRepository.close() == SQLITE_OK)
    }
}

@Test func nonGitProjectRoundTripsWithoutGitCommonDirectory() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let project = try await repository.createProjectWithDirectEnvironment(
            NewProject(
                displayName: "Plain Directory",
                rootBookmark: Data([0x04, 0x05]),
                canonicalRootIdentity: "file-id:plain-directory",
                workspaceRoot: "/Users/example/PlainDirectory",
                gitCommonDirectory: nil
            )
        )
        let expectedResolution = try await repository.resolve(.project(project.id))
        #expect(await repository.close() == SQLITE_OK)

        let reopenedRepository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        #expect(try await reopenedRepository.listProjects() == [project])
        #expect(try await reopenedRepository.resolve(.project(project.id)) == expectedResolution)
        #expect(await reopenedRepository.close() == SQLITE_OK)
        let inspectionConnection = try SQLiteConnection(databaseURL: databaseURL)
        let rows = try await inspectionConnection.query(
            "SELECT git_common_directory FROM environments"
        )
        #expect(rows.count == 1)
        #expect(isSQLiteNull(rows.first?.first))
        #expect(await inspectionConnection.close() == SQLITE_OK)
    }
}

@Test func clientWorkspaceLayoutsRoundTripIndependentlyAcrossProjectAndConversations() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let project = try await repository.createProjectWithDirectEnvironment(makeProjectInput())
        let firstConversation = try await repository.createConversation(
            NewConversation(projectID: project.id, title: "First")
        )
        let secondConversation = try await repository.createConversation(
            NewConversation(projectID: project.id, title: "Second")
        )
        let deviceID = DeviceID()
        let windowID = WindowID()
        let documentID = DocumentID()
        let projectState = try makeWorkspaceState(
            deviceID: deviceID, windowID: windowID, contextID: .project(project.id),
            documentID: documentID, tabID: TabID(), cursorLine: 3,
            collapsed: false, leadingWidth: 210, trailingWidth: 330, scroll: 11
        )
        let firstState = try makeWorkspaceState(
            deviceID: deviceID, windowID: windowID, contextID: .conversation(firstConversation.id),
            documentID: documentID, tabID: TabID(), cursorLine: 7,
            collapsed: true, leadingWidth: 180, trailingWidth: 410, scroll: 22
        )
        let secondState = try makeWorkspaceState(
            deviceID: deviceID, windowID: windowID, contextID: .conversation(secondConversation.id),
            documentID: documentID, tabID: TabID(), cursorLine: 12,
            collapsed: false, leadingWidth: 260, trailingWidth: 290, scroll: 33
        )

        try await repository.saveClientState(projectState)
        try await repository.saveClientState(firstState)
        try await repository.saveClientState(secondState)
        #expect(await repository.close() == SQLITE_OK)

        let reopened = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        #expect(try await reopened.loadClientState(projectState.key) == projectState)
        #expect(try await reopened.loadClientState(firstState.key) == firstState)
        #expect(try await reopened.loadClientState(secondState.key) == secondState)
        #expect(try await reopened.loadClientState(ClientWorkspaceStateKey(
            deviceID: DeviceID(),
            windowID: windowID,
            workspaceContextID: .project(project.id)
        )) == nil)
    }
}

@Test func clientWorkspaceStateSaveValidatesAndUpsertsOneExactKey() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let state = try makeWorkspaceState(
            deviceID: DeviceID(), windowID: WindowID(), contextID: .project(ProjectID()),
            documentID: DocumentID(), tabID: TabID(), cursorLine: 2,
            collapsed: false, leadingWidth: 200, trailingWidth: 300, scroll: 4
        )
        try await repository.saveClientState(state)
        var replacement = state
        replacement.sidebar.isCollapsed = true
        replacement.splitView.leadingPaneWidth = 250
        try await repository.saveClientState(replacement)

        let inspection = try SQLiteConnection(databaseURL: databaseURL)
        #expect(try await inspection.integerValue(for: "SELECT COUNT(*) FROM client_workspace_states") == 1)
        #expect(try await repository.loadClientState(state.key) == replacement)

        var invalid = state
        invalid.tabs.append(state.tabs[0])
        await #expect(throws: CockpitDomainValidationError.duplicateTabID) {
            try await repository.saveClientState(invalid)
        }
        #expect(try await inspection.integerValue(for: "SELECT COUNT(*) FROM client_workspace_states") == 1)
    }
}

@Test func clientWorkspaceStateLoadRejectsSQLJSONKeyMismatchAndMalformedStoredValues() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let requestedKey = ClientWorkspaceStateKey(
            deviceID: DeviceID(),
            windowID: WindowID(),
            workspaceContextID: .project(ProjectID())
        )
        let otherState = try makeWorkspaceState(
            deviceID: requestedKey.deviceID,
            windowID: requestedKey.windowID,
            contextID: .project(ProjectID()),
            documentID: DocumentID(), tabID: TabID(), cursorLine: 2,
            collapsed: false, leadingWidth: 200, trailingWidth: 300, scroll: 4
        )
        let inspection = try SQLiteConnection(databaseURL: databaseURL)

        try await replaceStoredState(
            connection: inspection,
            key: requestedKey,
            storedValue: .blob(try JSONEncoder().encode(otherState))
        )
        await #expect(throws: WorkspaceRepositoryError.invalidStoredValue) {
            _ = try await repository.loadClientState(requestedKey)
        }

        try await replaceStoredState(connection: inspection, key: requestedKey, storedValue: .blob(Data([0xFF])))
        await #expect(throws: WorkspaceRepositoryError.invalidStoredValue) {
            _ = try await repository.loadClientState(requestedKey)
        }

        try await replaceStoredState(connection: inspection, key: requestedKey, storedValue: .text("{"))
        await #expect(throws: WorkspaceRepositoryError.invalidStoredValue) {
            _ = try await repository.loadClientState(requestedKey)
        }

        let valid = try makeWorkspaceState(
            deviceID: requestedKey.deviceID,
            windowID: requestedKey.windowID,
            contextID: requestedKey.workspaceContextID,
            documentID: DocumentID(), tabID: TabID(), cursorLine: 2,
            collapsed: false, leadingWidth: 200, trailingWidth: 300, scroll: 4
        )
        let validData = try JSONEncoder().encode(valid)
        var object = try #require(JSONSerialization.jsonObject(with: validData) as? [String: Any])
        var split = try #require(object["splitView"] as? [String: Any])
        split["trailingPaneWidth"] = -1
        object["splitView"] = split
        try await replaceStoredState(
            connection: inspection,
            key: requestedKey,
            storedValue: .blob(try JSONSerialization.data(withJSONObject: object))
        )
        await #expect(throws: WorkspaceRepositoryError.invalidStoredValue) {
            _ = try await repository.loadClientState(requestedKey)
        }
    }
}

@Test func documentLocatorRelocationIsAtomicEnvironmentScopedAndPreservesDocumentAndTabState() async throws {
    try await withRepositoryDatabase { databaseURL in
        let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let project = try await repository.createProjectWithDirectEnvironment(makeProjectInput())
        let otherEnvironmentID = EnvironmentID()
        let exactID = DocumentID()
        let descendantID = DocumentID()
        let siblingID = DocumentID()
        let otherEnvironmentDocumentID = DocumentID()
        let state = try makeWorkspaceState(
            deviceID: DeviceID(), windowID: WindowID(), contextID: .project(project.id),
            documentID: exactID, tabID: TabID(), cursorLine: 9,
            collapsed: false, leadingWidth: 240, trailingWidth: 360, scroll: 15
        )
        try await repository.saveClientState(state)
        let inspection = try SQLiteConnection(databaseURL: databaseURL)
        try await inspection.withImmediateTransaction { connection in
            try connection.execute(
                """
                INSERT INTO environments (
                    id, project_id, kind, workspace_root, workspace_root_identity,
                    git_common_directory, worktree_branch
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(otherEnvironmentID.description), .text(project.id.description),
                    .text("worktree"), .text("/other"), .text("identity:other"), .null, .text("other"),
                ]
            )
            try insertDocument(
                connection: connection, id: exactID, environmentID: project.baseEnvironmentID,
                path: "old", documentVersion: 11, persistedVersion: 7,
                dirtyState: "dirty", editLeaseID: "lease-exact"
            )
            try insertDocument(
                connection: connection, id: descendantID, environmentID: project.baseEnvironmentID,
                path: "old/child.txt", documentVersion: 5, persistedVersion: 5,
                dirtyState: "clean", editLeaseID: nil
            )
            try insertDocument(
                connection: connection, id: siblingID, environmentID: project.baseEnvironmentID,
                path: "oldish/unchanged.txt", documentVersion: 3, persistedVersion: 2,
                dirtyState: "conflict", editLeaseID: "lease-sibling"
            )
            try insertDocument(
                connection: connection, id: otherEnvironmentDocumentID, environmentID: otherEnvironmentID,
                path: "old/other.txt", documentVersion: 13, persistedVersion: 8,
                dirtyState: "missing", editLeaseID: nil
            )
        }
        let stateJSONBefore = try await storedStateJSON(connection: inspection)

        try await inspection.execute(
            """
            CREATE TRIGGER reject_descendant_relocation
            BEFORE UPDATE OF relative_path ON documents
            WHEN OLD.relative_path = 'old/child.txt'
            BEGIN
                SELECT RAISE(ABORT, 'reject descendant relocation');
            END
            """
        )
        await #expect(throws: (any Error).self) {
            try await repository.relocateDocumentLocators(
                in: project.baseEnvironmentID,
                from: RelativePath("old"),
                to: RelativePath("failed")
            )
        }
        #expect(try await storedDocumentPath(connection: inspection, id: exactID) == "old")
        #expect(try await storedDocumentPath(connection: inspection, id: descendantID) == "old/child.txt")
        try await inspection.execute("DROP TRIGGER reject_descendant_relocation")

        try await repository.relocateDocumentLocators(
            in: project.baseEnvironmentID,
            from: RelativePath("old"),
            to: RelativePath("new")
        )

        let rows = try await inspection.query(
            """
            SELECT id, environment_id, relative_path, document_version,
                   persisted_version, dirty_state, edit_lease_id
            FROM documents
            ORDER BY id
            """
        )
        let actual = rows.map(documentRow)
        #expect(actual.contains(.init(
            id: exactID.description, environmentID: project.baseEnvironmentID.description,
            path: "new", documentVersion: 11, persistedVersion: 7,
            dirtyState: "dirty", editLeaseID: "lease-exact"
        )))
        #expect(actual.contains(.init(
            id: descendantID.description, environmentID: project.baseEnvironmentID.description,
            path: "new/child.txt", documentVersion: 5, persistedVersion: 5,
            dirtyState: "clean", editLeaseID: nil
        )))
        #expect(actual.contains(.init(
            id: siblingID.description, environmentID: project.baseEnvironmentID.description,
            path: "oldish/unchanged.txt", documentVersion: 3, persistedVersion: 2,
            dirtyState: "conflict", editLeaseID: "lease-sibling"
        )))
        #expect(actual.contains(.init(
            id: otherEnvironmentDocumentID.description, environmentID: otherEnvironmentID.description,
            path: "old/other.txt", documentVersion: 13, persistedVersion: 8,
            dirtyState: "missing", editLeaseID: nil
        )))
        #expect(try await storedStateJSON(connection: inspection) == stateJSONBefore)
        #expect(try await repository.loadClientState(state.key) == state)
    }
}

private func makeProjectInput() -> NewProject {
    NewProject(
        displayName: "Cockpit",
        rootBookmark: Data([0x01, 0x02, 0x03]),
        canonicalRootIdentity: "file-id:cockpit",
        workspaceRoot: "/Users/example/Cockpit",
        gitCommonDirectory: "/Users/example/Cockpit/.git"
    )
}

private struct StoredDocumentRow: Equatable {
    let id: String
    let environmentID: String
    let path: String
    let documentVersion: Int64
    let persistedVersion: Int64
    let dirtyState: String
    let editLeaseID: String?
}

private func documentRow(_ columns: [SQLiteColumn]) -> StoredDocumentRow {
    func text(_ index: Int) -> String {
        guard case let .text(value) = columns[index] else { fatalError("Expected text column") }
        return value
    }
    func integer(_ index: Int) -> Int64 {
        guard case let .integer(value) = columns[index] else { fatalError("Expected integer column") }
        return value
    }
    let lease: String?
    if case let .text(value) = columns[6] { lease = value } else { lease = nil }
    return StoredDocumentRow(
        id: text(0), environmentID: text(1), path: text(2),
        documentVersion: integer(3), persistedVersion: integer(4),
        dirtyState: text(5), editLeaseID: lease
    )
}

private func insertDocument(
    connection: isolated SQLiteConnection,
    id: DocumentID,
    environmentID: EnvironmentID,
    path: String,
    documentVersion: Int64,
    persistedVersion: Int64,
    dirtyState: String,
    editLeaseID: String?
) throws {
    try connection.execute(
        """
        INSERT INTO documents (
            id, environment_id, relative_path, document_version,
            persisted_version, dirty_state, edit_lease_id
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        bindings: [
            .text(id.description), .text(environmentID.description), .text(path),
            .integer(documentVersion), .integer(persistedVersion), .text(dirtyState),
            editLeaseID.map(SQLiteValue.text) ?? .null,
        ]
    )
}

private func storedDocumentPath(
    connection: SQLiteConnection,
    id: DocumentID
) async throws -> String? {
    let rows = try await connection.query(
        "SELECT relative_path FROM documents WHERE id = ?",
        bindings: [.text(id.description)]
    )
    guard let value = rows.first?.first, case let .text(path) = value else { return nil }
    return path
}

private func storedStateJSON(connection: SQLiteConnection) async throws -> Data? {
    let rows = try await connection.query(
        "SELECT CAST(state_json AS BLOB) FROM client_workspace_states"
    )
    guard let value = rows.first?.first, case let .blob(data) = value else { return nil }
    return data
}

private func makeWorkspaceState(
    deviceID: DeviceID,
    windowID: WindowID,
    contextID: WorkspaceContextID,
    documentID: DocumentID,
    tabID: TabID,
    cursorLine: UInt64,
    collapsed: Bool,
    leadingWidth: Double,
    trailingWidth: Double,
    scroll: Double
) throws -> ClientWorkspaceState {
    let cursor = try TextPosition(validatingLine: cursorLine, column: 2)
    let selection = try TextRange(
        validatingAnchor: cursor,
        active: TextPosition(validatingLine: cursorLine, column: 8)
    )
    let tab = try TabRecord(
        validatingID: tabID,
        resource: .file(documentID),
        fileViewState: DocumentViewState(
            validatingCursor: cursor,
            selections: [selection],
            firstVisibleLine: cursorLine,
            horizontalScrollOffset: scroll
        )
    )
    return try ClientWorkspaceState(
        validatingKey: ClientWorkspaceStateKey(
            deviceID: deviceID,
            windowID: windowID,
            workspaceContextID: contextID
        ),
        tabs: [tab],
        selectedTabID: tabID,
        sidebar: SidebarState(isCollapsed: collapsed),
        splitView: SplitViewState(
            validatingLeadingPaneWidth: leadingWidth,
            trailingPaneWidth: trailingWidth
        )
    )
}

private func replaceStoredState(
    connection: SQLiteConnection,
    key: ClientWorkspaceStateKey,
    storedValue: SQLiteValue
) async throws {
    let context: (kind: String, id: String)
    switch key.workspaceContextID {
    case let .project(id): context = ("project", id.description)
    case let .conversation(id): context = ("conversation", id.description)
    }
    try await connection.execute("DELETE FROM client_workspace_states")
    try await connection.execute(
        """
        INSERT INTO client_workspace_states (
            device_id, window_id, context_kind, context_id, state_json
        ) VALUES (?, ?, ?, ?, ?)
        """,
        bindings: [
            .text(key.deviceID.description),
            .text(key.windowID.description),
            .text(context.kind),
            .text(context.id),
            storedValue,
        ]
    )
}

private func seedConversationsAndClose(databaseURL: URL) async throws -> [Conversation] {
    let repository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
    let project = try await repository.createProjectWithDirectEnvironment(makeProjectInput())
    let active = try await repository.createConversation(
        NewConversation(projectID: project.id, title: "Active")
    )
    let deleting = try await repository.createConversation(
        NewConversation(projectID: project.id, title: "Deleting")
    )
    let deletionOperationID = DeletionOperationID()
    let inspectionConnection = try SQLiteConnection(databaseURL: databaseURL)
    try await inspectionConnection.withImmediateTransaction { connection in
        try connection.execute(
            """
            UPDATE conversations
            SET lifecycle_state = ?, deletion_phase = ?, deletion_operation_id = ?
            WHERE id = ?
            """,
            bindings: [
                .text("deleting"),
                .text("removing-workspace"),
                .text(deletionOperationID.description),
                .text(deleting.id.description),
            ]
        )
    }
    #expect(await inspectionConnection.close() == SQLITE_OK)
    #expect(await repository.close() == SQLITE_OK)

    return [
        active,
        Conversation(
            id: deleting.id,
            projectID: deleting.projectID,
            environmentID: deleting.environmentID,
            title: deleting.title,
            lifecycleState: .deleting(phase: "removing-workspace"),
            deletionOperationID: deletionOperationID,
            createdAt: deleting.createdAt
        ),
    ].sorted(by: conversationOrder)
}

private func conversationOrder(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
    if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
    return lhs.id.description < rhs.id.description
}

private func isSQLiteNull(_ column: SQLiteColumn?) -> Bool {
    guard let column, case .null = column else { return false }
    return true
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}

private func withRepositoryDatabase(
    _ body: (URL) async throws -> Void
) async throws {
    let directory = URL(
        fileURLWithPath: "/private/tmp/cockpit-workspace-repository-tests.\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appendingPathComponent("workspace.sqlite"))
}
