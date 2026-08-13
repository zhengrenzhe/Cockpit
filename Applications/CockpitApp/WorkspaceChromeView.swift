import AppKit

@MainActor
final class WorkspaceHeaderBackgroundView: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }

    init(identifier: String) {
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class WorkspaceColumnView: NSView {
    let headerContainer: WorkspaceHeaderBackgroundView
    let contentContainer = NSView()
    let footerContainer = NSVisualEffectView()
    let headerHeightConstraint: NSLayoutConstraint
    let footerHeightConstraint: NSLayoutConstraint

    init(
        identifier: String,
        headerIdentifier: String,
        header: NSView,
        content: NSView,
        footer: NSView
    ) {
        headerContainer = WorkspaceHeaderBackgroundView(identifier: headerIdentifier)
        headerHeightConstraint = headerContainer.heightAnchor.constraint(equalToConstant: 48)
        footerHeightConstraint = footerContainer.heightAnchor.constraint(equalToConstant: 24)
        super.init(frame: .zero)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)

        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        headerContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.translatesAutoresizingMaskIntoConstraints = false
        footerContainer.identifier = NSUserInterfaceItemIdentifier("workspace-column-footer")
        footerContainer.material = .sidebar
        footerContainer.blendingMode = .withinWindow
        footerContainer.state = .active

        addSubview(headerContainer)
        addSubview(contentContainer)
        addSubview(footerContainer)
        NSLayoutConstraint.activate([
            headerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            headerContainer.topAnchor.constraint(equalTo: topAnchor),
            headerHeightConstraint,
            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentContainer.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footerHeightConstraint,
        ])
        install(header, in: headerContainer)
        install(content, in: contentContainer)
        install(footer, in: footerContainer)
    }

    required init?(coder: NSCoder) { nil }

    private func install(_ child: NSView, in container: NSView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(child)
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            child.topAnchor.constraint(equalTo: container.topAnchor),
            child.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}

@MainActor
func workspaceSymbolButton(
    symbolName: String,
    accessibilityLabel: String,
    identifier: String,
    target: AnyObject?,
    action: Selector
) -> NSButton {
    let image = NSImage(
        systemSymbolName: symbolName,
        accessibilityDescription: accessibilityLabel
    ) ?? NSImage()
    let button = NSButton(image: image, target: target, action: action)
    button.identifier = NSUserInterfaceItemIdentifier(identifier)
    button.isBordered = false
    button.bezelStyle = .inline
    button.imagePosition = .imageOnly
    button.toolTip = accessibilityLabel
    button.setAccessibilityLabel(accessibilityLabel)
    return button
}

@MainActor
func workspaceFooterLabel(_ value: String) -> NSTextField {
    let label = NSTextField(labelWithString: value.uppercased())
    label.font = .systemFont(ofSize: 10, weight: .medium)
    label.textColor = .secondaryLabelColor
    label.alignment = .left
    label.lineBreakMode = .byTruncatingTail
    return label
}
