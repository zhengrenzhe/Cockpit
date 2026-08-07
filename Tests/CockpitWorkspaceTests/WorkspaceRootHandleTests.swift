import Darwin
import Foundation
import Testing
import CockpitHostCore
import CockpitTypes
@testable import CockpitWorkspace

@Test func rootHandleCreatesFilesAndDirectoriesAtRootAndNestedParents() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("nested"), withIntermediateDirectories: false)
    let handle = WorkspaceRootHandle(rootURL: fixture.root)

    let rootFile = try await handle.perform(.createFile(parent: .root, name: "root.txt"))
    let rootDirectory = try await handle.perform(.createDirectory(parent: .root, name: "folder"))
    let nestedFile = try await handle.perform(.createFile(parent: .relative(RelativePath("nested")), name: "child.txt"))
    let nestedDirectory = try await handle.perform(.createDirectory(parent: .relative(RelativePath("nested")), name: "child-folder"))

    #expect(rootFile.result == .created(path: try RelativePath("root.txt"), kind: .file))
    #expect(rootDirectory.result == .created(path: try RelativePath("folder"), kind: .directory))
    #expect(nestedFile.result == .created(path: try RelativePath("nested/child.txt"), kind: .file))
    #expect(nestedDirectory.result == .created(path: try RelativePath("nested/child-folder"), kind: .directory))
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("root.txt").path))
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("nested/child.txt").path))
}

@Test func rootHandleRejectsInvalidNamesDecodedPathsAndMoveIntoDescendant() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let handle = WorkspaceRootHandle(rootURL: fixture.root)

    for name in ["", ".", "..", "slash/name", "nul\0name"] {
        await #expect(throws: FileOperationError.invalidName) {
            _ = try await handle.perform(.createFile(parent: .root, name: name))
        }
    }

    for raw in ["/absolute", "../outside", "parent/../outside"] {
        let decoded = try JSONDecoder().decode(RelativePath.self, from: Data(#"{"string":"\#(raw)"}"#.utf8))
        await #expect(throws: FileOperationError.invalidPath) {
            _ = try await handle.perform(.trash(path: decoded))
        }
        let directory = WorkspaceDirectory.relative(decoded)
        await #expect(throws: FileOperationError.invalidPath) {
            _ = try await handle.perform(.createFile(parent: directory, name: "child"))
        }
    }

    try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("tree/child"), withIntermediateDirectories: true)
    await #expect(throws: FileOperationError.moveIntoDescendant) {
        _ = try await handle.perform(
            .move(source: RelativePath("tree"), destinationDirectory: .relative(RelativePath("tree/child")))
        )
    }
}

@Test func createRenameAndMoveCollisionsNeverReplaceExistingItems() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    let handle = WorkspaceRootHandle(rootURL: fixture.root)
    try Data("destination".utf8).write(to: fixture.root.appendingPathComponent("existing.txt"))

    do {
        _ = try await handle.perform(.createFile(parent: .root, name: "existing.txt"))
        Issue.record("Expected exclusive create to fail")
    } catch {
        let actual = error as NSError
        #expect(actual.domain == NSPOSIXErrorDomain)
        #expect(actual.code == Int(EEXIST))
        #expect(actual.userInfo[NSFilePathErrorKey] as? String == fixture.root.appendingPathComponent("existing.txt").path)
    }
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("existing.txt")) == Data("destination".utf8))

    try manager.createDirectory(at: fixture.root.appendingPathComponent("existing-directory"), withIntermediateDirectories: false)
    let stagingCount = LockedCounter()
    let directoryHandle = WorkspaceRootHandle(
        rootURL: fixture.root,
        afterCreatingDirectoryStaging: { _ in _ = stagingCount.increment() }
    )
    await #expect(throws: (any Error).self) {
        _ = try await directoryHandle.perform(.createDirectory(parent: .root, name: "existing-directory"))
    }
    #expect(stagingCount.current == 0)
    #expect(
        try manager.contentsOfDirectory(atPath: fixture.root.path)
            .filter { $0.hasPrefix(".cockpit-mkdir-") }
            .isEmpty
    )

    try Data("source".utf8).write(to: fixture.root.appendingPathComponent("source.txt"))
    await #expect(throws: (any Error).self) {
        _ = try await handle.perform(.rename(source: RelativePath("source.txt"), newName: "existing.txt"))
    }
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("source.txt")) == Data("source".utf8))
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("existing.txt")) == Data("destination".utf8))

    try manager.createDirectory(at: fixture.root.appendingPathComponent("destination"), withIntermediateDirectories: false)
    try Data("moved-source".utf8).write(to: fixture.root.appendingPathComponent("move.txt"))
    try Data("moved-destination".utf8).write(to: fixture.root.appendingPathComponent("destination/move.txt"))
    await #expect(throws: (any Error).self) {
        _ = try await handle.perform(
            .move(source: RelativePath("move.txt"), destinationDirectory: .relative(RelativePath("destination")))
        )
    }
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("move.txt")) == Data("moved-source".utf8))
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("destination/move.txt")) == Data("moved-destination".utf8))
}

