import AppKit

typealias WelcomeOpenProjectAction = @MainActor @Sendable () async throws -> Void

@MainActor
final class WelcomeViewController: NSViewController {
    private let openProjectAction: WelcomeOpenProjectAction
    private var openProjectTask: Task<Void, Never>?

    init(openProject: @escaping WelcomeOpenProjectAction) {
        openProjectAction = openProject
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        openProjectTask?.cancel()
    }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .contentBackground
        background.blendingMode = .withinWindow
        background.state = .active

        let mark = NSImageView()
        mark.image = NSImage(
            systemSymbolName: "rectangle.3.group.fill",
            accessibilityDescription: "Cockpit"
        )
        mark.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 46,
            weight: .medium
        )
        mark.contentTintColor = .controlAccentColor
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.widthAnchor.constraint(equalToConstant: 58).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 58).isActive = true

        let title = NSTextField(labelWithString: "Welcome to Cockpit")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center

        let subtitle = NSTextField(
            wrappingLabelWithString: "Open a project to start editing files, running terminals, and working with agents."
        )
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 2

        let openProjectButton = NSButton(
            title: "Open Project…",
            target: self,
            action: #selector(openProject(_:))
        )
        openProjectButton.identifier = NSUserInterfaceItemIdentifier("welcome-open-project")
        openProjectButton.bezelStyle = .rounded
        openProjectButton.controlSize = .large
        openProjectButton.keyEquivalent = "o"
        openProjectButton.keyEquivalentModifierMask = [.command]
        openProjectButton.setAccessibilityLabel("Open Project")

        let stack = NSStackView(views: [mark, title, subtitle, openProjectButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(18, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -48),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            openProjectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 156),
        ])
        view = background
    }

    @objc private func openProject(_ sender: NSButton) {
        guard openProjectTask == nil else { return }
        sender.isEnabled = false
        openProjectTask = Task { [weak self, weak sender] in
            guard let self else { return }
            defer {
                self.openProjectTask = nil
                sender?.isEnabled = true
            }
            do {
                try await openProjectAction()
            } catch is CancellationError {
            } catch {
                NSApp.presentError(error)
            }
        }
    }
}
