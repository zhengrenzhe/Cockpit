import AppKit
import CockpitClientCore
import CockpitHostCore
import CockpitTypes

@MainActor
public protocol FileRelocationCoordinating: AnyObject {
    func performRelocation(
        _ operation: FileOperation,
        workspaceContextID: WorkspaceContextID
    ) async throws
}

struct FileTreeProviderBinding: Sendable {
    let environmentID: EnvironmentID
    let provider: any FileTreeDataTransport
}

private final class FileTreeNode: NSObject {
    var entry: FileTreeEntry
    var children: [FileTreeNode] = []

    init(entry: FileTreeEntry) {
        self.entry = entry
    }

    var directory: WorkspaceDirectory? {
        guard entry.kind == .directory else { return nil }
        return .relative(entry.identity.path)
    }
}

private struct FileTreeActionBinding: Hashable, Codable {
    let activationID: UUID
    let contextID: WorkspaceContextID
    let environmentID: EnvironmentID
    let source: RelativePath
}

private final class FileTreeNameField: NSTextField {
    let actionBinding: FileTreeActionBinding
    let originalName: String

    init(actionBinding: FileTreeActionBinding) {
        self.actionBinding = actionBinding
        originalName = actionBinding.source.string.split(separator: "/").last.map(String.init)
            ?? actionBinding.source.string
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
}

@MainActor
final class FileTreeViewController: NSViewController,
    NSOutlineViewDataSource,
    NSOutlineViewDelegate,
    NSTextFieldDelegate
{
    private static let nodePasteboardType = NSPasteboard.PasteboardType(
        "com.cockpit.file-tree.relative-path"
    )

    let outlineView = NSOutlineView()
    private let relocationCoordinator: any FileRelocationCoordinating
    private var rootNodes: [FileTreeNode] = []
    private var nodesByIdentity: [FileTreeEntryIdentity: FileTreeNode] = [:]
    private var loadedDirectories: Set<WorkspaceDirectory> = []
    private var loadingDirectories: Set<WorkspaceDirectory> = []
    private var expandedDirectories: Set<WorkspaceDirectory> = [.root]
    private var latestRevision: UInt64 = 0
    private var activationID = UUID()
    private var directoryLoadTasks: [WorkspaceDirectory: Task<Void, Never>] = [:]
    private var changesTask: Task<Void, Never>?
    private var providerBinding: FileTreeProviderBinding?
    private var activeContext: ActiveContext?
    private var acceptsGeneration: (@MainActor (UInt64) async -> Bool)?

    private(set) var providerEnvironmentID: EnvironmentID?
    private(set) var lastError: Error?

    init(relocationCoordinator: any FileRelocationCoordinating) {
        self.relocationCoordinator = relocationCoordinator
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file-tree"))
        column.title = "Files"
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.rowSizeStyle = .medium
        outlineView.allowsMultipleSelection = true
        outlineView.registerForDraggedTypes([Self.nodePasteboardType])

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = outlineView
        view = scrollView
    }

    func activate(
        _ binding: FileTreeProviderBinding,
        context: ActiveContext,
        acceptsGeneration: @escaping @MainActor (UInt64) async -> Bool
    ) {
        cancelTasks()
        let id = UUID()
        activationID = id
        providerBinding = binding
        activeContext = context
        self.acceptsGeneration = acceptsGeneration
        providerEnvironmentID = binding.environmentID
        rootNodes = []
        nodesByIdentity = [:]
        loadedDirectories = []
        loadingDirectories = []
        expandedDirectories = [.root]
        latestRevision = 0
        lastError = nil
        outlineView.reloadData()
        loadDirectory(.root, activationID: id)
    }

    func commitRename(source: RelativePath, newName: String) async throws {
        try await perform(.rename(source: source, newName: newName))
    }

    func commitMove(
        source: RelativePath,
        destinationDirectory: WorkspaceDirectory
    ) async throws {
        try await perform(
            .move(source: source, destinationDirectory: destinationDirectory)
        )
    }

    private func perform(
        _ operation: FileOperation,
        actionBinding: FileTreeActionBinding? = nil
    ) async throws {
        if let actionBinding, !acceptsActionBinding(actionBinding) {
            throw CancellationError()
        }
        guard let activeContext,
              let acceptsGeneration,
              await acceptsGeneration(activeContext.generation)
        else { throw CancellationError() }
        if let actionBinding, !acceptsActionBinding(actionBinding) {
            throw CancellationError()
        }
        try await relocationCoordinator.performRelocation(
            operation,
            workspaceContextID: activeContext.contextID
        )
        guard self.activeContext?.contextID == activeContext.contextID,
              self.activeContext?.generation == activeContext.generation,
              await acceptsGeneration(activeContext.generation)
        else {
            throw CancellationError()
        }
    }

    private func apply(_ snapshot: FileTreeSnapshot) {
        let oldNodes = children(in: snapshot.directory)
        let newIdentities = Set(snapshot.children.map(\.identity))
        for node in oldNodes where !newIdentities.contains(node.entry.identity) {
            removeSubtree(node)
        }

        let nodes = snapshot.children
            .sorted { $0.identity.path.string < $1.identity.path.string }
            .map { entry -> FileTreeNode in
                if let node = nodesByIdentity[entry.identity] {
                    node.entry = entry
                    if entry.kind != .directory {
                        for child in node.children { removeSubtree(child) }
                        node.children = []
                    }
                    return node
                }
                let node = FileTreeNode(entry: entry)
                nodesByIdentity[entry.identity] = node
                return node
            }
        setChildren(nodes, in: snapshot.directory)
        loadedDirectories.insert(snapshot.directory)
        latestRevision = max(latestRevision, snapshot.revision)
        reload(snapshot.directory)
    }

    private func apply(_ delta: FileTreeDelta) {
        guard delta.revision > latestRevision else { return }
        var nodes = children(in: delta.directory)
        for mutation in delta.mutations {
            switch mutation {
            case let .insert(entry):
                if let old = nodes.first(where: { $0.entry.identity == entry.identity }) {
                    removeSubtree(old)
                    nodes.removeAll { $0 === old }
                }
                let node = FileTreeNode(entry: entry)
                nodesByIdentity[entry.identity] = node
                nodes.append(node)
            case let .remove(identity):
                guard let old = nodes.first(where: { $0.entry.identity == identity }) else {
                    continue
                }
                nodes.removeAll { $0 === old }
                removeSubtree(old)
            case let .update(entry):
                if let node = nodes.first(where: { $0.entry.identity == entry.identity }) {
                    node.entry = entry
                    if entry.kind != .directory {
                        for child in node.children { removeSubtree(child) }
                        node.children = []
                    }
                } else {
                    let node = FileTreeNode(entry: entry)
                    nodesByIdentity[entry.identity] = node
                    nodes.append(node)
                }
            }
        }
        nodes.sort { $0.entry.identity.path.string < $1.entry.identity.path.string }
        setChildren(nodes, in: delta.directory)
        latestRevision = delta.revision
        reload(delta.directory)
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        numberOfChildrenOfItem item: Any?
    ) -> Int {
        guard let item else { return rootNodes.count }
        return (item as? FileTreeNode)?.children.count ?? 0
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        child index: Int,
        ofItem item: Any?
    ) -> Any {
        guard let item else { return rootNodes[index] }
        return (item as! FileTreeNode).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileTreeNode)?.entry.kind == .directory
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldExpandItem item: Any
    ) -> Bool {
        guard let directory = (item as? FileTreeNode)?.directory else { return false }
        expandedDirectories.insert(directory)
        loadDirectory(directory, activationID: activationID)
        return true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        shouldCollapseItem item: Any
    ) -> Bool {
        guard let directory = (item as? FileTreeNode)?.directory else { return true }
        expandedDirectories = expandedDirectories.filter {
            !$0.isDescendant(of: directory)
        }
        expandedDirectories.insert(.root)
        restartChanges()
        return true
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? FileTreeNode,
              let actionBinding = actionBinding(for: node.entry.identity.path)
        else { return nil }
        let label = FileTreeNameField(actionBinding: actionBinding)
        label.stringValue = node.entry.identity.path.string
        label.isEditable = true
        label.isBordered = false
        label.drawsBackground = false
        label.delegate = self
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        pasteboardWriterForItem item: Any
    ) -> (any NSPasteboardWriting)? {
        guard let node = item as? FileTreeNode,
              let actionBinding = actionBinding(for: node.entry.identity.path),
              let encoded = try? JSONEncoder().encode(actionBinding)
        else { return nil }
        let pasteboardItem = NSPasteboardItem()
        guard pasteboardItem.setData(
            encoded,
            forType: Self.nodePasteboardType
        ) else { return nil }
        return pasteboardItem
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        validateDrop info: any NSDraggingInfo,
        proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        guard let sourceBinding = sourceBinding(from: info),
              let destination = destinationDirectory(for: item),
              isValidDrop(source: sourceBinding.source, destination: destination)
        else { return [] }
        if index != NSOutlineViewDropOnItemIndex {
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
        }
        return .move
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        acceptDrop info: any NSDraggingInfo,
        item: Any?,
        childIndex index: Int
    ) -> Bool {
        guard let sourceBinding = sourceBinding(from: info),
              let destination = destinationDirectory(for: item),
              isValidDrop(source: sourceBinding.source, destination: destination)
        else { return false }
        Task { @MainActor [weak self] in
            do {
                try await self?.perform(
                    .move(
                        source: sourceBinding.source,
                        destinationDirectory: destination
                    ),
                    actionBinding: sourceBinding
                )
            } catch is CancellationError {
                return
            } catch {
                self?.lastError = error
                NSApp.presentError(error)
            }
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? FileTreeNameField else { return }
        guard acceptsActionBinding(field.actionBinding) else {
            field.stringValue = field.actionBinding.source.string
            return
        }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.contains("/"),
              name != field.originalName
        else {
            field.stringValue = field.actionBinding.source.string
            return
        }
        Task { @MainActor [weak self] in
            do {
                try await self?.perform(
                    .rename(source: field.actionBinding.source, newName: name),
                    actionBinding: field.actionBinding
                )
            } catch is CancellationError {
                field.stringValue = field.actionBinding.source.string
                return
            } catch {
                field.stringValue = field.actionBinding.source.string
                self?.lastError = error
                NSApp.presentError(error)
            }
        }
    }

    private func loadDirectory(
        _ directory: WorkspaceDirectory,
        activationID expectedID: UUID
    ) {
        guard !loadedDirectories.contains(directory),
              !loadingDirectories.contains(directory),
              let binding = providerBinding,
              let context = activeContext,
              let acceptsGeneration
        else {
            if loadedDirectories.contains(directory) { restartChanges() }
            return
        }
        loadingDirectories.insert(directory)
        directoryLoadTasks[directory] = Task { @MainActor [weak self] in
            do {
                let snapshot = try await binding.provider.children(at: directory)
                guard !Task.isCancelled,
                      await acceptsGeneration(context.generation),
                      let self,
                      self.activationID == expectedID,
                      snapshot.environmentID == binding.environmentID,
                      snapshot.generation == context.generation,
                      snapshot.directory == directory
                else { return }
                self.loadingDirectories.remove(directory)
                self.directoryLoadTasks.removeValue(forKey: directory)
                self.apply(snapshot)
                self.restartChanges()
            } catch is CancellationError {
                return
            } catch {
                guard await acceptsGeneration(context.generation),
                      let self,
                      self.activationID == expectedID
                else { return }
                self.loadingDirectories.remove(directory)
                self.directoryLoadTasks.removeValue(forKey: directory)
                self.lastError = error
            }
        }
    }

    private func actionBinding(for source: RelativePath) -> FileTreeActionBinding? {
        guard let context = activeContext,
              let binding = providerBinding,
              binding.environmentID == context.environmentID,
              let identity = try? FileTreeEntryIdentity(
                  validating: binding.environmentID,
                  path: source
              ),
              nodesByIdentity[identity] != nil
        else { return nil }
        return FileTreeActionBinding(
            activationID: activationID,
            contextID: context.contextID,
            environmentID: binding.environmentID,
            source: source
        )
    }

    private func acceptsActionBinding(_ binding: FileTreeActionBinding) -> Bool {
        guard binding.activationID == activationID,
              activeContext?.contextID == binding.contextID,
              activeContext?.environmentID == binding.environmentID,
              providerBinding?.environmentID == binding.environmentID,
              let identity = try? FileTreeEntryIdentity(
                  validating: binding.environmentID,
                  path: binding.source
              )
        else { return false }
        return nodesByIdentity[identity] != nil
    }

    private func sourceBinding(from info: any NSDraggingInfo) -> FileTreeActionBinding? {
        guard let encoded = info.draggingPasteboard.data(forType: Self.nodePasteboardType),
              let binding = try? JSONDecoder().decode(
                  FileTreeActionBinding.self,
                  from: encoded
              ),
              acceptsActionBinding(binding)
        else { return nil }
        return binding
    }

    private func destinationDirectory(for item: Any?) -> WorkspaceDirectory? {
        guard let item else { return .root }
        guard let node = item as? FileTreeNode,
              node.entry.identity.environmentID == providerEnvironmentID,
              nodesByIdentity[node.entry.identity] === node
        else { return nil }
        return node.directory
    }

    private func isValidDrop(
        source: RelativePath,
        destination: WorkspaceDirectory
    ) -> Bool {
        guard destination != parentDirectory(of: source) else { return false }
        guard case let .relative(destinationPath) = destination else { return true }
        return destinationPath != source
            && !destinationPath.string.hasPrefix(source.string + "/")
    }

    private func parentDirectory(of source: RelativePath) -> WorkspaceDirectory {
        let components = source.string.split(separator: "/")
        guard components.count > 1 else { return .root }
        guard let path = try? RelativePath(components.dropLast().joined(separator: "/")) else {
            return .root
        }
        return .relative(path)
    }

    private func restartChanges() {
        changesTask?.cancel()
        guard loadedDirectories.contains(.root),
              let binding = providerBinding,
              let context = activeContext,
              let acceptsGeneration
        else { return }
        let expectedID = activationID
        let stream = binding.provider.changes(
            after: latestRevision,
            expandedDirectories: expandedDirectories
        )
        changesTask = Task { @MainActor [weak self] in
            do {
                for try await delta in stream {
                    guard !Task.isCancelled,
                          await acceptsGeneration(context.generation),
                          let self,
                          self.activationID == expectedID,
                          delta.environmentID == binding.environmentID,
                          self.expandedDirectories.contains(delta.directory)
                    else { return }
                    self.apply(delta)
                }
            } catch is CancellationError {
                return
            } catch {
                guard await acceptsGeneration(context.generation),
                      let self,
                      self.activationID == expectedID
                else { return }
                self.lastError = error
            }
        }
    }

    private func children(in directory: WorkspaceDirectory) -> [FileTreeNode] {
        switch directory {
        case .root:
            return rootNodes
        case let .relative(path):
            return nodesByIdentity.values.first {
                $0.entry.identity.path == path && $0.entry.kind == .directory
            }?.children ?? []
        }
    }

    private func setChildren(
        _ nodes: [FileTreeNode],
        in directory: WorkspaceDirectory
    ) {
        switch directory {
        case .root:
            rootNodes = nodes
        case let .relative(path):
            nodesByIdentity.values.first {
                $0.entry.identity.path == path && $0.entry.kind == .directory
            }?.children = nodes
        }
    }

    private func reload(_ directory: WorkspaceDirectory) {
        switch directory {
        case .root:
            outlineView.reloadData()
        case let .relative(path):
            let node = nodesByIdentity.values.first {
                $0.entry.identity.path == path && $0.entry.kind == .directory
            }
            outlineView.reloadItem(node, reloadChildren: true)
        }
    }

    private func removeSubtree(_ node: FileTreeNode) {
        for child in node.children { removeSubtree(child) }
        nodesByIdentity.removeValue(forKey: node.entry.identity)
        if let directory = node.directory {
            loadedDirectories.remove(directory)
            loadingDirectories.remove(directory)
            directoryLoadTasks.removeValue(forKey: directory)?.cancel()
            expandedDirectories.remove(directory)
        }
    }

    private func cancelTasks() {
        for task in directoryLoadTasks.values { task.cancel() }
        directoryLoadTasks.removeAll()
        changesTask?.cancel()
        changesTask = nil
    }

    deinit {
        for task in directoryLoadTasks.values { task.cancel() }
        changesTask?.cancel()
    }
}

private extension WorkspaceDirectory {
    func isDescendant(of ancestor: WorkspaceDirectory) -> Bool {
        switch (self, ancestor) {
        case (.root, .root): return true
        case (.root, .relative), (.relative, .root): return false
        case let (.relative(path), .relative(parent)):
            return path.string == parent.string
                || path.string.hasPrefix(parent.string + "/")
        }
    }
}
