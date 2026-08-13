import AppKit
import CockpitTypes

struct WorkspaceTabCloseBinding: Hashable {
    let tab: WorkspaceTab
    let activeContext: ActiveContext
}

@MainActor
private final class WorkspaceTabBackgroundView: NSView {
    var hoverChanged: ((Bool) -> Void)?
    private var activeTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let activeTrackingArea { removeTrackingArea(activeTrackingArea) }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        activeTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }
}

@MainActor
final class WorkspaceTabCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("workspace-tab")
    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let selectionIndicator = NSView()
    private weak var backgroundView: WorkspaceTabBackgroundView?
    private var isHovered = false
    private var closeBinding: WorkspaceTabCloseBinding?
    private var onClose: (@MainActor (WorkspaceTabCloseBinding) -> Void)?

    override func loadView() {
        let container = WorkspaceTabBackgroundView()
        container.wantsLayer = true
        container.hoverChanged = { [weak self] hovered in
            self?.isHovered = hovered
            self?.updateAppearance()
        }
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12, weight: .medium)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.title = ""
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close Tab"
        )
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.setAccessibilityLabel("Close Tab")
        closeButton.identifier = NSUserInterfaceItemIdentifier("workspace-tab-close")
        closeButton.target = self
        closeButton.action = #selector(closeTab(_:))
        container.addSubview(label)
        container.addSubview(closeButton)
        selectionIndicator.translatesAutoresizingMaskIntoConstraints = false
        selectionIndicator.wantsLayer = true
        selectionIndicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        container.addSubview(selectionIndicator)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 20),
            selectionIndicator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            selectionIndicator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            selectionIndicator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            selectionIndicator.heightAnchor.constraint(equalToConstant: 2),
        ])
        backgroundView = container
        view = container
        updateAppearance()
    }

    func configure(
        title: String,
        closeBinding: WorkspaceTabCloseBinding,
        onClose: @escaping @MainActor (WorkspaceTabCloseBinding) -> Void
    ) {
        loadViewIfNeeded()
        label.stringValue = title
        self.closeBinding = closeBinding
        self.onClose = onClose
        updateAppearance()
    }

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    @objc private func closeTab(_ sender: NSButton) {
        guard let closeBinding else { return }
        onClose?(closeBinding)
    }

    private func updateAppearance() {
        guard isViewLoaded else { return }
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
        selectionIndicator.isHidden = !isSelected
        if isSelected {
            backgroundView?.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.13).cgColor
        } else if isHovered {
            backgroundView?.layer?.backgroundColor = NSColor.labelColor
                .withAlphaComponent(0.06).cgColor
        } else {
            backgroundView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

@MainActor
final class TabStripController: NSViewController, NSCollectionViewDelegate {
    private enum Section: Hashable { case main }

    let collectionView = NSCollectionView()
    let contentHostController: ContentHostController
    private let viewModel: WorkspaceViewModel
    private var dataSource: NSCollectionViewDiffableDataSource<Section, TabID>?
    private var tabsByID: [TabID: WorkspaceTab] = [:]
    private var activeContext: ActiveContext?
    private let footerStatusLabel = workspaceFooterLabel("No tab")

    init(
        viewModel: WorkspaceViewModel,
        contentHostController: ContentHostController
    ) {
        self.viewModel = viewModel
        self.contentHostController = contentHostController
        super.init(nibName: nil, bundle: nil)
        addChild(contentHostController)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 168, height: 48)
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 0
        collectionView.collectionViewLayout = layout
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.register(
            WorkspaceTabCollectionItem.self,
            forItemWithIdentifier: WorkspaceTabCollectionItem.identifier
        )

        let dataSource = NSCollectionViewDiffableDataSource<Section, TabID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, tabID in
            guard let item = collectionView.makeItem(
                withIdentifier: WorkspaceTabCollectionItem.identifier,
                for: indexPath
            ) as? WorkspaceTabCollectionItem else { return nil }
            if let self,
               let tab = self.tabsByID[tabID],
               let activeContext = self.activeContext
            {
                item.configure(
                    title: self.title(for: tabID),
                    closeBinding: WorkspaceTabCloseBinding(
                        tab: tab,
                        activeContext: activeContext
                    ),
                    onClose: { [weak self] binding in self?.requestClose(binding) }
                )
            }
            return item
        }
        self.dataSource = dataSource

        let tabScrollView = NSScrollView()
        tabScrollView.drawsBackground = false
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.documentView = collectionView

        let newTabButton = workspaceSymbolButton(
            symbolName: "plus",
            accessibilityLabel: "New Tab",
            identifier: "workspace-chrome-center-new-tab",
            target: self,
            action: #selector(openNewTab(_:))
        )
        newTabButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let header = NSStackView(views: [tabScrollView, newTabButton])
        header.identifier = NSUserInterfaceItemIdentifier("workspace-center-tabs")
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)

        contentHostController.loadViewIfNeeded()
        let contentView = contentHostController.view
        let root = WorkspaceColumnView(
            identifier: "workspace-column-center",
            headerIdentifier: "workspace-tabs-header",
            header: header,
            content: contentView,
            footer: footerStatusLabel
        )
        view = root
    }

    func update(
        tabs: [WorkspaceTab],
        selectedTabID: TabID?,
        activeContext: ActiveContext?
    ) {
        loadViewIfNeeded()
        tabsByID = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        self.activeContext = activeContext
        contentHostController.synchronize(
            tabs: tabs,
            contextID: activeContext?.contextID
        )
        var snapshot = NSDiffableDataSourceSnapshot<Section, TabID>()
        snapshot.appendSections([.main])
        snapshot.appendItems(tabs.map(\.id), toSection: .main)
        dataSource?.apply(snapshot, animatingDifferences: false)

        let selected = selectedTabID.flatMap { tabsByID[$0] } ?? tabs.first
        footerStatusLabel.stringValue = selected.map {
            "  \(title(for: $0.id).uppercased())"
        } ?? "  NO TAB"
        if let selected,
           let index = tabs.firstIndex(where: { $0.id == selected.id }) {
            collectionView.selectItems(
                at: [IndexPath(item: index, section: 0)],
                scrollPosition: []
            )
        }
        if let activeContext {
            contentHostController.show(selected, in: activeContext)
        }
    }

    @objc private func openNewTab(_ sender: NSButton) {
        guard let activeContext else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await viewModel.openNewTabPicker(in: activeContext)
            } catch is CancellationError {
                return
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        guard let indexPath = indexPaths.first,
              let tabID = dataSource?.itemIdentifier(for: indexPath),
              tabsByID[tabID] != nil,
              activeContext != nil
        else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await viewModel.selectTab(tabID)
            } catch is CancellationError {
                return
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    private func requestClose(_ binding: WorkspaceTabCloseBinding) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await viewModel.closeTab(
                    binding.tab.id,
                    expectedTab: binding.tab,
                    in: binding.activeContext
                )
            } catch is CancellationError {
                return
            } catch {
                NSApp.presentError(error)
            }
        }
    }

    private func title(for tabID: TabID) -> String {
        guard let tab = tabsByID[tabID] else { return "Tab" }
        return switch tab.kind {
        case .file: "File"
        case .shell: "Shell"
        case .codex: "Codex"
        case .claude: "Claude"
        case .newTabPicker: "New Tab"
        }
    }
}
