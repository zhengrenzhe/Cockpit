import AppKit

@MainActor
final class WorkspaceWindowController: NSWindowController {
    let viewModel: WorkspaceViewModel
    let workspaceSplitViewController: WorkspaceSplitViewController

    init(
        viewModel: WorkspaceViewModel,
        monacoController: MonacoEditorViewController,
        relocationCoordinator: any FileRelocationCoordinating,
        fileTreeProviderFactory: @escaping FileTreeProviderFactory,
        terminalControllerFactory: @escaping TerminalContentControllerFactory
    ) {
        self.viewModel = viewModel
        workspaceSplitViewController = WorkspaceSplitViewController(
            viewModel: viewModel,
            monacoController: monacoController,
            relocationCoordinator: relocationCoordinator,
            fileTreeProviderFactory: fileTreeProviderFactory,
            terminalControllerFactory: terminalControllerFactory
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cockpit"
        window.contentViewController = workspaceSplitViewController
        window.setFrameAutosaveName("Cockpit.WorkspaceWindow")
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    func start() async throws {
        loadWindow()
        showWindow(nil)
        try await viewModel.loadWorkspace()
        workspaceSplitViewController.refresh()
    }
}
