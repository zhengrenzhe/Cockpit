import AppKit

enum WorkspaceWindowGeometry {
    static let autosaveName = "Cockpit.WorkspaceWindow"
    static let defaultContentSize = NSSize(width: 1_440, height: 900)
    static let minimumContentSize = NSSize(width: 960, height: 640)

    static func defaultFrame(visibleFrame: NSRect) -> NSRect {
        let size = NSSize(
            width: min(defaultContentSize.width, visibleFrame.width),
            height: min(defaultContentSize.height, visibleFrame.height)
        )
        return NSRect(
            x: visibleFrame.midX - (size.width / 2),
            y: visibleFrame.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    static func isRestorable(_ frame: NSRect, screens: [NSRect]) -> Bool {
        let values = [
            frame.origin.x,
            frame.origin.y,
            frame.width,
            frame.height,
        ]
        guard values.allSatisfy(\.isFinite), frame.width > 0, frame.height > 0 else {
            return false
        }
        return screens.contains { screen in
            let intersection = frame.intersection(screen)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }
    }
}

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
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: WorkspaceWindowGeometry.defaultContentSize)
        let defaultFrame = WorkspaceWindowGeometry.defaultFrame(visibleFrame: visibleFrame)
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cockpit"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = WorkspaceWindowGeometry.minimumContentSize
        window.isRestorable = true
        window.contentViewController = workspaceSplitViewController
        let restored = window.setFrameUsingName(WorkspaceWindowGeometry.autosaveName)
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        if !restored || !WorkspaceWindowGeometry.isRestorable(
            window.frame,
            screens: screenFrames
        ) {
            window.setContentSize(defaultFrame.size)
            window.center()
        }
        window.setFrameAutosaveName(WorkspaceWindowGeometry.autosaveName)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func start() async throws {
        loadWindow()
        showWindow(nil)
        try await viewModel.loadWorkspace()
        workspaceSplitViewController.refresh()
    }
}
