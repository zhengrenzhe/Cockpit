import AppKit
import CockpitHostCore
import CockpitTypes

struct ProjectDirectorySelection: Equatable, Sendable {
    let bookmark: Data
    let displayName: String
}

typealias ProjectDirectoryPicker = @MainActor @Sendable () async throws
    -> ProjectDirectorySelection?
typealias ProjectCreatedObserver = @MainActor @Sendable (ProjectSnapshot) async throws -> Void
typealias ProjectContextSelector = @MainActor @Sendable (WorkspaceContextID) async throws -> Void

@MainActor
final class ProjectCommandController {
    private let workspaceService: any WorkspaceServing
    private let directoryPicker: ProjectDirectoryPicker
    private let projectCreated: ProjectCreatedObserver
    private let selectContext: ProjectContextSelector

    init(
        workspaceService: any WorkspaceServing,
        directoryPicker: @escaping ProjectDirectoryPicker,
        projectCreated: @escaping ProjectCreatedObserver = { _ in },
        selectContext: @escaping ProjectContextSelector
    ) {
        self.workspaceService = workspaceService
        self.directoryPicker = directoryPicker
        self.projectCreated = projectCreated
        self.selectContext = selectContext
    }

    func addProject() async throws -> ProjectSnapshot? {
        guard let selection = try await directoryPicker() else { return nil }
        let project = try await workspaceService.addProject(
            bookmark: selection.bookmark,
            displayName: selection.displayName
        )
        try await projectCreated(project)
        try await selectContext(project.resolvedContext.contextID)
        return project
    }

    static func appKitDirectoryPicker() async throws -> ProjectDirectorySelection? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return ProjectDirectorySelection(
            bookmark: try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ),
            displayName: url.lastPathComponent
        )
    }
}