@Test func renameAndCrossDirectoryMoveReturnExactRelativePaths() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    try manager.createDirectory(at: fixture.root.appendingPathComponent("from"), withIntermediateDirectories: false)
    try manager.createDirectory(at: fixture.root.appendingPathComponent("to"), withIntermediateDirectories: false)
    try Data("rename".utf8).write(to: fixture.root.appendingPathComponent("from/old.txt"))
    try Data("move".utf8).write(to: fixture.root.appendingPathComponent("from/move.txt"))
    let handle = WorkspaceRootHandle(rootURL: fixture.root)

    let renamed = try await handle.perform(.rename(source: RelativePath("from/old.txt"), newName: "new.txt"))
    let moved = try await handle.perform(
        .move(source: RelativePath("from/move.txt"), destinationDirectory: .relative(RelativePath("to")))
    )

    #expect(renamed.result == .relocated(from: try RelativePath("from/old.txt"), to: try RelativePath("from/new.txt")))
    #expect(moved.result == .relocated(from: try RelativePath("from/move.txt"), to: try RelativePath("to/move.txt")))
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("from/new.txt")) == Data("rename".utf8))
    #expect(try Data(contentsOf: fixture.root.appendingPathComponent("to/move.txt")) == Data("move".utf8))
}

@Test func everyPathOperationRejectsAnAncestorSwappedToASymbolicLink() async throws {
    for operation in AncestorSwapOperation.allCases {
        let fixture = try FileOperationFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let inside = fixture.root.appendingPathComponent("inside")
        let outside = fixture.base.appendingPathComponent("outside")
        try manager.createDirectory(at: inside, withIntermediateDirectories: false)
        try manager.createDirectory(at: outside, withIntermediateDirectories: false)
        try manager.createDirectory(at: fixture.root.appendingPathComponent("destination"), withIntermediateDirectories: false)
        try Data("source".utf8).write(to: inside.appendingPathComponent("source.txt"))
        let swap = DirectorySwapAction(directory: inside, outside: outside)
        let handle = WorkspaceRootHandle(rootURL: fixture.root) { component in
            if component == "inside" { swap.run() }
        }

        await #expect(throws: FileOperationError.symbolicLinkTraversal) {
            _ = try await handle.perform(operation.value)
        }
        #expect(!manager.fileExists(atPath: outside.appendingPathComponent("created.txt").path))
        #expect(!manager.fileExists(atPath: outside.appendingPathComponent("created-directory").path))
        #expect(manager.fileExists(atPath: outside.appendingPathComponent("source.txt").path) == false)
        #expect(manager.fileExists(atPath: fixture.root.appendingPathComponent("inside-backup/source.txt").path))
    }
}

@Test func symlinkDestinationDirectoryIsRejectedWithoutEscapingRoot() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let outside = fixture.base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    try Data("source".utf8).write(to: fixture.root.appendingPathComponent("source.txt"))
    try FileManager.default.createSymbolicLink(
        at: fixture.root.appendingPathComponent("linked-destination"),
        withDestinationURL: outside
    )
    let handle = WorkspaceRootHandle(rootURL: fixture.root)

    await #expect(throws: FileOperationError.symbolicLinkTraversal) {
        _ = try await handle.perform(
            .move(source: RelativePath("source.txt"), destinationDirectory: .relative(RelativePath("linked-destination")))
        )
    }
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source.txt").path))
    #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("source.txt").path))
}

