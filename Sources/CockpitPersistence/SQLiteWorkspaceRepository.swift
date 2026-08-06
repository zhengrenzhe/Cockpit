import Foundation
import CockpitHostCore
import CockpitTypes

public actor SQLiteWorkspaceRepository: WorkspaceRepository {
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
                WHERE c.id = ?
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
