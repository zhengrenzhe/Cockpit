import AppKit
import CockpitTypes

enum NewTabPickerOption: Hashable, CaseIterable {
    case file
    case shell
    case codex
    case claude
    case reattach

    var title: String {
        switch self {
        case .file: "Open File"
        case .shell: "Shell"
        case .codex: "Codex"
        case .claude: "Claude"
        case .reattach: "Reattach Terminal"
        }
    }
}

typealias NewTabPickerChoiceHandler = @MainActor @Sendable (
    NewTabPickerOption,
    TabID,
    WorkspaceContextID
) async throws -> Void

typealias NewTabPickerCancellationHandler = @MainActor @Sendable (
    TabID,
    WorkspaceContextID
) async throws -> Void

@MainActor
final class NewTabPickerController: NSViewController {
    private struct Key: Hashable {
        let tabID: TabID
        let contextID: WorkspaceContextID
    }

    private struct Failure {
        let option: NewTabPickerOption
        let error: NSError
    }

    private final class WeakController {
        weak var value: NewTabPickerController?
        init(_ value: NewTabPickerController) { self.value = value }
    }

    static let options = NewTabPickerOption.allCases
    private static var controllers: [Key: WeakController] = [:]
    private static var pendingFailures: [Key: Failure] = [:]

    private let tabID: TabID
    private let contextID: WorkspaceContextID
    private let onChoose: NewTabPickerChoiceHandler
    private let onCancel: NewTabPickerCancellationHandler
    private var operationInFlight = false

    init(
        tabID: TabID,
        contextID: WorkspaceContextID,
        onChoose: @escaping NewTabPickerChoiceHandler,
        onCancel: @escaping NewTabPickerCancellationHandler
    ) {
        self.tabID = tabID
        self.contextID = contextID
        self.onChoose = onChoose
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
        Self.controllers[Key(tabID: tabID, contextID: contextID)] = WeakController(self)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        let key = Key(tabID: tabID, contextID: contextID)
        Task { @MainActor in
            if Self.controllers[key]?.value == nil {
                Self.controllers.removeValue(forKey: key)
            }
        }
    }

    override func loadView() {
        let key = Key(tabID: tabID, contextID: contextID)
        if let failure = Self.pendingFailures[key] {
            renderFailure(failure)
        } else {
            renderOptions()
        }
    }

    static func presentFailure(
        _ error: any Error,
        option: NewTabPickerOption,
        tabID: TabID,
        contextID: WorkspaceContextID
    ) {
        let key = Key(tabID: tabID, contextID: contextID)
        let failure = Failure(option: option, error: error as NSError)
        pendingFailures[key] = failure
        controllers[key]?.value?.renderFailure(failure)
    }

    private func renderOptions() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        for (index, option) in Self.options.enumerated() {
            let button = NSButton(
                title: option.title,
                target: self,
                action: #selector(chooseOption(_:))
            )
            button.identifier = NSUserInterfaceItemIdentifier(
                "new-tab-\(String(describing: option))"
            )
            button.tag = index
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }
        let cancel = NSButton(
            title: "Cancel",
            target: self,
            action: #selector(cancelPicker(_:))
        )
        cancel.identifier = NSUserInterfaceItemIdentifier("new-tab-cancel")
        cancel.bezelStyle = .rounded
        stack.addArrangedSubview(cancel)
        view = stack
    }

    private func renderFailure(_ failure: Failure) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "Agent launch failed")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(NSTextField(labelWithString:
            "\(failure.error.domain) \(failure.error.code): \(failure.error.localizedDescription)"
        ))
        let retry = NSButton(
            title: "Retry",
            target: self,
            action: #selector(retryFailure(_:))
        )
        retry.identifier = NSUserInterfaceItemIdentifier("new-tab-retry")
        retry.bezelStyle = .rounded
        stack.addArrangedSubview(retry)
        if failure.option == .codex || failure.option == .claude {
            let switchAgent = NSButton(
                title: "Switch Agent",
                target: self,
                action: #selector(switchAgent(_:))
            )
            switchAgent.identifier = NSUserInterfaceItemIdentifier("new-tab-switch-agent")
            switchAgent.bezelStyle = .rounded
            stack.addArrangedSubview(switchAgent)
        }
        view = stack
    }

    @objc private func chooseOption(_ sender: NSButton) {
        guard Self.options.indices.contains(sender.tag) else { return }
        runChoice(Self.options[sender.tag])
    }

    @objc private func retryFailure(_ sender: NSButton) {
        let key = Key(tabID: tabID, contextID: contextID)
        guard let failure = Self.pendingFailures[key] else { return }
        runChoice(failure.option)
    }

    @objc private func switchAgent(_ sender: NSButton) {
        let key = Key(tabID: tabID, contextID: contextID)
        guard let option = Self.pendingFailures[key]?.option else { return }
        switch option {
        case .codex: runChoice(.claude)
        case .claude: runChoice(.codex)
        case .file, .shell, .reattach: return
        }
    }

    private func runChoice(_ option: NewTabPickerOption) {
        guard beginOperation() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                try await onChoose(option, tabID, contextID)
                let key = Key(tabID: tabID, contextID: contextID)
                Self.pendingFailures.removeValue(forKey: key)
            } catch is CancellationError {
                return
            } catch {
                Self.presentFailure(
                    error,
                    option: option,
                    tabID: tabID,
                    contextID: contextID
                )
            }
        }
    }

    @objc private func cancelPicker(_ sender: NSButton) {
        guard beginOperation() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finishOperation() }
            do {
                try await onCancel(tabID, contextID)
            } catch is CancellationError {
                return
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    private func beginOperation() -> Bool {
        guard !operationInFlight else { return false }
        operationInFlight = true
        setButtonsEnabled(false, in: view)
        return true
    }

    private func finishOperation() {
        operationInFlight = false
        setButtonsEnabled(true, in: view)
    }

    private func setButtonsEnabled(_ enabled: Bool, in view: NSView) {
        if let button = view as? NSButton { button.isEnabled = enabled }
        for child in view.subviews { setButtonsEnabled(enabled, in: child) }
    }
}
