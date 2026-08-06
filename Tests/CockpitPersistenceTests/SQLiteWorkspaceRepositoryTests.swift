import Foundation
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

        let reopenedRepository = try await SQLiteWorkspaceRepository(databaseURL: databaseURL)
        let reopenedProjects = try await reopenedRepository.listProjects()
        let reopenedProjectResolution = try await reopenedRepository.resolve(.project(createdProject.id))
        let reopenedConversationResolution = try await reopenedRepository.resolve(.conversation(createdConversation.id))
        let inspectionConnection = try SQLiteConnection(databaseURL: databaseURL)

        #expect(reopenedProjects == [createdProject])
        #expect(reopenedProjectResolution == projectResolution)
        #expect(reopenedConversationResolution == conversationResolution)
        #expect(try await inspectionConnection.textValue(for: "SELECT title FROM conversations") == "Renamed")
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
