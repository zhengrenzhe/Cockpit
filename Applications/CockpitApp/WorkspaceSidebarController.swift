import AppKit
import CockpitHostCore
import CockpitTypes

@MainActor
final class WorkspaceSidebarController: NSViewController,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate
{
    let outlineView = NSOutlineView()
    private weak var viewModel: WorkspaceViewModel?
    private var projects: WorkspaceSnapshot = []
    private var selectableItems: Set<WorkspaceSidebarItem> = []

    init(viewModel: WorkspaceViewModel) {
        self.viewModel = viewModel
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
        view = scrollView
    }

    func update(projects: WorkspaceSnapshot, activeContext: ActiveContext?) {
        self.projects = projects
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
        return NSTextField(labelWithString: title(for: item))
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
