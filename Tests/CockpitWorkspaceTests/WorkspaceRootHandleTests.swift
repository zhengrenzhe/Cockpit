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
    let swap = FileIdentitySwapAction(url: replacement)
    let guarded = WorkspaceRootHandle(rootURL: fixture.root, beforeTrashValidation: { _ in swap.run() })
    await #expect(throws: FileOperationError.identityChanged) {
        _ = try await guarded.perform(.trash(path: RelativePath("replacement.txt")))
    }
    #expect(try Data(contentsOf: replacement) == Data("replacement".utf8))
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
    private let url: URL
    private var completed = false
    init(url: URL) { self.url = url }
    func run() {
        lock.withLock {
            guard !completed else { return }
            completed = true
            let original = url.deletingLastPathComponent().appendingPathComponent("replacement-original.txt")
            try! FileManager.default.moveItem(at: url, to: original)
            try! Data("replacement".utf8).write(to: url)
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
