import AppKit
import CockpitTypes

enum NewTabPickerOption: Hashable, CaseIterable {
    case file
    case shell
    case codex
    case claude

    var title: String {
        switch self {
        case .file: "Open File"
        case .shell: "Shell"
        case .codex: "Codex"
        case .claude: "Claude"
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
    static let options = NewTabPickerOption.allCases

    private let tabID: TabID
    private let contextID: WorkspaceContextID
    private let onChoose: NewTabPickerChoiceHandler
    private let onCancel: NewTabPickerCancellationHandler

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
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
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

    @objc private func chooseOption(_ sender: NSButton) {
        guard Self.options.indices.contains(sender.tag) else { return }
        let option = Self.options[sender.tag]
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onChoose(option, tabID, contextID)
            } catch is CancellationError {
                return
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    @objc private func cancelPicker(_ sender: NSButton) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await onCancel(tabID, contextID)
            } catch is CancellationError {
                return
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}