@Test func movingAnOpenedAncestorOutsideRootNeverMutatesTheEscapedDirectory() async throws {
    for operation in PostOpenEscapeOperation.allCases {
        let fixture = try FileOperationFixture()
        defer { fixture.remove() }
        let manager = FileManager.default
        let inside = fixture.root.appendingPathComponent("inside", isDirectory: true)
        let escaped = fixture.base.appendingPathComponent("escaped-inside", isDirectory: true)
        try manager.createDirectory(at: inside.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data("escaped-source".utf8).write(to: inside.appendingPathComponent("nested/source.txt"))
        try Data("moving".utf8).write(to: fixture.root.appendingPathComponent("moving.txt"))
        let swap = PostOpenAncestorMoveAction(directory: inside, escaped: escaped)
        let handle = WorkspaceRootHandle(rootURL: fixture.root) { component in
            if component == "nested" { swap.run() }
        }

        let result = try? await handle.perform(operation.value)
        if let trashURL = result?.trashURL { try? manager.removeItem(at: trashURL) }

        #expect(!manager.fileExists(atPath: escaped.appendingPathComponent("nested/created.txt").path))
        #expect(!manager.fileExists(atPath: escaped.appendingPathComponent("nested/created-directory").path))
        #expect(try Data(contentsOf: escaped.appendingPathComponent("nested/source.txt")) == Data("escaped-source".utf8))
        #expect(!manager.fileExists(atPath: escaped.appendingPathComponent("nested/renamed.txt").path))
        #expect(!manager.fileExists(atPath: escaped.appendingPathComponent("nested/moving.txt").path))
    }
}

@Test func sameParentRenameNeverUsesAParentMovedOutsideBetweenItsTwoResolutions() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    let inside = fixture.root.appendingPathComponent("inside", isDirectory: true)
    let escaped = fixture.base.appendingPathComponent("escaped-inside", isDirectory: true)
    try manager.createDirectory(at: inside, withIntermediateDirectories: false)
    try Data("escaped-source".utf8).write(to: inside.appendingPathComponent("source.txt"))
    let swap = PostOpenAncestorMoveAction(directory: inside, escaped: escaped)
    let callbackCount = LockedCounter()
    let handle = WorkspaceRootHandle(rootURL: fixture.root) { component in
        if component == "inside", callbackCount.increment() == 2 { swap.run() }
    }

    _ = try? await handle.perform(.rename(source: RelativePath("inside/source.txt"), newName: "renamed.txt"))

    #expect(try Data(contentsOf: escaped.appendingPathComponent("source.txt")) == Data("escaped-source".utf8))
    #expect(!manager.fileExists(atPath: escaped.appendingPathComponent("renamed.txt").path))
}

@Test func finalSymlinkRenameMoveAndTrashOperateOnTheLinkWithoutTouchingItsTarget() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    let target = fixture.root.appendingPathComponent("target.txt")
    let destination = fixture.root.appendingPathComponent("destination", isDirectory: true)
    try Data("target-bytes".utf8).write(to: target)
    try manager.createDirectory(at: destination, withIntermediateDirectories: false)
    try manager.createSymbolicLink(
        at: fixture.root.appendingPathComponent("rename-link"),
        withDestinationURL: target
    )
    try manager.createSymbolicLink(
        at: fixture.root.appendingPathComponent("move-link"),
        withDestinationURL: target
    )
    try manager.createSymbolicLink(
        at: fixture.root.appendingPathComponent("trash-link"),
        withDestinationURL: target
    )
    let handle = WorkspaceRootHandle(rootURL: fixture.root)

    _ = try await handle.perform(.rename(source: RelativePath("rename-link"), newName: "renamed-link"))
    _ = try await handle.perform(
        .move(source: RelativePath("move-link"), destinationDirectory: .relative(RelativePath("destination")))
    )
    let trashed = try await handle.perform(.trash(path: RelativePath("trash-link")))
    let trashURL = try #require(trashed.trashURL)
    defer { try? manager.removeItem(at: trashURL) }

    #expect(try manager.destinationOfSymbolicLink(atPath: fixture.root.appendingPathComponent("renamed-link").path) == target.path)
    #expect(try manager.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("move-link").path) == target.path)
    #expect(try manager.destinationOfSymbolicLink(atPath: trashURL.path) == target.path)
    #expect(try Data(contentsOf: target) == Data("target-bytes".utf8))
}

