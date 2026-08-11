import AppKit
import CockpitTypes

@MainActor
private final class WorkspaceTabCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("workspace-tab")
    private let label = NSTextField(labelWithString: "")

    override func loadView() {
        let container = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        view = container
    }

    func configure(title: String) {
        loadViewIfNeeded()
        label.stringValue = title
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
        let root = NSView()
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: 160, height: 32)
        layout.minimumInteritemSpacing = 4
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
            item.configure(title: self?.title(for: tabID) ?? "Tab")
            return item
        }
        self.dataSource = dataSource

        let tabScrollView = NSScrollView()
        tabScrollView.drawsBackground = false
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.documentView = collectionView
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false

        contentHostController.loadViewIfNeeded()
        let contentView = contentHostController.view
        contentView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(tabScrollView)
        root.addSubview(contentView)
        NSLayoutConstraint.activate([
            tabScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            tabScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            tabScrollView.topAnchor.constraint(equalTo: root.topAnchor),
            tabScrollView.heightAnchor.constraint(equalToConstant: 36),
            contentView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: tabScrollView.bottomAnchor),
            contentView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
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
