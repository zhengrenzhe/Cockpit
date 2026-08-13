import AppKit
import CockpitTypes

typealias FileTreeProviderFactory = @MainActor (ActiveContext) -> FileTreeProviderBinding

@MainActor
final class WorkspaceSplitViewController: NSSplitViewController {
    private static let initialSidebarWidth: CGFloat = 238
    private static let initialFileTreeWidth: CGFloat = 236

    let sidebarController: WorkspaceSidebarController
    let tabStripController: TabStripController
    let contentHostController: ContentHostController
    let fileTreeController: FileTreeViewController
    let welcomeController: WelcomeViewController

    private(set) var isShowingWelcome = false

    private let viewModel: WorkspaceViewModel
    private let fileTreeProviderFactory: FileTreeProviderFactory
    private var providerGeneration: UInt64?

    init(
        viewModel: WorkspaceViewModel,
        monacoController: MonacoEditorViewController,
        relocationCoordinator: any FileRelocationCoordinating,
        fileTreeProviderFactory: @escaping FileTreeProviderFactory,
        terminalControllerFactory: @escaping TerminalContentControllerFactory
    ) {
        self.viewModel = viewModel
        self.fileTreeProviderFactory = fileTreeProviderFactory
        sidebarController = WorkspaceSidebarController(viewModel: viewModel)
        contentHostController = ContentHostController(
            monacoController: monacoController,
            clientInstanceID: viewModel.clientInstanceID,
            terminalControllerFactory: terminalControllerFactory,
            newTabPickerChoice: { [weak viewModel] option, tabID, contextID in
                guard let viewModel else { throw CancellationError() }
                try await viewModel.routeNewTabPickerChoice(
                    option,
                    tabID: tabID,
                    contextID: contextID
                )
            },
            newTabPickerCancellation: { [weak viewModel] tabID, contextID in
                guard let viewModel else { throw CancellationError() }
                try await viewModel.routeNewTabPickerCancellation(
                    tabID: tabID,
                    contextID: contextID
                )
            }
        )
        tabStripController = TabStripController(
            viewModel: viewModel,
            contentHostController: contentHostController
        )
        fileTreeController = FileTreeViewController(
            relocationCoordinator: relocationCoordinator
        )
        welcomeController = WelcomeViewController { [weak viewModel] in
            guard let viewModel else { throw CancellationError() }
            _ = try await viewModel.addProject()
        }
        super.init(nibName: nil, bundle: nil)

        tabStripController.addChild(welcomeController)

        sidebarController.preferredContentSize = NSSize(
            width: Self.initialSidebarWidth,
            height: 900
        )
        fileTreeController.preferredContentSize = NSSize(
            width: Self.initialFileTreeWidth,
            height: 900
        )

        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = Self.initialSidebarWidth
        sidebar.maximumThickness = 420
        sidebar.holdingPriority = .defaultHigh
        let center = NSSplitViewItem(viewController: tabStripController)
        center.minimumThickness = 420
        center.holdingPriority = .defaultLow
        let fileTree = NSSplitViewItem(viewController: fileTreeController)
        fileTree.minimumThickness = Self.initialFileTreeWidth
        fileTree.maximumThickness = 520
        fileTree.holdingPriority = .init(rawValue: NSLayoutConstraint.Priority.defaultHigh.rawValue - 1)
        addSplitViewItem(sidebar)
        addSplitViewItem(center)
        addSplitViewItem(fileTree)
        splitView.dividerStyle = .thin

        viewModel.setChangeHandler { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { nil }

    func refresh() {
        let showingWelcome = viewModel.projects.isEmpty
        setWelcomeVisible(showingWelcome)
        sidebarController.update(
            projects: viewModel.projects,
            activeContext: viewModel.activeContext
        )
        tabStripController.update(
            tabs: viewModel.currentTabs,
            selectedTabID: viewModel.selectedTabID,
            activeContext: viewModel.activeContext
        )

        guard !showingWelcome,
              let active = viewModel.activeContext
        else {
            providerGeneration = nil
            fileTreeController.setWorkspaceAvailable(false)
            return
        }

        guard providerGeneration != active.generation else { return }
        providerGeneration = active.generation
        let binding = fileTreeProviderFactory(active)
        fileTreeController.activate(
            binding,
            context: active,
            acceptsGeneration: { [weak viewModel] generation in
                guard let viewModel else { return false }
                return await viewModel.accepts(generation: generation)
            }
        )
    }

    private func setWelcomeVisible(_ visible: Bool) {
        tabStripController.loadViewIfNeeded()
        welcomeController.loadViewIfNeeded()
        guard let column = tabStripController.view as? WorkspaceColumnView else {
            preconditionFailure("Tab strip must use WorkspaceColumnView")
        }
        if welcomeController.view.superview !== column.contentContainer {
            welcomeController.view.translatesAutoresizingMaskIntoConstraints = false
            column.contentContainer.addSubview(welcomeController.view)
            NSLayoutConstraint.activate([
                welcomeController.view.leadingAnchor.constraint(
                    equalTo: column.contentContainer.leadingAnchor
                ),
                welcomeController.view.trailingAnchor.constraint(
                    equalTo: column.contentContainer.trailingAnchor
                ),
                welcomeController.view.topAnchor.constraint(
                    equalTo: column.contentContainer.topAnchor
                ),
                welcomeController.view.bottomAnchor.constraint(
                    equalTo: column.contentContainer.bottomAnchor
                ),
            ])
        }
        welcomeController.view.isHidden = !visible
        if visible {
            column.contentContainer.addSubview(
                welcomeController.view,
                positioned: .above,
                relativeTo: nil
            )
        }
        isShowingWelcome = visible
    }
}