@Test func trashMovesRealItemAndRejectsIdentityReplacement() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let source = fixture.root.appendingPathComponent("trash-me.txt")
    try Data("trash".utf8).write(to: source)
    let handle = WorkspaceRootHandle(rootURL: fixture.root)
    let trashed = try await handle.perform(.trash(path: RelativePath("trash-me.txt")))
    let trashURL = try #require(trashed.trashURL)
    defer { try? FileManager.default.removeItem(at: trashURL) }

    #expect(trashed.result == .trashed(path: try RelativePath("trash-me.txt")))
    #expect(!FileManager.default.fileExists(atPath: source.path))
    #expect(FileManager.default.fileExists(atPath: trashURL.path))

    let replacement = fixture.root.appendingPathComponent("replacement.txt")
    try Data("original".utf8).write(to: replacement)
    let swap = FileIdentitySwapAction()
    let guarded = WorkspaceRootHandle(rootURL: fixture.root, beforeTrashValidation: { swap.run(at: $0) })
    do {
        _ = try await guarded.perform(.trash(path: RelativePath("replacement.txt")))
        Issue.record("Expected recovery-required failure")
    } catch let error as FileOperationRecoveryRequiredError {
        #expect(error.originalOperation == .trash(path: try RelativePath("replacement.txt")))
        guard case let .staged(stagingPath) = error.state else {
            Issue.record("Expected staged recovery state")
            return
        }
        #expect(stagingPath.string.hasPrefix(".cockpit-trash-"))
        #expect(error.originalError as? FileOperationError == .identityChanged)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent(stagingPath.string)) == Data("replacement".utf8))
        #expect(try Data(contentsOf: swap.movedURL) == Data("original".utf8))
    }
}

@Test func trashDetachesTheItemBeforeAnAncestorCanMoveOutsideTheRoot() async throws {
    let fixture = try FileOperationFixture()
    defer { fixture.remove() }
    let manager = FileManager.default
    let inside = fixture.root.appendingPathComponent("inside", isDirectory: true)
    let escaped = fixture.base.appendingPathComponent("escaped-inside", isDirectory: true)
    try manager.createDirectory(at: inside.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try Data("source".utf8).write(to: inside.appendingPathComponent("nested/source.txt"))
    try Data("sentinel".utf8).write(to: inside.appendingPathComponent("nested/sentinel.txt"))
    let swap = TrashAncestorSwapAction(directory: inside, escaped: escaped)
    let handle = WorkspaceRootHandle(rootURL: fixture.root, beforeTrashValidation: { _ in swap.run() })

    let result = try await handle.perform(.trash(path: RelativePath("inside/nested/source.txt")))
    let trashURL = try #require(result.trashURL)
    defer { try? manager.removeItem(at: trashURL) }

    #expect(result.result == .trashed(path: try RelativePath("inside/nested/source.txt")))
    #expect(try Data(contentsOf: escaped.appendingPathComponent("nested/source.txt")) == Data("external-replacement".utf8))
    #expect(try Data(contentsOf: escaped.appendingPathComponent("nested/sentinel.txt")) == Data("sentinel".utf8))
}

@Test func directoryStagingFailuresAreRecoveryRequiredAndNeverDeleteTheStagingItem() async throws {
    for failure in DirectoryStagingFailure.allCases {
        let fixture = try FileOperationFixture()
        defer { fixture.remove() }
        let action = DirectoryStagingFailureAction(root: fixture.root, failure: failure)
        let handle = WorkspaceRootHandle(
            rootURL: fixture.root,
            afterCreatingDirectoryStaging: { action.run(stagingPath: $0) }
        )

        do {
            _ = try await handle.perform(.createDirectory(parent: .root, name: "destination"))
            Issue.record("Expected recovery-required failure")
        } catch let error as FileOperationRecoveryRequiredError {
            #expect(error.originalOperation == .createDirectory(parent: .root, name: "destination"))
            guard case let .staged(stagingPath) = error.state else {
                Issue.record("Expected staged recovery state")
                continue
            }
            #expect(stagingPath.string.hasPrefix(".cockpit-mkdir-"))
            #expect(FileManager.default.fileExists(atPath: action.actualStagingURL.path))
        }
    }
}

private enum AncestorSwapOperation: CaseIterable {
    case createFile
    case createDirectory
    case rename
    case move

    var value: FileOperation {
        switch self {
        case .createFile:
            .createFile(parent: .relative(try! RelativePath("inside")), name: "created.txt")
        case .createDirectory:
            .createDirectory(parent: .relative(try! RelativePath("inside")), name: "created-directory")
        case .rename:
            .rename(source: try! RelativePath("inside/source.txt"), newName: "renamed.txt")
        case .move:
            .move(source: try! RelativePath("inside/source.txt"), destinationDirectory: .relative(try! RelativePath("destination")))
        }
    }
}

private enum PostOpenEscapeOperation: CaseIterable {
    case createFile
    case createDirectory
    case rename
    case move
    case trash

    var value: FileOperation {
        switch self {
        case .createFile:
            .createFile(parent: .relative(try! RelativePath("inside/nested")), name: "created.txt")
        case .createDirectory:
            .createDirectory(parent: .relative(try! RelativePath("inside/nested")), name: "created-directory")
        case .rename:
            .rename(source: try! RelativePath("inside/nested/source.txt"), newName: "renamed.txt")
        case .move:
            .move(source: try! RelativePath("moving.txt"), destinationDirectory: .relative(try! RelativePath("inside/nested")))
        case .trash:
            .trash(path: try! RelativePath("inside/nested/source.txt"))
        }
    }
}

private final class PostOpenAncestorMoveAction: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let escaped: URL
    private var completed = false

    init(directory: URL, escaped: URL) {
        self.directory = directory
        self.escaped = escaped
    }

    func run() {
        lock.withLock {
            guard !completed else { return }
            completed = true
            try! FileManager.default.moveItem(at: directory, to: escaped)
            try! FileManager.default.createDirectory(
                at: directory.appendingPathComponent("nested"),
                withIntermediateDirectories: true
            )
            try! Data("replacement-source".utf8).write(
                to: directory.appendingPathComponent("nested/source.txt")
            )
            try! Data("replacement-source".utf8).write(
                to: directory.appendingPathComponent("source.txt")
            )
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var current: Int { lock.withLock { value } }
    func increment() -> Int { lock.withLock { value += 1; return value } }
}

private final class DirectorySwapAction: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let outside: URL
    private var completed = false
    init(directory: URL, outside: URL) { self.directory = directory; self.outside = outside }
    func run() {
        lock.withLock {
            guard !completed else { return }
            completed = true
            let backup = directory.deletingLastPathComponent().appendingPathComponent("inside-backup")
            try! FileManager.default.moveItem(at: directory, to: backup)
            try! FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        }
    }
}

private final class FileIdentitySwapAction: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedMovedURL: URL?
    private var completed = false
    var movedURL: URL { lock.withLock { recordedMovedURL! } }
    func run(at url: URL) {
        lock.withLock {
            guard !completed else { return }
            completed = true
            let original = url.appendingPathExtension("moved")
            recordedMovedURL = original
            try! FileManager.default.moveItem(at: url, to: original)
            try! Data("replacement".utf8).write(to: url)
        }
    }
}

