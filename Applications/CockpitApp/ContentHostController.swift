import AppKit
import CockpitTypes

typealias TerminalContentControllerFactory = @MainActor (
    WorkspaceTab,
    ActiveContext,
    ClientInstanceID
) -> NSViewController

@MainActor
protocol TerminalContentRetiring: AnyObject {
    func detach()
    func detachAndWait() async
}

extension TerminalTabViewController: TerminalContentRetiring {}

@MainActor
final class ContentHostController: NSViewController {
    private struct CachedTerminalController {
        let sessionID: TerminalSessionID
        let controller: NSViewController
    }

    let monacoController: MonacoEditorViewController
    private let clientInstanceID: ClientInstanceID
    private let terminalControllerFactory: TerminalContentControllerFactory
    private let newTabPickerChoice: NewTabPickerChoiceHandler
    private let newTabPickerCancellation: NewTabPickerCancellationHandler
    private var terminalControllers: [TabID: CachedTerminalController] = [:]
    private var pickerControllers: [TabID: NewTabPickerController] = [:]
    private var synchronizedContextID: WorkspaceContextID?
    private weak var visibleController: NSViewController?

    init(
        monacoController: MonacoEditorViewController,
        clientInstanceID: ClientInstanceID,
        terminalControllerFactory: @escaping TerminalContentControllerFactory,
        newTabPickerChoice: @escaping NewTabPickerChoiceHandler,
        newTabPickerCancellation: @escaping NewTabPickerCancellationHandler
    ) {
        self.monacoController = monacoController
        self.clientInstanceID = clientInstanceID
        self.terminalControllerFactory = terminalControllerFactory
        self.newTabPickerChoice = newTabPickerChoice
        self.newTabPickerCancellation = newTabPickerCancellation
        super.init(nibName: nil, bundle: nil)
        addChild(monacoController)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        installView(for: monacoController)
        monacoController.view.isHidden = true
    }

    func show(_ tab: WorkspaceTab?, in context: ActiveContext) {
        loadViewIfNeeded()
        guard let tab else {
            hideCurrentContent()
            return
        }
        switch tab.kind {
        case .file:
            showController(monacoController)
        case let .shell(sessionID), let .codex(sessionID), let .claude(sessionID):
            let controller: NSViewController
            if let cached = terminalControllers[tab.id], cached.sessionID == sessionID {
                controller = cached.controller
            } else {
                retireTerminalController(for: tab.id)
                let value = terminalControllerFactory(tab, context, clientInstanceID)
                terminalControllers[tab.id] = CachedTerminalController(
                    sessionID: sessionID,
                    controller: value
                )
                addChild(value)
                installView(for: value)
                if let terminal = value as? TerminalTabViewController {
                    Task { try? await terminal.attach(
                        sessionID: sessionID,
                        lastAcknowledgedSequence: nil
                    ) }
                }
                controller = value
            }
            showController(controller)
        case .newTabPicker:
            let controller = pickerControllers[tab.id] ?? {
                let value = NewTabPickerController(
                    tabID: tab.id,
                    contextID: context.contextID,
                    onChoose: newTabPickerChoice,
                    onCancel: newTabPickerCancellation
                )
                pickerControllers[tab.id] = value
                addChild(value)
                installView(for: value)
                return value
            }()
            showController(controller)
        }
    }

    func synchronize(tabs: [WorkspaceTab], contextID: WorkspaceContextID?) {
        if synchronizedContextID != contextID {
            for tabID in Array(terminalControllers.keys) {
                retireTerminalController(for: tabID)
            }
            for controller in pickerControllers.values { retire(controller) }
            pickerControllers.removeAll()
            synchronizedContextID = contextID
        }
        let terminalSessions = Dictionary(uniqueKeysWithValues: tabs.compactMap { tab in
            tab.kind.terminalSessionID.map { (tab.id, $0) }
        })
        let retiredTerminalIDs = terminalControllers.compactMap { tabID, cached in
            terminalSessions[tabID] != cached.sessionID ? tabID : nil
        }
        for tabID in retiredTerminalIDs {
            retireTerminalController(for: tabID)
        }

        let pickerIDs = Set(tabs.compactMap { tab in
            tab.kind == .newTabPicker ? tab.id : nil
        })
        let retiredPickerIDs = pickerControllers.keys.filter { !pickerIDs.contains($0) }
        for tabID in retiredPickerIDs {
            guard let controller = pickerControllers.removeValue(forKey: tabID) else { continue }
            retire(controller)
        }
    }

    func detachTerminalsForApplicationTermination() async {
        let controllers = Array(terminalControllers.values.map(\.controller))
        terminalControllers.removeAll(keepingCapacity: false)
        for controller in controllers {
            if let terminal = controller as? any TerminalContentRetiring {
                await terminal.detachAndWait()
            }
            retire(controller)
        }
    }

    private func showController(_ controller: NSViewController) {
        for child in children { child.view.isHidden = child !== controller }
        controller.view.isHidden = false
        visibleController = controller
    }

    private func hideCurrentContent() {
        for child in children { child.view.isHidden = true }
        visibleController = nil
    }

    private func retireTerminalController(for tabID: TabID) {
        guard let cached = terminalControllers.removeValue(forKey: tabID) else { return }
        (cached.controller as? any TerminalContentRetiring)?.detach()
        retire(cached.controller)
    }

    private func retire(_ controller: NSViewController) {
        if visibleController === controller { visibleController = nil }
        controller.view.removeFromSuperview()
        controller.removeFromParent()
    }

    private func installView(for controller: NSViewController) {
        controller.loadViewIfNeeded()
        let childView = controller.view
        guard childView.superview == nil else { return }
        childView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(childView)
        NSLayoutConstraint.activate([
            childView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            childView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            childView.topAnchor.constraint(equalTo: view.topAnchor),
            childView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }
}
