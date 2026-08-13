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
        super.init(nibName: nil, bundle: nil)

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
        sidebarController.update(
            projects: viewModel.projects,
            activeContext: viewModel.activeContext
        )
        tabStripController.update(
            tabs: viewModel.currentTabs,
            selectedTabID: viewModel.selectedTabID,
            activeContext: viewModel.activeContext
        )

        guard let active = viewModel.activeContext,
              providerGeneration != active.generation
        else { return }
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
}