private final class TrashAncestorSwapAction: @unchecked Sendable {
    private let lock = NSLock()
    private let directory: URL
    private let escaped: URL
    private var completed = false
    init(directory: URL, escaped: URL) { self.directory = directory; self.escaped = escaped }
    func run() {
        lock.withLock {
            guard !completed else { return }
            completed = true
            try! FileManager.default.moveItem(at: directory, to: escaped)
            let escapedSource = escaped.appendingPathComponent("nested/source.txt")
            if !FileManager.default.fileExists(atPath: escapedSource.path) {
                try! Data("external-replacement".utf8).write(to: escapedSource)
            }
            try! FileManager.default.createSymbolicLink(at: directory, withDestinationURL: escaped)
        }
    }
}

private enum DirectoryStagingFailure: CaseIterable {
    case destinationCollision
    case identityCapture
}

private final class DirectoryStagingFailureAction: @unchecked Sendable {
    private let lock = NSLock()
    private let root: URL
    private let failure: DirectoryStagingFailure
    private var recordedStagingURL: URL?
    var actualStagingURL: URL { lock.withLock { recordedStagingURL! } }
    init(root: URL, failure: DirectoryStagingFailure) { self.root = root; self.failure = failure }
    func run(stagingPath: RelativePath) {
        lock.withLock {
            let stagingURL = root.appendingPathComponent(stagingPath.string, isDirectory: true)
            switch failure {
            case .destinationCollision:
                recordedStagingURL = stagingURL
                try! FileManager.default.createDirectory(
                    at: root.appendingPathComponent("destination", isDirectory: true),
                    withIntermediateDirectories: false
                )
            case .identityCapture:
                let moved = root.appendingPathComponent(stagingPath.string + "-moved", isDirectory: true)
                recordedStagingURL = moved
                try! FileManager.default.moveItem(at: stagingURL, to: moved)
            }
        }
    }
}

private final class FileOperationFixture {
    let base: URL
    let root: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp/cockpit-file-operation-tests.\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
