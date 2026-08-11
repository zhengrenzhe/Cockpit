import Foundation
import CockpitHostCore
import CockpitProtocol
import CockpitTypes

public actor SQLiteWorkspaceRepository: WorkspaceRepository, DocumentMetadataRepository {
    private let connection: SQLiteConnection

    public init(databaseURL: URL) async throws {
        let connection = try SQLiteConnection(databaseURL: databaseURL)
        try await connection.applyMigrations(WorkspaceMigrations.all)
        self.connection = connection
    }

    func close() async -> Int32 {
        await connection.close()
    }

    public func createProjectWithDirectEnvironment(_ input: NewProject) async throws -> Project {
        let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
        let project = Project(
            id: ProjectID(),
            displayName: input.displayName,
            rootBookmark: input.rootBookmark,
            canonicalRootIdentity: input.canonicalRootIdentity,
            baseEnvironmentID: EnvironmentID(),
            createdAt: createdAt
        )

        try await connection.withImmediateTransaction { connection in
            let rows = try connection.query("SELECT COUNT(*) FROM projects")
            guard rows.first?.first?.integer == 0 else {
                throw WorkspaceRepositoryError.phaseOneProjectLimit
            }
            try connection.execute(
                """
                INSERT INTO projects (
                    id, display_name, root_bookmark, canonical_root_identity,
                    base_environment_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(project.id.description),
                    .text(project.displayName),
                    .blob(project.rootBookmark),
                    .text(project.canonicalRootIdentity),
                    .text(project.baseEnvironmentID.description),
                    .real(project.createdAt.timeIntervalSince1970),
                ]
            )
            try connection.execute(
                """
                INSERT INTO environments (
                    id, project_id, kind, workspace_root, workspace_root_identity,
                    git_common_directory, worktree_branch
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(project.baseEnvironmentID.description),
                    .text(project.id.description),
                    .text(Environment.Kind.direct.rawValue),
                    .text(input.workspaceRoot),
                    .text(input.canonicalRootIdentity),
                    input.gitCommonDirectory.map { .text($0) } ?? .null,
                    .null,
                ]
            )
        }
        return project
    }

    public func listProjects() async throws -> [Project] {
        let rows = try await connection.query(
            """
            SELECT id, display_name, root_bookmark, canonical_root_identity,
                   base_environment_id, created_at
            FROM projects
            ORDER BY created_at, id
            """
        )
        return try rows.map(Self.project(from:))
    }

    public func createConversation(_ input: NewConversation) async throws -> Conversation {
        try await connection.withImmediateTransaction { connection in
            let projectRows = try connection.query(
                "SELECT base_environment_id FROM projects WHERE id = ?",
                bindings: [.text(input.projectID.description)]
            )
            guard let environmentText = projectRows.first?.first?.text,
                  let environmentUUID = UUID(uuidString: environmentText)
            else {
                throw WorkspaceRepositoryError.projectNotFound
            }

            let createdAt = Date(timeIntervalSince1970: Date().timeIntervalSince1970)
            let conversation = Conversation(
                id: ConversationID(),
                projectID: input.projectID,
                environmentID: EnvironmentID(environmentUUID),
                title: input.title,
                lifecycleState: .active,
                deletionOperationID: nil,
                createdAt: createdAt
            )
            try connection.execute(
                """
                INSERT INTO conversations (
                    id, project_id, environment_id, title, lifecycle_state,
                    deletion_phase, deletion_operation_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(conversation.id.description),
                    .text(conversation.projectID.description),
                    .text(conversation.environmentID.description),
                    .text(conversation.title),
                    .text("active"),
                    .null,
                    .null,
                    .real(conversation.createdAt.timeIntervalSince1970),
                ]
            )
            return conversation
        }
    }

    public func listConversations(projectID: ProjectID) async throws -> [Conversation] {
        let rows = try await connection.query(
            """
            SELECT id, project_id, environment_id, title, lifecycle_state,
                   deletion_phase, deletion_operation_id, created_at
            FROM conversations
            WHERE project_id = ?
            ORDER BY created_at, id
            """,
            bindings: [.text(projectID.description)]
        )
        return try rows.map(Self.conversation(from:))
    }

    public func renameConversation(id: ConversationID, title: String) async throws {
        try await connection.withImmediateTransaction { connection in
            guard try !connection.query(
                "SELECT 1 FROM conversations WHERE id = ?",
                bindings: [.text(id.description)]
            ).isEmpty else {
                throw WorkspaceRepositoryError.conversationNotFound
            }
            try connection.execute(
                "UPDATE conversations SET title = ? WHERE id = ?",
                bindings: [.text(title), .text(id.description)]
            )
        }
    }

    public func resolve(_ contextID: WorkspaceContextID) async throws -> ResolvedWorkspaceContext {
        switch contextID {
        case let .project(projectID):
            let rows = try await connection.query(
                """
                SELECT p.base_environment_id, e.workspace_root_identity
                FROM projects AS p
                JOIN environments AS e ON e.id = p.base_environment_id AND e.project_id = p.id
                WHERE p.id = ?
                """,
                bindings: [.text(projectID.description)]
            )
            guard let row = rows.first,
                  let environmentID = Self.environmentID(row[safe: 0]),
                  let workspaceRootIdentity = row[safe: 1]?.text
            else {
                throw WorkspaceRepositoryError.projectNotFound
            }
            return try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: projectID,
                conversationID: nil,
                environmentID: environmentID,
                workspaceRootIdentity: workspaceRootIdentity
            )

        case let .conversation(conversationID):
            let rows = try await connection.query(
                """
                SELECT c.project_id, c.environment_id, e.workspace_root_identity
                FROM conversations AS c
                JOIN environments AS e ON e.id = c.environment_id AND e.project_id = c.project_id
                WHERE c.id = ? AND c.lifecycle_state = 'active'
                """,
                bindings: [.text(conversationID.description)]
            )
            guard let row = rows.first,
                  let projectID = Self.projectID(row[safe: 0]),
                  let environmentID = Self.environmentID(row[safe: 1]),
                  let workspaceRootIdentity = row[safe: 2]?.text
            else {
                throw WorkspaceRepositoryError.conversationNotFound
            }
            return try ResolvedWorkspaceContext(
                validating: contextID,
                projectID: projectID,
                conversationID: conversationID,
                environmentID: environmentID,
                workspaceRootIdentity: workspaceRootIdentity
            )
        }
    }

    public func loadClientState(
        _ key: ClientWorkspaceStateKey
    ) async throws -> ClientWorkspaceState? {
        let context = Self.storageContext(key.workspaceContextID)
        let rows = try await connection.query(
            """
            SELECT device_id, window_id, context_kind, context_id,
                   CAST(state_json AS BLOB)
            FROM client_workspace_states
            WHERE device_id = ? AND window_id = ?
              AND context_kind = ? AND context_id = ?
            """,
            bindings: [
                .text(key.deviceID.description),
                .text(key.windowID.description),
                .text(context.kind),
                .text(context.id),
            ]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              row[safe: 0]?.text == key.deviceID.description,
              row[safe: 1]?.text == key.windowID.description,
              row[safe: 2]?.text == context.kind,
              row[safe: 3]?.text == context.id,
              let data = row[safe: 4]?.blob,
              String(data: data, encoding: .utf8) != nil
        else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
        do {
            let state = try JSONDecoder().decode(ClientWorkspaceState.self, from: data)
            let valid = try state.validated()
            guard valid.key == key else {
                throw WorkspaceRepositoryError.invalidStoredValue
            }
            return valid
        } catch let error as WorkspaceRepositoryError {
            throw error
        } catch {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
    }

    public func saveClientState(_ state: ClientWorkspaceState) async throws {
        let valid = try state.validated()
        let data = try JSONEncoder().encode(valid)
        guard let json = String(data: data, encoding: .utf8) else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
        let context = Self.storageContext(valid.key.workspaceContextID)
        try await connection.withImmediateTransaction { connection in
            if case let .conversation(conversationID) = valid.key.workspaceContextID {
                let active = try connection.query(
                    "SELECT 1 FROM conversations WHERE id = ? AND lifecycle_state = 'active'",
                    bindings: [.text(conversationID.description)]
                )
                guard active.count == 1 else {
                    throw WorkspaceRepositoryError.conversationNotFound
                }
            }
            try connection.execute(
                """
                INSERT INTO client_workspace_states (
                    device_id, window_id, context_kind, context_id, state_json
                ) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (device_id, window_id, context_kind, context_id)
                DO UPDATE SET state_json = excluded.state_json
                """,
                bindings: [
                    .text(valid.key.deviceID.description),
                    .text(valid.key.windowID.description),
                    .text(context.kind),
                    .text(context.id),
                    .text(json),
                ]
            )
        }
    }

    public func allClientStates() async throws -> [ClientWorkspaceState] {
        let rows = try await connection.query(
            """
            SELECT s.device_id, s.window_id, s.context_kind, s.context_id,
                   CAST(s.state_json AS BLOB)
            FROM client_workspace_states AS s
            WHERE s.context_kind != 'conversation'
               OR EXISTS (
                    SELECT 1 FROM conversations AS c
                    WHERE c.id = s.context_id AND c.lifecycle_state = 'active'
               )
            ORDER BY s.device_id, s.window_id, s.context_kind, s.context_id
            """
        )
        return try rows.map(Self.clientState(from:))
    }

    public func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID
    ) async throws -> ConversationDeletionOperation {
        try await beginConversationDeletion(
            conversationID: conversationID,
            operationID: operationID,
            persistedViewerExpectation: nil
        )
    }

    public func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        targetContextID: WorkspaceContextID,
        relevantDocumentIDs: Set<DocumentID>,
        expectedPersistedViewers: Set<ConversationDeletionPersistedViewer>
    ) async throws -> ConversationDeletionOperation {
        try await beginConversationDeletion(
            conversationID: conversationID,
            operationID: operationID,
            persistedViewerExpectation: (
                targetContextID,
                relevantDocumentIDs,
                expectedPersistedViewers
            )
        )
    }

    private func beginConversationDeletion(
        conversationID: ConversationID,
        operationID: DeletionOperationID,
        persistedViewerExpectation: (
            targetContextID: WorkspaceContextID,
            relevantDocumentIDs: Set<DocumentID>,
            viewers: Set<ConversationDeletionPersistedViewer>
        )?
    ) async throws -> ConversationDeletionOperation {
        try await connection.withImmediateTransaction { connection in
            if let existing = try Self.loadDeletion(
                connection: connection,
                operationID: operationID
            ) {
                guard existing.conversationID == conversationID else {
                    throw ConversationDeletionError.operationMismatch
                }
                return existing
            }
            if try !connection.query(
                "SELECT 1 FROM conversation_deletions WHERE conversation_id = ?",
                bindings: [.text(conversationID.description)]
            ).isEmpty {
                throw ConversationDeletionError.operationMismatch
            }
            let rows = try connection.query(
                """
                SELECT project_id, environment_id, lifecycle_state
                FROM conversations WHERE id = ?
                """,
                bindings: [.text(conversationID.description)]
            )
            guard rows.count == 1,
                  let projectID = Self.projectID(rows[0][safe: 0]),
                  let environmentID = Self.environmentID(rows[0][safe: 1]),
                  rows[0][safe: 2]?.text == "active" else {
                throw WorkspaceRepositoryError.conversationNotFound
            }
            if let expectation = persistedViewerExpectation {
                let stateRows = try connection.query(
                    """
                    SELECT s.device_id, s.window_id, s.context_kind, s.context_id,
                           CAST(s.state_json AS BLOB)
                    FROM client_workspace_states AS s
                    WHERE s.context_kind != 'conversation'
                       OR EXISTS (
                            SELECT 1 FROM conversations AS c
                            WHERE c.id = s.context_id AND c.lifecycle_state = 'active'
                       )
                    ORDER BY s.device_id, s.window_id, s.context_kind, s.context_id
                    """
                )
                let states = try stateRows.map(Self.clientState(from:))
                let actual = Set(states.flatMap { state in
                    state.tabs.compactMap { tab -> ConversationDeletionPersistedViewer? in
                        guard case let .file(documentID) = tab.resource,
                              state.key.workspaceContextID == expectation.targetContextID
                                || expectation.relevantDocumentIDs.contains(documentID) else {
                            return nil
                        }
                        return ConversationDeletionPersistedViewer(
                            documentID: documentID,
                            contextID: state.key.workspaceContextID
                        )
                    }
                })
                guard actual == expectation.viewers else {
                    throw ConversationDeletionError.stalePreparation
                }
            }
            let operation = ConversationDeletionOperation(
                operationID: operationID,
                conversationID: conversationID,
                projectID: projectID,
                environmentID: environmentID,
                phase: .deleting
            )
            try connection.execute(
                """
                INSERT INTO conversation_deletions (
                    operation_id, conversation_id, project_id, environment_id, phase
                ) VALUES (?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(operationID.description),
                    .text(conversationID.description),
                    .text(projectID.description),
                    .text(environmentID.description),
                    .text(Self.storagePhase(.deleting)),
                ]
            )
            try connection.execute(
                """
                UPDATE conversations
                SET lifecycle_state = 'deleting', deletion_phase = ?, deletion_operation_id = ?
                WHERE id = ?
                """,
                bindings: [
                    .text(Self.storagePhase(.deleting)),
                    .text(operationID.description),
                    .text(conversationID.description),
                ]
            )
            return operation
        }
    }

    public func conversationDeletion(
        operationID: DeletionOperationID
    ) async throws -> ConversationDeletionOperation? {
        try await connection.withImmediateTransaction { connection in
            try Self.loadDeletion(connection: connection, operationID: operationID)
        }
    }

    public func advanceConversationDeletion(
        operationID: DeletionOperationID,
        from expected: ConversationDeletionPhase,
        to phase: ConversationDeletionPhase
    ) async throws -> ConversationDeletionOperation {
        try await connection.withImmediateTransaction { connection in
            guard let current = try Self.loadDeletion(
                connection: connection,
                operationID: operationID
            ) else {
                throw ConversationDeletionError.operationMismatch
            }
            if current.phase == phase { return current }
            guard current.phase == expected, phase.rawValue == expected.rawValue + 1 else {
                throw ConversationDeletionError.operationMismatch
            }
            try connection.execute(
                "UPDATE conversation_deletions SET phase = ? WHERE operation_id = ?",
                bindings: [.text(Self.storagePhase(phase)), .text(operationID.description)]
            )
            try connection.execute(
                "UPDATE conversations SET deletion_phase = ? WHERE id = ? AND deletion_operation_id = ?",
                bindings: [
                    .text(Self.storagePhase(phase)),
                    .text(current.conversationID.description),
                    .text(operationID.description),
                ]
            )
            return ConversationDeletionOperation(
                operationID: current.operationID,
                conversationID: current.conversationID,
                projectID: current.projectID,
                environmentID: current.environmentID,
                phase: phase
            )
        }
    }

    public func finishConversationDeletion(
        operationID: DeletionOperationID
    ) async throws {
        try await connection.withImmediateTransaction { connection in
            guard let current = try Self.loadDeletion(
                connection: connection,
                operationID: operationID
            ) else {
                throw ConversationDeletionError.operationMismatch
            }
            if current.phase == .deleted { return }
            guard current.phase == .removingClientState else {
                throw ConversationDeletionError.operationMismatch
            }
            let context = Self.storageContext(.conversation(current.conversationID))
            try connection.execute(
                "DELETE FROM client_workspace_states WHERE context_kind = ? AND context_id = ?",
                bindings: [.text(context.kind), .text(context.id)]
            )
            try connection.execute(
                "DELETE FROM conversations WHERE id = ? AND deletion_operation_id = ?",
                bindings: [
                    .text(current.conversationID.description),
                    .text(operationID.description),
                ]
            )
            try connection.execute(
                "UPDATE conversation_deletions SET phase = ? WHERE operation_id = ?",
                bindings: [.text(Self.storagePhase(.deleted)), .text(operationID.description)]
            )
        }
    }

    public func findOrCreateDocument(
        in environmentID: EnvironmentID,
        at path: RelativePath
    ) async throws -> DocumentMetadata {
        let path = try validatedLocatorPath(path)
        return try await connection.withImmediateTransaction { connection in
            let rows = try connection.query(
                """
                SELECT id, environment_id, relative_path, document_version,
                       persisted_version, dirty_state, edit_lease_id
                FROM documents WHERE environment_id = ? AND relative_path = ?
                """,
                bindings: [.text(environmentID.description), .text(path.string)]
            )
            if let row = rows.first { return try Self.documentMetadata(from: row) }
            let metadata = try DocumentMetadata(
                validatingDocumentID: DocumentID(),
                environmentID: environmentID,
                relativePath: path,
                documentVersion: 0,
                persistedVersion: 0,
                dirtyState: .clean,
                editLeaseID: nil
            )
            try connection.execute(
                """
                INSERT INTO documents (
                    id, environment_id, relative_path, document_version,
                    persisted_version, dirty_state, edit_lease_id
                ) VALUES (?, ?, ?, 0, 0, 'clean', NULL)
                """,
                bindings: [
                    .text(metadata.documentID.description),
                    .text(environmentID.description),
                    .text(path.string),
                ]
            )
            return metadata
        }
    }

    public func loadDocument(id: DocumentID) async throws -> DocumentMetadata? {
        let rows = try await connection.query(
            """
            SELECT id, environment_id, relative_path, document_version,
                   persisted_version, dirty_state, edit_lease_id
            FROM documents WHERE id = ?
            """,
            bindings: [.text(id.description)]
        )
        guard let row = rows.first else { return nil }
        return try Self.documentMetadata(from: row)
    }

    public func compareAndSetDocumentMetadata(
        _ metadata: DocumentMetadata,
        expectedDocumentVersion: UInt64,
        expectedEditLeaseID: EditLeaseID?
    ) async throws {
        try Self.validateCounters(metadata)
        try await connection.withImmediateTransaction { connection in
            let rows = try connection.query(
                """
                SELECT id, environment_id, relative_path, document_version,
                       persisted_version, dirty_state, edit_lease_id
                FROM documents WHERE id = ?
                """,
                bindings: [.text(metadata.documentID.description)]
            )
            guard let row = rows.first else { throw DocumentMetadataRepositoryError.stale }
            let current = try Self.documentMetadata(from: row)
            guard current.documentVersion == expectedDocumentVersion,
                  current.editLeaseID == expectedEditLeaseID,
                  current.environmentID == metadata.environmentID,
                  current.relativePath == metadata.relativePath
            else { throw DocumentMetadataRepositoryError.stale }
            try Self.updateDocumentMetadata(metadata, connection: connection)
        }
    }

    public func repairDocumentMetadata(_ metadata: DocumentMetadata) async throws {
        try Self.validateCounters(metadata)
        try await connection.withImmediateTransaction { connection in
            let rows = try connection.query(
                "SELECT environment_id, relative_path FROM documents WHERE id = ?",
                bindings: [.text(metadata.documentID.description)]
            )
            guard rows.count == 1,
                  rows[0][safe: 0]?.text == metadata.environmentID.description,
                  rows[0][safe: 1]?.text == metadata.relativePath.string
            else { throw DocumentMetadataRepositoryError.stale }
            try Self.updateDocumentMetadata(metadata, connection: connection)
        }
    }

    public func relocateDocumentLocators(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) async throws {
        let validSource: RelativePath
        let validDestination: RelativePath
        do {
            guard !source.string.contains("\0"), !destination.string.contains("\0") else {
                throw FileOperationError.invalidPath
            }
            validSource = try RelativePath(source.string)
            validDestination = try RelativePath(destination.string)
        } catch let error as FileOperationError {
            throw error
        } catch {
            throw FileOperationError.invalidPath
        }

        try await connection.withImmediateTransaction { connection in
            let rows = try connection.query(
                "SELECT id, relative_path FROM documents WHERE environment_id = ? ORDER BY id",
                bindings: [.text(environmentID.description)]
            )
            for row in rows {
                guard let id = row[safe: 0]?.text,
                      let storedText = row[safe: 1]?.text
                else {
                    throw WorkspaceRepositoryError.invalidStoredValue
                }
                let stored: RelativePath
                do {
                    stored = try RelativePath(storedText)
                } catch {
                    throw WorkspaceRepositoryError.invalidStoredValue
                }
                let relocatedText: String
                if stored.string == validSource.string {
                    relocatedText = validDestination.string
                } else if stored.string.hasPrefix(validSource.string + "/") {
                    relocatedText = validDestination.string + stored.string.dropFirst(validSource.string.count)
                } else {
                    continue
                }
                let relocated: RelativePath
                do {
                    relocated = try RelativePath(relocatedText)
                } catch {
                    throw WorkspaceRepositoryError.invalidStoredValue
                }
                try connection.execute(
                    "UPDATE documents SET relative_path = ? WHERE id = ? AND environment_id = ?",
                    bindings: [
                        .text(relocated.string),
                        .text(id),
                        .text(environmentID.description),
                    ]
                )
            }
        }
    }

    public func preflightDocumentLocatorRelocation(
        in environmentID: EnvironmentID,
        from source: RelativePath,
        to destination: RelativePath
    ) async throws {
        let validSource = try validatedLocatorPath(source)
        let validDestination = try validatedLocatorPath(destination)
        let rows = try await connection.query(
            "SELECT id, relative_path FROM documents WHERE environment_id = ? ORDER BY id",
            bindings: [.text(environmentID.description)]
        )
        var stored: [(id: String, path: RelativePath)] = []
        for row in rows {
            guard let id = row[safe: 0]?.text,
                  let text = row[safe: 1]?.text,
                  let path = try? RelativePath(text)
            else {
                throw WorkspaceRepositoryError.invalidStoredValue
            }
            stored.append((id, path))
        }
        let movingIDs = Set(stored.compactMap { row -> String? in
            row.path.string == validSource.string || row.path.string.hasPrefix(validSource.string + "/")
                ? row.id
                : nil
        })
        let stationaryPaths = Set(stored.compactMap { movingIDs.contains($0.id) ? nil : $0.path.string })
        for row in stored where movingIDs.contains(row.id) {
            let destinationText = row.path.string == validSource.string
                ? validDestination.string
                : validDestination.string + row.path.string.dropFirst(validSource.string.count)
            guard (try? RelativePath(destinationText)) != nil else {
                throw WorkspaceRepositoryError.invalidStoredValue
            }
            if stationaryPaths.contains(destinationText) {
                throw FileOperationError.documentLocatorCollision
            }
        }
    }

    private func validatedLocatorPath(_ path: RelativePath) throws -> RelativePath {
        do {
            guard !path.string.contains("\0") else { throw FileOperationError.invalidPath }
            return try RelativePath(path.string)
        } catch let error as FileOperationError {
            throw error
        } catch {
            throw FileOperationError.invalidPath
        }
    }

    private static func project(from row: [SQLiteColumn]) throws -> Project {
        guard let id = projectID(row[safe: 0]),
              let displayName = row[safe: 1]?.text,
              let rootBookmark = row[safe: 2]?.blob,
              let canonicalRootIdentity = row[safe: 3]?.text,
              let baseEnvironmentID = environmentID(row[safe: 4]),
              let createdAt = row[safe: 5]?.real
        else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
        return Project(
            id: id,
            displayName: displayName,
            rootBookmark: rootBookmark,
            canonicalRootIdentity: canonicalRootIdentity,
            baseEnvironmentID: baseEnvironmentID,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static func conversation(from row: [SQLiteColumn]) throws -> Conversation {
        guard let id = conversationID(row[safe: 0]),
              let projectID = projectID(row[safe: 1]),
              let environmentID = environmentID(row[safe: 2]),
              let title = row[safe: 3]?.text,
              let lifecycleText = row[safe: 4]?.text,
              let createdAt = row[safe: 7]?.real
        else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }

        let lifecycleState: ConversationLifecycleState
        let deletionOperationID: DeletionOperationID?
        switch lifecycleText {
        case "active":
            guard row[safe: 5]?.isNull == true, row[safe: 6]?.isNull == true else {
                throw WorkspaceRepositoryError.invalidStoredValue
            }
            lifecycleState = .active
            deletionOperationID = nil
        case "deleting":
            guard let phase = row[safe: 5]?.text,
                  let operationID = Self.deletionOperationID(row[safe: 6])
            else {
                throw WorkspaceRepositoryError.invalidStoredValue
            }
            lifecycleState = .deleting(phase: phase)
            deletionOperationID = operationID
        default:
            throw WorkspaceRepositoryError.invalidStoredValue
        }

        return Conversation(
            id: id,
            projectID: projectID,
            environmentID: environmentID,
            title: title,
            lifecycleState: lifecycleState,
            deletionOperationID: deletionOperationID,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private static func clientState(from row: [SQLiteColumn]) throws -> ClientWorkspaceState {
        guard row.count == 5,
              let deviceText = row[safe: 0]?.text,
              let deviceUUID = UUID(uuidString: deviceText),
              let windowText = row[safe: 1]?.text,
              let windowUUID = UUID(uuidString: windowText),
              let contextKind = row[safe: 2]?.text,
              let contextUUIDText = row[safe: 3]?.text,
              let contextUUID = UUID(uuidString: contextUUIDText),
              let data = row[safe: 4]?.blob else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
        let contextID: WorkspaceContextID
        switch contextKind {
        case "project": contextID = .project(ProjectID(contextUUID))
        case "conversation": contextID = .conversation(ConversationID(contextUUID))
        default: throw WorkspaceRepositoryError.invalidStoredValue
        }
        do {
            let state = try JSONDecoder().decode(ClientWorkspaceState.self, from: data)
            let valid = try state.validated()
            let expected = ClientWorkspaceStateKey(
                deviceID: DeviceID(deviceUUID),
                windowID: WindowID(windowUUID),
                workspaceContextID: contextID
            )
            guard valid.key == expected else {
                throw WorkspaceRepositoryError.invalidStoredValue
            }
            return valid
        } catch let error as WorkspaceRepositoryError {
            throw error
        } catch {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
    }

    private static func loadDeletion(
        connection: isolated SQLiteConnection,
        operationID: DeletionOperationID
    ) throws -> ConversationDeletionOperation? {
        let rows = try connection.query(
            """
            SELECT operation_id, conversation_id, project_id, environment_id, phase
            FROM conversation_deletions WHERE operation_id = ?
            """,
            bindings: [.text(operationID.description)]
        )
        guard let row = rows.first else { return nil }
        guard rows.count == 1,
              Self.deletionOperationID(row[safe: 0]) == operationID,
              let conversationID = Self.conversationID(row[safe: 1]),
              let projectID = Self.projectID(row[safe: 2]),
              let environmentID = Self.environmentID(row[safe: 3]),
              let phaseText = row[safe: 4]?.text,
              let phase = Self.deletionPhase(phaseText) else {
            throw WorkspaceRepositoryError.invalidStoredValue
        }
        return ConversationDeletionOperation(
            operationID: operationID,
            conversationID: conversationID,
            projectID: projectID,
            environmentID: environmentID,
            phase: phase
        )
    }

    private static func storagePhase(_ phase: ConversationDeletionPhase) -> String {
        switch phase {
        case .deleting: "deleting"
        case .terminatingSessions: "terminatingSessions"
        case .purgingTerminalRecords: "purgingTerminalRecords"
        case .removingClientState: "removingClientState"
        case .deleted: "deleted"
        }
    }

    private static func deletionPhase(_ text: String) -> ConversationDeletionPhase? {
        switch text {
        case "deleting": .deleting
        case "terminatingSessions": .terminatingSessions
        case "purgingTerminalRecords": .purgingTerminalRecords
        case "removingClientState": .removingClientState
        case "deleted": .deleted
        default: nil
        }
    }

    private static func documentMetadata(from row: [SQLiteColumn]) throws -> DocumentMetadata {
        guard let idText = row[safe: 0]?.text,
              let idUUID = UUID(uuidString: idText),
              DocumentID(idUUID).description == idText,
              let environmentText = row[safe: 1]?.text,
              let environmentUUID = UUID(uuidString: environmentText),
              EnvironmentID(environmentUUID).description == environmentText,
              let pathText = row[safe: 2]?.text,
              let path = try? RelativePath(pathText),
              let version = row[safe: 3]?.integer,
              let persisted = row[safe: 4]?.integer,
              version >= 0, persisted >= 0,
              let dirtyText = row[safe: 5]?.text,
              let dirty = DocumentDirtyState(rawValue: dirtyText)
        else { throw WorkspaceRepositoryError.invalidStoredValue }
        let lease: EditLeaseID?
        if row[safe: 6]?.isNull == true {
            lease = nil
        } else {
            guard let leaseText = row[safe: 6]?.text,
                  let leaseUUID = UUID(uuidString: leaseText),
                  EditLeaseID(leaseUUID).description == leaseText
            else { throw WorkspaceRepositoryError.invalidStoredValue }
            lease = EditLeaseID(leaseUUID)
        }
        return try DocumentMetadata(
            validatingDocumentID: DocumentID(idUUID),
            environmentID: EnvironmentID(environmentUUID),
            relativePath: path,
            documentVersion: UInt64(version),
            persistedVersion: UInt64(persisted),
            dirtyState: dirty,
            editLeaseID: lease
        )
    }

    private static func validateCounters(_ metadata: DocumentMetadata) throws {
        guard metadata.documentVersion <= UInt64(Int64.max),
              metadata.persistedVersion <= UInt64(Int64.max)
        else { throw DocumentMetadataRepositoryError.counterOverflow }
    }

    private static func updateDocumentMetadata(
        _ metadata: DocumentMetadata,
        connection: isolated SQLiteConnection
    ) throws {
        try connection.execute(
            """
            UPDATE documents SET document_version = ?, persisted_version = ?,
                dirty_state = ?, edit_lease_id = ? WHERE id = ?
            """,
            bindings: [
                .integer(Int64(metadata.documentVersion)),
                .integer(Int64(metadata.persistedVersion)),
                .text(metadata.dirtyState.rawValue),
                metadata.editLeaseID.map { .text($0.description) } ?? .null,
                .text(metadata.documentID.description),
            ]
        )
    }

    private static func projectID(_ column: SQLiteColumn?) -> ProjectID? {
        guard let text = column?.text, let uuid = UUID(uuidString: text) else { return nil }
        return ProjectID(uuid)
    }

    private static func environmentID(_ column: SQLiteColumn?) -> EnvironmentID? {
        guard let text = column?.text, let uuid = UUID(uuidString: text) else { return nil }
        return EnvironmentID(uuid)
    }

    private static func conversationID(_ column: SQLiteColumn?) -> ConversationID? {
        guard let text = column?.text, let uuid = UUID(uuidString: text) else { return nil }
        return ConversationID(uuid)
    }

    private static func deletionOperationID(_ column: SQLiteColumn?) -> DeletionOperationID? {
        guard let text = column?.text, let uuid = UUID(uuidString: text) else { return nil }
        return DeletionOperationID(uuid)
    }

    private static func storageContext(
        _ contextID: WorkspaceContextID
    ) -> (kind: String, id: String) {
        switch contextID {
        case let .project(id): ("project", id.description)
        case let .conversation(id): ("conversation", id.description)
        }
    }
}

private extension SQLiteColumn {
    var text: String? {
        guard case let .text(value) = self else { return nil }
        return value
    }

    var blob: Data? {
        guard case let .blob(value) = self else { return nil }
        return value
    }

    var real: Double? {
        switch self {
        case let .real(value): value
        case let .integer(value): Double(value)
        default: nil
        }
    }

    var integer: Int64? {
        guard case let .integer(value) = self else { return nil }
        return value
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
