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
struct WorkspaceWindowFrameStore {
    private let loadValue: () -> String?
    private let saveValue: (String) -> Void

    init(defaults: UserDefaults) {
        loadValue = {
            defaults.string(forKey: WorkspaceWindowGeometry.autosaveName)
        }
        saveValue = {
            defaults.set($0, forKey: WorkspaceWindowGeometry.autosaveName)
        }
    }

    private init(
        loadValue: @escaping () -> String?,
        saveValue: @escaping (String) -> Void
    ) {
        self.loadValue = loadValue
        self.saveValue = saveValue
    }

    static var production: Self {
        Self(defaults: .standard)
    }

    static var disabled: Self {
        Self(loadValue: { nil }, saveValue: { _ in })
    }

    func restoredFrame(screens: [NSRect]) -> NSRect? {
        guard let value = loadValue() else { return nil }
        let frame = NSRectFromString(value)
        guard WorkspaceWindowGeometry.isRestorable(frame, screens: screens) else {
            return nil
        }
        return frame
    }

    func save(_ frame: NSRect) {
        saveValue(NSStringFromRect(frame))
    }
}

@MainActor
private final class WorkspaceWindowFramePersistence: NSObject, NSWindowDelegate {
    private let store: WorkspaceWindowFrameStore

    init(store: WorkspaceWindowFrameStore) {
        self.store = store
    }

    func windowDidMove(_ notification: Notification) {
        save(notification)
    }

    func windowDidResize(_ notification: Notification) {
        save(notification)
    }

    func windowWillClose(_ notification: Notification) {
        save(notification)
    }

    private func save(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        store.save(window.frame)
    }
}

@MainActor
final class WorkspaceWindowController: NSWindowController {
    let viewModel: WorkspaceViewModel
    let workspaceSplitViewController: WorkspaceSplitViewController
    private let framePersistence: WorkspaceWindowFramePersistence

    init(
        viewModel: WorkspaceViewModel,
        monacoController: MonacoEditorViewController,
        relocationCoordinator: any FileRelocationCoordinating,
        fileTreeProviderFactory: @escaping FileTreeProviderFactory,
        terminalControllerFactory: @escaping TerminalContentControllerFactory,
        frameStore: WorkspaceWindowFrameStore = .disabled
    ) {
        self.viewModel = viewModel
        framePersistence = WorkspaceWindowFramePersistence(store: frameStore)
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
        let screenFrames = NSScreen.screens.map(\.visibleFrame)
        if let restoredFrame = frameStore.restoredFrame(screens: screenFrames) {
            window.setFrame(restoredFrame, display: false)
        } else {
            window.setContentSize(defaultFrame.size)
            window.center()
        }
        super.init(window: window)
        window.delegate = framePersistence
    }

    required init?(coder: NSCoder) { nil }

    func start() async throws {
        loadWindow()
        showWindow(nil)
        try await viewModel.loadWorkspace()
        workspaceSplitViewController.refresh()
    }

    func prepareForApplicationTermination() async {
        await workspaceSplitViewController.contentHostController
            .detachTerminalsForApplicationTermination()
    }
}
