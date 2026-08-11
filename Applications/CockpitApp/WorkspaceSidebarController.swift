import AppKit
import CockpitHostCore
import CockpitTypes

typealias WorkspaceSidebarAddProjectAction = @MainActor @Sendable () async throws -> Void
typealias WorkspaceSidebarCreateConversationAction = @MainActor @Sendable (
    ProjectID
) async throws -> Void
typealias WorkspaceSidebarRenameConversationAction = @MainActor @Sendable (
    ConversationID,
    String
) async throws -> Void
typealias WorkspaceSidebarOpenNewTabAction = @MainActor @Sendable (
    ActiveContext
) async throws -> Void
typealias WorkspaceSidebarErrorPresenter = @MainActor @Sendable (any Error) -> Void

enum WorkspaceSidebarValidationError: Error, LocalizedError, Equatable {
    case emptyConversationTitle

    var errorDescription: String? {
        switch self {
        case .emptyConversationTitle: "Conversation title cannot be empty."
        }
    }
}

@MainActor
private final class WorkspaceConversationTitleField: NSTextField {
    let conversationID: ConversationID
    let originalTitle: String

    init(conversationID: ConversationID, originalTitle: String) {
        self.conversationID = conversationID
        self.originalTitle = originalTitle
        super.init(frame: .zero)
        stringValue = originalTitle
        isEditable = true
        isSelectable = true
        isBordered = false
        drawsBackground = false
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class WorkspaceSidebarController: NSViewController,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    NSTextFieldDelegate
{
    let outlineView = NSOutlineView()
    private weak var viewModel: WorkspaceViewModel?
    private var projects: WorkspaceSnapshot = []
    private var selectableItems: Set<WorkspaceSidebarItem> = []
    private let addProjectAction: WorkspaceSidebarAddProjectAction
    private let createConversationAction: WorkspaceSidebarCreateConversationAction
    private let renameConversationAction: WorkspaceSidebarRenameConversationAction
    private let openNewTabAction: WorkspaceSidebarOpenNewTabAction
    private let presentError: WorkspaceSidebarErrorPresenter
    private let newTabButton = NSButton()
    private var commandInFlight = false
    private var renameInFlight: Set<ConversationID> = []

    init(
        viewModel: WorkspaceViewModel,
        addProject: WorkspaceSidebarAddProjectAction? = nil,
        createConversation: WorkspaceSidebarCreateConversationAction? = nil,
        renameConversation: WorkspaceSidebarRenameConversationAction? = nil,
        openNewTab: WorkspaceSidebarOpenNewTabAction? = nil,
        presentError: WorkspaceSidebarErrorPresenter? = nil
    ) {
        self.viewModel = viewModel
        addProjectAction = addProject ?? { [weak viewModel] in
            guard let viewModel else { throw CancellationError() }
            _ = try await viewModel.addProject()
        }
        createConversationAction = createConversation ?? { [weak viewModel] projectID in
            guard let viewModel else { throw CancellationError() }
            _ = try await viewModel.createConversation(projectID: projectID)
        }
        renameConversationAction = renameConversation ?? { [weak viewModel] id, title in
            guard let viewModel else { throw CancellationError() }
            try await viewModel.renameConversation(id: id, title: title)
        }
        openNewTabAction = openNewTab ?? { [weak viewModel] active in
            guard let viewModel else { throw CancellationError() }
            _ = try await viewModel.openNewTabPicker(in: active)
        }
        self.presentError = presentError ?? { NSApp.presentError($0) }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("workspace-sidebar"))
        column.title = "Workspace"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .medium

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let addProject = NSButton(
            title: "Add Project",
            target: self,
            action: #selector(addProject(_:))
        )
        addProject.identifier = NSUserInterfaceItemIdentifier("workspace-add-project")
        let newConversation = NSButton(
            title: "New Conversation",
            target: self,
            action: #selector(newConversation(_:))
        )
        newConversation.identifier = NSUserInterfaceItemIdentifier("workspace-new-conversation")
        newTabButton.title = "New Tab"
        newTabButton.target = self
        newTabButton.action = #selector(newTab(_:))
        newTabButton.identifier = NSUserInterfaceItemIdentifier("workspace-new-tab")
        newTabButton.isEnabled = false
        let actions = NSStackView(views: [addProject, newConversation, newTabButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(actions)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -8),
            actions.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func update(projects: WorkspaceSnapshot, activeContext: ActiveContext?) {
        self.projects = projects
        newTabButton.isEnabled = activeContext != nil
        selectableItems = Set(projects.flatMap { project in
            [.project(project.projectID)]
                + project.conversations.map { .conversation($0.id) }
        })
        outlineView.reloadData()
        outlineView.expandItem(nil, expandChildren: true)
        guard let activeContext,
              let row = row(for: activeContext.contextID),
              row >= 0
        else { return }
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func isSelectable(_ item: WorkspaceSidebarItem) -> Bool {
        selectableItems.contains(item)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let item else { return projects.count }
        guard let sidebarItem = item as? WorkspaceSidebarItem,
              case let .project(projectID) = sidebarItem,
              let project = projects.first(where: { $0.projectID == projectID })
        else { return 0 }
        return project.conversations.count
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        guard let item else {
            return WorkspaceSidebarItem.project(projects[index].projectID)
        }
        guard let sidebarItem = item as? WorkspaceSidebarItem,
              case let .project(projectID) = sidebarItem,
              let project = projects.first(where: { $0.projectID == projectID })
        else { preconditionFailure("Invalid sidebar hierarchy") }
        return WorkspaceSidebarItem.conversation(project.conversations[index].id)
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let sidebarItem = item as? WorkspaceSidebarItem,
              case let .project(projectID) = sidebarItem
        else { return false }
        return projects.contains { $0.projectID == projectID }
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldSelectItem item: Any
    ) -> Bool {
        guard let item = item as? WorkspaceSidebarItem else { return false }
        return isSelectable(item)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let item = item as? WorkspaceSidebarItem else { return nil }
        switch item {
        case .project:
            return NSTextField(labelWithString: title(for: item))
        case let .conversation(conversationID):
            let field = WorkspaceConversationTitleField(
                conversationID: conversationID,
                originalTitle: title(for: item)
            )
            field.delegate = self
            return field
        }
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0,
              let item = outlineView.item(atRow: selectedRow) as? WorkspaceSidebarItem,
              let viewModel
        else { return }
        let contextID: WorkspaceContextID
        switch item {
        case let .project(projectID): contextID = .project(projectID)
        case let .conversation(conversationID): contextID = .conversation(conversationID)
        }
        guard viewModel.activeContext?.contextID != contextID else { return }
        Task { try? await viewModel.selectContext(contextID) }
    }

    @objc private func addProject(_ sender: NSButton) {
        run { try await self.addProjectAction() }
    }

    @objc private func newConversation(_ sender: NSButton) {
        guard let projectID = viewModel?.activeContext?.projectID else { return }
        run { try await self.createConversationAction(projectID) }
    }

    @objc private func newTab(_ sender: NSButton) {
        guard let active = viewModel?.activeContext else { return }
        run { try await self.openNewTabAction(active) }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? WorkspaceConversationTitleField else { return }
        guard renameInFlight.insert(field.conversationID).inserted else { return }
        let title = field.stringValue
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            renameInFlight.remove(field.conversationID)
            field.stringValue = field.originalTitle
            presentError(WorkspaceSidebarValidationError.emptyConversationTitle)
            return
        }
        field.isEditable = false
        Task { @MainActor [weak self, weak field] in
            guard let self, let field else { return }
            defer {
                renameInFlight.remove(field.conversationID)
                field.isEditable = true
            }
            do {
                try await renameConversationAction(field.conversationID, title)
            } catch is CancellationError {
                field.stringValue = field.originalTitle
            } catch {
                field.stringValue = field.originalTitle
                presentError(error)
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !commandInFlight else { return }
        commandInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { commandInFlight = false }
            do { try await operation() }
            catch is CancellationError { return }
            catch { presentError(error) }
        }
    }

    private func title(for item: WorkspaceSidebarItem) -> String {
        switch item {
        case let .project(projectID):
            projects.first(where: { $0.projectID == projectID })?.displayName ?? "Project"
        case let .conversation(conversationID):
            projects.flatMap(\.conversations)
                .first(where: { $0.id == conversationID })?.title ?? "Conversation"
        }
    }

    private func row(for contextID: WorkspaceContextID) -> Int? {
        let item: WorkspaceSidebarItem
        switch contextID {
        case let .project(projectID): item = .project(projectID)
        case let .conversation(conversationID): item = .conversation(conversationID)
        }
        let row = outlineView.row(forItem: item)
        return row == -1 ? nil : row
    }
}
